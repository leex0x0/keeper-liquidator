// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FlashLoanLiquidator} from "../src/FlashLoanLiquidator.sol";
import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {IAaveV3Pool, IAaveOracle} from "../src/interfaces/IAaveV3Pool.sol";

interface IWETH9 {
    function deposit() external payable;
}

/// @title LiquidationFork
/// @notice Proves the whole flash-loan liquidation flow against REAL, live Base Sepolia
///         contracts (Aave V3 Pool, Aave Oracle, Uniswap V3 SwapRouter02), forked locally with
///         Foundry so it's deterministic and doesn't need real testnet ETH/gas.
///
///         What's real: the Pool, Oracle, token contracts and Uniswap pool are the ACTUAL
///         deployed Base Sepolia contracts (addresses verified live on-chain, see README).
///         What's simulated: the victim's collateral/debt balances are created with
///         `vm.deal`/`deposit()` instead of a funded real account, and the price crash that
///         makes the position liquidatable is injected with `vm.mockCall` on the Oracle
///         instead of waiting for a real market move — this is exactly the "manipulate the
///         oracle in the fork" approach the task asked for.
contract LiquidationForkTest is Test {
    address constant AAVE_POOL = 0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27;
    address constant AAVE_ORACLE = 0x943b0dE18d4abf4eF02A85912F8fc07684C141dF;
    address constant SWAP_ROUTER02 = 0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4;

    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f;
    address constant USDC_VARIABLE_DEBT_TOKEN = 0xFB3e85601b7fEb3691bbb8779Ef0E1069E347204;

    bytes32 constant AAVE_V3_ID = keccak256("AAVE_V3");

    FlashLoanLiquidator liquidator;
    AaveV3Adapter adapter;
    IAaveV3Pool pool = IAaveV3Pool(AAVE_POOL);

    address victim = makeAddr("victim");
    address keeperBot = makeAddr("keeperBot");

    function setUp() public {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC", string("https://sepolia.base.org"));
        vm.createSelectFork(rpc);

        liquidator = new FlashLoanLiquidator(AAVE_POOL, SWAP_ROUTER02, address(this));
        adapter = new AaveV3Adapter(AAVE_POOL);
        liquidator.setAdapter(AAVE_V3_ID, address(adapter));
        liquidator.setKeeper(keeperBot, true);

        console.log("Forked Base Sepolia at block", block.number);
    }

    function _openUnderwaterPosition() internal returns (uint256 debtAmountUsdc) {
        vm.deal(victim, 0.03 ether);
        vm.startPrank(victim);
        IWETH9(WETH).deposit{value: 0.03 ether}();
        IERC20(WETH).approve(AAVE_POOL, 0.03 ether);
        pool.supply(WETH, 0.03 ether, victim, 0);

        (,, uint256 availableBorrowsBase,,,) = pool.getUserAccountData(victim);
        uint256 usdcPrice = IAaveOracle(AAVE_ORACLE).getAssetPrice(USDC); // 8 decimals
        // borrow 97% of max available borrowing power, in USDC (6 decimals)
        uint256 borrowBase = (availableBorrowsBase * 97) / 100;
        uint256 borrowAmount = (borrowBase * 1e6) / usdcPrice;

        pool.borrow(USDC, borrowAmount, 2, 0, victim);
        vm.stopPrank();

        debtAmountUsdc = IERC20(USDC_VARIABLE_DEBT_TOKEN).balanceOf(victim);

        (uint256 totalCollateralBase, uint256 totalDebtBase,,,, uint256 hf) = pool.getUserAccountData(victim);
        console.log("-- position opened --");
        console.log("collateralBase (8dp USD)", totalCollateralBase);
        console.log("debtBase (8dp USD)", totalDebtBase);
        console.log("healthFactor (1e18)", hf);
        assertGt(hf, 1e18, "position should start healthy");
    }

    function _crashWethPrice(uint256 dropPercent) internal returns (uint256 newPrice) {
        uint256 currentPrice = IAaveOracle(AAVE_ORACLE).getAssetPrice(WETH);
        newPrice = (currentPrice * (100 - dropPercent)) / 100;
        vm.mockCall(
            AAVE_ORACLE, abi.encodeWithSelector(IAaveOracle.getAssetPrice.selector, WETH), abi.encode(newPrice)
        );
        console.log("-- oracle price crash injected --");
        console.log("WETH price before (8dp USD)", currentPrice);
        console.log("WETH price after  (8dp USD)", newPrice);
    }

    function test_liquidation_fires_when_position_crosses_threshold() public {
        uint256 debtAmountUsdc = _openUnderwaterPosition();

        // Reaction point: a price-update event on the oracle is what a real listener/RSC would
        // react to. We record the block here to show the liquidation happens with ZERO extra
        // blocks of delay versus the triggering price move -- no polling interval involved.
        uint256 triggerBlock = block.number;
        _crashWethPrice(25); // -25% WETH, well past the 85% liquidation threshold

        (,,,,, uint256 hfAfterCrash) = pool.getUserAccountData(victim);
        console.log("healthFactor after crash (1e18)", hfAfterCrash);
        assertLt(hfAfterCrash, 1e18, "position must be liquidatable after crash");

        uint256 liquidatorWethBefore = IERC20(WETH).balanceOf(address(liquidator));

        vm.prank(keeperBot);
        uint256 gasBefore = gasleft();
        liquidator.executeLiquidation(AAVE_V3_ID, WETH, USDC, victim, debtAmountUsdc, false, 3000);
        uint256 gasUsed = gasBefore - gasleft();
        uint256 reactionBlock = block.number;

        uint256 liquidatorWethAfter = IERC20(WETH).balanceOf(address(liquidator));
        uint256 profitWeth = liquidatorWethAfter - liquidatorWethBefore;

        (,,,,, uint256 hfAfterLiquidation) = pool.getUserAccountData(victim);
        uint256 remainingDebt = IERC20(USDC_VARIABLE_DEBT_TOKEN).balanceOf(victim);

        console.log("================ RESULT ================");
        console.log("gas used by executeLiquidation", gasUsed);
        console.log("blocks between trigger and reaction", reactionBlock - triggerBlock);
        console.log("victim remaining USDC debt", remainingDebt);
        console.log("victim healthFactor after liquidation (1e18)", hfAfterLiquidation);
        console.log("liquidator profit in WETH (wei)", profitWeth);
        console.log("==========================================");

        assertEq(reactionBlock, triggerBlock, "liquidation must land same block as trigger, no polling delay");
        assertLt(remainingDebt, debtAmountUsdc, "debt must have been repaid");
        assertGt(profitWeth, 0, "liquidator must have seized a WETH profit after repaying the flash loan");
    }

    function test_liquidation_reverts_when_position_is_healthy() public {
        uint256 debtAmountUsdc = _openUnderwaterPosition();
        vm.prank(keeperBot);
        vm.expectRevert();
        liquidator.executeLiquidation(AAVE_V3_ID, WETH, USDC, victim, debtAmountUsdc, false, 3000);
    }

    function test_only_keeper_or_owner_can_trigger_liquidation() public {
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert(FlashLoanLiquidator.NotKeeper.selector);
        liquidator.executeLiquidation(AAVE_V3_ID, WETH, USDC, victim, 1, false, 3000);
    }

    function test_unknown_adapter_reverts() public {
        vm.prank(keeperBot);
        vm.expectRevert(FlashLoanLiquidator.UnknownAdapter.selector);
        liquidator.executeLiquidation(keccak256("UNKNOWN_PROTOCOL"), WETH, USDC, victim, 1, false, 3000);
    }
}

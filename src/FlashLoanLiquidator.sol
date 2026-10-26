// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAaveV3Pool, IFlashLoanSimpleReceiver} from "./interfaces/IAaveV3Pool.sol";
import {IProtocolAdapter} from "./interfaces/IProtocolAdapter.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

/// @title FlashLoanLiquidator
/// @notice Core, protocol-agnostic liquidation engine. Funds liquidations with an Aave V3
///         flash loan (flashLoanSimple) so the caller never needs upfront capital, then routes
///         the actual liquidation call through whichever IProtocolAdapter is registered for
///         the target market (Aave V3, Compound V3, Morpho Blue, Spark, ...). Any leftover
///         collateral after repaying the flash loan + premium is profit, held here until the
///         owner withdraws it.
///
///         Adding a new protocol = deploy a new adapter implementing IProtocolAdapter and
///         register it with `setAdapter`. This contract's logic never changes.
contract FlashLoanLiquidator is IFlashLoanSimpleReceiver, Ownable {
    using SafeERC20 for IERC20;

    /// @notice The Aave V3 Pool used purely as the flash-loan funding source. This does NOT
    ///         have to be the same pool the liquidated position lives in — Aave is simply the
    ///         cheapest/most liquid flash-loan venue on most testnets/mainnets.
    IAaveV3Pool public immutable FLASHLOAN_POOL;

    /// @notice Uniswap V3 SwapRouter02-style router, used to swap seized collateral back into
    ///         the flash-loaned debt asset to repay the loan + premium.
    ISwapRouter public immutable SWAP_ROUTER;

    /// @notice protocolId => adapter. protocolId is a short human id, e.g. keccak256("AAVE_V3").
    mapping(bytes32 => address) public adapters;

    /// @notice addresses allowed to trigger `executeLiquidation` (owner + registered keepers/
    ///         the off-chain listener bot's EOA, or in future a Reactive Network callback relay).
    mapping(address => bool) public keepers;

    struct FlashParams {
        bytes32 protocolId;
        address collateralAsset;
        address debtAsset;
        address user;
        bool receiveAToken;
        uint24 swapFeeTier;
    }

    event AdapterSet(bytes32 protocolId, address adapter);
    event KeeperSet(address keeper, bool allowed);
    event LiquidationExecuted(
        bytes32 protocolId,
        address indexed user,
        address collateralAsset,
        address debtAsset,
        uint256 debtRepaid,
        uint256 collateralSeized,
        uint256 flashPremium,
        uint256 profitInCollateral
    );
    event ProfitWithdrawn(address token, address to, uint256 amount);

    error NotKeeper();
    error UnknownAdapter();
    error UntrustedCaller();
    error UntrustedInitiator();

    modifier onlyKeeper() {
        if (msg.sender != owner() && !keepers[msg.sender]) revert NotKeeper();
        _;
    }

    constructor(address flashLoanPool, address swapRouter, address initialOwner) Ownable(initialOwner) {
        require(flashLoanPool != address(0) && swapRouter != address(0), "zero addr");
        FLASHLOAN_POOL = IAaveV3Pool(flashLoanPool);
        SWAP_ROUTER = ISwapRouter(swapRouter);
    }

    function setAdapter(bytes32 protocolId, address adapter) external onlyOwner {
        adapters[protocolId] = adapter;
        emit AdapterSet(protocolId, adapter);
    }

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        keepers[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @notice Entry point the off-chain listener (or, in future, a Reactive Network callback)
    ///         calls the instant a tracked position crosses its liquidation threshold.
    /// @param protocolId      keccak256 id of the target protocol, e.g. keccak256("AAVE_V3").
    /// @param collateralAsset the collateral token to seize.
    /// @param debtAsset       the debt token to repay (this is also what gets flash-borrowed).
    /// @param user            the underwater borrower.
    /// @param debtToCover     amount of debtAsset to repay on the user's behalf.
    /// @param receiveAToken   true = receive interest-bearing aToken instead of underlying.
    /// @param swapFeeTier     Uniswap V3 fee tier (e.g. 3000 = 0.3%) for the collateral->debt
    ///                        swap used to repay the flash loan.
    function executeLiquidation(
        bytes32 protocolId,
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken,
        uint24 swapFeeTier
    ) external onlyKeeper {
        if (adapters[protocolId] == address(0)) revert UnknownAdapter();

        bytes memory params = abi.encode(
            FlashParams({
                protocolId: protocolId,
                collateralAsset: collateralAsset,
                debtAsset: debtAsset,
                user: user,
                receiveAToken: receiveAToken,
                swapFeeTier: swapFeeTier
            })
        );

        FLASHLOAN_POOL.flashLoanSimple(address(this), debtAsset, debtToCover, params, 0);
    }

    /// @dev Aave V3 flash loan callback. Only the trusted flash-loan pool may call this, and
    ///      only as a result of a flash loan WE initiated (initiator == address(this)).
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        override
        returns (bool)
    {
        if (msg.sender != address(FLASHLOAN_POOL)) revert UntrustedCaller();
        if (initiator != address(this)) revert UntrustedInitiator();

        FlashParams memory fp = abi.decode(params, (FlashParams));
        address adapterAddr = adapters[fp.protocolId];
        if (adapterAddr == address(0)) revert UnknownAdapter();
        IProtocolAdapter adapter = IProtocolAdapter(adapterAddr);

        // 1) Hand the flash-loaned debt asset to the adapter and let it perform the actual
        //    protocol-specific liquidation call.
        IERC20(asset).forceApprove(adapterAddr, amount);
        uint256 collateralSeized = adapter.liquidate(fp.collateralAsset, asset, fp.user, amount, fp.receiveAToken);

        // 2) Repay flash loan (amount + premium) by swapping just enough seized collateral
        //    back into the debt asset via Uniswap V3. Any leftover collateral stays here as
        //    profit.
        uint256 amountOwed = amount + premium;
        uint256 debtBalance = IERC20(asset).balanceOf(address(this));
        uint256 swapped = 0;
        if (debtBalance < amountOwed) {
            uint256 amountOutNeeded = amountOwed - debtBalance;
            IERC20(fp.collateralAsset).forceApprove(address(SWAP_ROUTER), collateralSeized);
            swapped = SWAP_ROUTER.exactOutputSingle(
                ISwapRouter.ExactOutputSingleParams({
                    tokenIn: fp.collateralAsset,
                    tokenOut: asset,
                    fee: fp.swapFeeTier,
                    recipient: address(this),
                    amountOut: amountOutNeeded,
                    amountInMaximum: collateralSeized,
                    sqrtPriceLimitX96: 0
                })
            );
            IERC20(fp.collateralAsset).forceApprove(address(SWAP_ROUTER), 0);
        }

        // 3) Approve the flash-loan pool to pull back what it's owed (Aave V3 convention).
        IERC20(asset).forceApprove(address(FLASHLOAN_POOL), amountOwed);

        uint256 profitInCollateral = collateralSeized - swapped;
        emit LiquidationExecuted(
            fp.protocolId, fp.user, fp.collateralAsset, asset, amount, collateralSeized, premium, profitInCollateral
        );

        return true;
    }

    function withdrawProfit(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
        emit ProfitWithdrawn(token, to, amount);
    }
}

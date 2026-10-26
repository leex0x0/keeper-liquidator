// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {FlashLoanLiquidator} from "../src/FlashLoanLiquidator.sol";
import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";

/// @notice Deploys FlashLoanLiquidator + AaveV3Adapter wired to the real, verified-live
///         Base Sepolia Aave V3 Pool and Uniswap V3 SwapRouter02 addresses (see README for the
///         on-chain verification commands/output). Run with:
///   forge script script/Deploy.s.sol:Deploy --rpc-url base_sepolia --broadcast --private-key $DEPLOYER_KEY
contract Deploy is Script {
    address constant AAVE_POOL_BASE_SEPOLIA = 0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27;
    address constant UNISWAP_SWAP_ROUTER02_BASE_SEPOLIA = 0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4;

    function run() external returns (FlashLoanLiquidator liquidator, AaveV3Adapter adapter) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        liquidator = new FlashLoanLiquidator(AAVE_POOL_BASE_SEPOLIA, UNISWAP_SWAP_ROUTER02_BASE_SEPOLIA, deployer);
        adapter = new AaveV3Adapter(AAVE_POOL_BASE_SEPOLIA);
        liquidator.setAdapter(keccak256("AAVE_V3"), address(adapter));
        liquidator.setKeeper(deployer, true);

        vm.stopBroadcast();

        console.log("FlashLoanLiquidator:", address(liquidator));
        console.log("AaveV3Adapter:", address(adapter));
    }
}

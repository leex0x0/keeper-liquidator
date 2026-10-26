// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";

/// @title MorphoBlueAdapter (STUB — NOT IMPLEMENTED)
/// @notice Placeholder for Morpho Blue support. Morpho Blue is market-isolated: each
///         (collateral, loan, oracle, irm, lltv) tuple is its own market identified by a
///         `bytes32 marketId`, and liquidation goes through `Morpho.liquidate(MarketParams,
///         address borrower, uint256 seizedAssets, uint256 repaidShares, bytes callbackData)`.
///         A real adapter needs to store/accept the MarketParams per tracked position and
///         convert Morpho's per-market LTV math into the shared totalCollateralBase/
///         totalDebtBase/healthFactor shape so the generic listener logic keeps working.
contract MorphoBlueAdapter is IProtocolAdapter {
    error NotImplemented();

    address public immutable MORPHO;

    constructor(address morpho) {
        MORPHO = morpho;
    }

    function protocolName() external pure returns (string memory) {
        return "MORPHO_BLUE";
    }

    function lendingPool() external view returns (address) {
        return MORPHO;
    }

    function getAccountData(address) external pure returns (uint256, uint256, uint256) {
        revert NotImplemented();
    }

    function isLiquidatable(address) external pure returns (bool, uint256) {
        revert NotImplemented();
    }

    function liquidate(address, address, address, uint256, bool) external pure returns (uint256) {
        revert NotImplemented();
    }
}

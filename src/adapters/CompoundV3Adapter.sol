// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";

/// @title CompoundV3Adapter (STUB — NOT IMPLEMENTED)
/// @notice Placeholder showing where Compound V3 (Comet) support plugs into the same
///         IProtocolAdapter interface the core contract already speaks. Compound V3 has no
///         single "healthFactor"; it exposes `isLiquidatable(address)` directly on Comet and
///         absorbs positions via `absorb(address absorber, address[] accounts)` followed by
///         `buyCollateral(...)` instead of Aave-style `liquidationCall`. That logic needs to be
///         written here — everything else (core contract, flash loan plumbing, reactive
///         listener) stays untouched because it only ever talks to IProtocolAdapter.
contract CompoundV3Adapter is IProtocolAdapter {
    error NotImplemented();

    address public immutable COMET;

    constructor(address comet) {
        COMET = comet;
    }

    function protocolName() external pure returns (string memory) {
        return "COMPOUND_V3";
    }

    function lendingPool() external view returns (address) {
        return COMET;
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

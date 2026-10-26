// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AaveV3Adapter} from "./AaveV3Adapter.sol";

/// @title SparkAdapter
/// @notice Spark Protocol is a permissioned fork of Aave V3 — same Pool ABI, same
///         liquidationCall signature, same getUserAccountData shape. So unlike Compound V3 /
///         Morpho Blue, Spark does NOT need new liquidation logic: it needs the exact same
///         adapter code pointed at Spark's own Pool address. This file exists mainly to make
///         that "it's just another Aave V3 deployment" fact explicit and discoverable in the
///         codebase, and to give it its own name/slot in deployment scripts.
///         NOT DEPLOYED on Base Sepolia yet — Spark does not have a Base Sepolia market at the
///         time of writing, so there is no live Pool address to point this at. Wire it up by
///         deploying `AaveV3Adapter(sparkPoolAddress)` the moment one exists; this contract is
///         left as a 1-line marker/stub rather than duplicating AaveV3Adapter's code.
contract SparkAdapter is AaveV3Adapter {
    constructor(address sparkPool) AaveV3Adapter(sparkPool) {}

    function protocolName() external pure override returns (string memory) {
        return "SPARK";
    }
}

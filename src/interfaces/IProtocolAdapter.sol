// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IProtocolAdapter
/// @notice Common surface the core FlashLoanLiquidator talks to, no matter which lending
///         market (Aave V3, Compound V3, Morpho Blue, Spark, ...) actually holds the position.
///         Each protocol gets one thin adapter that translates its own event/data shapes into
///         this shared format. The core contract and any reactive listener only ever know
///         about THIS interface, so adding a 5th protocol later = write a new adapter that
///         implements this interface, not a rewrite of the liquidation/flash-loan logic.
interface IProtocolAdapter {
    /// @notice Human-readable protocol id, e.g. "AAVE_V3", "COMPOUND_V3", "MORPHO_BLUE", "SPARK".
    function protocolName() external view returns (string memory);

    /// @notice The address that must be approved to pull `debtAsset` from the caller before
    ///         `liquidate` is called (usually the protocol's own pool/comptroller contract).
    function lendingPool() external view returns (address);

    /// @notice Read-only health check. healthFactor is 1e18-scaled; < 1e18 means liquidatable.
    ///         For protocols that don't use a single "health factor" number (e.g. Morpho Blue is
    ///         per-market), adapters normalize to this shape so the common listener logic works
    ///         the same everywhere.
    function getAccountData(address user)
        external
        view
        returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 healthFactor);

    function isLiquidatable(address user) external view returns (bool liquidatable, uint256 healthFactor);

    /// @notice Perform the actual liquidation. Caller (the core contract) must have approved
    ///         this adapter to pull `debtToCover` of `debtAsset` beforehand. The adapter pulls
    ///         the funds, calls the underlying protocol, and forwards whatever collateral it
    ///         seized back to the caller in the same transaction.
    /// @return collateralSeized amount of collateralAsset transferred back to the caller.
    function liquidate(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external returns (uint256 collateralSeized);
}

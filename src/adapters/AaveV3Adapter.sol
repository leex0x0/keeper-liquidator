// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {IAaveV3Pool} from "../interfaces/IAaveV3Pool.sol";

/// @title AaveV3Adapter
/// @notice First, fully-implemented IProtocolAdapter. Thin wrapper around a single Aave V3
///         Pool instance. Also works unmodified for any Aave V3 fork (e.g. Spark) — just
///         deploy another instance of this same adapter pointed at the fork's Pool address.
contract AaveV3Adapter is IProtocolAdapter {
    using SafeERC20 for IERC20;

    IAaveV3Pool public immutable POOL;
    uint256 private constant HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 1e18;

    constructor(address pool) {
        require(pool != address(0), "AaveV3Adapter: zero pool");
        POOL = IAaveV3Pool(pool);
    }

    function protocolName() external pure virtual returns (string memory) {
        return "AAVE_V3";
    }

    function lendingPool() external view returns (address) {
        return address(POOL);
    }

    function getAccountData(address user)
        public
        view
        returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 healthFactor)
    {
        (totalCollateralBase, totalDebtBase, , , , healthFactor) = POOL.getUserAccountData(user);
    }

    function isLiquidatable(address user) external view returns (bool liquidatable, uint256 healthFactor) {
        (, , healthFactor) = getAccountData(user);
        liquidatable = healthFactor < HEALTH_FACTOR_LIQUIDATION_THRESHOLD;
    }

    /// @dev Caller (the core FlashLoanLiquidator) must approve this adapter for `debtToCover`
    ///      of `debtAsset` before calling. Flow: pull debt from caller -> approve Pool ->
    ///      Pool.liquidationCall (pulls debt from THIS adapter, sends collateral to THIS
    ///      adapter) -> forward seized collateral back to caller.
    function liquidate(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external returns (uint256 collateralSeized) {
        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), debtToCover);
        IERC20(debtAsset).forceApprove(address(POOL), debtToCover);

        uint256 balBefore = IERC20(collateralAsset).balanceOf(address(this));
        POOL.liquidationCall(collateralAsset, debtAsset, user, debtToCover, receiveAToken);
        collateralSeized = IERC20(collateralAsset).balanceOf(address(this)) - balBefore;

        IERC20(collateralAsset).safeTransfer(msg.sender, collateralSeized);
    }
}

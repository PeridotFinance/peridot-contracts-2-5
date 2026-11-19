// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Operator-pending defaults for pSPY as plain lending collateral (feat/spy-collateral). Every default is a
/// parameter of the ceremony (env overrides in tools/spy-collateral/ceremony.sh); nothing is final until signed.
library SpyCollateralParams {
    uint256 internal constant COLLATERAL_FACTOR = 0.3e18; // 30 %
    /// @dev 0.23 SPY ~= $165 at $716.12 (RHSPY, 2026-11-19): CF 30 % x $165 ~= $49.5 SPY-backed borrow ceiling.
    uint256 internal constant DEFAULT_LENDING_SUPPLY_CAP = 0.23e18;
    /// @dev SPY -> USDG swap floor below the SPY session price in the flash liquidator (the margin pair's maxSlippage).
    uint256 internal constant LIQUIDATOR_MAX_SLIPPAGE_BPS = 100;
    uint8 internal constant USDG_DECIMALS = 6;
}

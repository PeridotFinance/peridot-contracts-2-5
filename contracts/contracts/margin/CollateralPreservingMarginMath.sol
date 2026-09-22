// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Pure accounting foundation for collateral-preserving isolated margin.
/// @dev NOT wired into the existing executor or risk engine. All values are USD WAD.
/// Collateral and trading assets MUST be disjoint: if they use the same pToken,
/// the caller must partition shares, not count the same balance twice.
/// Prices, collateral haircuts, accrued debt, exit costs and strategy liquidity
/// must be validated by the integration; this library cannot prove redeemability.
library CollateralPreservingMarginMath {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant LEVERAGE_SCALE = 100;

    error InvalidMarginRatios();
    error SignedValueOverflow();

    struct Inputs {
        uint256 eligibleCollateralUsd;
        uint256 tradingAssetsUsd;
        uint256 debtUsd;
        uint256 reservedExitCostsUsd;
        // Long: marked AVAX trading holdings. Short: marked AVAX trading debt.
        // This deliberately excludes the original, separately retained collateral.
        uint256 tradingExposureUsd;
        uint16 initialMarginBps;
        uint16 maintenanceMarginBps;
    }

    struct Metrics {
        int256 equityUsd;
        uint256 initialRequirementUsd;
        uint256 maintenanceRequirementUsd;
        uint256 tradingLeverageX100;
        uint256 healthFactorBps;
        bool meetsInitialMargin;
        bool liquidatable;
    }

    function calculate(Inputs memory input) internal pure returns (Metrics memory result) {
        if (
            input.initialMarginBps == 0 || input.initialMarginBps > BPS || input.maintenanceMarginBps == 0
                || input.maintenanceMarginBps >= input.initialMarginBps
        ) revert InvalidMarginRatios();

        uint256 assets = input.eligibleCollateralUsd + input.tradingAssetsUsd;
        uint256 liabilities = input.debtUsd + input.reservedExitCostsUsd;
        uint256 magnitude = assets >= liabilities ? assets - liabilities : liabilities - assets;
        if (magnitude > uint256(type(int256).max)) revert SignedValueOverflow();
        result.equityUsd = assets >= liabilities ? int256(magnitude) : -int256(magnitude);
        result.initialRequirementUsd =
            Math.mulDiv(input.tradingExposureUsd, input.initialMarginBps, BPS, Math.Rounding.Ceil);
        result.maintenanceRequirementUsd =
            Math.mulDiv(input.tradingExposureUsd, input.maintenanceMarginBps, BPS, Math.Rounding.Ceil);

        if (result.equityUsd <= 0) {
            result.tradingLeverageX100 = input.tradingExposureUsd == 0 ? 0 : type(uint256).max;
            result.healthFactorBps = 0;
            result.liquidatable = input.debtUsd != 0 || input.tradingExposureUsd != 0;
            return result;
        }

        uint256 equity = uint256(result.equityUsd);
        result.tradingLeverageX100 = Math.mulDiv(input.tradingExposureUsd, LEVERAGE_SCALE, equity, Math.Rounding.Ceil);
        result.healthFactorBps = result.maintenanceRequirementUsd == 0
            ? type(uint256).max
            : Math.mulDiv(equity, BPS, result.maintenanceRequirementUsd);
        result.meetsInitialMargin = equity >= result.initialRequirementUsd;
        result.liquidatable = equity < result.maintenanceRequirementUsd;
    }
}

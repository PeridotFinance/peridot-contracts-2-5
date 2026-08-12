// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IsolatedMarginTypes} from "./IsolatedMarginTypes.sol";

library IsolatedMarginMath {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant LEVERAGE_SCALE = 100;
    uint256 internal constant MAX_LEVERAGE_X100 = 500;
    uint256 internal constant WAD = 1e18;

    error InvalidRiskParameters();
    error InitialMarginTooLow();
    error LeverageExceeded();
    error PositionCapExceeded();
    error DebtCapExceeded();

    function valueUsd(uint256 amount, uint8 assetDecimals, uint256 priceUsd) internal pure returns (uint256) {
        return Math.mulDiv(amount, priceUsd, 10 ** uint256(assetDecimals));
    }

    function underlyingFromPToken(uint256 pTokenAmount, uint256 exchangeRate) internal pure returns (uint256) {
        return Math.mulDiv(pTokenAmount, exchangeRate, WAD);
    }

    function pTokenFromUnderlying(uint256 underlyingAmount, uint256 exchangeRate, Math.Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(underlyingAmount, WAD, exchangeRate, rounding);
    }

    function pTokenForUsd(
        uint256 valueUsd_,
        uint8 assetDecimals,
        uint256 priceUsd,
        uint256 exchangeRate,
        Math.Rounding rounding
    ) internal pure returns (uint256) {
        uint256 underlyingAmount = Math.mulDiv(valueUsd_, 10 ** uint256(assetDecimals), priceUsd, rounding);
        return pTokenFromUnderlying(underlyingAmount, exchangeRate, rounding);
    }

    function calculateMetrics(
        uint256 grossAssetValueUsd,
        uint256 debtValueUsd,
        uint16 initialMarginBps,
        uint16 maintenanceMarginBps
    ) internal pure returns (IsolatedMarginTypes.AccountMetrics memory metrics) {
        metrics.grossAssetValueUsd = grossAssetValueUsd;
        metrics.debtValueUsd = debtValueUsd;
        metrics.initialRequirementUsd = Math.mulDiv(grossAssetValueUsd, initialMarginBps, BPS);
        metrics.maintenanceRequirementUsd = Math.mulDiv(grossAssetValueUsd, maintenanceMarginBps, BPS);

        if (grossAssetValueUsd >= debtValueUsd) {
            uint256 equity = grossAssetValueUsd - debtValueUsd;
            require(equity <= uint256(type(int256).max), "MarginMath: equity overflow");
            metrics.equityUsd = int256(equity);

            if (equity == 0) {
                metrics.leverageX100 = type(uint256).max;
            } else {
                metrics.leverageX100 = Math.mulDiv(grossAssetValueUsd, LEVERAGE_SCALE, equity);
            }

            if (metrics.maintenanceRequirementUsd == 0) {
                metrics.healthFactorBps = type(uint256).max;
            } else {
                metrics.healthFactorBps = Math.mulDiv(equity, BPS, metrics.maintenanceRequirementUsd);
            }
        } else {
            uint256 deficit = debtValueUsd - grossAssetValueUsd;
            require(deficit <= uint256(type(int256).max), "MarginMath: deficit overflow");
            metrics.equityUsd = -int256(deficit);
            metrics.leverageX100 = type(uint256).max;
            metrics.healthFactorBps = 0;
        }
    }

    function validateRiskConfig(IsolatedMarginTypes.PairRiskConfig memory config) internal pure {
        if (
            config.maxLeverageX100 < LEVERAGE_SCALE || config.maxLeverageX100 > MAX_LEVERAGE_X100
                || config.initialMarginBps == 0 || config.initialMarginBps >= BPS || config.maintenanceMarginBps == 0
                || config.maintenanceMarginBps >= config.initialMarginBps || config.liquidationTargetBps <= BPS
                || config.fullLiquidationHealthBps >= BPS || config.maxLiquidationBps == 0
                || config.maxLiquidationBps > BPS || config.liquidationBonusBps >= BPS || config.maxSlippageBps == 0
                || config.maxSlippageBps > 3_000 || config.oracleDeviationBps == 0 || config.oracleDeviationBps > 3_000
        ) {
            revert InvalidRiskParameters();
        }

        uint256 minimumInitialMargin = Math.ceilDiv(BPS * LEVERAGE_SCALE, config.maxLeverageX100);
        if (config.initialMarginBps < minimumInitialMargin) revert InvalidRiskParameters();
    }

    function validateOpen(
        IsolatedMarginTypes.AccountMetrics memory metrics,
        IsolatedMarginTypes.PairRiskConfig memory config
    ) internal pure {
        if (metrics.equityUsd <= 0 || uint256(metrics.equityUsd) < metrics.initialRequirementUsd) {
            revert InitialMarginTooLow();
        }
        if (metrics.leverageX100 > config.maxLeverageX100) revert LeverageExceeded();
        if (config.maxPositionValueUsd != 0 && metrics.grossAssetValueUsd > config.maxPositionValueUsd) {
            revert PositionCapExceeded();
        }
        if (config.maxDebtValueUsd != 0 && metrics.debtValueUsd > config.maxDebtValueUsd) {
            revert DebtCapExceeded();
        }
    }

    function isLiquidatable(IsolatedMarginTypes.AccountMetrics memory metrics) internal pure returns (bool) {
        return metrics.equityUsd <= 0 || uint256(metrics.equityUsd) < metrics.maintenanceRequirementUsd;
    }
}

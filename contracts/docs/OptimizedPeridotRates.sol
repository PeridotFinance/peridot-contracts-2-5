// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

/**
 * @title Optimized Interest Rate Configuration for Higher Supplier APY
 * @notice Recommended parameters to incentivize liquidity providers
 */
contract OptimizedPeridotRates {
    // ===== OPTION 1: MODERATE INCREASE (Recommended) =====
    struct ModerateIncrease {
        uint baseRatePerYear; // 3% (up from 2%)
        uint multiplierPerYear; // 12% (up from 10%)
        uint jumpMultiplierPerYear; // 200% (same)
        uint kink; // 85% (up from 80%)
        uint reserveFactorMantissa; // 8% (typical is 10-20%)
    }

    // ===== OPTION 2: AGGRESSIVE INCREASE =====
    struct AggressiveIncrease {
        uint baseRatePerYear; // 4%
        uint multiplierPerYear; // 15%
        uint jumpMultiplierPerYear; // 250%
        uint kink; // 85%
        uint reserveFactorMantissa; // 5%
    }

    // ===== OPTION 3: CONSERVATIVE INCREASE =====
    struct ConservativeIncrease {
        uint baseRatePerYear; // 2.5%
        uint multiplierPerYear; // 11%
        uint jumpMultiplierPerYear; // 200%
        uint kink; // 82%
        uint reserveFactorMantissa; // 10%
    }

    function getModerateConfig()
        external
        pure
        returns (ModerateIncrease memory)
    {
        return
            ModerateIncrease({
                baseRatePerYear: 0.03 * 1e18, // 3% APR
                multiplierPerYear: 0.12 * 1e18, // 12% APR slope
                jumpMultiplierPerYear: 2.0 * 1e18, // 200% APR slope after kink
                kink: 0.85 * 1e18, // 85% utilization threshold
                reserveFactorMantissa: 0.08 * 1e18 // 8% to reserves, 92% to suppliers
            });
    }

    function getAggressiveConfig()
        external
        pure
        returns (AggressiveIncrease memory)
    {
        return
            AggressiveIncrease({
                baseRatePerYear: 0.04 * 1e18, // 4% APR
                multiplierPerYear: 0.15 * 1e18, // 15% APR slope
                jumpMultiplierPerYear: 2.5 * 1e18, // 250% APR slope after kink
                kink: 0.85 * 1e18, // 85% utilization threshold
                reserveFactorMantissa: 0.05 * 1e18 // 5% to reserves, 95% to suppliers
            });
    }

    function getConservativeConfig()
        external
        pure
        returns (ConservativeIncrease memory)
    {
        return
            ConservativeIncrease({
                baseRatePerYear: 0.025 * 1e18, // 2.5% APR
                multiplierPerYear: 0.11 * 1e18, // 11% APR slope
                jumpMultiplierPerYear: 2.0 * 1e18, // 200% APR slope after kink
                kink: 0.82 * 1e18, // 82% utilization threshold
                reserveFactorMantissa: 0.10 * 1e18 // 10% to reserves, 90% to suppliers
            });
    }

    // ===== APY PROJECTIONS =====

    /**
     * @notice Calculate estimated supplier APY at different utilization rates
     * @dev Formula: supplyAPY = utilization * borrowRate * (1 - reserveFactor)
     */
    function calculateSupplierAPY(
        uint utilization, // e.g., 0.5 * 1e18 for 50%
        uint baseRate, // annual rate
        uint multiplier, // annual rate
        uint jumpMultiplier, // annual rate
        uint kink, // utilization threshold
        uint reserveFactor // fraction going to reserves
    ) external pure returns (uint supplierAPY) {
        uint borrowRate;

        if (utilization <= kink) {
            // Normal rate: base + (utilization * multiplier / kink)
            borrowRate = baseRate + ((utilization * multiplier) / kink);
        } else {
            // Jump rate: normal rate + excess utilization * jump multiplier
            uint normalRate = baseRate + multiplier;
            uint excessUtil = utilization - kink;
            uint maxExcess = 1e18 - kink; // max possible excess
            borrowRate =
                normalRate +
                ((excessUtil * jumpMultiplier) / maxExcess);
        }

        // Supply APY = utilization * borrow rate * (1 - reserve factor)
        uint oneMinusReserve = 1e18 - reserveFactor;
        supplierAPY =
            (utilization * borrowRate * oneMinusReserve) /
            (1e18 * 1e18);

        return supplierAPY;
    }

    // ===== EXAMPLE APY COMPARISONS =====

    function compareAPYs()
        external
        pure
        returns (
            uint currentAPY50, // Current config at 50% utilization
            uint currentAPY70, // Current config at 70% utilization
            uint moderateAPY50, // Moderate config at 50% utilization
            uint moderateAPY70, // Moderate config at 70% utilization
            uint aggressiveAPY50, // Aggressive config at 50% utilization
            uint aggressiveAPY70 // Aggressive config at 70% utilization
        )
    {
        // Current configuration
        uint currentBase = 0.02 * 1e18;
        uint currentMult = 0.10 * 1e18;
        uint currentJump = 2.0 * 1e18;
        uint currentKink = 0.80 * 1e18;
        uint currentReserve = 0.15 * 1e18; // Assuming 15%

        // Calculate current APYs
        currentAPY50 = calculateSupplierAPY(
            0.5 * 1e18,
            currentBase,
            currentMult,
            currentJump,
            currentKink,
            currentReserve
        );
        currentAPY70 = calculateSupplierAPY(
            0.7 * 1e18,
            currentBase,
            currentMult,
            currentJump,
            currentKink,
            currentReserve
        );

        // Moderate configuration
        ModerateIncrease memory moderate = getModerateConfig();
        moderateAPY50 = calculateSupplierAPY(
            0.5 * 1e18,
            moderate.baseRatePerYear,
            moderate.multiplierPerYear,
            moderate.jumpMultiplierPerYear,
            moderate.kink,
            moderate.reserveFactorMantissa
        );
        moderateAPY70 = calculateSupplierAPY(
            0.7 * 1e18,
            moderate.baseRatePerYear,
            moderate.multiplierPerYear,
            moderate.jumpMultiplierPerYear,
            moderate.kink,
            moderate.reserveFactorMantissa
        );

        // Aggressive configuration
        AggressiveIncrease memory aggressive = getAggressiveConfig();
        aggressiveAPY50 = calculateSupplierAPY(
            0.5 * 1e18,
            aggressive.baseRatePerYear,
            aggressive.multiplierPerYear,
            aggressive.jumpMultiplierPerYear,
            aggressive.kink,
            aggressive.reserveFactorMantissa
        );
        aggressiveAPY70 = calculateSupplierAPY(
            0.7 * 1e18,
            aggressive.baseRatePerYear,
            aggressive.multiplierPerYear,
            aggressive.jumpMultiplierPerYear,
            aggressive.kink,
            aggressive.reserveFactorMantissa
        );

        return (
            currentAPY50,
            currentAPY70,
            moderateAPY50,
            moderateAPY70,
            aggressiveAPY50,
            aggressiveAPY70
        );
    }

    // ===== IMPLEMENTATION RECOMMENDATIONS =====

    /**
     * @notice Recommended implementation strategy
     * @dev
     * 1. Start with Conservative configuration
     * 2. Monitor utilization and supplier adoption for 2-4 weeks
     * 3. If utilization stays healthy (40-80%), move to Moderate
     * 4. If you need more aggressive growth, consider Aggressive
     * 5. Always monitor borrower demand - don't price them out
     */

    /**
     * @notice Key metrics to monitor:
     * @dev
     * - Utilization rate (target: 50-80%)
     * - Total Value Locked growth
     * - Borrower activity and retention
     * - Liquidation frequency
     * - Protocol revenue vs. supplier incentives
     */
}

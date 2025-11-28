// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import "./InterestRateModel.sol";

/**
 * @title JumpRateModelBoosted
 * @notice Jump rate model that enforces a minimum borrow APR derived from an external yield target
 *         (e.g., Morpho vault APY) so suppliers earn at least that yield (plus a safety margin)
 *         once any utilization exists. Rates are expressed per second.
 */
contract JumpRateModelBoosted is InterestRateModel {
    uint256 public constant MANTISSA_ONE = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice Utilization kink (scaled by 1e18).
    uint256 public immutable kink;

    /// @notice Annualized parameters for the pre-kink and post-kink slopes.
    uint256 public immutable baseRatePerYear;
    uint256 public immutable multiplierPerYear;
    uint256 public immutable jumpMultiplierPerYear;

    /// @notice Target external supply APY (e.g., Morpho vault APY) in 1e18 terms.
    uint256 public immutable targetMorphoSupplyAPY;

    /// @notice Reserve factor assumed when computing the borrow-rate floor (must align with market RF).
    uint256 public immutable reserveFactorMantissa;

    /// @notice Extra margin applied to the external APY when deriving the floor.
    uint256 public immutable safetyMarginMantissa;

    /// @notice Minimum borrow rate per year and per second after applying the floor.
    uint256 public immutable minBorrowRatePerYear;
    uint256 public immutable minBorrowRatePerSecond;

    /// @notice Cached per-second slopes.
    uint256 public immutable baseRatePerSecond;
    uint256 public immutable multiplierPerSecond;
    uint256 public immutable jumpMultiplierPerSecond;

    /// @notice Cached per-year rates for convenience (borrow rate returned by getBorrowRate is per second).
    function borrowRatePerYear(uint256 cash, uint256 borrows, uint256 reserves) external view returns (uint256) {
        return getBorrowRate(cash, borrows, reserves) * SECONDS_PER_YEAR;
    }

    constructor(
        uint256 baseRatePerYear_,
        uint256 multiplierPerYear_,
        uint256 jumpMultiplierPerYear_,
        uint256 kink_,
        uint256 targetMorphoSupplyAPY_,
        uint256 reserveFactorMantissa_,
        uint256 safetyMarginMantissa_
    ) {
        require(kink_ <= MANTISSA_ONE, "Boosted: invalid kink");
        require(reserveFactorMantissa_ < MANTISSA_ONE, "Boosted: RF >= 1");

        baseRatePerYear = baseRatePerYear_;
        multiplierPerYear = multiplierPerYear_;
        jumpMultiplierPerYear = jumpMultiplierPerYear_;
        kink = kink_;
        targetMorphoSupplyAPY = targetMorphoSupplyAPY_;
        reserveFactorMantissa = reserveFactorMantissa_;
        safetyMarginMantissa = safetyMarginMantissa_;

        uint256 oneMinusRf = MANTISSA_ONE - reserveFactorMantissa_;

        // floor = yMorpho / (1 - RF) * (1 + safetyMargin)
        uint256 floorNoMargin = (targetMorphoSupplyAPY_ * MANTISSA_ONE) / oneMinusRf;
        uint256 floorWithMargin = (floorNoMargin * (MANTISSA_ONE + safetyMarginMantissa_)) / MANTISSA_ONE;

        minBorrowRatePerYear = floorWithMargin;
        minBorrowRatePerSecond = floorWithMargin / SECONDS_PER_YEAR;

        baseRatePerSecond = baseRatePerYear_ / SECONDS_PER_YEAR;
        multiplierPerSecond = multiplierPerYear_ / SECONDS_PER_YEAR;
        jumpMultiplierPerSecond = jumpMultiplierPerYear_ / SECONDS_PER_YEAR;
    }

    /**
     * @notice Calculates the utilization rate of the market: `borrows / (cash + borrows - reserves)`.
     */
    function utilizationRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves
    ) public pure returns (uint256) {
        if (borrows == 0) {
            return 0;
        }
        uint256 total = cash + borrows - reserves;
        if (total == 0) {
            return 0;
        }
        return (borrows * MANTISSA_ONE) / total;
    }

    /**
     * @inheritdoc InterestRateModel
     */
    function getBorrowRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves
    ) public view override returns (uint256) {
        uint256 util = utilizationRate(cash, borrows, reserves);
        uint256 ratePerSecond;

        if (util <= kink) {
            uint256 linearPart = (multiplierPerSecond * util) / MANTISSA_ONE;
            ratePerSecond = baseRatePerSecond + linearPart;
        } else {
            uint256 normalRate = baseRatePerSecond + (multiplierPerSecond * kink) / MANTISSA_ONE;
            uint256 excessUtil = util - kink;
            uint256 jumpPart = (jumpMultiplierPerSecond * excessUtil) / MANTISSA_ONE;
            ratePerSecond = normalRate + jumpPart;
        }

        if (ratePerSecond < minBorrowRatePerSecond) {
            ratePerSecond = minBorrowRatePerSecond;
        }
        return ratePerSecond;
    }

    /**
     * @inheritdoc InterestRateModel
     */
    function getSupplyRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves,
        uint256 reserveFactorMantissa_
    ) external view override returns (uint256) {
        uint256 util = utilizationRate(cash, borrows, reserves);
        uint256 borrowRate = getBorrowRate(cash, borrows, reserves);

        // supplyRate = utilization * borrowRate * (1 - reserveFactor)
        return (util * borrowRate * (MANTISSA_ONE - reserveFactorMantissa_)) / (MANTISSA_ONE * MANTISSA_ONE);
    }

    /**
     * @notice View helper: approximate blended supplier APY including the external yield target.
     * @dev This is informational only; it assumes targetMorphoSupplyAPY as the external yield input.
     */
    function getBoostedSupplyRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves,
        uint256 reserveFactorMantissa_
    ) external view returns (uint256) {
        uint256 util = utilizationRate(cash, borrows, reserves);
        uint256 borrowRateYear = getBorrowRate(cash, borrows, reserves) * SECONDS_PER_YEAR;

        // Borrow-derived supply component
        uint256 supplyFromBorrows = (util * borrowRateYear * (MANTISSA_ONE - reserveFactorMantissa_)) / (MANTISSA_ONE * MANTISSA_ONE);

        // Blended: (1 - U) * targetMorpho + U * supplyFromBorrows
        uint256 blended = ((MANTISSA_ONE - util) * targetMorphoSupplyAPY + util * supplyFromBorrows) / MANTISSA_ONE;
        return blended;
    }
}

// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {InterestRateModel} from "./InterestRateModel.sol";

/**
 * @notice Compound-style jump-rate model with an explicit blocks-per-year assumption.
 * @dev Peridot pTokens accrue by block number. The blocks-per-year value is immutable so a
 *      network timing change requires a separately reviewed model and the pToken admin switch.
 */
contract ConfigurableJumpRateModelV2 is InterestRateModel, Ownable {
    uint256 private constant BASE = 1e18;
    uint256 public constant MIN_BLOCKS_PER_YEAR = 1_000_000;
    uint256 public constant MAX_BLOCKS_PER_YEAR = 100_000_000;
    uint256 public constant MAX_RATE_PER_YEAR = 10e18;

    uint256 public immutable blocksPerYear;
    uint256 public multiplierPerBlock;
    uint256 public baseRatePerBlock;
    uint256 public jumpMultiplierPerBlock;
    uint256 public kink;

    event NewInterestParams(
        uint256 baseRatePerBlock, uint256 multiplierPerBlock, uint256 jumpMultiplierPerBlock, uint256 kink
    );

    constructor(
        uint256 blocksPerYear_,
        uint256 baseRatePerYear,
        uint256 multiplierPerYear,
        uint256 jumpMultiplierPerYear,
        uint256 kink_,
        address owner_
    ) Ownable(owner_) {
        require(
            blocksPerYear_ >= MIN_BLOCKS_PER_YEAR && blocksPerYear_ <= MAX_BLOCKS_PER_YEAR, "RateModel: blocks per year"
        );
        blocksPerYear = blocksPerYear_;
        _updateJumpRateModel(baseRatePerYear, multiplierPerYear, jumpMultiplierPerYear, kink_);
    }

    function updateJumpRateModel(
        uint256 baseRatePerYear,
        uint256 multiplierPerYear,
        uint256 jumpMultiplierPerYear,
        uint256 kink_
    ) external onlyOwner {
        _updateJumpRateModel(baseRatePerYear, multiplierPerYear, jumpMultiplierPerYear, kink_);
    }

    function utilizationRate(uint256 cash, uint256 borrows, uint256 reserves) public pure returns (uint256) {
        if (borrows == 0) return 0;
        require(cash + borrows >= reserves, "RateModel: invalid reserves");
        uint256 denominator = cash + borrows - reserves;
        require(denominator > 0, "RateModel: zero assets");
        return Math.mulDiv(borrows, BASE, denominator);
    }

    function getBorrowRate(uint256 cash, uint256 borrows, uint256 reserves) external view override returns (uint256) {
        uint256 utilization = utilizationRate(cash, borrows, reserves);
        if (utilization <= kink) {
            return Math.mulDiv(utilization, multiplierPerBlock, BASE) + baseRatePerBlock;
        }
        uint256 normalRate = Math.mulDiv(kink, multiplierPerBlock, BASE) + baseRatePerBlock;
        return Math.mulDiv(utilization - kink, jumpMultiplierPerBlock, BASE) + normalRate;
    }

    function getSupplyRate(uint256 cash, uint256 borrows, uint256 reserves, uint256 reserveFactorMantissa)
        external
        view
        override
        returns (uint256)
    {
        require(reserveFactorMantissa <= BASE, "RateModel: reserve factor");
        uint256 utilization = utilizationRate(cash, borrows, reserves);
        uint256 borrowRate;
        if (utilization <= kink) {
            borrowRate = Math.mulDiv(utilization, multiplierPerBlock, BASE) + baseRatePerBlock;
        } else {
            uint256 normalRate = Math.mulDiv(kink, multiplierPerBlock, BASE) + baseRatePerBlock;
            borrowRate = Math.mulDiv(utilization - kink, jumpMultiplierPerBlock, BASE) + normalRate;
        }
        uint256 rateToPool = Math.mulDiv(borrowRate, BASE - reserveFactorMantissa, BASE);
        return Math.mulDiv(utilization, rateToPool, BASE);
    }

    function _updateJumpRateModel(
        uint256 baseRatePerYear,
        uint256 multiplierPerYear,
        uint256 jumpMultiplierPerYear,
        uint256 kink_
    ) private {
        require(kink_ > 0 && kink_ <= BASE, "RateModel: invalid kink");
        require(
            baseRatePerYear <= MAX_RATE_PER_YEAR && multiplierPerYear <= MAX_RATE_PER_YEAR
                && jumpMultiplierPerYear <= MAX_RATE_PER_YEAR,
            "RateModel: annual rate too high"
        );

        baseRatePerBlock = baseRatePerYear / blocksPerYear;
        multiplierPerBlock = Math.mulDiv(multiplierPerYear, BASE, blocksPerYear * kink_);
        jumpMultiplierPerBlock = jumpMultiplierPerYear / blocksPerYear;
        kink = kink_;

        emit NewInterestParams(baseRatePerBlock, multiplierPerBlock, jumpMultiplierPerBlock, kink_);
    }
}

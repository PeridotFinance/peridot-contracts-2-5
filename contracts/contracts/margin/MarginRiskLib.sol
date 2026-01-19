// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PToken} from "../PToken.sol";
import {PErc20} from "../PErc20.sol";
import {SimplePriceOracle} from "../SimplePriceOracle.sol";

interface IPeridottrollerView {
    function getAllMarkets() external view returns (PToken[] memory);

    function markets(
        address pToken
    ) external view returns (bool, uint256, bool);
}

library MarginRiskLib {
    uint256 internal constant EXP_SCALE = 1e18;
    uint256 internal constant BPS_SCALE = 1e4;

    error PriceUnavailable(address cToken);

    struct AccountMetrics {
        uint256 collateralValue; // Sum of collateral * collateralFactor (USD 1e18)
        uint256 grossCollateralValue; // Sum of collateral USD without factor (1e18)
        uint256 borrowValue; // USD 1e18
        int256 equity; // grossCollateralValue - borrowValue (signed 18 decimals)
        uint256 healthFactorBps; // CollateralValue / BorrowValue in basis points
        uint256 excessCollateralValue; // CollateralValue - HF_MIN_WITHDRAW * BorrowValue
        uint256 grossExposureValue; // grossCollateralValue + borrowValue (USD 1e18)
        bool hasMissingPrice; // True if any market with a position had price = 0
        address missingPriceMarket; // First market with missing price (if any)
    }

    function computeAccountMetrics(
        IPeridottrollerView comptroller,
        SimplePriceOracle oracle,
        address account,
        uint16 hfMinWithdrawBps
    ) internal view returns (AccountMetrics memory metrics) {
        PToken[] memory markets = comptroller.getAllMarkets();
        uint256 marketsLength = markets.length;
        address[] memory marketAddresses = new address[](marketsLength);
        for (uint256 i = 0; i < marketsLength; i++) {
            marketAddresses[i] = address(markets[i]);
        }
        return
            computeAccountMetricsForMarkets(
                comptroller,
                oracle,
                account,
                hfMinWithdrawBps,
                marketAddresses
            );
    }

    /**
     * @notice Compute account metrics with strict price checking (reverts on missing price)
     * @dev Use this for operations that require accurate metrics (borrow, trade, etc.)
     */
    function computeAccountMetricsForMarkets(
        IPeridottrollerView comptroller,
        SimplePriceOracle oracle,
        address account,
        uint16 hfMinWithdrawBps,
        address[] memory marketList
    ) internal view returns (AccountMetrics memory metrics) {
        metrics = computeAccountMetricsForMarketsInternal(
            comptroller,
            oracle,
            account,
            hfMinWithdrawBps,
            marketList,
            true // strictPriceCheck = true, revert on missing price
        );
    }

    /**
     * @notice Compute account metrics with graceful degradation on missing prices
     * @dev Use this for operations that should still proceed when possible (withdrawals, repays)
     *      Markets with missing prices are skipped and flagged in hasMissingPrice
     */
    function computeAccountMetricsForMarketsGraceful(
        IPeridottrollerView comptroller,
        SimplePriceOracle oracle,
        address account,
        uint16 hfMinWithdrawBps,
        address[] memory marketList
    ) internal view returns (AccountMetrics memory metrics) {
        metrics = computeAccountMetricsForMarketsInternal(
            comptroller,
            oracle,
            account,
            hfMinWithdrawBps,
            marketList,
            false // strictPriceCheck = false, graceful degradation
        );
    }

    /**
     * @dev Internal implementation with configurable price checking behavior
     * @param strictPriceCheck If true, revert on missing price; if false, skip and flag
     */
    function computeAccountMetricsForMarketsInternal(
        IPeridottrollerView comptroller,
        SimplePriceOracle oracle,
        address account,
        uint16 hfMinWithdrawBps,
        address[] memory marketList,
        bool strictPriceCheck
    ) internal view returns (AccountMetrics memory metrics) {
        uint256 marketsLength = marketList.length;
        for (uint256 i = 0; i < marketsLength; i++) {
            address cToken = marketList[i];
            (bool isListed, uint256 collateralFactorMantissa, ) = comptroller
                .markets(cToken);
            // Skip only if not listed; markets with CF=0 must still account for borrows
            if (!isListed) {
                continue;
            }

            PErc20 pToken = PErc20(cToken);
            uint256 cTokenBalance = pToken.balanceOf(account);
            uint256 borrowBalance = pToken.borrowBalanceStored(account);

            // Skip if no position in this market
            if (cTokenBalance == 0 && borrowBalance == 0) {
                continue;
            }

            uint256 price = oracle.getUnderlyingPrice(PToken(cToken));
            if (price == 0) {
                if (cTokenBalance > 0 || borrowBalance > 0) {
                    if (strictPriceCheck) {
                        revert PriceUnavailable(cToken);
                    }
                    // Graceful mode: flag missing price and skip this market
                    if (!metrics.hasMissingPrice) {
                        metrics.hasMissingPrice = true;
                        metrics.missingPriceMarket = cToken;
                    }
                }
                continue;
            }

            uint256 exchangeRate = pToken.exchangeRateStored();

            // Only count collateral contribution if collateralFactor > 0
            if (cTokenBalance > 0) {
                uint256 underlyingAmount = (cTokenBalance * exchangeRate) /
                    EXP_SCALE;
                uint256 usdValue = (underlyingAmount * price) / EXP_SCALE;
                metrics.grossCollateralValue += usdValue;
                // Only add to collateralValue if factor > 0 (deprecated markets have CF=0)
                if (collateralFactorMantissa > 0) {
                    metrics.collateralValue +=
                        (usdValue * collateralFactorMantissa) /
                        EXP_SCALE;
                }
            }

            // Always count borrows for listed markets, regardless of collateral factor
            if (borrowBalance > 0) {
                uint256 borrowValue = (borrowBalance * price) / EXP_SCALE;
                metrics.borrowValue += borrowValue;
            }
        }

        if (metrics.borrowValue == 0) {
            metrics.healthFactorBps = type(uint256).max;
            metrics.equity = int256(metrics.grossCollateralValue);
            metrics.excessCollateralValue = metrics.collateralValue;
            metrics.grossExposureValue = metrics.grossCollateralValue;
        } else {
            metrics.equity =
                int256(metrics.grossCollateralValue) -
                int256(metrics.borrowValue);
            metrics.healthFactorBps =
                (metrics.collateralValue * BPS_SCALE) /
                metrics.borrowValue;

            uint256 minRequiredCollateral = (metrics.borrowValue *
                hfMinWithdrawBps) / BPS_SCALE;
            if (metrics.collateralValue > minRequiredCollateral) {
                metrics.excessCollateralValue =
                    metrics.collateralValue -
                    minRequiredCollateral;
            }

            metrics.grossExposureValue =
                metrics.grossCollateralValue +
                metrics.borrowValue;
        }
    }

    function maxWithdrawableUnderlying(
        IPeridottrollerView comptroller,
        SimplePriceOracle oracle,
        address account,
        address cToken,
        uint16 hfMinWithdrawBps
    ) internal view returns (uint256) {
        PToken[] memory markets = comptroller.getAllMarkets();
        address[] memory marketList = new address[](markets.length);
        for (uint256 i = 0; i < markets.length; i++) {
            marketList[i] = address(markets[i]);
        }
        return
            maxWithdrawableUnderlyingFromMarkets(
                comptroller,
                oracle,
                account,
                cToken,
                hfMinWithdrawBps,
                marketList
            );
    }

    function maxWithdrawableUnderlyingFromMarkets(
        IPeridottrollerView comptroller,
        SimplePriceOracle oracle,
        address account,
        address cToken,
        uint16 hfMinWithdrawBps,
        address[] memory marketList
    ) internal view returns (uint256) {
        (bool isListed, uint256 collateralFactorMantissa, ) = comptroller
            .markets(cToken);
        require(isListed, "RiskLib: market not listed");
        require(collateralFactorMantissa > 0, "RiskLib: market disabled");

        AccountMetrics memory metrics = computeAccountMetricsForMarkets(
            comptroller,
            oracle,
            account,
            hfMinWithdrawBps,
            marketList
        );

        if (metrics.excessCollateralValue == 0) {
            return 0;
        }

        uint256 price = oracle.getUnderlyingPrice(PToken(cToken));
        require(price > 0, "RiskLib: price zero");

        // Calculate withdrawable amount with proper precision to avoid truncation
        // Formula: withdrawable = excessCollateralValue / (price * collateralFactor / EXP_SCALE)
        // Rearranged: withdrawable = (excessCollateralValue * EXP_SCALE) / (price * collateralFactor / EXP_SCALE)
        // To avoid truncation in denominator, we compute:
        // withdrawable = (excessCollateralValue * EXP_SCALE * EXP_SCALE) / (price * collateralFactor)
        uint256 priceTimesCF = price * collateralFactorMantissa;
        if (priceTimesCF == 0) {
            return 0;
        }

        uint256 withdrawable = (metrics.excessCollateralValue *
            EXP_SCALE *
            EXP_SCALE) / priceTimesCF;

        PErc20 pToken = PErc20(cToken);
        uint256 cTokenBalance = pToken.balanceOf(account);
        if (cTokenBalance == 0) {
            return 0;
        }
        uint256 exchangeRate = pToken.exchangeRateStored();
        uint256 underlyingBalance = (cTokenBalance * exchangeRate) / EXP_SCALE;

        return
            withdrawable < underlyingBalance ? withdrawable : underlyingBalance;
    }
}

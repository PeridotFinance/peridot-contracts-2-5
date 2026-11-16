// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUsd18PriceSource3 {
    function assetPrices(address asset) external view returns (uint256);
}

interface IMarketUnderlying3 {
    function underlying() external view returns (address);
}

interface ITokenDecimals3 {
    function decimals() external view returns (uint8);
}

/**
 * @title RobinhoodLendingPriceAdapter3
 * @notice Controller price oracle for the Robinhood lending markets with a second stock market.
 * @dev Same arithmetic as the live two-market `RobinhoodLendingPriceAdapter` (PeridotV2-Robinhood remediation,
 *      installed at 0xe4e03C2F…2A2E4): each 18-decimal stock market returns `source.assetPrices(stock)` (USD 1e18 is
 *      already Compound's 1e36 / 10**18 scale), the 6-decimal dollar market returns `source.assetPrices(dollar) * 1e12`.
 *      The existing two markets must read bit-identical through this adapter (fork-tested); the third market is added
 *      so that `getHypotheticalAccountLiquidityInternal` can price an account that entered it. A listed market the
 *      oracle cannot price would make every account that enters it revert in the liquidity loop, i.e. unliquidatable.
 *      No storage, no admin. The source's manual/cached-price policy is inherited unchanged.
 */
contract RobinhoodLendingPriceAdapter3 is IUsd18PriceSource3 {
    bool public constant isPriceOracle = true;
    IUsd18PriceSource3 public immutable source;
    address public immutable stockMarket;
    address public immutable dollarMarket;
    address public immutable secondStockMarket;
    address public immutable stock;
    address public immutable dollar;
    address public immutable secondStock;

    error InvalidConfiguration();
    error UnsupportedMarket();
    error UnsupportedAsset();

    constructor(address source_, address stockMarket_, address dollarMarket_, address secondStockMarket_) {
        if (
            source_.code.length == 0 || stockMarket_ == dollarMarket_ || secondStockMarket_ == dollarMarket_
                || secondStockMarket_ == stockMarket_
        ) revert InvalidConfiguration();
        address stock_ = IMarketUnderlying3(stockMarket_).underlying();
        address dollar_ = IMarketUnderlying3(dollarMarket_).underlying();
        address secondStock_ = IMarketUnderlying3(secondStockMarket_).underlying();
        if (
            stock_ == dollar_ || secondStock_ == dollar_ || secondStock_ == stock_
                || ITokenDecimals3(stock_).decimals() != 18 || ITokenDecimals3(secondStock_).decimals() != 18
                || ITokenDecimals3(dollar_).decimals() != 6
        ) revert InvalidConfiguration();
        source = IUsd18PriceSource3(source_);
        stockMarket = stockMarket_;
        dollarMarket = dollarMarket_;
        secondStockMarket = secondStockMarket_;
        stock = stock_;
        dollar = dollar_;
        secondStock = secondStock_;
    }

    function getUnderlyingPrice(address market) external view returns (uint256) {
        if (market == stockMarket) return source.assetPrices(stock);
        // Checked multiplication rejects malformed / overflowing source prices.
        if (market == dollarMarket) return source.assetPrices(dollar) * 1e12;
        if (market == secondStockMarket) return source.assetPrices(secondStock);
        revert UnsupportedMarket();
    }

    /// @notice Compatibility API: USD18 per whole asset, never Compound-scaled.
    function assetPrices(address asset) external view override returns (uint256) {
        if (asset != stock && asset != dollar && asset != secondStock) revert UnsupportedAsset();
        return source.assetPrices(asset);
    }
}

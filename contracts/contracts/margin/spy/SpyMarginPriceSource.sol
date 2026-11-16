// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAssetPriceSource} from "../RobinhoodMarginPriceOracle.sol";

interface ISpyFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

interface IPausableStockToken {
    function paused() external view returns (bool);
    function oraclePaused() external view returns (bool);
}

/**
 * @title SpyMarginPriceSource
 * @notice Margin price for one 24/5 stock feed (Robinhood Chain RHSPY / USD) with an explicit closed-session policy.
 * @dev Returns the feed price in USD 1e18, or 0. The margin oracle treats 0 as "unavailable", so every price-reading
 *      margin path (open, add collateral, close, TP/SL, liquidation) fails closed, while repay and the debt-free
 *      in-kind exit stay usable because they read no price.
 *
 *      A price is served only while ALL of these hold:
 *        - the stock token reports neither `paused()` nor `oraclePaused()` (an unreadable flag counts as paused);
 *        - the latest round is complete, positive, not in the future, and at most `maxStaleness` seconds old;
 *        - the block time is outside the weekly closed window [closedFrom, closedUntil) (seconds since Monday
 *          00:00 UTC; the window may wrap past the end of the week; closedFrom == closedUntil disables it);
 *        - when `lendingSource` is set, it reports exactly the same price (the lending oracle reads the same feed;
 *          disagreement means one of them was re-pointed, and margin then refuses to price).
 *
 *      The window exists because a 24/5 feed does not post while the market is closed: without it, the last Friday
 *      print would still look fresh for up to `maxStaleness` into the weekend while the on-chain pool trades.
 *      All parameters are immutable; changing one means a new source and a new router (one owner call to repoint
 *      the margin oracle). There is no admin.
 *
 *      The quote asset (`usd`) is valued at exactly 1e18 (both Robinhood guards peg USDG at one dollar), subject to
 *      the same lending parity when `lendingSource` is set. It is not gated on the stock's session.
 */
contract SpyMarginPriceSource is IAssetPriceSource {
    uint256 public constant WEEK = 7 days;
    /// @dev 1970-01-01 was a Thursday, so Monday 00:00 UTC is three days before every Thursday 00:00 UTC.
    uint256 internal constant EPOCH_TO_MONDAY = 3 days;

    uint8 public constant OK = 0;
    uint8 public constant STOCK_PAUSED = 1;
    uint8 public constant ORACLE_PAUSED = 2;
    uint8 public constant FEED_UNREADABLE = 3;
    uint8 public constant BAD_ANSWER = 4;
    uint8 public constant INCOMPLETE_ROUND = 5;
    uint8 public constant STALE = 6;
    uint8 public constant CLOSED_WINDOW = 7;
    uint8 public constant LENDING_MISMATCH = 8;

    ISpyFeed public immutable feed;
    address public immutable stock;
    address public immutable usd;
    IAssetPriceSource public immutable lendingSource;
    uint256 public immutable maxStaleness;
    uint256 public immutable closedFrom;
    uint256 public immutable closedUntil;
    uint8 public immutable feedDecimals;

    error InvalidConfiguration();

    constructor(
        address feed_,
        address stock_,
        address usd_,
        address lendingSource_,
        uint256 maxStaleness_,
        uint256 closedFrom_,
        uint256 closedUntil_
    ) {
        if (feed_.code.length == 0 || stock_.code.length == 0 || usd_.code.length == 0 || stock_ == usd_) {
            revert InvalidConfiguration();
        }
        if (lendingSource_ != address(0) && lendingSource_.code.length == 0) revert InvalidConfiguration();
        if (maxStaleness_ == 0 || maxStaleness_ > WEEK) revert InvalidConfiguration();
        if (closedFrom_ >= WEEK || closedUntil_ >= WEEK) revert InvalidConfiguration();
        uint8 decimals_ = ISpyFeed(feed_).decimals();
        if (decimals_ > 18) revert InvalidConfiguration();
        feed = ISpyFeed(feed_);
        stock = stock_;
        usd = usd_;
        lendingSource = IAssetPriceSource(lendingSource_);
        maxStaleness = maxStaleness_;
        closedFrom = closedFrom_;
        closedUntil = closedUntil_;
        feedDecimals = decimals_;
    }

    /// @notice Seconds since the most recent Monday 00:00 UTC.
    function weekSecond(uint256 timestamp) public pure returns (uint256) {
        return (timestamp + EPOCH_TO_MONDAY) % WEEK;
    }

    /// @notice Whether `timestamp` falls in the weekly closed window.
    function inClosedWindow(uint256 timestamp) public view returns (bool) {
        if (closedFrom == closedUntil) return false;
        uint256 s = weekSecond(timestamp);
        if (closedFrom < closedUntil) return s >= closedFrom && s < closedUntil;
        return s >= closedFrom || s < closedUntil;
    }

    /// @notice The stock price this source would serve now, with the reason it is withheld (0 = served). Monitoring.
    function stockPrice() public view returns (uint256 priceE18, uint8 reason, uint256 updatedAt) {
        try IPausableStockToken(stock).paused() returns (bool p) {
            if (p) return (0, STOCK_PAUSED, 0);
        } catch {
            return (0, STOCK_PAUSED, 0);
        }
        try IPausableStockToken(stock).oraclePaused() returns (bool p) {
            if (p) return (0, ORACLE_PAUSED, 0);
        } catch {
            return (0, ORACLE_PAUSED, 0);
        }

        uint80 round;
        int256 answer;
        uint80 answeredIn;
        try feed.latestRoundData() returns (uint80 r, int256 a, uint256, uint256 u, uint80 ai) {
            (round, answer, updatedAt, answeredIn) = (r, a, u, ai);
        } catch {
            return (0, FEED_UNREADABLE, 0);
        }
        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) return (0, BAD_ANSWER, updatedAt);
        if (answeredIn < round) return (0, INCOMPLETE_ROUND, updatedAt);
        if (block.timestamp - updatedAt > maxStaleness) return (0, STALE, updatedAt);
        if (inClosedWindow(block.timestamp)) return (0, CLOSED_WINDOW, updatedAt);

        priceE18 = uint256(answer) * 10 ** (18 - feedDecimals);
        if (!_lendingAgrees(stock, priceE18)) return (0, LENDING_MISMATCH, updatedAt);
        return (priceE18, OK, updatedAt);
    }

    /// @inheritdoc IAssetPriceSource
    function assetPrices(address asset) external view returns (uint256) {
        if (asset == usd) return _lendingAgrees(usd, 1e18) ? 1e18 : 0;
        if (asset != stock) return 0;
        (uint256 priceE18,,) = stockPrice();
        return priceE18;
    }

    function _lendingAgrees(address asset, uint256 priceE18) internal view returns (bool) {
        if (address(lendingSource) == address(0)) return true;
        try lendingSource.assetPrices(asset) returns (uint256 lendingPrice) {
            return lendingPrice == priceE18;
        } catch {
            return false;
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SpyMarginPriceSource} from "../../contracts/margin/spy/SpyMarginPriceSource.sol";
import {MockSpyFeed, MockStockToken, RevertingFlagsToken, MockPriceSource} from "./SpyMocks.sol";

contract SpyMarginPriceSourceTest is Test {
    uint256 constant MON = 1794787200; // Monday 2026-11-16 00:00:00 UTC
    uint256 constant SAT = MON + 5 days; // Saturday 2026-11-21 00:00:00 UTC
    uint256 constant M = 90000;
    uint256 constant FROM = 5 days; // Saturday 00:00 UTC
    uint256 constant UNTIL = 1 hours; // Monday 01:00 UTC (wraps)
    uint256 constant P = 748538777500000000000; // 748.5387775e18

    MockSpyFeed feed;
    MockStockToken spy;
    MockStockToken usdg;
    MockPriceSource lending;
    SpyMarginPriceSource src;

    function setUp() public {
        feed = new MockSpyFeed();
        spy = new MockStockToken();
        usdg = new MockStockToken();
        lending = new MockPriceSource();
        src = new SpyMarginPriceSource(address(feed), address(spy), address(usdg), address(lending), M, FROM, UNTIL);
        vm.warp(MON + 2 days + 15 hours); // Wednesday 15:00 UTC
        feed.set(74853877750, block.timestamp - 60);
        lending.set(address(spy), P);
        lending.set(address(usdg), 1e18);
    }

    function _reason() internal view returns (uint8 r) {
        (, r,) = src.stockPrice();
    }

    // ---------------------------------------------------------------- happy path and scaling
    function testServesScaledFeedPriceAndPeggedUsd() public view {
        assertEq(src.assetPrices(address(spy)), P);
        assertEq(src.assetPrices(address(usdg)), 1e18);
        assertEq(_reason(), src.OK());
    }

    function testOtherAssetsAreZero() public view {
        assertEq(src.assetPrices(address(0xBEEF)), 0);
        assertEq(src.assetPrices(address(0)), 0);
    }

    function testEighteenDecimalFeedIsNotRescaled() public {
        MockSpyFeed f = new MockSpyFeed();
        f.setDecimals(18);
        f.set(int256(P), block.timestamp);
        SpyMarginPriceSource s =
            new SpyMarginPriceSource(address(f), address(spy), address(usdg), address(0), M, FROM, UNTIL);
        assertEq(s.assetPrices(address(spy)), P);
    }

    // ---------------------------------------------------------------- staleness
    function testStalenessBoundIsInclusive() public {
        feed.set(74853877750, block.timestamp - M);
        assertEq(src.assetPrices(address(spy)), P);
        feed.set(74853877750, block.timestamp - M - 1);
        assertEq(src.assetPrices(address(spy)), 0);
        assertEq(_reason(), src.STALE());
    }

    function testWeekdayTwentyFourHourHeartbeatGapStaysPriced() public {
        feed.set(74853877750, block.timestamp - 24 hours);
        assertEq(src.assetPrices(address(spy)), P);
    }

    function testFutureZeroNegativeAndIncompleteRoundsAreRefused() public {
        feed.set(74853877750, block.timestamp + 1);
        assertEq(src.assetPrices(address(spy)), 0);
        assertEq(_reason(), src.BAD_ANSWER());
        feed.set(74853877750, 0);
        assertEq(_reason(), src.BAD_ANSWER());
        feed.set(0, block.timestamp);
        assertEq(_reason(), src.BAD_ANSWER());
        feed.set(-1, block.timestamp);
        assertEq(_reason(), src.BAD_ANSWER());
        feed.set(74853877750, block.timestamp);
        feed.setRounds(11, 10);
        assertEq(src.assetPrices(address(spy)), 0);
        assertEq(_reason(), src.INCOMPLETE_ROUND());
    }

    function testRevertingFeedReadsAsUnavailable() public {
        feed.setBroken(true);
        assertEq(src.assetPrices(address(spy)), 0);
        assertEq(_reason(), src.FEED_UNREADABLE());
    }

    // ---------------------------------------------------------------- pause flags
    function testStockPausedAndOraclePausedAreRefused() public {
        spy.setFlags(true, false);
        assertEq(src.assetPrices(address(spy)), 0);
        assertEq(_reason(), src.STOCK_PAUSED());
        spy.setFlags(false, true);
        assertEq(src.assetPrices(address(spy)), 0);
        assertEq(_reason(), src.ORACLE_PAUSED());
        spy.setFlags(false, false);
        assertEq(src.assetPrices(address(spy)), P);
    }

    function testUnreadableFlagsCountAsPaused() public {
        RevertingFlagsToken t = new RevertingFlagsToken();
        SpyMarginPriceSource s = new SpyMarginPriceSource(address(feed), address(t), address(usdg), address(0), M, FROM, UNTIL);
        assertEq(s.assetPrices(address(t)), 0);
        (, uint8 r,) = s.stockPrice();
        assertEq(r, s.STOCK_PAUSED());
    }

    function testPausedStockDoesNotZeroTheQuoteAsset() public {
        spy.setFlags(true, true);
        assertEq(src.assetPrices(address(usdg)), 1e18);
    }

    // ---------------------------------------------------------------- weekend window
    function testWindowBoundariesSaturdayToMondayOneUtc() public {
        _at(SAT - 1, P);
        _at(SAT, 0);
        _at(SAT + 1 days, 0); // Sunday 00:00
        _at(SAT + 2 days - 1, 0); // Sunday 23:59:59
        _at(SAT + 2 days, 0); // Monday 00:00
        _at(SAT + 2 days + 1 hours - 1, 0); // Monday 00:59:59
        _at(SAT + 2 days + 1 hours, P); // Monday 01:00 open again
    }

    function _at(uint256 t, uint256 expected) internal {
        vm.warp(t);
        feed.set(74853877750, t); // a brand-new print still does not open the window
        assertEq(src.assetPrices(address(spy)), expected);
        if (expected == 0) assertEq(_reason(), src.CLOSED_WINDOW());
    }

    function testFridayPrintIsRefusedFromSaturdayEvenThoughFresh() public {
        vm.warp(SAT - 4 hours); // Friday 20:00 UTC
        feed.set(74853877750, block.timestamp);
        assertEq(src.assetPrices(address(spy)), P);
        vm.warp(SAT + 1 minutes);
        assertEq(src.assetPrices(address(spy)), 0);
        assertEq(_reason(), src.CLOSED_WINDOW());
    }

    function testMondayFirstPrintRequiredAfterWindow() public {
        vm.warp(SAT - 1 hours);
        feed.set(74853877750, block.timestamp); // Friday 23:00 UTC last print
        vm.warp(SAT + 2 days + 1 hours); // Monday 01:00 UTC: window over, print is 50 h old
        assertEq(src.assetPrices(address(spy)), 0);
        assertEq(_reason(), src.STALE());
        feed.set(75000000000, block.timestamp); // Sunday 20:00 ET reopening print
        lending.set(address(spy), 750e18); // the lending oracle reads the same feed
        assertEq(src.assetPrices(address(spy)), 750e18);
    }

    function testDisabledWindowAndNonWrappingWindow() public {
        SpyMarginPriceSource none =
            new SpyMarginPriceSource(address(feed), address(spy), address(usdg), address(0), M, 0, 0);
        vm.warp(SAT + 12 hours);
        feed.set(74853877750, block.timestamp);
        assertEq(none.assetPrices(address(spy)), P);
        assertFalse(none.inClosedWindow(block.timestamp));
        SpyMarginPriceSource mid =
            new SpyMarginPriceSource(address(feed), address(spy), address(usdg), address(0), M, 2 days, 2 days + 1 hours);
        assertTrue(mid.inClosedWindow(MON + 2 days));
        assertFalse(mid.inClosedWindow(MON + 2 days + 1 hours));
        assertFalse(mid.inClosedWindow(MON + 2 days - 1));
    }

    function testWeekSecondAnchorsOnMondayUtc() public view {
        assertEq(src.weekSecond(MON), 0);
        assertEq(src.weekSecond(SAT), 5 days);
        assertEq(src.weekSecond(MON - 1), 7 days - 1);
        assertEq(src.weekSecond(345600), 0); // 1970-01-05, a Monday
    }

    /// Reference: an independent day-of-week computation, for the deployed default window.
    function testFuzzWindowMatchesCalendar(uint256 t) public view {
        t = bound(t, 1, 4_000_000_000);
        uint256 weekday = ((t / 1 days) + 3) % 7; // 0 = Monday
        uint256 hour = (t % 1 days) / 1 hours;
        bool expected = weekday == 5 || weekday == 6 || (weekday == 0 && hour < 1);
        assertEq(src.inClosedWindow(t), expected);
    }

    // ---------------------------------------------------------------- lending parity
    function testLendingDisagreementRevertOrZeroRefuses() public {
        lending.set(address(spy), P + 1);
        assertEq(src.assetPrices(address(spy)), 0);
        assertEq(_reason(), src.LENDING_MISMATCH());
        lending.set(address(spy), 0);
        assertEq(src.assetPrices(address(spy)), 0);
        lending.set(address(spy), P);
        lending.setReverts(address(spy), true);
        assertEq(src.assetPrices(address(spy)), 0);
        lending.setReverts(address(spy), false);
        assertEq(src.assetPrices(address(spy)), P);
    }

    function testQuoteAssetParity() public {
        lending.set(address(usdg), 1e18 + 1);
        assertEq(src.assetPrices(address(usdg)), 0);
        lending.setReverts(address(usdg), true);
        assertEq(src.assetPrices(address(usdg)), 0);
    }

    function testNoLendingSourceMeansNoParity() public {
        SpyMarginPriceSource s =
            new SpyMarginPriceSource(address(feed), address(spy), address(usdg), address(0), M, FROM, UNTIL);
        lending.set(address(spy), 1);
        assertEq(s.assetPrices(address(spy)), P);
        assertEq(s.assetPrices(address(usdg)), 1e18);
    }

    // ---------------------------------------------------------------- construction
    function testConstructorRejectsBadConfiguration() public {
        address f = address(feed);
        address s = address(spy);
        address u = address(usdg);
        address l = address(lending);
        vm.expectRevert(SpyMarginPriceSource.InvalidConfiguration.selector);
        new SpyMarginPriceSource(address(0x1234), s, u, l, M, FROM, UNTIL);
        vm.expectRevert(SpyMarginPriceSource.InvalidConfiguration.selector);
        new SpyMarginPriceSource(f, address(0x1234), u, l, M, FROM, UNTIL);
        vm.expectRevert(SpyMarginPriceSource.InvalidConfiguration.selector);
        new SpyMarginPriceSource(f, s, address(0x1234), l, M, FROM, UNTIL);
        vm.expectRevert(SpyMarginPriceSource.InvalidConfiguration.selector);
        new SpyMarginPriceSource(f, s, s, l, M, FROM, UNTIL);
        vm.expectRevert(SpyMarginPriceSource.InvalidConfiguration.selector);
        new SpyMarginPriceSource(f, s, u, address(0x1234), M, FROM, UNTIL);
        vm.expectRevert(SpyMarginPriceSource.InvalidConfiguration.selector);
        new SpyMarginPriceSource(f, s, u, l, 0, FROM, UNTIL);
        vm.expectRevert(SpyMarginPriceSource.InvalidConfiguration.selector);
        new SpyMarginPriceSource(f, s, u, l, 7 days + 1, FROM, UNTIL);
        vm.expectRevert(SpyMarginPriceSource.InvalidConfiguration.selector);
        new SpyMarginPriceSource(f, s, u, l, M, 7 days, UNTIL);
        vm.expectRevert(SpyMarginPriceSource.InvalidConfiguration.selector);
        new SpyMarginPriceSource(f, s, u, l, M, FROM, 7 days);
        feed.setDecimals(19);
        vm.expectRevert(SpyMarginPriceSource.InvalidConfiguration.selector);
        new SpyMarginPriceSource(f, s, u, l, M, FROM, UNTIL);
        feed.setDecimals(8);
        SpyMarginPriceSource ok = new SpyMarginPriceSource(f, s, u, l, 7 days, FROM, UNTIL);
        assertEq(ok.maxStaleness(), 7 days);
        assertEq(ok.feedDecimals(), 8);
    }
}

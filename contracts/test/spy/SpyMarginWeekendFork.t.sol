// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SpyMarginForkBase.sol";

interface ISpySourceReason {
    function stockPrice() external view returns (uint256, uint8, uint256);
    function weekSecond(uint256) external view returns (uint256);
}

/// @notice Closed-session behaviour of a live SPY long (opened on the weekday pin): what each path does in the
/// weekend window and when the feed is stale or paused, the Monday reopen, and the 1% pool-vs-oracle guard.
/// Expected policy: close-only by repay + in-kind exit; opens, swap-closes, TP/SL and liquidation refused.
contract SpyMarginWeekendForkTest is SpyMarginForkBase {
    address keeper = makeAddr("keeper");
    uint256 id;
    uint256 slOrder;
    uint256 saturday; // next Saturday 00:00 UTC after the pin

    function setUp() public {
        _fork();
        uint256 ws = (block.timestamp + 3 days) % 7 days;
        require(ws >= 1 hours && ws < 4 days, "pin a Monday 01:00 .. Thursday 23:59 UTC block");
        _deploy();
        _fullCeremony();
        id = _openLong(40e6, 200);
        uint256 price = IMarginOracle(P.MARGIN_ORACLE).getPrice(P.SPY);
        vm.prank(user);
        slOrder = IRegistry(P.REGISTRY).createOrder(
            id, IRegistry.OrderKind.STOP_LOSS, false, price * 98 / 100, 10_000, 100, uint64(block.timestamp + 20 days)
        );
        saturday = block.timestamp - ((block.timestamp + 3 days) % 7 days) + 5 days;
    }

    function _reason() internal view returns (uint8 r) {
        (, r,) = ISpySourceReason(d.spySource).stockPrice();
    }

    /// @dev Every price-reading path refuses; repay, in-kind exit and cancel still work.
    function _assertCloseOnly(uint8 expectedReason) internal {
        assertEq(IMarginOracle(P.MARGIN_ORACLE).getPrice(P.SPY), 0, "SPY unpriced");
        assertEq(_reason(), expectedReason, "reason");
        address account = _pos(id).account;

        // open
        vm.expectRevert();
        this.openFor(20e6);
        // add collateral (getMetrics in the emitted health)
        _fund(user, 5e6);
        vm.startPrank(user);
        IERC20(P.USDG).approve(P.PUSDG, 5e6);
        IMarket(P.PUSDG).mint(5e6);
        uint256 extra = IMarket(P.PUSDG).balanceOf(user);
        IMarket(P.PUSDG).approve(P.MARGIN_VAULT, extra);
        IVault(P.MARGIN_VAULT).deposit(P.PUSDG, extra);
        vm.expectRevert();
        IExecutor(P.EXECUTOR).addCollateral(id, extra);
        // swap close
        vm.expectRevert();
        IExecutor(P.EXECUTOR).closePosition(IExecutor.CloseParams(id, 10_000, type(uint256).max, 1, 0, "", ""));
        vm.stopPrank();
        // stop-loss: the order waits, nothing is cancelled
        (bool can,, uint8 r) = IRegistry(P.REGISTRY).canExecute(slOrder);
        assertFalse(can);
        assertEq(r, 5, "R_ORACLE");
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSignature("OracleUnavailable()"));
        IRegistry(P.REGISTRY).executeOrder(slOrder, "");
        // liquidation, even at a crash price
        vm.prank(keeper);
        vm.expectRevert();
        ILiquidator(P.LIQUIDATOR).liquidate(ILiquidator.LiquidationParams(id, keeper, 0, 0, "", ""));
        vm.expectRevert();
        IRisk(P.RISK_ENGINE).isLiquidatable(account);

        // close-only path: partial repay with USDG, then repay the rest, then exit in kind
        uint256 debt = IMarket(P.PUSDG).borrowBalanceCurrent(account);
        _fund(user, debt + 1e6);
        vm.startPrank(user);
        IERC20(P.USDG).approve(P.EXECUTOR, debt + 1e6);
        IExecutor(P.EXECUTOR).repayWithUnderlying(id, debt / 2);
        IExecutor(P.EXECUTOR).repayWithUnderlying(id, debt + 1e6);
        assertEq(IMarket(P.PUSDG).borrowBalanceStored(account), 0, "debt repaid while closed");
        IRegistry(P.REGISTRY).cancelOrder(slOrder);
        (, uint256 pSpyOut,) = IExecutor(P.EXECUTOR).exitDebtFreeToPTokens(id, 0);
        vm.stopPrank();
        assertGt(pSpyOut, 0, "in-kind exit while closed");
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
    }

    function openFor(uint256 marginUsdg) external returns (uint256) {
        return _openLong(marginUsdg, 200);
    }

    function testSaturdayWithABrandNewPrintIsCloseOnly() public {
        vm.warp(saturday + 6 hours);
        _setSpy(spyAnswer * 60 / 100); // even a fresh crash print is not served in the window
        _assertCloseOnly(7); // CLOSED_WINDOW
    }

    function testFridayLastPrintStillFreshByAgeIsRefusedFromSaturday() public {
        vm.warp(saturday - 3 hours); // Friday 21:00 UTC
        _freshSpyFeed();
        assertGt(IMarginOracle(P.MARGIN_ORACLE).getPrice(P.SPY), 0, "Friday evening still open");
        vm.warp(saturday + 1);
        _assertCloseOnly(7);
    }

    function testWindowEndsMondayOneUtcButFridayPrintIsThenStale() public {
        vm.warp(saturday - 3 hours);
        _freshSpyFeed();
        vm.warp(saturday + 2 days + 1 hours); // Monday 01:00 UTC
        assertEq(_reason(), 6, "STALE: the reopening print is required");
        _assertCloseOnly(6);
    }

    function testMondayReopenGapDownFiresTheStopLossAtTheGapPrice() public {
        vm.warp(saturday + 12 hours);
        _setSpy(spyAnswer);
        (bool can,,) = IRegistry(P.REGISTRY).canExecute(slOrder);
        assertFalse(can);
        vm.warp(saturday + 2 days + 1 hours); // Sunday 20:00 ET reopening print, 5% lower
        _setSpy(spyAnswer * 95 / 100);
        (can,,) = IRegistry(P.REGISTRY).canExecute(slOrder);
        assertTrue(can, "first price after the weekend triggers the stop");
        vm.prank(keeper);
        assertTrue(IRegistry(P.REGISTRY).executeOrder(slOrder, ""));
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
    }

    function testMondayReopenCrashIsLiquidatableAtTheFirstPrice() public {
        vm.prank(user);
        IRegistry(P.REGISTRY).cancelOrder(slOrder);
        vm.warp(saturday + 2 days + 1 hours);
        _setSpy(spyAnswer * 60 / 100); // -40% gap
        assertTrue(IRisk(P.RISK_ENGINE).isLiquidatable(_pos(id).account));
        uint256 debtBefore = IMarket(P.PUSDG).borrowBalanceCurrent(_pos(id).account);
        vm.prank(keeper);
        ILiquidator(P.LIQUIDATOR).liquidate(ILiquidator.LiquidationParams(id, keeper, 0, 0, "", ""));
        assertLt(IMarket(P.PUSDG).borrowBalanceStored(_pos(id).account), debtBefore);
    }

    function testWeekdayTwentyFourHourQuietGapStaysLive() public {
        // A weekday quiet period up to the 24 h heartbeat: price still served (the 12 h policy would refuse it).
        uint256 lastPrint = block.timestamp;
        _setSpyAt(spyAnswer, lastPrint);
        vm.warp(lastPrint + 24 hours);
        if ((block.timestamp + 3 days) % 7 days >= 5 days) return; // pin too late in the week to cross 24 h
        assertGt(IMarginOracle(P.MARGIN_ORACLE).getPrice(P.SPY), 0);
        uint256 returned = _close(id, 10_000);
        assertGt(returned, 0);
    }

    function testWeekdayStaleBeyondTwentyFiveHoursIsCloseOnly() public {
        uint256 lastPrint = block.timestamp;
        _setSpyAt(spyAnswer, lastPrint);
        vm.warp(lastPrint + 90001);
        if ((block.timestamp + 3 days) % 7 days >= 5 days) return;
        _assertCloseOnly(6);
    }

    function testSpyOraclePausedIsCloseOnly() public {
        vm.mockCall(P.SPY, abi.encodeWithSignature("oraclePaused()"), abi.encode(true));
        _assertCloseOnly(2);
    }

    function testPoolMoreThanOnePercentFromOracleBlocksTheSwapClose() public {
        _moveSpy(10_300); // oracle 3% above the pool: selling SPY returns less than the oracle value minus 1%
        assertGt(IMarginOracle(P.MARGIN_ORACLE).getPrice(P.SPY), 0);
        uint256 minDebt = _minDebt(id, 10_000);
        vm.prank(user);
        vm.expectRevert();
        IExecutor(P.EXECUTOR).closePosition(IExecutor.CloseParams(id, 10_000, type(uint256).max, minDebt, 0, "", ""));
        // repay + in-kind exit still works
        address account = _pos(id).account;
        uint256 debt = IMarket(P.PUSDG).borrowBalanceCurrent(account);
        _fund(user, debt + 1e6);
        vm.startPrank(user);
        IERC20(P.USDG).approve(P.EXECUTOR, debt + 1e6);
        IExecutor(P.EXECUTOR).repayWithUnderlying(id, debt + 1e6);
        IRegistry(P.REGISTRY).cancelOrder(slOrder);
        IExecutor(P.EXECUTOR).exitDebtFreeToPTokens(id, 0);
        vm.stopPrank();
    }
}

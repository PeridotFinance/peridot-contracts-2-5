// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SpyMarginForkBase.sol";

interface IRangeCustodian {
    function createRangeOrder(uint256, uint8, uint256) external returns (int24, int24, uint128);
}

interface IPSpyErrors {
    error ZeroSharesMinted();
}

/// @notice SPY 2x long on the live stack after the ceremony: open, close, partial close, caps, short refusal, TP/SL
/// through the live order registry V2 and close adapter, range TP refusal, liquidation, repay + in-kind exit, and the
/// plain delegate's rounding guards.
contract SpyMarginLongForkTest is SpyMarginForkBase {
    address constant RANGE_CUSTODIAN = 0xA22cF43f9715CfBBF4808A7A249394141Ca9f538;
    address keeper = makeAddr("keeper");

    function setUp() public {
        _fork();
        _deploy();
        _fullCeremony();
    }

    function testOpenTwoXLongThenFullCloseReturnsMargin() public {
        uint256 id = _openLong(50e6, 200);
        IsolatedMarginTypes.Position memory p = _pos(id);
        assertEq(uint8(p.status), uint8(IsolatedMarginTypes.Status.ACTIVE));
        assertEq(p.positionPToken, d.pSpy);
        IsolatedMarginTypes.AccountMetrics memory m = _metrics(id);
        emit log_named_decimal_uint("gross USD", m.grossAssetValueUsd, 18);
        emit log_named_decimal_uint("debt USD", m.debtValueUsd, 18);
        emit log_named_decimal_uint("leverage x", m.leverageX100, 2);
        emit log_named_uint("health bps", m.healthFactorBps);
        assertLe(m.leverageX100, 200);
        assertGt(m.leverageX100, 190);
        assertApproxEqRel(m.grossAssetValueUsd, 100e18, 0.02e18);
        uint256 returned = _close(id, 10_000);
        p = _pos(id);
        assertEq(uint8(p.status), uint8(IsolatedMarginTypes.Status.CLOSED));
        assertEq(IMarket(P.PUSDG).borrowBalanceStored(p.account), 0);
        assertEq(IMarket(d.pSpy).balanceOf(p.account), 0);
        uint256 back = Math.mulDiv(returned, IMarket(P.PUSDG).exchangeRateStored(), 1e18);
        emit log_named_decimal_uint("returned USDG-equivalent", back, 6);
        assertApproxEqRel(back, 50e6, 0.015e18); // round-trip cost ~0.7% + pool/oracle offset
        vm.prank(user);
        IVault(P.MARGIN_VAULT).withdraw(P.PUSDG, returned);
        assertEq(IMarket(P.PUSDG).balanceOf(user), returned);
    }

    function testPartialCloseThenFullClose() public {
        uint256 id = _openLong(40e6, 200);
        uint256 debt0 = IMarket(P.PUSDG).borrowBalanceStored(_pos(id).account);
        _close(id, 5000);
        uint256 debt1 = IMarket(P.PUSDG).borrowBalanceStored(_pos(id).account);
        assertApproxEqRel(debt1, debt0 / 2, 0.01e18);
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.ACTIVE));
        _close(id, 10_000);
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
    }

    function testLeverageAboveTwoIsRefused() public {
        _fund(user, 20e6);
        vm.startPrank(user);
        IERC20(P.USDG).approve(P.PUSDG, 20e6);
        IMarket(P.PUSDG).mint(20e6);
        uint256 shares = IMarket(P.PUSDG).balanceOf(user);
        IMarket(P.PUSDG).approve(P.MARGIN_VAULT, shares);
        IVault(P.MARGIN_VAULT).deposit(P.PUSDG, shares);
        vm.expectRevert(abi.encodeWithSignature("ExecutorError(uint8)", uint8(13)));
        IExecutor(P.EXECUTOR).openPosition(
            IExecutor.OpenParams(P.PUSDG, d.pSpy, P.PUSDG, shares, 201, 0, 1, IsolatedMarginTypes.Side.LONG, "")
        );
        vm.stopPrank();
    }

    function testShortIsNotConfigured() public {
        _fund(user, 20e6);
        vm.startPrank(user);
        IERC20(P.USDG).approve(P.PUSDG, 20e6);
        IMarket(P.PUSDG).mint(20e6);
        uint256 shares = IMarket(P.PUSDG).balanceOf(user);
        IMarket(P.PUSDG).approve(P.MARGIN_VAULT, shares);
        IVault(P.MARGIN_VAULT).deposit(P.PUSDG, shares);
        vm.expectRevert(abi.encodeWithSignature("ExecutorError(uint8)", uint8(12)));
        IExecutor(P.EXECUTOR).openPosition(
            IExecutor.OpenParams(P.PUSDG, P.PUSDG, d.pSpy, shares, 200, 0, 1, IsolatedMarginTypes.Side.SHORT, "")
        );
        vm.stopPrank();
        assertFalse(IConfig(P.CONFIG).getPairRisk(P.PUSDG, P.PUSDG, d.pSpy).enabled);
    }

    function testStopLossThroughTheLiveRegistryClosesAtTheFirstPriceBelowTrigger() public {
        uint256 id = _openLong(40e6, 200);
        uint256 price = IMarginOracle(P.MARGIN_ORACLE).getPrice(P.SPY);
        vm.prank(user);
        uint256 orderId = IRegistry(P.REGISTRY).createOrder(
            id, IRegistry.OrderKind.STOP_LOSS, false, price * 98 / 100, 10_000, 100, uint64(block.timestamp + 7 days)
        );
        (bool can,, uint8 reason) = IRegistry(P.REGISTRY).canExecute(orderId);
        assertFalse(can);
        assertEq(reason, 6, "trigger not reached");
        _moveSpy(9_700); // -3%: the pool is above the oracle now, so the sale clears the 1% check
        (can,,) = IRegistry(P.REGISTRY).canExecute(orderId);
        assertTrue(can);
        vm.prank(keeper);
        assertTrue(IRegistry(P.REGISTRY).executeOrder(orderId, ""));
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
        assertGt(IVault(P.MARGIN_VAULT).freeBalance(user, P.PUSDG), 0, "margin returned to the owner");
    }

    function testTakeProfitThroughTheLiveRegistry() public {
        uint256 id = _openLong(40e6, 200);
        uint256 price = IMarginOracle(P.MARGIN_ORACLE).getPrice(P.SPY);
        vm.prank(user);
        uint256 orderId = IRegistry(P.REGISTRY).createOrder(
            id, IRegistry.OrderKind.TAKE_PROFIT, true, price * 10_020 / 10_000, 10_000, 100, uint64(block.timestamp + 7 days)
        );
        // +0.25%: within the 1% pool-vs-oracle check (the pool sits ~0.2% under the oracle at the pin)
        _moveSpy(10_025);
        (bool can,,) = IRegistry(P.REGISTRY).canExecute(orderId);
        assertTrue(can);
        vm.prank(keeper);
        assertTrue(IRegistry(P.REGISTRY).executeOrder(orderId, ""));
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
    }

    function testRangeTakeProfitRefusesSpyPositions() public {
        uint256 id = _openLong(40e6, 200);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("PositionNotEligible(uint8)", uint8(3)));
        IRangeCustodian(RANGE_CUSTODIAN).createRangeOrder(id, 1, 0);
    }

    function testLiquidationAfterAForteyPercentShock() public {
        uint256 id = _openLong(40e6, 200);
        assertFalse(IRisk(P.RISK_ENGINE).isLiquidatable(_pos(id).account));
        _moveSpy(6_000); // -40%: beyond the -33% maintenance line at 2x / MM 25%
        assertTrue(IRisk(P.RISK_ENGINE).isLiquidatable(_pos(id).account));
        uint256 debtBefore = IMarket(P.PUSDG).borrowBalanceCurrent(_pos(id).account);
        vm.prank(keeper);
        ILiquidator(P.LIQUIDATOR).liquidate(ILiquidator.LiquidationParams(id, keeper, 0, 0, "", ""));
        uint256 debtAfter = IMarket(P.PUSDG).borrowBalanceStored(_pos(id).account);
        emit log_named_decimal_uint("debt before", debtBefore, 6);
        emit log_named_decimal_uint("debt after", debtAfter, 6);
        assertLt(debtAfter, debtBefore);
    }

    function testRepayThenInKindExitReturnsPSpyThatRedeemsForSpy() public {
        uint256 id = _openLong(40e6, 200);
        address account = _pos(id).account;
        uint256 debt = IMarket(P.PUSDG).borrowBalanceCurrent(account);
        _fund(user, debt + 1e6);
        vm.startPrank(user);
        IERC20(P.USDG).approve(P.EXECUTOR, debt + 1e6);
        IExecutor(P.EXECUTOR).repayWithUnderlying(id, debt + 1e6);
        assertEq(IMarket(P.PUSDG).borrowBalanceStored(account), 0);
        (, uint256 pSpyOut,) = IExecutor(P.EXECUTOR).exitDebtFreeToPTokens(id, 0);
        assertGt(pSpyOut, 0);
        assertEq(IMarket(d.pSpy).balanceOf(user), pSpyOut);
        uint256 spyBefore = IERC20(P.SPY).balanceOf(user);
        IMarket(d.pSpy).redeem(pSpyOut);
        vm.stopPrank();
        assertGt(IERC20(P.SPY).balanceOf(user) - spyBefore, 0);
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
    }

    function testPlainDelegateRefusesZeroShareMintAndRoundsExactRedeemUp() public {
        address alice = makeAddr("alice");
        vm.prank(WHALE);
        IERC20(P.SPY).transfer(alice, 1e18);
        vm.startPrank(alice);
        IERC20(P.SPY).approve(d.pSpy, type(uint256).max);
        // 1 wei of SPY is worth less than one pSPY unit at 2e26: zero shares, refused
        vm.expectRevert(IPSpyErrors.ZeroSharesMinted.selector);
        IMarket(d.pSpy).mint(1);
        IMarket(d.pSpy).mint(1e17);
        uint256 shares = IMarket(d.pSpy).balanceOf(alice);
        uint256 rate = IMarket(d.pSpy).exchangeRateCurrent();
        uint256 want = 1e16 + 1; // not a multiple of the rate
        IMarket(d.pSpy).redeemUnderlying(want);
        uint256 burned = shares - IMarket(d.pSpy).balanceOf(alice);
        assertEq(burned, (want * 1e18 + rate - 1) / rate, "ceil");
        assertGe(Math.mulDiv(burned, rate, 1e18), want, "never under-burns");
        vm.stopPrank();
    }

    function testTenSpyDonationCannotZeroADemoSizedMint() public {
        // The seed (the Ledger's ~0.000148 SPY) sets the share supply an inflation attack must overcome.
        vm.prank(WHALE);
        IERC20(P.SPY).transfer(d.pSpy, 10e18); // ~$7,500 donated, lost by the attacker
        address bob = makeAddr("bob");
        vm.prank(WHALE);
        IERC20(P.SPY).transfer(bob, 13e16); // ~$100
        vm.startPrank(bob);
        IERC20(P.SPY).approve(d.pSpy, 13e16);
        IMarket(d.pSpy).mint(13e16);
        vm.stopPrank();
        uint256 value = Math.mulDiv(IMarket(d.pSpy).balanceOf(bob), IMarket(d.pSpy).exchangeRateCurrent(), 1e18);
        emit log_named_decimal_uint("bob's claim after donation (SPY)", value, 18);
        assertGt(value, 13e16 * 99 / 100, "loses under 1% to rounding");
    }

    function testLowerOperatorCapsAreEnforced() public {
        // The operator may lower the caps to $100 / $50: a fresh pair config proves the path (queue, 1 h, set).
        IsolatedMarginTypes.PairRiskConfig memory low = P.longRisk(100e18, 50e18);
        vm.prank(P.LEDGER);
        IConfig(P.CONFIG).queuePairRisk(P.PUSDG, d.pSpy, P.PUSDG, low);
        vm.warp(block.timestamp + 3601);
        _freshSpyFeed();
        vm.prank(P.LEDGER);
        IConfig(P.CONFIG).setPairRisk(P.PUSDG, d.pSpy, P.PUSDG, low);
        vm.expectRevert(); // $120 gross > $100
        this.openFor(60e6);
        uint256 id = _openLong(45e6, 200); // $90 gross fits
        assertGt(id, 0);
    }

    function openFor(uint256 marginUsdg) external returns (uint256) {
        return _openLong(marginUsdg, 200);
    }
}

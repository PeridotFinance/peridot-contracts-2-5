// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IsolatedMarginTypes} from "../../contracts/margin/IsolatedMarginTypes.sol";
import {SpyMarginParams as P} from "../../script/spy/SpyMarginParams.sol";
import {SpyCollateralParams as C} from "../../script/spy/SpyCollateralParams.sol";
import {DeploySpyCollateral} from "../../script/spy/DeploySpyCollateral.s.sol";
import {RobinhoodSpyCollateralDelegate} from "../../contracts/margin/spy/RobinhoodSpyCollateralDelegate.sol";
import {SpyCollateralLiquidator} from "../../contracts/margin/spy/SpyCollateralLiquidator.sol";
import "./SpyMarginForkBase.sol";

interface ICollateralController {
    function _setCollateralFactor(address, uint256) external returns (uint256);
    function exitMarket(address) external returns (uint256);
    function getHypotheticalAccountLiquidity(address, address, uint256, uint256)
        external
        view
        returns (uint256, uint256, uint256);
}

interface IPSpyCollateral {
    function _setImplementation(address, bool, bytes memory) external;
    function implementation() external view returns (address);
    function lendingSupplyCap() external view returns (uint256);
    function _setLendingSupplyCap(uint256) external;
    function totalUnderlyingSupply() external view returns (uint256);
    function getAccountSnapshot(address) external view returns (uint256, uint256, uint256, uint256);
    function sessionReason() external view returns (uint256);
}

interface IDebtMarket {
    function repayBorrow(uint256) external returns (uint256);
    function liquidateBorrow(address, uint256, address) external returns (uint256);
}

interface IOperatorAdapter {
    function setOperator(address, bool) external;
    function operators(address) external view returns (bool);
}

/// @notice pSPY as plain lending collateral, on top of the SPY margin ceremony applied to the live state with the
/// deployed SPY margin contracts (journal spy-margin-mainnet.json). Pin with SPY_FORK_BLOCK / SPY_NATIVE_BLOCK.
contract SpyCollateralForkTest is SpyMarginForkBase {
    using stdJson for string;

    address constant NVDA_LENDER = 0x12c1e2C33F63F897E0e4ac1969C29493136f2481; // live pNVDA+pUSDG lending account
    address alice = makeAddr("spy-collateral-alice");
    address bob = makeAddr("nvda-only-bob");
    address keeperEoa = makeAddr("keeper");
    DeploySpyCollateral.Deployed c;

    address constant NVDA_FEED_247 = 0x321A36e441DfBadA01Aa6f9884F14a344E133D1F; // guard + lending NVDA feed
    int256 nvdaAnswer;

    /// @dev Re-stamps the real NVDA (24/7) answer at the current time, optionally scaled (10_000 = unchanged).
    function _setNvda(uint256 bps) internal {
        if (nvdaAnswer == 0) (, nvdaAnswer,,,) = IFeedRead(NVDA_FEED_247).latestRoundData();
        uint256 t = block.timestamp;
        vm.mockCall(
            NVDA_FEED_247,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1000), int256(uint256(nvdaAnswer) * bps / 10_000), t, t, uint80(1000))
        );
    }

    function _fresh() internal {
        _freshSpyFeed();
        _setNvda(10_000);
    }

    function setUp() public {
        _fork();
        // A pin inside the SPY closed window (weekend) is moved to the next Monday 02:00 UTC, with both feeds re-stamped
        // at their real last answers. Interest accrues on the native block number, which a warp does not change.
        uint256 ws = (block.timestamp + 3 days) % 7 days;
        if (ws >= 5 days || ws < 1 hours) {
            vm.warp(block.timestamp + (7 days - ws) % 7 days + 2 hours);
        }
        _setNvda(10_000);
        string memory j = vm.readFile("deployments/spy-margin/spy-margin-mainnet.json");
        d.delegate = j.readAddress(".delegate");
        d.pSpy = j.readAddress(".pSpy");
        d.lendingAdapter = j.readAddress(".lendingAdapter");
        d.spySource = j.readAddress(".spySource");
        d.router = j.readAddress(".router");
        _fresh();
        _fullCeremony(); // SPY margin enable, exactly as tools/spy/ceremony.sh t0 + t1
        _fresh();
    }

    function _collateralCeremony() internal {
        DeploySpyCollateral s = new DeploySpyCollateral();
        c = s.deployAll(d.pSpy, d.spySource);
        s.verify(c, d.pSpy, d.spySource);
        vm.startPrank(P.LEDGER);
        IPSpyCollateral(d.pSpy)._setImplementation(c.delegate, false, abi.encode(C.DEFAULT_LENDING_SUPPLY_CAP)); // 1
        IOperatorAdapter(P.ROUTER_ADAPTER).setOperator(c.liquidator, true); // 2
        assertEq(ICollateralController(P.CONTROLLER)._setCollateralFactor(d.pSpy, C.COLLATERAL_FACTOR), 0); // 3
        vm.stopPrank();
        (bool listed, uint256 cf,) = IController(P.CONTROLLER).markets(d.pSpy);
        assertTrue(listed);
        assertEq(cf, C.COLLATERAL_FACTOR);
        assertEq(IPSpyCollateral(d.pSpy).implementation(), c.delegate);
        assertEq(IPSpyCollateral(d.pSpy).lendingSupplyCap(), C.DEFAULT_LENDING_SUPPLY_CAP);
    }

    function _supplySpy(address who, uint256 amount) internal {
        vm.prank(WHALE);
        IERC20(P.SPY).transfer(who, amount);
        vm.startPrank(who);
        IERC20(P.SPY).approve(d.pSpy, amount);
        IMarket(d.pSpy).mint(amount);
        address[] memory a = new address[](1);
        a[0] = d.pSpy;
        IController(P.CONTROLLER).enterMarkets(a);
        vm.stopPrank();
    }

    function _liquidity(address who) internal view returns (uint256 err, uint256 liq, uint256 shortfall) {
        return IController(P.CONTROLLER).getAccountLiquidity(who);
    }

    function _nextSaturdayNoon() internal view returns (uint256) {
        uint256 s = (block.timestamp + 3 days) % 7 days; // seconds since Monday 00:00 UTC
        uint256 sat = 5 days + 12 hours;
        return block.timestamp + (s < sat ? sat - s : 7 days - s + sat);
    }

    // ------------------------------------------------------------------ ceremony

    function testCeremonyKeepsMarginAndStateIntact() public {
        uint256 id = _openLong(50e6, 200);
        uint256 supply = IMarket(d.pSpy).totalSupply();
        uint256 rate = IMarket(d.pSpy).exchangeRateStored();
        IsolatedMarginTypes.AccountMetrics memory m0 = _metrics(id);
        bytes memory pos6 = abi.encode(IRisk(P.RISK_ENGINE).getMetrics(NVDA_POSITION6_ACCOUNT));
        (uint256 e0, uint256 l0, uint256 s0) = _liquidity(NVDA_LENDER);
        _collateralCeremony();
        assertEq(IMarket(d.pSpy).exchangeRateStored(), rate);
        assertEq(IMarket(d.pSpy).totalSupply(), supply);
        assertEq(abi.encode(_metrics(id)), abi.encode(m0), "SPY margin position metrics unchanged");
        assertEq(abi.encode(IRisk(P.RISK_ENGINE).getMetrics(NVDA_POSITION6_ACCOUNT)), pos6, "NVDA position 6 unchanged");
        (uint256 e1, uint256 l1, uint256 s1) = _liquidity(NVDA_LENDER);
        assertEq(e0, e1);
        assertEq(l0, l1);
        assertEq(s0, s1);
        assertTrue(IOperatorAdapter(P.ROUTER_ADAPTER).operators(c.liquidator));
    }

    // ------------------------------------------------------------------ borrow at 30 %

    function testBorrowAtThirtyPercentAndCap() public {
        _collateralCeremony();
        uint256 amount = 0.1e18;
        _supplySpy(alice, amount);
        (uint256 err, uint256 liq,) = _liquidity(alice);
        assertEq(err, 0);
        uint256 price = IPriceOracleLike(IController(P.CONTROLLER).oracle()).getUnderlyingPrice(d.pSpy);
        uint256 underlying = IMarket(d.pSpy).balanceOf(alice) * IMarket(d.pSpy).exchangeRateStored() / 1e18;
        assertApproxEqAbs(liq, underlying * price / 1e18 * 3 / 10, 1e12, "30 % of SPY value");
        uint256 maxUsdg = liq / 1e12;
        vm.prank(alice);
        assertEq(IMarket(P.PUSDG).borrow(maxUsdg - 1), 0);
        vm.prank(alice);
        vm.expectRevert();
        IMarket(P.PUSDG).borrow(1e4);
        // supply cap: room up to 0.23 SPY total, then lending mints revert
        uint256 room = C.DEFAULT_LENDING_SUPPLY_CAP - IPSpyCollateral(d.pSpy).totalUnderlyingSupply();
        vm.prank(WHALE);
        IERC20(P.SPY).transfer(bob, room + 1e15);
        vm.startPrank(bob);
        IERC20(P.SPY).approve(d.pSpy, room + 1e15);
        IMarket(d.pSpy).mint(room - 1e12);
        vm.expectRevert();
        IMarket(d.pSpy).mint(2e15);
        vm.stopPrank();
        // the cap bounds SPY-backed borrowing at ~CF x cap (no margin pSPY here)
        uint256 capUsd = C.DEFAULT_LENDING_SUPPLY_CAP * price / 1e18;
        emit log_named_uint("cap value USD (1e18)", capUsd);
        emit log_named_uint("max SPY-backed borrow USD (1e18)", capUsd * 3 / 10);
        // margin opens are not capped
        uint256 id = _openLong(50e6, 200);
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.ACTIVE));
        assertGt(IPSpyCollateral(d.pSpy).totalUnderlyingSupply(), C.DEFAULT_LENDING_SUPPLY_CAP);
    }

    // ------------------------------------------------------------------ weekend / stale

    function _assertRepayOnly(uint256 expectedReason) internal {
        assertEq(IPSpyCollateral(d.pSpy).sessionReason(), expectedReason);
        (uint256 err,,) = _liquidity(alice);
        assertEq(err, 15, "SNAPSHOT_ERROR");
        uint256 bal = IMarket(d.pSpy).balanceOf(alice);
        vm.startPrank(alice);
        vm.expectRevert();
        IMarket(P.PUSDG).borrow(1e5);
        vm.expectRevert();
        IMarket(d.pSpy).redeem(bal / 10);
        vm.expectRevert();
        IMarket(d.pSpy).redeemUnderlying(1e14);
        vm.expectRevert();
        IMarket(d.pSpy).transfer(bob, bal / 10);
        vm.expectRevert();
        ICollateralController(P.CONTROLLER).exitMarket(d.pSpy);
        uint256 debt = IMarket(P.PUSDG).borrowBalanceCurrent(alice);
        IERC20(P.USDG).approve(P.PUSDG, debt / 2);
        assertEq(IDebtMarket(P.PUSDG).repayBorrow(debt / 2), 0, "repay works while closed");
        vm.stopPrank();
        // liquidation refused even if a keeper tries
        _fund(keeperEoa, 5e6);
        vm.startPrank(keeperEoa);
        IERC20(P.USDG).approve(P.PUSDG, 5e6);
        vm.expectRevert();
        IDebtMarket(P.PUSDG).liquidateBorrow(alice, 1e6, d.pSpy);
        vm.expectRevert();
        SpyCollateralLiquidator(c.liquidator).liquidate(alice, 1e6);
        vm.stopPrank();
    }

    function _aliceBorrowing() internal {
        _collateralCeremony();
        _supplySpy(alice, 0.1e18);
        vm.prank(alice);
        IMarket(P.PUSDG).borrow(15e6);
        _fund(alice, 20e6);
    }

    function testWeekendWindowRepayOnly() public {
        _aliceBorrowing();
        vm.warp(_nextSaturdayNoon());
        _fresh(); // even a "fresh" print is withheld inside the window
        _assertRepayOnly(7);
    }

    function testStaleFeedRepayOnly() public {
        _aliceBorrowing();
        (, int256 a,,,) = IFeedRead(P.SPY_FEED).latestRoundData();
        _setSpyAt(a, block.timestamp - 90_001);
        _assertRepayOnly(6);
    }

    function testFreshAgainRestoresEverything() public {
        _aliceBorrowing();
        (, int256 a,,,) = IFeedRead(P.SPY_FEED).latestRoundData();
        _setSpyAt(a, block.timestamp - 90_001);
        (uint256 err,,) = _liquidity(alice);
        assertEq(err, 15);
        _setSpy(a);
        (err,,) = _liquidity(alice);
        assertEq(err, 0);
        vm.prank(alice);
        assertEq(IMarket(P.PUSDG).borrow(1e6), 0);
    }

    // ------------------------------------------------------------------ liquidation (fresh)

    function testLiquidationWhenFreshViaFlashLiquidator() public {
        _collateralCeremony();
        _supplySpy(alice, 0.1e18);
        (, uint256 liq,) = _liquidity(alice);
        vm.prank(alice);
        IMarket(P.PUSDG).borrow(liq / 1e12 - 1e4);
        _moveSpy(8_000); // SPY -20 % on the feed (pool unchanged): shortfall
        (uint256 err,, uint256 shortfall) = _liquidity(alice);
        assertEq(err, 0);
        assertGt(shortfall, 0);
        uint256 debt = IMarket(P.PUSDG).borrowBalanceCurrent(alice);
        uint256 ledgerBefore = IERC20(P.USDG).balanceOf(P.LEDGER);
        vm.prank(keeperEoa);
        uint256 g = gasleft();
        uint256 profit = SpyCollateralLiquidator(c.liquidator).liquidate(alice, debt / 2);
        emit log_named_uint("flash liquidation gas", g - gasleft());
        assertGt(profit, 0);
        assertEq(IERC20(P.USDG).balanceOf(P.LEDGER) - ledgerBefore, profit, "profit to the Ledger");
        assertEq(IERC20(P.USDG).balanceOf(keeperEoa), 0);
        assertApproxEqAbs(IMarket(P.PUSDG).borrowBalanceCurrent(alice), debt - debt / 2, 2);
        assertEq(IERC20(P.SPY).balanceOf(c.liquidator), 0);
        assertEq(IMarket(d.pSpy).balanceOf(c.liquidator), 0);
    }

    function testUnenteredPSpyNotSeizableAtWeekend() public {
        _collateralCeremony();
        // bob: pNVDA collateral entered, USDG debt, plus pSPY that he never entered.
        vm.prank(WHALE);
        IERC20(P.NVDA).transfer(bob, 0.2e18);
        vm.startPrank(bob);
        IERC20(P.NVDA).approve(P.PNVDA, 0.2e18);
        IMarket(P.PNVDA).mint(0.2e18);
        address[] memory a = new address[](1);
        a[0] = P.PNVDA;
        IController(P.CONTROLLER).enterMarkets(a);
        vm.stopPrank();
        vm.prank(WHALE);
        IERC20(P.SPY).transfer(bob, 0.01e18);
        vm.startPrank(bob);
        IERC20(P.SPY).approve(d.pSpy, 0.01e18);
        IMarket(d.pSpy).mint(0.01e18);
        (, uint256 liq,) = _liquidity(bob);
        IMarket(P.PUSDG).borrow(liq / 1e12 * 99 / 100);
        vm.stopPrank();
        vm.warp(_nextSaturdayNoon());
        _fresh();
        // NVDA falls 30 % on its (24/7) price: shortfall on the NVDA side, read through the live controller oracle.
        address o = IController(P.CONTROLLER).oracle();
        uint256 pn = IPriceOracleLike(o).getUnderlyingPrice(P.PNVDA);
        vm.mockCall(o, abi.encodeWithSignature("getUnderlyingPrice(address)", P.PNVDA), abi.encode(pn * 70 / 100));
        (uint256 err,, uint256 shortfall) = _liquidity(bob);
        assertEq(err, 0, "bob never entered pSPY: his liquidity reads no SPY price");
        assertGt(shortfall, 0);
        _fund(keeperEoa, 10e6);
        vm.startPrank(keeperEoa);
        IERC20(P.USDG).approve(P.PUSDG, 10e6);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodSpyCollateralDelegate.SpySessionClosed.selector, uint256(7)));
        IDebtMarket(P.PUSDG).liquidateBorrow(bob, 1e6, d.pSpy);
        // the NVDA collateral is still liquidatable at the weekend, as before
        assertEq(IDebtMarket(P.PUSDG).liquidateBorrow(bob, 1e6, P.PNVDA), 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ debt-free withdrawals while closed

    function testDebtFreeWithdrawsAtWeekend() public {
        _collateralCeremony();
        _supplySpy(alice, 0.05e18);
        vm.warp(_nextSaturdayNoon());
        _fresh();
        assertEq(IPSpyCollateral(d.pSpy).sessionReason(), 7);
        (uint256 err,,) = _liquidity(alice);
        assertEq(err, 0, "debt-free: no snapshot error");
        uint256 bal = IMarket(d.pSpy).balanceOf(alice);
        vm.startPrank(alice);
        assertTrue(IMarket(d.pSpy).transfer(bob, bal / 5));
        assertEq(IMarket(d.pSpy).redeem(bal / 5), 0);
        assertEq(ICollateralController(P.CONTROLLER).exitMarket(d.pSpy), 0);
        assertEq(IMarket(d.pSpy).redeem(IMarket(d.pSpy).balanceOf(alice)), 0);
        vm.stopPrank();
        // and a weekend borrow cannot lean on SPY
        _supplySpy(bob, 0.05e18);
        vm.prank(bob);
        vm.expectRevert();
        IMarket(P.PUSDG).borrow(1e6);
    }

    function testRepayToZeroAtWeekendThenWithdraw() public {
        _aliceBorrowing();
        vm.warp(_nextSaturdayNoon());
        _fresh();
        uint256 bal = IMarket(d.pSpy).balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        IMarket(d.pSpy).redeem(bal);
        _fund(alice, 20e6);
        vm.startPrank(alice);
        IERC20(P.USDG).approve(P.PUSDG, type(uint256).max);
        assertEq(IDebtMarket(P.PUSDG).repayBorrow(type(uint256).max), 0);
        assertEq(IMarket(d.pSpy).redeem(bal), 0, "debt-free inside the window: withdraws");
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ NVDA debt against pSPY

    function _nvdaDebtLiquidation(uint256 spyBps, uint256 nvdaBps) internal {
        _collateralCeremony();
        _supplySpy(alice, 0.1e18);
        (, uint256 liq,) = _liquidity(alice);
        address o = IController(P.CONTROLLER).oracle();
        uint256 pn = IPriceOracleLike(o).getUnderlyingPrice(P.PNVDA);
        uint256 nvdaBorrow = liq * 95 / 100 * 1e18 / pn;
        vm.prank(alice);
        assertEq(IMarket(P.PNVDA).borrow(nvdaBorrow), 0);
        _moveSpy(spyBps);
        _setNvda(nvdaBps);
        if (nvdaBps != 10_000) {
            // The guarded margin source also checks the NVDA pool against the feed; the shock moves only the feed here,
            // so stand in the shocked price for it (the pool is left where it is).
            uint256 shocked = uint256(nvdaAnswer) * 1e10 * nvdaBps / 10_000;
            vm.mockCall(P.NVDA_GUARDED_SOURCE, abi.encodeWithSignature("assetPrices(address)", P.NVDA), abi.encode(shocked));
        }
        (uint256 err,, uint256 shortfall) = _liquidity(alice);
        assertEq(err, 0);
        assertGt(shortfall, 0);
        uint256 debt = IMarket(P.PNVDA).borrowBalanceCurrent(alice);
        uint256 maxRepay = debt / 2;
        uint256 pNow = IPriceOracleLike(o).getUnderlyingPrice(P.PNVDA);
        uint256 usdgIn = maxRepay * pNow / 1e18 / 1e12 * 97 / 100;
        uint256 usdgBefore = IERC20(P.USDG).balanceOf(P.LEDGER);
        uint256 nvdaBefore = IERC20(P.NVDA).balanceOf(P.LEDGER);
        vm.prank(keeperEoa);
        uint256 g0 = gasleft();
        uint256 profit = SpyCollateralLiquidator(c.liquidator).liquidateNvdaDebt(alice, usdgIn, maxRepay);
        emit log_named_uint("NVDA-debt flash liquidation gas", g0 - gasleft());
        assertGt(profit, 0);
        assertEq(IERC20(P.USDG).balanceOf(P.LEDGER) - usdgBefore, profit);
        assertGe(IERC20(P.NVDA).balanceOf(P.LEDGER), nvdaBefore);
        uint256 after_ = IMarket(P.PNVDA).borrowBalanceCurrent(alice);
        assertLt(after_, debt);
        assertGe(after_ + maxRepay + 2, debt);
        assertEq(IERC20(P.SPY).balanceOf(c.liquidator) + IERC20(P.NVDA).balanceOf(c.liquidator), 0);
        assertEq(IERC20(P.USDG).balanceOf(c.liquidator) + IMarket(d.pSpy).balanceOf(c.liquidator), 0);
    }

    function testNvdaDebtLiquidationAfterSpyFall() public {
        _nvdaDebtLiquidation(8_000, 10_000);
    }

    function testNvdaDebtLiquidationAfterNvdaRise() public {
        _nvdaDebtLiquidation(10_000, 12_000);
    }

    function testNvdaDebtNotLiquidatableAtWeekend() public {
        _collateralCeremony();
        _supplySpy(alice, 0.1e18);
        (, uint256 liq,) = _liquidity(alice);
        uint256 pn = IPriceOracleLike(IController(P.CONTROLLER).oracle()).getUnderlyingPrice(P.PNVDA);
        vm.prank(alice);
        IMarket(P.PNVDA).borrow(liq * 95 / 100 * 1e18 / pn);
        vm.warp(_nextSaturdayNoon());
        _fresh();
        _setNvda(12_000);
        (uint256 err,,) = _liquidity(alice);
        assertEq(err, 15, "indebted pSPY holder frozen at the weekend");
        vm.expectRevert();
        SpyCollateralLiquidator(c.liquidator).liquidateNvdaDebt(alice, 5e6, 1e15);
    }

    function testNvdaOnlyAccountsUnchangedValueForValue() public {
        // a fresh NVDA-only borrower, plus the live lending account, read in session and at the weekend
        vm.prank(WHALE);
        IERC20(P.USDG).transfer(bob, 1);
        uint256 snap = vm.snapshotState();
        (uint256 a0, uint256 b0, uint256 c0) = _liquidity(NVDA_LENDER);
        bytes memory p0 = abi.encode(IRisk(P.RISK_ENGINE).getMetrics(NVDA_POSITION6_ACCOUNT));
        uint256 t = _nextSaturdayNoon();
        vm.warp(t);
        (uint256 a1, uint256 b1, uint256 c1) = _liquidity(NVDA_LENDER);
        vm.revertToState(snap);
        _collateralCeremony();
        (uint256 a2, uint256 b2, uint256 c2) = _liquidity(NVDA_LENDER);
        assertEq(abi.encode(a0, b0, c0), abi.encode(a2, b2, c2), "in session");
        assertEq(abi.encode(IRisk(P.RISK_ENGINE).getMetrics(NVDA_POSITION6_ACCOUNT)), p0);
        vm.warp(t);
        (uint256 a3, uint256 b3, uint256 c3) = _liquidity(NVDA_LENDER);
        assertEq(abi.encode(a1, b1, c1), abi.encode(a3, b3, c3), "at the weekend");
        // entering pSPY with no balance changes nothing either
        address[] memory a = new address[](1);
        a[0] = d.pSpy;
        vm.prank(NVDA_LENDER);
        IController(P.CONTROLLER).enterMarkets(a);
        (uint256 a4, uint256 b4, uint256 c4) = _liquidity(NVDA_LENDER);
        assertEq(abi.encode(a3, b3, c3), abi.encode(a4, b4, c4), "zero-balance pSPY entrant");
    }

    function testSpyMarginUnaffectedAtWeekend() public {
        uint256 id = _openLong(50e6, 200);
        _collateralCeremony();
        vm.warp(_nextSaturdayNoon());
        _fresh();
        IsolatedMarginTypes.Position memory p = _pos(id);
        (uint256 err, uint256 tokens,,) = IPSpyCollateral(d.pSpy).getAccountSnapshot(p.account);
        assertEq(err, 0, "margin accounts exempt from the gate");
        assertEq(tokens, IMarket(d.pSpy).balanceOf(p.account));
        // margin's own weekend rule: repay and debt-free exit work
        uint256 debt = IMarket(P.PUSDG).borrowBalanceCurrent(p.account);
        _fund(user, debt + 1e6);
        vm.startPrank(user);
        IERC20(P.USDG).approve(P.EXECUTOR, debt + 1e6);
        IExecutor(P.EXECUTOR).repayWithUnderlying(id, debt + 1e6);
        IExecutor(P.EXECUTOR).exitDebtFreeToPTokens(id, 10_000);
        vm.stopPrank();
    }

    function testDonationInflationIsBounded() public {
        _collateralCeremony();
        address attacker = makeAddr("attacker");
        _supplySpy(attacker, 0.001e18);
        (, uint256 before,) = _liquidity(attacker);
        uint256 donation = 0.05e18;
        vm.prank(WHALE);
        IERC20(P.SPY).transfer(d.pSpy, donation); // raises the rate for every holder pro rata
        (, uint256 afterLiq,) = _liquidity(attacker);
        uint256 price = IPriceOracleLike(IController(P.CONTROLLER).oracle()).getUnderlyingPrice(d.pSpy);
        uint256 donationValueCf = donation * price / 1e18 * 3 / 10;
        assertLt(afterLiq - before, donationValueCf, "a donation buys less borrowing power than it costs");
        // the donation counts against the cap (griefing costs the donated SPY)
        assertGt(IPSpyCollateral(d.pSpy).totalUnderlyingSupply(), donation);
    }

    function testRollbackCapThenCf() public {
        _aliceBorrowing();
        vm.startPrank(P.LEDGER);
        IPSpyCollateral(d.pSpy)._setLendingSupplyCap(0);
        vm.stopPrank();
        vm.prank(WHALE);
        IERC20(P.SPY).transfer(bob, 1e15);
        vm.startPrank(bob);
        IERC20(P.SPY).approve(d.pSpy, 1e15);
        vm.expectRevert();
        IMarket(d.pSpy).mint(1e15);
        vm.stopPrank();
        // CF to 0 with SPY-backed debt outstanding makes the borrower liquidatable (documented ordering)
        vm.prank(P.LEDGER);
        assertEq(ICollateralController(P.CONTROLLER)._setCollateralFactor(d.pSpy, 0), 0);
        (,, uint256 shortfall) = _liquidity(alice);
        assertGt(shortfall, 0);
    }
}

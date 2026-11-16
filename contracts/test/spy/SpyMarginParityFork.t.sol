// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SpyMarginForkBase.sol";

/// @notice The two LIVE-NVDA touch points of the SPY rollout, checked value for value on a fork of the live state:
///   step 5  controller._setPriceOracle(3-market adapter)  -> pNVDA / pUSDG lending prices and account liquidity
///   step 12 marginOracle.setAssetSource(router)           -> NVDA / USDG margin prices, NVDA position 6 metrics
/// plus the enterMarkets griefing case the 3-market adapter exists for, and both rollback calls.
contract SpyMarginParityForkTest is SpyMarginForkBase {
    struct Snap {
        uint256 nvda;
        uint256 usdg;
        address assetPNvda;
        address assetPUsdg;
        bool priceablePNvda;
        bool priceablePUsdg;
        bytes metrics6; // abi-encoded AccountMetrics, or the revert data
        bool metrics6Ok;
        bytes liq6;
        uint256 lendPNvda;
        uint256 lendPUsdg;
        bytes ledgerLiquidity;
        bytes pos6Liquidity;
    }

    function setUp() public {
        _fork();
        _deploy();
    }

    function _snap() internal view returns (Snap memory s) {
        IMarginOracle o = IMarginOracle(P.MARGIN_ORACLE);
        s.nvda = o.getPrice(P.NVDA);
        s.usdg = o.getPrice(P.USDG);
        s.assetPNvda = o.marketAsset(P.PNVDA);
        s.assetPUsdg = o.marketAsset(P.PUSDG);
        s.priceablePNvda = o.marketPriceable(P.PNVDA);
        s.priceablePUsdg = o.marketPriceable(P.PUSDG);
        (s.metrics6Ok, s.metrics6) =
            P.RISK_ENGINE.staticcall(abi.encodeCall(IRisk.getMetrics, (NVDA_POSITION6_ACCOUNT)));
        (, s.liq6) = P.RISK_ENGINE.staticcall(abi.encodeCall(IRisk.isLiquidatable, (NVDA_POSITION6_ACCOUNT)));
        IPriceOracleLike lend = IPriceOracleLike(IController(P.CONTROLLER).oracle());
        s.lendPNvda = lend.getUnderlyingPrice(P.PNVDA);
        s.lendPUsdg = lend.getUnderlyingPrice(P.PUSDG);
        (, s.ledgerLiquidity) = P.CONTROLLER.staticcall(abi.encodeCall(IController.getAccountLiquidity, (P.LEDGER)));
        (, s.pos6Liquidity) =
            P.CONTROLLER.staticcall(abi.encodeCall(IController.getAccountLiquidity, (NVDA_POSITION6_ACCOUNT)));
    }

    function _assertSame(Snap memory a, Snap memory b, bool usdgMayFallBack) internal pure {
        assertEq(a.nvda, b.nvda, "margin NVDA price");
        if (!usdgMayFallBack) assertEq(a.usdg, b.usdg, "margin USDG price");
        assertEq(a.assetPNvda, b.assetPNvda, "marketAsset pNVDA");
        assertEq(a.assetPUsdg, b.assetPUsdg, "marketAsset pUSDG");
        assertEq(a.priceablePNvda, b.priceablePNvda, "priceable pNVDA");
        if (!usdgMayFallBack) assertEq(a.priceablePUsdg, b.priceablePUsdg, "priceable pUSDG");
        assertEq(a.metrics6Ok, b.metrics6Ok, "position 6 metrics success");
        assertEq(keccak256(a.metrics6), keccak256(b.metrics6), "position 6 metrics bytes");
        assertEq(keccak256(a.liq6), keccak256(b.liq6), "position 6 isLiquidatable bytes");
        assertEq(a.lendPNvda, b.lendPNvda, "lending pNVDA price");
        assertEq(a.lendPUsdg, b.lendPUsdg, "lending pUSDG price");
        assertEq(keccak256(a.ledgerLiquidity), keccak256(b.ledgerLiquidity), "Ledger account liquidity");
        assertEq(keccak256(a.pos6Liquidity), keccak256(b.pos6Liquidity), "position 6 account liquidity");
    }

    function testNvdaBitIdenticalAcrossTheWholeCeremonyAtAFreshPrice() public {
        Snap memory before = _snap();
        assertTrue(before.metrics6Ok, "position 6 must be priceable at the pin (fresh NVDA feed)");
        assertGt(before.nvda, 0);
        IsolatedMarginTypes.PairRiskConfig memory risk = P.longRisk(P.DEFAULT_MAX_POSITION_USD, P.DEFAULT_MAX_DEBT_USD);
        _ceremonyT0(risk);
        _assertSame(before, _snap(), false);
        emit log_named_uint("position 6 health (bps) unchanged", abi.decode(before.metrics6, (IsolatedMarginTypes.AccountMetrics)).healthFactorBps);
    }

    /// The only intended difference: with the NVDA guard stale, USDG now reads 1e18 from the SPY source (it read 0).
    /// Every NVDA-pair path still fails closed, because each also needs the NVDA price.
    function testNvdaStaleBehaviourUnchangedExceptTheUsdgFallback() public {
        uint256 later = block.timestamp + 26 hours; // past the NVDA guard's 25 h bound; no new NVDA round on a fork
        uint256 snapId = vm.snapshotState();
        vm.warp(later);
        Snap memory before = _snap();
        assertEq(before.nvda, 0, "NVDA stale");
        assertFalse(before.metrics6Ok);
        vm.revertToState(snapId);
        IsolatedMarginTypes.PairRiskConfig memory risk = P.longRisk(P.DEFAULT_MAX_POSITION_USD, P.DEFAULT_MAX_DEBT_USD);
        _ceremonyT0(risk);
        vm.warp(later);
        _setSpy(int256(74853877750)); // a fresh SPY print, so the USDG fallback is live
        Snap memory afterSnap = _snap();
        _assertSame(before, afterSnap, true);
        assertEq(before.usdg, 0);
        // fallback only if the SPY source prices USDG at this instant (weekday, parity holds)
        if (!SpySourceView(d.spySource).inClosedWindow(block.timestamp)) assertEq(afterSnap.usdg, 1e18);
        vm.expectRevert();
        ILiquidator(P.LIQUIDATOR).liquidate(ILiquidator.LiquidationParams(6, address(this), 0, 0, "", ""));
    }

    function testLendingAdapterMatchesTheLiveAdapterInEveryPriceState() public {
        IPriceOracleLike live = IPriceOracleLike(P.LIVE_LENDING_ADAPTER);
        IPriceOracleLike next = IPriceOracleLike(d.lendingAdapter);
        uint256[4] memory offsets = [uint256(0), 13 hours, 30 hours, 80 hours]; // fresh, stale guard, past lending 72 h
        for (uint256 i; i < offsets.length; i++) {
            uint256 snapId = vm.snapshotState();
            vm.warp(block.timestamp + offsets[i]);
            assertEq(next.getUnderlyingPrice(P.PNVDA), live.getUnderlyingPrice(P.PNVDA), "pNVDA");
            assertEq(next.getUnderlyingPrice(P.PUSDG), live.getUnderlyingPrice(P.PUSDG), "pUSDG");
            vm.revertToState(snapId);
        }
    }

    function testListingPSpyUnderTheLiveAdapterMakesAnEnteredAccountUnpriceable() public {
        // What the ordering prevents: pSPY listed while the controller oracle is still the 2-market adapter.
        vm.prank(P.LEDGER);
        assertEq(IController(P.CONTROLLER)._supportMarket(d.pSpy), 0);
        address griefer = makeAddr("griefer");
        address[] memory m = new address[](1);
        m[0] = d.pSpy;
        vm.prank(griefer);
        IController(P.CONTROLLER).enterMarkets(m);
        vm.expectRevert(); // UnsupportedMarket inside the liquidity loop: such an account could never be liquidated
        IController(P.CONTROLLER).getAccountLiquidity(griefer);
    }

    function testAfterTheCeremonyAnEnteredAccountStaysPriceableAndPSpyIsNotCollateral() public {
        _fullCeremony();
        address griefer = makeAddr("griefer");
        _fund(griefer, 10e6);
        address[] memory m = new address[](2);
        m[0] = d.pSpy;
        m[1] = P.PUSDG;
        vm.startPrank(griefer);
        IController(P.CONTROLLER).enterMarkets(m);
        IERC20(P.USDG).approve(P.PUSDG, 10e6);
        IMarket(P.PUSDG).mint(10e6);
        vm.stopPrank();
        (uint256 err, uint256 liquidity,) = IController(P.CONTROLLER).getAccountLiquidity(griefer);
        assertEq(err, 0);
        assertGt(liquidity, 0);
        // pSPY holdings add nothing (collateral factor 0)
        vm.prank(WHALE);
        IERC20(P.SPY).transfer(griefer, 1e17);
        vm.startPrank(griefer);
        IERC20(P.SPY).approve(d.pSpy, 1e17);
        IMarket(d.pSpy).mint(1e17);
        vm.stopPrank();
        (, uint256 liquidity2,) = IController(P.CONTROLLER).getAccountLiquidity(griefer);
        assertEq(liquidity2, liquidity, "pSPY is not lending collateral");
        // and nobody can borrow SPY
        vm.prank(griefer);
        vm.expectRevert();
        IMarket(d.pSpy).borrow(1);
    }

    function testRollbackCallsRestoreTheOriginalPricePaths() public {
        Snap memory before = _snap();
        _ceremonyT0(P.longRisk(P.DEFAULT_MAX_POSITION_USD, P.DEFAULT_MAX_DEBT_USD));
        vm.startPrank(P.LEDGER);
        IMarginOracle(P.MARGIN_ORACLE).setAssetSource(P.NVDA_GUARDED_SOURCE);
        assertEq(IController(P.CONTROLLER)._setPriceOracle(P.LIVE_LENDING_ADAPTER), 0);
        vm.stopPrank();
        Snap memory afterSnap = _snap();
        _assertSame(before, afterSnap, false);
        assertEq(IController(P.CONTROLLER).oracle(), P.LIVE_LENDING_ADAPTER);
        assertEq(IMarginOracle(P.MARGIN_ORACLE).getPrice(P.SPY), 0, "SPY unpriced after rollback");
    }
}

interface SpySourceView {
    function inClosedWindow(uint256) external view returns (bool);
}

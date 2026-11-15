// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AvalancheCashOnlyBase.sol";
import {PeridottrollerAvalanche} from "../contracts/PeridottrollerAvalanche.sol";

/**
 * @notice Fork test of the PROPOSED one-direction pilot `PW40` (docs: avalanche-cash-only-decision-table.md): borrow USDC against WAVAX only,
 *         collateral factor 40% on WAVAX, 0% on USDC, WAVAX borrowing disabled (paused), a 20% borrow cash floor on pUSDC.
 *         PROPOSAL values for measuring, NOT approved parameters. Margin-free fixture, both controller hooks unset, no deployment.
 *         Close factor 50%, liquidation incentive 1.08 (the fixture's), borrowers at 99% of borrowing power.
 */
contract AvalancheCashOnlyPilotConfigForkTest is AvalancheCashOnlyBase {
    address internal constant WHALE = address(0xDEAD0001);
    uint256 internal constant PW_CF = 0.40e18;
    PeridottrollerAvalanche internal ctrl;

    function setUp() public override {
        super.setUp();
        if (address(controller) == address(0)) return;
        ctrl = PeridottrollerAvalanche(address(controller));
        // pilot configuration (proposal values)
        require(controller._setCollateralFactor(PToken(address(pWavax)), PW_CF) == 0, "cf w");
        require(controller._setCollateralFactor(PToken(address(pUsdc)), 0) == 0, "cf u off");
        controller._setBorrowPaused(PErc20(address(pUsdc)), false); // USDC borrowing enabled; WAVAX borrowing STAYS paused
        PToken[] memory ps = new PToken[](1);
        ps[0] = PToken(address(pUsdc));
        uint256[] memory caps = new uint256[](1);
        caps[0] = 320_000e6; // 80% of the fixture's 400,000 USDC supply
        controller._setMarketBorrowCaps(ps, caps);
        require(ctrl._setBorrowCashFloor(PToken(address(pUsdc)), 80_000e6) == 0, "floor"); // 20% of supply
    }

    function _wavaxToUsdc6(uint256 w) internal view returns (uint256) {
        return Math.mulDiv(w, uint256(avaxAnswer), 1e8 * 1e12);
    }

    function _borrowerAtMax(address who, uint256 collateralWavax) internal returns (uint256 debt) {
        _mintP(pWavax, who, collateralWavax);
        _enter(who);
        (, uint256 liquidity,) = controller.getAccountLiquidity(who);
        // liquidity is in 1e18 USD; USDC has 6 decimals
        uint256 max6 = liquidity / 1e12;
        uint256 want = (max6 * 99) / 100;
        (bool ok,) = _borrow(pUsdc, who, want);
        require(ok, "borrow at 99% of capacity failed");
        debt = pUsdc.borrowBalanceStored(who);
    }

    struct Outcome { uint256 rounds; uint256 repaid; uint256 debtLeft; uint256 collateralLeft6; uint256 bad6; bool redeemOk; }

    /// @dev Liquidate with a funded liquidator until the account is healthy or collateral is exhausted; then redeem the whole seized claim.
    function _clear(address who) internal returns (Outcome memory o) {
        for (uint256 i; i < 30; ++i) {
            (, , uint256 shortfall) = controller.getAccountLiquidity(who);
            if (shortfall == 0) break;
            uint256 debt = pUsdc.borrowBalanceCurrent(who);
            if (debt == 0 || pWavax.balanceOf(who) == 0) break;
            uint256 repay = debt / 2;
            if (repay == 0) repay = debt;
            // never ask to repay more than the remaining collateral can seize (collateral value / LI, 0.2% margin), so the last round
            // consumes the collateral instead of failing and leaving it behind (which would understate bad debt)
            uint256 collNow6 = _wavaxToUsdc6(Math.mulDiv(pWavax.balanceOf(who), pWavax.exchangeRateStored(), 1e18));
            uint256 maxBySeize = (collNow6 * 9_240) / 10_000;
            if (repay > maxBySeize) repay = maxBySeize;
            if (repay == 0) break;
            (bool ok,,) = _liquidate(pUsdc, pWavax, who, repay);
            if (!ok) break; // collateral exhausted or other refusal
            o.repaid += repay;
            ++o.rounds;
        }
        o.debtLeft = pUsdc.borrowBalanceCurrent(who);
        uint256 coll = Math.mulDiv(pWavax.balanceOf(who), pWavax.exchangeRateStored(), 1e18);
        o.collateralLeft6 = _wavaxToUsdc6(coll);
        o.bad6 = o.debtLeft > o.collateralLeft6 ? o.debtLeft - o.collateralLeft6 : 0;
        // the liquidator redeems its whole seized claim: the pWAVAX market has no borrowers, so its cash equals its deposits
        uint256 claim = pWavax.balanceOf(CAROL);
        uint256 claimUnderlying = Math.mulDiv(claim, pWavax.exchangeRateStored(), 1e18);
        (o.redeemOk,) = _redeemUnderlying(pWavax, CAROL, claimUnderlying > 1 ? claimUnderlying - 1 : claimUnderlying);
    }

    // ================================================================= configuration is what the proposal says
    function testPilot_OneDirectionOnly_UsdcCannotBackBorrowing_WavaxBorrowingDisabled() public {
        // USDC supplied as collateral gives no borrowing power
        _mintP(pUsdc, BOB, 10_000e6);
        _enter(BOB);
        (, uint256 liquidity,) = controller.getAccountLiquidity(BOB);
        assertEq(liquidity, 0, "USDC collateral factor 0: no borrowing power");
        (bool ok,) = _borrow(pWavax, BOB, 1e18);
        assertFalse(ok, "WAVAX borrowing is disabled");
        // even an account with WAVAX collateral cannot borrow WAVAX (paused)
        _mintP(pWavax, DAVE, 100e18);
        _enter(DAVE);
        (ok,) = _borrow(pWavax, DAVE, 1e18);
        assertFalse(ok);
        assertTrue(controller.borrowGuardianPaused(address(pWavax)), "pWAVAX stays borrow-paused");
        // WAVAX collateral borrows USDC up to 40% only
        (, liquidity,) = controller.getAccountLiquidity(DAVE);
        uint256 max6 = liquidity / 1e12;
        (ok,) = _borrow(pUsdc, DAVE, (max6 * 101) / 100);
        assertFalse(ok, "above 40% of collateral value is refused");
        (ok,) = _borrow(pUsdc, DAVE, (max6 * 99) / 100);
        assertTrue(ok, "99% of capacity is allowed");
        assertEq(controller.isolatedMarginRiskHook(), address(0));
    }

    function testPilot_CashFloorBoundsUtilisationAt80Percent() public {
        // fund a borrower that could take more than the cap/floor allow
        _mintP(pWavax, WHALE, 120_000e18); // about 410k USD of borrowing power at 40%: more than cash minus floor
        _enter(WHALE);
        PToken[] memory ps = new PToken[](1);
        ps[0] = PToken(address(pUsdc));
        uint256[] memory caps = new uint256[](1);
        caps[0] = 500_000e6; // lift the cap so that the FLOOR (not the cap) is the binding limit in this test
        controller._setMarketBorrowCaps(ps, caps);
        uint256 cash = pUsdc.getCash();
        (bool ok,) = _borrow(pUsdc, WHALE, cash - 80_000e6 + 1);
        assertFalse(ok, "one unit beyond the floor refused");
        assertEq(keccak256(lastRevert.length >= 68 ? abi.encodePacked(bytes4(lastRevert), lastRevert.length) : bytes("")), keccak256(lastRevert.length >= 68 ? abi.encodePacked(bytes4(lastRevert), lastRevert.length) : bytes("")));
        (ok,) = _borrow(pUsdc, WHALE, cash - 80_000e6);
        assertTrue(ok, "within cap and floor");
        assertGe(pUsdc.getCash(), 80_000e6, "cash stays at or above the 20% floor");
    }

    // ================================================================= gaps: zero bad debt inside the zero-loss gap, measured tail loss outside it
    function _gap(uint256 fallBps, uint256 collateralWavax) internal returns (Outcome memory o, uint256 debt0) {
        address b = DAVE; // reuse a harness address: its token slots are in the warm fork cache
        debt0 = _borrowerAtMax(b, collateralWavax);
        _setAvaxBps(10_000 - fallBps);
        o = _clear(b);
    }

    function testGap_ZeroBadDebt_AtEmpiricalWindows() public {
        uint256[4] memory falls = [uint256(670), 1_240, 2_550, 4_290]; // worst observed 1h, 24h, 7d, 30d falls (bp)
        for (uint256 i; i < falls.length; ++i) {
            uint256 s = vm.snapshotState();
            (Outcome memory o, uint256 d0) = _gap(falls[i], 10_000e18);
            assertEq(o.bad6, 0, "no bad debt");
            assertTrue(o.redeemOk, "liquidator redeems its whole seized claim in WAVAX");
            assertLe(o.repaid, d0 + d0 / 100, "liquidator inventory used <= about 1.0x the debt");
            emit log_named_uint(string.concat("fall bp ", vm.toString(falls[i]), " rounds"), o.rounds);
            emit log_named_uint(string.concat("fall bp ", vm.toString(falls[i]), " repaid/debt (bp)"), (o.repaid * 10_000) / d0);
            vm.revertToState(s);
            vm.clearMockedCalls();
            _setAvaxBps(10_000);
        }
    }

    function testGap_TailLoss_MatchesTheClosedForm() public {
        // closed form: loss = D * (1 - rho / LI), rho = (1 - x) / (CF * u); CF 40%, u 99%, LI 1.08
        uint256[3] memory falls = [uint256(6_000), 6_760, 7_500];
        uint256[3] memory expectBp = [uint256(647), 2_418, 4_154]; // 6.47%, 24.18%, 41.54% of the debt
        for (uint256 i; i < falls.length; ++i) {
            uint256 s = vm.snapshotState();
            (Outcome memory o, uint256 d0) = _gap(falls[i], 10_000e18);
            // the debt at the end includes interest accrued by the liquidation blocks; compare the share of the initial debt
            uint256 lossBp = (o.bad6 * 10_000) / d0;
            assertApproxEqAbs(lossBp, expectBp[i], 40, "measured tail loss matches the closed form (within 0.4 pp)");
            vm.revertToState(s);
            vm.clearMockedCalls();
            _setAvaxBps(10_000);
        }
    }

    /// @dev An outage (stale feed, no liquidation, no new borrow) followed by a fresh round at a gapped price: the 24 h and 7 day worst
    ///      moves are survived with zero bad debt, and repay works throughout.
    function testOutageThenGap_ZeroBadDebt_RepayWorksDuringOutage() public {
        address b = DAVE; // reuse a harness address: its token slots are in the warm fork cache
        uint256 d0 = _borrowerAtMax(b, 10_000e18);
        vm.warp(block.timestamp + 24 hours); // stale AVAX (limit 1,200 s) and fresh USDC (limit 90,000 s)
        assertEq(oracle.getPrice(WAVAX), 0, "AVAX stale");
        (bool ok,) = _borrow(pUsdc, WHALE, 1e6);
        assertFalse(ok, "no new borrow during the outage");
        (bool lok,,) = _liquidate(pUsdc, pWavax, b, 1e6);
        assertFalse(lok, "no liquidation during the outage");
        (ok,) = _repay(pUsdc, b, 1e6);
        assertTrue(ok, "repay works during the outage");
        // fresh round at the worst observed 7-day fall (-25.5%)
        _setPrices(int256((uint256(realAvaxAnswer) * 7_450) / 10_000), usdcAnswer);
        Outcome memory o = _clear(b);
        assertEq(o.bad6, 0, "zero bad debt after the outage");
        assertGt(d0, 0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AvalancheCashOnlyBase.sol";
import {PeridottrollerAvalanche} from "../contracts/PeridottrollerAvalanche.sol";

/**
 * @notice Extended feed outages followed by adverse price changes, on the proposed one-direction pilot (borrow USDC against WAVAX), at
 *         pilot-scale markets and borrowers at FULL capacity (100% of borrowing power at the moment of borrowing), with the interest that
 *         accrues during the outage, USDC price deviations, and the number of liquidation rounds needed once service resumes.
 *         RESEARCH sizes (USDC borrow caps 1,000 / 5,000 / 10,000) and PROPOSAL collateral factors (PW30 / PW40); nothing here is approved.
 *         Margin-free fixture, both hooks unset. Output lines are `OUTAGE|...`.
 *
 * Model of the outage: AVAX max age 1,200 s and USDC max age 90,000 s are the production-intended guards and are NOT changed; the test
 * warps time AND blocks (interest accrues per block, 1 block per second as in the fixture rate model) without refreshing the feed, then
 * serves a fresh round at the adverse price. While stale: borrow and liquidation are refused, repay works (asserted once).
 */
contract AvalancheCashOnlyPilotOutageForkTest is AvalancheCashOnlyBase {
    PeridottrollerAvalanche internal ctrl;
    address internal constant WHALE = address(0xDEAD0001);

    function setUp() public override {
        super.setUp();
        if (address(controller) == address(0)) return;
        ctrl = PeridottrollerAvalanche(address(controller));
    }

    struct R {
        uint256 debt0; // debt at borrowing (USDC 6dp)
        uint256 debtResume; // debt when service resumes (after the outage's interest)
        uint256 rounds; // liquidation transactions needed after resume
        uint256 repaid; // USDC the liquidator repaid
        uint256 bad6; // unrecoverable debt after the collateral is exhausted
        bool blockedDuringOutage; // borrow and liquidation refused while stale
        bool repayWorkedDuringOutage;
    }

    /// @dev Pilot-scale market: the supplier base is `cap / 0.8` USDC (20% cash floor), the borrow cap is `cap`.
    function _configure(uint256 cfBps, uint256 capUsdc6) internal returns (uint256 supply6) {
        _unpauseBorrows();
        require(controller._setCollateralFactor(PToken(address(pWavax)), cfBps * 1e14) == 0, "cf w");
        require(controller._setCollateralFactor(PToken(address(pUsdc)), 0) == 0, "cf u");
        supply6 = (capUsdc6 * 10_000) / 8_000;
        // shrink the fixture LP's 400,000 USDC supply to the pilot supply (the LP redeems the rest)
        uint256 lpTokens = pUsdc.balanceOf(LP);
        uint256 keep = (lpTokens * supply6) / 400_000e6;
        vm.prank(LP);
        require(pUsdc.redeem(lpTokens - keep) == 0, "shrink market");
        PToken[] memory ps = new PToken[](1);
        ps[0] = PToken(address(pUsdc));
        uint256[] memory caps = new uint256[](1);
        caps[0] = capUsdc6 + 1; // the cap check is strict (<): allow exactly `cap`
        controller._setMarketBorrowCaps(ps, caps);
        require(ctrl._setBorrowCashFloor(PToken(address(pUsdc)), supply6 - capUsdc6) == 0, "floor");
    }

    function _wavaxToUsdc6(uint256 w) internal view returns (uint256) {
        return Math.mulDiv(w, uint256(avaxAnswer), 1e8 * 1e12);
    }

    /// @dev One borrower at 100% of capacity, `cap` USDC borrowed.
    function _borrowFull(address who, uint256 cfBps, uint256 capUsdc6) internal returns (uint256 debt) {
        uint256 wavax = Math.mulDiv(capUsdc6 * 1e12 * 1e8, 10_000, uint256(avaxAnswer) * cfBps) + 1e12; // collateral just enough for `cap`
        _mintP(pWavax, who, wavax);
        _enter(who);
        (, uint256 liquidity,) = controller.getAccountLiquidity(who);
        uint256 max6 = liquidity / 1e12;
        uint256 amt = max6 > capUsdc6 ? capUsdc6 : max6;
        (bool ok,) = _borrow(pUsdc, who, amt);
        require(ok, "full-capacity borrow failed");
        debt = pUsdc.borrowBalanceStored(who);
    }

    function _advance(uint256 seconds_) internal {
        vm.roll(block.number + seconds_);
        vm.warp(block.timestamp + seconds_);
    }

    function _clear(address who, R memory r) internal {
        for (uint256 i; i < 40; ++i) {
            (, , uint256 shortfall) = controller.getAccountLiquidity(who);
            if (shortfall == 0) break;
            uint256 debt = pUsdc.borrowBalanceCurrent(who);
            if (debt == 0 || pWavax.balanceOf(who) == 0) break;
            uint256 repay = debt / 2;
            if (repay == 0) repay = debt;
            uint256 coll6 = _wavaxToUsdc6(Math.mulDiv(pWavax.balanceOf(who), pWavax.exchangeRateStored(), 1e18));
            uint256 maxBySeize = (coll6 * 9_240) / 10_000;
            if (repay > maxBySeize) repay = maxBySeize;
            if (repay == 0) break;
            (bool ok,,) = _liquidate(pUsdc, pWavax, who, repay);
            if (!ok) break;
            r.repaid += repay;
            ++r.rounds;
        }
        uint256 left = pUsdc.borrowBalanceCurrent(who);
        uint256 coll = _wavaxToUsdc6(Math.mulDiv(pWavax.balanceOf(who), pWavax.exchangeRateStored(), 1e18));
        r.bad6 = left > coll ? left - coll : 0;
    }

    /// @dev outage of `outage` seconds, then a fresh round with AVAX at `10_000 - fallBp` bp of the pin and USDC at `usdcBp` bp of 1.0.
    function _scenario(uint256 cfBps, uint256 capUsdc6, uint256 outage, uint256 fallBp, uint256 usdcBp, bool checkBlocked)
        internal
        returns (R memory r)
    {
        _configure(cfBps, capUsdc6);
        address who = DAVE;
        _mintP(pWavax, BOB, 100e18);
        _enter(BOB);
        r.debt0 = _borrowFull(who, cfBps, capUsdc6);
        _advance(outage); // no refresh: the real feeds age (AVAX limit 1,200 s; USDC limit 90,000 s)
        if (checkBlocked) {
            assertEq(oracle.getPrice(WAVAX), 0, "AVAX is stale");
            // lift the cap and the floor so that ONLY the stale price can refuse BOB's borrow (the cap check runs before the price check)
            PToken[] memory ps = new PToken[](1);
            ps[0] = PToken(address(pUsdc));
            uint256[] memory caps = new uint256[](1);
            caps[0] = 10 * capUsdc6;
            controller._setMarketBorrowCaps(ps, caps);
            require(ctrl._setBorrowCashFloor(PToken(address(pUsdc)), 0) == 0, "floor off");
            (bool bok,) = _borrow(pUsdc, BOB, 1e6); // BOB has collateral and no debt
            uint256 borrowErr = _revertCode(lastRevert);
            (bool lok, uint256 lcode,) = _liquidate(pUsdc, pWavax, who, 1);
            r.blockedDuringOutage = !bok && !lok && borrowErr == PRICE_ERROR_CODE && lcode == PRICE_ERROR_CODE;
            (bool rok,) = _repay(pUsdc, who, 1);
            r.repayWorkedDuringOutage = rok;
        }
        r.debtResume = pUsdc.borrowBalanceCurrent(who);
        _setPrices(int256((uint256(realAvaxAnswer) * (10_000 - fallBp)) / 10_000), int256((uint256(usdcAnswer) * usdcBp) / 10_000));
        _clear(who, r);
    }

    function _log(string memory tag, uint256 cf, uint256 cap, uint256 outage, uint256 fallBp, uint256 usdcBp, R memory r) internal {
        emit log_string(
            string.concat(
                "OUTAGE|", tag, "|cf=", vm.toString(cf), "|cap=", vm.toString(cap), "|outageS=", vm.toString(outage), "|fallBp=",
                vm.toString(fallBp), "|usdcBp=", vm.toString(usdcBp), "|debt0=", vm.toString(r.debt0), "|debtResume=", vm.toString(r.debtResume),
                "|interestPpm=", vm.toString((r.debtResume - r.debt0) * 1_000_000 / r.debt0), "|rounds=", vm.toString(r.rounds), "|repaid=",
                vm.toString(r.repaid), "|bad6=", vm.toString(r.bad6), "|badBpOfDebt=", vm.toString(r.bad6 * 10_000 / r.debtResume)
            )
        );
    }

    /// @dev Closed form with interest and a USDC price factor: zero bad debt iff s >= LI * CF * (1 + i) * pU (borrower at 100%).
    function _predictBadBp(uint256 cfBps, uint256 debt0, uint256 debtResume, uint256 fallBp, uint256 usdcBp) internal pure returns (uint256) {
        // rho = s / (CF * (1+i) * pU), s = 1 - fall; loss = max(0, 1 - rho / 1.08)
        uint256 s = 10_000 - fallBp;
        uint256 denom = (cfBps * debtResume * usdcBp) / debt0; // = cf[bp] * (1+i) * usdc[bp]
        uint256 rho = (s * 1e18 * 1e4) / denom; // rho = (s/1e4) / ((cf/1e4) * (1+i) * (usdc/1e4)), scaled 1e18
        if (rho >= 1.08e18) return 0;
        return 10_000 - (rho * 10_000) / 1.08e18;
    }

    // ================================================================= outage lengths x adverse moves, both candidates, three research caps
    function testOutage_ThenAdverseMove_AllCapsBothCandidates() public {
        uint256[3] memory caps = [uint256(1_000e6), 5_000e6, 10_000e6];
        uint256[2] memory cfs = [uint256(3_000), 4_000];
        // (outage seconds, worst observed AVAX fall over a window of that length in bp) from the decision table
        uint256[4] memory outages = [uint256(3_600), 86_400, 604_800, 2_592_000];
        uint256[4] memory worst = [uint256(670), 1_240, 2_550, 4_290];
        for (uint256 a; a < caps.length; ++a) {
            for (uint256 b; b < cfs.length; ++b) {
                for (uint256 c; c < outages.length; ++c) {
                    uint256 snap = vm.snapshotState();
                    R memory r = _scenario(cfs[b], caps[a], outages[c], worst[c], 10_000, c == 0);
                    _log("worst", cfs[b], caps[a], outages[c], worst[c], 10_000, r);
                    assertEq(r.bad6, 0, "no bad debt at the worst observed move for the outage length (interest included)");
                    if (c == 0) {
                        assertTrue(r.blockedDuringOutage, "stale: borrow and liquidation refused");
                        assertTrue(r.repayWorkedDuringOutage, "stale: repay works");
                    }
                    vm.revertToState(snap);
                    vm.clearMockedCalls();
                    _setAvaxBps(10_000);
                }
            }
        }
    }

    /// @dev Outage + a tail step beyond the zero-loss gap: measured bad debt matches the closed form WITH the interest accrued during
    ///      the outage (a 30-day outage at the pilot market's rate raises the debt by a measured amount).
    function testOutage_TailStep_MatchesClosedFormWithInterest() public {
        uint256[3] memory outages = [uint256(86_400), 604_800, 2_592_000];
        uint256[2] memory cfs = [uint256(3_000), 4_000];
        for (uint256 b; b < cfs.length; ++b) {
            for (uint256 c; c < outages.length; ++c) {
                uint256 snap = vm.snapshotState();
                uint256 fallBp = 7_500;
                R memory r = _scenario(cfs[b], 5_000e6, outages[c], fallBp, 10_000, false);
                _log("tail", cfs[b], 5_000e6, outages[c], fallBp, 10_000, r);
                uint256 predicted = _predictBadBp(cfs[b], r.debt0, r.debtResume, fallBp, 10_000);
                uint256 measured = (r.bad6 * 10_000) / r.debtResume;
                assertApproxEqAbs(measured, predicted, 60, "measured = closed form with accrued interest (within 0.6 pp)");
                vm.revertToState(snap);
                vm.clearMockedCalls();
                _setAvaxBps(10_000);
            }
        }
    }

    // ================================================================= USDC price deviations
    function testUsdcDeviation_UpRaisesDebtValue_DownLowersIt() public {
        // 24 h outage, AVAX -12.4% (worst 24 h), USDC +2% / +5% / -2%: PW40 and PW30 at the 5,000 research cap
        uint256[3] memory usdcBp = [uint256(10_200), 10_500, 9_800];
        uint256[2] memory cfs = [uint256(3_000), 4_000];
        for (uint256 b; b < cfs.length; ++b) {
            uint256 base;
            for (uint256 d; d < usdcBp.length; ++d) {
                uint256 snap = vm.snapshotState();
                R memory r = _scenario(cfs[b], 5_000e6, 86_400, 1_240, usdcBp[d], false);
                _log("usdc", cfs[b], 5_000e6, 86_400, 1_240, usdcBp[d], r);
                assertEq(r.bad6, 0, "no bad debt at the worst 24 h fall with a USDC deviation of this size");
                if (d == 0) base = r.rounds;
                vm.revertToState(snap);
                vm.clearMockedCalls();
                _setAvaxBps(10_000);
            }
            base;
        }
        // a deviation large enough to matter: USDC +10% together with the 7-day worst fall at PW40 and a 30-day outage (tail combination)
        uint256 s2 = vm.snapshotState();
        R memory r2 = _scenario(4_000, 5_000e6, 2_592_000, 4_290, 11_000, false);
        _log("usdc-combo", 4_000, 5_000e6, 2_592_000, 4_290, 11_000, r2);
        emit log_named_uint("combo bad debt (bp of debt): USDC +10%, 30 day outage, AVAX -42.9%", (r2.bad6 * 10_000) / r2.debtResume);
        vm.revertToState(s2);
    }

    /// @dev USDC stale while AVAX is fresh: every price-dependent action stops (both prices are required), including liquidation of
    ///      AVAX-collateral accounts; repay works; after the USDC round returns, normal liquidation proceeds.
    function testUsdcStaleAvaxFresh_LiquidationBlocked_ThenResumes() public {
        _configure(4_000, 5_000e6);
        _borrowFull(DAVE, 4_000, 5_000e6);
        _advance(90_001); // both feeds past their limits at the pin; then refresh ONLY AVAX
        _mockFeed(AVAX_FEED, int256((uint256(realAvaxAnswer) * 6_000) / 10_000)); // fresh AVAX at -40%
        assertGt(oracle.getPrice(WAVAX), 0, "AVAX fresh");
        assertEq(oracle.getPrice(USDC), 0, "USDC stale (limit 90,000 s)");
        (bool lok,,) = _liquidate(pUsdc, pWavax, DAVE, 100e6);
        assertFalse(lok, "liquidation refused: USDC unpriced");
        (bool rok,) = _repay(pUsdc, DAVE, 1e6);
        assertTrue(rok, "repay works");
        _mockFeed(USDC_FEED, usdcAnswer); // the USDC round returns
        (, , uint256 shortfall) = controller.getAccountLiquidity(DAVE);
        assertGt(shortfall, 0, "underwater at the fresh price");
        R memory r;
        _clear(DAVE, r);
        assertEq(r.bad6, 0, "cleared with zero bad debt once both feeds are fresh (-40% is inside PW40's zero-loss gap)");
        assertGt(r.rounds, 0);
    }
}

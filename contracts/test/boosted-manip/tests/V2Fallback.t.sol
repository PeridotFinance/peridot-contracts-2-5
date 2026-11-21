// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/Test.sol";

import {V2Base, LenderV2} from "./V2Base.sol";
import {PToken} from "../../../contracts/PToken.sol";

/// @notice Wrapper v2: the FALLBACK OVERVALUATION WINDOW (how far the true NAV can fall below stored x 0.97 while the vault cannot answer), the two debt populations, the interaction
///         checks (fallback vs live borrow power, haircut cannot be bypassed, donation during the outage, seed/inflation), the non-feed ways the vault can revert, forced-fallback gas sweep.
contract V2FallbackTest is V2Base {
    function setUp() public {
        _setUpV2();
    }

    // =====================================================================================================================================================
    // D. the key economic question
    // =====================================================================================================================================================

    /// the vault's USDt fraction w and how far TRUE value falls below stored x 0.97: real vault, real pool pushed through the band (an arbitraged depeg leaves the vault holding USDt only)
    function test_D1_outage_depeg_table_true_nav_vs_stored_x_097() public {
        (uint256 c0, uint256 u0) = _holdingsAtPair();
        this.pushUsdtIn(); // the market depegs: arbitrageurs sell USDt into the pool; the vault's 3 bins end up holding USDt only
        (uint256 c1, uint256 u1) = _holdingsAtPair();
        assertGe(u1 * 100, (c1 + u1) * 99, "post-arbitrage the vault is >= 99 % USDt");
        assertApproxEqRel(c0 * 1e6 / (c0 + u0), 0.5e6, 0.01e18);
        _toOutage();
        uint256 supply = _supply();
        uint256 fallbackNav = supply * (_stored() * 9_700 / 10_000) / 1e6;
        console2.log("pre-arbitrage w (bp):", u0 * 10_000 / (c0 + u0));
        console2.log("post-arbitrage w (bp):", u1 * 10_000 / (c1 + u1));
        console2.log("stale-feed live mark at par (USDC-6) / fallback NAV = supply x stored x 0.97:", c1 + u1);
        console2.log(fallbackNav);
        uint256[7] memory delta = [uint256(100), 300, 500, 1_000, 3_000, 5_000, 10_000];
        console2.log("USDT depeg bp | w=pre-arb: true/fallback bp, covered | w=post-arb (~100 %): true/fallback bp, covered, stale-mark overstatement bp");
        for (uint256 j; j < delta.length; ++j) {
            uint256 tru0 = c0 + u0 * (10_000 - delta[j]) / 10_000;
            uint256 tru1 = c1 + u1 * (10_000 - delta[j]) / 10_000;
            uint256 r0 = tru0 * 10_000 / fallbackNav;
            uint256 r1 = tru1 * 10_000 / fallbackNav;
            console2.log(delta[j], r0, tru0 >= fallbackNav);
            console2.log(r1, tru1 >= fallbackNav, tru1 == 0 ? 0 : (c1 + u1) * 10_000 / tru1);
        }
        // pre-arbitrage w ~ 0.5: a 3 % depeg is covered, 10 % is not; post-arbitrage w ~ 1: 1 % covered, 3 % break-even (not covered by the rounding), 5 % not
        assertTrue(c0 + u0 * 9_900 / 10_000 >= fallbackNav, "1 % covered");
        assertApproxEqRel(c0 + u0 * 9_400 / 10_000, fallbackNav, 2e14, "6 % at w 0.5 = 3 % of NAV: break-even (equal within dust)");
        assertTrue(c1 + u1 * 9_900 / 10_000 >= fallbackNav, "w=1: 1 % covered");
        assertFalse(c1 + u1 * 9_500 / 10_000 >= fallbackNav, "w=1: 5 % NOT covered");
        assertFalse(c0 + u0 * 9_000 / 10_000 >= fallbackNav, "w=0.5: 10 % NOT covered");
        // true NAV is exactly the market value of what the vault holds: the in-kind exit pays it
        (uint256 cOut, uint256 tOut) = _inKindProbe(LEDGER, 16e6);
        assertApproxEqAbs(cOut + tOut, (c1 + u1) * 16 / 17, 2_000);
    }

    /// bad debt for the pilot limits. pop A = debt taken BEFORE the outage at 50 % of the live value (no haircut); pop B = debt taken DURING the outage at 50 % x 97 % of stored.
    /// A liquidator keeps 8 %, so the lender recovers collateral / 1.08: bad debt = max(0, debt - collateral_true / 1.08).
    function _bad(uint256 posted, uint256 debtBps, uint256 wdBps) internal pure returns (uint256) {
        uint256 d = posted * debtBps / 10_000;
        uint256 rec = posted * (10_000 - wdBps) / 10_000 * 10_000 / 10_800;
        return d > rec ? d - rec : 0;
    }

    function test_D2_bad_debt_table_pilot_limits() public pure {
        uint256[11] memory wd = [uint256(100), 300, 500, 1_000, 3_000, 4_500, 4_600, 4_800, 5_000, 6_000, 10_000];
        console2.log("w x depeg bp | bad debt USDC-6: popA(S=199), popB(S=199), popB(S=412.4: borrow cap binds) | haircut covers | liquidation at fallback prices pays");
        for (uint256 j; j < wd.length; ++j) {
            uint256 a = _bad(199e6, 5_000, wd[j]);
            uint256 b = _bad(199e6, 4_850, wd[j]);
            uint256 bc = _bad(412_371_134, 4_850, wd[j]); // 0.485 x S = 200 (the strict borrow cap)
            // liquidation at the fallback price: seized 1.08 x repaid at 0.97 stored; true value = 1.08 x (1 - wd) / 0.97 per unit repaid
            bool pays = (10_000 - wd[j]) * 10_800 >= 10_000 * 9_700;
            console2.log(wd[j], a, b);
            console2.log(bc, wd[j] <= 300, pays);
        }
        // thresholds
        assertEq(_bad(199e6, 5_000, 4_600), 0, "pop A: bad debt starts above 46 % (CF 50 % x 1.08 = 0.54)");
        assertGt(_bad(199e6, 5_000, 4_700), 0);
        assertEq(_bad(199e6, 4_850, 4_700), 0, "pop B: starts above 47.6 % (0.485 x 1.08 = 0.5238)");
        assertGt(_bad(199e6, 4_850, 4_800), 0);
        assertEq(_bad(199e6, 4_850, 3_000), 0, "a 30 % loss of the whole NAV: no bad debt");
        // ceiling: USDt to zero with w = 1: the whole debt; 0.485 x 199 = 96.5 USDC against the deposit-capped vault; the borrow cap (strict < 200) needs 412 USDC of collateral, impossible under the 200 USDC deposit ceiling
        assertEq(_bad(199e6, 4_850, 10_000), 199e6 * 4_850 / 10_000);
        assertLt(uint256(199e6) * 4_850 / 10_000, uint256(97e6));
        assertEq(_bad(412_371_134, 4_850, 10_000), uint256(412_371_134) * 4_850 / 10_000);
        // liquidation at the (haircut) fallback price pays while 1.08 x (1 - wd) >= 0.97: wd <= 10.18 %
        assertTrue((10_000 - 1_018) * 10_800 >= 10_000 * 9_700);
        assertFalse((10_000 - 1_019) * 10_800 >= 10_000 * 9_700);
    }

    // =====================================================================================================================================================
    // D5-D6. the vault can revert for reasons other than a stale feed: the "depeg x w" bound does not apply
    // =====================================================================================================================================================

    function test_D5_a_failing_pair_read_makes_the_vault_revert_with_fresh_feeds_and_the_wrapper_cannot_tell() public {
        _tick(3_600);
        _freshBoth();
        _poke();
        uint256 liveP = _p();
        vm.mockCallRevert(address(pair), abi.encodeWithSelector(pair.getBin.selector), "pair down");
        vm.expectRevert(); // ExitFailed from _pv
        v.totalAssets();
        assertEq(_live(), 0);
        assertTrue(_usingFallback(), "fresh feeds, healthy USDC, broken pair: the fallback serves 97 % of the last good leg");
        assertEq(_p(), (_stored() * 9_700 / 10_000) * 1e24);
        assertLt(_p(), liveP);
        assertFalse(_poke(), "the poke cannot refresh while the vault cannot answer");
        // the true NAV in this case is unrelated to w x depeg: the bound is the whole debt (see D2: 0.485 x posted), for up to 24 h after the last poke
        (,,,, uint256 left) = w2.shareState();
        console2.log("pair failure: fallback seconds left right after an hourly poke:", left);
        assertGe(left, WINDOW - 1);
    }

    function test_D6_a_vault_whose_nav_rounds_to_zero_is_priced_at_97_percent_of_the_last_good_leg() public {
        _tick(3_600);
        _freshBoth();
        _poke();
        // the pair reports empty bins: the vault holds (nearly) nothing
        vm.mockCall(address(pair), abi.encodeWithSelector(pair.getBin.selector), abi.encode(uint128(0), uint128(0)));
        uint256 conv = v.convertToAssets(1e6);
        console2.log("convertToAssets(1 share) with the bins reported empty:", conv);
        uint256 ta = v.totalAssets();
        console2.log("totalAssets (idle dust):", ta);
        assertEq(conv, 0, "TA 2 wei over 17 shares: convertToAssets(1 share) floors to 0");
        assertTrue(_usingFallback(), "answer 0 = 'cannot answer': fallback at 97 % of the last good leg although the vault is worth ~0");
        assertEq(_p(), (_stored() * 9_700 / 10_000) * 1e24);
        // a non-zero (tiny) answer is the LIVE price: the wrapper follows the collapse, no fallback
        vm.mockCall(address(pair), abi.encodeWithSelector(pair.getBin.selector), abi.encode(uint128(1e6), uint128(1e6)));
        assertGt(v.convertToAssets(1e6), 0);
        assertFalse(_usingFallback());
    }

    function test_D7_usdt_feed_conditions_that_start_the_fallback_at_once() public {
        _tick(3_600);
        _freshBoth();
        _poke();
        uint256 st = _stored();
        uint256 fb = (st * 9_700 / 10_000) * 1e24;
        // answer <= 0
        feedUsdt.setAnswer(0);
        assertTrue(_usingFallback(), "USDT answer 0");
        assertEq(_p(), fb);
        feedUsdt.setAnswer(-1);
        assertEq(_p(), fb, "negative answer");
        // reverting feed
        feedUsdt.setAnswer(1e8);
        assertFalse(_usingFallback());
        feedUsdt.setRevertLatest(true);
        assertTrue(_usingFallback(), "feed reverts (aggregator removed / paused)");
        assertEq(_p(), fb);
        feedUsdt.setRevertLatest(false);
        // incomplete round
        feedUsdt.setIncompleteRound();
        assertTrue(_usingFallback(), "answeredInRound < roundId");
        assertEq(_p(), fb);
        feedUsdt.setAnswer(1e8);
        // future-dated update
        feedUsdt.setUpdatedAt(clock + 1);
        assertTrue(_usingFallback(), "updatedAt in the future");
        assertEq(_p(), fb);
        feedUsdt.setUpdatedAt(clock);
        assertFalse(_usingFallback());
        // all of these are Chainlink-side: no caller can set them (the feed is not ours)
    }

    function test_D8_usdc_side_never_reaches_the_fallback_under_the_pilot_configuration() public {
        _tick(3_600);
        _freshBoth();
        _poke();
        // (a) USDC feed older than the base maxAge (90,000 s) but younger than the vault's (93,600): vault answers, base has no USDC price -> 0, not the fallback
        _to(t0 + 3_600 + 90_001);
        feedUsdt.setUpdatedAt(clock);
        feedUsdc.setUpdatedAt(t0 + 3_600);
        assertGt(_live(), 0);
        assertEq(_p(), 0);
        assertFalse(_usingFallback());
        // (b) USDC feed older than both: vault reverts AND the base has no price -> 0, no fallback
        _to(t0 + 3_600 + 93_601);
        feedUsdt.setUpdatedAt(clock);
        feedUsdc.setUpdatedAt(t0 + 3_600);
        assertEq(_live(), 0);
        assertEq(_p(), 0);
        assertFalse(_usingFallback());
        // (c) incomplete round, (d) future-dated: both sides reject
        _freshBoth();
        feedUsdc.setIncompleteRound();
        assertEq(_live(), 0);
        assertEq(_p(), 0);
        assertFalse(_usingFallback());
        feedUsdc.setAnswer(1e8);
        feedUsdc.setUpdatedAt(clock + 1);
        assertEq(_p(), 0);
        assertFalse(_usingFallback());
        feedUsdc.setUpdatedAt(clock);
        assertGt(_p(), 0);
        // (e) the ONLY USDC-side path: the base oracle's maxAge widened by its owner above the vault's 93,600 s. The USDC feed's last update is u; hourly pokes while it ages
        src.setMaxAge(100_000);
        _freshBoth();
        uint256 u = clock;
        for (uint256 k = 1; k <= 26; ++k) {
            _tick(3_600);
            feedUsdt.setUpdatedAt(clock);
            assertTrue(_poke());
        }
        assertEq(clock, u + 93_600);
        _tick(1);
        feedUsdt.setUpdatedAt(clock);
        assertEq(_live(), 0, "vault: USDC feed 93,601 s old -> FeedInvalid");
        assertGt(_usdcPx(), 0, "base (maxAge widened): still prices USDC");
        assertTrue(_usingFallback(), "the only USDC-side fallback path: a base oracle maxAge above 93,600 s (owner configuration)");
    }

    // =====================================================================================================================================================
    // E. interaction checks
    // =====================================================================================================================================================

    /// the stated comparison. Fallback <= 0.97 x the live price AT THE LAST POKE always holds (stored <= live at a poke). Against the CURRENT live price it holds only while the NAV did not
    /// fall more than 3 % after the last poke: nobody can poke down while the vault cannot answer. (A USDT feed that merely goes STALE cannot produce the counterexample: its last update, which
    /// re-marks the NAV, is 93,601 s older than the outage, so any poke that is still inside the 24 h window already saw it. It needs an immediate trigger: a bad/reverting answer or a pair read failure.)
    function testFuzz_E1_fallback_vs_live_when_the_nav_moved_after_the_last_poke(uint256 gRaw) public {
        uint256 g = 0.4e8 + gRaw % 0.8e8; // USDT/USD answer 0.40 .. 1.20
        _tick(3_600);
        _freshBoth();
        _poke(); // stored = the true leg
        uint256 st = _stored();
        feedUsdt.setAnswer(int256(g)); // the feed re-marks USDT; nobody pokes
        _tick(7_200);
        _freshBoth();
        uint256 l = _live();
        uint256 pLive = _p();
        feedUsdt.setRevertLatest(true); // the vault stops answering (aggregator reverts)
        assertTrue(_usingFallback());
        uint256 pFb = _p();
        assertEq(pFb, (st * 9_700 / 10_000) * 1e24);
        if (l * 10_000 >= st * 9_700) assertLe(pFb, pLive, "stored not above live / 0.97: the fallback never lends more than live");
        else assertGt(pFb, pLive, "a NAV fall of more than 3 % since the last poke: fallback > live");
    }

    function test_E1b_counterexample_nav_down_since_the_last_poke_and_the_fix() public {
        _tick(3_600);
        _freshBoth();
        _poke();
        uint256 st = _stored();
        feedUsdt.setAnswer(0.9e8); // the feed tracks a real 10 % USDT move: NAV -5 % at w ~ 0.5
        _tick(7_200);
        _freshBoth();
        uint256 l = _live();
        uint256 pLive = _p();
        console2.log("NAV after the re-mark, bp of the stored leg:", l * 10_000 / st);
        feedUsdt.setRevertLatest(true);
        uint256 pFb = _p();
        console2.log("fallback / live in bp (above 10,000 = the fallback lends more than live):", pFb * 10_000 / pLive);
        assertGt(pFb, pLive);
        // fix: ANYONE can poke the drop at once while the vault answers (permissionless); the hourly keeper does
        feedUsdt.setRevertLatest(false);
        assertTrue(_poke());
        assertEq(_stored(), l);
        feedUsdt.setRevertLatest(true);
        assertLt(_p(), pLive, "after a poke of the drop the fallback is 3 % below live again");
    }

    function test_E2_borrow_power_live_vs_fallback_same_state() public {
        _tick(3_600);
        _freshBoth();
        _poke();
        uint256 live = _maxBorrow(100e6, 5_000);
        uint256 st = _stored();
        _toOutage();
        uint256 fb = _maxBorrow(100e6, 5_000);
        console2.log("borrow power of 100 shares at CF 50 %: live / fallback / ratio bp:", live);
        console2.log(fb, fb * 10_000 / live);
        assertLe(fb, live);
        assertApproxEqAbs(fb * 10_000 / live, 9_700, 2);
        assertEq(st, _stored());
    }

    /// the haircut cannot be bypassed: for ANY sequence the fallback price is exactly floor(stored x 0.97) x live USDC price, never above 0.97 x the highest leg any poke saw
    function testFuzz_E3_haircut_always_applied_and_bounded_by_the_highest_leg_seen(uint256 seed) public {
        uint256 maxSeen = _stored();
        for (uint256 i; i < 8; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 a = r % 5;
            if (a == 0) {
                uint256 d = (r >> 8) % (2 * _ta() + 1);
                usdc.mint(address(this), d);
                usdc.transfer(proxyAddr, d);
            } else if (a == 1) {
                feedUsdt.setAnswer(int256(0.3e8 + ((r >> 8) % 2.7e8)));
            } else if (a == 2) {
                feedUsdt.setAnswer(1e8);
            } else if (a == 3) {
                _tick((r >> 8) % (3 * 3_600));
                _freshBoth();
            } else {
                uint256 l = _live();
                if (_poke() && l > maxSeen) maxSeen = l;
            }
        }
        for (uint256 k = 1; k <= 26; ++k) {
            _tick(3_600);
            _freshUsdc();
            uint256 l = _live();
            if (_poke() && l > maxSeen) maxSeen = l;
        }
        _tick(1);
        _freshUsdc();
        assertTrue(_usingFallback(), "the walk ends before the 26 h run-up: the USDT feed is 93,601 s old");
        uint256 expected = (_stored() * 9_700 / 10_000) * _usdcPx() * 1e12 / 1e6;
        assertEq(_p(), expected, "haircut applied, live USDC price used");
        assertEq(w2.getShareUsdPrice(), expected / 1e12);
        assertLe(_p(), (maxSeen * 9_700 / 10_000 + 1) * 1e24, "never above 97 % of the highest vault leg any accepted poke saw");
    }

    function test_E4_donation_during_the_outage_cannot_raise_the_price() public {
        _toOutage();
        uint256 p0 = _p();
        uint256 st = _stored();
        usdc.mint(address(this), 500e6);
        usdt.mint(address(this), 500e6);
        usdc.transfer(proxyAddr, 500e6);
        usdt.transfer(proxyAddr, 500e6);
        assertEq(_p(), p0, "donation of USDC and USDT: the fallback ignores the live leg");
        assertFalse(_poke(), "the poke cannot store while the vault cannot answer");
        assertEq(_stored(), st);
        assertEq(_live(), 0);
        // the feed returns: live is the backed value; the stored leg can then only step +2 % per hour
        feedUsdt.setAnswer(1e8);
        assertGt(_live(), st * 50);
        assertEq(_p(), _live() * 1e24);
        _tick(3_600);
        _freshBoth();
        assertTrue(_poke());
        assertEq(_stored(), _up(st));
    }

    function test_E5_seed_and_donation_inflation_surface_is_not_read_by_the_wrapper() public {
        _tick(3_600);
        _freshBoth();
        _poke();
        uint256 live0 = _p();
        // shares donated straight to the pToken address (the first-depositor inflation vector of the lending market) do not move the share price: the wrapper never reads pToken balances
        vm.prank(LEDGER);
        sh.transfer(address(pS2), 16e6);
        assertEq(_p(), live0, "live price unchanged");
        _toOutage();
        uint256 fb = _p();
        vm.prank(DEAD);
        sh.transfer(address(pS2), 1e6);
        assertEq(_p(), fb, "fallback price unchanged");
        assertEq(address(w2.baseOracle()), address(guarded));
    }

    // =====================================================================================================================================================
    // F. forced fallback on a healthy vault through the gas the caller supplies
    // =====================================================================================================================================================

    function _sweepPrice(uint256 live, uint256 from, uint256 to, uint256 step) internal returns (uint256 reverts, uint256 equalLive, uint256 other, uint256 firstOther) {
        for (uint256 g = from; g <= to; g += step) {
            vm.cool(address(w2));
            vm.cool(proxyAddr);
            vm.cool(address(guarded));
            vm.cool(address(src));
            vm.cool(address(feedUsdc));
            vm.cool(address(feedUsdt));
            vm.cool(address(pair));
            (bool ok, bytes memory ret) = address(w2).staticcall{gas: g}(abi.encodeWithSignature("getUnderlyingPrice(address)", address(pS2)));
            if (!ok || ret.length < 32) {
                ++reverts;
            } else if (abi.decode(ret, (uint256)) == live) {
                ++equalLive;
            } else {
                ++other;
                if (firstOther == 0) firstOther = g;
            }
        }
    }

    /// stored ABOVE live: a 3.00 glitch pokes the stored leg up two steps, then the feed recovers: the fallback price (1.009) would be ABOVE the live price (1.0): the discriminating case
    function _storedAboveLive() internal {
        feedUsdt.setAnswer(3e8);
        _tick(3_600);
        _freshBoth();
        feedUsdt.setAnswer(3e8);
        _poke();
        _tick(3_600);
        _freshBoth();
        feedUsdt.setAnswer(3e8);
        _poke();
        feedUsdt.setAnswer(1e8);
        assertGt(_stored(), _live());
        assertGt((_stored() * 9_700 / 10_000), _live(), "setup: stored x 0.97 above live");
    }

    function test_F1_gas_sweep_getUnderlyingPrice_either_reverts_or_returns_the_live_price_stored_high() public {
        _storedAboveLive();
        uint256 live = _p();
        assertEq(live, _live() * 1e24);
        (uint256 rv, uint256 eq_, uint256 ot, uint256 first) = _sweepPrice(live, 4_000, 400_000, 250);
        console2.log("sweep stored>live (4k..400k step 250): reverts / equals live / OTHER / first other gas:", rv);
        console2.log(eq_, ot, first);
        assertEq(ot, 0, "no gas value makes a healthy vault price at the fallback");
        assertGt(eq_, 0);
    }

    function test_F1b_fine_gas_sweep_around_the_point_where_the_call_starts_to_succeed() public {
        _storedAboveLive();
        uint256 live = _p();
        (uint256 rv, uint256 eq_, uint256 ot, uint256 first) = _sweepPrice(live, 90_000, 106_000, 5);
        console2.log("fine sweep (90k..106k step 5): reverts / equals live / OTHER / first other gas:", rv);
        console2.log(eq_, ot, first);
        assertEq(ot, 0, "fine sweep: never the fallback price");
        assertGt(rv, 0);
        assertGt(eq_, 0);
    }

    function test_F2_gas_sweep_stored_below_live() public {
        feedUsdt.setAnswer(0.5e8);
        _poke(); // stored -25 %
        feedUsdt.setAnswer(1e8);
        assertLt(_stored() * 9_700 / 10_000, _live());
        uint256 live = _p();
        (uint256 rv, uint256 eq_, uint256 ot, uint256 first) = _sweepPrice(live, 4_000, 400_000, 250);
        console2.log("sweep stored<live: reverts / equals live / OTHER / first other gas:", rv);
        console2.log(eq_, ot, first);
        assertEq(ot, 0);
        assertGt(eq_, 0);
    }

    function test_F3_gas_sweep_poke_stores_only_the_live_leg_or_nothing() public {
        usdc.mint(address(this), 20e6);
        usdc.transfer(proxyAddr, 17e6 / 50); // +2 %: the gate-open poke would store the live leg exactly
        _tick(3_600);
        _freshBoth();
        uint256 before_ = _stored();
        uint256 live = _live();
        uint256 want = live > _up(before_) ? _up(before_) : live;
        uint256 snap = vm.snapshotState();
        uint256 stores;
        uint256 nothing;
        for (uint256 g = 4_000; g <= 200_000; g += 500) {
            vm.cool(address(w2));
            vm.cool(proxyAddr);
            vm.cool(address(pair));
            vm.cool(address(feedUsdc));
            vm.cool(address(feedUsdt));
            (bool ok,) = address(w2).call{gas: g}(abi.encodeWithSignature("poke()"));
            uint256 now_ = _stored();
            if (now_ == before_) ++nothing;
            else {
                ++stores;
                assertEq(now_, want, "a store is always the true bounded live leg");
                assertTrue(ok);
            }
            vm.revertToState(snap);
        }
        console2.log("poke gas sweep: nothing stored / stored the live leg:", nothing);
        console2.log(stores);
        assertGt(stores, 0);
    }

    // =====================================================================================================================================================
    // G. constants: what each alternative buys (arithmetic)
    // =====================================================================================================================================================

    function test_G1_alternatives_table() public pure {
        uint256[3] memory h = [uint256(300), 500, 1_000];
        console2.log("haircut bp | LTV liquidatable at outage onset (CF 50 %) | liquidation pays up to w x depeg (bp) | bad debt starts above w x depeg (bp, popB incl. 1.08)");
        for (uint256 i; i < 3; ++i) {
            uint256 ltvOnset = 5_000 * (10_000 - h[i]) / 10_000;
            uint256 liqPays = 10_000 - (10_000 - h[i]) * 10_000 / 10_800;
            uint256 badStarts = 10_000 - ltvOnset * 10_800 / 10_000;
            console2.log(h[i], ltvOnset, liqPays);
            console2.log(badStarts);
        }
        console2.log("up-cap bp/h | hours to climb back after -25 % | hours to reach 0.97-break-even 2/0.97 x true | max stored in 24 h of poisoning (x1e4)");
        uint256[3] memory u = [uint256(100), 200, 500];
        for (uint256 i; i < 3; ++i) {
            uint256 x = 10_000;
            uint256 n25;
            uint256 nBreak;
            uint256 m = 7_500;
            while (m < 10_000) {
                m = m * (10_000 + u[i]) / 10_000;
                ++n25;
            }
            while (x * 9_700 / 10_000 < 20_000) {
                x = x * (10_000 + u[i]) / 10_000;
                ++nBreak;
            }
            uint256 y = 10_000;
            for (uint256 k; k < 24; ++k) y = y * (10_000 + u[i]) / 10_000;
            console2.log(u[i], n25, nBreak);
            console2.log(y);
        }
    }
}

/// @notice The same economics at the USD 200 cap with the WHOLE NAV in the band (operator holds 199 of 200 shares), the worst case for the USDt fraction.
contract V2EconTest is V2Base {
    function _extraLedger() internal pure override returns (uint256) {
        return 183e6;
    }

    function setUp() public {
        _setUpV2();
    }

    function test_D3_two_debt_populations_at_the_outage_onset() public {
        LenderV2 lender = _lender();
        address[3] memory who = [ALICE, BOB, CAROL];
        uint256[3] memory ltv = [uint256(4_800), 4_900, 4_999]; // of the live value
        uint256[3] memory amt;
        for (uint256 i; i < 3; ++i) {
            vm.prank(LEDGER);
            sh.transfer(who[i], 40e6);
            vm.startPrank(who[i]);
            sh.approve(address(lender), type(uint256).max);
            lender.supply(sh.balanceOf(who[i]));
            amt[i] = _maxBorrow(lender.collateral(who[i]), ltv[i]);
            lender.borrow(amt[i]);
            vm.stopPrank();
        }
        vm.prank(LEDGER);
        sh.transfer(ATTACKER, 60e6); // 199 shares: 120 to the three borrowers, 60 here
        uint256 livePower = _maxBorrow(60e6, 5_000); // live borrow power of 60 shares at CF 50 %
        _toOutage();
        // pop A at the outage onset: the haircut turns LTV above 0.5 x 0.97 = 48.5 % into a shortfall
        (, uint256 sfA) = lender.liquidity(ALICE);
        (, uint256 sfB) = lender.liquidity(BOB);
        (, uint256 sfC) = lender.liquidity(CAROL);
        assertEq(sfA, 0, "LTV 48.0 %: safe on the fallback");
        assertGt(sfB, 0, "LTV 49.0 %: liquidatable the moment the fallback starts");
        assertGt(sfC, 0, "LTV 49.99 %: liquidatable");
        // effective bonus: the liquidator repays R and seizes 1.08 R at the 97 % price = 1.08 / 0.97 R of TRUE value
        uint256 repay = amt[2] / 2;
        usdc.mint(address(this), repay);
        usdc.approve(address(lender), repay);
        (uint256 seized,) = lender.liquidate(CAROL, repay);
        uint256 trueValue = seized * _stored() / 1e6;
        console2.log("liquidation at outage onset: repaid / true value seized / bonus bp (1.08/0.97 = 11,134):", repay);
        console2.log(trueValue, trueValue * 10_000 / repay);
        assertApproxEqAbs(trueValue * 10_000 / repay, 11_134, 15);
        // pop B: debt taken DURING the outage: max 48.5 % of stored
        vm.startPrank(ATTACKER);
        sh.approve(address(lender), type(uint256).max);
        lender.supply(60e6);
        // at the FALLBACK price: 4,990 / 5,010 bp of the fallback value = 48.4 % / 48.7 % of the live value
        uint256 ok = _maxBorrow(60e6, 4_990);
        uint256 tooMuch = _maxBorrow(60e6, 5_010);
        vm.expectRevert("insufficient liquidity");
        lender.borrow(tooMuch);
        lender.borrow(ok);
        vm.stopPrank();
        // compare with live: at the same state (stored == live at the last poke) the live borrow power is exactly 0.5 / 0.485 times higher
        assertApproxEqAbs(_maxBorrow(60e6, 5_000) * 10_000 / livePower, 9_700, 2, "fallback borrow power = 97 % of the live one");
    }

    /// the end-to-end loss: borrower at the pop-B maximum, USDt depegs 30 % and to ~0 while the feed is dead, the real pool arbitraged (w ~ 1), liquidated after the feed returns
    function test_D4_end_to_end_loss_depeg_30_and_100_percent() public {
        LenderV2 lender = _lender();
        vm.prank(LEDGER);
        sh.transfer(ATTACKER, 183e6);
        this.pushUsdtIn();
        _toOutage();
        vm.startPrank(ATTACKER);
        sh.approve(address(lender), type(uint256).max);
        lender.supply(183e6);
        uint256 debt = _maxBorrow(183e6, 4_999); // 50 % of the FALLBACK value = 48.5 % of stored
        lender.borrow(debt);
        vm.stopPrank();
        (uint256 c1, uint256 u1) = _holdingsAtPair();
        uint256 supply = _supply();
        uint256[4] memory dBps = [uint256(3_000), 5_000, 9_000, 10_000];
        console2.log("pop B max debt (USDC-6) / posted shares / USDt depeg bp -> collateral true value, recovered after liquidation (/1.08), bad debt");
        console2.log(debt, uint256(183e6));
        uint256 prevBad;
        for (uint256 j; j < dBps.length; ++j) {
            uint256 trueNav = c1 + u1 * (10_000 - dBps[j]) / 10_000;
            uint256 coll = trueNav * 183e6 / supply;
            uint256 rec = coll * 10_000 / 10_800;
            uint256 bad = debt > rec ? debt - rec : 0;
            console2.log(dBps[j], coll, rec);
            console2.log(bad);
            assertGe(bad, prevBad);
            prevBad = bad;
        }
        assertEq(prevBad, debt, "USDt to zero with w=1: the whole debt is lost");
        assertLt(debt, 90e6, "88.8 USDC at 183 posted shares");
        // no bad debt at -30 % even though the 3 % haircut stopped covering at -3 %
        assertEq(debt > ((c1 + u1 * 7_000 / 10_000) * 183e6 / supply) * 10_000 / 10_800 ? 1 : 0, 0);
    }
}

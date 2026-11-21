// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/Test.sol";

import {V2Base, LenderV2} from "./V2Base.sol";
import {PharaohDlmmShareOracle} from "../../../contracts/PharaohDlmmShareOracle.sol";
import {PToken} from "../../../contracts/PToken.sol";

/// @dev one transaction: donate, then poke `n` times
contract PokeStorm {
    function run(PharaohDlmmShareOracle o, IERC20 usdc, address vault, uint256 donation, uint256 n) external returns (uint256 accepted, uint256 storedAfter) {
        if (donation != 0) usdc.transfer(vault, donation);
        for (uint256 i; i < n; ++i) {
            if (o.poke()) ++accepted;
        }
        storedAfter = o.lastGoodAssetsPerShare();
    }
}

/// @notice Wrapper v2 (stored last-good vault leg, permissionless poke, 97 % fallback for 24 h): the POKE ATTACK SURFACE. Real vault, real wrapper, real GuardedAvalanchePriceOracle.
contract V2PokeTest is V2Base {
    function setUp() public {
        _setUpV2();
    }

    // =====================================================================================================================================================
    // A. the timeline: when does the fallback start and end (fixture trap: the vault only reverts 93,601 s after the USDT feed's last update, the stored leg expires 86,400 s after the last poke)
    // =====================================================================================================================================================

    function test_A1_timeline_with_an_hourly_keeper() public {
        uint256 lastPoke;
        for (uint256 k = 1; k <= 25; ++k) {
            _tick(3600);
            _freshUsdc(); // USDC heartbeat; the USDT feed is NOT refreshed: it died at t0
            assertTrue(_poke(), "keeper poke");
            lastPoke = clock;
        }
        assertEq(lastPoke, t0 + 90_000);
        // age 93,600: the vault still answers (maxFeedAge is inclusive), live price, no fallback
        _to(t0 + VAULT_MAX_AGE);
        _freshUsdc();
        assertGt(_live(), 0, "vault answers at age 93,600");
        assertFalse(_usingFallback());
        uint256 liveP = _p();
        // age 93,601: the vault reverts, the wrapper serves stored x 97 %
        _to(t0 + VAULT_MAX_AGE + 1);
        _freshUsdc();
        vm.expectRevert();
        v.totalAssets();
        assertEq(_live(), 0);
        assertTrue(_usingFallback());
        uint256 expected = (_stored() * 9_700 / 10_000) * _usdcPx() * 1e12 / 1e6;
        assertEq(_p(), expected, "fallback = stored x 0.97 x live USDC price");
        assertLt(_p(), liveP, "fallback below the un-haircut stale live mark");
        (,,,, uint256 left) = w2.shareState();
        console2.log("hourly keeper: fallback seconds left at outage start:", left);
        assertEq(left, WINDOW - (clock - lastPoke));
        // the window is inclusive at 24 h after the LAST poke and 0 one second later
        _to(lastPoke + WINDOW);
        _freshUsdc();
        assertGt(_p(), 0, "valid at age == 24 h");
        _to(lastPoke + WINDOW + 1);
        _freshUsdc();
        assertEq(_p(), 0, "0 one second later");
        assertFalse(_usingFallback());
    }

    function test_A2_without_a_keeper_the_fallback_is_already_expired_when_the_vault_first_reverts() public {
        // deployed at t0, nobody pokes, the USDT feed dies at t0: the vault reverts at t0 + 93,601 s, the stored leg expired at t0 + 86,400 s: price 0 (v1 behaviour)
        _to(t0 + VAULT_MAX_AGE + 1);
        _freshUsdc();
        vm.expectRevert();
        v.totalAssets();
        assertEq(_p(), 0, "stored leg older than 24 h: no fallback");
        // one poke while the vault still answered would have bought up to 24 h - (outage start - poke)
    }

    function test_A3_poke_gate_boundaries_3599_3600() public {
        usdc.mint(address(this), 20e6);
        usdc.transfer(proxyAddr, 2e6); // live +11.7 %
        uint256 s0 = _stored();
        _to(t0 + 3_599);
        _freshBoth();
        assertFalse(_poke(), "3,599 s: refused");
        assertEq(_stored(), s0);
        assertEq(w2.lastGoodTime(), t0, "a refused poke does not move the clock");
        _to(t0 + 3_600);
        _freshBoth();
        assertTrue(_poke(), "3,600 s: accepted");
        assertEq(_stored(), _up(s0));
    }

    // =====================================================================================================================================================
    // B. poisoning the stored leg UPWARD
    // =====================================================================================================================================================

    function test_B1_donation_then_poke_stored_moves_at_most_2pct_and_the_live_price_never_reads_it() public {
        uint256 s0 = _stored();
        usdc.mint(ATTACKER, 200e6);
        vm.prank(ATTACKER);
        usdc.transfer(proxyAddr, 200e6); // donation = 11.8x the vault
        uint256 liveHigh = _live();
        assertGt(liveHigh, s0 * 12);
        assertFalse(_poke(), "same block as the constructor: the upward gate is closed");
        _tick(3_600);
        _freshBoth();
        assertTrue(_poke());
        assertEq(_stored(), _up(s0), "+2 % exactly, not 12x");
        // the price the controller reads while the vault answers is the LIVE leg: the stored value is irrelevant to it, whatever it is
        assertEq(_p(), liveHigh * 1e24);
        assertFalse(_usingFallback());
    }

    function test_B2_flash_donation_and_repeated_pokes_in_one_transaction() public {
        PokeStorm storm = new PokeStorm();
        usdc.mint(address(storm), 100e6);
        uint256 s0 = _stored();
        _tick(3_600);
        _freshBoth();
        // gate open: 100 USDC donated and 20 pokes in one transaction -> exactly one accepted, +2 %
        (uint256 accepted, uint256 after_) = storm.run(w2, IERC20(address(usdc)), proxyAddr, 100e6, 20);
        assertEq(accepted, 1, "one store per transaction");
        assertEq(after_, _up(s0));
        // right after (same block): the gate is closed again, a further donation + storm stores nothing
        usdc.mint(address(storm), 100e6);
        (accepted, after_) = storm.run(w2, IERC20(address(usdc)), proxyAddr, 100e6, 20);
        assertEq(accepted, 0);
        assertEq(after_, _up(s0));
        console2.log("flash donation: 200 USDC given away, stored moved by (bp):", (after_ - s0) * 10_000 / s0);
    }

    function test_B3_hourly_pokes_with_a_held_donation_compound_2pct_per_hour_and_never_pass_the_backed_value() public {
        uint256 s0 = _stored();
        usdc.mint(ATTACKER, 153e6);
        vm.prank(ATTACKER);
        usdc.transfer(proxyAddr, 153e6); // TA 17 -> 170: live leg 10x
        uint256 expected = s0;
        uint256 n2x;
        uint256 nBreak;
        console2.log("n hourly pokes / stored in bp of the pre-donation leg / x1.02^n");
        for (uint256 n = 1; n <= 48; ++n) {
            _tick(3_599);
            _freshBoth();
            assertFalse(_poke(), "3,599 s after the last store: refused");
            _tick(1);
            _freshBoth();
            assertTrue(_poke());
            expected = _up(expected);
            assertEq(_stored(), expected, "floor(prev x 1.02) at every step");
            assertLe(_stored(), _live(), "never above the live leg");
            if (n2x == 0 && _stored() >= 2 * s0) n2x = n;
            if (nBreak == 0 && _stored() * 9_700 / 10_000 >= 2 * s0) nBreak = n;
            if (n == 1 || n == 6 || n == 12 || n == 24 || n == 36 || n == 48) console2.log(n, _stored() * 10_000 / s0);
        }
        console2.log("hours to double the stored leg (2x):", n2x);
        console2.log("hours until 0.97 x stored >= 2x the pre-donation leg (the CF-50% break-even of a fallback price):", nBreak);
        assertEq(n2x, 36);
        assertEq(nBreak, 37);
        // the donation is REAL value: the in-kind exit of one share (at the feed marks) pays at least the stored leg (up to the 2 wei vault dust)
        (uint256 cOut, uint256 tOut) = _inKindProbe(LEDGER, 16e6);
        uint256 perShare = _atFeeds(cOut, tOut) * 1e6 / 16e6;
        assertGe(perShare + 2, _stored(), "stored leg is backed by the vault: redeemable in kind");
    }

    function test_B4_feed_glitch_doubling_nav_stuck_until_the_vault_reverts_is_capped_by_the_2pct_ladder() public {
        uint256 s0 = _stored();
        feedUsdt.setAnswer(3e8); // USDT/USD = 3.00 for good (a stuck feed): the vault guard flags it but totalAssets still returns
        uint256 liveGlitch = _live();
        uint256 ratioBp = liveGlitch * 10_000 / s0;
        console2.log("USDT/USD = 3.00: live leg in bp of the true leg:", ratioBp);
        assertGt(ratioBp, 19_900); // doubles NAV with w ~ 0.5
        uint256 pokes;
        for (uint256 k = 1; k <= 26; ++k) {
            _tick(3_600);
            _freshUsdc(); // USDT is stuck: never refreshed
            if (_poke()) ++pokes;
        }
        assertEq(clock, t0 + VAULT_MAX_AGE);
        assertEq(pokes, 26);
        uint256 s = _stored();
        console2.log("after 26 hourly pokes at the glitch (the most the ladder allows before the vault reverts): stored in bp of the true leg:", s * 10_000 / s0);
        assertLt(s * 10_000 / s0, 16_800);
        assertGt(s * 10_000 / s0, 16_700);
        uint256 liveP = _p(); // the live path still serves the full glitch (UNLIMITED, pre-existing: the wrapper has no limiter on the live leg)
        assertGt(liveP, s0 * 1e24 * 19_900 / 10_000 - 1);
        _tick(1);
        _freshUsdc();
        assertTrue(_usingFallback());
        uint256 fb = _p();
        console2.log("fallback price in bp of the true price (stuck 3.00 feed, 26 pokes):", fb * 10_000 / (s0 * 1e24));
        assertLt(fb, liveP, "the fallback is BELOW the glitch price the live path served an hour earlier");
        // CF 50 %: borrow power against the fallback is 0.5 x 1.62 = 0.81 of the TRUE value of the collateral: no bad debt; break-even needs stored x 0.97 >= 2 x true
        assertLt(fb * 5_000 / 10_000, s0 * 1e24);
    }


    /// the gate may already be open when the glitch lands: then a 27th poke fits before the vault reverts
    function test_B4b_gate_already_open_gives_27_pokes_x1_707() public {
        uint256 s0 = _stored();
        _tick(3_600); // last store was the constructor, 3,600 s ago: gate open
        _freshBoth();
        feedUsdt.setAnswer(3e8); // glitch lands now (c)
        uint256 c = clock;
        uint256 pokes;
        if (_poke()) ++pokes;
        for (uint256 k = 1; k <= 26; ++k) {
            _tick(3_600);
            _freshUsdc();
            if (_poke()) ++pokes;
        }
        assertEq(clock, c + VAULT_MAX_AGE);
        assertEq(pokes, 27);
        console2.log("27 pokes: stored in bp of the true leg:", _stored() * 10_000 / s0);
        assertGt(_stored() * 10_000 / s0, 17_000);
        assertLt(_stored() * 10_000 / s0, 17_100);
        _tick(1);
        _freshUsdc();
        assertTrue(_usingFallback());
        assertLt(_p() * 5_000 / 10_000, s0 * 1e24, "borrow power still below the true collateral value");
    }

    function _swapBackAll() external {
        address who = address(0x5AAB);
        uint256 a = usdt.balanceOf(who);
        if (a != 0) _swapAs(who, false, a);
        uint256 b = usdc.balanceOf(who);
        if (b != 0) _swapAs(who, true, b);
    }

    function test_B5_swap_push_poke_swap_back_both_directions_moves_stored_by_basis_points_only() public {
        for (uint256 dir; dir < 2; ++dir) {
            uint256 snap = vm.snapshotState();
            _tick(3_600);
            _freshBoth();
            uint256 base = _live();
            if (dir == 0) this.pushUsdtIn();
            else this.pushUsdcIn();
            uint256 pushed = _live();
            _poke();
            uint256 storedAtPeak = _stored();
            this._swapBackAll();
            uint256 back = _live();
            console2.log(dir == 0 ? "sell USDt in: leg before / pushed / stored after poke / after swap back" : "sell USDC in: leg before / pushed / stored after poke / after swap back", base);
            console2.log(pushed, storedAtPeak, back);
            // the stored value can only be the pushed leg (capped): within a few bp of the true one
            assertLe(storedAtPeak * 10_000 / base, 10_000 + 10, "stored overstates the true leg by <= 10 bp");
            assertGe(storedAtPeak * 10_000 / base, 10_000 - 10, "or understates by <= 10 bp (an immediate downward poke)");
            // and an honest poke afterwards repairs it within one gate
            _tick(3_600);
            _freshBoth();
            _poke();
            assertApproxEqAbs(_stored(), back, back / 5_000 + 2);
            vm.revertToState(snap);
        }
    }

    function test_B6_an_equal_or_lower_poke_resets_the_gate_bounded_delay_no_starvation() public {
        uint256 s0 = _stored();
        _tick(3_000);
        _freshBoth();
        assertTrue(_poke(), "equal to live: stored at once");
        assertEq(w2.lastGoodTime(), clock);
        uint256 resetAt = clock;
        // live rises 1 % (donation)
        usdc.mint(address(this), 20e6);
        usdc.transfer(proxyAddr, 17e6 / 100 * 1); // ~ +1 % of TA 17e6
        uint256 live = _live();
        assertGt(live, s0);
        _tick(600); // t0 + 3,600: 3,600 s after the CONSTRUCTOR but only 600 s after the reset
        _freshBoth();
        assertFalse(_poke(), "only 600 s since the last store");
        assertEq(w2.lastGoodTime(), resetAt, "a refused poke never resets the clock: nobody can starve an upward move");
        _tick(3_000);
        _freshBoth();
        assertTrue(_poke(), "accepted 3,600 s after the reset");
        assertEq(_stored(), live < _up(s0) ? live : _up(s0));
    }

    function test_B7_stored_value_older_than_24h_is_replaced_uncapped_exactly_after_the_boundary() public {
        usdc.mint(address(this), 20e6);
        usdc.transfer(proxyAddr, 17e6); // live leg doubles (backed)
        uint256 s0 = _stored();
        uint256 snap = vm.snapshotState();
        _to(t0 + WINDOW); // age == 24 h: still fresh -> capped
        _freshBoth();
        assertTrue(_poke());
        assertEq(_stored(), _up(s0), "age == 24 h: capped");
        vm.revertToState(snap);
        _to(t0 + WINDOW + 1);
        _freshBoth();
        assertTrue(_poke());
        assertGt(_stored(), s0 * 19 / 10, "age > 24 h: the live value, uncapped (the live path already serves it)");
        assertEq(_stored(), _live());
    }

    /// INVARIANT: whatever the sequence of donations, glitches, time and pokes, the stored leg never exceeds the highest vault leg ANY accepted poke (or the constructor) saw,
    /// and no accepted poke inside the window raises it by more than 2 %.
    function testFuzz_B8_stored_never_exceeds_the_highest_live_leg_seen_and_rises_at_most_2pct_per_store(uint256 seed) public {
        uint256 maxSeen = _stored();
        for (uint256 i; i < 12; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 a = r % 6;
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
            } else if (a == 4) {
                _tick(WINDOW + 1 + (r >> 8) % 3_600);
                _freshBoth();
            } else {
                uint256 prev = _stored();
                uint256 prevAt = w2.lastGoodTime();
                uint256 l = _live();
                bool ok = _poke();
                if (ok && l > maxSeen) maxSeen = l;
                if (ok && clock - prevAt <= WINDOW) assertLe(_stored(), prev * 10_200 / 10_000, "<= +2 % per accepted store inside the window");
            }
            assertLe(_stored(), maxSeen, "stored <= the highest live leg any accepted poke saw");
        }
    }

    // =====================================================================================================================================================
    // C. poisoning DOWNWARD, the ratchet trap, MEV in the choice of WHEN to poke
    // =====================================================================================================================================================

    function _hoursToClimb(uint256 low, uint256 target) internal pure returns (uint256 n) {
        while (low < target) {
            low = low * 10_200 / 10_000;
            ++n;
            if (n > 400) revert("no convergence");
        }
    }

    function test_C1_downward_glitch_is_stored_at_once_then_climbs_2pct_per_hour() public {
        uint256 s0 = _stored();
        feedUsdt.setAnswer(0.5e8); // USDT/USD halves for one block
        uint256 l = _live();
        assertLt(l * 10_000 / s0, 7_600);
        assertTrue(_poke(), "downward: stored at once, even in the constructor's block and by anyone");
        assertEq(_stored(), l);
        feedUsdt.setAnswer(1e8); // the feed recovers
        assertApproxEqAbs(_live(), s0, 2);
        // the ratchet: the stored leg climbs back at 2 % per hour
        uint256 n;
        while (_stored() + 2 < _live()) {
            _tick(3_600);
            _freshBoth();
            assertTrue(_poke());
            ++n;
            if (n > 100) revert("no convergence");
        }
        console2.log("hours for the stored leg to climb back after a one-block -25 % glitch:", n);
        assertEq(n, _hoursToClimb(l, s0 - 2));
        // table (arithmetic of the same ladder): dip -> hours to recover, at 2 %/h
        uint256[7] memory dips = [uint256(100), 300, 500, 1_000, 2_500, 5_000, 7_500];
        console2.log("dip in bp / hours to climb back at +2 %/h / at +1 %/h / at +5 %/h");
        for (uint256 j; j < dips.length; ++j) {
            uint256 lo = s0 * (10_000 - dips[j]) / 10_000;
            uint256 n1 = _hoursAt(lo, s0, 10_100);
            uint256 n2 = _hoursAt(lo, s0, 10_200);
            uint256 n5 = _hoursAt(lo, s0, 10_500);
            console2.log(dips[j], n2);
            console2.log(n1, n5);
        }
    }

    function _hoursAt(uint256 low, uint256 target, uint256 stepBps) internal pure returns (uint256 n) {
        while (low < target) {
            low = low * stepBps / 10_000;
            ++n;
            if (n > 1000) revert("no convergence");
        }
    }

    /// the ratchet trap only bites if the vault is UNAVAILABLE while the stored leg is still low. For a USDT/USD feed that must go stale (93,601 s after its last update) that needs the
    /// glitch dip to be so deep that 26 hourly steps do not repair it: 1.02^26 = 1.67, i.e. a dip of more than 40 %.
    function test_C2_ratchet_trap_overlapping_a_feed_outage_needs_a_dip_over_40_percent() public {
        uint256 s0 = _stored();
        // a lender with a borrower who opened at live prices AFTER the feed recovered
        usdc.mint(address(this), 300e6);
        LenderV2 lender = new LenderV2(IERC20(address(usdc)), sh, w2, guarded, address(pS2), CF_BPS, BORROW_CAP, CASH_FLOOR, LIQ_INCENTIVE_BPS, CLOSE_FACTOR_BPS);
        usdc.transfer(address(lender), 274e6);
        // glitch: USDT/USD -> ~0 for one block (NAV -50 %), poked by anyone
        feedUsdt.setAnswer(1);
        assertTrue(_poke());
        uint256 low = _stored();
        assertLt(low * 10_000 / s0, 5_100);
        feedUsdt.setAnswer(1e8); // corrected at t0 = c: the feed can go stale at c + 93,601
        vm.startPrank(LEDGER);
        sh.approve(address(lender), type(uint256).max);
        lender.supply(16e6);
        uint256 borrowAmt = 16e6 * 4_500 / 10_000; // LTV 45 % of the live value
        lender.borrow(borrowAmt);
        vm.stopPrank();
        // hourly pokes for 26 h with the USDT feed not updated again
        for (uint256 k = 1; k <= 26; ++k) {
            _tick(3_600);
            _freshUsdc();
            assertTrue(_poke());
        }
        uint256 s = _stored();
        console2.log("dip -50 %: stored in bp of the true leg after 26 hourly pokes:", s * 10_000 / s0);
        assertLt(s * 10_000 / s0, 8_500); // 0.5 x 1.67 = 0.837
        _tick(1);
        _freshUsdc();
        assertTrue(_usingFallback());
        (uint256 liq, uint256 sf) = lender.liquidity(LEDGER);
        liq;
        assertGt(sf, 0, "LTV 45 % opened at live prices is liquidatable on the trapped fallback price");
        uint256 repay = borrowAmt / 2;
        usdc.mint(address(this), repay);
        usdc.approve(address(lender), repay);
        (uint256 seized,) = lender.liquidate(LEDGER, repay);
        // true value of the seized shares: the vault itself is unchanged by the glitch: 1 share = s0 / 1e6 USDC
        uint256 trueValue = seized * s0 / 1e6;
        console2.log("repaid / true value seized (USDC-6) -> liquidator bonus at true prices (bp):", repay);
        console2.log(trueValue, trueValue * 10_000 / repay);
        assertGt(trueValue * 10_000 / repay, 12_500, "bonus far above the 8 % incentive: the trap is a transfer from borrower to liquidator, not a lender loss");
        // it costs the lender nothing: collateral left covers the remaining debt many times over
        assertGt(lender.collateral(LEDGER) * s0 / 1e6, lender.debt(LEDGER) * 2);
        // a 25 % dip is repaired by the ladder long before the feed can go stale: no overlap
        assertEq(_hoursToClimb(s0 * 7_500 / 10_000, s0), 15);
        assertLt(_hoursToClimb(s0 * 7_500 / 10_000, s0), 26);
        // the critical dip: 1 / 1.02^26
        uint256 x = 1_000_000_000;
        for (uint256 k; k < 26; ++k) x = x * 10_200 / 10_000;
        console2.log("1.02^26 (x1e9):", x);
        assertApproxEqAbs(x, 1_673_418_000, 400_000);
    }

    function test_C3_poke_timing_attacker_controlled_downward_push_is_basis_points() public {
        // can an attacker push the NAV DOWN transiently and poke at the dip? Both swap directions, with the USDT feed at par and 10 bp off the pool in both signs (the live standing offset)
        int256[3] memory marks = [int256(1e8), int256(1e8 + 1e5), int256(1e8 - 1e5)];
        uint256 worst = 10_000;
        for (uint256 m; m < 3; ++m) {
            feedUsdt.setAnswer(marks[m]);
            uint256 base = _live();
            for (uint256 dir; dir < 2; ++dir) {
                uint256 snap = vm.snapshotState();
                if (dir == 0) this.pushUsdtIn();
                else this.pushUsdcIn();
                uint256 l = _live();
                _poke(); // a downward store is allowed at once
                uint256 st = _stored();
                uint256 low = l < st ? l : st;
                if (low * 10_000 / base < worst) worst = low * 10_000 / base;
                this._swapBackAll();
                vm.revertToState(snap);
            }
        }
        console2.log("lowest stored/live leg a push can lock in, bp of the unpushed leg (feed at par, +10 bp, -10 bp):", worst);
        assertGe(worst, 10_000 - 10, "basis points only");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {DlmmForkBase, IERC20, IPharaohDlmmVault, PharaohDlmmVault, IDLMMPair, IDLMMRewarder, IChainlinkFeed, console2} from "./DlmmForkBase.sol";

// =====================================================================================================================================================
// W6 mainnet-fork tests of PharaohDlmmVault: real pair 0x1688...255C, real DLMMRouter, real rewarder hook, real Chainlink USDC/USD and USDT/USD feeds.
// Groups (run one with --match-contract): DlmmForkDepeg (5), DlmmForkExit (6), DlmmForkHook (7), DlmmForkInit (1), DlmmForkHappy (2 + 8), DlmmForkHarvest (3),
// DlmmForkRebalance (4). Gate: DLMM_FORK_BLOCK (see run-locked.sh / RUN.md). Labels in logs: MEASURED = read on the fork at the pinned block.
// =====================================================================================================================================================

// -----------------------------------------------------------------------------------------------------------------------------------------------------
// (5) DEPEG: per leg, both directions, gradual path, feed failures, latch lifecycle
// -----------------------------------------------------------------------------------------------------------------------------------------------------
contract DlmmForkDepeg is DlmmForkBase {
    function _expectUnsafe(uint256 r) internal {
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardUnsafe.selector, r));
    }

    function _entryBlocked(bytes memory err) internal {
        vm.expectRevert(err);
        vm.prank(BOB);
        v.deposit(10e6, BOB);
        vm.expectRevert(err);
        vm.prank(BOB);
        v.mint(10e6, BOB);
    }

    /// Full lifecycle for one leg and one level. legBit = the leg's bit (4 asset / 8 pair), otherLeg the other one.
    function _lifecycle(address feed, int256 ans, uint256 legBit, uint256 otherLeg) internal {
        _unpause();
        _deposit(ALICE, 100e6);
        _approveBob(50e6);

        // ---- 1. no band yet: depeg -> openBand, deposit, mint blocked with GuardUnsafe(reasons)
        _mockFeed(feed, ans, _ts());
        (bool unsafe, bool latched, uint256 r) = v.guardState();
        console2.log("reasons at the depeg level (4/8 leg bit, 16 pool-vs-oracle may join):", r);
        assertTrue(unsafe, "unsafe");
        assertFalse(latched, "not latched yet");
        assertTrue(r & legBit != 0, "leg bit set");
        assertTrue(r & (otherLeg | 1 | 2 | 32) == 0, "no other leg / feed / rewarder bit");
        assertEq(v.maxDeposit(BOB), 0, "maxDeposit 0");
        assertEq(v.maxMint(BOB), 0, "maxMint 0");
        _entryBlocked(abi.encodeWithSelector(IPharaohDlmmVault.GuardUnsafe.selector, r));
        uint24 a = pair.getActiveId();
        _expectUnsafe(r);
        vm.prank(KEEPER);
        v.openBand(a, 0, 0, 0, 0, _ts() + 600);

        // ---- 2. anyone may latch; event carries only latchable bits
        vm.expectEmit(true, false, false, true, address(v));
        emit IPharaohDlmmVault.GuardTripped(BOB, r & 15);
        vm.prank(BOB);
        v.tripGuard();
        (, latched,) = v.guardState();
        assertTrue(latched, "latched");

        // ---- 3. price recovers: live state safe, latch persists, entries still blocked, rebalanceAllowed says latched
        _freshFeeds();
        (unsafe, latched, r) = v.guardState();
        assertFalse(unsafe, "live state safe after recovery");
        assertEq(r, 0);
        assertTrue(latched, "latch persists after the price recovers");
        _entryBlocked(abi.encodeWithSelector(IPharaohDlmmVault.GuardLatched.selector));
        a = pair.getActiveId();
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardLatched.selector));
        vm.prank(KEEPER);
        v.openBand(a, 0, 0, 0, 0, _ts() + 600);
        (, uint256 rb,) = v.rebalanceAllowed();
        assertTrue(rb & 1024 != 0, "rebalanceAllowed: latched bit");

        // ---- 4. clearGuard: only the owner, and only when the live state is safe
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, BOB));
        vm.prank(BOB);
        v.clearGuard();
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, KEEPER));
        vm.prank(KEEPER);
        v.clearGuard();
        _mockFeed(feed, ans, _ts()); // depeg again
        uint256 r2 = _reasons();
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardStillUnsafe.selector, r2));
        vm.prank(SAFE);
        v.clearGuard();
        _freshFeeds();
        vm.expectEmit(true, false, false, true, address(v));
        emit IPharaohDlmmVault.GuardCleared(SAFE);
        vm.prank(SAFE);
        v.clearGuard();
        (unsafe, latched,) = v.guardState();
        assertFalse(latched, "cleared");

        // ---- 5. back to normal: deposit and openBand work
        vm.prank(BOB);
        v.deposit(10e6, BOB);
        _openBand();
        (uint24 lo, uint24 hi,, bool hasBand,) = v.bandState();
        assertTrue(hasBand);

        // ---- 6. band out of range (vault holds one token), depeg: rebalance blocked, latch, recover, still blocked, clear, rebalance works
        _pushUp(hi + 1);
        (,,,, bool oor) = v.bandState();
        assertTrue(oor, "out of range");
        uint256 half = v.totalAssets() / 2;
        _mockFeed(feed, ans, _ts());
        r = _reasons();
        assertTrue(r & legBit != 0);
        a = pair.getActiveId();
        _expectUnsafe(r);
        vm.prank(KEEPER);
        v.rebalance(a, 0, false, half, 0, 0, 0, _ts() + 600);
        vm.prank(BOB);
        v.tripGuard();
        _freshFeeds();
        a = pair.getActiveId();
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardLatched.selector));
        vm.prank(KEEPER);
        v.rebalance(a, 0, false, half, 0, 0, 0, _ts() + 600);
        vm.prank(SAFE);
        v.clearGuard();
        _rebalance(false, half);
        (,,,, oor) = v.bandState();
        assertFalse(oor, "re-centred after the owner cleared the latch");
        lo; // silence
    }

    function test_depeg_usdcLeg_098() public { _lifecycle(FEED_USDC, 98_000_000, B_LEG_A, B_LEG_P); }
    function test_depeg_usdcLeg_102() public { _lifecycle(FEED_USDC, 102_000_000, B_LEG_A, B_LEG_P); }
    function test_depeg_usdtLeg_098() public { _lifecycle(FEED_USDT, 98_000_000, B_LEG_P, B_LEG_A); }
    function test_depeg_usdtLeg_102() public { _lifecycle(FEED_USDT, 102_000_000, B_LEG_P, B_LEG_A); }

    // ---------------------------------------------------------------- gradual path through the band: exact flip points
    function _gradual(address feed, uint256 bit, uint256 otherBit, int256[] memory path) internal {
        for (uint256 i; i < path.length; ++i) {
            int256 ans = path[i];
            _mockFeed(feed, ans, _ts());
            uint256 r = _reasons();
            int256 d = ans > 1e8 ? ans - 1e8 : 1e8 - ans;
            bool expectBit = uint256(d) * 10_000 > 50 * 1e8; // legBandBps 50: strictly more than 0.50 % off
            assertEq(r & bit != 0, expectBit, "leg bit flips exactly beyond 50 bps");
            assertEq(r & otherBit, 0, "other leg bit untouched");
            assertEq(r & (1 | 2), 0, "a valid in-time feed never sets the feed bits");
            console2.log("answer / reasons", uint256(ans), r);
            if (r == 0) {
                // entry open at this price: a 1 USDC deposit passes (idle USDC, no pair call)
                uint256 before = v.totalAssets();
                vm.prank(ALICE);
                v.deposit(1e6, ALICE);
                assertEq(v.totalAssets(), before + 1e6);
            } else {
                vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardUnsafe.selector, r));
                vm.prank(ALICE);
                v.deposit(1e6, ALICE);
            }
        }
        _freshFeeds();
    }

    function test_depeg_gradualPath_bitsFlipAtTheBoundary() public {
        _unpause();
        _deposit(ALICE, 20e6);
        vm.prank(ALICE);
        IERC20(USDC).approve(address(v), type(uint256).max);
        _fund(ALICE, USDC, 100e6);
        int256[] memory down = new int256[](7);
        down[0] = 99_990_000; down[1] = 99_900_000; down[2] = 99_700_000; down[3] = 99_500_000; down[4] = 99_499_999; down[5] = 99_000_000; down[6] = 98_000_000;
        int256[] memory up = new int256[](7);
        up[0] = 100_010_000; up[1] = 100_100_000; up[2] = 100_300_000; up[3] = 100_500_000; up[4] = 100_500_001; up[5] = 101_000_000; up[6] = 102_000_000;
        _gradual(FEED_USDC, B_LEG_A, B_LEG_P, down);
        _gradual(FEED_USDC, B_LEG_A, B_LEG_P, up);
        _gradual(FEED_USDT, B_LEG_P, B_LEG_A, down);
        _gradual(FEED_USDT, B_LEG_P, B_LEG_A, up);
        // tighten the band to its hard minimum (10 bps): the flip moves with it
        GP memory gp = _gp();
        gp.legBandBps = 10;
        vm.prank(SAFE);
        v.setGuardParams(_toIface(gp));
        _mockFeed(FEED_USDC, 99_900_000, _ts());
        assertEq(_reasons() & B_LEG_A, 0, "exactly 10 bps is inside");
        _mockFeed(FEED_USDC, 99_899_999, _ts());
        assertTrue(_reasons() & B_LEG_A != 0, "10 bps + 1 is outside");
    }

    struct GP { uint16 a; uint32 b; uint16 c; uint32 d; uint16 e; uint16 f; uint16 g; uint16 legBandBps; }

    function _gp() internal view returns (GP memory g) {
        IPharaohDlmmVault.GuardParams memory p = v.guardParams();
        g.legBandBps = p.legBandBps;
        g.a = p.maxPoolOracleDevBps; g.b = p.maxFeedAge; g.c = p.maxRebalancesPerDay; g.d = p.rebalanceCooldown; g.e = p.maxSwapBps; g.f = p.maxRebalanceLossBps;
    }

    function _toIface(GP memory g) internal pure returns (IPharaohDlmmVault.GuardParams memory p) {
        p = IPharaohDlmmVault.GuardParams({
            legBandBps: g.legBandBps, maxFeedAge: g.b, maxPoolOracleDevBps: g.a, rebalanceCooldown: g.d, maxRebalancesPerDay: g.c, maxSwapBps: g.e, maxRebalanceLossBps: g.f
        });
    }

    // ---------------------------------------------------------------- bit 16 (pool vs oracle ratio): live only, never latched
    function test_depeg_bit16_oracleRatioOffPool_liveOnly() public {
        _unpause();
        _deposit(ALICE, 20e6);
        _approveBob(20e6);
        // both legs inside their 50 bp band, ratio off by ~80 bp: only bit 16
        _mockFeed(FEED_USDC, 100_400_000, _ts());
        _mockFeed(FEED_USDT, 99_550_000, _ts());
        uint256 r = _reasons();
        assertEq(r, B_POOL, "only bit 16");
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardUnsafe.selector, B_POOL));
        vm.prank(BOB);
        v.deposit(1e6, BOB);
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardUnsafe.selector, 0)); // nothing latchable holds
        vm.prank(BOB);
        v.tripGuard();
        _freshFeeds();
        assertEq(_reasons(), 0);
        vm.prank(BOB);
        v.deposit(1e6, BOB); // works again at once: no latch
    }

    /// a real swap flow (deal-funded, through the real router, with extra USDt depth seeded above) moves the pool's active price past 60 bp
    function test_depeg_bit16_realSwapsMovePoolPrice() public {
        _unpause();
        _deposit(ALICE, 20e6);
        _seedDepth(false, 21, 90, 2_000_000e6);
        uint24 a0 = pair.getActiveId();
        _pushUpBig(a0 + 70, 50_000e6);
        uint256 r = _reasons();
        console2.log("active id moved by", pair.getActiveId() - a0);
        console2.log("reasons after a real ~70-bin move (pool/oracle deviation)", r);
        assertEq(r, B_POOL, "bit 16 from the pool price alone, no latch possible");
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardUnsafe.selector, 0));
        v.tripGuard();
    }

    // ---------------------------------------------------------------- feed failures: stale (> 93,600 s), reverting, zero, negative, incomplete round, future timestamp
    function _failMode(address feed, uint256 mode) internal {
        uint256 t = _ts();
        if (mode == 0) _mockFeed(feed, 1e8, t - 93_601);
        else if (mode == 1) _mockFeedReverts(feed);
        else if (mode == 2) _mockFeed(feed, 0, t);
        else if (mode == 3) _mockFeed(feed, -1e8, t);
        else if (mode == 4) _mockFeedFull(feed, 1000, 1e8, t, 999);
        else if (mode == 5) _mockFeed(feed, 1e8, 0);
        else if (mode == 6) _mockFeed(feed, 1e8, t - 93_600); // exactly maxFeedAge: still fresh
        else if (mode == 7) _mockFeed(feed, 1e8, t + 1 days); // future updatedAt
    }

    function test_feedFailureModes_bothFeeds() public {
        _unpause();
        _deposit(ALICE, 20e6);
        _approveBob(10e6);
        address[2] memory feeds = [FEED_USDC, FEED_USDT];
        string[8] memory names = ["stale 93601s", "reverting", "answer 0", "answer -1", "incomplete round", "updatedAt 0", "age == maxFeedAge", "future updatedAt"];
        bool[8] memory bad = [true, true, true, true, true, true, false, false];
        for (uint256 f; f < 2; ++f) {
            uint256 bit = f == 0 ? B_FEED_A : B_FEED_P;
            for (uint256 m; m < 8; ++m) {
                _freshFeeds();
                _failMode(feeds[f], m);
                (bool unsafe, bool latched, uint256 r) = v.guardState();
                console2.log(names[m], r);
                assertEq(r, bad[m] ? bit : 0, "reasons: exactly the feed bit (no leg bit, no bit 16) / zero");
                assertEq(unsafe, bad[m]);
                assertFalse(latched);
                (bool ok,) = address(v).staticcall(abi.encodeCall(v.rebalanceAllowed, ()));
                assertTrue(ok, "rebalanceAllowed never reverts");
                (ok,) = address(v).staticcall(abi.encodeCall(v.bandState, ()));
                assertTrue(ok, "bandState never reverts");
                if (bad[m]) {
                    assertEq(v.maxDeposit(BOB), 0);
                    vm.expectRevert(abi.encodeWithSelector(PharaohDlmmVault.FeedInvalid.selector, uint8(f + 1)));
                    v.totalAssets();
                    vm.expectRevert(abi.encodeWithSelector(PharaohDlmmVault.FeedInvalid.selector, uint8(f + 1)));
                    v.convertToAssets(1e6);
                    vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardUnsafe.selector, bit));
                    vm.prank(BOB);
                    v.deposit(1e6, BOB);
                    vm.expectEmit(true, false, false, true, address(v));
                    emit IPharaohDlmmVault.GuardTripped(BOB, bit);
                    vm.prank(BOB);
                    v.tripGuard();
                    (, latched,) = v.guardState();
                    assertTrue(latched);
                    _freshFeeds();
                    vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardLatched.selector));
                    vm.prank(BOB);
                    v.deposit(1e6, BOB);
                    vm.prank(SAFE);
                    v.clearGuard();
                } else {
                    v.totalAssets(); // fresh: reads fine
                    vm.prank(BOB);
                    v.deposit(1e6, BOB);
                }
            }
        }
    }

    /// While a feed is bad the owner cannot clear the latch either (the live state is not safe), and exits are untouched (see DlmmForkExit).
    function test_feedBad_ownerCannotClear() public {
        _unpause();
        _deposit(ALICE, 20e6);
        _mockFeedReverts(FEED_USDT);
        v.tripGuard();
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardStillUnsafe.selector, B_FEED_P));
        vm.prank(SAFE);
        v.clearGuard();
    }

    /// the 30 Oct lesson of the spec: a pool move alone must not be able to latch the guard
    function test_poolMoveAloneCannotLatch() public {
        _unpause();
        _deposit(ALICE, 20e6);
        _seedDepth(false, 21, 90, 2_000_000e6);
        _pushUpBig(pair.getActiveId() + 70, 50_000e6);
        assertTrue(_reasons() & B_POOL != 0);
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardUnsafe.selector, 0));
        v.tripGuard();
        (, bool latched,) = v.guardState();
        assertFalse(latched);
    }
}

// -----------------------------------------------------------------------------------------------------------------------------------------------------
// (6) EXITS under each condition
// -----------------------------------------------------------------------------------------------------------------------------------------------------
contract DlmmForkExit is DlmmForkBase {
    uint256 internal aliceSh;
    uint256 internal bobSh;
    uint256 internal nav0;

    function _state() internal {
        _unpause();
        aliceSh = _deposit(ALICE, 100e6);
        bobSh = _deposit(BOB, 50e6);
        _openBand();
        nav0 = v.totalAssets();
    }

    function _inKind(address who, uint256 shares) internal returns (uint256 x, uint256 y) {
        vm.prank(who);
        (x, y) = v.redeemInKind(shares, who, who);
    }

    // ---------------------------------------------------------------- latched guard under each depeg
    function _latchedExit(address feed, int256 ans, bool expectRedeemOk) internal {
        _state();
        _mockFeed(feed, ans, _ts());
        v.tripGuard();
        (, bool latched, uint256 r) = v.guardState();
        assertTrue(latched);
        console2.log("latched, live reasons", r);
        // the feed is STILL depegged: in-kind pays, no oracle read
        uint256 sh = 10e6;
        uint256 supply = v.totalSupply();
        uint256 expect_ = nav0 * sh / supply;
        (uint256 x, uint256 y) = _inKind(ALICE, sh);
        console2.log("inKind USDt / USDC paid", x, y);
        assertTrue(x > 0 && y > 0, "both legs paid (band in range)");
        assertApproxEqRel(x + y, expect_, 3e15);
        // redeem / withdraw (USDC out) while the feed is depegged: actual behaviour
        (bool ok, bytes memory ret) = _try(BOB, address(v), abi.encodeCall(v.redeem, (10e6, BOB, BOB)));
        console2.log("redeem under depeg, ok:", ok);
        if (!ok) console2.logBytes4(_sel(ret));
        assertEq(ok, expectRedeemOk, "redeem under the depeg: oracle minimum vs pool price");
        (ok, ret) = _try(BOB, address(v), abi.encodeCall(v.withdraw, (5e6, BOB, BOB)));
        console2.log("withdraw under depeg, ok:", ok);
        assertEq(ok, expectRedeemOk);
        // price recovers, latch stays: redeem and withdraw work (not gated by the latch), in-kind too
        _freshFeeds();
        (, latched,) = v.guardState();
        assertTrue(latched);
        vm.prank(BOB);
        uint256 got = v.redeem(10e6, BOB, BOB);
        console2.log("redeem with the latch only, paid", got);
        assertApproxEqRel(got, 10e6, 3e15);
        vm.prank(BOB);
        v.withdraw(5e6, BOB, BOB);
        _inKind(ALICE, 10e6);
    }

    // oracle-implied value of USDt in USDC = pp/pa; redeem's swap min is that x (1 - 50 bp) while the pool pays ~par: it reverts when the oracle says USDt is worth > 1.005 USDC
    function test_exit_latched_usdcLeg_098() public { _latchedExit(FEED_USDC, 98_000_000, false); }
    function test_exit_latched_usdcLeg_102() public { _latchedExit(FEED_USDC, 102_000_000, true); }
    function test_exit_latched_usdtLeg_098() public { _latchedExit(FEED_USDT, 98_000_000, true); }
    function test_exit_latched_usdtLeg_102() public { _latchedExit(FEED_USDT, 102_000_000, false); }

    // ---------------------------------------------------------------- pause
    function test_exit_pausedVault() public {
        _state();
        vm.prank(SAFE);
        v.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(BOB);
        v.deposit(1e6, BOB);
        uint256 expect_ = nav0 * 20e6 / v.totalSupply();
        (uint256 x, uint256 y) = _inKind(ALICE, 20e6);
        assertApproxEqRel(x + y, expect_, 3e15);
        vm.prank(BOB);
        uint256 got = v.redeem(10e6, BOB, BOB);
        assertApproxEqRel(got, 10e6, 3e15);
        vm.prank(BOB);
        v.withdraw(5e6, BOB, BOB);
    }

    // ---------------------------------------------------------------- reverting / stale feed: in-kind pays, USDC-out exits revert FeedInvalid (documented)
    function _feedDown(address feed, uint8 which, uint256 mode) internal {
        _state();
        if (mode == 0) _mockFeedReverts(feed);
        else if (mode == 1) _mockFeed(feed, 1e8, _ts() - 93_601);
        else _mockFeed(feed, 0, _ts());
        uint256 supply = v.totalSupply();
        (uint256 x, uint256 y) = _inKind(ALICE, 10e6);
        assertTrue(x > 0 && y > 0);
        assertApproxEqRel(x + y, nav0 * 10e6 / supply, 3e15);
        bytes memory fi = abi.encodeWithSelector(PharaohDlmmVault.FeedInvalid.selector, which);
        vm.expectRevert(fi);
        vm.prank(BOB);
        v.redeem(10e6, BOB, BOB);
        vm.expectRevert(fi);
        vm.prank(BOB);
        v.withdraw(5e6, BOB, BOB);
        vm.expectRevert(fi);
        v.previewRedeem(1e6);
        vm.expectRevert(fi);
        v.maxWithdraw(BOB);
        // with the guard tripped AND paused on top: still pays in kind
        v.tripGuard();
        vm.prank(SAFE);
        v.pause();
        (x, y) = _inKind(ALICE, 10e6);
        assertTrue(x > 0 && y > 0);
        // feed recovers: redeem works again
        _freshFeeds();
        vm.prank(BOB);
        v.redeem(10e6, BOB, BOB);
    }

    function test_exit_feedReverts_usdc() public { _feedDown(FEED_USDC, 1, 0); }
    function test_exit_feedReverts_usdt() public { _feedDown(FEED_USDT, 2, 0); }
    function test_exit_feedStale_usdc() public { _feedDown(FEED_USDC, 1, 1); }
    function test_exit_feedStale_usdt() public { _feedDown(FEED_USDT, 2, 1); }
    function test_exit_feedZero_usdt() public { _feedDown(FEED_USDT, 2, 2); }

    /// the LAST holders leave completely in kind with everything against them (latched, paused, both feeds reverting)
    function test_exit_everyoneLeavesInKind_allGatesClosed() public {
        _state();
        _mockFeedReverts(FEED_USDC);
        _mockFeedReverts(FEED_USDT);
        v.tripGuard();
        vm.prank(SAFE);
        v.pause();
        (uint256 ax, uint256 ay) = _inKind(ALICE, aliceSh);
        (uint256 bx, uint256 by) = _inKind(BOB, bobSh);
        console2.log("ALICE USDt / USDC", ax, ay);
        console2.log("BOB   USDt / USDC", bx, by);
        assertEq(v.totalSupply(), 0, "supply 0");
        assertApproxEqAbs(ax + ay + bx + by, nav0, 3e6, "everything came out (rounding + a little fee income only)");
        console2.log("vault USDC left", _bal(USDC, address(v)));
        console2.log("vault USDt left", _bal(USDT, address(v)));
        for (uint24 id = pinActiveId - 2; id <= pinActiveId + 2; ++id) assertEq(pair.balanceOf(address(v), id), 0, "no LB shares left");
        (,,, bool hasBand,) = v.bandState();
        assertFalse(hasBand, "band cleared on a full exit");
    }

    // ---------------------------------------------------------------- 100 % in one asset (natural: the active id leaves the band)
    function test_exit_100pct_usdt_activeBelowBand() public {
        _state();
        (uint24 lo,,,,) = v.bandState();
        _pushDown(lo - 1);
        (,,,, bool oor) = v.bandState();
        assertTrue(oor);
        // oracle at its live values, guard calm (a 2-bin move does not trip anything)
        uint256 supply = v.totalSupply();
        uint256 navNow = v.totalAssets();
        console2.log("NAV now / at open (vault holds only USDt)", navNow, nav0);
        (uint256 x, uint256 y) = _inKind(ALICE, 10e6);
        console2.log("in kind USDt / USDC", x, y);
        assertEq(y, 0, "no USDC left");
        assertTrue(x > 0);
        assertApproxEqRel(x, navNow * 10e6 / supply, 3e15);
        uint256 prev = v.previewRedeem(10e6);
        vm.prank(BOB);
        uint256 got = v.redeem(10e6, BOB, BOB);
        console2.log("redeem preview / paid (all USDt sold through the pool)", prev, got);
        assertGt(got, 0);
        // with the pool dumped by a depeg the oracle floor bites: latch + oracle 0.98 -> USDC-out reverts, in kind still pays
        _mockFeed(FEED_USDT, 98_000_000, _ts());
        v.tripGuard();
        (x, y) = _inKind(ALICE, 10e6);
        assertTrue(x > 0 && y == 0);
    }

    function test_exit_100pct_usdc_activeAboveBand() public {
        _state();
        (, uint24 hi,,,) = v.bandState();
        _pushUp(hi + 1);
        uint256 supply = v.totalSupply();
        uint256 navNow = v.totalAssets();
        console2.log("NAV now / at open (vault holds only USDC)", navNow, nav0);
        (uint256 x, uint256 y) = _inKind(ALICE, 10e6);
        console2.log("in kind USDt / USDC", x, y);
        assertEq(x, 0, "no USDt left");
        assertApproxEqRel(y, navNow * 10e6 / supply, 3e15);
        vm.prank(BOB);
        uint256 got = v.redeem(10e6, BOB, BOB);
        assertApproxEqRel(got, navNow * 10e6 / supply, 3e15);
        console2.log("redeem paid (no swap needed)", got);
        _mockFeed(FEED_USDC, 98_000_000, _ts());
        v.tripGuard();
        vm.prank(BOB);
        got = v.redeem(10e6, BOB, BOB); // all USDC, no swap: nothing for the oracle to veto
        console2.log("redeem with the USDC feed at 0.98, paid", got);
        (x, y) = _inKind(ALICE, 10e6);
        assertEq(x, 0);
    }

    // ---------------------------------------------------------------- 100 % in one asset, REAL deep depeg of the pool price (deal-funded LP adds depth, deal-funded trader dumps)
    function _deepDown() internal returns (uint24 a0) {
        _state();
        a0 = pair.getActiveId();
        _seedDepth(true, 21, 120, 4_000_000e6);
        _pushDownBig(a0 - 100, 300_000e6);
        console2.log("USDt dumped: active id moved down by", a0 - pair.getActiveId());
    }

    function test_exit_deepUsdtDepeg_oracleFollows() public {
        _deepDown();
        _mockFeed(FEED_USDT, 99_000_000, _ts()); // the feed follows the pool (~0.99)
        v.tripGuard();
        (uint256 x, uint256 y) = _inKind(ALICE, 10e6);
        console2.log("in kind USDt / USDC (100 % in the depegged USDt)", x, y);
        assertEq(y, 0);
        assertTrue(x > 0);
        vm.prank(BOB);
        uint256 got = v.redeem(10e6, BOB, BOB);
        console2.log("redeem paid in USDC for", x, got);
        assertApproxEqRel(got, x, 2e16);
        vm.prank(BOB);
        v.withdraw(5e6, BOB, BOB);
    }

    function test_exit_deepUsdtDepeg_oracleLags() public {
        _deepDown(); // feed still reads ~1.00: the oracle minimum (-50 bp) is above what the dumped pool pays
        uint256 r = _reasons();
        console2.log("reasons (pool deviates from the lagging oracle)", r);
        assertTrue(r & B_POOL != 0);
        (uint256 x, uint256 y) = _inKind(ALICE, 10e6);
        assertTrue(x > 0 && y == 0);
        vm.prank(BOB);
        (bool ok, bytes memory ret) = address(v).call(abi.encodeCall(v.redeem, (10e6, BOB, BOB)));
        console2.log("redeem with the oracle lagging the pool, ok:", ok);
        if (!ok) console2.logBytes4(_sel(ret));
        assertFalse(ok, "USDC-out redeem is vetoed by the oracle minimum while the oracle lags");
    }

    function test_exit_deepUsdcDepeg_oracleFollows() public {
        _state();
        uint24 a0 = pair.getActiveId();
        _seedDepth(false, 21, 120, 4_000_000e6);
        _pushUpBig(a0 + 100, 300_000e6);
        console2.log("USDC sold: active id moved up by", pair.getActiveId() - a0);
        _mockFeed(FEED_USDC, 99_000_000, _ts());
        v.tripGuard();
        (uint256 x, uint256 y) = _inKind(ALICE, 10e6);
        console2.log("in kind USDt / USDC (100 % in the depegged USDC)", x, y);
        assertEq(x, 0);
        assertTrue(y > 0);
        vm.prank(BOB);
        uint256 got = v.redeem(10e6, BOB, BOB);
        console2.log("redeem paid", got);
        assertApproxEqRel(got, y, 3e15);
    }

    // ---------------------------------------------------------------- dust: 1, 2, ... wei of shares
    function test_dust_redeemInKind_and_redeem_thresholds() public {
        _state();
        uint256[20] memory ss = [uint256(1), 2, 3, 4, 5, 6, 8, 10, 16, 32, 64, 100, 128, 256, 512, 1000, 5000, 10_000, 100_000, 1e6];
        uint256 firstKind;
        uint256 firstRedeem;
        for (uint256 i; i < ss.length; ++i) {
            uint256 snap = vm.snapshotState();
            (bool okK, bytes memory rK) = _try(ALICE, address(v), abi.encodeCall(v.redeemInKind, (ss[i], ALICE, ALICE)));
            uint256 gotK = okK ? _bal(USDC, ALICE) + _bal(USDT, ALICE) : 0;
            vm.revertToState(snap);
            snap = vm.snapshotState();
            (bool okR, bytes memory rR) = _try(ALICE, address(v), abi.encodeCall(v.redeem, (ss[i], ALICE, ALICE)));
            uint256 gotR = okR ? _bal(USDC, ALICE) : 0;
            vm.revertToState(snap);
            console2.log("shares", ss[i]);
            console2.log("  redeemInKind ok / raw paid", okK, gotK);
            if (!okK) console2.logBytes4(_sel(rK));
            console2.log("  redeem ok / USDC paid", okR, gotR);
            if (!okR) console2.logBytes4(_sel(rR));
            if (okK && firstKind == 0) firstKind = ss[i];
            if (okR && firstRedeem == 0) firstRedeem = ss[i];
        }
        console2.log("smallest tried share count that pays: redeemInKind", firstKind);
        console2.log("smallest tried share count that pays: redeem", firstRedeem);
        // MEASURED at the pin (the share price is ~1.0 raw per share): 1-2 shares revert ExitFailed in BOTH exits; in kind pays from 3 shares; the USDC-out exit
        // pays from 6 shares (3-5 shares: the pair's own LBPair__InsufficientAmountOut on the zero-output USDt swap). Reverts keep the shares (next test).
        assertEq(firstKind, 3, "redeemInKind: smallest paying share count among those tried");
        assertEq(firstRedeem, 6, "redeem: smallest paying share count among those tried");
    }

    /// shares are never lost on a failed exit: a revert leaves the balance untouched
    function test_dust_failedExitKeepsShares() public {
        _state();
        uint256 before = v.balanceOf(ALICE);
        (bool ok,) = _try(ALICE, address(v), abi.encodeCall(v.redeemInKind, (1, ALICE, ALICE)));
        assertFalse(ok, "1 share in kind reverts on the real pair");
        assertEq(v.balanceOf(ALICE), before);
        (ok,) = _try(ALICE, address(v), abi.encodeCall(v.redeem, (1, ALICE, ALICE)));
        assertFalse(ok, "1 share redeem reverts on the real pair");
        assertEq(v.balanceOf(ALICE), before);
        (ok,) = _try(ALICE, address(v), abi.encodeCall(v.redeem, (2, ALICE, ALICE)));
        assertFalse(ok, "2 shares redeem reverts on the real pair");
        assertEq(v.balanceOf(ALICE), before);
    }
}

// -----------------------------------------------------------------------------------------------------------------------------------------------------
// (7) FAILING HOOK on the REAL pair: what blocks, and that un-mocking restores it. This is the residual risk the operator accepts (spec section 3).
// The pair calls the rewarder (hook flags 0x151 = BEFORE_SWAP | BEFORE_MINT | BEFORE_BURN | BEFORE_TRANSFER) which in turn reads the voter
// (isAntiSybilEnabled, timeThresholdForGauge). Selectors MEASURED from a -vvvv trace of a real burn at the pin.
// -----------------------------------------------------------------------------------------------------------------------------------------------------
contract NoopHookImpl {
    /// a beacon "upgrade" to code that answers every call with its own selector (what a hook returns) and does nothing
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, calldataload(0))
            return(0, 32)
        }
    }
}

contract RevertingHookImpl {
    fallback() external {
        revert("broken implementation");
    }
}

contract DlmmForkHook is DlmmForkBase {
    bytes4 internal constant BEFORE_BURN = 0xea9db9d3; // beforeBurn(address,address,address,uint256[],uint256[])
    bytes4 internal constant BEFORE_SWAP = 0xfeee3735; // beforeSwap(address,address,bool,bytes32)
    bytes4 internal beforeMintSel;

    uint256 internal aliceSh;
    uint256 internal bobSh;

    function setUp() public override {
        super.setUp();
        beforeMintSel = bytes4(keccak256("beforeMint(address,address,bytes32[],bytes32)"));
    }

    function _state() internal {
        _unpause();
        aliceSh = _deposit(ALICE, 100e6);
        bobSh = _deposit(BOB, 50e6);
        _openBand();
    }

    // external wrappers so that a revert can be caught
    function seedExt(bool below) external { _seedDepth(below, 1, 1, 1_000e6); }
    function swapExt(address a, address b, uint256 n) external { _swap(a, b, n); }

    struct Row { bool burnInKind; bool redeemUsdc; bool swap; bool addLiq; bool deposit; }

    /// one tiny attempt of each operation; no snapshots (mocks live outside the EVM state)
    function _matrix(string memory label) internal returns (Row memory r) {
        _fund(BOB, USDC, _bal(USDC, BOB) + 1e6);
        (r.burnInKind,) = _try(ALICE, address(v), abi.encodeCall(v.redeemInKind, (1e6, ALICE, ALICE)));
        (r.redeemUsdc,) = _try(BOB, address(v), abi.encodeCall(v.redeem, (1e6, BOB, BOB)));
        try this.swapExt(USDC, USDT, 100e6) { r.swap = true; } catch {}
        try this.seedExt(true) { r.addLiq = true; } catch {}
        vm.prank(BOB);
        try v.deposit(1e6, BOB) { r.deposit = true; } catch {}
        console2.log(label);
        console2.log("  redeemInKind / redeem(USDC) / pool swap / addLiquidity / vault deposit:");
        console2.log(r.burnInKind, r.redeemUsdc, r.swap);
        console2.log(r.addLiq, r.deposit);
    }

    function test_hook_baseline_everythingWorks() public {
        _state();
        Row memory r = _matrix("baseline (no mock)");
        assertTrue(r.burnInKind && r.redeemUsdc && r.swap && r.addLiq && r.deposit);
    }

    /// the hook's beforeBurn reverts: EVERY burn reverts, hence redeemInKind, redeem, withdraw and rebalance. Deposits keep being accepted (the guard does not see it).
    function test_hook_beforeBurnReverts_blocksEveryExit_unmockRestores() public {
        _state();
        vm.mockCallRevert(REWARDER, abi.encodeWithSelector(BEFORE_BURN), "hook: revert");
        // the guard does not detect it
        (bool unsafe, bool latched, uint256 reasons) = v.guardState();
        console2.log("guard reasons with a reverting beforeBurn (bit 32 reads linkage + codehash only):", reasons);
        assertFalse(unsafe);
        assertFalse(latched);
        Row memory r = _matrix("beforeBurn reverts");
        assertFalse(r.burnInKind, "redeemInKind blocked");
        assertFalse(r.redeemUsdc, "redeem blocked");
        assertTrue(r.swap, "pool swaps still work");
        assertTrue(r.addLiq, "minting still works");
        assertTrue(r.deposit, "UNFAVOURABLE: deposits are still accepted while every exit is blocked (guard bit 32 does not read the hook's behaviour)");
        (bool ok, bytes memory ret) = _try(ALICE, address(v), abi.encodeCall(v.redeemInKind, (10e6, ALICE, ALICE)));
        assertFalse(ok);
        console2.log("redeemInKind revert data (the hook's own revert, bubbled):");
        console2.logBytes(ret);
        (ok,) = _try(BOB, address(v), abi.encodeCall(v.withdraw, (5e6, BOB, BOB)));
        assertFalse(ok, "withdraw blocked");
        // paused or not, owner or not: nothing the vault can do. The owner can only pause.
        vm.prank(SAFE);
        v.pause();
        (ok,) = _try(ALICE, address(v), abi.encodeCall(v.redeemInKind, (10e6, ALICE, ALICE)));
        assertFalse(ok);
        // rebalance (burn) is blocked as well
        vm.prank(SAFE);
        v.unpause();
        (, uint24 hi,,,) = v.bandState();
        vm.clearMockedCalls();
        _pushUp(hi + 1);
        vm.mockCallRevert(REWARDER, abi.encodeWithSelector(BEFORE_BURN), "hook: revert");
        uint24 a = pair.getActiveId();
        uint256 half = v.totalAssets() / 2;
        (ok,) = _try(KEEPER, address(v), abi.encodeCall(v.rebalance, (a, 0, false, half, 0, 0, 0, _ts() + 600)));
        assertFalse(ok, "rebalance blocked (it burns the band first)");
        // harvest only claims: unaffected
        (ok,) = _try(KEEPER, address(v), abi.encodeCall(v.harvestRewards, ()));
        console2.log("harvestRewards under a reverting beforeBurn, ok:", ok);

        // ---- un-mock: everything is restored
        vm.clearMockedCalls();
        vm.prank(ALICE);
        (uint256 x, uint256 y) = v.redeemInKind(10e6, ALICE, ALICE);
        assertGt(x + y, 0, "redeemInKind works again once the hook works again");
        vm.prank(BOB);
        assertGt(v.redeem(5e6, BOB, BOB), 0);
        _rebalance(false, v.totalAssets() / 2);
    }

    /// no band (idle USDC only): a failing hook does not block the exit at all (no pair burn is made)
    function test_hook_burnReverts_idleOnlyVaultStillExits() public {
        _unpause();
        aliceSh = _deposit(ALICE, 100e6);
        vm.mockCallRevert(REWARDER, abi.encodeWithSelector(BEFORE_BURN), "hook: revert");
        vm.prank(ALICE);
        (uint256 x, uint256 y) = v.redeemInKind(aliceSh, ALICE, ALICE);
        assertEq(y, 100e6, "idle USDC comes back");
        assertEq(x, 0);
    }

    /// the voter reads inside the hook: each one blocks what the real code path uses
    function test_hook_voterReadsRevert_matrix() public {
        _state();
        vm.mockCallRevert(voter, abi.encodeWithSignature("isAntiSybilEnabled()"), "voter: revert");
        Row memory r = _matrix("voter.isAntiSybilEnabled() reverts");
        // MEASURED: the hook tolerates this revert on burn and swap (the vault's exits survive); it breaks MINT (openBand / rebalance re-add)
        assertTrue(r.burnInKind && r.redeemUsdc && r.swap, "burn and swap survive a reverting isAntiSybilEnabled");
        assertFalse(r.addLiq, "mint path reads isAntiSybilEnabled and reverts");
        vm.clearMockedCalls();

        vm.mockCallRevert(voter, abi.encodeWithSignature("timeThresholdForGauge(address)", REWARDER), "voter: revert");
        r = _matrix("voter.timeThresholdForGauge(rewarder) reverts");
        assertTrue(r.burnInKind && r.redeemUsdc && r.swap && r.addLiq, "a reverting timeThresholdForGauge changes nothing (tolerated)");
        vm.clearMockedCalls();
        r = _matrix("after un-mocking");
        assertTrue(r.burnInKind && r.redeemUsdc && r.swap && r.addLiq && r.deposit);
    }

    /// a reverting beforeSwap blocks the USDC-out exits and every swap, NOT the in-kind exit
    function test_hook_beforeSwapReverts_inKindStillWorks() public {
        _state();
        vm.mockCallRevert(REWARDER, abi.encodeWithSelector(BEFORE_SWAP), "hook: swap revert");
        Row memory r = _matrix("beforeSwap reverts");
        assertTrue(r.burnInKind, "redeemInKind has no swap: works");
        assertFalse(r.redeemUsdc, "redeem swaps the USDt leg: blocked");
        assertFalse(r.swap);
        assertTrue(r.addLiq);
        (bool ok,) = _try(BOB, address(v), abi.encodeCall(v.withdraw, (5e6, BOB, BOB)));
        assertFalse(ok, "withdraw blocked");
        // rebalance with a swap is blocked; with swapIn = 0 it only burns and mints and works
        (, uint24 hi,,,) = v.bandState();
        vm.clearMockedCalls();
        _pushUp(hi + 1);
        vm.mockCallRevert(REWARDER, abi.encodeWithSelector(BEFORE_SWAP), "hook: swap revert");
        uint24 a = pair.getActiveId();
        uint256 half = v.totalAssets() / 2;
        (ok,) = _try(KEEPER, address(v), abi.encodeCall(v.rebalance, (a, 0, false, half, 0, 0, 0, _ts() + 600)));
        assertFalse(ok, "rebalance with a swap blocked");
        (ok,) = _try(KEEPER, address(v), abi.encodeCall(v.rebalance, (a, 0, false, 0, 0, 0, 0, _ts() + 600)));
        console2.log("rebalance with swapIn = 0 under a reverting beforeSwap, ok:", ok);
        assertTrue(ok);
    }

    /// a reverting beforeMint blocks openBand/rebalance only; every exit works
    function test_hook_beforeMintReverts_exitsWork() public {
        _state();
        vm.mockCallRevert(REWARDER, abi.encodeWithSelector(beforeMintSel), "hook: mint revert");
        Row memory r = _matrix("beforeMint reverts");
        assertTrue(r.burnInKind && r.redeemUsdc && r.swap);
        assertFalse(r.addLiq);
        (, uint24 hi,,,) = v.bandState();
        vm.clearMockedCalls();
        _pushUp(hi + 1);
        vm.mockCallRevert(REWARDER, abi.encodeWithSelector(beforeMintSel), "hook: mint revert");
        uint24 a = pair.getActiveId();
        uint256 half = v.totalAssets() / 2;
        (bool ok,) = _try(KEEPER, address(v), abi.encodeCall(v.rebalance, (a, 0, false, half, 0, 0, 0, _ts() + 600)));
        assertFalse(ok, "rebalance blocked at its re-add (the whole tx reverts: the band is NOT left burned)");
        (,,, bool hasBand,) = v.bandState();
        assertTrue(hasBand);
        vm.prank(ALICE);
        (uint256 x, uint256 y) = v.redeemInKind(10e6, ALICE, ALICE);
        assertGt(x + y, 0);
    }

    // ---------------------------------------------------------------- bit 32 (live, never latched): unlinked, hook parameter, beacon implementation change
    function test_hook_unlinked_bit32() public {
        _state();
        vm.mockCall(REWARDER, abi.encodeCall(IDLMMRewarder.isLinked, ()), abi.encode(false));
        uint256 r = _reasons();
        assertEq(r, B_REWARDER, "only bit 32");
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardUnsafe.selector, B_REWARDER));
        vm.prank(BOB);
        v.deposit(1e6, BOB);
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardUnsafe.selector, 0)); // not latchable
        v.tripGuard();
        vm.prank(ALICE);
        (uint256 x, uint256 y) = v.redeemInKind(10e6, ALICE, ALICE);
        assertGt(x + y, 0, "exits are not gated by bit 32");
        vm.prank(BOB);
        assertGt(v.redeem(5e6, BOB, BOB), 0);
        vm.clearMockedCalls();
        assertEq(_reasons(), 0);
    }

    function test_hook_pairHookParameterChanged_bit32() public {
        _state();
        vm.mockCall(POOL, abi.encodeCall(IDLMMPair.getLBHooksParameters, ()), abi.encode(bytes32(uint256(0x151) << 160 | uint256(uint160(address(0xBAD))))));
        assertEq(_reasons(), B_REWARDER);
        vm.prank(ALICE);
        (uint256 x, uint256 y) = v.redeemInKind(10e6, ALICE, ALICE);
        assertGt(x + y, 0);
    }

    /// Pharaoh upgrades the rewarder beacon to different code: the codehash pin trips bit 32 (entries blocked). Whether the exits survive depends on the new code.
    function test_hook_beaconImplementationChanged_bit32() public {
        _state();
        address noop = address(new NoopHookImpl());
        vm.mockCall(beacon, abi.encodeCall(IDLMMRewarderBeaconView.implementation, ()), abi.encode(noop));
        assertEq(_reasons(), B_REWARDER, "codehash pin: only bit 32");
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardUnsafe.selector, B_REWARDER));
        vm.prank(BOB);
        v.deposit(1e6, BOB);
        (bool ok,) = _try(ALICE, address(v), abi.encodeCall(v.redeemInKind, (10e6, ALICE, ALICE)));
        assertTrue(ok, "a no-op implementation does not block the burn (MEASURED); only a failing one does (next test)");
    }

    /// the codehash pin DOES see an upgrade of the beacon to broken code: bit 32 stops deposits at once, but the burns are already broken (exits blocked)
    function test_hook_beaconUpgradedToBrokenCode_bit32_stopsDeposits_exitsBlocked() public {
        _state();
        address bad = address(new RevertingHookImpl());
        vm.mockCall(beacon, abi.encodeCall(IDLMMRewarderBeaconView.implementation, ()), abi.encode(bad));
        assertEq(_reasons(), B_REWARDER);
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardUnsafe.selector, B_REWARDER));
        vm.prank(BOB);
        v.deposit(1e6, BOB);
        (bool ok,) = _try(ALICE, address(v), abi.encodeCall(v.redeemInKind, (10e6, ALICE, ALICE)));
        assertFalse(ok, "every burn reverts while the beacon points at broken code");
        vm.clearMockedCalls();
        vm.prank(ALICE);
        (uint256 x, uint256 y) = v.redeemInKind(10e6, ALICE, ALICE);
        assertGt(x + y, 0, "restored");
    }

    /// governance removes the router from the voter's authorised managers: mints through the router revert at the hook; burns are direct (no router)
    function test_hook_routerDeauthorised_exitsStillWork() public {
        _state();
        vm.mockCall(voter, abi.encodeWithSignature("isAuthorizedDLMMManager(address)", ROUTER), abi.encode(false));
        assertEq(_reasons(), 0, "NOT a guard bit (spec/DEVIATIONS): the vault cannot see it");
        Row memory r = _matrix("router de-authorised");
        assertTrue(r.deposit, "entries stay open: the vault cannot see the de-authorisation");
        assertTrue(r.burnInKind, "in kind needs no router");
        assertFalse(r.addLiq, "vault re-adds would fail too: addLiquidity from the router is vetoed");
    }
}

interface IDLMMRewarderBeaconView {
    function implementation() external view returns (address);
}

// -----------------------------------------------------------------------------------------------------------------------------------------------------
// (1) initialize validation on the real addresses (all 14 checks, one negative case each)
// -----------------------------------------------------------------------------------------------------------------------------------------------------
contract DlmmForkInit is DlmmForkBase {
    /// params are built BEFORE vm.expectRevert (building them makes external calls that would consume it)
    function _initFails(uint8 n) internal {
        IPharaohDlmmVault.InitParams memory p = _params();
        _expectCheck(n);
        _deployProxy(p);
    }

    function _expectCheck(uint8 n) internal {
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.PairValidationFailed.selector, n));
    }

    function test_init_realAddresses_allChecksPass_and_state() public view {
        assertEq(v.owner(), SAFE);
        assertEq(v.rebalancer(), KEEPER);
        assertEq(v.depositCap(), 200_000_000, "cap set inside initialize");
        assertEq(v.DEPOSIT_CAP_CEILING(), 200_000_000);
        assertTrue(v.paused(), "starts paused");
        assertEq(v.asset(), USDC);
        assertEq(address(v.pairToken()), USDT);
        assertEq(address(v.tokenX()), USDT, "pair order: X = USDt");
        assertEq(address(v.tokenY()), USDC);
        assertFalse(v.assetIsX());
        assertEq(v.pair(), POOL);
        assertEq(v.router(), ROUTER);
        assertEq(v.factory(), FACTORY);
        assertEq(v.rewarder(), REWARDER);
        assertEq(v.rewarderBeacon(), beacon);
        assertEq(v.rewardToken(), PHAR);
        assertEq(v.rewarderImplCodehash(), _pinnedCodehash());
        assertEq(v.feedAsset(), FEED_USDC);
        assertEq(v.feedPair(), FEED_USDT);
        assertEq(v.binStep(), 1);
        IPharaohDlmmVault.GuardParams memory g = v.guardParams();
        assertEq(g.legBandBps, 50);
        assertEq(g.maxFeedAge, 93_600);
        assertEq(g.maxPoolOracleDevBps, 60);
        assertEq(g.rebalanceCooldown, 120);
        assertEq(g.maxRebalancesPerDay, 48);
        assertEq(g.maxSwapBps, 6000);
        assertEq(g.maxRebalanceLossBps, 50);
        (bool unsafe, bool latched, uint256 reasons) = v.guardState();
        assertFalse(unsafe);
        assertFalse(latched);
        assertEq(reasons, 0, "live guard clean on the real chain (all six bits)");
        assertEq(v.totalAssets(), 0);
        assertEq(v.maxDeposit(ALICE), 0, "paused: nothing can enter");
        assertEq(v.name(), "Peridot Pharaoh DLMM USDC/USDt");
        assertEq(v.decimals(), 6);
    }

    function test_init_check01_zeroAddress() public {
        IPharaohDlmmVault.InitParams memory p = _params();
        p.rebalancer = address(0);
        _expectCheck(1);
        _deployProxy(p);
        p = _params();
        p.rewarderImplCodehash = bytes32(0);
        _expectCheck(1);
        _deployProxy(p);
        p = _params();
        p.feedPair = address(0);
        _expectCheck(1);
        _deployProxy(p);
    }

    function test_init_check02_assetEqualsPairToken() public {
        IPharaohDlmmVault.InitParams memory p = _params();
        p.pairToken = USDC;
        _expectCheck(2);
        _deployProxy(p);
    }

    function test_init_check03_wrongBinStep() public {
        IPharaohDlmmVault.InitParams memory p = _params();
        p.binStep = 2;
        _expectCheck(3);
        _deployProxy(p);
        p.binStep = 10;
        _expectCheck(3);
        _deployProxy(p);
    }

    function test_init_check04_pairFactoryMismatch() public {
        vm.mockCall(POOL, abi.encodeCall(IDLMMPair.getFactory, ()), abi.encode(address(0xFAC)));
        _initFails(4);
    }

    function test_init_check04_pairBinStepMismatch() public {
        vm.mockCall(POOL, abi.encodeCall(IDLMMPair.getBinStep, ()), abi.encode(uint16(5)));
        _initFails(4);
    }

    function test_init_check05_pairTokensNotTheTwoLegs() public {
        vm.mockCall(POOL, abi.encodeCall(IDLMMPair.getTokenX, ()), abi.encode(address(0xDEAD)));
        _initFails(5);
    }

    function test_init_check06_routerOfAnotherFactory() public {
        vm.mockCall(ROUTER, abi.encodeWithSignature("getFactory()"), abi.encode(address(0xFAC)));
        _initFails(6);
    }

    function test_init_check06_routerIsNotARouter_revertsWithTheCallsOwnData() public {
        IPharaohDlmmVault.InitParams memory p = _params();
        p.router = USDT; // a real contract without getFactory(): the validator's external read fails, the revert is bubbled (not PairValidationFailed)
        vm.expectRevert();
        _deployProxy(p);
    }

    function test_init_check07_hookIsNotTheRewarder() public {
        IPharaohDlmmVault.InitParams memory p = _params();
        p.rewarder = address(0xBEEF00BEEF);
        _expectCheck(7);
        _deployProxy(p);
    }

    function test_init_check08_rewarderNotLinked() public {
        vm.mockCall(REWARDER, abi.encodeCall(IDLMMRewarder.isLinked, ()), abi.encode(false));
        _initFails(8);
    }

    function test_init_check09_routerNotAuthorisedByVoter() public {
        vm.mockCall(voter, abi.encodeWithSignature("isAuthorizedDLMMManager(address)", ROUTER), abi.encode(false));
        _initFails(9);
    }

    function test_init_check10_beaconDoesNotListTheRewarder() public {
        vm.mockCall(beacon, abi.encodeCall(IDLMMRewarderBeaconCheck.getRewarder, (POOL)), abi.encode(address(0xDEAD)));
        _initFails(10);
    }

    function test_init_check11_wrongPinnedCodehash() public {
        IPharaohDlmmVault.InitParams memory p = _params();
        p.rewarderImplCodehash = bytes32(uint256(1));
        _expectCheck(11);
        _deployProxy(p);
    }

    function test_init_check12_rewardTokenIsALegOrZero() public {
        vm.mockCall(REWARDER, abi.encodeCall(IDLMMRewarder.getRewardToken, ()), abi.encode(USDC));
        _initFails(12);
        vm.mockCall(REWARDER, abi.encodeCall(IDLMMRewarder.getRewardToken, ()), abi.encode(address(0)));
        _initFails(12);
    }

    function test_init_check13_feedDecimalsNot8() public {
        vm.mockCall(FEED_USDC, abi.encodeCall(IChainlinkFeed.decimals, ()), abi.encode(uint8(18)));
        _initFails(13);
        vm.clearMockedCalls();
        vm.mockCall(FEED_USDT, abi.encodeCall(IChainlinkFeed.decimals, ()), abi.encode(uint8(6)));
        _initFails(13);
    }

    function test_init_check13b_feedStaleOrRevertingAtDeployment() public {
        _mockFeed(FEED_USDT, 1e8, _ts() - 93_601);
        _initFails(13);
        _mockFeedReverts(FEED_USDC);
        _initFails(13);
    }

    function test_init_check14_decimalsAbove18() public {
        vm.mockCall(USDT, abi.encodeWithSignature("decimals()"), abi.encode(uint8(19)));
        _initFails(14);
    }

    function test_init_capAboveCeiling_andNoDoubleInit() public {
        IPharaohDlmmVault.InitParams memory p = _params();
        p.depositCap = 200_000_001;
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.CapAboveCeiling.selector, 200_000_001, 200_000_000));
        _deployProxy(p);
        p = _params();
        vm.expectRevert(); // InvalidInitialization
        v.initialize(p);
        vm.expectRevert(); // the implementation itself is locked
        impl.initialize(p);
    }

    function test_init_pinnedCodehashIsTheBeaconImplementationNotTheProxy() public view {
        bytes32 impl_ = _pinnedCodehash();
        assertTrue(impl_ != REWARDER.codehash, "the proxy's codehash is not what is pinned");
        console2.logBytes32(impl_);
    }
}

interface IDLMMRewarderBeaconCheck {
    function getRewarder(address pool) external view returns (address);
}

// -----------------------------------------------------------------------------------------------------------------------------------------------------
// (2) happy path, (8) cap with the real token
// -----------------------------------------------------------------------------------------------------------------------------------------------------
contract DlmmForkHappy is DlmmForkBase {
    function _openLogged() internal returns (uint256 x, uint256 y, uint24 lo, uint24 hi) {
        vm.recordLogs();
        _openBand();
        Vm.Log[] memory l = vm.getRecordedLogs();
        bytes32 t0 = keccak256("BandOpened(uint24,uint24,uint24,uint256,uint256)");
        for (uint256 i; i < l.length; ++i) {
            if (l[i].topics.length > 0 && l[i].topics[0] == t0) {
                uint24 act;
                (lo, hi, act, x, y) = abi.decode(l[i].data, (uint24, uint24, uint24, uint256, uint256));
                assertEq(act, pair.getActiveId());
            }
        }
        require(hi != 0, "BandOpened not emitted");
    }

    /// The ceremony path, on the unmocked real feeds: the Ledger deposits exactly the cap, the keeper opens the band.
    function test_happy_ceremonyPath_realFeeds() public {
        _unpause();
        uint256 sh = _deposit(ALICE, 200e6);
        assertEq(sh, 200e6, "first deposit 1:1");
        assertEq(v.totalAssets(), 200e6);
        assertEq(v.maxDeposit(ALICE), 0, "at the cap");
        // 1 wei over the cap reverts (deposit and mint)
        _fund(BOB, USDC, 10e6);
        vm.prank(BOB);
        IERC20(USDC).approve(address(v), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.CapExceeded.selector, 200e6, 200e6 + 1));
        vm.prank(BOB);
        v.deposit(1, BOB);
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.CapExceeded.selector, 200e6, 200e6 + 1));
        vm.prank(BOB);
        v.mint(1, BOB);

        // swap cost of the vault's own USDC->USDt half (A/B: the same swap by the trader on a snapshot)
        uint256 snap = vm.snapshotState();
        uint256 out = _swap(USDC, USDT, 100e6);
        vm.revertToState(snap);
        console2.log("MEASURED pure swap USDC->USDt 100e6 in, out:", out);

        (uint256 x, uint256 y, uint24 lo, uint24 hi) = _openLogged();
        (uint24 l2, uint24 h2, uint24 a, bool hasBand, bool oor) = v.bandState();
        assertTrue(hasBand);
        assertFalse(oor);
        assertEq(l2, a - 1);
        assertEq(h2, a + 1);
        assertEq(lo, l2);
        assertEq(hi, h2);
        for (uint24 id = lo; id <= hi; ++id) assertGt(pair.balanceOf(address(v), id), 0, "LB shares in each of the 3 bins");
        uint256 nav = v.totalAssets();
        console2.log("MEASURED band opened: USDt added / USDC added", x, y);
        console2.log("MEASURED idle left in the vault: USDC / USDt", _bal(USDC, address(v)), _bal(USDT, address(v)));
        console2.log("MEASURED NAV after openBand (deposit 200000000):", nav);
        console2.log("MEASURED loss ppm of the deposit (swap + composition fee + floor rounding):", uint256(_ppm(200e6, nav)));
        // loss decomposition at the oracle: swap part vs the rest
        uint256 swapLoss = 100e6 - out * uint256(realAnsP) / uint256(realAnsA);
        console2.log("  of which pure swap cost (raw USDC units, at the oracle):", swapLoss);
        console2.log("  composition fee + rounding (raw):", (200e6 - nav) - swapLoss);
        assertGe(nav * 10_000, 200e6 * 9_950, "within the 50 bp NAV-loss bound");
        // with the D6 fix, openBand does not revert whatever NAV vs cap; NAV below the cap leaves headroom
        uint256 head = v.maxDeposit(BOB);
        console2.log("headroom under the cap after the open", head);
        assertEq(head, 200e6 - nav);
        // the vault holds no big idle amounts after the add (leftover refund only)
        assertLt(_bal(USDC, address(v)) + _bal(USDT, address(v)), 1e6, "leftover below 1 USDC");
        // shares price after open: the depositor's immediate cost
        console2.log("previewRedeem(200e6 shares) right after the open", v.previewRedeem(200e6));
    }

    /// headroom after the open can be filled to the cap exactly, then 1 wei more reverts
    function test_cap_fillHeadroomThenOneWei() public {
        _unpause();
        _deposit(ALICE, 200e6);
        _openBand();
        uint256 head = v.maxDeposit(BOB);
        assertGt(head, 0);
        _fund(BOB, USDC, head + 10);
        vm.startPrank(BOB);
        IERC20(USDC).approve(address(v), type(uint256).max);
        v.deposit(head, BOB);
        assertEq(v.totalAssets(), 200e6, "NAV == cap");
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.CapExceeded.selector, 200e6, 200e6 + 1));
        v.deposit(1, BOB);
        vm.stopPrank();
        // the late deposit sits idle until the next exit-triggered rebalance (decision 2)
        assertEq(_bal(USDC, address(v)) >= head, true, "BOB's deposit is idle USDC");
    }

    function test_cap_mintPath_atCapAndOver() public {
        _unpause();
        assertEq(v.maxMint(ALICE), 200e6);
        _fund(ALICE, USDC, 300e6);
        vm.startPrank(ALICE);
        IERC20(USDC).approve(address(v), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.CapExceeded.selector, 200e6, 200e6 + 1));
        v.mint(200e6 + 1, ALICE);
        uint256 assets = v.mint(200e6, ALICE);
        assertEq(assets, 200e6);
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.CapExceeded.selector, 200e6, 200e6 + 1));
        v.mint(1, ALICE);
        vm.stopPrank();
        assertEq(v.maxMint(ALICE), 0);
    }

    function test_cap_donationOnlyReducesHeadroom() public {
        _unpause();
        _fund(BOB, USDC, 60e6);
        vm.prank(BOB);
        IERC20(USDC).transfer(address(v), 10e6); // direct donation
        assertEq(v.totalAssets(), 10e6);
        assertEq(v.maxDeposit(ALICE), 190e6);
        _fund(ALICE, USDC, 300e6);
        vm.startPrank(ALICE);
        IERC20(USDC).approve(address(v), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.CapExceeded.selector, 200e6, 200e6 + 1));
        v.deposit(190e6 + 1, ALICE);
        v.deposit(190e6, ALICE);
        vm.stopPrank();
        // a donation above the cap cannot be exploited to deposit; and (D6 fix) openBand still works with NAV > cap
        vm.prank(BOB);
        IERC20(USDC).transfer(address(v), 50e6);
        assertGt(v.totalAssets(), 200e6);
        assertEq(v.maxDeposit(ALICE), 0);
        _openBand();
        (,,, bool hasBand,) = v.bandState();
        assertTrue(hasBand, "openBand does not revert when NAV exceeds the cap (D6 fix)");
        assertEq(v.maxDeposit(ALICE), 0);
    }

    function test_cap_setDepositCap_ceilingAndLowering() public {
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.CapAboveCeiling.selector, 200e6 + 1, 200e6));
        v.setDepositCap(200e6 + 1);
        vm.prank(SAFE);
        v.setDepositCap(50e6);
        _unpause();
        assertEq(v.maxDeposit(ALICE), 50e6);
        vm.prank(SAFE);
        v.setDepositCap(0);
        assertEq(v.maxDeposit(ALICE), 0);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, BOB));
        vm.prank(BOB);
        v.setDepositCap(1);
    }

    /// totalAssets drift: real swaps through the vault's bins generate fees (inside bin reserves, in the NAV), print the drift
    function test_cap_totalAssetsDrift_withTrading_and_composition() public {
        _unpause();
        _deposit(ALICE, 200e6);
        _openBand();
        uint256 nav0 = v.totalAssets();
        uint256 head0 = v.maxDeposit(BOB);
        for (uint256 i; i < 10; ++i) {
            _swap(USDC, USDT, 5_000e6);
            _swap(USDT, USDC, _bal(USDT, TRADER));
        }
        (,,,, bool oor) = v.bandState();
        uint256 nav1 = v.totalAssets();
        console2.log("MEASURED NAV before / after 10 round trips of 5000 USDC through the pool:", nav0, nav1);
        console2.log("MEASURED headroom before / after:", head0, v.maxDeposit(BOB));
        console2.log("active id still inside the band:", !oor);
        assertGe(nav1 + 5, nav0, "fees accrue (a few raw units of tolerance for floors)");
        assertEq(v.maxDeposit(BOB), nav1 >= 200e6 ? 0 : 200e6 - nav1, "headroom tracks NAV drift");
    }

    /// what a depositor pays to get out: the round trip deposit 200 -> open -> redeem all (USDC out) and in kind
    function test_happy_roundTripCost() public {
        _unpause();
        uint256 sh = _deposit(ALICE, 200e6);
        _openBand();
        uint256 prev = v.previewRedeem(sh);
        uint256 snap = vm.snapshotState();
        vm.prank(ALICE);
        uint256 got = v.redeem(sh, ALICE, ALICE);
        console2.log("MEASURED full redeem (USDC out): preview / paid / deposited", prev, got);
        console2.log("MEASURED round-trip loss ppm of the deposit", uint256(_ppm(200e6, got)));
        assertGe(got * 10_000, 200e6 * 9_950, "round trip within 50 bp");
        vm.revertToState(snap);
        vm.prank(ALICE);
        (uint256 x, uint256 y) = v.redeemInKind(sh, ALICE, ALICE);
        console2.log("MEASURED full in-kind exit (USDt, USDC):", x, y);
        assertGe((x + y) * 10_000, 200e6 * 9_950);
    }

    function test_happy_depositMintRedeemWithdrawSharePrice() public {
        _unpause();
        _deposit(ALICE, 100e6);
        _openBand();
        _approveBob(80e6);
        uint256 nav = v.totalAssets();
        uint256 supply = v.totalSupply();
        vm.prank(BOB);
        uint256 sh = v.deposit(40e6, BOB);
        assertApproxEqAbs(sh, 40e6 * supply / nav, 1);
        vm.prank(BOB);
        uint256 a = v.mint(10e6, BOB);
        assertApproxEqAbs(a, v.convertToAssets(10e6), 2);
        vm.prank(BOB);
        uint256 burned = v.withdraw(20e6, BOB, BOB);
        assertApproxEqAbs(burned, v.convertToShares(20e6), 2);
        console2.log("withdraw(20e6) burned shares", burned);
    }
}

// -----------------------------------------------------------------------------------------------------------------------------------------------------
// (3) harvest: real PHAR claim on the real rewarder, the 111 s window
// -----------------------------------------------------------------------------------------------------------------------------------------------------
contract DlmmForkHarvest is DlmmForkBase {
    function _ids() internal view returns (uint256[] memory ids) {
        (uint24 lo, uint24 hi,,,) = v.bandState();
        ids = new uint256[](uint256(hi) - lo + 1);
        for (uint256 i; i < ids.length; ++i) ids[i] = uint256(lo) + i;
    }

    function _pending() internal view returns (uint256) {
        return IDLMMRewarder(REWARDER).getPendingRewards(address(v), _ids());
    }

    function _harvest() internal returns (uint256 paid) {
        uint256 before = _bal(PHAR, SAFE);
        vm.prank(KEEPER);
        v.harvestRewards();
        paid = _bal(PHAR, SAFE) - before;
        assertEq(_bal(PHAR, address(v)), 0, "nothing left in the vault");
    }

    function test_harvest_claimsRealPhar_toOwner() public {
        _live(100e6);
        _warpBy(600);
        uint256 pend = _pending();
        uint256 navBefore = v.totalAssets();
        vm.recordLogs();
        uint256 paid = _harvest();
        Vm.Log[] memory l = vm.getRecordedLogs();
        console2.log("MEASURED pending PHAR after 600 s / paid to the Safe", pend, paid);
        assertGt(paid, 0, "PHAR is paid at the pin");
        assertApproxEqRel(paid, pend, 5e16, "paid ~ pending (pending read just before; a few seconds of difference)");
        assertEq(v.totalAssets(), navBefore, "PHAR is never in the share price");
        bytes32 t0 = keccak256("PharHarvested(address,uint256,uint256,uint256)");
        bool seen;
        for (uint256 i; i < l.length; ++i) {
            if (l[i].topics.length > 0 && l[i].topics[0] == t0) {
                (uint256 amt, uint256 ts, uint256 ta) = abi.decode(l[i].data, (uint256, uint256, uint256));
                assertEq(amt, paid);
                assertEq(ts, v.totalSupply());
                assertEq(ta, navBefore);
                seen = true;
            }
        }
        assertTrue(seen, "PharHarvested emitted");
        assertEq(_pending(), 0, "claimed");
    }

    /// Claim at `dt` seconds after the band's bins were last minted (no state travel backwards: every case is a fresh test), then 300 s later again.
    /// Logs pending (what the rewarder reports) and what is actually paid. The 111 s rule: a bin touched within the window forfeits its accrual.
    function _forfeit(uint256 dt) internal returns (uint256 pend, uint256 paid, uint256 later) {
        _live(100e6);
        _warpBy(dt);
        pend = _pending();
        paid = _harvest();
        _warpBy(300);
        uint256 pend2 = _pending();
        later = _harvest();
        console2.log("claim at +s after the mint / pending before / paid:", dt, pend);
        console2.log("   paid:", paid);
        console2.log("   300 s later: pending / paid:", pend2, later);
    }

    // MEASURED: a claim inside the window pays 0 AND forfeits the accrual up to that moment: the claim 300 s later pays 5317684586061233 (300 s of accrual,
    // the same as a first claim at +300), not the 300 + dt seconds a claim-free run would have paid. NOTE: repeated warps within one test make
    // getPendingRewards non-linear in an unexplained way (reads at +100, +112, +200 then +300 gave 2.4x the single-warp value); only single-warp, one-claim-per-case figures are used.
    function test_harvest_forfeit_010s() public { (, uint256 paid,) = _forfeit(10); assertEq(paid, 0, "inside 111 s: nothing paid"); }
    function test_harvest_forfeit_060s() public { (, uint256 paid,) = _forfeit(60); assertEq(paid, 0); }
    function test_harvest_forfeit_110s() public { (, uint256 paid,) = _forfeit(110); assertEq(paid, 0); }
    function test_harvest_forfeit_112s() public { (, uint256 paid,) = _forfeit(112); assertGt(paid, 0, "outside the window: paid"); }
    function test_harvest_forfeit_300s() public { (, uint256 paid,) = _forfeit(300); assertGt(paid, 0); }

    /// PHAR earned on the OLD band's bins before a rebalance: is it still paid by harvestRewards (which claims only the CURRENT band's ids)?
    function test_harvest_afterRebalance_oldBinRewards() public {
        _live(100e6);
        uint256[] memory oldIds = _ids();
        _warpBy(600);
        uint256 pendOld = IDLMMRewarder(REWARDER).getPendingRewards(address(v), oldIds);
        (, uint24 hi,,,) = v.bandState();
        _pushUp(hi + 1);
        _rebalanceAuto();
        uint256 pendOldAfter = IDLMMRewarder(REWARDER).getPendingRewards(address(v), oldIds);
        uint256[] memory newIds = _ids();
        uint256 pendNew = IDLMMRewarder(REWARDER).getPendingRewards(address(v), newIds);
        console2.log("pending on the OLD ids before / after the rebalance:", pendOld, pendOldAfter);
        console2.log("pending on the NEW ids right after the rebalance:", pendNew);
        _warpBy(600);
        uint256 paid = _harvest();
        uint256 stillOld = IDLMMRewarder(REWARDER).getPendingRewards(address(v), oldIds);
        console2.log("harvest paid / pending on the old ids afterwards (unclaimed by harvestRewards):", paid, stillOld);
        // old ids that are not part of the new band can only be claimed by claim(vault, ids): the vault never passes them
        uint256 stranded;
        for (uint256 i; i < oldIds.length; ++i) {
            bool inNew;
            for (uint256 j; j < newIds.length; ++j) if (newIds[j] == oldIds[i]) inNew = true;
            if (!inNew) {
                uint256[] memory one = new uint256[](1);
                one[0] = oldIds[i];
                stranded += IDLMMRewarder(REWARDER).getPendingRewards(address(v), one);
            }
        }
        console2.log("PHAR still attributed to old ids that left the band (stranded by harvestRewards):", stranded);
        // FINDING marker: assert the spec expectation that nothing earned is stranded
        assertEq(stranded, 0, "FINDING if red: PHAR accrued on bins that left the band is not claimed by harvestRewards");
    }

    function test_harvest_noBand_idleOnly() public {
        _unpause();
        _deposit(ALICE, 50e6);
        vm.prank(KEEPER);
        (bool ok, bytes memory ret) = address(v).call(abi.encodeCall(v.harvestRewards, ()));
        console2.log("harvestRewards with no band (empty id list), ok:", ok);
        if (!ok) console2.logBytes4(_sel(ret));
    }

    function test_harvest_accessControl() public {
        _live(100e6);
        vm.expectRevert(PharaohDlmmVault.NotRebalancer.selector);
        vm.prank(BOB);
        v.harvestRewards();
        vm.prank(SAFE);
        v.harvestRewards(); // owner may
        vm.prank(KEEPER);
        v.harvestRewards();
    }

    /// harvesting works while paused / latched / with bad feeds (a harvest must not depend on the feeds)
    function test_harvest_independentOfFeedsPauseGuard() public {
        _live(100e6);
        _warpBy(600);
        _mockFeedReverts(FEED_USDC);
        v.tripGuard();
        vm.prank(SAFE);
        v.pause();
        vm.recordLogs();
        uint256 paid = _harvest();
        assertGt(paid, 0);
        Vm.Log[] memory l = vm.getRecordedLogs();
        bytes32 t0 = keccak256("PharHarvested(address,uint256,uint256,uint256)");
        for (uint256 i; i < l.length; ++i) {
            if (l[i].topics.length > 0 && l[i].topics[0] == t0) {
                (,, uint256 ta) = abi.decode(l[i].data, (uint256, uint256, uint256));
                assertEq(ta, 0, "totalAssets reported as 0 when a feed is bad");
            }
        }
    }
}

// -----------------------------------------------------------------------------------------------------------------------------------------------------
// (4) rebalance through the real router
// -----------------------------------------------------------------------------------------------------------------------------------------------------
contract DlmmForkRebalance is DlmmForkBase {
    function _live150() internal { _live(150e6); }

    function _rebalanceLogged(bool xForY, uint256 swapIn) internal returns (uint256 sIn, uint256 sOut, uint256 nb, uint256 na) {
        vm.recordLogs();
        _rebalance(xForY, swapIn);
        Vm.Log[] memory l = vm.getRecordedLogs();
        bool found;
        (found, sIn, sOut, nb, na) = _rebalancedEvent(l);
        assertTrue(found, "Rebalanced emitted");
    }

    function test_rebalance_up_fullFlow() public {
        _live150();
        (uint24 lo0, uint24 hi0,,,) = v.bandState();
        _pushUp(hi0 + 1);
        (,,, bool hb, bool oor) = v.bandState();
        assertTrue(hb && oor);
        (bool ok, uint256 rb,) = v.rebalanceAllowed();
        assertTrue(ok, "rebalanceAllowed true");
        assertEq(rb, 0);
        uint256 half = v.totalAssets() / 2;
        (uint256 sIn, uint256 sOut, uint256 nb, uint256 na) = _rebalanceLogged(false, half);
        console2.log("MEASURED up: swapIn / swapOut / NAV before / NAV after", sIn, sOut);
        console2.log("                                         ", nb, na);
        console2.log("MEASURED NAV loss ppm of this rebalance (can be negative = gain):", _ppm(nb, na));
        assertGe(na * 10_000, nb * 9_950, "NAV loss bound (50 bp)");
        (uint24 lo, uint24 hi, uint24 a, bool hasBand, bool oor2) = v.bandState();
        assertTrue(hasBand);
        assertFalse(oor2);
        assertEq(lo, a - 1);
        assertEq(hi, a + 1);
        assertGt(a, hi0, "re-centred higher");
        assertEq(v.lastRebalanceAt(), _ts());
        assertEq(v.rebalancesToday(), 1);
        lo0;
        console2.log("MEASURED idle USDC / USDt after:", _bal(USDC, address(v)), _bal(USDT, address(v)));
    }

    function test_rebalance_down_fullFlow() public {
        _live150();
        (uint24 lo0,,,,) = v.bandState();
        _pushDown(lo0 - 1);
        uint256 half = v.totalAssets() / 2; // the vault holds only USDt: sell half of it (6 decimals both)
        (uint256 sIn, uint256 sOut, uint256 nb, uint256 na) = _rebalanceLogged(true, half);
        console2.log("MEASURED down: swapIn / swapOut / NAV before / NAV after", sIn, sOut);
        console2.log("                                         ", nb, na);
        console2.log("MEASURED NAV loss ppm:", _ppm(nb, na));
        assertGe(na * 10_000, nb * 9_950);
        (uint24 lo, uint24 hi, uint24 a,, bool oor) = v.bandState();
        assertFalse(oor);
        assertEq(lo, a - 1);
        assertEq(hi, a + 1);
    }

    function test_rebalance_preconditions_revertOrder() public {
        // no band
        _unpause();
        _deposit(ALICE, 100e6);
        uint24 a = pair.getActiveId();
        vm.expectRevert(IPharaohDlmmVault.NoBand.selector);
        vm.prank(KEEPER);
        v.rebalance(a, 0, false, 0, 0, 0, 0, _ts() + 600);
        _openBand();
        (uint24 lo, uint24 hi,,,) = v.bandState();
        // wrong caller
        vm.expectRevert(PharaohDlmmVault.NotRebalancer.selector);
        vm.prank(SAFE);
        v.rebalance(a, 0, false, 0, 0, 0, 0, _ts() + 600);
        // in range
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.NotOutOfRange.selector, a, lo, hi));
        vm.prank(KEEPER);
        v.rebalance(a, 0, false, 0, 0, 0, 0, _ts() + 600);
        // idSlippage > 2 / deadline
        vm.expectRevert(IPharaohDlmmVault.ParamOutOfBounds.selector);
        vm.prank(KEEPER);
        v.rebalance(a, 3, false, 0, 0, 0, 0, _ts() + 600);
        vm.expectRevert(abi.encodeWithSelector(PharaohDlmmVault.DeadlineExpired.selector, _ts() - 1));
        vm.prank(KEEPER);
        v.rebalance(a, 0, false, 0, 0, 0, 0, _ts() - 1);
        // paused
        _pushUp(hi + 1);
        a = pair.getActiveId();
        vm.prank(SAFE);
        v.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(KEEPER);
        v.rebalance(a, 0, false, 0, 0, 0, 0, _ts() + 600);
        (, uint256 rb,) = v.rebalanceAllowed();
        assertTrue(rb & 2048 != 0, "rebalanceAllowed: paused bit");
    }

    function test_rebalance_activeIdMoved() public {
        _live150();
        (, uint24 hi,,,) = v.bandState();
        _pushUp(hi + 1);
        uint24 a = pair.getActiveId();
        uint256 half = v.totalAssets() / 2;
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.ActiveIdMoved.selector, a - 3, a, uint24(2)));
        vm.prank(KEEPER);
        v.rebalance(a - 3, 2, false, half, 0, 0, 0, _ts() + 600);
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.ActiveIdMoved.selector, a + 1, a, uint24(0)));
        vm.prank(KEEPER);
        v.rebalance(a + 1, 0, false, half, 0, 0, 0, _ts() + 600);
        // within the slippage it goes through
        vm.prank(KEEPER);
        v.rebalance(a - 1, 1, false, half, 0, 0, 0, _ts() + 600);
    }

    function test_rebalance_cooldown_thenAllowed() public {
        _live150();
        (, uint24 hi,,,) = v.bandState();
        _pushUp(hi + 1);
        _rebalanceAuto();
        uint256 t1 = _ts();
        (, uint24 lo2,,,) = _bs();
        lo2;
        // push out again (downwards) at once
        (uint24 l,,,,) = v.bandState();
        _pushDown(l - 1);
        (bool ok, uint256 rb, uint256 readyAt) = v.rebalanceAllowed();
        assertFalse(ok);
        assertTrue(rb & 256 != 0, "cooldown bit");
        assertEq(readyAt, t1 + 120);
        uint24 a = pair.getActiveId();
        uint256 half = v.totalAssets() / 2;
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.CooldownActive.selector, t1 + 120));
        vm.prank(KEEPER);
        v.rebalance(a, 0, true, half, 0, 0, 0, _ts() + 600);
        _warpTo(t1 + 119);
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.CooldownActive.selector, t1 + 120));
        vm.prank(KEEPER);
        v.rebalance(a, 0, true, half, 0, 0, 0, _ts() + 600);
        _warpTo(t1 + 120);
        (ok, rb,) = v.rebalanceAllowed();
        assertTrue(ok, "allowed exactly at lastRebalanceAt + cooldown");
        _rebalance(true, half);
        assertEq(v.rebalancesToday(), 2);
    }

    function _bs() internal view returns (uint24, uint24, uint24, bool, bool) {
        return v.bandState();
    }

    /// daily cap: the hard minimum 4, alternating pushes, then DailyRebalanceCapReached; the next UTC day it works again
    function test_rebalance_dailyCap() public {
        // stay inside one UTC day
        if (_ts() % 1 days > 1 days - 3_000) _warpBy(3_600);
        _freshFeeds();
        _live150();
        IPharaohDlmmVault.GuardParams memory g = v.guardParams();
        g.maxRebalancesPerDay = 4;
        g.rebalanceCooldown = 111;
        vm.prank(SAFE);
        v.setGuardParams(g);
        for (uint256 i; i < 4; ++i) {
            (uint24 lo, uint24 hi,,,) = v.bandState();
            if (i % 2 == 0) _pushUp(hi + 1); else _pushDown(lo - 1);
            _rebalanceAuto();
            _warpBy(112);
            _freshFeeds();
        }
        assertEq(v.rebalancesToday(), 4);
        (uint24 lo2,,,,) = v.bandState();
        _pushDown(lo2 - 1);
        (bool ok, uint256 rb, uint256 readyAt) = v.rebalanceAllowed();
        assertFalse(ok);
        assertTrue(rb & 512 != 0, "daily cap bit");
        assertEq(readyAt, (_ts() / 1 days + 1) * 1 days, "readyAt = next UTC midnight");
        uint24 a = pair.getActiveId();
        uint256 half = v.totalAssets() / 2;
        vm.expectRevert(IPharaohDlmmVault.DailyRebalanceCapReached.selector);
        vm.prank(KEEPER);
        v.rebalance(a, 0, true, half, 0, 0, 0, _ts() + 600);
        _warpTo(readyAt);
        _freshFeeds();
        assertEq(v.rebalancesToday(), 0, "counter rolls over at UTC midnight");
        _rebalance(true, half);
        assertEq(v.rebalancesToday(), 1);
    }

    function test_rebalance_swapTooLarge() public {
        _live150();
        (, uint24 hi,,,) = v.bandState();
        _pushUp(hi + 1);
        uint256 nav = v.totalAssets();
        uint256 tooBig = nav * 6000 / 10_000 + 1;
        uint24 a = pair.getActiveId();
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.SwapTooLarge.selector, tooBig, nav * 6000 / 10_000));
        vm.prank(KEEPER);
        v.rebalance(a, 0, false, tooBig, 0, 0, 0, _ts() + 600);
    }

    /// loss bound with maxRebalanceLossBps at its hard minimum (5 bp): how the vault reacts as the pool is pushed further from the band before the keeper acts
    function test_rebalance_lossBound_vs_howFarThePoolMoved() public {
        _live150();
        IPharaohDlmmVault.GuardParams memory g = v.guardParams();
        g.maxRebalanceLossBps = 5;
        vm.prank(SAFE);
        v.setGuardParams(g);
        (, uint24 hi,,,) = v.bandState();
        uint256[6] memory extra = [uint256(1), 2, 3, 4, 5, 6];
        for (uint256 i; i < extra.length; ++i) {
            uint256 snap = vm.snapshotState();
            _pushUp(uint24(hi + extra[i]));
            uint24 a = pair.getActiveId();
            uint256 half = v.totalAssets() / 2;
            vm.recordLogs();
            vm.prank(KEEPER);
            (bool ok, bytes memory ret) = address(v).call(abi.encodeCall(v.rebalance, (a, 0, false, half, 0, 0, 0, _ts() + 600)));
            console2.log("active id above the old upper bin by / rebalance ok at a 5 bp loss bound:", a - hi, ok);
            if (ok) {
                (, , , uint256 nb, uint256 na) = _rebalancedEvent(vm.getRecordedLogs());
                console2.log("   NAV loss ppm:", _ppm(nb, na));
            } else {
                console2.logBytes4(_sel(ret));
            }
            // MEASURED at the pin: up to 3 bins beyond the band the swap fits the 5 bp floor; from 4 bins the ROUTER's minimum-out check
            // (LBRouter__InsufficientAmountOut, the floor derived from the same parameter) trips first. NavLossTooLarge was not reached in any scenario here.
            if (extra[i] <= 3) assertTrue(ok, "within the 5 bp bound");
            else {
                assertFalse(ok, "beyond: the swap floor reverts");
                assertEq(_sel(ret), bytes4(0x4feac00c), "LBRouter__InsufficientAmountOut (not NavLossTooLarge)");
            }
            vm.revertToState(snap);
        }
    }

    // ---------------------------------------------------------------- one-sided inventory add (the band's dropped-bin path), both directions
    function test_rebalance_oneSidedAdd_usdcOnly() public {
        _live150();
        (, uint24 hi,,,) = v.bandState();
        _pushUp(hi + 1);
        uint256 nb0 = v.totalAssets();
        (uint256 sIn,, uint256 nb, uint256 na) = _rebalanceLogged(false, 0);
        assertEq(sIn, 0);
        (uint24 lo, uint24 hi2, uint24 a, bool hasBand, bool oor) = v.bandState();
        console2.log("one-sided USDC add: NAV before / after / ppm loss", nb, na);
        console2.log("   ppm:", _ppm(nb, na));
        assertEq(nb, nb0);
        assertTrue(hasBand);
        assertFalse(oor);
        assertEq(lo, a - 1);
        assertEq(hi2, a + 1);
        assertGt(pair.balanceOf(address(v), a - 1), 0, "USDC below the active bin");
        console2.log("LB shares per bin (-1, 0, +1):", pair.balanceOf(address(v), a - 1), pair.balanceOf(address(v), a));
        console2.log("   +1:", pair.balanceOf(address(v), a + 1));
        assertEq(pair.balanceOf(address(v), a + 1), 0, "no USDt: the +1 bin is empty");
        assertGe(na * 10_000, nb * 9_950);
        // the vault still exits and values correctly with an empty bin in its nominal band
        uint256 sh = v.balanceOf(ALICE);
        vm.prank(ALICE);
        (uint256 x, uint256 y) = v.redeemInKind(sh / 2, ALICE, ALICE);
        assertGt(x + y, 0);
    }

    function test_rebalance_oneSidedAdd_usdtOnly() public {
        _live150();
        (uint24 lo0,,,,) = v.bandState();
        _pushDown(lo0 - 1);
        (,, uint256 nb, uint256 na) = _rebalanceLogged(true, 0);
        (uint24 lo, uint24 hi, uint24 a, bool hasBand, bool oor) = v.bandState();
        console2.log("one-sided USDt add: NAV before / after / ppm loss", nb, na);
        console2.log("   ppm:", _ppm(nb, na));
        assertTrue(hasBand);
        assertFalse(oor);
        assertEq(lo, a - 1);
        assertEq(hi, a + 1);
        assertEq(pair.balanceOf(address(v), a - 1), 0, "no USDC: the -1 bin is empty");
        assertGt(pair.balanceOf(address(v), a + 1), 0);
        assertGe(na * 10_000, nb * 9_950);
        uint256 sh = v.balanceOf(ALICE);
        vm.prank(ALICE);
        (uint256 x, uint256 y) = v.redeemInKind(sh / 2, ALICE, ALICE);
        assertGt(x + y, 0);
    }

    /// a second rebalance right after a one-sided add still works once the pool leaves again (the empty-bin band is not a dead state)
    function test_rebalance_afterOneSidedAdd_nextExit() public {
        _live150();
        (, uint24 hi,,,) = v.bandState();
        _pushUp(hi + 1);
        _rebalance(false, 0);
        _warpBy(121);
        _freshFeeds();
        (uint24 lo,,,,) = v.bandState();
        _pushDown(lo - 1);
        _rebalanceAuto();
        (,,,, bool oor) = v.bandState();
        assertFalse(oor);
    }

    function test_rebalance_tightAmountMins_revert() public {
        _live150();
        (, uint24 hi,,,) = v.bandState();
        _pushUp(hi + 1);
        uint24 a = pair.getActiveId();
        uint256 half = v.totalAssets() / 2;
        vm.prank(KEEPER);
        vm.expectRevert(); // router: amountXMin above what the bins take
        v.rebalance(a, 0, false, half, 0, type(uint128).max, 0, _ts() + 600);
    }

    function test_rebalance_keeperOnly() public {
        _live150();
        (, uint24 hi,,,) = v.bandState();
        _pushUp(hi + 1);
        uint24 a = pair.getActiveId();
        vm.expectRevert(PharaohDlmmVault.NotRebalancer.selector);
        vm.prank(ALICE);
        v.rebalance(a, 0, false, 1, 0, 0, 0, _ts() + 600);
        vm.expectRevert(PharaohDlmmVault.NotRebalancer.selector);
        vm.prank(SAFE);
        v.openBand(a, 0, 0, 0, 0, _ts() + 600);
    }
}

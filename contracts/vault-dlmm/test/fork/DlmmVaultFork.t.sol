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
        _mockFeed(feed, ans, block.timestamp);
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
        v.openBand(a, 0, 0, 0, 0, block.timestamp + 600);

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
        v.openBand(a, 0, 0, 0, 0, block.timestamp + 600);
        (, uint256 rb,) = v.rebalanceAllowed();
        assertTrue(rb & 1024 != 0, "rebalanceAllowed: latched bit");

        // ---- 4. clearGuard: only the owner, and only when the live state is safe
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, BOB));
        vm.prank(BOB);
        v.clearGuard();
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, KEEPER));
        vm.prank(KEEPER);
        v.clearGuard();
        _mockFeed(feed, ans, block.timestamp); // depeg again
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
        _mockFeed(feed, ans, block.timestamp);
        r = _reasons();
        assertTrue(r & legBit != 0);
        a = pair.getActiveId();
        _expectUnsafe(r);
        vm.prank(KEEPER);
        v.rebalance(a, 0, false, half, 0, 0, 0, block.timestamp + 600);
        vm.prank(BOB);
        v.tripGuard();
        _freshFeeds();
        a = pair.getActiveId();
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardLatched.selector));
        vm.prank(KEEPER);
        v.rebalance(a, 0, false, half, 0, 0, 0, block.timestamp + 600);
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
            _mockFeed(feed, ans, block.timestamp);
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
        _mockFeed(FEED_USDC, 99_900_000, block.timestamp);
        assertEq(_reasons() & B_LEG_A, 0, "exactly 10 bps is inside");
        _mockFeed(FEED_USDC, 99_899_999, block.timestamp);
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
        _mockFeed(FEED_USDC, 100_400_000, block.timestamp);
        _mockFeed(FEED_USDT, 99_550_000, block.timestamp);
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
        uint256 t = block.timestamp;
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
        _mockFeed(feed, ans, block.timestamp);
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
        else if (mode == 1) _mockFeed(feed, 1e8, block.timestamp - 93_601);
        else _mockFeed(feed, 0, block.timestamp);
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
        _mockFeed(FEED_USDT, 98_000_000, block.timestamp);
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
        _mockFeed(FEED_USDC, 98_000_000, block.timestamp);
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
        _mockFeed(FEED_USDT, 99_000_000, block.timestamp); // the feed follows the pool (~0.99)
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
        _mockFeed(FEED_USDC, 99_000_000, block.timestamp);
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
        (ok,) = _try(KEEPER, address(v), abi.encodeCall(v.rebalance, (a, 0, false, half, 0, 0, 0, block.timestamp + 600)));
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
        (ok,) = _try(KEEPER, address(v), abi.encodeCall(v.rebalance, (a, 0, false, half, 0, 0, 0, block.timestamp + 600)));
        assertFalse(ok, "rebalance with a swap blocked");
        (ok,) = _try(KEEPER, address(v), abi.encodeCall(v.rebalance, (a, 0, false, 0, 0, 0, 0, block.timestamp + 600)));
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
        (bool ok,) = _try(KEEPER, address(v), abi.encodeCall(v.rebalance, (a, 0, false, half, 0, 0, 0, block.timestamp + 600)));
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

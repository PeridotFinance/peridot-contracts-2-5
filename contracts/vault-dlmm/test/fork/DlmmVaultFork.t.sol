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

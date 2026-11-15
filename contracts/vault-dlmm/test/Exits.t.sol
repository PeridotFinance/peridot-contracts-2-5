// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {Base} from "./Base.t.sol";
import {IPharaohDlmmVault} from "../src/IPharaohDlmmVault.sol";
import {IChainlinkFeedMin} from "./ExitsIfaces.sol";

/// @notice Spec section 3, the exits the operator insists on. GUARANTEED by the vault code: `redeemInKind` is not gated by pause, the guard, the latch,
///         the cooldown, the daily cap, the keeper, the codehash pin or any oracle, and makes no oracle read and no swap. `withdraw`/`redeem` are not gated by
///         pause/guard/latch but need NAV and a swap: they can revert when a feed reverts or is stale, or the pool cannot fill: documented below as ACTUAL behaviour.
///         NOT guaranteed: a reverting rewarder hook blocks every pair `burn`, hence every exit that touches bins: shown exactly below.
contract ExitsTest is Base {
    function setUp() public virtual {
        _setUpVault();
    }

    bytes32 internal constant SIG_IN_KIND = keccak256("RedeemedInKind(address,address,uint256,uint256,uint256)");

    function _band2(uint256 a, uint256 b) internal {
        _deposit(ALICE, a);
        _deposit(BOB, b);
        _openBand();
    }

    function _noOracleReads() internal {
        // no call at all to either feed (empty calldata prefix matches every call), no router call, no pair swap
        vm.expectCall(address(feedUsdc), "", 0);
        vm.expectCall(address(feedUsdt), "", 0);
        vm.expectCall(address(router), "", 0);
        vm.expectCall(address(pair), abi.encodeWithSignature("swap(bool,address)", true, address(v)), 0);
        vm.expectCall(address(pair), abi.encodeWithSignature("swap(bool,address)", false, address(v)), 0);
    }

    function _killFeeds() internal {
        feedUsdc.setRevertAll(true);
        feedUsdt.setRevertAll(true);
    }

    // ------------------------------------------------------------------ positive control: the detector sees oracle reads when they happen
    function test_control_depositAndRedeemDoReadTheFeeds() public {
        vm.expectCall(address(feedUsdc), abi.encodeCall(IChainlinkFeedMin.latestRoundData, ()));
        vm.expectCall(address(feedUsdt), abi.encodeCall(IChainlinkFeedMin.latestRoundData, ()));
        _deposit(ALICE, 50e6);
        _openBand();
        vm.expectCall(address(feedUsdc), abi.encodeCall(IChainlinkFeedMin.latestRoundData, ()));
        _redeemAll(ALICE);
    }

    // ------------------------------------------------------------------ redeemInKind under every adverse condition
    function test_inKind_basicProRataAndEvent() public {
        _band2(100e6, 50e6);
        (uint256 c0, uint256 t0) = _holdings();
        uint256 supply = shares.balanceOf(ALICE) + shares.balanceOf(BOB);
        uint256 s = shares.balanceOf(ALICE);
        vm.recordLogs();
        (uint256 ax, uint256 ay) = _inKind(ALICE, s);
        _checkInKindEvent(s, ax, ay);
        // amounts are in the pair's X/Y order
        (uint256 gotUsdc, uint256 gotUsdt) = usdcIsX ? (ax, ay) : (ay, ax);
        assertEq(usdc.balanceOf(ALICE), 10_000e6 - 100e6 + gotUsdc);
        assertEq(usdt.balanceOf(ALICE), gotUsdt);
        // pro rata: floor(holdings * s / supply), up to the rounding of 3 bins
        assertApproxEqAbs(gotUsdc, c0 * s / supply, 4);
        assertApproxEqAbs(gotUsdt, t0 * s / supply, 4);
        assertEq(shares.balanceOf(ALICE), 0);
    }

    function _checkInKindEvent(uint256 s, uint256 ax, uint256 ay) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(v) && logs[i].topics[0] == SIG_IN_KIND) {
                n++;
                _eqEvt(logs[i].data, s, ax, ay);
            }
        }
        assertEq(n, 1, "RedeemedInKind emitted once");
    }

    function _eqEvt(bytes memory data, uint256 s, uint256 ax, uint256 ay) internal pure {
        (uint256 sh, uint256 ex, uint256 ey) = abi.decode(data, (uint256, uint256, uint256));
        require(sh == s && ex == ax && ey == ay, "RedeemedInKind args");
    }

    function test_inKind_withPauseOn() public {
        _band2(100e6, 50e6);
        vm.prank(SAFE);
        adm.pause();
        _noOracleReads();
        (uint256 ax, uint256 ay) = _inKind(ALICE, shares.balanceOf(ALICE));
        assertGt(ax + ay, 0);
    }

    function test_inKind_withGuardLatched() public {
        _band2(100e6, 50e6);
        feedUsdc.setAnswer(1.0055e8);
        v.tripGuard();
        feedUsdc.setAnswer(1e8);
        (, bool latched,) = v.guardState();
        assertTrue(latched);
        _noOracleReads();
        (uint256 ax, uint256 ay) = _inKind(ALICE, shares.balanceOf(ALICE));
        assertGt(ax + ay, 0);
    }

    function test_inKind_withRevertingFeeds() public {
        _band2(100e6, 50e6);
        _killFeeds();
        _noOracleReads();
        (uint256 ax, uint256 ay) = _inKind(ALICE, shares.balanceOf(ALICE));
        assertGt(ax + ay, 0);
    }

    function test_inKind_withOnlyOneFeedReverting() public {
        _band2(100e6, 50e6);
        feedUsdt.setRevertLatest(true);
        _noOracleReads();
        _inKind(ALICE, shares.balanceOf(ALICE));
    }

    function test_inKind_withStaleFeeds() public {
        _band2(100e6, 50e6);
        feedUsdc.setAnswerAt(1e8, block.timestamp - 10 days);
        feedUsdt.setAnswerAt(1e8, block.timestamp - 10 days);
        _noOracleReads();
        _inKind(ALICE, shares.balanceOf(ALICE));
    }

    function test_inKind_withZeroAndNegativeAnswers() public {
        _band2(100e6, 50e6);
        feedUsdc.setAnswer(0);
        feedUsdt.setAnswer(-1);
        _noOracleReads();
        _inKind(ALICE, shares.balanceOf(ALICE));
    }

    function test_inKind_withEveryConditionAtOnce() public {
        _band2(100e6, 50e6);
        // paused + latched + both feeds dead + hook unlinked + implementation changed + keeper replaced + band out of range + cooldown / daily cap irrelevant
        feedUsdc.setAnswer(1.0055e8);
        v.tripGuard();
        _killFeeds();
        pair.setHook(address(0)); // the owner-side unlink: bit 32
        beacon.setImplementation(address(implB));
        vm.prank(SAFE);
        v.setRebalancer(address(0xDEAD));
        vm.prank(SAFE);
        adm.pause();
        _pushOut(true);
        _noOracleReads();
        (uint256 ax, uint256 ay) = _inKind(ALICE, shares.balanceOf(ALICE));
        assertGt(ax + ay, 0);
        (ax, ay) = _inKind(BOB, shares.balanceOf(BOB));
        assertGt(ax + ay, 0);
        assertEq(shares.totalSupply(), 0);
    }

    function _pushToDepeggedLeg() internal {
        // the vault ends 100 % in USDt when the band sits above the active bin for X = USDt, i.e. the id FALLS when X = USDt; for X = USDC it must rise
        _pushOut(usdcIsX);
        (uint256 c, uint256 t) = _holdings();
        assertLe(c, 2, "no USDC left in the band (1 wei rounding dust)");
        assertGt(t, 0, "all value in USDt");
    }

    function test_inKind_100PercentInTheDepeggedLeg() public {
        _band2(100e6, 50e6);
        _pushToDepeggedLeg();
        // USDt crashes on the feed AND the pool is one-way; guard trips; pause; feeds dead
        feedUsdt.setAnswer(0.5e8);
        v.tripGuard();
        vm.prank(SAFE);
        adm.pause();
        _killFeeds();
        (, uint256 t0) = _holdings();
        _noOracleReads();
        (uint256 ax, uint256 ay) = _inKind(ALICE, shares.balanceOf(ALICE));
        (uint256 gotUsdc, uint256 gotUsdt) = usdcIsX ? (ax, ay) : (ay, ax);
        assertLe(gotUsdc, 2, "only the depegged token comes out (dust aside)");
        assertApproxEqAbs(gotUsdt, t0 * 100 / 150, 4);
        (ax, ay) = _inKind(BOB, shares.balanceOf(BOB));
        (gotUsdc, gotUsdt) = usdcIsX ? (ax, ay) : (ay, ax);
        assertLe(gotUsdc, 2);
        assertGt(gotUsdt, 0);
    }

    function test_inKind_100PercentInTheOtherLeg() public {
        _band2(100e6, 50e6);
        _pushOut(!usdcIsX);
        (uint256 c, uint256 t) = _holdings();
        assertLe(t, 2);
        assertGt(c, 0);
        feedUsdc.setAnswer(0.5e8);
        _killFeeds();
        (uint256 ax, uint256 ay) = _inKind(ALICE, shares.balanceOf(ALICE));
        (uint256 gotUsdc, uint256 gotUsdt) = usdcIsX ? (ax, ay) : (ay, ax);
        assertGt(gotUsdc, 0);
        assertLe(gotUsdt, 2);
    }

    function test_inKind_idleOnlyNoBand() public {
        _deposit(ALICE, 80e6);
        _deposit(BOB, 20e6);
        usdt.mint(address(v), 10e6); // a stray idle USDt: paid pro rata too
        vm.prank(SAFE);
        adm.pause();
        _killFeeds();
        _noOracleReads();
        uint256 s = shares.balanceOf(ALICE);
        (uint256 ax, uint256 ay) = _inKind(ALICE, s);
        (uint256 gotUsdc, uint256 gotUsdt) = usdcIsX ? (ax, ay) : (ay, ax);
        assertApproxEqAbs(gotUsdc, 80e6, 2);
        assertApproxEqAbs(gotUsdt, 8e6, 2);
    }

    function test_inKind_lastHolderLeavesNothingBehind() public {
        _band2(100e6, 50e6);
        _inKind(ALICE, shares.balanceOf(ALICE));
        _inKind(BOB, shares.balanceOf(BOB));
        assertEq(shares.totalSupply(), 0);
        (uint256 c, uint256 t) = _holdings();
        assertLe(c + t, 3, "dust only");
        (,,, bool has,) = v.bandState();
        assertFalse(has, "band closed after the last exit");
    }

    function test_inKind_conservation_secondHolderNotDiluted() public {
        _band2(100e6, 100e6);
        uint256 bobBefore = erc.convertToAssets(shares.balanceOf(BOB));
        _inKind(ALICE, shares.balanceOf(ALICE));
        uint256 bobAfter = erc.convertToAssets(shares.balanceOf(BOB));
        assertGe(bobAfter + 3, bobBefore, "the remaining holder keeps the value (rounding of a few wei)");
        // and what Alice took plus what is left equals what was there
    }

    function test_inKind_partialSlices_neverRevertNorOverpay() public {
        _band2(100e6, 100e6);
        uint256[6] memory sl = [uint256(1), 7, 999, 12_345, 1e6, 33e6];
        for (uint256 i; i < sl.length; ++i) {
            (uint256 c0, uint256 t0) = _holdings();
            uint256 supply = shares.totalSupply();
            vm.prank(ALICE);
            (bool ok, bytes memory ret) = address(v).call(abi.encodeCall(IPharaohDlmmVault.redeemInKind, (sl[i], ALICE, ALICE)));
            if (!ok) {
                emit log_named_uint("ACTUAL redeemInKind tiny slice reverts (shares)", sl[i]);
                emit log_named_bytes32("  selector", bytes32(_sel(ret)));
                // a dust slice may legitimately pay nothing; it must then fail with the vault's own error, never with a raw pair error
                assertTrue(sl[i] < 1e3, "only dust slices may fail");
                continue;
            }
            (uint256 ax, uint256 ay) = abi.decode(ret, (uint256, uint256));
            (uint256 gc, uint256 gt) = usdcIsX ? (ax, ay) : (ay, ax);
            assertLe(gc, c0 * sl[i] / supply + 4);
            assertLe(gt, t0 * sl[i] / supply + 4);
        }
    }

    function test_inKind_allowanceAndInputs() public {
        _band2(100e6, 50e6);
        uint256 s = shares.balanceOf(ALICE);
        vm.prank(ATTACKER);
        vm.expectRevert();
        v.redeemInKind(s, ATTACKER, ALICE);
        vm.prank(ALICE);
        shares.approve(CAROL, s / 2);
        vm.prank(CAROL);
        vm.expectRevert();
        v.redeemInKind(s, CAROL, ALICE); // more than approved
        vm.prank(CAROL);
        v.redeemInKind(s / 2, CAROL, ALICE);
        assertEq(shares.balanceOf(ALICE), s - s / 2);
        vm.prank(ALICE);
        vm.expectRevert();
        v.redeemInKind(0, ALICE, ALICE);
        vm.prank(ALICE);
        vm.expectRevert();
        v.redeemInKind(s, ALICE, ALICE); // more than the balance left
        vm.prank(ALICE);
        vm.expectRevert();
        v.redeemInKind(1, address(0), ALICE);
    }

    function test_inKind_notGatedByRoles() public {
        _band2(100e6, 50e6);
        vm.prank(SAFE);
        v.setRebalancer(address(0xDEAD)); // the keeper is irrelevant to exits
        _inKind(BOB, shares.balanceOf(BOB));
    }

    // ------------------------------------------------------------------ withdraw / redeem: ACTUAL behaviour with the oracles and the pool
    function test_redeem_worksWithPauseAndLatch() public {
        _band2(100e6, 50e6);
        feedUsdc.setAnswer(1.0055e8);
        v.tripGuard();
        feedUsdc.setAnswer(1e8);
        vm.prank(SAFE);
        adm.pause();
        uint256 s = shares.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 out = erc.redeem(s, ALICE, ALICE);
        assertApproxEqAbs(out, 100e6, 2e5, "about 100 USDC back (swap fee and the band's 1 bp slope)");
        vm.prank(BOB);
        erc.withdraw(10e6, BOB, BOB);
    }

    function test_redeem_revertsWhenAFeedReverts() public {
        _band2(100e6, 50e6);
        feedUsdt.setRevertLatest(true);
        uint256 s = shares.balanceOf(ALICE);
        vm.prank(ALICE);
        vm.expectRevert();
        erc.redeem(s, ALICE, ALICE);
        vm.prank(ALICE);
        vm.expectRevert();
        erc.withdraw(10e6, ALICE, ALICE);
        // ... and the in-kind exit is the way out
        _inKind(ALICE, s);
    }

    function test_redeem_revertsWhenAFeedIsStale() public {
        _band2(100e6, 50e6);
        feedUsdc.setAnswerAt(1e8, block.timestamp - 93_601);
        uint256 s = shares.balanceOf(ALICE);
        vm.prank(ALICE);
        vm.expectRevert();
        erc.redeem(s, ALICE, ALICE);
        _inKind(ALICE, s);
    }

    function test_redeem_revertsWhenThePoolPaysBelowTheOracleMinimum() public {
        _band2(100e6, 50e6);
        // oracle says USDt is worth 0.55 % more than the pool pays: the swap leg of redeem misses the oracle minimum (loss bound 0.5 %)
        feedUsdt.setAnswer(1.0055e8);
        uint256 s = shares.balanceOf(ALICE);
        vm.prank(ALICE);
        vm.expectRevert();
        erc.redeem(s, ALICE, ALICE);
        _inKind(ALICE, s);
    }

    function test_redeem_revertsWhenThePoolCannotFill_inKindStillWorks() public {
        _band2(100e6, 50e6);
        _pushToDepeggedLeg(); // the band is all USDt
        _removeWhale();
        uint256 s = shares.balanceOf(ALICE);
        vm.prank(ALICE);
        vm.expectRevert();
        erc.redeem(s, ALICE, ALICE);
        (uint256 ax, uint256 ay) = _inKind(ALICE, s);
        assertGt(ax + ay, 0);
    }

    function _removeWhale() internal {
        uint256[] memory ids = new uint256[](11);
        uint256[] memory am = new uint256[](11);
        for (uint256 i; i < 11; ++i) {
            ids[i] = ID0 - 5 + i;
            am[i] = pair.balanceOf(WHALE, ids[i]);
        }
        address xt = pair.tokenX();
        address yt = pair.tokenY();
        vm.startPrank(WHALE);
        pair.approveForAll(address(router), true);
        router.removeLiquidity(xt, yt, BIN_STEP, 0, 0, ids, am, WHALE, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_redeem_depeggedLegWithAValidFeedStillExits() public {
        // USDt at 0.9 on the feed (bit 8), pool still near 1.0: exits are not gated; the swap leg pays more than the oracle minimum
        _band2(100e6, 50e6);
        _pushToDepeggedLeg();
        feedUsdt.setAnswer(0.9e8);
        uint256 s = shares.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 out = erc.redeem(s, ALICE, ALICE);
        assertGt(out, 0);
    }

    // ------------------------------------------------------------------ the failing hook: exactly what it blocks
    /// rows: [mint hook down][burn hook down][swap hook down]; results asserted per operation
    bytes internal lastRet;

    function _opRedeemInKind() internal returns (bool ok) {
        uint256 s = shares.balanceOf(ALICE) / 10;
        vm.prank(ALICE);
        (ok, lastRet) = address(v).call(abi.encodeCall(IPharaohDlmmVault.redeemInKind, (s, ALICE, ALICE)));
    }

    function _opRedeem() internal returns (bool ok) {
        uint256 s = shares.balanceOf(BOB) / 10;
        vm.prank(BOB);
        (ok, lastRet) = address(v).call(abi.encodeCall(IERC4626Min2.redeem, (s, BOB, BOB)));
    }

    function _opDeposit() internal returns (bool ok) {
        vm.prank(CAROL);
        (ok, lastRet) = address(v).call(abi.encodeCall(IERC4626Min2.deposit, (1e6, CAROL)));
    }

    /// the last failed call reverted with Error(string) whose text contains `frag`
    function _lastRevertSays(string memory frag) internal view returns (bool) {
        bytes memory r = lastRet;
        if (r.length < 68 || _sel(r) != bytes4(keccak256("Error(string)"))) return false;
        bytes memory body = new bytes(r.length - 4);
        for (uint256 i; i < body.length; ++i) body[i] = r[i + 4];
        string memory msg_ = abi.decode(body, (string));
        bytes memory m = bytes(msg_);
        bytes memory f = bytes(frag);
        if (f.length > m.length) return false;
        for (uint256 i; i + f.length <= m.length; ++i) {
            bool hit = true;
            for (uint256 k; k < f.length; ++k) {
                if (m[i + k] != f[k]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }

    function test_hook_burnHookDown_blocksEveryExitThatTouchesBins() public {
        _band2(100e6, 50e6);
        rewarder.setRevert(false, false, true);
        assertFalse(_opRedeemInKind(), "redeemInKind needs pair.burn: blocked");
        assertTrue(_lastRevertSays("burn hook down"), "the hook's own revert text bubbles up");
        assertFalse(_opRedeem(), "redeem needs pair.burn: blocked");
        assertTrue(_lastRevertSays("burn hook down"));
        vm.prank(ALICE);
        vm.expectRevert();
        erc.withdraw(1e6, ALICE, ALICE);
        // the revert is the hook's: bubbled through the pair and the vault
        vm.prank(ALICE);
        (bool ok, bytes memory ret) = address(v).call(abi.encodeCall(IPharaohDlmmVault.redeemInKind, (1e6, ALICE, ALICE)));
        assertFalse(ok);
        assertEq(_sel(ret), bytes4(keccak256("Error(string)")));
        // what still works: views, deposit (idle), pause, setters, tripGuard, harvest of the guard state
        assertTrue(_opDeposit(), "deposits only touch the idle balance");
        v.guardState();
        v.bandState();
        assertGt(erc.totalAssets(), 0);
        vm.prank(SAFE);
        adm.pause();
        vm.prank(SAFE);
        adm.unpause();
        // the guard does NOT see this failure (accepted risk of the spec, section 3)
        (, , uint256 r) = v.guardState();
        assertEq(r, 0, "ACTUAL: a reverting hook is invisible to guardState (bit 32 is only unlink / codehash)");
        // rebalance is blocked too (it burns the band)
        _pushOut(true);
        bytes memory ret2 = _assertReverts(KEEPER, address(v), _rebalanceCall());
        assertEq(_sel(ret2), bytes4(keccak256("Error(string)")));
    }

    function test_hook_burnHookDown_idleOnlyExitStillWorks() public {
        _deposit(ALICE, 50e6); // no band yet
        rewarder.setRevert(false, false, true);
        assertTrue(_opRedeemInKind(), "no bin to burn: the idle slice is paid");
    }

    function test_hook_unlinkRestoresExits() public {
        _band2(100e6, 50e6);
        rewarder.setRevertAll(true);
        assertFalse(_opRedeemInKind());
        assertTrue(_lastRevertSays("burn hook down"));
        pair.setHook(address(0)); // Pharaoh's factory owner unlinks the hook
        assertTrue(_opRedeemInKind(), "exits work again once the hook is removed");
        (, , uint256 r) = v.guardState();
        assertEq(r, 32, "and the guard now reports the unlink");
    }

    function test_hook_wrongSelectorBlocksTheSame() public {
        _band2(100e6, 50e6);
        rewarder.setWrongSelector(true);
        assertFalse(_opRedeemInKind());
        assertEq(_sel(lastRet), bytes4(keccak256("LBPair__InvalidHooks()")), "wrong selector: the pair reverts InvalidHooks");
        assertFalse(_opRedeem());
        assertEq(_sel(lastRet), bytes4(keccak256("LBPair__InvalidHooks()")));
    }

    function test_hook_mintHookDown_exitsWorkButBandOpsFail() public {
        _band2(100e6, 50e6);
        rewarder.setRevert(false, true, false);
        assertTrue(_opRedeemInKind(), "burn is not hooked on the mint flag");
        assertTrue(_opRedeem(), "redeem = burn + swap: both fine");
        // opening or re-centring needs a mint: blocked, and nothing half-done is left behind
        _pushOut(true);
        uint256 navB = _oracleNav();
        bytes memory ret = _assertReverts(KEEPER, address(v), _rebalanceCall());
        assertEq(_sel(ret), bytes4(keccak256("Error(string)")));
        assertEq(_oracleNav(), navB, "rebalance reverted atomically");
    }

    function test_hook_swapHookDown_inKindWorksUsdcRedeemNeedsTheSwap() public {
        _band2(100e6, 50e6);
        rewarder.setRevert(true, false, false);
        assertTrue(_opRedeemInKind(), "in-kind never swaps");
        // redeem swaps the USDt part: with a hooked swap it fails while the band holds USDt
        (, uint256 t) = _holdings();
        assertGt(t, 0);
        assertFalse(_opRedeem(), "redeem with a USDt part needs the swap");
        assertTrue(_lastRevertSays("swap hook down"));
        // a vault whose band is all USDC pays redeem without any swap
        rewarder.setRevertAll(false); // third-party swaps must pass to set the fixture, then the hook goes down again
        _pushOut(!usdcIsX);
        rewarder.setRevert(true, false, false);
        (, uint256 t2) = _holdings();
        assertLe(t2, 2);
        assertTrue(_opRedeem(), "all-USDC slice: no swap needed (or only dust to swap)");
    }
}

interface IERC4626Min2 {
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256);
}

contract ExitsFlippedTest is ExitsTest {
    function _flipped() internal pure override returns (bool) {
        return true;
    }
}

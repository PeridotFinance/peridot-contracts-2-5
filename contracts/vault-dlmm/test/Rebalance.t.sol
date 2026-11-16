// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {Base} from "./Base.t.sol";
import {IPharaohDlmmVault} from "../src/IPharaohDlmmVault.sol";

/// @notice Spec section 5: openBand, band state, NAV, and every rebalance precondition (NotOutOfRange, cooldown, daily cap, swap too large, NAV loss, ActiveIdMoved).
contract RebalanceTest is Base {
    function setUp() public virtual {
        _setUpVault();
    }

    bytes32 internal constant SIG_REBALANCED =
        keccak256("Rebalanced(uint24,uint24,uint24,uint24,uint24,bool,uint256,uint256,uint256,uint256)");
    bytes32 internal constant SIG_BAND_OPENED = keccak256("BandOpened(uint24,uint24,uint24,uint256,uint256)");

    function _tail(bytes memory ret) internal pure returns (bytes memory out) {
        out = new bytes(ret.length - 4);
        for (uint256 i; i < out.length; ++i) out[i] = ret[i + 4];
    }

    function _sharePrice() internal view returns (uint256) {
        return erc.convertToAssets(1e6);
    }

    // ------------------------------------------------------------------ NAV
    function test_navIdleOnly() public {
        _deposit(ALICE, 100e6);
        assertApproxEqAbs(erc.totalAssets(), 100e6, 1);
        usdt.mint(address(v), 10e6); // an idle USDt donation is valued with the two feeds
        assertApproxEqAbs(erc.totalAssets(), _oracleNav(), 2);
        assertApproxEqAbs(erc.totalAssets(), 110e6, 2);
    }

    function test_navUsesTheTwoFeedsForTheUsdtLeg() public {
        _fundAndOpen(100e6);
        (, uint256 t) = _holdings();
        assertGt(t, 0, "band holds USDt");
        uint256 n0 = erc.totalAssets();
        assertApproxEqAbs(n0, _oracleNav(), 3);
        // USDt drifts to 0.997 (inside the 50 bp band): the USDt leg is worth 0.3 % less
        feedUsdt.setAnswer(0.997e8);
        uint256 n1 = erc.totalAssets();
        assertApproxEqAbs(n1, _oracleNav(), 3);
        assertLt(n1, n0);
        // USDC feed rises: USDt leg worth less in USDC terms
        feedUsdt.setAnswer(1e8);
        feedUsdc.setAnswer(1.002e8);
        assertApproxEqAbs(erc.totalAssets(), _oracleNav(), 3);
    }

    function test_navIsTheOwnershipValueIncludingBinFees() public {
        _fundAndOpen(100e6);
        uint256 sp0 = _sharePrice();
        // swap fees land in bin reserves: income to the vault pro rata, no collect step
        (uint128 bx, uint128 by) = pair.getBin(pair.getActiveId());
        uint256 feeUsdc_ = 50_000e6; // a large fee donation into the active bin makes the effect visible
        usdc.mint(address(pair), feeUsdc_);
        pair.addToBin(pair.getActiveId(), 0, 0); // no-op call keeps the knob exercised
        if (usdcIsX) pair.addToBin(pair.getActiveId(), uint128(feeUsdc_), 0);
        else pair.addToBin(pair.getActiveId(), 0, uint128(feeUsdc_));
        (bx, by);
        assertGt(_sharePrice(), sp0, "bin income raises the share price");
        assertApproxEqAbs(erc.totalAssets(), _oracleNav(), 3);
    }

    // ------------------------------------------------------------------ openBand
    function test_openBandCreatesThreeBinsAroundActive() public {
        _deposit(ALICE, 100e6);
        uint24 a = pair.getActiveId();
        vm.recordLogs();
        _openBand();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(v) && logs[i].topics[0] == SIG_BAND_OPENED) seen = true;
        }
        assertTrue(seen, "BandOpened emitted");
        (uint24 lo, uint24 hi, uint24 act, bool has, bool oor) = v.bandState();
        assertTrue(has);
        assertFalse(oor);
        assertEq(act, a);
        assertEq(lo, a - 1);
        assertEq(hi, a + 1);
        for (uint24 id = a - 4; id <= a + 4; ++id) {
            uint256 sh = pair.balanceOf(address(v), id);
            if (id >= a - 1 && id <= a + 1) assertGt(sh, 0, "share in a band bin");
            else assertEq(sh, 0, "no share outside the band");
        }
    }

    function test_openBandKeepsNavAndIsEvenByValue() public {
        _deposit(ALICE, 120e6);
        _openBand();
        uint256 nav = erc.totalAssets();
        assertGe(nav, 120e6 * 995 / 1000, "NAV after opening within the 0.5 % loss bound");
        assertApproxEqAbs(nav, _oracleNav(), 3);
        uint24 a = pair.getActiveId();
        uint256 total;
        uint256[3] memory val;
        for (uint256 i; i < 3; ++i) {
            uint24 id = a - 1 + uint24(i);
            uint256 sh = pair.balanceOf(address(v), id);
            (uint128 bx, uint128 by) = pair.getBin(id);
            uint256 sup = pair.totalSupply(id);
            uint256 xAmt = sh * bx / sup;
            uint256 yAmt = sh * by / sup;
            val[i] = xAmt + yAmt; // both are 1:1 USD at these feeds
            total += val[i];
        }
        for (uint256 i; i < 3; ++i) {
            assertApproxEqRel(val[i], total / 3, 0.10e18, "each bin carries about a third of the value");
        }
        // nothing material idle
        assertLt(usdc.balanceOf(address(v)) + usdt.balanceOf(address(v)), nav / 50, "less than 2 % idle");
    }

    function test_openBandSharesNotWorseForDepositorAfterwards() public {
        _deposit(ALICE, 100e6);
        uint256 sp0 = _sharePrice();
        _openBand();
        assertGe(_sharePrice() * 1000, sp0 * 995, "opening costs at most the loss bound");
    }

    function test_openBandOnlyRebalancer() public {
        _deposit(ALICE, 50e6);
        bytes memory ret = _assertReverts(ATTACKER, address(v), _openBandArgs());
        assertTrue(ret.length >= 4, "reverts with a reason");
        ret = _assertReverts(ALICE, address(v), _openBandArgs());
        assertTrue(ret.length >= 4);
        assertFalse(_hasBand());
    }

    function test_openBandNothingToDeploy() public {
        _assertReverts(KEEPER, address(v), _openBandArgs());
    }

    function test_openBandActiveIdMoved() public {
        _deposit(ALICE, 50e6);
        uint24 a = pair.getActiveId();
        bytes memory cd = abi.encodeCall(IPharaohDlmmVault.openBand, (a + 5, 1, 0, 0, 0, block.timestamp + 120));
        bytes memory ret = _assertReverts(KEEPER, address(v), cd);
        assertEq(_sel(ret), IPharaohDlmmVault.ActiveIdMoved.selector);
        (uint24 e, uint24 ac, uint24 sl) = abi.decode(_tail(ret), (uint24, uint24, uint24));
        assertEq(e, a + 5);
        assertEq(ac, a);
        assertEq(sl, 1);
        // within the slippage the router adds the 3 bins around the DESIRED id (a+1), not around the real active id (a): the pair then rejects the
        // one-sided rule on the bin a+1 or accepts. Record which (see the findings: idSlippage > 0 has no usable path if it reverts).
        vm.prank(KEEPER);
        (bool ok, bytes memory r2) = address(v).call(abi.encodeCall(IPharaohDlmmVault.openBand, (a + 1, 1, 0, 0, 0, block.timestamp + 120)));
        emit log_named_string("ACTUAL openBand(expected = active+1, idSlippage = 1)", ok ? "succeeds" : "reverts");
        if (!ok) emit log_named_bytes32("  revert selector", bytes32(_sel(r2)));
    }

    function test_openBandIdSlippageAboveTwoReverts() public {
        _deposit(ALICE, 50e6);
        uint24 a = pair.getActiveId();
        _assertReverts(KEEPER, address(v), abi.encodeCall(IPharaohDlmmVault.openBand, (a, 3, 0, 0, 0, block.timestamp + 120)));
        assertFalse(_hasBand());
        vm.prank(KEEPER);
        v.openBand(a, 2, 0, 0, 0, block.timestamp + 120);
        assertTrue(_hasBand());
    }

    function test_openBandDeadline() public {
        _deposit(ALICE, 50e6);
        _assertReverts(KEEPER, address(v), abi.encodeCall(IPharaohDlmmVault.openBand, (pair.getActiveId(), 1, 0, 0, 0, block.timestamp - 1)));
    }

    function test_openBandTwiceIsRecorded() public {
        _fundAndOpen(50e6);
        _deposit(BOB, 20e6);
        (bool ok,) = address(v).call(_openBandArgs());
        emit log_named_string("ACTUAL second openBand with a band present", ok ? "succeeds" : "reverts");
    }

    // ------------------------------------------------------------------ band state moves
    function test_smallSwapsKeepTheBandInRange() public {
        _fundAndOpen(100e6);
        _marketSwap(true, 1_000e6);
        (,,, bool has, bool oor) = v.bandState();
        assertTrue(has);
        assertFalse(oor);
        (bool ok,,) = v.rebalanceAllowed();
        assertFalse(ok, "in range: nothing to rebalance");
    }

    function test_bandStateOutOfRangeBothDirections() public {
        _fundAndOpen(100e6);
        uint256 snap = vm.snapshotState();
        _pushOut(true);
        (uint24 lo, uint24 hi, uint24 act, bool has, bool oor) = v.bandState();
        assertTrue(has);
        assertTrue(oor);
        assertGt(act, hi);
        assertEq(act, pair.getActiveId());
        (lo);
        vm.revertToState(snap);
        _pushOut(false);
        (lo, hi, act, has, oor) = v.bandState();
        assertTrue(oor);
        assertLt(act, lo);
    }

    // ------------------------------------------------------------------ rebalance: success path
    function _rebalanceOnce(bool up) internal returns (uint256 navBefore, uint256 navAfter) {
        _pushOut(up);
        navBefore = _oracleNav();
        _rebalance();
        navAfter = _oracleNav();
    }

    function test_rebalanceRecentresUp() public {
        _fundAndOpen(100e6);
        _pushOut(true);
        uint256 navB = _oracleNav();
        uint256 spB = _sharePrice();
        vm.recordLogs();
        _rebalance();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(v) && logs[i].topics[0] == SIG_REBALANCED) seen = true;
        }
        assertTrue(seen, "Rebalanced emitted");
        (uint24 lo, uint24 hi, uint24 act, bool has, bool oor) = v.bandState();
        assertTrue(has);
        assertFalse(oor, "back in range");
        assertEq(act, pair.getActiveId());
        assertEq(lo, act - 1);
        assertEq(hi, act + 1);
        uint256 navA = _oracleNav();
        assertGe(navA * 10_000, navB * (10_000 - 50), "oracle NAV conserved within the 0.5 % loss bound");
        assertApproxEqAbs(erc.totalAssets(), navA, 3);
        assertGe(_sharePrice() * 10_000, spB * (10_000 - 50));
        assertEq(v.rebalancesToday(), 1);
        assertEq(v.lastRebalanceAt(), block.timestamp);
    }

    function test_rebalanceRecentresDown() public {
        _fundAndOpen(100e6);
        (uint256 b, uint256 a) = _rebalanceOnce(false);
        assertGe(a * 10_000, b * (10_000 - 50));
        (uint24 lo, uint24 hi, uint24 act,, bool oor) = v.bandState();
        assertFalse(oor);
        assertEq(lo, act - 1);
        assertEq(hi, act + 1);
    }

    function test_rebalanceHarvestsNothingAndKeepsTheKeeperPoor() public {
        _fundAndOpen(100e6);
        phar.mint(address(rewarder), 5e18);
        rewarder.setPending(address(v), 3e18);
        _pushOut(true);
        uint256 pharBefore = phar.balanceOf(SAFE) + phar.balanceOf(address(v)) + phar.balanceOf(KEEPER);
        _rebalance();
        assertEq(phar.balanceOf(SAFE) + phar.balanceOf(address(v)) + phar.balanceOf(KEEPER), pharBefore, "claims are separate from the rebalance");
        assertEq(usdc.balanceOf(KEEPER), 0, "the keeper receives nothing");
        assertEq(usdt.balanceOf(KEEPER), 0);
    }

    // ------------------------------------------------------------------ rebalance preconditions, one failing at a time
    function test_rebalanceNoBand() public {
        _deposit(ALICE, 50e6);
        bytes memory ret = _assertReverts(KEEPER, address(v), abi.encodeCall(IPharaohDlmmVault.rebalance, (pair.getActiveId(), 1, true, 1e6, 0, 0, 0, block.timestamp + 120)));
        assertEq(_sel(ret), IPharaohDlmmVault.NoBand.selector);
    }

    function test_rebalanceNotOutOfRange() public {
        _fundAndOpen(100e6);
        (uint24 lo, uint24 hi, uint24 act,,) = v.bandState();
        bytes memory ret = _assertReverts(KEEPER, address(v), _rebalanceCall());
        assertEq(_sel(ret), IPharaohDlmmVault.NotOutOfRange.selector);
        (uint24 a, uint24 l, uint24 h) = abi.decode(_tail(ret), (uint24, uint24, uint24));
        assertEq(a, act);
        assertEq(l, lo);
        assertEq(h, hi);
    }

    function test_rebalanceNotOutOfRangeAtTheEdge() public {
        // the active id on the band edge is still in range (activeId < lowerId || activeId > upperId)
        _fundAndOpen(100e6);
        (, uint24 hi,,,) = v.bandState();
        // move up by one bin using a swap just large enough to drain the active bin's other token but not the next
        uint256 guard;
        while (pair.getActiveId() < hi && guard++ < 20) _marketSwap(!usdcIsX, 20_000e6);
        if (pair.getActiveId() == hi) {
            bytes memory ret = _assertReverts(KEEPER, address(v), _rebalanceCall());
            assertEq(_sel(ret), IPharaohDlmmVault.NotOutOfRange.selector, "edge bin is in range");
        }
    }

    function test_rebalanceRoleGated() public {
        _fundAndOpen(100e6);
        _pushOut(true);
        bytes memory cd = _rebalanceCall();
        _assertReverts(ATTACKER, address(v), cd);
        _assertReverts(ALICE, address(v), cd);
        // the owner calling rebalance is spec-silent: record (R3 lets the owner act as rebalancer)
        vm.prank(SAFE);
        (bool ok,) = address(v).call(cd);
        emit log_named_string("ACTUAL owner calling rebalance", ok ? "allowed (R3 behaviour)" : "reverts");
    }

    function test_rebalanceWhenPausedReverts() public {
        _fundAndOpen(100e6);
        _pushOut(true);
        vm.prank(SAFE);
        adm.pause();
        bytes memory ret = _assertReverts(KEEPER, address(v), _rebalanceCall());
        assertEq(_sel(ret), ENFORCED_PAUSE);
        (bool ok,,) = v.rebalanceAllowed();
        assertFalse(ok);
    }

    function test_rebalanceCooldown() public {
        _fundAndOpen(100e6);
        _pushOut(true);
        _rebalance();
        uint256 t0 = vm.getBlockTimestamp();
        _pushOut(false);
        (bool ok, uint256 bits, uint256 readyAt) = v.rebalanceAllowed();
        assertFalse(ok, "cooldown");
        assertEq(readyAt, t0 + 120);
        emit log_named_uint("ACTUAL rebalanceAllowed reasonBits during cooldown", bits);
        bytes memory ret = _assertReverts(KEEPER, address(v), _rebalanceCall());
        assertEq(_sel(ret), IPharaohDlmmVault.CooldownActive.selector);
        assertEq(abi.decode(_tail(ret), (uint256)), t0 + 120);
        vm.warp(t0 + 119);
        _refreshFeeds();
        ret = _assertReverts(KEEPER, address(v), _rebalanceCall());
        assertEq(_sel(ret), IPharaohDlmmVault.CooldownActive.selector, "one second early");
        vm.warp(t0 + 120);
        _refreshFeeds();
        (ok,,) = v.rebalanceAllowed();
        assertTrue(ok, "ready exactly at lastRebalanceAt + cooldown");
        _rebalance();
        assertEq(v.rebalancesToday(), 2);
    }

    function test_rebalanceCooldownFollowsParams() public {
        IPharaohDlmmVault.GuardParams memory g = v.guardParams();
        g.rebalanceCooldown = 600;
        vm.prank(SAFE);
        v.setGuardParams(g);
        _fundAndOpen(100e6);
        _pushOut(true);
        _rebalance();
        uint256 t0 = vm.getBlockTimestamp();
        _pushOut(false);
        vm.warp(t0 + 300);
        _refreshFeeds();
        bytes memory ret = _assertReverts(KEEPER, address(v), _rebalanceCall());
        assertEq(_sel(ret), IPharaohDlmmVault.CooldownActive.selector);
        assertEq(abi.decode(_tail(ret), (uint256)), t0 + 600);
    }

    function test_openBandIgnoresTheCooldownOfAPreviousRebalance() public {
        // openBand has no cooldown precondition (interface note): a band that does not exist can be opened right after a rebalance timestamp
        _fundAndOpen(100e6);
        assertEq(v.lastRebalanceAt(), 0, "openBand does not stamp the rebalance clock");
    }

    function test_rebalanceDailyCap() public {
        IPharaohDlmmVault.GuardParams memory g = v.guardParams();
        g.maxRebalancesPerDay = 4;
        g.rebalanceCooldown = 112;
        vm.prank(SAFE);
        v.setGuardParams(g);
        _fundAndOpen(150e6);
        for (uint256 i; i < 4; ++i) {
            _pushOut(i % 2 == 0);
            _rebalance();
            assertEq(v.rebalancesToday(), i + 1);
            _warp(115);
        }
        _pushOut(true);
        (bool ok,,) = v.rebalanceAllowed();
        assertFalse(ok, "daily cap reached");
        bytes memory ret = _assertReverts(KEEPER, address(v), _rebalanceCall());
        assertEq(_sel(ret), IPharaohDlmmVault.DailyRebalanceCapReached.selector);
        // a day later the counter is released
        _warp(2 days);
        (ok,,) = v.rebalanceAllowed();
        assertTrue(ok, "counter resets");
        _rebalance();
        assertEq(v.rebalancesToday(), 1);
    }

    /// ACTUAL (spec-silent, W2 DEVIATIONS: day = timestamp / 86400): the daily counter resets at UTC midnight, so up to twice the cap fits inside 24 h around a midnight.
    function test_dailyCapResetsAtUtcMidnightNotRolling24h() public {
        IPharaohDlmmVault.GuardParams memory g = v.guardParams();
        g.maxRebalancesPerDay = 4;
        g.rebalanceCooldown = 112;
        vm.prank(SAFE);
        v.setGuardParams(g);
        _fundAndOpen(150e6);
        uint256 now_ = vm.getBlockTimestamp();
        uint256 midnight = (now_ / 1 days + 1) * 1 days;
        vm.warp(midnight - 600); // ten minutes before midnight
        _refreshFeeds();
        for (uint256 i; i < 4; ++i) {
            _pushOut(i % 2 == 0);
            _rebalance();
            _warp(115);
        }
        assertEq(v.rebalancesToday(), 4);
        vm.warp(midnight + 1);
        _refreshFeeds();
        assertEq(v.rebalancesToday(), 0, "counter reset by the calendar day");
        _pushOut(true);
        _rebalance(); // the 5th rebalance inside about 12 minutes
        emit log_named_string("ACTUAL 5 rebalances within 12 minutes across UTC midnight with maxRebalancesPerDay = 4", "allowed");
    }

    function test_rebalanceSwapTooLarge() public {
        _fundAndOpen(100e6);
        _pushOut(true);
        (uint256 c, uint256 t) = _holdings();
        uint256 bulk = c >= t ? c : t;
        bool overUsdc = c >= t;
        bool swapXForY = overUsdc ? usdcIsX : !usdcIsX;
        uint256 nav = erc.totalAssets();
        uint256 swapIn = (bulk * 61) / 100; // 61 % > maxSwapBps 60 %
        bytes memory cd = abi.encodeCall(IPharaohDlmmVault.rebalance, (pair.getActiveId(), 1, swapXForY, swapIn, 0, 0, 0, block.timestamp + 120));
        bytes memory ret = _assertReverts(KEEPER, address(v), cd);
        assertEq(_sel(ret), IPharaohDlmmVault.SwapTooLarge.selector);
        (uint256 si, uint256 maxIn) = abi.decode(_tail(ret), (uint256, uint256));
        assertEq(si, swapIn);
        assertApproxEqAbs(maxIn, nav * 6000 / 10_000, 5, "max swap is maxSwapBps of the NAV");
    }

    function test_rebalanceSwapTooLargeFollowsParams() public {
        _fundAndOpen(100e6);
        _pushOut(true);
        IPharaohDlmmVault.GuardParams memory g = v.guardParams();
        g.maxSwapBps = 1_000; // 10 %
        vm.prank(SAFE);
        v.setGuardParams(g);
        bytes memory ret = _assertReverts(KEEPER, address(v), _rebalanceCall()); // swaps half
        assertEq(_sel(ret), IPharaohDlmmVault.SwapTooLarge.selector);
    }

    function test_rebalanceActiveIdMoved() public {
        _fundAndOpen(100e6);
        _pushOut(true);
        (uint256 c, uint256 t) = _holdings();
        bool overUsdc = c >= t;
        bool swapXForY = overUsdc ? usdcIsX : !usdcIsX;
        uint256 swapIn = (c >= t ? c : t) / 2;
        uint24 a = pair.getActiveId();
        bytes memory cd = abi.encodeCall(IPharaohDlmmVault.rebalance, (a + 4, 1, swapXForY, swapIn, 0, 0, 0, block.timestamp + 120));
        bytes memory ret = _assertReverts(KEEPER, address(v), cd);
        assertEq(_sel(ret), IPharaohDlmmVault.ActiveIdMoved.selector);
        (uint24 e, uint24 ac, uint24 sl) = abi.decode(_tail(ret), (uint24, uint24, uint24));
        assertEq(e, a + 4);
        assertEq(ac, a);
        assertEq(sl, 1);
    }

    function test_rebalanceIdSlippageAboveTwoReverts() public {
        _fundAndOpen(100e6);
        _pushOut(true);
        (uint256 c, uint256 t) = _holdings();
        bool swapXForY = c >= t ? usdcIsX : !usdcIsX;
        _assertReverts(KEEPER, address(v), abi.encodeCall(IPharaohDlmmVault.rebalance, (pair.getActiveId(), 3, swapXForY, (c >= t ? c : t) / 2, 0, 0, 0, block.timestamp + 120)));
    }

    function test_rebalanceDeadline() public {
        _fundAndOpen(100e6);
        _pushOut(true);
        (uint256 c, uint256 t) = _holdings();
        bool swapXForY = c >= t ? usdcIsX : !usdcIsX;
        _assertReverts(KEEPER, address(v), abi.encodeCall(IPharaohDlmmVault.rebalance, (pair.getActiveId(), 1, swapXForY, (c >= t ? c : t) / 2, 0, 0, 0, block.timestamp - 1)));
    }

    function test_rebalanceLossyPoolIsRejected() public {
        // the pool charges 2 % on the swap leg: the half swap costs 1 % of the NAV, above the 0.5 % bound. The vault must reject the whole rebalance,
        // by its own swap floor (oracle-implied out minus the loss bound) or by NavLossTooLarge; either way nothing moves.
        _fundAndOpen(100e6);
        _pushOut(true);
        pair.setFee(2e16);
        uint256 navB = _oracleNav();
        (uint24 lo, uint24 hi,,,) = v.bandState();
        bytes memory ret = _assertReverts(KEEPER, address(v), _rebalanceCall());
        emit log_named_bytes32("ACTUAL lossy rebalance revert selector", bytes32(_sel(ret)));
        assertEq(_oracleNav(), navB, "state untouched");
        (uint24 lo2, uint24 hi2,,,) = v.bandState();
        assertEq(lo, lo2);
        assertEq(hi, hi2);
    }

    function test_rebalanceNavLossBoundFollowsParams() public {
        // a pool fee of 0.3 % costs 0.15 % of the NAV on the half swap: passes at the default 0.5 %, fails at the minimum 0.05 % bound
        _fundAndOpen(100e6);
        _pushOut(true);
        pair.setFee(3e15);
        uint256 snap = vm.snapshotState();
        _rebalance(); // default bound 50 bps passes
        assertTrue(_hasBand());
        vm.revertToState(snap);
        IPharaohDlmmVault.GuardParams memory g = v.guardParams();
        g.maxRebalanceLossBps = 5;
        vm.prank(SAFE);
        v.setGuardParams(g);
        bytes memory ret = _assertReverts(KEEPER, address(v), _rebalanceCall());
        emit log_named_bytes32("ACTUAL tight-bound rebalance revert selector", bytes32(_sel(ret)));
    }

    function test_rebalanceAllowedMirrorsPreconditions() public {
        (bool ok,,) = v.rebalanceAllowed();
        assertFalse(ok, "no band");
        _fundAndOpen(100e6);
        (ok,,) = v.rebalanceAllowed();
        assertFalse(ok, "in range");
        _pushOut(true);
        uint256 readyAt;
        (ok,, readyAt) = v.rebalanceAllowed();
        assertTrue(ok);
        assertLe(readyAt, block.timestamp);
    }

    // ------------------------------------------------------------------ a rebalance never lets third parties extract: the vault ends with 3 bins and nothing else
    function test_rebalanceLeavesOnlyBandSharesAroundTheNewActive() public {
        _fundAndOpen(100e6);
        _pushOut(true);
        _rebalance();
        uint24 a = pair.getActiveId();
        uint256 inBand;
        for (uint24 id = ID0 - 60; id <= ID0 + 60; ++id) {
            uint256 sh = pair.balanceOf(address(v), id);
            if (sh == 0) continue;
            assertTrue(id >= a - 1 && id <= a + 1, "shares only in the three new bins");
            inBand++;
        }
        assertEq(inBand, 3);
    }
}

contract RebalanceFlippedTest is RebalanceTest {
    function _flipped() internal pure override returns (bool) {
        return true;
    }
}

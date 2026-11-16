// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {Base, IVaultAdmin} from "./Base.t.sol";
import {MockLBPair} from "./mocks/MockLBPair.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IPharaohDlmmVault} from "../src/IPharaohDlmmVault.sol";

/// @notice W7 mutation checks: tests added for the hand mutants of `PharaohDlmmVault` / `PharaohDlmmPairValidator` that the 419 earlier tests did not kill
///         (see mutation/MUTANTS.md; the ids M../V.. below refer to that table). Each test passes on the real source and fails on the named mutant.
interface MockERC20Like {
    function balanceOf(address) external view returns (uint256);
    function mint(address, uint256) external;
}

contract MutationTest is Base {
    bytes4 internal constant ROUTER_INSUFFICIENT_OUT = bytes4(keccak256("LBRouter__InsufficientAmountOut(uint256,uint256)"));

    function setUp() public virtual {
        _setUpVault();
    }

    function _reasons() internal view returns (uint256 r) {
        (,, r) = v.guardState();
    }

    function _selOf(bytes memory ret) internal pure returns (bytes4 s) {
        if (ret.length >= 4) {
            assembly {
                s := mload(add(ret, 32))
            }
        }
    }

    // ------------------------------------------------------------------ M12: initialize reports the cap it stored
    function test_initEmitsDepositCapSetFromZero() public {
        vm.recordLogs();
        address p2 = _deployVaultWith(_initParams());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == p2 && logs[i].topics[0] == keccak256("DepositCapSet(uint256,uint256)")) {
                (uint256 o, uint256 n) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(o, 0, "old cap");
                assertEq(n, CAP, "new cap");
                found = true;
            }
        }
        assertTrue(found, "DepositCapSet emitted by initialize");
    }

    // ------------------------------------------------------------------ M25 / M26: the leg band is inclusive at exactly legBandBps (50 bp)
    function test_bit4_exactBandEdgeIsSafeOneUnitBeyondTrips() public {
        feedUsdc.setAnswer(100_500_000);
        assertEq(_reasons() & 4, 0, "+50 bp exactly is inside");
        feedUsdc.setAnswer(100_500_001);
        assertEq(_reasons() & 4, 4, "+50 bp and one unit is outside");
        feedUsdc.setAnswer(99_500_000);
        assertEq(_reasons() & 4, 0, "-50 bp exactly is inside");
        feedUsdc.setAnswer(99_499_999);
        assertEq(_reasons() & 4, 4, "-50 bp and one unit is outside");
    }

    function test_bit8_exactBandEdgeIsSafeOneUnitBeyondTrips() public {
        feedUsdt.setAnswer(100_500_000);
        assertEq(_reasons() & 8, 0, "+50 bp exactly is inside");
        feedUsdt.setAnswer(100_500_001);
        assertEq(_reasons() & 8, 8, "+50 bp and one unit is outside");
        feedUsdt.setAnswer(99_500_000);
        assertEq(_reasons() & 8, 0, "-50 bp exactly is inside");
        feedUsdt.setAnswer(99_499_999);
        assertEq(_reasons() & 8, 8, "-50 bp and one unit is outside");
    }

    // ------------------------------------------------------------------ M90 / M91 / M92: a tolerated id difference (idSlippage > 0) builds the band around the REAL active id
    function test_openBandWithToleratedIdDifferenceBuildsBandAroundRealId() public {
        _deposit(ALICE, 100e6);
        uint24 a = pair.getActiveId();
        vm.prank(KEEPER);
        v.openBand(a + 1, 1, 0, 0, 0, block.timestamp + 120);
        (uint24 lo, uint24 hi,, bool has,) = v.bandState();
        assertTrue(has);
        assertEq(lo, a - 1, "lower around the real id");
        assertEq(hi, a + 1, "upper around the real id");
        assertGt(pair.balanceOf(address(v), a), 0, "shares in the real active bin");
    }

    function test_openBandWithToleratedIdDifferenceBelowBuildsBandAroundRealId() public {
        _deposit(ALICE, 100e6);
        uint24 a = pair.getActiveId();
        vm.prank(KEEPER);
        v.openBand(a - 1, 1, 0, 0, 0, block.timestamp + 120);
        (uint24 lo, uint24 hi,,,) = v.bandState();
        assertEq(lo, a - 1);
        assertEq(hi, a + 1);
    }

    function test_rebalanceWithToleratedIdDifferenceBuildsBandAroundRealId() public {
        _fundAndOpen(100e6);
        _pushOut(true);
        uint24 a = pair.getActiveId();
        (uint256 c, uint256 t) = _holdings();
        bool swapXForY = c >= t ? usdcIsX : !usdcIsX;
        uint256 swapIn = (c >= t ? c : t) / 2;
        vm.prank(KEEPER);
        v.rebalance(a - 1, 1, swapXForY, swapIn, 0, 0, 0, block.timestamp + 120);
        (uint24 lo, uint24 hi,,,) = v.bandState();
        assertEq(lo, a - 1, "lower around the real id");
        assertEq(hi, a + 1, "upper around the real id");
    }

    // ------------------------------------------------------------------ M71 / M74 / M75: NavLossTooLarge fires when the band ends up worth less than the swap-bounded loss allows
    /// the pair is made to report empty bins for the NEW band ids only (a pair that returned nothing for the added liquidity)
    function _mockNewBinsEmpty(uint24 from, uint24 to) internal {
        for (uint24 id = from; id <= to; ++id) {
            vm.mockCall(address(pair), abi.encodeWithSelector(bytes4(keccak256("getBin(uint24)")), id), abi.encode(uint128(0), uint128(0)));
        }
    }

    function test_rebalanceNavLossTooLargeWhenTheNewBandIsWorthLess() public {
        _fundAndOpen(100e6);
        _pushOut(true);
        uint24 a = pair.getActiveId();
        (, uint24 hi,,,) = v.bandState();
        assertGt(a, hi, "pushed above the band");
        _mockNewBinsEmpty(a, a + 1); // ids of the new band that are not ids of the old band
        (uint256 c, uint256 t) = _holdings();
        bool swapXForY = c >= t ? usdcIsX : !usdcIsX;
        uint256 swapIn = (c >= t ? c : t) / 2;
        vm.prank(KEEPER);
        (bool ok, bytes memory ret) = address(v).call(abi.encodeCall(IPharaohDlmmVault.rebalance, (a, 1, swapXForY, swapIn, 0, 0, 0, block.timestamp + 120)));
        assertFalse(ok, "must revert");
        assertEq(_selOf(ret), IPharaohDlmmVault.NavLossTooLarge.selector, "NavLossTooLarge");
    }

    function test_openBandNavLossTooLargeWhenTheNewBandIsWorthLess() public {
        _deposit(ALICE, 100e6);
        uint24 a = pair.getActiveId();
        _mockNewBinsEmpty(a - 1, a + 1);
        vm.prank(KEEPER);
        (bool ok, bytes memory ret) = address(v).call(abi.encodeCall(IPharaohDlmmVault.openBand, (a, 1, 0, 0, 0, block.timestamp + 120)));
        assertFalse(ok, "must revert");
        assertEq(_selOf(ret), IPharaohDlmmVault.NavLossTooLarge.selector, "NavLossTooLarge");
    }

    // ------------------------------------------------------------------ M76: the vault's own swap floor (oracle out minus the loss bound) holds when the NAV bound alone would pass
    function _smallSwapRebalance() internal returns (bool ok, bytes memory ret) {
        (uint256 c, uint256 t) = _holdings();
        bool swapXForY = c >= t ? usdcIsX : !usdcIsX;
        uint256 swapIn = (c >= t ? c : t) / 10; // 10 % of the bulk: a 1 % pool fee costs 0.1 % of the NAV (< 0.5 % bound)
        uint24 a = pair.getActiveId(); // read before the prank (a call in the argument list would consume it)
        vm.prank(KEEPER);
        (ok, ret) = address(v).call(abi.encodeCall(IPharaohDlmmVault.rebalance, (a, 1, swapXForY, swapIn, 0, 0, 0, block.timestamp + 120)));
    }

    function test_rebalanceSwapFloorRejectsAOnePercentSwapEvenWhenNavLossIsSmall() public {
        _fundAndOpen(100e6);
        _pushOut(true);
        pair.setFee(1e16); // 1 % on the swapped part
        (bool ok, bytes memory ret) = _smallSwapRebalance();
        assertFalse(ok, "the 1 % swap is below the oracle floor (0.5 %)");
        assertEq(_selOf(ret), ROUTER_INSUFFICIENT_OUT, "the router's minimum-out (the vault's floor) trips");
    }

    function test_rebalanceSmallSwapWithinTheFloorSucceeds() public {
        _fundAndOpen(100e6);
        _pushOut(true);
        pair.setFee(1e15); // 0.1 %: inside the floor
        (bool ok,) = _smallSwapRebalance();
        assertTrue(ok, "a 0.1 % swap passes");
    }

    // ------------------------------------------------------------------ M85 / M86: ActiveIdMoved is checked before AND after the vault's own inventory swap
    /// removes the whale's liquidity on the three bins the vault's USDC swap would trade through, so the swap pushes the active id three bins
    function _thinSwapSide() internal returns (uint24 movedTo) {
        uint24 a = pair.getActiveId();
        bool up = !usdcIsX; // USDC in as Y buys X on higher ids; USDC in as X sells into Y on lower ids
        uint256[] memory ids = new uint256[](3);
        uint256[] memory amts = new uint256[](3);
        for (uint24 i; i < 3; ++i) {
            ids[i] = up ? a + i : a - i;
            amts[i] = pair.balanceOf(WHALE, ids[i]);
        }
        vm.prank(WHALE);
        pair.burn(WHALE, WHALE, ids, amts);
        movedTo = up ? a + 3 : a - 3;
    }

    function test_openBandRechecksActiveIdAfterItsOwnSwap() public {
        uint24 expected = pair.getActiveId();
        uint24 movedTo = _thinSwapSide();
        _deposit(ALICE, 100e6);
        vm.prank(KEEPER);
        (bool ok, bytes memory ret) = address(v).call(abi.encodeCall(IPharaohDlmmVault.openBand, (expected, 1, 0, 0, 0, block.timestamp + 120)));
        assertFalse(ok, "the vault's swap moved the active id beyond the tolerance");
        assertEq(_selOf(ret), IPharaohDlmmVault.ActiveIdMoved.selector, "ActiveIdMoved");
        movedTo; // silence
    }

    function test_openBandChecksActiveIdBeforeItsOwnSwap() public {
        uint24 movedTo = _thinSwapSide();
        _deposit(ALICE, 100e6);
        // expected = where the vault's own swap will leave the id: the post-swap check alone would pass; the pre-swap check must refuse (3 > 2)
        vm.prank(KEEPER);
        (bool ok, bytes memory ret) = address(v).call(abi.encodeCall(IPharaohDlmmVault.openBand, (movedTo, 2, 0, 0, 0, block.timestamp + 120)));
        assertFalse(ok, "pre-swap id differs by 3 > 2");
        assertEq(_selOf(ret), IPharaohDlmmVault.ActiveIdMoved.selector, "ActiveIdMoved");
    }

    // ------------------------------------------------------------------ M120: NAV values the USDt leg rounding DOWN
    function test_navValuesTheUsdtLegRoundingDown() public {
        usdt.mint(address(v), 3);
        feedUsdt.setAnswer(99_999_999);
        // 3 raw USDt * 0.99999999 = 2.99999997 -> 2 (a round-up would give 3)
        assertEq(erc.totalAssets(), 2, "floor(3 * 0.99999999)");
    }

    // ------------------------------------------------------------------ M121: a partial in-kind exit burns FLOOR(bal * shares / supply) of each bin (never rounds up against the holders left)
    function test_partialInKindBurnsTheFlooredBinSlice() public {
        _fundAndOpen(100e6);
        (uint24 lo, uint24 hi,,,) = v.bandState();
        uint256 s = 12_345_679;
        uint256 supply = shares.totalSupply();
        uint256[3] memory before_;
        uint256 checked;
        for (uint256 i; i < 3; ++i) {
            before_[i] = pair.balanceOf(address(v), lo + i);
            if (before_[i] != 0 && (before_[i] * s) % supply != 0) ++checked;
        }
        assertGt(checked, 0, "fixture: at least one bin has a non-integer slice");
        _inKind(ALICE, s);
        for (uint256 i; i < 3; ++i) {
            if (before_[i] == 0) continue;
            assertEq(pair.balanceOf(address(v), lo + i), before_[i] - (before_[i] * s) / supply, "remaining = bal - floor(bal*s/supply)");
        }
        hi;
    }

    // ------------------------------------------------------------------ M131 / M136: the latch is reported by rebalanceAllowed and zeroes maxDeposit / maxMint after the feeds recover
    function _latchThenRecover() internal {
        feedUsdc.setAnswer(0);
        v.tripGuard();
        feedUsdc.setAnswer(1e8);
        (bool unsafe, bool latched, uint256 r) = v.guardState();
        assertFalse(unsafe, "live conditions recovered");
        assertTrue(latched, "still latched");
        assertEq(r, 0);
    }

    function test_rebalanceAllowedReportsTheLatchAfterRecovery() public {
        _latchThenRecover();
        (bool ok, uint256 bits,) = v.rebalanceAllowed();
        assertFalse(ok);
        assertEq(bits & 1024, 1024, "RB_LATCHED");
    }

    function test_maxDepositAndMaxMintAreZeroWhileLatchedEvenWhenLiveSafe() public {
        assertGt(erc.maxDeposit(ALICE), 0, "fixture: open before the latch");
        _latchThenRecover();
        assertEq(erc.maxDeposit(ALICE), 0, "maxDeposit under the latch");
        assertEq(erc.maxMint(ALICE), 0, "maxMint under the latch");
    }

    // ------------------------------------------------------------------ M151: openBand with nothing to deploy reverts NothingToDeploy (not a downstream router error)
    function test_openBandWithNoFundsRevertsNothingToDeploy() public {
        _assertRevertsWith(KEEPER, address(v), _openBandArgs(), bytes4(keccak256("NothingToDeploy()")));
    }

    // ------------------------------------------------------------------ M161 / M162: an exit that pays nothing reverts ExitFailed (redeem, withdraw path and in kind)
    function _emptyTheBinsFromTheVaultsView() internal {
        (uint24 lo, uint24 hi,,,) = v.bandState();
        for (uint24 id = lo; id <= hi; ++id) {
            vm.mockCall(address(pair), abi.encodeWithSignature("balanceOf(address,uint256)", address(v), uint256(id)), abi.encode(uint256(0)));
        }
    }

    function test_redeemThatPaysNothingRevertsExitFailed() public {
        _fundAndOpen(100e6);
        _emptyTheBinsFromTheVaultsView();
        vm.prank(ALICE);
        vm.expectRevert(bytes4(keccak256("ExitFailed()")));
        erc.redeem(1, ALICE, ALICE);
    }

    function test_redeemInKindThatPaysNothingRevertsExitFailed() public {
        _fundAndOpen(100e6);
        _emptyTheBinsFromTheVaultsView();
        vm.prank(ALICE);
        vm.expectRevert(bytes4(keccak256("ExitFailed()")));
        v.redeemInKind(1, ALICE, ALICE);
    }

    // ------------------------------------------------------------------ M23: an active id more than 4096 bins from 2^23 is always a deviation (not a peg), either side
    function test_bit16_farFromPegIdIsADeviation() public {
        pair.forceActiveId(ID0 + 5000);
        assertEq(_reasons() & 16, 16, "id far above");
        pair.forceActiveId(ID0 - 5000);
        assertEq(_reasons() & 16, 16, "id far below");
    }

    // ------------------------------------------------------------------ M24: the pool/oracle threshold is inclusive: a deviation of exactly maxPoolOracleDevBps is NOT a deviation
    function test_bit16_deviationExactlyAtTheThresholdIsSafe() public {
        // oracle ratio r = 0.9765625 (X per Y feeds 97_656_250 / 1e8), pool at id 2^23 = 1.0: |1 - r| * 1e4 == 240 * r exactly (r = 1e22 / 10240)
        IPharaohDlmmVault.GuardParams memory g = v.guardParams();
        g.maxPoolOracleDevBps = 240;
        vm.prank(SAFE);
        v.setGuardParams(g);
        // price of the X leg = 0.9765625, of the Y leg = 1.0
        if (usdcIsX) _setFeeds(97_656_250, 1e8);
        else _setFeeds(1e8, 97_656_250);
        assertEq(_reasons() & 16, 0, "exactly at the threshold: not a deviation");
        g.maxPoolOracleDevBps = 239;
        vm.prank(SAFE);
        v.setGuardParams(g);
        assertEq(_reasons() & 16, 16, "one bp tighter: a deviation");
    }

    // ------------------------------------------------------------------ M58: redeemInKind of more shares than owned reverts with the 4626 error (not a bare burn error)
    function test_redeemInKindMoreThanOwnedRevertsExceededMaxRedeem() public {
        _deposit(ALICE, 10e6);
        uint256 bal = shares.balanceOf(ALICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("ERC4626ExceededMaxRedeem(address,uint256,uint256)")), ALICE, bal + 1, bal));
        v.redeemInKind(bal + 1, ALICE, ALICE);
    }

    // ------------------------------------------------------------------ M69: a swap of exactly maxSwapBps of the NAV is allowed (the limit is inclusive)
    function test_rebalanceSwapOfExactlyMaxSwapBpsOfNavIsAllowed() public {
        _fundAndOpen(100e6);
        _pushOut(true);
        uint256 swapIn = (erc.totalAssets() * 6000) / 10_000;
        (uint256 c, uint256 t) = _holdings();
        bool swapXForY = c >= t ? usdcIsX : !usdcIsX;
        uint24 a = pair.getActiveId();
        vm.prank(KEEPER);
        v.rebalance(a, 1, swapXForY, swapIn, 0, 0, 0, block.timestamp + 120);
        (,,, bool has,) = v.bandState();
        assertTrue(has);
    }

    // ------------------------------------------------------------------ M73: a NAV loss of exactly maxRebalanceLossBps is allowed; one unit more is not
    function _mockOneBinWorth(uint24 id, uint256 assetUnits) internal {
        vm.mockCall(address(pair), abi.encodeWithSignature("balanceOf(address,uint256)", address(v), uint256(id)), abi.encode(uint256(1)));
        vm.mockCall(address(pair), abi.encodeWithSignature("totalSupply(uint256)", uint256(id)), abi.encode(uint256(1)));
        vm.mockCall(
            address(pair),
            abi.encodeWithSignature("getBin(uint24)", id),
            usdcIsX ? abi.encode(uint128(assetUnits), uint128(0)) : abi.encode(uint128(0), uint128(assetUnits))
        );
    }

    function test_openBandNavLossExactlyAtTheBoundIsAllowedOneUnitMoreIsNot() public {
        _deposit(ALICE, 100e6);
        uint24 a = pair.getActiveId();
        uint256 snap = vm.snapshotState();
        // probe: the new bins read empty, so the revert reports (navBefore, idle leftovers)
        _mockNewBinsEmpty(a - 1, a + 1);
        vm.prank(KEEPER);
        (bool ok, bytes memory ret) = address(v).call(abi.encodeCall(IPharaohDlmmVault.openBand, (a, 1, 0, 0, 0, block.timestamp + 120)));
        assertFalse(ok);
        bytes memory args = new bytes(ret.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = ret[i + 4];
        }
        (uint256 navBefore, uint256 idleNav) = abi.decode(args, (uint256, uint256));
        vm.clearMockedCalls();
        vm.revertToState(snap);
        assertEq((navBefore * 9950) % 10_000, 0, "fixture: the bound is an integer");
        uint256 need = (navBefore * 9950) / 10_000 - idleNav;

        _mockNewBinsEmpty(a - 1, a + 1);
        _mockOneBinWorth(a, need);
        vm.prank(KEEPER);
        v.openBand(a, 1, 0, 0, 0, block.timestamp + 120); // navAfter * 1e4 == navBefore * 9950: allowed
        vm.clearMockedCalls();
        vm.revertToState(snap);

        _mockNewBinsEmpty(a - 1, a + 1);
        _mockOneBinWorth(a, need - 1);
        vm.prank(KEEPER);
        (ok, ret) = address(v).call(abi.encodeCall(IPharaohDlmmVault.openBand, (a, 1, 0, 0, 0, block.timestamp + 120)));
        assertFalse(ok, "one unit below the bound");
        assertEq(_selOf(ret), IPharaohDlmmVault.NavLossTooLarge.selector);
    }

    // ------------------------------------------------------------------ M113: a feed that returns too little data is a bad feed (bit 1), never a revert of the guard
    function test_guardSurvivesAFeedReturningShortData() public {
        vm.mockCall(address(feedUsdc), abi.encodeWithSignature("latestRoundData()"), abi.encode(uint256(1)));
        (bool unsafe,, uint256 r) = v.guardState();
        assertTrue(unsafe);
        assertEq(r & 1, 1, "asset feed bad");
        vm.clearMockedCalls();
        vm.mockCall(address(feedUsdt), abi.encodeWithSignature("latestRoundData()"), abi.encode(uint256(1), uint256(2)));
        (unsafe,, r) = v.guardState();
        assertEq(r & 2, 2, "pair feed bad");
    }

    // ------------------------------------------------------------------ M118: maxMint is the FLOORED share value of maxDeposit (minting maxMint never breaks the cap)
    function test_maxMintFloorsAndMintingItStaysInsideTheCap() public {
        _fundAndOpen(100e6);
        uint24 a = pair.getActiveId();
        usdc.mint(address(pair), 7_000_001); // income inside the active bin: the share price rises above 1, conversions stop being exact
        if (usdcIsX) pair.addToBin(a, 7_000_001, 0);
        else pair.addToBin(a, 0, 7_000_001);
        uint256 md = erc.maxDeposit(BOB);
        uint256 mm = erc.maxMint(BOB);
        assertEq(mm, erc.convertToShares(md), "floor of the share value");
        assertLe(erc.previewMint(mm), md, "minting maxMint stays inside maxDeposit");
    }

    // ------------------------------------------------------------------ M123 / M124: the band flag follows the bins (all burned -> no band), also when a dust bin is left behind
    function test_lastHolderExitClearsTheBandFlagEvenWithADustBinLeft() public {
        _fundAndOpen(100e6);
        (uint24 lo,,,,) = v.bandState();
        vm.mockCall(address(pair), abi.encodeWithSignature("getBin(uint24)", lo), abi.encode(uint128(0), uint128(0))); // this bin pays nothing: skipped as dust
        uint256 all = shares.balanceOf(ALICE);
        _inKind(ALICE, all);
        (,,, bool has,) = v.bandState();
        assertFalse(has, "a full exit clears the band flag");
    }

    function test_partialExitWithNoBinSharesLeftClearsTheBandFlag() public {
        _fundAndOpen(100e6);
        usdc.mint(address(v), 50e6); // idle inventory so the exit pays something
        _emptyBinsInTheVaultsView();
        _inKind(ALICE, shares.balanceOf(ALICE) / 2);
        (,,, bool has,) = v.bandState();
        assertFalse(has, "no bin shares left: no band");
    }

    function _emptyBinsInTheVaultsView() internal {
        (uint24 lo, uint24 hi,,,) = v.bandState();
        for (uint24 id = lo; id <= hi; ++id) {
            vm.mockCall(address(pair), abi.encodeWithSignature("balanceOf(address,uint256)", address(v), uint256(id)), abi.encode(uint256(0)));
        }
    }

    // ------------------------------------------------------------------ M127: the swap floor of an asset -> pair swap uses the oracle ratio the right way round
    function test_openBandSwapFloorUsesTheAssetToPairPrice() public {
        _deposit(ALICE, 100e6);
        feedUsdc.setAnswer(1.003e8); // USDC 0.3 % dearer than USDt: still inside every guard
        assertEq(_reasons(), 0, "fixture: guard quiet");
        IPharaohDlmmVault.GuardParams memory g = v.guardParams();
        g.maxRebalanceLossBps = 5; // floor = oracle out - 0.05 %: the pool's 1.000 is below 1.003 * 0.9995
        vm.prank(SAFE);
        v.setGuardParams(g);
        uint24 a = pair.getActiveId();
        vm.prank(KEEPER);
        (bool ok, bytes memory ret) = address(v).call(abi.encodeCall(IPharaohDlmmVault.openBand, (a, 1, 0, 0, 0, block.timestamp + 120)));
        assertFalse(ok, "the pool pays less than the oracle floor");
        assertEq(_selOf(ret), ROUTER_INSUFFICIENT_OUT, "router minimum-out");
        g.maxRebalanceLossBps = 50;
        vm.prank(SAFE);
        v.setGuardParams(g);
        vm.prank(KEEPER);
        v.openBand(a, 1, 0, 0, 0, block.timestamp + 120); // control: the default 0.5 % bound passes
    }

    // ------------------------------------------------------------------ M133: the band edges are in range
    function test_rebalanceAllowedCountsTheEdgeBinsAsInRange() public {
        _fundAndOpen(100e6);
        (uint24 lo, uint24 hi,,,) = v.bandState();
        pair.forceActiveId(lo);
        (, uint256 bits,) = v.rebalanceAllowed();
        assertEq(bits & 128, 128, "active == lower is in range");
        pair.forceActiveId(hi);
        (, bits,) = v.rebalanceAllowed();
        assertEq(bits & 128, 128, "active == upper is in range");
        pair.forceActiveId(hi + 1);
        (, bits,) = v.rebalanceAllowed();
        assertEq(bits & 128, 0, "one above is out of range");
    }

    // ------------------------------------------------------------------ M135: when the daily cap is hit inside the last cooldown before midnight, readyAt is the later of cooldown end and next day
    function test_rebalanceAllowedReadyAtIsTheLaterOfCooldownAndNextDay() public {
        IPharaohDlmmVault.GuardParams memory g = v.guardParams();
        g.maxRebalancesPerDay = 4;
        g.rebalanceCooldown = 112;
        vm.prank(SAFE);
        v.setGuardParams(g);
        _fundAndOpen(150e6);
        uint256 midnight = (vm.getBlockTimestamp() / 1 days + 1) * 1 days;
        vm.warp(midnight - 366);
        _refreshFeeds();
        for (uint256 i; i < 4; ++i) {
            _pushOut(i % 2 == 0);
            _rebalance();
            if (i < 3) _warp(112);
        }
        uint256 last = v.lastRebalanceAt();
        assertEq(last, midnight - 30, "fixture: the 4th rebalance is 30 s before midnight");
        (, uint256 bits, uint256 readyAt) = v.rebalanceAllowed();
        assertEq(bits & 512, 512, "daily cap");
        assertEq(readyAt, last + 112, "cooldown ends after midnight: that is the later time");
    }

    // ------------------------------------------------------------------ M138: maxDeposit / maxMint are zero while a live guard bit is set (no latch, no pause)
    function test_maxDepositAndMaxMintAreZeroWhileLiveUnsafe() public {
        assertGt(erc.maxDeposit(ALICE), 0);
        feedUsdc.setAnswer(1.006e8); // bit 4 (and bit 16: the pool is 0.6 % off the oracle ratio)
        (bool unsafe, bool latched, uint256 r) = v.guardState();
        assertTrue(unsafe);
        assertFalse(latched);
        assertEq(r & 4, 4);
        assertEq(erc.maxDeposit(ALICE), 0);
        assertEq(erc.maxMint(ALICE), 0);
    }

    // ------------------------------------------------------------------ M147: a second openBand while a band exists reverts BandExists
    function test_openBandWhileABandExistsRevertsBandExists() public {
        _fundAndOpen(100e6);
        _deposit(BOB, 50e6);
        _assertRevertsWith(KEEPER, address(v), _openBandArgs(), bytes4(keccak256("BandExists()")));
    }

    // ------------------------------------------------------------------ M148 / M149: the vault's own deadline (an expired deadline reverts DeadlineExpired; deadline == now is valid)
    function test_openBandDeadline() public {
        _deposit(ALICE, 100e6);
        uint24 a = pair.getActiveId();
        _assertRevertsWith(
            KEEPER, address(v), abi.encodeCall(IPharaohDlmmVault.openBand, (a, 1, 0, 0, 0, block.timestamp - 1)), bytes4(keccak256("DeadlineExpired(uint256)"))
        );
        vm.prank(KEEPER);
        v.openBand(a, 1, 0, 0, 0, block.timestamp); // deadline == block.timestamp is still valid
    }

    function test_rebalanceDeadline() public {
        _fundAndOpen(100e6);
        _pushOut(true);
        (uint256 c, uint256 t) = _holdings();
        bool swapXForY = c >= t ? usdcIsX : !usdcIsX;
        uint256 swapIn = (c >= t ? c : t) / 2;
        uint24 a = pair.getActiveId();
        _assertRevertsWith(
            KEEPER,
            address(v),
            abi.encodeCall(IPharaohDlmmVault.rebalance, (a, 1, swapXForY, swapIn, 0, 0, 0, block.timestamp - 1)),
            bytes4(keccak256("DeadlineExpired(uint256)"))
        );
        vm.prank(KEEPER);
        v.rebalance(a, 1, swapXForY, swapIn, 0, 0, 0, block.timestamp);
    }

    // ------------------------------------------------------------------ M153: bit 32 also fires on a hook that points elsewhere while isLinked() still says 1
    function test_bit32_hookElsewhereWhileIsLinkedStillTrue() public {
        vm.mockCall(address(rewarder), abi.encodeWithSignature("isLinked()"), abi.encode(uint256(1)));
        pair.setHook(address(0xdead));
        (,, uint256 r) = v.guardState();
        assertEq(r & 32, 32);
    }

    // ------------------------------------------------------------------ M159 / M160 / M163 / M164: exits pay the RECEIVER, and refuse a zero receiver / zero shares with their own errors
    function test_redeemInKindPaysTheReceiverNotTheCaller() public {
        _fundAndOpen(100e6);
        uint256 bobX = tokenX_().balanceOf(BOB);
        uint256 bobY = tokenY_().balanceOf(BOB);
        uint256 aliceX = tokenX_().balanceOf(ALICE);
        uint256 aliceY = tokenY_().balanceOf(ALICE);
        uint256 half = shares.balanceOf(ALICE) / 2; // read before the prank
        vm.prank(ALICE);
        (uint256 ax, uint256 ay) = v.redeemInKind(half, BOB, ALICE);
        assertEq(tokenX_().balanceOf(BOB) - bobX, ax);
        assertEq(tokenY_().balanceOf(BOB) - bobY, ay);
        assertGt(ax + ay, 0);
        assertEq(tokenX_().balanceOf(ALICE), aliceX, "the caller got no X");
        assertEq(tokenY_().balanceOf(ALICE), aliceY, "the caller got no Y");
    }

    function test_redeemPaysTheReceiverNotTheCaller() public {
        _deposit(ALICE, 10e6);
        uint256 bob = usdc.balanceOf(BOB);
        uint256 alice = usdc.balanceOf(ALICE);
        uint256 half = shares.balanceOf(ALICE) / 2; // read before the prank
        vm.prank(ALICE);
        uint256 paid = erc.redeem(half, BOB, ALICE);
        assertGt(paid, 0);
        assertEq(usdc.balanceOf(BOB) - bob, paid);
        assertEq(usdc.balanceOf(ALICE), alice, "the caller got nothing");
    }

    function tokenX_() internal view returns (MockERC20Like) {
        return MockERC20Like(pair.tokenX());
    }

    function tokenY_() internal view returns (MockERC20Like) {
        return MockERC20Like(pair.tokenY());
    }

    function test_redeemInKindZeroReceiverAndZeroSharesHaveTheirOwnErrors() public {
        _deposit(ALICE, 10e6);
        vm.prank(ALICE);
        vm.expectRevert(bytes4(keccak256("ZeroAddress()")));
        v.redeemInKind(1e6, address(0), ALICE);
        vm.prank(ALICE);
        vm.expectRevert(bytes4(keccak256("ZeroAmount()")));
        v.redeemInKind(0, ALICE, ALICE);
    }

    // ------------------------------------------------------------------ M167: a rebalance may swap nothing (swapIn = 0): the swap step is skipped, not reverted
    function test_rebalanceWithZeroSwapSkipsTheSwap() public {
        _fundAndOpen(100e6);
        _pushOut(true);
        uint24 a = pair.getActiveId();
        uint256 swaps = pair.swapCount();
        vm.prank(KEEPER);
        v.rebalance(a, 1, false, 0, 0, 0, 0, block.timestamp + 120);
        assertEq(pair.swapCount(), swaps, "no swap");
        (uint24 lo, uint24 hi,,,) = v.bandState();
        assertEq(lo, a - 1);
        assertEq(hi, a + 1);
    }

    // ------------------------------------------------------------------ M84: rebalance checks the active id BEFORE burning (a swap that later brings the id back must not rescue a stale expected id)
    function test_rebalanceChecksActiveIdBeforeBurning() public {
        _fundAndOpen(100e6);
        _pushOut(true);
        uint24 a = pair.getActiveId();
        // remove the whale's liquidity at and above the active id and leave one stepping stone three bins up: the vault's own Y -> X swap lands there
        for (uint24 id = a; id <= ID0 + 5; ++id) {
            uint256 bal = pair.balanceOf(WHALE, id);
            if (bal == 0) continue;
            uint256[] memory ids = new uint256[](1);
            uint256[] memory amts = new uint256[](1);
            ids[0] = id;
            amts[0] = bal;
            vm.prank(WHALE);
            pair.burn(WHALE, WHALE, ids, amts);
        }
        uint24 stone = a + 3;
        (uint256 c, uint256 t) = _holdings();
        uint256 swapIn = (c >= t ? c : t) / 2;
        MockERC20Like xTok = tokenX_();
        xTok.mint(address(pair), 1_000_000e6);
        pair.addToBin(stone, 1_000_000e6, 0);
        // expected = where the swap will leave the id: only the PRE-burn check can refuse (3 > 2)
        _assertRevertsWith(
            KEEPER,
            address(v),
            abi.encodeCall(IPharaohDlmmVault.rebalance, (stone, 2, false, swapIn, 0, 0, 0, block.timestamp + 120)),
            IPharaohDlmmVault.ActiveIdMoved.selector
        );
    }

    // ------------------------------------------------------------------ M78: the caller's swapMinOut is honoured when it is above the oracle floor
    function test_rebalanceHonoursACallerMinOutAboveTheOracleFloor() public {
        _fundAndOpen(100e6);
        _pushOut(true);
        (uint256 c, uint256 t) = _holdings();
        bool swapXForY = c >= t ? usdcIsX : !usdcIsX;
        uint256 swapIn = (c >= t ? c : t) / 2;
        uint24 a = pair.getActiveId();
        vm.prank(KEEPER);
        (bool ok, bytes memory ret) =
            address(v).call(abi.encodeCall(IPharaohDlmmVault.rebalance, (a, 1, swapXForY, swapIn, swapIn * 2, 0, 0, block.timestamp + 120)));
        assertFalse(ok, "asked for twice what the swap can return");
        assertEq(_selOf(ret), ROUTER_INSUFFICIENT_OUT);
    }

    function test_openBandHonoursACallerMinOutAboveTheOracleFloor() public {
        _deposit(ALICE, 100e6);
        uint24 a = pair.getActiveId();
        vm.prank(KEEPER);
        (bool ok, bytes memory ret) = address(v).call(abi.encodeCall(IPharaohDlmmVault.openBand, (a, 1, 100e6, 0, 0, block.timestamp + 120)));
        assertFalse(ok, "the 50 USDC half swap cannot return 100");
        assertEq(_selOf(ret), ROUTER_INSUFFICIENT_OUT);
    }

    // ------------------------------------------------------------------ the "share price did not fall on deposit" flake (see mutation/MUTANTS.md): the exact bound
    /// OZ's virtual offset prices a deposit at floor(a * (S+1) / (N+1)) shares (S = supply, N = totalAssets). With D = N*s - a*S (> 0 means the price fell):
    /// D <= a * (N - S) / (N + 1), so D == 0 whenever N <= S, and the existing holders lose D / (S + s) asset units (< p - 1 raw units per deposit, p = N / S).
    function _depositDrop(uint256 first, uint256 income, uint256 amt) internal returns (bool ran) {
        first = bound(first, 1e6, 100e6);
        income = bound(income, 0, 40e6);
        amt = bound(amt, 1, 90e6);
        _deposit(ALICE, first);
        _openBand();
        if (income != 0) {
            uint24 a = pair.getActiveId();
            usdc.mint(address(pair), income);
            if (usdcIsX) pair.addToBin(a, uint128(income), 0);
            else pair.addToBin(a, 0, uint128(income));
        }
        if (amt > erc.maxDeposit(BOB)) return false;
        if (erc.previewDeposit(amt) == 0) return false;
        (uint256 n0, uint256 d0) = (erc.totalAssets(), shares.totalSupply());
        _deposit(BOB, amt);
        (uint256 n1, uint256 d1) = (erc.totalAssets(), shares.totalSupply());
        uint256 drop = n0 * d1 > n1 * d0 ? n0 * d1 - n1 * d0 : 0;
        if (n0 > d0) assertLe(drop * (n0 + 1), amt * (n0 - d0), "drop <= a (N - S) / (N + 1)");
        else assertEq(drop, 0, "no price drop when N <= S");
        return true;
    }

    function testFuzz_depositPriceDropIsBoundedByTheVirtualOffset(uint256 first, uint256 income, uint256 amt) public {
        _depositDrop(first, income, amt);
    }

    /// the input forge found on the unmutated source: the price falls by a rounding amount (product shortfall 1394 of 3.5e15), inside the bound
    function test_recordedFlakyInputIsInsideTheBound() public {
        assertTrue(
            _depositDrop(
                1911880305644076833487114229076, 35271246637922355855, 12539887258264965128491181840794683951595290493545185096511
            )
        );
    }

    // ------------------------------------------------------------------ post-review code (W7 round 2)
    // R02: renounceOwnership is disabled for the owner and still owner-gated (a stranger gets the Ownable error, not RenounceDisabled)
    function test_renounceOwnershipDisabledForOwnerAndUnauthorisedForOthers() public {
        bytes memory cd = abi.encodeWithSignature("renounceOwnership()");
        _assertRevertsWith(SAFE, address(v), cd, bytes4(keccak256("RenounceDisabled()")));
        _assertRevertsWith(ATTACKER, address(v), cd, OWNABLE_UNAUTH);
        assertEq(adm.owner(), SAFE, "owner unchanged");
    }

    // H05: a harvest with nothing to forward makes no zero-value transfer (a token that reverts on zero transfers must not block the harvest)
    function test_harvestWithNothingToForwardDoesNotTransferZero() public {
        vm.mockCallRevert(address(phar), abi.encodeWithSignature("transfer(address,uint256)", SAFE, uint256(0)), "zero transfer");
        vm.prank(KEEPER);
        v.harvestRewards();
    }

    // S12: mint measures the resulting supply in SHARES (price above 1: 1000 shares cost 1_001_000 assets, which must not pass as supply)
    function test_mintMinSupplyIsMeasuredInSharesNotAssets() public {
        usdc.mint(address(v), 1000); // idle donation before the first deposit: totalAssets 1000, supply 0, price ~1001 per share
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("SupplyBelowMinimum(uint256)")), 1000));
        erc.mint(1000, BOB);
    }

    // S14: the error reports the RESULTING supply (existing + minted), not the minted amount
    function test_supplyBelowMinimumReportsTheResultingSupply() public {
        _deposit(ALICE, 2e6);
        vm.prank(ALICE);
        erc.redeem(2e6 - 100, ALICE, ALICE); // supply 100: exits may leave it below the minimum
        assertEq(shares.totalSupply(), 100);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("SupplyBelowMinimum(uint256)")), 1100));
        erc.deposit(1000, BOB);
    }

    // P13: the post-swap pool/oracle re-check uses the right price order (pool at the oracle ratio 1.003: safe; the inverted ratio 0.997 would trip a 40 bp bound)
    function _skewPoolToTheOracle() internal returns (uint24 id) {
        IPharaohDlmmVault.GuardParams memory g = v.guardParams();
        g.maxPoolOracleDevBps = 40;
        vm.prank(SAFE);
        v.setGuardParams(g);
        if (usdcIsX) feedUsdc.setAnswer(1.003e8);
        else feedUsdt.setAnswer(1.003e8); // oracle ratio X per Y read as Y per X = 1.003
        id = ID0 + 30; // 1.0001^30 = 1.003
        pair.forceActiveId(id);
        usdc.mint(address(pair), 1_000_000e6);
        usdt.mint(address(pair), 1_000_000e6);
        pair.addToBin(id, uint128(1_000_000e6), uint128(1_000_000e6)); // depth at the skewed price
        assertEq(_reasons(), 0, "fixture: guard quiet at the skewed price");
    }

    function test_openBandPostSwapRecheckUsesTheRightPriceOrder() public {
        _deposit(ALICE, 100e6);
        uint24 id = _skewPoolToTheOracle();
        vm.prank(KEEPER);
        v.openBand(id, 1, 0, 0, 0, block.timestamp + 120);
        (,,, bool has,) = v.bandState();
        assertTrue(has);
    }

    function test_rebalancePostSwapRecheckUsesTheRightPriceOrder() public {
        _fundAndOpen(100e6);
        uint24 id = _skewPoolToTheOracle();
        vm.prank(KEEPER);
        v.rebalance(id, 1, true, 10e6, 0, 0, 0, block.timestamp + 120);
        (uint24 lo,,,,) = v.bandState();
        assertEq(lo, id - 1);
    }

    // P10: openBand re-checks the pool after ITS OWN USDt -> USDC swap (the swap lands the active id 30 bins away, 30 bp off the oracle: bit 16 at a 20 bp bound)
    function test_openBandRechecksThePoolAfterAUsdtToUsdcSwap() public {
        IPharaohDlmmVault.GuardParams memory g = v.guardParams();
        g.maxPoolOracleDevBps = 20;
        g.maxRebalanceLossBps = 300;
        vm.prank(SAFE);
        v.setGuardParams(g);
        usdt.mint(address(v), 100e6); // idle USDt only: half of it is sold for USDC
        uint24 a = pair.getActiveId();
        bool up = usdcIsX; // selling USDt: it is Y when USDC is X (buys X: id rises), else X (sells into Y: id falls)
        for (uint24 i; i <= 5; ++i) {
            uint24 id = up ? a + i : a - i;
            uint256 bal = pair.balanceOf(WHALE, id);
            if (bal == 0) continue;
            uint256[] memory ids = new uint256[](1);
            uint256[] memory amts = new uint256[](1);
            ids[0] = id;
            amts[0] = bal;
            vm.prank(WHALE);
            pair.burn(WHALE, WHALE, ids, amts);
        }
        uint24 stone = up ? a + 30 : a - 30;
        usdc.mint(address(pair), 1_000_000e6);
        if (usdcIsX) pair.addToBin(stone, uint128(1_000_000e6), 0);
        else pair.addToBin(stone, 0, uint128(1_000_000e6));
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardUnsafe.selector, uint256(16)));
        v.openBand(a, 1, 0, 0, 0, block.timestamp + 120);
    }
}

/// @notice initialize-time validation: one fixture per check of PharaohDlmmPairValidator (and per half of the compound checks), each asserting the EXACT check number
contract MutationInitTest is Base {
    address internal implOnce;

    function setUp() public virtual {
        _deployWorld();
        implOnce = _deployImpl(_findCode());
    }

    function _selOf(bytes memory ret) internal pure returns (bytes4 s) {
        if (ret.length >= 4) {
            assembly {
                s := mload(add(ret, 32))
            }
        }
    }

    function _init(IPharaohDlmmVault.InitParams memory p) internal returns (bool ok, bytes memory ret) {
        try new TransparentUpgradeableProxy(implOnce, SAFE, abi.encodeCall(IVaultAdmin.initialize, (p))) returns (TransparentUpgradeableProxy) {
            ok = true;
        } catch (bytes memory r) {
            ret = r;
        }
    }

    function _expectCheck(IPharaohDlmmVault.InitParams memory p, uint8 check, string memory what) internal {
        (bool ok, bytes memory ret) = _init(p);
        assertFalse(ok, what);
        assertEq(_selOf(ret), IPharaohDlmmVault.PairValidationFailed.selector, what);
        uint256 w;
        assembly {
            w := mload(add(ret, 36))
        }
        assertEq(uint8(w), check, what);
        vm.clearMockedCalls();
    }

    function _mockInfo(IPharaohDlmmVault.InitParams memory p, uint16 step, address lbPair) internal {
        vm.mockCall(
            address(factory),
            abi.encodeWithSignature("getLBPairInformation(address,address,uint256)", p.asset, p.pairToken, uint256(p.binStep)),
            abi.encode(step, lbPair, false, false)
        );
    }

    function test_controlHealthyWorldInitialises() public {
        (bool ok,) = _init(_initParams());
        assertTrue(ok);
    }

    // ---- 1: a zero address or an empty field
    function _zeroField(IPharaohDlmmVault.InitParams memory p, uint256 i) internal pure {
        if (i == 0) p.asset = address(0);
        else if (i == 1) p.pairToken = address(0);
        else if (i == 2) p.pair = address(0);
        else if (i == 3) p.router = address(0);
        else if (i == 4) p.factory = address(0);
        else if (i == 5) p.rewarder = address(0);
        else if (i == 6) p.feedAsset = address(0);
        else if (i == 7) p.feedPair = address(0);
        else if (i == 8) p.rebalancer = address(0);
        else p.rewarderImplCodehash = bytes32(0);
    }

    function test_check1_everyZeroFieldIsRefused() public {
        for (uint256 i; i < 10; ++i) {
            IPharaohDlmmVault.InitParams memory p = _initParams();
            _zeroField(p, i);
            _expectCheck(p, 1, "zero field");
        }
    }

    /// a zero owner never reaches the validator: OwnableUpgradeable refuses it first (so the validator's own owner test is redundant)
    function test_zeroOwnerIsRefusedByOwnable() public {
        IPharaohDlmmVault.InitParams memory p = _initParams();
        p.owner = address(0);
        (bool ok, bytes memory ret) = _init(p);
        assertFalse(ok);
        assertEq(_selOf(ret), bytes4(keccak256("OwnableInvalidOwner(address)")));
    }

    // ---- 2
    function test_check2_assetEqualsPairToken() public {
        IPharaohDlmmVault.InitParams memory p = _initParams();
        p.pairToken = p.asset;
        _expectCheck(p, 2, "asset == pairToken");
    }

    // ---- 3
    function test_check3_registryHasNoPairOrAnotherPairOrAnotherBinStep() public {
        IPharaohDlmmVault.InitParams memory p = _initParams();
        _mockInfo(p, p.binStep, address(0));
        _expectCheck(p, 3, "registry returns no pair (bin step right)");
        _mockInfo(p, p.binStep, address(0xdead));
        _expectCheck(p, 3, "registry returns another pair");
        _mockInfo(p, p.binStep + 1, p.pair);
        _expectCheck(p, 3, "registry returns another bin step (pair right)");
    }

    // ---- 4
    function test_check4_pairDisagreesOnFactoryOrBinStep() public {
        IPharaohDlmmVault.InitParams memory p = _initParams();
        vm.mockCall(p.pair, abi.encodeWithSignature("getFactory()"), abi.encode(address(0xdead)));
        _expectCheck(p, 4, "pair.getFactory differs");
        vm.mockCall(p.pair, abi.encodeWithSignature("getBinStep()"), abi.encode(uint16(2)));
        _expectCheck(p, 4, "pair.getBinStep differs");
    }

    // ---- 5
    function test_check5_pairTokensAreNotExactlyTheTwoLegs() public {
        IPharaohDlmmVault.InitParams memory p = _initParams();
        vm.mockCall(p.pair, abi.encodeWithSignature("getTokenX()"), abi.encode(address(0xdead)));
        _expectCheck(p, 5, "tokenX is a stranger");
        vm.mockCall(p.pair, abi.encodeWithSignature("getTokenY()"), abi.encode(address(0xdead)));
        _expectCheck(p, 5, "tokenY is a stranger");
        vm.mockCall(p.pair, abi.encodeWithSignature("getTokenX()"), abi.encode(p.asset));
        vm.mockCall(p.pair, abi.encodeWithSignature("getTokenY()"), abi.encode(p.asset));
        _expectCheck(p, 5, "both tokens are the asset");
    }

    // ---- 6
    function test_check6_routerFromAnotherFactory() public {
        IPharaohDlmmVault.InitParams memory p = _initParams();
        vm.mockCall(p.router, abi.encodeWithSignature("getFactory()"), abi.encode(address(0xdead)));
        _expectCheck(p, 6, "router.getFactory differs");
    }

    // ---- 7
    function test_check7_hookIsNotTheRewarder() public {
        IPharaohDlmmVault.InitParams memory p = _initParams();
        vm.mockCall(p.pair, abi.encodeWithSignature("getLBHooksParameters()"), abi.encode(bytes32(uint256(uint160(address(0xdead))))));
        _expectCheck(p, 7, "hook != rewarder");
    }

    // ---- 8
    function test_check8_rewarderNotLinked() public {
        IPharaohDlmmVault.InitParams memory p = _initParams();
        vm.mockCall(p.rewarder, abi.encodeWithSignature("isLinked()"), abi.encode(false));
        _expectCheck(p, 8, "not linked");
    }

    // ---- 9
    function test_check9_voterZeroOrRouterNotAuthorised() public {
        IPharaohDlmmVault.InitParams memory p = _initParams();
        vm.mockCall(p.rewarder, abi.encodeWithSignature("owner()"), abi.encode(address(0)));
        _expectCheck(p, 9, "voter is zero");
        voter.setManager(address(router), false);
        _expectCheck(p, 9, "router not an authorised manager");
    }

    // ---- 10
    function test_check10_beaconZeroOrNotListingTheRewarder() public {
        IPharaohDlmmVault.InitParams memory p = _initParams();
        voter.setBeacon(address(0));
        _expectCheck(p, 10, "beacon is zero");
        voter.setBeacon(address(beacon));
        beacon.setRewarder(address(pair), address(0xdead));
        _expectCheck(p, 10, "beacon lists another rewarder for the pair");
    }

    // ---- 11
    function test_check11_codehashPin() public {
        IPharaohDlmmVault.InitParams memory p = _initParams();
        beacon.setImplementation(address(implB));
        _expectCheck(p, 11, "implementation differs from the pin");
        beacon.setImplementation(address(implA));
        p.rewarderImplCodehash = bytes32(uint256(1));
        _expectCheck(p, 11, "pin differs from the implementation");
    }

    // ---- 12
    function test_check12_rewardTokenZeroOrALeg() public {
        IPharaohDlmmVault.InitParams memory p = _initParams();
        vm.mockCall(p.rewarder, abi.encodeWithSignature("getRewardToken()"), abi.encode(address(0)));
        _expectCheck(p, 12, "reward token zero");
        vm.mockCall(p.rewarder, abi.encodeWithSignature("getRewardToken()"), abi.encode(p.asset));
        _expectCheck(p, 12, "reward token is the asset");
        vm.mockCall(p.rewarder, abi.encodeWithSignature("getRewardToken()"), abi.encode(p.pairToken));
        _expectCheck(p, 12, "reward token is the pair token");
    }

    // ---- 13: feed decimals (each feed) and the healthy-feeds read at deployment (13b)
    function test_check13_feedDecimalsEachFeed() public {
        IPharaohDlmmVault.InitParams memory p = _initParams();
        feedUsdc.setDecimals(6);
        _expectCheck(p, 13, "asset feed decimals");
        feedUsdc.setDecimals(8);
        feedUsdt.setDecimals(6);
        _expectCheck(p, 13, "pair feed decimals");
    }

    function test_check13b_unhealthyFeedsAtDeployment() public {
        IPharaohDlmmVault.InitParams memory p = _initParams();
        feedUsdc.setAnswerAt(1e8, block.timestamp - 100_000); // older than maxFeedAge 93_600
        _expectCheck(p, 13, "stale asset feed");
        feedUsdc.setAnswer(1e8);
        feedUsdt.setAnswer(0);
        _expectCheck(p, 13, "bad pair feed");
    }

    // ---- 14: token decimals <= 18 (each token); 18 itself is accepted
    function test_check14_tokenDecimalsAboveEighteen() public {
        IPharaohDlmmVault.InitParams memory p = _initParams();
        vm.mockCall(p.asset, abi.encodeWithSignature("decimals()"), abi.encode(uint8(19)));
        _expectCheck(p, 14, "asset decimals 19");
        vm.mockCall(p.pairToken, abi.encodeWithSignature("decimals()"), abi.encode(uint8(19)));
        _expectCheck(p, 14, "pair token decimals 19");
        vm.mockCall(p.pairToken, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        (bool ok,) = _init(p);
        assertTrue(ok, "18 decimals is accepted");
    }

    // ------------------------------------------------------------------ M21: bit 16 reads the decimals of the right leg (needs a bin step where |id - 2^23| <= 4096 can span 12 decimals: step 100)
    function test_bit16_decimalScalesAtBinStep100() public {
        vm.mockCall(address(usdt), abi.encodeWithSignature("decimals()"), abi.encode(uint8(18))); // USDC 6, USDt 18
        // human Y per X = raw * 10^dX / 10^dY = 1 needs raw = 1e-12 (X = USDt) or 1e12 (X = USDC): 1.01^2777 = 1.001e12
        uint24 id = usdcIsX ? ID0 + 2777 : ID0 - 2777;
        MockLBPair p2 = new MockLBPair(pair.tokenX(), pair.tokenY(), 100, id, address(factory));
        factory.setPair(pair.tokenX(), pair.tokenY(), 100, address(p2));
        p2.setHook(address(rewarder));
        beacon.setRewarder(address(p2), address(rewarder));
        IPharaohDlmmVault.InitParams memory p = _initParams();
        p.pair = address(p2);
        p.binStep = 100;
        address proxy = _deployVaultWith(p);
        (,, uint256 r) = IPharaohDlmmVault(proxy).guardState();
        assertEq(r & 16, 0, "pool at the decimal-adjusted peg is not a deviation");
        p2.forceActiveId(id + 1); // +1 %
        (,, r) = IPharaohDlmmVault(proxy).guardState();
        assertEq(r & 16, 16, "one bin up (1 %) deviates");
        p2.forceActiveId(id - 1);
        (,, r) = IPharaohDlmmVault(proxy).guardState();
        assertEq(r & 16, 16, "one bin down (1 %) deviates");
    }
}

contract MutationInitFlippedTest is MutationInitTest {
    function _flipped() internal pure override returns (bool) {
        return true;
    }
}

contract MutationFlippedTest is MutationTest {
    function _flipped() internal pure override returns (bool) {
        return true;
    }
}

/// @notice a router that performs the real swap but reports a different amount out (an honest-balance check: the vault must pay what its USDC balance gained)
contract LyingRouter {
    MockRouter public immutable real;
    address public immutable factoryAddr;
    int256 public lie;

    constructor(MockRouter r, address f, int256 l) {
        real = r;
        factoryAddr = f;
        lie = l;
    }

    function getFactory() external view returns (address) {
        return factoryAddr;
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, MockRouter.Path memory path, address to, uint256 deadline)
        external
        returns (uint256 out)
    {
        IERC20(path.tokenPath[0]).transferFrom(msg.sender, address(this), amountIn);
        IERC20(path.tokenPath[0]).approve(address(real), amountIn);
        out = real.swapExactTokensForTokens(amountIn, amountOutMin, path, to, deadline);
        out = lie >= 0 ? out + uint256(lie) : out - uint256(-lie);
    }
}

/// @notice B01..B05: `redeem` pays the USDC balance delta of the swap, never the router's returned amount
contract MutationPayoutTest is Base {
    function setUp() public virtual {
        _deployWorld();
    }

    /// returns (paid to the receiver, vault USDC before, vault USDC after, shares redeemed, supply before)
    function _redeemHalf(int256 lie) internal returns (uint256 paid, uint256 before_, uint256 after_, uint256 sh, uint256 supply) {
        LyingRouter lr = new LyingRouter(router, address(factory), lie);
        voter.setManager(address(lr), true);
        IPharaohDlmmVault.InitParams memory p = _initParams();
        p.router = address(lr);
        address proxy = _deployVaultWith(p);
        vm.prank(SAFE);
        IVaultAdmin(proxy).unpause();
        _mintTokens(ALICE, 100e6, 0);
        vm.startPrank(ALICE);
        usdc.approve(proxy, type(uint256).max);
        IERC4626Min(proxy).deposit(100e6, ALICE);
        vm.stopPrank();
        usdt.mint(proxy, 50e6); // idle USDt: the payout has a pair leg to swap
        sh = IERC20(proxy).balanceOf(ALICE) / 2;
        supply = IERC20(proxy).totalSupply();
        before_ = usdc.balanceOf(proxy);
        uint256 bob = usdc.balanceOf(BOB);
        vm.prank(ALICE);
        paid = IERC4626Min(proxy).redeem(sh, BOB, ALICE);
        after_ = usdc.balanceOf(proxy);
        assertEq(usdc.balanceOf(BOB) - bob, paid, "the receiver got exactly what redeem returned");
    }

    function _check(int256 lie) internal {
        (uint256 paid, uint256 before_, uint256 after_, uint256 sh, uint256 supply) = _redeemHalf(lie);
        // the vault keeps exactly the other holders' share of its idle USDC; every USDC the swap really delivered went to the receiver
        assertEq(after_, before_ - (before_ * sh) / supply, "vault USDC after = before - idle slice");
        assertGt(paid, (before_ * sh) / supply, "the swap leg was paid");
    }

    function test_redeemPaysTheBalanceDeltaWhenTheRouterOverstates() public {
        _check(1000);
    }

    function test_redeemPaysTheBalanceDeltaWhenTheRouterUnderstates() public {
        _check(-1);
    }

    function test_redeemPaysTheBalanceDeltaWhenTheRouterIsHonest() public {
        _check(0);
    }
}

interface IERC4626Min {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
}

contract MutationPayoutFlippedTest is MutationPayoutTest {
    function _flipped() internal pure override returns (bool) {
        return true;
    }
}

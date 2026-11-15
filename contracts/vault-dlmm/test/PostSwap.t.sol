// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Base} from "./Base.t.sol";
import {IPharaohDlmmVault} from "../src/IPharaohDlmmVault.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

/// @notice W10 F2 (vault commit 3726773c): `openBand` and `rebalance` re-check the pool-vs-oracle deviation AFTER the vault's own inventory swap and revert
///         GuardUnsafe(16) when that swap pushed the pool more than maxPoolOracleDevBps (60) from the oracle ratio. The mock pair's swap really moves the active bin,
///         so the scenario is built with a THIN pool: the output token sits in one-token bins spread over many bin steps, the vault's own swap walks through them.
///         The swap's average price stays inside the 0.5 % loss bound (about half of the final deviation), so the swap floor does NOT fire first: only the deviation
///         re-check can stop it. A thick pool (same swap) is the control and must succeed.
contract PostSwapTest is Base {
    function setUp() public virtual {
        _setUpVault();
    }

    bytes4 internal constant GUARD_UNSAFE = IPharaohDlmmVault.GuardUnsafe.selector;

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

    /// one-token liquidity of the OUTPUT token of the vault's swap: `perBin` in each of `nBins`+1 bins starting at the active bin and walking in the direction the swap will
    /// consume (X lives at ids >= active, Y at ids <= active)
    function _thin(bool needUsdt, uint256 perBin, uint24 nBins) internal {
        bool tokenIsX = needUsdt ? !usdcIsX : usdcIsX;
        uint256 total = perBin * (uint256(nBins) + 1);
        if (needUsdt) usdt.mint(WHALE, total);
        else usdc.mint(WHALE, total);
        int256[] memory d = new int256[](uint256(nBins) + 1);
        uint256[] memory dX = new uint256[](uint256(nBins) + 1);
        uint256[] memory dY = new uint256[](uint256(nBins) + 1);
        for (uint256 i; i <= nBins; ++i) {
            d[i] = tokenIsX ? int256(i) : -int256(i);
            if (tokenIsX) dX[i] = uint256(1e18) / (uint256(nBins) + 1);
            else dY[i] = uint256(1e18) / (uint256(nBins) + 1);
        }
        address xt = pair.tokenX();
        address yt = pair.tokenY();
        uint24 a = pair.getActiveId();
        vm.startPrank(WHALE);
        usdc.approve(address(router), type(uint256).max);
        usdt.approve(address(router), type(uint256).max);
        router.addLiquidity(
            MockRouter.LiquidityParameters(
                xt, yt, BIN_STEP, tokenIsX ? total : 0, tokenIsX ? 0 : total, 0, 0, a, 0, d, dX, dY, WHALE, WHALE, block.timestamp + 1
            )
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ openBand
    function test_openBand_wideSwapIsRefusedByTheRecheckBeforeActiveIdMoved() public {
        _deposit(ALICE, 100e6);
        _removeWhale();
        _thin(true, 0.7e6, 72); // 73 bins x 0.7 USDt: the vault's 50 USDC swap walks to about +71 bin steps (0.71 %)
        uint24 a = pair.getActiveId();
        bytes memory ret = _assertReverts(KEEPER, address(v), abi.encodeCall(IPharaohDlmmVault.openBand, (a, 1, 0, 0, 0, block.timestamp + 120)));
        assertEq(_sel(ret), GUARD_UNSAFE, "the post-swap deviation re-check fires, not the swap floor");
    }

    function _tail(bytes memory ret) internal pure returns (bytes memory out) {
        out = new bytes(ret.length - 4);
        for (uint256 i; i < out.length; ++i) out[i] = ret[i + 4];
    }

    function test_openBand_postSwapRevertCarriesBit16AndLeavesNoState() public {
        _deposit(ALICE, 100e6);
        _removeWhale();
        _thin(true, 0.7e6, 72);
        uint24 a = pair.getActiveId();
        uint256 usdcB = usdc.balanceOf(address(v));
        bytes memory ret = _assertReverts(KEEPER, address(v), abi.encodeCall(IPharaohDlmmVault.openBand, (a, 1, 0, 0, 0, block.timestamp + 120)));
        assertEq(_sel(ret), GUARD_UNSAFE);
        assertEq(abi.decode(_tail(ret), (uint256)), 16, "reason bit 16 (pool vs oracle) only");
        assertFalse(_hasBand());
        assertEq(usdc.balanceOf(address(v)), usdcB, "the swap was rolled back");
        assertEq(pair.getActiveId(), a, "the pool is untouched");
    }

    // ------------------------------------------------------------------ rebalance, both directions
    function _rebalanceAfterThinning(bool up) internal returns (bytes memory ret) {
        _fundAndOpen(100e6);
        _pushOut(up);
        (uint256 c, uint256 t) = _holdings();
        bool overUsdc = c >= t;
        _removeWhale();
        _thin(overUsdc, 0.7e6, 72); // the OUTPUT token of the half swap is the one the vault does not hold
        ret = _assertReverts(KEEPER, address(v), _rebalanceCall());
    }

    function test_rebalance_wideSwapIsRefusedByTheRecheck_up() public {
        bytes memory ret = _rebalanceAfterThinning(true);
        assertEq(_sel(ret), GUARD_UNSAFE);
        assertEq(abi.decode(_tail(ret), (uint256)), 16);
    }

    function test_rebalance_wideSwapIsRefusedByTheRecheck_down() public {
        bytes memory ret = _rebalanceAfterThinning(false);
        assertEq(_sel(ret), GUARD_UNSAFE);
        assertEq(abi.decode(_tail(ret), (uint256)), 16);
    }

    function test_rebalance_revertIsAtomic() public {
        _fundAndOpen(100e6);
        _pushOut(true);
        _removeWhale();
        (uint256 c, uint256 t) = _holdings();
        _thin(c >= t, 0.7e6, 72);
        uint256 navB = _oracleNav();
        (uint24 lo, uint24 hi,,,) = v.bandState();
        uint24 a = pair.getActiveId();
        _assertReverts(KEEPER, address(v), _rebalanceCall());
        assertEq(_oracleNav(), navB);
        (uint24 lo2, uint24 hi2,,,) = v.bandState();
        assertEq(lo, lo2);
        assertEq(hi, hi2);
        assertEq(pair.getActiveId(), a);
        assertEq(v.rebalancesToday(), 0);
    }

    // ------------------------------------------------------------------ the re-check ALONE: a swap that moves the pool only 2 bin steps (inside idSlippage 2, so ActiveIdMoved
    // does not fire) from a pool/oracle deviation of 58.5 bp to 60.5 bp. Which side is "away" depends on the swap direction, so both signs of the oracle skew are run:
    // exactly one of them may pass the pre-swap guard AND then be pushed over the 60 bp tolerance by the vault's own swap.

    /// oracle ratio (Y per X, the pair order) set to `tenthBps`/10 bp away from 1.00, split over the two feeds so both legs stay inside their 50 bp band
    function _setRatioTenthBps(int256 tenthBps) internal {
        int256 half = tenthBps * 1e3 / 2; // 0.1 bp = 1e3 in 8-decimal USD
        uint256 num = uint256(int256(1e8) + half);
        uint256 den = uint256(int256(1e8) - half);
        // nonflipped: X = USDt, ratio = feedPair / feedAsset; flipped: X = USDC, ratio = feedAsset / feedPair
        if (!usdcIsX) {
            feedUsdt.setAnswer(int256(num));
            feedUsdc.setAnswer(int256(den));
        } else {
            feedUsdc.setAnswer(int256(num));
            feedUsdt.setAnswer(int256(den));
        }
    }

    function _skewAroundPool(int256 sign, int256 devTenthBps) internal {
        int256 k = int256(uint256(pair.getActiveId())) - int256(uint256(ID0)); // pool price = 1 + k bp
        _setRatioTenthBps(k * 10 + sign * devTenthBps);
    }

    /// with the DEFAULT maxRebalanceLossBps (50 bp) the swap floor (oracle out minus 0.5 %) fires first when the pool is 58 bp worse than the oracle, so the re-check alone is
    /// only reachable with the loss bound widened (owner-settable up to 300): this is itself an observation, see the report
    function _widenLossBound() internal {
        IPharaohDlmmVault.GuardParams memory g = v.guardParams();
        g.maxRebalanceLossBps = 300;
        vm.prank(SAFE);
        v.setGuardParams(g);
    }

    function _openBandWithSkew(int256 sign, int256 dev, uint24 idSlip) internal returns (bool ok, bytes memory ret) {
        _deposit(ALICE, 100e6);
        _widenLossBound();
        _removeWhale();
        _thin(true, 24e6, 3); // 4 bins x 24 USDt: the vault's 50 USDC swap ends 2 bins away
        _skewAroundPool(sign, dev);
        uint24 a = pair.getActiveId();
        vm.prank(KEEPER);
        (ok, ret) = address(v).call(abi.encodeCall(IPharaohDlmmVault.openBand, (a, idSlip, 0, 0, 0, block.timestamp + 120)));
    }

    function test_openBand_recheckAlone_oneSignOfTheSkewIsPushedOver() public {
        uint256 snap = vm.snapshotState();
        (bool okP, bytes memory retP) = _openBandWithSkew(1, 585, 2);
        vm.revertToState(snap);
        (bool okM, bytes memory retM) = _openBandWithSkew(-1, 585, 2);
        // the swap moves the pool one way: away from one oracle skew and towards the other
        assertTrue(okP != okM, "exactly one direction ends beyond 60 bp");
        bytes memory bad = okP ? retM : retP;
        assertEq(_sel(bad), GUARD_UNSAFE, "refused by the post-swap deviation re-check");
        assertEq(abi.decode(_tail(bad), (uint256)), 16);
    }

    function test_openBand_recheckAlone_benignSkewSucceeds_control() public {
        // 50 bp away before and 52 bp after the swap in the worst direction: inside the 60 bp tolerance, the band opens (both signs)
        uint256 snap = vm.snapshotState();
        (bool okP,) = _openBandWithSkew(1, 500, 2);
        vm.revertToState(snap);
        (bool okM,) = _openBandWithSkew(-1, 500, 2);
        assertTrue(okP && okM, "control: the same swap passes when the deviation stays under the tolerance");
    }

    function test_openBand_recheckAlone_followsTheParameter() public {
        // the failing direction passes once maxPoolOracleDevBps is widened to 300 (pre-swap guard AND post-swap re-check use the same parameter)
        uint256 snap = vm.snapshotState();
        (bool okP,) = _openBandWithSkew(1, 585, 2);
        vm.revertToState(snap);
        (bool okM,) = _openBandWithSkew(-1, 585, 2);
        int256 failing = okP ? int256(-1) : int256(1);
        assertTrue(okP != okM);
        vm.revertToState(snap);
        IPharaohDlmmVault.GuardParams memory g = v.guardParams();
        g.maxPoolOracleDevBps = 300;
        vm.prank(SAFE);
        v.setGuardParams(g);
        (bool ok,) = _openBandWithSkew(failing, 585, 2);
        assertTrue(ok, "inside a 300 bp tolerance the same swap passes");
    }

    function _rebalanceWithSkew(bool up, int256 sign, int256 dev) internal returns (bool ok, bytes memory ret) {
        _fundAndOpen(100e6);
        _widenLossBound();
        _pushOut(up);
        (uint256 c, uint256 t) = _holdings();
        _removeWhale();
        _thin(c >= t, 24e6, 3);
        _skewAroundPool(sign, dev);
        // like _rebalanceCall but with idSlippage 2 (the swap itself moves the active bin by 2 steps on this thin pool)
        bool overUsdc = c >= t;
        bool swapXForY = overUsdc ? usdcIsX : !usdcIsX;
        uint256 swapIn = (overUsdc ? c : t) / 2;
        bytes memory cd = abi.encodeCall(
            IPharaohDlmmVault.rebalance, (pair.getActiveId(), 2, swapXForY, swapIn, (swapIn * 9_700) / 10_000, 0, 0, block.timestamp + 120)
        );
        vm.prank(KEEPER);
        (ok, ret) = address(v).call(cd);
    }

    function _rebalanceRecheckAlone(bool up) internal {
        uint256 snap = vm.snapshotState();
        (bool okP, bytes memory retP) = _rebalanceWithSkew(up, 1, 585);
        vm.revertToState(snap);
        (bool okM, bytes memory retM) = _rebalanceWithSkew(up, -1, 585);
        vm.revertToState(snap);
        emit log_named_string("sign +", okP ? "ok" : "revert");
        emit log_named_bytes32("  sel", bytes32(_sel(retP)));
        if (!okP && _sel(retP) == IPharaohDlmmVault.ActiveIdMoved.selector) {
            (uint24 e, uint24 ac, uint24 sl) = abi.decode(_tail(retP), (uint24, uint24, uint24));
            emit log_named_uint("expected", e);
            emit log_named_uint("actual", ac);
            emit log_named_uint("slip", sl);
        }
        emit log_named_string("sign -", okM ? "ok" : "revert");
        emit log_named_bytes32("  sel", bytes32(_sel(retM)));
        assertTrue(okP != okM, "exactly one direction ends beyond 60 bp");
        bytes memory bad = okP ? retM : retP;
        assertEq(_sel(bad), GUARD_UNSAFE);
        assertEq(abi.decode(_tail(bad), (uint256)), 16);
        // control: 50 bp skew passes in both directions
        (okP,) = _rebalanceWithSkew(up, 1, 500);
        vm.revertToState(snap);
        (okM,) = _rebalanceWithSkew(up, -1, 500);
        assertTrue(okP && okM, "control: benign skew passes both ways");
    }

    function test_rebalance_recheckAlone_up() public {
        _rebalanceRecheckAlone(true);
    }

    function test_rebalance_recheckAlone_down() public {
        _rebalanceRecheckAlone(false);
    }
}

contract PostSwapFlippedTest is PostSwapTest {
    function _flipped() internal pure override returns (bool) {
        return true;
    }
}

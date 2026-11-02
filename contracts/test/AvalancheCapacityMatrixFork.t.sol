// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AvalancheMatrixEngine.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @notice Handoff 00 section 4 / handoff 09 section 5 CAPACITY MATRIX on an Avalanche fork. Tests only.
 *
 * Every scenario runs the REAL contracts (controller, markets, margin stack, `PharaohCLRouterAdapter`, the real
 * Pharaoh router and WAVAX/USDC pool) from a snapshot of the pinned state and logs one machine-readable line:
 *
 *   MX|slice|cfg|side|marginUsd|k|path|lagBps|removalBps|step|poolBps|oracleBps|liqable|ok|revert|
 *      repayC|seizedC|rewardC|surplusC|insuranceC|residualC|worstCostBps|execE8|poolE8|oracleE8|gas
 *
 * (amounts in USD cents; bps relative to the pinned AVAX price; see tools/avalanche-capacity-report.py).
 *
 * Evidence classes, never mixed:
 *   path=oracle  : MOCKED oracle only, pool untouched (original fork pool).
 *   path=pool    : pool moved by REAL swaps (WHALE) and the oracle follows the pool price.
 *   path=lag     : pool moved by REAL swaps, oracle only follows `lagBps` of the way back toward the pin.
 *   removal>0    : EMULATED third-party liquidity removal: the adapter's router is replaced by a shim that executes
 *                  swaps of size 1/(1-r) in the real pool and returns (1-r) of the output. Exact for uniform removal
 *                  of third-party liquidity at all ticks (CL scale invariance); NOT a model of LPs leaving selectively.
 *   cfg ALT-*    : alternative risk parameters or LOOSENED GUARDS, shown for comparison; only `cand-2x25` is the
 *                  candidate launch configuration.
 *
 * Run: see the header of AvalancheSection5Base.sol; add --match-contract AvalancheCapacityMatrixForkTest -vv, then
 *   python3 tools/avalanche-capacity-report.py <forge output>.
 */
contract AvalancheCapacityMatrixForkTest is AvalancheMatrixEngine {

    // A. MOCKED oracle only, pool untouched, one position.
    function testMatrix_A_oracleOnly_singlePosition() public {
        _slice("oracle-only", 0, 0, 0, 0, 0, 4, _sizes1(1_000, 5_000, 25_000), 1);
    }

    // B. REAL pool swaps, oracle follows the pool (consistent adverse path), one position.
    function testMatrix_B_poolFollows_singlePosition() public {
        _slice("pool-follows", 1, 0, 0, 0, 0, 4, _sizes1(1_000, 5_000, 25_000), 1);
    }

    // C. REAL pool swaps, oracle lags: 50% and 90% of the move still to come.
    function testMatrix_C1_oracleLag50() public {
        _slice("lag50", 2, 5_000, 0, 0, 0, 2, _sizes1(1_000, 5_000, 25_000), 1);
    }

    function testMatrix_C2_oracleLag90() public {
        _slice("lag90", 2, 9_000, 0, 0, 0, 2, _sizes1(1_000, 5_000, 25_000), 1);
    }

    // C3. Oracle a FIXED absolute gap behind the REAL pool: 50 / 100 / 200 bps (reachable between feed updates)
    function testMatrix_C3_fixedLag50() public {
        _slice("fixedlag50", 3, 50, 0, 0, 0, 2, _sizes1(1_000, 5_000, 25_000), 1);
    }

    function testMatrix_C4_fixedLag100() public {
        _slice("fixedlag100", 3, 100, 0, 0, 0, 2, _sizes1(1_000, 5_000, 25_000), 1);
    }

    function testMatrix_C5_fixedLag200() public {
        _slice("fixedlag200", 3, 200, 0, 0, 0, 2, _sizes1(1_000, 5_000, 25_000), 1);
    }

    // D. EMULATED removal of 50% of third-party liquidity (shim), pool follows.
    function testMatrix_D_removal50_poolFollows() public {
        _slice("removal50", 1, 0, 5_000, 0, 0, 2, _sizes1(1_000, 5_000, 25_000), 1);
    }

    // E. 90 days of accrued debt and a 9 bps flash fee.
    function testMatrix_E_accrual90d_flashFee9() public {
        _slice("accrual90d-fee9", 1, 0, 0, 90, 9, 2, _sizes1(1_000, 5_000, 25_000), 1);
    }

    // F. Correlated sequential liquidations: k positions of the same size, largest first, pool/cash/funding updated.
    function testMatrix_F1_aggregate_1k_x5() public {
        _slice("agg-k5", 1, 0, 0, 0, 0, 2, _sizes(1_000), 5);
    }

    function testMatrix_F2_aggregate_5k_x10() public {
        _slice("agg-k10", 1, 0, 0, 0, 0, 2, _sizes(5_000), 10);
    }

    function testMatrix_F3_aggregate_25k_x4() public {
        _slice("agg-k4", 1, 0, 0, 0, 0, 2, _sizes(25_000), 4);
    }



    // F4-F7. The handoff 00 section 4 aggregate: correlated sequential positions UNDER the stress (50% of third-party
    // liquidity removed, emulated) and with the oracle 100 bps behind the pool.
    function testMatrix_F4_aggregate_k5_removal50() public {
        _slice("agg-k5-removal50", 1, 0, 5_000, 0, 0, 2, _sizes(1_000), 5);
    }

    function testMatrix_F5_aggregate_k10_removal50() public {
        _slice("agg-k10-removal50", 1, 0, 5_000, 0, 0, 2, _sizes(5_000), 10);
    }

    function testMatrix_F6_aggregate_k5_fixedLag100() public {
        _slice("agg-k5-fixedlag100", 3, 100, 0, 0, 0, 2, _sizes(1_000), 5);
    }

    function testMatrix_F7_aggregate_k10_fixedLag100() public {
        _slice("agg-k10-fixedlag100", 3, 100, 0, 0, 0, 2, _sizes(5_000), 10);
    }

    // ------------------------------------------------------------------ G. ordinary lending liquidations
    function testMatrix_G_ordinaryLending() public {
        snapPre = vm.snapshotState();
        for (uint256 dir; dir < 2; ++dir) {
            uint256[3] memory utils = [uint256(70), 90, 99];
            uint256[2] memory counts = [uint256(1), 5];
            for (uint256 ui; ui < utils.length; ++ui) {
                for (uint256 ci; ci < counts.length; ++ci) {
                    _ordinary(dir == 1, utils[ui], counts[ci], type(uint256).max);
                }
            }
        }
    }

    // G2. ordinary lending after a price GAP (no intermediate liquidations): jump straight to the step price
    function testMatrix_G2_ordinaryGap() public {
        snapPre = vm.snapshotState();
        for (uint256 dir; dir < 2; ++dir) {
            uint256[2] memory utils = [uint256(70), 99];
            uint256[4] memory steps = [uint256(3), 5, 6, 7];
            for (uint256 ui; ui < utils.length; ++ui) {
                for (uint256 si; si < steps.length; ++si) {
                    _ordinary(dir == 1, utils[ui], 5, steps[si]);
                }
            }
        }
    }

    struct Ord {
        bool usdcCol;
        bool gap;
        uint256 util;
        uint256 n;
        PErc20Delegator colM;
        PErc20Delegator debtM;
        address debtAsset;
        address colAsset;
        address[] bs;
    }

    function _ordinary(bool usdcCollateral, uint256 util, uint256 n, uint256 onlyStep) internal {
        vm.revertToState(snapPre);
        snapPre = vm.snapshotState();
        _setPrices(avaxAnswer, usdcAnswer); // vm.mockCall state survives revertToState: re-serve the pinned answers
        _scaleVenues();
        _activateLendingBorrows();
        Ord memory o;
        o.usdcCol = usdcCollateral;
        o.gap = onlyStep != type(uint256).max;
        o.util = util;
        o.n = n;
        o.colM = usdcCollateral ? pUsdc : pWavax;
        o.debtM = usdcCollateral ? pWavax : pUsdc;
        o.debtAsset = usdcCollateral ? WAVAX : USDC;
        o.colAsset = usdcCollateral ? USDC : WAVAX;
        o.bs = new address[](n);
        for (uint256 i; i < n; ++i) {
            o.bs[i] = address(uint160(0x9000 + i));
            _mintP(o.colM, o.bs[i], usdcCollateral ? 10_000e6 : Math.mulDiv(10_000e6 * 1e12, 1e8, uint256(realAvaxAnswer)));
            _enter(o.bs[i]);
            (, uint256 liq,) = controller.getAccountLiquidity(o.bs[i]);
            uint256 amt = usdcCollateral ? Math.mulDiv(liq * util / 100, 1e8, uint256(realAvaxAnswer)) : liq * util / 100 / 1e12;
            (bool ok,) = _borrow(o.debtM, o.bs[i], amt);
            require(ok, string.concat("ordinary setup borrow util=", _u(util)));
        }
        for (uint256 st; st < 8; ++st) {
            if (onlyStep != type(uint256).max && st != onlyStep) continue; // gap: jump straight to this price
            _ordinaryStep(o, st);
        }
    }

    function _ordinaryStep(Ord memory o, uint256 st) internal {
        uint256[8] memory dn = [uint256(9_000), 8_000, 7_000, 6_000, 5_000, 4_000, 3_000, 2_000];
        uint256[8] memory up = [uint256(11_000), 12_500, 15_000, 17_500, 20_000, 25_000, 30_000, 40_000];
        uint256 target = o.usdcCol ? up[st] : dn[st];
        _setAvaxBps(target);
        uint256[6] memory agg; // inShortfall, repayC, netSeizedC, protocolC, residualDebtC, badDebtC
        for (uint256 i; i < o.n; ++i) _ordinaryBorrower(o, o.bs[i], agg);
        emit log_string(
            string.concat(
                "OX|", o.gap ? "GAP " : "path ", o.usdcCol ? "usdc-collateral/wavax-debt" : "wavax-collateral/usdc-debt", "|", _u(o.util), "|", _u(o.n), "|", _u(st), "|",
                _u(target), "|", _u(agg[0]), "|", _u(agg[1]), "|", _u(agg[2]), "|", _u(agg[3]), "|", _u(agg[4]), "|", _u(agg[5]), "|END"
            )
        );
    }

    function _ordinaryBorrower(Ord memory o, address b, uint256[6] memory agg) internal {
        (,, uint256 sf) = controller.getAccountLiquidity(b);
        if (sf == 0) return;
        agg[0]++;
        for (uint256 it; it < 12; ++it) {
            (,, uint256 sf2) = controller.getAccountLiquidity(b);
            if (sf2 == 0 || o.colM.balanceOf(b) == 0) break;
            uint256 repay = o.debtM.borrowBalanceCurrent(b) / 2; // close factor
            bool done;
            // a sophisticated liquidator halves the repay until the seize fits the remaining collateral
            for (uint256 h; h < 12 && repay > 0; ++h) {
                (bool ok,, uint256 seized) = _liquidateOrdinary(o.debtM, o.colM, b, repay);
                if (ok) {
                    agg[1] += _cents(o.debtAsset, repay);
                    uint256 net = _cents(o.colAsset, Math.mulDiv(seized, o.colM.exchangeRateStored(), 1e18));
                    agg[2] += net;
                    agg[3] += net * 28 / 972;
                    done = true;
                    break;
                }
                repay /= 2;
            }
            if (!done) break;
        }
        uint256 left = _cents(o.debtAsset, o.debtM.borrowBalanceStored(b));
        uint256 collLeft = _cents(o.colAsset, Math.mulDiv(o.colM.balanceOf(b), o.colM.exchangeRateStored(), 1e18));
        agg[4] += left;
        if (left > collLeft) agg[5] += left - collLeft; // debt not covered by remaining collateral
    }

    // ------------------------------------------------------------------ H. swap-guard reconciliation
    /// @dev Calls the REAL IsolatedMarginSwapModule with the oracle placed above/below the pool price and logs the
    ///      oracle price, pool price, expected/min/actual output and the exact revert, in both directions.
    ///      The module's conditions: protocolMinOut = expectedOut(oracle) * (1 - maxSlippageBps); the adapter hands
    ///      max(userMin, protocolMinOut) to the router, which reverts "Too little received" when the pool pays less;
    ///      afterwards SwapError(7) if out < min and SwapError(8) if oracleValue(out) < oracleValue(in)*(1-dev).
    ///      Favourable execution (pool pays MORE than the oracle expects) always passes: it is not a symmetric check.
    function testSwapGuard_directionTable() public {

        int256[13] memory d = [int256(-300), -150, -101, -100, -99, -50, 0, 50, 99, 100, 101, 150, 300];
        uint256 snap = vm.snapshotState();
        _activate();
        for (uint256 dir; dir < 2; ++dir) {
            for (uint256 j; j < d.length; ++j) {
                vm.revertToState(snap);
                snap = vm.snapshotState();
                _guardPoint(dir == 1, d[j], 5_000e6, 100, 100, "candidate-guard");
            }
        }
        // ALTERED GUARD (diagnostic only, not a candidate): slippage 300 / deviation 50 makes SwapError(8) reachable.
        int256[3] memory dd = [int256(250), 100, 40]; // oracle ABOVE the pool: the sell leg is UNFAVOURABLE
        for (uint256 j; j < dd.length; ++j) {
            vm.revertToState(snap);
            snap = vm.snapshotState();
            _guardPoint(false, dd[j], 5_000e6, 300, 50, "ALTERED-guard-slip300-dev50");
        }
    }

    function _guardPoint(bool buyWavax, int256 deltaBps, uint256 usd6, uint16 slip, uint16 dev, string memory label) internal {
        int256 poolAns = _poolAnswer8();
        int256 oracleAns = poolAns + poolAns * deltaBps / 10_000; // oracle relative to the pool
        _setPrices(oracleAns, usdcAnswer);
        address tin = buyWavax ? USDC : WAVAX;
        address tout = buyWavax ? WAVAX : USDC;
        uint256 amountIn = buyWavax ? usd6 : Math.mulDiv(usd6 * 1e12, 1e8, uint256(poolAns));
        deal(tin, address(this), amountIn);
        IERC20(tin).approve(address(swapModule), amountIn);
        uint256 expected = quoter.expectedOut(tin, tout, amountIn);
        uint256 minOut = Math.mulDiv(expected, 10_000 - slip, 10_000);
        uint256 snap = vm.snapshotState();
        (bool ok, bytes memory ret) = address(swapModule)
            .call(abi.encodeWithSelector(IsolatedMarginSwapModule.executeSwap.selector, tin, tout, amountIn, uint256(0), slip, dev, bytes("")));
        uint256 actual;
        if (ok) {
            actual = abi.decode(ret, (uint256));
        } else {
            // learn what the pool would actually pay, by trading it directly in a reverted branch
            vm.revertToState(snap);
            IERC20(tin).approve(address(clAdapter), amountIn);
            (bool ok2, uint256 o2) = _adapterOut(tin, tout, amountIn);
            actual = ok2 ? o2 : 0;
        }
        uint256 execE8 = actual == 0 ? 0 : (buyWavax ? Math.mulDiv(amountIn, 1e20, actual) : Math.mulDiv(actual, 1e20, amountIn));
        emit log_string(
            string.concat(
                "SG|", label, "|", buyWavax ? "buy-WAVAX" : "sell-WAVAX", "|", _i(deltaBps), "|oracleE8=", _i(oracleAns), "|poolE8=", _i(poolAns),
                "|expectedOut=", _u(expected), "|minOut=", _u(minOut), "|actualOut=", _u(actual), "|execE8=", _u(execE8)
            )
        );
        emit log_string(string.concat("SG2|", ok ? "PASS" : "REVERT", "|", ok ? "-" : _revName(ret), "|END"));
    }

    function _adapterOut(address tin, address tout, uint256 amountIn) internal returns (bool, uint256) {
        try clAdapter.swap(address(this), tin, tout, amountIn, 1, "") returns (uint256 o) {
            return (true, o);
        } catch {
            return (false, 0);
        }
    }
}

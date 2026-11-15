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
/// @notice Funded in-kind fallback with FINITE funding, run at the same stressed state after the normal route.
contract AvalancheFallbackMatrixForkTest is AvalancheMatrixEngine {
    // ------------------------------------------------------------------ FB. funded in-kind fallback, finite budgets
    // Normal route first, then the funded route at the same state. One funder, funded once (30k USDC, 3,500 WAVAX),
    // no replenishment, cumulative inventory. Break-even floor (minSeizeValueBps = 10_000) unless stated.
    function _fbSlice(string memory slice, uint8 path, uint16 lag, uint16 accrual, uint16 flashFee, uint256 cfgCount, uint256[] memory sizes, uint256 k, uint8 mode, uint256 peg8) internal {
        fbMode = mode;
        usdcPeg8 = peg8;
        _slice(slice, path, lag, 0, accrual, flashFee, cfgCount, sizes, k);
        fbMode = 0;
        usdcPeg8 = 0;
    }

    function testFallback_A_mockedOracle() public {
        _fbSlice("fb-oracle-only", 0, 0, 0, 0, 2, _sizes1(1_000, 5_000, 25_000), 1, 1, 0);
    }

    function testFallback_B_poolFollows() public {
        _fbSlice("fb-pool-follows", 1, 0, 0, 0, 2, _sizes1(1_000, 5_000, 25_000), 1, 1, 0);
    }

    function testFallback_C_fixedLag100() public {
        _fbSlice("fb-fixedlag100", 3, 100, 0, 0, 2, _sizes1(1_000, 5_000, 25_000), 1, 1, 0);
    }

    function testFallback_D_usdcDepeg98_lag100() public {
        _fbSlice("fb-depeg98-lag100", 3, 100, 0, 0, 1, _sizes1(1_000, 5_000, 25_000), 1, 1, 98_000_000);
    }

    function testFallback_E_accrual90d_fee9() public {
        _fbSlice("fb-accrual90d-fee9", 1, 0, 90, 9, 1, _sizes2(5_000, 25_000), 1, 1, 0);
    }

    function testFallback_F1_aggregate_k5() public {
        _fbSlice("fb-agg-k5", 1, 0, 0, 0, 1, _sizes(1_000), 5, 1, 0);
    }

    function testFallback_F2_aggregate_k10() public {
        _fbSlice("fb-agg-k10", 1, 0, 0, 0, 1, _sizes(5_000), 10, 1, 0);
    }

    function testFallback_F3_aggregate_k4() public {
        _fbSlice("fb-agg-k4", 1, 0, 0, 0, 1, _sizes(25_000), 4, 1, 0);
    }

    /// @dev Zero cash in the market where the seized pTokens would be redeemed: the funded route still settles, the
    ///      inventory is NOT redeemable (redeemable-now = 0). Mocked oracle path (reference price regime).
    function testFallback_H_zeroCash() public {
        drainMode = true;
        _fbSlice("fb-zerocash-oracle-only", 0, 0, 0, 0, 1, _sizes1(1_000, 5_000, 25_000), 1, 1, 0);
        drainMode = false;
    }

    function testFallback_G_noFloor_funderAbsorbsLoss() public {
        _fbSlice("fb-nofloor-pool-follows", 1, 0, 0, 0, 1, _sizes1(1_000, 5_000, 25_000), 1, 2, 0);
    }

}

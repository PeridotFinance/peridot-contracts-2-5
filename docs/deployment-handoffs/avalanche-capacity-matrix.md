# Avalanche capacity matrix: pinned WAVAX/USDC route (handoff 00 section 4, handoff 09 section 5)

Branch `avalanche-pharaoh-tracks-abcd`. Tests only: nothing signed or broadcast, no keys, borrowing (track B) and trading (track C) stay paused in every deployment this work describes.
Reproduce: `AVALANCHE_MAINNET_RPC_URL=<archive RPC> contracts/tools/run-avalanche-capacity-matrix.sh` (test: `contracts/test/AvalancheCapacityMatrixFork.t.sol`, report generator: `contracts/tools/avalanche-capacity-report.py`). The tables below are generated from the forge output of that script.

## Pinned state and configuration

| Item | Value |
| --- | --- |
| Chain / block | Avalanche C-Chain 43114, block **99,200,000**, hash `0x221a26c046d7c21cd8dc88ea808ccf2b0e9811916e1f091cc4b3222c5e11fd97`, timestamp 1793604320 (2026-11-02 07:25:20 UTC) |
| Tokens | native USDC `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E`, WAVAX `0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7` |
| Pool / router / factory | `0xf01449C0bA930B6e2CaCA3DEF3CCBd7a3E589534` (tick spacing 10, fee 490 ppm) / `0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c` / `0xAE6E5c62328ade73ceefD42228528b70c8157D0d`; adapter `PharaohCLRouterAdapter` pinned to them |
| Pool state at pin | pool price 855,522,072 (USD/AVAX x1e8) vs Chainlink 854,911,000 (7 bps apart); about 513k WAVAX and USD 95.8k USDC held; active liquidity 2.22e19 |
| Feeds / oracle | AVAX/USD `0x0A77230d17318075983913bC2145DB16C7366156` max age 1,200 s; USDC/USD `0xF096872672F44d6EBA71458D74fe67F9a77a23B9` max age 90,000 s; `GuardedAvalanchePriceOracle` over `AvalanchePriceOracle` (no emergency price), same instance for controller, risk engine and quoter. After the first warp the pinned answers are re-served by `vm.mockCall` (class `oracle`/`pool` below) |
| Lending (PARAM placeholders) | plain delegates, CF WAVAX 60% / USDC 75%, close factor 50%, incentive 1.08, protocol seize 2.8%, reserve factor 10%, jump-rate model 2% base / 10% multiplier / 100% jump / 80% kink, 31,536,000 blocks per year; matrix venue sizing: supplier cash USD 3.4M USDC and 112k WAVAX, borrow caps 2.5M USDC / 90k WAVAX, flash vault 3.2M USDC and 105k WAVAX |
| Margin (candidate `cand-2x25`) | 2x max, initial margin 50%, maintenance 25%, liquidation target 125%, full-liquidation health 50%, max liquidation 50% of debt per call, keeper bonus 5%, **max slippage 100 bps, oracle deviation 100 bps**, flash fee 0 (9 bps in the accrual slice), pair caps set high (10M USD) so caps never mask the measured limit; pairs: long = margin pUSDC / position pWAVAX / debt pUSDC, short = margin pUSDC / position pUSDC / debt pWAVAX |
| Alternatives (labelled `ALT-*`, not the candidate) | `ALT-2x40` maintenance 40%; `ALT-1.5x25` leverage 1.5x (initial margin 67%, the stack requires at least 1/leverage); `ALT-guard300-2x25` LOOSENED guards 300/300 bps (diagnostic only) |
| Insurance fund | seeded with about 1% of each market in pTokens (USD 5k USDC + 150 WAVAX equivalent) in the base harness |

## Evidence classes (never mixed)

1. **Original fork observations**: pool depth curve, adapter ladder, pool/oracle facts (`avalanche-section5-fork-results.md`).
2. **Mocked oracle** (`oracle-only`): the oracle is moved by `vm.mockCall`, the pool is untouched. Favourable-state evidence for longs (selling into an unchanged pool at a price better than the shocked oracle); never used for caps.
3. **Pool moved by REAL swaps** (`pool-follows`, `lag*`, `fixedlag*`, `agg-*`): a funded whale trades the real router/pool until the target price; the oracle follows the pool (`pool-follows`), lags it by a fraction of the move still to come (`lag50`, `lag90`), or sits a fixed 50/100/200 bps behind it (`fixedlag*`).
4. **Emulated third-party liquidity removal** (`removal50`): the adapter's router is swapped for a shim that executes 2x-size swaps in the real pool and forwards half the output. Exact for uniform removal of 50% of third-party liquidity at every tick (CL scale invariance); it does NOT model selective LP exits (near-the-money LPs leaving first is worse). Real removal through the position manager was not feasible: the pool uses non-standard storage and 126,057 position NFTs exist.
5. **Ordinary lending** (`path`/`GAP`): no swap, a funded liquidator repays and takes pTokens through `liquidateBorrow`.

Separate: cash-only B/C only. No strategy (track D) scenario is included and D deployment is not required.

## Reading the margin tables

- A position is attempted for liquidation only when the oracle says it is liquidatable. "Trigger" is the oracle price (bps of pin) at the first liquidatable step; "pool floor" means the pool price had been pushed below 2% of pin, i.e. the trigger lies in a region with no liquidity.
- The pool's sell side is a wall (about USD 98.5k, price falls 10% after about USD 90k and then collapses); the buy side is a wall at about +50% (about USD 4.9M). Between the wall and the next liquid price there is no stable pool price, so triggers inside that gap are only reachable by exhausting the pool; those rows show `pool floor` or a price near 225% and the liquidation fails.
- `repaid`, `seized`, `keeper reward`, `borrower surplus` are USD summed over the successful attempts; `insurance drawn` is the insurance fund's pToken value consumed; `residual debt` is the debt left after the last attempt at the oracle price of that step (huge numbers mean a price of hundreds of times the pin: the pool had been emptied).
- A cell `FAIL` is the exact first failure of the first attempt: all failures in the tables are the router's minimum-output check ("Too little received") produced by the swap module's oracle-relative floor; none is a `SwapError`, `PriceUnavailable` or cash error in these runs.


## Findings and conclusion

1. **Stress rows, candidate configuration `cand-2x25`:** no tested position size (margin 1k, 5k, 25k = notional 2k, 10k, 50k) can be liquidated through the normal route in the stress classes that matter, long or short, at any tested lag. For the long, the 25% maintenance trigger (about -34%) lies inside the empty gap below the sell wall; for the short, the +51% trigger lies just past the buy wall. The only success in the pool-follows class is the 1k short (trigger reached at about +51.8% with a 0.57% worst execution cost), and it fails at 5k.
2. **Alternatives:** `ALT-2x40` (earlier trigger) makes the short liquidatable inside the buy wall and its liquidation succeeds at all three sizes when the oracle follows the pool exactly (and at 50 bps lag), but fails at 100 bps lag or more. For the long it passes only at 1k margin and only when the oracle follows the pool exactly; it fails at 5k and 25k, and at every size with any lag (its trigger at about -17.7% to -20% sits on the edge of the sell wall). `ALT-1.5x25` has triggers outside any reachable price. Loosening guards to 300/300 does not rescue the long. No alternative passes every executed stress slice.
3. **Oracle lag is decisive and independent of depth.** The swap module's floor is one-sided (see `avalanche-controller-and-guards-review.md`): once the oracle is more than about 0.9% on the unfavourable side of the pool, the sell leg of a long liquidation or the debt-to-margin leg of a short liquidation reverts. The fixed-lag slices show the transition between 50 and 100 bps.
4. **Aggregates:** opening more than two USD 50k-notional positions in a row already fails at the open (the third open's swap breaches the oracle floor after earlier opens moved the pool), so a USD 100k notional per side is about the most the pool can even open in one sequence without moving the price beyond the guard. Correlated liquidations (agg slices, k=4/5/10) fail at their first attempt wherever a single position failed; the best case (`ALT-2x40` short, oracle following the pool) succeeds on 8 of 15, 10 of 40 and 2 of 8 attempts before the pool is exhausted; `cand-2x25` succeeds on 1 of 13 (k=5 short) and nothing else.
5. **Liquidity removal (50%, emulated)** and **90 days of accrued debt with a 9 bps flash fee** do not change the picture: the single-position results are already failures except `ALT-2x40` short, which still passes at 5k and 25k.
6. **Ordinary lending is not pool-dependent.** With a funded liquidator the path liquidates continuously with no bad debt through -80% (WAVAX collateral) and +200% (USDC collateral) at 70% to 99% borrow utilisation. After a **gap** (price jumps straight to the level, no intermediate liquidation) bad debt appears: for WAVAX collateral at 60% CF it appears from an AVAX fall of 40% at 99% borrow utilisation and of 60% at 70% utilisation; for USDC collateral (AVAX up) from +75% at 99% utilisation and +150% at 70%. The liquidator budget per USD 50k of borrower collateral is about USD 28k to 46k of debt asset (table). These use placeholder CFs (60%/75%).
7. **Explicit finding:** on this pinned pool, **the proposed 2x trading launch is not supportable through the normal liquidation route.** No derived cap is offered, because every stress slice that is not favourable-state fails at the smallest sizes; the numbers in "Candidate caps" below are UNSUPPORTED or conditional on lag below about 50 bps. The routes that remain are (a) the funded in-kind fallback (`avalanche-funded-fallback.md`), which does not use the pool, (b) a deeper venue or route, (c) much smaller exposure than the pool can absorb, with a separately proven fallback. Raising caps requires the section 4 stressed rehearsals to pass first.

Caveats: lag and removal were run on 1k/5k/25k margin and for configurations `cand-2x25` and `ALT-2x40` only; USDC depeg was not combined with the liquidation matrix; selective LP exit is not modelled; the whale-moved pool uses USD 2.5k to 50k chunks and the exact post-trade price at the walls is chunk dependent (the wall locations are not).

## Generated tables

Generated by `contracts/tools/avalanche-capacity-report.py` from forge output. Amounts in USD. Evidence classes: `oracle-only` = MOCKED oracle, pool untouched; `pool-follows` / `lag*` = pool moved by REAL swaps; `removal*` = EMULATED third-party liquidity removal; cfg `ALT-*` = alternative parameters or loosened guards (not the candidate).

## Margin scenarios

| slice | cfg | side | margin each | k | trigger (oracle bps of pin) | attempts ok/total | first failure | worst exec cost bps | repaid | seized | keeper reward | borrower surplus | insurance drawn | residual debt | pool reached (bps) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| oracle-only | cand-2x25 | long | 1,000 | 1 | 5000 | 1/1 | - | 0 | 980 | 989 | 49 | 949 | 0 | 0 | 10007 |
| oracle-only | cand-2x25 | long | 5,000 | 1 | 5000 | 1/1 | - | 0 | 4,899 | 4,944 | 245 | 4,743 | 0 | 0 | 10010 |
| oracle-only | cand-2x25 | long | 25,000 | 1 | 5000 | 1/1 | - | 0 | 24,495 | 24,695 | 1,225 | 23,716 | 0 | 0 | 10037 |
| oracle-only | cand-2x25 | short | 1,000 | 1 | 20000 | 0/2 | step 6 @ 20000 bps: Too little received | 6665 | 0 | 0 | 0 | 0 | 0 | 2,969 | 10006 |
| oracle-only | cand-2x25 | short | 5,000 | 1 | 20000 | 0/2 | step 6 @ 20000 bps: Too little received | 6665 | 0 | 0 | 0 | 0 | 0 | 14,845 | 10005 |
| oracle-only | cand-2x25 | short | 25,000 | 1 | 20000 | 0/2 | step 6 @ 20000 bps: Too little received | 6664 | 0 | 0 | 0 | 0 | 0 | 74,226 | 9987 |
| oracle-only | ALT-2x40 | long | 1,000 | 1 | 8250 | 3/3 | - | 0 | 980 | 945 | 49 | 949 | 0 | 0 | 10007 |
| oracle-only | ALT-2x40 | long | 5,000 | 1 | 8250 | 3/3 | - | 0 | 4,899 | 4,725 | 245 | 4,743 | 0 | 0 | 10008 |
| oracle-only | ALT-2x40 | long | 25,000 | 1 | 8250 | 3/3 | - | 0 | 24,495 | 23,616 | 1,225 | 23,716 | 0 | 0 | 10013 |
| oracle-only | ALT-2x40 | short | 1,000 | 1 | 12500 | 0/5 | step 3 @ 12500 bps: Too little received | 6665 | 0 | 0 | 0 | 0 | 0 | 2,969 | 10006 |
| oracle-only | ALT-2x40 | short | 5,000 | 1 | 12500 | 0/5 | step 3 @ 12500 bps: Too little received | 6665 | 0 | 0 | 0 | 0 | 0 | 14,845 | 10005 |
| oracle-only | ALT-2x40 | short | 25,000 | 1 | 12500 | 0/5 | step 3 @ 12500 bps: Too little received | 6664 | 0 | 0 | 0 | 0 | 0 | 74,226 | 9987 |
| oracle-only | ALT-1.5x25 | long | 1,000 | 1 | 2000 | 1/1 | - | 0 | 485 | 297 | 24 | 974 | 0 | 0 | 10007 |
| oracle-only | ALT-1.5x25 | long | 5,000 | 1 | 2000 | 1/1 | - | 0 | 2,425 | 1,483 | 121 | 4,869 | 0 | 0 | 10009 |
| oracle-only | ALT-1.5x25 | long | 25,000 | 1 | 2000 | 1/1 | - | 0 | 12,125 | 7,412 | 606 | 24,347 | 0 | 0 | 10025 |
| oracle-only | ALT-1.5x25 | short | 1,000 | 1 | 30000 | 0/1 | step 7 @ 30000 bps: Too little received | 6665 | 0 | 0 | 0 | 0 | 0 | 1,470 | 10006 |
| oracle-only | ALT-1.5x25 | short | 5,000 | 1 | 30000 | 0/1 | step 7 @ 30000 bps: Too little received | 6665 | 0 | 0 | 0 | 0 | 0 | 7,349 | 10006 |
| oracle-only | ALT-1.5x25 | short | 25,000 | 1 | 30000 | 0/1 | step 7 @ 30000 bps: Too little received | 6664 | 0 | 0 | 0 | 0 | 0 | 36,744 | 10000 |
| oracle-only | ALT-guard300-2x25 | long | 1,000 | 1 | 5000 | 1/1 | - | 0 | 941 | 970 | 47 | 951 | 0 | 0 | 10007 |
| oracle-only | ALT-guard300-2x25 | long | 5,000 | 1 | 5000 | 1/1 | - | 0 | 4,707 | 4,848 | 235 | 4,753 | 0 | 0 | 10010 |
| oracle-only | ALT-guard300-2x25 | long | 25,000 | 1 | 5000 | 1/1 | - | 0 | 23,534 | 24,217 | 1,177 | 23,765 | 0 | 0 | 10036 |
| oracle-only | ALT-guard300-2x25 | short | 1,000 | 1 | 20000 | 0/2 | step 6 @ 20000 bps: Too little received | 6665 | 0 | 0 | 0 | 0 | 0 | 2,911 | 10006 |
| oracle-only | ALT-guard300-2x25 | short | 5,000 | 1 | 20000 | 0/2 | step 6 @ 20000 bps: Too little received | 6665 | 0 | 0 | 0 | 0 | 0 | 14,557 | 10005 |
| oracle-only | ALT-guard300-2x25 | short | 25,000 | 1 | 20000 | 0/2 | step 6 @ 20000 bps: Too little received | 6664 | 0 | 0 | 0 | 0 | 0 | 72,785 | 9988 |
| pool-follows | cand-2x25 | long | 1,000 | 1 | pool floor | 0/3 | step 5 @ 0 bps: Too little received | 5859 | 0 | 0 | 0 | 0 | 0 | 980 | 0 |
| pool-follows | cand-2x25 | long | 5,000 | 1 | pool floor | 0/3 | step 5 @ 0 bps: Too little received | 8607 | 0 | 0 | 0 | 0 | 0 | 4,899 | 0 |
| pool-follows | cand-2x25 | long | 25,000 | 1 | pool floor | 0/3 | step 5 @ 0 bps: Too little received | 9740 | 0 | 0 | 0 | 0 | 0 | 24,495 | 0 |
| pool-follows | cand-2x25 | short | 1,000 | 1 | 22477 | 1/1 | - | 80 | 2,224 | 1,989 | 0 | 0 | 244 | 0 | 22477 |
| pool-follows | cand-2x25 | short | 5,000 | 1 | 22560 | 0/3 | step 5 @ 22560 bps: Too little received | 8811 | 0 | 0 | 0 | 0 | 0 | 561,161,152,384 | 1134027149032 |
| pool-follows | cand-2x25 | short | 25,000 | 1 | 22576 | 0/3 | step 5 @ 22576 bps: Too little received | 43215 | 0 | 0 | 0 | 0 | 0 | 2,911,539,436,546 | 1176761703037 |
| pool-follows | ALT-2x40 | long | 1,000 | 1 | 8226 | 1/4 | step 5 @ 0 bps: Too little received | 4583 | 490 | 520 | 24 | 2 | 0 | 490 | 0 |
| pool-follows | ALT-2x40 | long | 5,000 | 1 | 8227 | 0/5 | step 3 @ 8227 bps: Too little received | 8607 | 0 | 0 | 0 | 0 | 0 | 4,899 | 0 |
| pool-follows | ALT-2x40 | long | 25,000 | 1 | 8224 | 0/5 | step 3 @ 8224 bps: Too little received | 9740 | 0 | 0 | 0 | 0 | 0 | 24,495 | 0 |
| pool-follows | ALT-2x40 | short | 1,000 | 1 | 12502 | 2/2 | - | 28 | 1,733 | 1,989 | 87 | 166 | 0 | 0 | 22528 |
| pool-follows | ALT-2x40 | short | 5,000 | 1 | 12500 | 1/4 | step 5 @ 22619 bps: Too little received | 5539 | 3,093 | 3,280 | 155 | 32 | 0 | 319,033,876,023 | 1289444486078 |
| pool-follows | ALT-2x40 | short | 25,000 | 1 | 12501 | 1/4 | step 5 @ 22477 bps: Too little received | 32459 | 15,465 | 16,402 | 773 | 152 | 0 | 1,158,558,996,751 | 936513406600 |
| pool-follows | ALT-1.5x25 | long | 1,000 | 1 | pool floor | 0/3 | step 5 @ 0 bps: Too little received | 5034 | 0 | 0 | 0 | 0 | 0 | 485 | 0 |
| pool-follows | ALT-1.5x25 | long | 5,000 | 1 | pool floor | 0/3 | step 5 @ 0 bps: Too little received | 8312 | 0 | 0 | 0 | 0 | 0 | 2,425 | 0 |
| pool-follows | ALT-1.5x25 | long | 25,000 | 1 | pool floor | 0/3 | step 5 @ 0 bps: Too little received | 9603 | 0 | 0 | 0 | 0 | 0 | 12,125 | 0 |
| pool-follows | ALT-1.5x25 | short | 1,000 | 1 | 1028505423653 | 0/1 | step 7 @ 1028505423653 bps: Too little received | 1389 | 0 | 0 | 0 | 0 | 0 | 50,388,035,651 | 1028505423653 |
| pool-follows | ALT-1.5x25 | short | 5,000 | 1 | 1134091052358 | 0/1 | step 7 @ 1134091052358 bps: Too little received | 6599 | 0 | 0 | 0 | 0 | 0 | 277,804,175,932 | 1134091052358 |
| pool-follows | ALT-1.5x25 | short | 25,000 | 1 | 1174075219708 | 0/1 | step 7 @ 1174075219708 bps: Too little received | 32407 | 0 | 0 | 0 | 0 | 0 | 1,437,992,999,756 | 1174075219708 |
| pool-follows | ALT-guard300-2x25 | long | 1,000 | 1 | pool floor | 0/3 | step 5 @ 0 bps: Too little received | 5739 | 0 | 0 | 0 | 0 | 0 | 941 | 0 |
| pool-follows | ALT-guard300-2x25 | long | 5,000 | 1 | pool floor | 0/3 | step 5 @ 0 bps: Too little received | 8614 | 0 | 0 | 0 | 0 | 0 | 4,707 | 0 |
| pool-follows | ALT-guard300-2x25 | long | 25,000 | 1 | pool floor | 0/3 | step 5 @ 0 bps: Too little received | 9702 | 0 | 0 | 0 | 0 | 0 | 23,534 | 0 |
| pool-follows | ALT-guard300-2x25 | short | 1,000 | 1 | 22478 | 1/1 | - | 79 | 2,181 | 1,970 | 0 | 0 | 220 | 0 | 22478 |
| pool-follows | ALT-guard300-2x25 | short | 5,000 | 1 | 22567 | 0/3 | step 5 @ 22567 bps: Too little received | 8652 | 0 | 0 | 0 | 0 | 0 | 559,665,417,278 | 1153400608721 |
| pool-follows | ALT-guard300-2x25 | short | 25,000 | 1 | 22615 | 0/3 | step 5 @ 22615 bps: Too little received | 41086 | 0 | 0 | 0 | 0 | 0 | 3,097,935,723,921 | 1276891814192 |
| lag50 | cand-2x25 | long | 1,000 | 1 | 5000 | 0/3 | step 5 @ 5000 bps: Too little received | 9999 | 0 | 0 | 0 | 0 | 0 | 980 | 0 |
| lag50 | cand-2x25 | long | 5,000 | 1 | 5000 | 0/3 | step 5 @ 5000 bps: Too little received | 9999 | 0 | 0 | 0 | 0 | 0 | 4,899 | 0 |
| lag50 | cand-2x25 | long | 25,000 | 1 | 5000 | 0/3 | step 5 @ 5000 bps: Too little received | 9999 | 0 | 0 | 0 | 0 | 0 | 24,495 | 0 |
| lag50 | cand-2x25 | short | 1,000 | 1 | 16238 | 0/3 | step 5 @ 16238 bps: Too little received | 13889 | 0 | 0 | 0 | 0 | 0 | 46,275,196,665 | 935156123358 |
| lag50 | cand-2x25 | short | 5,000 | 1 | 16280 | 0/3 | step 5 @ 16280 bps: Too little received | 27622 | 0 | 0 | 0 | 0 | 0 | 280,580,578,666 | 1134027149032 |
| lag50 | cand-2x25 | short | 25,000 | 1 | 16288 | 0/3 | step 5 @ 16288 bps: Too little received | 96431 | 0 | 0 | 0 | 0 | 0 | 1,455,769,730,644 | 1176761703037 |
| lag50 | ALT-2x40 | long | 1,000 | 1 | 5000 | 0/3 | step 5 @ 5000 bps: Too little received | 9999 | 0 | 0 | 0 | 0 | 0 | 980 | 0 |
| lag50 | ALT-2x40 | long | 5,000 | 1 | 5000 | 0/3 | step 5 @ 5000 bps: Too little received | 9999 | 0 | 0 | 0 | 0 | 0 | 4,899 | 0 |
| lag50 | ALT-2x40 | long | 25,000 | 1 | 5000 | 0/3 | step 5 @ 5000 bps: Too little received | 9999 | 0 | 0 | 0 | 0 | 0 | 24,495 | 0 |
| lag50 | ALT-2x40 | short | 1,000 | 1 | 16238 | 0/3 | step 5 @ 16238 bps: Too little received | 13889 | 0 | 0 | 0 | 0 | 0 | 46,275,196,665 | 935156123358 |
| lag50 | ALT-2x40 | short | 5,000 | 1 | 16280 | 0/3 | step 5 @ 16280 bps: Too little received | 27622 | 0 | 0 | 0 | 0 | 0 | 280,580,578,666 | 1134027149032 |
| lag50 | ALT-2x40 | short | 25,000 | 1 | 16288 | 0/3 | step 5 @ 16288 bps: Too little received | 96431 | 0 | 0 | 0 | 0 | 0 | 1,455,769,730,644 | 1176761703037 |
| lag90 | cand-2x25 | long | 1,000 | 1 | NOT TRIGGERED | 0/0 | - | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| lag90 | cand-2x25 | long | 5,000 | 1 | NOT TRIGGERED | 0/0 | - | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| lag90 | cand-2x25 | long | 25,000 | 1 | NOT TRIGGERED | 0/0 | - | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| lag90 | cand-2x25 | short | 1,000 | 1 | 93515621335 | 0/1 | step 7 @ 93515621335 bps: Too little received | 109445 | 0 | 0 | 0 | 0 | 0 | 9,255,040,125 | 935156123358 |
| lag90 | cand-2x25 | short | 5,000 | 1 | 113402723903 | 0/1 | step 7 @ 113402723903 bps: Too little received | 178114 | 0 | 0 | 0 | 0 | 0 | 56,116,119,692 | 1134027149032 |
| lag90 | cand-2x25 | short | 25,000 | 1 | 117676179303 | 0/1 | step 7 @ 117676179303 bps: Too little received | 522158 | 0 | 0 | 0 | 0 | 0 | 291,153,965,922 | 1176761703037 |
| lag90 | ALT-2x40 | long | 1,000 | 1 | NOT TRIGGERED | 0/0 | - | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| lag90 | ALT-2x40 | long | 5,000 | 1 | NOT TRIGGERED | 0/0 | - | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| lag90 | ALT-2x40 | long | 25,000 | 1 | NOT TRIGGERED | 0/0 | - | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| lag90 | ALT-2x40 | short | 1,000 | 1 | 93515621335 | 0/1 | step 7 @ 93515621335 bps: Too little received | 109445 | 0 | 0 | 0 | 0 | 0 | 9,255,040,125 | 935156123358 |
| lag90 | ALT-2x40 | short | 5,000 | 1 | 113402723903 | 0/1 | step 7 @ 113402723903 bps: Too little received | 178114 | 0 | 0 | 0 | 0 | 0 | 56,116,119,692 | 1134027149032 |
| lag90 | ALT-2x40 | short | 25,000 | 1 | 117676179303 | 0/1 | step 7 @ 117676179303 bps: Too little received | 522158 | 0 | 0 | 0 | 0 | 0 | 291,153,965,922 | 1176761703037 |
| fixedlag50 | cand-2x25 | long | 1,000 | 1 | pool floor | 0/3 | step 5 @ 0 bps: Too little received | 5877 | 0 | 0 | 0 | 0 | 0 | 980 | 0 |
| fixedlag50 | cand-2x25 | long | 5,000 | 1 | pool floor | 0/3 | step 5 @ 0 bps: Too little received | 8611 | 0 | 0 | 0 | 0 | 0 | 4,899 | 0 |
| fixedlag50 | cand-2x25 | long | 25,000 | 1 | pool floor | 0/3 | step 5 @ 0 bps: Too little received | 9741 | 0 | 0 | 0 | 0 | 0 | 24,495 | 0 |
| fixedlag50 | cand-2x25 | short | 1,000 | 1 | 22364 | 0/3 | step 5 @ 22364 bps: Too little received | 2004 | 0 | 0 | 0 | 0 | 0 | 92,087,640,380 | 935156123358 |
| fixedlag50 | cand-2x25 | short | 5,000 | 1 | 22447 | 0/3 | step 5 @ 22447 bps: Too little received | 8906 | 0 | 0 | 0 | 0 | 0 | 558,355,346,622 | 1134027149032 |
| fixedlag50 | cand-2x25 | short | 25,000 | 1 | 22463 | 0/3 | step 5 @ 22463 bps: Too little received | 43483 | 0 | 0 | 0 | 0 | 0 | 2,896,981,739,363 | 1176761703037 |
| fixedlag50 | ALT-2x40 | long | 1,000 | 1 | 8038 | 0/4 | step 4 @ 8038 bps: Too little received | 5877 | 0 | 0 | 0 | 0 | 0 | 980 | 0 |
| fixedlag50 | ALT-2x40 | long | 5,000 | 1 | 7982 | 0/4 | step 4 @ 7982 bps: Too little received | 8611 | 0 | 0 | 0 | 0 | 0 | 4,899 | 0 |
| fixedlag50 | ALT-2x40 | long | 25,000 | 1 | 8035 | 0/4 | step 4 @ 8035 bps: Too little received | 9741 | 0 | 0 | 0 | 0 | 0 | 24,495 | 0 |
| fixedlag50 | ALT-2x40 | short | 1,000 | 1 | 12439 | 2/2 | - | 79 | 1,725 | 1,989 | 86 | 166 | 0 | 0 | 22528 |
| fixedlag50 | ALT-2x40 | short | 5,000 | 1 | 12438 | 1/4 | step 5 @ 22506 bps: Too little received | 5631 | 3,077 | 3,264 | 154 | 16 | 0 | 317,438,283,135 | 1289442765777 |
| fixedlag50 | ALT-2x40 | short | 25,000 | 1 | 12438 | 1/4 | step 5 @ 22365 bps: Too little received | 32752 | 15,388 | 16,320 | 769 | 70 | 0 | 1,152,757,177,522 | 936506075255 |
| fixedlag100 | cand-2x25 | long | 1,000 | 1 | pool floor | 0/3 | step 5 @ 0 bps: Too little received | 5894 | 0 | 0 | 0 | 0 | 0 | 980 | 0 |
| fixedlag100 | cand-2x25 | long | 5,000 | 1 | pool floor | 0/3 | step 5 @ 0 bps: Too little received | 8618 | 0 | 0 | 0 | 0 | 0 | 4,899 | 0 |
| fixedlag100 | cand-2x25 | long | 25,000 | 1 | pool floor | 0/3 | step 5 @ 0 bps: Too little received | 9743 | 0 | 0 | 0 | 0 | 0 | 24,495 | 0 |
| fixedlag100 | cand-2x25 | short | 1,000 | 1 | 22252 | 0/3 | step 5 @ 22252 bps: Too little received | 2065 | 0 | 0 | 0 | 0 | 0 | 91,624,888,418 | 935156123358 |
| fixedlag100 | cand-2x25 | short | 5,000 | 1 | 22334 | 0/3 | step 5 @ 22334 bps: Too little received | 9001 | 0 | 0 | 0 | 0 | 0 | 555,549,540,860 | 1134027149032 |
| fixedlag100 | cand-2x25 | short | 25,000 | 1 | 22351 | 0/3 | step 5 @ 22351 bps: Too little received | 43753 | 0 | 0 | 0 | 0 | 0 | 2,882,424,042,180 | 1176761703037 |
| fixedlag100 | ALT-2x40 | long | 1,000 | 1 | 8078 | 0/4 | step 4 @ 8078 bps: Too little received | 5894 | 0 | 0 | 0 | 0 | 0 | 980 | 0 |
| fixedlag100 | ALT-2x40 | long | 5,000 | 1 | 8022 | 0/4 | step 4 @ 8022 bps: Too little received | 8618 | 0 | 0 | 0 | 0 | 0 | 4,899 | 0 |
| fixedlag100 | ALT-2x40 | long | 25,000 | 1 | 8075 | 0/4 | step 4 @ 8075 bps: Too little received | 9743 | 0 | 0 | 0 | 0 | 0 | 24,495 | 0 |
| fixedlag100 | ALT-2x40 | short | 1,000 | 1 | 12377 | 0/5 | step 3 @ 12377 bps: Too little received | 2065 | 0 | 0 | 0 | 0 | 0 | 91,624,888,418 | 935156123358 |
| fixedlag100 | ALT-2x40 | short | 5,000 | 1 | 12375 | 0/5 | step 3 @ 12375 bps: Too little received | 9001 | 0 | 0 | 0 | 0 | 0 | 555,549,540,860 | 1134027149032 |
| fixedlag100 | ALT-2x40 | short | 25,000 | 1 | 12376 | 0/5 | step 3 @ 12376 bps: Too little received | 43753 | 0 | 0 | 0 | 0 | 0 | 2,882,424,042,180 | 1176761703037 |
| fixedlag200 | cand-2x25 | long | 1,000 | 1 | pool floor | 0/3 | step 5 @ 0 bps: Too little received | 5937 | 0 | 0 | 0 | 0 | 0 | 980 | 0 |
| fixedlag200 | cand-2x25 | long | 5,000 | 1 | pool floor | 0/3 | step 5 @ 0 bps: Too little received | 8633 | 0 | 0 | 0 | 0 | 0 | 4,899 | 0 |
| fixedlag200 | cand-2x25 | long | 25,000 | 1 | pool floor | 0/3 | step 5 @ 0 bps: Too little received | 9745 | 0 | 0 | 0 | 0 | 0 | 24,495 | 0 |
| fixedlag200 | cand-2x25 | short | 1,000 | 1 | 22027 | 0/3 | step 5 @ 22027 bps: Too little received | 2188 | 0 | 0 | 0 | 0 | 0 | 90,699,384,494 | 935156123358 |
| fixedlag200 | cand-2x25 | short | 5,000 | 1 | 22108 | 0/3 | step 5 @ 22108 bps: Too little received | 9195 | 0 | 0 | 0 | 0 | 0 | 549,937,929,336 | 1134027149032 |
| fixedlag200 | cand-2x25 | short | 25,000 | 1 | 22125 | 0/3 | step 5 @ 22125 bps: Too little received | 44301 | 0 | 0 | 0 | 0 | 0 | 2,853,308,647,815 | 1176761703037 |
| fixedlag200 | ALT-2x40 | long | 1,000 | 1 | 8158 | 0/4 | step 4 @ 8158 bps: Too little received | 5937 | 0 | 0 | 0 | 0 | 0 | 980 | 0 |
| fixedlag200 | ALT-2x40 | long | 5,000 | 1 | 8102 | 0/4 | step 4 @ 8102 bps: Too little received | 8633 | 0 | 0 | 0 | 0 | 0 | 4,899 | 0 |
| fixedlag200 | ALT-2x40 | long | 25,000 | 1 | 8155 | 0/4 | step 4 @ 8155 bps: Too little received | 9745 | 0 | 0 | 0 | 0 | 0 | 24,495 | 0 |
| fixedlag200 | ALT-2x40 | short | 1,000 | 1 | 12252 | 0/5 | step 3 @ 12252 bps: Too little received | 2188 | 0 | 0 | 0 | 0 | 0 | 90,699,384,494 | 935156123358 |
| fixedlag200 | ALT-2x40 | short | 5,000 | 1 | 12250 | 0/5 | step 3 @ 12250 bps: Too little received | 9195 | 0 | 0 | 0 | 0 | 0 | 549,937,929,336 | 1134027149032 |
| fixedlag200 | ALT-2x40 | short | 25,000 | 1 | 12251 | 0/5 | step 3 @ 12251 bps: Too little received | 44301 | 0 | 0 | 0 | 0 | 0 | 2,853,308,647,815 | 1176761703037 |
| removal50 | cand-2x25 | long | 5,000 | 1 | pool floor | 0/3 | step 5 @ 0 bps: Too little received | 9275 | 0 | 0 | 0 | 0 | 0 | 4,899 | 0 |
| removal50 | cand-2x25 | long | 25,000 | 1 | pool floor | 0/3 | step 5 @ 0 bps: Too little received | 9870 | 0 | 0 | 0 | 0 | 0 | 24,495 | 0 |
| removal50 | cand-2x25 | short | 5,000 | 1 | 22560 | 0/3 | step 5 @ 22560 bps: Too little received | 17618 | 0 | 0 | 0 | 0 | 0 | 561,161,152,384 | 1134027149032 |
| removal50 | cand-2x25 | short | 25,000 | 1 | 22576 | 0/3 | step 5 @ 22576 bps: Too little received | 86426 | 0 | 0 | 0 | 0 | 0 | 2,911,539,436,546 | 1176761703037 |
| removal50 | ALT-2x40 | long | 5,000 | 1 | 8227 | 0/5 | step 3 @ 8227 bps: Too little received | 9275 | 0 | 0 | 0 | 0 | 0 | 4,899 | 0 |
| removal50 | ALT-2x40 | long | 25,000 | 1 | 8224 | 0/5 | step 3 @ 8224 bps: Too little received | 9870 | 0 | 0 | 0 | 0 | 0 | 24,495 | 0 |
| removal50 | ALT-2x40 | short | 5,000 | 1 | 12500 | 1/4 | step 5 @ 22480 bps: Too little received | 12953 | 3,093 | 3,280 | 155 | 32 | 0 | 233,139,970,855 | 942285670883 |
| removal50 | ALT-2x40 | short | 25,000 | 1 | 12501 | 1/4 | step 5 @ 22579 bps: Too little received | 57720 | 15,465 | 16,402 | 773 | 140 | 0 | 1,465,337,146,795 | 1184495469813 |
| accrual90d-fee9 | cand-2x25 | long | 5,000 | 1 | pool floor | 0/3 | step 5 @ 0 bps: Too little received | 8763 | 0 | 0 | 0 | 0 | 0 | 4,919 | 0 |
| accrual90d-fee9 | cand-2x25 | long | 25,000 | 1 | pool floor | 0/3 | step 5 @ 0 bps: Too little received | 9725 | 0 | 0 | 0 | 0 | 0 | 24,599 | 0 |
| accrual90d-fee9 | cand-2x25 | short | 5,000 | 1 | 22560 | 0/3 | step 5 @ 22560 bps: Too little received | 8796 | 0 | 0 | 0 | 0 | 0 | 564,399,658,716 | 1135795293552 |
| accrual90d-fee9 | cand-2x25 | short | 25,000 | 1 | 22580 | 0/3 | step 5 @ 22580 bps: Too little received | 43013 | 0 | 0 | 0 | 0 | 0 | 2,948,017,111,257 | 1185765209247 |
| accrual90d-fee9 | ALT-2x40 | long | 5,000 | 1 | 8226 | 0/5 | step 3 @ 8226 bps: Too little received | 8763 | 0 | 0 | 0 | 0 | 0 | 4,919 | 0 |
| accrual90d-fee9 | ALT-2x40 | long | 25,000 | 1 | 8218 | 0/5 | step 3 @ 8218 bps: Too little received | 9725 | 0 | 0 | 0 | 0 | 0 | 24,599 | 0 |
| accrual90d-fee9 | ALT-2x40 | short | 5,000 | 1 | 12000 | 1/4 | step 5 @ 22611 bps: Too little received | 5677 | 2,982 | 3,165 | 149 | 31 | 0 | 314,794,084,094 | 1266980352064 |
| accrual90d-fee9 | ALT-2x40 | short | 25,000 | 1 | 12000 | 1/4 | step 5 @ 22636 bps: Too little received | 27636 | 14,918 | 15,836 | 746 | 147 | 0 | 1,656,836,681,777 | 1332841174600 |
| agg-k5 | cand-2x25 | long | 1,000 | 5 | pool floor | 0/15 | step 5 @ 0 bps: Too little received | 5543 | 0 | 0 | 0 | 0 | 0 | 980 | 0 |
| agg-k5 | cand-2x25 | short | 1,000 | 5 | 22560 | 1/13 | step 5 @ 22560 bps: Too little received | 1474 | 2,233 | 1,989 | 0 | 0 | 253 | 161,204,284,679 | 1628855049836 |
| agg-k5 | ALT-2x40 | long | 1,000 | 5 | 8227 | 1/24 | step 3 @ 8227 bps: Too little received | 5537 | 490 | 520 | 24 | 2 | 0 | 980 | 0 |
| agg-k5 | ALT-2x40 | short | 1,000 | 5 | 12500 | 8/15 | step 5 @ 22619 bps: Too little received | 859 | 6,461 | 7,279 | 323 | 477 | 0 | 106,995,190,296 | 2162221139071 |
| agg-k10 | cand-2x25 | long | 5,000 | 10 | pool floor | 0/30 | step 5 @ 0 bps: Too little received | 8621 | 0 | 0 | 0 | 0 | 0 | 4,899 | 0 |
| agg-k10 | cand-2x25 | short | 5,000 | 10 | 22602 | 0/30 | step 5 @ 22602 bps: Too little received | 8417 | 0 | 0 | 0 | 0 | 0 | 615,007,257,420 | 1242842495071 |
| agg-k10 | ALT-2x40 | long | 5,000 | 10 | 8231 | 0/50 | step 3 @ 8231 bps: Too little received | 8621 | 0 | 0 | 0 | 0 | 0 | 4,899 | 0 |
| agg-k10 | ALT-2x40 | short | 5,000 | 10 | 12501 | 10/40 | step 5 @ 22605 bps: Too little received | 5623 | 30,931 | 32,806 | 1,546 | 281 | 0 | 309,516,142,980 | 1250976507237 |
| agg-k4 | cand-2x25 | long | 25,000 | 2 | pool floor | 0/6 | step 5 @ 0 bps: Too little received | 9702 | 0 | 0 | 0 | 0 | 0 | 24,495 | 0 |
| agg-k4 | cand-2x25 | short | 25,000 | 2 | 22602 | 0/6 | step 5 @ 22602 bps: Too little received | 42051 | 0 | 0 | 0 | 0 | 0 | 3,075,036,288,931 | 1242842495912 |
| agg-k4 | ALT-2x40 | long | 25,000 | 2 | 8231 | 0/10 | step 3 @ 8231 bps: Too little received | 9702 | 0 | 0 | 0 | 0 | 0 | 24,495 | 0 |
| agg-k4 | ALT-2x40 | short | 25,000 | 2 | 12501 | 2/8 | step 5 @ 22605 bps: Too little received | 28084 | 30,931 | 32,806 | 1,547 | 281 | 0 | 1,547,580,694,690 | 1250976491001 |

## Open failures (position could not be opened)

| slice | cfg | side | margin each | requested k | opened | revert |
|---|---|---|---|---|---|---|
| agg-k4 | cand-2x25 | long | 25,000 | 4 | 2 | Too little received |
| agg-k4 | cand-2x25 | short | 25,000 | 4 | 2 | Too little received |
| agg-k4 | ALT-2x40 | long | 25,000 | 4 | 2 | Too little received |
| agg-k4 | ALT-2x40 | short | 25,000 | 4 | 2 | Too little received |

## Liquidation capacity per (slice, cfg, side)

Per tested size: result of the FIRST liquidation attempt once the position becomes liquidatable on the path (`ok` / `FAIL`), `-` = never liquidatable on the reachable path (the pool cannot reach the trigger without being emptied: NOT evidence of safety). `oracle-only` rows use a mocked oracle with the pool untouched: favourable-state evidence, reported but never used for caps.

| slice | cfg | side | 1k margin | 5k margin | 25k margin | first failure |
|---|---|---|---|---|---|---|
| oracle-only | cand-2x25 | long | ok | ok | ok | - |
| oracle-only | cand-2x25 | short | FAIL | FAIL | FAIL | oracle 20000 bps / pool 10006 bps: Too little received |
| oracle-only | ALT-2x40 | long | ok | ok | ok | - |
| oracle-only | ALT-2x40 | short | FAIL | FAIL | FAIL | oracle 12500 bps / pool 10006 bps: Too little received |
| oracle-only | ALT-1.5x25 | long | ok | ok | ok | - |
| oracle-only | ALT-1.5x25 | short | FAIL | FAIL | FAIL | oracle 30000 bps / pool 10006 bps: Too little received |
| oracle-only | ALT-guard300-2x25 | long | ok | ok | ok | - |
| oracle-only | ALT-guard300-2x25 | short | FAIL | FAIL | FAIL | oracle 20000 bps / pool 10006 bps: Too little received |
| pool-follows | cand-2x25 | long | FAIL | FAIL | FAIL | oracle 0 bps / pool 0 bps: Too little received |
| pool-follows | cand-2x25 | short | ok | FAIL | FAIL | oracle 22560 bps / pool 22560 bps: Too little received |
| pool-follows | ALT-2x40 | long | ok | FAIL | FAIL | oracle 0 bps / pool 0 bps: Too little received |
| pool-follows | ALT-2x40 | short | ok | ok | ok | oracle 22619 bps / pool 22619 bps: Too little received |
| pool-follows | ALT-1.5x25 | long | FAIL | FAIL | FAIL | oracle 0 bps / pool 0 bps: Too little received |
| pool-follows | ALT-1.5x25 | short | FAIL | FAIL | FAIL | oracle 1028505423653 bps / pool 1028505423653 bps: Too little received |
| pool-follows | ALT-guard300-2x25 | long | FAIL | FAIL | FAIL | oracle 0 bps / pool 0 bps: Too little received |
| pool-follows | ALT-guard300-2x25 | short | ok | FAIL | FAIL | oracle 22567 bps / pool 22567 bps: Too little received |
| lag50 | cand-2x25 | long | FAIL | FAIL | FAIL | oracle 5000 bps / pool 0 bps: Too little received |
| lag50 | cand-2x25 | short | FAIL | FAIL | FAIL | oracle 16238 bps / pool 22477 bps: Too little received |
| lag50 | ALT-2x40 | long | FAIL | FAIL | FAIL | oracle 5000 bps / pool 0 bps: Too little received |
| lag50 | ALT-2x40 | short | FAIL | FAIL | FAIL | oracle 16238 bps / pool 22477 bps: Too little received |
| lag90 | cand-2x25 | long | - | - | - | - |
| lag90 | cand-2x25 | short | FAIL | FAIL | FAIL | oracle 93515621335 bps / pool 935156123358 bps: Too little received |
| lag90 | ALT-2x40 | long | - | - | - | - |
| lag90 | ALT-2x40 | short | FAIL | FAIL | FAIL | oracle 93515621335 bps / pool 935156123358 bps: Too little received |
| fixedlag50 | cand-2x25 | long | FAIL | FAIL | FAIL | oracle 0 bps / pool 0 bps: Too little received |
| fixedlag50 | cand-2x25 | short | FAIL | FAIL | FAIL | oracle 22364 bps / pool 22477 bps: Too little received |
| fixedlag50 | ALT-2x40 | long | FAIL | FAIL | FAIL | oracle 8038 bps / pool 7998 bps: Too little received |
| fixedlag50 | ALT-2x40 | short | ok | ok | ok | oracle 22506 bps / pool 22619 bps: Too little received |
| fixedlag100 | cand-2x25 | long | FAIL | FAIL | FAIL | oracle 0 bps / pool 0 bps: Too little received |
| fixedlag100 | cand-2x25 | short | FAIL | FAIL | FAIL | oracle 22252 bps / pool 22477 bps: Too little received |
| fixedlag100 | ALT-2x40 | long | FAIL | FAIL | FAIL | oracle 8078 bps / pool 7998 bps: Too little received |
| fixedlag100 | ALT-2x40 | short | FAIL | FAIL | FAIL | oracle 12377 bps / pool 12502 bps: Too little received |
| fixedlag200 | cand-2x25 | long | FAIL | FAIL | FAIL | oracle 0 bps / pool 0 bps: Too little received |
| fixedlag200 | cand-2x25 | short | FAIL | FAIL | FAIL | oracle 22027 bps / pool 22477 bps: Too little received |
| fixedlag200 | ALT-2x40 | long | FAIL | FAIL | FAIL | oracle 8158 bps / pool 7998 bps: Too little received |
| fixedlag200 | ALT-2x40 | short | FAIL | FAIL | FAIL | oracle 12252 bps / pool 12502 bps: Too little received |
| removal50 | cand-2x25 | long | n/a | FAIL | FAIL | oracle 0 bps / pool 0 bps: Too little received |
| removal50 | cand-2x25 | short | n/a | FAIL | FAIL | oracle 22560 bps / pool 22560 bps: Too little received |
| removal50 | ALT-2x40 | long | n/a | FAIL | FAIL | oracle 8227 bps / pool 8227 bps: Too little received |
| removal50 | ALT-2x40 | short | n/a | ok | ok | oracle 22480 bps / pool 22480 bps: Too little received |
| accrual90d-fee9 | cand-2x25 | long | n/a | FAIL | FAIL | oracle 0 bps / pool 0 bps: Too little received |
| accrual90d-fee9 | cand-2x25 | short | n/a | FAIL | FAIL | oracle 22560 bps / pool 22560 bps: Too little received |
| accrual90d-fee9 | ALT-2x40 | long | n/a | FAIL | FAIL | oracle 8226 bps / pool 8226 bps: Too little received |
| accrual90d-fee9 | ALT-2x40 | short | n/a | ok | ok | oracle 22611 bps / pool 22611 bps: Too little received |
| agg-k5 | cand-2x25 | long | n/a | n/a | n/a | oracle 0 bps / pool 0 bps: Too little received |
| agg-k5 | cand-2x25 | short | n/a | n/a | n/a | oracle 22560 bps / pool 22560 bps: Too little received |
| agg-k5 | ALT-2x40 | long | n/a | n/a | n/a | oracle 8227 bps / pool 8227 bps: Too little received |
| agg-k5 | ALT-2x40 | short | n/a | n/a | n/a | oracle 22619 bps / pool 22619 bps: Too little received |
| agg-k10 | cand-2x25 | long | n/a | n/a | n/a | oracle 0 bps / pool 0 bps: Too little received |
| agg-k10 | cand-2x25 | short | n/a | n/a | n/a | oracle 22602 bps / pool 22602 bps: Too little received |
| agg-k10 | ALT-2x40 | long | n/a | n/a | n/a | oracle 8231 bps / pool 8231 bps: Too little received |
| agg-k10 | ALT-2x40 | short | n/a | n/a | n/a | oracle 22605 bps / pool 22605 bps: Too little received |
| agg-k4 | cand-2x25 | long | n/a | n/a | n/a | oracle 0 bps / pool 0 bps: Too little received |
| agg-k4 | cand-2x25 | short | n/a | n/a | n/a | oracle 22602 bps / pool 22602 bps: Too little received |
| agg-k4 | ALT-2x40 | long | n/a | n/a | n/a | oracle 8231 bps / pool 8231 bps: Too little received |
| agg-k4 | ALT-2x40 | short | n/a | n/a | n/a | oracle 22605 bps / pool 22605 bps: Too little received |

## Candidate caps derived from executed stress scenarios only

Largest single-position margin size whose first liquidation succeeded in EVERY executed stress slice (pool-follows, lag50, lag90, fixed lags, removal50, accrual) for that config and side; `-`/`FAIL` in any slice disqualifies the size. `not triggered` means the slice never made the position liquidatable (no evidence), `UNSUPPORTED` means no tested size passed. Aggregate cap = single cap / 2 (safety factor, handoff 00 section 4). The margin-each sizes are 2x notional.

| cfg | side | slices considered | max margin size passing all | aggregate cap (margin) after /2 | disqualifying slices |
|---|---|---|---|---|---|
| cand-2x25 | long | pool-follows, lag50, lag90, fixedlag50, fixedlag100, fixedlag200, removal50, accrual90d-fee9 | UNSUPPORTED | 0 | pool-follows: 1k:FAIL, 5k:FAIL, 25k:FAIL; lag50: 1k:FAIL, 5k:FAIL, 25k:FAIL; lag90: 1k:-, 5k:-, 25k:-; fixedlag50: 1k:FAIL, 5k:FAIL, 25k:FAIL; fixedlag100: 1k:FAIL, 5k:FAIL, 25k:FAIL; fixedlag200: 1k:FAIL, 5k:FAIL, 25k:FAIL; removal50: 1k:n/a, 5k:FAIL, 25k:FAIL; accrual90d-fee9: 1k:n/a, 5k:FAIL, 25k:FAIL |
| cand-2x25 | short | pool-follows, lag50, lag90, fixedlag50, fixedlag100, fixedlag200, removal50, accrual90d-fee9 | UNSUPPORTED | 0 | lag50: 1k:FAIL, 5k:FAIL, 25k:FAIL; lag90: 1k:FAIL, 5k:FAIL, 25k:FAIL; fixedlag50: 1k:FAIL, 5k:FAIL, 25k:FAIL; fixedlag100: 1k:FAIL, 5k:FAIL, 25k:FAIL; fixedlag200: 1k:FAIL, 5k:FAIL, 25k:FAIL; removal50: 1k:n/a, 5k:FAIL, 25k:FAIL; accrual90d-fee9: 1k:n/a, 5k:FAIL, 25k:FAIL; pool-follows: 5k:FAIL, 25k:FAIL |
| ALT-2x40 | long | pool-follows, lag50, lag90, fixedlag50, fixedlag100, fixedlag200, removal50, accrual90d-fee9 | UNSUPPORTED | 0 | lag50: 1k:FAIL, 5k:FAIL, 25k:FAIL; lag90: 1k:-, 5k:-, 25k:-; fixedlag50: 1k:FAIL, 5k:FAIL, 25k:FAIL; fixedlag100: 1k:FAIL, 5k:FAIL, 25k:FAIL; fixedlag200: 1k:FAIL, 5k:FAIL, 25k:FAIL; removal50: 1k:n/a, 5k:FAIL, 25k:FAIL; accrual90d-fee9: 1k:n/a, 5k:FAIL, 25k:FAIL; pool-follows: 5k:FAIL, 25k:FAIL |
| ALT-2x40 | short | pool-follows, lag50, lag90, fixedlag50, fixedlag100, fixedlag200, removal50, accrual90d-fee9 | UNSUPPORTED | 0 | lag50: 1k:FAIL, 5k:FAIL, 25k:FAIL; lag90: 1k:FAIL, 5k:FAIL, 25k:FAIL; fixedlag100: 1k:FAIL, 5k:FAIL, 25k:FAIL; fixedlag200: 1k:FAIL, 5k:FAIL, 25k:FAIL; removal50: 1k:n/a; accrual90d-fee9: 1k:n/a |
| ALT-1.5x25 | long | pool-follows | UNSUPPORTED | 0 | pool-follows: 1k:FAIL, 5k:FAIL, 25k:FAIL |
| ALT-1.5x25 | short | pool-follows | UNSUPPORTED | 0 | pool-follows: 1k:FAIL, 5k:FAIL, 25k:FAIL |
| ALT-guard300-2x25 | long | pool-follows | UNSUPPORTED | 0 | pool-follows: 1k:FAIL, 5k:FAIL, 25k:FAIL |
| ALT-guard300-2x25 | short | pool-follows | 1,000 | 500 | pool-follows: 5k:FAIL, 25k:FAIL |

## Ordinary lending liquidations (funded liquidator, no swap)

USD. `shortfall` = borrowers in shortfall at the step; liquidator budget = sum of repays; net seized excludes the 2.8% protocol share. `bad debt` = residual debt not covered by remaining collateral.

| direction | borrow util % | borrowers | step (AVAX bps of pin) | in shortfall | repaid (liquidator budget) | net seized | protocol share | residual debt | bad debt |
|---|---|---|---|---|---|---|---|---|---|
| GAP wavax-collateral/usdc-debt | 70 | 5 | 6000 | 5 | 10,496 | 11,018 | 317 | 10,496 | 0 |
| GAP wavax-collateral/usdc-debt | 70 | 5 | 4000 | 5 | 18,518 | 19,439 | 560 | 2,473 | 2,473 |
| GAP wavax-collateral/usdc-debt | 70 | 5 | 3000 | 5 | 13,887 | 14,578 | 420 | 7,104 | 7,102 |
| GAP wavax-collateral/usdc-debt | 70 | 5 | 2000 | 5 | 9,258 | 9,719 | 280 | 11,733 | 11,732 |
| GAP wavax-collateral/usdc-debt | 99 | 5 | 6000 | 5 | 27,777 | 29,159 | 840 | 1,910 | 1,910 |
| GAP wavax-collateral/usdc-debt | 99 | 5 | 4000 | 5 | 18,516 | 19,438 | 560 | 11,171 | 11,169 |
| GAP wavax-collateral/usdc-debt | 99 | 5 | 3000 | 5 | 13,887 | 14,578 | 420 | 15,800 | 15,798 |
| GAP wavax-collateral/usdc-debt | 99 | 5 | 2000 | 5 | 9,255 | 9,715 | 280 | 20,433 | 20,428 |
| GAP usdc-collateral/wavax-debt | 70 | 5 | 17500 | 5 | 44,483 | 46,696 | 1,345 | 1,435 | 0 |
| GAP usdc-collateral/wavax-debt | 70 | 5 | 25000 | 5 | 46,272 | 48,575 | 1,399 | 19,324 | 19,320 |
| GAP usdc-collateral/wavax-debt | 70 | 5 | 30000 | 5 | 46,275 | 48,578 | 1,399 | 32,441 | 32,440 |
| GAP usdc-collateral/wavax-debt | 70 | 5 | 40000 | 5 | 46,263 | 48,565 | 1,399 | 58,692 | 58,678 |
| GAP usdc-collateral/wavax-debt | 99 | 5 | 17500 | 5 | 46,272 | 48,574 | 1,399 | 18,669 | 18,664 |
| GAP usdc-collateral/wavax-debt | 99 | 5 | 25000 | 5 | 46,267 | 48,569 | 1,399 | 46,506 | 46,496 |
| GAP usdc-collateral/wavax-debt | 99 | 5 | 30000 | 5 | 46,267 | 48,569 | 1,399 | 65,060 | 65,050 |
| GAP usdc-collateral/wavax-debt | 99 | 5 | 40000 | 5 | 46,274 | 48,577 | 1,399 | 102,163 | 102,160 |
| path wavax-collateral/usdc-debt | 70 | 1 | 6000 | 1 | 2,099 | 2,204 | 63 | 2,099 | 0 |
| path wavax-collateral/usdc-debt | 70 | 1 | 5000 | 1 | 1,050 | 1,102 | 32 | 1,050 | 0 |
| path wavax-collateral/usdc-debt | 70 | 1 | 4000 | 1 | 525 | 551 | 16 | 525 | 0 |
| path wavax-collateral/usdc-debt | 70 | 1 | 3000 | 1 | 262 | 275 | 8 | 262 | 0 |
| path wavax-collateral/usdc-debt | 70 | 1 | 2000 | 1 | 230 | 241 | 7 | 33 | 0 |
| path wavax-collateral/usdc-debt | 70 | 5 | 6000 | 5 | 10,496 | 11,018 | 317 | 10,496 | 0 |
| path wavax-collateral/usdc-debt | 70 | 5 | 5000 | 5 | 5,248 | 5,509 | 159 | 5,248 | 0 |
| path wavax-collateral/usdc-debt | 70 | 5 | 4000 | 5 | 2,624 | 2,754 | 79 | 2,624 | 0 |
| path wavax-collateral/usdc-debt | 70 | 5 | 3000 | 5 | 1,312 | 1,377 | 40 | 1,312 | 0 |
| path wavax-collateral/usdc-debt | 70 | 5 | 2000 | 5 | 1,148 | 1,205 | 35 | 164 | 0 |
| path wavax-collateral/usdc-debt | 90 | 1 | 8000 | 1 | 2,699 | 2,833 | 82 | 2,699 | 0 |
| path wavax-collateral/usdc-debt | 90 | 1 | 7000 | 1 | 1,349 | 1,417 | 41 | 1,349 | 0 |
| path wavax-collateral/usdc-debt | 90 | 1 | 5000 | 1 | 675 | 708 | 20 | 675 | 0 |
| path wavax-collateral/usdc-debt | 90 | 1 | 3000 | 1 | 506 | 531 | 15 | 169 | 0 |
| path wavax-collateral/usdc-debt | 90 | 1 | 2000 | 1 | 148 | 155 | 4 | 21 | 0 |
| path wavax-collateral/usdc-debt | 90 | 5 | 8000 | 5 | 13,494 | 14,166 | 408 | 13,494 | 0 |
| path wavax-collateral/usdc-debt | 90 | 5 | 7000 | 5 | 6,747 | 7,083 | 204 | 6,747 | 0 |
| path wavax-collateral/usdc-debt | 90 | 5 | 5000 | 5 | 3,374 | 3,541 | 102 | 3,374 | 0 |
| path wavax-collateral/usdc-debt | 90 | 5 | 3000 | 5 | 2,530 | 2,656 | 76 | 843 | 0 |
| path wavax-collateral/usdc-debt | 90 | 5 | 2000 | 5 | 738 | 775 | 22 | 105 | 0 |
| path wavax-collateral/usdc-debt | 99 | 1 | 9000 | 1 | 2,969 | 3,116 | 90 | 2,969 | 0 |
| path wavax-collateral/usdc-debt | 99 | 1 | 7000 | 1 | 1,484 | 1,558 | 45 | 1,484 | 0 |
| path wavax-collateral/usdc-debt | 99 | 1 | 5000 | 1 | 742 | 779 | 22 | 742 | 0 |
| path wavax-collateral/usdc-debt | 99 | 1 | 4000 | 1 | 557 | 584 | 17 | 186 | 0 |
| path wavax-collateral/usdc-debt | 99 | 1 | 2000 | 1 | 174 | 183 | 5 | 12 | 0 |
| path wavax-collateral/usdc-debt | 99 | 5 | 9000 | 5 | 14,844 | 15,582 | 449 | 14,844 | 0 |
| path wavax-collateral/usdc-debt | 99 | 5 | 7000 | 5 | 7,422 | 7,791 | 224 | 7,422 | 0 |
| path wavax-collateral/usdc-debt | 99 | 5 | 5000 | 5 | 3,711 | 3,896 | 112 | 3,711 | 0 |
| path wavax-collateral/usdc-debt | 99 | 5 | 4000 | 5 | 2,783 | 2,922 | 84 | 928 | 0 |
| path wavax-collateral/usdc-debt | 99 | 5 | 2000 | 5 | 870 | 913 | 26 | 58 | 0 |
| path usdc-collateral/wavax-debt | 70 | 1 | 15000 | 1 | 3,936 | 4,132 | 119 | 3,936 | 0 |
| path usdc-collateral/wavax-debt | 70 | 1 | 17500 | 1 | 2,296 | 2,410 | 69 | 2,296 | 0 |
| path usdc-collateral/wavax-debt | 70 | 1 | 20000 | 1 | 1,312 | 1,377 | 40 | 1,312 | 0 |
| path usdc-collateral/wavax-debt | 70 | 1 | 25000 | 1 | 1,435 | 1,506 | 43 | 205 | 0 |
| path usdc-collateral/wavax-debt | 70 | 1 | 30000 | 1 | 123 | 129 | 4 | 123 | 0 |
| path usdc-collateral/wavax-debt | 70 | 1 | 40000 | 1 | 154 | 161 | 5 | 10 | 10 |
| path usdc-collateral/wavax-debt | 70 | 5 | 15000 | 5 | 19,679 | 20,658 | 595 | 19,679 | 0 |
| path usdc-collateral/wavax-debt | 70 | 5 | 17500 | 5 | 11,479 | 12,051 | 347 | 11,479 | 0 |
| path usdc-collateral/wavax-debt | 70 | 5 | 20000 | 5 | 6,560 | 6,886 | 198 | 6,560 | 0 |
| path usdc-collateral/wavax-debt | 70 | 5 | 25000 | 5 | 7,175 | 7,532 | 217 | 1,025 | 0 |
| path usdc-collateral/wavax-debt | 70 | 5 | 30000 | 5 | 615 | 646 | 19 | 615 | 0 |
| path usdc-collateral/wavax-debt | 70 | 5 | 40000 | 5 | 768 | 807 | 23 | 51 | 51 |
| path usdc-collateral/wavax-debt | 90 | 1 | 12500 | 1 | 6,325 | 6,640 | 191 | 2,108 | 0 |
| path usdc-collateral/wavax-debt | 90 | 1 | 15000 | 1 | 1,265 | 1,328 | 38 | 1,265 | 0 |
| path usdc-collateral/wavax-debt | 90 | 1 | 17500 | 1 | 738 | 775 | 22 | 738 | 0 |
| path usdc-collateral/wavax-debt | 90 | 1 | 20000 | 1 | 633 | 664 | 19 | 211 | 0 |
| path usdc-collateral/wavax-debt | 90 | 1 | 25000 | 1 | 198 | 207 | 6 | 66 | 0 |
| path usdc-collateral/wavax-debt | 90 | 1 | 30000 | 1 | 40 | 42 | 1 | 40 | 0 |
| path usdc-collateral/wavax-debt | 90 | 1 | 40000 | 1 | 40 | 41 | 1 | 13 | 0 |
| path usdc-collateral/wavax-debt | 90 | 5 | 12500 | 5 | 31,627 | 33,201 | 956 | 10,542 | 0 |
| path usdc-collateral/wavax-debt | 90 | 5 | 15000 | 5 | 6,325 | 6,640 | 191 | 6,325 | 0 |
| path usdc-collateral/wavax-debt | 90 | 5 | 17500 | 5 | 3,690 | 3,873 | 112 | 3,690 | 0 |
| path usdc-collateral/wavax-debt | 90 | 5 | 20000 | 5 | 3,163 | 3,320 | 96 | 1,054 | 0 |
| path usdc-collateral/wavax-debt | 90 | 5 | 25000 | 5 | 988 | 1,037 | 30 | 329 | 0 |
| path usdc-collateral/wavax-debt | 90 | 5 | 30000 | 5 | 198 | 208 | 6 | 198 | 0 |
| path usdc-collateral/wavax-debt | 90 | 5 | 40000 | 5 | 198 | 207 | 6 | 66 | 0 |
| path usdc-collateral/wavax-debt | 99 | 1 | 11000 | 1 | 4,082 | 4,285 | 123 | 4,082 | 0 |
| path usdc-collateral/wavax-debt | 99 | 1 | 12500 | 1 | 3,479 | 3,652 | 105 | 1,160 | 0 |
| path usdc-collateral/wavax-debt | 99 | 1 | 15000 | 1 | 696 | 730 | 21 | 696 | 0 |
| path usdc-collateral/wavax-debt | 99 | 1 | 17500 | 1 | 406 | 426 | 12 | 406 | 0 |
| path usdc-collateral/wavax-debt | 99 | 1 | 25000 | 1 | 544 | 571 | 16 | 36 | 0 |
| path usdc-collateral/wavax-debt | 99 | 1 | 30000 | 1 | 22 | 23 | 1 | 22 | 0 |
| path usdc-collateral/wavax-debt | 99 | 1 | 40000 | 1 | 27 | 29 | 1 | 2 | 2 |
| path usdc-collateral/wavax-debt | 99 | 5 | 11000 | 5 | 20,410 | 21,426 | 617 | 20,410 | 0 |
| path usdc-collateral/wavax-debt | 99 | 5 | 12500 | 5 | 17,395 | 18,260 | 526 | 5,798 | 0 |
| path usdc-collateral/wavax-debt | 99 | 5 | 15000 | 5 | 3,479 | 3,652 | 105 | 3,479 | 0 |
| path usdc-collateral/wavax-debt | 99 | 5 | 17500 | 5 | 2,029 | 2,130 | 61 | 2,029 | 0 |
| path usdc-collateral/wavax-debt | 99 | 5 | 25000 | 5 | 2,718 | 2,853 | 82 | 181 | 0 |
| path usdc-collateral/wavax-debt | 99 | 5 | 30000 | 5 | 109 | 114 | 3 | 109 | 0 |
| path usdc-collateral/wavax-debt | 99 | 5 | 40000 | 5 | 136 | 143 | 4 | 8 | 8 |

First step with bad debt per (direction, util, borrowers): ('GAP wavax-collateral/usdc-debt', 70, 5): 4000 bps, ('GAP wavax-collateral/usdc-debt', 99, 5): 6000 bps, ('GAP usdc-collateral/wavax-debt', 70, 5): 25000 bps, ('GAP usdc-collateral/wavax-debt', 99, 5): 17500 bps, ('path usdc-collateral/wavax-debt', 70, 1): 40000 bps, ('path usdc-collateral/wavax-debt', 70, 5): 40000 bps, ('path usdc-collateral/wavax-debt', 99, 1): 40000 bps, ('path usdc-collateral/wavax-debt', 99, 5): 40000 bps

## Swap-guard reconciliation (real `IsolatedMarginSwapModule`, $5k notional)

`delta` = oracle price relative to the pool price (bps). Expected/min/actual are token base units; exec/pool/oracle are USD per AVAX x1e8.

| guard | direction | oracle vs pool (bps) | oracle | pool | expected out | min out | actual out | exec price | result |
|---|---|---|---|---|---|---|---|---|---|
| candidate-guard | sell-WAVAX | -300 | 829856410 | 855522072 | 4852060671 | 4803540064 | 4997165828 | 855037132 | PASS |
| candidate-guard | sell-WAVAX | -150 | 842689241 | 855522072 | 4927092536 | 4877821610 | 4997165828 | 855037132 | PASS |
| candidate-guard | sell-WAVAX | -101 | 846881300 | 855522072 | 4951602951 | 4902086921 | 4997165828 | 855037132 | PASS |
| candidate-guard | sell-WAVAX | -100 | 846966852 | 855522072 | 4952103162 | 4902582130 | 4997165828 | 855037132 | PASS |
| candidate-guard | sell-WAVAX | -99 | 847052404 | 855522072 | 4952603373 | 4903077339 | 4997165828 | 855037132 | PASS |
| candidate-guard | sell-WAVAX | -50 | 851244462 | 855522072 | 4977113782 | 4927342644 | 4997165828 | 855037132 | PASS |
| candidate-guard | sell-WAVAX | 0 | 855522072 | 855522072 | 5002124402 | 4952103157 | 4997165828 | 855037132 | PASS |
| candidate-guard | sell-WAVAX | 50 | 859799682 | 855522072 | 5027135022 | 4976863671 | 4997165828 | 855037132 | PASS |
| candidate-guard | sell-WAVAX | 99 | 863991740 | 855522072 | 5051645430 | 5001128975 | 4997165828 | 855037132 | REVERT: Too little received |
| candidate-guard | sell-WAVAX | 100 | 864077292 | 855522072 | 5052145642 | 5001624185 | 4997165828 | 855037132 | REVERT: Too little received |
| candidate-guard | sell-WAVAX | 101 | 864162844 | 855522072 | 5052645853 | 5002119394 | 4997165828 | 855037132 | REVERT: Too little received |
| candidate-guard | sell-WAVAX | 150 | 868354903 | 855522072 | 5077156267 | 5026384704 | 4997165828 | 855037132 | REVERT: Too little received |
| candidate-guard | sell-WAVAX | 300 | 881187734 | 855522072 | 5152188133 | 5100666251 | 4997165828 | 855037132 | REVERT: Too little received |
| candidate-guard | buy-WAVAX | -300 | 829856410 | 855522072 | 602257985812268414001 | 596235405954145729860 | 584107176537765873510 | 856007287 | REVERT: Too little received |
| candidate-guard | buy-WAVAX | -150 | 842689241 | 855522072 | 593086544462005300480 | 587155679017385247475 | 584107176537765873510 | 856007287 | REVERT: Too little received |
| candidate-guard | buy-WAVAX | -101 | 846881300 | 855522072 | 590150768472512027364 | 584249260787786907090 | 584107176537765873510 | 856007287 | REVERT: Too little received |
| candidate-guard | buy-WAVAX | -100 | 846966852 | 855522072 | 590091157428201216073 | 584190245853919203912 | 584107176537765873510 | 856007287 | REVERT: Too little received |
| candidate-guard | buy-WAVAX | -99 | 847052404 | 855522072 | 590031558425280143588 | 584131242841027342152 | 584107176537765873510 | 856007287 | REVERT: Too little received |
| candidate-guard | buy-WAVAX | -50 | 851244462 | 855522072 | 587125875480879193079 | 581254616726070401148 | 584107176537765873510 | 856007287 | PASS |
| candidate-guard | buy-WAVAX | 0 | 855522072 | 855522072 | 584190246350534834593 | 578348343887029486247 | 584107176537765873510 | 856007287 | PASS |
| candidate-guard | buy-WAVAX | 50 | 859799682 | 855522072 | 581283827457847326814 | 575470989183268853545 | 584107176537765873510 | 856007287 | PASS |
| candidate-guard | buy-WAVAX | 99 | 863991740 | 855522072 | 578463458458526466931 | 572678823873941202261 | 584107176537765873510 | 856007287 | PASS |
| candidate-guard | buy-WAVAX | 100 | 864077292 | 855522072 | 578406184987442072485 | 572622123137567651760 | 584107176537765873510 | 856007287 | PASS |
| candidate-guard | buy-WAVAX | 101 | 864162844 | 855522072 | 578348922856488840198 | 572565433627923951796 | 584107176537765873510 | 856007287 | PASS |
| candidate-guard | buy-WAVAX | 150 | 868354903 | 855522072 | 575556893009216992928 | 569801324079124822998 | 584107176537765873510 | 856007287 | PASS |
| candidate-guard | buy-WAVAX | 300 | 881187734 | 855522072 | 567174996559813666221 | 561503246594215529558 | 584107176537765873510 | 856007287 | PASS |
| ALTERED-guard-slip300-dev50 | sell-WAVAX | 250 | 876910123 | 855522072 | 5127177507 | 4973362181 | 4997165828 | 855037132 | REVERT: SwapError(8) |
| ALTERED-guard-slip300-dev50 | sell-WAVAX | 100 | 864077292 | 855522072 | 5052145642 | 4900581272 | 4997165828 | 855037132 | REVERT: SwapError(8) |
| ALTERED-guard-slip300-dev50 | sell-WAVAX | 40 | 858944160 | 855522072 | 5022132898 | 4871468911 | 4997165828 | 855037132 | PASS |

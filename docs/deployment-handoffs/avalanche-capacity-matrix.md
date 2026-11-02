# Avalanche capacity matrix: pinned WAVAX/USDC route (handoff 00 section 4, handoff 09 section 5)

Branch `avalanche-pharaoh-tracks-abcd`. Tests only: nothing signed or broadcast, no keys, borrowing (track B) and trading (track C) stay paused in every deployment this work describes.
Reproduce (exit code 0 only if every manifest test passed and every manifest scenario produced rows; otherwise exit 1 after collecting all results; old outputs in the output directory are deleted first):

```
cd contracts
AVALANCHE_MAINNET_RPC_URL=<archive RPC> tools/run-avalanche-capacity-matrix.sh /tmp/avalanche-capacity-matrix
```

Test: `contracts/test/AvalancheCapacityMatrixFork.t.sol`; required-scenario manifest: `contracts/tools/avalanche-capacity-manifest.json`; generator: `contracts/tools/avalanche-capacity-report.py --strict`. The tables below are generated from one such run.

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

## Verdicts and how caps are derived

Each manifest scenario (slice x config x side x margin x number of positions) gets one verdict over the COMPLETE path, including every subsequent required liquidation and an end-of-path snapshot of every opened position:

| Verdict | Meaning |
| --- | --- |
| PASS | every required liquidation succeeded, every opened position ends LIQUIDATED with zero debt or ACTIVE and not liquidatable, no insurance used, no bad debt |
| PASS-INSURANCE-ASSISTED | as PASS but the insurance fund was drawn; never counted as a pass |
| FAIL-PARTIAL | the first attempt succeeded but a later required liquidation failed, or a position is left liquidatable at the end |
| FAIL-FIRST | the first attempt failed |
| FAIL-BADDEBT | attempts succeeded but debt above remaining collateral is left |
| FAIL-OPEN | the requested number of positions could not even be opened |
| UNTRIGGERED / NOT-RUN | no position became liquidatable on the reachable path / no rows: **no evidence, cannot establish capacity** |

Price regime: `mocked` (oracle cheat-coded, pool untouched; reference only), `external` (the real pool reached the intended grid price), `synthetic` (the pool overshot or hit its floor/ceiling and the oracle followed it to a price no external market produced; debt valuations there are not meaningful), `external->synthetic` (the first attempt was at an external price, later steps were not).

Caps come only from PASS verdicts of class `stress` (single position) and `aggregate` (sequential correlated positions, reported in margin, gross notional and debt) for the candidate configuration. Classes `reference` (mocked), `alternative` (other parameters) and `diagnostic` (loosened guards) never emit launch caps. The safety factor is shown beside, never substituted for aggregate validation.

## Findings (complete-path verdicts, generated tables below)

1. **Candidate `cand-2x25`: no capacity can be established.** Of its 44 required stress scenarios (both sides, margin 1k/5k/25k, all stress slices): 40 are FAIL-FIRST, 3 are UNTRIGGERED (the long under 90% lag never becomes liquidatable on a reachable pool price) and 1 is PASS-INSURANCE-ASSISTED; none is PASS. Nearly all are in the `synthetic` regime because the 25% maintenance triggers (about -34% long, +51% short) lie in the empty gap beyond the pool's liquidity walls: the pool can only be taken there by exhausting it, and the oracle then follows to a meaningless price. Aggregates: 5 x 1k long FAIL-FIRST, 5 x 1k short FAIL-PARTIAL, 10 x 5k both FAIL-FIRST, 4 x 25k FAIL-OPEN (only 2 of 4 positions can be opened because the third open's swap breaches the oracle floor). **Validated single-position margin: none. Validated aggregate: none.**
2. **The single pass-like result is not evidence of capacity.** The candidate USD 1k-margin short in `pool-follows` shows 1 of 1 attempts successful, but the grid step to +50% made the pool jump from about +100% to +225% (the buy wall at about +50% followed by an empty gap), so the oracle followed to 22,477 bps of pin (synthetic). The liquidation executed with 80 bps worst execution cost and repaid about USD 2,224 of debt, but only with **USD 244 (245.15 USDC) of insurance consumed**. Verdict: PASS-INSURANCE-ASSISTED in the synthetic regime. (An earlier revision of this document quoted "+51.8% and 57 bps" from a coarser grid that no longer matches the committed run; superseded.)
3. **Alternatives (no launch cap is emitted for any of them).** `ALT-2x40` (maintenance 40%) triggers inside the buy wall for shorts: with the oracle following the pool exactly (`pool-follows`) the 1k short is PASS, while its 5k and 25k shorts are FAIL-PARTIAL (the first liquidation was partial and succeeded, a later required liquidation failed and the position is left liquidatable); at a fixed 50 bps oracle lag the pattern is the same (1k PASS, larger sizes FAIL-PARTIAL); at 100 bps or more every size is FAIL-FIRST. Its long is FAIL-FIRST at 5k and 25k and FAIL-PARTIAL at 1k (pool-follows) and FAIL-FIRST in all lag slices. Aggregate shorts: 5 x 1k FAIL-PARTIAL (8 of 15 attempts succeed, 3 positions liquidated, 2 left liquidatable), 10 x 5k FAIL-PARTIAL (10 of 40 attempts, none liquidated). `ALT-1.5x25` (triggers outside reachable prices) and the loosened-guard diagnostic `ALT-guard300-2x25` do not rescue the long or the larger sizes. No alternative passes the full stress set.
4. **Oracle restriction.** `IsolatedMarginSwapModule` refuses *unfavourable* execution relative to the oracle on the affected swap leg: the effective minimum is `expectedOut(oracle) x (1 - maxSlippageBps)`. Whether a given oracle/pool gap fails depends on the direction of the leg (sell vs buy), the fee (490 ppm), the price impact of the size and the configured bound; the measured boundaries for USD 5k are in the swap-guard table (sell leg fails once the oracle is about 0.9% above the pool; buy leg between 0.5% and 0.99% below it). It is **not** a symmetric 100-bps deviation rule, and favourable execution always passes. The fixed-lag slices show the practical effect: with the oracle 100 bps or more behind the pool in the adverse direction, normal liquidations fail at every size.
5. **Ordinary lending does not use the pool** and a funded liquidator liquidates it. On a gradual path (liquidations at each step) there is no bad debt for WAVAX collateral down to -80%; for USDC collateral (AVAX up) bad debt is already nonzero at the +300% step (USD 8 to 10 per case, residue after progressive liquidation). After a **price gap** (no intermediate liquidations) bad debt appears much earlier: WAVAX collateral at 99% borrow utilisation from an AVAX fall of 40% and at 70% from 60%; USDC collateral from AVAX +75% (99% utilisation) and +150% (70%). The liquidator budget per USD 50k of borrower collateral (5 borrowers) is about USD 28k to 46k of debt asset. CFs here are placeholders (60% / 75%).
6. **Explicit finding for the proposed launch:** the pinned pool cannot support the 2x trading launch through the normal liquidation route; no cap is derived. The funded in-kind fallback exists and is evaluated below with finite funding; it settles solvent positions without the pool but does not change this conclusion (see the next section).

Caveats: lag and removal were run on `cand-2x25` and `ALT-2x40` only; a USDC depeg was not combined with the liquidation matrix; selective LP exit is not modelled; the chunked pool mover makes the exact price at a wall chunk dependent (the wall locations are not); "outstanding debt" is in base units, bad debt is USD only for non-synthetic paths.

## Funded in-kind fallback with finite funding (`AvalancheFallbackMatrixForkTest`)

Setup: one allowlisted funder (config timelock respected), funded ONCE per scenario with 30,000 USDC and 3,500 WAVAX, approvals limited to those amounts, no replenishment, cumulative inventory. At every stressed step the NORMAL route is attempted first; positions it leaves liquidatable go to `liquidateFunded` at the same state. Floored runs use `minSeizeValueBps` = 10,000 (the funder declines positions worth less than the debt); `fb-nofloor-*` runs have no floor. The route draws no insurance (design choice, `avalanche-funded-fallback.md`). The earlier unlimited-funding tests remain as mechanism diagnostics (40 tests, same doc).

Results (generated tables below; all values from the strict run):

1. **It works where the normal route cannot, for positions that are solvent at the oracle price.** Mocked-oracle shorts (the normal route fails on the oracle-leads-pool floor): the funded route settles 1k / 5k / 25k margin shorts, repaying 115.8 / 578.8 / 2,894.1 WAVAX and receiving pUSDC worth about USD 1,990 / 9,949 / 49,728 (funder mark-to-oracle gain about USD 10 / 48 / 223, roughly 0.5%: at +100% the 2x short barely covers its debt). With **zero cash** in the redemption market the funded route still settles both sides (PASS-VIA-FALLBACK, 6 of 6), with `redeemable now` = 0: the funder holds 231 / 1,157 / 5,777 WAVAX of pWAVAX (long) or 1,990 / 9,949 / 49,728 USDC of pUSDC (short) that cannot be redeemed until the market has cash.
2. **Finite budget.** Per position the funder needs about the debt: 24,505 USDC (25k-margin long; 5,495 USDC of the 30,000 left) or 2,894 WAVAX (25k-margin short; 606 of 3,500 left). The fixed budget therefore covers about one cap-size position per side, or roughly six 5k-margin positions. Exhaustion itself (reverting atomically, state unchanged) is covered by `testAcceptance_fallback_exhaustedFunding_revertsAtomically` and the mechanism suite; in the matrix the break-even floor declined the stressed positions before the budget ran out.
3. **It does not recover insolvent positions.** In the pool-following paths the candidate profile's triggers sit in the empty gap beyond the pool walls, the oracle follows the emptied pool to synthetic prices, and the positions are worth less than their debt there. The floored funder declines (FAIL-FLOOR-DECLINED: 22 of the synthetic scenarios in the table below, including every candidate pool-following long and the aggregate ones): the debt and the shortfall stay in the lending market as bad debt. The unfloored funder completes (PASS-VIA-FALLBACK in 5 of 6; the sixth, the 1k short, is settled by the normal route with a USD 244 insurance draw) but absorbs the whole shortfall; its loss is not valued here because the price is synthetic. Measured on the mechanism suite at plausible prices (USD 5,000 margin): a long at 30% of pin has USD 1,933 bad debt (39% of the debt), a short at 280% USD 3,911 (28%); the insurance seed in this harness (about USD 6.3k) would not cover a cap-size long at -70% (USD 9.3k).
4. **Alternative `ALT-2x40`:** shorts are PASS-VIA-FALLBACK at 5k / 25k in `pool-follows` and at every size with the oracle 100 bps behind the pool, where the normal route fails; its longs reach FAIL-FLOOR-DECLINED after the first partial.
5. **Aggregates:** 5 x 1k and 10 x 5k both sides end FAIL-FLOOR-DECLINED (synthetic prices); 4 x 25k cannot be opened (only 2 of 4 positions open).
6. **USDC depeg (feed 0.98) with 100 bps oracle lag:** the candidate shorts cannot even be opened (FAIL-OPEN): with USDC priced at 0.98 the sell leg of the opening swap falls below the oracle floor against a pool trading near 1.00. The longs reach the pool floor like the others. No guard was loosened.
7. **Successful in-kind seizure is not proof of recovery.** The funder receives pTokens, not cash: where the market has no cash the inventory is unredeemable (carry and price risk on the inventory are quantified in `avalanche-funded-fallback.md`, e.g. the cap-sized long's 5,348 WAVAX is 30% of the pWAVAX supply and an AVAX drop of about 4.7% erases the 5% bonus), and a funder that cannot replenish its debt-asset budget stops after about one cap-size position. The route also does not solve missing valuation: invalid prices revert.

Remaining blockers for any launch cap: a venue (or exposure) where the 25%-maintenance trigger is reachable without exhausting the pool; a funder operating plan (who, budget per asset, replenishment, redemption plan); bad-debt and insurance sizing at externally reachable prices; an audit scope for the changed account/config/liquidator contracts; USDC depeg handling for short opens.

## Generated tables

Generated by `contracts/tools/avalanche-capacity-report.py` against `contracts/tools/avalanche-capacity-manifest.json`. Evidence classes: `oracle-only` = MOCKED oracle, pool untouched (reference, never used for caps); `pool-follows` / `lag*` / `fixedlag*` = pool moved by REAL swaps; `removal*` = EMULATED third-party liquidity removal; `agg-*` = correlated sequential positions; cfg `ALT-*` = alternatives (no launch cap), `ALT-guard300-2x25` = LOOSENED GUARDS, diagnostic only (never emits a cap).

Manifest scenarios: 136; NOT-RUN: 0; manifest test outputs missing: 0. All manifest scenarios produced rows.

## Scenario verdicts (complete path)

`first` = first liquidation attempt; `attempts` = successful/total required attempts along the path; `end state` counts every opened position; `price regime`: `mocked` = oracle moved by cheat code with the pool untouched, `external` = the real pool reached the intended grid price, `synthetic` = the pool overshot/hit its floor or ceiling and the oracle followed it to a price no external market produced (debt valuations there are reported as n/m). `outstanding debt` (base units of the debt asset, all opened positions) and `bad debt` (USD value of debt above remaining collateral at the end-of-path oracle price; shown only when the whole path is at externally reachable prices) are separate; `insurance` = fund consumption (USD and base units). All amounts are sums over the opened positions.

| class | slice | cfg | side | margin each (USD) | k | price regime | verdict | first | attempts | end state | outstanding debt | bad debt (USD) | insurance used | first failure |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| reference | oracle-only | cand-2x25 | long | 1,000 | 1 | mocked | **PASS** | ok | 1/1 | 1 liquidated / 0 active (0 still liquidatable) | 0.0000 USDC | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| reference | oracle-only | cand-2x25 | long | 5,000 | 1 | mocked | **PASS** | ok | 1/1 | 1 liquidated / 0 active (0 still liquidatable) | 0.0000 USDC | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| reference | oracle-only | cand-2x25 | long | 25,000 | 1 | mocked | **PASS** | ok | 1/1 | 1 liquidated / 0 active (0 still liquidatable) | 0.0000 USDC | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| reference | oracle-only | cand-2x25 | short | 1,000 | 1 | mocked | **FAIL-FIRST** | FAIL | 0/2 | 0 liquidated / 1 active (1 still liquidatable) | 115.7639 WAVAX | 980 | 0 (0.0000 USDC, 0.0000 WAVAX) | step 6 oracle 20000 bps / pool 10006 bps: Too little received |
| reference | oracle-only | cand-2x25 | short | 5,000 | 1 | mocked | **FAIL-FIRST** | FAIL | 0/2 | 0 liquidated / 1 active (1 still liquidatable) | 578.8196 WAVAX | 4,900 | 0 (0.0000 USDC, 0.0000 WAVAX) | step 6 oracle 20000 bps / pool 10005 bps: Too little received |
| reference | oracle-only | cand-2x25 | short | 25,000 | 1 | mocked | **FAIL-FIRST** | FAIL | 0/2 | 0 liquidated / 1 active (1 still liquidatable) | 2,894.0981 WAVAX | 24,519 | 0 (0.0000 USDC, 0.0000 WAVAX) | step 6 oracle 20000 bps / pool 9987 bps: Too little received |
| alternative | oracle-only | ALT-2x40 | long | 1,000 | 1 | mocked | **PASS** | ok | 3/3 | 1 liquidated / 0 active (0 still liquidatable) | 0.0000 USDC | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| alternative | oracle-only | ALT-2x40 | long | 5,000 | 1 | mocked | **PASS** | ok | 3/3 | 1 liquidated / 0 active (0 still liquidatable) | 0.0000 USDC | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| alternative | oracle-only | ALT-2x40 | long | 25,000 | 1 | mocked | **PASS** | ok | 3/3 | 1 liquidated / 0 active (0 still liquidatable) | 0.0000 USDC | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| alternative | oracle-only | ALT-2x40 | short | 1,000 | 1 | mocked | **FAIL-FIRST** | FAIL | 0/5 | 0 liquidated / 1 active (1 still liquidatable) | 115.7639 WAVAX | 980 | 0 (0.0000 USDC, 0.0000 WAVAX) | step 3 oracle 12500 bps / pool 10006 bps: Too little received |
| alternative | oracle-only | ALT-2x40 | short | 5,000 | 1 | mocked | **FAIL-FIRST** | FAIL | 0/5 | 0 liquidated / 1 active (1 still liquidatable) | 578.8196 WAVAX | 4,900 | 0 (0.0000 USDC, 0.0000 WAVAX) | step 3 oracle 12500 bps / pool 10005 bps: Too little received |
| alternative | oracle-only | ALT-2x40 | short | 25,000 | 1 | mocked | **FAIL-FIRST** | FAIL | 0/5 | 0 liquidated / 1 active (1 still liquidatable) | 2,894.0981 WAVAX | 24,519 | 0 (0.0000 USDC, 0.0000 WAVAX) | step 3 oracle 12500 bps / pool 9987 bps: Too little received |
| alternative | oracle-only | ALT-1.5x25 | long | 1,000 | 1 | mocked | **PASS** | ok | 1/1 | 1 liquidated / 0 active (0 still liquidatable) | 0.0000 USDC | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| alternative | oracle-only | ALT-1.5x25 | long | 5,000 | 1 | mocked | **PASS** | ok | 1/1 | 1 liquidated / 0 active (0 still liquidatable) | 0.0000 USDC | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| alternative | oracle-only | ALT-1.5x25 | long | 25,000 | 1 | mocked | **PASS** | ok | 1/1 | 1 liquidated / 0 active (0 still liquidatable) | 0.0000 USDC | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| alternative | oracle-only | ALT-1.5x25 | short | 1,000 | 1 | mocked | **FAIL-FIRST** | FAIL | 0/1 | 0 liquidated / 1 active (1 still liquidatable) | 57.3060 WAVAX | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | step 7 oracle 30000 bps / pool 10006 bps: Too little received |
| alternative | oracle-only | ALT-1.5x25 | short | 5,000 | 1 | mocked | **FAIL-FIRST** | FAIL | 0/1 | 0 liquidated / 1 active (1 still liquidatable) | 286.5299 WAVAX | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | step 7 oracle 30000 bps / pool 10006 bps: Too little received |
| alternative | oracle-only | ALT-1.5x25 | short | 25,000 | 1 | mocked | **FAIL-FIRST** | FAIL | 0/1 | 0 liquidated / 1 active (1 still liquidatable) | 1,432.6495 WAVAX | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | step 7 oracle 30000 bps / pool 10000 bps: Too little received |
| diagnostic | oracle-only | ALT-guard300-2x25 | long | 1,000 | 1 | mocked | **PASS** | ok | 1/1 | 1 liquidated / 0 active (0 still liquidatable) | 0.0000 USDC | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| diagnostic | oracle-only | ALT-guard300-2x25 | long | 5,000 | 1 | mocked | **PASS** | ok | 1/1 | 1 liquidated / 0 active (0 still liquidatable) | 0.0000 USDC | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| diagnostic | oracle-only | ALT-guard300-2x25 | long | 25,000 | 1 | mocked | **PASS** | ok | 1/1 | 1 liquidated / 0 active (0 still liquidatable) | 0.0000 USDC | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| diagnostic | oracle-only | ALT-guard300-2x25 | short | 1,000 | 1 | mocked | **FAIL-FIRST** | FAIL | 0/2 | 0 liquidated / 1 active (1 still liquidatable) | 113.5161 WAVAX | 942 | 0 (0.0000 USDC, 0.0000 WAVAX) | step 6 oracle 20000 bps / pool 10006 bps: Too little received |
| diagnostic | oracle-only | ALT-guard300-2x25 | short | 5,000 | 1 | mocked | **FAIL-FIRST** | FAIL | 0/2 | 0 liquidated / 1 active (1 still liquidatable) | 567.5804 WAVAX | 4,708 | 0 (0.0000 USDC, 0.0000 WAVAX) | step 6 oracle 20000 bps / pool 10005 bps: Too little received |
| diagnostic | oracle-only | ALT-guard300-2x25 | short | 25,000 | 1 | mocked | **FAIL-FIRST** | FAIL | 0/2 | 0 liquidated / 1 active (1 still liquidatable) | 2,837.9020 WAVAX | 23,557 | 0 (0.0000 USDC, 0.0000 WAVAX) | step 6 oracle 20000 bps / pool 9988 bps: Too little received |
| stress | pool-follows | cand-2x25 | long | 1,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 980.1980 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| stress | pool-follows | cand-2x25 | long | 5,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 4,900.9901 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| stress | pool-follows | cand-2x25 | long | 25,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 24,504.9505 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| stress | pool-follows | cand-2x25 | short | 1,000 | 1 | synthetic | **PASS-INSURANCE-ASSISTED** | ok | 1/1 | 1 liquidated / 0 active (0 still liquidatable) | 0.0000 WAVAX | n/m (synthetic price) | 244 (245.1489 USDC, 0.0000 WAVAX) | - |
| stress | pool-follows | cand-2x25 | short | 5,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 578.8196 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22560 bps / pool 22560 bps: Too little received |
| stress | pool-follows | cand-2x25 | short | 25,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 2,894.0981 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22576 bps / pool 22576 bps: Too little received |
| alternative | pool-follows | ALT-2x40 | long | 1,000 | 1 | external->synthetic | **FAIL-PARTIAL** | ok | 1/4 | 0 liquidated / 1 active (1 still liquidatable) | 490.0990 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| alternative | pool-follows | ALT-2x40 | long | 5,000 | 1 | external->synthetic | **FAIL-FIRST** | FAIL | 0/5 | 0 liquidated / 1 active (1 still liquidatable) | 4,900.9901 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 3 oracle 8227 bps / pool 8227 bps: Too little received |
| alternative | pool-follows | ALT-2x40 | long | 25,000 | 1 | external->synthetic | **FAIL-FIRST** | FAIL | 0/5 | 0 liquidated / 1 active (1 still liquidatable) | 24,504.9505 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 3 oracle 8224 bps / pool 8224 bps: Too little received |
| alternative | pool-follows | ALT-2x40 | short | 1,000 | 1 | external->synthetic | **PASS** | ok | 2/2 | 1 liquidated / 0 active (0 still liquidatable) | 0.0000 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| alternative | pool-follows | ALT-2x40 | short | 5,000 | 1 | external->synthetic | **FAIL-PARTIAL** | ok | 1/4 | 0 liquidated / 1 active (1 still liquidatable) | 289.4098 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22619 bps / pool 22619 bps: Too little received |
| alternative | pool-follows | ALT-2x40 | short | 25,000 | 1 | external->synthetic | **FAIL-PARTIAL** | ok | 1/4 | 0 liquidated / 1 active (1 still liquidatable) | 1,447.0490 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22477 bps / pool 22477 bps: Too little received |
| alternative | pool-follows | ALT-1.5x25 | long | 1,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 485.2220 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| alternative | pool-follows | ALT-1.5x25 | long | 5,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 2,426.1102 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| alternative | pool-follows | ALT-1.5x25 | long | 25,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 12,130.5510 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| alternative | pool-follows | ALT-1.5x25 | short | 1,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/1 | 0 liquidated / 1 active (1 still liquidatable) | 57.3060 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 7 oracle 1028505423653 bps / pool 1028505423653 bps: Too little received |
| alternative | pool-follows | ALT-1.5x25 | short | 5,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/1 | 0 liquidated / 1 active (1 still liquidatable) | 286.5299 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 7 oracle 1134091052358 bps / pool 1134091052358 bps: Too little received |
| alternative | pool-follows | ALT-1.5x25 | short | 25,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/1 | 0 liquidated / 1 active (1 still liquidatable) | 1,432.6495 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 7 oracle 1174075219708 bps / pool 1174075219708 bps: Too little received |
| diagnostic | pool-follows | ALT-guard300-2x25 | long | 1,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 941.7476 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| diagnostic | pool-follows | ALT-guard300-2x25 | long | 5,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 4,708.7379 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| diagnostic | pool-follows | ALT-guard300-2x25 | long | 25,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 23,543.6893 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| diagnostic | pool-follows | ALT-guard300-2x25 | short | 1,000 | 1 | synthetic | **PASS-INSURANCE-ASSISTED** | ok | 1/1 | 1 liquidated / 0 active (0 still liquidatable) | 0.0000 WAVAX | n/m (synthetic price) | 220 (225.4831 USDC, 0.0000 WAVAX) | - |
| diagnostic | pool-follows | ALT-guard300-2x25 | short | 5,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 567.5804 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22567 bps / pool 22567 bps: Too little received |
| diagnostic | pool-follows | ALT-guard300-2x25 | short | 25,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 2,837.9020 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22615 bps / pool 22615 bps: Too little received |
| stress | lag50 | cand-2x25 | long | 1,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 980.1980 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 5000 bps / pool 0 bps: Too little received |
| stress | lag50 | cand-2x25 | long | 5,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 4,900.9901 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 5000 bps / pool 0 bps: Too little received |
| stress | lag50 | cand-2x25 | long | 25,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 24,504.9505 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 5000 bps / pool 0 bps: Too little received |
| stress | lag50 | cand-2x25 | short | 1,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 115.7639 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 16238 bps / pool 22477 bps: Too little received |
| stress | lag50 | cand-2x25 | short | 5,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 578.8196 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 16280 bps / pool 22560 bps: Too little received |
| stress | lag50 | cand-2x25 | short | 25,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 2,894.0981 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 16288 bps / pool 22576 bps: Too little received |
| alternative | lag50 | ALT-2x40 | long | 1,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 980.1980 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 5000 bps / pool 0 bps: Too little received |
| alternative | lag50 | ALT-2x40 | long | 5,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 4,900.9901 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 5000 bps / pool 0 bps: Too little received |
| alternative | lag50 | ALT-2x40 | long | 25,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 24,504.9505 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 5000 bps / pool 0 bps: Too little received |
| alternative | lag50 | ALT-2x40 | short | 1,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 115.7639 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 16238 bps / pool 22477 bps: Too little received |
| alternative | lag50 | ALT-2x40 | short | 5,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 578.8196 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 16280 bps / pool 22560 bps: Too little received |
| alternative | lag50 | ALT-2x40 | short | 25,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 2,894.0981 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 16288 bps / pool 22576 bps: Too little received |
| stress | lag90 | cand-2x25 | long | 1,000 | 1 | - | **UNTRIGGERED** | - | 0/0 | 0 liquidated / 1 active (0 still liquidatable) | 980.1980 USDC | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| stress | lag90 | cand-2x25 | long | 5,000 | 1 | - | **UNTRIGGERED** | - | 0/0 | 0 liquidated / 1 active (0 still liquidatable) | 4,900.9901 USDC | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| stress | lag90 | cand-2x25 | long | 25,000 | 1 | - | **UNTRIGGERED** | - | 0/0 | 0 liquidated / 1 active (0 still liquidatable) | 24,504.9505 USDC | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| stress | lag90 | cand-2x25 | short | 1,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/1 | 0 liquidated / 1 active (1 still liquidatable) | 115.7639 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 7 oracle 93515621335 bps / pool 935156123358 bps: Too little received |
| stress | lag90 | cand-2x25 | short | 5,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/1 | 0 liquidated / 1 active (1 still liquidatable) | 578.8196 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 7 oracle 113402723903 bps / pool 1134027149032 bps: Too little received |
| stress | lag90 | cand-2x25 | short | 25,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/1 | 0 liquidated / 1 active (1 still liquidatable) | 2,894.0981 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 7 oracle 117676179303 bps / pool 1176761703037 bps: Too little received |
| alternative | lag90 | ALT-2x40 | long | 1,000 | 1 | - | **UNTRIGGERED** | - | 0/0 | 0 liquidated / 1 active (0 still liquidatable) | 980.1980 USDC | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| alternative | lag90 | ALT-2x40 | long | 5,000 | 1 | - | **UNTRIGGERED** | - | 0/0 | 0 liquidated / 1 active (0 still liquidatable) | 4,900.9901 USDC | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| alternative | lag90 | ALT-2x40 | long | 25,000 | 1 | - | **UNTRIGGERED** | - | 0/0 | 0 liquidated / 1 active (0 still liquidatable) | 24,504.9505 USDC | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| alternative | lag90 | ALT-2x40 | short | 1,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/1 | 0 liquidated / 1 active (1 still liquidatable) | 115.7639 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 7 oracle 93515621335 bps / pool 935156123358 bps: Too little received |
| alternative | lag90 | ALT-2x40 | short | 5,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/1 | 0 liquidated / 1 active (1 still liquidatable) | 578.8196 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 7 oracle 113402723903 bps / pool 1134027149032 bps: Too little received |
| alternative | lag90 | ALT-2x40 | short | 25,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/1 | 0 liquidated / 1 active (1 still liquidatable) | 2,894.0981 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 7 oracle 117676179303 bps / pool 1176761703037 bps: Too little received |
| stress | fixedlag50 | cand-2x25 | long | 1,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 980.1980 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| stress | fixedlag50 | cand-2x25 | long | 5,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 4,900.9901 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| stress | fixedlag50 | cand-2x25 | long | 25,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 24,504.9505 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| stress | fixedlag50 | cand-2x25 | short | 1,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 115.7639 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22364 bps / pool 22477 bps: Too little received |
| stress | fixedlag50 | cand-2x25 | short | 5,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 578.8196 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22447 bps / pool 22560 bps: Too little received |
| stress | fixedlag50 | cand-2x25 | short | 25,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 2,894.0981 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22463 bps / pool 22576 bps: Too little received |
| alternative | fixedlag50 | ALT-2x40 | long | 1,000 | 1 | external->synthetic | **FAIL-FIRST** | FAIL | 0/4 | 0 liquidated / 1 active (1 still liquidatable) | 980.1980 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 4 oracle 8038 bps / pool 7998 bps: Too little received |
| alternative | fixedlag50 | ALT-2x40 | long | 5,000 | 1 | external->synthetic | **FAIL-FIRST** | FAIL | 0/4 | 0 liquidated / 1 active (1 still liquidatable) | 4,900.9901 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 4 oracle 7982 bps / pool 7943 bps: Too little received |
| alternative | fixedlag50 | ALT-2x40 | long | 25,000 | 1 | external->synthetic | **FAIL-FIRST** | FAIL | 0/4 | 0 liquidated / 1 active (1 still liquidatable) | 24,504.9505 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 4 oracle 8035 bps / pool 7995 bps: Too little received |
| alternative | fixedlag50 | ALT-2x40 | short | 1,000 | 1 | external->synthetic | **PASS** | ok | 2/2 | 1 liquidated / 0 active (0 still liquidatable) | 0.0000 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| alternative | fixedlag50 | ALT-2x40 | short | 5,000 | 1 | external->synthetic | **FAIL-PARTIAL** | ok | 1/4 | 0 liquidated / 1 active (1 still liquidatable) | 289.4098 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22506 bps / pool 22619 bps: Too little received |
| alternative | fixedlag50 | ALT-2x40 | short | 25,000 | 1 | external->synthetic | **FAIL-PARTIAL** | ok | 1/4 | 0 liquidated / 1 active (1 still liquidatable) | 1,447.0490 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22365 bps / pool 22477 bps: Too little received |
| stress | fixedlag100 | cand-2x25 | long | 1,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 980.1980 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| stress | fixedlag100 | cand-2x25 | long | 5,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 4,900.9901 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| stress | fixedlag100 | cand-2x25 | long | 25,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 24,504.9505 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| stress | fixedlag100 | cand-2x25 | short | 1,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 115.7639 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22252 bps / pool 22477 bps: Too little received |
| stress | fixedlag100 | cand-2x25 | short | 5,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 578.8196 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22334 bps / pool 22560 bps: Too little received |
| stress | fixedlag100 | cand-2x25 | short | 25,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 2,894.0981 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22351 bps / pool 22576 bps: Too little received |
| alternative | fixedlag100 | ALT-2x40 | long | 1,000 | 1 | external->synthetic | **FAIL-FIRST** | FAIL | 0/4 | 0 liquidated / 1 active (1 still liquidatable) | 980.1980 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 4 oracle 8078 bps / pool 7998 bps: Too little received |
| alternative | fixedlag100 | ALT-2x40 | long | 5,000 | 1 | external->synthetic | **FAIL-FIRST** | FAIL | 0/4 | 0 liquidated / 1 active (1 still liquidatable) | 4,900.9901 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 4 oracle 8022 bps / pool 7943 bps: Too little received |
| alternative | fixedlag100 | ALT-2x40 | long | 25,000 | 1 | external->synthetic | **FAIL-FIRST** | FAIL | 0/4 | 0 liquidated / 1 active (1 still liquidatable) | 24,504.9505 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 4 oracle 8075 bps / pool 7995 bps: Too little received |
| alternative | fixedlag100 | ALT-2x40 | short | 1,000 | 1 | external->synthetic | **FAIL-FIRST** | FAIL | 0/5 | 0 liquidated / 1 active (1 still liquidatable) | 115.7639 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 3 oracle 12377 bps / pool 12502 bps: Too little received |
| alternative | fixedlag100 | ALT-2x40 | short | 5,000 | 1 | external->synthetic | **FAIL-FIRST** | FAIL | 0/5 | 0 liquidated / 1 active (1 still liquidatable) | 578.8196 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 3 oracle 12375 bps / pool 12500 bps: Too little received |
| alternative | fixedlag100 | ALT-2x40 | short | 25,000 | 1 | external->synthetic | **FAIL-FIRST** | FAIL | 0/5 | 0 liquidated / 1 active (1 still liquidatable) | 2,894.0981 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 3 oracle 12376 bps / pool 12501 bps: Too little received |
| stress | fixedlag200 | cand-2x25 | long | 1,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 980.1980 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| stress | fixedlag200 | cand-2x25 | long | 5,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 4,900.9901 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| stress | fixedlag200 | cand-2x25 | long | 25,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 24,504.9505 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| stress | fixedlag200 | cand-2x25 | short | 1,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 115.7639 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22027 bps / pool 22477 bps: Too little received |
| stress | fixedlag200 | cand-2x25 | short | 5,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 578.8196 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22108 bps / pool 22560 bps: Too little received |
| stress | fixedlag200 | cand-2x25 | short | 25,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 2,894.0981 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22125 bps / pool 22576 bps: Too little received |
| alternative | fixedlag200 | ALT-2x40 | long | 1,000 | 1 | external->synthetic | **FAIL-FIRST** | FAIL | 0/4 | 0 liquidated / 1 active (1 still liquidatable) | 980.1980 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 4 oracle 8158 bps / pool 7998 bps: Too little received |
| alternative | fixedlag200 | ALT-2x40 | long | 5,000 | 1 | external->synthetic | **FAIL-FIRST** | FAIL | 0/4 | 0 liquidated / 1 active (1 still liquidatable) | 4,900.9901 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 4 oracle 8102 bps / pool 7943 bps: Too little received |
| alternative | fixedlag200 | ALT-2x40 | long | 25,000 | 1 | external->synthetic | **FAIL-FIRST** | FAIL | 0/4 | 0 liquidated / 1 active (1 still liquidatable) | 24,504.9505 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 4 oracle 8155 bps / pool 7995 bps: Too little received |
| alternative | fixedlag200 | ALT-2x40 | short | 1,000 | 1 | external->synthetic | **FAIL-FIRST** | FAIL | 0/5 | 0 liquidated / 1 active (1 still liquidatable) | 115.7639 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 3 oracle 12252 bps / pool 12502 bps: Too little received |
| alternative | fixedlag200 | ALT-2x40 | short | 5,000 | 1 | external->synthetic | **FAIL-FIRST** | FAIL | 0/5 | 0 liquidated / 1 active (1 still liquidatable) | 578.8196 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 3 oracle 12250 bps / pool 12500 bps: Too little received |
| alternative | fixedlag200 | ALT-2x40 | short | 25,000 | 1 | external->synthetic | **FAIL-FIRST** | FAIL | 0/5 | 0 liquidated / 1 active (1 still liquidatable) | 2,894.0981 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 3 oracle 12251 bps / pool 12501 bps: Too little received |
| stress | removal50 | cand-2x25 | long | 5,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 4,900.9901 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| stress | removal50 | cand-2x25 | long | 25,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 24,504.9505 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| stress | removal50 | cand-2x25 | short | 5,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 578.8196 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22560 bps / pool 22560 bps: Too little received |
| stress | removal50 | cand-2x25 | short | 25,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 2,894.0981 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22576 bps / pool 22576 bps: Too little received |
| alternative | removal50 | ALT-2x40 | long | 5,000 | 1 | external->synthetic | **FAIL-FIRST** | FAIL | 0/5 | 0 liquidated / 1 active (1 still liquidatable) | 4,900.9901 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 3 oracle 8227 bps / pool 8227 bps: Too little received |
| alternative | removal50 | ALT-2x40 | long | 25,000 | 1 | external->synthetic | **FAIL-FIRST** | FAIL | 0/5 | 0 liquidated / 1 active (1 still liquidatable) | 24,504.9505 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 3 oracle 8224 bps / pool 8224 bps: Too little received |
| alternative | removal50 | ALT-2x40 | short | 5,000 | 1 | external->synthetic | **FAIL-PARTIAL** | ok | 1/4 | 0 liquidated / 1 active (1 still liquidatable) | 289.4098 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22480 bps / pool 22480 bps: Too little received |
| alternative | removal50 | ALT-2x40 | short | 25,000 | 1 | external->synthetic | **FAIL-PARTIAL** | ok | 1/4 | 0 liquidated / 1 active (1 still liquidatable) | 1,447.0490 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22579 bps / pool 22579 bps: Too little received |
| stress | accrual90d-fee9 | cand-2x25 | long | 5,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 4,921.0393 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| stress | accrual90d-fee9 | cand-2x25 | long | 25,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 24,609.5372 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| stress | accrual90d-fee9 | cand-2x25 | short | 5,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 581.2538 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22560 bps / pool 22560 bps: Too little received |
| stress | accrual90d-fee9 | cand-2x25 | short | 25,000 | 1 | synthetic | **FAIL-FIRST** | FAIL | 0/3 | 0 liquidated / 1 active (1 still liquidatable) | 2,908.1071 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22580 bps / pool 22580 bps: Too little received |
| alternative | accrual90d-fee9 | ALT-2x40 | long | 5,000 | 1 | external->synthetic | **FAIL-FIRST** | FAIL | 0/5 | 0 liquidated / 1 active (1 still liquidatable) | 4,921.0393 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 3 oracle 8226 bps / pool 8226 bps: Too little received |
| alternative | accrual90d-fee9 | ALT-2x40 | long | 25,000 | 1 | external->synthetic | **FAIL-FIRST** | FAIL | 0/5 | 0 liquidated / 1 active (1 still liquidatable) | 24,609.5372 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 3 oracle 8218 bps / pool 8218 bps: Too little received |
| alternative | accrual90d-fee9 | ALT-2x40 | short | 5,000 | 1 | external->synthetic | **FAIL-PARTIAL** | ok | 1/4 | 0 liquidated / 1 active (1 still liquidatable) | 290.6269 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22611 bps / pool 22611 bps: Too little received |
| alternative | accrual90d-fee9 | ALT-2x40 | short | 25,000 | 1 | external->synthetic | **FAIL-PARTIAL** | ok | 1/4 | 0 liquidated / 1 active (1 still liquidatable) | 1,454.0535 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22636 bps / pool 22636 bps: Too little received |
| aggregate | agg-k5 | cand-2x25 | long | 1,000 | 5 | synthetic | **FAIL-FIRST** | FAIL | 0/15 | 0 liquidated / 5 active (5 still liquidatable) | 4,900.9901 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| aggregate | agg-k5 | cand-2x25 | short | 1,000 | 5 | synthetic | **FAIL-PARTIAL** | ok | 1/13 | 1 liquidated / 4 active (4 still liquidatable) | 463.0557 WAVAX | n/m (synthetic price) | 253 (253.4796 USDC, 0.0000 WAVAX) | step 5 oracle 22560 bps / pool 22560 bps: Too little received |
| alternative | agg-k5 | ALT-2x40 | long | 1,000 | 5 | external->synthetic | **FAIL-PARTIAL** | ok | 1/24 | 0 liquidated / 5 active (5 still liquidatable) | 4,410.8911 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 3 oracle 8227 bps / pool 8227 bps: Too little received |
| alternative | agg-k5 | ALT-2x40 | short | 1,000 | 5 | external->synthetic | **FAIL-PARTIAL** | ok | 8/15 | 3 liquidated / 2 active (2 still liquidatable) | 115.7639 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22619 bps / pool 22619 bps: Too little received |
| aggregate | agg-k10 | cand-2x25 | long | 5,000 | 10 | synthetic | **FAIL-FIRST** | FAIL | 0/30 | 0 liquidated / 10 active (10 still liquidatable) | 49,009.9010 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 0 bps / pool 0 bps: Too little received |
| aggregate | agg-k10 | cand-2x25 | short | 5,000 | 10 | synthetic | **FAIL-FIRST** | FAIL | 0/30 | 0 liquidated / 10 active (10 still liquidatable) | 5,788.1962 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22602 bps / pool 22602 bps: Too little received |
| alternative | agg-k10 | ALT-2x40 | long | 5,000 | 10 | external->synthetic | **FAIL-FIRST** | FAIL | 0/50 | 0 liquidated / 10 active (10 still liquidatable) | 49,009.9010 USDC | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 3 oracle 8231 bps / pool 8231 bps: Too little received |
| alternative | agg-k10 | ALT-2x40 | short | 5,000 | 10 | external->synthetic | **FAIL-PARTIAL** | ok | 10/40 | 0 liquidated / 10 active (10 still liquidatable) | 2,894.0981 WAVAX | n/m (synthetic price) | 0 (0.0000 USDC, 0.0000 WAVAX) | step 5 oracle 22605 bps / pool 22605 bps: Too little received |
| aggregate | agg-k4 | cand-2x25 | long | 25,000 | 4 | - | **FAIL-OPEN** | - | 0/0 | - | 0.0000 USDC | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| aggregate | agg-k4 | cand-2x25 | short | 25,000 | 4 | - | **FAIL-OPEN** | - | 0/0 | - | 0.0000 WAVAX | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| alternative | agg-k4 | ALT-2x40 | long | 25,000 | 4 | - | **FAIL-OPEN** | - | 0/0 | - | 0.0000 USDC | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | - |
| alternative | agg-k4 | ALT-2x40 | short | 25,000 | 4 | - | **FAIL-OPEN** | - | 0/0 | - | 0.0000 WAVAX | 0 | 0 (0.0000 USDC, 0.0000 WAVAX) | - |

## Derived limits for the candidate configuration (PASS verdicts only)

Single-position: the largest margin size whose verdict is PASS (no insurance, no bad debt, full path resolved) in EVERY required `stress` scenario for `cand-2x25` and the side. A missing, untriggered, failed or insurance-assisted scenario for a size disqualifies that size. Aggregate: taken only from the sequential correlated `agg-*` executions, in three units: margin, gross notional (margin x leverage) and debt (gross - margin); the safety factor is shown separately and is NOT used to substitute for aggregate validation.

| side | validated single-position margin (USD) | disqualifying scenarios |
|---|---|---|
| long | **NONE (unsupported)** | pool-follows: 1k:FAIL-FIRST, 5k:FAIL-FIRST, 25k:FAIL-FIRST; lag50: 1k:FAIL-FIRST, 5k:FAIL-FIRST, 25k:FAIL-FIRST; lag90: 1k:UNTRIGGERED, 5k:UNTRIGGERED, 25k:UNTRIGGERED; fixedlag50: 1k:FAIL-FIRST, 5k:FAIL-FIRST, 25k:FAIL-FIRST; fixedlag100: 1k:FAIL-FIRST, 5k:FAIL-FIRST, 25k:FAIL-FIRST; fixedlag200: 1k:FAIL-FIRST, 5k:FAIL-FIRST, 25k:FAIL-FIRST; removal50: 5k:FAIL-FIRST, 25k:FAIL-FIRST; accrual90d-fee9: 5k:FAIL-FIRST, 25k:FAIL-FIRST |
| short | **NONE (unsupported)** | pool-follows: 1k:PASS-INSURANCE-ASSISTED, 5k:FAIL-FIRST, 25k:FAIL-FIRST; lag50: 1k:FAIL-FIRST, 5k:FAIL-FIRST, 25k:FAIL-FIRST; lag90: 1k:FAIL-FIRST, 5k:FAIL-FIRST, 25k:FAIL-FIRST; fixedlag50: 1k:FAIL-FIRST, 5k:FAIL-FIRST, 25k:FAIL-FIRST; fixedlag100: 1k:FAIL-FIRST, 5k:FAIL-FIRST, 25k:FAIL-FIRST; fixedlag200: 1k:FAIL-FIRST, 5k:FAIL-FIRST, 25k:FAIL-FIRST; removal50: 5k:FAIL-FIRST, 25k:FAIL-FIRST; accrual90d-fee9: 5k:FAIL-FIRST, 25k:FAIL-FIRST |

| side | aggregate scenario | verdict | margin (USD) | gross notional (USD) | debt (USD) | after safety factor (margin) |
|---|---|---|---|---|---|---|
| long | agg-k5 (5 x 1,000) | FAIL-FIRST | 5,000 | 10,000 | 5,000 | - |
| long | agg-k10 (10 x 5,000) | FAIL-FIRST | 50,000 | 100,000 | 50,000 | - |
| long | agg-k4 (4 x 25,000) | FAIL-OPEN | 100,000 | 200,000 | 100,000 | - |
| long | **validated aggregate** | | **NONE (unsupported)** | | | |
| short | agg-k5 (5 x 1,000) | FAIL-PARTIAL | 5,000 | 10,000 | 5,000 | - |
| short | agg-k10 (10 x 5,000) | FAIL-FIRST | 50,000 | 100,000 | 50,000 | - |
| short | agg-k4 (4 x 25,000) | FAIL-OPEN | 100,000 | 200,000 | 100,000 | - |
| short | **validated aggregate** | | **NONE (unsupported)** | | | |

## Funding and token-unit accounting (aggregate and stress scenarios, candidate config)

Keeper compensation, repayment and borrower surplus in base units of the relevant asset; flash vault and market cash at the end of the path (start: flash vault 3,200,000 USDC and 105,000 WAVAX; supplier cash about 3.4M USDC and 112k WAVAX).

| slice | cfg | side | margin each | k | repaid | keeper reward | borrower surplus (USDC) | flash vault end (USDC / WAVAX) | market cash end (USDC / WAVAX) |
|---|---|---|---|---|---|---|---|---|---|
| pool-follows | cand-2x25 | long | 1,000 | 1 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,000 / 105,000 | 3,404,020 / 112,381 |
| pool-follows | cand-2x25 | long | 5,000 | 1 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,000 / 105,000 | 3,400,099 / 113,307 |
| pool-follows | cand-2x25 | long | 25,000 | 1 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,000 / 105,000 | 3,380,495 / 117,927 |
| pool-follows | cand-2x25 | short | 1,000 | 1 | 115.7639 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,000 | 3,404,755 / 112,150 |
| pool-follows | cand-2x25 | short | 5,000 | 1 | 0.0000 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,000 | 3,414,949 / 111,571 |
| pool-follows | cand-2x25 | short | 25,000 | 1 | 0.0000 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,000 | 3,454,728 / 109,256 |
| lag50 | cand-2x25 | long | 1,000 | 1 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,000 / 105,000 | 3,404,020 / 112,381 |
| lag50 | cand-2x25 | long | 5,000 | 1 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,000 / 105,000 | 3,400,099 / 113,307 |
| lag50 | cand-2x25 | long | 25,000 | 1 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,000 / 105,000 | 3,380,495 / 117,927 |
| lag50 | cand-2x25 | short | 1,000 | 1 | 0.0000 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,000 | 3,406,990 / 112,034 |
| lag50 | cand-2x25 | short | 5,000 | 1 | 0.0000 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,000 | 3,414,949 / 111,571 |
| lag50 | cand-2x25 | short | 25,000 | 1 | 0.0000 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,000 | 3,454,728 / 109,256 |
| lag90 | cand-2x25 | long | 1,000 | 1 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,000 / 105,000 | 3,404,020 / 112,381 |
| lag90 | cand-2x25 | long | 5,000 | 1 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,000 / 105,000 | 3,400,099 / 113,307 |
| lag90 | cand-2x25 | long | 25,000 | 1 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,000 / 105,000 | 3,380,495 / 117,927 |
| lag90 | cand-2x25 | short | 1,000 | 1 | 0.0000 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,000 | 3,406,990 / 112,034 |
| lag90 | cand-2x25 | short | 5,000 | 1 | 0.0000 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,000 | 3,414,949 / 111,571 |
| lag90 | cand-2x25 | short | 25,000 | 1 | 0.0000 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,000 | 3,454,728 / 109,256 |
| fixedlag50 | cand-2x25 | long | 1,000 | 1 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,000 / 105,000 | 3,404,020 / 112,381 |
| fixedlag50 | cand-2x25 | long | 5,000 | 1 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,000 / 105,000 | 3,400,099 / 113,307 |
| fixedlag50 | cand-2x25 | long | 25,000 | 1 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,000 / 105,000 | 3,380,495 / 117,927 |
| fixedlag50 | cand-2x25 | short | 1,000 | 1 | 0.0000 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,000 | 3,406,990 / 112,034 |
| fixedlag50 | cand-2x25 | short | 5,000 | 1 | 0.0000 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,000 | 3,414,949 / 111,571 |
| fixedlag50 | cand-2x25 | short | 25,000 | 1 | 0.0000 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,000 | 3,454,728 / 109,256 |
| fixedlag100 | cand-2x25 | long | 1,000 | 1 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,000 / 105,000 | 3,404,020 / 112,381 |
| fixedlag100 | cand-2x25 | long | 5,000 | 1 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,000 / 105,000 | 3,400,099 / 113,307 |
| fixedlag100 | cand-2x25 | long | 25,000 | 1 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,000 / 105,000 | 3,380,495 / 117,927 |
| fixedlag100 | cand-2x25 | short | 1,000 | 1 | 0.0000 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,000 | 3,406,990 / 112,034 |
| fixedlag100 | cand-2x25 | short | 5,000 | 1 | 0.0000 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,000 | 3,414,949 / 111,571 |
| fixedlag100 | cand-2x25 | short | 25,000 | 1 | 0.0000 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,000 | 3,454,728 / 109,256 |
| fixedlag200 | cand-2x25 | long | 1,000 | 1 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,000 / 105,000 | 3,404,020 / 112,381 |
| fixedlag200 | cand-2x25 | long | 5,000 | 1 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,000 / 105,000 | 3,400,099 / 113,307 |
| fixedlag200 | cand-2x25 | long | 25,000 | 1 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,000 / 105,000 | 3,380,495 / 117,927 |
| fixedlag200 | cand-2x25 | short | 1,000 | 1 | 0.0000 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,000 | 3,406,990 / 112,034 |
| fixedlag200 | cand-2x25 | short | 5,000 | 1 | 0.0000 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,000 | 3,414,949 / 111,571 |
| fixedlag200 | cand-2x25 | short | 25,000 | 1 | 0.0000 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,000 | 3,454,728 / 109,256 |
| removal50 | cand-2x25 | long | 5,000 | 1 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,000 / 105,000 | 3,400,099 / 113,307 |
| removal50 | cand-2x25 | long | 25,000 | 1 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,000 / 105,000 | 3,380,495 / 117,927 |
| removal50 | cand-2x25 | short | 5,000 | 1 | 0.0000 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,000 | 3,414,949 / 111,571 |
| removal50 | cand-2x25 | short | 25,000 | 1 | 0.0000 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,000 | 3,454,728 / 109,256 |
| accrual90d-fee9 | cand-2x25 | long | 5,000 | 1 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,004 / 105,000 | 3,400,103 / 113,306 |
| accrual90d-fee9 | cand-2x25 | long | 25,000 | 1 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,022 / 105,000 | 3,380,517 / 117,922 |
| accrual90d-fee9 | cand-2x25 | short | 5,000 | 1 | 0.0000 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,001 | 3,414,940 / 111,572 |
| accrual90d-fee9 | cand-2x25 | short | 25,000 | 1 | 0.0000 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,003 | 3,454,684 / 109,258 |
| agg-k5 | cand-2x25 | long | 1,000 | 5 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,000 / 105,000 | 3,400,099 / 113,307 |
| agg-k5 | cand-2x25 | short | 1,000 | 5 | 115.7639 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,000 | 3,412,706 / 111,687 |
| agg-k10 | cand-2x25 | long | 5,000 | 10 | 0.0000 USDC | 0.0000 USDC | 0.0000 USDC | 3,200,000 / 105,000 | 3,355,990 / 123,680 |
| agg-k10 | cand-2x25 | short | 5,000 | 10 | 0.0000 WAVAX | 0.0000 WAVAX | 0.0000 USDC | 3,200,000 / 105,000 | 3,504,397 / 106,362 |

## Funded in-kind fallback with finite funding (class `fallback*`)

One allowlisted funder, funded ONCE per scenario (30,000 USDC and 3,500 WAVAX, approvals limited to the budget), no replenishment between attempts, cumulative seized inventory. At each stressed step the NORMAL route is attempted first; positions it leaves liquidatable go to the funded route at the same state. `fb-nofloor-*` runs the funder with no break-even floor (it absorbs any shortfall); all others use the floor (`minSeizeValueBps` = 10,000, the call reverts when seized value < repaid value). `redeemable now` = min(inventory, market cash): pTokens are not cash. Funder P&L is seized value minus repaid value at the oracle price at each attempt (not realised). The route draws no insurance; `insurance used` is the NORMAL route's draw.

| class | slice | cfg | side | margin each | k | price regime | verdict | normal route ok/total | funded ok/total | first funded failure | funder repaid | budget left (USDC / WAVAX) | inventory (underlying USDC / WAVAX) | inventory USD | redeemable now (USDC / WAVAX) | funder P&L (USD) | normal-route insurance (USD) | outstanding debt | bad debt (USD) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| fallback-reference | fb-oracle-only | cand-2x25 | long | 1,000 | 1 | mocked | **PASS-NORMAL** | 1/1 | 0/0 | - | - | 30,000 / 3,500.0 | 0.00 / 0.00 | 0 | 0.00 / 0.00 | 0 | 0 | 0.0000 USDC | 0 |
| fallback-reference | fb-oracle-only | cand-2x25 | long | 5,000 | 1 | mocked | **PASS-NORMAL** | 1/1 | 0/0 | - | - | 30,000 / 3,500.0 | 0.00 / 0.00 | 0 | 0.00 / 0.00 | 0 | 0 | 0.0000 USDC | 0 |
| fallback-reference | fb-oracle-only | cand-2x25 | long | 25,000 | 1 | mocked | **PASS-NORMAL** | 1/1 | 0/0 | - | - | 30,000 / 3,500.0 | 0.00 / 0.00 | 0 | 0.00 / 0.00 | 0 | 0 | 0.0000 USDC | 0 |
| fallback-reference | fb-oracle-only | cand-2x25 | short | 1,000 | 1 | mocked | **PASS-VIA-FALLBACK** | 0/1 | 1/1 | - | 115.7639 WAVAX | 30,000 / 3,384.2 | 1,989.89 / 0.00 | 1,989 | 1,989.89 / 0.00 | 10 | 0 | 0.0000 WAVAX | 0 |
| fallback-reference | fb-oracle-only | cand-2x25 | short | 5,000 | 1 | mocked | **PASS-VIA-FALLBACK** | 0/1 | 1/1 | - | 578.8196 WAVAX | 30,000 / 2,921.2 | 9,949.13 / 0.00 | 9,945 | 9,949.13 / 0.00 | 48 | 0 | 0.0000 WAVAX | 0 |
| fallback-reference | fb-oracle-only | cand-2x25 | short | 25,000 | 1 | mocked | **PASS-VIA-FALLBACK** | 0/1 | 1/1 | - | 2,894.0981 WAVAX | 30,000 / 605.9 | 49,728.43 / 0.00 | 49,707 | 49,728.43 / 0.00 | 223 | 0 | 0.0000 WAVAX | 0 |
| fallback-reference | fb-oracle-only | ALT-2x40 | long | 1,000 | 1 | mocked | **PASS-NORMAL** | 3/3 | 0/0 | - | - | 30,000 / 3,500.0 | 0.00 / 0.00 | 0 | 0.00 / 0.00 | 0 | 0 | 0.0000 USDC | 0 |
| fallback-reference | fb-oracle-only | ALT-2x40 | long | 5,000 | 1 | mocked | **PASS-NORMAL** | 3/3 | 0/0 | - | - | 30,000 / 3,500.0 | 0.00 / 0.00 | 0 | 0.00 / 0.00 | 0 | 0 | 0.0000 USDC | 0 |
| fallback-reference | fb-oracle-only | ALT-2x40 | long | 25,000 | 1 | mocked | **PASS-NORMAL** | 3/3 | 0/0 | - | - | 30,000 / 3,500.0 | 0.00 / 0.00 | 0 | 0.00 / 0.00 | 0 | 0 | 0.0000 USDC | 0 |
| fallback-reference | fb-oracle-only | ALT-2x40 | short | 1,000 | 1 | mocked | **PASS-VIA-FALLBACK** | 0/3 | 3/3 | - | 115.7639 WAVAX | 30,000 / 3,384.2 | 1,949.26 / 0.00 | 1,948 | 1,949.26 / 0.00 | 93 | 0 | 0.0000 WAVAX | 0 |
| fallback-reference | fb-oracle-only | ALT-2x40 | short | 5,000 | 1 | mocked | **PASS-VIA-FALLBACK** | 0/3 | 3/3 | - | 578.8196 WAVAX | 30,000 / 2,921.2 | 9,746.29 / 0.00 | 9,742 | 9,746.29 / 0.00 | 464 | 0 | 0.0000 WAVAX | 0 |
| fallback-reference | fb-oracle-only | ALT-2x40 | short | 25,000 | 1 | mocked | **PASS-VIA-FALLBACK** | 0/3 | 3/3 | - | 2,894.0981 WAVAX | 30,000 / 605.9 | 48,731.44 / 0.00 | 48,711 | 48,731.44 / 0.00 | 2,320 | 0 | 0.0000 WAVAX | 0 |
| fallback | fb-pool-follows | cand-2x25 | long | 1,000 | 1 | synthetic | **FAIL-FLOOR-DECLINED** | 0/3 | 0/3 | step 5 pool 0 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 980.1980 USDC | n/m |
| fallback | fb-pool-follows | cand-2x25 | long | 5,000 | 1 | synthetic | **FAIL-FLOOR-DECLINED** | 0/3 | 0/3 | step 5 pool 0 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 4,900.9901 USDC | n/m |
| fallback | fb-pool-follows | cand-2x25 | long | 25,000 | 1 | synthetic | **FAIL-FLOOR-DECLINED** | 0/3 | 0/3 | step 5 pool 0 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 24,504.9505 USDC | n/m |
| fallback | fb-pool-follows | cand-2x25 | short | 1,000 | 1 | synthetic | **PASS-NORMAL-INSURANCE-ASSISTED** | 1/1 | 0/0 | - | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 244 | 0.0000 WAVAX | n/m |
| fallback | fb-pool-follows | cand-2x25 | short | 5,000 | 1 | synthetic | **FAIL-FLOOR-DECLINED** | 0/3 | 0/3 | step 5 pool 22560 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 578.8196 WAVAX | n/m |
| fallback | fb-pool-follows | cand-2x25 | short | 25,000 | 1 | synthetic | **FAIL-FLOOR-DECLINED** | 0/3 | 0/3 | step 5 pool 22576 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 2,894.0981 WAVAX | n/m |
| fallback | fb-pool-follows | ALT-2x40 | long | 1,000 | 1 | external->synthetic | **FAIL-FLOOR-DECLINED** | 1/4 | 0/3 | step 5 pool 0 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 490.0990 USDC | n/m |
| fallback | fb-pool-follows | ALT-2x40 | long | 5,000 | 1 | external->synthetic | **FAIL-FLOOR-DECLINED** | 0/4 | 1/4 | step 5 pool 0 bps: LiquidationError(32) | 2,450.4950 USDC | 27,550 / 3,500.0 | 0.00 / 365.65 | n/m | 0.00 / 365.65 | n/m | 0 | 2,450.4950 USDC | n/m |
| fallback | fb-pool-follows | ALT-2x40 | long | 25,000 | 1 | external->synthetic | **FAIL-FLOOR-DECLINED** | 0/4 | 1/4 | step 5 pool 0 bps: LiquidationError(32) | 12,252.4752 USDC | 17,748 / 3,500.0 | 0.00 / 1,828.84 | n/m | 0.00 / 1,828.84 | n/m | 0 | 12,252.4752 USDC | n/m |
| fallback | fb-pool-follows | ALT-2x40 | short | 1,000 | 1 | external->synthetic | **PASS-NORMAL** | 2/2 | 0/0 | - | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 0.0000 WAVAX | n/m |
| fallback | fb-pool-follows | ALT-2x40 | short | 5,000 | 1 | external->synthetic | **PASS-VIA-FALLBACK** | 1/2 | 1/1 | - | 289.4098 WAVAX | 30,000 / 3,210.6 | 5,878.95 / 0.00 | n/m | 5,878.95 / 0.00 | n/m | 0 | 0.0000 WAVAX | n/m |
| fallback | fb-pool-follows | ALT-2x40 | short | 25,000 | 1 | external->synthetic | **PASS-VIA-FALLBACK** | 1/2 | 1/1 | - | 1,447.0490 WAVAX | 30,000 / 2,053.0 | 29,209.79 / 0.00 | n/m | 29,209.79 / 0.00 | n/m | 0 | 0.0000 WAVAX | n/m |
| fallback | fb-fixedlag100 | cand-2x25 | long | 1,000 | 1 | synthetic | **FAIL-FLOOR-DECLINED** | 0/3 | 0/3 | step 5 pool 0 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 980.1980 USDC | n/m |
| fallback | fb-fixedlag100 | cand-2x25 | long | 5,000 | 1 | synthetic | **FAIL-FLOOR-DECLINED** | 0/3 | 0/3 | step 5 pool 0 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 4,900.9901 USDC | n/m |
| fallback | fb-fixedlag100 | cand-2x25 | long | 25,000 | 1 | synthetic | **FAIL-FLOOR-DECLINED** | 0/3 | 0/3 | step 5 pool 0 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 24,504.9505 USDC | n/m |
| fallback | fb-fixedlag100 | cand-2x25 | short | 1,000 | 1 | synthetic | **FAIL-FLOOR-DECLINED** | 0/3 | 0/3 | step 5 pool 22477 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 115.7639 WAVAX | n/m |
| fallback | fb-fixedlag100 | cand-2x25 | short | 5,000 | 1 | synthetic | **FAIL-FLOOR-DECLINED** | 0/3 | 0/3 | step 5 pool 22560 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 578.8196 WAVAX | n/m |
| fallback | fb-fixedlag100 | cand-2x25 | short | 25,000 | 1 | synthetic | **FAIL-FLOOR-DECLINED** | 0/3 | 0/3 | step 5 pool 22576 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 2,894.0981 WAVAX | n/m |
| fallback | fb-fixedlag100 | ALT-2x40 | long | 1,000 | 1 | external->synthetic | **FAIL-FLOOR-DECLINED** | 0/4 | 1/4 | step 5 pool 0 bps: LiquidationError(32) | 490.0990 USDC | 29,510 / 3,500.0 | 0.00 / 74.48 | n/m | 0.00 / 74.48 | n/m | 0 | 490.0990 USDC | n/m |
| fallback | fb-fixedlag100 | ALT-2x40 | long | 5,000 | 1 | external->synthetic | **FAIL-FLOOR-DECLINED** | 0/4 | 1/4 | step 5 pool 0 bps: LiquidationError(32) | 2,450.4950 USDC | 27,550 / 3,500.0 | 0.00 / 374.99 | n/m | 0.00 / 374.99 | n/m | 0 | 2,450.4950 USDC | n/m |
| fallback | fb-fixedlag100 | ALT-2x40 | long | 25,000 | 1 | external->synthetic | **FAIL-FLOOR-DECLINED** | 0/4 | 1/4 | step 5 pool 0 bps: LiquidationError(32) | 12,252.4752 USDC | 17,748 / 3,500.0 | 0.00 / 1,862.71 | n/m | 0.00 / 1,862.71 | n/m | 0 | 12,252.4752 USDC | n/m |
| fallback | fb-fixedlag100 | ALT-2x40 | short | 1,000 | 1 | external->synthetic | **PASS-VIA-FALLBACK** | 0/2 | 2/2 | - | 115.7639 WAVAX | 30,000 / 3,384.2 | 1,800.06 / 0.00 | n/m | 1,800.06 / 0.00 | n/m | 0 | 0.0000 WAVAX | n/m |
| fallback | fb-fixedlag100 | ALT-2x40 | short | 5,000 | 1 | external->synthetic | **PASS-VIA-FALLBACK** | 0/2 | 2/2 | - | 578.8196 WAVAX | 30,000 / 2,921.2 | 9,021.23 / 0.00 | n/m | 9,021.23 / 0.00 | n/m | 0 | 0.0000 WAVAX | n/m |
| fallback | fb-fixedlag100 | ALT-2x40 | short | 25,000 | 1 | external->synthetic | **PASS-VIA-FALLBACK** | 0/2 | 2/2 | - | 2,894.0981 WAVAX | 30,000 / 605.9 | 45,128.15 / 0.00 | n/m | 45,128.15 / 0.00 | n/m | 0 | 0.0000 WAVAX | n/m |
| fallback | fb-depeg98-lag100 | cand-2x25 | long | 1,000 | 1 | synthetic | **FAIL-FLOOR-DECLINED** | 0/3 | 0/3 | step 5 pool 0 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 980.1980 USDC | n/m |
| fallback | fb-depeg98-lag100 | cand-2x25 | long | 5,000 | 1 | synthetic | **FAIL-FLOOR-DECLINED** | 0/3 | 0/3 | step 5 pool 0 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 4,900.9901 USDC | n/m |
| fallback | fb-depeg98-lag100 | cand-2x25 | long | 25,000 | 1 | synthetic | **FAIL-FLOOR-DECLINED** | 0/3 | 0/3 | step 5 pool 0 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 24,504.9505 USDC | n/m |
| fallback | fb-depeg98-lag100 | cand-2x25 | short | 1,000 | 1 | - | **FAIL-OPEN** | 0/0 | 0/0 | - | - | - | - | - | - | 0 | 0 | - | 0 |
| fallback | fb-depeg98-lag100 | cand-2x25 | short | 5,000 | 1 | - | **FAIL-OPEN** | 0/0 | 0/0 | - | - | - | - | - | - | 0 | 0 | - | 0 |
| fallback | fb-depeg98-lag100 | cand-2x25 | short | 25,000 | 1 | - | **FAIL-OPEN** | 0/0 | 0/0 | - | - | - | - | - | - | 0 | 0 | - | 0 |
| fallback | fb-accrual90d-fee9 | cand-2x25 | long | 5,000 | 1 | synthetic | **FAIL-FLOOR-DECLINED** | 0/3 | 0/3 | step 5 pool 0 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 4,921.0393 USDC | n/m |
| fallback | fb-accrual90d-fee9 | cand-2x25 | long | 25,000 | 1 | synthetic | **FAIL-FLOOR-DECLINED** | 0/3 | 0/3 | step 5 pool 0 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 24,609.5372 USDC | n/m |
| fallback | fb-accrual90d-fee9 | cand-2x25 | short | 5,000 | 1 | synthetic | **FAIL-FLOOR-DECLINED** | 0/3 | 0/3 | step 5 pool 22560 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 581.2538 WAVAX | n/m |
| fallback | fb-accrual90d-fee9 | cand-2x25 | short | 25,000 | 1 | synthetic | **FAIL-FLOOR-DECLINED** | 0/3 | 0/3 | step 5 pool 22580 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 2,908.1071 WAVAX | n/m |
| fallback-aggregate | fb-agg-k5 | cand-2x25 | long | 1,000 | 5 | synthetic | **FAIL-FLOOR-DECLINED** | 0/15 | 0/15 | step 5 pool 0 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 4,900.9901 USDC | n/m |
| fallback-aggregate | fb-agg-k5 | cand-2x25 | short | 1,000 | 5 | synthetic | **FAIL-FLOOR-DECLINED** | 1/13 | 0/12 | step 5 pool 22560 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 253 | 463.0557 WAVAX | n/m |
| fallback-aggregate | fb-agg-k10 | cand-2x25 | long | 5,000 | 10 | synthetic | **FAIL-FLOOR-DECLINED** | 0/30 | 0/30 | step 5 pool 0 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 49,009.9010 USDC | n/m |
| fallback-aggregate | fb-agg-k10 | cand-2x25 | short | 5,000 | 10 | synthetic | **FAIL-FLOOR-DECLINED** | 0/30 | 0/30 | step 5 pool 22602 bps: LiquidationError(32) | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 0 | 5,788.1962 WAVAX | n/m |
| fallback-aggregate | fb-agg-k4 | cand-2x25 | long | 25,000 | 4 | - | **FAIL-OPEN** | 0/0 | 0/0 | - | - | - | - | - | - | 0 | 0 | - | 0 |
| fallback-aggregate | fb-agg-k4 | cand-2x25 | short | 25,000 | 4 | - | **FAIL-OPEN** | 0/0 | 0/0 | - | - | - | - | - | - | 0 | 0 | - | 0 |
| fallback-nofloor | fb-nofloor-pool-follows | cand-2x25 | long | 1,000 | 1 | synthetic | **PASS-VIA-FALLBACK** | 0/1 | 1/1 | - | 980.1980 USDC | 29,020 / 3,500.0 | 0.00 / 231.34 | n/m | 0.00 / 231.34 | n/m | 0 | 0.0000 USDC | n/m |
| fallback-nofloor | fb-nofloor-pool-follows | cand-2x25 | long | 5,000 | 1 | synthetic | **PASS-VIA-FALLBACK** | 0/1 | 1/1 | - | 4,900.9901 USDC | 25,099 / 3,500.0 | 0.00 / 1,156.56 | n/m | 0.00 / 1,156.56 | n/m | 0 | 0.0000 USDC | n/m |
| fallback-nofloor | fb-nofloor-pool-follows | cand-2x25 | long | 25,000 | 1 | synthetic | **PASS-VIA-FALLBACK** | 0/1 | 1/1 | - | 24,504.9505 USDC | 5,495 / 3,500.0 | 0.00 / 5,777.28 | n/m | 0.00 / 5,777.28 | n/m | 0 | 0.0000 USDC | n/m |
| fallback-nofloor | fb-nofloor-pool-follows | cand-2x25 | short | 1,000 | 1 | synthetic | **PASS-NORMAL-INSURANCE-ASSISTED** | 1/1 | 0/0 | - | - | 30,000 / 3,500.0 | 0.00 / 0.00 | n/m | 0.00 / 0.00 | n/m | 244 | 0.0000 WAVAX | n/m |
| fallback-nofloor | fb-nofloor-pool-follows | cand-2x25 | short | 5,000 | 1 | synthetic | **PASS-VIA-FALLBACK** | 0/1 | 1/1 | - | 578.8196 WAVAX | 30,000 / 2,921.2 | 9,949.13 / 0.00 | n/m | 9,949.13 / 0.00 | n/m | 0 | 0.0000 WAVAX | n/m |
| fallback-nofloor | fb-nofloor-pool-follows | cand-2x25 | short | 25,000 | 1 | synthetic | **PASS-VIA-FALLBACK** | 0/1 | 1/1 | - | 2,894.0981 WAVAX | 30,000 / 605.9 | 49,728.43 / 0.00 | n/m | 49,728.43 / 0.00 | n/m | 0 | 0.0000 WAVAX | n/m |
| fallback | fb-zerocash-oracle-only | cand-2x25 | long | 1,000 | 1 | mocked | **PASS-VIA-FALLBACK** | 0/1 | 1/1 | - | 980.1980 USDC | 29,020 / 3,500.0 | 0.00 / 231.34 | 396 | 0.00 / 0.00 | 9 | 0 | 0.0000 USDC | 0 |
| fallback | fb-zerocash-oracle-only | cand-2x25 | long | 5,000 | 1 | mocked | **PASS-VIA-FALLBACK** | 0/1 | 1/1 | - | 4,900.9901 USDC | 25,099 / 3,500.0 | 0.00 / 1,156.56 | 1,978 | 0.00 / 0.00 | 45 | 0 | 0.0000 USDC | 0 |
| fallback | fb-zerocash-oracle-only | cand-2x25 | long | 25,000 | 1 | mocked | **PASS-VIA-FALLBACK** | 0/1 | 1/1 | - | 24,504.9505 USDC | 5,495 / 3,500.0 | 0.00 / 5,777.28 | 9,878 | 0.00 / 0.00 | 201 | 0 | 0.0000 USDC | 0 |
| fallback | fb-zerocash-oracle-only | cand-2x25 | short | 1,000 | 1 | mocked | **PASS-VIA-FALLBACK** | 0/1 | 1/1 | - | 115.7639 WAVAX | 30,000 / 3,384.2 | 1,989.89 / 0.00 | 1,989 | 0.00 / 0.00 | 10 | 0 | 0.0000 WAVAX | 0 |
| fallback | fb-zerocash-oracle-only | cand-2x25 | short | 5,000 | 1 | mocked | **PASS-VIA-FALLBACK** | 0/1 | 1/1 | - | 578.8196 WAVAX | 30,000 / 2,921.2 | 9,949.13 / 0.00 | 9,945 | 0.00 / 0.00 | 48 | 0 | 0.0000 WAVAX | 0 |
| fallback | fb-zerocash-oracle-only | cand-2x25 | short | 25,000 | 1 | mocked | **PASS-VIA-FALLBACK** | 0/1 | 1/1 | - | 2,894.0981 WAVAX | 30,000 / 605.9 | 49,728.43 / 0.00 | 49,707 | 0.00 / 0.00 | 223 | 0 | 0.0000 WAVAX | 0 |

Funder budget requirements measured here are the tokens repaid by the funder in scenarios that completed; scenarios marked FAIL-FUNDING-EXHAUSTED show that the fixed budget was insufficient for the stress path (no replenishment).


## Open failures

| slice | cfg | side | margin each | requested k | opened | revert |
|---|---|---|---|---|---|---|
| fb-depeg98-lag100 | cand-2x25 | short | 1,000 | 1 | 0 | Too little received |
| fb-depeg98-lag100 | cand-2x25 | short | 5,000 | 1 | 0 | Too little received |
| fb-depeg98-lag100 | cand-2x25 | short | 25,000 | 1 | 0 | Too little received |
| fb-agg-k4 | cand-2x25 | long | 25,000 | 4 | 2 | Too little received |
| fb-agg-k4 | cand-2x25 | short | 25,000 | 4 | 2 | Too little received |
| agg-k4 | cand-2x25 | long | 25,000 | 4 | 2 | Too little received |
| agg-k4 | cand-2x25 | short | 25,000 | 4 | 2 | Too little received |
| agg-k4 | ALT-2x40 | long | 25,000 | 4 | 2 | Too little received |
| agg-k4 | ALT-2x40 | short | 25,000 | 4 | 2 | Too little received |

## Ordinary lending liquidations (funded liquidator, no swap)

USD, sums over the borrowers (each USD 10k collateral). `path` = price moves step by step with liquidations at every step; `GAP` = price jumps straight to the level. Bad debt = residual debt not covered by remaining collateral at that price; it can be nonzero on a gradual path at large moves too.

| mode / direction | borrow util % | borrowers | AVAX bps of pin | in shortfall | repaid (liquidator budget) | net seized | protocol share | residual debt | bad debt |
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

First step with bad debt: GAP wavax-collateral/usdc-debt util 70% n=5: 4000 bps; GAP wavax-collateral/usdc-debt util 99% n=5: 6000 bps; GAP usdc-collateral/wavax-debt util 70% n=5: 25000 bps; GAP usdc-collateral/wavax-debt util 99% n=5: 17500 bps; path usdc-collateral/wavax-debt util 70% n=1: 40000 bps; path usdc-collateral/wavax-debt util 70% n=5: 40000 bps; path usdc-collateral/wavax-debt util 99% n=1: 40000 bps; path usdc-collateral/wavax-debt util 99% n=5: 40000 bps

## Swap-guard reconciliation (real `IsolatedMarginSwapModule`, USD 5k notional)

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

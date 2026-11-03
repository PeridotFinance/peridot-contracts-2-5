# Cash-only lending: decision table, pilot recommendation, required funding

Status: **PROPOSAL derived from the stress tests; nothing here is an approved parameter.** No deployment, borrowing activation, signing, production parameter change or handoff 00 edit. Borrowing stays paused. Product: cash-only lending markets **pUSDC (USDC)** and **pWAVAX (WAVAX)** on Avalanche C-Chain, plain delegates, guarded Chainlink oracle (primary only; the secondary oracle is deferred and no freshness limit is widened).

Evidence base: closed form and measured grid of `avalanche-cash-only-risk-proposal.md` (fork suite `AvalancheCashOnlyRiskStudyFork.t.sol`, 18 tests, synthetic grid on a mocked-feed fixture); empirical price gaps (`avalanche-cash-only-risk-evidence/price-data/`, CoinGecko close-to-close, one year daily and 90 days hourly); feed delays measured on chain on 2026-11-03; gas and cost from `avalanche-operating-cost-estimate.md`. Tables below are produced by `avalanche-cash-only-risk-evidence/analysis/decision-table.py` (reproducible).

## 1. Recommendation (read this first)
**Pilot: one direction only. Borrow USDC against WAVAX (direction W). Collateral factor 40% on WAVAX, collateral factor 0% on USDC, WAVAX borrowing disabled (pWAVAX is a collateral-only market).** Candidate name `PW40`. Sizing is a function of the protection capital you fund, not a percentage I ask you to guess:

| Quantity | Rule (from the tests) | Per USD 100,000 of USDC borrow cap | Worked example: cap USD 100,000 |
| --- | --- | --- | --- |
| Zero-bad-debt gap | `1 - CF x u x LI` (u = 99%, LI = 1.08) | AVAX fall of **57.2%** in one step; survives the worst observed move of every window up to 30 days (-42.9%) | |
| Loss beyond it (tail) | `D x (1 - rho/LI)`, `rho = (1-x)/(CF x u)` | 6.5% of debt at a -60% step; 24.2% at -67.6% (the year's peak-to-trough treated as one step); 41.5% at -75% | |
| **Dedicated protection capital** (loss backing; separate ledger) | cap x loss at the tail you choose | USD 6,472 (tail -60%) / 24,178 (tail -67.6%) / 41,545 (tail -75%) | **USD 6,500 at a -60% tail** |
| **Liquidator inventory** (USDC; operator capital) | first round = close factor (50%) x aggregate debt in shortfall; up to about 1.0x for full clearance (study maximum 0.9998x) | USD 50,000 first round; up to 100,000 | **two independent operators, each able to fund the first round (USD 50,000 each); total capital at risk of immobilisation up to USD 100,000** |
| **Withdrawal cash** (not extra funding: the part of supplier USDC that stays un-lent) | borrow cash floor on pUSDC so borrows cannot take cash below it; study: floors of 5/10/20% of supply cap utilisation at 95/90/80% | supply >= cap / (1 - floor share) | **USDC supply >= USD 125,000 with a 20% floor (cash floor 25,000)**. The floor guards new borrows only; suppliers can still withdraw below it |
| Liquidator exit cash | seized claim is **pWAVAX**, and the pWAVAX market has no borrowers in this pilot, so its cash equals its deposits: the claim is fully redeemable (the exit-cash problem of the study arises only when the collateral market is also borrowed) | no floor needed on pWAVAX | |
| Operating cost (candidate-independent) | cents per transaction; hosting reused; batched monitoring reads | about 0.008 USD per liquidation; tens of cents per month at pilot scale | **under USD 1 per month in gas**, plus the existing host and alert channel (no subscription proposed) |

**Funding for the worked example (cap USD 100,000):** protection capital USD 6,500 (dedicated) + liquidator inventory USD 50,000 per operator x 2 (operator-held) + USDC supply USD 125,000 of which USD 25,000 stays as withdrawal cash (supplier money, not a separate fund) + operating funds (negligible). **These are four separate pots and none is counted twice** (`avalanche-funding-purposes-and-loss-reserve.md`). Scaling: every USD 10,000 of cap needs USD 650 of protection (tail -60%), USD 5,000 of first-round inventory per operator, USD 12,500 of supply.

If you prefer **zero modelled loss through everything observed in the year, even as an instantaneous gap, choose `PW30`** (CF 30%: zero-loss fall -67.9%, protection capital USD 0 at the -67.6% tail and USD 22,060 per 100,000 at a -75% tail). It halves the borrower's capacity (30% of collateral value) and is the safer pilot; `PW40` is the recommended balance because every observed window up to 30 days is survived with zero bad debt.

**Why one direction materially reduces funding.** Two-direction candidates add the U direction (WAVAX debt against USDC collateral), which needs WAVAX liquidator inventory as a second asset, a floor and exit-cash analysis on a market that is both collateral and debt (the study: at 95% market utilisation a liquidator can redeem only 23% (W) or 74% (U) of its seized claim), protection capital for a second tail, and exposure to a USDC depeg (a USDC fall of x% acts like an AVAX rise: AVAX x2 and USDC x0.5 give the identical bad-debt share, measured). For equal caps the protection and inventory needs roughly double in total, and the pWAVAX market would need its own cash floor. The pilot removes all of that.

**Fork verification of `PW40` (`contracts/test/AvalancheCashOnlyPilotConfigFork.t.sol`, 5 tests, margin-free fixture, pinned block 99,200,000):** (1) USDC collateral gives no borrowing power, WAVAX borrowing is refused (paused), WAVAX collateral borrows USDC up to 40% (101% of capacity refused, 99% allowed); (2) the 20% cash floor (cash 400,000, floor 80,000) refuses a borrow one unit beyond it and allows the boundary; (3) borrowers at 99% of capacity, price gaps in one step at the worst observed 1 h (-6.7%), 24 h (-12.4%), 7 day (-25.5%) and 30 day (-42.9%) falls: **zero bad debt**, the liquidator redeems its whole seized pWAVAX claim in WAVAX, and the liquidator's USDC repayments were 0.50x the debt in one round (3 windows) and 0.75x in two rounds (30-day gap); (4) tail steps of -60% / -67.6% / -75% leave a measured loss of the debt that matches the closed form (6.47% / 24.18% / 41.54%) within 0.4 percentage points; (5) a 24 h feed outage followed by a fresh round at the 7-day worst fall: no new borrow and no liquidation during the outage, repay works, zero bad debt afterwards. Mocked-feed fixture, synthetic liquidity; the same caveats as the risk study.

## 2. Candidate table (derived, not chosen)
Definitions: direction **W** = WAVAX collateral, USDC debt (hurt by an AVAX fall); direction **U** = USDC collateral, WAVAX debt (hurt by an AVAX rise or a USDC depeg). u = borrower utilisation of borrowing power (99% = maximum allowed borrow; the protocol cannot cap it below its collateral factor), LI = 1.08, close factor 50%.

## A. Empirical AVAX/USD moves by window (source: price-data/README.md)
| Window (= length of an outage or of a liquidation delay) | worst fall | worst rise | largest CF with zero bad debt: W (USDC debt) at that fall | U (WAVAX debt) at that rise |
|---|---|---|---|---|
| 1 h | -6.7% | +6.5% | 87.3% | 87.8% |
| 6 h | -9.0% | +16.0% | 85.1% | 80.6% |
| 24 h | -12.4% | +23.9% | 81.9% | 75.5% |
| 3 days | -18.2% | +48.8% | 76.5% | 62.8% |
| 7 days | -25.5% | +55.5% | 69.6% | 60.1% |
| 14 days | -32.0% | +57.3% | 63.6% | 59.4% |
| 30 days | -42.9% | +60.8% | 53.4% | 58.2% |
| peak-to-trough over the year (daily closes) | -67.6% | trough-to-peak +96.9% | 30.3% | 47.5% |

## B. Zero-bad-debt gap and loss beyond it (u = 99%, LI = 1.08; % of the debt of the affected direction)
| Candidate | CF W | CF U | W zero-loss fall | loss at -50% / -60% / -67.6% (year drawdown) / -75% | U zero-loss rise | loss at +100% / +150% / +200% |
|---|---|---|---|---|---|---|
| PW30 | 30% | 0% | -67.9% | 0.0% / 0.0% / 0.0% / 22.1% | n/a (direction disabled) | n/a |
| PW40 | 40% | 0% | -57.2% | 0.0% / 6.5% / 24.2% / 41.5% | n/a (direction disabled) | n/a |
| PW50 | 50% | 0% | -46.5% | 6.5% / 25.2% / 39.3% / 53.2% | n/a (direction disabled) | n/a |
| D40/40 | 40% | 40% | -57.2% | 0.0% / 6.5% / 24.2% / 41.5% | +134% | 0.0% / 6.5% / 22.1% |
| D50/50 | 50% | 50% | -46.5% | 6.5% / 25.2% / 39.3% / 53.2% | +87% | 6.5% / 25.2% / 37.6% |
| D60/60 | 60% | 60% | -35.8% | 22.1% / 37.6% / 49.5% / 61.0% | +56% | 22.1% / 37.6% / 48.0% |
| PLACEHOLDER 60/75 | 60% | 75% | -35.8% | 22.1% / 37.6% / 49.5% / 61.0% | +25% | 37.6% / 50.1% / 58.4% |

## C. Which empirical windows each candidate survives with zero bad debt (u = 99%)
| Candidate | W survives worst move of: | U survives worst move of: |
|---|---|---|
| PW30 | 1 h, 6 h, 24 h, 3 days, 7 days, 14 days, 30 days, year drawdown | n/a |
| PW40 | 1 h, 6 h, 24 h, 3 days, 7 days, 14 days, 30 days | n/a |
| PW50 | 1 h, 6 h, 24 h, 3 days, 7 days, 14 days, 30 days | n/a |
| D40/40 | 1 h, 6 h, 24 h, 3 days, 7 days, 14 days, 30 days | 1 h, 6 h, 24 h, 3 days, 7 days, 14 days, 30 days, year run-up |
| D50/50 | 1 h, 6 h, 24 h, 3 days, 7 days, 14 days, 30 days | 1 h, 6 h, 24 h, 3 days, 7 days, 14 days, 30 days |
| D60/60 | 1 h, 6 h, 24 h, 3 days, 7 days, 14 days | 1 h, 6 h, 24 h, 3 days, 7 days |
| PLACEHOLDER 60/75 | 1 h, 6 h, 24 h, 3 days, 7 days, 14 days | 1 h, 6 h, 24 h |

## D. Dedicated protection capital per USD 100,000 of borrow cap (loss at a stated tail gap; zero where the candidate survives it)
| Candidate | W tail -60% | W tail -67.6% | W tail -75% | U tail +100% | U tail +150% |
|---|---|---|---|---|---|
| PW30 | 0 | 0 | 22,060 | n/a | n/a |
| PW40 | 6,472 | 24,178 | 41,545 | n/a | n/a |
| PW50 | 25,178 | 39,343 | 53,236 | n/a | n/a |
| D40/40 | 6,472 | 24,178 | 41,545 | 0 | 6,472 |
| D50/50 | 25,178 | 39,343 | 53,236 | 6,472 | 25,178 |
| D60/60 | 37,648 | 49,452 | 61,030 | 22,060 | 37,648 |
| PLACEHOLDER 60/75 | 37,648 | 49,452 | 61,030 | 37,648 | 50,118 |
(USD per 100,000 of debt cap in that direction; two-direction candidates need both directions' protection if both caps are used.)

## E. Cap that a given protection capital supports (USD of borrow cap per USD 10,000 of protection capital) at a stated tail gap
| Candidate | W tail -67.6% | W tail -75% | U tail +100% |
|---|---|---|---|
| PW30 | unbounded (zero loss) | 45,331 | n/a |
| PW40 | 41,359 | 24,070 | n/a |
| PW50 | 25,418 | 18,784 | n/a |
| D40/40 | 41,359 | 24,070 | unbounded (zero loss) |
| D50/50 | 25,418 | 18,784 | 154,509 |
| D60/60 | 20,222 | 16,385 | 45,331 |
| PLACEHOLDER 60/75 | 20,222 | 16,385 | 26,562 |

## F. Gradual-path bad debt (measured, risk study section 2.4; share of debt at 99% utilisation, steps of 5/10/20% for W, 10/25/50% for U; K = liquidation calls per account per step)
| CF | W K=1 | W K=4 | U K=1 | U K=4 |
|---|---|---|---|---|
| 30% | 0/0/0 | 0/0/0 | 0/0/0 | 0/0/0 |
| 50% | 0/0/1.8% | 0/0/0 | 0/0/1.9% | 0/0/0 |
| 60% | 0/0.3%/8.4% | 0/0/1.1% | 0/0/12.6% | 0/0/0 |
| 70% | 0/0.9%/13.2% | 0/0/0.7% | 0/6.6%/21.6% | 0/0/10.9% |
(40% was not in the gradual-path grid; between the 30% and 50% rows.)


Cross-check against the measured grid (risk proposal section 2.2): the placeholder 60/75 row reproduces the measured losses (22.1% at -50%, 37.6% at -60%, 37.6% at +100%); measured largest tested CF with zero bad debt at 99% utilisation (W: -50% -> 40%, -60% -> 30%; U: +100% -> 40%) agrees with the closed form (46.8%, 37.4%, 46.8%).

## 3. Oracle delays and outages: what they do and whether the pilot is supportable
Current guards are kept: freshness limits of **1,200 s (AVAX) and 90,000 s (USDC)**, zero sentinel on bad rounds, no emergency price. Nothing here proposes widening them.

| Feed | Measured on chain (2026-11-03) | Limit | Margin |
| --- | --- | --- | --- |
| AVAX/USD | 1,500 consecutive rounds over 38.9 h: median gap 120 s, p99 136 s, **max 147 s**, none over 600 s | 1,200 s | 8.2x the worst observed gap (short sample: 39 h) |
| USDC/USD | 92 valid rounds over 90.8 days (aggregator phase 3 only): median 86,413 s, max 86,489 s, **worst lateness over the 24 h heartbeat: 89 s** | 90,000 s | slack 3,511 s, 39x the worst observed lateness |

**What a stale feed does** (tested): new borrows, ordinary liquidation and redemptions/transfers by accounts that entered markets stop; repay keeps working; a USDC outage stops AVAX-collateral accounts too, because every price-dependent action needs both prices. Bad debt that builds during an outage is realised at the first fresh price. So an outage of length T is equivalent to a price gap of the empirical worst move over T:

| Outage of | worst AVAX fall (W) | PW30 / PW40 / PW50 bad debt | worst rise (U) |
| --- | --- | --- | --- |
| 1 h | -6.7% | 0 / 0 / 0 | +6.5% |
| 24 h | -12.4% | 0 / 0 / 0 | +23.9% |
| 7 days | -25.5% | 0 / 0 / 0 | +55.5% |
| 30 days | -42.9% | 0 / 0 / 0 | +60.8% |
(zero bad debt at u = 99% for all three pilot candidates, at every window up to 30 days; the placeholder 60/75 survives only up to 14 days (W) and 24 h (U).) What an outage still costs the pilot is availability (no new borrow, no liquidation, entered suppliers frozen until the feed returns) and the risk that an outage coincides with a move larger than the table. **No outage longer than 147 s (AVAX) or 89 s late (USDC) has been observed in the samples**, so the availability cost is unmeasured rather than shown to be large.

**Is the one-direction pilot supportable under these restrictions? Yes**, on the evidence: the freshness limits have 8x (AVAX, short sample) and 39x (USDC, 91 days) headroom over observed behaviour, and a CF of 30% to 50% survives the worst observed move of every window up to 30 days with zero bad debt even if liquidation is unavailable for that whole window. It remains exposed to: an outage coinciding with a tail move beyond the table (covered only by the protection capital), a USDC round later than 3,511 s (observed worst 89 s; the feed's other phases were not examined), and the AVAX sample being only 39 hours long. These would be monitored (feed age against limit; `avalanche-cash-only-risk-proposal.md` section 4), not solved by widening.

## 4. Binding constraints (what could still stop the pilot)
1. **Loss handling: resolved as a recommendation, not built.** `avalanche-cash-only-loss-handling.md` (32 fork tests; prototype test-only) compares four handlings of the same real shortfall. **Pilot: S1, a dedicated pre-funded treasury account that repays defaulted accounts with the existing `repayBorrowBehalf`** (no new code; debt gone, exchange rate flat, no phantom interest, no early/late advantage; the treasury cost is exactly the loss, i.e. the protection capital above). `_addReserves` is NOT equivalent: the debt stays recorded and keeps accruing, the money becomes protocol reserves that an admin can withdraw, and the exit shortfall reappears (USDC 245 in 90 days in the test). **Scale: S3, an explicit reserve-first write-off in a new audited delegate with caps, precondition, timelock and event** (an unrestricted write-off is a measured theft vector: an admin borrowing 50,000 and writing it off cuts every supplier's claim by 8.32%); it needs shares-accounting support (new markets use shares borrow accounting, which has no forgiveness path) and has a race window for suppliers who exit before it executes. Reserve accrual is far too slow to be the backstop (about USD 44 per 100,000 of borrows per month at 27% market utilisation).
2. **Audit** of the borrow cash floor change in `PeridottrollerAvalanche` and of the deployment script/bootstrapper.
3. **Liquidator conversion liquidity.** A liquidator ends with WAVAX and needs USDC again. The pinned Pharaoh pool's sell side is a wall (about USD 98.5k of USDC in total); conversion at pilot scale on other venues was not measured.
4. **Liquidator operations and monitoring** (specified, not built), and **the PERIDOT token decision** (unresolved).
5. Parameters are conditional on u = 99% and on one year of price history; a different regime changes the tail rows.

## 5. Remaining decisions for you (specific)
1. Pilot direction and candidate: `PW40` (recommended) or `PW30` (zero modelled loss through the year's drawdown) or a two-direction candidate (not recommended for a first pilot).
2. The tail gap the protection capital must cover (-60% recommended: USD 6,500 per 100,000 of cap; -67.6%: 24,200; -75%: 41,500) and who contributes it (operator seed).
3. Pilot borrow cap and the matching USDC supply and floor (the example: cap 100,000, supply 125,000, floor 20%).
4. Liquidator operators (two independent) and their inventory.
5. Loss handling: accept S1 (pre-funded treasury `repayBorrowBehalf`) for the pilot, and decide whether the audited reserve-first write-off (S3) is built before any scale-up.
6. Liquidation incentive (1.08 assumed; net liquidator margin after the 2.8% seize share is 497.6 bp; it turns negative below 1.0288) and close factor (50% assumed).
7. Rate-model shape and reserve factor (affects supplier yield and reserve accrual, not the safety figures; at the placeholder shape 80% utilisation gives about 12% borrow APR and 1.19% of borrows per year to reserves, i.e. replenishment, not backing).

## 6. Labels and separation (reserve tables)
Pair and asset: cash-only lending **pUSDC / USDC** (suppliers deposit USDC; protection benchmark = holding USDC) and **pWAVAX / WAVAX** (collateral deposits; benchmark = holding WAVAX). The exposure behind the loss tables is AVAX/USD price risk on WAVAX collateral against USDC debt (AVAX/stablecoin); it is NOT the sAVAX/WAVAX or USDC/USDt exposure of the Pharaoh vaults, and not the WAVAX/USDC strategy of the unbuilt Pharaoh allocation. Withdrawal cash, loss backing (protection capital), operating funds and liquidator inventory are four separate pots; future yield and reserve-factor accrual are **replenishment only** and are not counted in any funding figure above.

## 7. Limits
Closed form assumes a single instantaneous gap from a position at u of borrowing power, LI and close factor as stated, liquidators acting on the first fresh price with enough inventory, and no price impact of liquidation; bad debt is linear in the borrowed amount. Empirical gaps come from CoinGecko close-to-close data (hourly for 90 days, daily for a year), not from the Chainlink feed, and understate intra-interval extremes; one year is one regime (it included a fall from 16.6 to 8.5 USD and a trough of 5.9). Feed delay samples are short (39 h AVAX; 91 days USDC, one aggregator phase). The fork results are on a mocked-feed fixture with synthetic parameters. Not modelled: liquidator competition, gas spikes, the real block time (the fixture rate model assumes 1 s blocks), mixed-collateral accounts, dust positions.

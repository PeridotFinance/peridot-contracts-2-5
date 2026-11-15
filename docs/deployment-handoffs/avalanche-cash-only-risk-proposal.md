# Avalanche cash-only lending: risk-parameter study, liquidator specification, monitoring list and bad-debt options

Status: **proposal with test-supported ranges for an operator decision. No production value is chosen, nothing is approved, borrowing stays paused.** Draft. Nothing signed, broadcast or deployed; no keys used.

Product: **cash-only lending** (pUSDC and pWAVAX, plain markets, no margin stack, no strategy), the same product as `avalanche-cash-only-lending-readiness.md`. Product names are used on purpose; the track letters of the handoff files are not reconciled.

## 0. Summary

1. **One closed form explains every cell, and the fork confirms it.** For a borrower at borrow utilisation `u` (borrowed value / borrowing power), with collateral factor `CF`, liquidation incentive `LI`, and an instant price gap that changes the collateral/debt value ratio by a factor `s`, the account is cleared without loss if and only if `rho = s / (CF*u) >= LI` (equivalently `CF <= s/(u*LI)`). Otherwise the unpaid debt is `D * (1 - rho/LI)`, whatever the close factor. 2,376 gap cells (both directions, 4 incentives, 3 close factors, 11 CF values, 3 utilisations, 6 gap sizes each) match this to within 1% of the debt plus USD 0.05 in every cell (0 mismatches; the AVAX x2 / USDC x0.5 equivalence test adds one more cell), so the safe-region map in section 2.2 is both measured and derived.
2. **Placeholder collateral factors (60% WAVAX, 75% USDC) are not gap-safe at maximum borrow.** At 99% of borrowing power, 60% WAVAX collateral survives an instant AVAX fall of about 36% (bad debt appears at -40%: 6.4% of the debt; -50%: 22%; -70%: 53%); 75% USDC collateral survives an instant AVAX rise of about 25% (+75%: 29% of the debt; +100%: 38%; +200%: 58%). To survive a -50% / +100% gap at maximum borrow with LI = 1.08 the collateral factor must be at most about **46.8%** for either collateral (section 2.2 has the full map). **No collateral factor protects against a gap larger than its limit; the only lever is a lower factor or a lower borrower utilisation, which the protocol does not control.**
3. **Gradual price paths are much kinder but not free**: up to CF 50% there is no bad debt for steps up to 10% (W) / 25% (U) even with one liquidation call per account per step; at CF 60% a slow liquidator (one call per step) already leaves 0.3% on 10% steps and 8.4% on 20% steps (1.1% with four calls per step). Details in section 2.4.
4. **Liquidator inventory** (section 3): the debt asset needed is up to about **1.0x the aggregate debt of the accounts that fall into shortfall** (typically 0.5x to 0.94x; 0.5x is the close-factor first round), in the asset that is owed (USDC for an AVAX fall, WAVAX for an AVAX rise). At 1.08 the liquidator keeps **497.6 bp** of the repaid value after the 2.8% protocol seize share; the measured gas is about 245k (warm, mocked feeds) to 420k (cold, real feeds) per liquidation plus 62k to 108k for redeeming the seized claim.
5. **Monitoring** (section 4): 20 metrics, each tied to a failure found by the study.
6. **Bad debt** (section 5): in a plain market nothing writes bad debt off. The unpaid borrow stays on the books and keeps counting in the exchange rate (measured: exchange rate unchanged after the loss), so the loss is borne by the **last suppliers to exit** (first come, first served), **not pro rata**. Cash held as `totalReserves` in the market shields suppliers exactly one for one (measured identity: exit shortfall = max(0, loss - reserves)). Reserve-factor interest alone is far too slow to cover gap losses (1.2% to 2.7% of borrows per year for the placeholder rate-model shape at 80% to 95% utilisation and a 10% reserve factor, 0.4% to 9.2% across the three synthetic shapes, section 5.2, against 6% to 58% of the affected debt in one gap at the placeholder factors). The **borrow cash floor is not a reserve and not liquidator funding** (section 5.4 table).

**Operator decisions that remain (none is taken here):** collateral factors; borrow caps and the intended borrower leverage (which sets the real `u`); liquidation incentive and close factor; reserve factors and rate-model shapes (and the blocks-per-year assumption); the cash floor per market and who may raise it; maximum feed age per feed; the liquidator operators, their funding and keys; the bad-debt policy (reserve-first, treasury backstop, or a code change that does not exist today); the alert thresholds and who is paged.

## 1. What was run, and how far to trust it

| Item | Value |
| --- | --- |
| Test file | `contracts/test/AvalancheCashOnlyRiskStudyFork.t.sol` (new; inherits `AvalancheCashOnlyBase`, overrides nothing) |
| Fixture | Controller + pUSDC + pWAVAX + guarded oracle only; both margin hooks `address(0)`; pinned fork block 99,200,000 |
| Result | **18 tests, 18 passed** (`attempt12-final-full.txt` is the evidence of record at the final code state; its `RISK|CELL` lines are byte-identical to `attempt05-full.txt`). 2,376 gap cells (+1 equivalence cell), 240 gradual-path cells, 14 stale-availability rows, 16 stale-open cells, 40 exit cells, 27 reserve-accrual runs, 63 rate-model rows, gas, monitoring and identity tests |
| Machine-readable output | lines prefixed `RISK|` (kinds CELL, STALE, STALEOPEN, EXIT, IRM, ACCR, RESFIRST, EQV, GAS, MON, SUMMARY); column legend at the top of the test file |
| Evidence | `docs/deployment-handoffs/avalanche-cash-only-risk-evidence/` (every attempt, passing and failing, header = UTC time, git HEAD, command) |
| Analysis scripts | `.../avalanche-cash-only-risk-evidence/analysis/*.py` (read the `RISK|` lines; they regenerate the tables below) |

**Asserted** (accounting identities and "the harness behaved", never a fairness threshold): every setup borrow succeeded; every cell emitted exactly one line; seized value = repay x incentive within 1%; the protocol share is 2.8% of the seize; `totalBorrows` fell by the repay; borrower debts sum to `totalBorrows`; cash + borrows - reserves = supplier claims; the closed form matches the measurement; fail-closed oracle behaviour; exit shortfall = max(0, loss - reserves); an AVAX rise of x2 and a USDC fall to x0.5 give the same bad-debt share.

**Everything here is a SYNTHETIC GRID on a synthetic fixture.** The numbers below depend on:

- a **mocked price path**: the feeds are mocked and move instantly, so there is no Chainlink deviation threshold, heartbeat, round gap or latency; real feed behaviour for these two feeds is not tested (the readiness report already lists the maximum age and heartbeat/deviation behaviour as not fixed by any test);
- **one harness-funded liquidator** with unlimited budget, no competition, no gas price, no swap and no redemption latency;
- **`deal`-minted collateral**: three borrowers per cell, USD 10,000 collateral each, against 400,000 USDC and 12,000 WAVAX of liquidity supplied by one LP. Ratios (bad debt as a share of debt, inventory as a share of debt) scale linearly; absolute USD amounts are for three borrowers only;
- **single-asset accounts**: each borrower supplies one asset and borrows the other. Mixed accounts (collateral in both markets, or debt in both) were not tested;
- **interest** accrues on `block.number` and only where a test rolls blocks; the fixture rate model assumes 31,536,000 blocks per year (one block per second). If the chain's real block time differs, every APR figure scales by that factor. The operator must set that parameter from the measured block rate (not measured here).

Everything that would change the numbers is listed in section 7.

## 2. Area 1: risk parameters

Definitions used throughout. Direction **W** = WAVAX collateral, USDC debt (hurt by an AVAX fall). Direction **U** = USDC collateral, WAVAX debt (hurt by an AVAX rise **or a USDC depeg**: only the AVAX/USDC ratio matters, tested: AVAX x2 and USDC x0.5 give the identical bad-debt share, 37.64% of the debt, in `RISK|EQV`). **Borrower utilisation** `u` = borrowed value as a percentage of the account's borrowing power (the capacity-matrix definition; the grid used 70, 90 and 99%; 99% is "maximum allowed borrow"). **Market utilisation** = borrows / (cash + borrows - reserves) (sections 2.6 and 2.7). LI = liquidation incentive, c = close factor.

### 2.1 What each parameter does to loss (derived, then confirmed)

Let `rho` be the collateral value divided by the debt value right after the shock. Each liquidation round with close factor c moves `rho` to `(rho - c*LI)/(1 - c)`, which rises iff `rho > LI`. So:

- `rho >= LI` (or the account is still healthy): fully cleared, zero bad debt, for **any** close factor (the close factor only changes the number of rounds).
- `rho < LI`: the collateral is exhausted before the debt; the unpaid debt is `D * (1 - rho/LI)`. (Note this includes positions whose collateral is still worth more than the debt: for `1 <= rho < LI` a liquidation incentive of 8% eats the whole cushion. Bad debt starts at `rho = LI`, not at `rho = 1`.)
- `rho = s / (CF*u)` for direction W with an AVAX fall of `1 - s`; `rho = 1 / (CF*u*s)` for direction U with an AVAX rise of `s - 1`.

So the largest collateral factor with zero bad debt for a gap of size `x` is `CF* = (1-x)/(u*LI)` (W, AVAX falls by `x`) and `CF* = 1/(u*LI*(1+x))` (U, AVAX rises by `x`), capped at the controller maximum 90%. Bad debt is **linear in the borrowed amount**, so the borrow cap sets the worst-case loss: `loss <= cap * (1 - rho/LI)`.

### 2.2 SAFE REGION map (largest collateral factor with zero bad debt)

Measured grid (LI = 1.08, c = 50%, bad debt <= USD 0.05 across three borrowers; collateral factors tested: 30, 40, 50, 55, 60, 65, 70, 75, 80, 85, 90%; each entry is the largest tested value):

| Direction | Util | AVAX move (shock) -> largest tested CF with zero bad debt |
| --- | --- | --- |
| W | 99% | -20%: 70% / -30%: 65% / -40%: 55% / -50%: 40% / -60%: 30% / -70%: **none (30% already fails)** |
| W | 90% | -20%: 80% / -30%: 70% / -40%: 60% / -50%: 50% / -60%: 40% / -70%: 30% |
| W | 70% | -20%: 90% / -30%: 90% / -40%: 75% / -50%: 65% / -60%: 50% / -70%: 30% |
| U | 99% | +25%: 70% / +50%: 60% / +75%: 50% / +100%: 40% / +150%: 30% / +200%: 30% |
| U | 90% | +25%: 80% / +50%: 65% / +75%: 55% / +100%: 50% / +150%: 40% / +200%: 30% |
| U | 70% | +25%: 90% / +50%: 85% / +75%: 75% / +100%: 65% / +150%: 50% / +200%: 40% |

Continuous values from the closed form (identical to the grid wherever both exist). Largest collateral factor with zero bad debt, **borrowers at 99% of borrowing power**, by incentive:

| Gap | LI 1.05 | LI 1.08 | LI 1.10 | LI 1.15 |
| --- | --- | --- | --- | --- |
| W: AVAX -20% | 77.0% | 74.8% | 73.5% | 70.3% |
| W: -30% | 67.3% | 65.5% | 64.3% | 61.5% |
| W: -40% | 57.7% | 56.1% | 55.1% | 52.7% |
| W: -50% | 48.1% | 46.8% | 45.9% | 43.9% |
| W: -60% | 38.5% | 37.4% | 36.7% | 35.1% |
| W: -70% | 28.9% | 28.1% | 27.5% | 26.4% |
| U: AVAX +25% | 77.0% | 74.8% | 73.5% | 70.3% |
| U: +50% | 64.1% | 62.4% | 61.2% | 58.6% |
| U: +75% | 55.0% | 53.4% | 52.5% | 50.2% |
| U: +100% | 48.1% | 46.8% | 45.9% | 43.9% |
| U: +150% | 38.5% | 37.4% | 36.7% | 35.1% |
| U: +200% | 32.1% | 31.2% | 30.6% | 29.3% |

The same table at borrower utilisation 90% (LI 1.08): W -20/-30/-40/-50/-60/-70%: 82.3 / 72.0 / 61.7 / 51.4 / 41.2 / 30.9%; U +25/+50/+75/+100/+150/+200%: 82.3 / 68.6 / 58.8 / 51.4 / 41.2 / 34.3%. At 70%: W 90 / 90 / 79.4 / 66.1 / 52.9 / 39.7; U 90 / 88.2 / 75.6 / 66.1 / 52.9 / 44.1.

**Gap a given collateral factor survives** (zero bad debt; LI 1.08):

| CF | W: largest AVAX fall, util 99% / 90% / 70% | U: largest AVAX rise, util 99% / 90% / 70% |
| --- | --- | --- |
| 30% | -68% / -71% / -77% | +212% / +243% / +341% |
| 40% | -57% / -61% / -70% | +134% / +157% / +231% |
| 50% | -47% / -51% / -62% | +87% / +106% / +165% |
| 60% (placeholder W) | **-36%** / -42% / -55% | +56% / +71% / +120% |
| 70% | -25% / -32% / -47% | +34% / +47% / +89% |
| 75% (placeholder U) | -20% / -27% / -43% | **+25%** / +37% / +76% |
| 80% | -14% / -22% / -40% | +17% / +29% / +65% |
| 90% | -4% / -13% / -32% | +4% / +14% / +47% |

**What this protects against and what it cannot.** A collateral factor protects only against gaps up to its limit and only if borrowers sit at or below the utilisation assumed; it cannot protect against a larger gap (the loss is then `1 - rho/LI` of the debt, e.g. 60% WAVAX at 99%: 6.4% at -40%, 22.1% at -50%, 37.6% at -60%, 53.2% at -70%; 75% USDC at 99%: 0.2% at +25%, 16.9% at +50%, 28.7% at +75%, 37.6% at +100%, 50.1% at +150%, 58.4% at +200%), against an oracle that is stale or wrong (sections 2.5 and 4), against collateral that cannot be liquidated because nobody has the debt asset (section 3), or against gradual losses when liquidation is slow (section 2.4). A collateral factor above `1/LI` (92.6% at LI 1.08, 87% at 1.15; the controller maximum is 90%) loses collateral faster than debt on every liquidation, so it leaves bad debt even on the slowest path (section 2.4).

Choosing the factor is a policy choice about which gap to survive; the table is the price list. Example reading: "survive a one-step -50% AVAX move and a +100% move with LI = 1.08 at maximum leverage" means a factor of at most 46.8% on both assets (W has no tested factor at or above 30% that survives -70%).

### 2.3 Placeholder values (60% / 75%), measured

At 99% of borrowing power the placeholder factors lose in the percentages above. At 70% borrower utilisation: W 60% loses 11.8% at -60%, 0% at -50%; U 75% loses 11.8% at +100%, 29.5% at +150%. **Refinement of the capacity matrix (slice G2), which the readiness report quotes:** the matrix's first-loss points for direction U ("+75% at 99% utilisation, +150% at 70%") were the first steps its coarse list happened to test (its GAP rows skip +25%, +50% and +100%), not thresholds. This finer grid shows the 75% USDC factor already loses 0.2% of the debt at +25% and 16.9% at +50% (99% utilisation), and 11.8% at +100% at 70% utilisation. For direction W the matrix agrees with this grid (99% utilisation, -40%: matrix residual USD 1,910 on about USD 29,700 of debt = 6.4%, the same share as here; 60% WAVAX loses from about -36%). Numbers quoted from the matrix should be updated accordingly.

### 2.4 Gradual paths (liquidation at each price step)

240 path cells: price walks to -80% (W, steps of 5%, 10%, 20%) or +200% (U, steps of 10%, 25%, 50%), the liquidator makes up to K liquidation calls per account per step (K = 1 or 4), c = 50%, LI = 1.08 unless stated; borrowers at 90% and 99%. Bad debt at the end of the path at 99% utilisation, as a share of the debt:

| CF | W, K=1: 5% / 10% / 20% steps | W, K=4: 5% / 10% / 20% | U, K=1: 10% / 25% / 50% steps | U, K=4: 10% / 25% / 50% |
| --- | --- | --- | --- | --- |
| 30% | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| 50% | 0 / 0 / 1.8% | 0 / 0 / 0 | 0 / 0 / 1.9% | 0 / 0 / 0 |
| 60% | 0 / 0.3% / 8.4% | 0 / 0 / 1.1% | 0 / 0 / 12.6% | 0 / 0 / 0 |
| 70% | 0 / 0.9% / 13.2% | 0 / 0 / 0.7% | 0 / 6.6% / 21.6% | 0 / 0 / 10.9% |
| 80% | 0.1% / 5.3% / 19.9% | 0 / 0 / 6.4% | 1.7% / 15.3% / 29.0% | 0 / 6.5% / 22.1% |
| 90% | 5.5% / 13.0% / 25.1% | 1.5% / 6.4% / 16.8% | 10.6% / 22.8% / 35.5% | 5.6% / 16.9% / 30.7% |

Reading: (a) **liquidation speed matters as much as the factor**: with one call per account per step the placeholder 60% already loses 8.4% on 20% steps, and with four calls per step it loses 1.1%; (b) **at CF 80% to 90% bad debt appears even on small steps with one call per step**, because the cushion between the point where an account becomes liquidatable (`rho = 1/CF`, 1.11 at 90%) and the point where liquidation stops paying for itself (`rho = LI`) is thin, so a single step's move erodes it; above `CF = 1/LI` (87% at LI 1.15) the cushion is negative and every path loses; (c) a **higher incentive generally makes gradual bad debt worse** (CF 90% W, 10% steps, K=1: 11.1% / 13.0% / 17.4% across LI 1.05 / 1.08 / 1.15; CF 75% U, 25% steps: 9.3% / 11.1% / 15.2%) because each liquidation consumes more collateral per unit of debt, though not in every cell (CF 60% W, 10% steps: 0 / 0.3% / 0); (d) the "steps" are price moves per liquidator opportunity; a real chain lets a liquidator act several times per block, so K stands for liquidator capacity, not blocks.

Time to clear (liquidation transactions per account, gap case, sequential): c = 50%: median 2, maximum 11 rounds; c = 25%: median 4, maximum 22; c = 90%: maximum 3. Near the boundary `CF ~ 1/LI` the number of rounds grows (a cell with CF 75%, -20% needed 30 transactions for three accounts) because `rho` sits close to the fixed point `LI`. Residual unhealthy accounts after a gap: zero when `rho >= LI`; when `rho < LI` every account ends with its collateral exhausted and its remaining debt unrecoverable (these are the bad-debt accounts, `residShort` in the data with `residColl = 0`).

### 2.5 Liquidation incentive, close factor, and the oracle maximum age

**Incentive.** Net liquidator profit after the 2.8% protocol seize share is `LI * 0.972 - 1`, measured in every cell: **206 bp at 1.05, 497.6 bp at 1.08, 692 bp at 1.10, 1178 bp at 1.15** (before gas and swap slippage). It turns negative below `LI = 1/0.972 = 1.0288`. Lowering LI raises the safe collateral factor slightly (table above: 74.8% to 77.0% at -20%) but shrinks the margin that pays for gas and slippage; raising it does the opposite, and in a gap the extra incentive is paid from collateral that would otherwise cover debt. Reading of the grid, not a recommendation: from LI 1.05 to 1.10 the safe factor for a -50% gap drops by 2.2 points (48.1% to 45.9%), to 1.15 by 4.2 points, while the liquidator margin rises from 206 bp to 692 bp and 1178 bp.

**Close factor.** It changes the number of transactions, not the loss: 3 / 9 / 18 transactions for the same three accounts at c = 90% / 50% / 25%, identical bad debt. A higher close factor needs a larger first inventory (c x debt). The controller limits it to 5% to 90%.

**Stale feed windows and maximum age** (`RISK|STALE`, `RISK|STALEOPEN`; windows applied to the real controller by warping time with a mock that is not refreshed; interest accrues at the fixture rate):

| AVAX max age / USDC max age | Quiet period D | Prices | Borrow, entrant redeem, liquidation | Repay |
| --- | --- | --- | --- | --- |
| 300 / 90,000 | 150 s | both available | all work | works |
| 300 / 90,000 | 301 s, 3,600 s | AVAX unavailable | all fail (liquidation: PRICE_ERROR, code 13) | works |
| 1,200 / 90,000 | 600 s | both | all work | works |
| 1,200 / 90,000 | 1,201 s to 89,000 s | AVAX unavailable | all fail | works |
| 1,200 / 90,000 | 90,001 s | both unavailable | all fail | works |
| 3,600 / 90,000 | 1,800 s / 3,601 s, 7,200 s | available / AVAX unavailable | work / fail | works |
| 90,000 / 90,000 | 45,000 s / 90,001 s | available / both unavailable | work / fail | works |
| 1,000,000 / 90,000 | 90,001 s | AVAX available, **USDC unavailable** | all fail | works |

Findings: (1) every price-dependent action needs **both** prices (a stale USDC feed blocks AVAX-collateral accounts too and vice versa; a supplier who entered markets cannot redeem even without debt); repay always works. (2) **The maximum age is the length of the window in which new borrows are still priced at the old value.** Opening a position at 99% of borrowing power at the stale price, then refreshing to a gapped price, produces the same loss share as the gap grid: with `maxAge` = 1,200 s the borrow succeeded at 600 s and was refused at 1,201 s; with `maxAge` = 90,000 s it succeeded at 45,000 s (12.5 hours stale). Example (direction W, CF 60%, refresh to -60%): the late position loses 37.6% of its debt (USD 2,233 of USD 5,937); to -40%: 6.4%. The three pre-existing positions at 90% utilisation lose the same amount whether or not the late position was opened. A long maximum age therefore **widens the stale-price attack and exposure window** from minutes to hours; a short one narrows it but fails closed more often (liquidation, new borrows and entrants' redemptions all stop whenever the feed is older than the limit, even if prices did not move). (3) The quiet period does not by itself change who is liquidatable (the on-chain price has not moved); what it costs is **the time a real price move stays invisible**: liquidations are impossible until the feed updates, so the effective gap seen at the update is the market move over the quiet period. How large that is for these feeds (heartbeat, deviation threshold, outage history) is not tested; the maximum age must exceed the real heartbeat plus a margin, or a healthy feed will read as stale. (4) Interest during the windows was negligible at the fixture rates (62 ppm of the debt over 25 hours at low market utilisation).

### 2.6 Rate-model shape and reserve factor

Three synthetic shapes (base / multiplier / jump multiplier / kink): shape 0 = 2% / 10% / 100% / 80% (the fixture placeholder), shape 1 = 0% / 8% / 200% / 90%, shape 2 = 2% / 15% / 300% / 70%. APR (borrow) and the reserve accrual rate on borrows at a 10% reserve factor, from the real rate model contract (`RISK|IRM`) and confirmed by real `accrueInterest` on the fork (`RISK|ACCR`: interest = borrows x rate x blocks and reserves = interest x reserve factor within 2 base units):

| Market utilisation | Shape 0 borrow APR / reserve accrual | Shape 1 | Shape 2 |
| --- | --- | --- | --- |
| 50% | 8.2% / 0.82% of borrows per year | 4.4% / 0.44% | 12.7% / 1.27% |
| 80% | 12.0% / 1.19% | 7.1% / 0.71% | 47.0% / 4.7% |
| 90% | 22.0% / 2.2% | 8.0% / 0.8% | 77.0% / 7.7% |
| 95% | 27.0% / 2.7% | 18.0% / 1.8% | 92.0% / 9.2% |
| 99% | 31.0% / 3.1% | 26.0% / 2.6% | 104.0% / 10.4% |

The rate model affects solvency through two things only: the speed at which debt (and `rho`) drifts for an unmonitored borrower (at 31% APR about 0.085% per day: small against any gap) and the size of reserve accrual (section 5.2). Its main protective job is the incentive for repayment and new supply near full utilisation, which interacts with the cash floor (section 2.7). A steep jump multiplier at high utilisation raises reserve accrual quickly but also raises borrower cost into the stress when exits are already difficult. The reserve factor scales reserve accrual linearly (5% / 10% / 20% give 0.41 / 0.82 / 1.64% of borrows per year at 50% utilisation, shape 0).

### 2.7 Caps, market utilisation, and exit liquidity

Bad debt is linear in borrowed amount (section 2.1), so the cap that bounds the loss is `cap = tolerated_loss / (1 - rho/LI)` at the chosen factor and the worst gap considered. At a factor and gap with `rho >= LI` the loss is zero at any cap, and the cap then only bounds liquidator inventory and exit liquidity.

Exit liquidity (`RISK|EXIT`, 40 cells; market utilisation pushed by a borrower with large collateral in the other market, then the worst clean shock, W -50% / U +100%, with the liquidator redeeming its seized claim and the supplier trying to exit; synthetic floors as a percentage of the market's supply):

- At 50% / 80% / 95% / 100% market utilisation with no floor, the liquidator can redeem 100% / 91% (W) or 100% (U) / 23% (W) or 74% (U) / 0% of its seized claim, and the LP can withdraw 65% / 26% / 6% / 0% (W) or 54% / 21% / 5% / 0% (U) of its claim. If the LP withdraws first (a run), the liquidator can redeem 0% in every cell where utilisation was at 50% or more.
- A cash floor of 5% / 10% / 20% of the market's supply caps market utilisation at 95% / 90% / 80% (rows with the floor hit: realised utilisation 9,500 / 9,000 / 8,000 bp) and leaves at least that much cash. With a 20% floor the liquidator could redeem 91% (W) / 100% (U) of its claim, with 10% 45% / 100%, with 5% 23% / 74% (the claim here was about 22% of the market in W and 7% in U; the floor never guaranteed a full redemption). **The floor guards new borrows only: any supplier can still withdraw below the floor** (rows "carolAfterLpRun" = 0), so it does not guarantee the liquidator can redeem, nor that suppliers can exit.
- Rule of thumb: the cash floor must be at least the largest collateral claim a liquidation event can create in that market (seizable collateral under the worst stress, `sum over affected accounts of debt x LI x price ratio`, as a share of the market's supply) plus the share the operator wants to keep exitable.

### 2.8 Candidate shape of a decision (not a recommendation)

The study turns the decision into four inputs: (1) the **gap** to survive, per asset (a price-move distribution is needed; section 7); (2) the **leverage** to assume (`u`; the protocol cannot cap it below 100% of `CF`, only choose `CF`); (3) the incentive; (4) the liquidator capacity and exit cash. With LI in 1.05 to 1.10 and u = 99%, `CF*` for a stated gap is the table in section 2.2. The only collateral-factor choices that survive a -50% / +100% gap at maximum borrow are those at or below the table's 44% to 48%; a placeholder-sized factor accepts the loss percentages listed.

## 3. Area 2: liquidator inventory and replenishment (specification)

### 3.1 Inventory

Inventory is needed in the **debt asset**, not in the collateral, because `liquidateBorrow` pulls the debt asset from the liquidator and pays out pTokens.

- **AVAX falls (direction W)**: USDC inventory. **AVAX rises or USDC depegs (direction U)**: WAVAX inventory. A single move of the AVAX/USDC ratio hurts only one direction (up hurts U, down hurts W), so one inventory per debt asset is needed, each sized for its own event rather than for their sum; a depeg combined with an AVAX move can change which direction is hit, which is why both inventories must exist.
- Measured (c = 50%, LI = 1.08, 99% utilisation, all tested factors and shocks): total repaid in a cleared gap is **0.31x to 1.00x of the initial debt of the affected accounts** (maximum over the grid: 0.9998x); typical safe-region values are 0.50x (only first rounds needed) to 0.94x; with bad debt the liquidator repays only what the collateral can pay (`collateral / LI`). Worst cell: 1.00x, 30 transactions for three accounts.
- First-round requirement: `c x debt` of every account in shortfall (0.5x at c = 50%).
- Sizing rule: `inventory_asset >= theta x min(borrows_asset, cap_asset)` with `theta` = 0.5 for a first-round-only target, 1.0 for full clearance. At the placeholder caps (500,000 USDC, 20,000 WAVAX) that is up to 500,000 USDC and 20,000 WAVAX, the size of the whole cap. A smaller inventory reduces the share that can be cleared before the next move; it does not remove the need.
- A liquidator that recycles proceeds (redeem pTokens, swap, refill) needs cash in the collateral market and a swap venue; neither is part of this fixture, and recycling takes at least two transactions plus swap latency, so it cannot be assumed to refill the inventory inside a gap.

### 3.2 Replenishment path and what happens when cash is exhausted

1. The liquidator receives **pTokens** (97.2% of the seized amount; 2.8% goes to the collateral market's reserves), a **claim**, not cash.
2. To get cash it calls `redeem` / `redeemUnderlying`, which needs cash in the collateral market (measured gas 62k to 108k).
3. It then swaps the collateral for the debt asset on a venue (not tested here) and refills the inventory.
4. If the collateral market's cash is exhausted, the claim cannot be redeemed (existing cash-exhaustion test; `RISK|EXIT` rows: 0% at 100% utilisation, 23% / 74% at 95%). The liquidator holds the pTokens (they keep earning supply interest and are counted in its balance) and waits for repayments or new supply; liquidation itself never needs market cash, so the liquidator is **not blocked from liquidating**, only from recycling. Its inventory is therefore locked, and the next event is served only by whatever debt-asset balance remains. This is why the inventory rule above assumes **no recycling inside an event**, and why the cash floor (section 2.7) is sized against the claim a liquidation creates.

### 3.3 Operators, trigger and priority

- At least **two independent liquidator operators** (different keys, hosts and RPC providers, separately funded), plus the permissionless third line of public liquidators who profit by the incentive. One operator is a single point of failure for a credit launch.
- **Trigger**: on every new Chainlink round of either feed (`AnswerUpdated`/new round) and on a timer shorter than the feed heartbeat, evaluate `getAccountLiquidity(account)` for all indexed borrowers (borrowers from `Borrow` events; this needs an indexer). Do not wait for a pending transaction pool signal.
- **Priority**: ascending `rho` (collateral value / debt value): accounts closest to or below `LI` first, because those are the ones that become bad debt if unattended; ties by size. For each account repay `min(c x debt, collateral / LI)` (the study's "fit" step), repeat until healthy or exhausted. Check the liquidation incentive against current gas before each transaction.
- **Gas and profit viability**: measured `liquidateBorrow` is 237k to 248k gas with mocked feeds in warm state, **258k with real feeds (warm) and about 420k cold** (`RISK|GAS`; the first liquidation of a transaction touches many cold accounts), plus 62k to 66k warm / 99k to 108k cold for `redeem`; add 21k intrinsic gas. Total about 0.55M gas per liquidation + redemption, swap not included. The profit is `repaid x (LI x 0.972 - 1)` = 4.976% at 1.08. Break-even repay = `gas_cost_usd / (0.04976 - slippage)`. Illustrative only (gas price and AVAX price are **inputs, not measured**): at an assumed 25 gwei and AVAX near USD 8.5 the gas is about USD 0.12; at 200 gwei about USD 0.93; at 1,000 gwei about USD 4.7. With 100 bp of swap slippage the break-even repay is about USD 3 / 24 / 118. Positions whose liquidation size is below the break-even stay unliquidated and become bad debt; **there is no minimum borrow size in the protocol**.
- **Liquidator empty or offline**: accounts stay in shortfall, the price keeps moving, and the loss grows with the gap that accumulates; third-party liquidators step in only if the incentive pays them and they hold the debt asset. Nothing in the contracts liquidates automatically. The guardian can pause new borrows (stops new exposure) but this changes nothing for existing positions.

## 4. Area 3: monitoring (specification, no code)

Thresholds are formulas of the chosen parameters (written `CF_W`, `CF_U`, `LI`, `c`, `maxAge_A`, `maxAge_U`, `cap_m`, `floor_m`, `RF_m`, `u_max` = assumed borrower utilisation, `H_A` = AVAX feed heartbeat). The test `testRisk_Monitoring_EachFailureFlipsItsMetric` evaluates the on-chain parts of this list against induced failures and asserts each flips (`RISK|MON`).

| # | Metric | Source (on-chain call) | Threshold (formula) | Severity | Guards (failure found) |
| --- | --- | --- | --- | --- | --- |
| 1 | AVAX feed age | `AggregatorV3Interface(AVAX_FEED).latestRoundData().updatedAt`; limit from `inner.feeds(WAVAX).maxAge` | warn at `age > 0.5 x maxAge_A`; high at `0.8 x`; critical at `> maxAge_A` | warn / high / critical | Liquidation, borrows and entrants' redemptions all fail closed (section 2.5) |
| 2 | USDC feed age | same with `USDC_FEED`, `inner.feeds(USDC)` | same with `maxAge_U` | same | Same; a stale USDC feed blocks AVAX accounts too |
| 3 | Oracle zero sentinel | `oracle.getUnderlyingPrice(pToken) == 0` for both markets | any zero | critical | Zero/negative/future/reverting round with a **fresh** age (metric 1 stays green: tested) |
| 4 | Accounts with a price error | `getAccountLiquidity(account)` first return value != 0 | count > 0 | critical | The controller refuses all price-dependent actions for those accounts |
| 5 | Feed configuration drift | `inner.feeds(asset)` (feed, maxAge, enabled), `inner.marketAsset(pToken)`, owner events | any change vs the approved set | critical | Owner repointing a feed or widening `maxAge` (trust assumption in the readiness report) |
| 6 | Market utilisation | `totalBorrows / (getCash + totalBorrows - totalReserves)` | warn at `>= u_cap - 0.05`, high at `>= u_cap`, where `u_cap = 1 - floor_m / supply_m` | warn / high | Exit and redemption stress (section 2.7) |
| 7 | Borrow cap usage | `totalBorrows / controller.borrowCaps(pToken)` | warn at 0.8, high at 0.95 | warn / high | Cap reached: loss bound and inventory bound (section 2.1, 3.1) |
| 8 | Cash vs borrow cash floor | `getCash() - controller.borrowCashFloor(pToken)` | high at `<= claim_liq_max` (largest liquidator claim of section 2.7), critical at `< 0` | high / critical | New borrows drained cash; the liquidator cannot redeem |
| 9 | Supplier exit coverage | `getCash / (totalSupply x exchangeRateStored)` | warn at `< 0.2`, high at `< 0.1` | warn / high | Bank-run shape (section 5.1) |
| 10 | Accounts in shortfall (count, size) | indexer + `getAccountLiquidity(account)` third return | count > 0 for longer than `2 x block interval x rounds` (rounds from section 2.4) | high; critical at `> 10 x` that time | Liquidation not keeping up (gradual-path bad debt) |
| 11 | Stress exposure | per tracked account `rho = collateral value / debt value` from oracle prices | for each stress gap `x` in the approved set: `sum of debt where rho x s_x < LI`; warn at `> 0` | warn | Gap bad debt before it happens: accounts with `s/(CF x u) < LI` for the set's gaps |
| 12 | Liquidator inventory | `balanceOf(liquidator)` of USDC and WAVAX; `allowance(liquidator, pToken)` | `balance >= need` and `allowance >= need`, `need = c x sum(debt of accounts in shortfall under the stress gap)` or `theta x borrows` | high | Empty / unapproved liquidator (section 3.1) |
| 13 | Liquidator gas balance | native balance of each operator | `>= n x 0.55M gas x gas price x 1.5` | high | Offline operator |
| 14 | Liquidator liveness | last successful `liquidateBorrow` and heartbeat of the bot; pending nonce | silence longer than `H_A` while a shortfall exists | critical | Operator offline or stuck (section 3.3) |
| 15 | Liquidator claim backlog | `balanceOf(liquidator)` pTokens x `exchangeRateStored` vs `getCash` of the collateral market | `claim > cash` | warn | Claim not redeemable (section 3.2) |
| 16 | Bad debt accrual | per tracked account `max(0, debt value - collateral value)` summed with oracle prices | `> 0` | critical | Borrows above collateral (exhausted accounts) |
| 17 | Reserve growth | `totalReserves(pToken)` delta per day | below `RF_m x interest accrued per day` x 0.9 or reserve drop not explained by an admin action | warn | Wrong reserve factor, unexplained reduction |
| 18 | Price deviation, Chainlink vs a reference (e.g. the Pharaoh pool) | off-chain: pool slot0 or router quote vs `latestRoundData` | `|dev| >= 0.5 x min over assets of f_max` where `f_max = 1 - CF x u_max x LI` (W) | warn; **diagnostic only, never an on-chain input** | A feed lagging the market (section 2.5 finding 3) |
| 19 | Parameter drift and pause state | `collateralFactor`, `closeFactorMantissa`, `liquidationIncentiveMantissa`, `reserveFactorMantissa`, `interestRateModel`, `borrowGuardianPaused`, `pauseGuardian`, controller `admin` | any difference vs approved values | critical | Unplanned governance change |
| 20 | Chain and RPC liveness | `block.timestamp` lag, RPC error rate | lag `> 4 x` mean block time | high | Monitoring blind; feed age metrics unreliable |

### 4.1 Runbook (actions and their limits)

| Action | Who | What it does | What it cannot do |
| --- | --- | --- | --- |
| **Pause borrowing** (`_setBorrowPaused(pToken, true)`, pause guardian) | guardian | Stops new borrows (including at a stale price within `maxAge`, metrics 1, 2, 11) | Does not stop interest, liquidation, redemptions or existing positions; does not cure bad debt; does not fix the oracle |
| **Raise the cash floor** (`_setBorrowCashFloor`, admin / timelock; whether a guardian may raise it is open) | admin | Limits further cash removal by borrows | Does not stop suppliers withdrawing below the floor, does not return cash, is not a reserve, does not fund liquidators; the timelock delay makes it slow |
| **Raise liquidator inventory** | liquidator operator | Lets the operator clear more of an event | Does not make seized claims redeemable, does not fix a price gap larger than the factor's limit, does not help if the operator is offline |
| **Top up reserves of the loss market** (`_addReserves`) | treasury | Reduces exit shortfall one for one (section 5) | Cannot be done in the other asset; does not stop interest on zombie debt |
| **Repay on behalf of an exhausted account** (`repayBorrowBehalf`) | treasury | Removes the unrecoverable borrow and restores cash (tested: exit shortfall -> 0) | Costs the treasury the loss; does not recover collateral (none left) |
| Lower a collateral factor | admin / timelock | Reduces new borrowing | **Makes existing accounts instantly liquidatable** (used in the gas test); never use it as a defensive action under stress |
| Raise the liquidation incentive | admin / timelock | Draws more liquidators | Raises loss in a gap and on slow paths (section 2.4 c) |

## 5. Area 4: bad-debt handling

### 5.1 Who bears the loss in a plain market (measured)

`testRisk_ReserveFirst_ExitIdentity` (W, CF 60%, 99%, AVAX -50%; loss USD 3,925 on a 400,000 USDC market):

- The unpaid borrow **stays in `totalBorrows`** and keeps counting as an asset: the exchange rate is unchanged (2.00e14 before and after) and supplier claims are unchanged (400,000 USDC). There is **no write-off function** in `PToken`, `PErc20` or the controller (searched), so the loss is not shared pro rata by the exchange rate.
- The loss is realised as a **shortfall at exit**: cash is 396,075 USDC against claims of 400,000, so the last 3,925 USDC of claims cannot be redeemed. Who loses is decided by order of withdrawal.
- With `R` of reserves held in the market (reserves are cash that suppliers do not own): **shortfall = max(0, loss - R)**, verified with R = 0, loss/2, 1.01 x loss and 2 x loss (full exit possible exactly when R >= loss).
- A treasury repaying the exhausted accounts on behalf (USD 3,925) restores cash = claims and a full exit (tested).
- The loss lands on the suppliers of the **debt asset** (USDC for W, WAVAX for U), not on collateral suppliers.

### 5.2 Reserves from interest versus measured bad debt

Reserve accrual per year at a 10% reserve factor and 80% / 95% market utilisation: shape 0: 1.19% / 2.69% of borrows; shape 1: 0.71% / 1.79%; shape 2: 4.69% / 9.19% (section 2.6). Against that, one gap at the placeholder factors destroys 6% to 58% of the affected debt in one step (section 2.2). Examples: a market at 320,000 USDC borrowed (80% utilisation, shape 0, RF 10%) accrues about USD 3,800 of reserves per year; the -50% gap at 99% leverage at CF 60% costs 22.1% of the affected debt, USD 70,700 if the whole 320,000 were affected: about 19 years of reserves. At the safe-region factors the gap loss is zero (section 2.2) and reserves are not what protects solvency. **Reserve-factor interest is a slow top-up, not a sized backstop for gap losses.** Raising the reserve factor to 20% doubles accrual (1.6% to 5.4% of borrows per year at 50% to 95% utilisation, shape 0) and moves that share of borrower interest from suppliers to reserves (`RISK|IRM` has the supply APR per reserve factor).

Liquidations also feed reserves: 2.8% of every seize goes to the **collateral** market's `totalReserves` (measured: exactly `0.028 x LI` of the repaid value in every cell: 2.94% at LI 1.05, 3.02% at 1.08, 3.08% at 1.10, 3.22% at 1.15). It lands in the collateral asset (WAVAX for a USDC-debt loss), so it cannot be applied to the loss market without an admin `_reduceReserves`, a swap and an `_addReserves` in the other market.

### 5.3 Options

| Option | Mechanism (exists today?) | Sizing evidence | Limits |
| --- | --- | --- | --- |
| **Suppliers bear it (plain)** | Nothing to do; exit shortfall for the last suppliers (5.1) | loss = `borrowed x (1 - rho/LI)` (zero in the safe region) | Not pro rata; zombie borrows keep accruing interest and inflate the exchange rate |
| **Reserve-first** | Leave `totalReserves` in the market (do not call `_reduceReserves`); suppliers are protected up to R (identity tested, 5.1) | accrual in 5.2; liquidation share ~3% of repay | Needs time to accrue; reserves are in one asset per market |
| **Treasury backstop / insurance reserve for lending** | `_addReserves` (any holder) or `repayBorrowBehalf` on exhausted accounts (both tested) | target = tolerated loss over the stress set, `cap x (1 - rho/LI)` per market per asset, table in 2.2 | A funding and governance decision. **Distinct from the margin insurance fund, which belongs to margin trading** and must not be shared |
| **Reserve-first socialisation (write-off)** | **Does not exist.** A write-off that reduces `totalBorrows` and `totalReserves` and lets the exchange rate fall would need a code change | Would turn the exit race into a pro rata loss | New code, new review; not proposed or tested here |

### 5.4 Three different things that must not be confused

| | **Borrow cash floor** (`borrowCashFloor`) | **Reserves** (`totalReserves`) | **Liquidator inventory** |
| --- | --- | --- | --- |
| Purpose | Limit how much cash new borrows may remove, so exits stay possible | Accounting claim owned by the protocol (admin-withdrawable); first-loss cushion if left in the market | Debt-asset balance an operator holds to execute `liquidateBorrow` |
| Where held | Nowhere: a number in the controller's namespaced storage; the cash stays in the market | In the market as ordinary cash, tracked by `totalReserves` | In operator wallets (EOA / contract), outside the protocol |
| Who funds it | No one: it is a limit, not an asset | Reserve-factor interest, 2.8% of seizes, `_addReserves` by anyone | The operators (or whoever funds them) |
| What it protects | Suppliers' ability to exit and the liquidator's ability to redeem, against borrows draining cash | Suppliers from a loss, one for one (5.1) | The protocol from not being able to liquidate (bad debt growth) |
| What it cannot protect against | Withdrawals by suppliers (allowed below it); an oracle failure; any loss; a liquidator without funds | Larger losses than R; liquidation not happening; cash taken by withdrawals if it was moved out | Gaps beyond the collateral factor's limit; unredeemable claims; an offline operator |

The controller's own text states the first row: the floor "is NOT an accounting reserve (`totalReserves`) and NOT liquidator funding; it is only a limit on how much cash new borrows may remove from the market" (`PeridottrollerAvalanche.sol`).

## 6. Operator decisions that remain

1. Collateral factor per market, and the gap and leverage assumptions behind it (section 2.2).
2. Liquidation incentive and close factor (section 2.5); minimum profitable position (no on-chain minimum exists).
3. Borrow caps per market (loss bound and inventory bound) and the cash floor per market (section 2.7); who may raise the floor.
4. Reserve factor and rate-model shape per market, including the blocks-per-year constant (section 2.6).
5. Maximum feed age per feed against the real heartbeat (section 2.5).
6. Liquidator operators, funding, keys, inventory sizing `theta`, and the monitoring owner and pager (sections 3, 4).
7. Bad-debt policy: plain, reserve-first, treasury backstop and its funding source, or a write-off code change (section 5.3).
8. The remaining gates in `avalanche-cash-only-lending-readiness.md` (mainnet deployment path, PERIDOT token, governance acceptance) are untouched by this study.

**No production value is chosen anywhere in this document, nothing is approved, and borrowing stays paused.** The grid values are measurements, not candidates.

## 7. Not tested, and what would change the numbers

- **Real Chainlink behaviour**: deviation threshold, heartbeat, round gaps, outage history, decimals, min/max answer clamps. The quiet-period gap size follows from this and is the single most important input to the factor.
- **A price-move distribution** for AVAX/USDC over the quiet period and over one block of liquidation latency (needed to choose the gap to survive); no historical data was read.
- **Liquidation competition, gas price, mempool conditions, MEV**, congestion during a crash; the harness liquidator is unlimited and instant.
- **Swap and redemption latency and slippage** for recycling inventory (no swap in this fixture); real market depth for liquidating seized collateral.
- **Mixed accounts** (collateral in both markets, debt in both), many small accounts below the break-even size, correlated accounts across the whole cap.
- **Interest drift during a gap** and rate-model behaviour at the extremes; the real block time (fixture assumes 1 block per second).
- **A real liquidator contract** (none exists in the repository for lending), real keys and bot behaviour; the monitoring is a specification and the monitor logic was exercised inside a test, not as a service.
- **Protocol-level changes** (write-off, minimum borrow size, per-market liquidation incentive) are not tested because they do not exist.

## 8. Reproduction and evidence

```
cd contracts
AVALANCHE_MAINNET_RPC_URL=<archive RPC> FOUNDRY_PROFILE=debt_accounting FOUNDRY_OUT=out_risk FOUNDRY_CACHE_PATH=cache_risk \
  forge test --threads 1 --gas-limit 9000000000000000000 --match-contract '^AvalancheCashOnlyRiskStudyForkTest$' -vv \
  --rpc-url <same> --compute-units-per-second 20 --fork-retries 10 --fork-retry-backoff 1000
python3 ../docs/deployment-handoffs/avalanche-cash-only-risk-evidence/analysis/safe-region.py <log>
```

Evidence log index: see `avalanche-cash-only-risk-evidence/README.md`. Every attempt is kept with its header (UTC time, git HEAD, command). Evidence of record: `attempt12-final-full.txt`, 18 passed, 0 failed, test file sha256 `120b80911624627999eafd48d1ed931e53db6326eaae0dcf805d501e026bf30b` (the test file is untracked, so the git HEAD in the headers does not pin it). Failures along the way: attempt 4 (a harness check that did not model the healthy band when CF x LI > 1, fixed in the test) and attempts 6, 8, 9, 10, 11 (public-RPC rate limits, HTTP 429, before or during the run; no assertion failed).

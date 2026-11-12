# Cash-only lending pilot: treasury repayment (`repayBorrowBehalf`) procedure, tested at pilot scale

Status: **PROCEDURE SPECIFICATION backed by fork tests. NO treasury funds are committed. Nothing in this document is an approved parameter, cap, role assignment or deployment.** The operator accepted the treasury `repayBorrowBehalf` only as the *preferred loss-handling mechanism to qualify for* the one-direction pilot; this document specifies the procedure and measures what it can and cannot do. The USD 1,000 / 5,000 / 10,000 borrow caps are **illustrative research sizes, not approved caps**. The audited reserve-first write-off ("S3" in `avalanche-cash-only-loss-handling.md`) is a **separate scaling proposal**: it is neither built, extended nor re-tested here. Nothing under `contracts/contracts/` was changed; nothing was committed, signed, broadcast or deployed; no keys were used; borrowing stays paused in the repository's deployment state. Pilot candidates: `PW30` (WAVAX collateral factor 30%) and `PW40` (40%), USDC collateral factor 0, WAVAX borrowing paused, 20% cash floor on pUSDC, close factor 50%, liquidation incentive 1.08 (PROVISIONAL), from `avalanche-cash-only-decision-table.md`.

> **Update 2026-11-06:** the operator replaced the manual Safe-signed repayment by an automatic **treasury keeper** (a hot wallet that holds the protection USDC and runs `repayBorrowBehalf` itself when this rule returns `DEFAULT_EXHAUSTED`; the Safe is the cold reserve that funds it). The rule of section 2 is unchanged and the keeper adds only restrictions; see `avalanche-cash-only-treasury-keeper.md`. Sections 3 (roles) and 5.3 (alerts) were rewritten to the keeper design on the same date; sections 4 (funding) and 6 (insufficient funding) still speak of "the treasury" and "signers" where the keeper and the Safe-funded top-up are meant.

## 0. Summary

1. **Detection rule** (section 2): the treasury repays an account's debt only when **all** of: prices fresh and an independent reference price present; `debt > 0`; controller `shortfall > 0`; `collateral value / LI < debt value` (a full liquidation cannot clear it); and `collateral value <= USD 0.01` (liquidation is exhausted: what is left to seize repays at most USD 0.0093). Amount = the account's whole remaining debt, paid with the full-repay sentinel `type(uint256).max`. Tested truth table: healthy, recoverable, tail-before-liquidation, stale/zero price, no debt: **silent**; exhausted collateral: **fires**.
2. **Funding** (section 4): the treasury must hold `L = D - C_after / LI` in USDC, measured per USD 100,000 of cap (borrowers at 100% of power, 30 days of 12.2% APR interest, no liquidation in between): **PW40 8,394 / 25,986 / 43,116** at -60% / -67.6% / -75%; **PW30 23,826 / 39,258** at -75% / -80%. These are **higher than the decision table's** 6,472 / 24,178 / 41,545 / 22,060 because that table assumes 99% of power and no interest (section 4.2).
3. **Response time** (section 5): the interest cost of waiting is small (PW40 -75%: 0.017% of L per day, 0.52% after 30 days, at a post-event borrow APR of 6.3%). The real cost of waiting is the first-come-first-served exit window, which does **not** shrink or grow with the delay: while any part of L is unpaid, the last suppliers in the withdrawal queue bear it. Proposed target (not derived from a threshold, section 5.3): repay within 1 hour of the first `DEFAULT_EXHAUSTED` reading, escalate at 4 hours.
4. **Insufficient funding** (section 6): every USDC repaid removes exactly one USDC of exit shortfall (asserted); shortfall = `max(0, unpaid debt - reserves)`; the **first supplier in the queue is never short in this population** and the **last ones absorb everything**. **Worst case (PW40, -75%, nothing funded): 34.4% of supplier deposits are unrecoverable at exit and a supplier recovers 0% of its claim in the worst order; at 50% funding the worst supplier still recovers 0%; at 25% 0%.** At the -60% tail the worst supplier recovers 34.1% unfunded, 50.8% at 25% funding, 67.5% at 50%. PW30: worst 0% at -75% unfunded (19.0% of supply lost), 6.15% at 50% funding; -80%: 31.3% of supply, 0% at 50%. The shortfall is a *deferred* claim: a later repayment makes late suppliers whole (tested).
5. **Mitigations** that exist (guardian pause of borrowing and of minting, raising the cash floor, partial repayments first) are tested; **none changes the exit shortfall**, none can pause redemptions (no such switch exists), none creates cash.
6. **Mutations** (section 9): two mutations of the new test file's logic (detector fires on shortfall alone; repayment applied to the wrong account) are caught (3 and 10 tests fail respectively).

## 1. What was run

Fork suite `contracts/test/AvalancheCashOnlyTreasuryRepayFork.t.sol` (`AvalancheCashOnlyTreasuryRepayForkTest`, **16 tests, all pass**: `avalanche-cash-only-treasury-evidence/attempt11-16tests-baseline-warm.txt` is the 16-test run on warm caches (the 14 original tests are in `attempt10-final-full.txt`; the 2 added tests are the reference-tolerance boundary and the wrong-reference property); cold single run of the 14: see `avalanche-cold-repro/`, the 16 are not re-run cold), on the margin-free cash-only fixture `AvalancheCashOnlyBase` (pinned Avalanche C-Chain block 99,200,000, real tokens and Chainlink feeds with the feeds mocked to move or age prices, plain `PErc20Delegate` markets behind `PErc20Delegator`, shares borrow accounting). The file also contains a TEST-ONLY reference implementation of the detector (`TreasuryDefaultDetector`); nothing in `contracts/contracts/` references it.

**Fixture construction (how the suppliers of interest dominate the market).**
- The fixture's liquidity provider holds USDC 400,000 of pUSDC. `setUp` **redeems all of it** so pUSDC supply is zero; the four research suppliers are then the only holders (asserted: their pToken balances sum to `totalSupply`). The LP's 12,000 WAVAX in pWAVAX stay (pWAVAX has no borrowers, so the liquidator's seized claim is redeemable: shown by `AvalancheCashOnlyPilotConfigFork.t.sol`, **not re-asserted in this suite**, which never redeems the liquidator's claim; the pool does not enter the loss accounting).
- Suppliers, of total `S = cap / 0.8` (so the 20% cash floor applies: floor = `S / 5 = cap / 4`): **A 50%, B 25%, C 15%, D 10%** of `S` (unequal on purpose so the 24 withdrawal orders differ). Cap 1,000 -> S 1,250; 5,000 -> 6,250; 10,000 -> 12,500 (USDC).
- Pilot configuration set in the test: WAVAX CF 30% or 40%, USDC CF 0, pUSDC borrowing on, WAVAX borrowing paused, close factor 50%, incentive 1.08, reserve factor 10%, rate model of the fixture (2% base; 12.00% APR at the 80% utilisation the full caps produce). The controller borrow cap is set to `cap + 1 unit` because its check is strict (`nextTotalBorrows < cap`); total borrows reach exactly `cap`.
- **Three borrowers at 100% of borrowing power**: each deposits WAVAX sized to a borrowing power of `cap / 3` and borrows the largest amount the controller accepts (decrementing one unit at a time). Achieved power: **99.9999%** (min of the three, in every run). A borrower at 100% of power is underwater from the first second of interest.
- **30 days of interest** (1 block = 1 second in the fixture's rate model; borrow APR 12.00% at the start, 12.22% after) with **no liquidation in between** (conservative: a liquidator acting on the interest-only shortfall would shrink the loss; this keeps the position the worst case). Debt grows **0.986%** in 30 days; reserves accrue 10% of the interest.
- **One adverse price gap** in a single step, then a funded liquidator (CAROL) liquidates every borrower at the 50% close factor until the collateral is below USD 0.01. PW40 tails: **-60%, -67.6%, -75%**; PW30 tails: **-75%, -80%** (all beyond the candidate's zero-loss gap: PW40 about -56% at this utilisation, PW30 about -67%). The unrecoverable debt left on the three accounts is **L0**.
- **Funding levels** are fractions of **L0** (what the closed form sizes): 100%, 50%, 25%, 0%; for delays above 0 a fifth level, **100% of L(delay)** (the debt at repayment time). The interest that accrues while nobody pays (delay 0, 1, 7, 30 days) is reported separately as *phantom interest* = `L(delay) - L0`.
- For every (cap, candidate, tail, delay, funding) state, **all 24 permutations** of the four suppliers' exit order are executed (each from the same snapshot): a supplier whose claim is covered by the cash left redeems everything, otherwise `redeemUnderlying(cash)`. 6,912 permutation runs (285 grid states x 24 orders, plus 72 in the mitigation test) are in the evidence log (`TRP|ORD|` lines). Everything is proportional to the cap (asserted to 0.01 pp across the three caps), so percentages are the same for every cap; USD columns are given per cap.

Pre-gap fixture (identical for every candidate): 

| cap | cand | supplies (S) | borrowed | cash at borrow | floor | power used (min of 3 borrowers) | borrow APR at borrow | debt after 30 d | growth in 30 d | borrow APR after | reserves after 30 d |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 5000 | PW40 | 6,250.00 | 5,000.00 | 1,250.00 | 1,250.00 | 99.9999% | 12.00% | 5,049.32 | 0.986% | 12.22% | 4.93 |
| 1000 | PW30 | 1,250.00 | 1,000.00 | 250.00 | 250.00 | 99.9999% | 12.00% | 1,009.86 | 0.986% | 12.22% | 0.99 |
| 5000 | PW30 | 6,250.00 | 5,000.00 | 1,250.00 | 1,250.00 | 99.9999% | 12.00% | 5,049.32 | 0.986% | 12.22% | 4.93 |
| 10000 | PW30 | 12,500.00 | 10,000.00 | 2,500.00 | 2,500.00 | 99.9999% | 12.00% | 10,098.63 | 0.986% | 12.22% | 9.86 |
| 1000 | PW40 | 1,250.00 | 1,000.00 | 250.00 | 250.00 | 99.9999% | 12.00% | 1,009.86 | 0.986% | 12.22% | 0.99 |
| 10000 | PW40 | 12,500.00 | 10,000.00 | 2,500.00 | 2,500.00 | 99.9999% | 12.00% | 10,098.63 | 0.986% | 12.22% | 9.86 |

Events (PW40 and PW30). `u` is debt at the gap over the pre-gap borrowing power; the measured loss matches `D - C_after / LI` to within the liquidation dust (asserted: lower bound within 32 wei, upper bound `N x (USD 0.01 + 16 wei)`; the measured residual collateral was **0.0000 USDC to 4 decimals** in every event):

| cap | cand | AVAX gap | debt at gap D | u (debt / borrowing power at the pre-gap price) | collateral after gap C | repaid by liquidator | unrecoverable debt L0 | closed form D - C/LI | L0 / D | residual collateral (max per account) |
|---|---|---|---|---|---|---|---|---|---|---|
| 5000 | PW40 | -75.0% | 5,049.32 | 100.986% | 3,125.00 | 2,893.52 | **2,155.80** | 2,155.80 | 42.69% | 0.0000 |
| 1000 | PW30 | -75.0% | 1,009.86 | 100.986% | 833.33 | 771.60 | **238.26** | 238.26 | 23.59% | 0.0000 |
| 1000 | PW30 | -80.0% | 1,009.86 | 100.986% | 666.67 | 617.28 | **392.58** | 392.58 | 38.87% | 0.0000 |
| 5000 | PW30 | -75.0% | 5,049.32 | 100.986% | 4,166.67 | 3,858.02 | **1,191.29** | 1,191.29 | 23.59% | 0.0000 |
| 5000 | PW30 | -80.0% | 5,049.32 | 100.986% | 3,333.33 | 3,086.42 | **1,962.90** | 1,962.90 | 38.87% | 0.0000 |
| 10000 | PW30 | -75.0% | 10,098.63 | 100.986% | 8,333.33 | 7,716.05 | **2,382.58** | 2,382.58 | 23.59% | 0.0000 |
| 10000 | PW30 | -80.0% | 10,098.63 | 100.986% | 6,666.67 | 6,172.84 | **3,925.79** | 3,925.79 | 38.87% | 0.0000 |
| 1000 | PW40 | -60.0% | 1,009.86 | 100.986% | 1,000.00 | 925.93 | **83.94** | 83.94 | 8.31% | 0.0000 |
| 1000 | PW40 | -67.6% | 1,009.86 | 100.986% | 810.00 | 750.00 | **259.86** | 259.86 | 25.73% | 0.0000 |
| 1000 | PW40 | -75.0% | 1,009.86 | 100.986% | 625.00 | 578.70 | **431.16** | 431.16 | 42.69% | 0.0000 |
| 5000 | PW40 | -60.0% | 5,049.32 | 100.986% | 5,000.00 | 4,629.63 | **419.69** | 419.69 | 8.31% | 0.0000 |
| 5000 | PW40 | -67.6% | 5,049.32 | 100.986% | 4,050.00 | 3,750.00 | **1,299.32** | 1,299.32 | 25.73% | 0.0000 |
| 10000 | PW40 | -60.0% | 10,098.63 | 100.986% | 10,000.00 | 9,259.26 | **839.37** | 839.37 | 8.31% | 0.0000 |
| 10000 | PW40 | -67.6% | 10,098.63 | 100.986% | 8,100.00 | 7,500.00 | **2,598.63** | 2,598.63 | 25.73% | 0.0000 |
| 10000 | PW40 | -75.0% | 10,098.63 | 100.986% | 6,250.00 | 5,787.04 | **4,311.59** | 4,311.59 | 42.69% | 0.0000 |

## 2. (a) Default-detection rule

### 2.1 The rule
Evaluated by the monitor with `eth_call` (it accrues interest on every listed market first, then reads only existing views), for each account `a` with pUSDC debt, at block `b`:

```
LI        = controller.liquidationIncentiveMantissa()                       (1.08e18)
P_m       = oracle.getUnderlyingPrice(pToken_m)                              (0 when the feed is stale or non-positive)
R_m       = independent reference price of the same market, supplied by the monitor (section 2.3.1: for WAVAX the Uniswap V3 0.05% 30-minute TWAP in USD, for USDC the oracle's own price)
D_units   = borrowBalanceCurrent(a) in pUSDC                                (after accrueInterest)
debtUsd   = D_units  * min(P_usdc, R_usdc) / 1e18
collUsd   = sum over EVERY listed market m of  (pTokenBalance_m * exchangeRate_m / 1e18) * max(P_m, R_m) / 1e18      (unweighted: liquidation can seize any listed collateral, whatever its collateral factor)
(err, liquidity, shortfall) = controller.getAccountLiquidity(a)

FIRE(a)  <=>  P_m != 0 and R_m != 0 for every market the account touches      (freshness precondition; else verdict STALE_OR_ZERO_PRICE or NO_REFERENCE_PRICE, never act)
         and  |P_m - R_m| * 10,000 <= R_m * TOL_BP for every market the account touches   (the two sources agree; else verdict PRICE_DIVERGENCE, never act; section 2.3.1)
         and  err == 0                                                          (error 13 = price error = unknown = do not act)
         and  D_units > 0
         and  shortfall > 0
         and  collUsd * 1e18 < debtUsd * LI                                     (even a FULL liquidation cannot clear the debt: max repay = collUsd / LI)
         and  collUsd <= DUST                                                   (liquidation exhausted; DUST = USD 0.01 = 1e16 in 1e18 USD)
AMOUNT   =  borrowBalanceCurrent(a) at the repay transaction, paid with repayBorrowBehalf(a, type(uint256).max)
         =  the debt remaining after the collateral was exhausted
```
Everything in the rule is computable on chain from existing views except `R_m`: the reference price is a monitor-side hardening input (its absence or zero fails closed to `NO_REFERENCE_PRICE`), so the rule does not become off-chain by using it. Eight verdicts: `NO_DEBT`, `STALE_OR_ZERO_PRICE`, `NO_REFERENCE_PRICE`, `HEALTHY`, `LIQUIDATABLE_RECOVERABLE`, `UNRECOVERABLE_LIQUIDATE_FIRST`, `DEFAULT_EXHAUSTED` (the only one that pays), `PRICE_DIVERGENCE` (added with the reference-price specification; numbered last so the earlier verdict numbers are unchanged). The reference implementation is `TreasuryDefaultDetector.evaluate` in the test file.

Why each term: *freshness* because the oracle returns 0 beyond 1,200 s (AVAX) / 90,000 s (USDC) and the rule must never fire on an unknown price; *shortfall* is the controller's own definition of a liquidatable account; *`C/LI < D`* separates "a liquidator can still clear this" from "it cannot"; *`C <= DUST`* is the exhaustion condition that keeps the treasury from paying before liquidators have taken what can be taken (an account with `C/LI < D` but collateral left is `UNRECOVERABLE_LIQUIDATE_FIRST`: alert liquidators, do **not** pay). Conservative valuation: collateral at the higher of oracle and reference, debt at the lower, so a manipulated price can only make the rule *less* willing to fire.

**DUST is a parameter, not a derived threshold.** USD 0.01 is the point where the test's liquidation loop stops; what remains is worth at most `0.01 / 1.08 = USD 0.0093` of repayment, and the liquidator bonus on it (8%) is far below the operating-cost estimate of about USD 0.008 of gas per liquidation (`avalanche-operating-cost-estimate.md`), so no operator will liquidate it. Measured residuals: 0.0000 USDC in all 15 events, USD 4.5e-7 in the truth-table account. Any other dust value is an operator choice.

**Exhaustion is corroborated on chain, but a dust liquidation is still possible**: a liquidation of 1 USDC on the exhausted account is refused (seize more than it holds); a liquidation of at most `DUST/LI` would still succeed, which is why exhaustion is defined by value, not by "liquidation impossible".

### 2.2 Truth table (test `testDetect_TruthTable_...`, PW40, cap 5,000, 30 days of interest, three full-power borrowers plus one half-power borrower and one debt-free account)
Stages: price unchanged -> -20% (inside the zero-loss gap) -> -75% (tail, nothing liquidated) -> account 0 liquidated to exhaustion, account 1 one liquidation round (collateral remains), account 2 untouched -> stale price -> zero answer -> after the treasury repays account 0. Amounts: debt in USDC, values in USD.

| case | verdict | debt (USDC units) | debt value (USD) | collateral value (USD) | max recovery C/LI (USD) | shortfall (USD) |
|---|---|---|---|---|---|---|
| stage1 half-power borrower | HEALTHY | 833.33 | 832.9794 | 4,164.8971 | 0.0000 | 0.0000 |
| stage1 no debt | NO_DEBT | 0.00 | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| stage1 full-power after 30d interest (shortfall from interest only) | LIQUIDATABLE_RECOVERABLE | 1,683.11 | 1,682.3902 | 4,164.8971 | 3,856.3862 | 16.4314 |
| stage2 -20% full-power | LIQUIDATABLE_RECOVERABLE | 1,683.11 | 1,682.3902 | 3,331.9177 | 3,085.1090 | 349.6231 |
| stage2 half-power still healthy at -20% | HEALTHY | 833.33 | 832.9794 | 3,331.9177 | 0.0000 | 0.0000 |
| stage3 -75% tail before liquidation (account 0) | UNRECOVERABLE_LIQUIDATE_FIRST | 1,683.11 | 1,682.3902 | 1,041.2243 | 964.0966 | 1,265.9005 |
| stage3 -75% tail before liquidation (account 1) | UNRECOVERABLE_LIQUIDATE_FIRST | 1,683.11 | 1,682.3902 | 1,041.2243 | 964.0966 | 1,265.9005 |
| stage3 -75% half-power account is liquidatable and still recoverable | LIQUIDATABLE_RECOVERABLE | 833.33 | 832.9794 | 1,041.2243 | 964.0965 | 416.4897 |
| stage4 exhausted account FIRES | DEFAULT_EXHAUSTED | 718.60 | 718.2937 | 0.0000 | 0.0000 | 718.2937 |
| stage4 partially liquidated (collateral remains) does not fire | UNRECOVERABLE_LIQUIDATE_FIRST | 841.55 | 841.1951 | 132.7336 | 122.9014 | 788.1017 |
| stage4 untouched tail account does not fire | UNRECOVERABLE_LIQUIDATE_FIRST | 1,683.11 | 1,682.3902 | 1,041.2243 | 964.0966 | 1,265.9005 |
| stage4 recoverable account does not fire | LIQUIDATABLE_RECOVERABLE | 833.33 | 832.9794 | 1,041.2243 | 964.0965 | 416.4897 |
| stale AVAX: exhausted account does NOT fire | STALE_OR_ZERO_PRICE | 718.60 | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| stale AVAX: tail account | STALE_OR_ZERO_PRICE | 1,683.11 | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| stale: an account without debt needs no price | NO_DEBT | 0.00 | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| zero AVAX answer: does NOT fire | STALE_OR_ZERO_PRICE | 718.60 | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| after repayment | NO_DEBT | 0.00 | 0.0000 | 0.0000 | 0.0000 | 0.0000 |

Reading: **the rule fires exactly once, on the exhausted account**; it is silent for the healthy account, for the liquidatable-but-recoverable accounts (including the full-power accounts that are underwater from interest alone), for the tail accounts before and during liquidation, under a stale AVAX price (1,201 s without a fresh round) and under a zero answer. After the repayment the same account reads `NO_DEBT`.

### 2.3 The oracle is the weak point (tested)
`testDetect_ManipulatedLowOracle_...`: with the AVAX price forced to 1e-8 USD, a **single-source** rule (reference := oracle) says `DEFAULT_EXHAUSTED` for a perfectly recoverable account and would pay its debt from the treasury. With an **independent reference price** (honest, supplied separately) the same account is **not** paid: the sources disagree, the verdict is `PRICE_DIVERGENCE` (before the divergence gate was added the same case read `LIQUIDATABLE_RECOVERABLE`; both are "do not pay"); with no reference supplied the rule reads `NO_REFERENCE_PRICE` and does not act. A manipulation that moves oracle and reference together is not covered; the bound then is the treasury balance (section 3.3).

#### 2.3.1 Reference-price specification (operator-selected source; monitor-side only; no change to the on-chain oracle)
**Source (selected by the operator on 2026-11-05; Pyth dropped).** Uniswap V3 WAVAX/USDC **0.05%** pool `0xfAe3f424a0a47706811521E3ee268f00cFb5c45E` (token0 WAVAX, token1 USDC), **30-minute TWAP**.
- *Pool identity:* the monitor re-derives the pool from `UniswapV3Factory(0x740b1c1de25031C31FF4fC9A62f554A55cdC1baD).getPool(WAVAX, USDC, 500)` at start-up and once a day; a mismatch fails closed.
- *Read:* `observe([1800, 0])` at **the same block** at which the rule reads the controller. Mean tick = `floor((c1 - c0) / 1800)` (rounding toward minus infinity as the library does); USDC per WAVAX = `1.0001^tick x 10^12`, computed with integer tick math, not floating point.
- *USD conversion and the USDC leg:* `R_wavax(USD) = (USDC per WAVAX) x P_usdc`, with `P_usdc` the oracle's own USDC price; **`R_usdc := P_usdc`**. The pool has no view of USDC's dollar value, so **a USDC de-peg is not covered by this reference**; it is covered only by the oracle's freshness guard (the guarded oracle has no peg guard, see the audit scope).
**Tolerance.** `TOL_BP =` **500 bp (5%)**: oracle and reference are *consistent* iff `|P - R| x 10,000 <= R x TOL_BP`. Tested to the wei in both directions (`testDetect_ReferenceTolerance_ExactBoundary_...`): at the tolerance the ordinary verdict stands, one wei beyond it the rule returns `PRICE_DIVERGENCE`. Basis: `avalanche-cash-only-risk-evidence/analysis/twap-vs-chainlink.py`, 2,013 samples at 10-minute spacing over 14 days to block 99,509,285 (`twap-vs-chainlink-14d.csv`, `.summary.txt`), TWAP and Chainlink read at the same block: median |gap| 15 bp, p90 45 bp, p99 116 bp, p99.9 190 bp, **maximum 308 bp**, mean signed gap +1 bp. The big gaps coincide with fast Chainlink moves (the 8 largest are 149 to 308 bp while Chainlink moved 222 to 452 bp in the previous 30 minutes; the TWAP lags by up to about 0.7 of such a move); with Chainlink moving less than 100 bp the maximum gap is 94 bp. 500 bp is 1.6 times the largest gap seen and 2.6 times p99.9, so it does not trip on ordinary volatility, and it trips only in 30-minute moves of roughly 7% or more, where a delay and a page are the intended response; it is far below any error that could matter for bad debt (PW30 zero-loss fall is -67.3%). **A 14-day sample from one regime, not a bound**: a faster move than any in it would trip the gate sooner, which fails closed. Re-derive from a longer sample when a private archive endpoint is available.
**What the check is for, stated precisely.** The conservative valuation (collateral at the higher price, debt at the lower) already guarantees that **a wrong reference can only make the treasury pay less, never more** (`testDetect_AWrongReferenceNeverCreatesAFire_ItOnlyDelays`: 28 account/reference pairs from 0.01% to 10x of the oracle price, on a detector with the gate disabled, none turns a non-exhausted account into a fire). The divergence gate therefore is not what stops a wrongful payment. Its job is to **detect that the two sources disagree**, because that is the signature of an oracle failure: *oracle above market* means borrowers can over-borrow and create bad debt; *oracle below market* means accounts can be liquidated that should not be. Either direction is a **page to the operator at once**, with "consider pausing borrowing (guardian)" as a human decision; nothing is automated.
**Fail closed (verdict `NO_REFERENCE_PRICE`, never act, page after N minutes), any of:** the RPC call fails or times out; `observe` reverts (for example `OLD`: the pool's history is shorter than 1,800 s); the derived price is zero; the pool address differs from the factory's; the pool's `liquidity()` at that block is below a floor set from its trailing median (the value is a monitor setting, **not derived here**); the reference and the oracle were read at different blocks.
**Timing effect, accepted knowingly.** After a fast move the TWAP lags by up to its window: the gate can hold the verdict at `PRICE_DIVERGENCE` for up to about 30 minutes after the market stops moving, so the treasury cannot pay during that time. The 1 h / 4 h / 24 h response targets are proposals and run from the first non-divergent verdict; liquidators are not gated by the reference price at all.
**Manipulation.** Moving the 30-minute TWAP by the tolerance requires holding the pool's price displaced by at least that much for the whole window. From the measured depth of this pool (1% about USD 109k, 3% about USD 323k, `avalanche-cash-only-liquidation-cycle.md`) that is on the order of one USD million of capital in the pool plus the arbitrage losses of holding it, an **estimate, not tested**. What the attacker obtains is limited by the test above: a manipulated reference can delay a payment, never cause one.
**Cost.** No subscription and no gas: two `eth_call`s per evaluation plus one daily factory check, inside the batched monitor read. Reading history for studies (not for operation) needs an archive node.
**Not covered / not tested.** A simultaneous manipulation of Chainlink and the pool; a USDC de-peg (above); the persistence hardening "the verdict must hold on two evaluations at least one fresh AVAX round apart before paying" (recommended, cheap, **not tested**); the liquidity floor value; the real RPC reliability of the chosen provider.

### 2.4 The runbook only pays accounts on which the rule fires (test `testRunbook_RepaysOnlyAccountsOnWhichTheRuleFires`)
With the -75% gap applied but nothing liquidated, a treasury holding USD 10,000 pays **nothing** and keeps the funds; after one account is exhausted it pays exactly that account's debt (within 2 wei) and no other; unused budget stays with the treasury.

### 2.5 Repayment mechanics
- Use the **full-repay sentinel** for full repayments. Tested (`testRepayBehalf_FrontRun_...`): if anyone (the borrower, a griefer) repays even 1 unit between detection and the treasury transaction, an *explicit* amount equal to the detected debt **reverts** (amount above the debt); the sentinel clears whatever remains. The earlier loss-handling suite never exercised the sentinel call shape; here it is used in every repayment of the grid and pulls exactly the debt (within 2 wei).
- For a **partial** repayment (insufficient budget) the runbook repays accounts largest debt first, whole accounts first, the remainder as an explicit amount on the last account (FND lines: e.g. 50% funding at 30 days: 1 account in full, 1 partial). The outcome for suppliers depends only on the total repaid, not on which account receives it (total borrows is what enters the exchange rate); repaying whole accounts first leaves fewer open defaulted accounts.
- Allowance: the treasury approves pUSDC for the exact budget of the action and nothing else (section 3).

## 3. (b) Authorized operator, roles and what a malicious or mistaken repayment can do

`repayBorrowBehalf` is **permissionless** in the contract: anyone can call it and it pulls the USDC from **the caller**. Authorization is therefore not a contract permission; it is **who holds the treasury USDC and which key can move it**. **Design (operator decision of 2026-11-06): the repayment is AUTOMATIC.** A dedicated hot wallet, the **treasury keeper**, holds the protection USDC and executes `repayBorrowBehalf` itself when the rule of section 2 returns `DEFAULT_EXHAUSTED`. The Avalanche Safe is only the **cold reserve that funds the keeper**; it is not an execution path for repayments. Specification, tests and limits of the keeper: `avalanche-cash-only-treasury-keeper.md` (code `operator/src/keeper.ts`).

### 3.1 Roles
| Role | Holds | Can do | Cannot do |
| --- | --- | --- | --- |
| **Monitor** (read-only process, any host) | no funds, no signing key (read-only RPC; alert channel) | evaluate the rule every cycle, raise alerts, tripwire on unexplained outflow of the keeper wallet | move funds, sign, call any market function |
| **Treasury keeper** (hot wallet, Foundry keystore on its own dedicated host; password in that host's encrypted environment) | the protection USDC (sized to the -75% tail, USD 1,191 for PW30 at the USD 5,000 cap) and gas AVAX | `approve(pUSDC, debt + 10 bp)` and `repayBorrowBehalf(account, max)` for an account whose verdict is `DEFAULT_EXHAUSTED`, after confirmation (2 evaluations, 60 s), re-verification at execution, within the daily spend cap (USD 1,500) and the fee cap; halts on anything unexpected | pause, set parameters, reduce reserves, change oracle/floor, pay a partial amount, pay any account the rule does not name (tested: it sends no transaction on any other verdict, under a stale, zero or divergent price, or without a reference price) |
| **Avalanche Safe** (cold reserve; the Ledger is its only owner today) | the reserve USDC | top the keeper up (a manual transaction, helper not built) | repay debts (not an execution path) |
| **Liquidator operators** (two independent hot keeper wallets, each on its own host, each with its own USDC inventory and gas; no admin rights) | their own USDC inventory (not the treasury) | `liquidateBorrow` (permissionless), redeem, swap WAVAX to USDC (`avalanche-cash-only-operator-executor.md`) | touch the treasury; the treasury never liquidates |
| **Market admin / timelock and pause guardian** | no treasury funds | parameters; guardian may pause borrowing and minting | repay for anyone using treasury funds |

Key separation: three different hot wallets on three different hosts (operator 1, operator 2, treasury keeper); none is the market admin or the pause guardian; the guardian key is separate from the admin timelock (existing design). The keeper wallet **holds only USDC (plus gas AVAX)** and **no admin power on the markets**. What a compromised keeper host can do (everything the wallet holds; the daily cap is software) and the tripwire that detects it: keeper document section 5.

Tested (`testRoles_...`, Foundry): the treasury account is not the controller admin, not the pause guardian, not a market admin; as that account, `_setBorrowPaused`, `_setCollateralFactor`, `_reduceReserves`, `_setBorrowCashFloor` and `_setPriceOracle` are all refused; a third party with no funds cannot repay (the call pulls from the caller), and cannot `transferFrom` the treasury although it approved the market; the approval is bounded (a second repayment beyond the approved budget fails); anyone may repay with their own money.

### 3.2 What a mistaken or malicious repayment can and cannot do (tested)
| Action | Result |
| --- | --- |
| Repay a **healthy** account's debt (`testRepayBehalf_OnAHealthyAccount_...`) | A **gift**: the borrower's debt falls by the amount and its free liquidity rises; the cost is borne entirely by the treasury. **Not a theft**: exchange rate, every supplier's claim (within 2 wei), reserves are unchanged; cash rises by exactly what borrows fell |
| Repay on behalf **never harms other suppliers** (asserted in all 285 grid states, the unfunded ones included: claims, reserves, exchange rate unchanged by the repayment; `cash + borrows - reserves = sum of claims`) | suppliers can only gain cash |
| `_addReserves` called instead of `repayBorrowBehalf` | debt unchanged; the money is booked as protocol reserves and the admin can withdraw it (the admin, not the treasury, received it in the test). Not repayment |
| Repay more than owed | reverts (use the sentinel) |
| Sentinel on a debt-free account | succeeds and moves nothing |
| Repay on the wrong market (pWAVAX has no borrows) | refused |
| Third party calls with the treasury's approval | impossible: the call spends the caller's funds |
| Rule fooled by a manipulated price | the treasury pays a recoverable account's debt: a loss bounded by the treasury balance; prevented by the independent reference price (2.3) |
| Keeper key compromised, or a keeper host operator colludes with a borrower (borrows at the cap, then "defaults") | bounded by the keeper wallet's balance (the daily cap is software and does not bind an attacker with the key); the monitor's `treasury:unexplained-outflow` finding detects USDC leaving without a recorded payment. Not preventable by the contract |

Not tested: gas and nonce handling on a congested chain, nonce recovery after a dropped transaction, the real Safe top-up flow, keeper host availability (a keeper that is down pays nothing; the unpaid-default alerts at 1 h / 4 h / 24 h are the safety net).

## 4. (c) Available funding the treasury must hold

### 4.1 Closed form and measurement
`L = D - C_after / LI`, algebraically the decision table's `D x (1 - rho / LI)` with `rho = C_after / D = (1 - x) / (CF x u)`; `D` is the debt at the gap *including accrued interest*, `x` the fall, `u = D / (CF x C_before)`. Measured per event by the suite and compared (asserted) with the closed form on the measured position. The treasury must hold **L(delay) in USDC on Avalanche at repayment time**, in one account, separate from liquidator inventory and withdrawal cash.

| candidate | AVAX gap | cap (USD) | measured L0 (unrecoverable debt at the event) | closed form on the measured position, D - C/LI | decision-table closed form, u = 99% and no interest, x cap | measured L(7 d) | measured L(30 d) | L0 per USD 100,000 of cap |
|---|---|---|---|---|---|---|---|---|
| PW40 | -60.0% | 1,000 | **83.94** | 83.94 | 64.72 | 83.98 | 84.13 | 8,394 |
| PW40 | -60.0% | 5,000 | **419.69** | 419.69 | 323.61 | 419.91 | 420.66 | 8,394 |
| PW40 | -60.0% | 10,000 | **839.37** | 839.37 | 647.21 | 839.83 | 841.33 | 8,394 |
| PW40 | -67.6% | 1,000 | **259.86** | 259.86 | 242.42 | 260.09 | 260.84 | 25,986 |
| PW40 | -67.6% | 5,000 | **1,299.32** | 1,299.32 | 1,212.12 | 1,300.46 | 1,304.21 | 25,986 |
| PW40 | -67.6% | 10,000 | **2,598.63** | 2,598.63 | 2,424.24 | 2,600.91 | 2,608.41 | 25,986 |
| PW40 | -75.0% | 1,000 | **431.16** | 431.16 | 415.45 | 431.68 | 433.39 | 43,116 |
| PW40 | -75.0% | 5,000 | **2,155.80** | 2,155.80 | 2,077.25 | 2,158.39 | 2,166.93 | 43,116 |
| PW40 | -75.0% | 10,000 | **4,311.59** | 4,311.59 | 4,154.51 | 4,316.79 | 4,333.85 | 43,116 |
| PW30 | -75.0% | 1,000 | **238.26** | 238.26 | 220.60 | 238.46 | 239.11 | 23,826 |
| PW30 | -75.0% | 5,000 | **1,191.29** | 1,191.29 | 1,103.01 | 1,192.29 | 1,195.57 | 23,826 |
| PW30 | -75.0% | 10,000 | **2,382.58** | 2,382.58 | 2,206.01 | 2,384.58 | 2,391.13 | 23,826 |
| PW30 | -80.0% | 1,000 | **392.58** | 392.58 | 376.48 | 393.02 | 394.48 | 39,258 |
| PW30 | -80.0% | 5,000 | **1,962.90** | 1,962.90 | 1,882.40 | 1,965.12 | 1,972.41 | 39,258 |
| PW30 | -80.0% | 10,000 | **3,925.79** | 3,925.79 | 3,764.81 | 3,930.23 | 3,944.82 | 39,258 |

Columns: *measured L0* is the loss right after liquidation; *closed form* is `D - C/LI` on the measured position; *decision-table closed form* is the decision table's figure (u = 99%, no interest) scaled to the cap; *L(7 d)*, *L(30 d)* are the debt that the treasury must repay if it waits 7 / 30 days (phantom interest included).

### 4.2 Reconciliation with the decision table
The decision table (section D) gives USD 6,472 / 24,178 / 41,545 per 100,000 of cap for PW40 and 0 / 0 / 22,060 for PW30 at -75%. This work measures **8,394 / 25,986 / 43,116** (PW40) and **23,826** (PW30, -75%) / **39,258** (-80%) per 100,000. The difference is the instruction to model borrowers at **100%** of power (the table uses 99%) with **30 days of interest and no intermediate liquidation** (debt/power `u` = 100.986%): at -60% the PW40 figure is **30% higher** (a position that sits in the zone where `C/LI` barely exceeds the debt is very sensitive to `u`), at -75% 3.8% higher. **The worked example of the decision table (USD 6,500 per 100,000 at a -60% tail) is therefore too low for borrowers who sit at full power with accrued interest and are not liquidated on the interest-only shortfall.** In practice a liquidator would act on that shortfall and shrink the position; the figures here are the conservative bound. The decision table has no PW30 -80% row: the 37,648 per 100,000 shown in the funding table for that tail is this document's own extrapolation of the table's formula at u = 99%, not a number from that document. Sizing consequence (a proposal): size the treasury on the table above, not on the 99% figure.

### 4.3 Funding "in transit" while detection waits
While the response is pending, the funds must already be in the treasury account as USDC: they cannot be in a bridge or a swap. The amount at risk of being required is `L(delay)`: `L0` plus phantom interest, which per USD 10,000 of cap is (section 5 table): PW40 -75%: 0.74 / 5.19 / 22.26 USDC after 1 / 7 / 30 days (0.52% of L0 after 30 days); PW30 -80%: 0.63 / 4.44 / 19.03. A **buffer of about 0.5% of L0** covers a 30-day response; reserves cover part of it (section 6). Funding that is committed to *other* purposes (liquidator inventory, withdrawal cash) is not counted.

Per cap (USDC; treasury balance that makes all suppliers whole after a response within 30 days):
| Candidate / tail | cap 1,000 | cap 5,000 | cap 10,000 |
| --- | --- | --- | --- |
| PW40 -60% | 84.13 | 420.66 | 841.33 |
| PW40 -67.6% | 260.84 | 1,304.21 | 2,608.41 |
| PW40 -75% | 433.39 | 2,166.93 | 4,333.85 |
| PW30 -75% | 239.11 | 1,195.57 | 2,391.13 |
| PW30 -80% | 394.48 | 1,972.41 | 3,944.82 |

## 5. (d) Response time: what a delay costs

### 5.1 Measured: interest on the unrecoverable debt (S0 "phantom interest") and the exit window
After the event the market is lightly used (borrows are only the unpaid debt, cash is large), so the borrow rate is near the 2% base, and the unpaid debt grows slowly; reserves take 10% of that interest. Cap 10,000 (everything scales with the cap):

| cap | cand | gap | delay | debt L(delay) | phantom interest (L(delay) - L0) | phantom as % of L0 | reserves | market cash | sum of claims | borrow APR (post-event) | utilisation (post-event) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1000 | PW30 | -75.0% | 0 d | 238.26 | 0.00 | 0.000% | 0.99 | 1,021.60 | 1,258.88 | 4.37% | 18.93% |
| 1000 | PW30 | -75.0% | 1 d | 238.29 | 0.03 | 0.012% | 0.99 | 1,021.60 | 1,258.90 | 4.37% | 18.93% |
| 1000 | PW30 | -75.0% | 7 d | 238.46 | 0.20 | 0.084% | 1.01 | 1,021.60 | 1,259.06 | 4.37% | 18.94% |
| 1000 | PW30 | -75.0% | 30 d | 239.11 | 0.85 | 0.359% | 1.07 | 1,021.60 | 1,259.65 | 4.37% | 18.98% |
| 1000 | PW30 | -80.0% | 0 d | 392.58 | 0.00 | 0.000% | 0.99 | 867.28 | 1,258.88 | 5.90% | 31.18% |
| 1000 | PW30 | -80.0% | 1 d | 392.64 | 0.06 | 0.016% | 0.99 | 867.28 | 1,258.93 | 5.90% | 31.19% |
| 1000 | PW30 | -80.0% | 7 d | 393.02 | 0.44 | 0.113% | 1.03 | 867.28 | 1,259.28 | 5.90% | 31.21% |
| 1000 | PW30 | -80.0% | 30 d | 394.48 | 1.90 | 0.485% | 1.18 | 867.28 | 1,260.59 | 5.91% | 31.29% |
| 5000 | PW30 | -75.0% | 0 d | 1,191.29 | 0.00 | 0.000% | 4.93 | 5,108.02 | 6,294.38 | 4.37% | 18.93% |
| 5000 | PW30 | -75.0% | 1 d | 1,191.43 | 0.14 | 0.012% | 4.95 | 5,108.02 | 6,294.51 | 4.37% | 18.93% |
| 5000 | PW30 | -75.0% | 7 d | 1,192.29 | 1.00 | 0.084% | 5.03 | 5,108.02 | 6,295.28 | 4.37% | 18.94% |
| 5000 | PW30 | -75.0% | 30 d | 1,195.57 | 4.27 | 0.359% | 5.36 | 5,108.02 | 6,298.23 | 4.37% | 18.98% |
| 5000 | PW30 | -80.0% | 0 d | 1,962.90 | 0.00 | 0.000% | 4.93 | 4,336.42 | 6,294.38 | 5.90% | 31.18% |
| 5000 | PW30 | -80.0% | 1 d | 1,963.21 | 0.32 | 0.016% | 4.96 | 4,336.42 | 6,294.67 | 5.90% | 31.19% |
| 5000 | PW30 | -80.0% | 7 d | 1,965.12 | 2.22 | 0.113% | 5.15 | 4,336.42 | 6,296.38 | 5.90% | 31.21% |
| 5000 | PW30 | -80.0% | 30 d | 1,972.41 | 9.52 | 0.485% | 5.88 | 4,336.42 | 6,302.95 | 5.91% | 31.29% |
| 10000 | PW30 | -75.0% | 0 d | 2,382.58 | 0.00 | 0.000% | 9.86 | 10,216.05 | 12,588.77 | 4.37% | 18.93% |
| 10000 | PW30 | -75.0% | 1 d | 2,382.87 | 0.28 | 0.012% | 9.89 | 10,216.05 | 12,589.02 | 4.37% | 18.93% |
| 10000 | PW30 | -75.0% | 7 d | 2,384.58 | 1.99 | 0.084% | 10.06 | 10,216.05 | 12,590.56 | 4.37% | 18.94% |
| 10000 | PW30 | -75.0% | 30 d | 2,391.13 | 8.55 | 0.359% | 10.72 | 10,216.05 | 12,596.46 | 4.37% | 18.98% |
| 10000 | PW30 | -80.0% | 0 d | 3,925.79 | 0.00 | 0.000% | 9.86 | 8,672.84 | 12,588.77 | 5.90% | 31.18% |
| 10000 | PW30 | -80.0% | 1 d | 3,926.42 | 0.63 | 0.016% | 9.93 | 8,672.84 | 12,589.34 | 5.90% | 31.19% |
| 10000 | PW30 | -80.0% | 7 d | 3,930.23 | 4.44 | 0.113% | 10.31 | 8,672.84 | 12,592.76 | 5.90% | 31.21% |
| 10000 | PW30 | -80.0% | 30 d | 3,944.82 | 19.03 | 0.485% | 11.77 | 8,672.84 | 12,605.90 | 5.91% | 31.29% |
| 1000 | PW40 | -60.0% | 0 d | 83.94 | 0.00 | 0.000% | 0.99 | 1,175.93 | 1,258.88 | 2.83% | 6.67% |
| 1000 | PW40 | -60.0% | 1 d | 83.94 | 0.01 | 0.008% | 0.99 | 1,175.93 | 1,258.88 | 2.83% | 6.67% |
| 1000 | PW40 | -60.0% | 7 d | 83.98 | 0.05 | 0.054% | 0.99 | 1,175.93 | 1,258.92 | 2.83% | 6.67% |
| 1000 | PW40 | -60.0% | 30 d | 84.13 | 0.20 | 0.233% | 1.01 | 1,175.93 | 1,259.05 | 2.84% | 6.68% |
| 1000 | PW40 | -67.6% | 0 d | 259.86 | 0.00 | 0.000% | 0.99 | 1,000.00 | 1,258.88 | 4.58% | 20.64% |
| 1000 | PW40 | -67.6% | 1 d | 259.90 | 0.03 | 0.013% | 0.99 | 1,000.00 | 1,258.91 | 4.58% | 20.64% |
| 1000 | PW40 | -67.6% | 7 d | 260.09 | 0.23 | 0.088% | 1.01 | 1,000.00 | 1,259.08 | 4.58% | 20.66% |
| 1000 | PW40 | -67.6% | 30 d | 260.84 | 0.98 | 0.376% | 1.08 | 1,000.00 | 1,259.76 | 4.59% | 20.71% |
| 1000 | PW40 | -75.0% | 0 d | 431.16 | 0.00 | 0.000% | 0.99 | 828.70 | 1,258.88 | 6.28% | 34.25% |
| 1000 | PW40 | -75.0% | 1 d | 431.23 | 0.07 | 0.017% | 0.99 | 828.70 | 1,258.94 | 6.28% | 34.25% |
| 1000 | PW40 | -75.0% | 7 d | 431.68 | 0.52 | 0.120% | 1.04 | 828.70 | 1,259.34 | 6.28% | 34.28% |
| 1000 | PW40 | -75.0% | 30 d | 433.39 | 2.23 | 0.516% | 1.21 | 828.70 | 1,260.88 | 6.30% | 34.37% |
| 5000 | PW40 | -60.0% | 0 d | 419.69 | 0.00 | 0.000% | 4.93 | 5,879.63 | 6,294.38 | 2.83% | 6.67% |
| 5000 | PW40 | -60.0% | 1 d | 419.72 | 0.03 | 0.008% | 4.93 | 5,879.63 | 6,294.41 | 2.83% | 6.67% |
| 5000 | PW40 | -60.0% | 7 d | 419.91 | 0.23 | 0.054% | 4.95 | 5,879.63 | 6,294.59 | 2.83% | 6.67% |
| 5000 | PW40 | -60.0% | 30 d | 420.66 | 0.98 | 0.233% | 5.03 | 5,879.63 | 6,295.26 | 2.84% | 6.68% |
| 5000 | PW40 | -67.6% | 0 d | 1,299.32 | 0.00 | 0.000% | 4.93 | 5,000.00 | 6,294.38 | 4.58% | 20.64% |
| 5000 | PW40 | -67.6% | 1 d | 1,299.48 | 0.16 | 0.013% | 4.95 | 5,000.00 | 6,294.53 | 4.58% | 20.64% |
| 5000 | PW40 | -67.6% | 7 d | 1,300.46 | 1.14 | 0.088% | 5.05 | 5,000.00 | 6,295.41 | 4.58% | 20.66% |
| 5000 | PW40 | -67.6% | 30 d | 1,304.21 | 4.89 | 0.376% | 5.42 | 5,000.00 | 6,298.79 | 4.59% | 20.71% |
| 5000 | PW40 | -75.0% | 0 d | 2,155.80 | 0.00 | 0.000% | 4.93 | 4,143.52 | 6,294.38 | 6.28% | 34.25% |
| 5000 | PW40 | -75.0% | 1 d | 2,156.17 | 0.37 | 0.017% | 4.97 | 4,143.52 | 6,294.72 | 6.28% | 34.25% |
| 5000 | PW40 | -75.0% | 7 d | 2,158.39 | 2.60 | 0.120% | 5.19 | 4,143.52 | 6,296.72 | 6.28% | 34.28% |
| 5000 | PW40 | -75.0% | 30 d | 2,166.93 | 11.13 | 0.516% | 6.04 | 4,143.52 | 6,304.40 | 6.30% | 34.37% |
| 10000 | PW40 | -60.0% | 0 d | 839.37 | 0.00 | 0.000% | 9.86 | 11,759.26 | 12,588.77 | 2.83% | 6.67% |
| 10000 | PW40 | -60.0% | 1 d | 839.44 | 0.07 | 0.008% | 9.87 | 11,759.26 | 12,588.83 | 2.83% | 6.67% |
| 10000 | PW40 | -60.0% | 7 d | 839.83 | 0.46 | 0.054% | 9.91 | 11,759.26 | 12,589.18 | 2.83% | 6.67% |
| 10000 | PW40 | -60.0% | 30 d | 841.33 | 1.95 | 0.233% | 10.06 | 11,759.26 | 12,590.53 | 2.84% | 6.68% |
| 10000 | PW40 | -67.6% | 0 d | 2,598.63 | 0.00 | 0.000% | 9.86 | 10,000.00 | 12,588.77 | 4.58% | 20.64% |
| 10000 | PW40 | -67.6% | 1 d | 2,598.96 | 0.33 | 0.013% | 9.90 | 10,000.00 | 12,589.06 | 4.58% | 20.64% |
| 10000 | PW40 | -67.6% | 7 d | 2,600.91 | 2.28 | 0.088% | 10.09 | 10,000.00 | 12,590.82 | 4.58% | 20.66% |
| 10000 | PW40 | -67.6% | 30 d | 2,608.41 | 9.78 | 0.376% | 10.84 | 10,000.00 | 12,597.57 | 4.59% | 20.71% |
| 10000 | PW40 | -75.0% | 0 d | 4,311.59 | 0.00 | 0.000% | 9.86 | 8,287.04 | 12,588.77 | 6.28% | 34.25% |
| 10000 | PW40 | -75.0% | 1 d | 4,312.34 | 0.74 | 0.017% | 9.94 | 8,287.04 | 12,589.43 | 6.28% | 34.25% |
| 10000 | PW40 | -75.0% | 7 d | 4,316.79 | 5.19 | 0.120% | 10.38 | 8,287.04 | 12,593.44 | 6.28% | 34.28% |
| 10000 | PW40 | -75.0% | 30 d | 4,333.85 | 22.26 | 0.516% | 12.09 | 8,287.04 | 12,608.80 | 6.30% | 34.37% |

(The table lists all caps; the 10,000 rows are the USD amounts quoted in the text.) Reading, PW40 -75%: post-event utilisation 34.3%, borrow APR 6.28%; the debt grows 0.017% per day of L0 (0.74 USDC per day on cap 10,000 at first), 0.52% in 30 days. At the -60% tail the APR is 2.83% and the 30-day phantom interest 0.23% of L0.

**The exit window.** While nothing is repaid, the exchange rate is unchanged (and even grows with the phantom interest), so claims stay at 100% and the market holds only `cash` of them. The share of claims that can exit whole, first come first served:

| candidate | AVAX gap | delay | market cash | sum of claims | share of claims that can exit whole (FCFS) while nothing is repaid |
|---|---|---|---|---|---|
| PW30 | -75.0% | 0 d | 1,021.60 | 1,258.88 | 81.2% (cap 1000) |
| PW30 | -75.0% | 30 d | 1,021.60 | 1,259.65 | 81.1% (cap 1000) |
| PW30 | -80.0% | 0 d | 867.28 | 1,258.88 | 68.9% (cap 1000) |
| PW30 | -80.0% | 30 d | 867.28 | 1,260.59 | 68.8% (cap 1000) |
| PW30 | -75.0% | 0 d | 5,108.02 | 6,294.38 | 81.2% (cap 5000) |
| PW30 | -75.0% | 30 d | 5,108.02 | 6,298.23 | 81.1% (cap 5000) |
| PW30 | -80.0% | 0 d | 4,336.42 | 6,294.38 | 68.9% (cap 5000) |
| PW30 | -80.0% | 30 d | 4,336.42 | 6,302.95 | 68.8% (cap 5000) |
| PW30 | -75.0% | 0 d | 10,216.05 | 12,588.77 | 81.2% (cap 10000) |
| PW30 | -75.0% | 30 d | 10,216.05 | 12,596.46 | 81.1% (cap 10000) |
| PW30 | -80.0% | 0 d | 8,672.84 | 12,588.77 | 68.9% (cap 10000) |
| PW30 | -80.0% | 30 d | 8,672.84 | 12,605.90 | 68.8% (cap 10000) |
| PW40 | -60.0% | 0 d | 1,175.93 | 1,258.88 | 93.4% (cap 1000) |
| PW40 | -60.0% | 30 d | 1,175.93 | 1,259.05 | 93.4% (cap 1000) |
| PW40 | -67.6% | 0 d | 1,000.00 | 1,258.88 | 79.4% (cap 1000) |
| PW40 | -67.6% | 30 d | 1,000.00 | 1,259.76 | 79.4% (cap 1000) |
| PW40 | -75.0% | 0 d | 828.70 | 1,258.88 | 65.8% (cap 1000) |
| PW40 | -75.0% | 30 d | 828.70 | 1,260.88 | 65.7% (cap 1000) |
| PW40 | -60.0% | 0 d | 5,879.63 | 6,294.38 | 93.4% (cap 5000) |
| PW40 | -60.0% | 30 d | 5,879.63 | 6,295.26 | 93.4% (cap 5000) |
| PW40 | -67.6% | 0 d | 5,000.00 | 6,294.38 | 79.4% (cap 5000) |
| PW40 | -67.6% | 30 d | 5,000.00 | 6,298.79 | 79.4% (cap 5000) |
| PW40 | -75.0% | 0 d | 4,143.52 | 6,294.38 | 65.8% (cap 5000) |
| PW40 | -75.0% | 30 d | 4,143.52 | 6,304.40 | 65.7% (cap 5000) |
| PW40 | -60.0% | 0 d | 11,759.26 | 12,588.77 | 93.4% (cap 10000) |
| PW40 | -60.0% | 30 d | 11,759.26 | 12,590.53 | 93.4% (cap 10000) |
| PW40 | -67.6% | 0 d | 10,000.00 | 12,588.77 | 79.4% (cap 10000) |
| PW40 | -67.6% | 30 d | 10,000.00 | 12,597.57 | 79.4% (cap 10000) |
| PW40 | -75.0% | 0 d | 8,287.04 | 12,588.77 | 65.8% (cap 10000) |
| PW40 | -75.0% | 30 d | 8,287.04 | 12,608.80 | 65.7% (cap 10000) |

(The share does not depend on the cap.) PW40 -75%: **65.8% of the claims can exit whole; the remaining 34.2% cannot**. A supplier who exits inside the window is whole; the rest bear the loss. **The window is open from the moment the liquidation has exhausted the collateral (the loss is on chain from that block, the exchange rate does not move) until the treasury's repayment is mined.**

### 5.2 Supplier outcome as a function of the delay
The shortfall in percent of supply, the worst single supplier's recovery and the spread across orders are essentially **independent of the delay** (e.g. PW40 -75% unfunded: 34.41% of supply at 0 d, 34.57% at 30 d; worst recovery 0.00% at every delay); the delay moves only the amount that must be repaid. Full tables in section 7. Two consequences:
- **Early/late advantage does not grow with time; it exists for as long as the repayment is outstanding.** At 0% funding the spread between the best and worst order for the same supplier is the full range (e.g. PW40 -75%: supplier A recovers 31.7%..100%; supplier D 0%..100%).
- **Funding 100% of L0 and responding late leaves a small residual**: at 7 days and below nobody is short (the reserves absorb the phantom interest); at 30 days PW40 -75% leaves **0.08% of supply** short (worst single recovery 99.2%) and PW30 -80% 0.06% (99.4%). Funding 100% of `L(delay)` leaves nobody short at any delay (asserted).

### 5.3 Response-time target and alerts (keeper design; the targets are operational choices, the tests measure the cost of waiting)
The keeper pays automatically, so the response time is the **confirmation window plus one transaction**: `DEFAULT_EXHAUSTED` must read on 2 evaluations at least 60 s apart, then the keeper re-verifies, approves, repays and reads back (about 3 transactions, seconds on Avalanche). The TWAP gate can hold a verdict at `PRICE_DIVERGENCE` for up to about 30 minutes after a fast move; nothing is paid during that time.

| Alert | Condition (monitor, every cycle) | Action |
| --- | --- | --- |
| feed age | AVAX price age above half the limit (600 s of 1,200 s), critical at 80%; USDC age above 89% of 90,000 s, critical at 95% | investigate; the rule is silent on stale prices |
| liquidatable | any account with verdict `LIQUIDATABLE_RECOVERABLE` or worse | liquidator operators (their executors act on their own) |
| tail account | any account `UNRECOVERABLE_LIQUIDATE_FIRST` (expected keeper payment = `debtUsd - maxRecoveryUsd`) | watch: a payment is coming; check the keeper balance |
| default (T0) | any account `DEFAULT_EXHAUSTED` | the keeper pays after confirmation; the guardian decides on pausing borrowing and minting (section 6.3) |
| payment | every keeper payment | message with the read-back (account, amount, transaction, balance left) |
| not paid | a confirmed default the keeper did NOT pay (cap, balance, fee, gas, re-verification, halt) | **page**: a human decides (top up from the Safe, raise the cap, clear a halt, partial repayment) |
| unpaid | `DEFAULT_EXHAUSTED` still unresolved at T0 + 1 h, T0 + 4 h and T0 + 24 h | escalate; at T0 + 4 h consider partial repayment (section 6) |
| funding | keeper USDC below the sum of `debt` over accounts at `UNRECOVERABLE_LIQUIDATE_FIRST` or worse | top up from the Safe (section 4.3) |
| unrecoverable debt | `sum over borrowers of max(0, debt - collateral/LI) - reserves > 0` (`operator/src/backing.ts`; replaces the earlier "claims minus cash" condition, which is positive whenever borrows are outstanding) | same as default; zero on the healthy and recoverable rows, positive on the tail and default rows |
| unexplained outflow | keeper USDC fell by more than its recorded payments explain | **page**: possible key compromise; move the remaining funds with the Safe procedure and rotate the key |
| halted | keeper or executor halted (revert, read-back mismatch, interrupted payment) | a human checks allowance, balance, the account's debt, then clears the flag |

**Targets: payment mined within minutes of T0 (confirmation window + one transaction); escalation at 1 h, 4 h and 24 h if unresolved.** Basis unchanged: the interest cost is negligible even at 30 days (at most 0.52% of L0); what matters is the exit window (section 5.1). The numbers 1 h / 4 h / 24 h are operational choices, not results of these tests.

## 6. (e) Insufficient funding

### 6.1 What happens (measured; funding as % of L0, all 24 orders)
For every state the suite asserts, **in every one of the 24 orders**: (i) value is conserved (every USDC went to a supplier or stays in the market); (ii) the **total exit shortfall equals `max(0, remaining borrows - reserves)`**; and across funding levels (iii) `shortfall(funded) + repaid = shortfall(unfunded)` while a shortfall remains, otherwise `repaid + reserves >= debt`. Every USDC repaid removes one USDC of shortfall; the reserves (protocol money in the market) absorb the first part of an unpaid debt (note: reserves are admin-withdrawable, so that cushion is not guaranteed).

**Who is short.** In this population the first supplier in the queue was never short (max shortfall of the first-in-queue = 0 in every state); the shortfall falls on the last suppliers in the queue, spilling backwards through the queue when the last one's whole claim is smaller than the shortfall. Example, PW40, -75%, cap 10,000, delay 0 (all 24 orders; shortfall of each supplier in USDC; A holds 50% of S):

**All 24 withdrawal orders, cap USD 10000, PW40, gap -75.0%, delay 0 d.** Shortfall of each supplier A (50% of S), B (25%), C (15%), D (10%) in USDC; order = who withdraws first..last.

| order (first..last) | 0% (nothing): A / B / C / D | 25% of L0: A / B / C / D | 50% of L0: A / B / C / D | 100% of L0: A / B / C / D |
|---|---|---|---|---|
| ABCD | 0.00 / 1,154.54 / 1,888.32 / 1,258.88 | 0.00 / 76.64 / 1,888.32 / 1,258.88 | 0.00 / 0.00 / 887.06 / 1,258.88 | 0.00 / 0.00 / 0.00 / 0.00 |
| ABDC | 0.00 / 1,154.54 / 1,888.32 / 1,258.88 | 0.00 / 76.64 / 1,888.32 / 1,258.88 | 0.00 / 0.00 / 1,888.32 / 257.62 | 0.00 / 0.00 / 0.00 / 0.00 |
| ACBD | 0.00 / 3,042.85 / 0.00 / 1,258.88 | 0.00 / 1,964.96 / 0.00 / 1,258.88 | 0.00 / 887.06 / 0.00 / 1,258.88 | 0.00 / 0.00 / 0.00 / 0.00 |
| ACDB | 0.00 / 3,147.19 / 0.00 / 1,154.54 | 0.00 / 3,147.19 / 0.00 / 76.64 | 0.00 / 2,145.93 / 0.00 / 0.00 | 0.00 / 0.00 / 0.00 / 0.00 |
| ADBC | 0.00 / 2,413.42 / 1,888.32 / 0.00 | 0.00 / 1,335.52 / 1,888.32 / 0.00 | 0.00 / 257.62 / 1,888.32 / 0.00 | 0.00 / 0.00 / 0.00 / 0.00 |
| ADCB | 0.00 / 3,147.19 / 1,154.54 / 0.00 | 0.00 / 3,147.19 / 76.64 / 0.00 | 0.00 / 2,145.93 / 0.00 / 0.00 | 0.00 / 0.00 / 0.00 / 0.00 |
| BACD | 1,154.54 / 0.00 / 1,888.32 / 1,258.88 | 76.64 / 0.00 / 1,888.32 / 1,258.88 | 0.00 / 0.00 / 887.06 / 1,258.88 | 0.00 / 0.00 / 0.00 / 0.00 |
| BADC | 1,154.54 / 0.00 / 1,888.32 / 1,258.88 | 76.64 / 0.00 / 1,888.32 / 1,258.88 | 0.00 / 0.00 / 1,888.32 / 257.62 | 0.00 / 0.00 / 0.00 / 0.00 |
| BCAD | 3,042.85 / 0.00 / 0.00 / 1,258.88 | 1,964.96 / 0.00 / 0.00 / 1,258.88 | 887.06 / 0.00 / 0.00 / 1,258.88 | 0.00 / 0.00 / 0.00 / 0.00 |
| BCDA | 4,301.73 / 0.00 / 0.00 / 0.00 | 3,223.83 / 0.00 / 0.00 / 0.00 | 2,145.93 / 0.00 / 0.00 / 0.00 | 0.00 / 0.00 / 0.00 / 0.00 |
| BDAC | 2,413.42 / 0.00 / 1,888.32 / 0.00 | 1,335.52 / 0.00 / 1,888.32 / 0.00 | 257.62 / 0.00 / 1,888.32 / 0.00 | 0.00 / 0.00 / 0.00 / 0.00 |
| BDCA | 4,301.73 / 0.00 / 0.00 / 0.00 | 3,223.83 / 0.00 / 0.00 / 0.00 | 2,145.93 / 0.00 / 0.00 / 0.00 | 0.00 / 0.00 / 0.00 / 0.00 |
| CABD | 0.00 / 3,042.85 / 0.00 / 1,258.88 | 0.00 / 1,964.96 / 0.00 / 1,258.88 | 0.00 / 887.06 / 0.00 / 1,258.88 | 0.00 / 0.00 / 0.00 / 0.00 |
| CADB | 0.00 / 3,147.19 / 0.00 / 1,154.54 | 0.00 / 3,147.19 / 0.00 / 76.64 | 0.00 / 2,145.93 / 0.00 / 0.00 | 0.00 / 0.00 / 0.00 / 0.00 |
| CBAD | 3,042.85 / 0.00 / 0.00 / 1,258.88 | 1,964.96 / 0.00 / 0.00 / 1,258.88 | 887.06 / 0.00 / 0.00 / 1,258.88 | 0.00 / 0.00 / 0.00 / 0.00 |
| CBDA | 4,301.73 / 0.00 / 0.00 / 0.00 | 3,223.83 / 0.00 / 0.00 / 0.00 | 2,145.93 / 0.00 / 0.00 / 0.00 | 0.00 / 0.00 / 0.00 / 0.00 |
| CDAB | 1,154.54 / 3,147.19 / 0.00 / 0.00 | 76.64 / 3,147.19 / 0.00 / 0.00 | 0.00 / 2,145.93 / 0.00 / 0.00 | 0.00 / 0.00 / 0.00 / 0.00 |
| CDBA | 4,301.73 / 0.00 / 0.00 / 0.00 | 3,223.83 / 0.00 / 0.00 / 0.00 | 2,145.93 / 0.00 / 0.00 / 0.00 | 0.00 / 0.00 / 0.00 / 0.00 |
| DABC | 0.00 / 2,413.42 / 1,888.32 / 0.00 | 0.00 / 1,335.52 / 1,888.32 / 0.00 | 0.00 / 257.62 / 1,888.32 / 0.00 | 0.00 / 0.00 / 0.00 / 0.00 |
| DACB | 0.00 / 3,147.19 / 1,154.54 / 0.00 | 0.00 / 3,147.19 / 76.64 / 0.00 | 0.00 / 2,145.93 / 0.00 / 0.00 | 0.00 / 0.00 / 0.00 / 0.00 |
| DBAC | 2,413.42 / 0.00 / 1,888.32 / 0.00 | 1,335.52 / 0.00 / 1,888.32 / 0.00 | 257.62 / 0.00 / 1,888.32 / 0.00 | 0.00 / 0.00 / 0.00 / 0.00 |
| DBCA | 4,301.73 / 0.00 / 0.00 / 0.00 | 3,223.83 / 0.00 / 0.00 / 0.00 | 2,145.93 / 0.00 / 0.00 / 0.00 | 0.00 / 0.00 / 0.00 / 0.00 |
| DCAB | 1,154.54 / 3,147.19 / 0.00 / 0.00 | 76.64 / 3,147.19 / 0.00 / 0.00 | 0.00 / 2,145.93 / 0.00 / 0.00 | 0.00 / 0.00 / 0.00 / 0.00 |
| DCBA | 4,301.73 / 0.00 / 0.00 / 0.00 | 3,223.83 / 0.00 / 0.00 / 0.00 | 2,145.93 / 0.00 / 0.00 / 0.00 | 0.00 / 0.00 / 0.00 / 0.00 |

Outcome for the last supplier: with nothing funded it loses its **whole** claim when its claim is not larger than the shortfall (D: 1,258.88; C: 1,888.32; B: 3,147.19) and, if A is last, A loses 4,301.73 of 6,294.38 (68%); with 50% funding the worst last-supplier loss is 2,145.93 (B or A), at 100% nothing. The complete 24-order tables for every cap, candidate, tail, delay and funding level are in `avalanche-cash-only-treasury-evidence/tables/all-24-orders-every-state.md` (generated from the `TRP|ORD|` lines).

**Late funding still helps** (`testLateFunding_...`): with nothing funded, suppliers exit in the order A, B, C, D; the market empties and the late ones keep leftover pTokens; the treasury then repays the loss; each supplier's leftover is redeemable and every supplier ends with its full claim (within 16 wei). The shortfall is a deferred claim, not extinguished.

### 6.2 Supplier outcomes by funding level
See section 7. Worst single recovery over all 24 orders: PW40 -60%: 100% (funded) / 67.5% (50%) / 50.8% (25%) / 34.1% (0%); -67.6%: 100% / 0% / 0% / 0%; -75%: 100% / 0% / 0% / 0%. PW30 -75%: 100% / 6.15% / 0% / 0%; -80%: 100% / 0% / 0% / 0%.

### 6.3 Operational mitigations, and what none of them can do (tested in `testMitigations_...`, PW40 -75%, cap 5,000)
| Mitigation | What it does (measured) | What it cannot do |
| --- | --- | --- |
| **Pause new borrowing** (guardian `_setBorrowPaused`) | with borrowing open, a fresh healthy borrower can take all cash above the floor: the unmet part of claims grows from 2,150.87 (loss minus reserves) to **5,044.38** (illiquidity, not loss: those loans are recoverable); with the pause the borrow is refused | recover any of the 2,150.87 |
| **Raise the cash floor** (admin `_setBorrowCashFloor`) | a floor above the cash refuses every new borrow; supplier A still exits in full although cash is below the floor | the floor limits *borrows only*; it does not block redemptions and does not create cash |
| **Pause minting** (guardian `_setMintPaused`) | new depositors cannot enter a damaged market (they would be behind the queue at an unreduced rate) | change what existing suppliers get |
| **Partial repayment first**, rest later | each instalment removes exactly its amount from the shortfall (25% then the rest: shortfall after the first = loss - 25% - reserves, after the second ~0) | speed up the second instalment |
| **All of the above together** | shortfall in every one of the 24 orders is still `max(0, loss - reserves)` (asserted) | change the shortfall |

**There is no switch that pauses redemptions** (`_setRedeemPaused` does not exist; the call is refused); `redeemAllowed` checks liquidity only for accounts that *entered* the market, so plain depositors are never frozen. Therefore **nothing the guardian or admin can do stops the first-come-first-served race, and nothing creates the missing cash**: borrowers in default have no collateral and are unsecured; the only sources of cash are the treasury, reserves (small: USD 9.86 per 10,000 of cap after 30 days) and the borrowers. `_addReserves` is not repayment (previous loss-handling document, section 5).

## 7. Supplier outcomes by withdrawal order (tables per cap and candidate)
Columns: shortfall in USDC for caps 1,000 / 5,000 / 10,000; percentages are cap-independent. *recovery* = USDC received over the claim at exit, minimum and maximum over the 24 orders for each supplier (A 50% of S, B 25%, C 15%, D 10%); *worst single recovery* = minimum over all orders and suppliers; *orders with a short supplier* of 24; *last-in-queue worst shortfall* = the largest shortfall suffered by the supplier who withdraws last, in percent of S. The "early" withdrawer is the first in the order (never short: 0 in every state); the "late" withdrawer's worst case is the last column. Funding is a fraction of L0 (and `100% of L(delay)` for delays above 0).

### PW40

**PW40, AVAX gap -60.0%** (L0 = 83.94 / 419.69 / 839.37 USDC for caps 1,000 / 5,000 / 10,000)

| delay | funding | unpaid debt, USD (cap 1k / 5k / 10k) | **exit shortfall, USD (1k / 5k / 10k)** | shortfall as % of supply | supplier A (50%) recovery min..max | B (25%) | C (15%) | D (10%) | worst single recovery | orders (of 24) with a short supplier | last-in-queue worst shortfall, % of supply |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 d | 100% of L0 | 0.00 / 0.00 / 0.00 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 0 d | 50% of L0 | 41.97 / 209.84 / 419.69 | **40.98 / 204.91 / 409.82** | 3.28% | 93.49%..100.00% | 86.98%..100.00% | 78.30%..100.00% | 67.45%..100.00% | 67.45% | 24 | 3.28% |
| 0 d | 25% of L0 | 62.95 / 314.76 / 629.53 | **61.97 / 309.83 / 619.67** | 4.96% | 90.16%..100.00% | 80.31%..100.00% | 67.18%..100.00% | 50.78%..100.00% | 50.78% | 24 | 4.96% |
| 0 d | 0% (nothing) | 83.94 / 419.69 / 839.37 | **82.95 / 414.75 / 829.51** | 6.64% | 86.82%..100.00% | 73.64%..100.00% | 56.07%..100.00% | 34.11%..100.00% | 34.11% | 24 | 6.64% |
| 1 d | 100% of L0 | 0.01 / 0.03 / 0.07 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 1 d | 50% of L0 | 41.98 / 209.88 / 419.75 | **40.99 / 204.94 / 409.88** | 3.28% | 93.49%..100.00% | 86.98%..100.00% | 78.29%..100.00% | 67.44%..100.00% | 67.44% | 24 | 3.28% |
| 1 d | 25% of L0 | 62.96 / 314.80 / 629.59 | **61.97 / 309.86 / 619.72** | 4.96% | 90.15%..100.00% | 80.31%..100.00% | 67.18%..100.00% | 50.77%..100.00% | 50.77% | 24 | 4.96% |
| 1 d | 0% (nothing) | 83.94 / 419.72 / 839.44 | **82.96 / 414.78 / 829.57** | 6.64% | 86.82%..100.00% | 73.64%..100.00% | 56.07%..100.00% | 34.10%..100.00% | 34.10% | 24 | 6.64% |
| 1 d | 100% of L(delay) | 0.00 / 0.00 / 0.00 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 7 d | 100% of L0 | 0.05 / 0.23 / 0.46 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 7 d | 50% of L0 | 42.01 / 210.07 / 420.14 | **41.02 / 205.12 / 410.23** | 3.28% | 93.48%..100.00% | 86.97%..100.00% | 78.28%..100.00% | 67.41%..100.00% | 67.41% | 24 | 3.28% |
| 7 d | 25% of L0 | 63.00 / 314.99 / 629.98 | **62.01 / 310.04 / 620.08** | 4.96% | 90.15%..100.00% | 80.30%..100.00% | 67.16%..100.00% | 50.75%..100.00% | 50.75% | 24 | 4.96% |
| 7 d | 0% (nothing) | 83.98 / 419.91 / 839.83 | **82.99 / 414.96 / 829.92** | 6.64% | 86.82%..100.00% | 73.63%..100.00% | 56.05%..100.00% | 34.08%..100.00% | 34.08% | 24 | 6.64% |
| 7 d | 100% of L(delay) | 0.00 / 0.00 / 0.00 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 30 d | 100% of L0 | 0.20 / 0.98 / 1.95 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 30 d | 50% of L0 | 42.16 / 210.82 / 421.64 | **41.16 / 205.79 / 411.58** | 3.29% | 93.46%..100.00% | 86.92%..100.00% | 78.21%..100.00% | 67.31%..100.00% | 67.31% | 24 | 3.29% |
| 30 d | 25% of L0 | 63.15 / 315.74 / 631.48 | **62.14 / 310.71 / 621.42** | 4.97% | 90.13%..100.00% | 80.26%..100.00% | 67.10%..100.00% | 50.64%..100.00% | 50.64% | 24 | 4.97% |
| 30 d | 0% (nothing) | 84.13 / 420.66 / 841.33 | **83.13 / 415.63 / 831.27** | 6.65% | 86.80%..100.00% | 73.59%..100.00% | 55.98%..100.00% | 33.98%..100.00% | 33.98% | 24 | 6.65% |
| 30 d | 100% of L(delay) | 0.00 / 0.00 / 0.00 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |

**PW40, AVAX gap -67.6%** (L0 = 259.86 / 1,299.32 / 2,598.63 USDC for caps 1,000 / 5,000 / 10,000)

| delay | funding | unpaid debt, USD (cap 1k / 5k / 10k) | **exit shortfall, USD (1k / 5k / 10k)** | shortfall as % of supply | supplier A (50%) recovery min..max | B (25%) | C (15%) | D (10%) | worst single recovery | orders (of 24) with a short supplier | last-in-queue worst shortfall, % of supply |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 d | 100% of L0 | 0.00 / 0.00 / 0.00 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 0 d | 50% of L0 | 129.93 / 649.66 / 1,299.32 | **128.95 / 644.73 / 1,289.45** | 10.32% | 79.51%..100.00% | 59.03%..100.00% | 31.71%..100.00% | 0.00%..100.00% | 0.00% | 24 | 10.32% |
| 0 d | 25% of L0 | 194.90 / 974.49 / 1,948.97 | **193.91 / 969.55 / 1,939.11** | 15.51% | 69.19%..100.00% | 38.39%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 15.51% |
| 0 d | 0% (nothing) | 259.86 / 1,299.32 / 2,598.63 | **258.88 / 1,294.38 / 2,588.77** | 20.71% | 58.87%..100.00% | 17.74%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 20.71% |
| 1 d | 100% of L0 | 0.03 / 0.16 / 0.33 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 1 d | 50% of L0 | 129.96 / 649.82 / 1,299.64 | **128.97 / 644.87 / 1,289.75** | 10.32% | 79.51%..100.00% | 59.02%..100.00% | 31.70%..100.00% | 0.00%..100.00% | 0.00% | 24 | 10.32% |
| 1 d | 25% of L0 | 194.93 / 974.65 / 1,949.30 | **193.94 / 969.70 / 1,939.40** | 15.52% | 69.19%..100.00% | 38.38%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 15.52% |
| 1 d | 0% (nothing) | 259.90 / 1,299.48 / 2,598.96 | **258.91 / 1,294.53 / 2,589.06** | 20.71% | 58.87%..100.00% | 17.74%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 20.71% |
| 1 d | 100% of L(delay) | 0.00 / 0.00 / 0.00 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 7 d | 100% of L0 | 0.23 / 1.14 / 2.28 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 7 d | 50% of L0 | 130.16 / 650.80 / 1,301.60 | **129.15 / 645.75 / 1,291.51** | 10.33% | 79.48%..100.00% | 58.97%..100.00% | 31.62%..100.00% | 0.00%..100.00% | 0.00% | 24 | 10.33% |
| 7 d | 25% of L0 | 195.13 / 975.63 / 1,951.26 | **194.12 / 970.58 / 1,941.16** | 15.53% | 69.17%..100.00% | 38.33%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 15.53% |
| 7 d | 0% (nothing) | 260.09 / 1,300.46 / 2,600.91 | **259.08 / 1,295.41 / 2,590.82** | 20.73% | 58.85%..100.00% | 17.69%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 20.73% |
| 7 d | 100% of L(delay) | 0.00 / 0.00 / 0.00 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 30 d | 100% of L0 | 0.98 / 4.89 / 9.78 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 30 d | 50% of L0 | 130.91 / 654.55 / 1,309.10 | **129.83 / 649.13 / 1,298.26** | 10.39% | 79.39%..100.00% | 58.78%..100.00% | 31.30%..100.00% | 0.00%..100.00% | 0.00% | 24 | 10.39% |
| 30 d | 25% of L0 | 195.88 / 979.38 / 1,958.76 | **194.79 / 973.96 / 1,947.91** | 15.58% | 69.07%..100.00% | 38.15%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 15.58% |
| 30 d | 0% (nothing) | 260.84 / 1,304.21 / 2,608.41 | **259.76 / 1,298.79 / 2,597.57** | 20.78% | 58.76%..100.00% | 17.52%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 20.78% |
| 30 d | 100% of L(delay) | 0.00 / 0.00 / 0.00 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |

**PW40, AVAX gap -75.0%** (L0 = 431.16 / 2,155.80 / 4,311.59 USDC for caps 1,000 / 5,000 / 10,000)

| delay | funding | unpaid debt, USD (cap 1k / 5k / 10k) | **exit shortfall, USD (1k / 5k / 10k)** | shortfall as % of supply | supplier A (50%) recovery min..max | B (25%) | C (15%) | D (10%) | worst single recovery | orders (of 24) with a short supplier | last-in-queue worst shortfall, % of supply |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 d | 100% of L0 | 0.00 / 0.00 / 0.00 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 0 d | 50% of L0 | 215.58 / 1,077.90 / 2,155.80 | **214.59 / 1,072.97 / 2,145.93** | 17.17% | 65.91%..100.00% | 31.81%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 17.17% |
| 0 d | 25% of L0 | 323.37 / 1,616.85 / 3,233.69 | **322.38 / 1,611.92 / 3,223.83** | 25.79% | 48.78%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 25.79% |
| 0 d | 0% (nothing) | 431.16 / 2,155.80 / 4,311.59 | **430.17 / 2,150.87 / 4,301.73** | 34.41% | 31.66%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 34.41% |
| 1 d | 100% of L0 | 0.07 / 0.37 / 0.74 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 1 d | 50% of L0 | 215.65 / 1,078.27 / 2,156.54 | **214.66 / 1,073.30 / 2,146.60** | 17.17% | 65.90%..100.00% | 31.80%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 17.17% |
| 1 d | 25% of L0 | 323.44 / 1,617.22 / 3,234.44 | **322.45 / 1,612.25 / 3,224.50** | 25.80% | 48.77%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 25.80% |
| 1 d | 0% (nothing) | 431.23 / 2,156.17 / 4,312.34 | **430.24 / 2,151.20 / 4,302.40** | 34.42% | 31.65%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 34.42% |
| 1 d | 100% of L(delay) | 0.00 / 0.00 / 0.00 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 7 d | 100% of L0 | 0.52 / 2.60 / 5.19 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 7 d | 50% of L0 | 216.10 / 1,080.50 / 2,160.99 | **215.06 / 1,075.30 / 2,150.61** | 17.20% | 65.85%..100.00% | 31.69%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 17.20% |
| 7 d | 25% of L0 | 323.89 / 1,619.44 / 3,238.89 | **322.85 / 1,614.25 / 3,228.51** | 25.83% | 48.73%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 25.83% |
| 7 d | 0% (nothing) | 431.68 / 2,158.39 / 4,316.79 | **430.64 / 2,153.20 / 4,306.40** | 34.45% | 31.61%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 34.45% |
| 7 d | 100% of L(delay) | 0.00 / 0.00 / 0.00 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 30 d | 100% of L0 | 2.23 / 11.13 / 22.26 | **1.02 / 5.09 / 10.17** | 0.08% | 99.84%..100.00% | 99.68%..100.00% | 99.46%..100.00% | 99.19%..100.00% | 99.19% | 24 | 0.08% |
| 30 d | 50% of L0 | 217.81 / 1,089.03 / 2,178.06 | **216.60 / 1,082.98 / 2,165.97** | 17.33% | 65.64%..100.00% | 31.29%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 17.33% |
| 30 d | 25% of L0 | 325.60 / 1,627.98 / 3,255.95 | **324.39 / 1,621.93 / 3,243.87** | 25.95% | 48.55%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 25.95% |
| 30 d | 0% (nothing) | 433.39 / 2,166.93 / 4,333.85 | **432.18 / 2,160.88 / 4,321.76** | 34.57% | 31.45%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 34.57% |
| 30 d | 100% of L(delay) | 0.00 / 0.00 / 0.00 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |

### PW30

**PW30, AVAX gap -75.0%** (L0 = 238.26 / 1,191.29 / 2,382.58 USDC for caps 1,000 / 5,000 / 10,000)

| delay | funding | unpaid debt, USD (cap 1k / 5k / 10k) | **exit shortfall, USD (1k / 5k / 10k)** | shortfall as % of supply | supplier A (50%) recovery min..max | B (25%) | C (15%) | D (10%) | worst single recovery | orders (of 24) with a short supplier | last-in-queue worst shortfall, % of supply |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 d | 100% of L0 | 0.00 / 0.00 / 0.00 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 0 d | 50% of L0 | 119.13 / 595.65 / 1,191.29 | **118.14 / 590.71 / 1,181.43** | 9.45% | 81.23%..100.00% | 62.46%..100.00% | 37.43%..100.00% | 6.15%..100.00% | 6.15% | 24 | 9.45% |
| 0 d | 25% of L0 | 178.69 / 893.47 / 1,786.94 | **177.71 / 888.54 / 1,777.07** | 14.22% | 71.77%..100.00% | 43.53%..100.00% | 5.89%..100.00% | 0.00%..100.00% | 0.00% | 24 | 14.22% |
| 0 d | 0% (nothing) | 238.26 / 1,191.29 / 2,382.58 | **237.27 / 1,186.36 / 2,372.72** | 18.98% | 62.30%..100.00% | 24.61%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 18.98% |
| 1 d | 100% of L0 | 0.03 / 0.14 / 0.28 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 1 d | 50% of L0 | 119.16 / 595.79 / 1,191.58 | **118.17 / 590.84 / 1,181.68** | 9.45% | 81.23%..100.00% | 62.45%..100.00% | 37.42%..100.00% | 6.13%..100.00% | 6.13% | 24 | 9.45% |
| 1 d | 25% of L0 | 178.72 / 893.61 / 1,787.22 | **177.73 / 888.66 / 1,777.33** | 14.22% | 71.76%..100.00% | 43.53%..100.00% | 5.88%..100.00% | 0.00%..100.00% | 0.00% | 24 | 14.22% |
| 1 d | 0% (nothing) | 238.29 / 1,191.43 / 2,382.87 | **237.30 / 1,186.49 / 2,372.97** | 18.98% | 62.30%..100.00% | 24.60%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 18.98% |
| 1 d | 100% of L(delay) | 0.00 / 0.00 / 0.00 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 7 d | 100% of L0 | 0.20 / 1.00 / 1.99 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 7 d | 50% of L0 | 119.33 / 596.64 / 1,193.29 | **118.32 / 591.61 / 1,183.22** | 9.47% | 81.20%..100.00% | 62.41%..100.00% | 37.35%..100.00% | 6.02%..100.00% | 6.02% | 24 | 9.47% |
| 7 d | 25% of L0 | 178.89 / 894.47 / 1,788.93 | **177.89 / 889.43 / 1,778.87** | 14.23% | 71.74%..100.00% | 43.49%..100.00% | 5.81%..100.00% | 0.00%..100.00% | 0.00% | 24 | 14.23% |
| 7 d | 0% (nothing) | 238.46 / 1,192.29 / 2,384.58 | **237.45 / 1,187.26 / 2,374.51** | 19.00% | 62.28%..100.00% | 24.56%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 19.00% |
| 7 d | 100% of L(delay) | 0.00 / 0.00 / 0.00 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 30 d | 100% of L0 | 0.85 / 4.27 / 8.55 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 30 d | 50% of L0 | 119.98 / 599.92 / 1,199.84 | **118.91 / 594.56 / 1,189.12** | 9.51% | 81.12%..100.00% | 62.24%..100.00% | 37.07%..100.00% | 5.60%..100.00% | 5.60% | 24 | 9.51% |
| 30 d | 25% of L0 | 179.55 / 897.74 / 1,795.48 | **178.48 / 892.38 / 1,784.77** | 14.28% | 71.66%..100.00% | 43.32%..100.00% | 5.54%..100.00% | 0.00%..100.00% | 0.00% | 24 | 14.28% |
| 30 d | 0% (nothing) | 239.11 / 1,195.57 / 2,391.13 | **238.04 / 1,190.21 / 2,380.41** | 19.04% | 62.21%..100.00% | 24.41%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 19.04% |
| 30 d | 100% of L(delay) | 0.00 / 0.00 / 0.00 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |

**PW30, AVAX gap -80.0%** (L0 = 392.58 / 1,962.90 / 3,925.79 USDC for caps 1,000 / 5,000 / 10,000)

| delay | funding | unpaid debt, USD (cap 1k / 5k / 10k) | **exit shortfall, USD (1k / 5k / 10k)** | shortfall as % of supply | supplier A (50%) recovery min..max | B (25%) | C (15%) | D (10%) | worst single recovery | orders (of 24) with a short supplier | last-in-queue worst shortfall, % of supply |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 d | 100% of L0 | 0.00 / 0.00 / 0.00 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 0 d | 50% of L0 | 196.29 / 981.45 / 1,962.90 | **195.30 / 976.52 / 1,953.03** | 15.62% | 68.97%..100.00% | 37.94%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 15.62% |
| 0 d | 25% of L0 | 294.43 / 1,472.17 / 2,944.34 | **293.45 / 1,467.24 / 2,934.48** | 23.48% | 53.38%..100.00% | 6.76%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 23.48% |
| 0 d | 0% (nothing) | 392.58 / 1,962.90 / 3,925.79 | **391.59 / 1,957.96 / 3,915.93** | 31.33% | 37.79%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 31.33% |
| 1 d | 100% of L0 | 0.06 / 0.32 / 0.63 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 1 d | 50% of L0 | 196.35 / 981.76 / 1,963.53 | **195.36 / 976.80 / 1,953.60** | 15.63% | 68.96%..100.00% | 37.93%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 15.63% |
| 1 d | 25% of L0 | 294.50 / 1,472.49 / 2,944.98 | **293.51 / 1,467.53 / 2,935.05** | 23.48% | 53.37%..100.00% | 6.74%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 23.48% |
| 1 d | 0% (nothing) | 392.64 / 1,963.21 / 3,926.42 | **391.65 / 1,958.25 / 3,916.50** | 31.33% | 37.78%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 31.33% |
| 1 d | 100% of L(delay) | 0.00 / 0.00 / 0.00 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 7 d | 100% of L0 | 0.44 / 2.22 / 4.44 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 7 d | 50% of L0 | 196.73 / 983.67 / 1,967.34 | **195.70 / 978.51 / 1,957.03** | 15.66% | 68.92%..100.00% | 37.84%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 15.66% |
| 7 d | 25% of L0 | 294.88 / 1,474.39 / 2,948.78 | **293.85 / 1,469.24 / 2,938.48** | 23.51% | 53.33%..100.00% | 6.66%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 23.51% |
| 7 d | 0% (nothing) | 393.02 / 1,965.12 / 3,930.23 | **391.99 / 1,959.96 / 3,919.92** | 31.36% | 37.74%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 31.36% |
| 7 d | 100% of L(delay) | 0.00 / 0.00 / 0.00 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |
| 30 d | 100% of L0 | 1.90 / 9.52 / 19.03 | **0.73 / 3.63 / 7.27** | 0.06% | 99.88%..100.00% | 99.77%..100.00% | 99.62%..100.00% | 99.42%..100.00% | 99.42% | 24 | 0.06% |
| 30 d | 50% of L0 | 198.19 / 990.96 / 1,981.93 | **197.02 / 985.08 / 1,970.16** | 15.76% | 68.74%..100.00% | 37.48%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 15.76% |
| 30 d | 25% of L0 | 296.34 / 1,481.69 / 2,963.37 | **295.16 / 1,475.80 / 2,951.61** | 23.61% | 53.17%..100.00% | 6.34%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 23.61% |
| 30 d | 0% (nothing) | 394.48 / 1,972.41 / 3,944.82 | **393.31 / 1,966.53 / 3,933.06** | 31.46% | 37.60%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00%..100.00% | 0.00% | 24 | 31.46% |
| 30 d | 100% of L(delay) | 0.00 / 0.00 / 0.00 | **0.00 / 0.00 / 0.00** | 0.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00%..100.00% | 100.00% | 0 | 0.00% |

Per-cap USD tables, per-order tables for every state: `avalanche-cash-only-treasury-evidence/tables/supplier-outcomes-per-cap.md` and `.../all-24-orders-every-state.md`.

## 8. Required assertions (all in the suite; no fairness threshold)
- Accounting identity `cash + borrows - reserves = sum of supplier claims` (8 wei) after every funded state and in every test state (`_identity`); value conserved by the exits (`sum received + cash left = cash before the exits`) in each of the 6,912 order runs (285 grid states x 24, plus 72 in the mitigation test).
- Loss = `D - C_after / LI` on the measured position in all 15 events; `debt - repaid by the liquidator = unrecoverable debt`.
- Equalities that distinguish the funding levels: `paid = min(budget, debt)`; `remaining debt = debt - paid` (accounts and total borrows); `total exit shortfall = max(0, remaining borrows - reserves)` in every order; `shortfall(funded) + repaid = shortfall(unfunded)`; funding `L(delay)` leaves 0.
- Repayment leaves exchange rate, claims and reserves unchanged (reserves within 8 wei: the shares-accounting reconcile moves them by rounding only; two failed attempts show the 2-wei difference).
- Detection-rule truth table (section 2.2), manipulated-oracle test, runbook gating.

## 9. Mutations
Applied through the environment variable `TREASURY_MUTATION` read by the test file's own logic (default 0; the hook is inert unless set), run against the **final 16-test suite** (baseline 16 of 16 pass). Logs: `avalanche-cash-only-treasury-evidence/mutation-M1-final-16tests.txt`, `...M2...`, `...M3...`; the counts below are copied from them:
| Mutation | Result |
| --- | --- |
| M1: the detector fires on shortfall alone (`TREASURY_MUTATION=1`: recoverable and not-yet-exhausted accounts also fire) | **3 of 16 tests fail**: the truth table, the runbook-gating test, and the new reference-tolerance boundary test (an agreeing-prices account reads "fire" instead of `UNRECOVERABLE_LIQUIDATE_FIRST`). The manipulated-oracle test no longer fails here because the divergence gate answers before the M1 branch is reached (it did fail in the earlier 14-test run, see below). The matrix tests pass, as expected: they only evaluate exhausted accounts |
| M2: the repayment is applied to the NEXT borrower instead of the named one (`TREASURY_MUTATION=2`) | **10 of 16 tests fail** (all six matrix tests, truth table, runbook gating, mitigations, late funding): "the NAMED account's debt fell by exactly the amount" and "the treasury paid exactly the amount" |
| M3: the detector without the reference-divergence gate (`TREASURY_MUTATION=3`) | **2 of 16 tests fail**: the reference-tolerance boundary test ("reference above, one wei beyond: fail closed") and the manipulated-oracle test (`LIQUIDATABLE_RECOVERABLE` instead of `PRICE_DIVERGENCE`); the other 14 pass |
Earlier runs against the 14-test suite (before the late-funding and reference tests): M1 3 failures (truth table, manipulated-oracle, runbook gating), M2 10 failures.

## 10. Not tested, and limits
- A fork fixture with **mocked feeds** and one funded liquidator; real feed behaviour and what an attacker could do to both the oracle and the reference at once are not tested; the reference source and tolerance are specified in 2.3.1 (the tolerance's boundary is tested, the source is read only in the separate 30-day study `avalanche-cash-only-risk-evidence/analysis/twap-vs-chainlink.py`).
- **Three identical-leverage borrowers** at 100% of power; different leverage, many borrowers, accounts holding USDC collateral, debt in both markets, the pWAVAX loss direction (not part of the pilot).
- Liquidation by one liquidator without competition or gas spikes; liquidation dust above USD 0.01; liquidators that stop before the collateral is exhausted (the account then stays `UNRECOVERABLE_LIQUIDATE_FIRST` and nothing is paid: a monitoring alert, not a treasury action).
- **Four suppliers in a single market** and exit orders where each supplier exits entirely; partial exits, re-deposits, suppliers entering after the event (the mint-pause mitigation is tested; their treatment if unpaused is not).
- Keeper mechanics beyond the fork tests (keeper document section 5): gas behaviour on a congested chain, nonce recovery after a dropped transaction, keeper host availability, the real Safe top-up flow (helper not built); the response targets are proposals.
- Reserves are treated as they are in the fixture (10% of interest); an admin `_reduceReserves` before exits would raise the shortfall by the amount withdrawn (measured in the earlier loss-handling suite, not re-run).
- The `cash + borrows - reserves` identity tolerance is 8 wei and the order-total tolerance 32 wei; rounding only.
- Everything uses the placeholder rate model; the post-event APR (2.8% to 6.3%) depends on it. Interest is the fixture's 1 block = 1 second.
- Block `99,200,000` data and a mocked-feed chain: the 12.00% / 12.22% APR and the 0.986% growth in 30 days are fixture facts, not forecasts.
- This document does not choose the caps, the candidate, the dust, the response times or who funds the treasury.

## 11. Evidence and reproduction
`docs/deployment-handoffs/avalanche-cash-only-treasury-evidence/` (README.md lists every attempt with its result; each log starts with UTC time, git HEAD, test-file sha256 and the exact command; failed attempts are kept). Evidence of record: `attempt10-final-full.txt` (14/14), `mutation-M1-detector-fires-on-shortfall-alone.txt`, `mutation-M2-repay-applied-to-wrong-account.txt`. Tables are generated by `analysis/tables.py LOG [section]` from the `TRP|` lines. Command (from `contracts/`; RPC `https://api.avax.network/ext/bc/C/rpc`, the cached pin block):

```
AVALANCHE_MAINNET_RPC_URL=<rpc> FOUNDRY_PROFILE=debt_accounting FOUNDRY_OUT=out_treasury FOUNDRY_CACHE_PATH=cache_treasury \
forge test --threads 1 --gas-limit 9000000000000000000 --match-contract AvalancheCashOnlyTreasuryRepayForkTest -vv \
--rpc-url <rpc> --compute-units-per-second 20 --fork-retries 10 --fork-retry-backoff 1000 \
--skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol --skip AvalancheBorrowFloorMarginFork.t.sol
```
Mutation runs add `TREASURY_MUTATION=1` or `2`. The test file is untracked, so the git HEAD in the logs does not pin it: use the sha256 in each log header and in the evidence README.

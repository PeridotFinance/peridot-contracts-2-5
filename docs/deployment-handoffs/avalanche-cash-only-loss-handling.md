# Cash-only lending: loss handling for unrecoverable debt (measured comparison, pilot and scale recommendation)

Status: **PROPOSAL backed by fork tests. Nothing here is an approved parameter. No production write-off is introduced: every write-off in this work is a TEST-ONLY prototype under `contracts/test/prototype/`; nothing under `contracts/contracts/` was changed, nothing was committed, signed, broadcast or deployed, no keys were used. Borrowing stays paused.** Product: cash-only lending markets **pUSDC (USDC)** and **pWAVAX (WAVAX)** on Avalanche C-Chain (plain delegates behind `PErc20Delegator`, no margin stack). Deposited asset per supplier: USDC suppliers deposit USDC, WAVAX suppliers deposit WAVAX; protection benchmark = holding the same asset (USDC suppliers: USDC; WAVAX suppliers: WAVAX). All loss cases below are measured on **pUSDC** (USDC debt against WAVAX collateral, direction W, which is the pilot direction of `avalanche-cash-only-decision-table.md`). The pWAVAX loss market (direction U) runs the same delegate code but was **not run** (section 12).

## 0. Summary and RECOMMENDATION

1. **Same event, same suppliers, four handlings.** A real liquidation shortfall (3 borrowers at 99% of borrowing power, AVAX -50% in one step, liquidated by a funded liquidator until their collateral is exhausted, CF 60% placeholder, LI 1.08) leaves **USDC 39,252.10 of unrecoverable debt** (22.0% of the USDC 178,200 borrowed; closed form `D x (1 - rho/LI)` reproduces it to 2 micro-USD) against pUSDC supplier deposits of USDC 601,000 (EARLY 100,000, LATE 100,000, BIG 400,000, SMALL 1,000).
2. **S0 (do nothing)**: exchange rate unchanged (2.000000), claims unchanged, the unpaid borrow is still counted as an asset. The loss lands on **whoever exits last**: shortfall = max(0, loss - reserves), LATE loses USDC 39,252.10 of its 100,000 while EARLY, SMALL and BIG are paid in full; in the reverse queue EARLY loses it instead.
3. **S1 (treasury `repayBorrowBehalf` of the unrecoverable debt)**: debt and total borrows go to zero, reserves and exchange rate untouched, **every supplier is paid in full in either order and at any time** (also after EARLY and SMALL already left). Cost to the treasury: exactly the loss (39,252.10). No code change.
4. **S2 (`_addReserves` of the same amount) is NOT repayment.** At t0 it also lets everyone exit, but the debt stays recorded and keeps accruing (+272.59 in 90 days at 6.5% market utilisation), the exchange rate and claims keep rising on interest nobody pays, the amount is booked as **protocol reserves** (admin can `_reduceReserves` it back out: shortfall returns to 39,252.10), the booked reserves are unbacked once suppliers have exited, and after 90 days the **exit shortfall reappears (USDC 245.33)** although the treasury paid the full loss. Section 5.
5. **S3 (reserve-first loss recognition, TEST-ONLY prototype)**: debt removed; reserves absorb first; only the remainder lowers the exchange rate for all suppliers pro rata at once. With no reserves the rate falls 2.000000 -> 1.869377 (every supplier keeps 93.47% of its claim, EARLY = LATE in either order, nobody is short at exit). With reserves = loss or more, suppliers recognise nothing. Two measured costs: (a) **the race window**: suppliers who exit before the write-off executes escape the whole loss and the remaining suppliers bear all of it (rate 1.842992 instead of 1.869377 when EARLY and SMALL leave first); (b) the recognised loss lowers the collateral value of any pUSDC holder who borrows against it (a 99%-levered holder falls into shortfall of USD 1,174 in the test).
6. **Unrestricted write-off power is a theft vector** (tested): an admin who borrows USDC 50,000 against healthy collateral and writes off its own loan keeps the cash and the collateral and every supplier's claim falls 8.32%. A per-call cap alone only needs more calls. The precondition (account in shortfall and no collateral worth recovering) stops it, but it reads the same oracle, so a manipulated price passes it; the per-call and per-period caps bound that damage. Required controls in section 9.
7. **Funding.** Every design that makes suppliers whole costs the protocol exactly the loss (`F = D x max(0, 1 - s/(CF x u x LI))`); the designs differ in who must hold the money when, whether it is permanent, and what happens if it is short. Reserves are not a backstop: measured accrual is USD 44 per USD 100,000 of borrows per month at about 27% market utilisation (reserve factor 10%), against a loss of 6,472 to 41,545 per 100,000 at the pilot's tails. Section 11 (evaluated at the candidates of the decision table).

**RECOMMENDATION (judgement from the measured identities; the operator decides).**
- **Pilot: S1, a dedicated pre-funded treasury account that repays defaulted accounts with the existing `repayBorrowBehalf`.** It needs no new contract code, uses audited functions, restores exactly the no-loss state (debt gone, rate flat, no phantom interest, no queue), is insensitive to timing and to exit order (tested), and cannot be reversed by an admin call. Rules: (1) the treasury (protection capital) is funded in USDC before borrowing is enabled, sized by the closed form on the borrow cap (section 11; `PW40`: USD 6,472 per 100,000 of cap at a -60% tail, 24,178 at -67.6%, 41,545 at -75%); (2) it is a separate ledger from withdrawal cash, liquidator inventory and operating funds; (3) runbook: after liquidation has exhausted an account's collateral, repay its remaining debt with `repayBorrowBehalf` from the treasury (`type(uint256).max` is the contract's full-repay sentinel; the tests pass the explicit current balance, which takes the same `repayBorrowFresh` path, so the sentinel call shape itself was not exercised); (4) **keep reserves in the market** (do not `_reduceReserves` while borrows are open), they do not absorb anything under S1 but they are protocol money that remains available; (5) if the treasury is smaller than the loss the remainder is S0 (queue loss on the last supplier, measured: half-funded treasury leaves USDC 19,626.05 on LATE), so **size the borrow cap to the funded treasury, not the other way round**. **S2 must not be used as a substitute for S1.**
- **Scale: S3, an explicit reserve-first write-off built into a new audited delegate, with the controls of section 9, combined with a treasury top-up path (`_addReserves` first, then write-off).** Reasons: it uses reserves already in the market with no operations, it degrades gracefully when funding is short (pro rata instead of a queue), it removes the debt (no phantom interest) and removes the per-account manual operation. Costs: new audited code in the debt-accounting path (shares mode), the race window, the recognition cascade on levered pUSDC holders, and a theft surface that the controls only bound. Do not adopt it for the pilot: it adds unaudited power over supplier funds to cover a situation the pilot can cover with an existing function and a funded account.

## 1. What was run
Fork suite `contracts/test/AvalancheCashOnlyLossHandlingFork.t.sol` (`AvalancheCashOnlyLossHandlingForkTest`, **32 tests, all pass**, attempt11), on the margin-free cash-only fixture `AvalancheCashOnlyBase` (pinned Avalanche C-Chain block 99,200,000, real tokens and Chainlink feeds with feeds mocked to move the price, plain `PErc20Delegate` markets behind `PErc20Delegator`). Prototype: `contracts/test/prototype/PErc20DelegateLossPrototype.sol`, installed with the delegator's `_setImplementation(impl, false, "")`.

- **Event.** Borrowers 0x9000..0x9002 each deposit USD 100,000 of WAVAX, enter markets and borrow USDC at 99% of borrowing power (total 178,200). AVAX x0.5 in one step; CAROL (funded) liquidates every borrower at the 50% close factor, shrinking the repay to what the remaining collateral pays, until the collateral is below USD 0.01. Result: repaid USDC 138,947.90, **unrecoverable debt 39,252.10 left on three accounts that have no collateral and stay in shortfall**.
- **Population (pUSDC, deposited asset USDC):** EARLY 100,000 and LATE 100,000 (identical deposits, differ only by queue position: in the forward run EARLY exits first and LATE last, in the reverse run the reverse), BIG 400,000 (the fixture's LP), SMALL 1,000. Total 601,000. Exit order forward: EARLY, SMALL, BIG, LATE.
- **As they exist in the repository:** reserve factor 10% (`RESERVE_FACTOR` 0.10), protocol seize share 2.8% (`protocolSeizeShareMantissa` 2.8e16, asserted), liquidation incentive 1.08, close factor 50%, collateral factor 60% (placeholder, not the pilot's 40%: the loss mechanics are independent of the CF; only the size of the loss depends on it), interest model 2% base, 1 block = 1 second.
- **Assertions** are accounting identities and the equalities that distinguish the designs (no fairness threshold): cash + borrows - reserves = sum of supplier claims in every state (within 8 wei), withdrawable <= min(claim, cash), value conserved (sum received + cash left = cash at the event + treasury inflow), exchange rate formula, and the per-design equalities listed in the sections below. Rounding tolerance 16 wei of USDC.
- **Important discovery about the fixture:** a market created by `PToken.initialize` starts in **shares borrow accounting** (`BorrowAccounting.state().enabled = true`). My first prototype handled only legacy accounting and 22 of 30 tests failed with its own "not supported" revert (attempt02, kept). The prototype was rewritten against the shares namespace (attempt04 onwards). Consequence for scope: section 10.

Output lines are `LOSS|ROW`, `LOSS|EXIT`, `LOSS|SUM` and rendered into the tables below by `avalanche-cash-only-loss-evidence/analysis/tables.py`. USDC amounts below are in USDC; `rate` is the pUSDC exchange rate divided by 1e14 (initial 2.000000); `claim` = pTokens x rate; `wd-now` = what that supplier alone could redeem now = min(claim, market cash). After the last supplier leaves, supply is zero and the rate prints as the initial rate.

## 2. The four handlings
| | What is done | Real function / code |
| --- | --- | --- |
| **S0** | nothing | none |
| **S1** | a treasury account repays each defaulted account's debt | `repayBorrowBehalf(account, amount)` (existing) |
| **S2** | the treasury adds the same amount as reserves | `_addReserves(amount)` (existing) |
| **S3** | the market admin writes the debt off; reserves absorb first; the remainder goes through the exchange rate | `writeOffBadDebt(account, amount)`, TEST-ONLY prototype subclass of `PErc20Delegate` |

## 3. The same event under each handling, step by step (no reserves in pUSDC, forward exit queue)
Reserves are zero here because a fresh fixture has none; sections 4 and 7 add reserves. "event" = right after the liquidations; "action" = after the handling; then each supplier's full exit attempt. All numbers are from `attempt12-final-full.txt`.

### Before and after the loss (common to all four)

| step | cash | recorded borrows | defaulted debt | reserves | rate | claim EARLY | claim LATE | claim BIG | claim SMALL | wd-now EARLY | wd-now LATE | wd-now BIG | wd-now SMALL |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| pre-loss | 422,800.00 | 178,200.00 | 178,200.00 | 0.00 | 2.000000 | 100,000.00 | 100,000.00 | 400,000.00 | 1,000.00 | 100,000.00 | 100,000.00 | 400,000.00 | 1,000.00 |
| post-liquidation | 561,747.90 | 39,252.10 | 39,252.10 | 0.00 | 2.000000 | 100,000.00 | 100,000.00 | 400,000.00 | 1,000.00 | 100,000.00 | 100,000.00 | 400,000.00 | 1,000.00 |

### S0 do nothing

| step | cash | recorded borrows | defaulted debt | reserves | rate | claim EARLY | claim LATE | claim BIG | claim SMALL | wd-now EARLY | wd-now LATE | wd-now BIG | wd-now SMALL |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| event | 561,747.90 | 39,252.10 | 39,252.10 | 0.00 | 2.000000 | 100,000.00 | 100,000.00 | 400,000.00 | 1,000.00 | 100,000.00 | 100,000.00 | 400,000.00 | 1,000.00 |
| action | 561,747.90 | 39,252.10 | 39,252.10 | 0.00 | 2.000000 | 100,000.00 | 100,000.00 | 400,000.00 | 1,000.00 | 100,000.00 | 100,000.00 | 400,000.00 | 1,000.00 |
| exit_early | 461,747.90 | 39,252.10 | 39,252.10 | 0.00 | 2.000000 | 0.00 | 100,000.00 | 400,000.00 | 1,000.00 | 0.00 | 100,000.00 | 400,000.00 | 1,000.00 |
| exit_small | 460,747.90 | 39,252.10 | 39,252.10 | 0.00 | 2.000000 | 0.00 | 100,000.00 | 400,000.00 | 0.00 | 0.00 | 100,000.00 | 400,000.00 | 0.00 |
| exit_big | 60,747.90 | 39,252.10 | 39,252.10 | 0.00 | 2.000000 | 0.00 | 100,000.00 | 0.00 | 0.00 | 0.00 | 60,747.90 | 0.00 | 0.00 |
| exit_late | 0.00 | 39,252.10 | 39,252.10 | 0.00 | 2.000000 | 0.00 | 39,252.10 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 |

| supplier | exit position | claim at exit | received | not received |
|---|---|---|---|---|
| early | 1 | 100,000.00 | 100,000.00 | 0.00 |
| late | 4 | 100,000.00 | 60,747.90 | 39,252.10 |
| big | 3 | 400,000.00 | 400,000.00 | 0.00 |
| small | 2 | 1,000.00 | 1,000.00 | 0.00 |

treasury paid in: 0.00; debt removed: 0.00; absorbed by reserves: 0.00; cash left after all exits: 0.00
### S1 treasury repays on behalf

| step | cash | recorded borrows | defaulted debt | reserves | rate | claim EARLY | claim LATE | claim BIG | claim SMALL | wd-now EARLY | wd-now LATE | wd-now BIG | wd-now SMALL |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| event | 561,747.90 | 39,252.10 | 39,252.10 | 0.00 | 2.000000 | 100,000.00 | 100,000.00 | 400,000.00 | 1,000.00 | 100,000.00 | 100,000.00 | 400,000.00 | 1,000.00 |
| action | 601,000.00 | 0.00 | 0.00 | 0.00 | 2.000000 | 100,000.00 | 100,000.00 | 400,000.00 | 1,000.00 | 100,000.00 | 100,000.00 | 400,000.00 | 1,000.00 |
| exit_early | 501,000.00 | 0.00 | 0.00 | 0.00 | 2.000000 | 0.00 | 100,000.00 | 400,000.00 | 1,000.00 | 0.00 | 100,000.00 | 400,000.00 | 1,000.00 |
| exit_small | 500,000.00 | 0.00 | 0.00 | 0.00 | 2.000000 | 0.00 | 100,000.00 | 400,000.00 | 0.00 | 0.00 | 100,000.00 | 400,000.00 | 0.00 |
| exit_big | 100,000.00 | 0.00 | 0.00 | 0.00 | 2.000000 | 0.00 | 100,000.00 | 0.00 | 0.00 | 0.00 | 100,000.00 | 0.00 | 0.00 |
| exit_late | 0.00 | 0.00 | 0.00 | 0.00 | 2.000000 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 |

| supplier | exit position | claim at exit | received | not received |
|---|---|---|---|---|
| early | 1 | 100,000.00 | 100,000.00 | 0.00 |
| late | 4 | 100,000.00 | 100,000.00 | 0.00 |
| big | 3 | 400,000.00 | 400,000.00 | 0.00 |
| small | 2 | 1,000.00 | 1,000.00 | 0.00 |

treasury paid in: 39,252.10; debt removed: 0.00; absorbed by reserves: 0.00; cash left after all exits: 0.00
### S2 `_addReserves` of the same amount

| step | cash | recorded borrows | defaulted debt | reserves | rate | claim EARLY | claim LATE | claim BIG | claim SMALL | wd-now EARLY | wd-now LATE | wd-now BIG | wd-now SMALL |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| event | 561,747.90 | 39,252.10 | 39,252.10 | 0.00 | 2.000000 | 100,000.00 | 100,000.00 | 400,000.00 | 1,000.00 | 100,000.00 | 100,000.00 | 400,000.00 | 1,000.00 |
| action | 601,000.00 | 39,252.10 | 39,252.10 | 39,252.10 | 2.000000 | 100,000.00 | 100,000.00 | 400,000.00 | 1,000.00 | 100,000.00 | 100,000.00 | 400,000.00 | 1,000.00 |
| exit_early | 501,000.00 | 39,252.10 | 39,252.10 | 39,252.10 | 2.000000 | 0.00 | 100,000.00 | 400,000.00 | 1,000.00 | 0.00 | 100,000.00 | 400,000.00 | 1,000.00 |
| exit_small | 500,000.00 | 39,252.10 | 39,252.10 | 39,252.10 | 2.000000 | 0.00 | 100,000.00 | 400,000.00 | 0.00 | 0.00 | 100,000.00 | 400,000.00 | 0.00 |
| exit_big | 100,000.00 | 39,252.10 | 39,252.10 | 39,252.10 | 2.000000 | 0.00 | 100,000.00 | 0.00 | 0.00 | 0.00 | 100,000.00 | 0.00 | 0.00 |
| exit_late | 0.00 | 39,252.10 | 39,252.10 | 39,252.10 | 2.000000 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 |

| supplier | exit position | claim at exit | received | not received |
|---|---|---|---|---|
| early | 1 | 100,000.00 | 100,000.00 | 0.00 |
| late | 4 | 100,000.00 | 100,000.00 | 0.00 |
| big | 3 | 400,000.00 | 400,000.00 | 0.00 |
| small | 2 | 1,000.00 | 1,000.00 | 0.00 |

treasury paid in: 39,252.10; debt removed: 0.00; absorbed by reserves: 0.00; cash left after all exits: 0.00
### S3 reserve-first write-off (no reserves, so suppliers recognise everything)

| step | cash | recorded borrows | defaulted debt | reserves | rate | claim EARLY | claim LATE | claim BIG | claim SMALL | wd-now EARLY | wd-now LATE | wd-now BIG | wd-now SMALL |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| event | 561,747.90 | 39,252.10 | 39,252.10 | 0.00 | 2.000000 | 100,000.00 | 100,000.00 | 400,000.00 | 1,000.00 | 100,000.00 | 100,000.00 | 400,000.00 | 1,000.00 |
| action | 561,747.90 | 0.00 | 0.00 | 0.00 | 1.869377 | 93,468.87 | 93,468.87 | 373,875.47 | 934.69 | 93,468.87 | 93,468.87 | 373,875.47 | 934.69 |
| exit_early | 468,279.03 | 0.00 | 0.00 | 0.00 | 1.869377 | 0.00 | 93,468.87 | 373,875.47 | 934.69 | 0.00 | 93,468.87 | 373,875.47 | 934.69 |
| exit_small | 467,344.34 | 0.00 | 0.00 | 0.00 | 1.869377 | 0.00 | 93,468.87 | 373,875.47 | 0.00 | 0.00 | 93,468.87 | 373,875.47 | 0.00 |
| exit_big | 93,468.87 | 0.00 | 0.00 | 0.00 | 1.869377 | 0.00 | 93,468.87 | 0.00 | 0.00 | 0.00 | 93,468.87 | 0.00 | 0.00 |
| exit_late | 0.00 | 0.00 | 0.00 | 0.00 | 2.000000 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 |

| supplier | exit position | claim at exit | received | not received |
|---|---|---|---|---|
| early | 1 | 93,468.87 | 93,468.87 | 0.00 |
| late | 4 | 93,468.87 | 93,468.87 | 0.00 |
| big | 3 | 373,875.47 | 373,875.47 | 0.00 |
| small | 2 | 934.69 | 934.69 | 0.00 |

treasury paid in: 0.00; debt removed: 39,252.10; absorbed by reserves: 0.00; cash left after all exits: 0.00

**Reading the tables.** S0: the unpaid borrow (39,252.10) is counted as an asset, so the rate and every claim stay at 100% while cash is 561,747.90: the last withdrawer finds 60,747.90 for a claim of 100,000. S1: borrows and defaulted debt vanish, cash rises by exactly the repayment, everything else is as before. S2: **cash and reserves rise by 39,252.10, but borrows and defaulted debt are unchanged**, so the exchange rate and claims are identical to S0; the exits succeed only because the treasury's cash is sitting in the market. S3: borrows and defaulted debt vanish with **no cash movement**, the rate falls to 1.869377, every claim falls by the same 6.53%, and all exits are paid in full from cash that is now a full backing of the reduced claims.

## 4. Early versus late withdrawal (same event, both queue orders)
Amounts received by each supplier of USDC (its claim at exit in brackets).
| Handling | Order | EARLY | LATE | BIG | SMALL | who bears the loss |
| --- | --- | --- | --- | --- | --- | --- |
| S0 | forward (EARLY first) | 100,000.00 | 60,747.90 (100,000) | 400,000.00 | 1,000.00 | LATE, alone: 39,252.10 |
| S0 | reverse (LATE first) | 60,747.90 (100,000) | 100,000.00 | 400,000.00 | 1,000.00 | EARLY, alone: 39,252.10 |
| S1 | forward and reverse | 100,000.00 | 100,000.00 | 400,000.00 | 1,000.00 | the treasury (39,252.10) |
| S2 (t0) | forward | 100,000.00 | 100,000.00 | 400,000.00 | 1,000.00 | nobody at t0; see section 5 (the shortfall returns) |
| S3 | forward and reverse | 93,468.87 | 93,468.87 | 373,875.47 | 934.69 | all suppliers pro rata (6.53% each); EARLY = LATE within 4 wei in both orders |

Measured identity (S0): shortfall = max(0, loss - reserves in the market), tested at reserves 0, loss/2, loss-1, loss and 1.5 x loss. **The queue position, not the size or identity of the supplier, decides who loses in S0**; BIG (400,000) and SMALL (1,000) are made whole simply because they were ahead of LATE. If the treasury (S1) or write-off (S3) acts only **after** EARLY and SMALL have left: S1 still makes BIG and LATE whole (tested, `testS1_RepaymentAfterEarlyExits...`, also S2); S3 does not (section 8.1).

## 5. S2 is not repayment: what differs, precisely
Measured on the same event (tests `testS2_AddReserves_IsNotRepayment_PreciseDifferences`, `testS2_Revocable...`, `testS2_ReservesUnbackedAfterExit...`, `testDrift90Days...`):

| Quantity (right after the action) | S0 | S1 `repayBorrowBehalf(39,252.10)` | S2 `_addReserves(39,252.10)` |
| --- | --- | --- | --- |
| market cash | 561,747.90 | 601,000.00 | 601,000.00 |
| total borrows | 39,252.10 | 0 | **39,252.10** |
| defaulted accounts' recorded debt | 39,252.10 | 0 | **39,252.10** |
| total reserves | 0 | 0 | **39,252.10** |
| exchange rate | 2.000000 | 2.000000 | 2.000000 (cash + borrows - reserves is invariant under `_addReserves`) |
| every supplier's claim | 100% | 100% | 100% (identical to S0: no supplier is credited) |
| what the admin can `_reduceReserves` | 0 | 0 | **all 39,252.10** (cash is there; restoring the S0 shortfall of 39,252.10 exactly) |
| can all suppliers exit at t0 | no (LATE short 39,252.10) | yes | yes |
| cash left after all suppliers exit | 0 | 0 | 0, but **recorded reserves 39,252.10 and recorded borrows 39,252.10 remain with no cash behind them** (`_reduceReserves(1)` reverts) |
| after 90 days: defaulted debt | 39,524.69 (+272.59) | 0 | **39,524.69 (+272.59)** |
| after 90 days: exchange rate / LATE claim | 2.000816 / 100,040.82 | 2.000000 / 100,000.00 | **2.000816 / 100,040.82** (inflated by interest on debt nobody pays) |
| after 90 days: reserves | 27.26 | 0 | 39,279.36 |
| after 90 days: exit shortfall (claims - cash) | 39,497.43 | 0 | **245.33 = interest x (1 - reserve factor): reappears although the treasury paid the full loss** |

Exact relations asserted: S2 drift shortfall = interest x (1 - 10%); reserves booked = 10% of the interest; S2 debt growth = S0 debt growth. The amount is **protocol reserves, not supplier-owned backing**: it protects suppliers only while it stays in the market and while the admin does not withdraw it; and it can be taken by suppliers' own redemptions (the cash is withdrawable by anyone). The minimum S2 amount that restores the t0 exit is loss - reserves (tested), but even then the debt ages: S2 is a temporary patch that needs a later S1 or S3 to clean the books.

**Treasury sizes (S1 and S2).** Loss 39,252.10, reserves 0, LATE's loss at exit: S1 with 19,626.05 (half): 19,626.05; 39,252.10: 0; 58,878.15: 0 (treasury pays only the recorded debt, 39,252.10, the rest stays with the treasury). S2 with 19,626.05: 19,626.05; 39,252.10: 0; 58,878.15: 0 (the extra 19,626.05 remains as real reserve cash). Rule: LATE's loss = max(0, loss - reserves - treasury amount), for both; the difference is what the amount becomes.

## 6. Reserve exhaustion (loss below, equal to, above reserves)
Reserves seeded in pUSDC **before the gap** (`_addReserves` by a separate seeder; this is pre-loss capital, distinct from S2 which is a post-loss action), then the same event. Loss L = 39,252.10. LATE's loss = what LATE does not receive in the forward queue; rate after = exchange rate after the handling.
| Reserves R | relation | S0: LATE's loss | S3: reserves used | S3: recognised by suppliers | S3: rate after | S3: each supplier keeps | S3: reserves left |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | R < L | 39,252.10 | 0 | 39,252.10 | 1.869377 | 93.47% | 0 |
| 19,626.05 (L/2) | R < L | 19,626.05 | 19,626.05 | 19,626.05 | 1.934689 | 96.73% | 0 |
| L - 1 wei | R < L by 1 | 1 wei | L - 1 wei | 1 wei | 1.99999999999667 | 100% | 0 |
| 39,252.10 (L) | R = L | 0 | 39,252.10 | 0 | 2.000000 | 100% | 0 |
| 58,878.15 (1.5 L) | R > L | 0 | 39,252.10 | 0 | 2.000000 | 100% | 19,626.05 |

In S0 with R >= L the last supplier is whole because the reserve cash itself is paid out to suppliers (cash left after all exits = R - L; the recorded reserves R remain on the books with that cash behind them). In S3 the reserves are consumed by the write-off. For S1, S2 the corresponding treasury sizes are in section 5. Cross-check of all four on the same events with R = 30% of L (11,775.63) and R = 150% of L (`testCross_*`): S0 LATE loses 27,476.47 and 0; S3 recognises 27,476.47 (rate 1.908564) and 0; S1 and S2 treasury 39,252.10 in both (S2 books reserves 51,027.73 and 98,130.25).

**Net protocol outlay is the loss in every design that keeps suppliers whole.** With R = 30% of L: S1 treasury pays 39,252.10 and R (11,775.63) stays as protocol reserves; S3 + top-up (`_addReserves` of L - R = 27,476.47, then write-off) consumes the R too, treasury pays 27,476.47 and reserves go to 0. Treasury + reserves given up = 39,252.10 in both (asserted) and suppliers receive identical amounts in both (within 1 wei). The advantage of S3 is that reserves already in the market can be used for it; S1 cannot apply them to the debt.

## 7. Interest on bad debt over 90 days (7,776,000 blocks)
| | S0 | S2 | S1 | S3 |
| --- | --- | --- | --- | --- |
| defaulted accounts' debt | 39,524.69 (+272.59, +0.69%, about 2.8% a year at the 6.5% market utilisation after the event) | 39,524.69 | 0 | 0 |
| reserves | 27.26 (10% of the interest) | 39,279.36 | 0 | 0 |
| exchange rate (event: 2.000000) | 2.000816 | 2.000816 | 2.000000 | 1.869377 (flat after the recognition) |
| LATE claim | 100,040.82 | 100,040.82 | 100,000.00 | 93,468.87 |
| cash | 561,747.90 | 601,000.00 | 601,000.00 | 561,747.90 |
| claims - cash | 39,497.43 | 245.33 | 0 | 0 |

S0 and S2 keep a zombie asset that grows and credits suppliers (and 10% reserves) with interest that is never paid; S1 and S3 do not. The size is small here because the market is lightly utilised after the event; it grows with the borrow rate (a higher utilisation, or the jump region of the rate model, makes it proportionally larger).

## 8. S3 in detail
### 8.1 Semantics prototyped and tested
`writeOffBadDebt(account, amount)` (market admin only): (1) `accrueInterest()` first (test `testS3_AccruesInterestFirst...`: after 30 idle days the write-off uses the current debt, a stale-amount write-off leaves the accrued interest on the account); (2) shares borrow accounting only; (3) **precondition**: the account has debt, is in shortfall (`getAccountLiquidity`), and the oracle value of its pToken balances in **every listed market** is at most USD 1 (`MAX_RESIDUAL_COLLATERAL_VALUE`; the liquidation loop stops at USD 0.01 dust, so a strict zero would fail the real case); (4) caps; (5) the account's borrow shares, `totalShares` and `totalBorrows` fall and the legacy snapshot is kept consistent; (6) **reserve-first**: `fromReserves = min(removed, totalReserves)`, only `removed - fromReserves` reaches the exchange rate `(cash + borrows - reserves) / supply`; (7) event `BadDebtWrittenOff(account, amount, absorbedByReserves, recognisedBySuppliers, rateBefore, rateAfter, totalBorrowsAfter, totalReservesAfter)` (the event test checks the split sums to the loss and to the reserves absorbed first).

Asserted: debt of every written-off account is 0; cash unchanged; `rate = (cash + borrows_after - remaining reserves) / supply` (independent expectation); sum of claims falls by exactly the recognised part, each supplier's claim falls pro rata to its pTokens; EARLY and LATE receive the same in both queue orders; no pToken is created or burned.

### 8.2 The race window (a real cost of S3)
S3 recognises the loss pro rata **from the block of the write-off**. Between the event and the write-off the market is S0: EARLY and SMALL exit at full claim (test `testS3_ExitsBeforeTheWriteOff...`), then the write-off hits only LATE and BIG: the rate falls to 1.842992 (not 1.869377), LATE 92,149.58 and BIG 368,598.32 bear the **whole** 39,252.10 and EARLY lost nothing; among the remaining holders it is pro rata (equal ratio within 1e-9). A timelock on the write-off call itself would create exactly this window. The window is closed by acting before anyone can react (a narrowly authorised executor inside caps) or by S1/S3-with-top-up where the treasury has already funded the loss. S1 has no such window (section 4).

### 8.3 Recognition cascade
A 99%-levered holder of pUSDC (USDC 30,000 supplied and entered as collateral at CF 75% placeholder, WAVAX borrowed to 99% of its power after the event) is healthy under S0 and S1 (the rate does not move) and **falls into shortfall of USD 1,174.14 after the S3 recognition** (`testS3_Recognition_PushesALeveragedSupplier...`). This is not a defect of S3, it is the loss becoming visible; liquidation of such accounts follows the normal path (they now owe what the collateral no longer covers). In the pilot (`PW40`) USDC has collateral factor 0%, so no pUSDC holder can borrow against it and this cascade does not exist; at scale with USDC collateral it must be modelled.

### 8.4 Seize share and real reserves
The 2.8% protocol seize share is booked in the **collateral** market: the liquidations put **982.56 WAVAX (USD 4,200.00 at the shocked price, 10.7% of the loss)** into pWAVAX `totalReserves`; pUSDC reserves stay 0 (asserted). Reserve-first in pUSDC absorbs 0 of the USDC loss from it (asserted, pWAVAX reserves untouched). Using it would take `_reduceReserves` in pWAVAX, a swap WAVAX -> USDC and `_addReserves` in pUSDC (off-chain steps with swap cost and slippage that were **not** measured; the 10.7% is an oracle-value upper bound).
Reserve-factor accrual before the gap, measured (30 days at 90% borrower utilisation, market utilisation about 27%): pUSDC reserves 71.49 on borrows of 162,714.94, exactly 10% of the interest charged (asserted within 2 wei). The gap loss in that run is 23,767.04, **332 times the reserves**: S0 LATE loses about 23,695.5; S3 absorbs the 71.49 and the suppliers recognise the remaining 23,695.5 (rate 2.002141 -> 1.923288).

## 9. Controls and the theft vector
| Test | Result |
| --- | --- |
| non-admin caller; amount 0; amount > recorded debt; account without debt | each reverts with its own message |
| healthy account (collateral and debt at current prices) | reverts `account is not in shortfall` |
| account in shortfall that still has collateral | reverts `collateral remains: liquidate first` |
| per-call cap 10,000 | a 13,084 write-off in one call reverts; 10,000 passes; the rest in a later call |
| per-period cap 15,000 per day | the call that would exceed it reverts; after one day the counter restarts |
| **unrestricted** (precondition off, no cap): admin deposits USD 100,000 of WAVAX, borrows 50,000 USDC, writes off its own loan, redeems the collateral | admin keeps 50,000 USDC **and** its collateral; reserves 0 so the rate falls 2.0000 -> 1.8336; every supplier loses 8.32% (EARLY 100,000 -> 91,680.53) |
| same call with the precondition in the bytecode | reverts `account is not in shortfall` |
| precondition off, per-call cap 10,000 only | the same 50,000 is taken in 5 calls: **a per-call cap alone is not a control** |
| precondition on, no cap, **price of the collateral manipulated to 1 wei** (mock) | the precondition is satisfied, 50,000 written off: the precondition is only as strong as the oracle and its governance |
| precondition on, caps 10,000 / 15,000 per day, same manipulation | only 15,000 can be forgiven in the period; 35,000 remains recorded |

**Required controls for any production write-off**: (1) the controls are **bytecode** (immutables, not admin-settable flags), so loosening them needs a new implementation through the timelocked `_setImplementation`; (2) the precondition (shortfall and no recoverable collateral in any listed market) is mandatory, not optional; (3) a per-call and a per-period cap sized to the stress loss of the market (section 11), so a compromised or colluding admin plus a manipulated oracle is bounded to the period allowance; (4) the event with the split; (5) the admin of the market is a timelock for installing/changing the implementation, but the execution role must **not** be slowed by a timelock when it acts within caps (race window 8.2), and must be a different key from whoever can set the oracle or the collateral factors; (6) reserve-first is not optional: without it suppliers pay a loss that protocol money could have taken (mutation M1/M2).

## 10. IMPLEMENTATION SCOPE of the recommended scale design (not built)
- **New code (audited scope):** one new delegate implementation extending `PErc20Delegate` with the write-off function, the precondition, the caps (immutables) and the event, plus the period counter in an ERC-7201 namespaced slot. The prototype is about 100 lines of logic. **Shares accounting is mandatory**: new markets start with `BorrowAccounting.state().enabled = true`; the stock `BorrowAccountingModule` has **no forgiveness path** (`setShares` is reachable only from repay and its reconcile rule forbids forgiving another borrower's debt). The prototype writes the shares and `totalShares` directly from the implementation; for production, route it through a new, reviewed function of `BorrowAccountingModule` so the share rounding and reserve reconciliation stay in one place (not tested). A market still on legacy per-account snapshots is not handled.
- **Files in audited scope:** the new delegate; `BorrowAccountingModule.sol` if the write-off is added there; the deployment/upgrade script for `_setImplementation`. **Not changed:** `PToken.sol`, `PErc20.sol`, `PErc20Delegator.sol`, `Peridottroller*.sol` (the precondition uses existing views: `getAccountLiquidity`, `getAllMarkets`, `oracle`, `getAccountSnapshot`). Size of the new implementation against the release size limit (`BorrowAccountingReleaseSize.t.sol`) was **not** checked.
- **Storage compatibility for plain delegates via `_setImplementation`:** no state variable is appended; control parameters are immutables, the period counter is in the namespaced slot. Tested (`testInstall_...UpgradePreservesEveryStorageSlot`): across the upgrade **exactly one proxy storage slot changes (the implementation pointer, slot 20)**, the 96 slots 0..95, the borrow-accounting namespace and all balances are identical, ordinary mint/redeem works, and the old implementation can be put back. `forge inspect storageLayout` of `PErc20Delegate` and the prototype: same 23 entries, same labels, slots and offsets (`storage-layout-comparison.txt`). Install with **empty** `becomeImplementation` data: non-empty data re-runs `activateBorrowAccounting` and reverts `BorrowAccountingAlreadyEnabled` on a market that already has shares accounting (seen in a draft test).
- **Interaction with liquidation:** the write-off is a last step after liquidation; the precondition makes it impossible while collateral is left and the account is not in shortfall. It does not change `liquidateBorrow`, the close factor or incentive. The 2.8% seize share stays in the collateral market and cannot absorb the loss without the manual cross-market path (8.4). Liquidation dust below USD 1 may remain on a written-off account; a later deposit by that address starts a clean account (the loss is crystallised, there is no record of a receivable in this prototype).
- **Governance and operations:** timelock on implementation/config; narrow executor within caps; runbook to write off only accounts that liquidation has exhausted; the event feeds monitoring; a treasury top-up (`_addReserves`) before the write-off keeps suppliers whole (section 6).
- **Interaction with S1:** both can coexist (S1 as manual pilot procedure, S3 later); a treasury `repayBorrowBehalf` on the same account first makes the write-off unnecessary for it.

## 11. REQUIRED FUNDING
Closed form (risk proposal, reproduced to 2 micro-USD by this suite's event): **loss = D x max(0, 1 - s / (CF x u x LI))**, `D` the borrowed debt of the affected direction, `s` the factor by which the collateral/debt value ratio changes (AVAX fall x: s = 1 - x), `u` borrower utilisation of borrowing power, `LI` 1.08. In every design that keeps suppliers whole the protocol gives up exactly this amount: S1 funds it from the treasury, S3 uses reserves first and the treasury for `loss - reserves`, S2 funds it only temporarily (section 5). **Required funding = D_cap x loss share at the tail the operator chooses, minus nothing for reserves in the pilot** (reserves are replenishment: USD 44 per 100,000 of borrows per month measured at about 27% utilisation).

`avalanche-cash-only-decision-table.md` exists; evaluated at its candidates (USD per **100,000 of USDC borrow cap**, direction W, u = 99%, LI = 1.08; its section D):
| Candidate | CF | tail -60% | tail -67.6% (year drawdown) | tail -75% | as share of a USDC supply of 125,000 at -75% |
| --- | --- | --- | --- | --- | --- |
| PW30 | 30% | 0 | 0 | 22,060 | 17.6% |
| **PW40 (recommended in that table)** | 40% | **6,472** | **24,178** | **41,545** | 33.2% |
| PW50 | 50% | 25,178 | 39,343 | 53,236 | 42.6% |
| placeholder 60/75 (measured in this suite at -50%: 22.0%) | 60% | 37,648 | 49,452 | 61,030 | 48.8% |
So S1's treasury for the pilot candidate is **USD 6,472 per 100,000 of cap at a -60% tail** (the decision table's USD 6,500 for a 100,000 cap), 24,178 / 41,545 at the deeper tails. Utilisation matters: at CF 40% a borrower at u = 90% has loss 0% / 16.7% / 35.7% at -60% / -67.6% / -75% (u = 75%: 0 / 0 / 22.8%). Without that funding the same event is S0 or S3 recognition: at PW40 and a -75% tail on a 100,000 cap the loss is 41,545 of supplier deposits of about 125,000, i.e. a 33% haircut recognised by S3 or taken by the last 33% of the queue in S0. **Cap the borrow to the funded protection capital**: `D_cap <= protection capital / loss share at the chosen tail` (decision table section E: USD 41,359 of cap per 10,000 of capital at -67.6%, 24,070 at -75% for PW40).
The treasury must hold the debt asset: USDC for the pUSDC loss market. For a future pWAVAX loss market (direction U) it would be WAVAX (not measured here).

## 12. Statement and what was not tested
**No production write-off is introduced.** `PErc20DelegateLossPrototype` exists only under `contracts/test/prototype/`; it is imported only by the new test; no file in `contracts/contracts/`, no script and no deployment references it. The recommended scale design is a design, not code in the repository. The pilot recommendation needs no new code.

Not tested (each could change a number or a conclusion):
- the **pWAVAX loss market** (WAVAX debt against USDC collateral); only pUSDC was run (the delegate code is the same);
- **legacy (non-shares) borrow accounting** markets for the write-off (the prototype reverts there);
- writing off accounts with **debt in both markets** or collateral in a third asset; partial liquidations followed by a write-off; **many defaulted accounts** (gas of a batch; the single-call gas was not isolated);
- the **bytecode size** of a production delegate with the write-off, the production routing through `BorrowAccountingModule`, ERC-20 hooks/reentrancy, and a hostile oracle other than the mocked 1-wei price;
- a market with **healthy borrowers outstanding** was tested only once (HB: cash gap equals the healthy debt, loss gap equals loss - reserves, verified); redemption blocked by the borrow cash floor (the floor limits borrows only);
- swap cost/slippage and delay when converting the pWAVAX seize reserve to USDC; time-varying utilisation after the event (drift measured at one utilisation, 6.5%); the real block time (1 s blocks in the rate model);
- **supplier interest**: the event is run in one block, so suppliers earned nothing, and "protection benchmark = holding USDC" compares claims with deposits at the event; interest earned before the event is not modelled except in the 30-day run;
- fairness of a recognised loss for suppliers who deposited **after** the event: under S0 a new depositor enters at the unreduced rate and is exposed to the queue; not asserted.

## 13. Evidence and reproduction
`docs/deployment-handoffs/avalanche-cash-only-loss-evidence/` (README.md lists each attempt; each log starts with UTC time, git HEAD and the exact command; failed attempts are kept). Evidence of record: `attempt12-final-full.txt` (32/32). Command (from `contracts/`): `AVALANCHE_MAINNET_RPC_URL=<rpc> FOUNDRY_PROFILE=debt_accounting FOUNDRY_OUT=out_loss FOUNDRY_CACHE_PATH=cache_loss forge test --threads 1 --gas-limit 9000000000000000000 --match-contract '^AvalancheCashOnlyLossHandlingForkTest$' -vv --rpc-url <rpc> --compute-units-per-second 20 --fork-retries 10 --fork-retry-backoff 1000 --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol --skip AvalancheBorrowFloorMarginFork.t.sol`.

**Mutation checks on the prototype (each applied, the full suite run, then the file restored). Failure counts are "of 29" tests (the suite at that time; the three tests added afterwards do not touch the prototype's logic except M4's re-run, which used the 30-test suite):**
| Mutation | Result |
| --- | --- |
| M1 reserves not reduced (suppliers absorb everything) | 6 tests fail (grid, cross 30% and 150%, event split, real reserve factor, top-up) |
| M2 suppliers first (`fromReserves = 0`) | the same 6 fail |
| M3 precondition removed | 2 fail (preconditions, strict-reverts-on-healthy-loan) |
| M4 accrual removed | **survived the first 29 tests**; the test `testS3_AccruesInterestFirst...` was added; with it 1 test fails (kept as two logs) |
| M5 caps removed | 3 fail |
| M6 admin check removed | 1 fails |
Test file sha256 (untracked): see the evidence README.

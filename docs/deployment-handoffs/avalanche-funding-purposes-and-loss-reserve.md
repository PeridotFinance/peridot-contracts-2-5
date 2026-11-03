# Avalanche: funding purposes, seeded loss reserve, affordable allocation

Status: ANALYSIS for an operator decision. **No production parameter is chosen or approved**; 50% retention and 75-90% allocation are *scenarios to evaluate*, as instructed. Nothing here changes a cap, a contract, a deployment or a launch gate. Product names are used (cash-only lending, Pharaoh vaults, Pharaoh allocation = the paired WAVAX/USDC strategy behind the lending markets, not built, margin trading = paused).

## 0. What "current caps" means on this chain (stated first because it limits every number below)
- Pharaoh vaults: live `depositCap` is 1 wei on both; nothing to size.
- Cash-only lending: **no production supply or borrow cap exists** (the repository has placeholders used for measuring: WAVAX borrow cap 20,000, USDC 500,000). Handoff 09 says caps come from the capacity analysis and are small at launch.
- Pharaoh allocation: not built; no cap.
So "affordable allocation at the current caps" cannot be evaluated against an existing production number. The calculation below is therefore expressed per unit of supplier cash S (in percent of S), which holds for any cap, and the operator supplies S.

## 1. Four funding purposes, never counted twice
| Purpose | What it is | Where it lives | Funded by | Protects | Must NOT be used for |
| --- | --- | --- | --- | --- | --- |
| **Supplier withdrawal cash** | cash the markets keep available for redemptions and recovery | the markets' own cash, protected by the **borrow cash floor** (new borrows cannot take cash below it) | suppliers' deposits that are simply not lent out or allocated | exits and recoveries needing cash | covering losses; it is not capital, it is cash that belongs to suppliers |
| **Loss reserve ("protection capital")** | first-loss capital: seed contributed by the operator, then a retained share of collected strategy income | a **separate ledger**, never part of ordinary supplier deposits, of the pToken exchange rate, of market cash or of the withdrawal-cash floor, until a loss is drawn against it | operator seed + retention (scenario: 50% of income net of entitlements) | suppliers against strategy loss and bad debt, up to its size | operating costs, liquidator inventory, reward entitlements |
| **Operating expenditure** | hosting, RPC, keeper gas, monitoring (`avalanche-operating-cost-estimate.md`: cents per transaction, hosting reused) | paid from the operator's operating budget or an explicit fee line | operator / explicit fee | running the system | being drawn from the loss reserve or supplier cash |
| **Funded-liquidator capital** | debt-asset inventory a liquidator needs to repay debt in a gap (risk proposal) | the liquidator's own wallet(s) | liquidator operator | liquidations happening | being counted as the reserve or as withdrawal cash |
**No-double-counting rule:** one unit of any asset has exactly one purpose at a time. The seed counts once (loss reserve); a floor of cash left in a market counts once (withdrawal cash); liquidator inventory counts once. A coverage check that adds them together is wrong by construction. Rewards: pending PHAR entitlements and quarantined intervals (`avalanche-vault-phar-entitlement-proposal.md`) belong to holders and are outside all four purposes: **they cannot be drawn to cover a loss**, and retention is taken from income only after attributed entitlements.

Income waterfall (scenario): collected strategy income -> (1) attributed reward entitlements stay with holders (unresolved/quarantined amounts stay quarantined) -> (2) operating costs, if an explicit fee line is chosen -> (3) retention to the loss reserve (scenario 50% of what remains) until a target -> (4) the rest to suppliers.

## 2. Strategy loss the reserve must absorb (Pharaoh allocation; closed-form, no fees, instantaneous move, oracle-valued)
For a **full-range** position the value in the supplier's own unit is the square root of the price ratio, so a USDC supplier loses `1 - sqrt(1 - X)` of the allocated notional when AVAX falls by X (and a WAVAX supplier loses `1 - 1/sqrt(r)` when AVAX is multiplied by r). Simple wide ranges lose more in the same move (computed for a 4x range [p0/4, 4p0] and a 2x range [p0/2, 2p0]):

| AVAX move | full range | 4x wide | 2x wide |
| --- | --- | --- | --- |
| -20% | 10.6% | 11.1% | 11.9% |
| -30% | 16.3% | 17.7% | 19.6% |
| -40% | 22.5% | 25.1% | 28.7% |
| -50% | 29.3% | 33.6% | 39.6% |
| -60% | 36.8% | 43.5% | 51.7% |
| -70% | 45.2% | 55.5% | 63.8% |
(loss as a share of the strategy notional, USDC-denominated, measured against holding USDC). WAVAX suppliers (full range): AVAX x1.5 -> 18.4%, x2 -> 29.3%, x3 -> 42.3%, x4 -> 50.0%. Wider ranges are NOT safer; they simply have a smaller leverage on the move, and they do not resolve deposit fairness, reward entitlement or exit issues (those come from the minting rule, the gauge's claim rules and pool liquidity respectively).

## 3. Minimum seed and affordable allocation (full range, USDC suppliers; R = seed as a share of supplier cash S)
`R_min = a x loss(X)`, `a_affordable = min(cap_a, R / loss(X))`.

Minimum seed to hold an allocation a through a shock X:
| allocation a | AVAX -30% | AVAX -50% | AVAX -70% |
| --- | --- | --- | --- |
| 75% | 12.3% of S | **22.0% of S** | 33.9% of S |
| 90% | 14.7% of S | **26.4% of S** | 40.7% of S |

Affordable allocation for a given seed (capped at the 90% scenario ceiling):
| seed R (% of S) | -30% shock | -50% shock | -70% shock |
| --- | --- | --- | --- |
| 2% | 12% | 7% | 4% |
| 5% | 31% | 17% | 11% |
| 10% | 61% | 34% | 22% |
| 15% | 90% | 51% | 33% |
| 20% | 90% | 68% | 44% |
| 25% | 90% | 85% | 55% |
| 30% | 90% | 90% | 66% |
**Reading:** surviving a 50% AVAX fall with 75-90% of supplier cash allocated needs protection capital of about 22-26% of S; a 30% fall needs 12-15%. A 5% seed supports roughly 17% allocation against a 50% shock, not 75%. The allocation is therefore bounded by the protection capital, not by the strategy's yield. Stronger APR is not a substitute: it only shortens the build time (below) and does nothing for a loss that arrives before the reserve is built.

Building the reserve from retained income alone (retention 50% of income on the allocated amount, `years = loss / (0.5 x y)`): at yield y = 20% a -30% target takes 1.6 years and a -50% target 2.9 years; at 10%: 3.3 and 5.9 years; at 5%: 6.5 and 11.7 years. **Yields are not measured here (no yield or PHAR price was measured on this chain); y is an assumption.** During the build the unfunded gap is the operator's seed decision: with a thin seed the allocation must start lower and rise as the reserve grows (allocation ratchet), rather than starting at 75-90% and relying on income.

Limits of this arithmetic: fees ignored (they reduce the loss), instantaneous gap (no path dependence, no rebalancing), full-range/closed-form (the real vault's position and its haircut valuation differ), oracle-valued, one asset side, no correlation with lending bad debt (the lending part is in `avalanche-cash-only-risk-proposal.md`), and no cost of unwinding in a thin pool (the pool's sell side is a wall: about USD 98.5k of USDC in total at the pin, see the capacity matrix), so an unwind during a shock realises more than the closed form.

## 4. What happens when protection is exhausted
Coverage ratio `c = R / (a x S x loss(X*))` for a chosen stress X*. Rules (proposed, not implemented):
| State | Condition | Behaviour |
| --- | --- | --- |
| Covered | c >= 1 | normal operation |
| Thin | 0.5 <= c < 1 | **no increase of allocation**; new deposits stay in the cash side; new borrowing keeps working only up to the cash floor; alert |
| Impaired | c < 0.5 (or reserve below the largest tested single-shock loss) | allocation ratchets down as pool liquidity permits; **new borrows paused** (new risk), repayment, liquidation and withdrawals continue; seed owner cannot withdraw seed |
| Exhausted | a loss exceeds the reserve | the excess must be **recognised immediately and pro rata** to suppliers at an oracle mark; no one waits to see it; **no new risk** of any kind (no allocation, no borrow, no new deposits into the strategy) until coverage is rebuilt; withdrawals continue at the marked value or as the in-kind mixture/claim (optional emergency exit, accepted by the operator). **Caveat, measured (section 4a): the plain lending markets in the repository do NOT recognise a loss this way today** |
**Fair loss recognition requires one valuation basis for entry, exit and the in-kind payout.** The F-IK-2 investigation shows what happens otherwise: the vault mints against a haircut NAV but pays real tokens in kind, which silently transfers value between depositors (incumbent -1,131 ppm, newcomer gain up to +20.8% of a small deposit after execution costs in the tested states). A loss recognised in a NAV that exit does not use gives first-mover advantage to whoever exits first; the reserve accounting must use the same mark for minting, redeeming and in-kind payouts.

### 4a. Correction from the lending risk study: plain markets have no loss recognition
An earlier draft of this document, and the requirement above, assume a loss is shared pro rata through the exchange rate. The risk study (`avalanche-cash-only-risk-proposal.md`, section 5; fork suite `AvalancheCashOnlyRiskStudyFork.t.sol`) measured what the plain markets actually do: **there is no write-off function** in `PToken`, `PErc20` or the controller. The unpaid borrow stays on the books and the exchange rate does not move (measured 2.0e14 before and after). The loss appears only as an exit shortfall that is **first-come-first-served**: suppliers who withdraw early are made whole from market cash, the last suppliers of the debt asset find the cash missing. Measured identity: shortfall = max(0, loss - reserves held in that market). So for lending bad debt today:
- "fair loss recognition" does not exist and would need NEW code (a write-off / loss socialisation that moves the exchange rate), which is not written or tested;
- the two backstops that need no new code and were tested are a treasury `_addReserves` into the loss market and a treasury `repayBorrowBehalf` for the exhausted accounts (the latter also restores a full exit);
- reserve-factor interest is far too slow to be the backstop: 1.2% to 2.7% of borrows per year at the placeholder rate shape (0.4% to 9.2% across three synthetic shapes), so one -50% gap would take about 19 years of reserves to cover;
- the placeholder collateral factors (60% WAVAX, 75% USDC) are **not gap-safe at maximum borrow**: 60% survives an AVAX fall of about 36% (loses 22% of the debt at -50%); 75% USDC survives a rise of about 25% (loses 38% of the debt at +100%). Largest zero-bad-debt collateral factor at 99% of borrowing power and incentive 1.08: 74.8% at -20%, 65.5% at -30%, 56.1% at -40%, 46.8% at -50%, 37.4% at -60%; 74.8% at +25%, 62.4% at +50%, 46.8% at +100% (synthetic grid on a mocked-feed fixture; caveats in the risk proposal).
The strategy-side reserve in sections 2 and 3 is a separate, not-yet-built design; it would have to include a loss mechanism of its own.

Seed accounting: the seed is a separate ledger line (`protectionSeed`), not a supplier deposit and not in the exchange rate until drawn; draws are logged with the loss event; the operator's right to take the seed back is limited to the amount above the required coverage; retained income is added to the same ledger with its own line. All of this is a design requirement for the allocation contracts, which do not exist yet.

## 5. Operator decisions this analysis does not make
Supplier cash S per market (caps); stress shocks X* to hold (30/50/70% shown); seed amount and whether the seed can ever be withdrawn; retention rate (50% scenario) and the income base it applies to; the allocation ceiling and ratchet (75-90% scenario); full range vs a wide range; the coverage thresholds in section 4; whether an explicit operating-fee line exists; the valuation basis for entry/exit/in-kind (F-IK-2).

## 6. Evidence and not-measured
Closed-form arithmetic above (reproducible with the formulas stated); gas and operating cost from `avalanche-operating-cost-estimate.md`; fairness findings from `avalanche-vault-entry-fairness.md`; lending bad-debt and liquidator numbers from `avalanche-cash-only-risk-proposal.md` (agent study; fixture-dependent). Not measured: strategy yields, PHAR value, real unwind cost under stress, correlation of strategy loss with lending bad debt, any production S.

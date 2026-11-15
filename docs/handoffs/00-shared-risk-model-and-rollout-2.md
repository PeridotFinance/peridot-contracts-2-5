# Handoff 00: Shared risk model and rollout order (read before any other handoff)

Audience: every implementation LLM working on handoffs 01 to 09, on any chain (Stellar, Robinhood, Avalanche).
Written: 2026-10-30, revised 2026-10-31 after three external design reviews. Where another handoff disagrees with this file, **this file wins**, and you report the conflict to the operator.

## 1. Rollout order (narrower than the full programme)

**Start now:** Stellar stage 1 (1x PYUSD/USDC share vault, handoff 07) with the compiled integration harness as its first checkpoint; Robinhood handoff 08 Phase 1 (measurement only) and handoff 01 Phase 0 (research only); Avalanche handoff 09 tracks A, cash-only B and C in parallel, with D's port and research alongside. Everything else waits for its gate.

**This file is copied identically into each repository** (`docs/handoffs/00-shared-risk-model-and-rollout.md`). If you find a conflict or need a change, report it to the operator; do not edit your copy alone.

### Stellar (`PeridotFinance/Peridot-Soroban`)

1. **Transferable Aquarius CL share vault, 1x pilot on PYUSD/USDC** (handoff 07). Provisional choice: it reuses the existing Peridot PYUSD/USDC strategy pool and price-router groundwork, so less new integration lands at once. Before any **collateral activation**, the comparison gate in 07 section 1 must confirm the pair (exact token identities, live depeg detection, liquidation capacity after withdrawals, net return with sharply reduced AQUA rewards). USDC/sUSD can become the leveraged product if that comparison shows better sustainable returns and adequate pricing and exits.
2. Funding group with USDC and XLM markets (handoff 02) **holding cash locally**. Upshift allocation exists in code but is **disabled**.
3. **Decided launch path:** PYUSD/USDC at 1x. The first capped Stellar margin release targets **2x using the existing integer leverage**. Activate only after reward accounting (section 8a), the share execution facade (07 section 3d, decided: pool-interface wrapper), post-cost position health and funded liquidation capacity (section 10) pass their tests. If 2x fails the gates, stay at 1x; do not weaken the gates to fit the interface. **Fractional leverage is deferred** unless evidence shows a viable 1.5x product that cannot safely launch at 2x.
4. Capped Upshift allocation, after its accounting and liquidity protections (handoff 02) are complete and tested.
5. Second stable pair, then XLM/yXLM, then the XLM/USDC research (handoff 04). Sushi (03) and Curve (05) stay off the critical path.

### Robinhood (`PeridotFinance/PeridotV2-Robinhood`)

1. Ramses group infrastructure (handoff 01): verify fee entitlement and feeds by fork test, supply-only.
2. Activate the **first pair that passes** the economic and liquidation gates (SPY is the likely first; GLD only with exit-depth-bound limits).
3. **1x share vault** (handoff 06) before any leveraged LP.
4. Leveraged long LP through the existing isolated-margin stack: LP-share markets at controller CF 0, leverage from the margin pair config (section 5a, handoff 06 section 0a), capped.
5. Stock-debt "hedged" mode only as a separately validated mode (handoff 06 section 2c), never the default before its stress results exist.

## 2. Profitable capacity is the output of every research phase

Every strategy's research must end in one sentence the operator can act on:

> "This strategy supports about **$X** of our capital at about **Y%** net return (range **Y_low to Y_high**) under these conditions: …"

Launch caps, revenue expectations and marketing claims come from that sentence. Leveraged LP creates borrow demand, but **borrow interest moves income between users**; the system's sustainable return still comes from external fees, rewards and strategy performance. Never present borrow interest paid by our own leveraged users as new yield at protocol level.

## 3. One P&L ledger for backtests

IL, LVR and realized rebalance losses measure related effects against different benchmarks. Subtracting all of them independently double-counts.

- Track **one portfolio ledger** per simulated position in the market's unit of account: starting equity, every contribution and withdrawal, swap, recenter, fee collect, reward claim (valued only when it is actually sold or distributed under the deployed policy), borrow interest, gas/resource fee, ending equity marked at the oracle.
- **Dollar P&L** = ending equity + withdrawals + externally distributed rewards − starting equity − contributions. Report it separately from **percentage return**: use a time-weighted return for strategy quality (independent of flow timing) and a money-weighted return (IRR) for what an actual depositor with that flow history earned. State which one any headline number is.
- Report **versus holding the deposited asset** (what the user would otherwise do).
- **Do not use the naive LVR formula (`σ²/8 × concentration`) as a forecast.** It assumes arbitrage at zero fee and continuous time. With a swap fee γ and block time Δt, arbitrageurs only trade when the price gap exceeds the fee, and the LP's loss to arbitrage is roughly the naive LVR × `P_trade`, with `P_trade ≈ 1 / (1 + γ / (σ·√(Δt/2)))` (Milionis, Moallemi, Roughgarden 2023). On fast-block chains this shrinks the loss a lot, especially at higher fee tiers (0.3%). What it does **not** shield is **price jumps**: session opens, weekend gaps, corporate actions. For tokenized stocks those gaps are the main LVR source. Measure both with markout analysis on real swaps; earlier rough break-even estimates in these handoffs that used the naive formula were likely too pessimistic for continuous trading and say nothing about gaps.
- The fee-adjusted arbitrage loss above **already nets the fees arbitrageurs pay**. When decomposing results, do not add those arbitrage fees again as separate income. The decomposition is explanatory; the **portfolio ledger is authoritative**. The paper supports this accounting; it does not show that any of our pools is profitable or that narrowing a range improves net return.
- For LVR, the matching benchmark is a **delta-matched rebalancing portfolio**: one that at every step holds the same quantity of the risky asset as the CL position and rebalances at the oracle price without fees. The LP's shortfall against that portfolio, before fees and rewards, is the LVR. A generic 50/50 rebalanced portfolio is a useful extra comparison but is **not** the LVR benchmark for a concentrated position. Report LVR only as a decomposition; never subtract it again from the ledger result.
- Rewards count only through the mechanism that will exist on mainnet. If RAM or AQUA sits in a segregated bucket with no enforceable distribution, its value to the user is zero in the backtest.
- Dilution: add our own capital at several sizes and recompute fees and rewards per unit of liquidity. Losses to arbitrage do not dilute.

## 4. Liquidation capacity is measured after the collateral leaves the pool

Liquidating an LP-backed position means: redeem shares, remove that liquidity from the pool, then sell the received assets into **whatever liquidity remains**. Pre-liquidation depth overstates capacity.

Required tool (`tools/liquidation_capacity` on each chain), run at a pinned state:

1. Start from measured pool liquidity per tick (or per range on Aquarius).
2. Remove a **stressed share of third-party liquidity** (start 50%) to model LPs leaving in a fast market.
3. Simulate a **sequence of correlated liquidations** (largest first), each one: remove the position's liquidity, swap its non-debt asset into the debt asset, update the pool, continue.
4. Count Peridot's own liquidity (backup range, other share vaults) **only if it is still there** at that step of the scenario. Our own positions are being liquidated in the same scenario.
5. Report the aggregate notional that can be liquidated with slippage below the configured maximum. Set per-position and **aggregate** caps from that number divided by a safety factor (start 2).

For receipt markets with an external strategy (Upshift): prove that every step a liquidation or a voluntary close needs (redeem collateral, repay debt) can execute **when the external strategy pays nothing**. If a step needs an external redemption, it is not a guaranteed path.

## 5. Leverage: two separate rule sets

Keep **ordinary lending** and **margin** apart. They are checked by different code on both chains, and mixing them produced wrong guidance in earlier drafts.

### 5.0 Ordinary lending (Compound-style controller, no margin account)

One collateral factor sets both borrowing capacity and the liquidation point. With CF, recursive borrowing reaches at most `1 / (1 − CF)`, and an account opened at that boundary has zero headroom. So:

- The CF of any LP-share or strategy-backed market bounds **manual looping** by ordinary users. Set it from the backtest's worst moves, not from a margin product's leverage target.
- Adversarial tests must include direct borrowing, manual looping, collateral withdrawal and pToken transfers.
- A separate origination LTV below a liquidation threshold (Aave-style) would need a reviewed controller change. Not planned.

### 5a. Robinhood margin (isolated margin accounts, EVM)

- Margin accounts are registered in the controller. For them, `borrowAllowed`, `redeemAllowed` and `transferAllowed` call the risk-engine hook **instead of** the CF check. Ordinary CF-based liquidation and seizure are blocked for those accounts.
- Leverage and liquidation come from the margin pair config: `maxLeverageX100`, `initialMarginBps`, `maintenanceMarginBps`, plus position and debt caps.
- **LP-share markets are listed at CF 0.** Ordinary users cannot borrow against them, so manual looping is impossible. Margin accounts use them under the pair config. Integration tests must prove a CF-0 market works as a margin position market end to end.
- Recorded live NVDA profile: **5x, 20% initial / 10% maintenance**. The earlier 2x canary profile (50% / 25%) is a candidate for new LP pairs, not the current configuration.
- Buffers are stated as a fall in **gross collateral value with debt fixed** (at 2x with 25% maintenance, about 33%). For LP shares, the underlying price move that causes that fall depends on the position's composition and range; compute it from the share NAV curve, not from the stock price.

### 5b. Stellar margin V3 (Soroban `margin-controller`)

- V3 borrows go through the receipt vault's `borrow_for_margin`, which checks margin-controller authorization, pauses, liquidity and caps, **without** the ordinary account-CF calculation. V3 position health uses equity and the pair's maintenance margin.
- `assert_market_supported` requires `get_market_cf(vault) > 0`. That is an **eligibility** check, not the margin liquidation rule. Earlier statements such as "2x does not fit XLM's 60% CF" were wrong for the V3 path and are withdrawn.
- **Integer leverage only:** the V3 entrypoint computes `notional_value = margin_value.checked_mul(leverage)` with no divisor. Passing 150 means 150x. Fractional leverage needs an explicit implementation: scaled leverage (e.g. ×100), opening fee computation, configuration validation (`max_leverage` in the same scale), rounding direction, migration of existing pair configs and compatibility tests. Until that ships, the only leverages are 2x, 3x, …
- LP-share markets need CF > 0 for eligibility today. A positive CF **creates** ordinary borrowing capacity; it only limits it (theoretical looping `1/(1−CF)`: 1.0101x at 1%, 1.1111x at 10%; at 10%, $100,000 of shares supports about $10,000 of direct borrowing before any looping). Decision for v1: **CF exactly 1%**. Explicitly accept the resulting ordinary borrowing against shares and **include it in the aggregate exposure model** and the liquidation-capacity analysis. Acceptance test: an ordinary account with share collateral can borrow at most 1% of the shares' value, and a margin-held position cannot be liquidated through the ordinary controller path.
- If the requirement becomes strictly **no** ordinary borrowing against LP shares: separate margin eligibility from CF and use CF 0. The controller source already exposes `is_market_supported`; the margin controller's `assert_market_supported` and the CF configuration would need reviewed changes to use it. Not in v1.
- First Stellar leveraged release: **2x integer leverage** with a maintenance margin set from the backtest and liquidation-capacity tool. Fractional leverage is deferred (section 1).

### 5c. Both chains

- Leverage limits are **opening** limits; price moves change an existing position's leverage afterward.
- Raising leverage requires **successful stressed liquidation rehearsals** (section 4 scenarios on a fork), not just a quiet week.

## 6. Valuation: three separate quantities

For any external strategy (Upshift, LP share vaults), never collapse these into one number:

| Quantity | Used for | When unavailable |
| --- | --- | --- |
| **Accounting value** + timestamp | Reporting, exchange-rate display | Keep last good value, mark it stale |
| **Collateral validity** | New borrows, collateral removal, redemptions at the exchange rate | **Fail closed**: block new borrows and collateral removal; do not let a cached value authorize them |
| **Withdrawable amount** | Sizing redemptions, liquidity checks | Use the external strategy's own `max_withdraw` / exit limits, never the share balance |

An emitted event does not make the controller react. If the controller must react, the controller (or receipt vault) must read the validity flag.

**Validity is checked across the whole account, not per market.** Compound-style account liquidity sums every collateral snapshot of the borrower. If market A's collateral becomes invalid, a borrow from market B by the same account must fail. So validity must propagate into the controller's account valuation: each collateral snapshot carries a validity flag, and the controller **reverts** (does not treat as zero) any risk-increasing action for an account holding invalid collateral: borrow from any market, redeem or withdraw collateral, pToken transfer, `exit_market`. Required test: supply into market A, invalidate A's valuation, attempt to borrow from market B, transfer A's pTokens, and exit A; all must revert.

**Liquidation under invalid valuation (two different conditions):**

| Condition | Required behavior |
| --- | --- |
| New deployment into the strategy is paused (breaker on deposits), but current collateral prices remain trustworthy | Repayment and normally priced liquidation continue |
| Collateral price or NAV is unavailable or untrustworthy | Repayment remains available. Ordinary price-based seizure of that collateral is **disabled**, because a cached number or a zero-price sentinel cannot determine a fair seize amount (a zero price would also make seize maths divide by zero or seize everything). A separately defined **recovery policy** applies: e.g. a timelocked recovery valuation (last trustworthy value minus a haircut, never above it), or in-kind settlement under section 10 once a trustworthy value exists. Specify and test it per product |

**Confirmed losses are always recognized**, including when they trip the breaker: if the strategy reports a lower value through a trustworthy path, the exchange rate marks down; the breaker may not hold a stale higher value.

## 7. Oracle rules

- Separate the **unit-price policy** of a quote asset (USDG = $1, USDC peg checks) from the **validity of each market's backing**. A GLD feed problem must not block SPY/USDG operations; it must block anything whose backing depends on GLD. Keep a deliberate group-wide emergency pause.
- Distinguish **oracle paused / session closed** from an ordinary late update. Robinhood Chainlink feeds keep the last value off-hours without heartbeat updates, so an age check alone lets a recent-but-closed price pass for hours after the close. Use `oraclePaused()`, the token's pause flag and a session calendar (or measured update cadence) as separate checks.
- A wider LP range keeps trading liquidity available. It does not remove gap risk while liquidations are unavailable.

## 8. Share-vault accounting proofs (both chains)

Every new share vault must prove, with unit and invariant tests:

1. New depositors pay their own execution costs (zap swap, slippage).
2. Existing holders keep previously accrued fees and rewards.
3. Donations and rounding cannot inflate share price or borrowing power.
4. A deposit just before a harvest or fee collection cannot capture earnings accrued before it.
5. A partial withdrawal receives exactly its proportional entitlement, including when the venue pays out **all** accrued fees on any withdrawal (Aquarius does).
6. Emergency in-kind redemption works for unencumbered shares when swaps, reward claims or the oracle are unavailable, as far as the venue allows, **and records the redeemer's outstanding reward entitlement without requiring a successful claim**. The only exception is an explicit, contract-enforced waiver (section 8a).

### 8a. Reward ownership (RAM, AQUA): entitlement index, not common NAV

Booking rewards outside NAV and selling them into common NAV later **transfers earnings to new depositors**. Required invariant test (Alice/Bob):

1. Alice holds the whole vault, NAV $100, plus earned rewards excluded from NAV.
2. Bob deposits $100 and receives half the shares.
3. The old rewards are sold for $10.
4. **Bob must receive $0 of that $10**; Alice receives $10.

Swap fees in pool tokens are not affected: collect them into NAV before every mint and burn. Reward tokens follow this design.

**Upstream accrual checkpoint before every ownership change.** Updating the accumulator only when rewards arrive is not enough: rewards earned upstream but not yet claimed would be split across holders who joined later (Alice earns 10 AQUA alone, Bob deposits before the claim, the claim divides 10 AQUA between both).

**v1 rule: a successful upstream claim before every normal ownership change.** Before any ordinary mint, burn or transfer, the vault claims (Aquarius `claim`, Ramses manager `getReward`) in the same transaction, credits the received amount to the accumulator at the **old** supply, settles affected holders at their **old** balances, then applies the share change. If the claim fails, **ordinary deposits and ordinary transfers pause** (revert). Receivables from pending views are **not** used on the normal path in v1; they are only for the emergency path below. This keeps the accounting small.

**Recovery paths must keep working during a reward outage.** Liquidation, repayment-based release of collateral and emergency redemption can need share movements (for example shares leaving a receipt market or margin account before a burn). These paths:

- stay available when both the claim and the pending view fail;
- are reachable only through their authorized callers (liquidator, executor or margin controller in a recovery state, the holder's own emergency redemption), never as a general transfer bypass;
- write an **entitlement ledger entry** for every holder whose shares move without a successful claim.

Required test: the complete flow receipt market → share vault → underlying, for liquidation, repay-and-release and emergency redemption, with **both** reward calls failing, and the later settlement.

**Entitlement is defined by verified accrual deltas, not by holding time.** Ownership changes split rewards correctly only if the vault knows how much had accrued **at the moment of each change**. Holding time is not a proxy: if Alice and Bob each hold half, the vault earns 10 AQUA, Alice exits, then it earns 90, the entitlements are Alice 5 and Bob 95, which no share-time split reproduces when emissions or in-range eligibility change during the period.

- **Normal path (v1):** the claim-first rule gives a verified delta at every ownership change (the claim returns exactly what had accrued). No estimation.
- **Recovery path without a claim:** a ledger entry is **proven** only if, at the moment of the change, the vault recorded a verified accrual reading: the venue's pending view for the vault (Aquarius `get_user_reward(vault)`), or venue accounting that reconstructs the delta at that moment (e.g. Ramses position period seconds inside, if fork-verified to reconstruct exact amounts). The entry stores holder, shares, accumulator, the reading and the timestamp.
- **A reading must be taken at the boundary itself.** If the pending view fails at an ownership change and becomes readable later, the later cumulative reading cannot establish the missing earlier boundary; that holder's entitlement for the interval stays **quarantined**. Required test.
- Aquarius documents `get_user_reward` as a pending **estimate**. Before treating its readings as proven, demonstrate against the pinned pool WASM that the reading equals the amount a `claim` at the same state pays (including rounding and the in-range checkpoint behaviour). Until demonstrated, readings are recorded but entries are treated as unresolved.
- Where **neither** exists, the amount is **unresolved** (quarantined, see below) or **explicitly waived** by the holder. It is never labelled as proven entitlement based on a time-weighted estimate.

At the next successful claim:

- The claimed amount is reconciled against the **proven** entries and the accumulator, by the recorded deltas. Holders who exited are included.
- A **shortfall** (claim smaller than the sum of proven readings) is applied **proportionally to those proven amounts**, among exactly the holders whose readings it covers. Exited holders are not paid first, and current holders do not absorb an exited holder's shortfall. Example: Alice is recorded at 100 AQUA, exits, Bob enters, the venue pays 80 for that interval: Alice's entry settles at 80; Bob is unaffected. Two holders each recorded at 50 for the same interval with 80 arriving: 40 each.
- An **excess** goes to current holders only when it is demonstrably attributable to their holding period; otherwise it stays in the ledger as unresolved and is reported.
- Never count the same reward twice (pending reading plus claim).

**Quarantine for unresolved amounts.** Rewards that cannot be attributed are held in a quarantine bucket per affected interval, excluded from NAV and from the accumulator, and reported. Release only through a governed attribution decision with published evidence, or after the venue provides the missing accounting. Quarantined amounts are never auto-distributed to current holders.

**Voluntary emergency redemption: contract-enforced waiver.** If a holder redeems in an emergency while their entitlement cannot be proven, the call takes `accept_reward_waiver: bool`. With `false` the call **reverts** with a named error (the holder can wait, or redeem without waiving once a proof is possible); with `true` the holder's unprovable amount for the open interval is waived and stays with the interval's other owners. A UI warning alone is not enough.

**Forced liquidation: no waiver, quarantine instead.**

- A borrower **cannot block** liquidation by refusing a waiver; the liquidation path takes no waiver parameter.
- The liquidator **cannot waive** the borrower's rewards.
- Principal liquidation proceeds normally. Any unprovable historical reward entitlement of the borrower is recorded in quarantine, attributed to the borrower, and resolved later as above (paid to the borrower, or applied to residual debt if the product spec says so).
- Automatic forfeiture on forced liquidation is **not** used. If a product ever wants it, it must be an explicit policy accepted by the user when opening the position, stored per position, never a flag supplied by the liquidator.

These are the only exceptions to section 8 item 6.

- Per holder: `reward_debt`, `pending`, plus any open ledger entries.
- **Conversion does not change ownership.** v1: no pooled conversion. Holders claim reward tokens in kind, or "claim and swap my own rewards". Optional auto-compound mints shares **to that holder only**, at NAV, after their rewards are settled.
- **Shares posted as collateral: pass-through, not forfeit.** For the leveraged products the reward stream is a large part (on PYUSD/USDC all) of the income, so forfeiting it removes the product's reason to exist. The collateral market and the margin account must attribute reward entitlements to the depositor or position owner (per-account sub-ledger in the market, or the margin account claims and forwards to its owner). Liquidation transfers the seized shares' **future** rewards to the liquidator; rewards accrued before seizure stay with the borrower (or are used to repay debt; specify and test).
- Required tests: Alice/Bob with **unclaimed upstream rewards at Bob's deposit**; the 10/90 emission-change case (Alice 5, Bob 95); transfers mid-accrual; several share movements in one transaction including successful claims that return zero; claim failure pauses ordinary deposits and transfers but not recovery paths; reconciliation of proven entries with shortfall and excess, including exited holders; quarantine of unprovable amounts; voluntary waiver true and false; forced liquidation with an unprovable entitlement (proceeds, borrower cannot block, liquidator cannot waive, amount quarantined to the borrower); collateral pass-through including liquidation.

Alternative if the index is too heavy for the bytecode budget: **settle before admitting deposits** (deposits are only accepted right after a successful claim in the same transaction, and pooled conversion stays off). Never mix the two models in one vault.

## 9. Multi-transaction flows

If an operation spans transactions (Soroban margin `begin → execute → swap → activate`, keeper multi-step recenters), the spec for each intermediate state must state: who holds custody, the deadline, how it is cancelled, which prices are revalidated at the next step, and who is responsible for any debt outstanding in that state. Tests cover abandonment at every step.

## 10. Fallback liquidation when the collateral cannot be sold

This is **new work on both chains**. The existing Robinhood liquidator requests a flash loan; a user repaying and exiting debt-free (`exitDebtFreeToPTokens`) helps the user but does not replace third-party liquidation during a swap outage.

When the swap needed to turn seized collateral into the debt asset is unavailable (pool swap killed, oracle path for a zap invalid), a liquidation can still settle **in kind**:

- The **liquidator supplies the actual debt asset**. Repayment and seizure settle **atomically** in one call.
- The liquidator receives the corresponding shares or underlying tokens at the configured bonus and **bears the subsequent exit risk**.
- This route **cannot rely on a flash loan**, because the seized collateral cannot be sold within the transaction to repay it. It needs **funded liquidators** holding the debt asset.
- Operational plan per product: who the funded liquidators are (Peridot's own liquidator with a funded wallet, partners), how much debt asset they hold, and a **capacity estimate for this route** (sum of liquidations it can clear before liquidators run out of funds or appetite). Set aggregate caps so this capacity covers the worst-case scenario from section 4 while swaps are down.
- Handing over illiquid pTokens does not guarantee anyone accepts them at the proposed bonus. Prefer seizing the underlying shares or tokens, and measure whether the bonus covers the exit cost in the stressed scenario.

## 11. Modifying audited contracts

The earlier rule "reuse existing contracts unmodified" is relaxed: **small, reviewed changes** to a controller or receipt vault are preferred over forcing protections into an adapter that cannot enforce them. Each such change: minimal diff, its own tests and mutation checks, an adversarial review, and a note listing what needs re-audit. Never change a live contract's storage layout in place.

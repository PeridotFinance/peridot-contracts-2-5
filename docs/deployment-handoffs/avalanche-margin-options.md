# Avalanche track C (margin): remaining venue / exposure and finite-funding choices

Status: options and evidence for an operator decision. **No launch approval is implied, no cap is proposed or changed.** Source of every number: `avalanche-capacity-matrix.md` (strict run, pin block 99,200,000, hash `0x221a26c046d7c21cd8dc88ea808ccf2b0e9811916e1f091cc4b3222c5e11fd97`) and `avalanche-funded-fallback.md`. Track A is reported separately (`avalanche-track-a-launch-gate.md`). Borrowing (track B) and trading (track C) stay paused.

## 1. Where the evidence leaves track C

- The candidate 2x / 25% maintenance profile has **no PASS** in any executed stress scenario on this pool: the long's trigger (about -34%) and the short's (about +51%) lie in the empty gap beyond the pool's liquidity walls (sell side about USD 98.5k of USDC in total; buy side about USD 4.9M up to about +50%), so the normal route (swap into the pool) cannot liquidate them at a price the pool can actually produce.
- Any gap between oracle and pool on the unfavourable side of the swap module's floor stops the normal route regardless of depth (measured: 100 bps of adverse oracle lag fails every size).
- The funded in-kind route removes the pool from the liquidation path and settles positions that are **solvent at the oracle price**; it does not recover insolvent ones and it does not make the seized pTokens cash.
- Ordinary lending liquidations (track B) do not use the pool and are not affected.

## 2. Venue / exposure choices

| Option | What it means | Evidence for / against | What it would still need |
| --- | --- | --- | --- |
| A. Keep track C paused; ship cash-only B | Lending only; margin waits | Ordinary lending liquidates without the pool; margin has no PASS | Nothing for C now; decide when C re-enters |
| B. Same pool, earlier trigger (`ALT-2x40`-type profile) | Higher maintenance margin so the trigger is reachable inside the walls | Short: PASS-VIA-FALLBACK and normal-route PASS only when the oracle follows the pool within about 50 bps, and only at small sizes (1k PASS; 5k and 25k FAIL-PARTIAL). Long: trigger (about -17.7%) sits at the sell wall's edge; FAIL at 5k and 25k, FAIL with any lag. No alternative passes the full stress set | A profile whose trigger is reachable AND passes the lag and 50%-removal variants; none exists in the tested set |
| C. Lower leverage | e.g. 1.5x | Trigger moves further out (about -56% long), further beyond what the pool can reach, so it relies entirely on the funded route | Funded-route budgets and inventory plan below |
| D. Funded in-kind as the primary liquidation route | Pool used only for user opens/closes; liquidations by allowlisted funders | Works for oracle-solvent positions with zero market cash (tests, 6 of 6 zero-cash scenarios) | Funder programme (section 3), bad-debt and insurance policy (section 3.3), audit of the changed contracts |
| E. A different venue or route | A pool/venue with materially deeper two-sided liquidity | Not evaluated: no data. Must pass the same strict matrix before any cap | Same matrix, new adapter, new oracle-vs-venue analysis |
| F. Much smaller exposure on this pool | Position and aggregate caps far below pool depth | The matrix shows failure even at USD 1k margin in the stress classes (the trigger is unreachable, not the size) | Not a fix by itself; size is not the binding limit |

The binding limit is the **reachability of the trigger**, not the position size. A smaller exposure does not fix a trigger that lies beyond the pool.

## 3. Finite-funding choices for the funded route

Measured (placeholder parameters; funder funded once with 30,000 USDC and 3,500 WAVAX, no replenishment):

| Quantity | Measured |
| --- | --- |
| Debt-asset budget per position | about the debt: 24,505 USDC (25k-margin long), 2,894 WAVAX (25k-margin short, about USD 24.7k at the pin and more if AVAX rises) |
| What the fixed budget covers | about one cap-size position per side |
| Aggregate | proportional to total debt; the worst case is the sum of margin debt up to the borrow caps |
| Gas | about 0.55 to 0.70M per funded liquidation (flash route: 1.57M) |

### 3.1 Who funds, and how much
Options: protocol-owned funded wallets; a small set of partner funders; a permissioned allowlist (timelocked add, immediate remove, as implemented). Budgets must be held in BOTH assets (the debt asset depends on the side) and must cover the worst case of the aggregate cap; a funder that runs out stops (reverts atomically, no partial state).

### 3.2 Inventory redemption (the funder receives pTokens, not cash)
- With market cash available the funder can redeem; with **zero cash** the inventory is not redeemable (`redeemable now` = 0 in the zero-cash scenarios): 231 / 1,157 / 5,777 WAVAX of pWAVAX (long) or 1,990 / 9,949 / 49,728 USDC of pUSDC (short) for 1k / 5k / 25k margin.
- The cap-size long's inventory is 5,348 WAVAX, about 30% of the pWAVAX supply; carry is about USD 19.5 per day at the placeholder rate model; an AVAX move of about -4.7% erases the whole 5% bonus; the redemption delay has no time bound.
- Choices: (a) funder holds the pTokens as supply and accepts exposure and delay; (b) funder hedges the inventory off-protocol; (c) a protocol cash reserve or redemption facility in the market so inventory can be redeemed (a new mechanism, not implemented); (d) caps sized so inventory stays a small share of the market.
- None of these is tested beyond the measurements above; successful in-kind seizure does not prove that the collateral can be redeemed, sold or that the funder can replenish its budget.

### 3.3 Who absorbs a loss
For a position that is **insolvent at the oracle price** (collateral worth less than debt):

| Choice | Effect |
| --- | --- |
| Funder with no floor (`minSeizeValueBps` = 0) | Funder repays the whole debt and receives all collateral: it absorbs the shortfall. Measured completing in 5 of 6 pool-following scenarios (value not meaningful: synthetic price) |
| Funder with the break-even floor (10,000) | The call reverts for insolvent positions: **debt and shortfall stay in the lending market** (suppliers' loss) unless something else covers it. Measured as FAIL-FLOOR-DECLINED in most synthetic scenarios |
| Insurance fund tops up | Not implemented (a new surface). Measured need: a long with USD 5,000 margin at 30% of pin leaves USD 1,933 bad debt (39% of debt); a short at 280% leaves USD 3,911 (28%); the harness insurance seed (about USD 6.3k) would not cover a cap-size long at -70% (USD 9.3k) |
| Reserves / reserve factor | Not tested |

### 3.4 What the break-even floor does and does not guarantee
`minSeizeValueBps = 10_000` means: **seized pTokens, valued at the oracle price at the moment of the call, are worth at least the debt repaid.** It is **not a guarantee of realizable cash proceeds**:
- pTokens become cash only through redemption, which needs market cash (zero in the stress scenarios);
- the oracle can differ from the price at which the underlying can actually be sold (the matrix shows the pool cannot absorb the sale; the swap module's own floor exists because of this);
- the underlying (WAVAX or USDC) moves in value during any redemption delay;
- a stale-but-valid oracle can satisfy the floor for a position that is healthy at market (the funded route has no market sanity check).
The floor protects the funder from accepting a position that is already underwater by the oracle's own measure; it does not bound the funder's realised loss.

## 4. What would have to be true for a cap to be derived

1. A profile and venue where the maintenance trigger is reachable without exhausting the venue, passing every strict matrix slice (pool-following, lag, 50% liquidity removal, accrual, aggregate variants) in an external price regime, or an explicit decision that the funded route is the only liquidation route.
2. A funder programme with named funders, budgets per asset covering the aggregate worst case, a replenishment and redemption plan, and a stated loss-absorption policy (3.3).
3. Bad-debt and insurance sizing at externally reachable prices.
4. Audit of the changed contracts (`avalanche-funded-fallback.md`, re-audit note) and a decision on the partial-sizing dependency (`avalanche-funded-sizing-design.md`).
5. Resolution of: transfer-pause stops both routes; USDC depeg handling; mainnet deploy-script rehearsal; PERIDOT token decision.

These are operator decisions; this document changes no parameter.

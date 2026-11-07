# Range take-profit: prototype (branch `proto/range-take-profit`, fork-tested, NOT for deployment)

Built 2026-11-06 to the operator's design: a leveraged long's stock goes into a concentrated-liquidity band entirely above
the market. Trading up through the band converts the stock to USDG; a fall back reverses that. A keeper finalises:
remove, collect, repay the current debt with interest, return the equity. **This branch is separate from
`feat/margin-order-interface`.** The executor upgrade prepared for signing is unchanged by it.

## Pieces

| piece | change | size |
| --- | --- | --- |
| `orders/range/RangeTakeProfit.sol` (new) | custodian behind an OZ 5 transparent proxy (admin = timelock; storage snapshot `tools/orders/range-layout.json`): one Ramses NFT per order; presets; fee split; finalise; unwind; `holdings` at the oracle; refuses bands until the risk engine counts it (`NotWired`) | see `forge build --sizes` |
| `IsolatedMarginExecutorUpgradeable` | `rangeRelease` (stock collateral to the custodian), `rangeReturn(id, settle)` (repay from USDG, stock back to collateral, debt-free exit when settling); `initializeRange(custodian, orderExecutor)` reinitializer(3), proxy admin only: sets the custodian and hands the order executor from adapter v1 to the range-aware adapter v2; slot 25 from the gap | 24,512 B (64 spare) |
| `IsolatedMarginRiskEngineUpgradeable` | `_metrics` counts the band's holdings at the oracle; `authorizeRangeRelease` (executor only, ACTIVE accounts); `initializeRangeCustodian` reinitializer(2), proxy admin only (the first wiring, inside the timelocked batch); `queueRangeCustodian` / `applyRangeCustodian` / `cancelRangeCustodian` (owner, for later changes); slots 8 and 9 from the gap | 16,926 B |
| `IsolatedMarginLiquidatorUpgradeable` | `liquidate` first calls `custodian.unwind(id)`; `initializeRangeCustodian` reinitializer(2); slot 22 from the gap | 13,304 B |
| `RobinhoodMarginCloseAdapter` | optional immutable `rangeCustodian`; `closeFor` unwinds an active band before any order closes (stop-loss path) | 5,059 B |

- **Storage:** append-only, checked against `feat/margin-order-interface` from the build artifacts. Every existing slot is
  unchanged; `rangeCustodian` takes the first gap slot, and each gap shrinks by one.
- **Defaults:** all hooks are off until wired (`rangeCustodian == 0`).

## How each rule is enforced

- **Conversion is not repayment.** `finalize` marks the order `SETTLED` only after `executor.rangeReturn(id, true)`
  returns; that call accrues the debt first and repays it. A failing repay reverts the whole finalisation, and the order
  stays `ACTIVE` (tested).
- **Partial commit:** `createRangeOrder(id, preset, positionPTokens)` can commit only part of the collateral. On
  finalisation the USDG repays what it covers; the position closes only when the debt reaches zero.
- **Not final until removed.** `finalize` requires the market to have traded through the whole band. A partial fill is
  refused (`BandNotFullyConverted`) and reverses on a fall (tested).
- **One order per position.** A second order is refused. A range order is refused while the registry holds an open
  `TAKE_PROFIT` on the position.
- **A stop-loss first removes the band.** The order adapter calls `unwind` before `closePositionFor`; the normal close
  path then sees all the collateral (tested).
- **Liquidation is never blocked.** The liquidator unwinds the band before computing anything, and the position is then
  liquidated in full (tested). The counterfactual test shows why the hook is required: without it the seizure reverts
  `LiquidationError(12)`, because the account holds no collateral.
- **Guards preserved:**
  - Placement and finalisation need the margin oracle's price, so a stale feed or the issuer's `paused()` /
    `oraclePaused()` refuses (tested).
  - The pool must be within the pair's `oracleDeviationBps` of the oracle (tested).
  - The band is valued for risk at the oracle price, never the pool's, so pushing the pool cannot change a position's
    health (tested).
- **No band below the market, so it is never offered as a stop-loss.** Presets need a distance above zero and are
  multiples of the pool's tick spacing, which is read from the pool (Ramses NVDA: 10; SPY: 1). The band sits on the
  stock's favourable side for either token order (NVDA is token1, SPY is token0; both tested).
- **Fee split as parameters:** user, protocol and reserve bps, summing to 10,000, set by the admin. They are snapshotted
  into each order and emitted at opt-in.
  - Swap fees are measured as collected minus principal.
  - Gauge rewards follow the same split; the user's RAM share goes to the owner's wallet.
- **Risk reduction never waits for fees.** `unwind` removes and collects in one step, reads no price, and is callable by
  the liquidator, the order adapter and the owner.
- **Approved presets only.** There are no arbitrary user ranges.

## Evidence (fork, L2 107,658,090 and, after the partial-commit test, 107,665,837; nothing sent)

`test/orders/RangeTakeProfitFork.t.sol`, 15/15, runs against the **live** stack upgraded on the fork through its
ProxyAdmins as the timelock: live long position 4, the real Ramses NVDA/USDG pool and position manager.

| case | result |
| --- | --- |
| Create from position 4, preset 1 (100 ticks above, 200 wide) | band 223,330 to 223,530 below tick 223,625 (NVDA is token1); 0.00792 NVDA committed; health 37,456 bps before and after |
| Partial fill, then reversal | mid-band 0.00395 NVDA + 0.783 USDG; finalise refused; after the fall, all 0.00792 NVDA back |
| Pool moved, oracle not | still valued as all stock; finalise refused |
| Full fill, keeper finalises | debt and interest repaid to 0; position CLOSED; 3,162,996,004 pUSDG units of equity to the owner; fee split 157 / 78 USDG raw to protocol and reserve (2:1); custodian keeps nothing |
| Repay fails | finalise reverts, the order stays ACTIVE |
| Half the collateral committed, full fill | the band's USDG repays what it can (0.96 to 0.18 USDG of debt); the position stays open on the uncommitted stock with better health; it closes only if the proceeds cover the debt |
| Liquidation with an active band | band unwound, position LIQUIDATED, debt 0 |
| Without the pre-hook | `LiquidationError(12)`, the band stays |
| Stop-loss through the registry | band unwound first, position CLOSED, SL EXECUTED |
| Rules | TP open refuses (code 5); a second order refuses (4); non-owner, unapproved preset, distance ≤ 0, off-spacing, a bad fee split, a stale feed, the issuer pause, a pool 3% from the oracle, and a stranger's unwind all refuse; the hooks are custodian-only |

`test/orders/RangeTakeProfitSpyFork.t.sol`, 4/4, runs on the SPY deployment's **real** Ramses SPY/USDG pool `0x3845`,
gauge `0x739E` and RHSPY feed. SPY is token0 there, so the band sits above the tick (tick −210,255, band −210,155 to
−209,955). Partial fill, reversal, finalisation (debt repaid, 9.83 USDG of equity), unwind, stale feed and pause flag
all behave as on NVDA.

The other orders suites still pass on this branch: registry 32, deploy path 7, close path 10.

## Delayed risk-engine setter (2026-11-07)

The custodian the risk engine counts is now changed by the owner (the Ledger) in two steps, like `queuePairRisk` and
`setPairRisk`:
1. `queueRangeCustodian(address)`;
2. `applyRangeCustodian()`, after the margin config's `actionDelay`, which is 3,600 s live, with a floor of 1 h.

`cancelRangeCustodian()` withdraws a queued change.

**Applying is refused while the current custodian has active bands** (`activeOrders() > 0`). Removing or replacing it
would drop those bands from every health calculation, so healthy positions would become liquidatable at once.

Fork test, live stack, L2 108,373,287:
- a stranger cannot queue;
- an early apply is refused, and so is an apply with a band active;
- after the owner unwinds the band, the apply succeeds;
- the queued change can be used only once.

The first wiring is not the queue: it is a proxy-admin reinitializer inside the timelocked range batch, so the timelock's
delay is the delay (see `RANGE_DEPLOY.md`). Queue and apply are for any later change.

## Finalisation keeper and alarm (2026-11-07)

**Same host and process as the order keeper.** `contracts/tools/orders/orders_keeper.py` runs the TP/SL orders first,
so a stop-loss removes the band through the adapter, then the range phase. It uses one wallet: gas only, no role.
- The range phase reads the journal's `rangeCustodian` and `executor`.
- It simulates `finalize` for every active band and sends it only when the band is fully converted.
- It waits on `BandNotFullyConverted` (partly filled, reversed or not reached), `OracleUnavailable` and
  `PoolOracleDeviation`.
- It never unwinds a band. When a liquidation, a stop-loss or the owner removes one, it records that once.
- It applies the gas-price cap and the per-step send budget.

**Tests:** 15 keeper unit tests (orders and range).

**Alarm:** `contracts/tools/orders/orders_alarm.py`, with `.github/workflows/orders-alarm.yml`. It is chain-only, with no
DigitalOcean token, and follows the pattern of `keeper/alarm.py`: a pure `classify`, and one de-duplicated GitHub issue
assigned to the operator.
- States: `RPC_FAILURE`, `GAS_CRITICAL` (below one send at the cap), `GAS_LOW` (under 10 sends), `IDLE`, `SERVED`,
  `STALLED`, `FAILED_SENDS` (still due while the nonce moved).
- **Stall detection:** an order or band has no age on chain. So the alarm reads what is due, waits 150 s, and reads
  again. Work still due with an unmoved keeper nonce is `STALLED`.
- It stays idle until a mainnet journal exists. 9 tests.

**Anvil fork rehearsal:** `contracts/tools/orders/rehearse_range_keeper.sh`. First run at L2 108,369,009, then rerun at
108,400,520 after the handover and proxy changes, with the same results.
- **Setup:** the live stack, upgraded through its real ProxyAdmins as the timelock in the real sequence. First the
  ceremony (registry V1, adapter v1). Then the range wiring: executor `initializeRange`, registry V2, risk engine and
  liquidator reinitializers. The custodian sits behind its proxy.
- Order created on live position 4 with preset 1: tick 223,944, band 223,640 to 223,840 (in the rerun: tick 223,954,
  band 223,650 to 223,850).

| scenario | band holdings at the oracle (NVDA, USDG raw) | keeper | end state |
| --- | --- | --- | --- |
| not reached | 7.93e15, 0 | wait, BandNotFullyConverted | ACTIVE |
| partial fill (mid-band) | 3.95e15, 759,430 | wait, BandNotFullyConverted | ACTIVE, debt unchanged |
| reversal | back to all NVDA | wait | ACTIVE |
| full fill | 578, 1,522,667 | **finalize sent** (2,089,736 gas); alarm `STALLED` before, `IDLE` after | SETTLED, position CLOSED, debt 0 |
| liquidation (stricter margin, fixture) | | records "removed by a risk path"; nothing sent | UNWOUND, position LIQUIDATED, debt 0 |
| stop-loss at the oracle price | | the order phase executes the SL (2,905,729 gas); the range phase records the removal | UNWOUND, position CLOSED, debt 0 |

**Host:** the keeper is not yet provisioned anywhere. It goes where the order keeper goes, after the ceremony, with its
own gas-only wallet.

## Not done, and decisions for the operator

1. **SPY has no margin engine,** so the SPY test uses a labelled test-only stand-in for the margin position.
   - Hosting SPY margin would need a new guarded SPY price source and market registrations in the margin oracle and
     quoter, V4 swap routes, the isolated-margin hook on the Ramses controller, and a pair risk config.
   - Borrowing on the Ramses markets stays closed under your 2026-11-06 decision. So this is a separate product
     decision, and nothing here assumes it.
2. **TP creation while a range order is active:** refused by `MarginOrderRegistryV2`, the prepared upgrade (item 3,
   2026-11-07).
   - V1, deployed in the ceremony, stays byte-identical. V2 is a separate file: V1 plus the rule, `initializeV2` and
     one appended slot.
   - Tests: 4 for the upgrade on top of V1 with live orders (storage kept; adapter re-pointed; the old order executes
     through the new adapter; TP refused with code 7 while stop-losses stay allowed; `initializeV2` proxy-admin-only and
     one-time; non-contracts rejected).
   - 6/6 V2 mutants killed. The layout check against the V1 snapshot shows 1 appended, gap 43.
   - Its timelock call is part of the production Ledger batch.
3. **Production gaps:**
   - The removal mins are 0, because risk paths must not be blockable. Placement is single-sided out of range, and
     finalisation checks the pool against the oracle.
   - Gauge anti-sybil applies: rewards are claimed before the removal, and a removal within 99 s of placement forfeits
     that window's RAM.
   - The executor has only 64 bytes to spare.
4. **Decided 2026-11-07:** fee split 70/20/10 for the pilot; presets 1%, 3% and 5% above the market, each 2% wide; RAM
   to the order owner at finalisation. **Still undecided:** the protocol and reserve recipient addresses.

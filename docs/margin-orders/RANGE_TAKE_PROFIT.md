# Range take-profit: prototype (branch `proto/range-take-profit`, fork-tested, NOT for deployment)

Built 2026-11-06 to the operator's design: a leveraged long's stock goes into a concentrated-liquidity band entirely above
the market. Trading up through the band converts the stock to USDG; a fall back reverses that. A keeper finalises:
remove, collect, repay the current debt with interest, return the equity. **This branch is separate from
`feat/margin-order-interface`.** The executor upgrade prepared for signing is unchanged by it.

## Pieces

| piece | change | size |
| --- | --- | --- |
| `orders/range/RangeTakeProfit.sol` (new) | custodian: one Ramses NFT per order; presets; fee split; finalise; unwind; `holdings` at the oracle | 16,457 B |
| `IsolatedMarginExecutorUpgradeable` | `rangeRelease` (stock collateral to the custodian), `rangeReturn(id, settle)` (repay from USDG, stock back to collateral, debt-free exit when settling); `initializeRangeCustodian` reinitializer(3), proxy admin only; slot 25 from the gap | 24,449 B (127 spare) |
| `IsolatedMarginRiskEngineUpgradeable` | `_metrics` counts the band's holdings at the oracle; `authorizeRangeRelease` (executor only, ACTIVE accounts); `setRangeCustodian` (owner); slot 8 from the gap | 15,646 B |
| `IsolatedMarginLiquidatorUpgradeable` | `liquidate` first calls `custodian.unwind(id)`; `initializeRangeCustodian` reinitializer(2); slot 22 from the gap | 13,304 B |
| `RobinhoodMarginCloseAdapter` | optional immutable `rangeCustodian`; `closeFor` unwinds an active band before any order closes (stop-loss path) | 5,059 B |

- **Storage:** append-only, checked against `feat/margin-order-interface` from the build artifacts. Every existing slot is
  unchanged; `rangeCustodian` takes the first gap slot, and each gap shrinks by one.
- **Defaults:** all hooks are off until wired (`rangeCustodian == 0`).

## How each rule is enforced

- **Conversion is not repayment.** `finalize` marks the order `SETTLED` only after `executor.rangeReturn(id, true)`
  returns; that call accrues the debt first and repays it. A failing repay reverts the whole finalisation, and the order
  stays `ACTIVE` (tested).
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

## Evidence (fork, L2 107,658,090; nothing sent)

`test/orders/RangeTakeProfitFork.t.sol`, 14/14, runs against the **live** stack upgraded on the fork through its
ProxyAdmins as the timelock: live long position 4, the real Ramses NVDA/USDG pool and position manager.

| case | result |
| --- | --- |
| Create from position 4, preset 1 (100 ticks above, 200 wide) | band 223,330 to 223,530 below tick 223,625 (NVDA is token1); 0.00792 NVDA committed; health 37,456 bps before and after |
| Partial fill, then reversal | mid-band 0.00395 NVDA + 0.783 USDG; finalise refused; after the fall, all 0.00792 NVDA back |
| Pool moved, oracle not | still valued as all stock; finalise refused |
| Full fill, keeper finalises | debt and interest repaid to 0; position CLOSED; 3,162,996,004 pUSDG units of equity to the owner; fee split 157 / 78 USDG raw to protocol and reserve (2:1); custodian keeps nothing |
| Repay fails | finalise reverts, the order stays ACTIVE |
| Liquidation with an active band | band unwound, position LIQUIDATED, debt 0 |
| Without the pre-hook | `LiquidationError(12)`, the band stays |
| Stop-loss through the registry | band unwound first, position CLOSED, SL EXECUTED |
| Rules | TP open refuses (code 5); a second order refuses (4); non-owner, unapproved preset, distance ≤ 0, off-spacing, a bad fee split, a stale feed, the issuer pause, a pool 3% from the oracle, and a stranger's unwind all refuse; the hooks are custodian-only |

`test/orders/RangeTakeProfitSpyFork.t.sol`, 4/4, runs on the SPY deployment's **real** Ramses SPY/USDG pool `0x3845`,
gauge `0x739E` and RHSPY feed. SPY is token0 there, so the band sits above the tick (tick −210,255, band −210,155 to
−209,955). Partial fill, reversal, finalisation (debt repaid, 9.83 USDG of equity), unwind, stale feed and pause flag
all behave as on NVDA.

The other orders suites still pass on this branch: registry 32, deploy path 7, close path 10.

## Not done, and decisions for the operator

1. **SPY has no margin engine,** so the SPY test uses a labelled test-only stand-in for the margin position.
   - Hosting SPY margin would need a new guarded SPY price source and market registrations in the margin oracle and
     quoter, V4 swap routes, the isolated-margin hook on the Ramses controller, and a pair risk config.
   - Borrowing on the Ramses markets stays closed under your 2026-11-06 decision. So this is a separate product
     decision, and nothing here assumes it.
2. **TP creation while a range order is active is not refused by the registry.** Its interface and implementation are
   frozen for Monday and for the signing package. The adapter unwinds the band before any order closes, so the two never
   act on the same collateral. Strict exclusivity in that direction would be a small registry upgrade later.
3. **Production gaps:**
   - `setRangeCustodian` on the risk engine is immediate for the owner; it should be delayed like `queuePairRisk`.
   - The removal mins are 0, because risk paths must not be blockable. Placement is single-sided out of range, and
     finalisation checks the pool against the oracle.
   - No keeper for `finalize` yet. The order keeper's pattern applies: simulate, then send.
   - Gauge anti-sybil applies: rewards are claimed before the removal, and a removal within 99 s of placement forfeits
     that window's RAM.
   - The executor has only 127 bytes to spare.
   - The prototype custodian is not behind a proxy.
4. **Fee split percentages** (the tests use 70 / 20 / 10) **and the presets are undecided.** Both are parameters.

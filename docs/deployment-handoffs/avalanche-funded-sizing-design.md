# Design: funded partial liquidation without the flash-lender dependency

Status: DESIGN ONLY. No contract is changed by this document, nothing is deployed, no cap changes, handoff 00 untouched. It addresses open risk 3 of `avalanche-funded-fallback.md` and finding 12 of the independent review.

## 1. The problem, precisely

`liquidateFunded` calls `riskEngine.beginLiquidation(account)`. For a partial liquidation (health above `fullLiquidationHealthBps`) that function sizes the repay through `_liquidationQuote`, which

1. requires `config.flashLoanProvider()` to be a contract (`require(lender.code.length > 0)`), and
2. calls `lender.flashFee(debtAsset, repay)` and adds the fee value to the required seizure, and
3. grosses the required seizure up by `1/(1 - maxSlippageBps)` whenever the position and debt assets differ (it reserves swap slippage).

A funded in-kind liquidation has none of those costs: no flash loan, no swap. Consequences today: if the lender is unset, has no code, reverts in `flashFee`, or `tokenAllowed(debtAsset)` is false, `beginLiquidation` reverts and **no route can partially liquidate** the position (full liquidations, health at or below `fullLiquidationHealthBps` or dust debt, do not read the lender and still work). With a nonzero fee or any slippage bound the sizing is also too conservative for the funded route: `requiredSeizeValueUsd` is inflated, which makes `partialWouldNotImprove` or `requiredPositionPTokens >= balance` escalate a partial case to a full liquidation, i.e. the borrower is liquidated more than the in-kind route needs.

## 2. Why a generic `try/catch` is not enough

Wrapping the `flashFee` read in `try/catch` (treating a failure as fee 0) would:

- change the NORMAL flash path: if the lender is broken the flash loan itself will fail later, so the call would now fail deep inside the callback (or mis-size the repay for a lender whose fee read intermittently fails) instead of failing cleanly at sizing; the normal path must keep its behaviour;
- not cover `require(lender.code.length > 0)`, a lender returning garbage or an absurd fee, or a lender that burns the gas;
- still apply the swap-slippage gross-up for a route that never swaps, so the sizing remains wrong for the funded path whenever the lender IS healthy;
- hide the real cost model: the funded route's costs are different (they fall on the funder, not on the borrower) and should be stated in code.

So the funded path needs its own explicit sizing, not a tolerated failure of the flash one.

## 3. Proposed minimal change

### 3.1 Risk engine (`IsolatedMarginRiskEngineUpgradeable.sol`)

- Refactor the body of `beginLiquidation` into `_beginLiquidation(address account, bool funded) internal returns (uint256 maxRepayUnderlying, uint256 previousHealthFactorBps)`. `beginLiquidation(account)` becomes `return _beginLiquidation(account, false);` (same modifiers, same external ABI, same selector, **bit-identical behaviour**).
- Add `beginFundedLiquidation(address account) external onlyLiquidator` returning the same tuple via `_beginLiquidation(account, true)`.
- Add `_fundedQuote(AccountConfig memory c, uint256 repayUnderlying) internal view returns (uint256 seizeValueUsd)` used when `funded == true` instead of `_liquidationQuote`:
  `seizeValueUsd = repayValueUsd + ceil(repayValueUsd x liquidationBonusBps / 10_000)`; no flash fee, no slippage gross-up, no lender read. Rounding stays against the liquidator (value floors, bonus ceils), matching `_planFundedSeizure` in the liquidator.
- Everything else in `_beginLiquidation` (health checks, status transition to LIQUIDATING, `maxLiquidationBps`, full-liquidation thresholds, `partialWouldNotImprove`, balance check) is shared and unchanged.
- No new storage; no storage layout change; appended external function only.

### 3.2 Liquidator (`IsolatedMarginLiquidatorUpgradeable.sol`)

- `liquidateFunded` calls `riskEngine.beginFundedLiquidation(account)` instead of `beginLiquidation(account)`. One call site. `liquidate` (flash path) and `onFlashLoan` are untouched.
- The funded path's `_planFundedSeizure` already computes seizure from `repayValueUsd x (1 + bonus)`, so sizing and seizure now use the same formula (today they differ by the flash fee and slippage terms).

### 3.3 Not changed

`IsolatedMarginAccount`, `IsolatedMarginConfigUpgradeable`, the vault, the executor, the controller. No change to which prices are used or to the zero-sentinel behaviour.

## 4. Audited-file impact

| File | Change | Re-audit scope |
| --- | --- | --- |
| `IsolatedMarginRiskEngineUpgradeable.sol` | internal refactor of `beginLiquidation` + one new external function + one new internal quote | liquidation sizing; proof that `beginLiquidation` is behaviourally identical (differential tests below); access control of the new function |
| `IsolatedMarginLiquidatorUpgradeable.sol` | one call-site change in `liquidateFunded` | funded path only |

Upgrade order: the risk-engine proxy must be upgraded first (the new function must exist); a new liquidator against an old risk engine reverts on the missing function (fail closed). Fresh mainnet deployment: no migration.

## 5. Required tests (all fork tests on the pin, plus unit-level where noted)

Preservation of the normal path (must pass before and after the change, golden values recorded from the current build):
1. `beginLiquidation` differential: for a table of positions (long/short, health at, just above and below `fullLiquidationHealthBps`, dust debt) the returned `(maxRepay, previousHealth)` and the final state of `liquidate()` are identical to the pre-change build (golden constants), with a healthy lender at fee 0 and at 9 bps.
2. Normal flash liquidation still reverts exactly as before when the lender is unset, has no code, or `flashFee` reverts (the failure mode is preserved, not tolerated).

Funded path, lender unavailable or reverting (each on a partial-eligible position, long and short):
3. lender unset (`address(0)` endpoints); 4. lender is an EOA / no code; 5. lender whose `flashFee` reverts (mock contract installed through the timelocked endpoint change); 6. `tokenAllowed(debtAsset) == false`; 7. lender with an extreme fee (100 bps and `type(uint128).max`): funded partial liquidation succeeds, repay and seizure equal the fee-0 case, health improves, locked-margin accounting correct.
8. In all of 3 to 7 the flash route still fails as in test 2.

Sizing correctness:
9. Property (fuzz over pair configs and prices): funded `seizeValueUsd == repayValueUsd + ceil(bonus)`; funded required seizure <= flash required seizure for the same repay; funded never exceeds `repay x (1 + bonus)`; partial results satisfy `finishLiquidation` (health >= target or improved).
10. A case where the flash sizing escalates to a full liquidation (because of the slippage gross-up) but the funded sizing stays partial; borrower keeps more collateral; no value is created or destroyed (borrower value + funder value + debt change reconcile).
11. `positionAsset == debtAsset` (short margin) and `!=` (long) both covered.

Access and ordering:
12. `beginFundedLiquidation` is `onlyLiquidator`; a direct call by anyone else reverts; status transitions ACTIVE -> LIQUIDATING -> ACTIVE/LIQUIDATED; a revert anywhere unwinds the whole call (state unchanged).
13. New liquidator against an old risk engine reverts (documented ordering test using the pre-change bytecode).

## 6. Open points

- The funded sizing ignores the funder's own costs (redemption delay, price risk on inventory). That is intentional: they are the funder's to price through `minSeizeValueBps`, not the borrower's to pay through a smaller health improvement.
- If governance wants the funded route to share the flash route's conservatism it can set a separate funded bonus; that would be a new pair parameter and is out of scope here.
- The transfer-pause dependency (finding 13) and the oracle-only trust of the funded route (finding 14) are separate issues and are not addressed by this change.

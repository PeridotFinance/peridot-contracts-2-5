# Funded partial liquidation without the flash-lender dependency: design and implementation record

Status: **IMPLEMENTED on the draft branch, NOT audited, NOT deployed.** Two audited-scope margin files changed (risk engine, liquidator). No cap changes, no handoff 00 edit, no launch approval implied. Funded sizing does not select a margin venue or approve a funding programme. Addresses open risk 3 of `avalanche-funded-fallback.md` and finding 12 of the independent review. This document used the product name "AVAX margin trading" for the legacy isolated-margin stack (handoff 09 calls it track C; track numbering is unreconciled).

## 0. Corrections to the earlier design text

1. **The bonus floors; it does not ceil.** The first version of this design wrote the funded quote as `repayValue + ceil(repayValue x bonus)` and claimed it matched `_planFundedSeizure`. It does not: the liquidator's cap is `capUsd = repayUsd + floor(repayUsd x bonus / 10_000)` (`IsolatedMarginLiquidatorUpgradeable._planFundedSeizure`), and the later independent check `_seizedValueUsd <= capUsd` (error 31) uses that floored cap. The flash quote (`_liquidationQuote`) is the one that ceils. The implemented funded quote **floors**, so sizing and seizure use one formula and the borrower's seizure bound (seized value <= repaid value x (1 + bonus), rounded against the funder) is unchanged. A ceil in sizing would have asked for one unit more than the funded route can ever take.
2. **Natural parameters do not separate the two sizings.** The design expected states where flash sizing escalates a partial to a full liquidation (swap-slippage gross-up) while funded sizing stays partial. A scan of 227 liquidatable states (112 long, 115 short; prices stepped through the whole partial and full range, flash fee 0, placeholder pair profile with slippage bound 100 bps and bonus 5%) found **zero** such states; the lender-fee tables (0 bps, 9 bps) add 54 more compared states with no such difference either: the two sizings take the same partial/full decision everywhere. The difference appears when the lender view is unavailable (flash cannot size at all) or the fee is large (tested with a mocked fee equal to the whole debt). So the benefit of the change is the removal of the dependency, not a measurably smaller liquidation at ordinary fees.
3. **Both deployed pairs have position asset != debt asset** (long: WAVAX position, USDC debt; short: USDC position, WAVAX debt), so the slippage gross-up applies to both and no deployed pair exercises the `positionAsset == debtAsset` branch of `_liquidationQuote`. The funded quote has no such branch. A same-asset test pair was not configured.

## 1. The problem (unchanged)

`liquidateFunded` called `riskEngine.beginLiquidation(account)`. For a partial liquidation (health above `fullLiquidationHealthBps`, debt value above the 10 USD dust bound) that sized the repay through `_liquidationQuote`, which requires `config.flashLoanProvider()` to have code, calls `lender.flashFee(debtAsset, repay)`, adds the fee, and grosses the seizure up by `1/(1 - maxSlippageBps)` when position and debt assets differ. The funded route borrows nothing and swaps nothing, so if the lender was unset, had no code, reverted in `flashFee` or disallowed the token, no route could partially liquidate the position. Full liquidations (health at or below `fullLiquidationHealthBps`, or dust debt) never read the lender.

## 2. Why a generic `try/catch` is not enough (unchanged)

Treating a failed fee read as fee 0 would (a) change the NORMAL flash path (a broken lender would then fail deep inside the flash callback or mis-size the repay for an intermittently failing lender); (b) not cover `require(lender.code.length > 0)`, a lender returning garbage or an absurd fee, or gas burning; (c) keep the swap-slippage gross-up for a route that never swaps; (d) hide the real cost model. The funded route needs its own explicit sizing.

## 3. What was implemented

`IsolatedMarginRiskEngineUpgradeable.sol`:
- `beginLiquidation(account)` is now `return _beginLiquidation(account, false);` with the previous body moved to `_beginLiquidation(account, bool funded)`. Same modifier (`onlyLiquidator`), same selector, same external ABI. The only difference inside the shared body is one branch: `funded ? _fundedQuote(...) : _liquidationQuote(...)` for the partial-repay seizure requirement. Health checks, dust rule, `maxLiquidationBps`, projected-health improvement test, balance check and the transition to LIQUIDATING are shared code.
- `beginFundedLiquidation(account) external onlyLiquidator`, returning the same tuple via `_beginLiquidation(account, true)`.
- `_fundedQuote(accountConfig, repay) = repayValueUsd + floor(repayValueUsd x liquidationBonusBps / BPS)`: no lender read, no flash fee, no slippage gross-up.
- `getFundedLiquidationQuote(account, repay) external view`, the read-only twin of `getLiquidationQuote`, so the sizing is observable and testable (a new view; it has no write effect).
- No new storage. `forge inspect` layout of the new contract and of the frozen pre-change copy are identical (label, slot, offset, type; compiler AST ids in type names ignored): `tools/check-risk-engine-storage-layout.sh` (part of the gate).

`IsolatedMarginLiquidatorUpgradeable.sol`: one call site, `liquidateFunded` calls `riskEngine.beginFundedLiquidation`. `liquidate` and `onFlashLoan` untouched. The funded plan (`_planFundedSeizure`) and its independent bound check are untouched.

Not changed: account, config, vault, executor, controller, oracle, prices used, zero-sentinel behaviour.

## 4. Audited-file impact

| File | Change | Re-audit scope |
| --- | --- | --- |
| `IsolatedMarginRiskEngineUpgradeable.sol` | internal refactor of `beginLiquidation` + one external function + one internal quote + one view | liquidation sizing; the claim that `beginLiquidation` is behaviourally identical (differential tests below, but a reviewer should read the diff: the refactor is a function-body move plus one branch); access control of `beginFundedLiquidation` |
| `IsolatedMarginLiquidatorUpgradeable.sol` | one call-site change in `liquidateFunded` (on top of the funded-fallback additions already listed in `avalanche-funded-fallback.md`) | funded path only |

Upgrade order: the risk-engine proxy first (the new function must exist). A new liquidator against an old risk engine fails closed: `liquidateFunded` reverts on the missing function and changes nothing, while the flash route keeps working (tested). Rollback of the engine to the old implementation is tested; storage is untouched by either direction.

## 5. Evidence (all on the pinned fork; nothing signed or broadcast)

Test file `contracts/test/AvalancheFundedSizingFork.t.sol` (18 tests), compared against a frozen copy of the pre-change engine (`contracts/test/legacy/IsolatedMarginRiskEngineLegacy.sol`, same source as commit `b3b34c63`, only the contract name and import paths differ) placed behind the same transparent proxy by the real `ProxyAdmin.upgradeAndCall`.

| Requirement | Tests |
| --- | --- |
| Normal flash sizing unchanged | `testDifferential_BeginLiquidation_{Long,Short}`: 27 lender/price states each (healthy lender at 0 bps and 9 bps, and a lender fee equal to the whole debt), identical return values, revert data and account status vs the legacy engine, from the same chain state. The table contains states (4 per side) where funded and flash sizing differ, asserted, so a merged or swapped implementation cannot pass. `testDifferential_FlashLiquidate_{Long_Partial,Long_Full}`: end-to-end `liquidate()` leaves an identical state digest under both engines; `..._Short_OracleOnlyRevertsIdentically`: both revert identically (the oracle-only short shock hits the unfavourable swap leg; the successful short flash paths are covered by the unchanged capacity matrix, which is regenerated and compared) |
| Partial/full thresholds and dust shared | `testThresholds_{Long,Short}_SharedAndMonotone` (120 prices per side; full at or below the full-liquidation health on both routes; funded never escalates where flash does not; same partial repay; previous health identical); `testDust_FullOnBothRoutes` (7 USDC position, health 9,976 bps, full on both routes by the dust rule) |
| Borrower seizure bound, rounding | `testQuote_{Long,Short}_FloorsBonus_NeverAboveFlash` (48 pseudo-random price/repay samples per side: quote == repaid value + floored bonus, <= flash quote, <= repay x (1 + bonus); on the WAVAX-debt side floor and ceil differ in some samples, so the test distinguishes them; on the USDC-debt side they coincide by construction of 6-decimal amounts); `testFunded_StaysPartialWhereFlashEscalates_BorrowerBoundAndConservation` (seized value <= the floored cap; borrower equity falls by exactly the funder's gain within 1e-6 USD; borrower keeps position pTokens) |
| Unavailable / reverting lender | `testFunded_PartialIndependentOfLender_{Long,Short}`: lender unset; lender is an EOA; `flashFee` reverts; debt token disallowed on the real lender; 100 bps fee; absurd fee (`uint128.max`); governance `disableExecutionEndpoints`. In every state the funded partial succeeds with the same repay, same seized pTokens and (except when endpoints are disabled) the same complete end-state digest as with a healthy lender, and the flash `beginLiquidation` behaves identically to the legacy engine (failure modes preserved, not tolerated). `testAcceptance_PartialSizingIndependentOfFlashLender` (replaces the old finding test in the 40-test mechanism suite) |
| Authorization | `testAuthorization_BeginFundedLiquidation_OnlyLiquidator`: five non-liquidator callers (incl. owner and executor) revert "not liquidator" and leave status ACTIVE; healthy account reverts; LIQUIDATING account cannot be restarted; non-allowlisted funder cannot reach it |
| Rollback | `testRollback_FundedCallRevertingAfterSizingLeavesNothing`: floors unmet / max repay too low / funder cannot pay revert after `beginFundedLiquidation` moved the account to LIQUIDATING, and the whole call unwinds (state digest equal, status ACTIVE); control call then succeeds |
| Upgrade order, rollback, storage | `testUpgrade_OrderRollbackAndStorageCompatibility` (positions opened on the new engine; downgrade to legacy: raw slots 0..8 and the per-account raw struct unchanged, funded fails closed and changes nothing, flash works; upgrade again: funded works); `testUpgrade_PositionOpenedUnderLegacyEngineIsLiquidatableAfterUpgrade`; layout check script |

### Mutation checks (deliberate faults, source restored byte-identical afterwards)

| Fault | Caught by |
| --- | --- |
| `beginLiquidation` and `beginFundedLiquidation` flags swapped | both `BeginLiquidation` differentials (return data differs), both lender-independence tests, the escalation test, the acceptance test. (A first version of the differential tables used only fee 0 and 9 bps and did NOT catch this fault: the two sizings coincide there. The table was strengthened with a whole-debt lender fee and a sensitivity assertion, then the fault was caught.) |
| Funded bonus rounded up | `testQuote_Short_FloorsBonus_NeverAboveFlash` (off by one unit) |
| `onlyLiquidator` removed from `beginFundedLiquidation` | `testAuthorization_...` |

## 6. Residual risks and open points

- Not audited. The diff is small but sits in the liquidation sizing of an audited contract.
- The funded sizing ignores the funder's own costs (redemption delay, price risk on inventory); the funder prices them through `minSeizeValueBps`.
- The transfer-pause dependency (a controller transfer pause stops both liquidation routes) and the oracle-only trust of the funded route are separate issues, not addressed here.
- The `getFundedLiquidationQuote` view is new public surface; read-only.
- The tests that compare against the legacy engine prove equality on the tabulated states (27 per side plus end-to-end cases), not on all states; the argument for the rest is that the refactor is a function-body move with one branch that is only taken when `funded == true`, which only `beginFundedLiquidation` passes.

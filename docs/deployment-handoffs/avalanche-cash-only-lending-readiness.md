# Avalanche cash-only USDC/WAVAX lending: readiness report

Status: evidence summary for an operator decision (revised after review: reserve gate corrected to UNMET; margin-hooks-unset fixture added). **No launch approval is implied, no parameter or cap is proposed or changed, borrowing stays paused.** Draft. Nothing signed, broadcast or deployed.

This report is about ONE product. It is deliberately separate from the margin-trading work and from the vault work, and it uses product names because the track letters are not reconciled between the handoff files and the PR documents:

| Product name used here | What it is | Handoff 09 label (unreconciled) |
| --- | --- | --- |
| **Cash-only lending** | Fresh controller with two plain markets, pUSDC and pWAVAX, all cash stays local, no strategy | track B |
| AVAX margin trading | Legacy isolated margin through the Pharaoh adapter | track C |
| Pharaoh vaults | The two existing Pharaoh USDC / WAVAX vaults | track A |
| Pharaoh allocation | Paired strategy behind the markets (not built) | track D |

**The funded-sizing work does not change cash-only lending.** Ordinary liquidations use `PErc20.liquidateBorrow` and the controller; none of the contracts changed in the funded-fallback or funded-sizing work (margin config, margin account, margin liquidator, margin risk engine) are deployed or called by a cash-only deployment. Funded sizing also does not select a margin venue or approve a funding programme.

## 1. What a cash-only deployment contains (and what it does not)

Controller (`Unitroller` + `PeridottrollerAvalanche`), plain `PErc20Delegate` markets pUSDC and pWAVAX, `GuardedAvalanchePriceOracle` over `AvalanchePriceOracle`, interest rate models, borrowing paused at deployment. It needs no margin stack. All parameters in the tests (collateral factors 60% WAVAX / 75% USDC, rate model, reserve factor, caps) are **placeholders for measuring**, not recommendations (operator decision 3 in handoff 09).

## 2. Evidence that exists (all on the pinned fork, block 99,200,000; fork suite `AvalanchePharaohSection5ForkTest`, 35 tests, plus the capacity matrix)

| Area | Evidence | Where |
| --- | --- | --- |
| Deploy state | Both markets borrow-paused at deploy, one implementation (plain delegate, no strategy), oracle wired | `testDeploymentStateIsPausedAndWired` |
| Supply / borrow / repay | Both directions, repay with interest, borrow cap enforced, over-borrow denied, borrow rejected while paused | `testSupplyAndBorrowBothDirectionsAndRepay`, `testBorrowIsRejectedWhilePausedAndAfterCap` |
| Ordinary liquidation | Both directions; healthy account rejected; close factor 50% enforced (over-repay refused with `TOO_MUCH_REPAY`); seized value = repay x 1.08 x (1 - 2.8%) | `testOrdinaryLiquidationBothDirections`, seize-share formula in `avalanche-controller-and-guards-review.md` s2 |
| Oracle | A stale feed with an emergency price set still blocks borrowing and ordinary liquidation (mutation-checked: wiring the unguarded oracle makes it fail); bad rounds (zero, negative, future, mismatched, reverting, disabled feed) give the zero sentinel; every consumer fails closed on the sentinel | `testStaleFeedWithEmergencyPriceStill...`, `testGuardedOracleFailsClosedOnBadRounds`, `testOracleZeroSentinel_allConsumers` |
| Stale-feed account classes | Documented availability cost: while a feed is stale, suppliers who **entered** markets cannot redeem even without debt; repay always works | `testStaleFeed_accountClassMatrix` |
| USDC depeg | Debt valued at the feed price, no revert, never at 1.0 | `testUsdcDepeg_valuationFollowsFeed` |
| Mainnet controller wrapper | Chain-id and token-code checks, storage-compatible with the proxy, reviewed | `testMainnetControllerWrapper_*`, review doc s6 |
| Liquidation under gaps | Matrix slice G (see `avalanche-capacity-matrix.md`, "Ordinary lending"): no pool involved. Gradual path: no bad debt for WAVAX collateral down to -80% of the pin; USDC collateral (AVAX up) shows small bad debt (USD 8 to 10 per case) at the +300% step. After a **price gap** (no intermediate liquidations): bad debt from an AVAX fall of 40% at 99% borrow utilisation (60% at 70%); USDC collateral from AVAX +75% (99% utilisation) and +150% (70%). Liquidator budget per USD 50k of borrower collateral (5 borrowers): about USD 28k to 46k of debt asset | matrix slice G |
| Zero-cash behaviour | Cash exhaustion is tested (supplier withdrawals limited by available cash; repay always works and adds cash; ordinary liquidation needs no market cash; seized pUSDC is a claim, not cash). This is **not** a test of a borrowing reserve: there is no reserve to test (section 3, section 5) | section 5 results finding 4; `AvalancheCashOnlyLendingFork.t.sol` |
| **Dedicated cash-only fixture** | `AvalancheCashOnlyLendingForkTest` (6 tests, `test/helpers/AvalancheCashOnlyBase.sol`): controller + pUSDC + pWAVAX + guarded oracle ONLY, no margin stack, no Pharaoh adapter, no flash vault, no insurance fund; BOTH controller hooks (`isolatedMarginRiskHook`, `isolatedMarginRegistrar`) asserted `address(0)`. Covers: supply while borrowing is paused and borrow rejection while paused; borrow/repay/redeem in both directions with 30 days of interest (WAVAX collateral / USDC debt and USDC collateral / WAVAX debt), over-borrow denied, repay on behalf; ordinary liquidation in both directions (healthy account refused with INSUFFICIENT_SHORTFALL, over-repay refused with TOO_MUCH_REPAY, seized value = repay x 1.08 x (1 - 2.8%) within 1%); stale feed + emergency price (borrow rejected with PRICE_ERROR in both directions, liquidation rejected with no seize and no debt change, repay still works, entered suppliers cannot redeem until a fresh round; a control run proves the unguarded oracle WOULD have allowed the liquidation); cash exhaustion | `AvalancheCashOnlyLendingFork.t.sol` |

## 3. Handoff 09 gate for this product, item by item

The handoff-09 gate for cash-only lending is: guarded oracle with the emergency-price test; plain cash-only delegates; reserve-versus-recovery path tests; ordinary liquidation tests; funded liquidator live; monitoring. Borrowing is "a credit launch": the liquidation tests and a funded, monitored liquidator must pass **before** borrowing is unpaused.

| Gate item | State | Honest reading |
| --- | --- | --- |
| Guarded oracle + emergency-price test | **Met in tests** | Mutation-checked once. Trust assumption remains: feed address, `maxAge`, decimals and the pToken-to-asset map come from the source oracle's owner, who can widen `maxAge` or repoint a feed. The maximum age and the Chainlink heartbeat/deviation behaviour for these two feeds on mainnet are not fixed by any test |
| Plain cash-only delegates | **Met in tests** | Test asserts one shared plain implementation |
| Local borrowing reserve + reserve-versus-recovery path tests | **UNMET** | Handoff 09 section 3b REQUIRES a local borrowing reserve that applies to new borrows (and margin opens) and "must never block repayment or authorized recovery", with each path tested at and below the reserve. The plain delegates and the controller have no such mechanism, so there is nothing to enforce and nothing to test. That the delegates lack it does not make it optional. Proposed minimal enforcement: section 5; parameter values stay open |
| Ordinary liquidation tests | **Met in tests** at placeholder parameters | Results depend on the collateral factors, which are placeholders; the gap results above show bad debt appears at plausible gaps for high utilisation. Choosing CFs, caps and utilisation limits against those results is operator decision 3 and is not made here |
| Funded liquidator live | **Not met** | Tests use a harness-funded liquidator. No liquidator operator, funding, key management or bot exists |
| Monitoring | **Not met** | Nothing built (feed freshness, utilisation, shortfall accounts, liquidator balance, bad debt) |

## 4. Open items that block treating this product as ready

0. **The local borrowing reserve does not exist (gate UNMET).** See section 5.
1. **Parameters are undecided** (rate models, reserve factors, supply/borrow caps, collateral factors, cash target). The bad-debt-under-gap results make the CF/cap/utilisation choice material, not cosmetic.
2. **Lending bad-debt policy.** Plain markets give suppliers the loss; reserves come from reserve-factor interest only. No insurance or backstop for lending is designed or tested (the insurance fund in the repo belongs to margin trading). Sizing of the reserve factor against the measured gap bad debt has not been done.
3. **Liquidator operations**: who runs it, with what budget in which asset, how it is monitored, what happens when it is empty.
4. **Oracle operations**: choose `maxAge` per feed; decide the availability trade-off (entered suppliers cannot redeem during a stale-feed window); who may change feed configuration; how feed changes are timelocked.
5. **Mainnet deployment path not written or rehearsed.** The Fuji bootstrapper and deploy scripts are chain-id gated; no mainnet bootstrapper (atomic list, seed, pause, pending-admin hand-off) exists; a rehearsal on a local fork using the real script has not been done.
6. **PERIDOT token decision.** `PeridottrollerAvalanche` requires a reward-token address with code (the base contract hardcodes another chain's token). Deploy a token or a no-supply placeholder before the controller implementation; with all reward speeds at zero no claim path moves tokens (tested).
7. ~~No test runs lending with the margin hooks unset~~ **Closed by the dedicated fixture** (section 2): borrow, repay, redeem, ordinary liquidation, stale-feed rejection and cash exhaustion pass with both hooks at `address(0)` and no margin stack. Still open: the same fixture on the real deployment script (none exists).
8. **Storage layout diff** of `PeridottrollerAvalanche` against the live proxy layout is recorded as review reasoning; a `forge inspect` diff in CI is not part of any gate yet.
9. **Handoff files unreconciled.** The PR variant of handoff 00 (with section 6a) and the attached 00 are not reconciled; liquidity-policy rules in 6a may change the gate wording. No handoff 00 was edited.
10. **Pharaoh governance acceptance** (all-tracks gate in handoff 09) and the adversarial review beyond the passes already done are outstanding.

## 5. Local borrowing reserve: requirement, gap, minimal enforcement proposal (not implemented)

**Requirement (handoff 09 section 3b).** A per-market local borrowing reserve applies to NEW borrows and margin opens. It must never block repayment or authorized recovery: repay and repay-on-behalf always allowed (they add cash); normal voluntary close and normal liquidation that redeem pTokens may use reserved cash down to zero; the in-kind recovery paths are unaffected; ordinary supplier withdrawals are limited by available cash as usual, not by the reserve. Each path is tested "at and below the reserve". The reserve size ("cash target and borrowing reserve per market") is operator decision 3 and stays open here.

**Gap.** `Peridottroller.borrowAllowed` checks only listing, price, the borrow cap and account liquidity (`borrowCaps` limits total borrows, not remaining cash). The plain `PErc20Delegate` markets enforce nothing about cash. So a borrower can take the last unit of cash; only the supplier-withdrawal and recovery tests above describe what then happens.

**Minimal enforcement proposal.**
- *What:* one per-market parameter `borrowCashFloor[pToken]` (underlying units, 0 = disabled) and one check in the borrow path: a new borrow is allowed only if `PToken(pToken).getCash() - borrowAmount >= borrowCashFloor[pToken]` (and `getCash() >= borrowAmount`). It sits next to the existing borrow-cap check, which already reverts with a message in the same function.
- *Why there:* every new-risk path (ordinary borrow and, through the same `borrowAllowed`, margin opens) goes through `borrowAllowed`. None of the exit and recovery paths calls it: `repayBorrow*`, `redeem*` (own `redeemAllowed`), `liquidateBorrow` / `seize`, the margin flash liquidation (flash vault, not a pToken borrow), funded in-kind liquidation (repay + transfer) and the voluntary debt-free exit. So they cannot be blocked by the floor by construction, which the tests below must show rather than assume.
- *Where, with the least change to audited code:* `PeridottrollerAvalanche` (the Avalanche-only wrapper) overrides `borrowAllowed`, applies the floor check FIRST (a view, so a rejection changes no state), then calls the unchanged base logic. The base function must be marked `virtual` (a one-keyword change with no behaviour change). The new mapping is appended after the base's storage in the wrapper; this is safe for a fresh deployment (no live Avalanche instance), with the caveat that a future base that appends its own storage would collide, so a storage-layout check against the base belongs in the gate. Alternative: put the mapping and the check in the base `Peridottroller` as a new V9 storage contract; this touches shared code used on other chains and is not preferred. Using `borrowCaps` as a stand-in is not enforcement (it limits total borrows, not cash, and would need continuous manual updates).
- *Admin:* the floor is set only by the admin (timelocked in the intended deployment); lowering it is the loosening direction. Whether a guardian may RAISE it quickly (the safe direction) is an open choice. Events on change.
- *Not done by this proposal:* no value is chosen; the floor is not a promise of withdrawability (cash can still be taken by supplier withdrawals below the floor: that is allowed, the floor only stops new borrows); donations to the market add cash and are harmless.

**Tests required before the gate can be marked met (at and below the floor, both markets, both directions):**
1. Boundary: a borrow leaving cash exactly equal to the floor succeeds; one unit more is rejected; with the floor 0 behaviour is identical to the current controller (differential against the unchanged wrapper).
2. Below the floor (reached by a supplier withdrawal): new ordinary borrows rejected; margin opens rejected (margin product, when it is deployed).
3. Repay and repay-on-behalf succeed below the floor and raise cash.
4. Supplier withdrawals succeed up to the available cash below the floor and fail beyond it exactly as today.
5. Ordinary liquidation succeeds below the floor in both directions; margin close, flash liquidation and funded in-kind liquidation succeed below the floor.
6. Setter authorization, event, storage layout (appended slots only), and that no exit path reads the floor.

## 6. What this report does not say

- It does not say lending is safe at any particular cap, collateral factor or utilisation.
- It does not say borrowing may be unpaused. The tested state is "paused at deployment"; unpausing is a separate decision gated on the funded liquidator, monitoring and the local borrowing reserve.
- Nothing in the margin work (capacity matrix verdicts, funded fallback, funded sizing) is a precondition for or evidence about this product other than the shared oracle and controller tests listed in section 2.

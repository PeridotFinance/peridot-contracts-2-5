# Avalanche cash-only USDC/WAVAX lending: readiness report

Status: evidence summary for an operator decision. **No launch approval is implied, no parameter or cap is proposed or changed, borrowing stays paused.** Draft. Nothing signed, broadcast or deployed.

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
| Zero-cash behaviour | Plain markets have no local borrowing reserve, so the reserve-versus-recovery tests reduce to cash exhaustion: repay always works; supplier withdrawals are limited by cash as usual | section 5 results, finding 4 |

## 3. Handoff 09 gate for this product, item by item

The handoff-09 gate for cash-only lending is: guarded oracle with the emergency-price test; plain cash-only delegates; reserve-versus-recovery path tests; ordinary liquidation tests; funded liquidator live; monitoring. Borrowing is "a credit launch": the liquidation tests and a funded, monitored liquidator must pass **before** borrowing is unpaused.

| Gate item | State | Honest reading |
| --- | --- | --- |
| Guarded oracle + emergency-price test | **Met in tests** | Mutation-checked once. Trust assumption remains: feed address, `maxAge`, decimals and the pToken-to-asset map come from the source oracle's owner, who can widen `maxAge` or repoint a feed. The maximum age and the Chainlink heartbeat/deviation behaviour for these two feeds on mainnet are not fixed by any test |
| Plain cash-only delegates | **Met in tests** | Test asserts one shared plain implementation |
| Reserve-versus-recovery path tests | **Partly met / mostly moot** | There is no borrowing reserve in plain delegates, so there is nothing to test "at and below the reserve". Cash-exhaustion behaviour is tested. If the operator wants a local borrowing reserve, it is new work |
| Ordinary liquidation tests | **Met in tests** at placeholder parameters | Results depend on the collateral factors, which are placeholders; the gap results above show bad debt appears at plausible gaps for high utilisation. Choosing CFs, caps and utilisation limits against those results is operator decision 3 and is not made here |
| Funded liquidator live | **Not met** | Tests use a harness-funded liquidator. No liquidator operator, funding, key management or bot exists |
| Monitoring | **Not met** | Nothing built (feed freshness, utilisation, shortfall accounts, liquidator balance, bad debt) |

## 4. Open items that block treating this product as ready

1. **Parameters are undecided** (rate models, reserve factors, supply/borrow caps, collateral factors, cash target). The bad-debt-under-gap results make the CF/cap/utilisation choice material, not cosmetic.
2. **Lending bad-debt policy.** Plain markets give suppliers the loss; reserves come from reserve-factor interest only. No insurance or backstop for lending is designed or tested (the insurance fund in the repo belongs to margin trading). Sizing of the reserve factor against the measured gap bad debt has not been done.
3. **Liquidator operations**: who runs it, with what budget in which asset, how it is monitored, what happens when it is empty.
4. **Oracle operations**: choose `maxAge` per feed; decide the availability trade-off (entered suppliers cannot redeem during a stale-feed window); who may change feed configuration; how feed changes are timelocked.
5. **Mainnet deployment path not written or rehearsed.** The Fuji bootstrapper and deploy scripts are chain-id gated; no mainnet bootstrapper (atomic list, seed, pause, pending-admin hand-off) exists; a rehearsal on a local fork using the real script has not been done.
6. **PERIDOT token decision.** `PeridottrollerAvalanche` requires a reward-token address with code (the base contract hardcodes another chain's token). Deploy a token or a no-supply placeholder before the controller implementation; with all reward speeds at zero no claim path moves tokens (tested).
7. **No test runs lending with the margin hooks unset.** Every fork test deploys the margin stack too (`isolatedMarginRiskHook` is wired). A cash-only deployment would leave the hooks unset; the controller paths with the hook at the zero address have not been exercised in this suite and should get their own test before deployment.
8. **Storage layout diff** of `PeridottrollerAvalanche` against the live proxy layout is recorded as review reasoning; a `forge inspect` diff in CI is not part of any gate yet.
9. **Handoff files unreconciled.** The PR variant of handoff 00 (with section 6a) and the attached 00 are not reconciled; liquidity-policy rules in 6a may change the gate wording. No handoff 00 was edited.
10. **Pharaoh governance acceptance** (all-tracks gate in handoff 09) and the adversarial review beyond the passes already done are outstanding.

## 5. What this report does not say

- It does not say lending is safe at any particular cap, collateral factor or utilisation.
- It does not say borrowing may be unpaused. The tested state is "paused at deployment"; unpausing is a separate decision gated on items 3 (funded liquidator) and the monitoring item above.
- Nothing in the margin work (capacity matrix verdicts, funded fallback, funded sizing) is a precondition for or evidence about this product other than the shared oracle and controller tests listed in section 2.

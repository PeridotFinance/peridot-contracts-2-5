# Avalanche funded in-kind forced-liquidation fallback: implementation, tests, funding numbers

Branch `avalanche-pharaoh-tracks-abcd`. Tests and fork only: nothing signed or broadcast, no keys. This closes the open requirement in `avalanche-section5-fork-results.md` ("Funded in-kind fallback: not implemented", shared risk model section 10, handoff 09 section 3b "Forced liquidation").

Contract entry point: `IsolatedMarginLiquidatorUpgradeable.liquidateFunded(FundedLiquidationParams)`.
**Funded-sizing update:** after `avalanche-funded-sizing-design.md` was implemented, the 40-test mechanism suite (with `testFinding_PartialSizingNeedsFlashLenderView` replaced by `testAcceptance_PartialSizingIndependentOfFlashLender`), the 35-test section 5 suite, the 18-test `AvalancheFundedSizingFork.t.sol` suite and the 31-test capacity matrix all pass on the warm local cache (gate run on the working tree on top of `b3b34c63`); the regenerated capacity report is byte-identical to the committed one apart from one new status field, including the finite-funding fallback tables. That run was NOT an isolated-cache clean reproduction; an isolated-cache run populated across retries at the later final code checkpoint (all of these suites passed on its attempt 3) is described in `avalanche-clean-repro-final/README.md`.

Tests: `contracts/test/AvalancheFundedFallbackFork.t.sol` (40 tests, inherits `AvalancheSection5Base`; **40 pass**). **Status update (checkpoint `988b836c`):** the deliberate failure `testRequirement_fundedInKindForcedFallback_UNMET` is RETIRED. It was replaced (not removed) by the acceptance tests `testAcceptance_fallback_*` in `AvalanchePharaohSection5Fork.t.sol` (zero cash long and short, pool wall, atomic exhaustion, invalid price, authorization / repeat / ownership); that suite now has 35 tests (34 original plus `testFinding_transferPauseStopsAllMarginLiquidations`) and the gate no longer carries a deliberate failure. The numbers below that mention "28 pass, 1 fail" belong to the earlier state and are historical. Existing non-fork margin suites re-run against the changed contracts: `IsolatedMarginFujiPolicy` 14, `IsolatedMarginV2` (two suites) 4 + 29, `FujiMockMargin` 7 + 14, `CollateralPreservingLifecycle` 70: all pass.

What this route is **not**: it does not solve missing valuation (every price failure still reverts it, tests d) and it does not guarantee recovery of an already insolvent position (section "Insolvent positions" has the measured bad debt). It only removes the dependency on a flash loan, a swap and market cash for a position that is still liquidatable at a trustworthy price.

## What it does

One call by an allowlisted, funded liquidator:

1. `config.fundedLiquidators(msg.sender)` must be true (else `LiquidationError(27)`).
2. Execution status ACTIVE, accrue interest, `riskEngine.beginLiquidation(account)` (the **first** price-touching call: a zero sentinel from the guarded oracle reverts `PriceUnavailable(asset)`). The repay amount is exactly what the risk engine returns (partial `maxLiquidationBps`, or full). The caller can neither shrink it nor name a price.
3. Seizure plan (view-only arithmetic, rounding against the funder): `repayUsd = riskEngine.underlyingValueUsd(debtPToken, repay)` (floor), `capUsd = repayUsd + floor(repayUsd x liquidationBonusBps / 10_000)`. No flash fee and no slippage gross-up (the flash quote adds them for a swap that does not happen here).
   - Partial: position pTokens = floor(pTokens worth `capUsd`), capped at the balance; margin pTokens are never touched; locked margin is reduced pro rata exactly as the flash path (ceil, with the same two sanity reverts).
   - Full: position pTokens first, up to the cap. Only if the whole position is worth less than the cap does the funder also take margin pTokens (second asset, long only), up to the remaining cap. Everything not seized is the borrower's.
   - Independent bound: `riskEngine.pTokenValueUsd(seized)` summed must be `<= capUsd` (else `LiquidationError(31)`).
   - Caller protection: `maxRepayUnderlying` (spend cap, `28`), `minPositionPTokens`/`minMarginPTokens` (`30`), `minSeizeValueBps` (seized value / repaid value, `10_000` = break-even, `32`).
4. Funds in (`transferFrom(funder)`, exact amount, balance-delta checked), `repayBorrowBehalf(account, repay)`, then in-kind movement with a same-block `authorizeMovement` per transfer and the new `account.liquidationTransfer`: seized pTokens go straight to `recipient`.
5. Full liquidation surplus: remaining **margin** pTokens go to the liquidator contract and into `vault.releaseFromLiquidation(id, fullLock, marginLeft)` (owner's free balance, locked margin cleared, identical to the existing path). Remaining **position** pTokens (the non-margin asset, e.g. pWAVAX for a long) cannot go through the vault release (it only accepts the lock's margin pToken), so they are transferred in kind to `position.owner`. This is a deliberate deviation, listed for the re-audit.
6. `riskEngine.finishLiquidation` (partial: health must reach the target or strictly improve; full: stored debt must be zero), then `executor.recordLiquidation`. Any revert anywhere unwinds everything (the whole call is one transaction with no callback): debt, collateral, vault and executor accounting are untouched (tests c, d, f, g compare a full state hash before and after).

Insurance fund: **not used** by the fallback (decision). Drawing it would need either a redemption (impossible at zero cash) or a new in-kind top-up surface, and the funder is a voluntary, allowlisted party. A funder who would lose money should not call; `minSeizeValueBps = 10_000` makes the chain refuse instead.

Reentrancy: `nonReentrant` (shared with `liquidate()`); with real USDC/WAVAX/pTokens there is no callback surface. The flash path (`liquidate`, `onFlashLoan`) is textually unchanged.

## Changed audited files (re-audit note)

| File | Change | Upgrade/layout |
| --- | --- | --- |
| `contracts/margin/IsolatedMarginAccount.sol` | New `liquidationTransfer(pToken, amount, recipient) onlyLiquidator` (margin/position pToken only, `PErc20.transfer` must return true). | **Non-upgradeable**. Only new accounts have it. The mainnet stack is a fresh deployment (no existing accounts). Existing Fuji accounts do not have it: for them `liquidateFunded` reverts and the flash route is unaffected. |
| `contracts/margin/IsolatedMarginConfigUpgradeable.sol` | New `mapping(address => bool) fundedLiquidators` (append, slot 8 after `_feeDistributionConfigured`), `__gap` 39 -> 38 (verified with `forge inspect ... storage-layout`: slot 8 mapping, gap slots 9..46, same end slot). New `queueFundedLiquidator`, `addFundedLiquidator` (timelocked through the existing `_queue`/`_consume`, same `actionDelay`, cancellable with `cancelAction`), `removeFundedLiquidator` (immediate, owner only, risk-reducing like `disablePair`), event `FundedLiquidatorSet`. | Append-only. Already deployed config proxies must be upgraded **before** the liquidator is upgraded (the liquidator reads `fundedLiquidators`). |
| `contracts/margin/IsolatedMarginLiquidatorUpgradeable.sol` | New `liquidateFunded` + helpers, structs, event `FundedPositionLiquidated`, error codes 27 to 32, minimal interface `IFundedLiquidatorRegistry`, imports. **No new storage** (no pending struct: no callback). | Runtime size 18,162 B (profile `debt_accounting`), under the limit. |

Relied on, **not** changed (semantics must stay): risk engine `beginLiquidation`/`finishLiquidation`/`authorizeMovement`/`_consumeMovement`/`pTokenValueUsd`/`underlyingValueUsd`/`oracle()`; `IsolatedMarginVaultUpgradeable.releaseFromLiquidation`; `IsolatedMarginExecutorUpgradeable.recordLiquidation`; controller `transferAllowed` hook for margin accounts and the blocked ordinary seizure; the guarded oracle. Oracle/slippage guards, pair parameters and all other repositories untouched. Deployment scripts (`DeployIsolatedMarginAvalanche.s.sol`, `ConfigureIsolatedMarginPairAvalanche.s.sol`) are **not** updated (not mine): the operator step after deployment is `config.queueFundedLiquidator(funder)`, wait `actionDelay` (at least 1 hour), `config.addFundedLiquidator(funder)`.

## Test results (40 of 40 pass, pinned block 99,200,000, mocked feeds as in the Section 5 suite)

| Scenario | Tests | Result |
| --- | --- | --- |
| (a) zero collateral-market cash, long and short, partial and full | `testZeroCash_{Long,Short}_{Partial,Full}`: market of the position token drained (pWAVAX for the long, pUSDC for the short, cash <= 1); flash `liquidate()` reverts `RedeemTransferOutNotPossible`; funded call succeeds, cash stays 0 (nothing was redeemed), funder gets pTokens and no underlying | pass x4 |
| (b) swap dead | `testPoolWall_Long_...` (pool sold to its floor, 127 chunks, USD 108.6k; oracle 60% of pin) and `testPoolWall_Short_...` (pool pumped to its wall, USDC 4.925M; oracle 155%): flash reverts "Too little received", funded succeeds. `testSwapDeadAndLenderDisabled_...`: router and flash lender disabled by governance, **full** funded liquidation still works | pass x3 |
| (c) exhausted funding | `testFundingExhausted_{Long,Short}`: no balance and no allowance, balance only, allowance only, short balance, short allowance: each reverts, state hash unchanged; positive control works | pass x2 |
| (d) invalid prices | `testInvalidPrices_{Long,Short}`: stale AVAX (asset in the error is WAVAX), stale AVAX plus emergency price on the inner oracle (still blocked), USDC feed reverting, USDC feed zero (asset in the error is USDC); control with valid prices works; state unchanged | pass x2 |
| (e) repeats and sequences | `testSequence_{Long,Short}_PartialThenFullThenRepeat` (partial, immediate repeat reverts "healthy", deeper shock full, repeat after LIQUIDATED reverts `LiquidationError(8)` on both routes), `testSequence_FundedPartialThenFlashFull_Long` | pass x3 |
| (f) authorization | allowlist: unauthorised, queued-but-not-added, removed (immediate), owner-only, timelock "not ready", "not queued", zero address, cancel; flash `liquidate()` stays permissionless. Account/risk engine/vault/executor entry points reject strangers; a direct account transfer without authorization is rejected by the controller (`TransferPeridottrollerRejection(4)`) | pass x2 |
| (g) bonus and surplus bounds, adversarial | `testBonusBound_{Long,Short}_{Partial,Full}`: seized value <= repaid x 1.05 and (asserted to within 1e-9, measured within about 3e-13) of it, full: account emptied, seized + returned == original balance, value conserved, lock deleted. `testAdversarialFunder_*`: min above bound, margin demand in a partial, spend cap below repay, value floor above 1 + bonus (10_501 bps) all revert atomically, exact bound passes; recipient zero, the margin account itself, or any other registered margin account refused (`testAdversarial_RecipientCannotBeAnotherMarginAccount`, `LiquidationError(9)`). `testAdversarial_DonationsDoNotChangeSeizure`: stray balances do not change the result | pass x8 |
| (h) deep underwater | `testInsolvent_{Long,Short}_...`, `testInsolvent_BorderlineForcesFull`: a break-even floor refuses the call; a willing funder clears the debt, takes everything, absorbs the loss; insurance balances unchanged | pass x3 |
| (i) ownership, locked margin | `testOwnership_{Long,Short}_PartialAccounting` (recipient gets pTokens not underlying; account, executor, vault per-user and total locked move together; reduction == ceil(locked x seized / balance); vault covered; liquidator holds nothing), `testExtraMargin_*` (long with added margin pUSDC: partial never takes margin; full takes position first then margin to the cap and returns the margin remainder through the vault; full where the position alone covers the cap returns BOTH the position remainder to the owner and all margin through the vault in one call; position + all margin below the cap leaves the borrower nothing), `testEvent_...` | pass x7 |
| Acceptance (was a finding) | `testAcceptance_PartialSizingIndependentOfFlashLender` (funded PARTIAL completes with the lender view disabled; replaced `testFinding_PartialSizingNeedsFlashLenderView` when funded sizing was implemented) | pass |
| Quantification | `testQuantify_PerPositionBudgets`, `..._AggregateStress`, `..._RedemptionDelay_{Long,Short}`, `..._BadDebtSweep` | pass x5 (numbers below) |

Gas of a funded liquidation: long about 0.58M, short 0.55M partial and 0.69 to 0.70M full (flash long liquidation in the Section 5 results: 1.57M).

## Mutation checks (one safeguard removed at a time, then restored; 23 mutants)

Killed (the named test fails): allowlist check removed (`testAuthorization_Unauthorized...`); timelock `_consume` removed (same test); account `onlyLiquidator` removed (`testAuthorization_NoOtherEntryPoints`); bonus doubled (`testBonusBound_Long_Partial`, `testAdversarialFunder_Long`); over-seize with the bound check kept (reverts `LiquidationError(31)`, `testBonusBound_Long_Partial`) and with the check removed (assertion "seized value exceeds repaid x (1 + bonus)"); `minPositionPTokens` removed; `minSeizeValueBps` removed (`testAdversarialFunder_Long`, `testInsolvent_Long`); `maxRepayUnderlying` removed; recipient restriction weakened to "own account only" or removed (`testAdversarial_RecipientCannotBeAnotherMarginAccount`); `finishLiquidation` removed (`testZeroCash_Long_Partial`); `authorizeMovement` removed (controller rejects the transfer); owner position-remainder return removed (`testBonusBound_Long_Full`); margin remainder return removed and vault release with `returned = 0` (`testBonusBound_Short_Full`); locked reduction ceil -> floor (`testOwnership_Long`); ACTIVE status check removed (`testSequence_Long`); margin top-up unbounded (`testExtraMargin_Full_TopsUp...`); funds pull removed (`testFundingExhausted_Long`).

**Survived (honest list):**
- Balance-delta check on the funding pull (`LiquidationError(29)`): needs a fee-on-transfer debt token; USDC and WAVAX are not. Untested guard.
- `nonReentrant` on `liquidateFunded`: no callback surface with USDC/WAVAX/pTokens, so no test can reenter. Defence in depth, untested.
- Zero check inside the liquidator's own `_priceOf`: dominated by `beginLiquidation`, which reverts first with the same `PriceUnavailable`. Removing it changes nothing observable.
- Final value-bound check (31) when removed **alone**: the floor arithmetic already holds the bound. It is shown to be effective in the over-seize mutant (it is the check that fires there).

## Funding economics (measured, placeholder parameters: 2x, 50%/25% margins, bonus 5%, max liquidation 50%, position cap USD 50k, debt cap USD 25k)

All figures are for oracle-only shocks on the real pool at the pin (AVAX about USD 8.55); the funded route does not touch the pool.

### Debt-asset budget per position (what the funder must hold and approve)

| Position | Event | Debt asset budget (= repay) | pTokens received | Value received | Bonus |
| --- | --- | --- | --- | --- | --- |
| LONG, margin 5,000 USDC (debt 4,900.99 USDC) | partial, AVAX at ~66% of pin | 2,450.50 USDC | 22,791 pWAVAX (~456 WAVAX) | USD 2,571.93 | USD 122.47 |
| | full, AVAX 54% | 4,900.99 USDC | 55,711 pWAVAX | USD 5,143.85 | USD 244.95 (borrower keeps USD 195.43 as pWAVAX) |
| SHORT, margin 5,000 USDC (debt 578.82 WAVAX) | partial, AVAX ~151% | 289.41 WAVAX (USD 3,736) | 196,225 pUSDC | USD 3,922.84 | USD 186.80 |
| | full, AVAX 180% | 578.82 WAVAX (USD 8,907) | 467,822 pUSDC | USD 9,352.46 | USD 445.36 (borrower keeps USD 592.44 through the vault) |
| LONG, margin 24,000 (cap-sized, debt 23,524.75 USDC) | partial | 11,762.38 USDC | 109,397 pWAVAX | USD 12,345.25 | USD 587.87 |
| | full | 23,524.75 USDC | 267,415 pWAVAX (5,348 WAVAX) | USD 24,690.50 | USD 1,175.74 |
| SHORT, margin 24,000 (cap-sized, debt 2,778.33 WAVAX) | partial | 1,389.17 WAVAX (USD 17,933) | 941,881 pUSDC | USD 18,829.62 | USD 896.65 |
| | full | 2,778.33 WAVAX (USD 42,754 at the 180% price) | 2,245,545 pUSDC | USD 44,891.82 | USD 2,137.71 |

Take-aways: the budget is about 100% of the debt for a full liquidation and 50% for a partial one. A short's budget is in **WAVAX** and grows with the price at which the short is liquidated (2,778 WAVAX is USD 23.7k at the pin and USD 42.8k at +80%). The funder must already hold the debt asset (or buy it into the squeeze).

### Aggregate stress (one funder, full liquidations in sequence)

4 longs of 10,000 USDC margin liquidated at AVAX 54% of pin: **39,207.92 USDC** budget, inventory 445,691 pWAVAX = 8,913.8 WAVAX. 3 shorts of 6,000 USDC margin liquidated at 180%: **2,083.75 WAVAX** budget, inventory 1,684,158 pUSDC = 33,683 USDC. (Two separate price directions, so two separate budgets.)

Budget scales linearly with debt. At the proposed caps (debt cap USD 25k per position): about 23.5k USDC per long or 2,778 WAVAX per short. If margin debt used all the test borrow caps (USDC 500k, WAVAX 20k) the worst-case funder budget is about **500k USDC and 20,000 WAVAX** (about USD 171k at the pin, about USD 308k at +80%). The earlier remark that the pool could absorb about USD 15k of aggregate long notional (and therefore that the funded route "needs only about USD 7.5k of USDC") is **withdrawn**: it came from favourable-state depth arithmetic, not from executed stress scenarios (the strict matrix, `avalanche-capacity-matrix.md`, derives no cap). Aggregate caps should be set so that this worst-case budget is actually held by the allowlisted funders.

### Inventory and a delayed redemption (market cash zero)

The funder holds pTokens that can only be redeemed from market cash. With cash at zero (utilisation 100%) the supply carry at the test rate model is about 28.8% APY simple (placeholder IRM), but the exit needs borrowers to repay or new suppliers to deposit.

| | Long cap-sized, full (inventory 5,348 WAVAX, USD 24,690) | Short cap-sized, full (inventory 44,911 USDC) |
| --- | --- | --- |
| Cost basis | 23,524.75 USDC paid; bonus if redeemed at the liquidation price USD 1,165.75 (4.96%) | 2,778.33 WAVAX (USD 42,754) paid; bonus USD 2,137.71 (5.0%) |
| Redemption blocked (zero cash) | `redeem` reverts `RedeemTransferOutNotPossible` | same |
| Share of the market | 30.2% of pWAVAX supply (market 17,697 WAVAX, 100% borrowed): exit needs at least 5,348 WAVAX of repayments | 9.9% of pUSDC supply (452,740 USDC) |
| Carry while waiting | USD 19.5 / 136.3 / 584.3 for 1 / 7 / 30 days | USD 35.4 / 248.0 / 1,062.7 |
| Price loss on the inventory | AVAX -10%: USD 2,469; -20%: USD 4,938; -30%: USD 7,407 | USDC peg -1%: USD 449; -3%: USD 1,347; -10%: USD 4,491 |

Reading: for a long the whole 5% bonus is erased by an AVAX move of about -4.7% before the inventory can be sold; 30 days of carry (USD 584) recovers about half the bonus only if no price move happens. The short is paid in a stable asset, so the delay costs time value, not price; the price risk of a short sits in how the funder acquires the WAVAX it repays. Redemption delay has no time bound in this design: it ends only when cash returns.

### Insolvent positions (measured, not recoverable by this route)

If collateral value is below the debt, a full liquidation is forced (health cannot improve) and the funder absorbs the shortfall. 5,000 USDC margin: long at AVAX 30% of pin: debt USD 4,898.91, assets USD 2,966.27, **bad debt USD 1,932.64 (39.4%)**; short at 280%: debt USD 13,855.50, assets USD 9,944.90, **bad debt USD 3,910.60 (28.2%)**. In both the funder who calls with no floor loses exactly that amount; with `minSeizeValueBps = 10_000` the call reverts and the bad debt stays in the lending market (position stays ACTIVE and liquidatable). Insurance balances are unchanged by the fallback (asserted).

Cap-sized (24,000 margin) bad debt by price (USD, share of debt): long at 49% of pin: 280 (1.2%); 45%: 2,176 (9.3%); 40%: 4,547 (19.3%); 30%: 9,289 (39.5%); 20%: 14,031 (59.7%); 10%: 18,773 (79.8%). Short at 205%: 972 (2.0%); 220%: 4,535 (8.7%); 250%: 11,661 (19.6%); 300%: 23,537 (33.0%); 400%: 47,289 (49.8%); 600%: 94,794 (66.5%). The funder is made whole plus the bonus only inside a price window: the long becomes liquidatable at about 66% of pin and insolvent below about 49.5% (about 16 points); the short at about 151% and insolvent above about 202% (about 51 points). The test insurance fund (seeded at about 1% of each market: USD 5.0k pUSDC plus USD 1.28k pWAVAX at the pin) would not cover one cap-sized long at -70% (USD 9.3k) even if the fallback used it.

## Open risks and limits

1. **Valuation**: any invalid price blocks the route (tests d). It does not provide a recovery valuation.
2. **Insolvency**: not recovered unless a funder chooses to absorb the loss; no insurance draw. Residual bad debt is the table above. Deciding whether the insurance fund should ever top up a funded liquidation is a governance decision and a new surface.
3. **Partial sizing needed the flash lender view: RESOLVED on this branch (not audited).** `riskEngine.beginFundedLiquidation` sizes the funded route without a lender read, flash fee or swap-slippage gross-up; `beginLiquidation` is unchanged (differential tests against a frozen copy of the pre-change engine). Design, corrections (the bonus floors, it does not ceil), audited-file impact, tests and mutation checks: `avalanche-funded-sizing-design.md`. The re-audit scope now includes the risk engine and one call site in the liquidator.
4. **Approvals**: the funder approves the liquidator **proxy**. The proxy is upgradeable. Funders should approve only the amount of the call (or the exact budget) and revoke afterwards.
5. **Funder risk is the operator's to size**: bonus 5% (placeholder) versus a -4.7% price move on a long inventory; redemption delay is unbounded. Aggregate caps must be set against the funded budgets above, not the pool depth.
6. **Borrower surplus on a full long liquidation returns as pWAVAX to the owner's wallet, not as pUSDC in the vault** (see design). Locked margin is cleared to zero in both.
7. **Fresh deployment assumption**: the account change reaches only new accounts. Existing Fuji accounts cannot be funded-liquidated.
8. Same-block movement authorizations left after a full liquidation are not consumed (debt is zero, as in the flash path); harmless in state LIQUIDATED.
9. Rounding: seized pTokens are floored and valued with floor/ceil on the safe side; the borrower can keep at most a few pToken units of dust; the bound tests measure seized value within about 3e-13 (relative) of the cap.
10. Mocked feeds: all prices are mocked at the aggregator (as in the Section 5 suite); only deployments, the pool and token balances are real.

## Reproduction

### Clean reproduction (authoritative)

- Code commit: `988b836c64370a2ce73cff1cb68775b8a1efdaba` (working tree identical to the commit for every code and tool file; only documents changed afterwards).
- Pinned state: Avalanche C-Chain 43114, block **99,200,000**, hash `0x221a26c046d7c21cd8dc88ea808ccf2b0e9811916e1f091cc4b3222c5e11fd97`, timestamp 1793604320.
- Environment: an **isolated empty Foundry home** (empty RPC cache; only the solc toolchain is linked in), RPC `https://api.avax.network/ext/bc/C/rpc` only, **no proxy and no substituted values**, `FOUNDRY_PROFILE=debt_accounting`.
- Command: `AVALANCHE_MAINNET_RPC_URL=<rpc> contracts/tools/run-avalanche-clean-repro.sh` (runs `tools/run-avalanche-section5-gate.sh` under the clean home and retries because a public RPC rate-limits a cold cache; every attempt fills the isolated cache).
- Result: attempt 1 failed while the cache was cold (suites `section5` and `funded-fallback` failed and the matrix was incomplete; the cause is most likely public-RPC rate limits as in the earlier cold runs, but the log of that attempt was overwritten by attempt 2 and was not retained). **Attempt 2 passed**: generator fixtures pass; `AvalanchePharaohSection5ForkTest` 35 of 35; `AvalancheFundedFallbackForkTest` 40 of 40; capacity matrix 31 of 31 tests in 217 s, 168 manifest scenarios and 64 fallback scenarios all with rows, 0 NOT-RUN, 0 conflicting records; exit 0. The generated matrix report from this clean run is **byte-identical** (0 differing lines) to the report from the earlier warm-cache run at the same commit.

### Earlier runs, and the count "74 of 74" versus 35 + 40 = 75

- The builder's original 40/40 run used a **substituted** RPC path: a local pass-through proxy in front of `avalanche-c-chain-rpc.publicnode.com` that answered zero for two never-written allowance slots and the balance/nonce/code of two codeless addresses when the node timed out at the pinned block (details below). Its entries had entered the shared global Foundry RPC cache for block 99,200,000. That run is **superseded** by the clean reproduction above and is not evidence of the clean result.
- The lead then moved that cache file aside (backup kept), re-ran the section 5 and fallback suites against `api.avax.network` only (attempts 1 and 2 hit rate limits; **attempt 3: all 74 tests passed**). At that moment the section 5 suite had **34** tests; **34 + 40 = 74**. The 75th test is `testFinding_transferPauseStopsAllMarginLiquidations`, added afterwards (the reviewer's transfer-pause finding), so the current counts are **35 + 40 = 75**, matching the clean reproduction.

### Original builder run (superseded): how it was run and the RPC substitution

```
AVALANCHE_MAINNET_RPC_URL=<fork rpc> FOUNDRY_OUT=out_fallback FOUNDRY_CACHE_PATH=cache_fallback FOUNDRY_PROFILE=debt_accounting \
forge test --threads 1 --match-contract AvalancheFundedFallbackForkTest -vv \
  --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol
```

`avalanche-c-chain-rpc.publicnode.com` times out (30 s, deterministic) on `eth_getStorageAt`/`eth_getBalance` for never-written slots and codeless accounts at the pinned historical block, which the new flows need (for example the ERC-20 allowance from the funder to the fork-only liquidator proxy). The runs here went through a local pass-through proxy (kept outside the repository) that forwards everything and, only when the node times out at the pin **and** the same node returns zero/empty code for `latest`, answers zero. It zero-filled exactly 2 storage slots (the funder's USDC and WAVAX allowance to the liquidator proxy, which exists only in the fork) and the balance/nonce/code of two codeless addresses (`address(0)`, `0xBEEF`; native balances are not asserted anywhere). Foundry's shared local RPC cache for block 99,200,000 therefore now holds those zero entries. A re-run on the lead's archive endpoint should give identical results; I could not do that run. The harness addresses (CAROL as funder, `KEEPER_RECIPIENT` as recipient, DAVE as stranger) were reused so the existing warm cache is used.

Process note: while debugging I ran one `pkill -f "forge test"`, which could have killed a concurrent `forge test` of the lead (pid 27312); if a lead run aborted around that time, rerun it. Build directories `contracts/out_fallback` and `contracts/cache_fallback` are untracked artifacts of the requested isolated build.

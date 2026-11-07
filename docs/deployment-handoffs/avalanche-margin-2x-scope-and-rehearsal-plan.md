# Avalanche margin 2x on Pharaoh WAVAX/USDC: scope and fork rehearsal plan

Status: **SCOPE AND PLAN FOR REVIEW, NOTHING BUILT, NOTHING SIGNED OR BROADCAST.** Written 7 Nov 2026 from the sources on branch `avalanche-pharaoh-tracks-abcd` (`d84db887`) and the order layer on `feat/margin-order-interface` (`010b30ac`, read only, its worktree untouched). Every claim below names its source; what is not yet measured is marked **TO MEASURE**.

Fixed by the operator: existing isolated-margin stack unchanged in storage; Pharaoh WAVAX/USDC pool; position cap USD 5,000; maintenance 25%; liquidation funded by the two operators (assisted liquidation is the design); the TP/SL registry from `feat/margin-order-interface` as the order layer with an Avalanche close adapter; enable by 18 Nov.

## 1. The stack in one paragraph (from the sources)

A position lives in its own `IsolatedMarginAccount`, held as **lending pTokens**: margin pUSDC, position pWAVAX, debt borrowed from pUSDC. The controller treats these accounts specially through two hooks (`_setIsolatedMarginRiskHook`, `_setIsolatedMarginRegistrar`, `Peridottroller.sol:1133,1142`). Open and close go through a **flash loan** from a funded `SimpleFlashLoanVault` and a **swap** through `PharaohCLRouterAdapter`, pinned to the WAVAX/USDC pool `0xf01449C0…9534` (tick spacing 10). Liquidation has two routes: the flash route (`liquidate`, swaps into the pool) and the **funded in-kind route** (`liquidateFunded`, an allowlisted funder repays the debt and receives pTokens plus a bonus; no pool, no flash loan). Config changes sit behind a timelock (`actionDelay`, default 24 h).

## 2. Findings that shape the scope

| # | Finding | Source | Consequence |
| --- | --- | --- | --- |
| F1 | **Long only.** A short borrows WAVAX; PW30 keeps WAVAX borrowing **paused** and `borrowAllowed` reverts on the pause before it reaches the margin hook. | `Peridottroller.sol:383`; ceremony doc | Scope is "long AVAX with USDC margin and USDC debt". A short needs WAVAX borrowing enabled, which contradicts the PW30 design. Not proposed. |
| F2 | **Margin debt shares the lending USDC budget.** The market borrow cap (`totalBorrows + new < cap`) and the cash floor apply to margin accounts too. PW30: cap USD 5,000, pUSDC cash 6,350, floor 1,250. | `Peridottroller.sol:402-408`; ceremony doc | If the team borrows the full 4,900, margin has no room. A 2x position at the USD 5,000 cap takes margin 2,500 and **debt about 2,450**. Decision D2. |
| F3 | **The normal liquidation route cannot reach the trigger.** At 2x and 25% maintenance a long is liquidatable at about **-33%** (equity 25% of gross assets); the strict matrix found no PASS for the pool route at that trigger (the pool has no liquidity out there; 100 bp of oracle lag already fails every size). The funded route settles positions that are solvent at the oracle price. | `avalanche-margin-options.md` s1; `avalanche-funded-fallback.md` | The two operators are **the** liquidation mechanism, as you decided. They must be on the `fundedLiquidators` allowlist (timelocked queue, then add). |
| F4 | **The operator package has no margin awareness.** The monitor's borrower index follows `Borrow` events on pUSDC, so margin accounts will appear in it; the lending executor would try `liquidateBorrow` on them and the controller blocks ordinary seizure of margin accounts. | `operator/src/borrowers.ts`; funded-fallback doc | Needs a classifier (`isolatedMarginAccounts`) and a **margin liquidation step** (new). |
| F5 | **No mainnet scripts.** Both scripts hard-require Fuji (chain id 43113) and carry Fuji confirmation gates. | `DeployIsolatedMarginAvalanche.s.sol:84`, `ConfigureIsolatedMarginPairAvalanche.s.sol:34` | New mainnet variants in new files; the Fuji ones stay untouched. |
| F6 | **About 45 Ledger signatures** if the existing monolithic script is run as is (21 deployments, about 25 wiring and ownership calls). | script count | Split into three re-runnable stages with read-back checks between them (decision D7). |
| F7 | **The funded liquidation is a transfer of pTokens, and WAVAX is redeemable here.** In the stress tests redemption failed because the market was 100% borrowed. In PW30 nobody can borrow WAVAX, so pWAVAX cash equals the deposits. | funded-fallback doc ("inventory"); ceremony doc | The operator can redeem its bonus-bearing pWAVAX. **TO MEASURE** in the rehearsal (redeem of the seized amount while borrowers' collateral stays deposited). |
| F8 | **The executor has no third-party close.** `closePosition` requires `msg.sender == owner`. `feat/margin-order-interface` adds `closePositionFor(owner, params)` to the same file (+41 lines, gap slot 40 -> 39, layout unchanged, size 22,141 B). | `git diff` of the executor between the branches | The mainnet margin stack is a **fresh deployment**, so the order executor change ships in the first implementation; no upgrade of a live proxy. |
| F9 | **Stop-loss tolerance is clamped by the pair.** The registry allows 300 bp, the pair's `maxSlippageBps` is 100; the adapter uses the tighter (as the Robinhood adapter does). | `RobinhoodMarginCloseAdapter.sol:148` | A stop-loss in a fast move can revert and stay open. Liquidation remains the backstop. The keeper and the frontend must show this. |
| F10 | **The registry admin on Avalanche is the Ledger**, not a timelock contract (the SPEC names "the chain's timelock"). | `SPEC.md` deployment convention | Admin powers are pause only; no admin path executes, modifies or redirects an order. State it in the ceremony. |
| F11 | **Pool at the live head** (block 99,667,577): AVAX feed USD 8.275; the pool holds 813,607 USDC and 283,951 WAVAX. The old evidence is pinned at block 99,200,000 (sell side about USD 98.5k). | live read | Re-measure depth, open/close cost and the round trip at a recent pin (**TO MEASURE**); frontend note. |
| F12 | **`AVALANCHE_RPC` answers HTTP 403 "Unspecified origin not on whitelist".** Reads in this report used the established endpoint. | live call | I do not work around an origin allowlist. The old 99.2M-pin suites need archive state and wait for an endpoint that serves it; the new rehearsals pin to recent heads. |

## 3. Scope

**In**
- Long AVAX / USDC 2x through the existing executor, risk engine, vault, liquidator, swap module and CL adapter. Margin asset USDC.
- Pair risk (proposed): `maxLeverageX100` 200, `initialMarginBps` 5,000, `maintenanceMarginBps` **2,500**, `liquidationTargetBps` 12,500, `fullLiquidationHealthBps` 5,000, `maxLiquidationBps` 5,000, `liquidationBonusBps` 500, `maxSlippageBps` 100, `oracleDeviationBps` 100, `maxPositionValueUsd` **5,000e18**, `maxDebtValueUsd` **2,500e18** (these are the Fuji defaults except maintenance, the position cap and the debt cap).
- `closePositionFor` in the executor (taken verbatim from `e8f225ba` so the two branches merge cleanly), the registry and interfaces, and **`AvalancheMarginCloseAdapter`** (new; the Robinhood adapter's construction with the Avalanche oracle and quoter).
- Mainnet deploy and configure scripts (new files), staged; ceremony document; fork rehearsal; operator margin liquidation step and monitor classification.
- Interface handoff for the Stellar agent (`avalanche-margin-close-path-interface.md`).

**Out**
- Shorts (F1). Any pair other than WAVAX/USDC. Changing the lending pilot caps (D2). Audit work. The Pharaoh vault-share collateral adapters. Automated recycling of the operators' pWAVAX inventory (alerts and a documented manual step; D4).

## 4. Build list

| Piece | File(s) | Notes |
| --- | --- | --- |
| Order executor change | `IsolatedMarginExecutorUpgradeable.sol` | verbatim from `e8f225ba`; layout check; size under 24,576 |
| Registry and interfaces | `margin/orders/*` | verbatim from the order branch (no edits) |
| Avalanche close adapter | `margin/orders/AvalancheMarginCloseAdapter.sol` | long only (reverts for SHORT); price = margin oracle; minimum from the quoter less the tighter slippage; never below debt plus flash fee |
| Mainnet scripts | `script/DeployIsolatedMarginAvalancheMainnet.s.sol` (stages 1-3), `ConfigureIsolatedMarginPairAvalancheMainnet.s.sol`, `DeployMarginOrdersAvalanche.s.sol` | new files; `ceremony/margin-pw30.env` public values only |
| Ceremony wrapper | `tools/avalanche-ceremony.sh` (new `margin-*` subcommands) | same `verify live` read-only pattern as PW30 |
| Operator | `operator/src/margin.ts` (liquidation step), classifier in `borrowers.ts`/`executor.ts`, config block, tests | funded route only; exact-need allowance to the liquidator proxy; daily cap; halt; `minSeizeValueBps` 10,000 |
| Rehearsals | `test/AvalancheMarginMainnetRehearsalFork.t.sol`, `operator/scripts/rehearse-margin.ts` | section 5 |
| Docs | ceremony, frontend notes (exit cost, TP/SL clamp), host-setup addition | |

## 5. Fork rehearsal plan

All local; nothing signed. Pin: a recent head (F12). Prices: the real Chainlink rounds, then shocked with mocked aggregators (a fork cannot move real feeds), as in the existing suites. Fork jobs one at a time.

**R-A. Foundry fork suite on the exact PW30 parameters** (CF WAVAX 30%, USDC 0%, cap 5,000, floor 1,250, seeds as in the ceremony). The stack is created by running **the new mainnet scripts**, not by hand wiring, with the Ledger impersonated.
1. Deploy stages 1-3; `verify` reads: owners, wiring, hooks, opens paused, fees, fee stream, oracle prices non-zero, flash lender funded.
2. Queue pair risk, funded liquidators and unpause; before the delay each execution reverts; after `warp(actionDelay)` each succeeds; cancel works.
3. Lifecycle: open at 2x with margin 2,500 (success); margin 2,501 or leverage 201 or position above 5,000 (reverts, each with its code); add collateral; partial and full close; funds returned to the owner; debt zero; dust bounds.
4. Shared budget (F2): lending borrowers at 4,900 then a margin open (refused by cap or floor); the reverse order; ordinary borrowers and the lending liquidation cycle unchanged.
5. Liquidation: shock to 66%, 60%, 50%, 45%, 30%. The funded route by each operator: partial then full; budget equals the debt repaid; bonus at most 5%; the flash route as a control (expected to fail or succeed, recorded); insolvent case with and without the break-even floor; non-allowlisted caller refused; removal is immediate.
6. F7: the operator redeems the seized pWAVAX to WAVAX with borrowers' pWAVAX collateral still deposited; amount and cash read back.
7. Orders: registry created through the script; adapter wired once via `upgradeAndCall` with `initializeOrderExecutor` (second call reverts; non-admin reverts); TP and SL created, executed at the trigger by a third party, owner receives the proceeds, caller nothing; partial; expiry; owner closes directly (orders cancel); liquidation cancels orders; pause stops only execution; the stop-loss clamp (F9) shown with a fast-move shock.
8. Pool cost at the pin: open and close at 500, 2,500 and 5,000; round-trip exit cost; swap module floor behaviour with 0, 50 and 100 bp of oracle lag.
9. Layout check of the executor against the pre-change layout; runtime sizes.

**R-B. Operator rehearsal on anvil** (`operator/scripts/rehearse-margin.ts`, the harness that already runs the lending cycle): a test wallet opens a position; the mocked feed falls; the monitor classifies the margin account (no lending liquidation attempted); the margin step liquidates partially, then fully; allowance exact-need and revoked; daily cap and halt trip; a stale price stops it (nothing sent); the unrecoverable-debt alert fires for the insolvent case; restart mid-liquidation resumes from the pending marker.

**R-C. Mutation checks** on the new code, one safeguard at a time: adapter owner check, price equality check, slippage clamp, long-only guard, minimum-by-debt floor, operator allowance bound, daily cap, classifier, allowlist in the script wiring.

**R-D. Full pipeline once**, in order: PW30 ceremony on the fork, margin stages, timelock warp, enable, open, TP executed, SL clamped, liquidation by operator 1 and 2, close. The log is the rehearsal evidence in the ceremony document.

Pass criteria: every assertion green; mutants killed or documented; `verify live` equals the expected-state table; layout identical; sizes under the limit.

## 6. Schedule (latest dates; each step starts when the previous one is done)

| Date | Delivered |
| --- | --- |
| 7 Nov | this document and the interface handoff |
| 9 Nov (Mon) | executor change, registry and adapter compiled; ABIs committed for the Stellar agent; a fork recipe that brings up the whole stack locally with an addresses file |
| 10 Nov | mainnet scripts and ceremony wrapper; R-A items 1-3 |
| 12 Nov | R-A complete; pool cost numbers |
| 14 Nov | operator margin step and R-B; R-C; R-D |
| 15 Nov | ceremony document final; **prepared** (the R3 ceremony is the same day) |
| 16 Nov | Ledger: deploy stages 1-3, hook wiring, **queue** pair risk, funders and unpause; funding of the flash vault and insurance fund |
| 17 Nov | Ledger: execute the queued actions after the delay |
| 18 Nov | `verify live`; unpause opens; operators confirm `fundedLiquidators`; **enabled** |

The deploy stages are inert (opens paused) and can run any day after 11 Nov; the earlier they run, the earlier the 24 h clock starts. The 16 Nov date is the latest, not the target.

## 7. Decisions and inputs (defaults apply unless you say otherwise)

| # | Question | My default |
| --- | --- | --- |
| D1 | `actionDelay` | 24 h (the tested default); queue on the deploy day |
| D2 | Shared USDC budget (F2) | no change to the pilot caps: margin opens only inside the headroom left by the cap and the floor. To make room, raise the cap to 7,500 **and** add 2,500 USDC of supply; that is a live parameter change for you |
| D3 | Who absorbs bad debt beyond about -49% (scaled from the measured table: about USD 29 at -51%, 230 at -55%, 470 at -60%, 970 at -70% on a 2,450 debt) | the operator declines (floor 10,000); debt stays in the market; the monitor's unrecoverable-debt alert fires; the insurance fund is not used by the funded route. Say if you want the fund seeded and used |
| D4 | Inventory | each operator already holds at least USD 3,750; a full margin liquidation uses up to 2,450 USDC and returns about 2,570 of pWAVAX. No automated recycling; a low-inventory alert and a manual step |
| D5 | Flash vault funding | 3,000 USDC from the Ledger side (open needs the debt amount plus a margin), fee 0 |
| D6 | Insurance fund seed | the deploy gate requires a non-zero pUSDC balance; propose 250 USDC of pUSDC |
| D7 | Ledger signing | three staged runs (about 15 signatures each) rather than a bootstrapper contract |
| D8 | Who writes the Avalanche adapter | **me** (it is coupled to the executor, quoter and the rehearsal). The Stellar agent takes the keeper and the range take-profit against the interface handoff. Tell me if you meant the other split |
| D9 | Order-layer code | copied verbatim from the order branch into this branch, so the later merge sees identical changes; I do not merge anything |

Inputs for the ceremony: the Ledger with AVAX for about 45 transactions (estimate 0.6 AVAX, **TO MEASURE** on the fork), the 3,000 + 250 USDC of D5 and D6, and the operators' public addresses (already requested).

## 8. What this does not remove

- A price gap beyond about -50% in one oracle update leaves bad debt that nobody is obliged to cover (D3).
- The funded route needs a valid price: a stale or zero Chainlink round stops liquidation and the order execution alike.
- The operators carry pWAVAX price risk from the moment of liquidation (a -4.7% AVAX move erases the 5% bonus).
- Transfer pause on a pToken stops both liquidation routes (measured finding in the Section 5 suite).
- The pool route for closes can fail at depth or at oracle lag; owners then cannot exit by themselves until the gap closes (the funded liquidation does not depend on the pool).

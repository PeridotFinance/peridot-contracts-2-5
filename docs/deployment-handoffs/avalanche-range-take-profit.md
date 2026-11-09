# Range take-profit for the 2x WAVAX long on Pharaoh (port of PR #7), PROTOTYPE

**Nothing in this document is deployed, signed, sent or merged.** Everything was run on forks (Foundry `createSelectFork` and a local anvil on 127.0.0.1) at one pinned block, **99,859,291** (Avalanche C-Chain, 9 Nov 2026). The margin stack itself is not live yet (`avalanche-pilot-addresses.json` has `margin: null`), so every test deploys it on the fork with the real four-stage script and then applies the range upgrade described below. No address in this document is a mainnet address of anything new.

New files only: `contracts/range-tp/` (Foundry project), `range-tp-keeper/` (TypeScript keeper), this document. `operator/`, `contracts/contracts/`, `contracts/script/`, `contracts/vault-r3/` and the `.wt-orders` worktree are untouched (read only). The three engine changes the feature needs are delivered as copies and as patches that `git apply --check` accepts against the current originals (section 4); they are the upgrade the real stack would need, not applied.

## 0. Read this first: what "70/20/10" means, and what I built

PR #7 (`proto/range-take-profit`, "Range take-profit prototype (NVDA), fork-tested") uses **70/20/10 as a FEE split**: user / protocol / reserve shares of the **swap fees** a band earns (`setFeeSplit(userBps, protocolBps, reserveBps, ...)`, snapshotted into each order). Its presets are **1 %, 3 % and 5 % above the market, each 2 % wide**, and one order is **one band** at one of them.

The brief for this port says the take-profit is "split 70/20/10 across the preset levels". That is a different thing: **three bands per order**, 70 % of the collateral at the first level, 20 % at the second, 10 % at the third. PR #7 does not do that.

I implemented **both**, as separate, independent parameters, so that nothing is lost whichever you meant:

| | what | where |
| --- | --- | --- |
| Presets 1, 2, 3 | one band at +1 %, +3 %, +5 % (PR #7 verbatim: 100 / 300 / 490 ticks above the current tick, 200 ticks wide) | `RangeTakeProfit` table |
| **Preset 4: the ladder** | **three bands, 70 % / 20 % / 10 % of the collateral at +1 % / +3 % / +5 %** (the brief's reading) | `RangeTakeProfit` table |
| Fee split 70/20/10 | user / protocol / reserve shares of swap fees (PR #7's reading); admin parameter, snapshotted per order, **default 100/0/0** | `setFeeSplit` |

**Open question 1 (yours):** which one did you mean? If only the ladder: leave the fee split at 100/0/0 (it is the default). If only PR #7's fee split: disable preset 4 (`setPreset(4, false, ...)`). Nothing else changes. See also section 7: on the live Pharaoh pool the fee split currently pays nothing, because the pool gives LPs no swap fees.

## 1. The product as built

A 2x long (collateral pWAVAX, debt USDC, from `DeployAvalancheMarginMainnet`) can opt in to a range take-profit. The owner calls `createRangeOrder(positionId, presetId, positionPTokens)` (0 = all the collateral). The custodian then:

1. takes the position's WAVAX out of the margin account (executor hook `rangeRelease`);
2. splits it by the preset's weights (the last rung takes the rounding remainder);
3. mints one Pharaoh NFT per rung, **single-sided WAVAX, entirely above the current tick** (WAVAX is token0 of the pool, so a band above the tick holds only token0). Near edge = current tick + the level's distance, snapped **up** to the tick spacing (10), so it is never closer than the preset says; upper edge = near edge + width;
4. refuses the order if the position would be liquidatable once the bands are valued (the risk engine counts the bands at the **oracle** price, never the pool's).

As the market trades up through a rung its WAVAX becomes USDC; a fall back reverses that. Nothing is final until a keeper calls `finalize(positionId)`:

* it handles **every rung the pool tick has fully crossed** (tick >= the rung's upper tick), removes its liquidity, collects, applies the slippage floor, sends the proceeds to the margin account, and **calls the executor's `rangeReturn`, which repays the current debt (accrued interest first) from that USDC before anything else**;
* when **no rung remains active**, `rangeReturn(settle = true)` also exits the debt-free position: the equity goes to the owner exactly as the normal close path does (margin pTokens credited in the margin vault, position pTokens to the wallet);
* when rungs remain (a ladder crossed in stages), the position stays open, **debt-free if rung 1 covered it**, with the surplus USDC held as margin collateral and the other rungs still in the pool; the owner receives the equity when the last rung is finalised, or after a cancel and a normal close. **While rungs remain the position cannot be closed** (the risk-engine guard of section 4 and the defect in section 8). (Open question 3.)
* the order is SETTLED only after the executor's repay returned; a failing repay reverts the whole finalisation and the order stays ACTIVE (tested).

The owner cancels with `unwind(positionId)`: every active rung is removed, WAVAX goes back to collateral, any USDC from partial fills goes to the debt first. Cancel reads no price and has no floor (a risk path must never be blockable). `unwind` is callable only by the owner, the liquidator contract and the order adapter.

### Preset table as ported (tick spacing 10; 1.0001^ticks)

| preset | levels | distance above the tick | width | weight | price above the market (near edge) | band (near to far edge) |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 1 | 100 ticks | 200 | 100 % | +1.005 % | +1.0 % to +3.0 % |
| 2 | 1 | 300 ticks | 200 | 100 % | +3.05 % | +3.0 % to +5.1 % |
| 3 | 1 | 490 ticks | 200 | 100 % | +5.02 % | +5.0 % to +7.2 % |
| **4 (ladder)** | 3 | 100 / 300 / 490 | 200 each | **70 % / 20 % / 10 %** | as 1, 2, 3 | rung 1 [+1, +3], rung 2 [+3, +5.1], rung 3 [+5.0, +7.2] |

Consequences of PR #7's numbers that I kept: in the ladder, rung 1 and rung 2 **touch** (rung 1's upper tick = rung 2's lower tick), and rung 2 and rung 3 **overlap by one tick spacing** (rung 2's upper tick is 10 above rung 3's lower tick). That is harmless for correctness (separate NFTs, each finalised by its own upper tick) and is asserted in `test_02`. Presets are admin parameters (`setPreset`, admin = the timelock behind the proxy), validated: distance and width positive and multiples of the pool's tick spacing, 1 to 3 levels, weights sum to 10,000.

## 2. Files and how to run

```
contracts/range-tp/
  foundry.toml                    profile = the margin engine's `debt_accounting` (solc 0.8.35, cancun, via-IR, runs 1); lib -> ../lib (as vault-r3)
  run-fork.sh                     takes the shared fork lock, pins RANGE_FORK_BLOCK (default 99,859,291), exits 42 on any 429 / rate-limit text
  src/RangeTakeProfit.sol         the custodian (24,236 B of 24,576)
  src/vendor/*                    Uniswap v4 TickMath, FullMath, ... copied unmodified from PR #7
  src/engine/*                    range-aware copies of executor, risk engine, liquidator, close adapter (PR #7's hooks on the Avalanche sources)
  patches/*.patch                 the same as diffs against the originals; `git apply --check` passes (tools/make-patches.sh regenerates them)
  test/RangeFixture.sol           shared fixture (live PW30 + Pharaoh at the pin, real margin script, range upgrade, mocked Chainlink)
  test/RangeLifecycleFork.t.sol   20 tests: presets, ladder, lifecycle, partial fill, reversal, cancel, fee split
  test/RangeRiskFork.t.sol        23 tests: rules, price conditions, floors, hooks, liquidation, stop-loss, the orphan guard, rewards
  test/KeeperFixtureDump.t.sol    builds and dumps the state the keeper's anvil test replays (1 test)
  tools/mutation-check.py         12 mutants, one fork job at a time, always restores the file
range-tp-keeper/                  TypeScript keeper (ethers 5.8.0), 28 unit tests with fakes + 1 anvil fork test
```

```
# compile (no network): sizes
cd contracts/range-tp && forge build --sizes

# fork tests (ONE fork job at a time; the script takes /tmp/pilot-fork.lock and releases it)
export AVALANCHE_MAINNET_RPC_URL=...        # environment only, never printed or written
cd contracts/range-tp && ./run-fork.sh --match-contract "Range(Lifecycle|Risk)ForkTest" -vv
./run-fork.sh --match-contract KeeperFixtureDump -vv     # writes fixtures/ (gitignored) for the keeper's fork test

# keeper
cd range-tp-keeper && npm install && npm test             # 28 unit tests, no network
./run-fork-test.sh                                        # the anvil fork test (lock, fixture, MockFeed artifact required)
```

## 3. Results (pinned block 99,859,291)

### 3.1 Foundry fork tests: 44 of 44 pass

`./run-fork.sh --match-contract "Range(Lifecycle|Risk)ForkTest|KeeperFixtureDump"` at block 99,859,291: **`RangeLifecycleForkTest` 20/20, `RangeRiskForkTest` 23/23, `KeeperFixtureDump` 1/1**. Position: 90 USDC margin at 2x = 20.1005 WAVAX collateral, 88.218 USDC debt, pool tick -254,520 (WAVAX about 8.87 USDC). The fixture runs the real margin script on the fork (stage 1 to 4), opens the position through the real vault and executor, upgrades the engine through the ProxyAdmins, and drives the **real Pharaoh router into the real pool** to move the market.

| scenario | result |
| --- | --- |
| create, presets 1 / 2 / 3 | bands [-254,420, -254,220], [-254,220, -254,020], [-254,030, -253,830]; all 20.1005 WAVAX committed; NFT held by the custodian; health unchanged (20,152 bps before and after); nothing left in the account |
| create from an off-spacing tick (-254,513) | near edge snapped away: -254,410 (not -254,420, which would be 93 ticks away) |
| create, ladder | 3 rungs, 70.00 / 20.00 / 10.00 % of the committed collateral (last rung takes the remainder), summing exactly; rungs 1 and 2 touch, 2 and 3 overlap by one spacing |
| lifecycle, each preset | not reached: finalise refuses (`BandNotFullyConverted`); market through the band: `finalize` by a stranger: debt repaid to 0, position CLOSED, custodian holds nothing, **owner equity 93.24 / 96.91 / 100.46 USDC from 90 margin** (presets 1 / 2 / 3) |
| ladder staged | rung 1 (70 %) crossed: finalise **repays the debt first**, position stays ACTIVE, debt-free, nothing paid out, order ACTIVE (rungs 2, 3 active); rung 2, then rung 3: the last finalisation closes the position, **equity 94.70 USDC** |
| ladder in one move | one `finalize` takes all three rungs, position CLOSED |
| partial fill, then reversal | mid-band: 10.03 WAVAX + 90.50 USDC at the oracle; finalise refused; price back: WAVAX back; owner cancel restores the collateral |
| price returns inside the range after crossing | not final; refused; converts again when the market returns |
| half the collateral committed | band's USDC repays the debt; order SETTLED; position closed (the proceeds covered the debt) |
| owner cancel | all collateral back, debt untouched, NFTs burned, idempotent, a stranger refused, a new order is possible |
| cancel after a partial fill | the partial fill's USDC repays debt first, WAVAX back to collateral |
| fee split 70/20/10 | **stubbed fees**: 20 % and 10 % of 10 USDC paid to protocol and reserve, snapshot kept after a later change; a failing recipient transfer never blocks finalisation. Live pool: **no swap fees at all** (`feeProtocol` 100 %) |
| rules | not owner, disabled preset, too much collateral, second order, open TAKE_PROFIT in the registry (code 5; a STOP_LOSS does not block), custodian not wired, wrong pool token order, preset validation, fee-split validation |
| price conditions | stale oracle refuses create and finalise (`OracleUnavailable`), cancel still works; pool 3 % from the oracle refuses create, and refuses finalise until the oracle follows; the band is valued at the **oracle**, so pushing the pool through a band changes no health figure; a position already 36 % down (liquidatable) cannot place bands |
| floors and failures | a principal 2 % short of the liquidity maths: `SlippageFloor`, nothing moves; repay failing (stubbed): whole finalisation reverts, order, rung and NFT unchanged, then finalises when the repay works; finalise with nothing active refuses; dust (1 pWAVAX wei) mints in every rung and cancels |
| hooks | executor hooks custodian-only (`ExecutorError(61)`), risk-engine release executor-only, wiring one-shot, custodian change refused while bands are active |
| **liquidation with a 3-rung band** | after a 36 % oracle fall the position is liquidatable (bands count at the oracle); the funded operator's call **unwinds first** (all NFTs burned, order UNWOUND), then seizes; a healthy position's band survives a liquidator's attempt; a stranger cannot call `unwind` |
| **stop-loss through the adapter** | adapter v2 unwinds first, then the normal close: position CLOSED, debt 0, order UNWOUND; counterfactual: an owner close while the collateral sits in a band fails |
| **orphan defect** (section 8) | after rung 1 the debt-free exit and the full close are refused while rungs 2, 3 hold collateral; after a cancel the exit works. Before the risk-engine guard the exit succeeded |
| rewards | 3 days half-filled then cancelled: about 349 PHAR forwarded to the owner (logged, not asserted); xPHAR and a failing PHAR transfer recorded in `rewardClaimable`, a reverting claim leaves the record intact (stubbed balances); a reverting `getReward` does not block the removal |

Gas (forge, warm; the anvil figure is a real transaction, cold): `createRangeOrder` **972k** (1 rung) / **1.91M** (3); `finalize` **1.02M** (1 rung, closes the position) / **0.71M** (rung 1 of a ladder, position stays open) / **0.81M** (last rung, closes) / **1.64M** (3 rungs at once) / **1.85M** on the anvil fork; `unwind` **1.09M** (3 rungs); `liquidateFunded` with a 3-rung band **1.67M**; stop-loss close with a 3-rung band **2.53M**. At 25 gwei, 1.85M gas is 0.046 AVAX.

### 3.2 Keeper

* **28 unit tests, all pass** (fakes, no network): waits, simulate-then-send, pending marker persisted before the send, the three wait errors, refusal with cooldown, halt on a mined revert, halt keeping the marker on an unknown error, halt on a read-back mismatch, halt on a marker found at start-up, halted does nothing, fee cap, gas floor, send budget, removal recorded once, cursor, a failing read does not stop the others, no `unwind` in the ABI or the source, no import from `operator/`, state file atomic and mode 600, secret masking, config validation, log pacing and 429 back-off (copied tests), wait-timer cleared.
* **1 fork test, passes** (local anvil at the pin, 127.0.0.1 only, the Foundry state replayed, accounts impersonated): the ladder is fully crossed (3 of 3 ready); with the AVAX feed stale the keeper's simulation says `OracleUnavailable` and **sends nothing** (nonce unchanged); with a fresh feed it sends **one** `finalize` (1,854,827 gas), reads back (3 rungs SETTLED, `RangeOrderSettled` event, position CLOSED), the debt goes 88.218 USDC to 0, the owner holds 94.70 USDC of equity in the margin vault, the custodian holds no USDC and no WAVAX, the state file records it, and a further step sends nothing. Run 5 times in total; no HTTP 429 was seen by the proxy.

### 3.3 Mutation check (`contracts/range-tp/tools/mutation-check.py`)

12 mutants, one at a time, each a compile plus a full fork run of the 43 lifecycle and risk tests, the source restored after each (verified byte-identical afterwards): **12 killed, 0 survived, 0 inconclusive.**

| id | mutation | tests that failed |
| --- | --- | --- |
| M1 | finalise without the pool-vs-oracle check | 1 |
| M2 | finalise without the slippage floor | 1 |
| M3 | finalise never settles the position | 10 |
| M4 | a partly filled rung is finalised (tick >= lower) | 2 |
| M5 | `unwind` open to anyone | 2 |
| M6 | `liquidateFunded` does not unwind | 1 |
| M7 | band snapped toward the market (floor instead of ceil) | 1 |
| M8 | last rung does not take the rounding remainder | 6 |
| M9 | no liquidatable check after the bands are placed | 1 |
| M10 | the orphan guard removed from the risk engine | 1 |
| M11 | a second order on the same position accepted | 1 |
| M12 | readiness gate uses the lower tick | 3 |

A first run of 9 mutants had two survivors (M7, M9): the pool tick at the pin is a multiple of 10 so floor and ceil coincide, and no test placed bands for an already-liquidatable position. `test_01d` and `test_28` were added and now kill them. The mutation check is evidence about these tests, not about the design.

## 4. The engine changes the feature needs (and why nothing can be done without them)

PR #7's custodian cannot work on its own: the collateral cannot leave the margin account without an executor hook, the position would be liquidatable the moment it left without a risk-engine valuation of the band, and a liquidation or stop-loss would find no collateral without an unwind hook. The brief forbids touching `contracts/contracts`, so the hooks are **copies in `contracts/range-tp/src/engine/`**, with PR #7's diff applied to the Avalanche sources and one addition for Avalanche (item 4). In the fork tests the real stack is deployed by the real script and then its executor, risk engine and liquidator proxies are upgraded **through their own ProxyAdmins as the Ledger (the timelock's role)**, exactly as PR #7's fork tests did. `patches/*.patch` are the same changes as diffs; `git apply --check` passes against the current originals.

| contract | change (all from PR #7 unless marked) | size under the `debt_accounting` profile |
| --- | --- | --- |
| executor | `rangeRelease` (collateral to the custodian, custodian only), `rangeReturn(id, settle)` (repay from USDC first, stock back to collateral, debt-free exit when settling, custodian only), `initializeRange` (reinitializer 3, proxy admin only: sets the custodian and re-points `orderExecutor` to adapter v2); `rangeCustodian` takes slot 25 from the gap (39 to 38) | **24,471 B, 105 B spare** (original 21,885 B) |
| risk engine | `_metrics` counts the bands' holdings at the oracle; `authorizeRangeRelease` (executor only); `initializeRangeCustodian` (reinitializer 2); queue / apply / cancel for later changes, **apply refused while any band is active**; 2 slots from the gap. **Added for the ladder (not in PR #7): `beginDebtFreeClose` and a full `finishClose` refuse while a band holds the account's collateral** ("RiskEngine: range order active"; section 8) | **17,979 B** (original 15,504 B) |
| liquidator | `unwind` before seizure; `initializeRangeCustodian`; 1 slot from the gap. **Added for Avalanche (not in PR #7): the same hook in `liquidateFunded`**, because Avalanche's operators liquidate through the funded route; PR #7 hooked only `liquidate` | 18,739 B (original 18,121 B) |
| close adapter | immutable `rangeCustodian`; `closeFor` unwinds an active order before any close (stop-loss path) | 5,089 B (original 4,848 B) |

Headline: **the executor fits, with 105 bytes to spare** (PR #7 had 64 on Robinhood). Any further executor change will not fit without moving code out.

Things the engine change implies that are **not** in these files: the registry re-pointing to adapter v2 (PR #7 does it with `MarginOrderRegistryV2` and its `initializeV2`, which also refuses a take-profit order while a range order is active), a storage-layout snapshot check for the custodian (PR #7's `check_registry_layout.py` and `range-layout.json`), and a deploy script. The tests use adapter v2 with the test contract as its "registry" to exercise the stop-loss path.

## 5. What is different from PR #7 (every difference, with the cause)

Caused by Pharaoh vs Ramses (or Avalanche vs Robinhood):

| # | PR #7 (Ramses, NVDA/USDG, Robinhood) | this port (Pharaoh, WAVAX/USDC, Avalanche) |
| --- | --- | --- |
| P1 | the stock can be token0 or token1; both branches (NVDA is token1, SPY token0) | **WAVAX must be token0**; `initialize` refuses any other pool. One branch, fewer untested paths. Band is always above the tick, holds only token0 |
| P2 | LPs earn swap fees; the 70/20/10 fee split pays protocol and reserve (157 / 78 USDG raw in PR #7's run) | **the live WAVAX/USDC pool has `feeProtocol` = 1,000,000 (100 %) at the pin: LPs earn no swap fees.** Measured: a fully crossed rung returned exactly the principal (`quoteFees` 0). The fee split machinery is ported and tested (with the position manager's `collect` stubbed), but pays nothing on the live pool unless governance changes `feeProtocol`. Section 7 |
| P3 | gauge rewards are RAM, forwarded whole to the owner at finalisation | rewards are **PHAR and xPHAR**. PHAR transfers; **xPHAR is transfer-restricted** (a transfer to an ordinary address reverts: checked on the fork). The reward step never reverts the removal: PHAR goes to the owner, any share that cannot be sent is recorded in `rewardClaimable[owner][token]` and the owner can claim it with `claimRewards`; a reverting `getReward` is swallowed (tested). The `exitXPhar` helper I wrote was removed to stay under the size limit; the owner exits xPHAR from his own wallet |
| P4 | removal minimums are 0 and the pool-vs-oracle check is the only guard | **finalisation applies a slippage floor at the pair's own `maxSlippageBps` (100)**, two anchors, the larger wins: (a) the USDC principal must be at least the liquidity maths of a fully converted rung times (1 - 100 bp); (b) at least the committed WAVAX times the **oracle price at creation** times (1 - 100 bp). The risk path (`unwind`) still has no floor and reads no price |
| P5 | the liquidator hook is in `liquidate` | also in `liquidateFunded` (Avalanche's primary liquidation route). Tested with a 3-rung band: the liquidator unwinds first, the operator seizes the collateral, the NFTs are burned |
| P6 | fee-share transfers and the reserve `deposit` | a fee-share transfer that fails (USDC can blacklist a recipient) **cannot block a risk path**: the share stays in the owner's proceeds and `FeeShareKept` is emitted (tested). The StrategyLossReserve deposit (`reservePairId`) is not ported; Avalanche has no such contract, reserve is a plain transfer; recipients are still undecided |
| P7 | the position's price source is Robinhood's NVDA feed; USDG 6 decimals | the margin oracle's WAVAX and USDC prices, both USD at 18 decimals (`GuardedAvalanchePriceOracle.getPrice`), decimals corrected in `_oracleSqrtPriceX96` (18 vs 6). Checked on the fork: pool and oracle agree to rounding after `_syncOracleToPool` |
| P8 | `MarginOrderRegistryV2` (a take-profit order is refused while a range order is active) | **not ported** (it is a change to `contracts/contracts`). The custodian refuses a range order while the registry holds an open TAKE_PROFIT (tested, code 5), but a take-profit created AFTER a range order is not refused. Both would then try to take profit: the registry's order cannot execute (the adapter unwinds the range order first, which is a safe outcome), but the product is confusing. Needs the registry change |
| P9 | the pair's `oracleDeviationBps` for NVDA | for the Avalanche pair it is **100 bp**: a pool more than 1 % from the oracle refuses creation and finalisation. A fast pump that outruns the Chainlink update makes the keeper wait (`PoolOracleDeviation` is a wait) |

Caused by the brief, not by Pharaoh:

| # | PR #7 | this port |
| --- | --- | --- |
| B1 | one band per order | up to three rungs per order; `finalize` handles every fully crossed rung; the position closes only when no rung is active. PR #7's "half the collateral committed" semantics (the band repays what it can, the position stays open) generalises to this |
| B2 | one NFT per order, one status | per-rung status (`ACTIVE`, `SETTLED`, `UNWOUND`); order status ends SETTLED (last rung finalised) or UNWOUND (cancel / liquidator / adapter) |
| B3 | keeper reads the journal's custodian and executor | the keeper enumerates positions through `executor.nextPositionId` and the custodian's `finalizable(id)` view: no event logs needed (see section 6) |
| B4 | admin changes presets with one level | `setPreset(id, enabled, levels, distance[3], width[3], weight[3])` |
| B5 | a single band always settles with `settle = true`, so the position is closed by the custodian itself | with a ladder the position can be debt-free and ACTIVE while rungs remain; the **orphan defect** (section 8) needed a new engine guard in the risk-engine copy |

Kept as PR #7 had it, **no new trust assumption**: a custodian behind a transparent proxy whose admin is the timelock (presets, fee split and recipients, unwinders); `finalize` permissionless and paying the caller nothing; the three engine hooks, each custodian-only or admin-only and one-shot; the oracle valuation of the bands; order snapshot of the fee bps (recipients are global, as in PR #7).

## 6. The finalisation keeper (`range-tp-keeper/`)

A gas-only wallet with **no role**. It cannot cancel or remove a band: the ABI it carries has no `unwind` (a test asserts that, and that no source file encodes one). Semantics carried over from PR #7's range phase, per rung:

* per position with an ACTIVE order it reads `finalizable(id)` = (active rungs, rungs the pool has fully crossed). Nothing crossed: **wait** (not reached, partly filled, or reversed), no simulation;
* some rung crossed: **simulate `finalize`**; send only if the simulation passes. `BandNotFullyConverted`, `OracleUnavailable` and `PoolOracleDeviation` are **waits** (no alert, no cooldown). Anything else (e.g. `SlippageFloor`) is not sent, warned, and put on a 300 s cooldown;
* gas-price cap (`maxFeeGwei`), AVAX floor, per-step send budget (`maxSendsPerStep`);
* a band that disappears without the keeper (owner cancel, liquidation, stop-loss: `UNWOUND`; or finalised by another caller: `SETTLED`) is **recorded once**, never acted on.

Disciplines copied from `operator/src` (no runtime import from `operator/`; a test enforces it): `mask.ts` (the RPC URL and the keystore password never leave the process), `logpace.ts` (paced `eth_getLogs`, 60 s doubling to 900 s back-off after a 429; used only by the optional `EthersPort.createdSince` discovery, the default discovery uses no logs), `signer.ts` (keystore signer, password from an environment variable), `txkit.ts` (fee cap, send-and-wait, `TxReverted`; one change: the 180 s wait timer is cleared when the wait ends, otherwise it kept the process alive for three minutes after a send). **Halt and pending marker**: the state file is written atomically **before** a send (`pending`), cleared when the send ends; a `pending` found at start-up is an interrupted send and **halts**; a mined revert after a passing simulation, a read-back mismatch (the rungs that were ready are not SETTLED, no `RangeOrderSettled` event) or an unknown error **halt**; a halted keeper does nothing until a human clears `halted` in the state file. Commands: `check` (read-only), `once`, `run`. Config: `config/keeper.example.json` (public values; the endpoint and the password are environment variable NAMES).

The keeper is not provisioned anywhere. It would go on a host with its own gas-only wallet; no Droplet exists for it yet.

## 7. What the fork tests prove, and what they do not

**What they prove**

* The **real Pharaoh position manager** takes single-sided WAVAX mints above the tick at spacing 10, and burns, collects and removes them; band geometry, tick alignment and the 70/20/10 split of the collateral are exactly as stated. The first `createRangeOrder` of every test runs against the **real Chainlink round at the pin** and the real pool, and passes the 100 bp deviation check: that validates the 18-vs-6 decimal scaling of `_oracleSqrtPriceX96` against reality, not only against my own helper.
* **Real swaps** through the real router move the real pool through the bands, and a fully crossed band returns exactly its liquidity-maths USDC.
* The **real margin script's stack** (executor, vault, quoter, swap module, flash vault, risk engine, liquidator, adapter) with the hook upgrades: a 2x long can commit its collateral, be finalised (debt repaid first, in full), and closed with the equity to the owner; cancelled; liquidated and stopped out with a band active.
* Every failure mode in section 3.1 behaves as stated, including that a failing step reverts the whole finalisation and leaves the order ACTIVE.
* The keeper, with the real ethers signer path and a real JSON-RPC node, finalises once, waits when it must, and never sends otherwise.

**What they do NOT prove**

* **The oracle is mocked after the first read.** Every price move in the tests moves the pool by real swaps and then writes the matching value into the Chainlink aggregators (`vm.mockCall`; `MockFeed` on anvil). Real feed lag, heartbeat and deviation thresholds against a fast move are not tested, so how often `PoolOracleDeviation` would make the keeper wait in a real pump is unknown. The "pool pushed, oracle not" tests show the refusal, not its frequency.
* **The margin stack is not live.** It is deployed on the fork by the script, and the range upgrade is applied by impersonating the Ledger on the ProxyAdmins: no timelock delay, no ceremony, no read-backs, no layout snapshot check for the custodian or the three engine contracts (PR #7's `check_registry_layout.py` and `range-layout.json` were not ported). The registry is not re-pointed (adapter v2 is called through a stand-in "registry"), and registry V2 is absent.
* **No LP swap fees exist on the live pool**, so the fee split is proven only with `collect` stubbed. **xPHAR and the failed-transfer ledger** are proven only with stubbed balances; no real xPHAR emission was observed at the pin. The 349 PHAR figure is one probe on one day's emissions.
* **Depth and market behaviour:** the tests cross a band with a 20M USDC swap, which the pool can absorb at this pin; pool depth changed by 60 to 70 % between two heads two days apart (stop-loss notes). Nothing shows that a real market will trade through a band, or that a keeper polling every 20 s catches a short spike before it reverses.
* Only the **funded** liquidation route is tested (the `liquidate` flash route has the same hook, untested). Gauge anti-sybil forfeits, MEV around `finalize`, gas-price spikes, reorgs, large positions (the pilot cap is USD 200; tests use USD 180), and any concurrency are not tested; there is no fuzzing.
* **One block.** Everything is at 99,859,291.
* **The keeper's fork test replays a Foundry `dumpState`**, so the fork it runs on is the live chain at the pin plus that dump, not an independent reproduction. It is one scenario; the keeper has not run against mainnet, with a keystore signer, with the log discovery live, or over time (no soak).

## 8. Risks

* **Keeper latency is a product risk, not only a technical one.** A rung is converted only while the price is above it. If the market crosses the band and falls back before the keeper finalises, the WAVAX comes back (tested: `test_07`): no loss, but the take-profit did not happen. A range order is not a market sell. Poll fast; a 20 s loop on Avalanche's roughly one-second blocks can miss a short spike. The pool-vs-oracle bound (100 bp) can also make the keeper wait through a fast move.
* **Thin liquidity above the price helps the band and the rewards:** the band is the only liquidity in its range, so it takes the whole in-range share of the gauge emission (the reward probe forwarded about 349 PHAR to the owner for a 90 USDC position left half-filled for 3 days at the pin; it is logged, not asserted, and depends on that day's emissions). The same fact means that anyone can push the pool through the band with little capital; the oracle bound is what stops a pushed pool from finalising.
* **Gauge anti-sybil:** a removal within 111 s of the last liquidity change forfeits that window's rewards; cancelling right after creating loses the first minutes' PHAR. Not a principal risk.
* **Position cap USD 200 (pilot).** A rung with weight 10 % of a USD 180 position is about USD 18 of WAVAX. Dust works (even 1 pWAVAX wei mints liquidity in all three rungs) and there is no minimum.
* **Executor size:** 105 bytes spare.
* **Risk-engine cost:** `holdings` is an external call in every health read of an account with a band; it reverts when the oracle has no price, exactly as the risk engine's own valuation does. A stale feed therefore also blocks the liquidator from valuing a banded account (the same as for any margin account).
* **Fee recipients are global**, so changing them redirects the protocol / reserve share of orders already open (the bps are snapshotted, the addresses are not). Same as PR #7.
* **DEFECT of preset 4, found in review, fixed in the engine copy, not a design choice.** After rung 1 of a ladder repays the debt, the position is ACTIVE and debt-free while rungs 2 and 3 still hold its WAVAX in the pool. Nothing in the executor's debt-free exit (`exitDebtFreeToPTokens`) or full close consults the custodian, so the owner (or a mistake) could close the position; `finalize` and `unwind` both call `executor.rangeReturn`, which reverts for a non-ACTIVE position (`ExecutorError(47)`), so the rungs' WAVAX would have been **unreachable**. Confirmed by `test_54` before the fix (the exit succeeded). Fix: the risk-engine copy refuses `beginDebtFreeClose` and a full `finishClose` while the custodian reports holdings for the account; every legitimate path reaches those calls with no active band (the custodian's final settlement, the liquidator and the adapter all unwind first). It is one more change to a contract in `contracts/contracts` (+475 bytes in the risk engine, which has room), and it means: **while rungs remain, the owner must cancel before closing normally**. PR #7 never hit this because its single band always settles with `settle = true`. A custodian-side recovery path (remove the rungs and pay the owner directly when the position is no longer ACTIVE) would be a second line of defence; I did not add it (340 bytes spare). The equity of rung 1 is not paid to the owner at once (open question 3).
* **Oracle mocked in every test.** See section 7.

## 9. Open questions for you

1. **70/20/10** (section 0): the ladder across levels, PR #7's fee split, or both (as built)?
2. **Engine changes:** are you willing to put the executor / risk engine / liquidator / adapter changes and a registry V2 into the production ceremony? The executor has 105 bytes spare; the guard added to the risk engine is part of this. Without them the feature cannot exist; there is no executor-free design (the collateral cannot leave the account).
3. **Surplus after rung 1:** pay the owner at once (needs a new executor entry point, which does not fit in the 105 bytes without moving code out) or keep it as margin until the last rung (as built)? Or drop preset 4 and ship only single-band presets, which have none of this?
4. **Presets:** keep PR #7's 100 / 300 / 490 ticks (rungs 2 and 3 overlap by one spacing) or move rung 3 to 500 (a one-line admin change, no code)?
5. **Fee split on Pharaoh:** the pool pays LPs no swap fees today. Keep the fee split at 100/0/0 and let the owner keep PHAR, or route a share of the PHAR to protocol / reserve (a code change: PR #7 sent RAM to the owner whole)?
6. **Recipients** for protocol and reserve: still undecided (PR #7 has the same open item).
7. **Keeper host and wallet**, fee cap (60 gwei default), poll interval, and whether it runs on the existing keeper Droplet.
8. **Registry V2** (a take-profit order refused while a range order is active): include it?
9. **xPHAR:** the owner exits it from his own wallet; is that acceptable, or should the custodian forward only PHAR and the keeper deal with xPHAR?

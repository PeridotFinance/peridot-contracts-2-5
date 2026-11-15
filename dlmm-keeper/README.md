# dlmm-keeper

Exit-triggered rebalance keeper (W5) for the Pharaoh DLMM USDC/USDt 3-bin vault. Spec (FROZEN): `docs/deployment-handoffs/avalanche-pharaoh-dlmm-vault-spec.md` sections 4, 5, 6. ABI (FROZEN): `contracts/vault-dlmm/src/IPharaohDlmmVault.sol` (a test compares every fragment in `src/abi.ts` with that file). Structure, discipline and deploy pattern follow the production order keeper (TypeScript, Docker, systemd unit, `deploy/*-host.sh bootstrap|stage`, config validation, redaction, pending marker, gas-runway alert).

Status: built and tested against a fake world, a stub vault AND the REAL `PharaohDlmmVault` with W4's mocks on a local anvil (16 Nov 2026). **Never run against the real pair or a deployed vault** (the fork queue is W6's). Nothing here signs or sends anything by itself: the default mode is `dry-run`.

## What it does

Every `timing.pollSeconds` (3 s) it makes ONE Multicall3 `eth_call`: pair `getActiveId()`, vault `bandState()`, vault `guardState()`.

1. HALT file present: return before any chain call (see below).
2. `guardState().latched` or any latchable bit (1, 2, 4, 8) in `reasons`: HALT.
3. No band: warn, wait. Active id inside `[lowerId, upperId]`: nothing. (Exit trigger is spec section 5, outside `[lowerId, upperId]`, not the evaluation's `[lower+1, upper-1]`.)
4. Active id outside: write an exit marker, wait `exitWaitSeconds` (60 s, polling continues, so a return into the band clears the marker and sends nothing).
5. After the wait, one pinned-block re-read of everything (one Multicall at block N): active id, band, guard, `rebalanceAllowed`, `guardParams`, `rebalancesToday`, `lastRebalanceAt`, pair tokens and decimals, the vault's idle token balances, the two Chainlink feeds, and for each band bin `balanceOf(vault, id)`, `totalSupply(id)`, `getBin(id)`; then the pool price at the active id and the swap quotes at the same block.
6. Still outside the band, guard safe, vault says allowed: the keeper's own oracle check, then the swap sizing (below), then `eth_call` simulation of exactly the transaction, then ONE `rebalance(...)` send, read back from the receipt (`Rebalanced` event, `bandState`, `lastRebalanceAt` advanced).

Never a loop on a revert: every failed attempt sets a backoff (30 s doubling to 900 s) and is counted; `maxConsecutiveFailures` (5) HALTS. The only repeated simulation is ONE adaptive re-simulation after `ActiveIdMoved`, with the id the vault reported, if it is within `maxActiveIdShift` (4) of the id the plan was made for.

Sent arguments: `expectedActiveId` = the pair's active id at the pinned block, i.e. BEFORE the vault's own swap (UNVERIFIED against W2: if the swap moves the active id by more than `idSlippage` the simulation reverts `ActiveIdMoved` and the one adaptive re-simulation adopts the vault's reported id); `idSlippage` = 2 (config, hard max 2); `deadline` = max(block time, local time) + 120 s.

## Swap sizing (`src/plan.ts`, pure, unit-tested)

Target mix: after the swap the inventory is EVEN BY ORACLE VALUE between the two legs. Reasoning: the new band is ids a-1, a, a+1; bins below the active id hold only Y and bins above only X (MEASURED on the live pair, 15 Nov 2026: `getBin(active+1)` = X only, `getBin(active-1)` = Y only), so V/3 in each bin with the active bin split 50/50 makes the TOTAL inventory 50/50 by value. UNVERIFIED against W2 (the vault computes the distributions itself); if W2 targets another mix only the target share in `plan.ts` changes. Likewise UNVERIFIED: that W2's NAV counts the vault's idle token balances (the keeper adds them to the inventory, as the spec's "mixed inventory" implies).

Inventory = sum over band bins of `balanceOf(vault,id) x reserve / totalSupply(id)` (rounded down per bin, as the spec's NAV) + idle balances. Orientation is read from the pair (`getTokenX()`, `getTokenY()`; on the live pair X = USDt, Y = USDC), never assumed. At an upward exit the band is all Y (USDC) so the swap is Y for X, about 50 % of NAV.

With oracle price pO (raw Y per raw X) and the QUOTED rate r (`pair.getSwapOut`) at the first-order size s0 = half the imbalance: X to Y `s = (x pO - y) / (pO + r)`; Y to X `s = (y - x pO) / (1 + r pO)`; a second quote at s verifies the fill. `swapIn` is capped at `maxSwapBps` of NAV from `guardParams()` less 1 %. `swapMinOut` = max(quote x (1 - 10 bp), oracle-implied output x (1 - min(keeper 40 bp, vault `maxRebalanceLossBps`))). If the quote is below the oracle floor, or leaves input unfilled, nothing is sent (alert, backoff). `amountXMin/YMin` = the post-swap inventory at the WORST case (`swapMinOut`) x (1 - 50 bp).

`getSwapOut(uint128,bool) returns (amountInLeft, amountOut, fee)` was MEASURED against the live pair with read-only `eth_call`s (1,000 USDt to USDC returned 999.508; 1,000 USDC to USDt returned 1,000.375; `getPriceFromId` = 0.99960 at id 8388604). The router is not used: the quote is the pair's own (the router routes through the same pair).

## The keeper's second, independent oracle check (`src/sanity.ts`)

Spec section 6 lists a read set without the feeds; the task adds an independent check, so the keeper reads the two Chainlink USD feeds directly (not guardState bit 16) and compares: each feed fresh (<= the vault's `maxFeedAge`), complete round, within 1.00 +- min(keeper 40 bp, vault `legBandBps`); and the pool price at the active id vs the oracle ratio within min(keeper 50 bp, vault `maxPoolOracleDevBps`). The keeper's own thresholds (40 bp leg band, 50 bp pool deviation, 40 bp quote loss, 10 bp swap slippage, 50 bp add slippage) are my choices, ESTIMATED, pending W-CAL's calibration of the vault's numbers; the effective value is always the stricter of keeper and vault. A failure sends nothing, warns (`oracle:keeper-check`), backs off 30 s. It is never a latch and never a halt (the pool deviation, bit 16, is a live condition by design).

## Halt, and `resume`

The HALT file (`monitor.haltPath`, on the persistent volume) is the ONLY authority on "halted". Its existence is checked at the start of every cycle; while it exists the keeper returns before any chain call: no read, no balance check, no send (MEASURED: the fake-world test asserts zero eth_calls, balance reads and block reads over five halted cycles; the anvil test asserts zero state requests, excluding block reads, over six; the state file is not rewritten while halted). The keeper creates it on: a latched vault or a latchable bit (kind `guard`), `maxConsecutiveFailures`, `maxMinedRevertsPerDay`, a pending marker found at start (an interrupted send), a read-back mismatch, an unexpected error after the pending marker, a rebalance the keeper did not make (`vault.lastRebalanceAt` differs from what it saw after its own send: a second instance, or the rebalancer key in other hands; checked at each attempt, not at each poll), a wiring mismatch (pair tokens differ from the configuration). It is never removed by the keeper. A restart does not clear it. An unreadable HALT file still halts.

`dlmm-keeper resume` (`node dist/src/main.js resume`, offline: no RPC, no keystore) resets everything that could re-halt the keeper for the OLD cause (pending marker, failure backoff and count, exit timer, the last-seen `lastRebalanceAt`, which is re-learned at the next attempt, and the `keeper:halted` alert state), writes that state BEFORE removing the HALT file, then removes the file and appends an audit line to `<haltPath>.log`. A running daemon notices the file is gone and reloads the state from disk; it never writes its older copy over it (tested as a separate process on anvil, and the test fails if either guard is removed). If the cause still holds (a latched guard: the Safe must `clearGuard()` first) the keeper halts again at once, so running it early is harmless. `dlmm-keeper status` prints the HALT record and state offline (exit 1 when halted).

Live-only bits (16 pool deviation, 32 rewarder) are NOT halts: warn (`guard:live`), no send, wait.

## tripGuard(): decision

`guard.autoTripGuard`, default OFF in the template and in code. Recommendation: YES, turn it on at go-live, after the dry-run period and after W-CAL has fixed the guard numbers.

Why yes: it is permissionless, so it adds no capability anyone lacks; the keeper's HALT stops its own sends only, while the vault-side latch also blocks deposits, mint, openBand and the next rebalance after prices recover (a depeg that flickers back is exactly when a deposit would be dangerous), and nobody else is guaranteed to be watching. Cost: DERIVED, one SSTORE and one event, ESTIMATED 50 to 60k gas; at 3.5 gwei (the median in the evaluation) about 0.0002 AVAX, under USD 0.002 at AVAX 8.58. The wallet pays it. Why default off: it is the one transaction the keeper may send while halted, and a latch costs the Safe a `clearGuard()` signature even for a transient single-round feed glitch (a person with Ledger access is the price of each false latch). W-CAL's false-trip table decides how acceptable that is.

Behaviour when on: the HALT file is written FIRST; then, only if a latchable bit STILL holds after `tripDebounceSeconds` (15 s) and the vault is not latched, the keeper simulates `tripGuard()` and sends it once through the same fee-cap / pending-marker / send path as a rebalance (so at most one transaction before halting, at most one per halt). The outcome (`sent 0x..`, `condition cleared ...`, `already latched`, `simulation reverted ...`, `dry-run`, `disabled`) is written into the HALT record. In dry-run it never sends.

## Limits (mirror the vault, plus keeper-side extras)

| Limit | Value | Where |
| --- | --- | --- |
| sends per cycle | exactly 1 | config floor, structural |
| rebalances per rolling 24 h | <= 48 (min with vault `maxRebalancesPerDay`) | config max 48 |
| cooldown between rebalances | >= 120 s (and the vault's `readyAt`) | config floor |
| exit wait | >= 60 s | config floor |
| deadline | now + 120 s max | config max |
| idSlippage | <= 2 | config max |
| max consecutive failures | 5 | HALT |
| mined reverts per 24 h | 3 | HALT |
| min wallet balance | 0.005 AVAX | no send, crit `keeper:gas` |
| fee cap | 100 gwei | no send |
| gas-runway warning | wallet covers < 5 rebalances at current gas price x 1,000,000 gas | warn `keeper:gas-runway`, checked every 300 s |

Gas per rebalance 1,000,000 is the task's figure (ESTIMATED; the vault does not exist: the evaluation measured 370k gas per deposit and 258k per withdraw on this pool). At 3.5 gwei one rebalance is 0.0035 AVAX (DERIVED), the 48 a day worst case 0.17 AVAX a day, so 1 AVAX covers about 285 rebalances.

## Configuration

JSON file (`DLMM_KEEPER_CONFIG` or `--config`): public addresses and parameters only; `config/dlmm-keeper.example.json` has `UNSET` for every undecided value and is REFUSED (exit 78). `deploy/make-config.py` fills it from explicit addresses. The file is scanned for URLs with key-like paths, 32-byte hex, and the words key/mnemonic/password.

Environment (secrets and secret locations only): `AVALANCHE_MAINNET_RPC_URL` (state endpoint; never printed, never in a file or argument; errors and alerts pass through `mask()`), `DLMM_KEEPER_KEYSTORE_PATH` and `DLMM_KEEPER_KEYSTORE_PASSWORD_FILE` (live mode only; both files must be mode 600; the password file's content is registered with `mask()`), `DLMM_KEEPER_ALERT_TELEGRAM_TOKEN` / `_CHAT_ID` or `DLMM_KEEPER_ALERT_WEBHOOK_URL` for those alert channels.

Commands: `run [--dry-run]`, `check` (one dry cycle without the 60 s wait; writes nothing), `status`, `resume`, `validate-config`. `mode` is `dry-run` unless the file says `live`; `--dry-run` forces it. Dry-run reads, plans and SIMULATES; it never loads the keystore, never sets a pending marker, never sends.

Logging: a line on activity (any note, send, non-idle status) and on every 20th cycle; alerts de-duplicated per key (`keeper:halted`, `attempt:failed`, `guard:live`, `oracle:keeper-check`, `plan:*`, `limit:daily`, `keeper:gas`, `keeper:gas-runway`, `node:stale`, `band:none`, `rebalance:not-allowed`, `cycle:failed`).

Chain event scans: none. The read-back uses the receipt, so nothing needs `eth_getLogs`; the public endpoint (`https://api.avax.network/ext/bc/C/rpc`, 100-block chunks) is not used. If a log cross-check is added later, use that endpoint in 100-block chunks.

RPC load: one Multicall `eth_call` per 3 s = 28,800 a day on the state endpoint (DERIVED), plus 2 reads every 300 s. A free tier may not like that; check the provider's limit before go-live.

## Tests

`npm test` (build + 115 unit tests, MEASURED): plan (14), sanity (9), config floors and template refusal, HALT / state, keeper step on a fake world (54, including resume after each kind of halt and a second halt alerting again: exit detection, the 60 s wait, in-range recovery at poll and at re-read, dry-run, each latchable bit, latch and manual resume, zero calls while halted, live-only bits, tripGuard on/off/debounce/dry-run, limits, backoff to halt, benign and halting reverts, ActiveIdMoved, mined revert, pending marker, read-back lies, foreign rebalance, gas runway, wallet floor, fee cap, oracle check, orientation, idle balances, wiring, stale node), revert classes, ABI vs the frozen `.sol`, keystore signer, CLI, redaction and a repository scan for keys / provider names / the production keeper's resource names.

`npm run test:anvil` (needs `anvil` and `forge` on the PATH, no fork, no lock; stubs in `test/stub`, own `foundry.toml`, solc 0.8.24 from the local cache): 10 tests with the real keystore signer on a throwaway chain 43114, plus `run.anvil.test.ts` (two whole-process tests: `resume` from another process against a running daemon, about 16 s; `run` in live mode with the real 60 s wait, about 75 s). Covers: exactly one tx per exit with the arguments decoded on chain, zero in dry-run, zero when the active bin returns, zero RPC requests while halted, autoTripGuard sending one `tripGuard`, failure backoff to halt without any gas spent, oracle check blocking, CLI `check` with the endpoint masked.

`./run-fork-test.sh` (fork against the real pair, shared lock `/tmp/pilot-fork.lock`, retry every 30 s, `rmdir` on every exit path, endpoint from the environment, exit 42 on any 429): UNVERIFIED, compiled but never run. Its one test checks the pair side only (orientation, one-sided bins, quote, sizing); the vault-side fork test needs W2.

## Not done / unfavourable facts

- The keeper does NOT call `openBand`. The first band is created from the keeper wallet by the operator (the interface puts `openBand` under the rebalancer role); `openBand` has no `swapIn`, so its `swapMinOut` cannot be sized without knowing the vault's swap.
- The sizing target (50/50 by oracle value), the idle-balance treatment and `expectedActiveId` = the pre-swap id are unverified against the vault (W2).
- The Docker image was never built and `package-lock.json` (copied from the production keeper's with the name changed) was checked with `npm ci --dry-run` only; `deploy/dlmm-keeper-host.sh` was checked with `bash -n` only.
- One process-level anvil run failed once (113 s) before the harness polled receipts quickly; DERIVED cause: the assertion that the 60 s wait was honoured, measured from a timestamp taken up to 4 s after the exit (slow `.wait()`); the margin is now 5 s and the keeper process is killed in a `finally`. Not reproduced since; not confirmed.
- Foreign-rebalance detection runs when the keeper attempts, not every poll.
- A halted keeper alerts once per key (de-duplicated); the escalation timers of the production keeper were not ported.
- The harness vault is a stub: rebalance and swap behaviour, gas, composition fees and the real hook (a failing rewarder blocks `burn`, spec section 3) are not exercised.

## Deploy (prepared, NOT run)

`deploy/dlmm-keeper-host.sh bootstrap <ip>` builds the image on a Droplet, mounts volume `pilot-dlmmkeeper-data`, generates the keystore ON the Droplet (password in `/etc/pilot/dlmmkeeper.password`, uid 1000, mode 400) and prints only the address. `stage <ip> <host.json>` copies the public config, writes the endpoint into `/etc/pilot/dlmmkeeper.env` through a pipe, installs `pilot-dlmm-keeper.service` NOT enabled. Start: `systemctl enable --now pilot-dlmm-keeper`. Leave a halt: `docker exec dlmm-keeper node dist/src/main.js resume`. All names (volume, env file, container, unit, `/opt` path) are this keeper's own; a test fails on any leftover name of the production keeper's resources. Checked with `bash -n` only. The deploy, the Droplet, the keeper wallet funding and the switch from `dry-run` to `live` are the operator's live steps.


## Update 16 Nov 2026: the real vault, `open-band`, the exit probe

**Real vault ABI** (`contracts/vault-dlmm/src/PharaohDlmmVault.sol`, DEVIATIONS.md): the frozen interface is unchanged; `src/abi.ts` adds `VAULT_EXTRA_ABI` (getters `pair`, `rebalancer`, `feedAsset`, `feedPair`, `asset`, `pairToken`, extra errors `NotRebalancer`, `FeedInvalid`, `DeadlineExpired`, `BandExists`, `NothingToDeploy`, `ExitFailed`, OZ `EnforcedPause`), checked against the `.sol` by a test. Each attempt reads the getters and HALTS (kind `wiring`) if the vault's pair, feeds or tokens differ from the configuration or if the keeper wallet is not the vault's `rebalancer()` (a rotation); `NotRebalancer` from a simulation does the same. `rebalanceAllowed` bits 64 (no band), 128 (active in range: recovered, no send), 256 (cooldown, wait until `readyAt`), 512 (daily cap, `readyAt` = next UTC midnight, alert `limit:daily`), 1024 (latched), 2048 (paused: warn `vault:paused`, no send, no halt) are decoded. The vault's daily cap is a UTC-day counter, so the keeper reads it from the vault (`rebalancesToday`, bit 512) and no longer compares its own rolling 24 h count with the vault's `maxRebalancesPerDay` (that would block after midnight); the keeper's own rolling cap (<= 48) stays.

**Active id semantics**: the vault builds the band around the REAL active id read after its inventory swap; `expectedActiveId` (the id the keeper read at the pinned block) must be within `idSlippage` (config, default 2, max 2) of the id before AND after that swap. On `ActiveIdMoved(expected, actual, slip)` the keeper does ONE re-simulation with the midpoint of its id and `actual` (within `idSlippage` of both), only if they differ by <= 2 x `idSlippage` (and <= `maxActiveIdShift`); otherwise a counted failure.

**`open-band [--send]`**: the same step as a rebalance with the precondition "no band": guard and halt rules, the keeper's oracle check, simulation, pending marker, fee cap, wallet floor, read-back (`BandOpened`, `bandState`), failure backoff. Dry unless `--send` AND `"mode": "live"` (then the keystore is loaded and ONE `openBand` is sent; nothing is persisted in a dry run). `openBand` has no `swapIn`: the vault evens its idle inventory itself (read in the vault code): `pv` = idle pair token valued at the oracle in asset units; if asset > pv + 1 it swaps (asset - pv) / 2 of the asset, else min(assetToPair((pv - asset) / 2), pair balance) of the pair token, subject to `SwapTooLarge` (value <= `maxSwapBps` of NAV) and the oracle floor. `planOpenBand` mirrors that formula exactly, quotes that swap, and returns `swapMinOut` (>= quote x (1 - 10 bp) and >= the oracle floor) and `amountXMin/YMin`; it predicts `SwapTooLarge`. MEASURED on the real vault: the swap size the keeper predicted (50,000,000 of 100 USDC idle) is the swap the vault made. The vault's distribution is fixed (Y 2/3 on -1 and 1/3 on 0, X 1/3 on 0 and 2/3 on +1), which is why the 50/50 target in `plan.ts` is the right one (now verified by the end-to-end test: usdc share 45 to 55 % after a re-centre; the vault's own `navAfter` bound held).

**Exit probe** (`src/chain.ts probeExit`): a failing Pharaoh hook (rewarder `beforeBurn` reverts, or the voter's `isAntiSybilEnabled` / `timeThresholdForGauge`) blocks every exit, `redeemInKind` included, while `guardState()` reads 0 and deposits stay open (W6's fork finding). Every `probe.everyCycles` (default 20, about 1 minute) cycles, and again at the pinned block before every attempt, the keeper `eth_call`s `pair.burn(vault, vault, [bin], [whole balance of the vault's most valuable band bin])` with `from` = the vault. `pair.burn` needs `from == msg.sender`, so no holder shares and no state override are needed, and the call runs the whole burn path including the hook; it is never mined. A minimal share amount is not used because it can pay 0 and revert `ZeroAmountsOut` for another reason; that revert, or no shares, is INCONCLUSIVE. Any other revert: crit alert `EXIT PROBE FAILED: pause deposits ...`, `state.exitProbe` set, re-centring BLOCKED (a burn would revert anyway), probing continues, the owner pauses from the Safe. Decision: this is NOT the HALT latch (it clears itself when the probe passes, the HALT needs a person, and a halted keeper would stop probing); while the flag is set the keeper sends nothing but alerts and probes. Not run while halted.

**Found while testing (MEASURED)**: ethers v5 can hand the revert data of a reverted `eth_call` back as a plain RESULT (a reverting `pair.burn` came back as `0x08c379a0...` on anvil). The keeper's simulations of void functions (`rebalance`, `openBand`, `tripGuard`) therefore pass only on an EXACTLY empty result (`callVoid`); anything else is thrown as a revert with that data and classified. Unit tests cover all three and the probe.

**Quoter**: optional config `quoter` (default: the pair). The live pair has `getSwapOut` (MEASURED); W4's mock pair does not, so the end-to-end test uses `MockPairQuoter` (active-bin price and fee, no bin crossing): sizing accuracy there is that of a single-bin quote.

**Tests now**: `npm test` 134 unit tests; `npm run test:anvil` adds 8 real-vault end-to-end tests (`real.anvil.test.ts`): open-band dry then live (NAV bound, swap prediction), market swap pushes the active bin out and the keeper re-centres exactly once around the real active id (NAV bound, inventory even, in-range afterwards sends nothing), the vault's own cooldown (bit 256), the daily cap (4, the 5th waits until UTC midnight, then sends and the vault counter resets), guard latch (feed out of band: HALT, one real `tripGuard`, Safe `clearGuard` reverts while unsafe and works after, manual `resume`), the exit probe against a reverting mock hook (alert, no re-centre, deposits open, recovery), wiring (not the rebalancer). Needs `forge`, `anvil` and `contracts/lib/{forge-std,openzeppelin-contracts,openzeppelin-contracts-upgradeable}` (gitignored symlinks to RobinhoodVaults/lib); `test/realvault` is its own forge project that imports the vault and the mocks (artifacts in a temp dir). The first re-centre uses a real market swap; the repeated cycles (cooldown, cap, latch) move the active bin with the mock's `forceActiveId`, which does not change bin composition (the keeper sizes from the real reserves either way).

**Fork test (prepared, NOT run)**: `./run-fork-test.sh` is unchanged and still covers only the pair side (`pair.fork.test.ts`). The vault-side fork job (W6's queue) should: deploy the real vault on the fork as the ceremony does, then run `check` and `open-band` (dry) with the keeper wallet set as rebalancer through an impersonated owner, against the real pair's own `getSwapOut` (no `quoter`), and run the exit probe against the real hook.

**Still unverified**: everything against the real pair, router, rewarder and voter (composition fees, gas, the real hook's `beforeBurn` / anti-sybil reads); the probe against the real hook (a mock hook was used); multi-bin quote crossing; the real USDT/USD feed address and the configuration values for the ceremony.

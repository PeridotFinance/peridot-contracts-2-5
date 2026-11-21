# bpPHAR-USDC mainnet-fork rehearsal (B0 .. B11)

Rehearses the whole **listing ceremony** of the `bpPHAR-USDC` lending market (underlying = the share token of the Peridot Pharaoh DLMM USDC/USDt ERC-4626 vault) and the **oracle wrapper in front of the live controller's oracle**, on a local anvil fork of the LIVE Avalanche pilot, in the order of the ceremony: the new contracts are DEPLOYED but not seeded and not listed; then the Ledger transactions; then everything the market has to survive; finally the PHAR distribution to the market's suppliers.

**Status: written and checked offline by the assistant, NOT run on a fork** (it has no RPC). **Every check that reads the live chain (all of B0 to B11) has only ever been through `DRY=1` (inputs, ABIs, encodings, README ids), syntax checks and the offline self-test; none of them has produced fork evidence.** What HAS run for real, on a local anvil without a fork: the plumbing (`selftest.sh` P0..P2), the real v2 wrapper bytecode against stand-in vault / oracle / pToken contracts (P3: poke expectations, fallback arithmetic, the exact 24 h boundary), and the PHAR expected-split model against the generator's own `wrapperSplit` (P4 and `DRY`). The user runs the fork. Nothing here signs, broadcasts or touches mainnet: the Ledger, the Safe, the throwaway deployers and every test wallet are *impersonated on the local anvil*; the RPC URL exists only in the environment of the local proxy.

## RUN 2: the v2 wrapper, the full run, ONE command (one tree, one lock, one proxy)

Run 2 deploys the **v3 wrapper** (`PharaohDlmmShareOracle`, 3,628 bytes: last good vault leg x 97 % for up to 24 h ONLY when the vault reverts with its own `FeedInvalid(uint8)`; any other failure prices 0 at once, permissionless bounded `poke()`), and adds three things to run 1: the facts of the v2 wrapper and the real feeds (B0), the stale-feed **outage** on the real vault (B10), and the **PHAR distribution** with the market this run deployed (B11, last group). The harness, the ceremony tool, its pin file, the build artifacts and the wrapper all come from THIS checkout (`contracts/` of the branch `feat/bp-dlmm-fork-v2` = `feat/bp-dlmm-fork` + `feat/bp-dlmm-core-v2`); nothing falls back to another worktree.

```bash
cd /Users/joshua/Peridot/.wt-bp-fork2/contracts
tools/bp-dlmm-ceremony.sh pin rehearsal          # once per source change: offline, builds out_bpdlmm, writes ceremony/bp-dlmm-pin.json; it must print  runtime PharaohDlmmShareOracle  3628 bytes
cd ..                                            # repo root
# static checks only (no endpoint, no fork, no lock; seconds):
DRY=1 REH_SCAN_FROM=<vault deployment block> contracts/bp-dlmm/tools/rehearsal/rehearsal.sh /tmp/bp-dry     # REH_WRAPPER=0 to skip the PHAR inputs
contracts/bp-dlmm/tools/rehearsal/selftest.sh                                                                   # offline plumbing + v2 helpers; no endpoint
# THE run (the endpoint is typed in YOUR shell only; it is never written to a file, an argv or the output):
AVALANCHE_RPC='<your endpoint>' REH_SCAN_FROM=<vault deployment block> contracts/bp-dlmm/tools/rehearsal/rehearsal.sh ~/bp-rehearsal-2
```

* **`REH_SCAN_FROM` = the DLMM vault proxy's deployment block** (`0x278B1b62...7f7D`, creation transaction on the explorer). It is needed by the PHAR step only (the generator scans the vault's Transfer logs from there) and is **recorded nowhere**: it must be at or before the vault's first share mint and at most 100,488,395 (the first epoch starts at the `openBand` block 100,488,395); too late a value ends B11 with the generator's `negative balance` error, which the log then explains. The run refuses to start (exit 2, before the lock) without it unless `REH_WRAPPER=0`.
* **Skipping the PHAR step**: `REH_WRAPPER=0` (then B11 is one NOTE and nothing of the rewards project is needed). `REH_RERUN=0` skips only the generator's determinism re-run (halves the upstream log scan).
* **Pre-lock guards (exit 2, nothing started)**: the ceremony tool must be inside this tree and its pin file must exist, the pin's wrapper runtime must be 3,628 bytes (`BP_WRAPPER_RUNTIME`), the pin's sources sha256 must equal the sources of this tree now (a stale pin after any source change is refused), the wrapper artifact must have `poke()` / `shareState()`, and with the PHAR step on: the rewards project, the harvest tools, `REH_SCAN_FROM`. The rewards project's distributor build is compiled BEFORE the lock into the run's scratch directory.
* **Inputs outside this tree (read-only, run from where they are)**: `REH_REWARDS_PROJ` (default `/Users/joshua/Peridot/.wt-bp-rewards/contracts/vault-dlmm`, branch `feat/dlmm-rewards-boosted`: the generator `tools/dlmm-rewards-root.mjs`, the distributor deploy script and `tools/dlmm-rewards-{ceremony,safe-call}.sh`) and `REH_INT_TOOLS` (default `/Users/joshua/Peridot/.wt-dlmm-int/contracts/vault-dlmm/tools`: `dlmm-harvest.sh`, `dlmm-safe-call.sh`). Their forge output, cache and broadcast folders go to the scratch directory, so those worktrees are not written to. Their commit is printed in the `DRY` header (`0ac79d95` at the time of writing).
* **Expected runtime (an ESTIMATE; nothing was measured, the harness has never run on a fork)**: B0..B9 as in run 1 (tens of minutes of local anvil work behind the proxy); B10 adds a few minutes (about 25 transactions and 4 warps, all local); B11 is dominated by the generator's `eth_getLogs` scan: about `2 x (head - REH_SCAN_FROM) / 100` calls through anvil and the proxy to YOUR endpoint (`REH_RERUN=0` halves it; for a head about 4-5 days after the vault deployment that is roughly 8,000-9,000 calls), plus a few minutes of forge compilation for the distributor and the claim / sweep steps. Plan for the lock to be held for **well over an hour**; `lock-minutes.log` and the `RESULTS` line give the real figure afterwards. Set `REH_SLEEP_MS=50` if the endpoint is touchy. A 429 anywhere ends the run with exit 42: stop and report, do not switch provider.

### What each new group proves

| group | what it proves (all against the REAL vault, feeds and controller of the fork, the three feeds mocked from B1.n2 on) |
|---|---|
| **B0.v1-v4** | the v2 wrapper as deployed by the real deploy script: the constructor stored the live `convertToAssets(1e6)` of the deployment block (event + getters agree, exactly one `FallbackPriceStored`), `shareState()` is consistent (live = stored, `usingFallback` false, seconds left = 86,400 - age), the constants (300 bp, 24 h, 200 bp, 1 h), runtime size 3,628 and all four contract sizes under 24,576 (on chain, and equal to the pin) |
| **B0.f1-f7** | evidence, printed from the REAL chain before any mock exists: the vault's `feedAsset` / `feedPair` (address, description, answer, `updatedAt`, age, decimals, aggregator), the vault's `maxFeedAge`, the base oracle's configured USDC and WAVAX feeds (address, `maxAge`, decimals, enabled) and the verdict whether the vault's USDC feed is the same contract as the base oracle's (`B0.f6` FAILS the run if not: then one re-pinned mock would not refresh both). `results.json` -> `data.feedEvidence` has the same numbers |
| **B4.1-B4.5 (updated)** | with only the USDT feed stale the wrapper no longer says 0: it serves stored x 0.97 x live USDC price, an account that entered the share market is priced (error 0, lower liquidity), can borrow and redeem, and a healthy account is rejected with INSUFFICIENT_SHORTFALL (3), not PRICE_ERROR (13). B4.8 / B4.10 are unchanged: no fallback without a USDC price or after 24 h |
| **B10.2b-d (v3)** | **a vault failure that is NOT `FeedInvalid` is a broken vault, not an outage**: the pair's code is removed with `anvil_setCode` (feeds fresh), `convertToAssets` reverts with something other than the `FeedInvalid(uint8)` selector, and the wrapper prices the share **0 at once** with `usingFallback` false although the stored value is fresh; `poke()` returns false; the code is restored and the live price returns. If the vault still answers with the pair gone the injection is reported as a NOTE (B10.2c), not a pass |
| **B10.1-B10.6** | account setup (WAVAX collateral, a pUSDC borrow, **entered the share market holding 0 pBP**) and the **poke upward cap on the real vault**: a 20 USDC donation lifts the live leg far above +2 %; an upward poke inside 1 h of the last store is refused (`false`, nothing stored), an hour later it is stored capped at exactly `prev x 10200 / 10000`, directly after it is refused again, an hour later it moves by at most another 2 % |
| **B10.7-B10.11** | the **outage**: the USDT feed stops at t0 (explicit `updatedAt`, so `repin` leaves it alone); a keeper poke at t0 + 80,000 s stores the live leg; at t0 + 93,700 s `convertToAssets` and `totalAssets` revert `FeedInvalid(2)` (B10.8 asserts the RAW revert data through the proxy: selector `FeedInvalid(uint8)` with argument 2, the one selector the v3 wrapper keys on) while the USDC and AVAX mocks are fresh; `usingFallback` is true and the price is **exactly** stored x 0.97 x the live base-oracle USDC price (recomputed in the contract's integer order); `poke()` returns false; the account that entered the share market is priced and, after AVAX -60 %, shows a shortfall instead of PRICE_ERROR |
| **B10.12** | **the insolvent account IS liquidated during the outage**: static call returns 0, the liquidator pays the repay, receives the seized pWAVAX less the protocol share, the borrower loses exactly the seized pTokens and the debt falls by the repay (failed transactions are traced) |
| **B10.13-B10.15** | **R1 rollback while the fallback is active**: every existing market is priced identically by the guarded oracle and by the wrapper at the same block (8 values), the share market is priced 0 by the guarded oracle; the account that entered it is frozen (13) under the guarded oracle, the live margin account that never entered is not; re-applying the wrapper restores both |
| **B10.16-B10.18** | **expiry**: with nobody poking, at head = stored + 86,400 s exactly the fallback is still valid (static calls only; a mined transaction would move the head), one second later the price is 0, `usingFallback` false, liquidation returns PRICE_ERROR 13 (strict), the expiry is confined to the share market (pWAVAX, pUSDC, the live margin account unaffected), `poke()` is false while the vault is dead |
| **B10.19-B10.21** | **recovery**: USDT restored, the share price is the live price with no transaction and the stored value is untouched; a 20 USDC donation then a `poke()` stores the live value **uncapped** because the old one is older than 24 h; liquidation works again. `B10.n2` records the finding that a never-poked wrapper has no usable fallback (the vault dies at 93,600 s, the window is 86,400 s) |
| **B11.p00-p32, w01-w06** | the **PHAR distribution** with THE MARKET THIS RUN DEPLOYED as the wrapper holder (`wrappers.json` = its address and creation block): suppliers (the Ledger, a pure supplier Carol, Bob who also holds shares directly and redeems half mid-epoch, the earlier test account dave, a direct donation of shares to the market) are split by pToken balance; the seed at `0xdEaD` and a contract holder are excluded; the expected split is rebuilt from the local chain's Transfer logs and reconciled with state (`w01`) before being compared with the generator's `epoch.json` (`w03`); harvest through the Safe, generator twice (determinism), distributor deployed by a fresh deployer through the rewards project's own tool, approve + publish through the Safe tool, the claim window, a cancelled second epoch, claims (Carol, a pure supplier, claims to her own address), a double claim, sweep after 180 days. No contract is changed |

### How to read the log

* `>>> GROUP <name>` opens a group, `--- scenario ... (snapshot n)` / `reverted` brackets an evm snapshot; `PASS id text`, `FAIL id text :: detail`, `NOTE id text`; after a failed transaction `TXFAIL` / `TRACE ... depth d CALL to X error ... output <decoded custom error>` lines print the reverting frames. Search the log for `FAIL` and `TRACE`; the last lines are `RESULTS pass=.. fail=.. notes=..`, `REHEARSAL PASSED|FAILED` and the proxy's upstream status counts.
* `results.json` is rewritten after EVERY group (`"partial": true`, `"lastGroup"`), so a killed or crashed run still has its finished groups; the final write has no `partial`. A group that throws prints `FAIL <group>.exception` and the run continues with the next group.
* Read in this order: `B0.v*` (is it the v2 wrapper, right size), `B0.f*` (the feed evidence: print it into the decision record), `B4.*`, `B10.*` (`B10.n1` states the timeline, `B10.n2` the poke-cadence finding), `B9.*` (nothing moved that should not), `B11.*` and `B11.n3`.
* New files in `<out-dir>`: `wrappers.json` (the wrapper config handed to the generator: market address and creation block), `epoch-rehearsal-NOT-PUBLISHABLE/{epoch.json,manifest.json}` (generated against a LOCAL fork: never publish them), `tool-*.log` (the ceremony tool's output per step). The scratch directory (scan caches, epoch folders, forge output) is removed on exit.

### Hang protection (run 2; added after run 1 went silent for over an hour after the oracle swap)

* **The log is written by the harness itself**: every line (redacted) is appended synchronously to `<out-dir>/rehearsal-run.log` by the node process (`REH_LOGFILE`); the terminal pipe is a line-buffered `awk`, not `sed | tee` (BSD `sed` buffers 4 KB blocks, which is why run 1's log stayed at 0 bytes).
* **Every JSON-RPC call is tracked and times out** (`REH_RPC_TIMEOUT_MS`, default 180 s; tracers 600 s): a call that never answers becomes `TIMEOUT after N s waiting for: rpc <method> <params>` and an error, which the group reports as a FAIL naming it.
* **Every child process** (the ceremony tool, forge, the generator, the Safe tools) runs ASYNCHRONOUSLY with **stdin closed**, its own timeout (`REH_TOOL_TIMEOUT_MS` 25-30 min, the generator `REH_GEN_TIMEOUT_MS` 150 min) and no wait for a grandchild that kept the pipe open; the previous `spawnSync` froze the whole event loop while it ran, so nothing could be reported.
* **Heartbeat every 60 s** (`REH_HEARTBEAT_MS`): `HEARTBEAT hh:mm:ss group="..." last check B1.7 (42 s ago) in flight: rpc eth_call ... (41 s) | process ceremony tool ... (300 s)`. A silent log therefore means the node process itself is gone or blocked, and the last heartbeat says what it was waiting for.
* **Per-group watchdog** (`REH_GROUP_TIMEOUT_MS`, default 20 min; B11 4 h `REH_PHAR_TIMEOUT_MS`): a group that exceeds it fails as `<group>.watchdog` with the last check id and the calls in flight, `results.json` is saved (`"aborted"`) and the run ENDS with exit 1 (the chain state after a stuck group is unknown, so it does not carry on).

* **Run 2 stalled in B2 (20 minutes, no RPC in flight) right after B1m's `evm_revert`.** Evidence: the stall sat inside the wait for a mined transaction. ethers v5 never lets its block number go DOWN after a revert (offline repro: `provider.getBlockNumber()` stayed 58 on a chain at block 6) and its poll loop skips its pending-transaction checks while that clamped number does not change. The harness therefore (a) resets ethers' block caches after EVERY `evm_revert`, (b) never uses `provider.getBlockNumber()` (`blockNumber()` = one tracked `eth_blockNumber`) and never ethers' `wait()`: every transaction is sent with `eth_sendTransaction` and its receipt polled with tracked, bounded `eth_getTransactionReceipt` calls, (c) prints `STEP` lines for every transaction and ceremony step (`static call ok`, `sent 0x..`, `mined 0x.. in block N`, `tracing`, `done`) and the heartbeat reports the current step. The exact mechanism of the fork-run stall was NOT reproduced offline (self-test P5 pins down the stale block number and that sends and waits work across reverts, nested snapshots and the 1 s timestamp interval).

* **Run 3: T10 `_setCollateralFactor` mined with status 1 and left the CF at 0; every poke used exactly 60,627 gas and stored nothing. Root cause (reproduced offline with the real v3 wrapper, self-test P6.1): gas starvation of a TOLERATED inner call.** `eth_estimateGas` returns the lowest gas at which the transaction does not REVERT. The wrapper reads the vault with a `staticcall` and, in v3, prices the share 0 when that read fails for any reason other than `FeedInvalid` (an out-of-gas inner call returns empty data); the controller then RETURNS `PRICE_ERROR` (13) with status 1 instead of reverting. So the lowest non-reverting gas starves the vault read (63/64 rule): the reproduction gives an estimate of 129,046 gas, a mined transaction at 1.5 x that returns 13 and stores nothing, while the eth_call simulation (huge gas) says 0. v2 hid this because an inner failure fell back to the stored value. The harness now sends every transaction with `max(1.5 x estimate, estimate + 2,000,000)` gas (P6.2), and **a mined transaction that carries a `Failure(error, info, detail)` event is a FAILURE of the step**: `TXCODE <label> ... returned controller error PRICE_ERROR (13) info SET_COLLATERAL_FACTOR_WITHOUT_PRICE (..)` is printed (names from this tree's `ErrorReporter.sol`), the call throws, and it is recorded in `results.json` -> `data.txCodes` (P6.3). Every transaction also prints a `TXCTX` line: block timestamp, the `updatedAt` and age of the three feeds, gas limit and gas used, the wrapper's `lastGoodTime` and stored leg.
  **Consequence for the LIVE ceremony (not a harness issue): the printed `cast send` lines have no `--gas-limit`; a node's estimate for T10 (`_setCollateralFactor`) or for any keeper transaction that reads the share price can be the starving one, the transaction then mines "successfully" with the CF still 0 (T10) or a liquidation returning a price error. Use an explicit gas limit (for example 1,500,000 for T10 and liquidations of accounts that entered the share market) and ALWAYS read the result back (`verify-listing 4`).**

Exit codes and files are unchanged from run 1 (below), plus: `2` also for a failed pre-lock guard or a failed pre-build of the rewards project.

## Run it (run 1 style, kept for reference)

```bash
# once: the forge artifacts of the market contracts: tools/bp-dlmm-ceremony.sh pin rehearsal (in this tree), and ethers v5 (any of operator/, order-keeper/, range-tp-keeper/ with node_modules)
( cd <repo>/operator && npm ci )                                   # only if no node_modules/ethers v5 exists yet
DRY=1 REH_WRAPPER=0 contracts/bp-dlmm/tools/rehearsal/rehearsal.sh /tmp/bp-dry                              # static checks only
AVALANCHE_RPC='<your endpoint>' REH_WRAPPER=0 contracts/bp-dlmm/tools/rehearsal/rehearsal.sh ~/bp-rehearsal-out    # B0..B10 without the PHAR step
```

Expected last lines on success (counts are what the code defines; a NOTE is neither pass nor fail):

```
RESULTS pass=<n> fail=0 notes=<m> (<out>/results.json)
REHEARSAL PASSED
upstream HTTP status counts seen by the proxy: {"requests":...,"errors":0,"upstreamStatus":{"200":...}}
```

Exit codes: `0` nothing failed, `1` a check FAILED (see `results.json`), `2` usage / no endpoint / artifacts or ethers missing / a pre-lock guard failed, `3` fork did not come up or the ARGV CHECK failed, **`42` an HTTP 429 / rate limit was seen: STOP, report, do not switch providers**. One fork job at a time: the script takes the shared lock `/tmp/pilot-fork.lock` (mkdir; retries every 30 s; released in every exit path; override with `REH_LOCK` only in the self-test).

Files in `<out-dir>`: `rehearsal-run.log`, `results.json` (every PASS/FAIL/NOTE, gas per transaction, the B1 price table, the B7 manipulation table, the deployed addresses and creation blocks, the feed evidence), `snapshot-before.json`, `snapshot-end.json`, `diff-end.json`, `upstream-status.json`, `argv-check.txt`, `lock-minutes.log`, `pin-block.txt`, `deploy-cmd.log` (only when `BP_DEPLOY_CMD` is used).

## How it uses subagent A's work (reconciled with A's commits e80861ca / 07d98db4 / 49733d57 / 04e6064f)

* **A's ceremony tool is driven THROUGH, not re-implemented** (`BP_TOOL`, default `contracts/tools/bp-dlmm-ceremony.sh` of THIS tree; used when it and its pin file `contracts/ceremony/bp-dlmm-pin.json` exist, i.e. after `tools/bp-dlmm-ceremony.sh pin rehearsal` in this tree; `BP_USE_TOOL=1` requires it, `BP_USE_TOOL=0` forces the built-in deployment). The harness runs, against the local anvil only (`ETH_RPC_URL` = the local fork, the deployer is a throwaway address): `check rehearsal` (B0.t1), `deploy rehearsal` = A's `forge script ... --unlocked --broadcast` by the throwaway deployer, followed by its own `verify-deployed` (B0.12), `print-ledger-calls rehearsal` (B0.t5), `verify-listing rehearsal 1..4` after each stage (B1.t1, B2.t1, B2.t2, B3.t1). Without the tool or its pin file the run FAILS `B0.t0` and falls back to the built-in deployment (forge artifacts of `BP_OUT`, constructor arguments resolved by name; `B0.12b`), which is NOT the real deploy script; `BP_USE_TOOL=0` accepts that mode explicitly. `results.json` -> `data.mode` says which mode ran. `verify-deployed` compares the deployed code with the pin: the pin must match A's FINAL sources (re-pin after any source change).
* **The Ledger transactions are A's call list** (`contracts/avalanche_bp_dlmm_ceremony_calls.md`; as of A's latest tool: T1 `_setPriceOracle(wrapper)`; T2 `_setMarketBorrowCaps([market],[1])` BEFORE listing (0 would mean UNLIMITED); T3 `_supportMarket`; T4 `_setBorrowPaused(true)`; T5 `vault.approve(market, 1,000,000)`; T6 `market.mint(1,000,000)` (admin-only first mint); T7 `_setMintPaused(true)` (right after the seed mint); T8 `market.transfer(0xdEaD, 5,000,000,000)`; activation T9 `_setMintPaused(false)`, T10 `_setCollateralFactor(0.5e18)`; rollback R1 `_setPriceOracle(guarded oracle)`). The harness identifies each transaction **by meaning** (oracleSwap, capSet, list, borrowPause, approveSeed, mintSeed, seedToDead, mintPause, mintOpen, setCF, rollback) and takes the T-numbers and the order within a stage from the tool, so a reordering inside the tool (it already happened once while this harness was written) cannot desynchronise the rehearsal, while a transaction added, removed or changed in the tool fails `B0.t5` by name. B1 compares at the oracle swap, B2 runs stages 2 and 3 (with the seed-window probe right after listing), B3 runs the activation (T9, then the CF-0 negative tests, then T10), B6 the rollback. The harness sends **the tool's own printed calldata** from the impersonated Ledger and ALSO encodes every call independently from its own ABIs: `B0.t5` fails if a single byte or target differs (this cross-check also runs offline in `DRY=1`, with placeholder addresses). Every call is first executed statically (a code-returning call must give 0), then sent with 50 % gas headroom, then traced with the state-diff tracer to list the contracts it wrote. Flash loans are paused from birth by A's delegate (no transaction; asserted in B0 and B2); an outsider's first mint reverts `PharaohBoosted__SeedPending` (B2.1).
* **Other ways in**: `BP_DEPLOY_CMD='<command>' BP_DEPLOY_CWD=<dir>` (any deploy command; it is run with `ETH_RPC_URL` = the local fork and `BP_DEPLOYER`, and must write `export BP_MARKET=..`, `export BP_ORACLE=..`, optionally `export BP_DELEGATE=..` to `$BP_ADDRESSES_FILE`); `BP_ADDRESSES_FILE`; `BP_OUT`, `BP_WRAPPER_NAME`, `BP_DELEGATE_NAME`; constructor-argument override `BP_CTOR_<CONTRACTNAME>='[...]'`.
* Knobs: `BP_SEED_SHARES` (1,000,000 raw = 1 share), `BP_MIN_VAULT_SUPPLY`, `BP_INITIAL_EXCHANGE_RATE` (2e14), `BP_PTOKEN_DECIMALS/NAME/SYMBOL`, `BP_CF` (50 %), `BP_SHARE_BORROW_CAP` (1), `BP_FORK_BLOCK` (default head-4).
* **Prerequisite for the tool path** (not run by the harness because it needs a clean tree and a long build): `cd contracts && tools/bp-dlmm-ceremony.sh pin rehearsal` once per source change, so `out_bpdlmm` and the pin file exist (`BP_OUT` defaults to `contracts/out_bpdlmm`; the pre-lock guard refuses a pin whose sources hash differs from the tree).

## Rollback: both cases are tested and logged

* **Case 1, before listing** (`B1.r1`-`B1.r3`, right after the oracle swap): R1 restores the old oracle in one transaction; every price and consumer value equals the wrapper's; only the controller's oracle pointer moves; nothing is listed, so nothing can freeze.
* **Case 2, after the market exists**: `B6.a*` (seeded, nobody entered: clean, but the CF can no longer be raised, `_setCollateralFactor` returns PRICE_ERROR 13) and `B6.b*` (after activation, an account entered and borrowed: borrow, redeem, exit and its own liquidation return PRICE_ERROR until the wrapper is back; `repayBorrow` works; accounts that never entered are unaffected; re-applying the wrapper unfreezes).
* The wrapper is never in the margin path: `B1.6` asserts the risk engine, quoter and close adapter keep the guarded oracle (the liquidator reads the risk engine's), `B9.4` re-asserts it at the end.

## Known limits of the numbers

* The test wallets of B3/B5 obtain shares by `vault.deposit` (falling back to Ledger transfers): that leaves idle USDC in the vault, which dilutes the USDT leg (B5 needs a deeper depeg than on the bare 17 USDC vault), raises the NAV baseline of B7 and makes the label "Ledger (its shares at this point)" a relative one. All numbers are printed; none is assumed.
* The pair-donation observation (`B7.3`) is a measurement of the live vault, not a design guarantee.

## How it behaves

* **Instant mining** (no `--block-time`); the harness sets a 1-second block-timestamp interval so the REAL feeds (AVAX maxAge 1200 s) cannot go stale during B1 however long the run takes, and warps explicitly (`evm_increaseTime` + `evm_mine`). After every warp or snapshot revert every mock feed is **re-pinned** (`updatedAt` = head block). B0 refuses to start the comparison when a real feed is older than a safe margin (otherwise B1 would compare 0 with 0).
* **50 % gas headroom** on every harness transaction (`provider.estimateGas` wrapper), **failure tracing**: when a transaction fails (or `estimateGas` fails, in which case it is replayed once with a fixed gas limit so that a mined, failed transaction exists) the harness prints the reverting frames of `debug_traceTransaction` (callTracer) with custom errors decoded (vault, pToken, registry, executor errors; `XxxPeridottrollerRejection(code)` is read as the Compound error code).
* **Snapshots**: every destructive scenario (fork-only 100,000 USDC supply and cap raise for margin tests, rollback, inflation, stale feeds, liquidation, manipulation) runs between `evm_snapshot` and `evm_revert`, so B3 really tests the 200 USDC cap and the 50 USDC cash floor and B9 really compares with the start.
* **Ethers v5 structs** with fields that collide with Array methods are read by index; `getAccountLiquidity` returns `(error, liquidity, shortfall)`.

## What is real and what is mocked

* **Real up to B1's identity comparison**: the Chainlink feeds, the guarded oracle, the controller, the live margin stack (risk engine, quoter, executor, registry, adapter), the DLMM vault with its bins. No mock exists before the old-vs-wrapper price comparison is finished.
* **From then on the three feeds (AVAX/USD, USDC/USD, USDT/USD) are MOCKS** (`MockFeed.json`, runtime code placed at the real feed address, at the REAL answers) because a fork cannot move real feeds: margin TP/SL tests need the AVAX price to follow the pool; B4 and B10 need old feeds; B5 needs a USDT depeg. Real feed lag, heartbeat and round behaviour are **not** rehearsed after B1 (B0.f* prints the real ones before the mocks exist). The mock model needs the vault's USDC feed and the base oracle's USDC feed to be the SAME contract (B0.f6 asserts it).
* Fork-only helpers (always reverted by their scenario): USDC balances forced by storage write, 100,000 USDC supplied to pUSDC and its cap raised for the margin sections.

## Findings the harness is built around (read from the source)

* The margin stack does **not** read `controller.oracle()`: the risk engine and the quoter hold their own pointer (the guarded oracle) and the liquidator reads the risk engine's. The oracle swap therefore changes only the controller's price path (borrow, redeem, liquidate, seize, CF checks, `getAccountLiquidity` of margin accounts); B1 asserts the margin pointers are unchanged and compares the controller-side reads and the margin-side reads separately. The wrapper must also expose `getPrice(asset)` / `marketAsset(pToken)` (forwarded verbatim by A's wrapper) for the off-chain operator code, which reads `controller.oracle()`.
* A pToken's user functions **revert** with `BorrowPeridottrollerRejection(code)` etc. while the controller's admin functions **return** the code; both are handled.
* After the swap, `_setCollateralFactor(pBP, 50 %)` needs a non-zero share price: B3 shows the order matters, B6 shows it returns 13 after a rollback.
* Compound semantics that B6 and B10 assert: an account that **entered** a market whose price is 0 cannot borrow, redeem, exit or be liquidated (the liquidity query returns PRICE_ERROR); accounts that never entered it are unaffected; repayment never reads a price. This is why v1's "stale feed => price 0" was dangerous (entering is free and needs no balance), and why the v2 wrapper serves a 24 h fallback instead: with it the same account is priced and liquidatable during the outage (B4, B10), and only after the window expires (B10.16-B10.17) does the old behaviour return.
* **The fallback needs a poker**: the vault leg dies when the USDT feed is older than 93,600 s, the fallback window is 86,400 s after the LAST store; a wrapper nobody pokes has no usable fallback at the moment the vault dies (B10.n2). Anyone may call `poke()`; the stored value follows the live vault only downward at once and upward by at most 2 % per hour (B10.3-B10.6).

## B5: how an account is made underwater (justification)

The wrapper prices a share as `convertToAssets(1 share) x USDC price` and debt is priced by the same USDC feed, so moving the USDC feed does nothing. The vault's NAV, however, values its **USDT leg with the USDT/USD feed** (`totalAssets` -> `_pairToAsset`), and an **out-of-band answer does not revert** `totalAssets` (only a stale or bad round does). A USDT depeg therefore lowers `convertToAssets` through the vault's real code, and is the one realistic way a share price falls below its debt. The harness mocks the USDT feed only (no vault storage is edited), borrows ~98.5 % of the power, and steps the USDT price down (99, 97, 95, 90, 80, 60, 40 % of $1) until the controller reports a shortfall. If the USDT leg is too small a part of the NAV for that to work, it falls back to a *synthetic loss* (impersonating the vault to burn 30 % of its bins to a third party), says so in the log and marks the method; if neither works, B5 is a NOTE ("no faithful method") and the offline tests carry the logic. The liquidator is a funded wallet that repays USDC and **keeps the seized pTokens** (it never redeems them); the harness checks balances, the 50 % close factor, the 108 % incentive (recomputed independently), the protocol seize share and the shortfall formula.

## What was verified offline, and what only the fork can verify

Verified by the assistant: `node --check` of every script; `DRY=1` (every `Interface` constructs, every planned call encodes, every address checksums, the artifacts and the wrapper/market constructors resolve, the wrapper artifact is v2 with runtime size 3,628, every check id is in this README and used once, the PHAR expected-split model equals the generator's own `wrapperSplit` on random histories, a `wrappers.json` for the market parses with the generator's parser); the self-test cases P3 (the REAL v2 wrapper bytecode on stand-in vault / base oracle / pToken contracts: `expectPoke`, `shareExpect`, `fallbackLeg`, the `shareState()` indices, `warpTo` and the exact 24 h boundary with static calls) and P4 (model vs generator, two seeds); `selftest.sh` (a local anvil with chain id 43114 plays the upstream; `rehearsal.sh` forks it through the real proxy path and runs `selftest/selftest.mjs`: gas headroom, failure tracing with nested custom errors, balance forcing for slot 0 and slot 9 layouts, mock feeds and re-pinning after a warp, snapshots, timestamp pinning, the prestate tracer, the results writer, the lock held by another job, the ARGV CHECK negative case, the 429 path -> exit 42, a failing check -> exit 1, DRY with and without the PHAR step, the pre-lock guards (a pin for another wrapper version; the PHAR step on without `REH_SCAN_FROM`)). **Not verifiable without the fork**: every `B*` check itself (it reads the live contracts); that the live addresses still match (B0 reads them all back); that the prestate tracer works on the user's anvil (a call-target fallback exists); pool depth for B7 swaps and for the margin moves; the exact numbers (they are printed, not assumed).

## Checks

Every line is `PASS <id> <text>`, `FAIL <id> <text> :: <detail>` or `NOTE <id> <text>` (an observation recorded for the integrator). Texts below are cut from the code; `...` stands for a number printed at run time.

<!-- CHECKS:BEGIN -->
| id | kind | what it asserts / records |
|---|---|---|
| `B0.1` | PASS/FAIL | local anvil fork, chain id 43114, pinned block … (head …) |
| `B0.2` | PASS/FAIL | every live contract address has code (… addresses) |
| `B0.3` | PASS/FAIL | controller.oracle() = the guarded oracle …, controller admin = the Ledger, guarded.source = … |
| `B0.4` | PASS/FAIL | closeFactor 50 %, liquidation incentive 108 % |
| `B0.5` | PASS/FAIL | pWAVAX CF 30 % borrow paused; pUSDC CF 0, borrow cap 200 USDC, cash floor 50 USDC (pUSDC cash …, borrows … USDC) |
| `B0.6` | PASS/FAIL | exactly the two existing markets are listed (…) |
| `B0.7` | PASS/FAIL | DLMM vault: asset USDC, 6 decimals, owner = the Safe, feeds = the live USDC/USDT feeds, pair and router as pinned |
| `B0.8` | PASS/FAIL | share holders: Ledger …, dead …, total … (state moved since the brief if this fails) |
| `B0.9` | PASS/FAIL | real feeds are fresh with margin at the pin (age s: AVAX … (maxAge 1200), USDC … (maxAge 90000), USDT … (vault maxFeedAge …)); a stale feed would make B1 compare 0 with 0 - re-run if this fails |
| `B0.10` | PASS/FAIL | the margin stack holds ITS OWN oracle pointer = the guarded oracle (risk engine and quoter); it does not read controller.oracle() |
| `B0.11` | PASS/FAIL | live margin positions opened …, orders … |
| `B0.12` | PASS/FAIL | the REAL deploy script ran on the fork through the tool by the throwaway deployer (exit …) and its verify-deployed (code == the pinned build, wrapper == guarded oracle for every market) passed; log tool-deploy-rehearsal.log |
| `B0.12a` | PASS/FAIL | new contracts: market … (created in block …), wrapper … (block …), delegate … |
| `B0.12b` | PASS/FAIL | built-in deployment by the throwaway deployer from the forge artifacts of … (NOT the real deploy script - use the ceremony tool for the real rehearsal): delegate …, market …, wrapper … |
| `B0.13` | PASS/FAIL | starting state: the market is deployed (underlying = the DLMM vault, controller = the live one, admin = the Ledger), NOT listed, pToken supply 0 |
| `B0.14` | PASS/FAIL | the delegate pinned the vault at deployment (pharaohVault() = …, minimum supply …) |
| `B0.15` | PASS/FAIL | flash loans are PAUSED FROM BIRTH (delegate _becomeImplementation) and maxFlashLoan(shares) = 0 |
| `B0.16` | PASS/FAIL | wrapper: base oracle = the live guarded oracle, market = the new pToken, vault = the DLMM vault, asset = USDC |
| `B0.17` | PASS/FAIL | the wrapper already prices the (unlisted) share market: … (USD per raw share x 1e36 / 1e18... = … USD per whole share) |
| `B0.f1` | PASS/FAIL | evidence readable: the base oracle's feeds for USDC and WAVAX are enabled, and the vault's feedAsset / feedPair and both base feeds all answer (answer > 0, updatedAt > 0) |
| `B0.f2` | NOTE | VAULT … |
| `B0.f3` | NOTE | VAULT … \| maxFeedAge … s (a feed older than that makes totalAssets/convertToAssets revert FeedInvalid) |
| `B0.f4` | NOTE | BASE ORACLE USDC (key …) … \| maxAge … s \| feed decimals … \| enabled … |
| `B0.f5` | NOTE | BASE ORACLE WAVAX (key …) … \| maxAge … s \| feed decimals … \| enabled … |
| `B0.f6` | PASS/FAIL | THE HARNESS'S MOCK MODEL HOLDS: the vault's USDC feed (…) is the SAME contract as the base oracle's USDC feed (…), so ONE re-pinned mock at that address refreshes both the vault's asset leg and pUSDC / the wrapper's USDC price; the AVAX feed and the USDT feed are the pinned ones. If this fails the outage and stale-feed groups would test the wrong thing |
| `B0.f7` | NOTE | VERDICT: the vault's USDC/USD feed … as the base oracle's USDC/USD feed (latest round identical: …). … Ages now: vault asset … s, vault pair … s, base USDC … s, base AVAX … s. |
| `B0.n1` | NOTE | block timestamp interval set to 1 s (deterministic time for the real-feed comparison in B1) |
| `B0.n2` | NOTE | vault: totalAssets … USDC, depositCap …, paused …, guard unsafe=… latched=… reasons=…, maxDeposit …, maxFeedAge …s, legBand …bp, poolDev …bp |
| `B0.t0` | PASS/FAIL | A's ceremony tool is not usable (tool …, pin file …): the run falls back to the BUILT-IN deployment, which is NOT the real deploy script; run 'tools/bp-dlmm-ceremony.sh pin rehearsal' in A's worktree, or set BP_USE_TOOL=0 to accept the built-in mode explicitly |
| `B0.t5` | PASS/FAIL | every Ledger transaction printed by the tool's print-ledger-calls (…) has byte-identical calldata AND target to the harness's own independent encoding, and the harness knows no transaction the tool does not print (the harness sends the order the tool prints: …) |
| `B0.v0` | PASS/FAIL | the deployed wrapper answers shareState(): it is the v2 wrapper (run 1 used v1, which has no such function): if this fails re-pin and rebuild in THIS tree |
| `B0.v1` | PASS/FAIL | the constructor stored the LIVE vault leg: lastGoodAssetsPerShare … = convertToAssets(1e6) at the deployment block … (…) = now (…); lastGoodTime … = that block's timestamp; exactly one FallbackPriceStored(…, …) |
| `B0.v2` | PASS/FAIL | shareState() is consistent: live … = stored … (at …), usingFallback …, … s of window left = 86,400 - age …; getShareUsdPrice = price / 1e12; price = stored x the base oracle's USDC price (recomputed) |
| `B0.v3` | PASS/FAIL | constants: FALLBACK_HAIRCUT_BPS … (3 %), FALLBACK_WINDOW … s (24 h), POKE_MAX_UP_BPS … (2 %), POKE_UP_INTERVAL … s (1 h); share and asset decimals 6 |
| `B0.v4` | PASS/FAIL | runtime sizes (EIP-170 limit …): wrapper … bytes (v2 = …), market (delegator) …, delegate …, accounting module …; on chain == the pin … |
| `B1.1` | PASS/FAIL | BEFORE the swap the real prices are non-zero (so equality below is not 0 == 0): pWAVAX …, pUSDC …, getPrice(WAVAX) …, getPrice(USDC) … |
| `B1.2` | PASS/FAIL | controller.oracle() is now the wrapper … (the oracle-swap transaction only) |
| `B1.3` | PASS/FAIL | wrapper == old oracle BIT-IDENTICAL for getUnderlyingPrice(pWAVAX, pUSDC), getPrice(WAVAX, USDC) and marketAsset(pWAVAX, pUSDC) at the same block (… values) |
| `B1.4` | PASS/FAIL | the prices read before the swap equal the prices read through the wrapper after it (the real feeds did not move between the two reads) |
| `B1.5` | PASS/FAIL | after the swap the prices are still non-zero (not a stale-feed 0 == 0) |
| `B1.6` | PASS/FAIL | THE WRAPPER IS NOT IN THE MARGIN PATH: the risk engine and the quoter still point at the guarded oracle and so does the close adapter (…); the liquidator reads the risk engine's pointer - the swap changed only the controller pointer |
| `B1.7` | PASS/FAIL | controller.getAccountLiquidity of the live margin accounts, risk-engine getMetrics, quoter.quoteOpen and the controller's liquidateCalculateSeizeTokens (both directions) are IDENTICAL before and after the swap (… values) |
| `B1.8` | PASS/FAIL | executor positions 1 and 2, registry orders and the raw storage of the margin proxies are field-for-field unchanged by the swap (debt interest excluded) |
| `B1.9` | PASS/FAIL | lending state of the existing markets (CF, caps, pauses, floor, admin, rate model, flags) and every code hash in the account's path unchanged by the swap |
| `B1.10` | PASS/FAIL | the ONLY pointer that moved is controllerOracle (…) |
| `B1.11` | PASS/FAIL | the oracle swap writes state in exactly one contract of the account's path: … (state-diff trace; all touched: …) |
| `B1.12` | PASS/FAIL | wrapper.marketAsset(pBP) forwards the base oracle verbatim (…): the share market is NOT a margin market |
| `B1.n1` | NOTE | the wrapper prices the share market at … (= … USD per whole share) while the controller has not listed it yet |
| `B1.n2` | NOTE | from here the AVAX, USDC and USDT feeds are MOCKS at their real answers (a fork cannot move real feeds; real feed lag, heartbeat and round behaviour are NOT rehearsed after this point) |
| `B1.r1` | PASS/FAIL | ROLLBACK BEFORE LISTING (case 1): one Ledger transaction restores controller.oracle() = the guarded oracle and every existing price/consumer value equals the one read through the wrapper |
| `B1.r2` | PASS/FAIL | nothing but the controller's oracle pointer moves (…); no market is listed yet, so nothing can be frozen |
| `B1.r3` | PASS/FAIL | the controller-side and margin-side views (liquidity of the live margin accounts, getMetrics, quoteOpen, seize calculation) are identical after the rollback |
| `B1m.1` | PASS/FAIL | margin OPEN after the oracle swap: a 2x long (position …) was opened through the live executor; its borrow went through the controller priced by the WRAPPER (controller.oracle() = …) |
| `B1m.2` | PASS/FAIL | a stop-loss (order …) and a take-profit (order …) are registered in the LIVE order registry; the live adapter is … (pinned in live-addresses.env as …) |
| `B1m.3` | PASS/FAIL | the take-profit does not execute before its trigger (…) |
| `B1m.4` | PASS/FAIL | TAKE-PROFIT executed through the live registry/adapter AFTER the swap (permissionless call): position … CLOSED, order … EXECUTED |
| `B1m.5` | PASS/FAIL | the sibling stop-loss was cancelled by the TP execution (order … status …) |
| `B1m.6` | PASS/FAIL | margin CLOSE after the swap: position … closed by its stop-loss through the live registry/adapter (order … EXECUTED) |
| `B1m.7` | PASS/FAIL | live positions 1 and 2 and live orders 1..4 are field-for-field unchanged by the margin activity of other users |
| `B1m.n1` | NOTE | fork only (reverted with the scenario): 100,000 USDC supplied to pUSDC and its borrow cap raised, so two new test positions can borrow; not part of the ceremony |
| `B2.1` | PASS/FAIL | SEED WINDOW: between listing and the seed an outsider's mint is refused (…); the delegate allows only the admin to make the first mint |
| `B2.2` | PASS/FAIL | LISTED with collateral factor 0 as the third market |
| `B2.3` | PASS/FAIL | borrow paused and cap … (non-zero: 0 would mean UNLIMITED; effectively zero: <= 1000 raw shares) |
| `B2.4` | PASS/FAIL | flash loans paused: flag true, maxFlashLoan 0, flashLoan() reverts 'flash loans are paused' |
| `B2.5` | PASS/FAIL | PERMANENT SEED: … pTokens at 0xdEaD = the entire pToken supply (…); the market holds … raw shares of cash; the Ledger holds no pTokens |
| `B2.6` | PASS/FAIL | mint is paused after the seed (T8): an outsider's mint reverts 'mint is paused' |
| `B2.7` | PASS/FAIL | a pWAVAX holder with liquidity … cannot borrow shares: … |
| `B2.8` | PASS/FAIL | DEFENCE IN DEPTH: even with the borrow pause lifted, the cap (…) refuses any borrow of shares: … |
| `B2.9` | PASS/FAIL | wrapper price of the share market = convertToAssets(1 share) x USDC feed, recomputed independently: … (… USD per share) |
| `B2.10` | PASS/FAIL | after the whole listing the existing markets still price identically through the wrapper and the old oracle |
| `B2.11` | PASS/FAIL | the controller and the new market are administered by the Ledger; symbol …, decimals …, exchange rate … |
| `B2.n0` | NOTE | mallory could not obtain shares through the vault (…): the seed-window probe uses the Ledger's shares instead |
| `B3.1` | PASS/FAIL | there is room to borrow … USDC inside the live 200 USDC cap and the 50 USDC cash floor (cash …, borrows …) |
| `B3.2` | PASS/FAIL | SUPPLY: … raw shares (…) -> … pTokens at exchange rate …; entered the market |
| `B3.3` | PASS/FAIL | CF 0: the supplied shares give NO borrow power (liquidity …) and a borrow returns INSUFFICIENT_LIQUIDITY (4): … |
| `B3.4` | PASS/FAIL | _setCollateralFactor(pBP, 50 %) returns 0 (success) - it needs the wrapper's non-zero share price |
| `B3.5` | PASS/FAIL | read-back: collateralFactorMantissa = … |
| `B3.6` | PASS/FAIL | liquidity = CF x value: … vs independent … (collateral value … USD, … of it) |
| `B3.7` | PASS/FAIL | borrowing 0.02 USDC more than the power (… vs …) is refused: INSUFFICIENT_LIQUIDITY (4) … |
| `B3.8` | PASS/FAIL | the 200 USDC pUSDC borrow cap still binds: … |
| `B3.9` | PASS/FAIL | BORROW … USDC against shares: callStatic returns 0 |
| `B3.10` | PASS/FAIL | carol received exactly … USDC, debt …, pUSDC cash … >= the 50 USDC floor |
| `B3.11` | PASS/FAIL | liquidity fell … -> …, no shortfall |
| `B3.12` | PASS/FAIL | REPAY: debt 0, paid … USDC |
| `B3.13` | PASS/FAIL | REDEEM: … pTokens -> … raw shares back (supplied …; rounding loss …) |
| `B3.14` | PASS/FAIL | a standing borrower exists (dave: … pTokens, debt … USDC, healthy) |
| `B3.n0` | NOTE | vault.deposit refused for a test wallet (…): shares are taken from the Ledger instead |
| `B3.n1` | NOTE | ACTIVATION step 1 (T9): supply opened with one Ledger transaction (_setMintPaused(market,false)); the listing leaves mint paused |
| `B4.1` | PASS/FAIL | USDT feed older than the vault's maxFeedAge (… s): vault.totalAssets() and convertToAssets() REVERT (…) |
| `B4.2` | PASS/FAIL | v2 FALLBACK: with the vault leg dead the wrapper does NOT return 0 and does not revert: usingFallback … (stored … written … s ago), price … = stored x 0.97 x the live USDC price (… recomputed) < the live-leg price …; pUSDC and pWAVAX stay priced |
| `B4.3` | PASS/FAIL | an account that entered the share market is PRICED (v1: error 13): getAccountLiquidity error …, liquidity … < … at the live price (the 3 % haircut), shortfall … |
| `B4.4` | PASS/FAIL | BOUNDED, NOT FROZEN: dave can still borrow (…) and redeem pTokens (…) while the share price is the fallback (the haircut leaves the healthy account healthy) |
| `B4.5` | PASS/FAIL | a HEALTHY account is not liquidatable at the fallback price: rejected with INSUFFICIENT_SHORTFALL (3), not PRICE_ERROR (13) (…); B10 liquidates an insolvent account the same way |
| `B4.6` | PASS/FAIL | the live margin accounts (they never entered the share market) are unaffected (getAccountLiquidity error …) |
| `B4.7` | PASS/FAIL | the vault's exit path redeemInKind still works with the feed stale (no oracle read): … |
| `B4.8` | PASS/FAIL | USDC feed 91,000 s old (guarded maxAge 90,000, vault maxFeedAge 93,600): the vault still prices, but the wrapper's share price AND pUSDC are 0 (the share price uses the BASE oracle's USDC price; NEVER a fallback when the USDC price is missing: usingFallback false); pWAVAX stays priced |
| `B4.9` | PASS/FAIL | borrow refused with PRICE_ERROR (…) |
| `B4.10` | PASS/FAIL | after 100,000 s with no feed update every price is 0 (USDC feed age … s): share (the stored value is older than 24 h AND the USDC price is missing: no fallback), pUSDC and pWAVAX |
| `B4.11` | PASS/FAIL | all borrowing is fail-closed (…) |
| `B4.12` | PASS/FAIL | RESTORE: when the feeds publish again the share price and pUSDC price return without any transaction on our side |
| `B4.13` | PASS/FAIL | dave's account answers again (liquidity …, shortfall …) |
| `B4.14` | PASS/FAIL | borrowing works again (…) |
| `B5.1` | PASS/FAIL | setup: erin supplied … raw shares (…) and borrowed … USDC (… of her power); healthy: liquidity …, shortfall … |
| `B5.2` | PASS/FAIL | METHOD: …. Underwater found at …: shortfall …; vault convertToAssets(1 share) … -> … |
| `B5.3` | PASS/FAIL | SHORTFALL MATH: controller shortfall … == debt value … - CF x collateral value … = … |
| `B5.4` | PASS/FAIL | CLOSE FACTOR 50 %: repaying more than … USDC is refused (…) |
| `B5.5` | PASS/FAIL | INCENTIVE: seize … pTokens == repay x 108 % x p(USDC) / p(share) / exchange rate = … |
| `B5.6` | PASS/FAIL | liquidateBorrow(erin, … USDC, pBP) static call returns 0 |
| `B5.7` | PASS/FAIL | the liquidator paid … USDC and the borrower's debt fell … -> … |
| `B5.8` | PASS/FAIL | SEIZE-AND-KEEP: the liquidator holds … pBP (seized … less the protocol's … % = …) and keeps them as pTokens (not redeemed); the borrower lost … |
| `B5.8b` | PASS/FAIL | the liquidator's pToken delta (…) equals the LiquidateBorrow event's seizeTokens (…) minus the … % protocol seize share (…) |
| `B5.9` | PASS/FAIL | the protocol's seize share went to reserves (pToken supply fell by exactly that share) |
| `B5.10` | PASS/FAIL | the liquidator's seized value … USD exceeds the repaid … USD by … % (108 % incentive less the protocol's seize share) |
| `B5.n1` | NOTE | NO faithful way found to make the account underwater: the liquidation test is not run (the offline unit tests cover the logic) |
| `B5.n2` | NOTE | at that point the vault's own guard reads unsafe=… reasons=… (8 = PAIR_LEG_OUT_OF_BAND): deposits are closed, but convertToAssets (the wrapper's input) keeps answering - the wrapper does not look at the guard |
| `B5.n3` | NOTE | after one liquidation the borrower's state: liquidity …, shortfall … (…) |
| `B6.a1` | PASS/FAIL | ONE Ledger transaction sets the controller's oracle back to the guarded oracle |
| `B6.a2` | PASS/FAIL | after the rollback the existing markets are priced exactly as before and the share market has NO price (the guarded oracle does not know it: 0) |
| `B6.a3` | PASS/FAIL | the rollback changes only the controller's oracle pointer; no position, order, code or market parameter moves (…) |
| `B6.a4` | PASS/FAIL | FROZEN: _setCollateralFactor(pBP, 50 %) now returns PRICE_ERROR (13): no borrowing against shares can be enabled (…) |
| `B6.a5` | PASS/FAIL | a margin position can still be opened after the rollback (the margin stack never depended on the wrapper) |
| `B6.a6` | PASS/FAIL | re-applying the wrapper is one more Ledger transaction and restores the share price |
| `B6.b1` | PASS/FAIL | ONE Ledger transaction rolls the oracle back while dave has entered the share market and borrowed |
| `B6.b2` | PASS/FAIL | FROZEN: dave's liquidity query now returns PRICE_ERROR (…) because the guarded oracle prices the share market at 0 |
| `B6.b3` | PASS/FAIL | FROZEN: dave cannot borrow more (…) nor redeem pTokens (…) |
| `B6.b4` | NOTE | exitMarket(pBP) by dave while debt is open: … (12 = NONZERO_BORROW_BALANCE) |
| `B6.b5` | PASS/FAIL | FROZEN: dave cannot be liquidated either (…) - an account that entered the share market is a blind spot until the wrapper is back |
| `B6.b6` | PASS/FAIL | REPAY still works during the rollback (repayBorrow reads no price): dave's debt is 0 |
| `B6.b7` | NOTE | with the debt repaid, dave's pBP redeem is … and exitMarket is … (redeem 13 = PRICE_ERROR and exitMarket 14 = REJECTION with opaque code 13 mean his pTokens stay stuck until the wrapper is re-applied) |
| `B6.b8` | PASS/FAIL | accounts that never entered the share market are unaffected: a pUSDC supplier redeems (…), live margin position 1 liquidity error … |
| `B6.b9` | PASS/FAIL | no live margin position, order or code hash moved during the rollback |
| `B6.b10` | PASS/FAIL | re-applying the wrapper unfreezes everything: dave's liquidity answers and his pTokens redeem again |
| `B6.n1` | NOTE | CONCLUSION: the one-transaction rollback is a clean undo only while NO account has entered the share market. After that it freezes those accounts' borrow, redeem and liquidation until the wrapper is re-applied; the safer reaction to a bad share price is the CF -> 0 / mint pause path (and, for a stale feed, the v2 wrapper's 24 h fallback: B4, B10), not the rollback. |
| `B7.2` | PASS/FAIL | donated USDT is valued with the USDT feed: extra power … < cost … |
| `B7.3` | NOTE | donating USDC to the PAIR: the vault's share price … (… -> …); expected (bin reserves are accounted by the pair, not by its token balance) - a measurement of the live vault, not a guarantee |
| `B7.5` | NOTE | after the swaps: vault guard reasons … (16 = POOL_ORACLE_DEVIATION), maxDeposit …, a deposit …; the wrapper price is … (nonzero) - the wrapper does not read the guard (a design decision: report to the integrator) |
| `B7.6` | PASS/FAIL | a round trip through the pool leaves the share price at or above where it started (… -> …): the trader paid fees and slippage to the LPs |
| `B7.n…` | NOTE | …: cost … USDC \| 1 share … -> … USDC (… bp) \| NAV … \| guard reasons … \| extra borrow power at CF 50 %: …: …`).join("; ")} |
| `B7.n0` | NOTE | BASELINE: NAV … USDC vs depositCap …, supply …, 1 share = … USDC, wrapper price …, guard reasons …, maxDeposit …; borrow power at CF 50 % of ALL … shares = … USDC |
| `B8.1` | PASS/FAIL | a direct donation of … raw shares raises the exchange rate … -> …; the attacker holds no pTokens, so the whole donation accrues to the pToken holders (the dead seed) |
| `B8.2` | PASS/FAIL | the second depositor still receives pTokens after the donation (… pTokens for … raw shares; no zero-mint) |
| `B8.3` | PASS/FAIL | the second depositor redeems … of … raw shares: rounding loss … <= … (one pToken's worth of rate) |
| `B8.4` | PASS/FAIL | the donation is not recoverable by the attacker: the dead seed's claim went from … to … raw shares (the attacker paid … and holds nothing) |
| `B9.1` | PASS/FAIL | the live margin positions (1 and 2) and orders (1..4) are field-for-field unchanged at the end (debt interest excluded) |
| `B9.2` | PASS/FAIL | the margin proxies (implementation, admin, 70 raw storage slots each) and every code hash in the account's path are unchanged |
| `B9.3` | PASS/FAIL | lending configuration of the existing markets (CF, caps, pauses, floor, admin, rate model, reserve factor, flash flag) and of the controller (close factor, incentive, guardian) is unchanged; only allMarkets gained the new market |
| `B9.4` | PASS/FAIL | the only pointer that moved is controller.oracle() -> the wrapper (risk engine and quoter still …) |
| `B9.5` | PASS/FAIL | the new market ends as designed: listed, CF …, borrow paused, flash loans paused, cap … |
| `B9.6` | PASS/FAIL | CONTRACTS TOUCHED (state written) by the whole ceremony: … addresses; of those in the account's path: … (expected: the controller [oracle pointer, new market, flags] and the DLMM vault [the seed transfer]); the new market … and the wrapper's market … are new |
| `B9.n1` | NOTE | balance-type fields of the existing markets that moved because the TEST users supplied/borrowed (expected): … |
| `B9.n2` | NOTE | GAS of the ceremony txs: …)} |
| `B9.n3` | NOTE | (computed text) |
| `B10.1` | PASS/FAIL | setup: frank supplied … raw WAVAX (pWAVAX CF 30 %), borrowed … USDC (… of his power), ENTERED the share market holding 0 pBP; healthy: liquidity …, shortfall … |
| `B10.2` | PASS/FAIL | no outage: the wrapper's share price … = convertToAssets(1 share) … x the base oracle's USDC price … (recomputed independently); shareState: live …, stored … (at …), usingFallback …, … s of window left |
| `B10.2b` | PASS/FAIL | BROKEN VAULT (not an outage): with the pair's code removed (feeds fresh) convertToAssets reverts with …… (not FeedInvalid …); the wrapper prices the share 0 AT ONCE although the stored value is fresh (… s of window left): usingFallback …, price …, live …; poke() returns … |
| `B10.2c` | NOTE | FAULT INJECTION INEFFECTIVE: with the pair's code removed convertToAssets still answers (…): the broken-vault case could not be provoked on the fork; the offline self-test P3.7 covers it with stand-ins |
| `B10.2d` | PASS/FAIL | the pair's code is restored and the share price is the live price again |
| `B10.3` | PASS/FAIL | a first poke after more than an hour stores the live leg (…; the constructor stored …) and emits FallbackPriceStored |
| `B10.4` | PASS/FAIL | UPWARD move inside … s of the last store is REFUSED: live leg … (> stored … x 1.02 = …), poke() returns false and stores nothing |
| `B10.5` | PASS/FAIL | the next upward poke is stored CAPPED at +2 %: stored … = floor(… x 10200 / 10000), below the live leg … |
| `B10.6` | PASS/FAIL | directly after a store a further upward poke is refused (…); an hour later it moves by at most another 2 %: … -> … (cap …, live …) - the stored value follows a glitch by at most 2 % per hour |
| `B10.7` | PASS/FAIL | the keeper's poke while the vault still answers stores … at … (expected from the specification: …; live …, previous … stored … s earlier) |
| `B10.8` | PASS/FAIL | the vault leg is DEAD (USDT feed … s old > maxFeedAge …): through the PROXY the RAW revert data of convertToAssets is … and of totalAssets …: selector … = FeedInvalid(uint8) with argument 2 (the selector the v3 wrapper keys on); the USDC and AVAX mocks are fresh (USDC … s, AVAX … s) |
| `B10.9` | PASS/FAIL | FALLBACK: usingFallback true, live 0, stored …, … s left; price … = stored x 0.97 x the LIVE USDC price … (… recomputed independently); getShareUsdPrice() agrees |
| `B10.10` | PASS/FAIL | poke() returns false while the vault cannot answer (nothing is stored from a dead vault); pWAVAX and pUSDC keep their live prices |
| `B10.11` | PASS/FAIL | the account that entered the share market is PRICED, not frozen: getAccountLiquidity error … (v1 gave 13 = PRICE_ERROR here), shortfall … after AVAX -60 % |
| `B10.12` | PASS/FAIL | LIQUIDATION WORKS during the outage (share price = the fallback): liquidateBorrow static call returns …; the liquidator paid … USDC (= repay), received … pWAVAX (seized … less the protocol share), frank lost … pWAVAX and … USDC of debt |
| `B10.13` | PASS/FAIL | R1 (one Ledger transaction) while the fallback is active: every existing market is priced IDENTICALLY by the guarded oracle and by the wrapper at the same block (… values), the share market (fallback price … under the wrapper) is priced 0 by the guarded oracle |
| `B10.14` | PASS/FAIL | the account that entered the share market is FROZEN under the guarded oracle (liquidity error …, liquidation code …), the live margin account that never entered it is not (error …): the rollback is a clean undo only while nobody has entered |
| `B10.15` | PASS/FAIL | re-applying the wrapper restores frank's liquidity answer and the fallback price |
| `B10.16` | PASS/FAIL | the fallback is valid at age EXACTLY 24 h (head … = stored … + …): usingFallback …, 0 s left, price … still the fallback price, liquidation static call code … |
| `B10.17` | PASS/FAIL | ONE SECOND LATER (age … s, nobody poked): share price 0, usingFallback false, liquidation of frank returns PRICE_ERROR … (13), his liquidity query error … |
| `B10.18` | PASS/FAIL | the expiry is confined to the share market: pWAVAX and pUSDC stay priced, the live margin account that never entered it answers (error …), poke() still returns false (the vault is dead) |
| `B10.19` | PASS/FAIL | USDT restored: the share price is the LIVE price again (… = … x …) with no transaction; the stored value is untouched and still expired (…, … s old) |
| `B10.20` | PASS/FAIL | poke() after the outage stores the LIVE value UNCAPPED because the old one is older than 24 h: … -> … (live …; a capped poke would have given at most …); price = live price … |
| `B10.21` | PASS/FAIL | LIQUIDATION WORKS AGAIN after the feed is back, the poke done and the price the live price: static call …, paid … USDC, received … pWAVAX, frank lost … pWAVAX |
| `B10.n0` | NOTE | fork only (reverted with the scenario): 100,000 USDC supplied to pUSDC and its borrow cap raised so the test account can borrow; not part of the ceremony |
| `B10.n1` | NOTE | TIMELINE: the USDT/USD feed stops updating at t0 = …; the vault's maxFeedAge is … s, the wrapper's fallback window … s. A keeper pokes at t0 + 80,000 s (vault still answering); the vault leg dies at t0 + …; the stored value expires 24 h after the poke. |
| `B10.n2` | NOTE | FINDING: a wrapper that is never poked has NO usable fallback when the USDT feed stops: the vault leg dies at 93,600 s of feed age, the fallback window is 86,400 s after the last store, so without a keeper poking at least once in the last ~24 h the outage window opens at price 0 (the v1 behaviour). The harness pokes at t0 + 80,000 s to model the keeper; a poke cadence of a few hours (any account m |
| `B11.n0` | NOTE | the PHAR step was SKIPPED (REH_WRAPPER=0) |
| `B11.n1` | NOTE | suppliers added: Ledger … pTokens (… shares), Carol … (…, her only holding is the market), Bob … (…), a donation of … shares straight to the market; the permanent seed (… pTokens at 0xdEaD) and the B3 account dave were already in the market |
| `B11.n2` | NOTE | a second publish of the same id is refused by the tool (epochCount is 1): exit …: … |
| `B11.n3` | NOTE | PHAR step finished in … s (generator run 1: … s incl. later steps); the epoch files of this rehearsal are in … and are NOT publishable |
| `B11.p00` | PASS/FAIL | anvil fork of chain 43114 at block … (> the first epoch start …); vault supply … shares; the market under test is … (deployed by this run at block …) |
| `B11.p01` | PASS/FAIL | the REAL vault: owner = the Safe, rewardToken = PHAR, rewarder = …, has a band […,…] |
| `B11.p02` | PASS/FAIL | the Ledger holds … shares, the dead seed … shares |
| `B11.p03` | PASS/FAIL | Bob (EOA …) holds … shares and the contract … holds … shares (both sent by the impersonated Ledger) |
| `B11.p04` | PASS/FAIL | chain time advanced by … s (>= …); feeds were re-pinned after every warp |
| `B11.p05` | PASS/FAIL | pending PHAR on the band …..… = … wei after the warp (0 means REH_WARP_SECONDS=172800 and run again) |
| `B11.p06` | PASS/FAIL | harvest … at block …: PharHarvested.amount … wei, the Safe's PHAR rose by … (pending was …) |
| `B11.p07` | PASS/FAIL | (computed text) |
| `B11.p08` | PASS/FAIL | first-epoch parameters: epoch 0, start …, end … = the fork harvest block, user-bps …, … harvest(s) summing … wei (the fork's own: …), scan-from … |
| `B11.p09` | PASS/FAIL | every generator check is true (…) |
| `B11.p10` | PASS/FAIL | the dead seed is excluded (reason …), its slice … wei stays with the Safe, and it has no leaf |
| `B11.p11` | PASS/FAIL | the contract holder … is excluded (reason …), its slice … wei stays with the Safe, and it has no leaf |
| `B11.p12` | PASS/FAIL | the Ledger (…) and Bob (…) have leaves equal to floor(pool * weight / totalWeight) recomputed here from epoch.json (pool …, totalWeight …); … leaves in all |
| `B11.p13` | PASS/FAIL | partition of … wei: publish … + excluded … + rounding … + the 10 % part …; the leaves add up to the publish total |
| `B11.p14` | PASS/FAIL | (computed text) |
| `B11.p15` | PASS/FAIL | distributor deployed at … in ONE transaction by the fresh deployer … (nonce … -> …); runtime codehash … (the live deployment with the same constructor arguments must show the same codehash) |
| `B11.p16` | PASS/FAIL | read-back: owner = the Safe (not the deployer), pendingOwner 0, PHAR, CLAIM_DELAY …, CLAIM_DEADLINE …, epochCount 0 (verify exit …) |
| `B11.p17` | PASS/FAIL | the Safe approved EXACTLY … wei to the distributor (a 10^31 approval was refused by the tool); allowance … |
| `B11.p18` | PASS/FAIL | epoch 0 published: status Open, root/total/from/to/dataHash equal the manifest's publishEpochArguments, claim opens at publish + …, deadline + …; the distributor holds … PHAR, allowance back to 0, EpochPublished logged; a wrong EXPECT_EPOCH_ID was refused by the tool |
| `B11.p19` | PASS/FAIL | (computed text) |
| `B11.p20` | PASS/FAIL | a second epoch (id 1, 1 wei, a test root) is published; the distributor holds … PHAR |
| `B11.p21` | PASS/FAIL | (computed text) |
| `B11.p22` | PASS/FAIL | after the 24 h window: isClaimWindowOpen true; cancel is refused by the tool ("challenge window ... is over") and by the contract (…) |
| `B11.p23` | PASS/FAIL | a changed amount (…) and another holder's proof (…) are refused; verifyLeaf is false for the changed amount |
| `B11.p24` | PASS/FAIL | the Ledger claimed with the proof from epoch.json: PHAR received … = epoch.json amount …; Claimed logged; isClaimed true (claim gas …) |
| `B11.p25` | PASS/FAIL | a double claim is refused: … |
| `B11.p26` | PASS/FAIL | Bob's claim submitted by a STRANGER paid Bob … and the stranger nothing |
| `B11.p27` | PASS/FAIL | the dead seed (…) and the contract holder (…; with a borrowed proof …) cannot claim their slices even with the amount from epoch.json: those slices were never published |
| `B11.p28` | PASS/FAIL | accounting: claimed … of …; the distributor holds …; the Safe paid only the publish total … (Safe PHAR … -> …): the excluded slices (… wei), the 10 % part and the rounding never left it |
| `B11.p29` | PASS/FAIL | (computed text) |
| `B11.p30` | PASS/FAIL | (computed text) |
| `B11.p31` | PASS/FAIL | the sweep returned … wei (total - claimed) to the Safe, status Swept, the distributor holds … PHAR |
| `B11.p32` | PASS/FAIL | (computed text) |
| `B11.w01` | PASS/FAIL | the harness's expected-split model (built from the local chain's pToken and vault Transfer logs since the market's deployment block …: … events) equals the chain: the market holds … vault shares for … pTokens across … suppliers (seed at 0xdEaD, the Ledger, Carol, Bob and the earlier test accounts) |
| `B11.w02` | PASS/FAIL | epoch.json carries the wrapper config (THIS run's market …, from block …) and report (generator …, … wrapper(s)) and the checks wrapperSplitSumsToPTokenHolding, seedExcluded, wrapperHoldersHaveNoLeaf are true |
| `B11.w03` | PASS/FAIL | supplier weights equal the harness's own expectation for all … suppliers (Ledger …, Bob …, Carol …, dead seed …); integral of the shares in the market …, rounding …, no-supplier … |
| `B11.w04` | PASS/FAIL | the market itself has no leaf and only its residual (…) as an excluded row; the seed's pTokens at the dead address earned … share-seconds that stay with the Safe (dead-seed, no leaf) |
| `B11.w05` | PASS/FAIL | the Ledger and Bob (direct holders AND suppliers) have weight = direct + wrapper; Carol (a pure supplier of the REAL market: her only direct weight is … share-seconds between receiving the shares and supplying them) has a leaf of … wei = floor(pool * weight / totalWeight), almost all of it from her pToken balance |
| `B11.w06` | PASS/FAIL | Carol, who holds only pTokens of the bpPHAR-USDC market, claimed … wei of PHAR to HER address (the one she supplied from) with a proof from epoch.json, submitted by a stranger (claim gas …) |
| `B7.1a`, `B7.1b` | PASS/FAIL | donating 1 USDC and 20 USDC to the vault: the best-placed holder's extra borrow power at CF 50 % is below the cost and below CF x donation |
| `B7.4a`, `B7.4b`, `B7.4c` | PASS/FAIL (NOTE when a size cannot be swapped) | swapping 1,000 / 10,000 / 100,000 USDC -> USDT in the vault's pool: extra borrow power of the best-placed holder is not above the swap's cost at the oracle |
<!-- CHECKS:END -->

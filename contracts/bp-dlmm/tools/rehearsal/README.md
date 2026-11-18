# bpPHAR-USDC mainnet-fork rehearsal (B0 .. B9)

Rehearses the whole **listing ceremony** of the `bpPHAR-USDC` lending market (underlying = the share token of the Peridot Pharaoh DLMM USDC/USDt ERC-4626 vault) and the **oracle wrapper in front of the live controller's oracle**, on a local anvil fork of the LIVE Avalanche pilot, in the order of the ceremony: the new contracts are DEPLOYED but not seeded and not listed; then the Ledger transactions; then everything the market has to survive.

**Status: written and checked offline by the assistant, NOT run on a fork** (it has no RPC). The user runs it. Nothing here signs, broadcasts or touches mainnet: the Ledger, the Safe, the throwaway deployer and every test wallet are *impersonated on the local anvil*; the RPC URL exists only in the environment of the local proxy.

## Run it

```bash
# once: the forge artifacts of the market contracts (subagent A's worktree) and ethers v5 (any of operator/, order-keeper/, range-tp-keeper/ with node_modules)
( cd /Users/joshua/Peridot/.wt-bp-core/contracts && forge build --skip test )
( cd <repo>/operator && npm ci )                                   # only if no node_modules/ethers v5 exists yet

# static checks only (no endpoint, no fork, no lock):
DRY=1 contracts/bp-dlmm/tools/rehearsal/rehearsal.sh /tmp/bp-dry

# the rehearsal (the endpoint is typed in YOUR shell only; it is never written to a file, an argv or the output):
AVALANCHE_RPC='<your endpoint>' contracts/bp-dlmm/tools/rehearsal/rehearsal.sh ~/bp-rehearsal-out
```

Expected last lines on success (counts are what the code defines; a NOTE is neither pass nor fail):

```
RESULTS pass=<n> fail=0 notes=<m> (<out>/results.json)
REHEARSAL PASSED
upstream HTTP status counts seen by the proxy: {"requests":...,"errors":0,"upstreamStatus":{"200":...}}
```

Exit codes: `0` nothing failed, `1` a check FAILED (see `results.json`), `2` usage / no endpoint / artifacts or ethers missing, `3` fork did not come up or the ARGV CHECK failed, **`42` an HTTP 429 / rate limit was seen: STOP, report, do not switch providers**. One fork job at a time: the script takes the shared lock `/tmp/pilot-fork.lock` (mkdir; retries every 30 s; released in every exit path; override with `REH_LOCK` only in the self-test).

Files in `<out-dir>`: `rehearsal-run.log`, `results.json` (every PASS/FAIL/NOTE, gas per transaction, the B1 price table, the B7 manipulation table, the deployed addresses), `snapshot-before.json`, `snapshot-end.json`, `diff-end.json`, `upstream-status.json`, `argv-check.txt`, `lock-minutes.log`, `pin-block.txt`, `deploy-cmd.log` (only when `BP_DEPLOY_CMD` is used).

## How it uses subagent A's work (reconciled with A's commits e80861ca / 07d98db4 / 49733d57 / 04e6064f)

* **A's ceremony tool is driven THROUGH, not re-implemented** (`BP_TOOL`, default `/Users/joshua/Peridot/.wt-bp-core/contracts/tools/bp-dlmm-ceremony.sh`; used when it and its pin file `contracts/ceremony/bp-dlmm-pin.json` exist, i.e. after `tools/bp-dlmm-ceremony.sh pin rehearsal` in A's worktree; `BP_USE_TOOL=1` requires it, `BP_USE_TOOL=0` forces the built-in deployment). The harness runs, against the local anvil only (`ETH_RPC_URL` = the local fork, the deployer is a throwaway address): `check rehearsal` (B0.t1), `deploy rehearsal` = A's `forge script ... --unlocked --broadcast` by the throwaway deployer, followed by its own `verify-deployed` (B0.12), `print-ledger-calls rehearsal` (B0.t5), `verify-listing rehearsal 1..4` after each stage (B1.t1, B2.t1, B2.t2, B3.t1). Without the tool or its pin file the run FAILS `B0.t0` and falls back to the built-in deployment (forge artifacts of `BP_OUT`, constructor arguments resolved by name; `B0.12b`), which is NOT the real deploy script; `BP_USE_TOOL=0` accepts that mode explicitly. `results.json` -> `data.mode` says which mode ran. `verify-deployed` compares the deployed code with the pin: the pin must match A's FINAL sources (re-pin after any source change).
* **The Ledger transactions are A's call list** (`contracts/avalanche_bp_dlmm_ceremony_calls.md`; as of A's latest tool: T1 `_setPriceOracle(wrapper)`; T2 `_setMarketBorrowCaps([market],[1])` BEFORE listing (0 would mean UNLIMITED); T3 `_supportMarket`; T4 `_setBorrowPaused(true)`; T5 `vault.approve(market, 1,000,000)`; T6 `market.mint(1,000,000)` (admin-only first mint); T7 `_setMintPaused(true)` (right after the seed mint); T8 `market.transfer(0xdEaD, 5,000,000,000)`; activation T9 `_setMintPaused(false)`, T10 `_setCollateralFactor(0.5e18)`; rollback R1 `_setPriceOracle(guarded oracle)`). The harness identifies each transaction **by meaning** (oracleSwap, capSet, list, borrowPause, approveSeed, mintSeed, seedToDead, mintPause, mintOpen, setCF, rollback) and takes the T-numbers and the order within a stage from the tool, so a reordering inside the tool (it already happened once while this harness was written) cannot desynchronise the rehearsal, while a transaction added, removed or changed in the tool fails `B0.t5` by name. B1 compares at the oracle swap, B2 runs stages 2 and 3 (with the seed-window probe right after listing), B3 runs the activation (T9, then the CF-0 negative tests, then T10), B6 the rollback. The harness sends **the tool's own printed calldata** from the impersonated Ledger and ALSO encodes every call independently from its own ABIs: `B0.t5` fails if a single byte or target differs (this cross-check also runs offline in `DRY=1`, with placeholder addresses). Every call is first executed statically (a code-returning call must give 0), then sent with 50 % gas headroom, then traced with the state-diff tracer to list the contracts it wrote. Flash loans are paused from birth by A's delegate (no transaction; asserted in B0 and B2); an outsider's first mint reverts `PharaohBoosted__SeedPending` (B2.1).
* **Other ways in**: `BP_DEPLOY_CMD='<command>' BP_DEPLOY_CWD=<dir>` (any deploy command; it is run with `ETH_RPC_URL` = the local fork and `BP_DEPLOYER`, and must write `export BP_MARKET=..`, `export BP_ORACLE=..`, optionally `export BP_DELEGATE=..` to `$BP_ADDRESSES_FILE`); `BP_ADDRESSES_FILE`; `BP_OUT`, `BP_WRAPPER_NAME`, `BP_DELEGATE_NAME`; constructor-argument override `BP_CTOR_<CONTRACTNAME>='[...]'`.
* Knobs: `BP_SEED_SHARES` (1,000,000 raw = 1 share), `BP_MIN_VAULT_SUPPLY`, `BP_INITIAL_EXCHANGE_RATE` (2e14), `BP_PTOKEN_DECIMALS/NAME/SYMBOL`, `BP_CF` (50 %), `BP_SHARE_BORROW_CAP` (1), `BP_FORK_BLOCK` (default head-4).
* **Prerequisite for the tool path** (not run by the harness because it needs a clean tree and a long build): `cd /Users/joshua/Peridot/.wt-bp-core/contracts && tools/bp-dlmm-ceremony.sh pin rehearsal` once, so `out_bpdlmm` and the pin file exist.

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
* **From then on the three feeds (AVAX/USD, USDC/USD, USDT/USD) are MOCKS** (`MockFeed.json`, runtime code placed at the real feed address, at the REAL answers) because a fork cannot move real feeds: margin TP/SL tests need the AVAX price to follow the pool; B4 needs old feeds; B5 needs a USDT depeg. Real feed lag, heartbeat and round behaviour are **not** rehearsed after B1.
* Fork-only helpers (always reverted by their scenario): USDC balances forced by storage write, 100,000 USDC supplied to pUSDC and its cap raised for the margin sections.

## Findings the harness is built around (read from the source)

* The margin stack does **not** read `controller.oracle()`: the risk engine and the quoter hold their own pointer (the guarded oracle) and the liquidator reads the risk engine's. The oracle swap therefore changes only the controller's price path (borrow, redeem, liquidate, seize, CF checks, `getAccountLiquidity` of margin accounts); B1 asserts the margin pointers are unchanged and compares the controller-side reads and the margin-side reads separately. The wrapper must also expose `getPrice(asset)` / `marketAsset(pToken)` (forwarded verbatim by A's wrapper) for the off-chain operator code, which reads `controller.oracle()`.
* A pToken's user functions **revert** with `BorrowPeridottrollerRejection(code)` etc. while the controller's admin functions **return** the code; both are handled.
* After the swap, `_setCollateralFactor(pBP, 50 %)` needs a non-zero share price: B3 shows the order matters, B6 shows it returns 13 after a rollback.
* Compound semantics that B4 and B6 assert: an account that **entered** a market whose price is 0 cannot borrow, redeem, exit or be liquidated (the liquidity query returns PRICE_ERROR); accounts that never entered it are unaffected; repayment never reads a price.

## B5: how an account is made underwater (justification)

The wrapper prices a share as `convertToAssets(1 share) x USDC price` and debt is priced by the same USDC feed, so moving the USDC feed does nothing. The vault's NAV, however, values its **USDT leg with the USDT/USD feed** (`totalAssets` -> `_pairToAsset`), and an **out-of-band answer does not revert** `totalAssets` (only a stale or bad round does). A USDT depeg therefore lowers `convertToAssets` through the vault's real code, and is the one realistic way a share price falls below its debt. The harness mocks the USDT feed only (no vault storage is edited), borrows ~98.5 % of the power, and steps the USDT price down (99, 97, 95, 90, 80, 60, 40 % of $1) until the controller reports a shortfall. If the USDT leg is too small a part of the NAV for that to work, it falls back to a *synthetic loss* (impersonating the vault to burn 30 % of its bins to a third party), says so in the log and marks the method; if neither works, B5 is a NOTE ("no faithful method") and the offline tests carry the logic. The liquidator is a funded wallet that repays USDC and **keeps the seized pTokens** (it never redeems them); the harness checks balances, the 50 % close factor, the 108 % incentive (recomputed independently), the protocol seize share and the shortfall formula.

## What was verified offline, and what only the fork can verify

Verified by the assistant: `node --check` of every script; `DRY=1` (every `Interface` constructs, every planned call encodes, every address checksums, the artifacts of A and the wrapper/market constructors resolve, every check id is in this README); `selftest.sh` (a local anvil with chain id 43114 plays the upstream; `rehearsal.sh` forks it through the real proxy path and runs `selftest/selftest.mjs`: gas headroom, failure tracing with nested custom errors, balance forcing for slot 0 and slot 9 layouts, mock feeds and re-pinning after a warp, snapshots, timestamp pinning, the prestate tracer, the results writer, the lock held by another job, the ARGV CHECK negative case, the 429 path -> exit 42, a failing check -> exit 1, DRY). **Not verifiable without the fork**: every `B*` check itself (it reads the live contracts); that the live addresses still match (B0 reads them all back); that the prestate tracer works on the user's anvil (a call-target fallback exists); pool depth for B7 swaps and for the margin moves; the exact numbers (they are printed, not assumed).

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
| `B0.12a` | PASS/FAIL | new contracts: market …, wrapper …, delegate … |
| `B0.12b` | PASS/FAIL | built-in deployment by the throwaway deployer from the forge artifacts of … (NOT the real deploy script - use the ceremony tool for the real rehearsal): delegate …, market …, wrapper … |
| `B0.13` | PASS/FAIL | starting state: the market is deployed (underlying = the DLMM vault, controller = the live one, admin = the Ledger), NOT listed, pToken supply 0 |
| `B0.14` | PASS/FAIL | the delegate pinned the vault at deployment (pharaohVault() = …, minimum supply …) |
| `B0.15` | PASS/FAIL | flash loans are PAUSED FROM BIRTH (delegate _becomeImplementation) and maxFlashLoan(shares) = 0 |
| `B0.16` | PASS/FAIL | wrapper: base oracle = the live guarded oracle, market = the new pToken, vault = the DLMM vault, asset = USDC |
| `B0.17` | PASS/FAIL | the wrapper already prices the (unlisted) share market: … (USD per raw share x 1e36 / 1e18... = … USD per whole share) |
| `B0.n1` | NOTE | block timestamp interval set to 1 s (deterministic time for the real-feed comparison in B1) |
| `B0.n2` | NOTE | vault: totalAssets … USDC, depositCap …, paused …, guard unsafe=… latched=… reasons=…, maxDeposit …, maxFeedAge …s, legBand …bp, poolDev …bp |
| `B0.t0` | PASS/FAIL | A's ceremony tool is not usable (tool …, pin file …): the run falls back to the BUILT-IN deployment, which is NOT the real deploy script; run 'tools/bp-dlmm-ceremony.sh pin rehearsal' in A's worktree, or set BP_USE_TOOL=0 to accept the built-in mode explicitly |
| `B0.t5` | PASS/FAIL | every Ledger transaction printed by the tool's print-ledger-calls (…) has byte-identical calldata AND target to the harness's own independent encoding, and the harness knows no transaction the tool does not print (the harness sends the order the tool prints: …) |
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
| `B4.2` | PASS/FAIL | the wrapper returns 0 (price unavailable) for the share market and does NOT revert; pUSDC and pWAVAX stay priced (the failure is isolated) |
| `B4.3` | PASS/FAIL | an account that entered the share market has no liquidity answer: getAccountLiquidity error … (13 = PRICE_ERROR) |
| `B4.4` | PASS/FAIL | FAIL-CLOSED: dave cannot borrow more (…) nor redeem pTokens (…) while the share price is unavailable |
| `B4.5` | PASS/FAIL | FAIL-CLOSED: liquidation of an account holding shares is refused while the price is unavailable (…) |
| `B4.6` | PASS/FAIL | the live margin accounts (they never entered the share market) are unaffected (getAccountLiquidity error …) |
| `B4.7` | PASS/FAIL | the vault's exit path redeemInKind still works with the feed stale (no oracle read): … |
| `B4.8` | PASS/FAIL | USDC feed 91,000 s old (guarded maxAge 90,000, vault maxFeedAge 93,600): the vault still prices, but the wrapper's share price AND pUSDC are 0 (the share price uses the BASE oracle's USDC price); pWAVAX stays priced |
| `B4.9` | PASS/FAIL | borrow refused with PRICE_ERROR (…) |
| `B4.10` | PASS/FAIL | after 100,000 s with no feed update every price is 0 (USDC feed age … s): share, pUSDC and pWAVAX |
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
| `B6.n1` | NOTE | CONCLUSION: the one-transaction rollback is a clean undo only while NO account has entered the share market. After that it freezes those accounts' borrow, redeem and liquidation until the wrapper is re-applied; the safer reaction to a bad share price is the CF -> 0 / mint pause / stale-feed fail-closed path, not the rollback. |
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
| `B9.n3` | NOTE | OPTIONAL step from the rewards work (branch feat/dlmm-rewards-boosted, its rehearsal steps W01-W06: PHAR wrapper-holder distribution, seed excluded) is NOT part of this rehearsal; run it after this one on the same kind of fork if the wrapper-split distribution is wanted. |
| `B7.1a`, `B7.1b` | PASS/FAIL | donating 1 USDC and 20 USDC to the vault: the best-placed holder's extra borrow power at CF 50 % is below the cost and below CF x donation |
| `B7.4a`, `B7.4b`, `B7.4c` | PASS/FAIL (NOTE when a size cannot be swapped) | swapping 1,000 / 10,000 / 100,000 USDC -> USDT in the vault's pool: extra borrow power of the best-placed holder is not above the swap's cost at the oracle |
<!-- CHECKS:END -->

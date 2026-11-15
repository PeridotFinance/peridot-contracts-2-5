# Pharaoh DLMM USDC/USDt vault: full fork rehearsal report (W8), 15 Nov 2026

What this is: the whole ceremony of `avalanche-dlmm-vault-ceremony.md` run end to end against a **local anvil fork of Avalanche mainnet** (chain id 43114), with the Safe and the Ledger impersonated on the fork, a fresh keyless deployer address, a throwaway keeper wallet, and the dlmm-keeper in LIVE mode. **Nothing was signed or sent on mainnet; no real key, keystore or the Ledger was used; the only remote traffic was anvil's read-only state fetching.** Labels: MEASURED (observed in the run), DERIVED (arithmetic on measured figures), ESTIMATED, UNVERIFIED.

Raw evidence (redacted of every URL, no secrets): `avalanche-dlmm-vault-rehearsal-evidence/rehearsal-run.log` (388 lines, every command output and read-back), `results.json` (gas, ppm, step timings), `pin-block.txt`, `lock-minutes.log`. Re-run: `AVALANCHE_RPC=<in your shell> contracts/vault-dlmm/tools/rehearsal/rehearsal.sh <out-dir>` (optionally `DLMM_FORK_BLOCK=<n>`).

## 1. Setup (MEASURED)

| Item | Value |
| --- | --- |
| Code under test | integration branch plus W2's `3726773c` (deposit-side minimum supply `SupplyBelowMinimum`, balance-delta payout, `renounceOwnership` disabled, cooldown bound 112, claim-only `PharHarvested`, post-swap pool check), merged into `feat/dlmm-vault-rehearsal`; solc 0.8.35 via-IR; implementation runtime 24,051 bytes |
| Keeper | `dlmm-keeper` at `1a676ef6` (the checkout's built `dist/`, copied to a scratch dir; its config written there; the checkout untouched) |
| Fork | pinned at head minus 4 at run time: block **100427327** (final run), chain time 6 to 15 s behind wall clock (anvil `--block-time 1`), pool active id 8388605, Safe nonce 19 (Ledger and Safe unchanged by the run), feeds USDC/USD 0.99975181 (age 30,057 s), USDT/USD 0.99934 (age 23,569 s) |
| Deployer | a fresh random address, impersonated (`anvil_impersonateAccount`), funded 100 AVAX with `anvil_setBalance`; **no key was ever used or generated for it** |
| Keeper wallet | `Wallet.createRandom()` in memory; the only file is its encrypted keystore plus password file (mode 600) in a `mktemp` dir that the wrapper's trap removes (a deviation from "no key on disk", forced by the keeper's live mode, which needs a keystore) |
| Balances | USDC/USDt written with `anvil_setStorageAt` (Ledger 300 USDC, second user 300 USDC, trader 3M of each); the Ledger had 7.697 USDC on the real chain |
| Lock | `/tmp/pilot-fork.lock` held by the wrapper's trap only while anvil ran; final run 165 s; all 11 sessions 995 s = 16.6 minutes (section 6) |

## 2. Step by step (final run; MEASURED unless marked)

| # | Step | Result | Gas | Loss (ppm) | Time |
| --- | --- | --- | --- | --- | --- |
| S2a | Stage 0 with `cast` (`tools/dlmm-vault-stage0.sh`) | ALL CHECKS PASSED (chain, Safe 1-of-1 `[Ledger]` v1.4.1, tokens, hook, linked, router authorised, beacon, feeds fresh and in band, deployer nonce 0, planned addresses empty). Codehash recorded `0x91ac083c...3355` | | | 6 s |
| S2 | Negative pre-flights | wrong expected codehash: refused (`preflight: beacon implementation codehash != EXPECTED...`), **deployer nonce stayed 0**; deployer = Ledger and rebalancer = Ledger refused by `check-env` | | | 2 s |
| S3 | **Deploy** (`tools/dlmm-vault-ceremony.sh deploy rehearsal`) | 2 transactions: implementation, then proxy with `initialize`; deployer nonce 2; the deployer spent 0.0073 AVAX at the fork's 1.0 gwei | impl **6,109,695**, proxy **1,234,032** (7,343,727 total) | | 3.5 s |
| S4 | Read-back stage 1 (appendix A) | `READ-BACK OK`; a wrong `REBALANCER` is refused. Runtime-code check: implementation 24,051 B, validator 3,680 B, proxy 752 B, ProxyAdmin 838 B all equal the build output (immutables masked); one flipped byte in the validator is detected (`MISMATCH at byte 100`); a second `deploy` with the same deployer is refused (`DEPLOYER nonce != 0`). The deployer cannot `unpause`, `pause`, `setRebalancer` or `upgradeAndCall` (`OwnableUnauthorizedAccount`) | | | 5 s |
| S5 | While paused | `deposit` and the keeper's `openBand` revert `EnforcedPause`; `maxDeposit` 0 | | | 0.5 s |
| S6 | **Safe MultiSend** `[unpause, approve, deposit(1000000, 0xdEaD)]`: builder refuses seed 999,999; `simulate` refuses while the Safe holds no USDC; step 0 Ledger transfers 1 USDC to the Safe; `simulate` true; `send` through `execTransaction` operation 1 from the impersonated Ledger | one transaction: paused false, 1,000,000 shares at `0xdEaD`, totalSupply 1,000,000, totalAssets 1,000,000, Safe nonce 19 to 20. Read-back stage 2 `READ-BACK OK` (appendix B) | step 0 62,159; **MultiSend 317,296** | 0 | 7.6 s |
| S7 | Deposits | Ledger 100 USDC (100,000,000 shares); `maxDeposit` for the second user 99,000,000; **deposit of max+1 reverts `CapExceeded(200000000,200000001)`**; second user deposits 99 USDC (totalAssets exactly 200,000,000, `maxDeposit` 0); 1 USDC more reverts | 233,799 and 238,611 | 0 and 0 | 2.5 s |
| S8 | Keeper: `validate-config`, `check` (`no-band`), `open-band` dry (simulation passed), **`open-band --send` live** | one `openBand` from the keeper wallet: it swapped 100 USDC for USDt (the vault's own inventory swap) and minted bins [8388604, 8388606] around active 8388605, `BandOpened(8388604, 8388606, 8388605, 100027501, 99999999)`, guardState `false,false,0`, all three bins held. NAV 200,000,000 to 199,986,722. Exit probe (simulation): `redeemInKind(10)` returns 4/4, `redeem(10)` 6. A second `openBand` reverts `BandExists` | **746,242** | **66.4** of NAV (the earlier run at another block: 60.0; W6's figure 23.7 at USD 200) | 5.2 s |
| S9 | Keeper daemon (live). A real market swap through the real Pharaoh router (22,243 USDC, the USDt reserves of bins 8388605 to 8388607 plus 0.5 %) moves the active id 8388605 to **8388608**, 2 bins above the band | the keeper waited its 60 s exit window and **re-centred 64.7 s after the swap**: band [8388607, 8388609] around 8388608; swap Y to X 100,024,725 in, 100,021,774 out; NAV 200,005,299 to 199,947,680; a second look 5 s later: no further send, keeper wallet nonce 2 (openBand + rebalance) | **901,632**; trader swap 242,416 | **288.1** of NAV (oracle-marked, the vault's own measure) | 80.6 s |
| S10 | `harvestRewards` by the keeper wallet after +6 h chain time | PHAR pending 2.52241 PHAR, `PharHarvested` 2.52252 PHAR (the claim of that block), forwarded to the Safe (owner), vault PHAR left 0; a stranger's call reverts `NotRebalancer`. An amount at one block, **not a rate** | 288,848 | | 0.8 s |
| S11 | Pause and rollback (section 3) | all rows pass | see section 3 | | 36 s |
| S12 | **Exits**: Ledger `redeem` (USDC out) of half its shares, then `redeemInKind` of the rest; second user `redeemInKind`; seed holder `0xdEaD` last (impersonated, FORK ONLY) | totalSupply 0, totalAssets 0, hasBand false, vault USDC 0 / USDt 0 / PHAR 0, the three bins' vault shares 0. Then `deposit(500000)` and `deposit(4)` into the empty vault revert `SupplyBelowMinimum(...)`: **the W10 F1 four-wei attacker cannot enter an empty vault** | redeem 450,697; in-kind 327,096 (Ledger, second user), 305,574 (seed) | `redeem` USDC-out: **-252.5** (paid MORE than the oracle NAV); in-kind: 0.06, 0.01, 0 | 3.8 s |

Round trips (oracle value of everything received, PHAR excluded, against the amount deposited; includes the cost of one `openBand` and one re-centre): Ledger **135.8 ppm**, second user **272.4 ppm**, seed **264 ppm**. The spread between holders is the order of the exits and the pool/oracle offset, not a vault transfer: across the Ledger's USDC-out redeem the remaining holders' NAV per share moved by about -0.7 ppm (49.986920 to 49.986883 per 50M shares, DERIVED from the log), consistent with W4's "spill" of a few wei.

Gas, summary (MEASURED): deploy 7.34M; Safe MultiSend 317k; idle deposit 234k to 239k; `openBand` 746k; `rebalance` 902k (the keeper's `gasPerRebalance` is 1,000,000: a margin of 10 %, its `maxGasLimit` 3M is safe); harvest 289k; in-kind exit 305k to 371k; Safe single calls 65k to 161k.

## 3. Pause and rollback exercised on the fork (S11; all MEASURED)

| Procedure | Result |
| --- | --- |
| Safe `pause()` (via `tools/dlmm-safe-call.sh`) | paused, `maxDeposit` 0, `deposit` and keeper `openBand` revert `EnforcedPause`. **A real `redeemInKind(1000)` (371k gas) and a real `redeem(1000)` (447k gas) succeeded while paused.** `unpause()` restores |
| `setDepositCap(1)` / `setDepositCap(0)` | `maxDeposit` 0, deposits revert `CapExceeded(1, ...)` and `CapExceeded(0, ...)`: **zero closes the vault here, it does not open it as in R3**. Restored to 200,000,000. `setDepositCap(200000001)` refused (simulation fails; inner revert `CapAboveCeiling`) |
| `setRebalancer(Ledger)` then back | the old keeper's `rebalance` reverts `NotRebalancer`; restored |
| `setGuardParams` | `legBandBps` 75 accepted and read back; a cooldown of 111 refused (new bound 112); defaults restored |
| Guard latch with a feed override (the USDT/USD feed's runtime code replaced by a storage-less mock answering 0.97, fork only, the real code put back afterwards) | `guardState` `true,false,24` (bits 8 pair leg and 16 pool deviation); `deposit` reverts `GuardUnsafe(24)`; anyone's `tripGuard()` (108k gas) gives `true,true,24`; the Safe's `clearGuard` is refused while the feed is bad; **a real `redeemInKind(1000)` succeeded under the latch and the bad feed (332k gas)**; feed restored: `false,true,0` and deposits still revert `GuardLatched`; Safe `clearGuard()` (161k gas) gives `false,false,0` |
| `renounceOwnership` through the Safe | refused (inner `RenounceDisabled`); owner still the Safe |
| The tool refuses `transferOwnership(address)` | exit 2, `function not allowed here` |

A Safe `execTransaction` whose inner call fails only reports `GS013`; `dlmm-safe-call.sh simulate` then also prints the inner call's own revert as a raw custom-error selector (MEASURED: `0xf64ec131` = `CapAboveCeiling`, `0xcc408572` = `ParamOutOfBounds`, `0x8bf28c1e` = `GuardStillUnsafe`; decode with `cast sig`).

## 4. Findings, deviations and failures (unfavourable facts first)

1. **Rebalance cost is high relative to NAV (MEASURED, one sample).** One re-centre cost 288 ppm of NAV (0.029 %) and `openBand` 60 to 66 ppm. DERIVED: at the measured 5 to 6 re-centres a week this is about 0.14 to 0.17 % of NAV a week, **roughly 7.5 to 9 % a year of NAV in rebalancing cost alone**, before fees and PHAR. The sample is one block, one direction, 50 % of NAV swapped, with the pool pushed 3 bins by my own trade (part of the figure is the pool's active price sitting above the oracle ratio after that push: the USDC-out redeem paid +252 ppm over the oracle NAV for the same reason). It supports the risk register's row that rebalance cost is 3x to 20x the model; it does not prove the economics either way.
2. **Seed is USD 1 that can never be withdrawn** and sits in the bins; it carries its pro-rata share of every loss (264 ppm at the end).
3. **A public window exists between MultiSend (2d) and `openBand` (2g)**: the vault is unpaused and public deposits up to the cap are accepted but idle. Keep it short; the first-depositor window itself is closed (seed in the same transaction; the fix and the seed are both exercised).
4. **`cast codehash` is unreliable on the anvil fork**: it printed `0xc5d246...a470` for the beacon implementation while `keccak256(code)` (= EXTCODEHASH, what the vault pins and what the deploy compared) was `0x91ac083c...3355`. Stage 0 therefore uses `cast keccak $(cast code ...)`. UNVERIFIED against a real endpoint.
5. **Harness bugs fixed during development (not product bugs)**: `readCallers` mode for `startBroadcast` is RecurrentBroadcast (my check was wrong, the deploy refused until fixed); BSD `sed`/`cast call` output quirks; `eth_getLogs` from block 0 on a fork exceeds the provider's 10,000-block range (fixed: from the pin block; a 400, not a rate limit). No HTTP 429 reached the harness (anvil's own output was discarded, see section 6).
6. **UNVERIFIED / not rehearsed**: the live signing paths (`--account` keystore for the deployer, `--ledger` for the Ledger, forge's `avalanche` alias resolution, the redaction on a real endpoint: the fork used the unlocked/impersonated forms of the same commands); `deploy-resume`; the Safe `upgradeAndCall` path; the keeper's `resume` after a halt and its host deployment (`deploy/*-host.sh`); the real Pharaoh hook failing (W6 did it with a mock); MultiSendCallOnly `0x9641d764...02e2` is confirmed only by code presence (411 bytes) and by the Safe executing through it, not against the Safe deployments list; real mainnet gas prices (fork 0.7 to 1.0 gwei; the 25 gwei funding in the ceremony is a margin, DERIVED). The Ledger's hardware confirmation of the 1-of-1 "approved by msg.sender" signature was simulated (`msg.sender` = Ledger).
7. **Endpoint handling**: the real endpoint (environment variable `AVALANCHE_RPC`) was passed only to `anvil --fork-url` (and to one `cast block-number`), so it is in anvil's argument vector on this machine for the roughly 3 minutes of each run; nothing logged or wrote it, and the node process, forge, cast and the keeper ran with a clean environment in which `AVALANCHE_MAINNET_RPC_URL` and `ETH_RPC_URL` point at the local anvil. `forge script` in rehearsal mode also refuses to run unless the endpoint answers `anvil_nodeInfo`.
8. **Anvil `--block-time 1`** kept chain time near wall time so the keeper's 60 s wait and block-lag check behave as in production; the +6 h warp for the harvest was done with the keeper stopped.
9. The merge of W2's commit changed the codehash of the implementation relative to the earlier W6 runs; this rehearsal is valid for `3726773c` only (rerun after any change to `src/`).
10. Daily-cap boundary (UTC midnight), a second re-centre inside the cooldown, a down-move re-centre, and a deposit after the band exists were not exercised here (the keeper's anvil suite and W6 cover them against mocks / the real pair).

## 5. Second run (evidence-2): the assertions added after review

After the first full run (headline numbers above, `avalanche-dlmm-vault-rehearsal-evidence/`) four assertions were added and the whole rehearsal run again at another pin (block 100427888, `avalanche-dlmm-vault-rehearsal-evidence-2/`, lock 125 s, failures none; its ppm are of the same size: `openBand` 63.0, re-centre 288.3, round trips 137.3 / 274.1 / 263). New in that run only (MEASURED):

- **MultiSendCallOnly identity**: its runtime-code hash equals `0xecd5bd14a08c5d2122379900b2f272bdf107a7e92423c10dd5fe3254386c9939`, the `codeHash` published in safe-global/safe-deployments for v1.4.1 (stage 0 and the builder now refuse any other code). The published value was read through a web-fetch summary, and the fork's code matching it independently is the confirmation.
- **The delegatecall MultiSend leaves the Safe unchanged**: owners, threshold, storage slots 0 to 9 except the nonce (singleton, modules, owners, threshold), the fallback-handler slot, the guard slot, the modules list and the Safe's code hash were identical before and after; the nonce went 19 to 20 and the Safe's USDC 0 to 0.
- **The runtime-code verifier asserts the immutables** (ceiling 200000000, VALIDATOR = `CREATE(implementation, 1)`, the proxy's admin = `CREATE(proxy, 1)`) and fails on a one-byte change of either immutable (both negative cases tested), as well as on a one-byte change of the validator's code.

## 6. Conventions and what the reader must know

- **Seed receiver `0xdEaD` is a departure from the brief's two options (Safe or Ledger)**: chosen so that "never redeemed" is enforced by the chain; the tool takes `SEED_RECEIVER` and the ceremony document gives the reasons and the Safe alternative.
- **A temporary keystore was written to disk** for the throwaway keeper wallet (keeper live mode needs one), in a mode-700 temp directory, removed by the wrapper's trap; the deployer needed no key at all.
- **Evidence is tracked in git** (unlike the raw `avalanche-pharaoh-dlmm-evidence` folder, which holds raw RPC data and is kept out of git with a SHA-256 manifest): these logs are small, redacted of every URL, hold no secrets and no raw RPC payloads; they are not a manifest-protected record.
- **Rate limits**: no 429 reached the harness; anvil ran `--silent` with its output discarded and retries rate limits internally, so one it absorbed would not be visible. The final-run log was scanned for `429`/`rate limit` strings (none).
- **Lock**: 11 locked sessions, 995 s in total (16.6 minutes): one probe, eight development runs, the two reported runs.

## Appendix A. Stage 0 (verbatim, final run)

```
PASS  1  chain id: 43114
PASS  2  Safe owners: [0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD]
PASS  2  Safe threshold: 1
PASS  2  Safe version: "1.4.1"
INFO  2  Safe nonce (record it): 19
INFO  3  Ledger AVAX 10.000000000000000000   Ledger USDC 300000000 raw   Safe USDC 0 raw
PASS  MultiSendCallOnly has code at 0x9641d764fc13c8B624c04430C7356C1C7C8102e2
PASS  4  pair tokenX (USDt): 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7
PASS  4  pair tokenY (USDC): 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E
PASS  5  bin step: 1
PASS  5  pair factory: 0xEb480050b016f6c6d45203D2346B68bDDDa23D4D
INFO  5  factory.getLBPairInformation(USDt, USDC, 1) = (1, 0x16888EE58E706C253b821EAA637ae9b2cFeA255C, true, false)
PASS  5  factory registers the pair
PASS  6  pair hook (low 160 bits of getLBHooksParameters): 0x32e68c4b8edc6d1f16e99eba826b292fdc18dadc
PASS  6  rewarder.isLinked(): true
INFO  7  voter = rewarder.owner() = 0x922b9Ca8e2207bfB850B6FF647c054d4b58a2Aa7
INFO  7  beacon = voter.dlmmRewarderFactory() = 0xd28467eDe84cEde6B05070779E39Eaff4988548C
PASS  7  beacon lists the rewarder for the pair: 0x32E68C4b8Edc6d1F16E99EbA826B292FDC18daDC
INFO  7  beacon implementation = 0x9b9d60557b639EDa795BCc28822fa6214C29CEb2
INFO  7  REWARDER_IMPL_CODEHASH = 0x91ac083cbb550e8aeb1def2053f468cea00cf113ce364067f3832e34c4193355   <- record this value; it is the EXPECTED_REWARDER_IMPL_CODEHASH of the deploy (keccak256 of the implementation's runtime code = EXTCODEHASH)
PASS  8  router is an authorised DLMM manager: true
PASS  8  router factory: 0xEb480050b016f6c6d45203D2346B68bDDDa23D4D
PASS  9  feed 0xF096872672F44d6EBA71458D74fe67F9a77a23B9 decimals: 8
PASS  9  feed 0xF096872672F44d6EBA71458D74fe67F9a77a23B9 answer 99975181 (inside 1.00 +- 0.50 %) age 30065 s (<= 93600)
PASS  9  feed 0xEBE676ee90Fe1112671f19b6B7459bC678B67e8a decimals: 8
PASS  9  feed 0xEBE676ee90Fe1112671f19b6B7459bC678B67e8a answer 99934000 (inside 1.00 +- 0.50 %) age 23577 s (<= 93600)
INFO  10 pool active id: 8388605 [8.388e6]   (about 8388598 to 8388608 is normal; the peg bin is 8388608)
PASS  11 deployer nonce (fresh key): 0
PASS  11 deployer has no code: 0x
INFO  11 deployer AVAX: 100.000000000000000000
PASS  12 planned implementation has no code: 0x
PASS  12 planned proxy has no code: 0x
INFO  12 planned implementation 0x06c4Fbd8950316A138Fc41b427aBC652994f01DF  planned proxy (the vault) 0xAb156001cD5811b090307fAb9037Bb456e42eb57
PASS  11 keeper has no code: 0x
STAGE 0: ALL CHECKS PASSED
```

## Appendix B. Read-back stage 1 (verbatim, final run; addresses are fork-generated and differ per run)

```
== read-back (rehearsal), stage 1: read-only, no broadcast
No files changed, compilation skipped
Script ran successfully.
== Logs ==
  == read-back, stage 1, chain 43114, block 100427344
  vault (proxy)            0xAb156001cD5811b090307fAb9037Bb456e42eb57
  implementation           0x06c4Fbd8950316A138Fc41b427aBC652994f01DF
  proxy admin (ProxyAdmin) 0x14739D0D370E9C84a5348cF420D240C2E9FB89CF
  ProxyAdmin owner         0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12   (expect the Safe)
  implementation.owner()   0x0000000000000000000000000000000000000000   (expect 0: initializers disabled)
  validator CREATE(impl,1) 0x7658aDB49cd267d761b8a924C994d5837ef73640   code bytes 3680
  vault owner              0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12   (expect the Safe)
  rebalancer               0xD01E33957E223E6e6f23B17506Ee2082C6bB2300   (expect the keeper wallet)
  asset                    0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E
  pairToken                0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7
  tokenX / tokenY          0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7 / 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E   assetIsX false
  pair                     0x16888EE58E706C253b821EAA637ae9b2cFeA255C
  router                   0xff2BEFC4ff86CB0f3e8D3d9D6200B7A05BF5D93d
  factory                  0xEb480050b016f6c6d45203D2346B68bDDDa23D4D
  rewarder                 0x32E68C4b8Edc6d1F16E99EbA826B292FDC18daDC
  rewarderBeacon           0xd28467eDe84cEde6B05070779E39Eaff4988548C
  rewardToken (PHAR)       0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7
  feedAsset (USDC/USD)     0xF096872672F44d6EBA71458D74fe67F9a77a23B9
  feedPair  (USDT/USD)     0xEBE676ee90Fe1112671f19b6B7459bC678B67e8a
  binStep                  1
  rewarderImplCodehash     0x91ac083cbb550e8aeb1def2053f468cea00cf113ce364067f3832e34c4193355
  live beacon impl hash    0x91ac083cbb550e8aeb1def2053f468cea00cf113ce364067f3832e34c4193355
  name / symbol / decimals Peridot Pharaoh DLMM USDC/USDt / pdUSDC / 6
  depositCap               200000000   (expect 200000000)
  DEPOSIT_CAP_CEILING      200000000   (expect 200000000)
  maxDeposit(Ledger)       0
  guardParams legBandBps 50 maxFeedAge 93600 maxPoolOracleDevBps 60
  guardParams cooldown 120 maxRebalancesPerDay 48 maxSwapBps 6000
  guardParams maxRebalanceLossBps 50
  guardState unsafe false latched false reasons 0   (expect false false 0)
  bandState lower 0 upper 0 active 8388605
  bandState hasBand false outOfRange false   (expect false false)
  paused                   true
  totalSupply / totalAssets 0 / 0   (stage 1: expect paused = true and an empty vault)
  deployer 0x75c1485E9dA8d383Cb2ef5AF97ECfed07640167B nonce 2 (expect 2)
  deployer balance (wei)   99992666162327346688
  deployer USDC / vault shares 0 / 0
  READ-BACK OK
```

## Appendix C. Read-back stage 2, after the MultiSend (verbatim, final run)

```
== read-back (rehearsal), stage 2: read-only, no broadcast
No files changed, compilation skipped
Script ran successfully.
== Logs ==
  == read-back, stage 2, chain 43114, block 100427356
  vault (proxy)            0xAb156001cD5811b090307fAb9037Bb456e42eb57
  implementation           0x06c4Fbd8950316A138Fc41b427aBC652994f01DF
  proxy admin (ProxyAdmin) 0x14739D0D370E9C84a5348cF420D240C2E9FB89CF
  ProxyAdmin owner         0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12   (expect the Safe)
  implementation.owner()   0x0000000000000000000000000000000000000000   (expect 0: initializers disabled)
  validator CREATE(impl,1) 0x7658aDB49cd267d761b8a924C994d5837ef73640   code bytes 3680
  vault owner              0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12   (expect the Safe)
  rebalancer               0xD01E33957E223E6e6f23B17506Ee2082C6bB2300   (expect the keeper wallet)
  asset                    0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E
  pairToken                0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7
  tokenX / tokenY          0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7 / 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E   assetIsX false
  pair                     0x16888EE58E706C253b821EAA637ae9b2cFeA255C
  router                   0xff2BEFC4ff86CB0f3e8D3d9D6200B7A05BF5D93d
  factory                  0xEb480050b016f6c6d45203D2346B68bDDDa23D4D
  rewarder                 0x32E68C4b8Edc6d1F16E99EbA826B292FDC18daDC
  rewarderBeacon           0xd28467eDe84cEde6B05070779E39Eaff4988548C
  rewardToken (PHAR)       0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7
  feedAsset (USDC/USD)     0xF096872672F44d6EBA71458D74fe67F9a77a23B9
  feedPair  (USDT/USD)     0xEBE676ee90Fe1112671f19b6B7459bC678B67e8a
  binStep                  1
  rewarderImplCodehash     0x91ac083cbb550e8aeb1def2053f468cea00cf113ce364067f3832e34c4193355
  live beacon impl hash    0x91ac083cbb550e8aeb1def2053f468cea00cf113ce364067f3832e34c4193355
  name / symbol / decimals Peridot Pharaoh DLMM USDC/USDt / pdUSDC / 6
  depositCap               200000000   (expect 200000000)
  DEPOSIT_CAP_CEILING      200000000   (expect 200000000)
  maxDeposit(Ledger)       199000000
  guardParams legBandBps 50 maxFeedAge 93600 maxPoolOracleDevBps 60
  guardParams cooldown 120 maxRebalancesPerDay 48 maxSwapBps 6000
  guardParams maxRebalanceLossBps 50
  guardState unsafe false latched false reasons 0   (expect false false 0)
  bandState lower 0 upper 0 active 8388605
  bandState hasBand false outOfRange false   (expect false false)
  paused                   false
  seed holder 0x000000000000000000000000000000000000dEaD shares 1000000   (expect >= 1000000)
  totalSupply 1000000 totalAssets 1000000
  deployer 0x75c1485E9dA8d383Cb2ef5AF97ECfed07640167B nonce 2 (expect 2)
  deployer balance (wei)   99992666162327346688
  deployer USDC / vault shares 0 / 0
  READ-BACK OK
```

## Appendix D. Runtime-code check (verbatim, final run; the second run's version also asserts the immutables, see section 5)

```
proxy 0xAb156001cD5811b090307fAb9037Bb456e42eb57   implementation 0x06c4fbd8950316a138fc41b427abc652994f01df   validator(CREATE(impl,1)) 0x7658aDB49cd267d761b8a924C994d5837ef73640   ProxyAdmin 0x14739d0d370e9c84a5348cf420d240c2e9fb89cf (CREATE(proxy,1) = 0x14739D0D370E9C84a5348cF420D240C2E9FB89CF)
PharaohDlmmVault: runtime code equals the build output (24051 bytes; 4 immutable slot(s) masked: 0xbebc200, 0x7658adb49cd267d761b8a924c994d5837ef73640)
PharaohDlmmPairValidator: runtime code equals the build output (3680 bytes; 0 immutable slot(s) masked: none)
TransparentUpgradeableProxy: runtime code equals the build output (752 bytes; 1 immutable slot(s) masked: 0x14739d0d370e9c84a5348cf420d240c2e9fb89cf)
ProxyAdmin: runtime code equals the build output (838 bytes; 0 immutable slot(s) masked: none)
```

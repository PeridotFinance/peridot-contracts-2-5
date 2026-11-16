# DLMM vault PHAR distributor ceremony: what the operator types and signs (deployment once, then one epoch a week)

Run everything from `contracts/vault-dlmm/`. `OPERATOR` = only the operator, with a key or the Ledger in hand. No mark = read-only, anyone. The RPC endpoint is in the environment (`ETH_RPC_URL` for `cast`, `AVALANCHE_MAINNET_RPC_URL` for `forge`), never an argument. Design and reasoning: `avalanche-dlmm-vault-rewards-distribution.md`. Style and conventions: `avalanche-dlmm-vault-ceremony-today.md`. **Nothing in this document has been run on the live chain.** The tools were tested offline (stub `cast`, a mock world on a local anvil); the fork rehearsal (part 0) is the operator's to run and is a precondition.

**At every step that shows `SIMULATION ... true`, read the decoded call and the Safe nonce it prints; if the simulation fails or the decoded call is not exactly what is written here, STOP.** Every Safe tool (`tools/dlmm-rewards-safe-call.sh`, `tools/dlmm-safe-call.sh`, `tools/dlmm-harvest.sh`) runs an `eth_call` of `execTransaction` from the Ledger before anything is signed and refuses to continue unless it returns `true`; the simulation is not optional and `simulate` signs nothing. The deployer transaction (a throwaway keystore, not the Ledger) is simulated by `forge script` itself before it is broadcast, after the tool's own on-chain pre-flight.

Public values used below: `VAULT=0x278B1b625C74B1926C5F989ddE601f3C5Ba27f7D`, `SAFE=0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12` (1-of-1, owner the Ledger `0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD`), `PHAR=0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7`, keeper wallet `0xCf8387DE198413347BA4EEB2E7d3Bcc1fE3705d2`, openBand block `100488395`.

Decisions in force (operator, final): the dead seed's slice returns to the Safe; every epoch folder is committed to the repo and kept at least 180 days; the second recompute is a fresh subagent from the published inputs only; harvest daily, publish weekly; the first epoch starts at block 100488395; design B is not part of this.

## Part 0. Before anything (all must be true)

| # | Who | Check | Expected | Abort if |
| --- | --- | --- | --- | --- |
| 0a | anyone | `forge build --skip test` at the reviewed commit; `forge test --match-path 'test/rewards/*'` | `69 tests passed, 0 failed` | any failure |
| 0b | anyone | `ETHERS_DIR=<dlmm-keeper>/node_modules/ethers node --test tools/rewards-test/dlmm-rewards-root.test.mjs tools/rewards-test/dlmm-rewards-root.rpc.test.mjs tools/rewards-test/dlmm-rewards-tools.test.mjs` | `tests 40`, `pass 40`, `fail 0` | any failure |
| 0c | anyone | `node tools/rewards-rehearsal/selftest/selftest.mjs` (no endpoint) | last line `SELFTEST PASSED` | any `SELFTEST FAIL` |
| 0d | anyone | **the fork rehearsal**: `REH_SCAN_FROM=<vault deployment block> tools/rewards-rehearsal/rehearsal.sh --dry`, then the real run in "Part 0 rehearsal command" below | `DRY: all inputs OK`; then `REHEARSAL PASSED: 33 checks, 0 failures`, exit 0, `upstream HTTP status counts seen by the proxy` without a `429` | exit 1, 2, 3, 42 or 43 (see the rehearsal section); never deploy on a failed rehearsal |
| 0e | OPERATOR | the vault's deployment block is known (needed by the rehearsal and by the generator as `--scan-from`): the block of the vault proxy's creation, at or before the first share mint (the seed mint) | an integer `<= 100488395` | unknown: find it before going on (explorer: the proxy `0x278B...f7D` creation transaction) |
| 0f | OPERATOR | the distributor was reviewed (about 300 lines, OpenZeppelin building blocks) or the operator accepts that it is **not audited** (risk table, rewards document section 10) | decision recorded | |
| 0g | OPERATOR | decisions of rewards document section 14 that the first epoch needs: `--allow-contract` list (default none), whether the Ledger's holding is `--exclude`d (default: paid), the hosting URI pattern | recorded in the handoff | |
| 0h | OPERATOR | Ledger holds about 0.1 AVAX; Safe is 1-of-1 owned by the Ledger: `cast call $SAFE 'getOwners()(address[])'` and `'getThreshold()(uint256)'` | `[0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD]` and `1` | any other owner set |

**Part 0 rehearsal command (the operator runs it; it takes the shared fork lock `/tmp/pilot-fork.lock`):**

```
cd contracts/vault-dlmm
export AVALANCHE_RPC=<your endpoint, in your shell only>   # never in a file or an argument
export REH_SCAN_FROM=<vault deployment block>
export ETHERS_DIR=<path>/dlmm-keeper/node_modules/ethers    # (the script also finds ../../dlmm-keeper/node_modules)
tools/rewards-rehearsal/rehearsal.sh --dry                  # inputs only: exit 0 'DRY: all inputs OK'
tools/rewards-rehearsal/rehearsal.sh /path/to/evidence-dir  # the real rehearsal on a local anvil fork of head-4
```

Pass: the last two lines are `RESULTS {...}` and `REHEARSAL PASSED: 33 checks, 0 failures`; exit code 0; 33 lines `PASS P00` .. `PASS P32`; no `FAIL` line; `upstream-status.json` shows no `"429"`. Fail: `REHEARSAL FAILED: 33 checks, N failures: P..` with the failing `FAIL Pxx` lines, exit 1; `FATAL: ...` exit 2 (bad input or an aborted step); exit 3 sandbox refused (anvil/proxy/argv check); exit 42 rate limit seen (stop, report, do not switch provider); exit 43 `NO PHAR ACCRUED` (the live band paid 0 PHAR in the warped day: run again with `REH_WARP_SECONDS=172800`). The output also lists the first epoch's real numbers (copies in `<evidence-dir>/epoch-rehearsal-NOT-PUBLISHABLE/`, flagged `rehearsalEndpoint`; never commit or publish them) and the distributor's runtime codehash (P15), which the live deployment must equal.

## Part A. Deploy the distributor (once)

The deployer is a **throwaway keystore** that only pays gas and owns nothing: the Safe is the owner from the constructor (`new PharRewardsDistributor(PHAR, SAFE, 86400, 15552000)`), there is no hand-over step.

| # | Who | Command | Expected | Abort if |
| --- | --- | --- | --- | --- |
| A1 | OPERATOR | `cast wallet new ~/.foundry/keystores dlmm-rewards-deployer` (hidden password prompt) | prints the new deployer address; the key stays in the keystore | |
| A2 | anyone | `export DEPLOYER=<address from A1> DLMM_DEPLOYER_ACCOUNT=dlmm-rewards-deployer ; tools/dlmm-rewards-ceremony.sh check-env live` | `all inputs set; the deployer is neither the Ledger nor the Safe` | any UNSET / refusal |
| A3 | OPERATOR (Ledger) | `DEPLOYER_AVAX=0.05 tools/dlmm-ledger-step.sh simulate fund-deployer` then `DEPLOYER_AVAX=0.05 tools/dlmm-ledger-step.sh send fund-deployer` | decoded "plain AVAX transfer of 0.05 AVAX to the deployer (code at the recipient: none (an EOA))", Ledger nonce, `simulation passed`, ONE Ledger confirmation | recipient shows `HAS CODE`; simulation fails |
| A4 | anyone | read the chain facts the pre-flight will check: `cast chain-id` ; `cast call $SAFE 'getOwners()(address[])'` ; `cast call $VAULT 'owner()(address)'` ; `cast call $VAULT 'rewardToken()(address)'` ; `cast call $PHAR 'decimals()(uint8)'` ; `cast nonce $DEPLOYER` | `43114`; `[0x064eFE76...B2dD]`; the Safe; the PHAR address; `18`; `0` | any other value |
| A5 | OPERATOR (deployer) | `tools/dlmm-rewards-ceremony.sh deploy live` (forge asks the keystore password; `forge script` simulates on chain before it broadcasts) | pre-flight passes (chain, Safe 1-of-1 owned by the Ledger, vault owner = Safe, `vault.rewardToken() == PHAR`, PHAR 18 decimals, vault shares 6 decimals, deployer fresh), ONE transaction (1,247,178 gas, MEASURED with `forge create` on a plain local anvil; the forge script's own gas limit applies), prints `PHAR_DISTRIBUTOR=0x...` and `PHAR_DISTRIBUTOR_CODEHASH=0x...`, writes `ceremony/dlmm-rewards-addresses.live.env` (`values found: 2`) | a pre-flight revert (nothing was sent: fix and re-run); `values found: 0` or `MISSING` in the file |
| A6 | anyone | `source ceremony/dlmm-rewards-addresses.live.env ; export DIST=$PHAR_DISTRIBUTOR DISTRIBUTOR=$PHAR_DISTRIBUTOR EXPECT_OWNER_SAFE=true EXPECT_DELAY=86400 EXPECT_DEADLINE=15552000 ; tools/dlmm-rewards-ceremony.sh verify live` | the read-back table below, no `require` failure | any mismatch: do NOT use the contract; nothing is funded yet, abandon it |
| A7 | anyone | **read-back list** (below), by hand with `cast call` | every row as written | any difference |
| A8 | anyone | `cast codehash $DIST` | equals the codehash printed by the rehearsal at P15 and by A5 (same compiler settings, same constructor arguments) | different: STOP, the bytecode is not what was rehearsed |
| A9 | OPERATOR (deployer) | `DEPLOYER=$DEPLOYER DLMM_DEPLOYER_ACCOUNT=dlmm-rewards-deployer tools/dlmm-ledger-step.sh simulate sweep-deployer` then `send sweep-deployer` | leftover AVAX back to the Ledger | |
| A10 | OPERATOR | delete the `dlmm-rewards-deployer` keystore and its password, and `broadcast/DeployPharRewardsDistributor.s.sol/` (only after A6 to A9 passed) | | |
| A11 | OPERATOR | record in the handoff and the frontend config: `$DIST`, the codehash, `sha256sum src/rewards/PharRewardsDistributor.sol`, the deploy transaction hash and block, the deployment block `REH_SCAN_FROM` | | |
| A12 | OPERATOR | (optional, decision) switch on the keeper's daily harvest: add `"harvest": {"enabled": true}` to the host config, `deploy/dlmm-keeper-host.sh stage <ip> host.json`, restart the unit (`dlmm-keeper/README.md`, section "Optional periodic PHAR harvest"). Read back: `docker exec dlmm-keeper node dist/src/main.js status` shows `harvest.enabled: true`; within one in-range cycle a `PHAR HARVESTED` log line | the Safe's PHAR balance rises by `PharHarvested.amount` | `harvest:failed` warnings that repeat: leave it disabled and harvest by hand (part B step W0) |

**Read-back list (A7), every row exact:**

| What | Command | Expected |
| --- | --- | --- |
| owner is the Safe from the constructor | `cast call $DIST 'owner()(address)'` | `0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12` |
| no pending ownership transfer | `cast call $DIST 'pendingOwner()(address)'` | `0x0000000000000000000000000000000000000000` |
| the deployer owns nothing | `cast call $DIST 'owner()(address)'` differs from `$DEPLOYER` | true |
| token | `cast call $DIST 'PHAR()(address)'` | `0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7` |
| challenge window | `cast call $DIST 'CLAIM_DELAY()(uint256)'` | `86400` |
| claim deadline | `cast call $DIST 'CLAIM_DEADLINE()(uint256)'` | `15552000` |
| minimum window | `cast call $DIST 'MIN_CLAIM_WINDOW()(uint256)'` | `604800` |
| next epoch id | `cast call $DIST 'epochCount()(uint256)'` | `0` |
| balance | `cast call $PHAR 'balanceOf(address)(uint256)' $DIST` | `0` |
| the deployer's nonce | `cast nonce $DEPLOYER` | `1` (one transaction) |
| renounce is disabled | `cast call $DIST 'renounceOwnership()' --from $SAFE` | reverts `RenounceDisabled()` |
| code | `cast codehash $DIST` | equals the rehearsal's (A8) |

**Brakes and aborts, any time:** the distributor has no pause and no rescue (by design). Before any epoch is published there is nothing to lose: abandon the address. After publication the brakes are `cancelEpoch` (inside 24 h) and `sweepUnclaimed` (after 180 days); ownership moves only by `transferOwnership(new)` + `acceptOwnership()`.

## Part B. The weekly procedure (harvest daily, publish weekly)

Variables: `DIST` from A11, `SCAN_FROM` = the vault's deployment block, `ID` = the next epoch id. **Every command is run from `contracts/vault-dlmm/` on a clean checkout of the reviewed commit.**

| # | Who | Command | Expected | Abort if |
| --- | --- | --- | --- | --- |
| W0 | keeper (daily) or OPERATOR (Ledger via Safe) | the keeper's periodic harvest (A12), or by hand: `VAULT=$VAULT tools/dlmm-harvest.sh simulate` then `VAULT=$VAULT tools/dlmm-harvest.sh send` | prints the band, the pending PHAR, `SIMULATION ... true`, one Ledger confirmation, then `received this harvest (wei) N`; a `PharHarvested(PHAR, N, supply, assets)` event; the Safe's PHAR rose by N | simulation not true; N = 0 for several days (the weekly vote may have given the pool nothing; not a failure) |
| W1 | anyone | choose the END harvest: the newest `PharHarvested` (its transaction hash `$TX`): `dlmm-keeper status` (`harvest.last.tx`) or the vault's logs; read back `cast receipt $TX blockNumber status` | `status 1` and the block | the transaction is not a `harvestRewards()` of the vault |
| W2 | anyone | `ID=$(cast call $DIST 'epochCount()(uint256)' \| awk '{print $1}')` ; the previous LIVE epoch: the highest id whose `epochInfo` status is 1 or 3 (not 2 = cancelled), its folder `epochs/<prev>/` | `$ID` | a cancelled id as the previous epoch |
| W3 | anyone | **generate** (no key, public endpoint only): first epoch: `node tools/dlmm-rewards-root.mjs --epoch-id $ID --scan-from $SCAN_FROM --first-epoch --to-harvest $TX --out-dir epochs/$ID --uri '<URI of the epoch file>'` ; every later epoch: replace `--first-epoch` by `--previous-manifest epochs/<prev>/manifest.json`. Add `--allow-contract ADDR` / `--exclude ADDR` only as decided in 0g. Defaults: `--user-bps 9000`, the dead seed excluded (its slice stays with the Safe) | prints `epoch N: blocks (start, end] ...`, `root`, `leaves`, `PUBLISH TOTAL`, `stays with the Safe: ...`, `checks: ... all true`, `dataHash`, `publishEpoch(...)`. The first epoch starts at block `100488395` | any `check failed`, `negative balance` (scan-from too late), `the start block ... has no PharHarvested event` (wrong previous manifest) |
| W4 | anyone | **refuse a dirty generator:** `jq -r '.gitCommit, .gitDirty' epochs/$ID/manifest.json` ; `git rev-parse HEAD` ; `git status --porcelain -- tools/dlmm-rewards-root.mjs` ; and `jq -r .rehearsalEndpoint epochs/$ID/manifest.json` | `gitCommit` equals `HEAD`, `false`, empty status, `null` | `gitDirty` true, `gitCommit` null, or `rehearsalEndpoint` set: re-run on a clean checkout |
| W5 | OPERATOR | **commit the epoch folder** and publish it: `git add contracts/vault-dlmm/epochs/$ID && git commit` (message: epoch id, block range, root, dataHash), push; the app serves `epochs/$ID/epoch.json` at the `--uri`. **Kept at least 180 days; never edited or deleted afterwards** | the commit is public; `cast keccak 0x$(xxd -p epochs/$ID/epoch.json \| tr -d '\n')` equals `manifest.dataHash`; the hosted bytes hash the same | a hash mismatch between the repo file and the hosted file |
| W6 | a FRESH subagent | **second recompute** from the published inputs only: `avalanche-dlmm-rewards-second-recompute.md` (the prompt template, the checklist of what is published) | the report ends `MATCH`; byte-identical `epoch.json`, same `dataHash` and `root`; report saved as `epochs/$ID/recompute-report.md` and committed | `MISMATCH` or `COULD NOT RECOMPUTE` (never counted as a match): STOP, find the cause, do not publish |
| W7 | OPERATOR (Ledger via Safe, tx 1) | `DIST=$DIST tools/dlmm-rewards-safe-call.sh simulate approve $TOTAL` then `DIST=$DIST tools/dlmm-rewards-safe-call.sh send approve $TOTAL` (`$TOTAL = manifest.publishEpochArguments.total`, the EXACT sum of the leaves; the tool refuses above 10^30 wei) | decoded `PHAR.approve(DIST, TOTAL)`, `before: ... Safe PHAR ... allowance=0 ... safe nonce=N`, `SIMULATION ... true`, `ABOUT TO SIGN: Safe nonce N`, one Ledger confirmation; read back `cast call $PHAR 'allowance(address,address)(uint256)' $SAFE $DIST` = `$TOTAL` | the Safe's PHAR balance is below `$TOTAL`; the decoded amount differs |
| W8 | OPERATOR (Ledger via Safe, tx 2) | `EXPECT_EPOCH_ID=$ID DIST=$DIST tools/dlmm-rewards-safe-call.sh simulate publish <root> <total> <fromBlock> <toBlock> <dataHash>` then the same with `send` (the five arguments are `manifest.publishEpochArguments`, copied, not retyped) | `PUBLISH epoch id $ID: root ... total ... blocks (from, to] dataHash ...`, `SIMULATION ... true`, one Ledger confirmation; afterwards `epochCount()` = `$ID + 1`, `epochInfo($ID)` status `1` with root / total / fromBlock / toBlock / dataHash equal to the manifest, `claimOpensAt = publishedAt + 86400`, `claimDeadline = publishedAt + 15552000`; `cast call $PHAR 'balanceOf(address)(uint256)' $DIST` rose by exactly `$TOTAL`; the allowance is back to `0`; the `EpochPublished` log | the tool refuses (`epochCount() is X but the root was generated for id Y`: regenerate, the id is inside every leaf); a toBlock above the head |
| W9 | OPERATOR | **continuity read-back** (nothing on chain enforces it): `cast call $DIST 'epochInfo(uint256)' <previous live id>` shows `toBlock` equal to this epoch's `fromBlock` (`manifest.startBlock`) and no overlap | equal | a gap or an overlap: cancel (W11) |
| W10 | OPERATOR | **announce** (channel of your choice): epoch id, block range and times, root, `dataHash`, the committed file's URL and commit, the total in PHAR, `userBps`, "claims open at `claimOpensAt` (24 h review window); anyone can recompute: `avalanche-dlmm-rewards-second-recompute.md`" | | |
| W11 | OPERATOR (Ledger via Safe) | **only inside the 24 h window, only if something is wrong:** `DIST=$DIST tools/dlmm-rewards-safe-call.sh simulate cancel $ID` then `send cancel $ID`. Then regenerate for the NEW id (`epochCount()`) with the SAME `--previous-manifest`, and go to W3. Keep the cancelled epoch's folder (add a `CANCELLED` file naming the cancel transaction) | `epochInfo($ID)` status `2`; the Safe's PHAR balance back to its value before W7 | the tool says the window is over (`claimOpensAt <= now`): the epoch is immutable |
| W12 | anyone | **claims open** at `claimOpensAt`: watch `Claimed` events; `isClaimWindowOpen($ID)` true | | |
| W13 | OPERATOR (Ledger via Safe) | at or after `publishedAt + 180 days`: `DIST=$DIST tools/dlmm-rewards-safe-call.sh simulate sweep $ID` then `send sweep $ID` | status `3`; the Safe's PHAR rose by `total - claimed`; the distributor holds `0` for this epoch | the tool says `sweep is not possible yet` |

**Read-backs after every Safe transaction:** `cast call $SAFE 'nonce()(uint256)'` increased by one; the Safe's PHAR balance and the distributor's PHAR balance against the figures printed by the tool (`before:` / `after:` lines).

**What stays with the Safe (and why),** printed by the generator for every epoch: the 10 % part (`10000 - userBps`), the excluded holders' slices (the dead seed, contracts, the vault, explicit excludes: listed per address with `returnedToSafe`), and rounding. Only the sum of the leaves is ever approved and published.

**Rehearsal versus live differences:** the rehearsal uses `SEND_MODE=unlocked` (an impersonated Ledger on a local fork); the live run uses the default `SEND_MODE=ledger` (`cast send --ledger`, one confirmation on the device). The tools print `OPERATOR-ONLY: one Ledger confirmation` in that mode. Nothing else differs.

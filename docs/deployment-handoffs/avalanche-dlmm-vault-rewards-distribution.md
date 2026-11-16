# Avalanche Pharaoh DLMM USDC/USDt vault: PHAR distribution to depositors (design A)

Status: **BUILT AND TESTED OFFLINE, NOT DEPLOYED, NOT RUN AGAINST THE NETWORK.** Nothing here was signed, sent or broadcast and no RPC endpoint was used by the agent that built it. The deploy script (`contracts/vault-dlmm/script/DeployPharRewardsDistributor.s.sol`) and the three operator tools were only compiled / syntax-checked. All paths are relative to `contracts/vault-dlmm/` unless they start with `docs/`.

The live vault (proxy `0x278B1b625C74B1926C5F989ddE601f3C5Ba27f7D`, source `src/PharaohDlmmVault.sol`, **frozen**, together with `PharaohDlmmPairValidator.sol` and `IPharaohDlmmVault.sol`) claims PHAR with `harvestRewards()` and forwards the **whole** PHAR balance to its owner, the Peridot Safe `0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12` (1-of-1, owner the Ledger `0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD`). `harvestRewards()` may be called by the rebalancer (keeper) or the owner, so PHAR reaches the Safe whenever either calls it. The operator decided that depositors receive most of that PHAR. This document is design A: **a separate distributor contract plus an off-chain root generator; the vault is not touched.**

## 1. Design in one page

```
vault.harvestRewards()  --PHAR-->  Safe (owner)        (keeper or Safe; emits PharHarvested(token, amount, supplyShares, nav))
          |
          |  off chain, anyone can repeat it:  tools/dlmm-rewards-root.mjs
          |    inputs : the vault's public ERC-20 Transfer events (shares) and PharHarvested events
          |    output : epoch.json (every holder, weight, amount, exclusions, leaves + Merkle proofs), manifest.json
          v
Safe: PHAR.approve(distributor, total)  ->  distributor.publishEpoch(root, total, fromBlock, toBlock, dataHash)   pulls `total` PHAR from the Safe
          |  24 h challenge window: the Safe may cancelEpoch(id) and get everything back; nobody can claim yet
          v
claim(epochId, account, amount, proof)        anyone may submit; the PHAR always goes to `account`; once per (epoch, account)
          |  180 days after publication
          v
sweepUnclaimed(epochId)  ->  what nobody claimed returns to the Safe
```

* **One epoch = a block range `(start, end]` whose two boundaries are harvest blocks.** `end` is the block of a chosen `PharHarvested` event; `start` is the previous published epoch's `end` (the first epoch starts at the vault's first harvest-eligible block, the `openBand` block **100488395**, tx `0x58e31159ad11de27e80ed6871f00e53923077c1c18a5e31b07722ae25e8634ab`, unless the operator says otherwise). An epoch may span several consecutive harvests (`--to-harvest`). **The PHAR of an epoch is the sum of `PharHarvested.amount` inside the range**, not the Safe's balance: PHAR the Safe received from the Pharaoh CL vaults, or that someone donated to the DLMM vault, is not distributed unless the operator adds it explicitly (`--extra-phar`), and then it is shown separately.
* **Entitlement is time-weighted.** For every share holder the generator integrates the share balance over the block timestamps of the range (a share held for the whole epoch counts fully, one bought half-way counts half, one sold half-way the other half). The epoch's PHAR times `USER_BPS` (default **9000 = 90 %**, a per-epoch generator argument, **not an on-chain constant**) is split pro rata over the **total** time-weighted supply, with floor rounding.
* **Holders that cannot claim are excluded and their share goes back to the Safe**: the zero address, the dead seed `0x...dEaD` (1,000,000 seed shares), the vault itself, every address with contract code at the epoch's end block **except** addresses on the operator's `--allow-contract` list (an EIP-7702 delegation designator, code `0xef0100` + 20 bytes = 23 bytes, counts as an EOA), and any `--exclude` address. Their weight **stays in the denominator**, so excluding a holder never raises anybody else's amount; their slice is simply never published and stays with the Safe (it is listed per address as `returnedToSafe`).
* **The Safe publishes the exact sum of the leaves** as `total` (not `pharTotal * USER_BPS / 10000`): rounding dust and the excluded slices never leave the Safe, so nothing is locked in the distributor for 180 days.
* **On chain only the root, the total, the block range and a hash of the data file are recorded** (`EpochPublished(epochId, root, total, fromBlock, toBlock, dataHash, publishedAt, claimOpensAt, claimDeadline)`). `dataHash = keccak256(epoch.json bytes)`. `USER_BPS` appears on chain **only inside** that file (so only as part of `dataHash`), as do the exclusion list, the harvest transaction list and every holder's weight.

## 2. Files

| File | What |
| --- | --- |
| `src/rewards/PharRewardsDistributor.sol` | the distributor (294 lines, solc 0.8.35, OpenZeppelin 5.3.0 `Ownable2Step`, `ReentrancyGuard`, `SafeERC20`, `MerkleProof`) |
| `tools/dlmm-rewards-root.mjs` | the root generator (Node, ethers v5 as the keeper uses; run `npm ci` once in `dlmm-keeper/`, the tool finds `../../../dlmm-keeper/node_modules/ethers`, or set `ETHERS_DIR`) |
| `tools/rewards-test/dlmm-rewards-root.test.mjs` | offline tests of the generator on a synthetic event fixture (`node --test tools/rewards-test/dlmm-rewards-root.test.mjs`) |
| `test/rewards/*.sol`, `test/rewards/fixtures/*.json` | Foundry tests of the contract, odd-token tests, fuzz, invariants, and the JS-vs-Solidity cross-check on the committed fixtures |
| `script/DeployPharRewardsDistributor.s.sol` | deploy script (pre-flight, one transaction, post-checks) and `ReadBackPharRewardsDistributor` |
| `tools/dlmm-rewards-ceremony.sh` | `list` / `check-env` / `deploy` / `verify`, in the style of `dlmm-vault-ceremony.sh` |
| `tools/dlmm-rewards-safe-call.sh` | the Safe calls of the procedure (approve exact total, publish, cancel, sweep), in the style of `dlmm-safe-call.sh` |
| `mutation/rewards-mutants.py` | the hand-mutant round on the distributor (section 12) |

The Foundry project got one change: `foundry.toml` has `fs_permissions = [{ access = "read", path = "./test/rewards/fixtures" }]` (read-only, for the cross-check test).

## 3. Trust model

**What the Safe controls (and only this):**

1. *Whether* and *when* an epoch is published, its Merkle root, its funded `total`, its block range and `dataHash`. A wrong or dishonest root is the one real trust assumption: a depositor cannot veto it. The remedy is public detectability (below) plus the Safe's own `cancelEpoch` inside the 24 h window.
2. `cancelEpoch(id)`: only while `now < publishedAt + CLAIM_DELAY` (strictly before `claimOpensAt`). It returns all of the epoch's PHAR to the owner and is terminal (the id is burnt).
3. `sweepUnclaimed(id)`: only when `now >= publishedAt + CLAIM_DEADLINE`, exactly `total - claimed`, once. Claims of the epoch are closed from the same second.
4. Two-step ownership transfer (`transferOwnership` then `acceptOwnership` by the new owner). `renounceOwnership` always reverts. Refunds and sweeps go to the **current** owner.

**What the Safe cannot do:** change a root, a total or a range after publication; take PHAR out of an open epoch except by the two doors above (every PHAR transfer out of the contract is in `claim`, `cancelEpoch` or `sweepUnclaimed`; there is no pause, no rescue, no setter for the token, the delay or the deadline; no `receive`/`fallback`); redirect a claim (the PHAR goes to the `account` in the leaf, whoever submits); block a claim during the window (no pause); touch another epoch's PHAR (every epoch has its own `claimed` counter and `claimed + amount <= total` is checked on every claim, even for a wrong root).

**What anyone can verify from public events** (no trust in Peridot): the vault share `Transfer` events, the `PharHarvested` events and `eth_getCode` at the end block are all public chain data. `node tools/dlmm-rewards-root.mjs` is deterministic: the same inputs give a byte-identical `epoch.json`. A depositor (or a watcher bot) can therefore (a) read `EpochPublished` from the distributor, (b) download the data file from the URI in the manifest, (c) check `keccak256(file) == dataHash`, (d) re-run the generator over the same block range and compare the file byte for byte, (e) check the Merkle proof of any leaf against the on-chain root. **What stays a policy choice of the Safe and is checkable only for consistency**: `USER_BPS` (written in the file), the `--allow-contract` / `--exclude` lists (written in the file, with a hash), and `--extra-phar`.

**How a depositor recomputes their own amount** (no tool needed, exact):

```
W_me   = sum over the epoch's seconds of my share balance          (share-seconds; Transfer events, timestamps of their blocks)
W      = sum over the epoch's seconds of the vault's TOTAL share supply  (= sum of every holder's W, including the seed and excluded holders)
pool   = floor(PHAR_harvested_in_range * USER_BPS / 10000)           (+ --extra-phar before the bps if the file says so)
amount = floor(pool * W_me / W)
```

`epoch.json` lists `weight` (= `W_me`) for every holder and `totals.totalWeight` (= `W`), so the arithmetic can be checked per line. The window is `(startBlock, endBlock]`: events in blocks `<= startBlock` only build the opening balances; an event in a block `> startBlock` takes effect at that block's timestamp; weights are integrated over `[ts(startBlock), ts(endBlock)]`; events in the same block are applied in log order.

## 4. Parameters

| Parameter | Value | Where | Changeable? |
| --- | --- | --- | --- |
| `PHAR` | `0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7` (18 decimals) | immutable; the deploy script requires `vault.rewardToken() == PHAR` | no |
| owner | the Safe (constructor argument; the deployer is never an owner) | `Ownable2Step` | two-step transfer only; no renounce |
| `CLAIM_DELAY` | 86400 s (24 h) | immutable, constructor argument | no |
| `CLAIM_DEADLINE` | 15552000 s (180 days) after `publishedAt` | immutable, constructor argument | no |
| constructor sanity | `CLAIM_DELAY > 0`; `CLAIM_DEADLINE >= CLAIM_DELAY + 7 days` (`MIN_CLAIM_WINDOW`) and `<= 10 years`; token has code; owner not zero | | |
| `USER_BPS` | default **9000**, per-epoch generator argument `--user-bps` | `epoch.json` (`inputs.userBps`), `manifest.json`; on chain only inside `dataHash` | per epoch, by the operator |
| epoch ids | 0, 1, 2, ... in publication order; `epochCount()` is the id the next `publishEpoch` assigns; a cancelled id is never reused | | |
| block range | `publishEpoch` records `fromBlock`, `toBlock` and `dataHash`; only sanity-checked (`fromBlock < toBlock <= block.number`, `dataHash != 0`); **ranges are not chained on chain** (a cancelled epoch must be republishable with the same range) | | continuity is checked by the generator (`--previous-manifest`) and by the procedure |
| claim window | `claim` works for `claimOpensAt <= now < claimDeadline`; `cancelEpoch` for `now < claimOpensAt`; `sweepUnclaimed` for `now >= claimDeadline`; boundaries are tested at `t-1`, `t`, `t+1` | | |

Contract conventions worth knowing: the "bitmap" of the brief is a per-`(epoch, account)` flag, because the leaf `(epochId, account, amount)` has no index (an index parameter not in the leaf would allow a double claim). `claimMany(Claim[])` **skips** an entry whose `(epoch, account)` is already claimed (so a front-run of one entry cannot fail the whole batch) and reverts the whole batch on any other problem (bad proof, window, a token that refuses the transfer). `publishEpoch` measures the balance delta and reverts unless the distributor received exactly `total` (a fee-on-transfer or over-delivering token cannot fund an epoch). PHAR sent to the distributor directly is neither claimable nor sweepable (it is lost): accounting is by `total`/`claimed`, never by balance.

## 5. The generator

```
cd contracts/vault-dlmm
node tools/dlmm-rewards-root.mjs --epoch-id <ID> --scan-from <vault deployment block> \
     (--first-epoch | --previous-manifest epochs/<prev>/manifest.json) --to-harvest <txhash|N> \
     [--user-bps 9000] [--extra-phar WEI] [--allow-contract ADDR]... [--exclude ADDR]... [--min-amount WEI] \
     [--out-dir epochs/<ID>] [--uri 'https://...'] [--cache-dir ./rewards-cache]
```

* **Network:** the public endpoint `https://api.avax.network/ext/bc/C/rpc` only; it is a constant in the tool, there is no RPC option and no environment variable is read; error text passes through a redaction of any `http(s)://` string. Logs are fetched in **100-block chunks** (`eth_getLogs`, topic filter Transfer + PharHarvested on the vault address), with exponential back-off and jitter, and are **resumable** (`--cache-dir` holds the scanned logs and block timestamps; a second run scans only new blocks; a run with `--to-harvest N` stops at the chunk that contains the chosen harvest). Block timestamps are fetched only for blocks that contain an in-epoch Transfer plus the two boundary blocks, and cached; `Timestamps.blockAtOrBefore/After` are binary searches kept for ad-hoc lookups.
* **Scan time:** the scan must start at the vault's deployment block (`--scan-from`) so that every opening balance is known; the tool aborts with "negative balance" if the history is incomplete. At 100 blocks per call a month of Avalanche blocks is on the order of 10^4 calls; the first run is slow, later runs resume. **Not measured against the live endpoint** (see open questions).
* **Contract detection:** `eth_getCode` at the epoch's end block for every holder that is not already excluded. If the public endpoint does not serve historical state, the tool falls back to the **latest** code and records `checkedAt: "latest"` per address in `epoch.json` (`codeChecks`). A contract does not disappear, but a contract deployed after the end block at an address that was an EOA then would not be seen: low risk, stated here.
* **Outputs** (`--out-dir`, default `epochs/<ID>/`): `epoch.json` (the hashed data file: `inputs`, `totals`, `exclusions` with the reason and the PHAR returned per address and `listHash`, `codeChecks`, `checks`, `root`, the per-holder table, and `leaves` sorted by leaf hash **with their proofs**) and `manifest.json` (epoch id, vault, start/end block and timestamps, harvest tx hashes, `harvestSum`, `extraPhar`, `pharTotal`, `userBps`, `publishTotal`, generator version, **git commit and dirty flag of the generator**, `exclusionListHash`, `dataFile`, `leavesFile`, `dataHash`, `root`, a free-string `uri`, and the exact `publishEpochArguments`). The manifest is not part of `dataHash` (it carries the git commit and the `uri`, which are set after the fact); everything that matters for recomputation is in `epoch.json`. The tool refuses to overwrite an existing, different `epoch.json` (`--force` to override).
* **Checks the tool enforces before it writes** (it throws otherwise): sum of leaves <= `floor(pharTotal * bps / 10000)` and <= `pharTotal * bps / 10000`; the sum of the per-holder weights equals the integral of the total supply; leaves unique, none zero, none for an excluded holder; the excluded slices add up; `leaves + excluded + rounding/dust + (100 % - bps)` partition `pharTotal` exactly; every proof verifies against the root.
* Rounding: `amount = floor(pool * weight / totalWeight)`; the remainder stays with the Safe and is reported as `roundingAndDust`. `--min-amount` (default 1 wei) drops tiny leaves (a claim costs about 90,000 gas).

## 6. Operator procedure (exact order, every on-chain step a Safe transaction)

Variables (public values): `DIST` = the deployed distributor, `VAULT=0x278B1b625C74B1926C5F989ddE601f3C5Ba27f7D`, `SAFE=0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12`, `PHAR=0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7`. `ETH_RPC_URL` is the operator's endpoint in the environment (never an argument). Safe transactions go through the Ledger; each tool simulates first (`simulate` is an `eth_call` from the Ledger and must print `true`). The tools below were **not run**; rehearse them on a local anvil fork of Avalanche first (`SEND_MODE=unlocked`).

**A. One-time deployment** (`tools/dlmm-rewards-ceremony.sh list` prints this too)

1. Throwaway deployer key (Foundry keystore), gas only. `tools/dlmm-rewards-ceremony.sh check-env live`.
2. `tools/dlmm-rewards-ceremony.sh deploy live`: pre-flight (chain 43114, Safe 1-of-1 owned by the Ledger, vault owner = Safe, `vault.rewardToken() == PHAR`, PHAR 18 decimals), ONE transaction, post-checks. Writes `ceremony/dlmm-rewards-addresses.live.env` (public values).
3. `DISTRIBUTOR=$DIST EXPECT_OWNER_SAFE=true tools/dlmm-rewards-ceremony.sh verify live`. Read back: `cast call $DIST 'owner()(address)'` = Safe; `'PHAR()(address)'`; `'CLAIM_DELAY()(uint256)'` = 86400; `'CLAIM_DEADLINE()(uint256)'` = 15552000; `'epochCount()(uint256)'` = 0; `cast codehash $DIST` recorded with the sha256 of `src/rewards/PharRewardsDistributor.sol`.

**B. Every epoch**

1. **Harvest (Safe tx 1; skip if the keeper already harvested and you chose that harvest as the end).** `tools/dlmm-safe-call.sh send $VAULT 'harvestRewards()'`. Read back the receipt: `cast receipt <tx> blockNumber status`; the `PharHarvested(token, amount, totalSupplyShares, totalAssets)` log; `cast call $PHAR 'balanceOf(address)(uint256)' $SAFE` before and after. Note the transaction hash and block of the harvest that will END the epoch. The epoch ends at a harvest **block**; every harvest of the range counts.
2. **Next epoch id:** `ID=$(cast call $DIST 'epochCount()(uint256)')`. The id is inside every leaf: after a cancelled epoch the next id is higher, and the root must be regenerated.
3. **Generate** (off chain, any machine, no key): the command of section 5 with `--epoch-id $ID`, `--to-harvest <txhash>` and `--previous-manifest` of the last **published, not cancelled** epoch (`--first-epoch` for the first). Read the printed summary: harvests, pool, **PUBLISH TOTAL**, what stays with the Safe and why, the exclusion list (address and reason), the checks. A **second person re-runs it on another machine** and compares `sha256sum epochs/$ID/epoch.json`.
4. **Host the files.** The operator hosts `epoch.json` and `manifest.json` at a URI of their choice and writes it into `manifest.uri` (a free string; **only `dataHash` goes on chain**). Publish **before** step 6 so that the 24 h window can be used. Check the hosted bytes: `cast keccak 0x$(xxd -p epoch.json | tr -d '\n')` must equal `manifest.dataHash`.
5. **Approve exactly the total (Safe tx 2):** `DIST=$DIST tools/dlmm-rewards-safe-call.sh send approve <publishTotal>`. Read back `cast call $PHAR 'allowance(address,address)(uint256)' $SAFE $DIST`.
6. **Publish (Safe tx 3):** `DIST=$DIST EXPECT_EPOCH_ID=$ID tools/dlmm-rewards-safe-call.sh send publish <root> <publishTotal> <fromBlock> <toBlock> <dataHash>` (the arguments are in `manifest.publishEpochArguments`). The tool refuses if `epochCount() != EXPECT_EPOCH_ID`, if the Safe's PHAR balance or allowance is below the total, or if `toBlock` is above the head. Read back **continuity** first (nothing on chain enforces it): `cast call $DIST 'epochInfo(uint256)' <previous live epoch id>` must show `toBlock` equal to this epoch's `fromBlock` (`manifest.startBlock`) and the ranges must not overlap. Then: `cast call $DIST 'epochInfo(uint256)' $ID` (status 1 = Open, root, total, `fromBlock`, `toBlock`, `dataHash`, `claimOpensAt`, `claimDeadline`); `cast call $PHAR 'balanceOf(address)(uint256)' $DIST` rose by exactly the total; the allowance is back to 0; the `EpochPublished` log.
7. **Challenge window (24 h).** Anyone may recompute and compare. If anything is wrong (wrong id, wrong range, a holder missing, a wrong exclusion): **Safe tx 4, inside the window only:** `DIST=$DIST tools/dlmm-rewards-safe-call.sh send cancel $ID`. Read back `epochInfo` status 2 (Cancelled) and the Safe's PHAR balance restored. Then regenerate for the NEW id (`epochCount()`), with the **same** `--previous-manifest`, and go to step 3. After `claimOpensAt` the epoch is immutable.
8. **Claims open** at `claimOpensAt`; anyone can submit a claim; watch the `Claimed` events.
9. **Sweep (Safe tx 5)**, at or after `publishedAt + 180 days` (`claimDeadline`): `DIST=$DIST tools/dlmm-rewards-safe-call.sh send sweep $ID`. Read back status 3 (Swept) and the Safe's PHAR balance (+ `total - claimed`). Claims of that epoch end at the same second.

**C. If the Safe ever changes:** `transferOwnership(newSafe)` from the old Safe, then `acceptOwnership()` from the new one; read back `owner()` and `pendingOwner()`.

Where the data file is published, who hosts it and who runs the second recompute are **operator decisions** (section 14); the contract only commits to the hash.

## 7. Frontend read calls (a claim button)

All reads are `eth_call`s on `DIST`; the proofs come from the hosted `epoch.json` (`leaves[]` is an array of `{account, amount, leaf, proof}`; index it by lower-cased `account` in the page).

| Need | Call |
| --- | --- |
| list epochs | `epochCount()(uint256)`, then `epochInfo(uint256 id)` for `0 .. count-1`; or index `EpochPublished` / `EpochCancelled` / `Claimed` / `EpochSwept` |
| state of an epoch | `epochInfo(id)` returns `(root, total, claimed, publishedAt, claimOpensAt, claimDeadline, fromBlock, toBlock, dataHash, status)`; `status` 0 None, 1 Open, 2 Cancelled, 3 Swept |
| can claim now | `isClaimWindowOpen(id)(bool)` (open **and** `claimOpensAt <= now < claimDeadline`) |
| already claimed | `isClaimed(id, account)(bool)` |
| is my proof valid | `verifyLeaf(id, account, amount, proof)(bool)` (does not look at the window or at `isClaimed`) |
| claim | `claim(id, account, amount, proof)`; several: `claimMany([(id, account, amount, proof), ...])`. The PHAR goes to `account` even when another wallet submits |

Button states per epoch and connected account: **no leaf** (not in the file: show why, e.g. "contracts and the seed are excluded"), **pending** (`now < claimOpensAt`: "opens at ..., 24 h review window"), **claimable** (`isClaimWindowOpen && !isClaimed`), **claimed**, **closed** (`now >= claimDeadline`), **cancelled**. Show the amount in PHAR (18 decimals) and the manifest's block range. Never show a rate, an APY or an estimate of future PHAR (see section 8).

## 8. Deposit screen disclosure

Before deposits open, the deposit screen must show the following, in plain words, **before** the deposit button is usable (not behind a tooltip or a link). The same section is in `avalanche-dlmm-vault-frontend-handoff.md` (section 12).

1. **Share passed to depositors.** "Of the PHAR this vault harvests, **90 %** is passed to depositors in proportion to how many vault shares they held and for how long. The remaining **10 %** stays with the protocol Safe." (The number is the `userBps` of the latest published epoch, default 90 %; it is set per distribution and shown with each distribution; it can differ between distributions.)
2. **How it is paid.** "PHAR is distributed in rounds. Each round is published, then waits **24 hours** before anyone can claim; **you claim it yourself** (it is not sent automatically). Unclaimed PHAR returns to the Safe 180 days after publication."
3. **Who is not paid.** "Shares held by smart contracts (for example lending pools or routers) and the 1 USDC launch seed are excluded; their part stays with the protocol Safe. If you hold your shares in a contract, you may not receive PHAR for them."
4. **No promise.** "PHAR comes from a weekly vote and can be zero in any week. There is no APY and no promised amount. PHAR is paid in PHAR; its price is not guaranteed."

## 9. Known limits

* **Shares transferred during an epoch.** Handled by time-weighting, per second of block timestamps: seller and buyer each get PHAR for the time they held. It does not track *who deposited the USDC*: a transfer moves the entitlement from that moment. Shares sent to the dead address stop earning for the sender.
* **PHAR is attributed by holding time, not by accrual time.** The vault's bins earn PHAR continuously but it is only harvested when someone calls `harvestRewards()`; an epoch's PHAR is split by who held shares during the range that ends at a harvest, not by when the PHAR was earned. A holder who is there for the whole range gets the most; a deposit just before a harvest gets little (the weight is time-weighted) but is not zero.
* **The dead seed.** 1,000,000 shares (1 USDC) sit at `0x...dEaD` and earn nothing: their weight stays in the denominator and their slice (visible in `exclusions.list` of `epoch.json` as the entry with reason `dead-seed`, with its `weight` and `returnedToSafe`) stays with the Safe. A reading in which the seed is removed from the denominator would give depositors that slice too: see the open questions.
* **Shares held by contracts** (a lending pool, a router, a Safe) are excluded by default and their PHAR returns to the Safe; the operator can allow a contract that can claim (`--allow-contract`). A holder behind a contract loses the distribution unless the operator allows that contract or the holder moves the shares to an EOA.
* **The operator's own holding** (the 199 USDC "rest" is minted to the Ledger by default) is an ordinary holder: 90 % of its slice returns to the Safe by claiming. The operator may exclude it (`--exclude`).
* **Dust and rounding** stay with the Safe (reported). **Donated PHAR** is not distributed (unless `--extra-phar`), and PHAR sent straight to the distributor is lost.
* **Harvests by the keeper.** The keeper may harvest at any time; every harvest in the range counts (the manifest lists them). The harvest event's `amount` is what the rewarder paid in that call; the whole PHAR balance is forwarded, so a donation to the vault never inflates the event.
* **Public endpoint reliability and historical state** (`eth_getCode` at old blocks): section 5. The cache makes a failed run resumable.
* **PHAR price risk** is not our concern (stated in the disclosure). **Tax and legal treatment** of distributions is outside this document.
* **A token that can freeze an account** (not PHAR as far as known) would block only that account's claim; `claimMany` reverts as a whole on such an entry. Rebasing tokens are outside the guarantees.

## 10. Risks

| Risk | Effect | Mitigation |
| --- | --- | --- |
| Wrong root (bug in the generator, wrong id, wrong range) | some holders short-paid or a total that does not match; late claimers of that epoch can fail (`ExceedsEpochTotal`) | 24 h cancel window; second-person recompute; deterministic output; `publishEpoch` tool refuses a wrong epoch id; contract bounds every epoch by its own total |
| The Safe omits or shorts a holder deliberately | a depositor loses an amount | detectable by anyone with the public events; cannot be stopped by a depositor: this is the central trust assumption of design A |
| Generator or the public RPC returns incomplete logs | wrong weights | tool aborts on negative balance and on supply/weight mismatch; a second machine re-runs; `getLogs` results are cached and inspectable |
| Contract bug | funds locked or drained | small code (294 lines), 69 Foundry tests, fuzz, invariants, mutation round; **not independently audited** |
| Safe key loss | publication and sweep impossible; open epochs remain claimable (no owner action is needed to claim) | two-step ownership transfer |
| Unclaimed PHAR | returns to the Safe 180 days after publication | by design |

## 11. Engineering-effort note

Built here: contract + 69 tests + generator + 22 offline tests + deploy script + tools. Before mainnet: (1) an independent review of the distributor (about 300 lines, OpenZeppelin building blocks) and of the generator's weighting code; (2) a **fork rehearsal** of the deploy and of the Safe transactions with `SEND_MODE=unlocked` on a local anvil fork, including a fork run of one epoch end to end; (3) a **dry run of the generator against the public endpoint** on the first harvest range, timing the scan and checking historical `eth_getCode`; (4) the frontend claim screen and the deposit disclosure (a few days); (5) the hosting of epoch files and the second-person recompute routine; (6) operator decisions of section 14. Realistic total from now: about one week of review and rehearsal in parallel with a few days of frontend work. Running cost: one Safe harvest, approve and publish per epoch (about 145,000 to 180,000 gas for `publishEpoch`, about 87,000 to 99,000 gas per claim paid by whoever claims, 51,000 for cancel or sweep; isolated-transaction figures, section 12).

## 12. Evidence

Run from `contracts/vault-dlmm` (no fork, no RPC): `forge test --match-path 'test/rewards/*'` and `node --test tools/rewards-test/dlmm-rewards-root.test.mjs`.

* Foundry: 69 tests in 5 suites (45 contract tests incl. every window boundary at `t-1/t/t+1`, cancel/sweep/over-commit/ownership/unprivileged/renounce, 9 odd-token tests: fee-on-transfer, over-delivering, false-returning, no-return-value, blacklisting, ERC-777-style recipient hooks re-entering `claim`, `claimMany`, `cancelEpoch`, `sweepUnclaimed`; 7 fuzz tests on claim amounts, proofs, tampering, epoch ids, time windows, over-commit, constructor windows; 3 invariants: balance equals open obligations, `claimed <= total` and matches the ghost accounting, no over-pay; 5 JS-vs-Solidity cross-check tests).
* Gas (`forge test --isolate --match-test test_gasNumbers -vv`, so that every call is its own transaction with cold slots and the 21,000 base cost included; optimizer 200, via-IR): `publishEpoch` 145,000 to 180,000 (the first epoch of a fresh contract is the highest), `claim` 87,000 (empty proof) to 99,000 (10 proof nodes) to a fresh account, `cancelEpoch` 51,000, `sweepUnclaimed` 51,000, `claimMany` of 5 (5-leaf tree) 313,000. Without `--isolate` forge reports warm-slot numbers that are about 30 to 40 % lower and must not be quoted.
* Cross-check: `test/rewards/fixtures/expected.epoch.json` and `expected.manifest.json` are generated by the tool from `events.fixture.json` and committed; the Node test fails if the tool's output differs by one byte, and the Foundry test publishes the file's root with the manifest's arguments, checks `dataHash == keccak256(file)`, and claims **every** leaf with the JS proofs through OpenZeppelin `MerkleProof`.
* Mutation round (`mutation/rewards-mutants.py`, 84 hand mutants, one textual change each, run on scratch copies that contain only `src/rewards` and `test/rewards`, fixed fuzz seed `0x2a`): **79 killed, 5 equivalent (argued in the script: M27 publishEpoch without its reentrancy guard, M45 effects after the transfer while the guard holds, M66 `verifyLeaf` on an unknown epoch, M71 cancel refund `total - claimed` (claimed is always 0 in the window), M72 sweep of a zero amount), 0 survivors unexplained.** Two mutants (M13, M82) first failed to compile ("Tag too large", a via-IR artefact) and were re-written; M64 (`isClaimWindowOpen` ignoring the status) survived the first pass and led to a new test (`test_isClaimWindowOpenIsFalseForCancelledAndSweptEpochsInsideTheirTimeWindow`). The 81 mutants other than M13, M64 and M82 were run against the 68-test suite, those three against the 69-test one. The first pass did not record which test killed which mutant; a re-run of M12, M19, M25, M26 and M41 with the corrected script shows the intended killers (boundary tests and the fuzz time-window test for M12/M19, the recipient-hook re-entrancy tests for M25/M26, the over-commit tests for M41). Only the kill/survive status is claimed for the other mutants.

**Not done / uncertain (read before relying on this):**
* The live network path of the generator (`RpcSource`: `eth_getLogs` in 100-block chunks, timestamps, `eth_getCode`) has **zero test coverage**; everything was tested against a fixture source. Throttling, log limits and the public endpoint's historical-state behaviour are unknown.
* `codeChecks[].checkedAt` can be `"latest"` when the endpoint lacks old state, so the byte-identical output of two machines depends on the endpoint's behaviour (both must see the same code, which is true unless an address changed type after the end block).
* `dataHash` is the keccak256 of `epoch.json`, not of `manifest.json` (the manifest carries the git commit and the `uri`, which are set afterwards). `USER_BPS` is therefore on chain only through that hash.
* "Bitmap" is a per-`(epoch, account)` flag (the leaf has no index). The tools live under `contracts/vault-dlmm/tools/` because the repository root has no `tools/` directory.
* The vault's deployment block for `--scan-from` is not known to this branch. The three shell tools (`dlmm-rewards-ceremony.sh`, `dlmm-rewards-safe-call.sh`) were only syntax-checked (`bash -n`); the deploy script was only compiled; `dlmm-rewards-safe-call.sh` parses `cast` tuple output and needs `bc`: rehearse it on a fork. Its four function signatures were compared with `forge inspect ... methodIdentifiers`.
* Nothing enforces on chain that consecutive epochs tile; the generator (`--previous-manifest`) and the read-back in procedure step 6 do.
* The distributor was not audited.

## 13. What design B (an in-vault accumulator) would change

Design B puts the split in the vault: `harvestRewards()` would not forward PHAR to the Safe but credit it to a per-share accumulator, checkpointing every holder on every share transfer, mint and burn; depositors would pull their PHAR with a `claim()` on the vault. It would remove the off-chain generator, the Merkle root, the 24 h review window and the trust in the Safe's computation (the on-chain accounting would be exact per second, including mid-epoch transfers). It would cost: **an upgrade of the frozen vault** (the Safe owns the proxy admin; new code on the live vault, new audit scope and a new W10-style review, a rehearsal), extra gas on every deposit, withdrawal and transfer, a decision about the dead seed and contract holders in code (the exclusions become on-chain rules or constants), and the `USER_BPS` becomes either an on-chain constant or an owner setter (the operator chose a per-epoch argument precisely to avoid a constant). It would also change what "frozen" means for the risk register. It is **not part of this job**; design A leaves it open: the distributor can be abandoned later without touching depositors' shares.

## 14. Open questions for the operator

1. **The dead seed's slice.** Default implemented: the seed's weight stays in the denominator and its slice returns to the Safe (plain reading of "excluded from entitlement, their part stays with the Safe"). The alternative, removing the seed from the denominator, would pass that slice to depositors. Which?
2. **Contract-held shares.** Default: every holder with code at the end block is excluded and its slice returns to the Safe. Which contracts go on `--allow-contract` (the Ledger's Safe if it ever holds shares; a lending market that you want to pay and that can pass PHAR on)? Do you want a public list?
3. **The Ledger's 199 USDC holding** (the "rest" receiver): paid like any holder, or `--exclude`d?
4. **Hosting.** Where are `epoch.json` and `manifest.json` published (the operator hosts; a content-addressed store would make `dataHash` self-evident), who runs the second recompute, and how long are files kept (they must outlive the 180-day claim window)?
5. **Cadence.** Per harvest, per week, or when the PHAR in range exceeds a threshold? A minimum `--min-amount` (claim gas is about 90,000)?
6. **First epoch.** Default start block 100488395 (the `openBand` block). Confirm, and confirm `--scan-from` (the vault's deployment block, not recorded in this branch).
7. **`USER_BPS`.** Default 9000; per epoch. Is a change announced in advance? The disclosure text says 90 % by default.
8. **`--extra-phar`.** May the Safe add PHAR that is not a harvest (donations, PHAR of the CL vaults)? It is shown separately but nothing on chain distinguishes it.
9. **Sweep policy.** Swept PHAR goes back to the Safe; or is it rolled into the next epoch's `--extra-phar`?
10. **Windows.** 24 h review and 180 days claim window are the defaults; the Safe is 1-of-1, so the review window is the only independent check. Longer (48 h)? These are constructor arguments: fixed at deployment.
11. **Public endpoint.** The generator uses only the public endpoint; if it throttles or lacks historical state, may it use the operator's own archive endpoint (an environment-driven option that does not exist today)?

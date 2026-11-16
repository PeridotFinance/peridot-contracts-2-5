# PHAR distribution: the second recompute (fresh subagent, published inputs only)

Decision (operator, final): before an epoch is published on chain, its Merkle root is recomputed by a **fresh subagent** that receives **only the published inputs** below, never the operator's session, notes or the first run's cache. It reports `MATCH`, `MISMATCH` or `COULD NOT RECOMPUTE`. **Only a `MATCH` lets the Safe publish.** Anyone else (a depositor, a watcher) can run the same procedure after publication, during the 24 h window or later.

Paths are relative to `contracts/vault-dlmm/` of the repository. Design and trust model: `avalanche-dlmm-vault-rewards-distribution.md`; the weekly procedure that calls this one (step W6): `avalanche-dlmm-vault-rewards-ceremony.md`.

## 1. What is published with every epoch (the checklist)

The operator commits all of these in the epoch's commit (W5) **before** the subagent is started; the subagent receives the commit hash and nothing else from the operator.

| # | Published item | Where | What it is for |
| --- | --- | --- | --- |
| 1 | `epoch.json` | `epochs/<id>/epoch.json` (and the URI in `manifest.uri`) | the hashed data file: `inputs`, `totals`, `exclusions` (+ `listHash`), `codeChecks`, `checks`, `root`, the per-holder table, `leaves` with proofs. `dataHash = keccak256(bytes)` |
| 2 | `manifest.json` | `epochs/<id>/manifest.json` | epoch id, vault, start/end block and timestamps, `harvestTxHashes`, `harvestSum`, `extraPhar`, `pharTotal`, `userBps`, `publishTotal`, **`gitCommit` and `gitDirty` of the generator**, `exclusionListHash`, `dataHash`, `root`, `uri`, and the exact `publishEpochArguments` |
| 3 | the **input block range** | `manifest.startBlock` / `endBlock` (+ timestamps), `epoch.json inputs.scanFromBlock` | the epoch is the block range `(startBlock, endBlock]`; both are harvest blocks (the first epoch starts at 100488395); the scan starts at `scanFromBlock` (the vault's deployment block) |
| 4 | the **parameters** | `epoch.json inputs`: `userBps`, `extraPhar`, `minAmount`, `epochId`, `firstEpoch`, `previousEpochId` | what the generator was told |
| 5 | the **allowlist and the exclusions** | `epoch.json inputs.allowContracts`, `inputs.explicitExcludes`, `exclusions.list` (address, reason, weight, `returnedToSafe`) | the contracts allowed to claim (default none) and everyone excluded, with the reason |
| 6 | the **generator source at the recorded commit** | the repository at `manifest.gitCommit`: `tools/dlmm-rewards-root.mjs` | the code that produced the file. `gitDirty` must be `false` |
| 7 | the previous epoch's manifest | `epochs/<prev>/manifest.json` (every epoch after the first) | the start block and the continuity of epochs |
| 8 | the harvest transactions of the range | `manifest.harvestTxHashes` | each is a `PharHarvested` event of the vault; their `amount`s add up to `harvestSum` |
| 9 | the Safe transactions | `epochs/<id>/safe-txs.md`: the approve and the publish transaction hashes, later the cancel or sweep | after publication: the on-chain `EpochPublished` log must show the manifest's root, total, range and `dataHash` |
| 10 | this recompute's report | `epochs/<id>/recompute-report.md` | the subagent's verdict, committed with the epoch |

**Not published, not an input:** the operator's scan cache (the vault's logs and block timestamps; the recompute makes its own scan from an EMPTY cache), any private endpoint or key, the operator's notes. (Whether to publish the cache as evidence is an open question, rewards document section 14 item 12.)

**The generator needs a chain source.** It reads the vault's public events from the public Avalanche endpoint that is hard-wired into it (`https://api.avax.network/ext/bc/C/rpc`, 100-block `eth_getLogs` chunks; no key, no option, no environment variable). The subagent therefore needs outbound HTTPS to that endpoint and nothing else. If the endpoint throttles (HTTP 429) or does not serve what is needed, the verdict is `COULD NOT RECOMPUTE`, never `MATCH`.

**Deriving the generator command from the published inputs** (all values come from `epoch.json inputs`):

```
node tools/dlmm-rewards-root.mjs \
  --epoch-id <inputs.epochId> --scan-from <inputs.scanFromBlock> \
  [ if inputs.firstEpoch:  --first-epoch --start-block <inputs.startBlock>
    else:                  --previous-manifest epochs/<inputs.previousEpochId>/manifest.json ] \
  --to-harvest <the transaction hash in inputs.harvest.transactions whose block == inputs.endBlock> \
  --user-bps <inputs.userBps> --extra-phar <inputs.extraPhar> --min-amount <inputs.minAmount> \
  [ --allow-contract <A> for every A in inputs.allowContracts ] [ --exclude <E> for every E in inputs.explicitExcludes ] \
  --out-dir <a NEW empty directory> --cache-dir <a NEW empty directory>
```

ethers v5 is needed (the generator finds `../../dlmm-keeper/node_modules/ethers`, or `ETHERS_DIR`): `npm ci` in `dlmm-keeper/` once.

## 2. The prompt template for the fresh subagent

Start a NEW agent (no inherited context). Fill the `{{...}}` placeholders from the committed `manifest.json`. Give it **nothing else**: not the operator's generation log, not this session. Save its report text as `epochs/<id>/recompute-report.md`.

```
You are an independent verifier of one epoch of a PHAR token distribution. You work ONLY from the
published inputs named below. You must not trust, use or ask for anything the operator did when
generating the epoch (no logs, no caches, no notes). Your job is to recompute the epoch's Merkle
root and data file from public chain data and report whether it matches. A mismatch or an
inability to recompute is a normal, useful outcome: never round it up to a match.

PUBLISHED INPUTS (the only things you may rely on)
  repository:        {{REPO_URL}}   commit of the EPOCH FILES: {{EPOCH_COMMIT}}
  epoch folder:      contracts/vault-dlmm/epochs/{{EPOCH_ID}}/   (epoch.json, manifest.json)
  generator commit:  {{GIT_COMMIT_FROM_MANIFEST}}   (manifest.gitCommit; must have gitDirty=false)
  chain:             Avalanche C-chain 43114; vault {{VAULT}}; PHAR {{PHAR}}
  distributor:       {{DISTRIBUTOR}} (read-only use, step 7)
  chain source:      ONLY the public endpoint hard-wired into the generator. Do NOT use any other
                     RPC endpoint, key or account. If you cannot reach it, say so (step 8).

RULES
  - Work in a fresh empty directory. Never edit the generator or the published files.
  - Do not sign or send anything. Do not use any private key.
  - Never print an RPC URL or any secret.
  - If any step fails, stop and report COULD NOT RECOMPUTE with the reason. Do not improvise a fix.

STEPS
 1. Clone the repository and check out {{EPOCH_COMMIT}}. Read epochs/{{EPOCH_ID}}/manifest.json.
    Verify: manifest.gitDirty is false; manifest.gitCommit is {{GIT_COMMIT_FROM_MANIFEST}};
    manifest.rehearsalEndpoint is absent; manifest.epochId is {{EPOCH_ID}}.
    Verify keccak256(bytes of epoch.json) equals manifest.dataHash. (cast keccak 0x$(xxd -p
    epoch.json | tr -d '\n'), or ethers utils.keccak256.) Record the sha256 of epoch.json.
 2. Check out the GENERATOR at manifest.gitCommit into a separate worktree/directory
    (git worktree add <dir> <gitCommit>) and record sha256 of tools/dlmm-rewards-root.mjs there.
    Read the generator and the weighting rules (docs/deployment-handoffs/
    avalanche-dlmm-vault-rewards-distribution.md sections 1, 3 and 5) so that you can explain
    them. Run `npm ci` in dlmm-keeper/ if ethers v5 is missing.
 3. Build the command from epoch.json "inputs" (see the derivation table in
    docs/deployment-handoffs/avalanche-dlmm-rewards-second-recompute.md section 1). Use a NEW
    empty --out-dir and a NEW empty --cache-dir. Do not copy any cache. Run it from the generator
    directory. Record the exact command (without any URL) and the exit code.
 4. Compare the generated epoch.json with the published one BYTE FOR BYTE (cmp, sha256). Compare
    dataHash and root from the generated manifest with the published manifest. If the bytes
    differ, list the first differing JSON paths (a structural diff) and classify them: only
    codeChecks[].checkedAt differing (an endpoint that lacks historical state) is a
    DIFFERENT-ENVIRONMENT note, everything else is a MISMATCH.
 5. INDEPENDENT ARITHMETIC (do not reuse the generator's code): for the vault's dead seed
    0x000000000000000000000000000000000000dEaD, the largest paid holder, and one more holder of
    your choice, recompute weight = sum over the epoch's seconds of the holder's share balance
    from the vault's ERC-20 Transfer events and the block timestamps of the range
    (startBlock, endBlock]; the window is [timestamp(startBlock), timestamp(endBlock)]; an event
    in a block <= startBlock only builds the opening balance; same-block events in log order;
    scan from epoch.json inputs.scanFromBlock. Then check amount = floor(pool * weight /
    totalWeight) with pool = floor(pharTotal * userBps / 10000) against epoch.json holders[] and
    leaves[]. Report your three numbers next to the published ones.
 6. Check the exclusions: every address in epoch.json exclusions.list has the stated reason
    (dead-seed, vault, contract = code at the end block via eth_getCode, explicit), none of them
    has a leaf, and every holder with code at the end block that is not in inputs.allowContracts
    is excluded. Check that the harvest transactions in manifest.harvestTxHashes are
    PharHarvested events of the vault and that their amounts add up to inputs.harvest.sum.
 7. (If the distributor already shows the epoch.) cast call <DISTRIBUTOR> 'epochInfo(uint256)'
    {{EPOCH_ID}} (public endpoint is enough) and compare root, total, fromBlock, toBlock, dataHash
    with the manifest's publishEpochArguments. If the epoch is not published yet, write
    "not published yet" for this step: that is expected before the Safe publishes.
 8. If the endpoint refused or throttled (HTTP 429, "rate limit"), or did not serve historical
    code, or any command failed: the verdict is COULD NOT RECOMPUTE. Say which call failed. Do
    not switch to another provider.

REPORT FORMAT (plain text, exactly these lines, then free notes)
  RECOMPUTE REPORT epoch {{EPOCH_ID}}
  epoch commit: <hash>   generator commit: <hash>   gitDirty: <true|false>
  epoch.json sha256 (published): <hex>     (recomputed): <hex>      byte-identical: <yes|no>
  dataHash (published): <0x..>   (recomputed): <0x..>   equal: <yes|no>
  root (published): <0x..>       (recomputed): <0x..>   equal: <yes|no>
  independent weights: dead seed <published|mine>, largest holder <addr> <published|mine>, holder <addr> <published|mine>
  exclusions checked: <yes|no>    harvest events checked: <yes|no>    on-chain epochInfo: <equal|not published yet|DIFFERENT>
  command: <the exact generator command, no URL>
  VERDICT: MATCH | MISMATCH | COULD NOT RECOMPUTE
Rules for the verdict line: MATCH only if epoch.json is byte-identical (or differs ONLY in
codeChecks[].checkedAt, which you must then say), dataHash and root are equal, the independent
weights agree exactly, and the exclusions and harvest checks passed. Any difference in an amount,
a leaf, a holder, the root or the dataHash is MISMATCH. Anything you could not complete is COULD
NOT RECOMPUTE. When in doubt, do not write MATCH.
```

## 3. What the operator does with the verdict

| Verdict | Action |
| --- | --- |
| `MATCH` | commit the report as `epochs/<id>/recompute-report.md` (it is part of the epoch's published set), then W7 (approve) and W8 (publish) |
| `MISMATCH` | do **not** publish. Find the cause (a generator bug, an endpoint serving different data, a wrong parameter, a dirty generator). Fix on a clean commit, regenerate, commit a NEW epoch folder state (the old one is kept as evidence if it was ever pushed: do not rewrite history) and run a NEW fresh subagent |
| `COULD NOT RECOMPUTE` | do **not** publish. Repeat later (rate limit) or after fixing the missing input; a second `COULD NOT RECOMPUTE` for the same reason (for example the public endpoint lacks historical state) needs an operator decision (rewards document section 14 item 10); it is never treated as a match |

A recompute after publication (a depositor, a watcher, the next week's agent) follows the same steps; a `MISMATCH` found inside the 24 h window is the reason the Safe has `cancelEpoch`.

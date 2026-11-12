# Independent reproduction of the two Pharaoh vault fork suites

Purpose: re-run both existing suites (`contracts/test/AvalancheTrackAVaultsFork.t.sol`, 35 tests per vault) from a clean state against an archive RPC with an isolated cache and no proxy, and keep the full log of every attempt. Nothing was signed, broadcast or deployed; the suites only fork and `vm.prank`.

## Attempts

| Attempt | Vault | Log | UTC start | UTC end | Result |
| --- | --- | --- | --- | --- | --- |
| 1 | Pharaoh USDC vault (`AvalancheTrackAUsdcVaultForkTest`, pin block 99216397) | `attempt1-usdc.txt` | 2026-11-02 14:14:48 | 2026-11-02 15:11:06 | **35 passed, 0 failed, 0 skipped** (suite 3201.74 s; includes a first compile of 217 files) |
| 2 | Pharaoh WAVAX vault (`AvalancheTrackAWavaxVaultForkTest`, pin block 99216312) | `attempt2-wavax.txt` | 2026-11-02 15:11:16 | 2026-11-02 16:02:27 | **35 passed, 0 failed, 0 skipped** (suite 3058.18 s) |

There were 2 attempts in total and no failed or infrastructure-failed attempt: no HTTP 429, timeout or disk problem appeared in either log (free space on `/tmp` was 4.2 GiB at the start of attempt 1 and about 68 GiB at its end, because something other than this work freed space; it never fell below the 1.5 GiB limit) (the search for `429`, `rate limit`, `timed out`, `retry` and `-32002` only hits unrelated numbers in compiler warnings and logged values). Because of that, no attempt was discarded and no rerun was needed. First failing test: none.

## Environment and exact commands

- RPC: `https://api.avax.network/ext/bc/C/rpc` (public, no key in the URL, direct, no proxy, no cache-priming, no substituted or zero-filled values). Passed to the test as `AVALANCHE_MAINNET_RPC_URL`; the pin comes from `TRACKA_PIN_BLOCK`.
- Archive check, run before the attempts (probe repeated at 2026-11-02T16:03Z, chain head then 99232393): `cast block 99216397 -f hash` returns `0x883381b5...c9c65` and `cast block 99216312 -f hash` returns `0xc0f581b4...b6c57`, both equal to the hashes recorded in the report. `cast call <USDC vault> totalSupply()` at block 99216397 returns 29,850,429 (the supply the report records), `cast call <WAVAX vault> totalSupply()` at block 99216312 returns 1,723,597,814,184,121,992 (the same as in the earlier WAVAX log), and the same USDC call at block 99100000 (about 132,000 blocks before the head) also answers. So the endpoint served historical state for both pins far outside a 128-block window; I treat it as archive-capable for these blocks. It is not proof for every older block.
- Isolated cache: each attempt ran with `HOME` set to a fresh `mktemp -d` directory containing only an empty `.foundry/cache/rpc` and symlinks to the existing solc installs (`Library/Application Support/svm`, `.svm`), as in `contracts/tools/run-avalanche-clean-repro.sh`. Each log's last lines show the isolated home ended with one cache file (the pin block). The isolated homes were removed afterwards. The fork cache therefore started empty, and every storage read came from `api.avax.network`.
- Build output: `FOUNDRY_OUT=out_tracka_repro FOUNDRY_CACHE_PATH=cache_tracka_repro` (new, untracked directories under `contracts/`). Attempt 1 compiled from scratch (217 files with solc 0.8.35); attempt 2 reused that build and recompiled 4 files (the log does not say which; not investigated, possibly sources touched by the HEAD change described below).
- Profile and flags: `FOUNDRY_PROFILE=debt_accounting`, `--threads 1`, the same `--skip` set as the report's command, `--match-contract <suite> -vv`. **No `--gas-limit` flag was used**, because the report's command does not have one; the suites pass without it. The exact command is in the header of each log.
- Forge: `forge 1.7.1-Homebrew` (commit 4072e487, built 2026-05-08).
- Git: attempt 1 ran at HEAD `b3b34c63`, attempt 2 at HEAD `2e9d241a`. **HEAD moved between the two attempts** (another commit landed on the branch while attempt 1 was running). `git diff --stat b3b34c63 2e9d241a` touches neither `contracts/test/AvalancheTrackAVaultsFork.t.sol`, nor `contracts/test/helpers/AvalancheTrackAVaultsBase.sol`, nor `contracts/foundry.toml`; it changes margin/risk-engine contracts, other tests, tools and notes, none of which these suites call (they fork the deployed vaults). Both logs list the dirty working tree (`git status --short` of `contracts/`), which contains unrelated uncommitted edits (Robinhood files, Fuji runner tools); the vault suites do not depend on them.

## Comparison with the earlier logs (`../usdc-vault-suite-log.txt`, `../wavax-vault-suite-log.txt`)

After stripping the compile preamble and the run duration, the forge output from `Ran 35 tests` to the last line of each new log is **identical to the earlier log, line for line, including every logged amount and every per-test `gas:` figure**: USDC 395 lines against 395 lines, WAVAX 420 against 420, `diff` output empty apart from the suite duration (earlier runs 15.93 s and 15.53 s warm through the proxy; new runs 3201.74 s and 3058.18 s cold, directly against the public endpoint, with `--threads 1`). There is no count or number that differs. The earlier logs have no header (no command, time, RPC or environment); these new logs do.

## What the reproduction does and does not establish

Establishes: at the same two pinned blocks (99216397 USDC vault, 99216312 WAVAX vault) and the same suite code, running the suites again without the local proxy and with an empty cache gives the same 35 passes per vault and the same logged numbers as the earlier proxy-assisted runs. So the earlier numbers do not depend on the proxy or on cache contents.

Does not establish: behaviour at any other block; the correctness of the on-chain strategy beyond what the suites measure; that a "passed" test means the vault exit worked. The suites contain no assertion on the success of `redeem` or `redeemInKind` in the capacity ladder (`test_06_*`) or the stress tests (`test_07_*`); they log the outcome, and the test passes whether the redeem succeeded or reverted. The `testFinding_*` tests assert the unfavourable behaviour, so a pass there means the problem reproduced. Read the logged lines, not the pass count, for exit capacity.

# Isolated-cache reproduction at the final code checkpoint (commit 7c45de9f; later commits are scripts and documents only)

What these runs are, stated precisely: **isolated-cache runs populated across retries.** Each run used an isolated Foundry home that started EMPTY (no RPC cache from any earlier run, proxy or agent; only the solc binaries were linked in), `https://api.avax.network/ext/bc/C/rpc` directly, no proxy, no substituted or zero-filled value. Because the public endpoint rate-limits, the same isolated home was REUSED across the retries of one run, so a run that passed on attempt N read values that its earlier attempts had already fetched from the chain into that home. They are therefore not single cold runs. Tests only: nothing was signed or broadcast.

## Gate (section 5, funded fallback, funded sizing, cash-only lending, capacity matrix, generator fixtures, storage layout)
Driver: `tools/run-avalanche-clean-repro.sh` at the time of the run (the old version: it retried every non-zero exit and reused one output directory; see "What survives" below).

- Attempt 1: failed with public-RPC 429s (it overlapped with the first vault runs, which I started at the same time against the same endpoint: a scheduling mistake). Per-suite logs survive in `gate-attempt1-archived/` (copied before attempt 2 overwrote the directory).
- Attempt 2: failed (rate limits, from the progress lines). **Only the progress output survives** (in `gate-clean-repro.log`); the per-suite and per-test logs of attempt 2 were overwritten by attempt 3 and were not kept.
- **Attempt 3 passed:** section5 35/35, funded-fallback 40/40, funded-sizing 18/18, cash-only-lending 6/6, capacity matrix 31/31 (168 manifest + 64 fallback scenarios, 0 NOT-RUN, 0 conflicting records, 0 aggregate groups missing a variant), generator fixtures, storage layout. The regenerated matrix report is identical to the generated tables in `../avalanche-capacity-matrix.md`. `gate/` holds the logs of the passing attempt.

## Vault suites (Pharaoh USDC vault, Pharaoh WAVAX vault; 40 tests each since the in-kind assertions were added)
Driver: `tools/run-avalanche-vault-clean-repro.sh` (single attempt) called from a retry loop in a scratch launcher that is NOT in the repository (that loop retried every non-zero exit; it was replaced afterwards, see below). **Every vault attempt kept its own full log** (`vault-attempt<N>-<vault>.txt`; header = UTC time, git HEAD, git status, command).

| Attempts | Vault | Result | Cause |
| --- | --- | --- | --- |
| 1-2 | USDC | FAILED (4 and 7 of 40 passed) | HTTP 429 from the public RPC (a fresh empty home per attempt; attempt 1 also overlapped with the gate run) |
| 3-5 | USDC | FAILED (7 of 40) | HTTP 429 (same) |
| 6-8 | WAVAX | FAILED (7 of 40) | HTTP 429 (same) |
| 9-13 | USDC | NOT RUN (forge exit 2) | my script error: the throttling flags need `--rpc-url`; a usage error, no test executed |
| 14-17 | USDC | FAILED (13, 22, 33, 33 of 40) | RPC errors only: every failing test is a `database error` / 429 / `Max retries` (checked line by line; no assertion failed). One isolated home reused across these retries |
| **18** | **USDC** | **PASSED 40/40** | same isolated home |
| 19-22 | WAVAX | FAILED (13, 26, 33, 33 of 40) | RPC errors only (checked) |
| **23** | **WAVAX** | **PASSED 40/40** | same isolated home |

Pin blocks: 99216397 (USDC vault), 99216312 (WAVAX vault). `git diff 7c45de9f..HEAD -- contracts/contracts contracts/test` was empty for these runs, so the tests that passed are the final tests.

## What this establishes and does not
Both new 40-test suites pass from an isolated home that started empty, against the public endpoint directly, with their cache populated across retries by chain values. Failed attempts were infrastructure failures (rate limits) or my script error, not test results. It says nothing about other blocks. The in-kind thresholds are historical observations from earlier logs (two-holder caps back-fitted), see `avalanche-track-a-evidence/inkind/README.md`.

## Retry policy fixed afterwards (no new cold run was done to repair these descriptions)
The old wrappers retried every non-zero exit and reused output directories. Replaced by `tools/avalanche-repro-retry.sh` + `tools/avalanche-repro-classify.py`, used by `tools/run-avalanche-clean-repro.sh` and `tools/run-avalanche-vault-clean-repro-retry.sh`: only positively identified transient RPC infrastructure failures are retried; assertion failures, incomplete evidence and unidentified failures stop the run; each attempt gets its own directory with full logs and a `summary.tsv` line; an existing attempt directory is never reused. Regression tests with simulated outcomes: `tools/avalanche-repro-runner.test.sh` (also run by the gate).

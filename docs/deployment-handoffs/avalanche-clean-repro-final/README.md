# Isolated reproduction at the final code checkpoint (commit 7c9934f4 and later documents/scripts only)

Isolated empty Foundry home (empty RPC cache; solc only linked), `https://api.avax.network/ext/bc/C/rpc` directly, no proxy, no substituted values. Tests only.

## Gate (section 5 + funded fallback + funded sizing + cash-only lending + capacity matrix + generator fixtures + storage layout)
`tools/run-avalanche-clean-repro.sh`: `gate-clean-repro.log` is the full progress log of all attempts. **Attempt 1 and 2 failed (public-RPC 429 rate limits; attempt 1 overlapped with vault runs that I started at the same time against the same endpoint, which was a scheduling mistake); attempt 3 passed**: section5 35/35, funded-fallback 40/40, funded-sizing 18/18, cash-only-lending 6/6, capacity matrix 31/31 (168 manifest + 64 fallback scenarios, 0 NOT-RUN, 0 conflicting records, 0 aggregate groups missing a variant), generator fixtures, storage layout identical. The regenerated matrix report is identical to `../avalanche-capacity-matrix.md`'s generated tables. `gate/` holds the logs of the passing attempt; `gate-attempt1-archived/` holds the logs of the failed attempt 1 (the script overwrites its output directory on each retry, so attempt 2's per-suite logs were not kept; its progress lines are in `gate-clean-repro.log`).

## Vault suites (Pharaoh USDC vault, Pharaoh WAVAX vault; 40 tests each since the in-kind assertions were added)
`tools/run-avalanche-vault-clean-repro.sh`. Every attempt keeps its log (`vault-attempt<N>-<vault>.txt`, header = UTC time, git HEAD, git status, command). See the table below for results; an attempt that fails with HTTP 429 is an infrastructure failure, not a test result.

### Vault attempts (all logs kept; `vault-attempt<N>-<vault>.txt`)

| Attempts | Vault | Result | Cause |
| --- | --- | --- | --- |
| 1-2 | Pharaoh USDC vault | FAILED (4 and 7 of 40 passed) | HTTP 429 from the public RPC (a fresh empty home per attempt; attempt 1 also overlapped with the gate run) |
| 3-5 | Pharaoh USDC vault | FAILED (7 of 40) | HTTP 429 (same) |
| 6-8 | Pharaoh WAVAX vault | FAILED (7 of 40) | HTTP 429 (same) |
| 9-13 | Pharaoh USDC vault | NOT RUN (forge exit 2) | my script error: the throttling flags need `--rpc-url`; usage error, no test executed |
| 14-17 | Pharaoh USDC vault | FAILED (13, 22, 33, 33 of 40) | RPC errors only (every failing test is a `database error` / 429 / `Max retries`; checked line by line: no assertion failed). One isolated home reused across these retries, so each retry kept the values earlier attempts had fetched from the chain |
| **18** | **Pharaoh USDC vault** | **PASSED 40/40** | same isolated home |
| 19-22 | Pharaoh WAVAX vault | FAILED (13, 26, 33, 33 of 40) | RPC errors only (checked) |
| **23** | **Pharaoh WAVAX vault** | **PASSED 40/40** | same isolated home |

Pin blocks: 99216397 (USDC vault), 99216312 (WAVAX vault). Attempts 14-23 ran at the code checkpoint's descendants (git HEAD in each log header); `git diff 7c45de9f..HEAD -- contracts/contracts contracts/test` is empty, so the tests that passed are the final tests.

What this establishes and does not: both new 40-test suites pass from an isolated home that started empty, against `api.avax.network` directly, no proxy. The passing runs read RPC values that earlier failed attempts had already fetched from the same chain into that isolated home; none was substituted or zero-filled. Failed attempts are infrastructure failures (rate limits) or a script error, not test results. Nothing here says anything about blocks other than the two pins, and the thresholds in the in-kind assertions are derived from logged values (the two-holder caps were back-fitted after an earlier attempt, flagged in `avalanche-track-a-evidence/inkind/README.md`).

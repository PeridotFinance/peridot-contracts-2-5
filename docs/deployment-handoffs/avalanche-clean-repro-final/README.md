# Isolated reproduction at the final code checkpoint (commit 7c9934f4 and later documents/scripts only)

Isolated empty Foundry home (empty RPC cache; solc only linked), `https://api.avax.network/ext/bc/C/rpc` directly, no proxy, no substituted values. Tests only.

## Gate (section 5 + funded fallback + funded sizing + cash-only lending + capacity matrix + generator fixtures + storage layout)
`tools/run-avalanche-clean-repro.sh`: `gate-clean-repro.log` is the full progress log of all attempts. **Attempt 1 and 2 failed (public-RPC 429 rate limits; attempt 1 overlapped with vault runs that I started at the same time against the same endpoint, which was a scheduling mistake); attempt 3 passed**: section5 35/35, funded-fallback 40/40, funded-sizing 18/18, cash-only-lending 6/6, capacity matrix 31/31 (168 manifest + 64 fallback scenarios, 0 NOT-RUN, 0 conflicting records, 0 aggregate groups missing a variant), generator fixtures, storage layout identical. The regenerated matrix report is identical to `../avalanche-capacity-matrix.md`'s generated tables. `gate/` holds the logs of the passing attempt; `gate-attempt1-archived/` holds the logs of the failed attempt 1 (the script overwrites its output directory on each retry, so attempt 2's per-suite logs were not kept; its progress lines are in `gate-clean-repro.log`).

## Vault suites (Pharaoh USDC vault, Pharaoh WAVAX vault; 40 tests each since the in-kind assertions were added)
`tools/run-avalanche-vault-clean-repro.sh`. Every attempt keeps its log (`vault-attempt<N>-<vault>.txt`, header = UTC time, git HEAD, git status, command). See the table below for results; an attempt that fails with HTTP 429 is an infrastructure failure, not a test result.

# Isolated-cache reproduction of the 52-test Pharaoh vault suites (commit 401e9b00)

Both suites (Pharaoh USDC vault at pin 99216397, Pharaoh WAVAX vault at pin 99216312; 52 tests each: the 40-test gate suite plus the F-IK-2 ledger tests 18-23) were run with the transient-only retry driver (`tools/run-avalanche-vault-clean-repro-retry.sh`; classification in `tools/avalanche-repro-classify.py`) against `https://api.avax.network/ext/bc/C/rpc` directly, no proxy, in an isolated Foundry home that started empty. As in the earlier runs, the home is reused across the retries of one run: these are **isolated-cache runs populated across retries**, not single cold runs.

| Vault | Attempt | Class (by the driver) | Result |
| --- | --- | --- | --- |
| USDC | 1 | TRANSIENT (58 failures, all RPC `database error` / rate limit) | not a result; retried |
| USDC | 2 | TRANSIENT (38 failures, all RPC errors) | not a result; retried |
| USDC | 3 | PASS | **52 passed, 0 failed** |
| WAVAX | 1 | TRANSIENT (26 failures, all RPC errors) | not a result; retried |
| WAVAX | 2 | PASS | **52 passed, 0 failed** |

Every attempt has its own directory (`<vault>/attempt<N>/`: `vault.txt` = full forge log with header, `run.log`) and a line in `<vault>/summary.tsv`; nothing was overwritten or deleted. The driver stopped at the first pass and would have stopped at once on an assertion failure, incomplete evidence or an unidentified failure (none occurred).

Establishes: the 52 tests pass at the two pinned blocks from an isolated, initially empty cache against the public endpoint. Does not establish: behaviour at other blocks; that any gate passes (the tests assert accounting identities and in-kind outcomes; the diagnostics, including the F-IK-2 ledger, are not gates); fairness of deposits (the ledger explains the cause for the scenarios run and shows the deployed code failing the proposed incumbent limit, see `../avalanche-vault-entry-fairness.md`).

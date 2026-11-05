# Cold single-run reproduction of the new suites (git 6c584f6d)

Each attempt ran in a **fresh, empty** isolated Foundry home (no RPC cache from any earlier attempt, run, proxy or agent; the home is deleted afterwards), against `https://api.avax.network/ext/bc/C/rpc` directly, no proxy. A home populated across retries is NOT used: `tools/run-avalanche-suite-cold.sh` creates a new home for every attempt (regression-tested in `tools/avalanche-repro-runner.test.sh`: three attempts, three distinct homes, all empty at start, all removed). A retry happens only for a positively identified transient RPC failure; anything else stops the run. Every attempt has its own directory with the full forge log (`suite.txt`, header = UTC time, git HEAD, command, empty-cache statement) and a `summary.tsv` line.

| Suite | Contract | Tests | Attempts | Result (single cold run) |
| --- | --- | --- | --- | --- |
| Outage | `AvalancheCashOnlyPilotOutageForkTest` | 4 | 1 | **PASS 4/4** (attempt 1) |
| Reward-token independence | `AvalancheCashOnlyRewardTokenIndependenceForkTest` | 3 | 1 | **PASS 3/3** (attempt 1) |
| Treasury repayment | `AvalancheCashOnlyTreasuryRepayForkTest` | 14 | 1 | **PASS 14/14** (attempt 1) |
| Liquidation cycle | `AvalancheCashOnlyLiquidationCycleForkTest` | 8 | 1 | **PASS 8/8** (attempt 1) |
| Routes | `AvalancheWavaxUsdcRoutesForkTest` | 38 | 6 at the standard pacing (client limit 10 compute units/s, backoff 2 s) | **NOT REPRODUCED from one cold run at that pacing**: all six attempts stopped by Cloudflare HTTP 429 rate limits (error code 1015); attempt 1 passed 12/38, attempts 2-6 each passed 26/38 and failed 12 with the same cause; the driver exhausted its attempts (exit 11) |

The four passing suites read little state at the pinned block and completed in seconds from an empty cache (the isolated home was verified to be populated during the run). The routes suite reads several DEX pools cold and exceeds what the public endpoint serves at that request rate. A slower-paced set of attempts (`routes-slow/`, client limit 2 compute units/s, backoff 5 s) is recorded below if it completed.

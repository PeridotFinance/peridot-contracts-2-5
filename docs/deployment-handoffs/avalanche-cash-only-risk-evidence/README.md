# Evidence log: cash-only lending risk study

Suite: `contracts/test/AvalancheCashOnlyRiskStudyFork.t.sol` (`AvalancheCashOnlyRiskStudyForkTest`, 18 tests). Every file starts with a header: UTC time, git HEAD, exact command. Tests only: nothing signed or broadcast, no keys. `AvalancheBorrowFloorMarginFork.t.sol` is skipped in every command (another agent's file under edit, not part of this suite). Compile-only failures (stack-too-deep in the first version of two helpers, one type error) produced no test run and are not kept.

Final test file sha256 (untracked file, so the git HEAD in the headers does not pin it): `120b80911624627999eafd48d1ed931e53db6326eaae0dcf805d501e026bf30b`.

| File | Code state | Result | Notes |
| --- | --- | --- | --- |
| `attempt01-smoke.txt` | first complete version, 2 tests (monitoring, ratio equivalence) | 2/2 passed | smoke test of the harness |
| `attempt02-full.txt` | all tests, grid of 11 collateral-factor values split in 6 gap tests | 14 passed, 2 failed | failures were test bugs, not findings: the rate-model test created its rate models after the snapshot (reverted away), the gas test skipped the liquidator approval in one mode |
| `attempt03-gas-rates.txt` | both bugs fixed | 2/2 passed | gas and rate-model tests |
| `attempt04-full-FAILED-closed-form-healthy-band.txt` | grid widened to CF 85/90% and more path cells | 17 passed, 1 failed | the closed-form cross-check did not model an account that is still healthy when CF x LI > 1 (CF 90%, LI 1.15, 70% utilisation); the measurement was right, the prediction function was fixed |
| `attempt05-full.txt` | prediction fixed | 18/18 passed | all `RISK|` data used for the tables in the proposal |
| `attempt06-resfirst-RPC-FAILED-fork-instantiate.txt` | on-behalf-repayment block added to `testRisk_ReserveFirst_ExitIdentity` | not run | public RPC refused the fork (HTTP 429) |
| `attempt07-resfirst.txt` | same | 1/1 passed | `testRisk_ReserveFirst_ExitIdentity` with the new block |
| `attempt08`, `attempt09`, `attempt11` | final code | not run | fork instantiation refused, HTTP 429 (shared public endpoint) |
| `attempt10-RPC-429-FAILED-mid-run.txt` | final code | 0 passed (one suite-level failure) | account fetch failed with HTTP 429 mid-run |
| **`attempt12-final-full.txt`** | **final code** | **18/18 passed** | **evidence of record**; its `RISK|CELL` lines are identical to attempt05 |

`analysis/*.py` read a log and print the tables used in `docs/deployment-handoffs/avalanche-cash-only-risk-proposal.md`, e.g. `python3 analysis/safe-region.py attempt12-final-full.txt`.

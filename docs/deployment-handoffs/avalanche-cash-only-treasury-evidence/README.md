# Evidence log: cash-only lending, treasury repayment (`repayBorrowBehalf`) at pilot scale

Suite: `contracts/test/AvalancheCashOnlyTreasuryRepayFork.t.sol` (`AvalancheCashOnlyTreasuryRepayForkTest`, 14 tests, includes the TEST-ONLY `TreasuryDefaultDetector`). Doc: `../avalanche-cash-only-treasury-repayment.md`. Every log starts with a header: UTC time, git HEAD (the test file is untracked, so HEAD does not pin it: use the test-file sha256 in each header), the exact command, a note. Failed attempts are kept. Tests only: nothing signed or broadcast, no keys, `contracts/contracts/` untouched, no treasury funds committed. `AvalancheBorrowFloorMarginFork.t.sol` (another agent's file) is skipped in every command.

Build note: `FOUNDRY_OUT=out_treasury FOUNDRY_CACHE_PATH=cache_treasury` started as a copy of the loss-handling build directories (`out_loss`, `cache_loss`); a first from-scratch `forge build` was stopped after 21 minutes, the copy's incremental build still recompiled 146 files (3,029 s of solc) once; later builds compiled 1 file. Profile `debt_accounting`. RPC `https://api.avax.network/ext/bc/C/rpc` (no HTTP 429 occurred; the publicnode fallback was not needed).

Final test-file sha256 (attempt10 and the final mutation runs): `238286838b09e2faf5f49f306b7069829c468411a4a852ec22a885f7fef8d517`.

| Log | Code state | Result | Notes |
| --- | --- | --- | --- |
| `attempt01-FAILED-runner-quoting-error.txt` | first smoke | runner shell error, nothing ran | my script did not quote the regex in `--match-test` |
| `attempt02-smoke-FAILED-3-of-5-...txt` | detector, roles, gift, front-run tests | 2 passed, 3 failed | test bugs: `assertGt(snapshotId, 0)` (the first snapshot id is 0); the extra healthy account could not borrow because cash sat exactly at the 20% floor (floor lowered for that account in test setup only) |
| `attempt03-smoke-FAILED-1-of-6-...txt` | + mitigations | 5 passed, 1 failed | test bug: the gift test repaid 1,000 USDC on a debt of 833 (over-repay reverts, which is itself asserted elsewhere) |
| `attempt04-smoke-truthtable-roles.txt` | smoke | 6/6 | truth table, manipulated oracle, roles, gift, front-run, mitigations |
| `attempt05-matrix-FAILED-reserves-...txt` | first matrix run | 2 failed | FINDING: `repayBorrowBehalf` changes pUSDC `totalReserves` by 2 wei (shares-accounting reconcile); strict equality relaxed to 8 wei. The filter also matched Cap10000 by prefix |
| `attempt06-NO-TESTS-RAN-...txt` | | no tests found | forge's `--match-test` did not accept my `$` anchor; tests renamed `Cap01000/Cap05000` |
| `attempt07-matrix-PW40-cap01000.txt` | one matrix test | 1/1 | timing run (4 s for 3 tails x 19 states x 24 orders) |
| `attempt08-full-13-tests-superseded.txt` | 13 tests | 13/13 | superseded by the 14-test suite |
| `attempt09-late-funding-test.txt` | added `testLateFunding_...` | 1/1 | |
| **`attempt10-final-full.txt`** | **14 tests** | **14/14** | **evidence of record**; all `TRP\|` data in the doc come from it |
| `mutation-M1-detector-fires-on-shortfall-alone.txt` | `TREASURY_MUTATION=1` | 3 of 14 fail | truth table, manipulated-oracle test, runbook gating |
| `mutation-M2-repay-applied-to-wrong-account.txt` | `TREASURY_MUTATION=2` | 10 of 14 fail | six matrix tests, truth table, runbook gating, mitigations, late funding |
| `mutation-M*-vs-13-tests-earlier-sha.txt` | same mutations, 13-test suite | M1 3 fail, M2 9 fail | |

The mutation hook is an environment variable read by the test file's own logic (default 0); no file was edited and restored.

`analysis/tables.py LOG [base|evt|dly|fund|truth|window|sup|compact|orders|orders_all|all]` renders the `TRP|` lines. `tables/` holds the generated tables used in the doc: `supplier-outcomes-compact.md` (per candidate), `supplier-outcomes-per-cap.md` (per cap and candidate), `all-24-orders-every-state.md` (every withdrawal order of every state), `headline-24-orders-PW40-cap10000-gap75.md`, `fund.md`, `dly.md`, `window.md`, `evt.md`, `base.md`, `truth.md`.

Line types: `TRP|BASE` (fixture, accrual), `TRP|EVT` (gap, liquidation, loss, closed form), `TRP|DLY` (debt, phantom interest, reserves, cash, claims, APR, utilisation per delay), `TRP|FND` (budget, paid, accounts repaid in full / partially, unpaid), `TRP|ORD` (shortfall of A/B/C/D for one order), `TRP|TAB`/`TAB2` (aggregate over the 24 orders), `TRP|TRUTH`, `TRP|MANIP`, `TRP|MIT`, `TRP|FRONTRUN`. Amounts are raw USDC units (6 decimals).

Working-tree note: the tree also contains other agents' untracked files (`contracts/test/AvalancheCashOnlyLiquidationCycleFork.t.sol`, `contracts/test/AvalancheWavaxUsdcRoutesFork.t.sol`, `contracts/test/helpers/AvalancheWavaxUsdcRoutes.sol`, `docs/deployment-handoffs/avalanche-cash-only-cycle-evidence/`). They were compiled together with this suite's build but not run, not edited. Future runs should reuse `contracts/out_treasury` and `contracts/cache_treasury` (about 660 MB; untracked) instead of building from scratch.

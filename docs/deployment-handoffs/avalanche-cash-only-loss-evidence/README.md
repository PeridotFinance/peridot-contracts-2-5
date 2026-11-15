# Evidence log: cash-only lending loss handling

Suite: `contracts/test/AvalancheCashOnlyLossHandlingFork.t.sol` (`AvalancheCashOnlyLossHandlingForkTest`, 32 tests) and the TEST-ONLY prototype `contracts/test/prototype/PErc20DelegateLossPrototype.sol`. Every log starts with a header: UTC time, git HEAD (it moved during the work because other agents committed; the test files are untracked, so the HEAD does not pin them: use the hashes below), exact command. Tests only: nothing signed or broadcast, no keys; `contracts/contracts/` untouched. `AvalancheBorrowFloorMarginFork.t.sol` is skipped in every command (another agent's file). Profile `debt_accounting`, `FOUNDRY_OUT=out_loss`, `FOUNDRY_CACHE_PATH=cache_loss`.

Final file sha256: test `a1c741a107f9846d3251090bd5828c944fa6ce4608148ec71c67c1f9058c6846`, prototype `b19c9d394997dd3a47e9cb0d08f6b8cff40680a5a67ab45c2015434fda21bfd8` (the prototype hash is the restored, unmutated file).

| File | Code state | Result | Notes |
| --- | --- | --- | --- |
| `attempt01-smoke-event.txt` | event test only (legacy-accounting prototype) | 1/1 passed | harness smoke test |
| `attempt02-full-FAILED-8-pass-22-fail-fixture-uses-shares-accounting.txt` | first full run | 8 passed, 22 failed | FINDING: the fixture's markets use shares borrow accounting; the first prototype refused it (its own revert). Not a test bug; the prototype was rewritten |
| `attempt03-COMPILE-FAILED-prototype-file-damaged-by-my-edit.txt` | edit script matched the interface instead of the contract | compile error | my scripting error, file rewritten |
| `attempt04-full-FAILED-15-pass-14-fail-test-and-prototype-bugs.txt` | shares-accounting prototype | 15 passed, 14 failed | prototype left the legacy snapshot non-zero after a write-off (`BorrowAccountingMissingBorrower`); two test expectations wrong (cash left when reserves exceed the loss, cap amounts larger than the account's debt) |
| `attempt05-full-FAILED-25-pass-4-fail-test-bugs.txt` | prototype fixed | 25 passed, 4 failed | test bugs: rate tolerance computed after all suppliers left (division by zero), leftover assertion, a cash comparison that ignored that S3 consumes reserves |
| `attempt06-full-FAILED-28-pass-1-fail-rounding-tolerance.txt` | tests fixed | 28 passed, 1 failed | rounding: sequential exits differ by 2 wei between orders; tolerance set to 4 wei |
| `attempt07-full.txt` | 29 tests | 29/29 passed | basis of the mutation runs |
| `mutation-M*.txt` | prototype with one mutation each | see below | the prototype file was restored afterwards (`cmp` against the saved copy) |
| `attempt08-full-FAILED-29-pass-1-fail-new-accrual-test-assertion.txt` | added the accrual-first test after M4 survived | 29 passed, 1 failed | wrong assertion on reserves in the new test (the reserves were absorbed in the same call) |
| `attempt09-full.txt`, `attempt10-final-full.txt` | 30 tests | 30/30 passed | |
| `attempt11-final-full.txt` | 32 tests (adds two timing tests) | 32/32 passed | identical `LOSS|` data to attempt12 |
| **`attempt12-final-full.txt`** | **32 tests, after a test rename and a comment fix** | **32/32 passed** | **evidence of record**; all `LOSS|` data in the doc come from it |
| `storage-layout-comparison.txt` | `forge inspect storageLayout` | label/slot/offset identical, 23 entries | |

Mutations (applied to the prototype, full suite run each time):
| Log | Mutation | Failing tests |
| --- | --- | --- |
| `mutation-M1_reserves_not_reduced.txt` | reserves not reduced | 6 of 29 |
| `mutation-M2_suppliers_first.txt` | `fromReserves = 0` | 6 of 29 |
| `mutation-M3_precondition_removed.txt` | precondition removed | 2 of 29 |
| `mutation-M4_accrue_removed-SURVIVED-against-29-tests.txt` | no `accrueInterest` | **0: survived** the 29-test suite |
| `mutation-M4_accrue_removed-vs-30-tests.txt` | same, after adding `testS3_AccruesInterestFirst_WriteOffUsesTheCurrentDebt` | 1 of 30 |
| `mutation-M5_caps_removed.txt` | per-call and per-period caps removed | 3 of 29 |
| `mutation-M6_admin_check_removed.txt` | admin check removed | 1 of 29 |

`analysis/tables.py LOG [group-prefix]` renders the `LOSS|ROW/EXIT/SUM` lines as the tables of the doc, e.g. `python3 analysis/tables.py attempt12-final-full.txt X_R0_`.

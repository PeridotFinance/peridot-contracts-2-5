# Borrow accounting rounding regression — 2026-09-15

Update: a [local remediation candidate](borrow-accounting-fix.md) now exists. The findings below describe legacy behavior, which remains deployed. The unit reproduction explicitly selects the legacy mode; separate tests exercise the fixed mode. No live upgrade has occurred.

## Outcome

The observed 8-raw-unit mockAVAX residue is reproducible, but the accounting mismatch is not exclusively harmless positive dust. Independent rounding of aggregate borrows and the borrower index can also make an individual account owe **more** than the market records. A healthy 2x position then cannot fully close in the pinned Fuji fork because repayment subtracts the account repayment from the smaller aggregate and reverts.

No production contracts, deployed settings, wallets or chain state were changed. The new tests characterize current behavior; a passing reproduction of a revert is **not** evidence that the underlying bug is fixed.

## Reproductions

| Case | Result |
| --- | --- |
| Replay the actual short close from Fuji block 58345305 at block 58345307 | Account debt becomes zero; aggregate mockAVAX debt remains exactly 8 raw units. |
| 32 long plus 32 short cycles at 2x, with interest before each close | All 64 closes and final pToken withdrawal succeed; aggregate mockAVAX residue grows from 8 to 150 raw units. |
| Same 64 cycles at a local-only 5x candidate configuration | All closes and final pToken withdrawal succeed; residue grows from 8 to 719 raw units. |
| Healthy 2x long, six-decimal mockUSD debt, 64 separate one-block accrual calls | Account debt is 98,019,805 raw; aggregate borrows are 98,019,801 raw. Full close reverts with arithmetic panic `0x11`; debt and locked collateral remain unchanged by the reverted transaction. |
| Deterministic local market, 64 eighteen-decimal borrow/repay cycles | 359 raw units of residue, with zero borrower debt after each repayment. |
| Deterministic six-decimal market, one accrual per borrow/repay cycle | Zero residue in the selected 64-cycle scenario. This does not cover frequent intra-position accrual. |
| Deterministic six-decimal market, 32 one-block accrual calls on a 100-token loan | Account debt exceeds aggregate by 2 raw units; full repayment reverts. |
| Last supplier redeeming all shares in a single-supplier, zero-reserve local fixture | Positive aggregate residue contributes to the exchange-rate claim without matching cash; full underlying redemption can revert for insufficient cash. In-kind pToken transfer still succeeds. |

The four-raw-unit close discrepancy is only 0.000004 mockUSD, but its size does not prevent a transaction-wide revert. These tests do not show that the user's already-closed positions are stuck. Those live positions and the wallet withdrawal remain completed.

## Cause and scope

`PToken.accrueInterest()` truncates aggregate interest on every accrual and independently truncates the index increment. `borrowBalanceStoredInternal()` applies that index to the account's original principal. Frequent small accruals can therefore lose aggregate fractions while the account accumulates enough indexed interest to round up by whole raw units. `repayBorrowFresh()` subtracts actual repayment from `totalBorrows` without reconciling the mismatch.

Positive residue is also included in `exchangeRateStoredInternal()` as an asset. The tests reproduce both the slight exchange-rate overstatement and, in a deliberately single-supplier zero-reserve fixture, a final cash-redemption shortfall. This is not a claim that every live supplier redemption fails.

The core reproduction uses real `PErc20Delegator`/`PErc20Delegate` accounting with a deterministic test-only rate model and permissive controller. The fork reproductions use existing migrated Fuji contracts at block **58388595**, without replacing bytecode or injecting storage. Only the fork's 5x scenario changes risk settings through their timelock in the local VM (20% initial, 10% maintenance); the actual deployed cap remains untouched at 2x.

## Files and verification

- `test/BorrowRoundingRegression.t.sol`: nine unit/characterization tests, including a 1,024-case fuzz property for a bounded single-borrower, single-accrual rounding calculation, plus a simultaneous-borrower preservation test.
- `test/FujiMockBorrowRoundingFork.t.sol`: four pinned real-code fork tests, including 128 total successful multi-block 2x/5x margin round trips and the failing-close reproduction.

Final verification: all 13 new tests passed, including the explicit expected-failure reproductions. Broad local rerun: 374 passed, zero failed, one unrelated `RedeemSimulation` setup skipped. All Fuji mock fork suites: 65 passed, zero failed/skipped. Eleven fuzz properties across those runs each executed 1,024 cases; the five existing fee invariants retained 128 runs at depth 128. The broad run retains the existing missing-LayerZero exclusions and excludes external Monad `YieldAccrualTest`; it is not an unfiltered whole-repository pass. Scoped formatting and whitespace checks passed. No external security scan, commit or push was performed.

Run from `contracts`:

```sh
FUJI_MOCK_FORK_RPC_URL=https://api.avax-test.network/ext/bc/C/rpc \
forge test --threads 1 --fuzz-runs 1024 \
  --match-contract '^(BorrowRoundingRegressionTest|FujiMockBorrowRoundingForkTest)$' \
  --skip P_OFTAdapter.sol \
  --skip P_OFTAdapterUpgradeable.sol \
  --skip P_OFTAdapterUpgradeable.t.sol -vv
```

Test clock advancement uses `vm.getBlockNumber()` rather than a cached `block.number` expression: the optimizer may rematerialize the latter across `vm.roll`. The multi-call withdrawal uses `startPrank` so a getter does not consume a one-call impersonation.

## Required next decision

Review and remediate lending-market accounting before expanding live leverage tests. A fix must preserve other borrowers' real debt, repay/close atomicity, reserves and supplier claims, and existing proxy storage/upgrade compatibility. Simply clearing aggregate borrows whenever one account reaches zero would erase other borrowers' debt; blindly clamping subtraction would not resolve the full accounting problem. No such fix, upgrade, pause, or live risk change is authorized by these regression tests.

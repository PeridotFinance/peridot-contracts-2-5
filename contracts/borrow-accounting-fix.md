# Borrow-accounting remediation candidate

Status: implementation committed and pushed as `944e670abea57a2454cd9a64511d826b41da03c7`; Almanax exact-diff scan `6636be8d-67e8-4f9d-bc8d-201e3e3caa88` completed with zero findings. **Not deployed and not an authorization to upgrade.** The deployed Fuji markets still use legacy accounting until a separately approved migration. The subsequently added [Fuji operator package](fuji-borrow-accounting-migration.md) requires its own review/scan and transaction approvals.

## Accounting changes

The [regression findings](borrow-rounding-regression-notes.md) showed two failures: positive aggregate residue after repayment, and negative aggregate/account divergence that could revert a healthy margin close.

The new mode records each borrower's normalized debt units and their sum in a dedicated ERC-7201 namespace. Existing linear storage fields, including the underlying token, implementation, collateral balances and historical borrow snapshots, retain their positions.

For scale `S = 1e36`, index `I`, and a whole-unit account balance `B`:

```text
account units at checkpoint = ceil(B × S / I)
account debt                = floor(account units × I / S)
aggregate borrows           = floor(sum of units × I / S)
```

An index limit of `I <= S` makes the checkpoint round trip preserve the integer account balance exactly. Checked arithmetic and full-precision `mulDiv` reject out-of-range inputs rather than wrap. The account and aggregate use the same growing index. With `n` accounts, the difference between the aggregate and the sum of rounded account debts is at most `n − 1` raw units; it cannot cause aggregate-subtraction underflow because repayment replaces only that borrower's units and recalculates the aggregate. Once all accounts are repaid, both total units and aggregate borrows are exactly zero.

The cash received on repayment remains authoritative, including fee-on-transfer tokens. Overpayments still revert atomically. A borrower's full repayment does not zero other borrowers' debt. Borrow rates, price feeds, lending collateral factors and margin leverage/liquidation settings are unchanged.

### Reserves and supply claims

Accrued interest is derived from the new aggregate minus its previous value; the configured reserve factor applies to that interest. Checkpointing a rounded account balance can discard a fractional receivable. Reserves absorb the resulting write-down first; any uncovered remainder reduces supplier assets rather than inventing cash. Upward rounding adjustments accrue to reserves, not instant supplier yield. Migration uses the same explicit reconciliation policy and an operator-approved absolute adjustment limit.

Tests cover zero and 100% reserve factors, randomized reserve factors, multiple borrowers, actual cash movements, all-debt repayment and the last supplier's underlying redemption. This is not a promise that every arbitrary price/liquidity scenario allows redemption.

## Source organization and build requirements

- `contracts/PToken.sol`: new-mode integration and the retained pre-migration legacy path.
- `contracts/BorrowAccounting.sol`: namespace, mode flag, aggregate units and per-account units.
- `contracts/BorrowAccountingModule.sol`: immutable helper deployed by each implementation's constructor. Only the namespace is written through delegatecall; aggregate/reserve results are written by `PToken`. Its target cannot be changed by an admin setter. Direct calls to its state-changing methods are rejected; pure math methods are intentionally public.
- `contracts/PErc20Delegate.sol`: optional atomic migration payload in the existing admin-only implementation hook. Empty data retains the old hook behavior.

Use the **`debt_accounting` Foundry profile** for release-candidate builds:

```sh
FOUNDRY_PROFILE=debt_accounting forge build \
  --skip P_OFTAdapter.sol \
  --skip P_OFTAdapterUpgradeable.sol \
  --skip P_OFTAdapterUpgradeable.t.sol
```

The profile pins Solidity 0.8.35, Cancun, IR and optimizer runs 1. Default builds are deliberately unchanged. Default optimizer runs 200 makes Robinhood's modified delegate too large for EIP-170; do not use that build for its deployment. Release runtime sizes checked independently against the 24,576-byte limit:

| Delegate | Runtime bytes |
| --- | ---: |
| PErc20Delegate | 18,199 |
| MagmaBoostedDelegate | 22,239 |
| RobinhoodBoostedDelegate | 24,521 |
| PharaohBoostedDelegate | 19,305 |

Robinhood has only 55 bytes of headroom, so the release-size test must stay mandatory for subsequent edits. Morpho is **not a deployment target of this package**: it is 25,908 bytes under this profile; the previous default-profile build was already oversized at 24,995 bytes. Its size remediation and deployment require separate work. A green local Foundry deployment test alone does not prove EIP-170 compliance.

The helper adds internal deployment and call gas. Existing deployment artifacts and previously approved payloads must not be reused for this code. Do not reset or roll back an activated market to a legacy implementation; the normalized state must be preserved by future implementations.

## Existing-market migration requirements

New markets enable the fixed mode during initialization. Existing markets retain legacy behavior until `activateBorrowAccounting(borrowers, expectedTotalBorrows, maxRoundingAdjustment)` succeeds. This is a deliberate opt-in, not a silent interpretation change on upgrade.

For plain lending delegates, `_setImplementation(newDelegate, false, abi.encode(borrowers, expectedTotal, maxAdjustment))` performs the implementation upgrade and migration atomically. Any failed check rolls the transaction back, including the implementation pointer. Boosted delegates override their implementation hooks and require a separately reviewed activation sequence; their own hook data must not be replaced with this plain-market tuple.

Before any broadcast:

1. Reconstruct the **complete set of active borrowers** from historical `Borrow` events and fresh account balances. Sort ascending, remove duplicates and exclude zero-debt accounts. Review the set against controller/margin records and reconcile totals.
2. Review the precise legacy aggregate/account discrepancy and the reserve/supplier effect. Set the smallest justified adjustment limit, not an arbitrary large allowance.
3. Use a fresh, controlled upgrade snapshot. `expectedTotalBorrows` is checked **after legacy interest accrual**. An active market can change between an off-chain simulation and inclusion; a suitable atomic admin/coordinator workflow is necessary rather than assuming an old expected value is still valid. Large borrower sets may exceed a single transaction's gas budget and are not covered by this migration procedure.
4. Verify the new implementation and its constructor-deployed helper, code size, immutable binding, storage layout and proxy admin. Review pausing/coordination separately. Run the actual market migration and exit tests before seeking broadcast approval.
5. After activation, independently verify every account debt, total units/borrows, reserves, supply exchange rate, custody balances and permissions.

**On-chain limitation:** the legacy borrow mapping cannot prove that an admin-supplied list is complete. The adjustment cap is only a guard, not a completeness proof. An omitted nonzero legacy account reverts with `BorrowAccountingMissingBorrower`; it is never reported as debt-free, but it would require remediation. The tests deliberately demonstrate this operator obligation. No automatic live migration script is provided in this change.

## Tests and remaining gates

Final local verification (2026-09-16, pinned release profile): **465 unique tests passed**, zero failed. This comprises 387 local tests, 74 Fuji mock/migration fork tests, three real-Fuji lending/LFJ fork tests and one pinned Pharaoh fork test. One unrelated `RedeemSimulation` setup was skipped; missing LayerZero dependencies and external Monad `YieldAccrualTest` retain their documented exclusions. Thirteen fuzz properties ran 1,024 cases each; five existing fee-accounting invariants ran 128 sequences at depth 128 with zero handler reverts. Recursive compiler storage-layout comparisons matched all fields/types/offsets for the base, Magma, Morpho, Robinhood and Pharaoh delegates. Release-size, proxy/delegate selector compatibility, scoped formatting, whitespace and high-severity lint checks passed. Morpho's size exclusion above remains a real deployment blocker despite its passing functional tests.

`BorrowRoundingRegression.t.sol` retains historical reproductions by selecting the legacy mode in its test fixture only. `FujiMockBorrowRoundingFork.t.sol` continues to test deployed legacy code without substituting bytecode.

`BorrowAccountingFix.t.sol` tests the fixed path, randomized four-borrower lifecycles at both decimal scales, fee-on-transfer repayment, partial/full repayments, reserves, final supply redemption, migration guards and helper access. `FujiBorrowAccountingFixFork.t.sol` uses real local proxy upgrades, preserves existing debt/custody, closes the formerly underflowing position and reuses the 24 opening-cost/liquidation-boundary flows through 5x. `BorrowAccountingReleaseSize.t.sol` enforces the scoped release-size limits.

Run local tests and then forks with the release profile, retaining the documented existing dependency exclusions. The fork RPC is read-only; risk changes and upgrades in the tests happen only in the local VM.

```sh
FOUNDRY_PROFILE=debt_accounting \
FUJI_MOCK_FORK_RPC_URL=https://api.avax-test.network/ext/bc/C/rpc \
forge test --threads 1 --fuzz-runs 1024 \
  --match-contract '(BorrowAccounting.*Test|FujiBorrowAccounting.*ForkTest)' \
  --skip P_OFTAdapter.sol \
  --skip P_OFTAdapterUpgradeable.sol \
  --skip P_OFTAdapterUpgradeable.t.sol
```

The accounting diff has now completed the Almanax scan recorded above; that is not a full audit or coverage of later operator changes. A separately approved Fuji upgrade remains required. No mainnet deployment or deployed-Fuji leverage increase is authorized.

### Pre-scan review

The follow-up local review checked every production write to borrower snapshots and aggregate debt, immutable helper dispatch and authorization, proxy upgrade atomicity, reserve reconciliation, and the migration list/snapshot assumptions against the regression tests. No additional production change was identified in that review; this is not an independent security audit. The known migration and bytecode-size constraints above remain release gates.

The Almanax commit-scan workflow requires the exact candidate commit to be available on GitHub. Prepare the scoped local commit first, obtain approval for its exact push to `origin/boosted-findings-remediation`, then scan its diff against its immediate parent. Other workspace work advanced that parent to `6b571fde06cb09ec48449abccda65cf1dc861c69` during review. Do not substitute a scan of the old remote HEAD or broaden the diff to include the separate Robinhood V4 adapter commit. The 465-test evidence above predates those unrelated additions; the accounting-only focused rerun passed 22 tests after the adapter source appeared. It does not claim full-suite validation of the independently changed branch.

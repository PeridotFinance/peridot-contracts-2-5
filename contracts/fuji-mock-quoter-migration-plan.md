# Fuji mock opening-quoter migration proposal

Status: architecture approved; implemented locally. **Not deployed or approved for broadcast**.
Prepared 2026-09-07 on `boosted-findings-remediation`, production source at `4d63e7ec`.
Scope is the existing unbacked mock-asset stack on Avalanche Fuji (43113), never real-token markets or mainnet.

## Recommendation and decision

Keep the existing stack and deploy a new quoter plus a one-use executor migration implementation.
Use the existing ProxyAdmin's `upgradeAndCall` to atomically install the fixed executor and replace
its stored quoter address. Do not add a general-purpose quoter setter, reset initialization, move
user deposits, or replace executor/vault/account addresses.

The user approved implementing and testing this one-use migration locally. Deployment and signing
still require a later, separate review of the exact transaction payloads. A full stack redeployment
would entail controller,
operator and liquidation wiring changes and renewed configuration; it is unnecessary for this
opening-only change if the scoped migration passes its acceptance gates.

## Evidence and pinned targets

At Fuji block **58244625**, the local fork verified:

| Component | Address or state |
| --- | --- |
| Executor proxy (preserve) | `0xa155ccCB986774AE818b3F10F07d01D1b7A47b26` |
| Executor ProxyAdmin | `0x23359eB6f9437caDfbF766C11EeC2D0090a67155` |
| ProxyAdmin owner | `0x94696d767e65a75581145646960FA0eC886cE5d2` |
| Old executor implementation | `0xdD9F436C6F11cC1cA7E4c5A738256444b660a5bc` |
| Old quoter | `0x6c68ef73728337e5D8212a11CFeDDdF1B4Ff23eD` |
| Config (preserve) | `0x6148183676E304dbe63a85C350c208DA3cEAc39C` |
| Margin oracle (preserve) | `0x8099F959f9E78972b8534a696F7360cD01E00E28` |
| Existing position/debt state | `nextPositionId = 1`, both markets' `totalBorrows = 0` |
| Existing opens | Unpaused; migration must explicitly pause them |

`test/FujiMockMigrationPreflightFork.t.sol` passes seven tests with no skips, including
1,024 fuzz cases comparing old/new helper outputs for both asset decimal formats. It uses
the actual deployed ProxyAdmin entry point in a local VM, not `vm.etch` or `vm.store`.

The tests demonstrate that:

- The old quoter does not implement `quoteOpen`; the replacement does.
- An unauthorized caller cannot upgrade the executor.
- Reusing `initialize` to replace the quoter reverts the entire upgrade.
- Installing the fixed executor alone succeeds as an upgrade but makes an opening fail at
  the missing quoter selector. The failed opening preserves the user's deposit and leaves no debt.
- A long opened before the local upgrade can still fully close and withdraw pTokens with opens paused.
- The inspected top-level executor slots remain unchanged during that executor-only upgrade.
  This is not a substitute for full compiler storage-layout comparison or successful migration testing.

Mock feeds were refreshed only inside the test VM. This is pinned historical evidence, not a fresh
live-state assertion at signing time. Successful migration and lifecycle tests are now provided
separately in `test/FujiMockQuoterMigrationFork.t.sol`; the diagnostic preflight alone remains
insufficient migration evidence.

## Why other components can remain unchanged

The swap module has an immutable pointer to the old quoter. The liquidator also stores the old
quoter address. Neither calls `quoteOpen`: both use valuation, conversion, fee or lender helpers
whose function bodies are unchanged by `4d63e7ec`. The preflight fuzz test compares those helpers
against the deployed old quoter, including floor and ceiling rounding.

The executor can therefore use the new opening quoter while the swap module and liquidator retain
the old one, provided both quoters have the exact same config and oracle. Keeping these references
is deliberate, not an overlooked partial migration. Future changes to shared quote helpers would
require a separate dependency review. Post-migration liquidation tests remain mandatory.

## Implemented safeguards

`contracts/margin/IsolatedMarginExecutorFujiQuoterMigration.sol` is a Fuji-specific subclass of
the fixed executor with no added ordinary storage fields. Proxy, ProxyAdmin, config, oracle and
old quoter are constants pinned to the table above. New quoter and its runtime code hash are
constructor-bound immutables. The migration entry point:

- Is a one-use `reinitializer(2)`, guarded against reentrancy, and requires chain 43113 and the exact existing executor proxy context.
- Requires the actual ProxyAdmin as caller and matching ERC-1967 admin slot, reached through its owner-authorized `upgradeAndCall`.
  The owner's ordinary direct call to the executor must fail.
- Requires opens paused, the expected old quoter, and the replacement code hash/bindings to the
  existing config/oracle. The operator must also review its compiled runtime and supported opening selector;
  matching getter addresses alone does not establish that arbitrary code is trustworthy.
- Updates only the existing executor `quoter` field and emits the old/new address event. Does not reset
  `nextPositionId`, positions, initialization state, custody, fee eligibility, risk or operators.
- Fails atomically: any failed check reverts both implementation replacement and quoter update.

There is no independently callable, repeatable admin setter. Constructor initialization remains
disabled on the implementation itself. Inspect inherited and namespaced storage layouts, runtime size,
and selector compatibility before deployment. One-use initialization does not remove the existing
ProxyAdmin owner's ability to authorize future code upgrades.

## Staged operator sequence after separate approval

`script/MigrateFujiMockOpeningQuoter.s.sol` implements steps 2–4 as **four separate transactions**:
pause, new quoter, new implementation, then the atomic upgrade-and-pointer-update transaction.
It pins the original implementation/admin/owner/quoter/config/oracle, rejects a pending unpause
queue or changed one-day delay, and requires both `CONFIRM_FUJI_MOCK_ONLY=true` and
`CONFIRM_FUJI_QUOTER_MIGRATION=true`. It does not refresh feeds, queue reopening, change risk,
or move user assets. Inspect the exact unsigned payloads and freshly constructed runtime before
approving broadcast. Its postconditions are simulation checks, not on-chain batch-wide assertions.
If execution stops partway, reconcile receipts and reuse verified created contracts through a
separately reviewed continuation; do not redeploy them by blindly rerunning the four-call script.

1. Re-read chain, proxy implementation/admin and owner, dependency graph, positions, debt, vault
   accounting, risk/fee configuration and outstanding governance actions. Stop on unexplained drift.
2. Pause new opens using the existing config owner. Preserve user exits and liquidation service.
3. Deploy the replacement quoter with the existing config/oracle, then the reviewed migration
   implementation bound to its actual address. Verify code, immutable bindings and contract sizes.
4. Simulate and sign exactly one ProxyAdmin `upgradeAndCall` with nonempty migration calldata.
   Never send an executor-only upgrade or split the pointer update into a later transaction.
5. Verify receipts, new implementation, new executor quoter, consumed initializer version, unchanged
   position/custody/accounting state and all retained dependencies. Keep opens paused if any check fails.
6. Queue reopening through the existing config timelock, after the migration verification succeeds.
   Wait the real configured delay; do not reduce it. Refresh only the approved mock feed scenario
   before the separately simulated reopening and smoke transactions.
7. First run quote-aware 2x long/short opening, closing and separate pToken withdrawal. Verify every
   receipt and raw debt/allowance/free/locked balance. Never blindly rerun a partially mined script.
8. Higher-leverage risk activation is separate: retain the live 2x policy during migration. A 5x
   candidate (20% initial / 10% maintenance) needs its own risk review, timelock and signing approval.

If an upgrade transaction fails, the original implementation/quoter remain in place and the earlier
pause remains effective. Do not unpause the original known-bug code merely to clear a failed rollout.
If post-upgrade checks fail, keep opens paused, inspect receipts/state, and prepare a reviewed recovery;
do not blindly restore old code after new activity. No automated rollback is proposed here.

## Client and acceptance work required before signing

`SmokeFujiMockMargin.s.sol` now rejects the old quoter before any broadcast and requires completed
migration version 2. It accrues both markets, converts collateral pToken shares to redeemable
underlying, and derives total minimum position output from `executor.quoter().quoteOpen(...)`.
The two explicit accrual transactions per position increase `run()` from 9 to **13 transactions**;
withdrawal is still separately simulated and signed. The historical old-code smoke test now asserts
rejection without transfers; the successful quote-aware smoke/withdraw test runs against a genuinely
migrated local fork through the actual operator scripts.
For shorts this includes the unswapped collateral; the executor subtracts it for the swap minimum.
Do not lower an explicit user minimum or weaken either independent swap bound. A quote may still
be invalidated by state changes before inclusion; simulate exact transactions immediately before signing.

The new local migration tests cover successful atomic migration through the real ProxyAdmin, rejected caller/
proxy/chain/binding/unpaused/replay cases, failed-migration rollback, complete storage compatibility,
existing long and short preservation, partial/full close, stale-price debt-free exit, liquidation and
insurance after migration, deposit/reward preservation, and quote-aware 2x–5x flows with costs.
The migrated sizing suite overrides the historical code-substitution hook with real CREATE plus
ProxyAdmin upgradeAndCall, retaining all 24 existing scenarios and price-boundary checks. Preserve the
separate six-decimal short-output rounding guard and the existing interest/funding treatment.

Run the focused and broader regression suites and scan the exact new commit with Almanax after
reviewed publication. The zero-finding scan for `4d63e7ec` does not cover a future migration implementation
or these new preflight files. Ozone/Cecuro is unavailable; do not claim its review. No scanner result
alone permits mainnet deployment.

Preflight command (local fork only):

```sh
FUJI_MOCK_FORK_RPC_URL=https://api.avax-test.network/ext/bc/C/rpc \
FOUNDRY_FUZZ_RUNS=1024 forge test --threads 1 \
  --match-contract FujiMockMigrationPreflightForkTest \
  --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol \
  --skip P_OFTAdapterUpgradeable.t.sol -vv
```

## Local verification record (2026-09-07)

- Combined margin/Fuji/fee/migration suite: **142 passed, zero failures/skips**. Ten fuzz properties
  each ran 1,024 cases. This includes 17 migration tests, seven preflight tests and four migrated
  sizing cases covering 24 complete 2x–5x cost/boundary/close/withdraw scenarios.
- A recorded migration write-set allows only the ERC-1967 implementation slot, existing quoter slot 5,
  initializer namespace and transient reentrancy-guard updates. The guard's final value is preserved;
  initialization version changes from 1 to 2. No vault, fee distributor, risk engine or config writes
  occur inside the atomic upgrade itself (the separate pause transaction intentionally writes config).
- Complete recursive compiler storage-layout comparison with the fixed base executor passed for all
  11 entries, nested position/pending structures and the reserved gap. An isolated build was used
  because the shared Forge cache omitted requested layout output; its runtime exactly matched the
  tested artifact. Existing namespaced initializer/guard storage is checked by the write-set test.
- No implementation selector collisions, including the proxy upgrade selector. Migration runtime
  is 23,241 bytes, below the 24,576-byte limit; replacement quoter remains 6,519 bytes.
- Broad non-RPC regression exited successfully, using the established LayerZero file exclusions,
  `test/simulation/YieldAccrualTest.t.sol` exclusion and `.*ForkTest` exclusion. The fork suites were
  run separately in the 142-test combined scope above. Scoped formatting, whitespace checks and
  high-severity lint for the new migration implementation and both operator scripts passed.
- Fresh public-Fuji **unsigned** operator simulation succeeded. Payload inspection verified four
  zero-native-value transactions from the expected signer, nonces 139–142: config pause, quoter CREATE,
  migration implementation CREATE, ProxyAdmin upgradeAndCall with `migrateOpeningQuoter()` calldata.
  Estimated gas: 8,735,408 (about 0.0087354 test AVAX at the simulation's approximately 1 gwei;
  neither nonce nor gas estimates are guarantees for later inclusion).
- Predicted quoter `0xA73180B7Fdc50e061e32205f3b01e0be952d280b` and implementation
  `0xc22894e9C815Cd84052C0d1E7D06018ef65C1fa1` are **not deployed addresses**. They have not been put
  into live environment files. Dry-run artifact:
  `broadcast/MigrateFujiMockOpeningQuoter.s.sol/43113/dry-run/run-latest.json`.
- Initial migration test failures were test-only caller/expectation scoping around external getters;
  those were corrected before the final passing run. Existing unrelated compiler/NatSpec/config
  warnings remain. This record does not assert an Almanax result for the migration changes.

# Fuji mock borrowing-accounting migration

This operator package is **testnet-only and not deployed**. It does not touch Avalanche mainnet, the real-token Fuji lending markets, margin pricing, fees, feeds or leverage settings. The deployed mock margin cap remains **2x**; tests through 5x are local simulations, not a deployed setting.

The accounting implementation in `944e670abea57a2454cd9a64511d826b41da03c7` passed Almanax scan `6636be8d-67e8-4f9d-bc8d-201e3e3caa88` with zero findings. That result does **not** cover this subsequently added operator package. Review/scan this package and obtain separate transaction approval before broadcasting.

## Verified starting point

At Fuji block **58411457**, hash `0x0022f5859cdd0ca58df6c65207d0faadfe4e1f9deb157dc43e6a4e859f5f7d98`, the read-only preflight queried all Borrow events from block 58205700 across 103 contiguous ranges. Both market addresses had no code at the lower bound and had code by block 58205715. There was exactly one historical borrower per market, both now debt-free:

| Market | Historical borrower | Aggregate debt | Reserves |
| --- | --- | ---: | ---: |
| pMockUSD `0x81BF2032e98C8F35F2336e1A68baA01B5B2030E4` | `0x8280Bb4DDc57447c5a3b04177e67F7bf7C07dAE1` | 0 | 0 |
| pMockAVAX `0x577AC6Ca3Df06D7702740A6A8c136F868f9f0195` | `0xBe80594d30c257f61E3C9ad7A3E189ba6f065Dd4` | 8 | 1,263,604,596 |

Debt/reserve numbers are raw token units. The eight-unit AVAX discrepancy is the previously reproduced rounding residue, not an unpaid account loan. Migrating it reduces reserves by eight and preserves supplier net assets and the exchange rate. No token is redeemed or moved.

Both delegates currently point to `0x87563AAb6F1e60441D511d1512f28A0bdfA6FAf2`, runtime hash `0x38aefc43d0a808b508524223cdeef1160e05e305bf88435491cbd60ac2e4b7db`. Admin is `0x94696d767e65a75581145646960FA0eC886cE5d2`. Snapshot signer latest/pending nonce: 161/161. These are observations, not permanent guarantees.

## Two separately approved stages

Stage A calls `pause()` in `script/MigrateFujiMockBorrowAccounting.s.sol`:

1. Margin config `pauseOpens()`.
2. Controller `_setBorrowPaused(pMockUSD, true)`.
3. Controller `_setBorrowPaused(pMockAVAX, true)`.

This does not prevent repayment or normal closes/withdrawals. It does not queue reopening. Verify all three real receipts, then rerun the complete history preflight:

```sh
node script/check-fuji-borrow-accounting.cjs
```

The preflight loads no env file or wallet, signs nothing and uses only read methods against the pinned public Fuji endpoint. It aborts on changed borrower history, nonzero account debt, changed aggregate, implementation/runtime, identity, insufficient reserves or queued reopening. The report must show all three gates paused before Stage B. A trusted complete RPC response is still an off-chain prerequisite; a zero aggregate alone is not a borrower-list proof.

Stage B calls `run()` only after separate approval:

1. Deploy a new `PErc20Delegate`; its constructor creates its immutable helper.
2. Atomically upgrade/migrate pMockUSD with an empty active-borrower list, expected aggregate 0, adjustment cap 0.
3. Atomically upgrade/migrate pMockAVAX with an empty active-borrower list, expected aggregate 8, adjustment cap 8.

The two markets are **not** upgraded in one atomic batch. On partial failure, stop and inspect the actual receipts and pointers; do not blindly rerun, use `--resume`, switch back to the legacy implementation, or relax assertions. Each market's own upgrade/migration failure is atomic. Reopening and its timelock require later approval; this package deliberately has no unpause or risk-change function.

Script guards also require chain 43113, explicit confirmation flags, the pinned `debt_accounting` release profile, known legacy pointer/runtime, owners/controller/assets, closed positions 1 and 2, next position ID 3, zero locks, flash loans paused, no pending reopen, 2x caps and the reviewed aggregate totals. Historical enumeration must be repeated after real pauses: the script's confirmation flag cannot prove list completeness on-chain.

## Simulations and build

Use the pinned Solidity 0.8.35 / Cancun / IR / optimizer-runs-1 profile. From `contracts/`, unsigned Stage A simulation:

```sh
FOUNDRY_PROFILE=debt_accounting \
CONFIRM_FUJI_MOCK_ONLY=true CONFIRM_FUJI_DEBT_PAUSE=true \
forge script script/MigrateFujiMockBorrowAccounting.s.sol:MigrateFujiMockBorrowAccounting \
  --sig 'pause()' --rpc-url https://api.avax-test.network/ext/bc/C/rpc \
  --sender 0x94696d767e65a75581145646960FA0eC886cE5d2 \
  --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol
```

For a separately reviewed **unsigned** Stage B simulation, omit `--sig 'pause()'`, set `CONFIRM_FUJI_DEBT_MIGRATION=true` and `CONFIRM_FUJI_BORROWER_HISTORY_REVIEWED=true`, and retain the profile/mock confirmation. Do not set the latter without actually reviewing fresh complete history. Stage B must reject the currently unpaused Fuji environment.

These commands omit `--broadcast` and wallet arguments deliberately. User-local keystore signing instructions are supplied only for the separately approved stage. Never expose passwords/private keys to the assistant.

Verification on 2026-09-16: **34 targeted tests passed**, including 12 operator guards, fixed-debt unit/fuzz checks (1,024 cases each), release size and existing Fuji migration/24 long-short 2x–5x cost/boundary flows. Guards include wrong chain/profile, confirmations, pending unpause, history/aggregate drift and replay. Scoped format, whitespace, JavaScript syntax and high-severity Solidity lint passed. This is not a fresh all-repository test run.

Both stages were also rehearsed against a localhost-only Anvil fork at block 58411347: local pause calls followed by an unsigned deployment/migration script. Assertions preserved custody, supply, owner/vault shares and exchange rates; aggregate debts ended at zero and reserves absorbed exactly eight raw units. Three Stage B payloads were independently decoded: CREATE from the exact release artifact, followed by the two pinned `_setImplementation` calls with the exact empty lists and 0/8 expected totals/caps. Candidate delegate/helper addresses from that rehearsal are **not live deployments** and must not be saved as deployed configuration.

The refreshed read-only check at block **58411578** confirmed the same borrower/debt/pointer state, all three gates still unpaused and signer latest/pending nonce 161/161. No Fuji transaction was sent. Observed estimates (not fee guarantees): Stage A 218,685 gas, about 0.000437 test AVAX at the refreshed 2.00000002 gwei quote; Stage B 6,337,428 gas, about 0.00634 test AVAX at the earlier local-fork quote. Refresh after scan/approval. After actual Stage B receipts, independently verify implementation and helper code/immutable binding, mode/shares/debt/reserves, all account debts, custody/supply claims, unchanged risk/dependencies and retained pauses before discussing reopening.

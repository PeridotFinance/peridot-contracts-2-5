# SPY 2x margin (feat/spy-margin): build record

Nothing here is live. Going live needs the operator-signed command list (`tools/spy/ceremony.sh`, phases below), run in a weekday US session with a fresh RHSPY feed. Scope: `RobinhoodVaults/deployments/spy-margin/SCOPE.md`.

## Contracts (`contracts/margin/spy/`, profile `robinhood_spy`: 0.8.26, via-IR, runs 1, cancun)

| Contract | Role | Runtime B |
| --- | --- | --- |
| `SpyMarginPriceSource` | RHSPY feed price in USD 1e18, or 0 when any of these hold: SPY paused or oraclePaused, incomplete or bad round, age > `maxStaleness`, inside the weekly window [`closedFrom`, `closedUntil`) (seconds since Monday 00:00 UTC), or lending-oracle mismatch. Immutable, no admin. | 2,781 |
| `MarginPriceSourceRouter` | SPY -> SPY source; NVDA -> live `0x25E0` unchanged; USDG -> `0x25E0`, falling back to the SPY source only on 0 or revert. | 872 |
| `RobinhoodLendingPriceAdapter3` | Controller oracle: the live `0xe4e0` arithmetic, plus pSPY. | 1,860 |
| `RobinhoodPlainDelegate` | pSPY implementation: `PErc20Delegate` plus the October `ZeroSharesMinted` and round-up `redeemUnderlying` corrections. | 18,394 |

Defaults are operator-pending and all are parameters:
- 90000 s staleness, closed window Sat 00:00 to Mon 01:00 UTC (deploy env `SPY_MAX_STALENESS`, `SPY_CLOSED_FROM`, `SPY_CLOSED_UNTIL`);
- caps $250 / $125 (`ceremony.sh` env `SPY_MAX_POSITION_USD`, `SPY_MAX_DEBT_USD`);
- long only.

## Tests

| Suite | Result |
| --- | --- |
| Unit (`test/spy/SpyMarginPriceSource.t.sol`, `RouterAndAdapter.t.sol`), incl. 4 fuzz | 32 / 32 |
| Hand-written mutants (`tools/spy/mutate.py`; baseline must compile and pass) | 35 / 35 killed |
| Fork: NVDA parity (`SpyMarginParityFork.t.sol`) | 6 / 6 |
| Fork: SPY long, TP/SL, liquidation, delegate (`SpyMarginLongFork.t.sol`) | 12 / 12 |
| Fork: weekend / stale / paused (`SpyMarginWeekendFork.t.sol`) | 9 / 9 |

Fork pin: `SPY_FORK_BLOCK=115940809 SPY_NATIVE_BLOCK=26429129` (Mon 2026-11-16 17:37 UTC), `ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com`. The public RPC prunes state after about 10 minutes. A new pin needs a weekday block (Mon 01:00 to Thu 23:59 UTC) and its `l1BlockNumber`.

## Ceremony (`tools/spy/ceremony.sh <journal> <phase>`)

| Phase | Calls |
| --- | --- |
| `preflight` | Read-only checks. |
| `t0` | Steps 1-13, including the two **[LIVE-NVDA]** calls: step 5 (controller oracle) and step 12 (margin source). Each is followed by a bit-identity check. |
| `gate` | Seed front-run gate and the 1 h delay. Read-only. |
| `t1` | Steps 14-16. |
| `demo-open`, `demo-orders`, `demo-close` | The demo. |
| `verify` | Read-only. |
| `rollback` | `disablePair`; with `ROLLBACK_PRICES=yes` also `setAssetSource(0x25E0)`. |

Deploy (throwaway sender): `script/spy/DeploySpyMargin.s.sol`. Rehearsal: `tools/spy/rehearse_ceremony.sh`, which runs on anvil with the same scripts and `SIGN=--unlocked`.

## Evidence (not committed; SHA-256 of the local files in `.scratch/`)

**Anvil rehearsal** (`tools/spy/rehearse_ceremony.sh`), run at fork block 115956906 (Mon 2026-11-16 18:05 UTC), passed end to end:
- 5 deployer transactions, 0.000127 ETH;
- 25 Ledger transactions: 16 ceremony, 7 demo, 2 rollback;
- both [LIVE-NVDA] identity checks passed;
- seed front-run gate passed;
- SPY position 7 opened at 1.99x ($98.39 gross, $48.99 debt, health 20084 bp) with SL -5% and TP +5%;
- the live `orders_keeper.py` left both orders waiting, then after a -6% print executed the SL (2.14M gas) and the position closed;
- position 8 opened and closed through `demo-close`, and its margin was withdrawn;
- after the rollback, SPY is unpriced and NVDA is priced as before.

| SHA-256 | File (`.scratch/`) |
| --- | --- |
| 57d30a6748eb0628b73faa9f90ce965d5263bf947ddc2c1054aace53d3491d6e | rehearsal-run4.log (full run) |
| f3a8e8c17b55caeba9ace5aaa7262fabb4ea2a964bc1699fa63dc1e0af13c512 | rehearsal/preflight.log |
| 9983d6a97644dc318eb4f452e6890e061f1a84a5c5a4f13e08c4a24d46d54a26 | rehearsal/t0.log |
| 8abf13903d5930c58f3dab9226922290a9e84d7e75c626f2c1b8dc788361bf97 | rehearsal/gate.log |
| 543a0c2ead248c309fdfbc73c2d52d279f3fe49b988361320e1f3165833807dc | rehearsal/t1.log |
| ce6a0050ae2232181e83b36d541ca35d0c9d89ffd36402acfd8451a9216a596e | rehearsal/demo-open.log (last run: position 8) |
| bf3f65066cc3985cb39b5ba349ecca8b9f89a0034c61790587e56ffa998dda5e | rehearsal/demo-orders.log |
| 56f4971281ee858fc9579507dae714d8f5e9b1309d78d5b38d8410166a0d2419 | rehearsal/keeper-1.log |
| a5accaf26f6f6d865be3dcfa1c9162e5b3560479567600a55e77a5c7fb5b597d | rehearsal/keeper-2.log |
| 6499cc5ad90ab452da87e26affb06105cb47c0b95aea9661c34c4fbcd5846b01 | rehearsal/demo-close.log |
| d486f26e204986430e9e0ab9fc86913c63a9a322214fef39a4e15f47a5728ff8 | rehearsal/verify.log |
| 5c49705c8456bb57a3b2c66da1d44c9af23279562e3145bd48dc830fdafdd468 | rehearsal/rollback.log |
| 416b945ec3790a68fb6313313020489c27f6627da841e96017f06494fc721fe2 | rehearsal/deploy.log |
| a8224e06affca484e4f2333a4085555e5f473e1f769c2b5fa8dc3ca9dce15e66 | mutate-run3.log (35/35) |

Rehearsal-only deviations:
- pUSDG/pNVDA `accrualBlockNumber` was aligned to anvil's block number;
- the RHSPY feed was etched with a fixed-answer mock to survive the 1 h warp.

The real ceremony uses the live feed, in session.

Findings fixed during the build:
- pSPY borrow accounting is enabled by `PToken.initialize`, so the scoped Ledger step 10 is not needed;
- the demo open needs its SPY minimum 5 bp above the swap module's floor, because margin accrues between the quote and the mined open (`SwapError(5)` otherwise);
- bash cannot compare 1e18-scale integers, so the script uses Python comparisons.

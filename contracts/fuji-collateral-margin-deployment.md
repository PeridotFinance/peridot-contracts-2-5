# Fresh collateral-preserving margin on Fuji

This package is **mock-only and not yet deployed**. It never upgrades or consumes
addresses from the old Fuji margin system. Mainnet chain43114 and every chain
other than Fuji43113 are rejected. Building or simulating it does not authorize
broadcasting it, activating trading, or using these fixture parameters on mainnet.

## Files and roles

| File | Role |
| --- | --- |
| `script/DeployFujiCollateralMargin.s.sol` | Create, seed and wire an entirely fresh paused environment. |
| `script/ConfigureFujiCollateralMargin.s.sol` | `run()` queues five timelock actions; `execute()` applies those five after24h. Neither activates trading. `verify(address,address)` is read-only. |
| `contracts/margin/testing/FujiMockPharaoh.sol` | Fuji-only ERC4626 vaults, immutable factory/pool bindings and CL-ABI bridge. |
| `test/FujiCollateralMarginDeployment.t.sol` | Deployment, policy, timelock, adapter composition and lifecycle tests. |
| `fuji-collateral-margin.env.example` | Public inputs; confirmation defaults false and executor is unset. |

The new script reads only `CP_FUJI_DEPLOYER` and
`CONFIRM_FUJI_COLLATERAL_MOCK_ONLY`; configuration additionally reads
`CP_FUJI_EXECUTOR`. It does not read legacy `MOCK_*`, `MARGIN_*`,
`PERIDOTTROLLER`, private-key variables or a keystore. It does not rewrite any
environment variables or files. The sample deployer is the previously verified
public robinhood-deployer address; recheck the local account address before any
future signing. Never paste a password or private key into chat or a tracked file.

## What gets deployed

Fresh mockUSD(6decimals), mockAVAX(18decimals), owner-controlled $1/$10 feeds and
two mock ERC4626 vaults model the collateral interfaces for the USDC/USDt and
sAVAX/WAVAX markets. These vaults hold only their single mock underlying: they
do **not** reproduce Pharaoh LP composition, actual yield, USDt/sAVAX risks or
mainnet liquidity. Their seeded share price initially equals their asset price.
Deposits/mints close after seeding; redemptions remain available for later tests.

The trading path uses the production Pharaoh vault-share adapter and production
Pharaoh CL adapter, followed by a new mock CL-ABI bridge and the existing funded
mock fixed-price venue. There is no LFJ fallback. The terminal venue is not a
concentrated-liquidity AMM and does not establish real price impact or capacity.
Existing pinned-mainnet fork evidence remains separate from these mock tests.

The lending deployment has its own PERIDOT, Unitroller/controller implementation,
jump-rate model, plain delegate, Pharaoh delegate and four pToken markets. Two
single-use atomic bootstrappers list, seed and pause the plain and share markets;
each validates untouched markets and returns pending administration to the
deployer, which the script accepts. Any prior donation to an unbootstrapped market
causes bootstrap to fail closed. If a live batch ever fails partway, stop and
reconcile receipts; do not rerun the whole script or assume the whole batch was atomic.

The fresh margin risk engine, executor, settlement and swap modules are immutable,
not legacy-proxy replacements. Config, fee distributor, margin vault and insurance
use fresh initialized proxies with deployer-controlled ProxyAdmins. Account factory,
controller hooks, fee collectors and insurance liquidation authority point only to
the new stack. All governance is single-operator **test governance**, not an approved
mainnet Safe/timelock arrangement.

## Mock seed and policy preset

| Destination | mockUSD | mockAVAX |
| --- | ---: | ---: |
| Plain lending markets | 100,000 | 10,000 |
| Mock collateral vaults, then their share-pToken markets | 10,000 | 1,000 |
| Flash lender | 100,000 | 10,000 |
| Fixed-price test venue | 1,000,000 | 100,000 |
| Debt-asset cash insurance | 10,000 | 1,000 |
| Operator wallet for later repayment tests | 10,000 | 1,000 |

These tokens are unbacked mocks minted during deployment; no real USDC/WAVAX is
spent. All seed pTokens belong to the operator. No collateral is deposited in the
margin vault and no position is opened. Temporary vault/bootstrap allowances clear.
Spot collateral factors are zero, lending reserve factors10%, market borrow caps
five times each market's seed, and native pToken flash loans remain disabled.
Collateral-market borrowing remains paused even during later local activation tests.
The separate funded flash lender charges5bps but remains paused.

Deployment queues nothing and leaves new opens, all four market borrowing gates,
the mock venue and flash lender paused. The margin config uses a24h action delay,
0% immediately claimable rewards and seven-day fee streaming. Collateral valuation
weights are100% only for mock testing, not mainnet approval. Interest model fixture:
31,536,000blocks/year; 2% base,10% multiplier,100% jump multiplier,80% kink.

Configuration queues exactly:

- Opening/closing fees10bps each;50% to the same collateral-pToken depositor pool,
  50% insurance,0% treasury. This is a mock fixture split, not a production decision.
- Four enabled pair configurations: both collateral markets × long/short
  AVAX/USD. Requested maximum trade leverage5x, initial margin20%, maintenance10%,
  liquidation target125%, full-liquidation threshold50%, partial liquidation cap50%,
  keeper bonus5%, maximum slippage1%, oracle deviation1%, max position value$10,000,
  max debt value$5,000. These are test limits, not approved production risk.

Executing configuration after24h **still leaves all gates paused**. There is no
unpause action queued by either script. Configuration rejects an existing unpause
queue, previously used accounts/nonempty margin vaults, mixed owners/hooks/assets,
altered feeds/emergency prices, missing insurance/liquidity, and unsafe pause state.
It checks the entire five-action batch before broadcasting: duplicate, incomplete,
cancelled, immature or already-consumed batches require reconciliation, not retry.
Fresh price timestamps are intentionally not required to configure a paused stack;
they must be refreshed and revalidated under a separately approved activation plan.

## Simulation only

From `contracts/`, export public inputs explicitly; do not source or replace the old
deployment's `.env`. The pinned `debt_accounting` build profile is required. The
LayerZero exclusions address the existing unrelated missing dependencies.

```sh
export CP_FUJI_DEPLOYER=0x94696d767e65a75581145646960FA0eC886cE5d2
export CONFIRM_FUJI_COLLATERAL_MOCK_ONLY=true
export CP_FUJI_RPC_URL=https://api.avax-test.network/ext/bc/C/rpc
FOUNDRY_PROFILE=debt_accounting forge script script/DeployFujiCollateralMargin.s.sol:DeployFujiCollateralMargin \
  --rpc-url "$CP_FUJI_RPC_URL" --sender "$CP_FUJI_DEPLOYER" \
  --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol
```

This command has **no `--broadcast`, no account selection and no signing key**.
Inspect estimated gas, predicted transaction order and every target/value/calldata
before asking for live deployment approval. Predicted addresses are not deployed
addresses and depend on the sender nonce. A simulation's Solidity assertions do
not make a multi-transaction live broadcast atomic.

After separately approved deployment and actual receipt/runtime/binding verification,
set `CP_FUJI_EXECUTOR` to the newly verified address. Never use the old executor.
The configuration simulations use the same flags as above with target
`script/ConfigureFujiCollateralMargin.s.sol:ConfigureFujiCollateralMargin`:
default `run()` simulates queueing; `--sig 'execute()'` simulates execution only
after the actual mined queue deadlines. Each live phase needs its own reviewed
transaction batch and approval. No broadcast command is supplied in this package.

## Verification checkpoint — 26 September 2026

- Fifteen new package tests pass: fresh seed/ownership/pause/allowance checks,
  chain and confirmation rejection, environment separation, five-action timelock
  boundaries and incomplete-batch rejection, oracle/insurance/owner/gate checks,
  mock vault restrictions, key runtime sizes and script-deployed lifecycles.
- Lifecycle coverage includes all16 combinations of two collateral pools,
  long/short and2x/3x/4x/5x, accrued interest and pToken withdrawal, stale-oracle
  paused recovery, and partial then insured full liquidation in all four
  collateral/direction combinations. Activation exists only in test code.
- The final broader scoped run passed268 test executions; a separate existing
  bootstrap/rate-model/chain-gate run passed12, totaling280 with zero failures or
  skips. The15 new tests are included, not additional. Selected fuzz properties
  ran1,024 cases each. Inherited tests repeat in different fixtures;280 is not a
  count of novel economic scenarios or every test in the repository.
- Scoped formatting, whitespace and targeted high-severity lint passed. Tests
  enforce EIP-170 for the core deployed contracts and new mock dependencies.
  Existing metadata/Natspec/compiler warnings and the three unrelated LayerZero
  dependency exclusions remain. Production margin contracts were not modified.
- An **unsigned** simulation against the public Fuji RPC succeeded:103 proposed
  transactions, including41 top-level creations, sender nonces215–317 at that
  snapshot, all native values zero and every call target in the freshly created
  contract set. Unnamed proxy calls were independently decoded as initial wiring;
  no activation, position opening or legacy upgrade was included. No keystore,
  signing or broadcast was used. Predicted addresses are not live deployments.
- Simulation gas estimate:89,878,010 at2.00000002gwei, approximately0.17975602
  **test AVAX**. This estimate and nonce range are time-sensitive, not guarantees;
  resimulate before any separately approved broadcast. The ignored record is
  `broadcast/DeployFujiCollateralMargin.s.sol/43113/dry-run/run-latest.json`.

## Remaining release gates

Obtain external review of this new package; the clean recovery scan atfc7f02ba
does not cover deployment tooling. Then separately approve deployment, verify all
receipts/code/pointers/owners/balances and pause gates, approve queueing, wait24h,
approve execution, and verify configuration while still paused. Only then prepare
a separate activation and small live smoke plan with fresh mock feeds. Rehearse
2x–5x long/short, both collateral pools, partial/full close, repayment/recovery,
liquidation/insurance, fee streaming and pToken withdrawal on that fresh Fuji stack.
The old live Fuji smoke results cannot substitute for these new receipts.

Production-sized Pharaoh capacity, risk weights/fees/caps, cash-insurance budgets,
governance, keeper operation, monitoring and mainnet approval remain unresolved.

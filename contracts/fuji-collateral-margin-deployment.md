# Fresh collateral-preserving margin on Fuji

This package is **mock-only**. The original version was deployed on Fuji and its
one-hour delay was applied on 6 October 2026. The seven-call activation was verified
on 9 October 2026; deposits, smoke trades and withdrawals require separate approval.
It never upgrades or consumes
addresses from the old Fuji margin system. Mainnet chain43114 and every chain
other than Fuji43113 are rejected. Building or simulating it does not authorize
broadcasting it, activating trading, or using these fixture parameters on mainnet.

## Files and roles

| File | Role |
| --- | --- |
| `script/DeployFujiCollateralMargin.s.sol` | Create, seed and wire an entirely fresh paused environment. |
| `script/ConfigureFujiCollateralMargin.s.sol` | `run()` queues five actions; `execute()` applies them after their stored deadlines. Accepts the new 1h or legacy 24h policy. Neither activates trading. |
| `script/ReduceFujiCollateralMarginDelay.s.sol` | Fuji-only 24h-to-1h transition: `run()` queues one action; `execute()` applies it after the old 24h deadline. Preserves existing queues and all pause gates. |
| `script/ActivateFujiCollateralMargin.s.sol` | First activation only: seven calls, fresh mock feeds, venue/lender and plain borrowing enabled, opens last. `verify(address,address)` checks the unused, freshly activated stack. |
| `script/SmokeFujiCollateralMargin.s.sol` | First four 2x round trips, two collateral pools × long/short. Separate `withdraw()` returns free pTokens after receipt review. Never use the legacy smoke script. |
| `contracts/margin/testing/FujiMockPharaoh.sol` | Fuji-only ERC4626 vaults, immutable factory/pool bindings and CL-ABI bridge. |
| `test/FujiCollateralMarginDeployment.t.sol` | Deployment, policy, timelock, adapter composition and lifecycle tests. |
| `fuji-collateral-margin.env.example` | Public inputs; confirmation defaults false and executor is unset. |

Deployment reads only `CP_FUJI_DEPLOYER` and
`CONFIRM_FUJI_COLLATERAL_MOCK_ONLY`; configuration, delay transition and activation
additionally read `CP_FUJI_EXECUTOR`. Activation also requires
`CONFIRM_FUJI_COLLATERAL_ACTIVATION=true`. Smoke phases also read the same owner and
executor, requiring respectively `CONFIRM_FUJI_COLLATERAL_SMOKE=true` or
`CONFIRM_FUJI_COLLATERAL_WITHDRAW=true` in addition to the mock-only confirmation.
It does not read legacy `MOCK_*`, `MARGIN_*`,
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
the mock venue and flash lender paused. New Fuji deployments use a1h action delay,
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

Executing configuration after its stored deadlines (1h for new queues under the
new policy; 24h under the legacy policy) **still leaves all gates paused**. There is no
unpause action queued by either script. Configuration rejects an existing unpause
queue, previously used accounts/nonempty margin vaults, mixed owners/hooks/assets,
altered feeds/emergency prices, missing insurance/liquidity, and unsafe pause state.
It checks the entire five-action batch before broadcasting: duplicate, incomplete,
cancelled, immature or already-consumed batches require reconciliation, not retry.
Fresh price timestamps are intentionally not required to configure a paused stack;
they must be refreshed and revalidated under a separately approved activation plan.

## One-hour Fuji policy and existing deployment transition

Only the Fuji mock deployment preset and operator scripts change. Shared production
contracts, their one-hour minimum, and mainnet deployment/governance policies are
unchanged. Do not redeploy the existing stack to change its delay.

`ReduceFujiCollateralMarginDelay` uses the existing owner-only timelocked API:

1. `run()` queues `queueActionDelay(3600)` while the current delay is 24h.
2. Wait until that action's actual mined deadline, still 24h after queueing.
3. With separate execution approval, `execute()` calls `setActionDelay(3600)`.
4. Subsequently queued actions wait one hour. Already-queued deadlines do not change.

Each phase contains exactly one transaction. Both require Fuji43113, explicit mock
confirmation, the expected fresh executor/owner, a current 24h delay, and all normal
paused-stack identity, ownership, market, oracle and funding checks. Missing,
duplicate, canceled, immature or already-applied transition actions fail closed.
The transition-specific read-only verifier permits an existing unpause queue but
checks its deadline is preserved across the operation. The ordinary configuration
verifier still rejects an unpause queue. Both accept only 1h or legacy 24h delays.

The existing unpause action matured on **6 October 2026 at 09:29:35 UTC**. The delay
transition completed at 14:07:03 UTC that day, with all gates still paused; do not
repeat the queue or execution. The transition did not accelerate existing deadlines.
Since the transition script requires every gate
paused, finish the delay change before separately activating the stack; if the
stack has already been activated, stop and plan a separately approved pause first.
The transition does not cancel queues, unpause, refresh feeds, deposit or trade.

For an unsigned queue simulation, use the public input exports and exclusions below
with target `script/ReduceFujiCollateralMarginDelay.s.sol:ReduceFujiCollateralMargin`
and set `CP_FUJI_EXECUTOR` to the independently verified fresh executor
`0xA1398d06Cf8d0bE8673A46C67e462718FD99Bf9C`. After the actual transition deadline,
add `--sig 'execute()'` to simulate execution. Neither simulation authorizes broadcast.
Never use the legacy margin executor or blindly rerun a partially completed phase.

## First activation — separate approval required

The existing unpause action is mature: no new queue or waiting period is needed.
`ActivateFujiCollateralMargin.run()` requires Fuji43113, both explicit confirmations,
the verified fresh executor and owner, a one-hour policy, and every gate initially
paused. It checks unused accounts/empty margin vaults, dependency and ownership
bindings, unchanged mock feed answers, insurance/venue/lender funding, exact fees
and all four pair presets, consumption of the five preset configuration queues, seed lending cash,
five-times-seed caps and 10% reserve factors. Altered settings or a partial previous
activation fail closed; this is not a generic pause/reopen operator.

The exact batch is:

1. Refresh mockUSD at its unchanged $1 value.
2. Refresh mockAVAX at its unchanged $10 value.
3. Unpause the funded mock swap venue.
4. Unpause the separate funded flash lender.
5. Enable plain pMockUSD borrowing.
6. Enable plain pMockAVAX borrowing.
7. Unpause margin opens **last**, consuming the existing mature action.

Both boosted collateral markets' borrowing and every native pToken flash-loan gate
remain paused. No deposit, approval, position, withdrawal, new deployment, or mainnet
call is included. The temporary verification helper executes only in the local
script EVM and must not appear as a deployment in the unsigned transaction batch.

Before broadcast, inspect all seven targets/calldata/zero native values and obtain
separate approval after review. **The batch is not atomic.** Stop and reconcile any
partial execution rather than blindly rerunning or using `--resume`. Opens last
limits intermediate exposure but does not make earlier changes atomic. Verify all
receipts and current state after signing. Feeds have a 1,200-second freshness limit;
delay during signing can invalidate verification and later smoke tests. Refreshes
after that window require their own reviewed transaction scope.

Unsigned simulation from `contracts/`, with no keystore or `--broadcast`:

```sh
export CP_FUJI_DEPLOYER=0x94696d767e65a75581145646960FA0eC886cE5d2
export CP_FUJI_EXECUTOR=0xA1398d06Cf8d0bE8673A46C67e462718FD99Bf9C
export CONFIRM_FUJI_COLLATERAL_MOCK_ONLY=true
export CONFIRM_FUJI_COLLATERAL_ACTIVATION=true
export CP_FUJI_RPC_URL=https://api.avax-test.network/ext/bc/C/rpc
FOUNDRY_PROFILE=debt_accounting forge script script/ActivateFujiCollateralMargin.s.sol:ActivateFujiCollateralMargin \
  --rpc-url "$CP_FUJI_RPC_URL" --sender "$CP_FUJI_DEPLOYER" \
  --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol
```

After actual activation, the same unsigned command with
`--sig 'verify(address,address)' "$CP_FUJI_EXECUTOR" "$CP_FUJI_DEPLOYER"`
checks the initial activated state, including fresh prices and consumed unpause.
It is not a live-position monitor: it deliberately rejects an already-used stack.
Only after receipt/state verification should separately approved small smoke trades
begin, covering both collateral pools and directions before larger test cases.

## Simulation only

### First fresh-stack 2x smoke batch

**Existing deployment: this first-use batch partially executed on9October. Do not
run it again or use `--resume`; use the reviewed continuation checkpoint below.**

Activation is complete on the existing fresh stack. Do not rerun activation or use
the legacy `SmokeFujiMockMargin` operator. This new script is first-use-only:
positions1–4 must be unused, the margin vault empty, all reviewed risk/fee/funding
settings unchanged, and the owner must already hold both collateral pTokens with
zero deposit allowances. It does not mint or buy anything.

The proposed `SmokeFujiCollateralMargin.run()` batch contains exactly20 transactions:

- Two unchanged $1/$10 mock feed refreshes.
- Four explicit market-interest accruals (plainUSD, plainAVAX, boostedUSD, boostedAVAX).
- For each collateral pool: approve a fixed pToken budget, deposit it, clear approval,
  open/fully close one2x long, then open/fully close one2x short (seven calls per pool).

Each pool receives $60-equivalent collateral:300,000,000,000 raw USD-vault pToken
shares or30,000,000,000 raw AVAX-vault pToken shares at the verified mock seed rates.
Each position locks $25-equivalent original collateral, with requested trade
leverage2x (actual leverage is conservatively quoted, not promised exactly2x).
The script rejects changed mock NAV rather than resizing these fixed budgets.
Maximum opening and closing fees are each $0.10-equivalent pTokens; maximum
collateral sold for a close deficit is $1-equivalent. The existing1% swap/oracle
bounds remain enforced, with explicit opening and trade-close output minimums.
Every open/close has a15-minute deadline from simulation; do not delay signing.
No risk settings, pause gates, insurance withdrawals or mock prices are changed.

Local assertions check original collateral retention at entry, entry leverage
between1.8x and2x and health factor at least4, closed accounts/zero account and
aggregate debt, unlocked collateral, cleared deposit approvals, same-pool insurance
fees and depositor reward eligibility. The fixture fee split is50/50; integer
rounding can send at most one raw pToken unit per fee to the configured treasury.
The operator is also the treasury in this mock setup. Profit settlement, if any,
is separate mockUSD; it is not a redemption of unused original collateral.

Unsigned simulation (from `contracts/`, using the public owner/executor/RPC exports
above or below, **no wallet or broadcast**):

```sh
export CP_FUJI_EXECUTOR=0xA1398d06Cf8d0bE8673A46C67e462718FD99Bf9C
export CONFIRM_FUJI_COLLATERAL_SMOKE=true
FOUNDRY_PROFILE=debt_accounting forge script script/SmokeFujiCollateralMargin.s.sol:SmokeFujiCollateralMargin \
  --rpc-url "$CP_FUJI_RPC_URL" --sender "$CP_FUJI_DEPLOYER" \
  --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol
```

After separately approved live execution, verify all20 receipts, exact IDs/assets,
eight fee events and four retained-collateral opening events, then run the unsigned
`--sig 'verify(address,address)' "$CP_FUJI_EXECUTOR" "$CP_FUJI_DEPLOYER"` checkpoint.
That checkpoint validates closed positions/debt/locks/allowances; it is not a
general policy or fresh-price monitor. Stop and reconcile partial failures: neither
this script nor a later `--resume` makes the batch atomic. In particular a successful
open followed by a failed close requires a separately reviewed close/recovery plan.

Only after that review, simulate `--sig 'withdraw()'` with
`CONFIRM_FUJI_COLLATERAL_WITHDRAW=true` and separately approve its **two** exact
`withdraw(pToken,amount)` calls. These snapshot current free balances and return
pTokens to the wallet without strategy redemption, price updates, swaps or trades.
Withdrawal itself settles streamed rewards, so a small newly credited free balance
may remain; never claim the entire reward stream was withdrawn. Both amounts must
be between95% and101% of the original respective deposits. No automatic rerun,
reward sweep, or reuse after later positions is supported. Stale prices or closed
strategy redemptions do not prevent this pToken-native withdrawal.

### Exact USD-deposit continuation (new review and approval required)

The first nine calls succeeded, including the USD-pToken deposit and approval
clearance. First open `0x8aad2fe35dd6c866368b965f8b268ba244759e3d91dcc7a4466024502d9935af`
reverted at block59237427: deadline15:31:18UTC, inclusion15:37:06UTC on9October.
Historical read-only replay with only the deadline refreshed succeeded. This was
an expired transaction, not a demonstrated leverage-math defect. The on-chain
state after failure has the full300,000,000,000 raw USD collateral shares free,
zero locked collateral and debt, nextPositionId1, no AVAX deposit, and no allowances.

`continueFromUsdDeposit()` accepts only that exact financial checkpoint. It checks
the owner's and global free balances, locked balances, physical pToken custody,
zero deposit approvals, unused position IDs and the full existing ownership,
wiring, gates, risk, fees, oracle bindings, market caps and funding policy. The
owner need not still hold a second USD deposit in their wallet. Other users' funds,
an under/over-sized USD deposit, custody donations, an AVAX deposit or an existing
position cause rejection before any feed transaction. It is not a general resume
mechanism or permission to recover arbitrary partial batches.

Exactly17 new calls are generated:

1. Refresh mockUSD and mockAVAX at unchanged $1/$10 (two calls).
2. Accrue all four markets (four calls).
3. Reuse deposited USD-pTokens for the long/open-close and short/open-close (four calls).
4. Approve/deposit/clear the original $60 AVAX-pToken budget (three calls).
5. Open/close the AVAX-collateral long and short (four calls).

There is **no second USD deposit, withdrawal, new deployment, pause change or risk
change**. All four positions still request2x with $25 margin, $0.10 fee caps per
open/close, $1 collateral-sale caps per close, and the original output protections.
Postconditions and the later separately approved two-call withdrawal are unchanged.
Fresh simulation regenerates quotes and15-minute deadlines; it does not remove
expiry or refresh already signed calldata. A long password/signing delay can still
expire a transaction. Have the keystore ready, sign promptly, and if anything
fails, stop and reconcile receipts instead of rerunning or using `--resume`.

Unsigned simulation only, from `contracts/`:

```sh
export CP_FUJI_DEPLOYER=0x94696d767e65a75581145646960FA0eC886cE5d2
export CP_FUJI_EXECUTOR=0xA1398d06Cf8d0bE8673A46C67e462718FD99Bf9C
export CP_FUJI_RPC_URL=https://api.avax-test.network/ext/bc/C/rpc
export CONFIRM_FUJI_COLLATERAL_MOCK_ONLY=true
export CONFIRM_FUJI_COLLATERAL_SMOKE=true
export CONFIRM_FUJI_COLLATERAL_CONTINUATION=true
export CONFIRM_FUJI_COLLATERAL_WITHDRAW=false
FOUNDRY_PROFILE=debt_accounting forge script script/SmokeFujiCollateralMargin.s.sol:SmokeFujiCollateralMargin \
  --sig 'continueFromUsdDeposit()' \
  --rpc-url "$CP_FUJI_RPC_URL" --sender "$CP_FUJI_DEPLOYER" \
  --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol
```

Inspect all17 target/calldata/value envelopes and current nonce before asking for
separate live approval. No signing command is authorized by this simulation.
Neither the original20-call approval nor its clean scan covers this changed operator.
Verify all actual continuation receipts and four closed positions before quoting
or approving withdrawals. Do not run the old `withdraw()` against the current
failed-first-open state: its four-closed-position guard correctly rejects it.

### Historical deployment simulation

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
  collateral/direction combinations. At this historical checkpoint activation
  existed only in test code; the operator above was added subsequently.
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

## One-hour policy verification — 5 October 2026

- 248 scoped test executions passed with zero failures or skips across six suites,
  using 1,024 runs per selected fuzz property. This includes the 22-test Fuji package
  suite (seven new transition regressions), collateral-preserving math, settlement,
  lifecycle and recovery suites, and the existing Fuji chain-policy suite. It is not
  every repository test; inherited fixtures repeat some scenarios.
- Transition tests cover the old 24h deadline, new 1h boundary, preservation of
  existing fee/pair/unpause deadlines, missing/duplicate/canceled/replayed actions,
  unsupported delay, wrong chain/confirmation/owner and changed pause gates.
- Formatting, whitespace and scoped high-severity lint checks passed. Existing
  compiler/dependency warnings and the three LayerZero exclusions remain.
- An unsigned simulation against the existing paused Fuji stack passed, including
  its already-queued unpause action. Independently encoded calldata matched exactly
  one `queueActionDelay(3600)` call to the verified config, zero native value,
  sender nonce329 at that snapshot. No verifier deployment was included in the batch.
- No transaction was broadcast. Live delay remains24h until separately approved
  queueing, the old waiting period, and execution. External review of this revision
  remains pending; earlier clean scans do not cover it.

## Activation verification — 8 October 2026

- 258 scoped test executions passed across six suites, zero failures or skips,
  with 1,024 cases per selected fuzz property. This includes all32 Fuji package
  tests and ten new activation regressions. It is not every repository test;
  inherited fixtures repeat scenarios.
- The actual activation operator now drives local deployment lifecycle tests:
  both collateral pools, both directions, requested2x/3x/4x/5x, partial and insured
  full liquidation, and paused oracle-free recovery.
- Regressions cover chain/confirmation/owner checks, missing/immature/canceled
  unpause, partial activation, altered fees/pairs/caps/liquidity/insurance/prices,
  legacy delay rejection, exact post-activation gates, replay and stale feeds.
- Scoped formatting, whitespace and high-severity lint checks passed; existing
  metadata/NatSpec warnings and three unrelated LayerZero exclusions remain.
  No production contract logic changed.

Activation simulation checkpoint — 8 October 2026: the unsigned public-Fuji run
passed all preflight and post-state checks. Independently encoded calldata matched
exactly the seven calls above, sender nonces331–337, zero native values, no helper
deployment. Estimated gas347,195 at2.759139749gwei was approximately0.00095796
test AVAX; estimates and nonces must be refreshed before signing. The ignored
public record is `broadcast/ActivateFujiCollateralMargin.s.sol/43113/dry-run/run-latest.json`.
Subsequent live snapshot59184881 (8 October14:39:04UTC) confirmed all gates still
paused, actionDelay3600, unchanged mature unpauseETA1791278975 and latest/pending
nonce331. Simulation did not activate the live deployment.

## Smoke verification — 9 October 2026

- 266 scoped test executions passed across six suites, zero failures/skips, with
  1,024 cases per selected fuzz property. This includes40 Fuji package tests and
  eight new smoke regressions; it is not every repository test. Existing local
  2x–5x/lifecycle/liquidation/recovery coverage remains included.
- Four round trips exercise the actual script. Eight fee events are checked for
  the same original collateral token and50/50 distribution including rounding dust.
  Separate withdrawal passes with stale prices and strategy redemptions closed,
  preserving total pToken supply and returning the exact requested pTokens.
- Guards cover chain/confirmations/owner, pre-existing balances/allowances, missing
  wallet budget, changed fees/prices, replay and premature/repeated withdrawal.
  Formatting, whitespace and scoped high-severity lint passed. Existing build
  warnings and three LayerZero exclusions remain; no production contract changed.
- Unsigned public-Fuji simulation passed. Independently decoded/re-encoded all20
  calls with exact targets, nonces338–357, zero native values, bounded parameter
  values, empty route data and no helper deployment or withdrawal. Actual simulated
  entry leverage was1.99x long/1.97x short for each pool, with health factors5.0489
  and5.0989. Remaining free raw shares were298,567,399,498 USD-vault and29,858,253,070
  AVAX-vault. These are simulation outputs, not guaranteed live withdrawal amounts.
- Gas estimate64,004,697 at2.492583818gwei was approximately0.15953707testAVAX;
  the largest proposed transaction gas limit15,824,663 was below the observed Fuji
  block limit32,000,000. High opening gas is an operational concern to review for
  production; this smoke package does not optimize the risk engine. Refresh gas,
  fee, nonce, deadline and liquidity checks before separately approved signing.
- Live snapshot59232325/hash0x8248cbf7b8f0da9c20ab8445ad99d57ef1249bfe9f2fd73eb5a2a4873bc32f6a,
  9October12:49:55UTC, confirmed nonce338/latest+pending,1.42964518testAVAX,
  nextPositionId1, opens enabled, zero margin balances and zero deposit allowances.
  No live smoke transaction was sent. The ignored public simulation record is
  `broadcast/SmokeFujiCollateralMargin.s.sol/43113/dry-run/run-latest.json`.

## Continuation verification — 10 October 2026

- 273 scoped test executions passed across six suites, zero failures/skips, with
  1,024 cases per selected fuzz property. This includes47 Fuji package tests and
  seven continuation regressions; it is not every repository test.
- Regressions cover the expired first open with its intact USD deposit, continuation
  without spare USD wallet shares, exactly one new deposit (AVAX), fee accounting,
  fresh deadlines, stale feeds, replay, active positions, altered balances/custody,
  wrong depositor, outstanding approvals, policy and identity/confirmation guards.
  The original first-use operator still rejects the partial checkpoint.
- Unsigned public-Fuji continuation simulation passed. Independent ABI decoding and
  re-encoding verified exactly17 calls, owner nonces348–364, zero native values,
  unchanged bounds, no USD deposit/approval, no withdrawal and no helper deployment.
  Simulated entry leverage was1.99x long/1.97x short in each pool, health factors
  5.0489/5.0989, and final free raw shares298,567,399,498 USD/29,858,253,070 AVAX.
- Estimated gas63,469,420 at0.250000139gwei was0.01586736testAVAX. The largest
  transaction gas limit15,824,663 was below the observed32,000,000 block limit.
  Gas, nonces, prices and deadlines must be refreshed before separately approved
  signing; these simulations are not live trades or guaranteed final balances.
- Live snapshot59266779/hash0x73830c5764428eadc74b21a443499ce85c5a841dbc743ef167c8c437256cefd0,
  10October11:24:28UTC, confirmed nextPositionId1, latest/pending nonce348,
  USD free/custody300,000,000,000raw, AVAX free/custody0, and zero locks/approvals.
  Simulation did not change this checkpoint. The ignored public record is
  `broadcast/SmokeFujiCollateralMargin.s.sol/43113/dry-run/continueFromUsdDeposit-latest.json`.
- Scoped formatting, whitespace and high-severity lint passed. Existing metadata/
  NatSpec warnings and three LayerZero exclusions remain. No production contract
  logic changed; no signing or broadcast was performed for this continuation.

## Remaining release gates

The original package, one-hour policy and activation diff through b2ad2e0f received
clean Almanax diff reviews. Activation scan
`74cbddbf-eaf1-4197-a1f6-789d70848ef7` completed with zero findings; all seven actual
activation receipts were independently verified on9October at blocks59231469–59231482,
followed by a passing read-only full activation checkpoint. These are diff reviews,
not full audits or mainnet clearance. The original smoke diff through40f5e743 also
received a clean Almanax review (`c3ab6e9d-2ecc-4293-85db-b930db5f3fb2`, zero findings).
Those reviews do **not** cover this new continuation and checkpoint-verifier change:
publish the exact new commit with approval and scan it before separately approving
the17-call continuation.
For future deployments, independently verify receipts/code/pointers/owners/balances
and pause gates, approve queueing, wait for the stored deadlines, approve execution,
and verify configuration while still paused. The existing deployment needs neither
redeployment, another delay transition nor another activation. Review this smoke
continuation, separately approve its exact17-call batch, then verify receipts before
approving the two-call withdrawal phase. Rehearse
2x–5x long/short, both collateral pools, partial/full close, repayment/recovery,
liquidation/insurance, fee streaming and pToken withdrawal on that fresh Fuji stack.
The old live Fuji smoke results cannot substitute for these new receipts.

Production-sized Pharaoh capacity, risk weights/fees/caps, cash-insurance budgets,
governance, keeper operation, monitoring and mainnet approval remain unresolved.

# Fuji collateral-preserving liquidation rehearsal

Status: operator, bounded two-signer runner and local tests. No new liquidation broadcast,
price stress, insurance spending, deposit or withdrawal is authorized by this file.
The earlier34-transaction trading approval was consumed by the completed batch.

## Starting checkpoint

The completed runner owns closed positions5–16. The executor's next ID is17.
`LiquidateFujiMarginRunner.s.sol` reuses its existing free margin; it does not mint,
transfer in, approve, deposit, withdraw, or redeem additional user collateral.
All addresses are pinned to the same Fuji deployment. Other chains are rejected.

The source generates transactions from **two separate signers**:

- Existing owner: refreshes/stresses/restores mock feeds and acts as liquidation keeper.
- Dedicated test runner: accrues markets, opens its position and closes a partial-liquidation remainder.

Using the owner as keeper is a test convenience, not a requirement of permissionless
liquidation. The runner receives no admin or price-setting authority. This is not
compatible with the old one-use34-call signer or a single-account Forge broadcast.
Do not export private keys or bypass that runner's allowlist to execute it.

## Proposed scenarios

Each scenario uses **$10-equivalent original collateral and a requested5x position**.
Cases must run in order, from the exact prior completed state; skipped or repeated
cases revert. Fees are limited to$0.10 per open/voluntary close and voluntary
close collateral sales to$2. Those limits do **not** cap liquidation losses.

| Case | ID | Collateral | Direction | Liquidation | Mock AVAX stress price | Maximum insurance cash |
| --- | --- | --- | --- | --- | --- | --- |
|0|17|USD vault|Long|50% partial|$8.70|0|
|1|18|USD vault|Short|50% partial|$11.30|0|
|2|19|USD vault|Long|Full, negative equity|$5|50 mockUSD|
|3|20|USD vault|Short|Full, negative equity|$20|5 mockAVAX|
|4|21|AVAX vault|Long|50% partial|$8.80|0|
|5|22|AVAX vault|Short|50% partial|$11.60|0|
|6|23|AVAX vault|Long|Full, negative equity|$5|50 mockUSD|
|7|24|AVAX vault|Short|Full, negative equity|$20|5 mockAVAX|

Maximum proposed insurance authorization across the suite is100 mockUSD plus10
mockAVAX. These are mock units, not mainnet assets or a proposed production reserve.
Each full case can consume the entire original position collateral. Keeper bonuses
are paid to the owner acting as keeper, not counted as a return to the runner.

Each case refreshes unchanged$1/$10 feeds, accrues four markets, opens one position,
checks healthy liquidation rejection locally, applies the specified mock stress,
liquidates, and restores AVAX to$10. Partial cases then fully close the remainder.
Partial cases generate11 transactions; full cases generate10, for84 across all8.
The healthy-rejection probe is deliberately local-only and not a reverting public
transaction. The full local tests start from block59499119, after the real runner
batch, not the earlier pre-trading fixture.

## Checks and measured local results

The operator verifies exact policy, addresses, owners, prior position history,
existing collateral, no residual borrowing/locks/approvals, and insurance cash.
It then checks:

- Original pTokens remain in the account at entry; entry is healthy.
- Healthy liquidation rejects with the expected risk-engine error.
- Partial liquidation reduces debt, improves health and consumes no insurance.
- Full cases reach negative equity, use positive insurance within the cap, and leave no debt.
- Every completed case has the expected closed/liquidated status and no account residue.
- Both mock prices are restored, with zero aggregate debt and no locked collateral.

In the sequential local rehearsal, insurance consumed was14.808510 mockUSD and
1.957266022685393256 mockAVAX for the USD-collateral full cases, and19.808510
mockUSD and1.457265977085393256 mockAVAX for AVAX collateral. Partial cases used0.
Remaining free pTokens were149205628133 raw USD-vault shares and14759060583 raw
AVAX-vault shares. These are **simulation results**, not guaranteed future balances.

Run tests from `contracts/`:

```sh
CP_FUJI_RPC_URL=https://api.avax-test.network/ext/bc/C/rpc \
FOUNDRY_PROFILE=debt_accounting forge test \
  --match-contract FujiMarginLiquidationRunnerForkTest \
  --fork-url https://api.avax-test.network/ext/bc/C/rpc \
  --fork-block-number 59499119 --threads 1 -vv \
  --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol
```

Without the opt-in RPC the tests skip; that is not a pass. To generate an unsigned
first-case plan against current Fuji state (no key and no broadcast):

```sh
CONFIRM_FUJI_RUNNER_LIQUIDATION=true FOUNDRY_PROFILE=debt_accounting \
forge script script/LiquidateFujiMarginRunner.s.sol:LiquidateFujiMarginRunner \
  --sig 'runScenario(uint8)' 0 \
  --rpc-url https://api.avax-test.network/ext/bc/C/rpc \
  --sender 0x94696d767e65a75581145646960FA0eC886cE5d2 \
  --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol
```

## Before any live execution

Publish/review the runner diff, scan it, and obtain explicit approval for the exact
scenario, collateral loss, keeper bonus, insurance and gas budgets. The existing
round-trip Node runner must not be modified in place or replayed.

These are not atomic scenarios. If execution fails after a stress update, the
price can remain stressed and a position can remain open. A live execution plan
must include separately authorized owner restoration/recovery, receipt-based
stage tracking, and stop-on-failure behavior. Do not resume a partially mined
scenario using this initial-checkpoint script. Never transfer feed ownership to
the test runner to avoid coordinating signatures.

## Bounded two-signer runner

`tools/fuji-liquidation-runner.cjs` has only `check CASE`, `run CASE` and
`recover CASE`, for cases 0–7. Its public execution endpoint and chain are fixed
to Fuji. There are no arbitrary network, signer, recipient or calldata options.
Each case generates a fresh **unsigned** Forge plan, independently decodes its
exact 10/11 calls, and checks the starting checkpoint before accessing a signer.
Both signers' pending nonces must match their mined nonces.

Every case reserves at most **0.025 test AVAX combined across both signers**,
including two optional recovery feed writes. Eight cases therefore reserve no
more than 0.20 test AVAX. The fixed gas price is 125% of the initial RPC suggestion;
there are no gas-price bumps or automatic retries. Insufficient balance or a high
gas quote aborts before signing. Public RPC requests are serialized with at least
200ms between starts, and Forge's read-only fork uses a conservative request-rate
limit. Rate limiting still causes a stop, never a blind transaction retry.
Forge uses a fixed legacy fee solely to generate
the unsigned plan; the actual bounded gas reservation is calculated separately.

The owner signs only through `cast wallet sign --no-hash --account
robinhood-deployer`, with a local keystore password prompt for each owner call.
Only the transaction digest is passed to Cast. The resulting signature must
recover the pinned owner and is attached to the exact chain-43113 transaction.
The runner credential is read internally from the existing ignored, owner-only
file; no private key or password is exported, printed or passed as an argument.
Repeated owner password prompts are intentional: this tool does not cache or
export the administrative key. Signature prompts are not new scope approvals.

All intents and signed hashes are fsynced before submission into separate
`private-keys/fuji-liquidation-v1-case-N.jsonl` journals. The journal contains
public intent fields/hashes, not raw signatures or keys. A suite-wide exclusive
`fuji-liquidation-v1.active` file prevents concurrent run/recovery processes.
Successful exit removes only that active lock, never a case journal. A hard crash
can leave the lock: verify the recorded process has stopped and reconcile the
journal before authorizing its removal. Never delete a journal to enable reruns.

Each transaction checks chain, nonce, policy, feed state, deadlines and gas before
signing and again before broadcast. Only the swap minimum is refreshed from the
current quote; if it changes while signing, execution stops without sending.
Canonical receipts and their actual calldata, sender, nonce, gas and value are
verified. Entry health, healthy-liquidation rejection (read-only call), partial
health improvement/no insurance, full insurance use, debt cleanup and restored
prices are checked separately. No case can be replayed or skipped by the CLI.

Read-only preflight from `contracts/` (no approval flag, signer or public writes):

```sh
node tools/fuji-liquidation-runner.cjs check 0
```

Only **after separate explicit live-case approval**, execute the reviewed case
locally, with the terminal available for owner keystore prompts:

```sh
CONFIRM_FUJI_LIQUIDATION_CASE=0 node tools/fuji-liquidation-runner.cjs run 0
```

Deadlines are generated one hour from the fresh simulation, not from a timestamp
copied from chat. Complete prompts promptly: the stricter 15-minute runtime feed
freshness checks still apply. No mainnet assets, ownership changes or new deposits
are part of this command.

### Interrupted-case recovery

Recovery is a **separately approved, one-attempt, two-transaction price restoration**,
not a resumed scenario. It first reconciles every recorded signed attempt against
canonical receipts and exact transaction envelopes. A reverted but mined call is
known; an absent receipt, unsigned intent, unexpected nonce, replacement transaction,
reorg or externally changed price is not. Uncertainty blocks automated recovery
and requires manual review. Do not guess whether a transaction was sent.

Once explicitly approved for the affected case:

```sh
CONFIRM_FUJI_LIQUIDATION_RECOVERY=0 node tools/fuji-liquidation-runner.cjs recover 0
```

It refreshes mockUSD to $1 and restores mockAVAX to $10 using the owner, with the
original reserved gas price/cap. It does **not** borrow, liquidate, spend insurance,
close, deposit or withdraw. Restoration remains available when new opens are
paused. After restoration, a position may still be open; reconcile its debt and
request a separately reviewed close plan. Recovered cases cannot continue into
later scenarios through this CLI. A second recovery attempt is blocked even if
the first attempt stopped; reconcile before preparing any additional action.

Unit tests: `node --test tools/fuji-liquidation-runner.test.cjs`.
Integration tests use an isolated localhost Anvil fork at block 59499119, port
18548, chain 43113, with `--hardfork cancun --auto-impersonate` and preferably
`--compute-units-per-second 40`. An explicitly recorded newer fixture can be
selected with `FUJI_LIQUIDATION_FORK_BLOCK`; all starting-state guards still apply.
With that disposable fork running:

```sh
FUJI_LIQUIDATION_LOCAL_TEST=true node --test tools/fuji-liquidation-runner.local.test.cjs
```

The local test uses impersonation, not either real key. It exercises all eight
cases and recovery after opening, stressing, liquidating and restoring. The
raw-signing transport is tested separately with ephemeral synthetic keys. These
tests are not evidence of live Fuji liquidation or mainnet readiness.

Verification checkpoint (2026-10-19): **14 new runner unit tests, 12 existing Node
tests, 9 Solidity liquidation fork tests, 50 existing Fuji operator tests, and the
complete localhost integration test pass with no skips**. The integration mined
84 normal scenario transactions plus 42 calls across all four interrupted-case
recovery checks: 126 calls, 132220770 gas in total, on the isolated fork only.
Every normal case restored baseline prices and cleared debt/locks. Recovery
restored both feeds while deliberately retaining the open position; the harness
requires the specific remaining-debt assertion, not merely any RPC exception.

A temporary user-provided RPC resolved the public endpoint's HTTP 429/historical
state access failures. Chain 43113, the canonical block 59499119 hash and historical
executor code were verified before use. Its URL was kept in memory behind a
read-only local proxy, not placed in tracked files. The harness also now creates
a fresh ethers client after each VM snapshot rewind, clearing monotonic block and
receipt caches that could otherwise stall receipt waiting; waits are bounded.
A separate read-only current-Fuji checkpoint passed at block59687674, with owner
nonce380 and runner nonce34. No real signer was loaded or public transaction sent.
Publication/security review and explicit live-case approval remain required.

## Mainnet liquidity and keeper boundary

The margin trade is AVAX/USDC; its current `PharaohCLRouterAdapter` uses one pinned
Pharaoh concentrated-liquidity pool. It needs enough **active depth**, in both
directions and during liquidation stress. It does not create LP positions or
require Peridot to seed a new pool. An alternate pool type would require a
separately reviewed adapter/integration, not just a configuration flag.

The two collateral vaults are separate USDC/USDt and sAVAX/WAVAX LP strategies.
Read-only mainnet checks at block97613094 (2026-10-15T11:37:20Z) found both owned
by Safe0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12, with rebalancer
0x94696d767e65a75581145646960FA0eC886cE5d2; both were unpaused but maxDeposit=0.
That role assignment does not prove a scheduler is running or that mainnet
liquidity is adequate. No vault settings were changed.

The separate LP-Vaults source has `onlyRebalancer` operations `rebalance()` and
`deployIdle()`; governance retains ownership. A funded, narrowly permissioned
automation service with monitored range/price/loss guards is needed for an
actively managed public strategy. Pharaoh documents that out-of-range concentrated
liquidity becomes inactive and stops earning trading fees until price returns or
the position is adjusted: [Pharaoh farming guide](https://docs.phar.gg/pages/farming).

Margin liquidation is a different service: executor.liquidate is permissionless,
but calls do not happen automatically. Launch requires a tested, funded operator,
failure alerts and operational coverage. LP range automation cannot substitute for
liquidation monitoring. Reward harvest/compounding is another workflow: the current
LP-vault handoff specifies Safe-only bounded reward processing and a pending public
anti-sniping policy; a rebalancer does not automatically authorize compounding.

Do not infer public launch readiness from mock tests, the rebalancer address, or a
clean automated diff scan. Current real-route capacity, strategy exits, risk weights,
insurance, reward policy, governance and keeper operation still need review.

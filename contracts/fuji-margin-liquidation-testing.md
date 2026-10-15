# Fuji collateral-preserving liquidation rehearsal

Status: proposed operator and local-fork tests only. No new liquidation broadcast,
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

Publish/review the operator, complete its bounded two-signer execution mechanism,
and obtain explicit approval for the exact scenario, collateral loss, keeper
bonus, insurance and gas budgets. The existing round-trip Node runner must not be
modified in place or replayed. No new signing mechanism is provided by this package.

These are not atomic scenarios. If execution fails after a stress update, the
price can remain stressed and a position can remain open. A live execution plan
must include separately authorized owner restoration/recovery, receipt-based
stage tracking, and stop-on-failure behavior. Do not resume a partially mined
scenario using this initial-checkpoint script. Never transfer feed ownership to
the test runner to avoid coordinating signatures.

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

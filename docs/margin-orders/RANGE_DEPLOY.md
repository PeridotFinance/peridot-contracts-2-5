# Range take-profit: production deployment (prepared for after the interview; nothing sent)

**Runs after the 15 to 17 Nov orders ceremony.** It reads that ceremony's journal.
- **Script:** `contracts/script/orders/DeployRangeTakeProfit.s.sol`, profile `robinhood_orders`.
- **Signers:**
  - a throwaway key for the 7 creations, with gas only, about 0.0001 ETH;
  - **the Ledger for 2 signatures,** the batch schedule and, at least 3,600 s later, the execute.

## What the batch does (one atomic timelock batch)

| # | target | call |
| --- | --- | --- |
| 1 | executor ProxyAdmin `0x561f` | `upgradeAndCall(executor, v3, initializeRange(custodian, adapter v2))`: range hooks; **order executor handed from adapter v1 to v2** |
| 2 | registry ProxyAdmin | `upgradeAndCall(registry, V2, initializeV2(adapter v2, custodian))`: same handover; a TP is refused while a band is active |
| 3 | risk engine ProxyAdmin | `upgradeAndCall(risk, impl, initializeRangeCustodian(custodian))`: bands counted at the oracle |
| 4 | liquidator ProxyAdmin | `upgradeAndCall(liquidator, impl, initializeRangeCustodian(custodian))`: bands removed before seizure |
| 5 to 7 | custodian | `setPreset(1, 2, 3)`: 100, 300 and 490 ticks above the market (1%, 3%, 5%), each 200 wide (2%) |
| 8 | custodian | `setFeeSplit(7000, 2000, 1000, protocol, reserve)` |
| 9 | custodian | `setUnwinders(liquidator, adapter v2)` |

- **Why one batch:** steps 1 and 2 must happen together, because `closePositionFor` accepts only the executor's
  `orderExecutor`.
- **Why a pair:** the risk engine's first wiring is a proxy-admin reinitializer inside the batch, so the timelock's delay
  is the delay. Later changes go through the risk engine's queue and apply (owner, the margin config's action delay; refused
  while bands are active).
  - **This is a choice you can reverse:** the alternative is a direct Ledger queue and, an hour later, an apply after the
    batch. That is 4 signatures in total.
- **Until the batch runs, the custodian refuses every band.**

## Commands

```sh
cd contracts
export RANGE_PUBLIC_SENDER=$DEPLOYER ORDERS_JOURNAL=deployments/orders-mainnet.json RANGE_JOURNAL=deployments/range-mainnet.json
export RANGE_PROTOCOL_RECIPIENT=<decide> RANGE_RESERVE_RECIPIENT=<decide>      # required; no defaults; never the old key
export RANGE_SOURCE_COMMIT=$(git rev-parse HEAD)
FOUNDRY_PROFILE=robinhood_orders forge script script/orders/DeployRangeTakeProfit.s.sol:DeployRangeTakeProfit \
  --rpc-url https://rpc.mainnet.chain.robinhood.com --sender $DEPLOYER --keystore <throwaway> --broadcast --slow
J=deployments/range-mainnet.json; R=https://rpc.mainnet.chain.robinhood.com; L=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD
FOUNDRY_PROFILE=robinhood_orders forge script script/orders/DeployRangeTakeProfit.s.sol:DeployRangeTakeProfit --sig 'check(string)' $J --rpc-url $R
cast send 0x6797FB8Ce049B42C5BC2b42Bf76c6d15C7B12498 $(jq -r .scheduleCalldata $J) --ledger --from $L --gas-limit 3000000 --rpc-url $R
# at least 3,600 s later; check again first
cast send 0x6797FB8Ce049B42C5BC2b42Bf76c6d15C7B12498 $(jq -r .executeCalldata $J) --ledger --from $L --gas-limit 10000000 --rpc-url $R
FOUNDRY_PROFILE=robinhood_orders forge script script/orders/DeployRangeTakeProfit.s.sol:DeployRangeTakeProfit --sig 'verify(string)' $J --rpc-url $R
```

**The script refuses unless the ceremony state is exactly live:**
- the executor runs the ceremony's implementation, at initializer version 2, with adapter v1 as its order executor;
- the registry is at version 1 and uses adapter v1;
- the risk engine and the liquidator are at version 1;
- all four ProxyAdmins are the timelock's;
- the timelock's delay is at least 3,600 s, and the Ledger is proposer and executor.

**After broadcasting, it checks:**
- each implementation's code equals the build's;
- the custodian proxy is the timelock's and its admin is the timelock;
- the custodian is wired to the live contracts and the NVDA pool;
- adapter v2's wiring;
- the deployer holds nothing.

**`verify` checks after the execute:**
- versions 3, 2, 2 and 2;
- every wiring, including adapter v1 now refused (`ExecutorError(60)`);
- presets, fee split and unwinders;
- positions kept.

**The keeper** (`tools/orders/orders_keeper.py`) reads `registry`, `rangeCustodian` and `executor` from the range
journal.

## Evidence (2026-11-07)

- **`test/orders/RangeTakeProfitDeployFork.t.sol`,** 4/4 at L2 108,387,355:
  - the ceremony replayed with its own script and pair, then this batch: early execute refused, `verify`, runs once;
  - refusal when the ceremony state differs;
  - the custodian failing closed before the batch;
  - a preset-3 order on live position 4 finalised after the batch, with the TP refused (code 7).
- **`tools/orders/rehearse_range_deploy.sh`** (anvil, `--broadcast`), fork at L2 108,398,868:
  - ceremony: 2 Ledger transactions, 58,771 and 94,131 gas;
  - 7 creations, 0.000093 ETH of gas;
  - `check` ok; Ledger schedule 125,951 gas; early execute refused; execute 487,341 gas; `verify` passed.
- **A mainnet dry run is only possible after the ceremony,** because the preconditions read the ceremony's state.

## Open before signing

- **Fee recipients (operator, 2026-11-09):**
  - **Protocol share:** still unconfirmed: the Robinhood Safe or the Ledger. The operator will confirm which.
  - **Reserve share (decided):** to the NVDA/USDG pair's loss reserve `0x806b182B050f7EcF908758dD6bBF91DB8B2212aF`,
    credited through its `deposit(pairId, token, amount)` for pair id
    `0xe2050352f4346597cc69d2776d99ae60c9440dfc28f9406ce66be0bbe3fb6b06`.
    - A plain token transfer would not be credited to the pair.
    - The custodian change that deposits instead of transferring is being built separately.
  - The margin config's treasury still points at the old key. Do not reuse it.
- **Decided 2026-11-09:** the custodian setting stays inside the timelock batch (2 Ledger signatures). Every ceremony
  that touches the executor is gated on the sequence-replay tests: `testCeremonyThenRangeBatchHandsOverFromAdapterV1ToV2`
  and `RangeTakeProfitDeployFork`.
- **The range keeper's host and wallet:** the same process as the order keeper (see `RANGE_TAKE_PROFIT.md`).
- **A fidelity note:** on this branch the replayed ceremony uses this branch's 6-argument adapter with custodian 0 as
  adapter v1. The ceremony's real artifact is the 5-argument adapter on `feat/margin-order-interface`, which behaves the
  same for the handover.

# Robinhood TP/SL: registry deployment and executor upgrade (prepared, not sent)

**Prepared 2026-11-06.** The registry is `MarginOrderRegistry` (this branch). Nothing below has been sent.

- **Signers:** a throwaway key sends 4 creations, with gas only. The Ledger `0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD`
  signs 2: the timelock schedule and the execute.
- **Script:** `contracts/script/orders/DeployRobinhoodOrders.s.sol`, profile `robinhood_orders`. That profile uses the live
  margin stack's compiler settings: 0.8.26, cancun, via-IR, 1 optimizer run.

## The registry

`contracts/contracts/margin/orders/MarginOrderRegistry.sol` follows the deployment convention in `SPEC.md`. The
script deploys it from its build artifact.

## 1. Deploy (throwaway key, 4 creations)

```sh
cd contracts
export ORDERS_PUBLIC_SENDER=$DEPLOYER ORDERS_JOURNAL=deployments/orders-mainnet.json
export ORDERS_SOURCE_COMMIT=$(git rev-parse HEAD)
FOUNDRY_PROFILE=robinhood_orders forge script script/orders/DeployRobinhoodOrders.s.sol:DeployRobinhoodOrders \
  --rpc-url https://rpc.mainnet.chain.robinhood.com --sender $DEPLOYER --keystore <throwaway keystore> --broadcast --slow
```

**What it deploys, in order:**
1. the new executor implementation;
2. the `MarginOrderRegistry` implementation;
3. the registry proxy, initialized with the adapter address predicted from the deployer nonce;
4. `RobinhoodMarginCloseAdapter(executor, registry proxy, oracle 0x6315, quoter 0xeD3c, config 0x09F9)`.

**It refuses to run unless:**
- the chain is 4663;
- the executor's ProxyAdmin `0x561f...F9B8` is owned by the timelock;
- the executor still runs `0xD44a1d...Fbd8`, with initializer version 1;
- the timelock delay is at least 3,600 s and the Ledger is proposer and executor;
- the journal file does not exist yet.

**After broadcasting, it asserts:**
- the adapter landed on the predicted address;
- the executor implementation's code equals this build's artifact;
- the registry's `adapter()` and the adapter's `registry()` point at each other;
- the registry ProxyAdmin is owned by the timelock;
- the registry implementation's code equals this build's, and it cannot be initialized;
- the registry's admin is the timelock, it is not paused, and `nextOrderId` is 1;
- the deployer holds nothing: no proxy ownership, and no registry owner or admin.

The journal records every address, the operation id, the source commit and both timelock calldatas.

## 2. Ledger: the timelock pair

The operation is `ProxyAdmin(0x561f).upgradeAndCall(executor 0x6A45...8977, newImplementation, initializeOrderExecutor(adapter))`,
with salt `keccak256("peridot-margin-orders-executor-upgrade-v1")` and delay 3,600 s.

```sh
J=deployments/orders-mainnet.json; R=https://rpc.mainnet.chain.robinhood.com; L=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD
FOUNDRY_PROFILE=robinhood_orders forge script script/orders/DeployRobinhoodOrders.s.sol:DeployRobinhoodOrders --sig 'check(string)' $J --rpc-url $R
cast send 0x6797FB8Ce049B42C5BC2b42Bf76c6d15C7B12498 $(jq -r .scheduleCalldata $J) --ledger --from $L --gas-limit 1000000 --rpc-url $R
# at least 3,600 s later; check again first:
FOUNDRY_PROFILE=robinhood_orders forge script script/orders/DeployRobinhoodOrders.s.sol:DeployRobinhoodOrders --sig 'check(string)' $J --rpc-url $R
cast send 0x6797FB8Ce049B42C5BC2b42Bf76c6d15C7B12498 $(jq -r .executeCalldata $J) --ledger --from $L --gas-limit 1000000 --rpc-url $R
FOUNDRY_PROFILE=robinhood_orders forge script script/orders/DeployRobinhoodOrders.s.sol:DeployRobinhoodOrders --sig 'verify(string)' $J --rpc-url $R
```

`verify` must print `verified: ...`. It checks:
- the implementation slot;
- initializer version 2;
- `orderExecutor == adapter`;
- positions kept;
- both ProxyAdmins owned by the timelock;
- the operation done;
- a simulated `closePositionFor` from any other address reverting `ExecutorError(60)`.

Abort before the execute with `cancel(operationId)` from the Ledger. There is no market-hours condition: the upgrade
does not read the oracle.

## What changes and what does not

- **Inert until orders exist.** The adapter only acts when the registry calls it, and only for a position's real owner. Its
  minimums come from the margin oracle and quoter, with `adapterData` empty.
- **Liquidation, owner closes and every stored position are unchanged** (fork-tested before and after).
- **Wired once:** `orderExecutor` is set inside the upgrade (`reinitializer(2)`), and the adapter's `registry` is
  immutable.
  - The registry can be upgraded behind its own proxy, by the timelock.
  - Replacing the adapter needs another executor implementation with a `reinitializer(3)` setter. That is not built.

## 3. Keeper (after verify)

The keeper is permissionless: its wallet needs gas only, and it receives nothing.

```sh
python3 contracts/tools/orders/orders_keeper.py --journal contracts/deployments/orders-mainnet.json \
  --sender $ORDERS_KEEPER --keystore <keeper keystore> --password-file <file> --execute
```

- It runs `executeOrder` for orders that `canExecute` reports as executable.
- It sweeps expired orders and orders on closed positions.
- It waits on a stale oracle, an untouched trigger or a pause.
- Every send is simulated first, with a gas-price cap and at most 10 sends per step.

## Evidence (2026-11-06)

- **Registry unit suite:** `test/orders/MarginOrderRegistry.t.sol`, 32/32, including a 256-run fuzz test of the open-set
  bookkeeping.
- **Mutants:** `tools/orders/mutate_registry.py` kills every mutant (see the commit). One equivalent mutant is
  documented in the tool.
- **Storage layout:** `tools/orders/check_registry_layout.py`, against the snapshot `tools/orders/registry-layout.json`.
- **Fork suite:** `test/orders/RobinhoodOrdersDeployFork.t.sol`, 7/7 at L2 107,629,698 against the live stack, using the
  script's own deploy with the real registry.
  - **Timelock pair:** the real timelock and ProxyAdmin, with the Ledger: `check`, the schedule, a refused early execute,
    the execute, and `verify`. Positions are byte-identical, and the operation runs only once. Only the Ledger can
    schedule.
  - **Before the upgrade:** an order whose trigger is crossed still cannot close, and stays `OPEN`.
  - **Live position 4:** a stranger cannot create an order. `canExecute` reports 0 for the take-profit and 6 for the
    stop-loss. A keeper executed the take-profit: the position closed, 2,779,322,504 pUSDG units were credited to its
    owner, and the stop-loss was cancelled (mutual cancellation).
  - **Stale feed (13 h):** `canExecute` reports 5 and `executeOrder` reverts `OracleUnavailable`. After a fresh answer, the
    order executes.
  - **Liquidation:** the same outcome and return data with and without open orders.
  - **Pause:** only the timelock can pause; a pause stops execution only.
- `test/orders/RobinhoodOrderCloseFork.t.sol`: 10/10 at the same pin.
- **Anvil script rehearsal:** `bash contracts/tools/orders/rehearse_orders.sh`, fork at L2 107,636,516.
  - 4 deployments, 0.00013 ETH of gas. Ledger schedule 58,771 gas, execute 93,979 gas, then `verify` passed.
  - The owner of position 4 placed a far stop-loss and a take-profit at the oracle price.
  - **Keeper:** the dry run reported the take-profit due and the stop-loss waiting. With `--execute` it sent the
    take-profit (2,231,254 gas). The position closed, the stop-loss was cancelled, and the next pass had nothing to do.
  - **On anvil the markets' `accrualBlockNumber` is set to the anvil block.** Anvil's `block.number` is the L2 height,
    while the markets accrue on the native L1 number. Without that, the close path sees about 81M blocks of interest and
    its swap floor refuses the trade (`V4TooLittleReceived`). The keeper treats that error as a wait, since on mainnet it
    means the pool is further from the oracle than the order allows.

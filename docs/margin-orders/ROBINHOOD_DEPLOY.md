# Robinhood TP/SL: registry deployment and executor upgrade (prepared, not sent)

**Prepared 2026-11-06. Ready for when the registry implementation arrives.** Nothing below has been sent.

- **Signers:** a throwaway key sends 4 creations, with gas only. The Ledger `0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD`
  signs 2: the timelock schedule and the execute.
- **Script:** `contracts/script/orders/DeployRobinhoodOrders.s.sol`, profile `robinhood_orders`. That profile uses the live
  margin stack's compiler settings: 0.8.26, cancun, via-IR, 1 optimizer run.

## What the registry must provide

The registry follows the deployment convention in `SPEC.md`:
- a no-argument constructor that disables initializers;
- `initialize(adapter, admin)`, with admin set to the timelock;
- `adapter()`;
- OZ 5 `TransparentUpgradeableProxy`.

To use it, put the source under `contracts/contracts/margin/orders/` and set
`ORDERS_REGISTRY_ARTIFACT=<File>.sol:<Contract>`.

## 1. Deploy (throwaway key, 4 creations)

```sh
cd contracts
export ORDERS_PUBLIC_SENDER=$DEPLOYER ORDERS_REGISTRY_ARTIFACT=<File>.sol:<Contract> ORDERS_JOURNAL=deployments/orders-mainnet.json
export ORDERS_SOURCE_COMMIT=$(git rev-parse HEAD)
FOUNDRY_PROFILE=robinhood_orders forge script script/orders/DeployRobinhoodOrders.s.sol:DeployRobinhoodOrders \
  --rpc-url https://rpc.mainnet.chain.robinhood.com --sender $DEPLOYER --keystore <throwaway keystore> --broadcast --slow
```

**What it deploys, in order:**
1. the new executor implementation;
2. the registry implementation;
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
- the registry implementation cannot be initialized;
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

## Evidence (2026-11-06)

- `test/orders/RobinhoodOrdersDeployFork.t.sol`, 3/3 at L2 107,575,444 against the live stack. It uses the script's own
  deploy, with `RehearsalRegistryStub`, a test-only stand-in that is **not a registry**. Results:
  - The real timelock and ProxyAdmin, with the Ledger: `check`, the schedule, a refused early execute, the execute, and
    `verify`. Every position is byte-identical, and the operation cannot run twice.
  - Only the Ledger can schedule.
  - Live position 4 was closed through stub → adapter → `closePositionFor`, and 2,746,084,854 pUSDG units were credited to
    its owner in the margin vault.
    - That needs an active position. If none exists at the pin, the test logs that and still verifies the deploy path.
- `test/orders/RobinhoodOrderCloseFork.t.sol`, 10/10 at the same pin under this profile.
- **Anvil script rehearsal (`--broadcast`, Ledger unlocked):**
  - 4 deployments, 0.00011 ETH of gas.
  - `check` ok; Ledger schedule 58,771 gas, then `check` showed it scheduled.
  - An early execute was refused; the execute took 93,979 gas.
  - `verify` passed.

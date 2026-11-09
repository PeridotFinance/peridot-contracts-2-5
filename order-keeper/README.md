# Avalanche order keeper

Off-chain process that executes take-profit / stop-loss orders on the Avalanche `MarginOrderRegistry`. Execution is permissionless on chain: the keeper wallet holds **gas only** and receives nothing; proceeds go to the position owner through the existing close path. Full description, hosting and test status: `docs/deployment-handoffs/avalanche-order-keeper.md`.

**Status: built and tested on a local fork. NOT run against mainnet.** The registry and the close adapter are deployed only in the margin rehearsal; there are no mainnet addresses yet, so the checked-in configuration is a template that the process refuses to start with.

## What one cycle does

1. Read at the **head** (no archive state): `nextOrderId`, the wiring (`registry.adapter()`, `adapter.registry()`, `adapter.executor()`), `paused()`.
2. Discover orders **by id**: new ids from `highWater` up to `nextOrderId`, plus every id last seen OPEN. `getOrder` + `canExecute` per id in Multicall3 batches. No event scan is needed.
3. Decide from `canExecute`: reason 0 execute; 2 / 3 / 4 (expired, position inactive, owner changed) sweep; 5 / 6 / 7 (oracle, trigger, paused) wait; 1 final.
4. For each due order (stop-losses first), simulate `executeOrder(id, "0x")` from the keeper address; a revert puts the order on a doubling cooldown (not retried every cycle). Persist a **pending marker**, send, **read back** from the receipt (events, order, position, owner's vault balance, keeper balances), clear the marker. Any mismatch **halts**.
5. Optionally cross-check `OrderCreated` through the separate log endpoint (bounded chunks, pacing, 429 back-off). Discovery never depends on it.

## Commands

```
npm ci --ignore-scripts && npm run build
ORDER_KEEPER_CONFIG=<file> node dist/src/main.js validate-config   # config only
ORDER_KEEPER_CONFIG=<file> node dist/src/main.js check             # one DRY cycle: decisions + simulations, sends and writes nothing
ORDER_KEEPER_CONFIG=<file> node dist/src/main.js run               # the loop (signs and sends)
```

Exit codes: 0 ok, 1 cycle failed / halted, 2 usage, 78 refused to start (config, endpoint, password, signer, state file).

## Configuration and secrets

`config/order-keeper.example.json` is the template (every undecided value is `UNSET`, and it is refused). The file holds **public values only**. Secrets are environment variables:

| Variable | Use |
| --- | --- |
| `AVALANCHE_MAINNET_RPC_URL` | state endpoint (a free-tier node is enough) |
| `AVALANCHE_LOGS_RPC_URL` | separate log endpoint for the optional cross-check |
| `ORDER_KEEPER_KEYSTORE_PASSWORD` | Foundry keystore password (the variable name is `keeper.passwordEnv`) |
| `ORDER_KEEPER_ALERT_TELEGRAM_TOKEN` / `_CHAT_ID`, `ORDER_KEEPER_ALERT_WEBHOOK_URL` | alert channel, if not `log` |

State file (`monitor.statePath`, on the mounted volume): `highWater`, open ids, cooldowns, send history, `pending`, `halted`, alert state. **A human clears `halted` / `pending`** after checking the wallet's transactions and the order.

## Tests

```
npm test                                   # 51 unit tests (node --test, fakes; no network)
AVALANCHE_MAINNET_RPC_URL=... npm run test:fork   # fork tests, under the shared lock /tmp/pilot-fork.lock; builds the margin stack with the ceremony wrapper
```

The fork tests (9 scenarios) passed in one pinned run (section 6 of the handoff). The fork run needs `forge` and `anvil`, the endpoint in the environment, and the compiled mock feeds (`ORDER_KEEPER_FORGE_OUT`, default `operator/.forge-out`; `test/fork/run.sh` sets it to its own build directory). The fork block is pinned by `run.sh` (file in $TMPDIR, reused on a re-run). A 429 from the endpoint stops the run (exit 42): wait 20 minutes and retry at most once; do not switch providers.

## Layout

`src/`: `keeper.ts` (the cycle), `decide.ts` (pure decision), `readback.ts` (pure verification), `orders.ts` (reads), `errors.ts` (revert classes), `logaudit.ts`, `state.ts`, `config.ts`, `main.ts`; copied from `operator/src`: `signer.ts`, `txkit.ts`, `alerts.ts`, `logpace.ts`, `mask.ts`, `multicall.ts`. `test/fakeworld.ts` is the in-memory registry/executor/provider used by the unit tests; `test/fork/` has the fork harness, the margin bring-up (copied from `operator/scripts/margin-fork-lib.ts`) and the fork tests.

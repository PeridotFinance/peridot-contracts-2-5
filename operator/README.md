# operator/ — cash-only pilot operator tooling

**Steps 1-2 of the build plan: a read-only monitor and the treasury keeper.** It reads Avalanche C-Chain, evaluates the treasury default-detection rule (with the Uniswap V3 reference price), runs the health checks and raises de-duplicated alerts. Key handling is confined to `src/signer.ts` (Foundry keystore, password from the environment) and `src/keeper.ts` (the treasury keeper, `run` only); every other module is read-only and a test fails the build if that changes. The liquidator executor and the operator setup steps are later steps and are **not started**.

Status: DRAFT, not audited, not deployed, no launch approval implied. Spec: `docs/deployment-handoffs/avalanche-cash-only-treasury-repayment.md` section 2 (rule, truth table, 2.3.1 reference price); plan: `avalanche-cash-only-build-plan-and-audit-scope.md`; this step: `avalanche-cash-only-operator-monitor.md`.

## Use
```
npm ci --ignore-scripts          # own lockfile; one runtime dependency (ethers 5.8.0)
npm test                         # 59 unit tests, no network
npm run build:contracts          # forge build (debt_accounting profile) into .forge-out, needed by the fork tests only
AVALANCHE_MAINNET_RPC_URL=... npm run test:fork   # 30 fork tests on a local anvil fork (needs anvil and an archive RPC)
OPERATOR_CONFIG=<file> AVALANCHE_MAINNET_RPC_URL=... node dist/src/main.js check    # one cycle, JSON report, alerts NOT delivered
OPERATOR_CONFIG=<file> ... node dist/src/main.js run                                 # loop, alerts delivered
```
Exit codes: `0` ok, `1` a critical finding (check), `2` usage, **`78` refused to start**.

## It refuses to start while anything undecided is unset
`config/pilot.example.json` is the checked-in template; every undecided value is the placeholder `UNSET` and the process refuses it (exit 78, every problem listed): **operators** (two, names and public addresses), **signer type**, **alert channel**, **slippage bound**, the TWAP pool **liquidity floor**, the treasury address and the deployment addresses/block. Also refused: no RPC endpoint in the environment, no alert credentials in the environment for the chosen channel, a config file that contains a URL with a key, a 32-byte hex string or key words. Secrets are read from the environment only (`AVALANCHE_MAINNET_RPC_URL`, `OPERATOR_ALERT_TELEGRAM_TOKEN` + `OPERATOR_ALERT_TELEGRAM_CHAT_ID`, or `OPERATOR_ALERT_WEBHOOK_URL`); every printed string passes through `mask()`.

## Layout
`src/detect.ts` the rule (pure, port of `TreasuryDefaultDetector`); `src/reference.ts` + `src/tickmath.ts` the TWAP reference (integer Uniswap tick math); `src/chain.ts` + `src/multicall.ts` block-pinned reads with interest accrued first inside one batch; `src/borrowers.ts` event index with cursor, reorg margin and full re-scan cross-check; `src/health.ts` oracle/market/operator/treasury checks; `src/alerts.ts` de-duplication, 1 h / 4 h / 24 h escalation, sinks; `src/monitor.ts` one cycle; `src/main.ts` CLI; `src/keeper.ts` + `src/signer.ts` the treasury keeper and the external signer; `src/backing.ts` unrecoverable debt; `scripts/compute-min-pool-liquidity.ts` the liquidity floor; `src/config.ts` schema and refusal; `src/mask.ts` secret masking. Tests: `test/*.test.ts` (unit), `test/fork/*` (anvil fork, private RPC through a local pass-through proxy so the URL is never a process argument).

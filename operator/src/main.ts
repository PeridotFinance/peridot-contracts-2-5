// Entry point.   node dist/src/main.js check [--live-alerts]   one cycle, prints a JSON report
//                node dist/src/main.js run                      loop (alerts delivered)
//                node dist/src/main.js validate-config          only validate the configuration
// REFUSES TO START (exit 78) while any operator decision is unset (operators, signer type, alert channel, slippage bound, ...) or the RPC
// endpoint / alert credentials are missing from the ENVIRONMENT. Exit codes: 0 ok, 1 critical finding present (check), 2 usage, 78 config.
// Everything printed is passed through mask(). No key is read, accepted or stored here.
import fs from "node:fs";
import { providers } from "ethers";
import { AlertManager, MemorySink, createSink } from "./alerts";
import { checkPoolIdentity } from "./reference";
import { ConfigError, findSecretsInConfigText, requireRpcUrlFromEnv, requireValidConfig } from "./config";
import type { MonitorConfig } from "./config";
import { crossCheckIndex, loadState, saveState } from "./borrowers";
import { emptyMonitorState, reportBlind, runCycle } from "./monitor";
import { keeperStep, verifySigner } from "./keeper";
import type { KeeperState } from "./keeper";
import { executorStep, verifyExecutorSigner } from "./executor";
import type { ExecutorState } from "./executor";
import { KeystoreSigner } from "./signer";
import type { ExternalSigner } from "./signer";
import type { MonitorState } from "./monitor";
import { mask, safeError } from "./mask";
import { CHAIN_ID, MULTICALL3 } from "./constants";
import { MULTICALL3_ABI } from "./abi";

const EX_CONFIG = 78;

export function loadConfig(env: NodeJS.ProcessEnv = process.env, argv: string[] = process.argv.slice(2)): MonitorConfig {
  const i = argv.indexOf("--config");
  const file = (i >= 0 ? argv[i + 1] : undefined) ?? env.OPERATOR_CONFIG;
  if (!file) throw new Error("no configuration: set OPERATOR_CONFIG (or pass --config <file>); the checked-in template is config/pilot.example.json and it is REFUSED while it contains placeholders");
  const text = fs.readFileSync(file, "utf8");
  const secrets = findSecretsInConfigText(text);
  if (secrets.length) throw new Error(`the configuration file must not contain secrets: found ${secrets.join("; ")}. Secrets go in the environment.`);
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    throw new Error("the configuration file is not valid JSON");
  }
  return requireValidConfig(raw);
}

async function buildContext(cfg: MonitorConfig) {
  const url = requireRpcUrlFromEnv();
  const provider = new providers.StaticJsonRpcProvider(url, { chainId: CHAIN_ID, name: "avalanche" });
  const net = await provider.send("eth_chainId", []);
  if (parseInt(net, 16) !== CHAIN_ID) throw new Error(`RPC chain id ${parseInt(net, 16)} is not ${CHAIN_ID}`);
  if ((await provider.getCode(MULTICALL3)) === "0x") throw new Error("Multicall3 not deployed at the expected address");
  void MULTICALL3_ABI;
  // eth_getLogs range probe: the borrower index and the keeper's on-chain daily-cap check scan events in chunks of monitor.logChunkBlocks.
  // Some plans allow only a handful of blocks per request (a free tier allowed 10): refuse to start rather than fail later, mid-incident.
  try {
    const head = await provider.getBlockNumber();
    await provider.getLogs({ address: cfg.deployment.pUsdc, fromBlock: Math.max(1, head - cfg.monitor.logChunkBlocks + 1), toBlock: head });
  } catch (e) {
    throw new Error(`the RPC endpoint does not serve eth_getLogs over monitor.logChunkBlocks (${cfg.monitor.logChunkBlocks}) blocks: ${safeError(e)}. Upgrade the plan or lower logChunkBlocks to the endpoint's limit (a free tier allowed 10)`);
  }
  const identity = await checkPoolIdentity(provider);
  return { provider, cfg, poolIdentityOk: identity === null, identityProblem: identity };
}

async function main(): Promise<number> {
  const cmd = process.argv[2] ?? "";
  if (!["check", "run", "validate-config"].includes(cmd)) {
    console.error("usage: main.js check [--live-alerts] | run | validate-config   (configuration: OPERATOR_CONFIG or --config <file>; secrets: environment only)");
    return 2;
  }
  let cfg: MonitorConfig;
  try {
    cfg = loadConfig();
  } catch (e) {
    console.error(e instanceof ConfigError ? e.message : `configuration refused: ${safeError(e)}`);
    console.error("the process did not start");
    return EX_CONFIG;
  }
  if (cmd === "validate-config") {
    console.log("configuration valid");
    return 0;
  }
  const live = cmd === "run" || process.argv.includes("--live-alerts");
  let sink;
  try {
    requireRpcUrlFromEnv();
    sink = live ? createSink(cfg) : new MemorySink();
  } catch (e) {
    console.error(`start refused: ${safeError(e)}`);
    return EX_CONFIG;
  }
  const ctx = await buildContext(cfg);
  // the treasury keeper pays ONLY in `run` (never in `check`): it needs the keystore password in the environment and a signer whose address is the configured treasury address
  let signer: ExternalSigner | undefined;
  let execSigner: ExternalSigner | undefined;
  if (cmd === "run" && cfg.executor.enabled) {
    try {
      execSigner = await KeystoreSigner.load(ctx.provider, cfg.executor.keystorePath, cfg.executor.passwordEnv);
      await verifyExecutorSigner(execSigner, cfg, ctx.provider);
    } catch (e) {
      console.error(`start refused: liquidator executor signer: ${safeError(e)}`);
      return EX_CONFIG;
    }
  }
  if (cmd === "run" && cfg.keeper.enabled) {
    try {
      signer = await KeystoreSigner.load(ctx.provider, cfg.keeper.keystorePath, cfg.keeper.passwordEnv);
      await verifySigner(signer, cfg, ctx.provider);
    } catch (e) {
      console.error(`start refused: treasury keeper signer: ${safeError(e)}`);
      return EX_CONFIG;
    }
  }
  const loaded = loadState<MonitorState>(cfg.monitor.statePath, emptyMonitorState(cfg));
  const state0: MonitorState = { ...emptyMonitorState(cfg), ...loaded, keeper: { ...emptyMonitorState(cfg).keeper, ...(loaded.keeper ?? {}) }, executor: { ...emptyMonitorState(cfg).executor, ...(loaded.executor ?? {}) } };
  const alerts = new AlertManager(sink, cfg.monitor.escalationSeconds, state0.alerts);
  let state = state0;
  const once = async (): Promise<number> => {
    try {
      const out = await runCycle(ctx, state, alerts);
      state = out.state;
      // daily full re-scan of the events from the deployment block against the incremental index
      const nowS = out.report.blockTimestamp;
      if (nowS - state.lastIndexCrossCheckAt >= 86_400) {
        const diff = await crossCheckIndex(ctx.provider, cfg.deployment.pUsdc, state.index, cfg.deployment.deploymentBlock, out.report.blockNumber, cfg.monitor.logChunkBlocks);
        if (diff.missingFromIndex.length > 0) await alerts.raise({ key: "index:incomplete", severity: "crit", message: `the borrower index misses ${diff.missingFromIndex.length} account(s) found by the full re-scan: ${diff.missingFromIndex.slice(0, 5).join(", ")}`, audience: "monitor-operator" }, nowS);
        state = { ...state, lastIndexCrossCheckAt: nowS, index: { ...state.index, borrowers: [...new Set([...state.index.borrowers, ...diff.missingFromIndex])].sort() } };
      }
      saveState(cfg.monitor.statePath, state);
      if (signer) {
        const k = await keeperStep(
          { ctx, signer, alerts, persist: (ks: KeeperState) => { state = { ...state, keeper: ks }; saveState(cfg.monitor.statePath, { ...state, alerts: alerts.toJson() }); } },
          state.keeper,
          out.report,
        );
        state = { ...state, keeper: k.state, alerts: alerts.toJson() };
        saveState(cfg.monitor.statePath, state);
        if (k.paid.length || k.skipped.length) console.log(mask(JSON.stringify({ keeper: { paid: k.paid, skipped: k.skipped, halted: k.halted } })));
      }
      if (execSigner) {
        const x = await executorStep(
          { ctx, signer: execSigner, alerts, slippageBoundBp: cfg.execution.slippageBoundBp, accounts: async () => state.index.borrowers, persist: (xs: ExecutorState) => { state = { ...state, executor: xs }; saveState(cfg.monitor.statePath, { ...state, alerts: alerts.toJson() }); } },
          state.executor,
        );
        state = { ...state, executor: x.state, alerts: alerts.toJson() };
        saveState(cfg.monitor.statePath, state);
        if (x.round || x.skipped.length || x.halted) console.log(mask(JSON.stringify({ executor: { round: x.round, skipped: x.skipped, unfunded: x.unfunded, swapBlocked: x.swapBlocked, halted: x.halted } })));
      }
      console.log(mask(JSON.stringify(out.report, null, 2)));
      return out.report.findings.some((f) => f.severity === "crit") ? 1 : 0;
    } catch (e) {
      await reportBlind(alerts, e, Math.floor(Date.now() / 1000));
      console.error(`cycle failed: ${safeError(e)}`);
      return 1;
    }
  };
  if (cmd === "check") return once();
  for (;;) {
    await once();
    await new Promise((r) => setTimeout(r, cfg.monitor.pollSeconds * 1000));
  }
}

if (require.main === module) {
  main().then((c) => process.exit(c), (e) => {
    console.error(`fatal: ${safeError(e)}`);
    process.exit(1);
  });
}

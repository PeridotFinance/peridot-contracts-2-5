// Entry point.   node dist/src/main.js check              one DRY cycle: decisions and simulations, prints a JSON report, sends and writes NOTHING
//                node dist/src/main.js run                loop (signs and sends; alerts delivered)
//                node dist/src/main.js validate-config    only validate the configuration
// REFUSES TO START (exit 78) while any decision in the configuration is unset, the state endpoint or the keystore password is missing from the ENVIRONMENT, the signer
// is not the configured keeper wallet, the chain is not 43114, or the state file is unreadable / belongs to another registry. Everything printed passes through mask().
import fs from "node:fs";
import { providers } from "ethers";
import { AlertManager, MemorySink, createSink } from "./alerts";
import { ConfigError, findSecretsInConfigText, logsRpcUrlFromEnv, requireRpcUrlFromEnv, requireValidConfig } from "./config";
import type { KeeperConfig } from "./config";
import { CHAIN_ID } from "./constants";
import { keeperStep, verifySigner } from "./keeper";
import { logCrossCheck } from "./logaudit";
import { configureLogPace } from "./logpace";
import { mask, safeError } from "./mask";
import { KeystoreSigner } from "./signer";
import type { ExternalSigner } from "./signer";
import { loadState, saveState, StateError } from "./state";
import type { KeeperState } from "./state";

const EX_CONFIG = 78;

export function loadConfig(env: NodeJS.ProcessEnv = process.env, argv: string[] = process.argv.slice(2)): KeeperConfig {
  const i = argv.indexOf("--config");
  const file = (i >= 0 ? argv[i + 1] : undefined) ?? env.ORDER_KEEPER_CONFIG;
  if (!file) throw new Error("no configuration: set ORDER_KEEPER_CONFIG (or pass --config <file>); the checked-in template config/order-keeper.example.json is REFUSED while it contains placeholders");
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

async function main(): Promise<number> {
  const cmd = process.argv[2] ?? "";
  if (!["check", "run", "validate-config"].includes(cmd)) {
    console.error("usage: main.js check | run | validate-config   (configuration: ORDER_KEEPER_CONFIG or --config <file>; secrets: environment only)");
    return 2;
  }
  let cfg: KeeperConfig;
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
  const live = cmd === "run";
  let sink;
  let rpcUrl: string;
  try {
    rpcUrl = requireRpcUrlFromEnv();
    sink = live ? createSink(cfg.alerts.channel) : new MemorySink();
  } catch (e) {
    console.error(`start refused: ${safeError(e)}`);
    return EX_CONFIG;
  }
  const provider = new providers.StaticJsonRpcProvider({ url: rpcUrl, timeout: 20_000, throttleLimit: 2 }, { chainId: CHAIN_ID, name: "avalanche" });
  const net = await provider.send("eth_chainId", []);
  if (parseInt(net, 16) !== CHAIN_ID) {
    console.error(`start refused: RPC chain id ${parseInt(net, 16)} is not ${CHAIN_ID}`);
    return EX_CONFIG;
  }
  let signer: ExternalSigner | undefined;
  if (live) {
    try {
      signer = await KeystoreSigner.load(provider, cfg.keeper.keystorePath, cfg.keeper.passwordEnv);
      await verifySigner(signer, cfg, provider);
    } catch (e) {
      console.error(`start refused: keeper signer: ${safeError(e)}`);
      return EX_CONFIG;
    }
  }
  let state: KeeperState;
  try {
    state = loadState(cfg.monitor.statePath, cfg.registry);
  } catch (e) {
    console.error(`start refused: ${e instanceof StateError ? e.message : safeError(e)}`);
    return EX_CONFIG;
  }
  const alerts = new AlertManager(sink, cfg.escalationSeconds, state.alerts);
  const nowS = (): number => Math.floor(Date.now() / 1000);
  // LOG endpoint: separate from the state endpoint, optional (the cross-check only)
  const logUrl = cfg.logs.enabled ? logsRpcUrlFromEnv() : undefined;
  const logProvider = logUrl ? new providers.StaticJsonRpcProvider({ url: logUrl, timeout: 20_000, throttleLimit: 1 }, { chainId: CHAIN_ID, name: "avalanche-logs" }) : undefined; // throttleLimit 1: a 429 comes back at once; logpace.ts spaces and backs off
  configureLogPace({ minIntervalMs: cfg.logs.minIntervalMs });
  const persist = (s: KeeperState): void => {
    state = s;
    if (live) saveState(cfg.monitor.statePath, { ...s, alerts: alerts.toJson() });
  };
  if (state.halted) await alerts.raise({ key: "keeper:halted", severity: "crit", message: `ORDER KEEPER is HALTED since ${state.halted.at}: ${state.halted.reason}. It sends nothing until a human clears halted / pending in the state file`, audience: "keeper-operator" }, nowS());

  let cycles = 0;
  let stopping = false;
  // a stop signal lets the current cycle finish (a transaction that was sent is read back and its marker cleared) and then ends the loop
  for (const sig of ["SIGTERM", "SIGINT"] as const) process.on(sig, () => { stopping = true; });
  const once = async (): Promise<number> => {
    try {
      const o = await keeperStep({ provider, cfg, signer, alerts, persist }, state);
      state = o.state;
      if (logProvider && !state.halted) {
        const head = await provider.getBlockNumber();
        const l = await logCrossCheck({ logProvider, cfg, alerts, now: nowS }, state, head, o.caughtUp);
        if (l.cursor !== state.logCursor) persist({ ...state, logCursor: l.cursor });
      }
      if (live) saveState(cfg.monitor.statePath, { ...state, alerts: alerts.toJson() });
      cycles++;
      const active = o.executed.length + o.swept.length + o.due.length + o.reverted.length + o.skipped.length > 0 || o.halted;
      if (active || cycles % 20 === 1 || cmd === "check") console.log(mask(JSON.stringify({ at: new Date().toISOString(), scanned: o.scanned, executed: o.executed, swept: o.swept, due: o.due, reverted: o.reverted, skipped: o.skipped, halted: o.halted, ...(sink instanceof MemorySink ? { alerts: sink.messages.map((m) => ({ key: m.key, severity: m.severity, text: m.text })) } : {}) })));
      return o.halted ? 1 : 0;
    } catch (e) {
      // nothing was sent before this error (an error after a pending marker is a halt inside keeperStep): a failed cycle, retried next time
      await alerts.raise({ key: "cycle:failed", severity: "warn", message: `the order keeper cycle failed before any transaction: ${safeError(e)}`, audience: "keeper-operator" }, nowS());
      console.error(`cycle failed: ${safeError(e)}`);
      return 1;
    }
  };
  if (cmd === "check") return once();
  while (!stopping) {
    const rc = await once();
    if (rc === 0) await alerts.clear("cycle:failed", nowS());
    for (let i = 0; i < cfg.monitor.pollSeconds * 4 && !stopping; i++) await new Promise((r) => setTimeout(r, 250));
  }
  console.log("stopped after the current cycle");
  return 0;
}

if (require.main === module) {
  main().then((c) => process.exit(c), (e) => {
    console.error(`fatal: ${safeError(e)}`);
    process.exit(1);
  });
}

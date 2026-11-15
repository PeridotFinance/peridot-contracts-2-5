// Entry point.
//   dlmm-keeper run [--dry-run]    the loop. mode comes from the configuration ("dry-run" is the default; "live" needs the keystore + password file in the environment);
//                                  --dry-run forces dry-run whatever the configuration says. Dry-run reads, plans and SIMULATES; it never signs, never sends.
//   dlmm-keeper check              ONE dry cycle that does not wait for the 60 s: prints a JSON report; writes nothing (no state, no HALT file)
//   dlmm-keeper status             offline: prints the HALT record and the keeper's state (no RPC, no keystore)
//   dlmm-keeper resume             THE ONLY WAY OUT OF A HALT: removes the HALT file (audit line appended to <haltPath>.log) and clears a pending marker. No RPC, no keystore.
//   dlmm-keeper validate-config    only validate the configuration
// REFUSES TO START (exit 78) while any decision in the configuration is unset, the RPC endpoint is missing from the ENVIRONMENT, (live) the keystore / password file are
// missing or wrong, the signer is not the configured keeper wallet, the chain id is wrong, or the state file is unreadable / belongs to another vault. Everything printed passes through mask().
import fs from "node:fs";
import { providers } from "ethers";
import { AlertManager, MemorySink, createSink } from "./alerts";
import { ConfigError, findSecretsInConfigText, requireRpcUrlFromEnv, requireValidConfig } from "./config";
import type { KeeperConfig } from "./config";
import { keeperStep, verifySigner } from "./keeper";
import { mask, safeError } from "./mask";
import { KeystoreSigner } from "./signer";
import type { ExternalSigner } from "./signer";
import { clearHalt, loadState, readHalt, saveState, StateError } from "./state";
import type { KeeperState } from "./state";

const EX_CONFIG = 78;

export function loadConfig(env: NodeJS.ProcessEnv = process.env, argv: string[] = process.argv.slice(2)): KeeperConfig {
  const i = argv.indexOf("--config");
  const file = (i >= 0 ? argv[i + 1] : undefined) ?? env.DLMM_KEEPER_CONFIG;
  if (!file) throw new Error("no configuration: set DLMM_KEEPER_CONFIG (or pass --config <file>); the checked-in template config/dlmm-keeper.example.json is REFUSED while it contains placeholders");
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
  const argv = process.argv.slice(2);
  const cmd = argv[0] ?? "";
  if (!["check", "run", "validate-config", "resume", "status"].includes(cmd)) {
    console.error("usage: dlmm-keeper run [--dry-run] | check | status | resume | validate-config   (configuration: DLMM_KEEPER_CONFIG or --config <file>; secrets: environment only)");
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
  const nowS = (): number => Math.floor(Date.now() / 1000);
  if (cmd === "validate-config") {
    console.log("configuration valid");
    return 0;
  }
  // ---- offline commands: no RPC, no keystore
  if (cmd === "status" || cmd === "resume") {
    const h = readHalt(cfg.monitor.haltPath);
    let st: KeeperState | undefined;
    try {
      st = loadState(cfg.monitor.statePath, cfg.vault);
    } catch (e) {
      console.error(`state file: ${e instanceof StateError ? e.message : safeError(e)}`);
    }
    if (cmd === "status") {
      console.log(JSON.stringify({ mode: cfg.mode, halted: !!h, halt: h, pending: st?.pending ?? null, exit: st?.exit ?? null, backoff: st?.backoff ?? null, sendsLast24h: st?.sends.filter((s) => s.ts > nowS() - 86_400).length ?? 0 }, null, 2));
      return h ? 1 : 0;
    }
    const was = clearHalt(cfg.monitor.haltPath, nowS());
    if (st && st.pending) {
      saveState(cfg.monitor.statePath, { ...st, pending: null });
      console.log(`cleared the pending marker (${st.pending.kind} started at ${st.pending.at}): you have checked the keeper wallet's transactions and the vault's band`);
    }
    console.log(was ? `HALT removed (was ${was.kind}: ${mask(was.reason)}). The keeper resumes on its next cycle. If the cause still holds (a latched guard), it will halt again at once.` : "there was no HALT file");
    return 0;
  }
  const forceDry = argv.includes("--dry-run");
  const live = cmd === "run" && cfg.mode === "live" && !forceDry;
  let sink;
  let rpcUrl: string;
  try {
    rpcUrl = requireRpcUrlFromEnv();
    sink = cmd === "run" ? createSink(cfg.alerts.channel) : new MemorySink();
  } catch (e) {
    console.error(`start refused: ${safeError(e)}`);
    return EX_CONFIG;
  }
  const provider = new providers.StaticJsonRpcProvider({ url: rpcUrl, timeout: 20_000, throttleLimit: 2 }, { chainId: cfg.chainId, name: "avalanche" });
  try {
    const net = await provider.send("eth_chainId", []);
    if (parseInt(net, 16) !== cfg.chainId) {
      console.error(`start refused: RPC chain id ${parseInt(net, 16)} is not ${cfg.chainId}`);
      return EX_CONFIG;
    }
  } catch (e) {
    console.error(`start refused: the endpoint did not answer eth_chainId: ${safeError(e)}`);
    return EX_CONFIG;
  }
  let signer: ExternalSigner | undefined;
  if (live) {
    try {
      signer = await KeystoreSigner.load(provider);
      await verifySigner(signer, cfg, provider);
    } catch (e) {
      console.error(`start refused: keeper signer: ${safeError(e)}`);
      return EX_CONFIG;
    }
  }
  const effCfg: KeeperConfig = { ...cfg, mode: live ? "live" : "dry-run" };
  let state: KeeperState;
  try {
    state = loadState(cfg.monitor.statePath, cfg.vault);
  } catch (e) {
    console.error(`start refused: ${e instanceof StateError ? e.message : safeError(e)}`);
    return EX_CONFIG;
  }
  const alerts = new AlertManager(sink, state.alerts);
  const persist = (s: KeeperState): void => {
    state = s;
    if (cmd === "run") saveState(cfg.monitor.statePath, { ...s, alerts: alerts.toJson() });
  };
  console.log(mask(JSON.stringify({ at: new Date().toISOString(), start: cmd, mode: effCfg.mode, vault: cfg.vault, keeper: cfg.keeper.address, halted: !!readHalt(cfg.monitor.haltPath) })));

  let cycles = 0;
  let stopping = false;
  // a stop signal lets the current cycle finish (a transaction that was sent is read back and its marker cleared) and then ends the loop
  for (const sig of ["SIGTERM", "SIGINT"] as const) process.on(sig, () => { stopping = true; });
  const once = async (): Promise<number> => {
    try {
      const o = await keeperStep({ provider, cfg: effCfg, signer, alerts, persist }, state, { skipWait: cmd === "check", noHaltWrite: cmd === "check" });
      state = o.state;
      if (cmd === "run") saveState(cfg.monitor.statePath, { ...state, alerts: alerts.toJson() });
      cycles++;
      const active = o.sent.length > 0 || o.notes.length > 0 || !["in-range", "halted"].includes(o.status);
      if (active || cycles % 20 === 1 || cmd === "check") {
        console.log(mask(JSON.stringify({ at: new Date().toISOString(), status: o.status, sent: o.sent, notes: o.notes, halted: o.halted, ...(o.halt ? { halt: o.halt } : {}), ...(o.plan ? { plan: JSON.parse(JSON.stringify(o.plan, (_k, v) => (typeof v === "bigint" ? v.toString() : v))) } : {}), ...(sink instanceof MemorySink ? { alerts: sink.messages.map((m) => ({ key: m.key, severity: m.severity, text: m.text })) } : {}) })));
      }
      return o.halted ? 1 : 0;
    } catch (e) {
      // nothing was sent before this error (an error after a pending marker is a halt inside keeperStep): a failed cycle, retried next time
      await alerts.raise({ key: "cycle:failed", severity: "warn", message: `the keeper cycle failed before any transaction: ${safeError(e)}`, audience: "keeper-operator" }, nowS());
      console.error(`cycle failed: ${safeError(e)}`);
      return 1;
    }
  };
  if (cmd === "check") return once();
  while (!stopping) {
    const rc = await once();
    if (rc === 0) await alerts.clear("cycle:failed", nowS());
    for (let i = 0; i < cfg.timing.pollSeconds * 4 && !stopping; i++) await new Promise((r) => setTimeout(r, 250));
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

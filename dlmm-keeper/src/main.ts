// Entry point.
//   dlmm-keeper run [--dry-run]    the loop. mode comes from the configuration ("dry-run" is the default; "live" needs the keystore + password file in the environment);
//                                  --dry-run forces dry-run whatever the configuration says. Dry-run reads, plans and SIMULATES; it never signs, never sends.
//   dlmm-keeper check              ONE dry cycle that does not wait for the 60 s: prints a JSON report; writes nothing (no state, no HALT file)
//   dlmm-keeper open-band [--send] the FIRST band from the vault's idle assets (the vault has no band yet). Same step as a rebalance: guard, oracle check, sizing, simulation, the same
//                                  limits and halt rules. DRY unless `--send` is given AND the configuration says "live" (then the keystore is loaded and ONE openBand is sent).
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
import { checkWiring } from "./chain";
import { keeperStep, verifySigner } from "./keeper";
import { preflight } from "./preflight";
import { mask, safeError } from "./mask";
import { KeystoreSigner } from "./signer";
import type { ExternalSigner } from "./signer";
import { loadState, readHalt, resumeKeeper, saveState, StateError } from "./state";
import type { KeeperState } from "./state";

const EX_CONFIG = 78;

/**
 * `partial`: the vault and the keeper wallet may still be the UNSET placeholder (the host is bootstrapped before the vault exists and the wallet is made ON the host);
 * they are replaced by dummy non-zero addresses for the validation, and `placeholders` names what was replaced. Everything else is validated as always.
 */
export function loadConfig(env: NodeJS.ProcessEnv = process.env, argv: string[] = process.argv.slice(2), partial = false): KeeperConfig & { placeholders?: string[] } {
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
  if (partial && raw && typeof raw === "object") {
    const c = raw as Record<string, any>;
    const placeholders: string[] = [];
    if (String(c.vault).toUpperCase() === "UNSET") { c.vault = "0x00000000000000000000000000000000000000d1"; placeholders.push("vault"); }
    if (c.keeper && String(c.keeper.address).toUpperCase() === "UNSET") { c.keeper.address = "0x00000000000000000000000000000000000000d2"; placeholders.push("keeper.address"); }
    return { ...requireValidConfig(raw), placeholders };
  }
  return requireValidConfig(raw);
}

async function main(): Promise<number> {
  const argv = process.argv.slice(2);
  const cmd = argv[0] ?? "";
  if (!["check", "run", "open-band", "validate-config", "preflight", "resume", "status"].includes(cmd)) {
    console.error("usage: dlmm-keeper run [--dry-run] | open-band [--send] | preflight | check | status | resume | validate-config   (configuration: DLMM_KEEPER_CONFIG or --config <file>; secrets: environment only)");
    return 2;
  }
  let cfg: KeeperConfig;
  try {
    cfg = loadConfig(process.env, process.argv.slice(2), cmd === "preflight" || (cmd === "validate-config" && process.argv.includes("--partial")));
  } catch (e) {
    console.error(e instanceof ConfigError ? e.message : `configuration refused: ${safeError(e)}`);
    console.error("the process did not start");
    return EX_CONFIG;
  }
  const nowS = (): number => Math.floor(Date.now() / 1000);
  const placeholders = (cfg as KeeperConfig & { placeholders?: string[] }).placeholders ?? [];
  if (cmd === "validate-config") {
    console.log(placeholders.length ? `configuration valid, EXCEPT these placeholders (filled by the wire step): ${placeholders.join(", ")}` : "configuration valid");
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
    const r = resumeKeeper(cfg.monitor.statePath, cfg.monitor.haltPath, cfg.vault, nowS());
    if (r.stateProblem) console.error(`state file: ${r.stateProblem} (left untouched)`);
    if (r.clearedPending) console.log(`cleared the pending marker (${r.clearedPending.kind} started at ${r.clearedPending.at}): you have checked the keeper wallet's transactions and the vault's band`);
    console.log(r.was ? `HALT removed (was ${r.was.kind}: ${mask(r.was.reason)}). Reset: pending marker, failure backoff, exit timer, last-seen rebalance (re-learned at the next attempt). The keeper resumes on its next cycle; if the cause still holds (a latched guard) it halts again at once.` : "there was no HALT file");
    return 0;
  }
  const forceDry = argv.includes("--dry-run");
  const sendRequested = cmd === "run" || (cmd === "open-band" && argv.includes("--send"));
  if (cmd === "open-band" && argv.includes("--send") && cfg.mode !== "live") {
    console.error('open-band --send needs "mode": "live" in the configuration (dry-run is the default); nothing was sent');
    return EX_CONFIG;
  }
  const live = sendRequested && cfg.mode === "live" && !forceDry;
  const oneShot = cmd === "check" || cmd === "open-band";
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
  if (cmd === "preflight") {
    const lines = await preflight(provider, cfg, nowS(), !placeholders.includes("vault"));
    for (const l of lines) console.log(mask(`${l.level.padEnd(4)} ${l.text}`));
    const fails = lines.filter((l) => l.level === "FAIL").length;
    console.log(fails ? `PREFLIGHT: ${fails} CHECK(S) FAILED` : "PREFLIGHT: ALL CHECKS PASSED");
    return fails ? 1 : 0;
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
  if (placeholders.length === 0) {
    // the wiring is checked BEFORE anything runs: the unit refuses to start on a vault that is not the configured one or whose rebalancer is not this wallet
    try {
      const w = await checkWiring(provider, cfg);
      const bad = w.filter((x) => x.level === "FAIL");
      if (bad.length) {
        for (const x of bad) console.error(mask(`start refused: wiring: ${x.text}`));
        return EX_CONFIG;
      }
    } catch (e) {
      console.error(`start refused: the wiring could not be read: ${safeError(e)}`);
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
    if (cmd === "run" || (cmd === "open-band" && live)) saveState(cfg.monitor.statePath, { ...s, alerts: alerts.toJson() });
  };
  console.log(mask(JSON.stringify({ at: new Date().toISOString(), start: cmd, mode: effCfg.mode, vault: cfg.vault, keeper: cfg.keeper.address, halted: !!readHalt(cfg.monitor.haltPath) })));

  let cycles = 0;
  let stopping = false;
  let lastStatus = "";
  let wasHalted = !!readHalt(cfg.monitor.haltPath);
  // a stop signal lets the current cycle finish (a transaction that was sent is read back and its marker cleared) and then ends the loop
  for (const sig of ["SIGTERM", "SIGINT"] as const) process.on(sig, () => { stopping = true; });
  const once = async (): Promise<number> => {
    try {
      // `resume` (another process) removed the HALT file and reset the state file: reload it, never write our older in-memory copy over it
      if (wasHalted && !readHalt(cfg.monitor.haltPath)) {
        state = loadState(cfg.monitor.statePath, cfg.vault);
        wasHalted = false;
      }
      const o = await keeperStep({ provider, cfg: effCfg, signer, alerts, persist }, state, { skipWait: oneShot, noHaltWrite: cmd === "check" || (cmd === "open-band" && !live), openBand: cmd === "open-band" });
      state = o.state;
      wasHalted = o.halted;
      lastStatus = o.status;
      // while the HALT file exists nothing is written: the state on disk is what `resume` will reset
      if ((cmd === "run" || (cmd === "open-band" && live)) && o.status !== "halted") saveState(cfg.monitor.statePath, { ...state, alerts: alerts.toJson() });
      cycles++;
      const active = o.sent.length > 0 || o.notes.length > 0 || !["in-range", "halted"].includes(o.status);
      if (active || cycles % 20 === 1 || oneShot) {
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
  if (oneShot) {
    const rc = await once();
    return cmd === "open-band" ? (lastStatus === "dry-run" || lastStatus === "sent" ? 0 : 1) : rc;
  }
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

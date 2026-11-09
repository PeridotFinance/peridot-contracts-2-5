// Configuration schema and the START-UP REFUSAL (the pattern of operator/src/config.ts, own schema).
//   * the JSON file (OPERATOR-style: path from ORDER_KEEPER_CONFIG or --config): PUBLIC addresses and parameters only; the checked-in template
//     (config/order-keeper.example.json) has "UNSET" for every undecided value and is REFUSED.
//   * the environment: secrets only (state endpoint AVALANCHE_MAINNET_RPC_URL, log endpoint AVALANCHE_LOGS_RPC_URL, keystore password under the name
//     keeper.passwordEnv, alert credentials). NEVER in the file.
import { utils } from "ethers";

export const UNSET = "UNSET";
export const ALERT_CHANNELS = ["log", "telegram", "webhook"] as const;
export type AlertChannel = (typeof ALERT_CHANNELS)[number];

export interface KeeperConfig {
  schemaVersion: 1;
  chainId: number;
  label: string;
  /** the MarginOrderRegistry proxy and the Avalanche close adapter, the margin executor and vault (all public addresses of the margin ceremony) */
  registry: string;
  closeAdapter: string;
  marginExecutor: string;
  marginVault: string;
  keeper: { address: string; keystorePath: string; passwordEnv: string };
  limits: {
    maxFeeGwei: number;
    minGasWei: string;
    /** ceiling of the gas limit of one transaction (estimate x 1.3 above it: the order is skipped and an alert is raised) */
    maxGasLimit: number;
    maxSendsPerCycle: number;
    /** transactions in a rolling 24 h (sweeps included) */
    maxSendsPerDay: number;
    /** mined reverts after a passing simulation in a rolling 24 h that HALT the keeper (each one cost gas) */
    maxMinedRevertsPerDay: number;
    sweep: boolean;
    /** most open ids re-read, and most NEW ids first read, per cycle (so each is bounded separately and new ids always make progress); the rest waits for the next cycle */
    maxIdsPerCycle: number;
    /** simulate-revert cooldown: base, doubling per consecutive failure up to the maximum */
    retryCooldownSeconds: number;
    retryCooldownMaxSeconds: number;
    /** after a revert nobody classified, or a mined revert */
    unknownRevertCooldownSeconds: number;
    /** a due order that cannot be filled for this long raises a warning (a stop-loss that cannot fill: liquidation is the backstop) */
    unfilledAlertSeconds: number;
  };
  /** the SEPARATE log endpoint: optional cross-check of OrderCreated against the id scan. Discovery never depends on it. */
  logs: { enabled: boolean; chunkBlocks: number; maxChunksPerCycle: number; minIntervalMs: number; reorgMarginBlocks: number; behindWarnBlocks: number };
  monitor: { pollSeconds: number; maxBlockLagSeconds: number; statePath: string };
  alerts: { channel: AlertChannel };
  escalationSeconds: number[];
}

export interface ConfigProblem {
  path: string;
  problem: string;
}
const isUnsetString = (v: unknown): boolean => v === undefined || v === null || (typeof v === "string" && (v.trim() === "" || /^(UNSET|TODO|TBD|CHANGEME|<.*>)$/i.test(v.trim())));
function addr(p: ConfigProblem[], path: string, v: unknown): void {
  if (isUnsetString(v)) return void p.push({ path, problem: "unset (placeholder)" });
  if (typeof v !== "string" || !utils.isAddress(v)) return void p.push({ path, problem: "not a valid address" });
  if (/^0x0{40}$/i.test(v)) p.push({ path, problem: "zero address" });
}
function int(p: ConfigProblem[], path: string, v: unknown, lo: number, hi: number): void {
  if (isUnsetString(v)) return void p.push({ path, problem: "unset (placeholder)" });
  if (typeof v !== "number" || !Number.isInteger(v) || v < lo || v > hi) p.push({ path, problem: `must be an integer in [${lo}, ${hi}]` });
}
function bigintString(p: ConfigProblem[], path: string, v: unknown): void {
  if (isUnsetString(v)) return void p.push({ path, problem: "unset (placeholder)" });
  if (typeof v !== "string" || !/^[0-9]+$/.test(v) || BigInt(v) === 0n) p.push({ path, problem: "must be a positive decimal integer string" });
}

export function validateConfig(raw: unknown): { problems: ConfigProblem[]; config?: KeeperConfig } {
  const problems: ConfigProblem[] = [];
  if (typeof raw !== "object" || raw === null) return { problems: [{ path: "$", problem: "config must be a JSON object" }] };
  const c = raw as Record<string, any>;
  if (c.schemaVersion !== 1) problems.push({ path: "schemaVersion", problem: "must be 1" });
  if (c.chainId !== 43114) problems.push({ path: "chainId", problem: "must be 43114 (Avalanche C-Chain); addresses of other chains are never reused" });
  if (isUnsetString(c.label)) problems.push({ path: "label", problem: "unset (placeholder)" });
  for (const k of ["registry", "closeAdapter", "marginExecutor", "marginVault"]) addr(problems, k, c[k]);
  const k = c.keeper ?? {};
  addr(problems, "keeper.address", k.address);
  if (isUnsetString(k.keystorePath)) problems.push({ path: "keeper.keystorePath", problem: "unset (placeholder)" });
  if (isUnsetString(k.passwordEnv) || !/^[A-Z][A-Z0-9_]*$/.test(String(k.passwordEnv))) problems.push({ path: "keeper.passwordEnv", problem: "must be the NAME of an environment variable (the password itself never goes in the file)" });
  const l = c.limits ?? {};
  int(problems, "limits.maxFeeGwei", l.maxFeeGwei, 1, 5000);
  bigintString(problems, "limits.minGasWei", l.minGasWei);
  int(problems, "limits.maxGasLimit", l.maxGasLimit, 100_000, 15_000_000);
  int(problems, "limits.maxSendsPerCycle", l.maxSendsPerCycle, 1, 50);
  int(problems, "limits.maxSendsPerDay", l.maxSendsPerDay, 1, 5000);
  int(problems, "limits.maxMinedRevertsPerDay", l.maxMinedRevertsPerDay, 1, 100);
  if (typeof l.sweep !== "boolean") problems.push({ path: "limits.sweep", problem: "must be a boolean" });
  int(problems, "limits.maxIdsPerCycle", l.maxIdsPerCycle, 1, 5000);
  int(problems, "limits.retryCooldownSeconds", l.retryCooldownSeconds, 1, 86_400);
  int(problems, "limits.retryCooldownMaxSeconds", l.retryCooldownMaxSeconds, 1, 86_400);
  if (typeof l.retryCooldownSeconds === "number" && typeof l.retryCooldownMaxSeconds === "number" && l.retryCooldownSeconds > l.retryCooldownMaxSeconds) problems.push({ path: "limits.retryCooldownMaxSeconds", problem: "must not be below retryCooldownSeconds" });
  int(problems, "limits.unknownRevertCooldownSeconds", l.unknownRevertCooldownSeconds, 1, 86_400);
  int(problems, "limits.unfilledAlertSeconds", l.unfilledAlertSeconds, 1, 86_400);
  const g = c.logs ?? {};
  if (typeof g.enabled !== "boolean") problems.push({ path: "logs.enabled", problem: "must be a boolean" });
  int(problems, "logs.chunkBlocks", g.chunkBlocks, 1, 100); // free tier serves 10, the Avalanche public RPC 100 (measured 9 Nov 2026)
  int(problems, "logs.maxChunksPerCycle", g.maxChunksPerCycle, 1, 500);
  int(problems, "logs.minIntervalMs", g.minIntervalMs, 0, 60_000);
  int(problems, "logs.reorgMarginBlocks", g.reorgMarginBlocks, 0, 1000);
  int(problems, "logs.behindWarnBlocks", g.behindWarnBlocks, 1, 10_000_000);
  const m = c.monitor ?? {};
  int(problems, "monitor.pollSeconds", m.pollSeconds, 1, 3600);
  int(problems, "monitor.maxBlockLagSeconds", m.maxBlockLagSeconds, 1, 3600);
  if (isUnsetString(m.statePath)) problems.push({ path: "monitor.statePath", problem: "unset (placeholder)" });
  if (isUnsetString(c.alerts?.channel)) problems.push({ path: "alerts.channel", problem: "unset (placeholder)" });
  else if (!(ALERT_CHANNELS as readonly string[]).includes(c.alerts.channel)) problems.push({ path: "alerts.channel", problem: `must be one of ${ALERT_CHANNELS.join(", ")}` });
  if (!Array.isArray(c.escalationSeconds) || c.escalationSeconds.length < 1 || c.escalationSeconds.some((s: unknown, i: number, a: unknown[]) => typeof s !== "number" || !Number.isInteger(s) || s <= 0 || (i > 0 && (s as number) <= (a[i - 1] as number)))) {
    problems.push({ path: "escalationSeconds", problem: "must be a strictly increasing list of positive integers" });
  }
  return problems.length ? { problems } : { problems, config: raw as KeeperConfig };
}

export class ConfigError extends Error {
  constructor(public readonly problems: ConfigProblem[]) {
    super(`configuration refused (${problems.length} problem${problems.length === 1 ? "" : "s"}):\n` + problems.map((x) => `  - ${x.path}: ${x.problem}`).join("\n"));
    this.name = "ConfigError";
  }
}
export function requireValidConfig(raw: unknown): KeeperConfig {
  const { problems, config } = validateConfig(raw);
  if (!config) throw new ConfigError(problems);
  return config;
}

/** The state endpoint comes from the environment only. The message never contains a value. */
export function requireRpcUrlFromEnv(env: NodeJS.ProcessEnv = process.env): string {
  const url = env.AVALANCHE_MAINNET_RPC_URL || env.AVALANCHE_RPC || "";
  if (!url) throw new Error("no RPC endpoint: set AVALANCHE_MAINNET_RPC_URL (read from the environment only; never put it in the config file)");
  return url;
}
/** The LOG endpoint (separate from the state endpoint). Absent = the cross-check is skipped, nothing else changes. */
export function logsRpcUrlFromEnv(env: NodeJS.ProcessEnv = process.env): string | undefined {
  return env.AVALANCHE_LOGS_RPC_URL || undefined;
}

/** Defence in depth: a config FILE must not carry an RPC URL or any key-like secret. */
export function findSecretsInConfigText(text: string): string[] {
  const hits: string[] = [];
  if (/https?:\/\/[^"\s]*[A-Za-z0-9_-]{16,}/.test(text)) hits.push("a URL that looks like it carries a key or token");
  if (/\b0x[0-9a-fA-F]{64}\b/.test(text)) hits.push("a 32-byte hex string (private key shaped)");
  if (/(mnemonic|seed phrase|private[_ -]?key)/i.test(text)) hits.push("the words mnemonic / seed phrase / private key");
  return hits;
}

// Configuration schema and the START-UP REFUSAL.
//   * the JSON file (path from DLMM_KEEPER_CONFIG or --config): PUBLIC addresses and parameters only. The checked-in template
//     (config/dlmm-keeper.example.json) has "UNSET" for every undecided value and is REFUSED.
//   * the environment: secrets and secret locations only: AVALANCHE_MAINNET_RPC_URL (state endpoint), DLMM_KEEPER_KEYSTORE_PATH, DLMM_KEEPER_KEYSTORE_PASSWORD_FILE,
//     alert credentials. NEVER in the file (a scan of the file text refuses key-shaped content).
//   * floors of the spec are enforced here: exit wait >= 60 s, cooldown >= 120 s, <= 48 sends per rolling 24 h, exactly 1 send per cycle, deadline <= 120 s, idSlippage <= 2.
import { utils } from "ethers";
import { MAX_DEADLINE_SECONDS, MAX_ID_SLIPPAGE, MAX_SENDS_PER_DAY, MIN_COOLDOWN_SECONDS, MIN_EXIT_WAIT_SECONDS } from "./constants";

export const UNSET = "UNSET";
export const ALERT_CHANNELS = ["log", "telegram", "webhook"] as const;
export type AlertChannel = (typeof ALERT_CHANNELS)[number];
export type Mode = "dry-run" | "live";

export interface KeeperConfig {
  schemaVersion: 1;
  chainId: number;
  label: string;
  /** dry-run (the default): everything is read, planned and SIMULATED, nothing is signed or sent, no keystore is loaded. live: sends. */
  mode: Mode;
  vault: string;
  pair: string;
  /** the vault's asset (USDC) and pair token (USDt); checked against pair.getTokenX()/getTokenY() at start */
  assetToken: string;
  pairToken: string;
  /** the two Chainlink USD feeds the vault reads (asset leg, pair leg): the keeper's SECOND, independent oracle check */
  feeds: { asset: string; pair: string };
  /** optional: the contract answering getSwapOut(uint128,bool) (default = the pair, which has it on the live chain; the local mock pair does not) */
  quoter?: string;
  /** Multicall3 address, or "none" (one eth_call per read: only for a local chain without Multicall3) */
  multicall3: string;
  keeper: { address: string };
  timing: { pollSeconds: number; exitWaitSeconds: number; cooldownSeconds: number; deadlineSeconds: number; maxBlockLagSeconds: number };
  limits: {
    /** exactly 1 (the vault's own rule) */
    maxSendsPerCycle: number;
    /** rolling 24 h, <= 48 (the vault's default cap); the effective cap is also min() with the vault's guardParams().maxRebalancesPerDay */
    maxSendsPerDay: number;
    /** consecutive failed attempts (simulation reverts that count, mined reverts, send errors) that HALT the keeper */
    maxConsecutiveFailures: number;
    /** mined reverts after a passing simulation in a rolling 24 h that HALT the keeper (each cost gas) */
    maxMinedRevertsPerDay: number;
    maxFeeGwei: number;
    maxGasLimit: number;
    /** below this wallet balance nothing is sent (hard stop) */
    minWalletWei: string;
    /** gas runway alert: warn when the wallet covers fewer than minRebalancesCovered rebalances at the CURRENT gas price x gasPerRebalance */
    gasPerRebalance: number;
    minRebalancesCovered: number;
    gasRunwayCheckSeconds: number;
    /** failure backoff: base, doubling per consecutive failure up to the maximum */
    retryBackoffSeconds: number;
    retryBackoffMaxSeconds: number;
    /** refuse a band wider than this (bounds the reads; the vault's band is 3 bins) */
    maxBandBins: number;
  };
  rebalance: {
    idSlippage: number;
    /** swapMinOut = quote x (1 - this) (and never below the oracle floor) */
    swapSlippageBps: number;
    /** amountXMin / amountYMin = the post-swap inventory (worst case at swapMinOut) x (1 - this) */
    addSlippageBps: number;
    /** KEEPER-side oracle checks, independent of the vault's guard; the effective value is min(this, the vault's own parameter) */
    maxQuoteLossBps: number;
    maxPoolOracleDevBps: number;
    keeperLegBandBps: number;
    /** an ActiveIdMoved revert reporting an id further than this from the id the plan was made for is not adopted */
    maxActiveIdShift: number;
  };
  guard: {
    /** permissionless tripGuard() when a latchable bit holds and the vault is not latched. DEFAULT OFF (see README). */
    autoTripGuard: boolean;
    /** the condition must still hold after this many seconds before tripGuard is sent */
    tripDebounceSeconds: number;
  };
  /** the exit-health probe: every N cycles a simulated burn of the vault's own band shares (hook failures block every exit while guardState reads 0) */
  probe: { everyCycles: number };
  monitor: { statePath: string; haltPath: string };
  alerts: { channel: AlertChannel };
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
  if (c.mode !== "dry-run" && c.mode !== "live") problems.push({ path: "mode", problem: 'must be "dry-run" (the default) or "live"' });
  for (const k of ["vault", "pair", "assetToken", "pairToken"]) addr(problems, k, c[k]);
  addr(problems, "feeds.asset", c.feeds?.asset);
  addr(problems, "feeds.pair", c.feeds?.pair);
  if (c.multicall3 !== "none") addr(problems, "multicall3", c.multicall3);
  addr(problems, "keeper.address", c.keeper?.address);
  if (typeof c.assetToken === "string" && typeof c.pairToken === "string" && c.assetToken.toLowerCase() === c.pairToken.toLowerCase()) problems.push({ path: "pairToken", problem: "must differ from assetToken" });
  const t = c.timing ?? {};
  int(problems, "timing.pollSeconds", t.pollSeconds, 1, 60);
  int(problems, "timing.exitWaitSeconds", t.exitWaitSeconds, MIN_EXIT_WAIT_SECONDS, 3600);
  int(problems, "timing.cooldownSeconds", t.cooldownSeconds, MIN_COOLDOWN_SECONDS, 3600);
  int(problems, "timing.deadlineSeconds", t.deadlineSeconds, 30, MAX_DEADLINE_SECONDS);
  int(problems, "timing.maxBlockLagSeconds", t.maxBlockLagSeconds, 5, 3600);
  const l = c.limits ?? {};
  if (l.maxSendsPerCycle !== 1) problems.push({ path: "limits.maxSendsPerCycle", problem: "must be exactly 1 (the vault allows one rebalance per cooldown; the keeper never sends two in a cycle)" });
  int(problems, "limits.maxSendsPerDay", l.maxSendsPerDay, 1, MAX_SENDS_PER_DAY);
  int(problems, "limits.maxConsecutiveFailures", l.maxConsecutiveFailures, 1, 100);
  int(problems, "limits.maxMinedRevertsPerDay", l.maxMinedRevertsPerDay, 1, 100);
  int(problems, "limits.maxFeeGwei", l.maxFeeGwei, 1, 5000);
  int(problems, "limits.maxGasLimit", l.maxGasLimit, 200_000, 15_000_000);
  bigintString(problems, "limits.minWalletWei", l.minWalletWei);
  int(problems, "limits.gasPerRebalance", l.gasPerRebalance, 100_000, 15_000_000);
  int(problems, "limits.minRebalancesCovered", l.minRebalancesCovered, 1, 1000);
  int(problems, "limits.gasRunwayCheckSeconds", l.gasRunwayCheckSeconds, 10, 86_400);
  int(problems, "limits.retryBackoffSeconds", l.retryBackoffSeconds, 1, 86_400);
  int(problems, "limits.retryBackoffMaxSeconds", l.retryBackoffMaxSeconds, 1, 86_400);
  if (typeof l.retryBackoffSeconds === "number" && typeof l.retryBackoffMaxSeconds === "number" && l.retryBackoffSeconds > l.retryBackoffMaxSeconds) problems.push({ path: "limits.retryBackoffMaxSeconds", problem: "must not be below retryBackoffSeconds" });
  int(problems, "limits.maxBandBins", l.maxBandBins, 1, 25);
  const r = c.rebalance ?? {};
  int(problems, "rebalance.idSlippage", r.idSlippage, 0, MAX_ID_SLIPPAGE);
  int(problems, "rebalance.swapSlippageBps", r.swapSlippageBps, 0, 300);
  int(problems, "rebalance.addSlippageBps", r.addSlippageBps, 0, 1000);
  int(problems, "rebalance.maxQuoteLossBps", r.maxQuoteLossBps, 1, 300);
  int(problems, "rebalance.maxPoolOracleDevBps", r.maxPoolOracleDevBps, 1, 300);
  int(problems, "rebalance.keeperLegBandBps", r.keeperLegBandBps, 1, 200);
  int(problems, "rebalance.maxActiveIdShift", r.maxActiveIdShift, 0, 25);
  const g = c.guard ?? {};
  if (typeof g.autoTripGuard !== "boolean") problems.push({ path: "guard.autoTripGuard", problem: "must be a boolean" });
  int(problems, "guard.tripDebounceSeconds", g.tripDebounceSeconds, 0, 600);
  if (c.quoter !== undefined) addr(problems, "quoter", c.quoter);
  int(problems, "probe.everyCycles", c.probe?.everyCycles, 1, 100_000);
  const m = c.monitor ?? {};
  if (isUnsetString(m.statePath)) problems.push({ path: "monitor.statePath", problem: "unset (placeholder)" });
  if (isUnsetString(m.haltPath)) problems.push({ path: "monitor.haltPath", problem: "unset (placeholder)" });
  if (isUnsetString(c.alerts?.channel)) problems.push({ path: "alerts.channel", problem: "unset (placeholder)" });
  else if (!(ALERT_CHANNELS as readonly string[]).includes(c.alerts.channel)) problems.push({ path: "alerts.channel", problem: `must be one of ${ALERT_CHANNELS.join(", ")}` });
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
  const url = env.AVALANCHE_MAINNET_RPC_URL || "";
  if (!url) throw new Error("no RPC endpoint: set AVALANCHE_MAINNET_RPC_URL (read from the environment only; never put it in the config file, an argument or a log)");
  return url;
}

/** Defence in depth: a config FILE must not carry an RPC URL or any key-like secret. */
export function findSecretsInConfigText(text: string): string[] {
  const hits: string[] = [];
  if (/https?:\/\/[^"\s]*[A-Za-z0-9_-]{16,}/.test(text)) hits.push("a URL that looks like it carries a key or token");
  if (/\b0x[0-9a-fA-F]{64}\b/.test(text)) hits.push("a 32-byte hex string (private key shaped)");
  if (/(mnemonic|seed phrase|private[_ -]?key|password)/i.test(text)) hits.push("the words mnemonic / seed phrase / private key / password");
  return hits;
}

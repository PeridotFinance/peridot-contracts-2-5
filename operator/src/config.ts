// Configuration schema and the START-UP REFUSAL. The process must not start while any operator decision is unset.
//
// What lives where:
//   * the JSON config file (path from the environment variable OPERATOR_CONFIG): public addresses, parameters, and the operator
//     decisions. It is checked in as a TEMPLATE (config/pilot.example.json) in which every undecided value is the placeholder "UNSET".
//   * the environment: secrets only (RPC URL: AVALANCHE_MAINNET_RPC_URL, alert credentials). NEVER in the file.
//   * no key, mnemonic or signer secret is read, accepted or stored anywhere in this package (step 1 is read-only). The `signer.type`
//     field only records WHICH kind of external signer the executor stage will use.
import { utils } from "ethers";

export const UNSET = "UNSET";
export const SIGNER_TYPES = ["foundry-keystore"] as const; // the only implemented external signer (hot keeper wallets, Foundry keystore accounts)
export const ALERT_CHANNELS = ["log", "telegram", "webhook"] as const; // "log" until the Telegram bot exists
export type SignerType = (typeof SIGNER_TYPES)[number];
export type AlertChannel = (typeof ALERT_CHANNELS)[number];

export interface OperatorEntry {
  name: string;
  address: string; // public address only
}
export interface MonitorConfig {
  schemaVersion: 1;
  chainId: number;
  deployment: { controller: string; pWavax: string; pUsdc: string; oracle: string; deploymentBlock: number };
  pilot: {
    label: string;
    wavaxCollateralFactorBp: number; // 3000 = 30%
    usdcCollateralFactorBp: number;
    usdcBorrowCapUsd: number;
    wavaxBorrowingDisabled: boolean;
    protectionCapitalUsd: number;
    operatorInventoryMinUsd: number;
    operatorInventoryTargetUsd: number;
    cashFloorBp: number; // 2000 = 20%
  };
  // ---- operator decisions that MUST be set before the process starts ----
  operators: OperatorEntry[];
  signer: { type: SignerType };
  alerts: { channel: AlertChannel };
  execution: { slippageBoundBp: number };
  reference: { toleranceBp: number; minPoolLiquidity: string; minPoolLiquiditySource: LiquiditySource };
  /** the TREASURY KEEPER wallet: a hot wallet holding the protection USDC (the Safe is the cold reserve that funds it) */
  treasury: { address: string };
  /** the LIQUIDATOR EXECUTOR of ONE operator (each operator is its own process, host, keystore and inventory); never enabled together with the keeper */
  executor: {
    enabled: boolean;
    operator: string; // the NAME of this process's entry in `operators` (the signer must be that entry's address)
    keystorePath: string;
    passwordEnv: string;
    convertToUsdc: boolean; // redeem the seized pWAVAX and swap WAVAX -> USDC after each liquidation (false = hold, the no-recycling mode)
    minRepayUsdc: number; // an operator with less USDC than this does not liquidate
    maxFeeGwei: number;
    minGasWei: string;
  };
  keeper: {
    enabled: boolean;
    keystorePath: string; // Foundry keystore file (encrypted); the password comes from the environment variable named by passwordEnv
    passwordEnv: string;
    dailySpendCapUsdc: number; // rolling 24 h
    confirmEvaluations: number; // consecutive evaluations (on distinct blocks) that must read DEFAULT_EXHAUSTED before paying
    confirmSeconds: number; // ... spanning at least this many seconds of chain time
    allowanceMarginBp: number; // the exact-need allowance is the debt read now plus this margin (interest until inclusion)
    maxFeeGwei: number; // do not send above this max fee
    minGasWei: string; // keeper AVAX balance floor
  };
  // ---- monitor settings with defaults (proposals, not results) ----
  monitor: {
    pollSeconds: number;
    maxBlockLagSeconds: number;
    reorgMarginBlocks: number;
    logChunkBlocks: number;
    statePath: string;
    dustUsd1e18: string;
    avaxFeedWarnRatio: number; // alert when the age exceeds this fraction of the guard (0.5 = 600 s of 1,200 s)
    avaxFeedCritRatio: number;
    usdcFeedWarnRatio: number; // 80,000 of 90,000 s
    usdcFeedCritRatio: number;
    minOperatorGasWei: string;
    utilisationWarnBp: number;
    borrowCapWarnBp: number;
    escalationSeconds: number[]; // [3600, 14400, 86400] = 1 h / 4 h / 24 h
    noReferencePageSeconds: number; // an unknown price (stale/zero oracle, no reference) that persists this long is paged
  };
}

/** How `reference.minPoolLiquidity` was computed (scripts/compute-min-pool-liquidity.ts): 50% of the trailing 7-day median of pool.liquidity(). */
export interface LiquiditySource {
  fromBlock: number;
  toBlock: number;
  samples: number;
  medianLiquidity: string;
  method: string;
}

export interface ConfigProblem {
  path: string;
  problem: string;
}

const isUnsetString = (v: unknown): boolean =>
  v === undefined || v === null || (typeof v === "string" && (v.trim() === "" || /^(UNSET|TODO|TBD|CHANGEME|<.*>)$/i.test(v.trim())));

function addr(problems: ConfigProblem[], path: string, v: unknown): void {
  if (isUnsetString(v)) return void problems.push({ path, problem: "unset (placeholder)" });
  if (typeof v !== "string" || !utils.isAddress(v)) return void problems.push({ path, problem: "not a valid address" });
  if (/^0x0{40}$/i.test(v)) problems.push({ path, problem: "zero address" });
}
function int(problems: ConfigProblem[], path: string, v: unknown, lo: number, hi: number): void {
  if (isUnsetString(v)) return void problems.push({ path, problem: "unset (placeholder)" });
  if (typeof v !== "number" || !Number.isInteger(v) || v < lo || v > hi) problems.push({ path, problem: `must be an integer in [${lo}, ${hi}]` });
}
function bigintString(problems: ConfigProblem[], path: string, v: unknown, positive: boolean): void {
  if (isUnsetString(v)) return void problems.push({ path, problem: "unset (placeholder)" });
  if (typeof v !== "string" || !/^[0-9]+$/.test(v)) return void problems.push({ path, problem: "must be a decimal integer string" });
  if (positive && BigInt(v) === 0n) problems.push({ path, problem: "must be positive" });
}
function num(problems: ConfigProblem[], path: string, v: unknown, lo: number, hi: number): void {
  if (typeof v !== "number" || !Number.isFinite(v) || v < lo || v > hi) problems.push({ path, problem: `must be a number in [${lo}, ${hi}]` });
}

/** Pure validation. Returns every problem (never just the first) so that an operator can fix them in one pass. */
export function validateConfig(raw: unknown): { problems: ConfigProblem[]; config?: MonitorConfig } {
  const problems: ConfigProblem[] = [];
  if (typeof raw !== "object" || raw === null) return { problems: [{ path: "$", problem: "config must be a JSON object" }] };
  const c = raw as Record<string, any>;
  if (c.schemaVersion !== 1) problems.push({ path: "schemaVersion", problem: "must be 1" });
  if (c.chainId !== 43114) problems.push({ path: "chainId", problem: "must be 43114 (Avalanche C-Chain); addresses of other chains are never reused" });

  const d = c.deployment ?? {};
  for (const k of ["controller", "pWavax", "pUsdc", "oracle"]) addr(problems, `deployment.${k}`, d[k]);
  int(problems, "deployment.deploymentBlock", d.deploymentBlock, 1, 1_000_000_000);

  const p = c.pilot ?? {};
  if (isUnsetString(p.label)) problems.push({ path: "pilot.label", problem: "unset (placeholder)" });
  int(problems, "pilot.wavaxCollateralFactorBp", p.wavaxCollateralFactorBp, 0, 9000);
  int(problems, "pilot.usdcCollateralFactorBp", p.usdcCollateralFactorBp, 0, 9000);
  int(problems, "pilot.usdcBorrowCapUsd", p.usdcBorrowCapUsd, 1, 1_000_000_000);
  if (typeof p.wavaxBorrowingDisabled !== "boolean") problems.push({ path: "pilot.wavaxBorrowingDisabled", problem: "must be a boolean" });
  int(problems, "pilot.protectionCapitalUsd", p.protectionCapitalUsd, 1, 1_000_000_000);
  int(problems, "pilot.operatorInventoryMinUsd", p.operatorInventoryMinUsd, 1, 1_000_000_000);
  int(problems, "pilot.operatorInventoryTargetUsd", p.operatorInventoryTargetUsd, 1, 1_000_000_000);
  int(problems, "pilot.cashFloorBp", p.cashFloorBp, 0, 10_000);

  // ---- the operator decisions ----
  if (!Array.isArray(c.operators)) problems.push({ path: "operators", problem: "unset (must list the liquidator operators)" });
  else {
    if (c.operators.length < 2) problems.push({ path: "operators", problem: "the pilot requires two liquidator operators" });
    const seen = new Set<string>();
    c.operators.forEach((o: any, i: number) => {
      if (isUnsetString(o?.name)) problems.push({ path: `operators[${i}].name`, problem: "unset (placeholder)" });
      addr(problems, `operators[${i}].address`, o?.address);
      if (typeof o?.address === "string") {
        const k = o.address.toLowerCase();
        if (seen.has(k)) problems.push({ path: `operators[${i}].address`, problem: "duplicate operator address" });
        seen.add(k);
      }
    });
  }
  if (isUnsetString(c.signer?.type)) problems.push({ path: "signer.type", problem: "unset (placeholder)" });
  else if (!(SIGNER_TYPES as readonly string[]).includes(c.signer.type)) problems.push({ path: "signer.type", problem: `must be one of ${SIGNER_TYPES.join(", ")}` });
  if (isUnsetString(c.alerts?.channel)) problems.push({ path: "alerts.channel", problem: "unset (placeholder)" });
  else if (!(ALERT_CHANNELS as readonly string[]).includes(c.alerts.channel)) problems.push({ path: "alerts.channel", problem: `must be one of ${ALERT_CHANNELS.join(", ")}` });
  int(problems, "execution.slippageBoundBp", c.execution?.slippageBoundBp, 1, 1000);
  int(problems, "reference.toleranceBp", c.reference?.toleranceBp, 1, 5000);
  bigintString(problems, "reference.minPoolLiquidity", c.reference?.minPoolLiquidity, true);
  {
    // the floor is 50% of the pool's trailing 7-day median in-range liquidity, computed ONCE at deployment and recorded with its source range
    const src = c.reference?.minPoolLiquiditySource;
    if (isUnsetString(c.reference?.minPoolLiquidity)) {
      /* already reported */
    } else if (typeof src !== "object" || src === null) problems.push({ path: "reference.minPoolLiquiditySource", problem: "the floor must be recorded with its source block range (run scripts/compute-min-pool-liquidity.ts)" });
    else {
      int(problems, "reference.minPoolLiquiditySource.fromBlock", src.fromBlock, 1, 1_000_000_000);
      int(problems, "reference.minPoolLiquiditySource.toBlock", src.toBlock, 1, 1_000_000_000);
      int(problems, "reference.minPoolLiquiditySource.samples", src.samples, 100, 100_000);
      bigintString(problems, "reference.minPoolLiquiditySource.medianLiquidity", src.medianLiquidity, true);
      if (typeof src.fromBlock === "number" && typeof src.toBlock === "number" && src.fromBlock >= src.toBlock) problems.push({ path: "reference.minPoolLiquiditySource", problem: "fromBlock must be below toBlock" });
      if (/^[0-9]+$/.test(String(src.medianLiquidity)) && /^[0-9]+$/.test(String(c.reference.minPoolLiquidity)) && BigInt(c.reference.minPoolLiquidity) !== BigInt(src.medianLiquidity) / 2n) {
        problems.push({ path: "reference.minPoolLiquidity", problem: "must equal 50% of reference.minPoolLiquiditySource.medianLiquidity (floor division)" });
      }
    }
  }
  addr(problems, "treasury.address", c.treasury?.address);
  {
    const x = c.executor;
    if (typeof x?.enabled !== "boolean") problems.push({ path: "executor.enabled", problem: "must be a boolean" });
    else if (x.enabled) {
      if (isUnsetString(x.operator)) problems.push({ path: "executor.operator", problem: "unset (placeholder): the name of this process's entry in `operators`" });
      else if (Array.isArray(c.operators) && !c.operators.some((o: any) => o?.name === x.operator)) problems.push({ path: "executor.operator", problem: "does not name an entry of `operators`" });
      if (isUnsetString(x.keystorePath)) problems.push({ path: "executor.keystorePath", problem: "unset (placeholder)" });
      if (isUnsetString(x.passwordEnv) || !/^[A-Z][A-Z0-9_]*$/.test(String(x.passwordEnv))) problems.push({ path: "executor.passwordEnv", problem: "must be the NAME of an environment variable (the password itself never goes in the file)" });
      if (typeof x.convertToUsdc !== "boolean") problems.push({ path: "executor.convertToUsdc", problem: "must be a boolean" });
      int(problems, "executor.minRepayUsdc", x.minRepayUsdc, 1, 1_000_000);
      int(problems, "executor.maxFeeGwei", x.maxFeeGwei, 1, 5000);
      bigintString(problems, "executor.minGasWei", x.minGasWei, true);
      if (c.keeper?.enabled === true) problems.push({ path: "executor.enabled", problem: "the executor and the treasury keeper are different wallets on different hosts: enable only one per process" });
    }
  }
  {
    const k = c.keeper;
    if (typeof k?.enabled !== "boolean") problems.push({ path: "keeper.enabled", problem: "must be a boolean" });
    else if (k.enabled) {
      if (isUnsetString(k.keystorePath)) problems.push({ path: "keeper.keystorePath", problem: "unset (placeholder)" });
      if (isUnsetString(k.passwordEnv) || !/^[A-Z][A-Z0-9_]*$/.test(String(k.passwordEnv))) problems.push({ path: "keeper.passwordEnv", problem: "must be the NAME of an environment variable (the password itself never goes in the file)" });
      int(problems, "keeper.dailySpendCapUsdc", k.dailySpendCapUsdc, 1, 1_000_000_000);
      int(problems, "keeper.confirmEvaluations", k.confirmEvaluations, 1, 20);
      int(problems, "keeper.confirmSeconds", k.confirmSeconds, 0, 3600);
      int(problems, "keeper.allowanceMarginBp", k.allowanceMarginBp, 0, 1000);
      int(problems, "keeper.maxFeeGwei", k.maxFeeGwei, 1, 5000);
      bigintString(problems, "keeper.minGasWei", k.minGasWei, true);
    }
  }

  const m = c.monitor ?? {};
  int(problems, "monitor.pollSeconds", m.pollSeconds, 1, 3600);
  int(problems, "monitor.maxBlockLagSeconds", m.maxBlockLagSeconds, 1, 3600);
  int(problems, "monitor.reorgMarginBlocks", m.reorgMarginBlocks, 0, 1000);
  int(problems, "monitor.logChunkBlocks", m.logChunkBlocks, 1, 100_000);
  if (isUnsetString(m.statePath)) problems.push({ path: "monitor.statePath", problem: "unset (placeholder)" });
  bigintString(problems, "monitor.dustUsd1e18", m.dustUsd1e18, true);
  for (const k of ["avaxFeedWarnRatio", "avaxFeedCritRatio", "usdcFeedWarnRatio", "usdcFeedCritRatio"]) num(problems, `monitor.${k}`, m[k], 0.01, 0.99);
  if (m.avaxFeedWarnRatio >= m.avaxFeedCritRatio) problems.push({ path: "monitor.avaxFeedWarnRatio", problem: "must be below avaxFeedCritRatio" });
  if (m.usdcFeedWarnRatio >= m.usdcFeedCritRatio) problems.push({ path: "monitor.usdcFeedWarnRatio", problem: "must be below usdcFeedCritRatio" });
  bigintString(problems, "monitor.minOperatorGasWei", m.minOperatorGasWei, true);
  int(problems, "monitor.utilisationWarnBp", m.utilisationWarnBp, 1, 10_000);
  int(problems, "monitor.borrowCapWarnBp", m.borrowCapWarnBp, 1, 10_000);
  int(problems, "monitor.noReferencePageSeconds", m.noReferencePageSeconds, 60, 86_400);
  if (
    !Array.isArray(m.escalationSeconds) ||
    m.escalationSeconds.length < 1 ||
    m.escalationSeconds.some((s: unknown, i: number, a: unknown[]) => typeof s !== "number" || !Number.isInteger(s) || s <= 0 || (i > 0 && (s as number) <= (a[i - 1] as number)))
  ) {
    problems.push({ path: "monitor.escalationSeconds", problem: "must be a strictly increasing list of positive integers (1 h / 4 h / 24 h = 3600, 14400, 86400)" });
  }
  return problems.length ? { problems } : { problems, config: raw as MonitorConfig };
}

export class ConfigError extends Error {
  constructor(public readonly problems: ConfigProblem[]) {
    super(`configuration refused (${problems.length} problem${problems.length === 1 ? "" : "s"}):\n` + problems.map((x) => `  - ${x.path}: ${x.problem}`).join("\n"));
    this.name = "ConfigError";
  }
}

/** Throws ConfigError listing every unset or invalid value. The caller (main) exits non-zero and starts nothing. */
export function requireValidConfig(raw: unknown): MonitorConfig {
  const { problems, config } = validateConfig(raw);
  if (!config) throw new ConfigError(problems);
  return config;
}

/** Secrets and endpoints come from the environment only. Returns the RPC URL or throws a message that does not contain any value. */
export function requireRpcUrlFromEnv(env: NodeJS.ProcessEnv = process.env): string {
  const url = env.AVALANCHE_MAINNET_RPC_URL || env.AVALANCHE_RPC || "";
  if (!url) throw new Error("no RPC endpoint: set AVALANCHE_MAINNET_RPC_URL (read from the environment only; never put it in the config file)");
  return url;
}

/** Defence in depth: a config FILE must not carry an RPC URL or any key-like secret. */
export function findSecretsInConfigText(text: string): string[] {
  const hits: string[] = [];
  if (/https?:\/\/[^"\s]*[A-Za-z0-9_-]{16,}/.test(text)) hits.push("a URL that looks like it carries a key or token");
  if (/\b0x[0-9a-fA-F]{64}\b/.test(text)) hits.push("a 32-byte hex string (private key shaped)");
  if (/(mnemonic|seed phrase|private[_ -]?key)/i.test(text)) hits.push("the words mnemonic / seed phrase / private key");
  return hits;
}

// One monitor CYCLE: pick a block, update the borrower index, read everything at that block, evaluate the rule for every indexed borrower,
// run the health checks, de-duplicate and deliver alerts, persist state. READ-ONLY: the only chain interface used is `provider.call`,
// `getBlock`, `getLogs`, `getBalance`/`getTransactionCount`; there is no signer in this package.
import { providers } from "ethers";
import { AlertManager } from "./alerts";
import type { AlertMessage, AlertStateJson } from "./alerts";
import { readAccountInputs, latestBlock, readBlockSnapshot, pIface } from "./chain";
import type { BlockSnapshot, Ctx } from "./chain";
import type { MonitorConfig } from "./config";
import { evaluateRule, Verdict, VERDICT_NAMES } from "./detect";
import type { RuleResult, RuleTestHooks } from "./detect";
import { emptyIndex, updateIndexBounded } from "./borrowers";
import type { IndexState } from "./borrowers";
import { emptyHealthState, marketFindings, operatorFindings, oracleFindings, treasuryFindings, treasuryOutflowFinding } from "./health";
import type { Finding, HealthState } from "./health";
import { multicall } from "./multicall";
import { safeError } from "./mask";
import { unrecoverableDebt } from "./backing";
import { emptyKeeperState } from "./keeper";
import { emptyExecutorState } from "./executor";
import type { ExecutorState } from "./executor";
import type { KeeperState } from "./keeper";
import type { BackingResult } from "./backing";
import { USDC } from "./constants";
import { classifyMargin, evaluateMarginPositions, marginFindings, marginConfigIface, marginUnrecoverableUsd, readMarginPositions, readPairBonusBps } from "./margin";
import type { MarginEval } from "./margin";
import { ctrlIface } from "./chain";

export interface MonitorState {
  index: IndexState;
  health: HealthState;
  alerts: AlertStateJson;
  unknownPriceSince: number | null;
  lastIndexCrossCheckAt: number;
  keeper: KeeperState;
  executor: ExecutorState;
}
export function emptyMonitorState(cfg: MonitorConfig): MonitorState {
  return { index: emptyIndex(cfg.deployment.deploymentBlock), health: emptyHealthState(), alerts: { active: {} }, unknownPriceSince: null, lastIndexCrossCheckAt: 0, keeper: emptyKeeperState(), executor: emptyExecutorState() };
}

export interface AccountReport {
  account: string;
  verdict: string;
  verdictCode: number;
  debtUnits: string;
  debtUsd: string;
  collUsd: string;
  maxRecoveryUsd: string;
  shortfallUsd: string;
}
export interface CycleReport {
  blockNumber: number;
  blockTimestamp: number;
  blind: boolean;
  /** blocks of pUSDC history the borrower index has NOT scanned yet (0 = complete) and the scan error, if any. The treasury keeper pays NOTHING while this is not complete (operator decision 9 Nov 2026). */
  indexBehindBlocks: number;
  indexError?: string;
  accounts: AccountReport[];
  /** verdict name -> count */
  counts: Record<string, number>;
  findings: Finding[];
  alertsSent: AlertMessage[];
  reference: { status: string; detail: string };
  expectedTreasuryCall: string;
  /** unrecoverable debt (src/backing.ts): sum of max(0, debt - collateral/LI) over borrowers, minus pUSDC reserves, clipped at 0; 1e18 USD */
  unrecoverableDebt: { usd: string; rawUsd: string; reservesUsd: string; complete: boolean };
  /** isolated margin: accounts the controller flags are REMOVED from `accounts` (they are not lending borrowers: nothing above or in the keeper applies to them) */
  margin: {
    classified: number;
    unknownFlags: string[];
    enabled: boolean;
    positions: Array<{ id: string; account: string; owner: string; status: number; verdict: string; debtUsd: string; assetsUsd: string; equityUsd: string; healthBps: string }>;
    counts: Record<string, number>;
  };
}

export interface CycleOptions {
  /** test hook (mutation testing); never set by main */
  hooks?: RuleTestHooks;
  /** clock override for tests, unix seconds; default = block time */
  nowSeconds?: number;
  /** extra accounts to evaluate besides the index (tests) */
  extraAccounts?: string[];
}

export async function runCycle(ctx: Ctx, state: MonitorState, alerts: AlertManager, opts: CycleOptions = {}): Promise<{ report: CycleReport; state: MonitorState }> {
  const cfg = ctx.cfg;
  // 1. borrower index, from the LOG endpoint (small range limit): bounded per cycle and resumable. It NEVER makes the cycle fail: a lagging or failing
  //    log endpoint is a finding below, the cursor keeps its progress. The snapshot block is chosen AFTER the scan so that it is fresh (a non-archive node
  //    serves state only for about the last 128 blocks, and a long catch-up must not push the snapshot out of that window).
  const head0 = await latestBlock(ctx.provider);
  const scan = await updateIndexBounded(ctx.logProvider ?? ctx.provider, cfg.deployment.pUsdc, state.index, head0.number, cfg.monitor.logs?.chunkBlocks ?? cfg.monitor.logChunkBlocks, cfg.monitor.reorgMarginBlocks, cfg.monitor.logs?.maxChunksPerCycle ?? 1_000_000);
  const index = scan.state;
  const blk = await latestBlock(ctx.provider);
  const now = opts.nowSeconds ?? blk.timestamp;
  const indexComplete0 = scan.behindBlocks === 0 && !scan.error;
  const accounts = [...new Set([...index.borrowers, ...(opts.extraAccounts ?? []).map((a) => a.toLowerCase())])].sort();
  // 2. everything at ONE block
  const snap = await readBlockSnapshot(ctx, blk.number);
  // 2a. isolated margin accounts are NOT lending borrowers (the controller's own flag decides): they leave every lending rule, the treasury figures and
  //     the keeper's input. An account whose flag cannot be read is excluded too (fail closed) and reported. They stay in the borrow-shares sum below.
  const cls = opts.hooks?.noClassifier ? { margin: new Set<string>(), unknown: [] as string[] } : await classifyMargin(ctx, cfg.deployment.controller, accounts, blk.number);
  const lendingAccounts = accounts.filter((a) => !cls.margin.has(a) && !cls.unknown.includes(a));
  const inputs = await readAccountInputs(ctx, snap, lendingAccounts);
  const params = { liquidationIncentive: snap.liquidationIncentive, dustUsd: BigInt(cfg.monitor.dustUsd1e18), toleranceBp: BigInt(cfg.reference.toleranceBp) };
  const results = new Map<string, RuleResult>();
  for (const a of lendingAccounts) results.set(a, evaluateRule(inputs.get(a)!, params, opts.hooks));
  // 2b. margin positions (read only; the risk engine's own metrics)
  let marginEvals: MarginEval[] = [];
  let marginExtra = { unknownFlags: cls.unknown, accountsNotFlagged: [] as string[], hookOk: true, operatorsNotFunders: [] as string[] };
  if (cfg.margin?.enabled) {
    const m = cfg.margin;
    const positions = await readMarginPositions(ctx, m.executor, blk.number);
    const bonus = await readPairBonusBps(ctx, m.config, positions.find((p) => p.status === 2), blk.number);
    marginEvals = await evaluateMarginPositions(ctx, m.riskEngine, positions, blk.number, m.watchHealthBps, bonus);
    const hook = ctrlIface.decodeFunctionResult("isolatedMarginRiskHook", await ctx.provider.call({ to: cfg.deployment.controller, data: ctrlIface.encodeFunctionData("isolatedMarginRiskHook") }, blk.number))[0] as string;
    const flagged = new Set<string>();
    const live = marginEvals.filter((e) => e.position.status === 2).map((e) => e.position.account);
    const direct = await classifyMargin(ctx, cfg.deployment.controller, live, blk.number);
    for (const a of direct.margin) flagged.add(a);
    const fundedRes = await Promise.all(cfg.operators.map(async (o) => marginConfigIface.decodeFunctionResult("fundedLiquidators", await ctx.provider.call({ to: m.config, data: marginConfigIface.encodeFunctionData("fundedLiquidators", [o.address]) }, blk.number))[0] as boolean));
    marginExtra = {
      unknownFlags: cls.unknown,
      accountsNotFlagged: live.filter((a) => !flagged.has(a)),
      hookOk: hook.toLowerCase() === m.riskEngine.toLowerCase(),
      operatorsNotFunders: cfg.operators.filter((_, i) => !fundedRes[i]).map((o) => o.name),
    };
  }
  // 3. shares consistency (sum over indexed borrowers)
  const sharesSum = await sumBorrowShares(ctx.provider, cfg.deployment.pUsdc, accounts, snap.blockNumber, ctx.multicallAddress);
  // 4. findings
  const findings: Finding[] = [];
  const lag = now - snap.blockTimestamp;
  const blind = lag > cfg.monitor.maxBlockLagSeconds;
  if (blind) findings.push({ key: "monitor:blind", severity: "crit", message: `latest block is ${lag}s old (limit ${cfg.monitor.maxBlockLagSeconds}s): the RPC is stale and nothing below can be trusted`, audience: "monitor-operator" });
  if (!indexComplete0) {
    const crit = scan.behindBlocks >= (cfg.monitor.logs?.behindCritBlocks ?? 3900);
    const warn = scan.behindBlocks >= (cfg.monitor.logs?.behindWarnBlocks ?? 600);
    if (warn || scan.error) findings.push({ key: "index:behind", severity: crit ? "crit" : "warn", message: `the borrower index is ${scan.behindBlocks} blocks behind the head (about ${Math.round(scan.behindBlocks * 0.94)} s): ${scan.error ?? "catching up"}. Accounts that borrowed since the cursor are not yet known to the monitor and the executor; the log endpoint (AVALANCHE_LOGS_RPC_URL, default the Avalanche public RPC) may be down or rate-limited`, audience: "monitor-operator" });
  }
  findings.push(...oracleFindings(snap, cfg));
  findings.push(...marginFindings(marginEvals, marginExtra));
  if (!cfg.margin?.enabled && cls.margin.size > 0) findings.push({ key: "margin:unconfigured", severity: "warn", message: `${cls.margin.size} isolated margin account(s) exist but the margin block of the configuration is not enabled: they are excluded from the lending checks and NOT monitored as margin positions`, audience: "monitor-operator" });
  const mk = marketFindings(snap, cfg, state.health, sharesSum, indexComplete0);
  findings.push(...mk.findings);
  const op = operatorFindings(snap, cfg, state.health);
  findings.push(...op.findings);
  // verdict findings (treasury document 5.3 table)
  let expectedTreasuryCall = 0n;
  let unknown = false;
  let divergence = false;
  for (const [a, r] of results) {
    const name = VERDICT_NAMES[r.verdict]!;
    if (r.verdict === Verdict.LIQUIDATABLE_RECOVERABLE) findings.push({ key: `acct:${a}:${name}`, severity: "warn", message: `account ${a} is liquidatable and fully recoverable (debt USD ${fmt18(r.debtUsd)}, collateral USD ${fmt18(r.collUsd)}): liquidators act`, audience: "liquidators" });
    else if (r.verdict === Verdict.UNRECOVERABLE_LIQUIDATE_FIRST) {
      const call = r.debtUsd > r.maxRecoveryUsd ? r.debtUsd - r.maxRecoveryUsd : 0n;
      expectedTreasuryCall += r.debtUnits;
      findings.push({ key: `acct:${a}:${name}`, severity: "crit", message: `account ${a} cannot be fully recovered by liquidation (debt USD ${fmt18(r.debtUsd)}, max recovery USD ${fmt18(r.maxRecoveryUsd)}); expected treasury call about USD ${fmt18(call)}: liquidate first, do NOT repay yet`, audience: "treasury-signers" });
    } else if (r.verdict === Verdict.DEFAULT_EXHAUSTED) {
      expectedTreasuryCall += r.debtUnits;
      findings.push({ key: `acct:${a}:${name}`, severity: "crit", escalates: true, message: `DEFAULT: account ${a} is exhausted (collateral USD ${fmt18(r.collUsd)}), debt ${r.debtUnits} USDC units is unpaid. T0. Treasury repayment is due (repayBorrowBehalf with the full-repay sentinel, human-signed); the guardian decides on pausing borrowing and minting`, audience: "treasury-signers" });
    } else if (r.verdict === Verdict.PRICE_DIVERGENCE) divergence = true;
    else if (r.verdict === Verdict.NO_REFERENCE_PRICE || r.verdict === Verdict.STALE_OR_ZERO_PRICE) unknown = true;
  }
  if (divergence) findings.push({ key: "price-divergence", severity: "crit", message: "oracle and reference price differ by more than the tolerance for a market an indebted account touches: the signature of an oracle failure (or a fast move the 30-minute TWAP has not caught up with). Nothing is paid. Consider pausing borrowing (guardian): a human decision", audience: "guardian" });
  let unknownPriceSince = state.unknownPriceSince;
  if (unknown) {
    unknownPriceSince = unknownPriceSince ?? now;
    const persisted = now - unknownPriceSince >= cfg.monitor.noReferencePageSeconds;
    findings.push({ key: "unknown-price", severity: persisted ? "crit" : "warn", message: `an indebted account cannot be evaluated (stale/zero oracle price or no reference price) for ${now - unknownPriceSince}s; the rule is silent and nothing is paid`, audience: "monitor-operator" });
  } else unknownPriceSince = null;
  const usdcIdx = snap.markets.findIndex((m) => m.underlying.toLowerCase() === USDC.toLowerCase());
  const reservesUsd = usdcIdx >= 0 ? (snap.markets[usdcIdx]!.totalReserves * snap.oraclePrices[usdcIdx]!) / 10n ** 18n : 0n;
  const marginRaw = marginEvals.reduce((a, e) => a + marginUnrecoverableUsd(e), 0n);
  const marginComplete = marginEvals.every((e) => e.verdict !== "UNPRICED" && e.verdict !== "STUCK");
  const backing: BackingResult = unrecoverableDebt(results.values(), snap.liquidationIncentive, reservesUsd, { rawUsd: marginRaw, complete: marginComplete });
  if (backing.unrecoverableUsd > 0n) findings.push({ key: "market:unrecoverable-debt", severity: "crit", message: `unrecoverable debt USD ${fmt18(backing.unrecoverableUsd)} (debt beyond what liquidating the remaining collateral can recover, minus reserves USD ${fmt18(reservesUsd)}${backing.complete ? "" : "; INCOMPLETE: some accounts could not be valued"}): suppliers are not fully backed once this is realised`, audience: "treasury-signers" });
  else if (!backing.complete) findings.push({ key: "market:unrecoverable-debt-incomplete", severity: "warn", message: "unrecoverable debt cannot be stated: at least one indebted account could not be valued (stale/zero price, no reference or divergence)", audience: "monitor-operator" });
  findings.push(...treasuryFindings(snap, cfg, expectedTreasuryCall));
  const outflow = treasuryOutflowFinding(state.health.lastTreasury, snap.treasury.usdc, snap.blockNumber, state.keeper.payments, cfg.treasury.address);
  if (outflow) findings.push(outflow);
  // 5. alerts
  const alertsSent = await alerts.process(findings, now);
  const counts: Record<string, number> = {};
  const accountReports: AccountReport[] = [];
  for (const [a, r] of results) {
    const name = VERDICT_NAMES[r.verdict]!;
    counts[name] = (counts[name] ?? 0) + 1;
    accountReports.push({ account: a, verdict: name, verdictCode: r.verdict, debtUnits: r.debtUnits.toString(), debtUsd: r.debtUsd.toString(), collUsd: r.collUsd.toString(), maxRecoveryUsd: r.maxRecoveryUsd.toString(), shortfallUsd: r.shortfallUsd.toString() });
  }
  accountReports.sort((x, y) => (BigInt(y.shortfallUsd) > BigInt(x.shortfallUsd) ? 1 : BigInt(y.shortfallUsd) < BigInt(x.shortfallUsd) ? -1 : 0));
  const next: MonitorState = {
    index,
    health: { lastExchangeRate: mk.next.lastExchangeRate, operatorNonce: op.next.operatorNonce, lastTreasury: { usdc: snap.treasury.usdc.toString(), blockNumber: snap.blockNumber } },
    alerts: alerts.toJson(),
    unknownPriceSince,
    lastIndexCrossCheckAt: state.lastIndexCrossCheckAt,
    keeper: state.keeper,
    executor: state.executor,
  };
  return {
    report: {
      blockNumber: snap.blockNumber,
      blockTimestamp: snap.blockTimestamp,
      blind,
      indexBehindBlocks: scan.behindBlocks,
      indexError: scan.error,
      accounts: accountReports,
      counts,
      findings,
      alertsSent,
      reference: snap.reference.status === "ok" ? { status: "ok", detail: `tick ${snap.reference.tick}` } : { status: "none", detail: snap.reference.reason },
      expectedTreasuryCall: expectedTreasuryCall.toString(),
      unrecoverableDebt: { usd: backing.unrecoverableUsd.toString(), rawUsd: backing.rawUsd.toString(), reservesUsd: reservesUsd.toString(), complete: backing.complete },
      margin: {
        classified: cls.margin.size,
        unknownFlags: cls.unknown,
        enabled: !!cfg.margin?.enabled,
        positions: marginEvals.map((e) => ({ id: e.position.id.toString(), account: e.position.account, owner: e.position.owner, status: e.position.status, verdict: e.verdict, debtUsd: (e.metrics?.debtValueUsd ?? 0n).toString(), assetsUsd: (e.metrics?.grossAssetValueUsd ?? 0n).toString(), equityUsd: (e.metrics?.equityUsd ?? 0n).toString(), healthBps: (e.metrics?.healthFactorBps ?? 0n).toString() })),
        counts: marginEvals.reduce((c: Record<string, number>, e) => ((c[e.verdict] = (c[e.verdict] ?? 0) + 1), c), {}),
      },
    },
    state: next,
  };
}

async function sumBorrowShares(provider: providers.Provider, pUsdc: string, accounts: string[], block: number, mc?: string): Promise<bigint | undefined> {
  let sum = 0n;
  for (let s = 0; s < accounts.length; s += 100) {
    const part = accounts.slice(s, s + 100);
    const res = await multicall(provider, part.map((a) => ({ target: pUsdc, iface: pIface, fn: "borrowShares", args: [a] })), block, mc);
    for (const r of res) {
      if (!r.success || !r.value) return undefined; // cannot judge: no mismatch claim
      sum += BigInt(r.value[0].toString());
    }
  }
  return sum;
}

const fmt18 = (v: bigint): string => `${v / 10n ** 18n}.${((v % 10n ** 18n) / 10n ** 14n).toString().padStart(4, "0")}`;

/** A failed cycle (RPC down, malformed config of the chain, ...) becomes a CRITICAL "blind" alert, never a silent skip. Text is masked. */
export async function reportBlind(alerts: AlertManager, err: unknown, nowSeconds: number): Promise<AlertMessage[]> {
  return alerts.raise({ key: "monitor:cycle-failed", severity: "crit", message: `monitor cycle failed: ${safeError(err)}. The monitor is BLIND until this clears`, audience: "monitor-operator" }, nowSeconds);
}

export type { BlockSnapshot };

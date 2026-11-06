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
import { emptyIndex, updateIndex } from "./borrowers";
import type { IndexState } from "./borrowers";
import { emptyHealthState, marketFindings, operatorFindings, oracleFindings, treasuryFindings, treasuryOutflowFinding } from "./health";
import type { Finding, HealthState } from "./health";
import { multicall } from "./multicall";
import { safeError } from "./mask";
import { unrecoverableDebt } from "./backing";
import { emptyKeeperState } from "./keeper";
import type { KeeperState } from "./keeper";
import type { BackingResult } from "./backing";
import { USDC } from "./constants";

export interface MonitorState {
  index: IndexState;
  health: HealthState;
  alerts: AlertStateJson;
  unknownPriceSince: number | null;
  lastIndexCrossCheckAt: number;
  keeper: KeeperState;
}
export function emptyMonitorState(cfg: MonitorConfig): MonitorState {
  return { index: emptyIndex(cfg.deployment.deploymentBlock), health: emptyHealthState(), alerts: { active: {} }, unknownPriceSince: null, lastIndexCrossCheckAt: 0, keeper: emptyKeeperState() };
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
  accounts: AccountReport[];
  /** verdict name -> count */
  counts: Record<string, number>;
  findings: Finding[];
  alertsSent: AlertMessage[];
  reference: { status: string; detail: string };
  expectedTreasuryCall: string;
  /** unrecoverable debt (src/backing.ts): sum of max(0, debt - collateral/LI) over borrowers, minus pUSDC reserves, clipped at 0; 1e18 USD */
  unrecoverableDebt: { usd: string; rawUsd: string; reservesUsd: string; complete: boolean };
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
  const blk = await latestBlock(ctx.provider);
  const now = opts.nowSeconds ?? blk.timestamp;
  // 1. borrower index
  const index = await updateIndex(ctx.provider, cfg.deployment.pUsdc, state.index, blk.number, cfg.monitor.logChunkBlocks, cfg.monitor.reorgMarginBlocks);
  const accounts = [...new Set([...index.borrowers, ...(opts.extraAccounts ?? []).map((a) => a.toLowerCase())])].sort();
  // 2. everything at ONE block
  const snap = await readBlockSnapshot(ctx, blk.number);
  const inputs = await readAccountInputs(ctx, snap, accounts);
  const params = { liquidationIncentive: snap.liquidationIncentive, dustUsd: BigInt(cfg.monitor.dustUsd1e18), toleranceBp: BigInt(cfg.reference.toleranceBp) };
  const results = new Map<string, RuleResult>();
  for (const a of accounts) results.set(a, evaluateRule(inputs.get(a)!, params, opts.hooks));
  // 3. shares consistency (sum over indexed borrowers)
  const sharesSum = await sumBorrowShares(ctx.provider, cfg.deployment.pUsdc, accounts, snap.blockNumber, ctx.multicallAddress);
  // 4. findings
  const findings: Finding[] = [];
  const lag = now - snap.blockTimestamp;
  const blind = lag > cfg.monitor.maxBlockLagSeconds;
  if (blind) findings.push({ key: "monitor:blind", severity: "crit", message: `latest block is ${lag}s old (limit ${cfg.monitor.maxBlockLagSeconds}s): the RPC is stale and nothing below can be trusted`, audience: "monitor-operator" });
  findings.push(...oracleFindings(snap, cfg));
  const mk = marketFindings(snap, cfg, state.health, sharesSum, true);
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
  const backing: BackingResult = unrecoverableDebt(results.values(), snap.liquidationIncentive, reservesUsd);
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
  };
  return {
    report: {
      blockNumber: snap.blockNumber,
      blockTimestamp: snap.blockTimestamp,
      blind,
      accounts: accountReports,
      counts,
      findings,
      alertsSent,
      reference: snap.reference.status === "ok" ? { status: "ok", detail: `tick ${snap.reference.tick}` } : { status: "none", detail: snap.reference.reason },
      expectedTreasuryCall: expectedTreasuryCall.toString(),
      unrecoverableDebt: { usd: backing.unrecoverableUsd.toString(), rawUsd: backing.rawUsd.toString(), reservesUsd: reservesUsd.toString(), complete: backing.complete },
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

// Health checks (build plan 2.4 b-e) as PURE functions over one block snapshot. They return findings; delivery, de-duplication and
// escalation are in alerts.ts. Thresholds are configuration (proposals, not results). Nothing here reads the chain or writes anything.
import { USDC, WAVAX } from "./constants";
import type { MonitorConfig } from "./config";
import type { BlockSnapshot } from "./chain";
import { E18 } from "./bigmath";

export type Severity = "info" | "warn" | "crit";
export interface Finding {
  /** stable identity for de-duplication, e.g. "feed:avax" */
  key: string;
  severity: Severity;
  message: string;
  /** who should act (text only) */
  audience: "monitor-operator" | "liquidators" | "treasury-signers" | "guardian";
  /** true: the age of this finding drives the 1 h / 4 h / 24 h escalation */
  escalates?: boolean;
  data?: Record<string, string | number | boolean>;
}

export interface HealthState {
  /** exchange rate seen at the previous evaluation, per pToken (lower-case) */
  lastExchangeRate: Record<string, string>;
  /** operator nonce last seen and when it last changed (unix seconds, block time) */
  operatorNonce: Record<string, { nonce: number; changedAt: number }>;
  /** keeper wallet USDC at the previous evaluation (units) and its block, for the unexplained-outflow check */
  lastTreasury?: { usdc: string; blockNumber: number };
}
export const emptyHealthState = (): HealthState => ({ lastExchangeRate: {}, operatorNonce: {} });

/**
 * USDC may leave the keeper wallet ONLY through a recorded keeper payment. If the balance is lower than (previous balance - payments recorded
 * between the two blocks), money moved without the keeper: the signature of a stolen key or a rogue process. Critical, page at once.
 */
export function treasuryOutflowFinding(prev: HealthState["lastTreasury"], nowUsdc: bigint, nowBlock: number, payments: Array<{ blockNumber: number; amountUsdc: string }>, treasuryAddress: string): Finding | undefined {
  if (!prev || nowBlock <= prev.blockNumber) return undefined;
  const paid = payments.filter((p) => p.blockNumber > prev.blockNumber && p.blockNumber <= nowBlock).reduce((a, p) => a + BigInt(p.amountUsdc), 0n);
  const floor = BigInt(prev.usdc) - paid;
  if (nowUsdc >= floor) return undefined;
  return { key: "treasury:unexplained-outflow", severity: "crit", message: `keeper wallet ${treasuryAddress} lost ${floor - nowUsdc} USDC units that no recorded payment explains (balance ${nowUsdc}, expected at least ${floor}): possible key compromise. Move the remaining funds with the Safe procedure and rotate the key`, audience: "treasury-signers" };
}

const usd6 = (n: number): bigint => BigInt(n) * 1_000_000n;
const wei = (s: string): bigint => BigInt(s);

export function oracleFindings(snap: BlockSnapshot, cfg: MonitorConfig): Finding[] {
  const f: Finding[] = [];
  const m = cfg.monitor;
  const one = (name: "avax" | "usdc", warn: number, crit: number) => {
    const fd = snap.feeds[name];
    if (!fd.ok) {
      f.push({ key: `feed:${name}`, severity: "crit", message: `${name.toUpperCase()} Chainlink feed unreadable or non-positive; the guarded oracle returns 0 and the default rule is silent`, audience: "monitor-operator" });
      return;
    }
    const ratio = Number(fd.ageSeconds) / fd.guardSeconds;
    if (ratio >= crit) f.push({ key: `feed:${name}`, severity: "crit", message: `${name.toUpperCase()} feed age ${fd.ageSeconds}s is ${(ratio * 100).toFixed(0)}% of the ${fd.guardSeconds}s oracle guard`, audience: "monitor-operator", data: { ageSeconds: Number(fd.ageSeconds), guardSeconds: fd.guardSeconds } });
    else if (ratio >= warn) f.push({ key: `feed:${name}`, severity: "warn", message: `${name.toUpperCase()} feed age ${fd.ageSeconds}s is ${(ratio * 100).toFixed(0)}% of the ${fd.guardSeconds}s oracle guard`, audience: "monitor-operator", data: { ageSeconds: Number(fd.ageSeconds), guardSeconds: fd.guardSeconds } });
  };
  one("avax", m.avaxFeedWarnRatio, m.avaxFeedCritRatio);
  one("usdc", m.usdcFeedWarnRatio, m.usdcFeedCritRatio);
  snap.markets.forEach((mk, i) => {
    if (snap.oraclePrices[i] === 0n) f.push({ key: `oracle-zero:${mk.pToken.toLowerCase()}`, severity: "crit", message: `guarded oracle returns 0 for ${mk.pToken} (stale, non-positive or unreadable): liquidations and borrows are blocked, the default rule is silent`, audience: "monitor-operator" });
  });
  if (snap.reference.status === "none") f.push({ key: "reference:none", severity: "warn", message: `no reference price (fail closed): ${snap.reference.reason}`, audience: "monitor-operator" });
  return f;
}

export function marketFindings(snap: BlockSnapshot, cfg: MonitorConfig, prev: HealthState, sharesSum: bigint | undefined, indexComplete: boolean): { findings: Finding[]; next: Pick<HealthState, "lastExchangeRate"> } {
  const f: Finding[] = [];
  const next: Record<string, string> = { ...prev.lastExchangeRate };
  for (const mk of snap.markets) {
    const k = mk.pToken.toLowerCase();
    if (!mk.readOk) f.push({ key: `market-read:${k}`, severity: "crit", message: `market ${mk.pToken} could not be read completely`, audience: "monitor-operator" });
    const before = prev.lastExchangeRate[k] ? BigInt(prev.lastExchangeRate[k]!) : undefined;
    if (before !== undefined && mk.exchangeRate < before) f.push({ key: `exchange-rate:${k}`, severity: "crit", message: `exchange rate of ${mk.pToken} fell from ${before} to ${mk.exchangeRate}: supplier value dropped (bad debt recognised or an accounting fault)`, audience: "treasury-signers", data: { before: before.toString(), now: mk.exchangeRate.toString() } });
    if (mk.exchangeRate > 0n) next[k] = mk.exchangeRate.toString();
  }
  const dep = cfg.deployment;
  const find = (a: string) => snap.markets.find((m) => m.pToken.toLowerCase() === a.toLowerCase());
  const pU = find(dep.pUsdc);
  const pW = find(dep.pWavax);
  if (!pU || !pW) {
    f.push({ key: "market-missing", severity: "crit", message: "pUSDC or pWAVAX is not in the controller's market list", audience: "monitor-operator" });
    return { findings: f, next: { lastExchangeRate: next } };
  }
  if (pU.underlying.toLowerCase() !== USDC.toLowerCase() || pW.underlying.toLowerCase() !== WAVAX.toLowerCase()) f.push({ key: "market-underlying", severity: "crit", message: "configured markets do not have the expected underlyings (USDC / WAVAX)", audience: "monitor-operator" });
  // configuration drift against the pilot configuration
  const p = cfg.pilot;
  const cf = (bp: number) => BigInt(bp) * 10n ** 14n;
  if (pW.collateralFactor !== cf(p.wavaxCollateralFactorBp)) f.push({ key: "drift:cf-wavax", severity: "crit", message: `WAVAX collateral factor ${pW.collateralFactor} differs from the pilot configuration ${cf(p.wavaxCollateralFactorBp)}`, audience: "treasury-signers" });
  if (pU.collateralFactor !== cf(p.usdcCollateralFactorBp)) f.push({ key: "drift:cf-usdc", severity: "crit", message: `USDC collateral factor ${pU.collateralFactor} differs from the pilot configuration ${cf(p.usdcCollateralFactorBp)}`, audience: "treasury-signers" });
  if (p.wavaxBorrowingDisabled && !pW.borrowPaused) f.push({ key: "drift:wavax-borrow", severity: "crit", message: "WAVAX borrowing is enabled but the pilot configuration disables it", audience: "treasury-signers" });
  const expCap = usd6(p.usdcBorrowCapUsd);
  if (pU.borrowCap !== expCap && pU.borrowCap !== expCap + 1n) f.push({ key: "drift:cap-usdc", severity: "warn", message: `pUSDC borrow cap ${pU.borrowCap} differs from the pilot configuration ${expCap}`, audience: "treasury-signers" });
  if (p.cashFloorBp > 0 && pU.cashFloor === 0n) f.push({ key: "drift:cash-floor", severity: "warn", message: "pUSDC borrow cash floor is 0 (disabled) but the pilot configuration expects one", audience: "treasury-signers" });
  // utilisation, cash against floor, cap use, reserves
  const denom = pU.cash + pU.totalBorrows - pU.totalReserves;
  const util = denom > 0n ? Number((pU.totalBorrows * 10_000n) / denom) : 0;
  if (util >= cfg.monitor.utilisationWarnBp) f.push({ key: "util:usdc", severity: "warn", message: `pUSDC utilisation ${(util / 100).toFixed(2)}%`, audience: "monitor-operator", data: { utilisationBp: util } });
  if (pU.cashFloor > 0n && pU.cash < pU.cashFloor) f.push({ key: "floor:usdc", severity: "warn", message: `pUSDC cash ${pU.cash} is below the borrow cash floor ${pU.cashFloor}: new borrows are refused (suppliers' exit room is protected)`, audience: "monitor-operator" });
  if (pU.borrowCap > 0n) {
    const use = Number((pU.totalBorrows * 10_000n) / pU.borrowCap);
    if (use >= cfg.monitor.borrowCapWarnBp) f.push({ key: "cap:usdc", severity: "warn", message: `pUSDC borrows are ${(use / 100).toFixed(2)}% of the borrow cap`, audience: "monitor-operator", data: { capUseBp: use } });
  }
  // shares consistency
  if (!pU.accountingEnabled) f.push({ key: "shares:disabled", severity: "crit", message: "pUSDC unified borrow accounting (shares) is not enabled", audience: "monitor-operator" });
  else if (sharesSum !== undefined && sharesSum !== pU.totalBorrowShares) {
    f.push({ key: "shares:mismatch", severity: indexComplete ? "crit" : "warn", message: `sum of indexed borrowers' shares ${sharesSum} != totalBorrowShares ${pU.totalBorrowShares}: ${indexComplete ? "accounting drift" : "the borrower index may be incomplete"}`, audience: "monitor-operator" });
  }
  // pause state (information for the guardian runbook)
  if (pU.mintPaused || pU.borrowPaused) f.push({ key: "paused:usdc", severity: "info", message: `pUSDC mint paused=${pU.mintPaused}, borrow paused=${pU.borrowPaused}`, audience: "guardian" });
  return { findings: f, next: { lastExchangeRate: next } };
}

export function operatorFindings(snap: BlockSnapshot, cfg: MonitorConfig, prev: HealthState): { findings: Finding[]; next: Pick<HealthState, "operatorNonce"> } {
  const f: Finding[] = [];
  const nextNonce: HealthState["operatorNonce"] = { ...prev.operatorNonce };
  const pU = snap.markets.find((m) => m.pToken.toLowerCase() === cfg.deployment.pUsdc.toLowerCase());
  const aggregateDebt = pU?.totalBorrows ?? 0n;
  const required = (aggregateDebt * 75n) / 100n; // no-recycling inventory rule: 0.75 x aggregate debt
  for (const o of snap.operators) {
    const k = o.address.toLowerCase();
    const was = prev.operatorNonce[k];
    nextNonce[k] = was && was.nonce === o.nonce ? was : { nonce: o.nonce, changedAt: snap.blockTimestamp };
    if (o.usdc < required) f.push({ key: `inventory:${k}`, severity: "crit", message: `operator ${o.name}: USDC inventory ${o.usdc} is below 0.75 x aggregate pUSDC debt (${required})`, audience: "liquidators", data: { inventory: o.usdc.toString(), required: required.toString() } });
    else if (o.usdc < usd6(cfg.pilot.operatorInventoryMinUsd)) f.push({ key: `inventory:${k}`, severity: "warn", message: `operator ${o.name}: USDC inventory ${o.usdc} is below the pilot requirement of ${usd6(cfg.pilot.operatorInventoryMinUsd)} (USD ${cfg.pilot.operatorInventoryMinUsd})`, audience: "liquidators" });
    if (o.avaxWei < wei(cfg.monitor.minOperatorGasWei)) f.push({ key: `gas:${k}`, severity: "crit", message: `operator ${o.name}: AVAX gas balance ${o.avaxWei} wei is below the minimum ${cfg.monitor.minOperatorGasWei}`, audience: "liquidators" });
  }
  return { findings: f, next: { operatorNonce: nextNonce } };
}

export function treasuryFindings(snap: BlockSnapshot, cfg: MonitorConfig, expectedTreasuryCall: bigint): Finding[] {
  const f: Finding[] = [];
  const need = usd6(cfg.pilot.protectionCapitalUsd);
  if (snap.treasury.usdc < need) f.push({ key: "treasury:capital", severity: "warn", message: `protection capital ${snap.treasury.usdc} USDC units is below the pilot requirement ${need}`, audience: "treasury-signers" });
  if (expectedTreasuryCall > 0n && snap.treasury.usdc < expectedTreasuryCall) f.push({ key: "treasury:funding", severity: "crit", message: `treasury USDC ${snap.treasury.usdc} is below the sum of debt over accounts at UNRECOVERABLE_LIQUIDATE_FIRST or worse (${expectedTreasuryCall}): top up`, audience: "treasury-signers" });
  return f;
}

export const _E18 = E18;

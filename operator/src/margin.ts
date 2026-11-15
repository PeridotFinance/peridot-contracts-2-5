// ISOLATED MARGIN: the READ layer (no signer, nothing is ever sent) and the pure planning rules of the operator's margin step.
//
// Why this module exists. A 2x margin position is a borrower of the SAME pUSDC market as lending, held in its own IsolatedMarginAccount. Seen through
// the lending lens (controller collateral factors) EVERY such account is "in shortfall" all the time, so without a classification
//   * the monitor would raise "liquidatable" for it constantly, count it in the treasury figures and could hand it to the treasury keeper;
//   * the lending executor would approve, simulate, fail and reset every cycle (the controller refuses `liquidateBorrow` for these accounts).
// The authoritative signal is the controller's own flag `isolatedMarginAccounts(address)`: the same flag it uses to refuse `liquidateBorrow` and
// `seize`. This module reads it (and the margin positions with their risk-engine health) at ONE block, fails closed on an unreadable flag, and holds
// the sizing / decline rules for the funded liquidation:
//   * the operator liquidates through `liquidateFunded` only (it repays from its own USDC and receives the position pTokens with a bonus of at most 5%);
//   * `minSeizeValueBps` is FIXED at 10,000 (break-even): an insolvent position is DECLINED, the debt stays in the market and a human decides;
//   * the repayment is not chosen by the operator (the risk engine decides it), so the allowance is BOUNDED, not exact: `maxRepayUnderlying` is
//     min(inventory, daily-cap remaining, per-call cap, debt) and the contract itself refuses a repayment above it (LiquidationError 28).
import { utils } from "ethers";
import type { BigNumber, providers } from "ethers";
import { CONTROLLER_ABI, MARGIN_CONFIG_ABI, MARGIN_EXECUTOR_ABI, MARGIN_LIQUIDATOR_ABI, MARGIN_RISK_ENGINE_ABI } from "./abi";
import type { Finding } from "./health";
import { multicall } from "./multicall";
import type { Call } from "./multicall";

const ctrlIface = new utils.Interface(CONTROLLER_ABI);
export const marginExecutorIface = new utils.Interface(MARGIN_EXECUTOR_ABI);
export const marginRiskIface = new utils.Interface(MARGIN_RISK_ENGINE_ABI);
export const marginLiquidatorIface = new utils.Interface(MARGIN_LIQUIDATOR_ABI);
export const marginConfigIface = new utils.Interface(MARGIN_CONFIG_ABI);

/** `IsolatedMarginTypes.Status` */
export const MarginStatus = { NONE: 0, OPENING: 1, ACTIVE: 2, CLOSING: 3, LIQUIDATING: 4, CLOSED: 5, LIQUIDATED: 6 } as const;
/** the funded route's break-even floor: value received / value repaid, in bp. NOT configurable (an insolvent position must be declined, D3). */
export const MIN_SEIZE_VALUE_BPS = 10_000;
/** `IsolatedMarginLiquidatorUpgradeable.LiquidationError` codes this module reacts to */
export const LIQ_NOT_FUNDER = 27;
export const LIQ_REPAY_ABOVE_MAX = 28;
export const LIQ_VALUE_FLOOR = 32;
/** hard bound on the position scan (the pilot has a handful; beyond this the scan must become an index, so it refuses instead of growing silently) */
export const MAX_POSITION_SCAN = 2_000;

export interface MarginCtx {
  provider: providers.Provider;
  multicallAddress?: string;
}

// ------------------------------------------------------------------ classification
export interface Classification {
  /** accounts the controller flags as isolated margin accounts */
  margin: Set<string>;
  /** accounts whose flag could not be read: they are treated as NOT lending borrowers either (fail closed) and reported */
  unknown: string[];
}
export async function classifyMargin(ctx: MarginCtx, controller: string, accounts: string[], block: number, chunk = 200): Promise<Classification> {
  const margin = new Set<string>();
  const unknown: string[] = [];
  for (let s = 0; s < accounts.length; s += chunk) {
    const part = accounts.slice(s, s + chunk);
    const calls: Call[] = part.map((a) => ({ target: controller, iface: ctrlIface, fn: "isolatedMarginAccounts", args: [a] }));
    const res = await multicall(ctx.provider, calls, block, ctx.multicallAddress);
    part.forEach((a, i) => {
      const r = res[i]!;
      if (!r.success || !r.value) unknown.push(a.toLowerCase());
      else if (r.value[0] === true) margin.add(a.toLowerCase());
    });
  }
  return { margin, unknown };
}

// ------------------------------------------------------------------ positions
export interface MarginPosition {
  id: bigint;
  owner: string;
  account: string;
  marginPToken: string;
  positionPToken: string;
  debtPToken: string;
  borrowedPrincipal: bigint;
  side: number;
  status: number;
}
export interface MarginMetrics {
  grossAssetValueUsd: bigint;
  debtValueUsd: bigint;
  equityUsd: bigint;
  maintenanceRequirementUsd: bigint;
  healthFactorBps: bigint;
}
export type MarginVerdict = "INACTIVE" | "STUCK" | "UNPRICED" | "HEALTHY" | "WATCH" | "LIQUIDATABLE" | "INSOLVENT";
export interface MarginEval {
  position: MarginPosition;
  verdict: MarginVerdict;
  metrics?: MarginMetrics;
  liquidatable?: boolean;
  bonusBps?: number;
}

export async function readMarginPositions(ctx: MarginCtx, executor: string, block: number, chunk = 100): Promise<MarginPosition[]> {
  const next = BigInt((marginExecutorIface.decodeFunctionResult("nextPositionId", await ctx.provider.call({ to: executor, data: marginExecutorIface.encodeFunctionData("nextPositionId") }, block))[0] as BigNumber).toString());
  const count = next > 0n ? Number(next - 1n) : 0;
  if (count > MAX_POSITION_SCAN) throw new Error(`margin position scan refused: ${count} positions exceed the scan bound ${MAX_POSITION_SCAN} (build an index)`);
  const out: MarginPosition[] = [];
  for (let s = 1; s <= count; s += chunk) {
    const ids: number[] = [];
    for (let i = s; i < s + chunk && i <= count; i++) ids.push(i);
    const res = await multicall(ctx.provider, ids.map((i) => ({ target: executor, iface: marginExecutorIface, fn: "positions", args: [i] })), block, ctx.multicallAddress);
    res.forEach((r, k) => {
      if (!r.success || !r.value) throw new Error(`margin position ${ids[k]} could not be read`);
      out.push({
        id: BigInt(r.value[0].toString()),
        owner: (r.value[1] as string).toLowerCase(),
        account: (r.value[2] as string).toLowerCase(),
        marginPToken: (r.value[3] as string).toLowerCase(),
        positionPToken: (r.value[4] as string).toLowerCase(),
        debtPToken: (r.value[5] as string).toLowerCase(),
        borrowedPrincipal: BigInt(r.value[8].toString()),
        side: Number(r.value[10]),
        status: Number(r.value[11]),
      });
    });
  }
  return out;
}

/** Metrics and the liquidatable flag for every position that can carry risk (ACTIVE; anything in a transient status is reported as STUCK). */
export async function evaluateMarginPositions(ctx: MarginCtx, riskEngine: string, positions: MarginPosition[], block: number, watchHealthBps: number, bonusBps: number): Promise<MarginEval[]> {
  const live = positions.filter((p) => p.status === MarginStatus.ACTIVE);
  const calls: Call[] = [];
  for (const p of live) {
    calls.push({ target: riskEngine, iface: marginRiskIface, fn: "getMetrics", args: [p.account] });
    calls.push({ target: riskEngine, iface: marginRiskIface, fn: "isLiquidatable", args: [p.account] });
  }
  const res = await multicall(ctx.provider, calls, block, ctx.multicallAddress);
  const byId = new Map<string, MarginEval>();
  live.forEach((p, i) => {
    const m = res[2 * i]!;
    const l = res[2 * i + 1]!;
    const metrics = m.success && m.value ? toMetrics(m.value[0]) : undefined;
    const liquidatable = l.success && l.value ? (l.value[0] as boolean) : undefined;
    byId.set(p.id.toString(), { position: p, metrics, liquidatable, bonusBps, verdict: evaluateMargin(p, metrics, liquidatable, watchHealthBps) });
  });
  return positions.map((p) => byId.get(p.id.toString()) ?? { position: p, verdict: evaluateMargin(p, undefined, undefined, watchHealthBps) });
}

function toMetrics(t: any): MarginMetrics {
  return {
    grossAssetValueUsd: BigInt(t.grossAssetValueUsd.toString()),
    debtValueUsd: BigInt(t.debtValueUsd.toString()),
    equityUsd: BigInt(t.equityUsd.toString()),
    maintenanceRequirementUsd: BigInt(t.maintenanceRequirementUsd.toString()),
    healthFactorBps: BigInt(t.healthFactorBps.toString()),
  };
}

/** The pair's liquidation bonus (bp) as the Ledger set it; falls back to the pilot's 500 when the read fails (the figure only sizes an estimate). */
export async function readPairBonusBps(ctx: MarginCtx, config: string, p: MarginPosition | undefined, block: number): Promise<number> {
  if (!p) return 500;
  try {
    const out = marginConfigIface.decodeFunctionResult("getPairRisk", await ctx.provider.call({ to: config, data: marginConfigIface.encodeFunctionData("getPairRisk", [p.marginPToken, p.positionPToken, p.debtPToken]) }, block))[0] as any;
    return Number(out.liquidationBonusBps);
  } catch {
    return 500;
  }
}

/** PURE. INSOLVENT = collateral no longer covers the debt (equity <= 0): the funded route's break-even floor refuses it. */
export function evaluateMargin(p: MarginPosition, m: MarginMetrics | undefined, liquidatable: boolean | undefined, watchHealthBps: number): MarginVerdict {
  if (p.status === MarginStatus.OPENING || p.status === MarginStatus.CLOSING || p.status === MarginStatus.LIQUIDATING) return "STUCK";
  if (p.status !== MarginStatus.ACTIVE) return "INACTIVE";
  if (!m || liquidatable === undefined) return "UNPRICED";
  if (m.debtValueUsd === 0n) return "HEALTHY";
  if (m.equityUsd <= 0n) return "INSOLVENT";
  if (liquidatable) return "LIQUIDATABLE";
  if (m.healthFactorBps < BigInt(watchHealthBps)) return "WATCH";
  return "HEALTHY";
}

/** Debt beyond what seizing the collateral (with the bonus) can recover, 1e18 USD. Only meaningful for LIQUIDATABLE / INSOLVENT positions. */
export function marginUnrecoverableUsd(e: MarginEval): bigint {
  if (!e.metrics || (e.verdict !== "LIQUIDATABLE" && e.verdict !== "INSOLVENT")) return 0n;
  const bonus = BigInt(e.bonusBps ?? 0);
  const seizable = (e.metrics.grossAssetValueUsd * 10_000n) / (10_000n + bonus);
  return e.metrics.debtValueUsd > seizable ? e.metrics.debtValueUsd - seizable : 0n;
}

// ------------------------------------------------------------------ the operator's sizing rules (pure)
export interface MarginRound {
  ts: number;
  positionId: string;
  repay: string;
}
/** USDC units repaid by margin rounds in the rolling 24 hours before `now`. */
export function repaidInWindow(rounds: ReadonlyArray<MarginRound>, now: number, windowSeconds = 86_400): bigint {
  let sum = 0n;
  for (const r of rounds) if (r.ts > now - windowSeconds) sum += BigInt(r.repay);
  return sum;
}
export interface MarginPlan {
  maxRepay: bigint;
  /** which bound is the binding one, for the alert text */
  bound: "inventory" | "daily-cap" | "per-call-cap" | "debt";
  /** nothing to do (below the minimum): `reason` says why */
  reason?: string;
}
/** Interest accrues between the read of the debt and the block of the call (about 1 s per block): a FULL liquidation repays the debt as it is THEN, a few units above the one read now, and the contract refuses a repayment above `maxRepayUnderlying` (LiquidationError 28). The rehearsal showed exactly that, so the debt bound carries this margin (the treasury keeper uses the same 10 bp). */
export const DEBT_BOUND_MARGIN_BP = 10n;
export function planMarginRepay(a: { debt: bigint; inventory: bigint; dailyCap: bigint; repaidToday: bigint; perCallCap: bigint; minRepay: bigint }): MarginPlan {
  const dailyRemaining = a.dailyCap > a.repaidToday ? a.dailyCap - a.repaidToday : 0n;
  const debtBound = a.debt === 0n ? 0n : a.debt + (a.debt * DEBT_BOUND_MARGIN_BP) / 10_000n + 1n;
  const bounds: Array<[MarginPlan["bound"], bigint]> = [["inventory", a.inventory], ["daily-cap", dailyRemaining], ["per-call-cap", a.perCallCap], ["debt", debtBound]];
  let [bound, maxRepay] = bounds[0]!;
  for (const [b, v] of bounds) if (v < maxRepay) [bound, maxRepay] = [b, v];
  if (a.debt === 0n) return { maxRepay: 0n, bound: "debt", reason: "no debt" };
  if (maxRepay < a.minRepay) return { maxRepay: 0n, bound, reason: `${bound} bound ${maxRepay} is below the minimum repayment ${a.minRepay}` };
  return { maxRepay, bound };
}

// ------------------------------------------------------------------ revert decoding
/** Raw revert data out of an ethers v5 call error (providers differ in where they put it). */
export function revertData(e: unknown): string | undefined {
  const seen = new Set<unknown>();
  const walk = (x: any, depth: number): string | undefined => {
    if (!x || typeof x !== "object" || depth > 6 || seen.has(x)) return undefined;
    seen.add(x);
    for (const k of ["data", "error", "body"]) {
      const v = x[k];
      if (typeof v === "string") {
        if (/^0x[0-9a-fA-F]{8,}$/.test(v)) return v;
        if (k === "body") {
          try {
            const r = walk(JSON.parse(v), depth + 1);
            if (r) return r;
          } catch {
            /* not JSON */
          }
        }
      } else {
        const r = walk(v, depth + 1);
        if (r) return r;
      }
    }
    return undefined;
  };
  return walk(e, 0);
}
/** The `LiquidationError(uint8 code)` code of a reverted call, or undefined when the revert is something else. */
export function liquidationErrorCode(e: unknown): number | undefined {
  const data = revertData(e);
  if (!data) return undefined;
  try {
    const parsed = marginLiquidatorIface.parseError(data);
    if (parsed.name === "LiquidationError") return Number(parsed.args[0]);
  } catch {
    /* another error */
  }
  return undefined;
}

// ------------------------------------------------------------------ monitor findings (pure)
const fmt18 = (v: bigint): string => `${v / 10n ** 18n}.${((v % 10n ** 18n) / 10n ** 16n).toString().padStart(2, "0")}`;
const hf = (m: MarginMetrics | undefined): string => (m ? (m.healthFactorBps > 10n ** 12n ? "n/a" : `${(Number(m.healthFactorBps) / 100).toFixed(1)}%`) : "n/a");

/**
 * Findings for margin positions. The audiences follow the funded design (decision D3): LIQUIDATABLE is for the operators; INSOLVENT is a human
 * decision (the operators' break-even floor declines it, the debt stays in the pUSDC market, the insurance fund is not used by the funded route).
 * Nothing here is ever payable by the treasury keeper (which only reads `report.accounts`, from which margin accounts are removed).
 */
export function marginFindings(evals: MarginEval[], extra: { unknownFlags: string[]; accountsNotFlagged: string[]; hookOk: boolean; operatorsNotFunders: string[] }): Finding[] {
  const f: Finding[] = [];
  for (const e of evals) {
    const id = e.position.id.toString();
    const d = e.metrics ? `debt USD ${fmt18(e.metrics.debtValueUsd)}, assets USD ${fmt18(e.metrics.grossAssetValueUsd)}, health ${hf(e.metrics)}` : "no valuation";
    if (e.verdict === "LIQUIDATABLE") f.push({ key: `margin:${id}:LIQUIDATABLE`, severity: "warn", message: `margin position ${id} (account ${e.position.account}) is below its maintenance margin (${d}): the funded operators liquidate it (break-even floor)`, audience: "liquidators" });
    else if (e.verdict === "INSOLVENT") f.push({ key: `margin:${id}:INSOLVENT`, severity: "crit", escalates: true, message: `margin position ${id} (account ${e.position.account}) is INSOLVENT (${d}): the operators' break-even floor DECLINES it, the debt stays in the pUSDC market (est. unrecoverable USD ${fmt18(marginUnrecoverableUsd(e))}) and the insurance fund is not used by the funded route. A human decision is needed (cover from the treasury or accept the loss)`, audience: "treasury-signers" });
    else if (e.verdict === "WATCH") f.push({ key: `margin:${id}:WATCH`, severity: "warn", message: `margin position ${id} is approaching liquidation (${d})`, audience: "monitor-operator" });
    else if (e.verdict === "UNPRICED") f.push({ key: `margin:${id}:UNPRICED`, severity: "warn", message: `margin position ${id} cannot be valued (the risk engine reverted: stale or unreadable oracle price): no liquidation is possible until it can`, audience: "monitor-operator" });
    else if (e.verdict === "STUCK") f.push({ key: `margin:${id}:STUCK`, severity: "crit", message: `margin position ${id} is in the transient status ${e.position.status} at a block boundary (it is set and cleared inside one transaction): investigate`, audience: "monitor-operator" });
  }
  if (extra.unknownFlags.length) f.push({ key: "margin:classification-unreadable", severity: "warn", message: `the controller's margin flag could not be read for ${extra.unknownFlags.length} account(s) (${extra.unknownFlags.slice(0, 3).join(", ")}): they are excluded from the lending checks until it can`, audience: "monitor-operator" });
  if (extra.accountsNotFlagged.length) f.push({ key: "margin:account-not-flagged", severity: "crit", message: `margin position account(s) ${extra.accountsNotFlagged.slice(0, 3).join(", ")} are NOT flagged by the controller as isolated margin accounts: the lending path would treat them as ordinary borrowers`, audience: "monitor-operator" });
  if (!extra.hookOk) f.push({ key: "margin:hook-drift", severity: "crit", message: "the controller's isolated-margin risk hook is not the configured risk engine: margin borrows are not checked by the expected engine", audience: "monitor-operator" });
  for (const op of extra.operatorsNotFunders) f.push({ key: `margin:not-funder:${op}`, severity: "warn", message: `operator ${op} is not on the funded-liquidator allowlist: it cannot liquidate margin positions (Ledger: addFundedLiquidator after the 24 h queue)`, audience: "monitor-operator" });
  return f;
}

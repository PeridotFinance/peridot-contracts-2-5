// READ-BACK of a mined transaction: pure verification of what happened against what the keeper intended. Any problem HALTS the keeper.
// Two branches, because a sweep legitimately emits no execution: (execute) the order was filled and the close path moved the funds to the owner,
// (sweep) the order was only marked EXPIRED / CANCELLED and nothing else moved.
import { utils } from "ethers";
import type { providers } from "ethers";
import { ORDER_STATUS, POSITION_STATUS } from "./constants";
import type { PositionView, Snapshot } from "./orders";
import { executorIface, registryIface } from "./orders";

export interface ParsedEvents {
  executed: Array<{ orderId: bigint; positionId: bigint; executor: string; priceE18: bigint; closeBps: number; returnedMargin: bigint }>;
  cancelled: Array<{ orderId: bigint; positionId: bigint; reason: number }>;
  expired: Array<{ orderId: bigint; positionId: bigint }>;
  closed: Array<{ positionId: bigint; closeBps: number; returnedMarginPTokens: bigint; fullyClosed: boolean }>;
}
const big = (x: unknown): bigint => BigInt((x as { toString(): string }).toString());

/** Only logs emitted by the registry and by the margin executor are read; everything else in the receipt is ignored. */
export function parseReceiptEvents(logs: providers.Log[], registry: string, executor: string): ParsedEvents {
  const out: ParsedEvents = { executed: [], cancelled: [], expired: [], closed: [] };
  for (const l of logs) {
    const a = l.address.toLowerCase();
    if (a === registry.toLowerCase()) {
      let p: utils.LogDescription;
      try {
        p = registryIface.parseLog(l);
      } catch {
        continue;
      }
      if (p.name === "OrderExecuted") out.executed.push({ orderId: big(p.args.orderId), positionId: big(p.args.positionId), executor: String(p.args.executor).toLowerCase(), priceE18: big(p.args.oraclePriceE18), closeBps: Number(p.args.closeBps), returnedMargin: big(p.args.returnedMargin) });
      else if (p.name === "OrderCancelled") out.cancelled.push({ orderId: big(p.args.orderId), positionId: big(p.args.positionId), reason: Number(p.args.reason) });
      else if (p.name === "OrderExpired") out.expired.push({ orderId: big(p.args.orderId), positionId: big(p.args.positionId) });
    } else if (a === executor.toLowerCase()) {
      let p: utils.LogDescription;
      try {
        p = executorIface.parseLog(l);
      } catch {
        continue;
      }
      if (p.name === "PositionClosed") out.closed.push({ positionId: big(p.args.positionId), closeBps: Number(p.args.closeBps), returnedMarginPTokens: big(p.args.returnedMarginPTokens), fullyClosed: !!p.args.fullyClosed });
    }
  }
  return out;
}

export interface ReadBackInput {
  orderId: bigint;
  keeper: string;
  events: ParsedEvents;
  /** state just before the transaction's block and at its block; `exact` false = one of them is the fallback (latest) and the vault delta is only bounded */
  before: Snapshot;
  after: Snapshot;
  /** true when both snapshots are at exact blocks (kept for diagnostics: the vault check is `>=` either way) */
  exact: boolean;
}
const same = (a: string, b: string): boolean => a.toLowerCase() === b.toLowerCase();

function commonProblems(i: ReadBackInput, problems: string[]): void {
  for (const [t, v] of Object.entries(i.before.keeperBalances)) {
    const a = i.after.keeperBalances[t];
    if (a === undefined || a !== v) problems.push(`the keeper wallet's balance of ${t} changed (${v} -> ${a}): the executor must receive nothing`);
  }
  if (i.after.pos.id !== i.before.pos.id || !same(i.after.pos.owner, i.before.pos.owner)) problems.push("the position's id or owner differs between the two reads");
  if (i.after.order && !same(i.after.order.owner, i.before.order?.owner ?? i.after.order.owner)) problems.push("the order's owner changed");
}

export function verifyExecution(i: ReadBackInput): string[] {
  const problems: string[] = [];
  const o = i.after.order;
  if (!o) return ["the order could not be read back"];
  if (o.status !== ORDER_STATUS.EXECUTED) problems.push(`order status ${o.status} is not EXECUTED`);
  const ex = i.events.executed.filter((e) => e.orderId === i.orderId);
  if (i.events.executed.length !== 1 || ex.length !== 1) problems.push(`${i.events.executed.length} OrderExecuted events (${ex.length} for this order), expected exactly one`);
  const e = ex[0];
  if (e) {
    if (e.positionId !== o.positionId) problems.push("OrderExecuted names a different position");
    if (!same(e.executor, i.keeper)) problems.push("OrderExecuted names a different executor");
    if (e.closeBps !== o.closeBps) problems.push(`OrderExecuted closeBps ${e.closeBps} differs from the order's ${o.closeBps}`);
    if (e.priceE18 === 0n) problems.push("OrderExecuted oracle price is zero");
    else if (o.triggerAbove ? e.priceE18 < o.triggerPriceE18 : e.priceE18 > o.triggerPriceE18) problems.push(`executed at ${e.priceE18} which does not cross the trigger ${o.triggerPriceE18}`);
    if (e.returnedMargin === 0n) problems.push("no margin was returned to the owner");
    const pc = i.events.closed.filter((c) => c.positionId === o.positionId);
    if (i.events.closed.length !== 1 || pc.length !== 1) problems.push(`${i.events.closed.length} PositionClosed events from the margin executor, expected exactly one for the position`);
    const c = pc[0];
    if (c) {
      if (c.closeBps !== o.closeBps) problems.push(`PositionClosed closeBps ${c.closeBps} differs from the order's ${o.closeBps}`);
      if (c.returnedMarginPTokens !== e.returnedMargin) problems.push(`PositionClosed returned ${c.returnedMarginPTokens} but OrderExecuted reports ${e.returnedMargin}`);
      if (o.closeBps === 10_000 && !c.fullyClosed) problems.push("a full close did not fully close the position");
      if (c.fullyClosed ? i.after.pos.status !== POSITION_STATUS.CLOSED : i.after.pos.status !== POSITION_STATUS.ACTIVE) problems.push(`position status ${i.after.pos.status} does not match fullyClosed=${c.fullyClosed}`);
    }
    if (i.before.free === null || i.after.free === null) problems.push("the owner's vault balance could not be read");
    else {
      const delta = i.after.free - i.before.free;
      // AT LEAST the returned margin: the vault settles the owner's accrued fee-distributor rewards into freeBalance in the same call (_settle), so an exact match would halt on a legitimate execution
      if (delta < e.returnedMargin) problems.push(`the owner's vault balance rose by ${delta}, the close reports ${e.returnedMargin} returned`);
    }
  }
  if (i.after.open.includes(i.orderId)) problems.push("the order is still in the position's open list");
  if (i.after.pos.status !== POSITION_STATUS.ACTIVE && i.after.open.length !== 0) problems.push(`the position ended but ${i.after.open.length} orders are still open on it (mutual cancellation failed)`);
  commonProblems(i, problems);
  return problems;
}

/** `canReason`: the canExecute reason that made this a sweep (2 expired, 3 inactive, 4 owner changed). */
export function verifySweep(i: ReadBackInput, canReason: number): string[] {
  const problems: string[] = [];
  const o = i.after.order;
  if (!o) return ["the order could not be read back"];
  if (i.events.executed.length !== 0) problems.push("a sweep emitted OrderExecuted: the order was executed instead");
  if (i.events.closed.length !== 0) problems.push("a sweep emitted PositionClosed: a position was closed");
  const canc = i.events.cancelled.filter((c) => c.orderId === i.orderId);
  const exp = i.events.expired.filter((c) => c.orderId === i.orderId);
  if (o.status === ORDER_STATUS.CANCELLED) {
    if (canc.length !== 1 || exp.length !== 0) problems.push("CANCELLED without exactly one OrderCancelled for this order");
    else {
      if (canc[0]!.positionId !== o.positionId) problems.push("OrderCancelled names a different position");
      if (canc[0]!.reason !== 2 && canc[0]!.reason !== 3) problems.push(`OrderCancelled reason ${canc[0]!.reason} is not 2 (inactive) or 3 (owner changed)`);
    }
    if (canReason === 2) problems.push("an expired order (reason 2) was CANCELLED, not EXPIRED");
  } else if (o.status === ORDER_STATUS.EXPIRED) {
    if (exp.length !== 1 || canc.length !== 0) problems.push("EXPIRED without exactly one OrderExpired for this order");
    else if (exp[0]!.positionId !== o.positionId) problems.push("OrderExpired names a different position");
  } else problems.push(`order status ${o.status} is neither CANCELLED nor EXPIRED`);
  if (i.after.pos.status !== i.before.pos.status) problems.push(`the position's status changed (${i.before.pos.status} -> ${i.after.pos.status}) in a sweep`);
  if (i.after.open.includes(i.orderId)) problems.push("the order is still in the position's open list");
  commonProblems(i, problems);
  return problems;
}

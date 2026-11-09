// The DECISION, pure: from what was read (orders and canExecute), the cooldowns, the budget and the clock to the list of transactions to attempt.
// Mapping of the canExecute reason (docs/margin-orders/SPEC.md):
//   0 executable                    -> execute
//   2 expired, 3 inactive, 4 owner changed -> sweep (executeOrder marks it EXPIRED / CANCELLED and frees the slot; no revert)
//   5 oracle unavailable            -> wait + alert (nothing is sent: the order waits, nothing is cancelled)
//   6 trigger not reached, 7 paused -> wait
//   1 not open                      -> final (never read again)
import { ORDER_STATUS, REASON } from "./constants";
import type { OrderItem } from "./orders";
import type { CooldownEntry } from "./state";

export interface Action {
  id: string;
  kind: "execute" | "sweep";
  /** the canExecute reason behind it (0 for an execution) */
  reason: number;
  positionId: bigint;
  orderKind: number;
  priceE18: bigint;
}
export interface Decision {
  actions: Action[];
  /** ids that are no longer open: dropped from the open list for good */
  final: string[];
  /** still open */
  open: string[];
  waiting: Array<{ id: string; why: string }>;
  oracleDown: string[];
  cooling: Array<{ id: string; until: number; why: string }>;
  /** due but beyond this cycle's / this day's send budget */
  deferred: string[];
  /** ids whose canExecute no longer says "due": their cooldown/failure history is dropped */
  resetCooldown: string[];
  anomalies: string[];
}
export interface DecideInput {
  items: OrderItem[];
  now: number;
  cooldown: Record<string, CooldownEntry>;
  sweep: boolean;
  /** sends allowed in this cycle (min of the per-cycle limit and what is left of the daily one) */
  budget: number;
}

export function decide(inp: DecideInput): Decision {
  const d: Decision = { actions: [], final: [], open: [], waiting: [], oracleDown: [], cooling: [], deferred: [], resetCooldown: [], anomalies: [] };
  const due: Action[] = [];
  for (const it of inp.items) {
    const id = it.id.toString();
    const o = it.order;
    if (!o) {
      d.waiting.push({ id, why: "getOrder failed" });
      d.open.push(id); // unknown: keep it in the open list, read it again
      continue;
    }
    if (o.status === ORDER_STATUS.NONE) {
      // an id below nextOrderId that reads as NONE: a lagging node or a broken registry; it is read again, never acted on
      d.anomalies.push(`order ${id} reads as NONE although it is below nextOrderId`);
      d.open.push(id);
      continue;
    }
    if (o.status !== ORDER_STATUS.OPEN) {
      d.final.push(id);
      continue;
    }
    d.open.push(id);
    const c = it.can;
    if (!c) {
      d.waiting.push({ id, why: "canExecute failed" });
      continue;
    }
    if (c.reason === REASON.NOT_OPEN) {
      d.waiting.push({ id, why: "canExecute says not open while getOrder says open (blocks differ); read again" });
      continue;
    }
    if (c.reason === REASON.ORACLE) d.oracleDown.push(id);
    const isDue = c.executable || (inp.sweep && (c.reason === REASON.EXPIRED || c.reason === REASON.INACTIVE || c.reason === REASON.OWNER_CHANGED));
    if (!isDue) {
      d.waiting.push({ id, why: c.reason === REASON.PAUSED && !c.executable ? "paused" : `reason ${c.reason}` });
      if (c.reason === REASON.TRIGGER || c.reason === REASON.ORACLE) d.resetCooldown.push(id);
      continue;
    }
    const cd = inp.cooldown[id];
    if (cd && cd.until > inp.now) {
      d.cooling.push({ id, until: cd.until, why: cd.why });
      continue;
    }
    due.push({ id, kind: c.executable ? "execute" : "sweep", reason: c.reason, positionId: o.positionId, orderKind: o.kind, priceE18: c.priceE18 });
  }
  // executions first and stop-losses before take-profits (a stop-loss is the time-critical one); sweeps last; then by id
  const rank = (a: Action): number => (a.kind === "execute" ? (a.orderKind === 1 ? 0 : 1) : 2);
  due.sort((a, b) => rank(a) - rank(b) || (BigInt(a.id) < BigInt(b.id) ? -1 : 1));
  d.actions = due.slice(0, Math.max(0, inp.budget));
  d.deferred = due.slice(Math.max(0, inp.budget)).map((a) => a.id);
  return d;
}

/** Cooldown after a simulate-revert: doubles per consecutive failure from `base` up to `max`. */
export function nextCooldown(prev: CooldownEntry | undefined, now: number, kind: "wait" | "attention", why: string, p: { base: number; max: number; unknown: number }): CooldownEntry {
  const fails = (prev?.fails ?? 0) + 1;
  const secs = kind === "attention" ? p.unknown : Math.min(p.max, p.base * 2 ** (fails - 1));
  return { until: now + secs, fails, firstFailAt: prev?.firstFailAt ?? now, why };
}

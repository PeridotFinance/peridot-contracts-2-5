import test from "node:test";
import assert from "node:assert/strict";
import { decide, nextCooldown } from "../src/decide";
import type { OrderItem, OrderView } from "../src/orders";

const order = (id: number, o: Partial<OrderView> = {}): OrderView => ({ id: BigInt(id), positionId: 1n, owner: "0x1", kind: 1, triggerAbove: false, triggerPriceE18: 1n, closeBps: 10_000, maxSlippageBps: 100, expiry: 2n, status: 1, ...o });
const item = (id: number, reason: number, o: Partial<OrderView> = {}): OrderItem => ({ id: BigInt(id), order: order(id, o), can: { executable: reason === 0, priceE18: 5n, reason } });
const base = { now: 1000, cooldown: {}, sweep: true, budget: 10 };

test("reason mapping: 0 execute; 2/3/4 sweep; 5/6/7 wait; 1 and non-open orders are final", () => {
  const d = decide({ ...base, items: [item(1, 0), item(2, 2), item(3, 3), item(4, 4), item(5, 5), item(6, 6), item(7, 7), { id: 8n, order: order(8, { status: 2 }), can: null }, { id: 9n, order: order(9, { status: 4 }), can: null }] });
  assert.deepEqual(d.actions.map((a) => `${a.id}:${a.kind}`), ["1:execute", "2:sweep", "3:sweep", "4:sweep"]);
  assert.deepEqual(d.final, ["8", "9"]);
  assert.deepEqual(d.oracleDown, ["5"]);
  assert.deepEqual(d.waiting.map((w) => w.id), ["5", "6", "7"]);
  assert.deepEqual(d.open, ["1", "2", "3", "4", "5", "6", "7"]);
});
test("stop-loss before take-profit, executions before sweeps, then by id; the budget cuts the tail", () => {
  const items = [item(1, 3), item(2, 0, { kind: 0 }), item(3, 0, { kind: 1 }), item(4, 0, { kind: 1 })];
  const d = decide({ ...base, items, budget: 3 });
  assert.deepEqual(d.actions.map((a) => a.id), ["3", "4", "2"]);
  assert.deepEqual(d.deferred, ["1"]);
  assert.deepEqual(decide({ ...base, items, budget: 0 }).actions, []);
});
test("cooldown: a due order on cooldown is not an action; an expired cooldown is", () => {
  const items = [item(1, 0), item(2, 0)];
  const d = decide({ ...base, items, cooldown: { "1": { until: 1500, fails: 1, firstFailAt: 900, why: "x" }, "2": { until: 999, fails: 1, firstFailAt: 900, why: "x" } } });
  assert.deepEqual(d.actions.map((a) => a.id), ["2"]);
  assert.deepEqual(d.cooling.map((c) => c.id), ["1"]);
});
test("a trigger that is no longer crossed drops the failure history", () => {
  const d = decide({ ...base, items: [item(1, 6)], cooldown: { "1": { until: 5000, fails: 3, firstFailAt: 1, why: "x" } } });
  assert.deepEqual(d.resetCooldown, ["1"]);
});
test("sweeping off: reasons 2/3/4 wait", () => {
  const d = decide({ ...base, sweep: false, items: [item(1, 3)] });
  assert.deepEqual(d.actions, []);
});
test("unreadable and NONE orders are kept for the next read, never acted on", () => {
  const d = decide({ ...base, items: [{ id: 1n, order: null, can: null }, { id: 2n, order: order(2, { status: 0 }), can: null }, { id: 3n, order: order(3), can: null }] });
  assert.deepEqual(d.actions, []);
  assert.deepEqual(d.open, ["1", "2", "3"]);
  assert.equal(d.anomalies.length, 1);
});
test("cooldown schedule: doubling to the cap; unclassified reverts use the flat long cooldown; firstFailAt is kept", () => {
  const p = { base: 30, max: 300, unknown: 900 };
  let c = nextCooldown(undefined, 100, "wait", "a", p);
  assert.deepEqual([c.fails, c.until, c.firstFailAt], [1, 130, 100]);
  c = nextCooldown(c, 200, "wait", "a", p);
  assert.deepEqual([c.fails, c.until, c.firstFailAt], [2, 260, 100]);
  for (let i = 0; i < 6; i++) c = nextCooldown(c, 1000, "wait", "a", p);
  assert.equal(c.until, 1300);
  assert.equal(nextCooldown(c, 2000, "attention", "u", p).until, 2900);
});

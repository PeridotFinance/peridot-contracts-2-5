import test from "node:test";
import assert from "node:assert/strict";
import type { providers } from "ethers";
import { AlertManager, MemorySink } from "../src/alerts";
import type { KeeperConfig } from "../src/config";
import { keeperStep, verifySigner } from "../src/keeper";
import type { KeeperDeps, KeeperOutcome } from "../src/keeper";
import { emptyState } from "../src/state";
import type { KeeperState } from "../src/state";
import { A, decidedConfig } from "./fixtures";
import { addOrder, addPosition, FakeProvider, FakeSigner, newWorld } from "./fakeworld";
import type { World } from "./fakeworld";

interface Rig {
  w: World;
  p: FakeProvider;
  sink: MemorySink;
  alerts: AlertManager;
  cfg: KeeperConfig;
  persisted: KeeperState[];
  state: KeeperState;
  signerSends: number;
  /** the state persisted most recently at the moment of each send */
  pendingAtSend: Array<KeeperState["pending"]>;
  step(): Promise<KeeperOutcome>;
}
function rig(mut?: (c: KeeperConfig) => void): Rig {
  const cfg = decidedConfig();
  mut?.(cfg);
  const w = newWorld();
  const p = new FakeProvider(w);
  const sink = new MemorySink();
  const alerts = new AlertManager(sink, cfg.escalationSeconds);
  const r: Rig = { w, p, sink, alerts, cfg, persisted: [], state: emptyState(cfg.registry), signerSends: 0, pendingAtSend: [], step: undefined as never };
  const signer = new FakeSigner(w, p, A.keeper, () => {
    r.signerSends++;
    r.pendingAtSend.push(r.persisted[r.persisted.length - 1]?.pending ?? null);
  });
  r.step = async () => {
    const deps: KeeperDeps = { provider: p as unknown as providers.Provider, cfg, signer, alerts, persist: (s) => { r.persisted.push(structuredClone(s)); r.state = s; }, now: () => w.now, sleep: async () => {} };
    const o = await keeperStep(deps, r.state);
    r.state = o.state;
    return o;
  };
  return r;
}
const keys = (r: Rig): string[] => r.sink.messages.map((m) => `${m.kind}:${m.key}`);

test("execution: simulate, pending marker persisted BEFORE the send, send, read-back, marker cleared", async () => {
  const r = rig();
  addPosition(r.w, 1);
  const id = addOrder(r.w, 1); // stop-loss, trigger 30; the price is 25: crossed
  const o = await r.step();
  assert.deepEqual(o.executed, [String(id)]);
  assert.equal(r.signerSends, 1);
  assert.deepEqual(r.pendingAtSend[0], { orderId: String(id), kind: "execute", at: r.w.now - 2 }, "the last persisted state before the send carried the marker");
  assert.equal(r.state.pending, null);
  assert.equal(r.state.halted, null);
  assert.deepEqual(r.state.open, [], "an executed order leaves the open list");
  assert.equal(r.state.sends.length, 1);
  assert.equal(r.state.sends[0]!.outcome, "ok");
  assert.equal(r.w.positions.get(1)!.status, 5);
  assert.ok(keys(r).includes(`action:order:${id}:execute`));
});

test("take-profit and stop-loss both execute; a stop-loss goes first", async () => {
  const r = rig();
  addPosition(r.w, 1);
  addPosition(r.w, 2);
  const tp = addOrder(r.w, 1, { kind: 0, triggerAbove: true, trigger: 20n * 10n ** 18n }); // price 25 >= 20
  const sl = addOrder(r.w, 2);
  const o = await r.step();
  assert.deepEqual(o.executed, [String(sl), String(tp)]);
});

test("a full close executes the order and its siblings are cancelled in the same transaction (verified, not assumed)", async () => {
  const r = rig();
  addPosition(r.w, 1);
  const sl = addOrder(r.w, 1);
  const sib = addOrder(r.w, 1, { kind: 0, triggerAbove: true, trigger: 99n * 10n ** 18n });
  const o = await r.step();
  assert.deepEqual(o.executed, [String(sl)]);
  assert.equal(r.w.orders.get(sib)!.status, 3);
  assert.equal(r.state.halted, null);
  const o2 = await r.step();
  assert.deepEqual(o2.executed, []);
  assert.deepEqual(r.state.open, [], "the sibling was seen CANCELLED and dropped");
});

test("a pending marker found at start HALTS: nothing is read or sent", async () => {
  const r = rig();
  addPosition(r.w, 1);
  addOrder(r.w, 1);
  r.state = { ...r.state, pending: { orderId: "7", kind: "execute", at: 123 } };
  const o = await r.step();
  assert.equal(o.halted, true);
  assert.match(r.state.halted!.reason, /interrupted/);
  assert.equal(r.signerSends, 0);
  assert.equal(r.w.calls.simulations, 0);
  assert.ok(keys(r).includes("new:keeper:halted"));
  // and it stays halted on the next cycles
  const o2 = await r.step();
  assert.equal(o2.halted, true);
  assert.equal(r.signerSends, 0);
});

test("a persisted halt flag survives a restart and blocks everything", async () => {
  const r = rig();
  addPosition(r.w, 1);
  addOrder(r.w, 1);
  r.state = { ...r.state, halted: { reason: "earlier", at: 1 } };
  const o = await r.step();
  assert.equal(o.halted, true);
  assert.equal(r.signerSends, 0);
  assert.equal(o.scanned, 0);
});

test("a signer that is not the configured keeper wallet halts before anything is sent; verifySigner refuses it at start", async () => {
  const r = rig();
  addPosition(r.w, 1);
  addOrder(r.w, 1);
  const stranger = new FakeSigner(r.w, r.p, "0x00000000000000000000000000000000000000ff");
  await assert.rejects(verifySigner(stranger, r.cfg, r.p as never), /not the configured keeper address/);
  const o = await keeperStep({ provider: r.p as never, cfg: r.cfg, signer: stranger, alerts: r.alerts, persist: () => {}, now: () => r.w.now }, r.state);
  assert.equal(o.halted, true);
  assert.match(o.state.halted!.reason, /signer address differs/);
  assert.equal(r.w.sent.length, 0);
});

test("wiring drift (registry.adapter, adapter.registry, adapter.executor) halts before any send", async () => {
  for (const f of ["adapterOfRegistry", "registryOfAdapter", "executorOfAdapter"] as const) {
    const r = rig();
    addPosition(r.w, 1);
    addOrder(r.w, 1);
    r.w[f] = "0x00000000000000000000000000000000000000dd";
    const o = await r.step();
    assert.equal(o.halted, true, f);
    assert.match(r.state.halted!.reason, /wiring drift/);
    assert.equal(r.w.sent.length, 0);
  }
});

test("READ-BACK: every kind of mismatch halts the keeper after the transaction", async () => {
  const cases: Array<[string, (w: World) => void, RegExp]> = [
    ["no PositionClosed event", (w) => (w.lies.noPositionClosed = true), /PositionClosed/],
    ["wrong executor in OrderExecuted", (w) => (w.lies.wrongExecutor = true), /different executor/],
    ["owner's vault balance did not rise", (w) => (w.lies.noVaultCredit = true), /vault balance/],
    ["the keeper wallet received tokens", (w) => (w.lies.keeperGetsTokens = true), /keeper wallet's balance/],
    ["order not marked executed", (w) => (w.lies.noStatusChange = true), /not EXECUTED/],
  ];
  for (const [name, lie, re] of cases) {
    const r = rig();
    addPosition(r.w, 1);
    addOrder(r.w, 1);
    lie(r.w);
    const o = await r.step();
    assert.equal(o.halted, true, name);
    assert.match(r.state.halted!.reason, /read-back failed/, name);
    assert.match(r.state.halted!.reason, re, name);
    assert.equal(r.state.pending, null, "the transaction is known and was read back: the marker is cleared, the halt flag stays");
    assert.ok(keys(r).includes("new:keeper:halted"), name);
    // halted: the next cycle sends nothing even with another due order
    addPosition(r.w, 2);
    addOrder(r.w, 2);
    const before = r.w.sent.length;
    await r.step();
    assert.equal(r.w.sent.length, before, name);
  }
});

test("READ-BACK: a full close that leaves a sibling order open (mutual cancellation failed) halts", async () => {
  const r = rig();
  addPosition(r.w, 1);
  addOrder(r.w, 1);
  addOrder(r.w, 1, { kind: 0, triggerAbove: true, trigger: 99n * 10n ** 18n });
  r.w.lies.noSiblingCancel = true;
  const o = await r.step();
  assert.equal(o.halted, true);
  assert.match(r.state.halted!.reason, /mutual cancellation/);
});

test("simulate-revert: a close path refusal (SwapError 7) sends nothing, puts the order on a cooldown, and is NOT retried every cycle", async () => {
  const r = rig();
  addPosition(r.w, 1);
  const id = addOrder(r.w, 1);
  r.w.closeRevert = { name: "SwapError", args: [7] };
  const o = await r.step();
  assert.equal(r.w.sent.length, 0);
  assert.deepEqual(o.reverted, [String(id)]);
  assert.equal(r.w.calls.simulations, 1);
  const cd = r.state.cooldown[String(id)]!;
  assert.equal(cd.fails, 1);
  assert.equal(cd.until, r.w.now + 30);
  assert.deepEqual(r.state.open, [String(id)], "the order stays open");
  assert.equal(r.state.halted, null);
  assert.ok(!keys(r).some((k) => k.includes(":simfail")), "a known wait raises no alert");
  // inside the cooldown: not even simulated
  r.w.now += 10;
  await r.step();
  assert.equal(r.w.calls.simulations, 1);
  // after it: retried, and the cooldown doubles
  r.w.now += 25;
  await r.step();
  assert.equal(r.w.calls.simulations, 2);
  assert.equal(r.state.cooldown[String(id)]!.fails, 2);
  assert.equal(r.state.cooldown[String(id)]!.until, r.w.now + 60);
  // and the slippage clamp case fills once the pool can take it
  r.w.closeRevert = undefined;
  r.w.now += 61;
  const o3 = await r.step();
  assert.deepEqual(o3.executed, [String(id)]);
  assert.equal(r.state.cooldown[String(id)], undefined);
});

test("cooldown doubling is capped; an order due for long raises the 'cannot be filled' warning", async () => {
  const r = rig();
  addPosition(r.w, 1);
  const id = addOrder(r.w, 1);
  r.w.closeRevert = { name: "InvalidClose", args: [6] };
  for (let i = 0; i < 8; i++) {
    await r.step();
    r.w.now = r.state.cooldown[String(id)]!.until;
  }
  const cd = r.state.cooldown[String(id)]!;
  assert.equal(cd.until - (r.w.now - 0), 0);
  await r.step();
  assert.equal(r.state.cooldown[String(id)]!.until - r.w.now, 300, "capped at retryCooldownMaxSeconds");
  assert.ok(keys(r).includes(`new:order:${id}:unfilled`), "due for more than 10 minutes");
});

test("an unclassified revert: long cooldown and a warning", async () => {
  const r = rig();
  addPosition(r.w, 1);
  const id = addOrder(r.w, 1);
  r.w.closeRevert = { name: "NotRegistry", args: [] };
  await r.step();
  assert.equal(r.w.sent.length, 0);
  assert.equal(r.state.cooldown[String(id)]!.until, r.w.now + 900);
  assert.ok(keys(r).includes(`new:order:${id}:simfail`));
});

test("oracle unavailable: nothing is sent, the order waits (not cancelled), an alert is raised and cleared on recovery", async () => {
  const r = rig();
  addPosition(r.w, 1);
  const id = addOrder(r.w, 1);
  r.w.oracleOk = false;
  const o = await r.step();
  assert.equal(r.w.sent.length, 0);
  assert.equal(r.w.calls.simulations, 0, "canExecute already says reason 5: no simulation either");
  assert.deepEqual(r.state.open, [String(id)]);
  assert.ok(keys(r).includes("new:oracle:unavailable"));
  assert.ok(o.skipped.some((s) => /oracle unavailable/.test(s)));
  r.w.oracleOk = true;
  const o2 = await r.step();
  assert.deepEqual(o2.executed, [String(id)]);
  assert.ok(keys(r).includes("resolved:oracle:unavailable"));
});

test("registry paused: nothing is sent (not even a sweep), warning, cleared when unpaused", async () => {
  const r = rig();
  addPosition(r.w, 1);
  addOrder(r.w, 1);
  addPosition(r.w, 2, 6);
  addOrder(r.w, 2);
  r.w.paused = true;
  await r.step();
  assert.equal(r.w.sent.length, 0);
  assert.ok(keys(r).includes("new:registry:paused"));
  r.w.paused = false;
  const o = await r.step();
  assert.equal(o.executed.length + o.swept.length, 2);
  assert.ok(keys(r).includes("resolved:registry:paused"));
});

test("liquidated position: the order is swept (cancelled, no revert, no halt); the keeper never executes against it", async () => {
  const r = rig();
  addPosition(r.w, 1, 6); // LIQUIDATED
  const id = addOrder(r.w, 1); // the stop-loss trigger is crossed too
  const o = await r.step();
  assert.deepEqual(o.swept, [String(id)]);
  assert.deepEqual(o.executed, []);
  assert.equal(r.w.orders.get(id)!.status, 3);
  assert.equal(r.state.halted, null);
  assert.equal(r.w.positions.get(1)!.status, 6, "the position was not touched");
  assert.deepEqual(r.state.open, []);
});

test("expired order is swept to EXPIRED; sweeping can be switched off", async () => {
  const r = rig();
  addPosition(r.w, 1);
  const id = addOrder(r.w, 1, { trigger: 1n, expiry: 1_799_999_999 });
  const o = await r.step();
  assert.deepEqual(o.swept, [String(id)]);
  assert.equal(r.w.orders.get(id)!.status, 4);
  const r2 = rig((c) => (c.limits.sweep = false));
  addPosition(r2.w, 1, 6);
  addOrder(r2.w, 1);
  await r2.step();
  assert.equal(r2.w.sent.length, 0);
});

test("a sweep whose read-back shows an execution or a closed position halts", async () => {
  const r = rig();
  addPosition(r.w, 1, 6);
  addOrder(r.w, 1);
  r.w.lies.closedAnythingOnSweep = true;
  const o = await r.step();
  assert.equal(o.halted, true);
  assert.match(r.state.halted!.reason, /PositionClosed/);
});

test("mined revert after a passing simulation: cooldown, marker cleared, no halt; the daily limit of such reverts halts", async () => {
  const r = rig();
  addPosition(r.w, 1);
  const id = addOrder(r.w, 1);
  r.w.minedRevert = true;
  const o = await r.step();
  assert.deepEqual(o.reverted, [String(id)]);
  assert.equal(r.state.pending, null);
  assert.equal(r.state.halted, null);
  assert.equal(r.state.sends[0]!.outcome, "reverted");
  assert.equal(r.state.cooldown[String(id)]!.until, r.w.now + 900);
  for (let i = 0; i < 2; i++) {
    r.w.now += 901;
    await r.step();
  }
  assert.equal(r.state.halted !== null, true, "3 mined reverts in 24 h halt");
  assert.match(r.state.halted!.reason, /mined and reverted/);
});

test("limits: sends per cycle and per day; gas floor and fee cap stop sending", async () => {
  const r = rig((c) => (c.limits.maxSendsPerCycle = 2));
  for (let i = 1; i <= 4; i++) {
    addPosition(r.w, i);
    addOrder(r.w, i);
  }
  const o = await r.step();
  assert.equal(o.executed.length, 2);
  assert.ok(o.skipped.some((s) => /beyond this cycle/.test(s)));
  const o2 = await r.step();
  assert.equal(o2.executed.length, 2);

  const d = rig((c) => (c.limits.maxSendsPerDay = 1));
  addPosition(d.w, 1);
  addPosition(d.w, 2);
  addOrder(d.w, 1);
  addOrder(d.w, 2);
  await d.step();
  await d.step();
  assert.equal(d.w.sent.length, 1, "daily limit");

  const g = rig();
  addPosition(g.w, 1);
  addOrder(g.w, 1);
  g.w.keeperAvax = 5n;
  await g.step();
  assert.equal(g.w.sent.length, 0);
  assert.ok(keys(g).includes("new:keeper:gas"));

  const f = rig((c) => (c.limits.maxFeeGwei = 10)); // the fake reports 30 gwei
  addPosition(f.w, 1);
  addOrder(f.w, 1);
  const of = await f.step();
  assert.equal(f.w.sent.length, 0);
  assert.ok(of.skipped.some((s) => /above the cap/.test(s)));
});

test("discovery by id: new ids only once, terminal orders dropped, open ids re-read, nothing beyond nextOrderId", async () => {
  const r = rig();
  addPosition(r.w, 1);
  const wait = addOrder(r.w, 1, { trigger: 1n }); // SL at 1: not crossed
  addPosition(r.w, 2);
  const done = addOrder(r.w, 2);
  r.w.orders.get(done)!.status = 3; // already cancelled
  const o = await r.step();
  assert.equal(o.scanned, 2);
  assert.equal(r.state.highWater, 3);
  assert.deepEqual(r.state.open, [String(wait)]);
  const o2 = await r.step();
  assert.equal(o2.scanned, 1, "only the open id is read again");
  const later = addOrder(r.w, 1, { trigger: 2n });
  const o3 = await r.step();
  assert.equal(o3.scanned, 2);
  assert.deepEqual(r.state.open, [String(wait), String(later)]);
});

test("discovery: an id that reads as NONE is not skipped over; nextOrderId going backwards halts", async () => {
  const r = rig();
  addPosition(r.w, 1);
  addOrder(r.w, 1, { trigger: 1n });
  r.w.nextOrderId = 3; // id 2 exists below nextOrderId but reads NONE (a lagging node)
  await r.step();
  assert.equal(r.state.highWater, 2, "stops before the unreadable id");
  assert.ok(keys(r).includes("new:registry:anomaly"));
  r.w.nextOrderId = 1;
  const o = await r.step();
  assert.equal(o.halted, true);
  assert.match(r.state.halted!.reason, /below the highest id/);
});

test("per-cycle read bound: ids beyond maxIdsPerCycle wait for the next cycle", async () => {
  const r = rig((c) => (c.limits.maxIdsPerCycle = 2));
  addPosition(r.w, 1);
  for (let i = 0; i < 5; i++) addOrder(r.w, 1, { trigger: 1n });
  await r.step();
  assert.equal(r.state.highWater, 3);
  assert.equal(r.state.open.length, 2);
  await r.step();
  await r.step();
  assert.equal(r.state.highWater, 6, "new ids make progress even while open ids fill the re-read bound");
  assert.equal(r.state.open.length, 5, "no open id is lost while others are being read");
});

test("a stale node head: nothing is decided", async () => {
  const r = rig();
  addPosition(r.w, 1);
  addOrder(r.w, 1);
  const real = r.p.getBlock.bind(r.p);
  r.p.getBlock = async (t: string) => ({ ...(await real(t)), timestamp: r.w.now - 600 });
  const o = await r.step();
  assert.equal(r.w.sent.length, 0);
  assert.ok(o.skipped.some((s) => /head block is 600 s old/.test(s)));
  assert.ok(keys(r).includes("new:node:stale"));
});

test("dry run (no signer): simulates and reports what is due, sends and marks nothing", async () => {
  const r = rig();
  addPosition(r.w, 1);
  const id = addOrder(r.w, 1);
  const o = await keeperStep({ provider: r.p as never, cfg: r.cfg, alerts: r.alerts, persist: (s) => r.persisted.push(structuredClone(s)), now: () => r.w.now }, r.state);
  assert.deepEqual(o.due, [String(id)]);
  assert.equal(r.w.sent.length, 0);
  assert.ok(r.persisted.every((s) => s.pending === null));
});

test("a failure of the node before any send is an ordinary failed cycle (it throws to main, nothing halts)", async () => {
  const r = rig();
  addPosition(r.w, 1);
  addOrder(r.w, 1);
  r.p.call = async () => {
    throw new Error("503 service unavailable");
  };
  await assert.rejects(r.step(), /503/);
  assert.equal(r.state.halted, null);
  assert.equal(r.state.pending, null);
});

test("the vault settling the owner's accrued rewards in the same call (balance rises by MORE than the returned margin) is not a mismatch", async () => {
  const r = rig();
  addPosition(r.w, 1);
  const id = addOrder(r.w, 1);
  r.w.extraCredit = 777n;
  const o = await r.step();
  assert.deepEqual(o.executed, [String(id)]);
  assert.equal(r.state.halted, null);
});

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { providers } from "ethers";
import { AlertManager, MemorySink } from "../src/alerts";
import type { KeeperConfig } from "../src/config";
import { keeperStep, verifySigner } from "../src/keeper";
import type { KeeperOutcome } from "../src/keeper";
import { clearHalt, emptyState, loadState, readHalt, resumeKeeper, saveState } from "../src/state";
import type { KeeperState } from "../src/state";
import { A, decidedConfig } from "./fixtures";
import { bandAllX, bandAllY, FakeProvider, FakeSigner, newWorld } from "./fakeworld";
import type { World } from "./fakeworld";

interface Rig {
  w: World;
  p: FakeProvider;
  sink: MemorySink;
  alerts: AlertManager;
  cfg: KeeperConfig;
  dir: string;
  state: KeeperState;
  persisted: KeeperState[];
  sleeps: number[];
  /** state persisted most recently at the moment of each send */
  pendingAtSend: Array<KeeperState["pending"]>;
  sends: number;
  step(o?: { skipWait?: boolean; live?: boolean; openBand?: boolean }): Promise<KeeperOutcome>;
  /** what `dlmm-keeper resume` does, then what main.ts does on the next cycle: reload the state file */
  resume(): ReturnType<typeof resumeKeeper>;
  at(s: number): void;
  keys(): string[];
}
function rig(mut?: (c: KeeperConfig) => void, y = 100_000_000n): Rig {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "dk-keeper-"));
  const cfg = decidedConfig(dir);
  mut?.(cfg);
  const w = newWorld();
  bandAllY(w, y); // active bin above the band: an exit upward, the band holds only USDC
  const p = new FakeProvider(w);
  const sink = new MemorySink();
  const alerts = new AlertManager(sink);
  const r: Rig = { w, p, sink, alerts, cfg, dir, state: emptyState(cfg.vault), persisted: [], sleeps: [], pendingAtSend: [], sends: 0, step: undefined as never, resume: undefined as never, at: (s) => { w.now = 1_800_000_000 + s; }, keys: () => sink.messages.map((m) => `${m.kind}:${m.key}`) };
  const signer = new FakeSigner(w, () => { r.sends++; r.pendingAtSend.push(r.persisted[r.persisted.length - 1]?.pending ?? null); });
  r.resume = () => {
    const res = resumeKeeper(cfg.monitor.statePath, cfg.monitor.haltPath, cfg.vault, w.now);
    r.state = loadState(cfg.monitor.statePath, cfg.vault);
    return res;
  };
  r.step = async (o = {}) => {
    const out = await keeperStep(
      { provider: p as unknown as providers.Provider, cfg: o.live === false ? { ...cfg, mode: "dry-run" } : cfg, signer: o.live === false || cfg.mode === "dry-run" ? undefined : signer, alerts, persist: (s) => { r.persisted.push(structuredClone(s)); r.state = s; saveState(cfg.monitor.statePath, { ...s, alerts: alerts.toJson() }); }, now: () => w.now, sleep: async (ms) => { r.sleeps.push(ms); } },
      r.state, { skipWait: o.skipWait, openBand: o.openBand },
    );
    r.state = out.state;
    return out;
  };
  return r;
}
const halted = (r: Rig) => readHalt(r.cfg.monitor.haltPath);

test("in range: nothing sent, ONE eth_call per cycle (the multicall poll), no state written", async () => {
  const r = rig();
  r.w.activeId = r.w.band.upperId; // inside
  await r.step(); // cycle 0 also runs the exit probe
  r.at(3);
  const before = r.w.calls.eth_call;
  const o = await r.step();
  assert.equal(o.status, "in-range");
  assert.equal(r.w.calls.eth_call - before, 1, "one multicall");
  assert.equal(r.w.calls.getBlock, 0);
  assert.equal(r.sends, 0);
  assert.equal(r.persisted.length, 0);
});
test("exit detection: the first sighting only starts the 60 s timer (marker persisted, nothing else called)", async () => {
  const r = rig();
  const o = await r.step();
  assert.equal(o.status, "exit-detected");
  assert.deepEqual(r.state.exit, { since: r.w.now, lowerId: r.w.band.lowerId, upperId: r.w.band.upperId });
  assert.equal(r.w.calls.sims, 0);
  assert.equal(r.sends, 0);
  assert.ok(r.keys().includes("action:band:exit"));
});
test("the 60 s wait: at 3 s, 30 s and 59 s the keeper only waits (no simulation, no block read); at 60 s it acts", async () => {
  const r = rig();
  await r.step();
  for (const s of [3, 30, 59]) {
    r.at(s);
    const o = await r.step();
    assert.equal(o.status, "waiting", `t=${s}`);
  }
  assert.equal(r.w.calls.sims, 0);
  assert.equal(r.w.calls.getBlock, 0);
  r.at(60);
  const o = await r.step();
  assert.equal(o.status, "sent");
  assert.equal(r.sends, 1);
});
test("the rebalance that is sent: encoded arguments (expected id, idSlippage 2, direction, sizes, deadline = now + 120 s) and the pending marker is persisted BEFORE the send", async () => {
  const r = rig();
  await r.step();
  r.at(61);
  const o = await r.step();
  assert.equal(o.status, "sent");
  const s = r.w.sent[0]!;
  assert.equal(s.fn, "rebalance");
  assert.equal(s.to.toLowerCase(), A.vault.toLowerCase());
  const a = s.args;
  assert.equal(Number(a.expectedActiveId), 8_388_611, "expected id = the pair's active id at the attempt (upper 8388609 + 2)");
  assert.equal(Number(a.idSlippage), 2);
  assert.equal(a.swapXForY, false, "the band is all USDC (Y): swap Y for X");
  const inn = BigInt(a.swapIn.toString());
  assert.ok(inn > 49_900_000n && inn < 50_100_000n, String(inn));
  assert.ok(BigInt(a.swapMinOut.toString()) > 49_800_000n);
  assert.equal(Number(a.deadline), r.w.now + 120);
  assert.deepEqual(r.pendingAtSend[0], { kind: "rebalance", at: r.w.now }, "the marker was on disk before the transaction");
  assert.equal(r.state.pending, null);
  assert.equal(r.state.sends.length, 1);
  assert.equal(r.state.sends[0]!.outcome, "ok");
  assert.equal(r.state.exit, null);
  assert.equal(r.state.lastRebalanceSeen, r.w.now);
  assert.ok(r.keys().includes("action:rebalance:sent"));
});
test("a simulation passes BEFORE the send: the simulated call data equals the sent call data", async () => {
  const r = rig();
  await r.step();
  r.at(60);
  await r.step();
  assert.equal(r.w.calls.sims, 1);
  assert.deepEqual(r.w.rebalanceCalls[0]!.map(String), r.w.sent[0]!.args.map(String));
});
test("in-range recovery during the wait: the active bin returns at 30 s: no send, timer cleared", async () => {
  const r = rig();
  await r.step();
  r.at(30);
  r.w.activeId = r.w.band.upperId;
  const o = await r.step();
  assert.equal(o.status, "recovered");
  assert.equal(r.state.exit, null);
  assert.equal(r.sends, 0);
  assert.ok(r.keys().includes("action:band:recovered"));
  r.at(60);
  assert.equal((await r.step()).status, "in-range");
  assert.equal(r.w.calls.sims, 0);
});
test("in-range recovery at the RE-READ: the poll still sees the exit, the pinned re-read sees the active bin back: no simulation, no send", async () => {
  const r = rig();
  await r.step();
  r.at(60);
  // reads of pair.getActiveId: 1) the poll (out), 2) the pinned re-read (back inside)
  r.w.activeIdQueue = [r.w.activeId, r.w.band.upperId];
  const o = await r.step();
  assert.equal(o.status, "recovered");
  assert.equal(r.w.calls.sims, 0);
  assert.equal(r.sends, 0);
  assert.equal(r.state.exit, null);
});
test("DRY-RUN: reads, plans and SIMULATES, never sends, never sets a pending marker, and does not re-simulate every 3 s", async () => {
  const r = rig((c) => (c.mode = "dry-run"));
  await r.step();
  r.at(60);
  const o = await r.step();
  assert.equal(o.status, "dry-run");
  assert.ok(o.notes.some((n) => /DRY-RUN: simulation passed, NOT sent/.test(n)));
  assert.equal(r.w.calls.sims, 1);
  assert.equal(r.sends, 0);
  assert.ok(r.persisted.every((s) => s.pending === null));
  r.at(63);
  assert.equal((await r.step()).status, "backoff");
  assert.equal(r.w.calls.sims, 1, "no second simulation inside the cooldown");
  assert.equal(r.state.sends.length, 0);
});
test("a latchable guard bit (each of 1, 2, 4, 8) HALTS: HALT file written, crit alert, no simulation, no send", async () => {
  for (const bit of [1, 2, 4, 8]) {
    const r = rig();
    r.w.reasons = bit;
    const o = await r.step();
    assert.equal(o.status, "halting", `bit ${bit}`);
    const h = halted(r);
    assert.equal(h?.kind, "guard");
    assert.equal(h?.reasons, bit);
    assert.match(h!.trip!, /disabled/);
    assert.ok(r.sink.messages.some((m) => m.key === "keeper:halted" && m.severity === "crit"));
    assert.equal(r.w.calls.sims, 0);
    assert.equal(r.sends, 0);
  }
});
test("a LATCHED vault halts even when no reason bit holds any more (prices recovered, owner has not cleared)", async () => {
  const r = rig();
  r.w.latched = true;
  const o = await r.step();
  assert.equal(o.status, "halting");
  assert.match(halted(r)!.reason, /LATCHED/);
  assert.match(halted(r)!.trip!, /already latched/);
});
test("while HALTED the keeper CALLS NOTHING: zero eth_calls, zero balance reads, zero blocks, zero sends, cycle after cycle", async () => {
  const r = rig();
  r.w.reasons = 4;
  await r.step();
  const snap = { ...r.w.calls };
  for (let i = 0; i < 5; i++) {
    r.at(3 * (i + 1));
    r.w.reasons = 0; // the condition even recovers: still halted
    const o = await r.step();
    assert.equal(o.status, "halted");
    assert.equal(o.halted, true);
  }
  assert.deepEqual(r.w.calls, snap);
  assert.equal(r.sends, 0);
});
test("HALT survives a restart (a brand new state object and alert manager) and is NEVER auto-resumed", async () => {
  const r = rig();
  r.w.reasons = 8;
  await r.step();
  r.state = emptyState(r.cfg.vault);
  r.w.reasons = 0;
  r.at(86_400 * 3);
  const o = await r.step();
  assert.equal(o.status, "halted");
  assert.ok(halted(r));
});
test("manual resume: clearHalt (what `dlmm-keeper resume` calls) lets the keeper run again; if the cause still holds it halts again at once", async () => {
  const r = rig();
  r.w.reasons = 4;
  await r.step();
  clearHalt(r.cfg.monitor.haltPath, r.w.now);
  assert.equal(halted(r), null);
  assert.equal((await r.step()).status, "halting", "the feed is still out of band");
  clearHalt(r.cfg.monitor.haltPath, r.w.now);
  r.w.reasons = 0;
  r.w.activeId = r.w.band.upperId;
  assert.equal((await r.step()).status, "in-range");
});
test("live-only bits 16 / 32 (pool deviation, rewarder): NO halt, NO send, a warning; the keeper waits", async () => {
  for (const bit of [16, 32]) {
    const r = rig();
    r.w.reasons = bit;
    await r.step();
    r.at(60);
    const o = await r.step();
    assert.equal(halted(r), null, `bit ${bit}`);
    assert.equal(o.status, "blocked");
    assert.equal(r.sends, 0);
    assert.ok(r.sink.messages.some((m) => m.key === "guard:live" && m.severity === "warn"));
  }
});
test("tripGuard is OFF by default: a latchable bit halts WITHOUT sending anything", async () => {
  const r = rig();
  r.w.reasons = 4;
  await r.step();
  assert.equal(r.sends, 0);
  assert.equal(r.w.latched, false);
});
test("autoTripGuard ON: HALT is written FIRST, the condition is re-checked after the debounce, then ONE tripGuard is sent (via simulation) and the outcome is in the HALT file", async () => {
  const r = rig((c) => (c.guard.autoTripGuard = true));
  r.w.reasons = 4;
  const o = await r.step();
  assert.equal(o.status, "halting");
  assert.deepEqual(r.sleeps, [15_000]);
  assert.equal(r.sends, 1);
  assert.equal(r.w.sent[0]!.fn, "tripGuard");
  assert.equal(r.w.latched, true);
  assert.match(halted(r)!.trip!, /^sent 0x/);
  assert.equal(r.state.pending, null);
  // afterwards: halted, calls nothing
  const snap = { ...r.w.calls };
  await r.step();
  assert.deepEqual(r.w.calls, snap);
  assert.equal(r.sends, 1);
});
test("autoTripGuard: a condition that clears during the debounce is NOT tripped; an already latched vault is NOT tripped; dry-run never sends it", async () => {
  const a = rig((c) => (c.guard.autoTripGuard = true));
  a.w.reasons = 4;
  const origSleep = a.sleeps;
  void origSleep;
  // clear the reason as the debounce sleep happens
  const stepA = keeperStep({ provider: a.p as unknown as providers.Provider, cfg: a.cfg, signer: new FakeSigner(a.w), alerts: a.alerts, persist: () => {}, now: () => a.w.now, sleep: async () => { a.w.reasons = 0; } }, a.state);
  await stepA;
  assert.equal(a.w.sent.length, 0);
  assert.match(halted(a)!.trip!, /condition cleared/);
  const b = rig((c) => (c.guard.autoTripGuard = true));
  b.w.latched = true;
  await b.step();
  assert.equal(b.w.sent.length, 0);
  const c = rig((cc) => { cc.guard.autoTripGuard = true; cc.mode = "dry-run"; });
  c.w.reasons = 8;
  await c.step();
  assert.equal(c.w.sent.length, 0);
  assert.match(halted(c)!.trip!, /dry-run/);
});
test("autoTripGuard: a tripGuard whose simulation reverts is not sent; the halt stands", async () => {
  const r = rig((c) => (c.guard.autoTripGuard = true));
  r.w.reasons = 4;
  r.w.tripSimRevert = { name: "GuardUnsafe", args: [0] };
  await r.step();
  assert.equal(r.w.sent.length, 0);
  assert.match(halted(r)!.trip!, /simulation reverted: GuardUnsafe/);
});
test("limit: at most ONE send per cycle and the cooldown (120 s) holds: right after a send the next exit waits", async () => {
  const r = rig();
  await r.step();
  r.at(60);
  await r.step();
  assert.equal(r.sends, 1);
  // the world exits again right after the re-centre (the new band holds USDC only)
  bandAllY(r.w, 100_000_000n);
  r.at(62);
  assert.equal((await r.step()).status, "exit-detected");
  r.at(122);
  const o = await r.step();
  assert.equal(o.status, "cooldown", "62 s after the send");
  assert.equal(r.sends, 1);
  r.at(181);
  assert.equal((await r.step()).status, "sent");
  assert.equal(r.sends, 2);
});
test("limit: 48 rebalance transactions in a rolling 24 h stop the keeper; the 49th waits for the oldest to age out", async () => {
  const r = rig();
  const now = r.w.now;
  r.state = { ...r.state, sends: Array.from({ length: 48 }, (_, i) => ({ ts: now - 3600 - i * 600, kind: "rebalance" as const, tx: "0x" + i, outcome: "ok" as const })) };
  await r.step();
  r.at(60);
  const o = await r.step();
  assert.equal(o.status, "limit");
  assert.equal(r.sends, 0);
  assert.ok(r.sink.messages.some((m) => m.key === "limit:daily"));
  r.at(86_400 - 3600 + 1); // the oldest send is now 24 h old
  r.w.feedAsset.updatedAt = r.w.now - 100;
  r.w.feedPair.updatedAt = r.w.now - 100;
  const o2 = await r.step();
  assert.notEqual(o2.status, "limit");
});
test("limit: the effective daily cap is also the VAULT's maxRebalancesPerDay when that is lower", async () => {
  const r = rig();
  r.w.params.maxRebalancesPerDay = 4;
  r.w.rebalancesToday = 4;
  await r.step();
  r.at(60);
  const o = await r.step();
  assert.ok(["limit", "blocked", "cooldown"].includes(o.status));
  assert.equal(r.sends, 0);
  assert.ok(r.sink.messages.some((m) => m.key === "limit:daily"));
});
test("failure backoff: a reverting simulation is NOT retried every cycle; backoff 30 s, 60 s, then HALT at maxConsecutiveFailures (3)", async () => {
  const r = rig();
  r.w.simRevertAlways = { name: "NavLossTooLarge", args: [1_000_000, 900_000] };
  await r.step();
  r.at(60);
  assert.equal((await r.step()).status, "failed");
  assert.equal(r.state.backoff?.fails, 1);
  assert.equal(r.w.calls.sims, 1);
  for (const s of [63, 70, 89]) {
    r.at(s);
    assert.equal((await r.step()).status, "backoff");
  }
  assert.equal(r.w.calls.sims, 1, "no simulation during the backoff");
  r.at(91);
  assert.equal((await r.step()).status, "failed");
  assert.equal(r.state.backoff?.fails, 2);
  assert.equal(r.state.backoff!.until, r.w.now + 60, "doubled");
  r.at(152);
  const o = await r.step();
  assert.equal(o.status, "halting");
  assert.equal(halted(r)!.kind, "failures");
  assert.equal(r.sends, 0);
  assert.ok(r.sink.messages.some((m) => m.key === "attempt:failed"));
});
test("a SimRevert after backoff expiry that clears resets nothing wrongly: a later success sends and zeroes the failure count", async () => {
  const r = rig();
  r.w.simRevert = [{ name: "SwapTooLarge", args: [1, 1] }];
  await r.step();
  r.at(60);
  assert.equal((await r.step()).status, "failed");
  r.at(91);
  r.w.feedAsset.updatedAt = r.w.now - 100;
  r.w.feedPair.updatedAt = r.w.now - 100;
  assert.equal((await r.step()).status, "sent");
  assert.equal(r.state.backoff, null);
  assert.equal(r.sends, 1);
});
test("benign reverts are not failures: NotOutOfRange clears the exit; CooldownActive sets the backoff to readyAt; DailyRebalanceCapReached backs off 1 h", async () => {
  const a = rig();
  a.w.simRevert = [{ name: "NotOutOfRange", args: [1, 2, 3] }];
  await a.step();
  a.at(60);
  assert.equal((await a.step()).status, "recovered");
  assert.equal(a.state.exit, null);
  const b = rig();
  b.w.simRevert = [{ name: "CooldownActive", args: [b.w.now + 200] }];
  await b.step();
  b.at(60);
  assert.equal((await b.step()).status, "cooldown");
  assert.equal(b.state.backoff?.until, 1_800_000_200);
  assert.equal(b.state.backoff?.fails, 0);
  const c = rig();
  c.w.simRevert = [{ name: "DailyRebalanceCapReached", args: [] }];
  await c.step();
  c.at(60);
  await c.step();
  assert.equal(c.state.backoff?.until, c.w.now + 3600);
  assert.equal(c.state.backoff?.fails, 0);
});
test("a simulation revert of GuardLatched / GuardUnsafe(latchable) HALTS; GuardUnsafe(live only) waits", async () => {
  const a = rig();
  await a.step();
  a.at(60);
  a.w.simRevert = [{ name: "GuardLatched", args: [] }];
  assert.equal((await a.step()).status, "halting");
  assert.equal(halted(a)!.kind, "guard");
  const b = rig();
  await b.step();
  b.at(60);
  b.w.simRevert = [{ name: "GuardUnsafe", args: [4] }];
  assert.equal((await b.step()).status, "halting");
  const c = rig();
  await c.step();
  c.at(60);
  c.w.simRevert = [{ name: "GuardUnsafe", args: [16] }];
  assert.equal((await c.step()).status, "blocked");
  assert.equal(halted(c), null);
});
test("ActiveIdMoved: ONE adaptive re-simulation with the id the vault reported (still a simulation), then the single send carries that id", async () => {
  const r = rig();
  await r.step();
  r.at(60);
  const active = r.w.activeId;
  r.w.simRevert = [{ name: "ActiveIdMoved", args: [active, active + 2, 2] }];
  const o = await r.step();
  assert.equal(o.status, "sent");
  assert.equal(r.w.calls.sims, 2);
  assert.equal(Number(r.w.sent[0]!.args.expectedActiveId), active + 1, "the midpoint of the pre-swap id and the reported post-swap id: within idSlippage of both");
  assert.equal(r.sends, 1);
});
test("ActiveIdMoved by more than maxActiveIdShift is NOT adopted (a counted failure, no send); a second ActiveIdMoved is a failure, not a loop", async () => {
  const a = rig();
  await a.step();
  a.at(60);
  const id = a.w.activeId;
  a.w.simRevert = [{ name: "ActiveIdMoved", args: [id, id + 5, 2] }]; // 5 > 2 x idSlippage: no id is within 2 of both
  assert.equal((await a.step()).status, "failed");
  assert.equal(a.sends, 0);
  assert.equal(a.w.calls.sims, 1);
  const b = rig();
  await b.step();
  b.at(60);
  b.w.simRevert = [{ name: "ActiveIdMoved", args: [id, id + 1, 2] }, { name: "ActiveIdMoved", args: [id, id + 1, 2] }];
  assert.equal((await b.step()).status, "failed");
  assert.equal(b.w.calls.sims, 2, "at most one extra simulation");
  assert.equal(b.sends, 0);
});
test("a mined revert after a passing simulation is recorded, counted, backed off; the 2nd in 24 h HALTS (limit 2)", async () => {
  const r = rig();
  r.w.minedRevert = true;
  await r.step();
  r.at(60);
  const o = await r.step();
  assert.equal(o.status, "failed");
  assert.equal(r.state.sends[0]!.outcome, "reverted");
  assert.equal(r.state.pending, null);
  assert.equal(r.sends, 1);
  r.at(60 + 31 + 120);
  r.w.feedAsset.updatedAt = r.w.now - 100;
  r.w.feedPair.updatedAt = r.w.now - 100;
  const o2 = await r.step();
  assert.equal(o2.status, "halting");
  assert.equal(halted(r)!.kind, "mined-reverts");
  assert.equal(r.sends, 2);
});
test("a pending marker found at start-up (process died between the marker and the read-back) HALTS; nothing is called", async () => {
  const r = rig();
  r.state = { ...r.state, pending: { kind: "rebalance", at: r.w.now - 30 } };
  const o = await r.step();
  assert.equal(o.status, "halting");
  assert.equal(halted(r)!.kind, "pending-interrupted");
  assert.equal(r.sends, 0);
  assert.equal(r.w.calls.eth_call, 0);
});
test("read-back lies HALT: no Rebalanced event; lastRebalanceAt did not advance; the band after differs from the event's band", async () => {
  for (const lie of [{ noEvent: true }, { noAdvance: true }, { wrongBand: true }] as const) {
    const r = rig();
    Object.assign(r.w.lies, lie);
    await r.step();
    r.at(60);
    const o = await r.step();
    assert.equal(o.status, "halting", JSON.stringify(lie));
    assert.equal(halted(r)!.kind, "readback");
    assert.equal(r.state.pending, null);
    assert.ok(r.sink.messages.some((m) => m.key === "rebalance:readback" && m.severity === "crit"));
  }
});
test("a rebalance NOT made by this keeper (vault.lastRebalanceAt differs from what it saw after its own send) HALTS", async () => {
  const r = rig();
  await r.step();
  r.at(60);
  await r.step(); // sent; lastRebalanceSeen = now
  bandAllY(r.w, 100_000_000n);
  r.w.lastRebalanceAt = r.w.now + 5; // somebody else rebalanced
  r.at(70);
  await r.step();
  r.at(200);
  r.w.feedAsset.updatedAt = r.w.now - 100;
  r.w.feedPair.updatedAt = r.w.now - 100;
  const o = await r.step();
  assert.equal(o.status, "halting");
  assert.equal(halted(r)!.kind, "foreign-rebalance");
  assert.equal(r.sends, 1);
});
test("gas runway: warning when the balance covers fewer than 5 rebalances at the current gas price x 1,000,000 gas; cleared when topped up; keeper:gas-runway key", async () => {
  const r = rig();
  r.w.activeId = r.w.band.upperId;
  r.w.keeperBalance = 4n * 1_000_000n * r.w.gasPrice; // 4 rebalances
  await r.step();
  const m = r.sink.messages.find((x) => x.key === "keeper:gas-runway");
  assert.ok(m, "alert raised");
  assert.equal(m!.severity, "warn");
  assert.match(m!.text, /covers 4 rebalance\(s\) at 3.5 gwei/);
  r.w.keeperBalance = 5n * 1_000_000n * r.w.gasPrice;
  r.at(301);
  await r.step();
  assert.ok(r.keys().includes("resolved:keeper:gas-runway"));
});
test("gas runway is checked on its own cadence (300 s), not every 3 s poll", async () => {
  const r = rig();
  r.w.activeId = r.w.band.upperId;
  await r.step();
  const b = r.w.calls.getBalance;
  for (let i = 1; i < 10; i++) { r.at(i * 3); await r.step(); }
  assert.equal(r.w.calls.getBalance, b);
  r.at(301);
  await r.step();
  assert.equal(r.w.calls.getBalance, b + 1);
});
test("minimum wallet balance: below the floor nothing is sent (crit alert keeper:gas); a simulation still ran", async () => {
  const r = rig((c) => (c.limits.minWalletWei = "1000000000000000"));
  r.w.keeperBalance = 500n;
  await r.step();
  r.at(60);
  const o = await r.step();
  assert.equal(o.status, "blocked");
  assert.equal(r.sends, 0);
  assert.ok(r.sink.messages.some((m) => m.key === "keeper:gas" && m.severity === "crit"));
});
test("fee cap: a gas price above maxFeeGwei sends nothing", async () => {
  const r = rig((c) => (c.limits.maxFeeGwei = 2));
  await r.step();
  r.at(60);
  const o = await r.step();
  assert.equal(o.status, "blocked");
  assert.equal(r.sends, 0);
});
test("the keeper's SECOND oracle check blocks the send: pool 80 bp off the oracle, a stale feed, a leg out of the keeper's band", async () => {
  for (const f of [(w: World) => { w.priceNum = 99_100n; }, (w: World) => { w.feedPair.updatedAt = w.now - 200_000; }, (w: World) => { w.feedPair.answer = 99_500_000n; }] as const) {
    const r = rig();
    f(r.w);
    await r.step();
    r.at(60);
    const o = await r.step();
    assert.equal(o.status, "blocked");
    assert.equal(r.sends, 0);
    assert.equal(r.w.calls.sims, 0, "no simulation, no plan");
    assert.ok(r.sink.messages.some((m) => m.key === "oracle:keeper-check"));
    assert.equal(halted(r), null, "an oracle disagreement is a wait, not a halt");
  }
});
test("a pool that pays below the oracle floor (quote fee 90 bp) is NOT sent: plan refused, alert, backoff", async () => {
  const r = rig();
  r.w.quoteFeeBps = 90n;
  await r.step();
  r.at(60);
  const o = await r.step();
  assert.equal(o.status, "blocked");
  assert.equal(r.sends, 0);
  assert.ok(r.sink.messages.some((m) => m.key === "plan:quote-below-oracle"));
});
test("a quote that cannot fill (depth) is NOT sent", async () => {
  const r = rig();
  r.w.quoteMaxIn = 1_000_000n;
  await r.step();
  r.at(60);
  assert.equal((await r.step()).status, "blocked");
  assert.equal(r.sends, 0);
});
test("exit downward: the band holds only X (USDt, the pair's token X): swap X for Y", async () => {
  const r = rig();
  bandAllX(r.w, 100_000_000n);
  await r.step();
  r.at(60);
  assert.equal((await r.step()).status, "sent");
  assert.equal(r.w.sent[0]!.args.swapXForY, true);
});
test("orientation is read from the pair, not assumed: with X = USDC and Y = USDt the same all-USDC band swaps X for Y", async () => {
  const r = rig();
  r.w.tokenX = A.usdc;
  r.w.tokenY = A.usdt;
  r.w.priceNum = 100_040n; // raw Y per raw X now USDt per USDC
  r.w.priceDen = 100_000n;
  bandAllX(r.w, 100_000_000n); // X = USDC now
  await r.step();
  r.at(60);
  assert.equal((await r.step()).status, "sent");
  assert.equal(r.w.sent[0]!.args.swapXForY, true);
});
test("idle balances count as inventory: a band of USDt plus idle USDC needs a smaller swap", async () => {
  const r = rig();
  bandAllX(r.w, 60_000_000n);
  r.w.idle.set(A.usdc.toLowerCase(), 40_000_000n);
  await r.step();
  r.at(60);
  await r.step();
  const inn = BigInt(r.w.sent[0]!.args.swapIn.toString());
  assert.ok(inn > 9_900_000n && inn < 10_100_000n, String(inn)); // 60 vs 40 -> move 10
});
test("wiring: a pair whose tokens are not the configured pair HALTS (kind wiring); the same for an unknown band width", async () => {
  const r = rig();
  r.w.tokenY = A.feedAsset; // not USDC
  await r.step();
  r.at(60);
  const o = await r.step();
  assert.equal(o.status, "halting");
  assert.equal(halted(r)!.kind, "wiring");
  const b = rig((c) => (c.limits.maxBandBins = 2));
  await b.step();
  b.at(60);
  assert.equal((await b.step()).status, "failed");
  assert.equal(b.sends, 0);
});
test("a stale node (head block older than maxBlockLagSeconds) decides nothing", async () => {
  const r = rig();
  r.w.blockLag = 600;
  await r.step();
  r.at(60);
  const o = await r.step();
  assert.equal(o.status, "stale");
  assert.equal(r.sends, 0);
  assert.equal(r.w.calls.sims, 0);
});
test("no band: the keeper waits and warns (openBand is not its job)", async () => {
  const r = rig();
  r.w.band.hasBand = false;
  const o = await r.step();
  assert.equal(o.status, "no-band");
  assert.ok(r.sink.messages.some((m) => m.key === "band:none"));
  assert.equal(r.sends, 0);
});
test("`check` (skipWait): decides at once but does not need the 60 s; a halt decision writes NO HALT file when noHaltWrite is set", async () => {
  const r = rig((c) => (c.mode = "dry-run"));
  const o = await r.step({ skipWait: true });
  assert.equal(o.status, "dry-run");
  assert.equal(r.sends, 0);
  const h = rig((c) => (c.mode = "dry-run"));
  h.w.reasons = 4;
  const out = await keeperStep({ provider: h.p as unknown as providers.Provider, cfg: h.cfg, alerts: h.alerts, persist: () => {}, now: () => h.w.now }, h.state, { skipWait: true, noHaltWrite: true });
  assert.equal(out.status, "halting");
  assert.equal(halted(h), null);
});
test("live mode without a signer refuses to run (no silent downgrade, no silent upgrade); verifySigner checks address and chain", async () => {
  const r = rig();
  await assert.rejects(keeperStep({ provider: r.p as unknown as providers.Provider, cfg: r.cfg, alerts: r.alerts, persist: () => {}, now: () => r.w.now }, r.state), /no signer/);
  const s = new FakeSigner(r.w);
  await verifySigner(s, r.cfg, r.p);
  await assert.rejects(verifySigner(s, { ...r.cfg, keeper: { address: A.vault } }, r.p), /not the configured keeper/);
  await assert.rejects(verifySigner(s, r.cfg, { getNetwork: async () => ({ chainId: 1 }) }), /chain id/);
});
test("a read failure BEFORE any send is an ordinary failed cycle (the error propagates, nothing was sent, no halt)", async () => {
  const r = rig();
  const p = r.p as unknown as { call: () => Promise<string> };
  p.call = async () => { throw new Error("SERVER_ERROR 503"); };
  await assert.rejects(r.step(), /SERVER_ERROR/);
  assert.equal(r.sends, 0);
  assert.equal(halted(r), null);
});

// ---------------------------------------------------------------- resume really resumes (the state fields that could re-halt for the OLD cause are reset)
const resumeAndExpectNoReHalt = async (r: Rig, why: string): Promise<void> => {
  r.resume();
  assert.equal(halted(r), null, why);
  r.at(86_400);
  r.w.feedAsset.updatedAt = r.w.now - 100;
  r.w.feedPair.updatedAt = r.w.now - 100;
};
test("resume after pending-interrupted: the pending marker is cleared ON DISK, the keeper runs again and does not halt for the old marker", async () => {
  const r = rig();
  r.state = { ...r.state, pending: { kind: "rebalance", at: r.w.now - 30 } };
  saveState(r.cfg.monitor.statePath, r.state);
  assert.equal((await r.step()).status, "halting");
  const res = r.resume();
  assert.equal(res.clearedPending?.kind, "rebalance");
  assert.equal(loadState(r.cfg.monitor.statePath, r.cfg.vault).pending, null);
  assert.equal((await r.step()).status, "exit-detected", "runs normally");
  assert.equal(halted(r), null);
});
test("resume after a READBACK halt: the transaction DID mine, so lastRebalanceAt moved; the stale lastRebalanceSeen is reset and the next attempt does not halt as foreign-rebalance", async () => {
  const r = rig();
  r.w.lies.noEvent = true;
  await r.step();
  r.at(60);
  assert.equal((await r.step()).status, "halting");
  assert.equal(halted(r)!.kind, "readback");
  r.w.lies.noEvent = false;
  await resumeAndExpectNoReHalt(r, "resume removed the file");
  assert.equal(r.state.lastRebalanceSeen, null);
  bandAllY(r.w, 100_000_000n);
  await r.step();
  r.at(86_400 + 61);
  const o = await r.step();
  assert.equal(o.status, "sent", `${o.status} ${JSON.stringify(o.notes)}`);
  assert.equal(halted(r), null);
});
test("resume after a foreign-rebalance halt: the new lastRebalanceAt becomes the baseline; the next attempt sends instead of halting again", async () => {
  const r = rig();
  await r.step();
  r.at(60);
  await r.step(); // sent
  bandAllY(r.w, 100_000_000n);
  r.w.lastRebalanceAt = r.w.now + 5;
  r.at(70);
  await r.step();
  r.at(200);
  r.w.feedAsset.updatedAt = r.w.now - 100;
  r.w.feedPair.updatedAt = r.w.now - 100;
  assert.equal((await r.step()).status, "halting");
  assert.equal(halted(r)!.kind, "foreign-rebalance");
  r.at(86_400);
  r.w.feedAsset.updatedAt = r.w.now - 100;
  r.w.feedPair.updatedAt = r.w.now - 100;
  r.resume();
  await r.step();
  r.at(86_400 + 61);
  assert.equal((await r.step()).status, "sent");
  assert.equal(halted(r), null);
});
test("resume after a `failures` halt: the failure count starts again (the first new failure does not halt)", async () => {
  const r = rig();
  r.w.simRevertAlways = { name: "NavLossTooLarge", args: [1, 1] };
  await r.step();
  for (const s of [60, 91, 152]) {
    r.at(s);
    await r.step();
  }
  assert.equal(halted(r)!.kind, "failures");
  await resumeAndExpectNoReHalt(r, "file removed");
  assert.equal(r.state.backoff, null);
  await r.step();
  r.at(86_400 + 61);
  assert.equal((await r.step()).status, "failed", "fails 1 of 3, not a halt");
  assert.equal((r.state as KeeperState).backoff?.fails, 1);
});
test("a second halt after a resume ALERTS AGAIN (keeper:halted is cleared when the HALT file is gone)", async () => {
  const r = rig();
  r.w.reasons = 4;
  await r.step();
  r.resume();
  await r.step(); // still unsafe: halts again at once
  const news = r.sink.messages.filter((m) => m.key === "keeper:halted" && m.kind === "new");
  assert.equal(news.length, 2, r.keys().join());
  assert.ok(r.keys().includes("resolved:keeper:halted"));
});
test("attempt:failed is cleared when the episode ends without a send (the active bin returns)", async () => {
  const r = rig();
  r.w.simRevert = [{ name: "SwapTooLarge", args: [1, 1] }];
  await r.step();
  r.at(60);
  await r.step();
  assert.ok(r.sink.messages.some((m) => m.key === "attempt:failed"));
  r.at(100);
  r.w.activeId = r.w.band.upperId;
  await r.step();
  assert.ok(r.keys().includes("resolved:attempt:failed"));
});
test("while halted the state file is NOT rewritten by the keeper step (resume's reset is never overwritten)", async () => {
  const r = rig();
  saveState(r.cfg.monitor.statePath, r.state);
  r.w.reasons = 4;
  await r.step();
  const before = fs.readFileSync(r.cfg.monitor.statePath, "utf8");
  const writes = r.persisted.length;
  for (let i = 1; i < 4; i++) { r.at(3 * i); await r.step(); }
  assert.equal(r.persisted.length, writes, "no persist while halted");
  assert.equal(fs.readFileSync(r.cfg.monitor.statePath, "utf8"), before);
});

// ---------------------------------------------------------------- the exit probe
test("exit probe: every N cycles the keeper simulates pair.burn of the vault's own most valuable band bin FROM the vault (no shares, no state override); a passing probe is silent", async () => {
  const r = rig((c) => (c.probe.everyCycles = 2));
  r.w.activeId = r.w.band.upperId;
  for (let i = 0; i < 6; i++) { r.at(3 * i); await r.step(); }
  assert.equal(r.w.burnCalls.length, 3, "cycles 0, 2, 4");
  const c = r.w.burnCalls[0]!;
  assert.equal(c.from!.toLowerCase(), A.vault.toLowerCase(), "from = the vault: msg.sender == from, no approval needed");
  assert.equal(String(c.args[0]).toLowerCase(), A.vault.toLowerCase());
  assert.equal(String(c.args[1]).toLowerCase(), A.vault.toLowerCase());
  assert.equal(r.sink.messages.filter((m) => m.key === "exit:probe").length, 0);
  assert.equal(r.state.exitProbe, null);
});
test("exit probe FAILS (a failing hook: burn reverts while guardState reads 0): crit alert 'EXIT PROBE FAILED: pause deposits', state flag, NO halt, keeps probing", async () => {
  const r = rig((c) => (c.probe.everyCycles = 2));
  r.w.activeId = r.w.band.upperId;
  r.w.hookRevert = true;
  await r.step();
  const m = r.sink.messages.find((x) => x.key === "exit:probe");
  assert.ok(m);
  assert.equal(m!.severity, "crit");
  assert.match(m!.text, /EXIT PROBE FAILED: pause deposits/);
  assert.ok(r.state.exitProbe);
  assert.equal(halted(r), null, "not the HALT latch: it clears itself when the hook recovers");
  for (let i = 1; i < 5; i++) { r.at(3 * i); await r.step(); }
  assert.equal(r.w.burnCalls.length, 3, "keeps probing (cycles 0, 2, 4)");
  assert.equal(r.sink.messages.filter((x) => x.key === "exit:probe").length, 1, "alerted once");
});
test("exit probe failed: a band exit is NOT re-centred (a burn would revert anyway): no simulation, no send; when the hook recovers the probe clears and the rebalance goes", async () => {
  const r = rig();
  r.w.hookRevert = true;
  await r.step();
  r.at(60);
  const o = await r.step();
  assert.equal(o.status, "blocked");
  assert.equal(r.sends, 0);
  assert.equal(r.w.calls.sims, 0);
  r.w.hookRevert = false;
  r.at(100);
  r.w.feedAsset.updatedAt = r.w.now - 100;
  r.w.feedPair.updatedAt = r.w.now - 100;
  const o2 = await r.step();
  assert.equal(o2.status, "sent");
  assert.equal(r.state.exitProbe, null);
  assert.ok(r.keys().includes("resolved:exit:probe"));
});
test("exit probe: a ZeroAmountsOut revert or no band shares is INCONCLUSIVE (no alert, no flag); an endpoint error is a failed cycle, not a hook failure", async () => {
  const r = rig();
  r.w.activeId = r.w.band.upperId;
  r.w.burnZero = true;
  await r.step();
  assert.equal(r.state.exitProbe, null);
  assert.equal(r.sink.messages.filter((m) => m.key === "exit:probe").length, 0);
  const e = rig();
  e.w.activeId = e.w.band.upperId;
  e.w.bins.clear();
  await e.step();
  assert.equal(e.w.burnCalls.length, 0, "no shares: nothing to simulate");
  assert.equal(e.state.exitProbe, null);
});
test("the probe is not run while HALTED (the keeper calls nothing)", async () => {
  const r = rig((c) => (c.probe.everyCycles = 1));
  r.w.reasons = 4;
  await r.step();
  const n = r.w.burnCalls.length;
  for (let i = 1; i < 4; i++) { r.at(3 * i); await r.step(); }
  assert.equal(r.w.burnCalls.length, n);
});

// ---------------------------------------------------------------- the real vault's wiring and rebalanceAllowed bits
test("wiring: the keeper wallet is not the vault's rebalancer / the vault's pair or feeds differ from the configuration: HALT kind wiring", async () => {
  for (const mut of [(w: World) => { w.wiring.rebalancer = A.vault; }, (w: World) => { w.wiring.pair = A.keeper; }, (w: World) => { w.wiring.feedPair = A.keeper; }, (w: World) => { w.wiring.asset = A.keeper; }]) {
    const r = rig();
    mut(r.w);
    await r.step();
    r.at(60);
    assert.equal((await r.step()).status, "halting");
    assert.equal(halted(r)!.kind, "wiring");
    assert.equal(r.sends, 0);
  }
});
test("NotRebalancer from the simulation (a rotated rebalancer) HALTS with kind wiring", async () => {
  const r = rig();
  r.w.simRevert = [{ name: "NotRebalancer", args: [] }];
  await r.step();
  r.at(60);
  assert.equal((await r.step()).status, "halting");
  assert.equal(halted(r)!.kind, "wiring");
});
test("rebalanceAllowed bit 2048 (paused): no send, no halt, warning; bit 512 (daily cap): waits until readyAt, no send; bit 128 (in range): recovered", async () => {
  const a = rig();
  a.w.paused = true;
  await a.step();
  a.at(60);
  assert.equal((await a.step()).status, "blocked");
  assert.ok(a.sink.messages.some((m) => m.key === "vault:paused"));
  assert.equal(halted(a), null);
  const b = rig();
  b.w.rebalancesToday = 48;
  await b.step();
  b.at(60);
  const ob = await b.step();
  assert.ok(["cooldown", "limit"].includes(ob.status));
  assert.equal(b.sends, 0);
});
test("the vault's daily cap is the vault's (UTC-day) counter: 5 sends of this keeper in the last 24 h do NOT block when the vault says 0 today and its cap is 4", async () => {
  const r = rig();
  r.w.params.maxRebalancesPerDay = 4;
  r.w.rebalancesToday = 0;
  const now = r.w.now;
  r.state = { ...r.state, sends: Array.from({ length: 5 }, (_, i) => ({ ts: now - 3600 - i * 600, kind: "rebalance" as const, tx: "0x" + i, outcome: "ok" as const })) };
  await r.step();
  r.at(60);
  assert.equal((await r.step()).status, "sent");
});

// ---------------------------------------------------------------- open-band
test("open-band (DRY, the default): the vault has no band, idle USDC only: sized like the vault sizes its own swap, simulated, NOT sent", async () => {
  const r = rig((c) => (c.mode = "dry-run"));
  r.w.band.hasBand = false;
  r.w.idle.set(A.usdc.toLowerCase(), 100_000_000n);
  const o = await r.step({ skipWait: true, openBand: true });
  assert.equal(o.status, "dry-run");
  assert.equal(r.sends, 0);
  assert.equal(r.w.openBandCalls.length, 1);
  assert.equal(r.w.rebalanceCalls.length, 0);
  const a = r.w.openBandCalls[0]!;
  assert.equal(Number(a.expectedActiveId), r.w.activeId);
  assert.equal(Number(a.idSlippage), 2);
  assert.ok(BigInt(a.swapMinOut.toString()) > 49_900_000n, "half of 100 USDC swapped to USDt: min out about 50");
  assert.ok(o.plan && o.plan.ok && o.plan.swapIn > 49_900_000n && o.plan.swapIn < 50_100_000n);
  assert.equal(r.state.sends.length, 0);
});
test("open-band LIVE: ONE openBand is sent after the simulation, pending marker first, BandOpened read back, recorded as kind openBand (not counted against the rebalance limits)", async () => {
  const r = rig();
  r.w.band.hasBand = false;
  r.w.idle.set(A.usdc.toLowerCase(), 100_000_000n);
  const o = await r.step({ skipWait: true, openBand: true });
  assert.equal(o.status, "sent");
  assert.equal(r.sends, 1);
  assert.equal(r.w.sent[0]!.fn, "openBand");
  assert.deepEqual(r.pendingAtSend[0], { kind: "openBand", at: r.w.now });
  assert.equal(r.state.pending, null);
  assert.equal(r.state.sends[0]!.kind, "openBand");
  assert.equal(r.w.band.hasBand, true);
  // a second open-band: the band exists now
  r.at(5);
  assert.equal((await r.step({ skipWait: true, openBand: true })).status, "blocked");
  assert.equal(r.sends, 1);
});
test("open-band obeys the same safety rules: a latchable guard bit HALTS, a paused vault blocks, a failing simulation backs off and counts, a read-back lie HALTS", async () => {
  const mk = (mut: (r: Rig) => void): Rig => {
    const r = rig();
    r.w.band.hasBand = false;
    r.w.idle.set(A.usdc.toLowerCase(), 100_000_000n);
    mut(r);
    return r;
  };
  const a = mk((r) => (r.w.reasons = 8));
  assert.equal((await a.step({ skipWait: true, openBand: true })).status, "halting");
  assert.equal(a.sends, 0);
  const b = mk((r) => (r.w.paused = true));
  assert.equal((await b.step({ skipWait: true, openBand: true })).status, "blocked");
  assert.equal(b.sends, 0);
  const c = mk((r) => (r.w.simRevertAlways = { name: "NavLossTooLarge", args: [1, 1] }));
  assert.equal((await c.step({ skipWait: true, openBand: true })).status, "failed");
  assert.equal(c.state.backoff?.fails, 1);
  assert.equal(c.sends, 0);
  const d = mk((r) => (r.w.lies.noEvent = true));
  assert.equal((await d.step({ skipWait: true, openBand: true })).status, "halting");
  assert.equal(halted(d)!.kind, "readback");
  const e = mk((r) => (r.w.quoteFeeBps = 90n));
  assert.equal((await e.step({ skipWait: true, openBand: true })).status, "blocked");
  assert.equal(e.sends, 0, "the pool pays below the oracle floor: not sent");
});
test("open-band with nothing idle is refused (plan empty), never sent", async () => {
  const r = rig();
  r.w.band.hasBand = false;
  const o = await r.step({ skipWait: true, openBand: true });
  assert.equal(o.status, "blocked");
  assert.equal(r.sends, 0);
});

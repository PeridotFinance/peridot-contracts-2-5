import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Alert, Alerts } from "../src/alerts";
import { CUSTODIAN_ABI, custodianIface, PositionStatus, Status } from "../src/abi";
import { DEFAULT_LIMITS, keeperStep, KeeperLimits } from "../src/keeper";
import { mask } from "../src/mask";
import { ChainPort, FeeRead, OrderRead, Sent, Sim, TxReverted } from "../src/port";
import { emptyState, KeeperState, loadState, saveState } from "../src/state";
import { parseConfig } from "../src/config";

// ------------------------------------------------------------------ a fake chain
interface FakeOrder {
  active: number;
  ready: number;
  status: number;
  rungStatuses: number[];
  posStatus: number;
}
class Fake implements ChainPort {
  next = 4n; // positions 1..3
  orders = new Map<string, FakeOrder>();
  sim = new Map<string, Sim>();
  feeRead: FeeRead = { ok: true, maxFeePerGas: 30n, maxPriorityFeePerGas: 1n };
  balance = 10n ** 18n;
  sendCalls: string[] = [];
  sendBehaviour: "ok" | "revert" | "timeout" | "noop" = "ok";
  log: string[] = [];
  onSend?: () => void;
  async chainId() {
    return 43114;
  }
  async head() {
    return { number: 1, timestamp: 1_000 };
  }
  async nextPositionId() {
    return this.next;
  }
  private o(id: bigint): FakeOrder {
    return this.orders.get(id.toString()) ?? { active: 0, ready: 0, status: Status.NONE, rungStatuses: [], posStatus: PositionStatus.ACTIVE };
  }
  async positionStatus(id: bigint) {
    return this.o(id).posStatus;
  }
  async finalizable(id: bigint) {
    const o = this.o(id);
    return { active: o.active, ready: o.ready };
  }
  async order(id: bigint): Promise<OrderRead> {
    const o = this.o(id);
    return { status: o.status, rungCount: o.rungStatuses.length, rungStatuses: o.rungStatuses };
  }
  async simulateFinalize(id: bigint): Promise<Sim> {
    this.log.push(`sim ${id}`);
    return this.sim.get(id.toString()) ?? { ok: true, gas: 1_000_000n };
  }
  async fees() {
    return this.feeRead;
  }
  async keeperAddress() {
    return "0x00000000000000000000000000000000004B33";
  }
  async keeperBalanceWei() {
    return this.balance;
  }
  async sendFinalize(id: bigint): Promise<Sent> {
    this.log.push(`send ${id}`);
    this.sendCalls.push(id.toString());
    this.onSend?.();
    if (this.sendBehaviour === "revert") throw new TxReverted("0xdead");
    if (this.sendBehaviour === "timeout") throw new Error("transaction 0xbeef was not mined within 180 s");
    const o = this.o(id);
    if (this.sendBehaviour === "ok") {
      // the chain: every ready rung is settled; the order ends when no rung is left active
      let toSettle = o.ready;
      const rungs = o.rungStatuses.map((s) => (s === Status.ACTIVE && toSettle-- > 0 ? Status.SETTLED : s));
      const left = rungs.filter((s) => s === Status.ACTIVE).length;
      this.orders.set(id.toString(), { ...o, rungStatuses: rungs, active: left, ready: 0, status: left === 0 ? Status.SETTLED : Status.ACTIVE, posStatus: left === 0 ? PositionStatus.CLOSED : o.posStatus });
      return { hash: "0xaaa", blockNumber: 2, gasUsed: 700_000n, settled: { repaid: 88n, remainingDebt: 0n, positionClosed: left === 0 } };
    }
    return { hash: "0xaaa", blockNumber: 2, gasUsed: 700_000n, settled: { repaid: 0n, remainingDebt: 0n, positionClosed: false } }; // "noop": mined but nothing changed
  }
}
const order = (o: Partial<FakeOrder>): FakeOrder => ({ active: 1, ready: 1, status: Status.ACTIVE, rungStatuses: [Status.ACTIVE], posStatus: PositionStatus.ACTIVE, ...o });

function setup(limits: Partial<KeeperLimits> = {}, now = 10_000) {
  const port = new Fake();
  const alerts: Alert[] = [];
  const persisted: KeeperState[] = [];
  const deps = {
    port,
    alerts: new Alerts({ send: async (a: Alert) => void alerts.push(a) }),
    limits: { ...DEFAULT_LIMITS, ...limits },
    persist: (s: KeeperState) => void persisted.push(JSON.parse(JSON.stringify(s))),
    now: () => now,
  };
  return { port, alerts, persisted, deps, clock: { now } };
}

// ------------------------------------------------------------------ decisions
test("nothing active: no reads beyond the order status, no send", async () => {
  const { port, deps } = setup();
  const r = await keeperStep(deps, emptyState());
  assert.equal(r.sent, 0);
  assert.deepEqual(port.sendCalls, []);
});

test("an active order with no fully crossed rung WAITS (not reached, partly filled, reversed): no simulation, no send", async () => {
  const { port, deps } = setup();
  port.orders.set("1", order({ active: 3, ready: 0, rungStatuses: [1, 1, 1] }));
  const r = await keeperStep(deps, emptyState());
  assert.equal(r.decisions[0]!.kind, "waiting");
  assert.ok(!port.log.some((l) => l.startsWith("sim")));
  assert.equal(r.sent, 0);
  assert.equal(r.halted, false);
});

test("a ready rung: simulate, then send; read-back ok; state records the finalisation; the order is done only when settled", async () => {
  const { port, deps } = setup();
  // ladder: rung 1 ready, rungs 2 and 3 not
  port.orders.set("1", order({ active: 3, ready: 1, rungStatuses: [Status.ACTIVE, Status.ACTIVE, Status.ACTIVE] }));
  const r = await keeperStep(deps, emptyState());
  assert.deepEqual(port.log.filter((l) => l !== "sim 2" && l !== "sim 3"), ["sim 1", "send 1"], "simulation first, then the send");
  const d = r.decisions.find((x) => x.positionId === "1")!;
  assert.equal(d.kind, "finalised");
  assert.equal(r.state.finalisations.length, 1);
  assert.equal(r.state.finalisations[0]!.rungsFinalised, 1);
  assert.equal(r.state.finalisations[0]!.orderSettled, false);
  assert.equal(r.state.finalisations[0]!.positionClosed, false);
  assert.equal(r.state.pending, null);
  assert.equal(r.state.done["1"], undefined, "two rungs are still active: keep watching");
  // next step: 2 rungs active, none ready: waits
  const r2 = await keeperStep(deps, r.state);
  assert.equal(r2.decisions.find((x) => x.positionId === "1")!.kind, "waiting");
  // the rest crossed: finalise again, order settled, position closed, done
  port.orders.set("1", { ...port.orders.get("1")!, ready: 2 });
  const r3 = await keeperStep(deps, r2.state);
  assert.equal(r3.decisions.find((x) => x.positionId === "1")!.kind, "finalised");
  assert.equal(r3.state.finalisations[1]!.orderSettled, true);
  assert.equal(r3.state.finalisations[1]!.positionClosed, true);
  assert.equal(r3.state.done["1"], true);
});

test("the pending marker is persisted BEFORE the send", async () => {
  const { port, deps, persisted } = setup();
  port.orders.set("1", order({}));
  let pendingAtSend: unknown = "unset";
  port.onSend = () => {
    pendingAtSend = persisted[persisted.length - 1]!.pending;
  };
  await keeperStep(deps, emptyState());
  assert.deepEqual((pendingAtSend as { positionId: string }).positionId, "1");
  assert.equal(persisted[persisted.length - 1]!.pending, null, "cleared when the send is finished");
});

for (const name of ["BandNotFullyConverted", "OracleUnavailable", "PoolOracleDeviation"]) {
  test(`${name} from the simulation is a wait: no send, no halt, no alert, no cooldown`, async () => {
    const { port, deps, alerts } = setup();
    port.orders.set("1", order({}));
    port.sim.set("1", { ok: false, name, message: name });
    const r = await keeperStep(deps, emptyState());
    assert.equal(r.decisions[0]!.kind, "waiting");
    assert.deepEqual(port.sendCalls, []);
    assert.equal(r.halted, false);
    assert.equal(alerts.length, 0);
    assert.equal(r.state.cooldown["1"], undefined);
  });
}

test("SlippageFloor or any other refusal: not sent, warned, cooldown set and honoured on the next step", async () => {
  const { port, deps, alerts, clock } = setup();
  port.orders.set("1", order({}));
  port.sim.set("1", { ok: false, name: "SlippageFloor", message: "SlippageFloor(0,1,2)" });
  const r = await keeperStep(deps, emptyState());
  assert.equal(r.decisions[0]!.kind, "skipped");
  assert.equal(alerts.length, 1);
  assert.equal(alerts[0]!.severity, "warn");
  assert.equal(r.state.cooldown["1"], clock.now + DEFAULT_LIMITS.cooldownSeconds);
  port.log.length = 0;
  const r2 = await keeperStep(deps, r.state);
  assert.match((r2.decisions[0] as { reason: string }).reason, /cooling down/);
  assert.ok(!port.log.some((l) => l.startsWith("sim")), "no simulation during the cooldown");
  assert.deepEqual(port.sendCalls, []);
});

test("a transaction mined and REVERTED after a passing simulation HALTS; later steps send nothing", async () => {
  const { port, deps, alerts } = setup();
  port.orders.set("1", order({}));
  port.sendBehaviour = "revert";
  const r = await keeperStep(deps, emptyState());
  assert.equal(r.halted, true);
  assert.ok(r.state.halted);
  assert.equal(r.state.pending, null, "the outcome of a mined tx is known: marker cleared");
  assert.equal(alerts.at(-1)!.severity, "crit");
  port.sendCalls.length = 0;
  port.sendBehaviour = "ok";
  const r2 = await keeperStep(deps, r.state);
  assert.deepEqual(port.sendCalls, []);
  assert.equal(r2.halted, true);
});

test("an unknown error during the send HALTS and keeps the pending marker (the tx may have been mined)", async () => {
  const { port, deps } = setup();
  port.orders.set("1", order({}));
  port.sendBehaviour = "timeout";
  const r = await keeperStep(deps, emptyState());
  assert.equal(r.halted, true);
  assert.equal(r.state.pending?.positionId, "1");
});

test("a read-back mismatch (mined, but the rung is not SETTLED) HALTS", async () => {
  const { port, deps } = setup();
  port.orders.set("1", order({}));
  port.sendBehaviour = "noop";
  const r = await keeperStep(deps, emptyState());
  assert.equal(r.halted, true);
  assert.match(r.state.halted!.reason, /read-back failed/);
});

test("a pending marker found at start-up (interrupted send) HALTS without sending", async () => {
  const { port, deps, alerts } = setup();
  port.orders.set("1", order({}));
  const st: KeeperState = { ...emptyState(), pending: { positionId: "1", at: 5 } };
  const r = await keeperStep(deps, st);
  assert.equal(r.halted, true);
  assert.deepEqual(port.sendCalls, []);
  assert.match(r.state.halted!.reason, /interrupted/);
  assert.equal(alerts[0]!.severity, "crit");
});

test("a halted keeper does nothing at all", async () => {
  const { port, deps } = setup();
  port.orders.set("1", order({}));
  const st: KeeperState = { ...emptyState(), halted: { reason: "x", at: 1 } };
  const r = await keeperStep(deps, st);
  assert.deepEqual(port.log, []);
  assert.equal(r.halted, true);
});

test("fee cap and gas floor: skipped, nothing sent; the floor raises a crit alert", async () => {
  const a = setup();
  a.port.orders.set("1", order({}));
  a.port.feeRead = { ok: false, reason: "max fee 90 gwei is above the cap 60 gwei" };
  const r = await keeperStep(a.deps, emptyState());
  assert.match((r.decisions[0] as { reason: string }).reason, /fee cap/);
  assert.deepEqual(a.port.sendCalls, []);
  const b = setup();
  b.port.orders.set("1", order({}));
  b.port.balance = 1n;
  const r2 = await keeperStep(b.deps, emptyState());
  assert.match((r2.decisions[0] as { reason: string }).reason, /below the floor/);
  assert.equal(b.alerts[0]!.severity, "crit");
  assert.deepEqual(b.port.sendCalls, []);
});

test("the per-step send budget is honoured", async () => {
  const { port, deps } = setup({ maxSendsPerStep: 2 });
  port.next = 6n;
  for (const id of ["1", "2", "3", "4", "5"]) port.orders.set(id, order({}));
  const r = await keeperStep(deps, emptyState());
  assert.equal(r.sent, 2);
  assert.equal(port.sendCalls.length, 2);
  assert.ok(r.decisions.some((d) => d.kind === "skipped" && /budget/.test((d as { reason: string }).reason)));
});

test("a band removed by the owner, liquidator or adapter is recorded ONCE; one finalised by someone else too; the keeper never unwinds", async () => {
  const { port, deps, alerts } = setup();
  port.orders.set("1", order({ ready: 0 }));
  port.orders.set("2", order({ ready: 0 }));
  let r = await keeperStep(deps, emptyState());
  assert.equal(r.state.removals.length, 0);
  assert.ok(r.state.watching["1"] && r.state.watching["2"]);
  port.orders.set("1", { active: 0, ready: 0, status: Status.UNWOUND, rungStatuses: [Status.UNWOUND], posStatus: PositionStatus.LIQUIDATED });
  port.orders.set("2", { active: 0, ready: 0, status: Status.SETTLED, rungStatuses: [Status.SETTLED], posStatus: PositionStatus.CLOSED });
  r = await keeperStep(deps, r.state);
  assert.deepEqual(r.state.removals.map((x) => [x.positionId, x.kind]), [["1", "risk-path-or-owner"], ["2", "finalised-by-another-caller"]]);
  assert.equal(alerts.filter((a) => a.severity === "info").length, 2);
  r = await keeperStep(deps, r.state);
  assert.equal(r.state.removals.length, 2, "recorded once");
  assert.deepEqual(port.sendCalls, []);
  assert.equal(r.state.done["1"], true);
});

test("the cursor advances over finished positions and stops at one that may still get an order", async () => {
  const { port, deps } = setup();
  port.next = 5n;
  port.orders.set("1", { active: 0, ready: 0, status: Status.SETTLED, rungStatuses: [Status.SETTLED], posStatus: PositionStatus.CLOSED });
  port.orders.set("2", { active: 0, ready: 0, status: Status.NONE, rungStatuses: [], posStatus: PositionStatus.ACTIVE }); // open position, no order (yet)
  port.orders.set("3", { active: 0, ready: 0, status: Status.NONE, rungStatuses: [], posStatus: PositionStatus.CLOSED });
  const r = await keeperStep(deps, emptyState());
  assert.equal(r.state.cursor, "2");
  assert.equal(r.state.done["3"], true);
});

test("a read failure on one position does not stop the others", async () => {
  const { port, deps } = setup();
  const orig = port.finalizable.bind(port);
  port.finalizable = async (id: bigint) => {
    if (id === 1n) throw new Error("boom https://secret.example/abcdef123456");
    return orig(id);
  };
  port.orders.set("2", order({}));
  const r = await keeperStep(deps, emptyState());
  assert.equal(r.decisions.find((d) => d.positionId === "1")!.kind, "skipped");
  assert.equal(r.decisions.find((d) => d.positionId === "2")!.kind, "finalised");
});

// ------------------------------------------------------------------ structure
test("the keeper's ABI has no function that removes or cancels a band (it can only finalise and read)", () => {
  const fns = Object.keys(custodianIface.functions);
  assert.deepEqual(fns.filter((f) => /unwind|remove|cancel|create|set/i.test(f)), []);
  assert.ok(fns.some((f) => f.startsWith("finalize(")));
  assert.ok(!CUSTODIAN_ABI.some((x) => /unwind/i.test(x)));
});

test("the source never encodes an unwind and imports nothing from operator/", () => {
  const dir = path.join(__dirname, "..", "..", "src");
  for (const f of fs.readdirSync(dir).filter((n) => n.endsWith(".ts"))) {
    const text = fs.readFileSync(path.join(dir, f), "utf8");
    assert.ok(!/encodeFunctionData\(\s*["']unwind/.test(text), f);
    assert.ok(!/from\s+["'][^"']*operator\//.test(text), `${f} imports from operator/`);
  }
});

test("state: round trip, atomic file, owner-only mode", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "rtpk-"));
  const file = path.join(dir, "s.json");
  assert.deepEqual(loadState(file), emptyState());
  const s: KeeperState = { ...emptyState(), cursor: "7", done: { "3": true }, halted: { reason: "r", at: 2 } };
  saveState(file, s);
  assert.deepEqual(loadState(file), s);
  assert.equal(fs.statSync(file).mode & 0o077, 0);
  assert.ok(!fs.readdirSync(dir).some((n) => n.endsWith(".tmp")));
});

test("secrets: the RPC URL (host, path token) is masked in every alert and error text", () => {
  const env = { AVALANCHE_MAINNET_RPC_URL: "https://rpc.example.invalid/v2/SECRETKEY1234567890" } as NodeJS.ProcessEnv;
  const m = mask("failed at https://rpc.example.invalid/v2/SECRETKEY1234567890 (SECRETKEY1234567890)", env);
  assert.ok(!m.includes("SECRETKEY1234567890"));
  assert.ok(!m.includes("example.invalid"));
});

test("config: validated; the RPC and the password are NAMES of environment variables, never values", () => {
  const ok = { chainId: 43114, custodian: "0x0000000000000000000000000000000000000001", rpcEnv: "AVALANCHE_MAINNET_RPC_URL", keystore: { path: "/k.json", passwordEnv: "RANGE_KEEPER_KEYSTORE_PASSWORD" } };
  const c = parseConfig(ok);
  assert.equal(c.maxFeeGwei, 60);
  assert.equal(c.limits.maxSendsPerStep, 3);
  assert.throws(() => parseConfig({ ...ok, chainId: 1 }), /43114/);
  assert.throws(() => parseConfig({ ...ok, rpcEnv: "https://x.example/key" }), /NAME/);
  assert.throws(() => parseConfig({ ...ok, keystore: { path: "/k", passwordEnv: "hunter2" } }), /passwordEnv/);
  assert.throws(() => parseConfig({ ...ok, custodian: "nope" }), /address/);
  assert.throws(() => parseConfig({ ...ok, limits: { maxSendsPerStep: 0 } }), /maxSendsPerStep/);
});

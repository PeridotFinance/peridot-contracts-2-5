// A failing alert sink must never break a cycle (reference behaviour: dlmm-keeper's AlertManager.deliver, which catches and logs; this goes further: back-off,
// retry of un-announced findings, the dropped alert is kept in the process log, a 10 s transport timeout).
import test, { mock } from "node:test";
import assert from "node:assert/strict";
import { AlertManager, MemorySink, TelegramSink, WebhookSink } from "../src/alerts";
import type { AlertMessage, AlertSink } from "../src/alerts";

const AUD = "liquidators" as const;
const F = (o: Record<string, unknown> = {}): any => ({ key: "k", severity: "warn", message: "m", audience: AUD, ...o });
const MSG = (o: Partial<AlertMessage> = {}): AlertMessage => ({ kind: "action", key: "n", severity: "warn", text: "t", audience: AUD, ...o } as AlertMessage);
const quiet = () => {
  const out: string[] = [];
  mock.method(console, "error", (...a: unknown[]) => void out.push(a.join(" ")));
  mock.method(console, "log", (...a: unknown[]) => void out.push(a.join(" ")));
  return out;
};
class Switchable implements AlertSink {
  mode: "ok" | "throw" | "429" = "throw";
  calls = 0;
  delivered: AlertMessage[] = [];
  async send(m: AlertMessage): Promise<void> {
    this.calls++;
    if (this.mode === "throw") throw new Error("socket hang up");
    if (this.mode === "429") throw new Error("telegram delivery failed with HTTP 429");
    this.delivered.push(m);
  }
}

test("a sink that throws: process / raise / clear / notify never reject, the cycle continues, later notices are delivered once the sink works", async (t) => {
  quiet();
  t.after(() => mock.restoreAll());
  let now = 1_000_000;
  const sink = new Switchable();
  const am = new AlertManager(sink, [3600], undefined, { nowMs: () => now });
  await assert.doesNotReject(am.process([F({ key: "a" })], 0));
  await assert.doesNotReject(am.raise(F({ key: "b", severity: "crit" }), 1));
  await assert.doesNotReject(am.notify(MSG()));
  await assert.doesNotReject(am.clear("a", 5));
  assert.equal(sink.delivered.length, 0);
  sink.mode = "ok";
  now += 31_000; // past the first back-off
  const sent = await am.process([F({ key: "a" })], 10);
  assert.deepEqual(sent.map((m) => m.key), ["a"], "the un-announced finding is announced now (its state was rolled back, not lost)");
  await am.notify(MSG({ key: "later" }));
  assert.deepEqual(sink.delivered.map((m) => m.key), ["a", "later"]);
});

test("a notice after a sent transaction cannot throw: the code that follows it (read-back, state write) still runs", async (t) => {
  quiet();
  t.after(() => mock.restoreAll());
  const am = new AlertManager(new Switchable(), [3600]);
  const steps: string[] = [];
  const afterSentTx = async () => {
    steps.push("tx sent");
    await am.notify(MSG({ kind: "payment", key: "keeper:payment:0x1", severity: "warn", text: "PAID 0x1" }));
    steps.push("read-back and ledger write");
  };
  await afterSentTx();
  assert.deepEqual(steps, ["tx sent", "read-back and ledger write"]);
});

test("the dropped one-shot notice is kept in the process log (masked), not lost", async (t) => {
  const out = quiet();
  t.after(() => mock.restoreAll());
  process.env.AVALANCHE_MAINNET_RPC_URL = "https://archive.example.org/ext/bc/C/rpc/AbCdEf0123456789SecretKey";
  try {
    const am = new AlertManager(new Switchable(), [3600]);
    await am.notify(MSG({ key: "executor:liquidation:op1", text: "LIQUIDATED 0xabc at https://archive.example.org/ext/bc/C/rpc/AbCdEf0123456789SecretKey" }));
    const all = out.join("\n");
    assert.match(all, /alert delivery failed/);
    assert.match(all, /executor:liquidation:op1/);
    assert.ok(!all.includes("AbCdEf0123456789SecretKey") && !all.includes("archive.example.org"));
  } finally {
    delete process.env.AVALANCHE_MAINNET_RPC_URL;
  }
});

test("Telegram HTTP 429: never throws into the cycle; back-off instead of hammering; retried after the back-off; a failed raise is announced exactly once when it recovers", async (t) => {
  quiet();
  t.after(() => mock.restoreAll());
  let now = 5_000_000;
  let status = 429;
  let fetches = 0;
  const fetchFn = async () => {
    fetches++;
    return { ok: status === 200, status };
  };
  const am = new AlertManager(new TelegramSink("123:TOKEN-SECRET", "42", fetchFn as any), [3600], undefined, { nowMs: () => now });
  await am.process([F({ key: "x" })], 0);
  assert.equal(fetches, 1);
  for (let i = 1; i <= 5; i++) await am.process([F({ key: "x" })], i * 15); // 5 more cycles inside the back-off
  assert.equal(fetches, 1, "no new HTTP request while the sink is in back-off");
  status = 200;
  now += 31_000;
  const sent = await am.process([F({ key: "x" })], 100);
  assert.equal(fetches, 2);
  assert.equal(sent.length, 1);
  assert.equal(sent[0]!.kind, "new");
  await am.process([F({ key: "x" })], 130);
  assert.equal(fetches, 2, "announced once, then de-duplicated as usual");
});

test("back-off doubles per consecutive failure (30 s, 60 s, ...) and is capped at 15 min", async (t) => {
  quiet();
  t.after(() => mock.restoreAll());
  let now = 10_000_000;
  const sink = new Switchable();
  const am = new AlertManager(sink, [3600], undefined, { nowMs: () => now });
  await am.notify(MSG()); // failure 1
  for (let k = 1; k <= 8; k++) {
    const gap = Math.min(900_000, 30_000 * 2 ** (k - 1));
    const c = sink.calls;
    now += gap - 1;
    await am.notify(MSG());
    assert.equal(sink.calls, c, `failure ${k}: still in back-off 1 ms before ${gap} ms`);
    now += 1;
    await am.notify(MSG()); // the next attempt (fails again)
    assert.equal(sink.calls, c + 1, `failure ${k}: attempted again after ${gap} ms`);
  }
});

test("a hung fetch that ignores the abort signal times out (default 10 s) and the manager stays alive", async (t) => {
  quiet();
  t.after(() => mock.restoreAll());
  mock.timers.enable({ apis: ["setTimeout"] });
  let sawSignal: AbortSignal | undefined;
  const hung = (_u: string, init: { signal?: AbortSignal }) => {
    sawSignal = init.signal;
    return new Promise<never>(() => {}); // never settles, ignores the signal
  };
  const tg = new TelegramSink("123:TOKEN-SECRET", "42", hung as any); // default timeout
  const p = tg.send(MSG());
  const outcome = p.then(() => "resolved", (e: Error) => e.message);
  mock.timers.tick(9_999);
  await Promise.resolve();
  assert.equal(sawSignal?.aborted, false, "still waiting at 9.999 s");
  mock.timers.tick(1);
  assert.match(String(await outcome), /timed out after 10000 ms/);
  assert.equal(sawSignal?.aborted, true, "the request was aborted");
  const wh = new WebhookSink("https://hooks.example/abc", hung as any);
  const o2 = wh.send(MSG()).then(() => "resolved", (e: Error) => e.message);
  mock.timers.tick(10_000);
  assert.match(String(await o2), /timed out/);
  mock.timers.reset();
  const am = new AlertManager(new TelegramSink("123:T", "42", (() => Promise.reject(new Error("fetch failed"))) as any), [3600]);
  await assert.doesNotReject(am.process([F()], 0));
});

test("a real timer: a short timeout rejects a hung transport quickly and the error never contains the token", async (t) => {
  quiet();
  t.after(() => mock.restoreAll());
  const hung = () => new Promise<never>(() => {});
  const started = Date.now();
  await assert.rejects(new TelegramSink("123:TOKEN-SECRET", "42", hung as any, 40).send(MSG()), (e: Error) => /timed out after 40 ms/.test(e.message) && !/TOKEN-SECRET/.test(e.message));
  assert.ok(Date.now() - started < 2000);
});

test("MemorySink behaviour is unchanged: de-duplication, escalation and resolution still work after the change", async () => {
  const sink = new MemorySink();
  const am = new AlertManager(sink, [3600]);
  await am.process([F()], 0);
  await am.process([F()], 15);
  assert.equal(sink.messages.length, 1);
  await am.process([F({ severity: "crit" })], 30);
  assert.equal(sink.messages[1]!.kind, "severity-up");
  await am.process([], 40);
  assert.equal(sink.messages.at(-1)!.kind, "resolved");
});

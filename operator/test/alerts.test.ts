import test from "node:test";
import assert from "node:assert/strict";
import { AlertManager, MemorySink, TelegramSink, WebhookSink, createSink } from "../src/alerts";
import type { Finding } from "../src/health";

const F = (o: Partial<Finding> = {}): Finding => ({ key: "k", severity: "warn", message: "m", audience: "liquidators", ...o });
const H = 3600;

test("de-duplication: the same finding is sent once; a severity increase is sent again", async () => {
  const sink = new MemorySink();
  const am = new AlertManager(sink, [H, 4 * H, 24 * H]);
  await am.process([F()], 0);
  await am.process([F()], 15);
  await am.process([F()], 30);
  assert.equal(sink.messages.length, 1);
  await am.process([F({ severity: "crit" })], 45);
  assert.equal(sink.messages.length, 2);
  assert.equal(sink.messages[1]!.kind, "severity-up");
  await am.process([F({ severity: "warn" })], 60); // a decrease is not re-sent
  assert.equal(sink.messages.length, 2);
});
test("info findings are never sent", async () => {
  const sink = new MemorySink();
  await new AlertManager(sink, [H]).process([F({ severity: "info" })], 0);
  assert.equal(sink.messages.length, 0);
});
test("escalation timers 1 h / 4 h / 24 h fire once each, from T0, and only for escalating findings", async () => {
  const sink = new MemorySink();
  const am = new AlertManager(sink, [H, 4 * H, 24 * H]);
  const d = F({ key: "default", severity: "crit", escalates: true });
  await am.process([d], 1000);
  await am.process([d], 1000 + H - 1);
  assert.equal(sink.messages.length, 1);
  await am.process([d], 1000 + H);
  await am.process([d], 1000 + H + 5);
  assert.equal(sink.messages.filter((m) => m.kind === "escalation").length, 1);
  await am.process([d], 1000 + 4 * H);
  await am.process([d], 1000 + 24 * H);
  const esc = sink.messages.filter((m) => m.kind === "escalation").map((m) => m.escalationSeconds);
  assert.deepEqual(esc, [H, 4 * H, 24 * H]);
  const s2 = new MemorySink();
  const am2 = new AlertManager(s2, [H]);
  const plain = F({ key: "plain", severity: "crit" });
  await am2.process([plain], 0);
  await am2.process([plain], 10 * H);
  assert.equal(s2.messages.filter((m) => m.kind === "escalation").length, 0);
});
test("a missed poll catches up on all due escalations once", async () => {
  const sink = new MemorySink();
  const am = new AlertManager(sink, [H, 4 * H]);
  const d = F({ severity: "crit", escalates: true });
  await am.process([d], 0);
  await am.process([d], 5 * H);
  assert.equal(sink.messages.filter((m) => m.kind === "escalation").length, 2);
});
test("resolution is announced once and the key can alert again afterwards", async () => {
  const sink = new MemorySink();
  const am = new AlertManager(sink, [H]);
  await am.process([F()], 0);
  await am.process([], 10);
  assert.equal(sink.messages.at(-1)!.kind, "resolved");
  await am.process([], 20);
  assert.equal(sink.messages.length, 2);
  await am.process([F()], 30);
  assert.equal(sink.messages.length, 3);
});
test("raise() adds one finding without resolving the others", async () => {
  const sink = new MemorySink();
  const am = new AlertManager(sink, [H]);
  await am.process([F({ key: "a" }), F({ key: "b" })], 0);
  await am.raise(F({ key: "blind", severity: "crit" }), 5);
  assert.ok(!sink.messages.some((m) => m.kind === "resolved"));
  assert.deepEqual(Object.keys(am.toJson().active).sort(), ["a", "b", "blind"]);
});
test("state survives a restart (no duplicate page for an already-active alert)", async () => {
  const sink = new MemorySink();
  const am = new AlertManager(sink, [H]);
  await am.process([F()], 0);
  const restored = new AlertManager(sink, [H], JSON.parse(JSON.stringify(am.toJson())));
  await restored.process([F()], 100);
  assert.equal(sink.messages.length, 1);
});
test("alert text is masked before delivery", async () => {
  const sink = new MemorySink();
  process.env.AVALANCHE_MAINNET_RPC_URL = "https://archive.example.org/ext/bc/C/rpc/AbCdEf0123456789SecretKey";
  try {
    await new AlertManager(sink, [H]).process([F({ message: "failed at https://archive.example.org/ext/bc/C/rpc/AbCdEf0123456789SecretKey" })], 0);
    assert.ok(!sink.messages[0]!.text.includes("AbCdEf0123456789SecretKey") && !sink.messages[0]!.text.includes("archive.example.org"));
  } finally {
    delete process.env.AVALANCHE_MAINNET_RPC_URL;
  }
});
test("sinks: delivery failure reports the HTTP status and never the URL or token", async () => {
  const bad = async () => ({ ok: false, status: 429 });
  await assert.rejects(new TelegramSink("123:TOKEN-SECRET", "42", bad).send({ kind: "new", key: "k", severity: "warn", text: "t", audience: "liquidators" }), (e: Error) => /429/.test(e.message) && !/TOKEN-SECRET/.test(e.message));
  await assert.rejects(new WebhookSink("https://hooks.example/abc", bad).send({ kind: "new", key: "k", severity: "warn", text: "t", audience: "liquidators" }), /429/);
});
test("createSink refuses to start without credentials in the environment", () => {
  const cfg: any = { alerts: { channel: "telegram" } };
  assert.throws(() => createSink(cfg, {} as any), /OPERATOR_ALERT_TELEGRAM_TOKEN/);
  assert.throws(() => createSink({ alerts: { channel: "webhook" } } as any, {} as any), /OPERATOR_ALERT_WEBHOOK_URL/);
  assert.ok(createSink(cfg, { OPERATOR_ALERT_TELEGRAM_TOKEN: "t", OPERATOR_ALERT_TELEGRAM_CHAT_ID: "c" } as any));
});

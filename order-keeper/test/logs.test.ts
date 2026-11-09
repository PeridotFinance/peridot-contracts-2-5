import test from "node:test";
import assert from "node:assert/strict";
import { utils } from "ethers";
import { AlertManager, MemorySink } from "../src/alerts";
import { logCrossCheck } from "../src/logaudit";
import { configureLogPace, isRateLimit, logBackoffRemainingSeconds, LogRateLimitedError, pacedGetLogs } from "../src/logpace";
import { registryIface } from "../src/orders";
import { emptyState } from "../src/state";
import { A, decidedConfig } from "./fixtures";

const rl = () => Object.assign(new Error("server response 429 (Too Many Requests) (status=429, body=Cloudflare 1015)"), { status: 429 });
const topic = registryIface.getEventTopic("OrderCreated");
const log = (id: number) => ({ topics: [topic, utils.hexZeroPad(utils.hexlify(id), 32)] });

test("429 detection and the 60 s back-off that doubles to 900 s and resets on success (copy of the operator's behaviour)", async () => {
  let t = 1_000_000;
  configureLogPace({ minIntervalMs: 0, now: () => t });
  let calls = 0;
  let mode: "429" | "ok" = "429";
  const prov: any = { getLogs: async () => { calls++; if (mode === "429") throw rl(); return []; } };
  assert.ok(isRateLimit(rl()));
  await assert.rejects(pacedGetLogs(prov, {}), LogRateLimitedError);
  assert.equal(calls, 1);
  assert.equal(logBackoffRemainingSeconds(), 60);
  await assert.rejects(pacedGetLogs(prov, {}), /no request for another/);
  assert.equal(calls, 1, "no request while backing off");
  t += 61_000;
  await assert.rejects(pacedGetLogs(prov, {}), LogRateLimitedError);
  assert.equal(logBackoffRemainingSeconds(), 120);
  for (let i = 0; i < 6; i++) {
    t += logBackoffRemainingSeconds() * 1000 + 1;
    await assert.rejects(pacedGetLogs(prov, {}), LogRateLimitedError);
  }
  assert.equal(logBackoffRemainingSeconds(), 900, "capped");
  t += 901_000;
  mode = "ok";
  assert.deepEqual(await pacedGetLogs(prov, {}), []);
  mode = "429";
  await assert.rejects(pacedGetLogs(prov, {}), LogRateLimitedError);
  assert.equal(logBackoffRemainingSeconds(), 60, "a success reset the back-off");
});

test("the cross-check starts at the head, scans forward in bounded chunks, and flags an OrderCreated id the id scan has not read", async () => {
  let t = 1;
  configureLogPace({ minIntervalMs: 0, now: () => t });
  const cfg = decidedConfig();
  const sink = new MemorySink();
  const alerts = new AlertManager(sink, [1]);
  const ranges: Array<[number, number]> = [];
  const prov: any = { getLogs: async (f: any) => { ranges.push([f.fromBlock, f.toBlock]); return f.fromBlock === 1011 ? [log(7)] : []; } };
  let st = emptyState(cfg.registry);
  st = { ...st, highWater: 5 };
  const first = await logCrossCheck({ logProvider: prov, cfg, alerts, now: () => 1 }, st, 1000);
  assert.equal(first.cursor, 990, "starts at head - reorg margin; no history scan");
  assert.equal(ranges.length, 0);
  st = { ...st, logCursor: first.cursor };
  const second = await logCrossCheck({ logProvider: prov, cfg, alerts, now: () => 1 }, st, 1030);
  assert.deepEqual(ranges, [[991, 1000], [1001, 1010], [1011, 1020]], "chunks of 10 blocks up to head - 10");
  assert.equal(second.cursor, 1020);
  assert.deepEqual(second.uncovered, ["7"]);
  assert.ok(sink.messages.some((m) => m.key === "logs:uncovered" && m.severity === "crit"));
  assert.ok(A.registry);
});

test("a rate-limited or failing log endpoint never throws, never stops the keeper: a warning, the cursor holds, no request during the back-off", async () => {
  let t = 5_000_000;
  configureLogPace({ minIntervalMs: 0, now: () => t });
  const cfg = decidedConfig();
  const sink = new MemorySink();
  const alerts = new AlertManager(sink, [1]);
  let calls = 0;
  const prov: any = { getLogs: async () => { calls++; throw rl(); } };
  const st = { ...emptyState(cfg.registry), logCursor: 100 };
  const r = await logCrossCheck({ logProvider: prov, cfg, alerts, now: () => 1 }, st, 200);
  assert.equal(r.limited, true);
  assert.equal(r.cursor, 100);
  assert.equal(calls, 1);
  assert.ok(sink.messages.some((m) => m.key === "logs:limited"));
  const r2 = await logCrossCheck({ logProvider: prov, cfg, alerts, now: () => 1 }, st, 200);
  assert.equal(calls, 1, "backing off: the endpoint is not asked again");
  assert.equal(r2.limited, true);
  const prov2: any = { getLogs: async () => { throw new Error("range too large"); } };
  t += 10_000_000;
  const r3 = await logCrossCheck({ logProvider: prov2, cfg, alerts, now: () => 1 }, st, 200);
  assert.equal(r3.failed, true);
});

test("the 'uncovered id' critical is suppressed while the id scan is still catching up (a cycle that hit maxIdsPerCycle leaves highWater behind)", async () => {
  configureLogPace({ minIntervalMs: 0, now: () => 1 });
  const cfg = decidedConfig();
  const sink = new MemorySink();
  const alerts = new AlertManager(sink, [1]);
  const prov: any = { getLogs: async () => [log(50)] };
  const st = { ...emptyState(cfg.registry), highWater: 5, logCursor: 100 };
  const r = await logCrossCheck({ logProvider: prov, cfg, alerts, now: () => 1 }, st, 200, false);
  assert.deepEqual(r.uncovered, []);
  assert.ok(!sink.messages.some((m) => m.key === "logs:uncovered"));
  const r2 = await logCrossCheck({ logProvider: prov, cfg, alerts, now: () => 1 }, st, 200, true);
  assert.deepEqual(r2.uncovered.slice(0, 1), ["50"]);
});

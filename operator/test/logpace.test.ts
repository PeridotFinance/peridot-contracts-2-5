import test from "node:test";
import assert from "node:assert/strict";
import { configureLogPace, isRateLimit, logBackoffRemainingSeconds, pacedGetLogs, LogRateLimitedError } from "../src/logpace";

function provider(behaviour: (n: number) => "ok" | "429" | "other") {
  let n = 0;
  return {
    calls: () => n,
    getLogs: async () => {
      n++;
      const b = behaviour(n);
      if (b === "429") throw Object.assign(new Error("processing response error (status=429, body=\"error code: 1015\")"), { status: 429 });
      if (b === "other") throw new Error("block range too large");
      return [];
    },
  } as any;
}

test("a 429 backs off 60 s, then refuses without sending a request, then doubles on the next 429 and resets on success", async () => {
  let t = 1_000_000;
  configureLogPace({ minIntervalMs: 0, now: () => t });
  const p = provider((n) => (n === 1 || n === 3 ? "429" : "ok"));
  await assert.rejects(() => pacedGetLogs(p, {}), LogRateLimitedError);
  assert.equal(logBackoffRemainingSeconds(), 60);
  await assert.rejects(() => pacedGetLogs(p, {}), /no request for another/);
  assert.equal(p.calls(), 1, "no network call during the back-off");
  t += 61_000;
  assert.deepEqual(await pacedGetLogs(p, {}), []); // call 2: ok -> reset
  t += 1;
  await assert.rejects(() => pacedGetLogs(p, {}), LogRateLimitedError); // call 3: 429 again, back to 60 s because the success reset it
  assert.equal(logBackoffRemainingSeconds(), 60);
  t += 61_000;
  const q = provider(() => "429");
  await assert.rejects(() => pacedGetLogs(q, {}), LogRateLimitedError);
  assert.equal(logBackoffRemainingSeconds(), 120);
  t += 121_000;
  await assert.rejects(() => pacedGetLogs(q, {}), LogRateLimitedError);
  assert.equal(logBackoffRemainingSeconds(), 240);
  configureLogPace({ minIntervalMs: 0, now: () => Date.now() });
});

test("other errors are not treated as rate limits and do not start a back-off", async () => {
  configureLogPace({ minIntervalMs: 0, now: () => 5_000_000 });
  const p = provider(() => "other");
  await assert.rejects(() => pacedGetLogs(p, {}), /block range too large/);
  assert.equal(logBackoffRemainingSeconds(), 0);
  assert.equal(isRateLimit(new Error("block range too large")), false);
  assert.equal(isRateLimit(new Error("status=429")), true);
  assert.equal(isRateLimit(new Error("error code: 1015")), true);
  configureLogPace({ minIntervalMs: 0, now: () => Date.now() });
});

test("requests are spaced by the minimum interval", async () => {
  configureLogPace({ minIntervalMs: 80 });
  const p = provider(() => "ok");
  const t0 = Date.now();
  await pacedGetLogs(p, {});
  await pacedGetLogs(p, {});
  await pacedGetLogs(p, {});
  assert.ok(Date.now() - t0 >= 150, `3 requests took ${Date.now() - t0} ms`);
  configureLogPace({ minIntervalMs: 0 });
});

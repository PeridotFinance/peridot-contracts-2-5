import test from "node:test";
import assert from "node:assert/strict";
import { checkOracle, oraclePrice18, pool18 } from "../src/sanity";
import type { FeedReading, SanityInput } from "../src/sanity";

const feed = (answer: bigint, over: Partial<FeedReading> = {}): FeedReading => ({ roundId: 9n, answer, updatedAt: 1_000_000 - 3600, answeredInRound: 9n, decimals: 8, ...over });
const Q = 2n ** 128n;
const input = (over: Partial<SanityInput> = {}): SanityInput => ({
  feedX: feed(99_934_000n), feedY: feed(99_975_000n), chainNow: 1_000_000, maxFeedAge: 93_600, legBandBps: 50, keeperLegBandBps: 40,
  poolPrice128: (Q * 9996n) / 10_000n, tokenDecX: 6, tokenDecY: 6, maxPoolOracleDevBps: 50, vaultMaxPoolOracleDevBps: 60, ...over,
});

test("oracle price of X in Y raw units: the live feeds (USDT 0.99934, USDC 0.99975) give 0.99959", () => {
  const p = oraclePrice18(feed(99_934_000n), feed(99_975_000n), 6, 6);
  assert.equal(p / 10n ** 12n, 999_589n); // 0.999589...
});
test("decimals: an 18-decimal X against a 6-decimal Y shifts the raw ratio by 1e12", () => {
  const p = oraclePrice18(feed(100_000_000n), feed(100_000_000n), 18, 6);
  assert.equal(p, 10n ** 6n);
});
test("pool18 converts the 128.128 price", () => {
  assert.equal(pool18(Q), 10n ** 18n);
  const v = pool18((Q * 9996n) / 10_000n) / 10n ** 12n;
  assert.ok(v === 999_599n || v === 999_600n, String(v)); // floor of a floor
});
test("normal day: no problem, deviation about 0 bp", () => {
  const r = checkOracle(input());
  assert.deepEqual(r.problems, []);
  assert.ok(r.poolDevBps !== undefined && r.poolDevBps <= 2);
});
test("pool 80 bp away from the oracle ratio: refused (keeper limit 50 bp, vault 60 bp)", () => {
  const r = checkOracle(input({ poolPrice128: (Q * 9918n) / 10_000n }));
  assert.equal(r.problems.length, 1);
  assert.match(r.problems[0]!, /pool price differs/);
});
test("the effective pool limit is the stricter of keeper and vault (vault 30 bp beats keeper 50 bp)", () => {
  const r = checkOracle(input({ poolPrice128: (Q * 9960n) / 10_000n, vaultMaxPoolOracleDevBps: 30 })); // 36 bp off
  assert.equal(r.problems.length, 1);
});
test("a leg 60 bp from 1.00 is refused by the keeper (limit 40) and a leg 45 bp too, one at 30 bp passes", () => {
  assert.equal(checkOracle(input({ feedX: feed(99_400_000n) })).problems.some((p) => /bp from 1.00/.test(p)), true);
  assert.equal(checkOracle(input({ feedX: feed(99_550_000n) })).problems.some((p) => /bp from 1.00/.test(p)), true);
  assert.equal(checkOracle(input({ feedX: feed(99_700_000n) })).problems.length, 0);
});
test("a stale feed (older than the vault's maxFeedAge) and an incomplete round are refused", () => {
  assert.match(checkOracle(input({ feedY: feed(99_975_000n, { updatedAt: 1_000_000 - 100_000 }) })).problems.join(), /stale/);
  assert.match(checkOracle(input({ feedY: feed(99_975_000n, { answeredInRound: 8n }) })).problems.join(), /round incomplete/);
  assert.match(checkOracle(input({ feedX: feed(99_934_000n, { updatedAt: 0 }) })).problems.join(), /round incomplete/);
});
test("a non-positive answer is refused without throwing", () => {
  assert.match(checkOracle(input({ feedX: feed(0n) })).problems.join(), /non-positive/);
  assert.match(checkOracle(input({ feedX: feed(-5n) })).problems.join(), /non-positive/);
});

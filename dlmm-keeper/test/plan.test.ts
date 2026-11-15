import test from "node:test";
import assert from "node:assert/strict";
import { E18, planSwap } from "../src/plan";
import type { PlanParams, Quote } from "../src/plan";

// pool: 1 X = 0.9996 Y (raw), fee 3 bp; the oracle agrees (0.99959)
const P = 999_590_000_000_000_000n; // oracle price raw Y per raw X, 1e18
const mkQuote = (rate18: bigint, feeBps = 3n, maxIn?: bigint): Quote => async (xForY, amountIn) => {
  const left = maxIn !== undefined && amountIn > maxIn ? amountIn - maxIn : 0n;
  const ain = amountIn - left;
  const gross = xForY ? (ain * rate18) / E18 : (ain * E18) / rate18;
  return { amountInLeft: left, amountOut: (gross * (10_000n - feeBps)) / 10_000n };
};
const base = (over: Partial<PlanParams>): PlanParams => ({ x: 0n, y: 0n, oracle18: P, maxSwapBps: 6000, effLossBps: 40, swapSlippageBps: 10, addSlippageBps: 50, quote: mkQuote(999_600_000_000_000_000n), ...over });
const value = (x: bigint, y: bigint): bigint => (x * P) / E18 + y;

test("exit upward: the band is all Y (USDC); X is the other leg, so swap Y for X, about half of NAV", async () => {
  const pl = await planSwap(base({ y: 100_000_000n }));
  assert.ok(pl.ok);
  if (!pl.ok) return;
  assert.equal(pl.swapXForY, false);
  assert.ok(pl.swapIn > 49_900_000n && pl.swapIn < 50_100_000n, String(pl.swapIn));
  assert.ok(pl.residualImbalanceBps <= 2, `residual ${pl.residualImbalanceBps} bp`);
  assert.equal(pl.capped, false);
});
test("exit downward: the band is all X (USDt): swap X for Y", async () => {
  const pl = await planSwap(base({ x: 100_000_000n }));
  assert.ok(pl.ok);
  if (!pl.ok) return;
  assert.equal(pl.swapXForY, true);
  assert.ok(pl.swapIn > 49_900_000n && pl.swapIn < 50_100_000n);
  assert.ok(pl.residualImbalanceBps <= 2);
});
test("the swap is sized from the QUOTED rate, not the pool price: a worse rate swaps a bit more X", async () => {
  const a = await planSwap(base({ x: 100_000_000n }));
  const b = await planSwap(base({ x: 100_000_000n, quote: mkQuote(999_300_000_000_000_000n, 3n) })); // 3 bp worse, still within the 40 bp oracle tolerance
  assert.ok(a.ok && b.ok);
  if (a.ok && b.ok) assert.ok(b.swapIn > a.swapIn);
});
test("an already balanced inventory sends no swap (swapIn 0, swapMinOut 0) and keeps the add minimums", async () => {
  const x = 50_000_000n;
  const y = (x * P) / E18;
  const pl = await planSwap(base({ x, y }));
  assert.ok(pl.ok);
  if (!pl.ok) return;
  assert.equal(pl.swapIn, 0n);
  assert.equal(pl.swapMinOut, 0n);
  assert.equal(pl.amountXMin, (x * 9950n) / 10_000n);
});
test("idle balances are part of the inventory the caller passes (x and y are the sum); a mixed inventory swaps only the difference", async () => {
  const pl = await planSwap(base({ x: 30_000_000n, y: 70_000_000n }));
  assert.ok(pl.ok);
  if (!pl.ok) return;
  assert.equal(pl.swapXForY, false);
  const diff = 70_000_000n - (30_000_000n * P) / E18;
  assert.ok(pl.swapIn > diff / 2n - 50_000n && pl.swapIn < diff / 2n + 50_000n);
});
test("swapIn is capped under maxSwapBps of NAV (with a 1 % margin) and the plan says so", async () => {
  const pl = await planSwap(base({ y: 100_000_000n, maxSwapBps: 3000 })); // 30 % cap but the balance needs 50 %
  assert.ok(pl.ok);
  if (!pl.ok) return;
  assert.equal(pl.capped, true);
  assert.ok(pl.swapIn <= (100_000_000n * 3000n * 99n) / (10_000n * 100n));
  assert.ok(pl.residualImbalanceBps > 1000);
});
test("swapMinOut clears BOTH the quote minus slippage and the oracle-implied floor", async () => {
  const pl = await planSwap(base({ x: 100_000_000n }));
  assert.ok(pl.ok);
  if (!pl.ok) return;
  const quoteFloor = (pl.quoteOut * 9990n) / 10_000n;
  const oracleFloor = (pl.oracleOut * 9960n) / 10_000n;
  assert.ok(pl.swapMinOut >= quoteFloor && pl.swapMinOut >= oracleFloor);
  assert.ok(pl.swapMinOut <= pl.quoteOut, "never above what the pair quotes");
});
test("the oracle floor uses the stricter of the keeper's and the vault's loss bound", async () => {
  const strict = await planSwap(base({ x: 100_000_000n, effLossBps: 5 }));
  const loose = await planSwap(base({ x: 100_000_000n, effLossBps: 40 }));
  assert.ok(strict.ok && loose.ok);
  // a pool paying 4 bp under the oracle (rate 0.9996*(1-3bp) vs 0.99959) is inside 40 bp but outside 5 bp? quote 0.99930 vs oracle 0.99959 = 2.9 bp: inside 5
  assert.ok(strict.ok);
  const bad = await planSwap(base({ x: 100_000_000n, effLossBps: 5, quote: mkQuote(999_000_000_000_000_000n, 3n) }));
  assert.equal(bad.ok, false);
  if (!bad.ok) assert.equal(bad.code, "quote-below-oracle");
});
test("a quote below the oracle floor is NOT sent (pool 1 % off the oracle)", async () => {
  const pl = await planSwap(base({ x: 100_000_000n, quote: mkQuote(989_000_000_000_000_000n) }));
  assert.equal(pl.ok, false);
  if (!pl.ok) assert.equal(pl.code, "quote-below-oracle");
});
test("a quote that leaves input unfilled (depth) is NOT sent", async () => {
  const pl = await planSwap(base({ y: 100_000_000n, quote: mkQuote(999_600_000_000_000_000n, 3n, 10_000_000n) }));
  assert.equal(pl.ok, false);
  if (!pl.ok) assert.equal(pl.code, "depth");
});
test("empty inventory and bad inputs are refused, not swapped", async () => {
  const e = await planSwap(base({}));
  assert.ok(!e.ok && e.code === "empty");
  const b = await planSwap(base({ y: 1n, oracle18: 0n }));
  assert.ok(!b.ok && b.code === "bad-input");
});
test("amount minimums are the worst-case post-swap inventory (at swapMinOut) minus the add slippage, never above what will be added", async () => {
  const pl = await planSwap(base({ y: 100_000_000n }));
  assert.ok(pl.ok);
  if (!pl.ok) return;
  const xWorst = pl.swapMinOut; // Y->X swap: all X comes from the swap
  assert.equal(pl.amountXMin, (xWorst * 9950n) / 10_000n);
  assert.equal(pl.amountYMin, ((100_000_000n - pl.swapIn) * 9950n) / 10_000n);
  assert.ok(pl.amountXMin <= pl.quoteOut);
});
test("value is conserved up to fee and slippage: NAV after (oracle) >= NAV before x (1 - loss bound)", async () => {
  const x = 20_000_000n;
  const y = 80_000_000n;
  const pl = await planSwap(base({ x, y }));
  assert.ok(pl.ok);
  if (!pl.ok) return;
  const after = value(x + pl.quoteOut, y - pl.swapIn);
  assert.ok(after * 10_000n >= value(x, y) * 9960n);
});
test("different token decimals (6 and 18): the sizing works in raw units", async () => {
  // X has 18 decimals, Y 6: 1 whole X = 1 whole Y => raw Y per raw X = 1e-12; oracle18 = 1e6
  const pO = 10n ** 6n;
  const q: Quote = async (xForY, ain) => ({ amountInLeft: 0n, amountOut: xForY ? ain / 10n ** 12n : ain * 10n ** 12n });
  const pl = await planSwap({ x: 100n * 10n ** 18n, y: 0n, oracle18: pO, maxSwapBps: 6000, effLossBps: 40, swapSlippageBps: 10, addSlippageBps: 50, quote: q });
  assert.ok(pl.ok);
  if (pl.ok) {
    assert.equal(pl.swapXForY, true);
    assert.ok(pl.swapIn > 49n * 10n ** 18n && pl.swapIn < 51n * 10n ** 18n);
  }
});

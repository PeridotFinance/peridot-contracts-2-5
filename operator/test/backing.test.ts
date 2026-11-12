import test from "node:test";
import assert from "node:assert/strict";
import { unrecoverableDebt } from "../src/backing";
import { Verdict } from "../src/detect";
import type { RuleResult } from "../src/detect";

const E18 = 10n ** 18n;
const LI = 1_080_000_000_000_000_000n;
const r = (verdict: number, debtUsd: bigint, collUsd: bigint): RuleResult => ({ verdict: verdict as any, debtUnits: 1n, debtUsd, collUsd, collUsdOracle: collUsd, shortfallUsd: 0n, maxRecoveryUsd: 0n });
const usd = (n: number) => BigInt(Math.round(n * 1e6)) * 10n ** 12n;

test("zero when every account is covered by its seizable collateral (healthy and recoverable rows)", () => {
  const b = unrecoverableDebt([r(Verdict.HEALTHY, usd(832.98), usd(4164.9)), r(Verdict.LIQUIDATABLE_RECOVERABLE, usd(1682.39), usd(4164.9)), r(Verdict.NO_DEBT, 0n, 0n)], LI, usd(5));
  assert.equal(b.unrecoverableUsd, 0n);
  assert.equal(b.rawUsd, 0n);
  assert.equal(b.complete, true);
});
test("positive on tail and default rows: sum of max(0, debt - collateral/LI) minus reserves", () => {
  const tail = r(Verdict.UNRECOVERABLE_LIQUIDATE_FIRST, usd(1682.39), usd(1041.22)); // 1682.39 - 964.09 = 718.30
  const dead = r(Verdict.DEFAULT_EXHAUSTED, usd(718.29), 0n); // 718.29
  const b = unrecoverableDebt([tail, dead], LI, usd(10));
  const want = (usd(1682.39) - (usd(1041.22) * E18) / LI) + usd(718.29);
  assert.equal(b.rawUsd, want);
  assert.equal(b.unrecoverableUsd, want - usd(10));
});
test("reserves absorb small defaults (clipped at zero, unclipped value still reported)", () => {
  const b = unrecoverableDebt([r(Verdict.DEFAULT_EXHAUSTED, usd(3), 0n)], LI, usd(10));
  assert.equal(b.unrecoverableUsd, 0n);
  assert.equal(b.rawUsd, usd(3));
});
test("an account that cannot be valued makes the figure INCOMPLETE instead of silently low", () => {
  const b = unrecoverableDebt([r(Verdict.PRICE_DIVERGENCE, 0n, 0n), r(Verdict.DEFAULT_EXHAUSTED, usd(100), 0n)], LI, 0n);
  assert.equal(b.complete, false);
  assert.equal(b.unrecoverableUsd, usd(100));
  assert.equal(unrecoverableDebt([r(Verdict.STALE_OR_ZERO_PRICE, 0n, 0n)], LI, 0n).complete, false);
  assert.equal(unrecoverableDebt([r(Verdict.NO_REFERENCE_PRICE, 0n, 0n)], LI, 0n).complete, false);
});

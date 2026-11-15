import test from "node:test";
import assert from "node:assert/strict";
import { evaluateRule, Verdict } from "../src/detect";
import type { AccountInput, MarketAccountData } from "../src/detect";

const E18 = 10n ** 18n;
const PARAMS = { liquidationIncentive: 1_080_000_000_000_000_000n, dustUsd: 10n ** 16n, toleranceBp: 500n };
// pWAVAX: 18-dec underlying, price 25 USD (25e18); pUSDC: 6-dec, price 1 USD (1e30). exchange rates 1:1 for readability.
const P_W = 25n * E18;
const P_U = 10n ** 30n;
const wavax = (o: Partial<MarketAccountData> = {}): MarketAccountData => ({ snapshotErr: 0n, pTokenBalance: 0n, borrowBalance: 0n, exchangeRate: E18, oraclePrice: P_W, referencePrice: P_W, ...o });
const usdc = (o: Partial<MarketAccountData> = {}): MarketAccountData => ({ snapshotErr: 0n, pTokenBalance: 0n, borrowBalance: 0n, exchangeRate: E18, oraclePrice: P_U, referencePrice: P_U, ...o });
const acct = (w: Partial<MarketAccountData>, u: Partial<MarketAccountData>, liq: Partial<AccountInput> = {}): AccountInput => {
  const um = usdc(u);
  return { debtUnits: um.borrowBalance, markets: [wavax(w), um], liquidityErr: 0n, shortfall: 0n, ...liq };
};
const v = (i: AccountInput, hooks = {}, p = PARAMS) => evaluateRule(i, p, hooks).verdict;

test("NO_DEBT: an account without debt needs no price", () => {
  assert.equal(v(acct({ pTokenBalance: 10n * E18, oraclePrice: 0n }, {})), Verdict.NO_DEBT);
});
test("HEALTHY: debt but no shortfall", () => {
  assert.equal(v(acct({ pTokenBalance: 10n * E18 }, { borrowBalance: 100_000_000n })), Verdict.HEALTHY);
});
test("LIQUIDATABLE_RECOVERABLE: shortfall and a full liquidation clears the debt", () => {
  // collateral USD 250, debt USD 100: C/LI = 231 >= 100
  assert.equal(v(acct({ pTokenBalance: 10n * E18 }, { borrowBalance: 100_000_000n }, { shortfall: 1n })), Verdict.LIQUIDATABLE_RECOVERABLE);
});
test("UNRECOVERABLE_LIQUIDATE_FIRST: C/LI < D but collateral above dust", () => {
  // collateral USD 25 (1 WAVAX), debt USD 100
  assert.equal(v(acct({ pTokenBalance: 1n * E18 }, { borrowBalance: 100_000_000n }, { shortfall: 1n })), Verdict.UNRECOVERABLE_LIQUIDATE_FIRST);
});
test("DEFAULT_EXHAUSTED fires only when collateral is dust", () => {
  assert.equal(v(acct({ pTokenBalance: 0n }, { borrowBalance: 100_000_000n }, { shortfall: 1n })), Verdict.DEFAULT_EXHAUSTED);
  // exactly dust (USD 0.01 = 1e16): still fires; one wei of USD above: does not
  const atDust = 10n ** 16n / 25n; // wavax units worth 0.0004 USD... scale: 25 USD per 1e18 units -> 1e16 USD(1e18) = 4e14 units
  const unitsAtDust = (10n ** 16n * E18) / P_W;
  assert.equal(v(acct({ pTokenBalance: unitsAtDust }, { borrowBalance: 100_000_000n }, { shortfall: 1n })), Verdict.DEFAULT_EXHAUSTED);
  assert.equal(v(acct({ pTokenBalance: unitsAtDust + 1n }, { borrowBalance: 100_000_000n }, { shortfall: 1n })), Verdict.UNRECOVERABLE_LIQUIDATE_FIRST);
  void atDust;
});
test("exact recoverable boundary: collUsd x 1e18 == debtUsd x LI is still RECOVERABLE (C/LI == D)", () => {
  // collateral 4.32 WAVAX = USD 108.00, debt USD 100.00, LI 1.08 -> C == D x LI exactly
  assert.equal(v(acct({ pTokenBalance: (432n * E18) / 100n }, { borrowBalance: 100_000_000n }, { shortfall: 1n })), Verdict.LIQUIDATABLE_RECOVERABLE);
  assert.equal(v(acct({ pTokenBalance: (432n * E18) / 100n - 1n }, { borrowBalance: 100_000_000n }, { shortfall: 1n })), Verdict.UNRECOVERABLE_LIQUIDATE_FIRST, "one wei less is unrecoverable");
});
test("fail closed: a zero oracle price, an unreadable market, a controller error", () => {
  assert.equal(v(acct({ pTokenBalance: 0n, oraclePrice: 0n, borrowBalance: 1n }, { borrowBalance: 100_000_000n }, { shortfall: 1n })), Verdict.STALE_OR_ZERO_PRICE);
  assert.equal(v(acct({ snapshotErr: 9n }, { borrowBalance: 100_000_000n }, { shortfall: 1n })), Verdict.STALE_OR_ZERO_PRICE);
  assert.equal(v(acct({}, { borrowBalance: 100_000_000n }, { liquidityErr: 13n, shortfall: 5n })), Verdict.STALE_OR_ZERO_PRICE);
});
test("fail closed: a missing reference price for a market the account touches", () => {
  assert.equal(v(acct({ pTokenBalance: 1n, referencePrice: 0n }, { borrowBalance: 100_000_000n }, { shortfall: 1n })), Verdict.NO_REFERENCE_PRICE);
  // a market the account does not touch needs no reference
  assert.equal(v(acct({ pTokenBalance: 0n, referencePrice: 0n }, { borrowBalance: 100_000_000n }, { shortfall: 1n })), Verdict.DEFAULT_EXHAUSTED);
});
test("tolerance boundary, to the wei, both directions", () => {
  const ref = P_W;
  const tol = 500n;
  const atEdgeUp = ref + (ref * tol) / 10_000n; // |P-R| * 1e4 == R * tol
  const atEdgeDown = ref - (ref * tol) / 10_000n;
  const mk = (p: bigint) => acct({ pTokenBalance: 1n * E18, oraclePrice: p, referencePrice: ref }, { borrowBalance: 100_000_000n }, { shortfall: 1n });
  assert.notEqual(v(mk(atEdgeUp)), Verdict.PRICE_DIVERGENCE, "at the tolerance the ordinary verdict stands");
  assert.notEqual(v(mk(atEdgeDown)), Verdict.PRICE_DIVERGENCE);
  assert.equal(v(mk(atEdgeUp + 1n)), Verdict.PRICE_DIVERGENCE, "one wei beyond: divergence");
  assert.equal(v(mk(atEdgeDown - 1n)), Verdict.PRICE_DIVERGENCE);
});
test("a wrong reference can only delay a payment, never cause one (28 reference/oracle pairs, divergence gate disabled)", () => {
  const nonExhausted = (ref: bigint) => acct({ pTokenBalance: 1n * E18, oraclePrice: P_W, referencePrice: ref }, { borrowBalance: 100_000_000n }, { shortfall: 1n });
  const factors = [1n, 10n, 100n, 1_000n, 5_000n, 9_000n, 9_999n, 10_001n, 11_000n, 20_000n, 100_000n, 1_000_000n, 10_000n, 150_000n]; // x 1/10_000 of the oracle price
  let n = 0;
  for (const f of factors) {
    for (const wide of [PARAMS, { ...PARAMS, toleranceBp: 10n ** 12n }]) {
      const ref = (P_W * f) / 10_000n;
      const verdict = v(nonExhausted(ref), {}, wide);
      assert.notEqual(verdict, Verdict.DEFAULT_EXHAUSTED, `ref factor ${f}`);
      n++;
    }
  }
  assert.equal(n, 28);
});
test("MUTATION 1 (fire on shortfall alone) is caught by the verdict tests above", () => {
  assert.equal(v(acct({ pTokenBalance: 10n * E18 }, { borrowBalance: 100_000_000n }, { shortfall: 1n }), { mutation: 1 }), Verdict.DEFAULT_EXHAUSTED, "the mutant fires on a recoverable account");
});
test("MUTATION 3 (no divergence gate) is caught by the boundary test", () => {
  const i = acct({ pTokenBalance: 1n * E18, oraclePrice: P_W * 2n, referencePrice: P_W }, { borrowBalance: 100_000_000n }, { shortfall: 1n });
  assert.equal(v(i), Verdict.PRICE_DIVERGENCE);
  assert.notEqual(v(i, { mutation: 3 }), Verdict.PRICE_DIVERGENCE);
});
test("conservative valuation: collateral at max(P,R), debt at min(P,R)", () => {
  const r = evaluateRule(acct({ pTokenBalance: 10n * E18, oraclePrice: P_W, referencePrice: (P_W * 103n) / 100n }, { borrowBalance: 100_000_000n, oraclePrice: P_U, referencePrice: (P_U * 99n) / 100n }, { shortfall: 1n }), PARAMS);
  assert.equal(r.collUsd, (10n * E18 * ((P_W * 103n) / 100n)) / E18);
  assert.equal(r.collUsdOracle, (10n * E18 * P_W) / E18);
  assert.equal(r.debtUsd, (100_000_000n * ((P_U * 99n) / 100n)) / E18);
});

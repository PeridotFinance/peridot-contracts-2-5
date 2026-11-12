import test from "node:test";
import assert from "node:assert/strict";
import { marketFindings, operatorFindings, oracleFindings, treasuryFindings, emptyHealthState, treasuryOutflowFinding } from "../src/health";
import type { BlockSnapshot, MarketStat } from "../src/chain";
import { requireValidConfig } from "../src/config";
import { USDC, WAVAX } from "../src/constants";

import { A, decidedConfig } from "./fixtures";
const cfgRaw = decidedConfig({ treasury: A(0x200), operators: [A(0x101), A(0x102)] });
cfgRaw.deployment = { controller: A(1), pWavax: A(0x11), pUsdc: A(0x12), oracle: A(0x13), deploymentBlock: 1 };
const cfg = requireValidConfig(cfgRaw);

const mk = (pToken: string, underlying: string, o: Partial<MarketStat> = {}): MarketStat => ({ pToken, underlying, cash: 0n, totalBorrows: 0n, totalReserves: 0n, totalSupply: 0n, exchangeRate: 2n * 10n ** 14n, collateralFactor: 0n, borrowCap: 0n, cashFloor: 0n, mintPaused: false, borrowPaused: false, accountingEnabled: true, totalBorrowShares: 0n, readOk: true, ...o });
const snap = (o: Partial<BlockSnapshot> = {}): BlockSnapshot => ({
  blockNumber: 100, blockTimestamp: 10_000, liquidationIncentive: 1_080_000_000_000_000_000n, closeFactor: 5n * 10n ** 17n,
  markets: [mk(A(0x11), WAVAX, { collateralFactor: 3n * 10n ** 17n, borrowPaused: true }), mk(A(0x12), USDC, { cash: 2_000_000_000n, totalBorrows: 1_000_000_000n, borrowCap: 5_000_000_000n, cashFloor: 1_000_000_000n, totalBorrowShares: 7n })],
  oraclePrices: [25n * 10n ** 18n, 10n ** 30n], usdcOraclePrice: 10n ** 30n,
  feeds: { avax: { ok: true, answer: 1n, updatedAt: 0n, ageSeconds: 100n, guardSeconds: 1200 }, usdc: { ok: true, answer: 1n, updatedAt: 0n, ageSeconds: 100n, guardSeconds: 90000 } },
  reference: { status: "ok", wavaxReference: 25n * 10n ** 18n, tick: 0, poolLiquidity: 1n },
  operators: cfg.operators.map((op) => ({ name: op.name, address: op.address, usdc: 5_000_000_000n, avaxWei: 10n ** 18n, nonce: 1 })),
  treasury: { address: cfg.treasury.address, usdc: 1_200_000_000n, allowanceToPUsdc: 0n }, controller: { admin: A(9), pauseGuardian: A(9) }, ...o,
});
const keys = (f: { key: string; severity: string }[]) => f.map((x) => `${x.key}:${x.severity}`);

test("oracle freshness: warn at 50% / 80% of the AVAX guard, crit when unreadable, crit on a zero price", () => {
  const s = (age: bigint) => snap({ feeds: { avax: { ok: true, answer: 1n, updatedAt: 0n, ageSeconds: age, guardSeconds: 1200 }, usdc: snap().feeds.usdc } });
  assert.deepEqual(keys(oracleFindings(s(599n), cfg)), []);
  assert.deepEqual(keys(oracleFindings(s(600n), cfg)), ["feed:avax:warn"]);
  assert.deepEqual(keys(oracleFindings(s(960n), cfg)), ["feed:avax:crit"]);
  assert.ok(keys(oracleFindings(snap({ feeds: { avax: { ok: false, answer: 0n, updatedAt: 0n, ageSeconds: 0n, guardSeconds: 1200 }, usdc: snap().feeds.usdc } }), cfg)).includes("feed:avax:crit"));
  assert.ok(keys(oracleFindings(snap({ oraclePrices: [0n, 10n ** 30n] }), cfg)).some((k) => k.startsWith("oracle-zero:") && k.endsWith("crit")));
  assert.ok(keys(oracleFindings(snap({ reference: { status: "none", reason: "x" } }), cfg)).includes("reference:none:warn"));
});
test("exchange rate must not fall", () => {
  const prev = emptyHealthState();
  const first = marketFindings(snap(), cfg, prev, 7n, true);
  assert.ok(!first.findings.some((f) => f.key.startsWith("exchange-rate")));
  const s2 = snap({ markets: [snap().markets[0]!, mk(A(0x12), USDC, { ...snap().markets[1]!, exchangeRate: 2n * 10n ** 14n - 1n })] });
  const second = marketFindings(s2, cfg, { ...prev, lastExchangeRate: first.next.lastExchangeRate }, 7n, true);
  assert.ok(second.findings.some((f) => f.key.startsWith("exchange-rate") && f.severity === "crit"));
});
test("shares consistency: mismatch is critical when the index is complete, disabled accounting is critical", () => {
  assert.ok(marketFindings(snap(), cfg, emptyHealthState(), 8n, true).findings.some((f) => f.key === "shares:mismatch" && f.severity === "crit"));
  assert.ok(marketFindings(snap(), cfg, emptyHealthState(), 8n, false).findings.some((f) => f.key === "shares:mismatch" && f.severity === "warn"));
  assert.ok(!marketFindings(snap(), cfg, emptyHealthState(), 7n, true).findings.some((f) => f.key.startsWith("shares")));
  const off = snap({ markets: [snap().markets[0]!, mk(A(0x12), USDC, { ...snap().markets[1]!, accountingEnabled: false })] });
  assert.ok(marketFindings(off, cfg, emptyHealthState(), 7n, true).findings.some((f) => f.key === "shares:disabled"));
});
test("configuration drift: collateral factor, WAVAX borrowing, cap, floor", () => {
  const drift = snap({ markets: [mk(A(0x11), WAVAX, { collateralFactor: 4n * 10n ** 17n, borrowPaused: false }), mk(A(0x12), USDC, { borrowCap: 9_000_000_000n, cashFloor: 0n, collateralFactor: 5n * 10n ** 17n })] });
  const k = keys(marketFindings(drift, cfg, emptyHealthState(), undefined, true).findings);
  for (const must of ["drift:cf-wavax:crit", "drift:cf-usdc:crit", "drift:wavax-borrow:crit", "drift:cap-usdc:warn", "drift:cash-floor:warn"]) assert.ok(k.includes(must), must);
  assert.deepEqual(keys(marketFindings(snap(), cfg, emptyHealthState(), 7n, true).findings), []);
});
test("utilisation, cash against the floor, cap use", () => {
  const hot = snap({ markets: [snap().markets[0]!, mk(A(0x12), USDC, { cash: 100_000_000n, totalBorrows: 4_900_000_000n, borrowCap: 5_000_000_000n, cashFloor: 1_000_000_000n, totalBorrowShares: 7n })] });
  const k = keys(marketFindings(hot, cfg, emptyHealthState(), 7n, true).findings);
  for (const must of ["util:usdc:warn", "floor:usdc:warn", "cap:usdc:warn"]) assert.ok(k.includes(must), must);
});
test("operator inventory: crit below 0.75 x aggregate debt, warn below the pilot minimum, crit on low gas; nonce change tracked", () => {
  const s = snap();
  const lowInv = snap({ operators: [{ ...s.operators[0]!, usdc: 700_000_000n }, { ...s.operators[1]!, avaxWei: 1n }] }); // aggregate debt 1000 -> required 750
  const r = operatorFindings(lowInv, cfg, emptyHealthState());
  assert.ok(keys(r.findings).includes(`inventory:${A(0x101)}:crit`));
  assert.ok(keys(r.findings).includes(`gas:${A(0x102)}:crit`));
  const belowMin = snap({ operators: s.operators.map((o) => ({ ...o, usdc: 3_000_000_000n })) });
  assert.ok(operatorFindings(belowMin, cfg, emptyHealthState()).findings.every((f) => f.severity === "warn"));
  const a = operatorFindings(s, cfg, emptyHealthState());
  const b = operatorFindings({ ...s, blockTimestamp: 20_000 }, cfg, { ...emptyHealthState(), operatorNonce: a.next.operatorNonce });
  assert.equal(b.next.operatorNonce[A(0x101)]!.changedAt, 10_000, "unchanged nonce keeps its timestamp");
  const c = operatorFindings({ ...s, blockTimestamp: 30_000, operators: s.operators.map((o) => ({ ...o, nonce: 2 })) }, cfg, { ...emptyHealthState(), operatorNonce: a.next.operatorNonce });
  assert.equal(c.next.operatorNonce[A(0x101)]!.changedAt, 30_000);
});
test("treasury: capital below the requirement (warn) and below the expected call (crit)", () => {
  assert.deepEqual(keys(treasuryFindings(snap(), cfg, 0n)), []);
  assert.deepEqual(keys(treasuryFindings(snap({ treasury: { address: cfg.treasury.address, usdc: 1n, allowanceToPUsdc: 0n } }), cfg, 0n)), ["treasury:capital:warn"]);
  assert.ok(keys(treasuryFindings(snap(), cfg, 2_000_000_000n)).includes("treasury:funding:crit"));
});

test("USDC leaving the keeper wallet without a recorded payment is critical; recorded payments and inflows are not", () => {
  const prev = { usdc: "1000", blockNumber: 100 };
  const addr = "0xkeeper";
  assert.equal(treasuryOutflowFinding(undefined, 5n, 200, [], addr), undefined, "first evaluation: nothing to compare");
  assert.equal(treasuryOutflowFinding(prev, 1000n, 200, [], addr), undefined);
  assert.equal(treasuryOutflowFinding(prev, 5000n, 200, [], addr), undefined, "a top-up is an inflow");
  assert.equal(treasuryOutflowFinding(prev, 400n, 200, [{ blockNumber: 150, amountUsdc: "600" }], addr), undefined, "explained by a recorded payment");
  assert.equal(treasuryOutflowFinding(prev, 400n, 200, [{ blockNumber: 99, amountUsdc: "600" }], addr)?.severity, "crit", "a payment from before the previous evaluation does not explain it");
  assert.equal(treasuryOutflowFinding(prev, 399n, 200, [{ blockNumber: 150, amountUsdc: "600" }], addr)?.severity, "crit", "one unit more than explained");
  assert.equal(treasuryOutflowFinding(prev, 0n, 200, [], addr)?.key, "treasury:unexplained-outflow");
});

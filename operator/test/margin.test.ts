import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { utils } from "ethers";
import { DEBT_BOUND_MARGIN_BP, evaluateMargin, liquidationErrorCode, marginConfigIface, marginExecutorIface, marginFindings, marginLiquidatorIface, marginRiskIface, marginUnrecoverableUsd, MarginStatus, MIN_SEIZE_VALUE_BPS, planMarginRepay, repaidInWindow, revertData } from "../src/margin";
import type { MarginEval, MarginMetrics, MarginPosition } from "../src/margin";
import { validateConfig } from "../src/config";
import { unrecoverableDebt } from "../src/backing";
import { decidedConfig, A } from "./fixtures";

const U = (n: number) => BigInt(Math.round(n * 1e6));
const E18 = 10n ** 18n;
const pos = (over: Partial<MarginPosition> = {}): MarginPosition => ({ id: 1n, owner: A(0xa1), account: A(0xa2), marginPToken: A(0x12), positionPToken: A(0x11), debtPToken: A(0x12), borrowedPrincipal: U(2450), side: 0, status: MarginStatus.ACTIVE, ...over });
const met = (gross: number, debt: number, healthBps: number): MarginMetrics => ({ grossAssetValueUsd: BigInt(gross) * E18, debtValueUsd: BigInt(debt) * E18, equityUsd: (BigInt(gross) - BigInt(debt)) * E18, maintenanceRequirementUsd: (BigInt(gross) * E18) / 4n, healthFactorBps: BigInt(healthBps) });

// ---------------------------------------------------------------- sizing
const base = { debt: U(2450), inventory: U(3750), dailyCap: U(2500), repaidToday: 0n, perCallCap: U(1500), minRepay: U(1) };
test("margin plan: the bound is the smallest of inventory, daily-cap remaining, per-call cap and debt, and the binding one is named", () => {
  assert.deepEqual(planMarginRepay(base), { maxRepay: U(1500), bound: "per-call-cap" });
  assert.deepEqual(planMarginRepay({ ...base, inventory: U(900) }), { maxRepay: U(900), bound: "inventory" });
  assert.deepEqual(planMarginRepay({ ...base, repaidToday: U(2000) }), { maxRepay: U(500), bound: "daily-cap" });
  const d = planMarginRepay({ ...base, debt: U(700) });
  assert.equal(d.bound, "debt");
  assert.equal(d.maxRepay, U(700) + (U(700) * DEBT_BOUND_MARGIN_BP) / 10_000n + 1n, "the debt bound carries the interest margin: a full liquidation repays the debt as it is at the block of the call");
  assert.ok(d.maxRepay > U(700) && d.maxRepay < U(700) + U(1), "...and the margin is small (10 bp)");
});
test("margin plan: the daily cap used up, an empty inventory or no debt means NO repayment (never a smaller surprise one)", () => {
  assert.equal(planMarginRepay({ ...base, repaidToday: U(2500) }).maxRepay, 0n);
  assert.equal(planMarginRepay({ ...base, repaidToday: U(9999) }).maxRepay, 0n, "over the cap is still zero, not negative");
  assert.equal(planMarginRepay({ ...base, inventory: 0n }).maxRepay, 0n);
  assert.equal(planMarginRepay({ ...base, debt: 0n }).maxRepay, 0n);
  const below = planMarginRepay({ ...base, inventory: U(1) - 1n });
  assert.equal(below.maxRepay, 0n);
  assert.equal(below.bound, "inventory");
  assert.match(below.reason ?? "", /below the minimum/);
});
test("margin plan: rolling 24 h window", () => {
  const rounds = [{ ts: 1_000, positionId: "1", repay: U(100).toString() }, { ts: 80_000, positionId: "2", repay: U(200).toString() }];
  assert.equal(repaidInWindow(rounds, 86_400), U(300), "now = 86,400: the round at t=1,000 is 85,400 s old, inside; both count");
  assert.equal(repaidInWindow(rounds, 86_400 + 1_000), U(200), "now = 87,400: the round at t=1,000 is exactly 86,400 s old and is outside the window");
  assert.equal(repaidInWindow(rounds, 200_000), 0n);
});

// ---------------------------------------------------------------- classification of a position
test("margin verdicts: INACTIVE / STUCK / UNPRICED / HEALTHY / WATCH / LIQUIDATABLE / INSOLVENT", () => {
  const w = 13_000;
  assert.equal(evaluateMargin(pos({ status: MarginStatus.CLOSED }), undefined, undefined, w), "INACTIVE");
  assert.equal(evaluateMargin(pos({ status: MarginStatus.LIQUIDATED }), undefined, undefined, w), "INACTIVE");
  for (const s of [MarginStatus.OPENING, MarginStatus.CLOSING, MarginStatus.LIQUIDATING]) assert.equal(evaluateMargin(pos({ status: s }), undefined, undefined, w), "STUCK");
  assert.equal(evaluateMargin(pos(), undefined, undefined, w), "UNPRICED");
  assert.equal(evaluateMargin(pos(), met(5000, 2500, 20_000), undefined, w), "UNPRICED", "metrics without the flag is still unknown");
  assert.equal(evaluateMargin(pos(), met(5000, 2500, 20_000), false, w), "HEALTHY");
  assert.equal(evaluateMargin(pos(), met(5000, 0, 99_999), false, w), "HEALTHY", "no debt is healthy whatever the ratio");
  assert.equal(evaluateMargin(pos(), met(5000, 3800, 12_000), false, w), "WATCH");
  assert.equal(evaluateMargin(pos(), met(3300, 2500, 9_000), true, w), "LIQUIDATABLE");
  assert.equal(evaluateMargin(pos(), met(2400, 2500, 0), true, w), "INSOLVENT");
  assert.equal(evaluateMargin(pos(), met(2500, 2500, 0), true, w), "INSOLVENT", "equity exactly zero is insolvent for a break-even operator");
  assert.equal(evaluateMargin(pos(), met(2400, 2500, 0), false, w), "INSOLVENT", "insolvent even if the engine flag were false");
});
test("margin unrecoverable value: debt beyond collateral / (1 + bonus); zero unless liquidatable or insolvent", () => {
  const e = (verdict: MarginEval["verdict"], gross: number, debt: number): MarginEval => ({ position: pos(), verdict, metrics: met(gross, debt, 0), bonusBps: 500 });
  assert.equal(marginUnrecoverableUsd(e("INSOLVENT", 2100, 2500)), 2500n * E18 - (2100n * E18 * 10_000n) / 10_500n);
  assert.equal(marginUnrecoverableUsd(e("LIQUIDATABLE", 3300, 2500)), 0n, "collateral covers debt plus bonus: nothing unrecoverable");
  assert.equal(marginUnrecoverableUsd(e("HEALTHY", 100, 2500)), 0n);
  const exact = marginUnrecoverableUsd(e("LIQUIDATABLE", 2625, 2500));
  assert.equal(exact, 0n, "2,625 / 1.05 = 2,500: exactly covered");
});
test("backing: margin's own unrecoverable value is added, and an unvaluable margin position makes the figure INCOMPLETE", () => {
  const none = unrecoverableDebt([], 108n * 10n ** 16n, 0n);
  assert.equal(none.rawUsd, 0n);
  const withMargin = unrecoverableDebt([], 108n * 10n ** 16n, 100n * E18, { rawUsd: 300n * E18, complete: true });
  assert.equal(withMargin.rawUsd, 300n * E18);
  assert.equal(withMargin.unrecoverableUsd, 200n * E18, "reserves are deducted");
  assert.equal(unrecoverableDebt([], 108n * 10n ** 16n, 0n, { rawUsd: 0n, complete: false }).complete, false);
});

// ---------------------------------------------------------------- findings
test("margin findings: LIQUIDATABLE is for the operators; INSOLVENT is critical, escalates and goes to the treasury signers as a human decision; nothing is a payment", () => {
  const ev = (verdict: MarginEval["verdict"], id: bigint, m?: MarginMetrics): MarginEval => ({ position: pos({ id }), verdict, metrics: m, bonusBps: 500 });
  const f = marginFindings([ev("LIQUIDATABLE", 1n, met(3300, 2500, 9000)), ev("INSOLVENT", 2n, met(2000, 2500, 0)), ev("WATCH", 3n, met(5000, 3800, 12_000)), ev("UNPRICED", 4n), ev("STUCK", 5n), ev("HEALTHY", 6n, met(5000, 2500, 20_000))], { unknownFlags: [], accountsNotFlagged: [], hookOk: true, operatorsNotFunders: [] });
  const by = Object.fromEntries(f.map((x) => [x.key, x]));
  assert.equal(by["margin:1:LIQUIDATABLE"]!.audience, "liquidators");
  assert.equal(by["margin:2:INSOLVENT"]!.severity, "crit");
  assert.equal(by["margin:2:INSOLVENT"]!.escalates, true);
  assert.equal(by["margin:2:INSOLVENT"]!.audience, "treasury-signers");
  assert.match(by["margin:2:INSOLVENT"]!.message, /DECLINES/);
  assert.match(by["margin:2:INSOLVENT"]!.message, /insurance fund is not used/);
  assert.equal(by["margin:5:STUCK"]!.severity, "crit");
  assert.equal(by["margin:6:HEALTHY"], undefined, "healthy positions raise nothing");
  assert.equal(f.length, 5);
});
test("margin findings: wiring problems (unflagged account, hook drift, an operator that is not a funder, unreadable flag)", () => {
  const f = marginFindings([], { unknownFlags: [A(9)], accountsNotFlagged: [A(8)], hookOk: false, operatorsNotFunders: ["op-b"] });
  assert.deepEqual(f.map((x) => x.key).sort(), ["margin:account-not-flagged", "margin:classification-unreadable", "margin:hook-drift", "margin:not-funder:op-b"]);
  assert.equal(f.find((x) => x.key === "margin:account-not-flagged")!.severity, "crit");
  assert.equal(f.find((x) => x.key === "margin:hook-drift")!.severity, "crit");
});

// ---------------------------------------------------------------- revert decoding
const liqErr = (code: number) => marginLiquidatorIface.encodeErrorResult("LiquidationError", [code]);
test("LiquidationError codes are decoded from the places ethers v5 and the providers put revert data", () => {
  assert.equal(liquidationErrorCode({ data: liqErr(32) }), 32);
  assert.equal(liquidationErrorCode({ error: { data: liqErr(28) } }), 28);
  assert.equal(liquidationErrorCode({ error: { error: { data: liqErr(27) } } }), 27);
  assert.equal(liquidationErrorCode({ body: JSON.stringify({ error: { code: 3, data: liqErr(32) } }) }), 32);
  assert.equal(liquidationErrorCode(new Error("execution reverted")), undefined);
  assert.equal(liquidationErrorCode({ data: "0x08c379a0" + "00".repeat(40) }), undefined, "a different error is not a LiquidationError");
  assert.equal(revertData({ a: 1 }), undefined);
  const cyc: any = { data: undefined };
  cyc.error = cyc;
  assert.equal(revertData(cyc), undefined, "cyclic error objects terminate");
});
test("the break-even floor is a constant of 10,000 bp", () => {
  assert.equal(MIN_SEIZE_VALUE_BPS, 10_000);
});

// ---------------------------------------------------------------- configuration
const withMargin = (over: any = {}): any => {
  const c = decidedConfig();
  c.margin = { enabled: true, executor: A(0x301), liquidator: A(0x302), riskEngine: A(0x303), config: A(0x304), watchHealthBps: 13_000, liquidation: { enabled: true, dailyRepayCapUsdc: 2500, maxRepayPerCallUsdc: 1500, minRepayUsdc: 1, retryCooldownSeconds: 30, insolventCooldownSeconds: 600 }, ...over };
  c.executor.enabled = true;
  c.keeper.enabled = false;
  return c;
};
test("config: the margin block is optional (old configurations still load) and the template ships it disabled", () => {
  const c = decidedConfig();
  delete c.margin;
  assert.equal(validateConfig(c).problems.length, 0);
  const t = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "config", "pilot.example.json"), "utf8"));
  assert.equal(t.margin.enabled, false);
  assert.equal(t.margin.liquidation.enabled, false);
  assert.equal(validateConfig(withMargin()).problems.length, 0);
});
test("config: an enabled margin block with placeholders, bad caps, or without the executor is REFUSED", () => {
  const bad = (c: any) => validateConfig(c).problems.map((p) => p.path);
  assert.ok(bad(withMargin({ executor: "UNSET" })).includes("margin.executor"));
  assert.ok(bad(withMargin({ riskEngine: "0x" + "0".repeat(40) })).includes("margin.riskEngine"));
  assert.ok(bad(withMargin({ watchHealthBps: 9_000 })).includes("margin.watchHealthBps"), "the watch level must be above the 100% liquidation line");
  const l = (x: any) => ({ liquidation: { enabled: true, dailyRepayCapUsdc: 2500, maxRepayPerCallUsdc: 1500, minRepayUsdc: 1, retryCooldownSeconds: 30, insolventCooldownSeconds: 600, ...x } });
  assert.ok(bad(withMargin(l({ maxRepayPerCallUsdc: 3000 }))).includes("margin.liquidation.maxRepayPerCallUsdc"), "a per-call bound above the daily cap makes the daily cap meaningless");
  assert.ok(bad(withMargin(l({ minRepayUsdc: 2000 }))).includes("margin.liquidation.minRepayUsdc"));
  assert.ok(bad(withMargin(l({ dailyRepayCapUsdc: "UNSET" }))).includes("margin.liquidation.dailyRepayCapUsdc"));
  const noExec = withMargin();
  noExec.executor.enabled = false;
  assert.ok(bad(noExec).includes("margin.liquidation.enabled"), "the margin step lives in the executor process");
  const off = withMargin({ enabled: false, executor: "UNSET" });
  assert.equal(validateConfig(off).problems.length, 0, "a disabled block is not validated");
});

// ---------------------------------------------------------------- ABI coverage
test("every function the margin read layer and the margin step encode or decode is in the ABI they use", () => {
  const ifaces: Record<string, utils.Interface> = { marginExecutorIface, marginRiskIface, marginLiquidatorIface, marginConfigIface };
  for (const f of ["margin.ts", "executor.ts", "monitor.ts"]) {
    const text = fs.readFileSync(path.join(__dirname, "..", "..", "src", f), "utf8");
    for (const m of text.matchAll(/(marginExecutorIface|marginRiskIface|marginLiquidatorIface|marginConfigIface)\.(?:encodeFunctionData|decodeFunctionResult)\("([A-Za-z0-9_]+)"/g)) {
      assert.doesNotThrow(() => ifaces[m[1]!]!.getFunction(m[2]!), `${f}: ${m[1]}.${m[2]}`);
    }
    for (const m of text.matchAll(/iface: (marginExecutorIface|marginRiskIface), fn: "([A-Za-z0-9_]+)"/g)) assert.doesNotThrow(() => ifaces[m[1]!]!.getFunction(m[2]!), `${f}: ${m[1]}.${m[2]}`);
  }
});

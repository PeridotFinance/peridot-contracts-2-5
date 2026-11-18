import test from "node:test";
import assert from "node:assert/strict";
import { requireValidConfig, validateConfig, oracleAllowList, assertOracleAllowed } from "../src/config";
import type { MonitorConfig } from "../src/config";
import { readBlockSnapshot } from "../src/chain";
import { executorStep, emptyExecutorState } from "../src/executor";
import { keeperStep, emptyKeeperState, KeeperState } from "../src/keeper";
import { runCycle, emptyMonitorState } from "../src/monitor";
import { AlertManager, MemorySink } from "../src/alerts";
import { Verdict } from "../src/detect";
import { chooseCollateralRoute, checkNetSeizeValue, fitRepayToSeize, liquidatorSeizeTokens, planShareRepay, pTokenValueUsdc, shareRepaidInWindow } from "../src/share";
import { decidedConfig, A } from "./fixtures";
import { ADDR, MockChain, WAVAX_PRICE } from "./mockchain";

const U = (n: number) => BigInt(Math.round(n * 1e6));
const E18 = 10n ** 18n;

// ------------------------------------------------------------------ the oracle allow-list
const dep = { oracle: ADDR.guarded, oracleWrapper: ADDR.wrapper };

test("oracle allow-list: exactly the guarded oracle and the configured wrapper (case-insensitive); anything else fails closed", () => {
  assert.deepEqual(oracleAllowList(dep), [ADDR.guarded.toLowerCase(), ADDR.wrapper.toLowerCase()]);
  assert.doesNotThrow(() => assertOracleAllowed(dep, ADDR.guarded), "the old guarded oracle (before the swap)");
  assert.doesNotThrow(() => assertOracleAllowed(dep, ADDR.wrapper.toUpperCase().replace("0X", "0x")), "the wrapper (after the swap)");
  assert.throws(() => assertOracleAllowed(dep, A(0x999)), /neither the configured guarded oracle nor the configured oracle wrapper/);
  // before the wrapper is configured: only the guarded oracle (the previous behaviour)
  assert.deepEqual(oracleAllowList({ oracle: ADDR.guarded }), [ADDR.guarded.toLowerCase()]);
  assert.throws(() => assertOracleAllowed({ oracle: ADDR.guarded }, ADDR.wrapper), /fails closed/);
});

test("oracle allow-list in the read layer: the same build reads before AND after the swap, and refuses a third oracle", async () => {
  const cfg = requireValidConfig(withWrapper());
  for (const which of ["guarded", "wrapper"] as const) {
    const chain = new MockChain();
    chain.oracle = ADDR[which];
    chain.accounts[ADDR.borrower.toLowerCase()] = { debt: U(100), pShare: 10n ** 12n, shortfall: true };
    const snap = await readBlockSnapshot({ provider: chain.provider(), cfg, poolIdentityOk: true }, chain.block);
    assert.equal(snap.oracleAddress!.toLowerCase(), ADDR[which].toLowerCase());
    assert.equal(snap.markets.length, 3);
    assert.deepEqual(snap.oraclePrices, [WAVAX_PRICE, 10n ** 30n, 102n * 10n ** 28n], `every pToken (existing two and the share market) priced through the ${which}`);
  }
  const chain = new MockChain();
  chain.oracle = A(0x777);
  await assert.rejects(readBlockSnapshot({ provider: chain.provider(), cfg, poolIdentityOk: true }, chain.block), /neither the configured guarded oracle nor the configured oracle wrapper/);
  // an old config (no wrapper) still refuses the wrapper: the swap must not happen before the hosts carry the wrapper address
  const old = requireValidConfig(withWrapper(false, false));
  const c2 = new MockChain();
  c2.oracle = ADDR.wrapper;
  await assert.rejects(readBlockSnapshot({ provider: c2.provider(), cfg: old, poolIdentityOk: true }, c2.block), /fails closed/);
});

// ------------------------------------------------------------------ configuration
function withWrapper(wrapper = true, liquidation = true): any {
  const c = decidedConfig();
  c.deployment = { controller: ADDR.controller, pWavax: ADDR.pWavax, pUsdc: ADDR.pUsdc, oracle: ADDR.guarded, deploymentBlock: 99_000_000 };
  if (wrapper) c.deployment.oracleWrapper = ADDR.wrapper;
  c.operators = [{ name: "op-a", address: ADDR.operator }, { name: "op-b", address: A(0x102) }];
  c.executor.enabled = true;
  c.keeper.enabled = false;
  c.executor.convertToUsdc = false;
  c.shareCollateral = { pToken: ADDR.pShare, underlying: ADDR.vault, liquidation: { enabled: liquidation, maxRepayPerCallUsdc: 60, dailyRepayCapUsdc: 100, minRepayUsdc: 1, retryCooldownSeconds: 30, maxHeldValueUsdc: 200 } };
  return c;
}

test("config: the wrapper address and the share block are validated; everything is optional so existing host configs stay valid", () => {
  assert.ok(requireValidConfig(decidedConfig()), "an existing config without either block");
  assert.ok(requireValidConfig(withWrapper()));
  const bad = (mut: (x: any) => void, re: RegExp) => {
    const x = withWrapper();
    mut(x);
    const { problems } = validateConfig(x);
    assert.ok(problems.some((p) => re.test(p.path)), `${re}: ${JSON.stringify(problems)}`);
  };
  bad((x) => (x.deployment.oracleWrapper = "UNSET"), /deployment\.oracleWrapper/);
  bad((x) => (x.deployment.oracleWrapper = "0x1234"), /deployment\.oracleWrapper/);
  bad((x) => (x.deployment.oracleWrapper = x.deployment.oracle), /deployment\.oracleWrapper/);
  bad((x) => delete x.deployment.oracleWrapper, /shareCollateral\.liquidation\.enabled/); // the share market is priced only by the wrapper
  bad((x) => (x.shareCollateral.pToken = x.deployment.pUsdc), /shareCollateral\.pToken/);
  bad((x) => (x.shareCollateral.underlying = "UNSET"), /shareCollateral\.underlying/);
  bad((x) => (x.executor.enabled = false), /shareCollateral\.liquidation\.enabled/);
  bad((x) => (x.shareCollateral.liquidation.maxRepayPerCallUsdc = 101), /maxRepayPerCallUsdc/);
  bad((x) => (x.shareCollateral.liquidation.dailyRepayCapUsdc = 0), /dailyRepayCapUsdc/);
  bad((x) => delete x.shareCollateral.liquidation.maxHeldValueUsdc, /maxHeldValueUsdc/);
  bad((x) => (x.shareCollateral.liquidation.enabled = "yes"), /liquidation\.enabled/);
  // the treasury keeper host: the block present with the liquidation OFF needs no caps and no executor
  const k = withWrapper(true, false);
  k.executor.enabled = false;
  k.keeper.enabled = true;
  k.shareCollateral.liquidation = { enabled: false };
  assert.ok(requireValidConfig(k));
});

// ------------------------------------------------------------------ planning, caps, seize fit, break-even floor, route choice
const plan = (over: Partial<Parameters<typeof planShareRepay>[0]> = {}) =>
  planShareRepay({ debt: U(1000), closeFactor: 5n * 10n ** 17n, liquidationIncentive: 108n * 10n ** 16n, collateralUsdc: U(10_000), inventory: U(1000), dailyCap: U(100), repaidToday: 0n, perCallCap: U(60), minRepay: U(1), heldValueUsdc: 0n, maxHeldValueUsdc: U(200), ...over });

test("share plan: the per-call cap (60) binds first, then the rolling 24 h cap (100), the inventory, the collateral, the close factor and the held-value ceiling", () => {
  assert.deepEqual(plan(), { repay: U(60), bound: "per-call-cap" });
  assert.deepEqual(plan({ repaidToday: U(70) }), { repay: U(30), bound: "daily-cap" });
  assert.equal(plan({ repaidToday: U(100) }).repay, 0n, "daily cap used up");
  assert.equal(plan({ repaidToday: U(99.5) }).repay, 0n, "0.5 left is below the minimum repayment");
  assert.deepEqual(plan({ inventory: U(25) }), { repay: U(25), bound: "inventory" });
  assert.equal(plan({ inventory: U(0.5) }).repay, 0n);
  assert.deepEqual(plan({ debt: U(40) }), { repay: U(20), bound: "close-factor" });
  assert.deepEqual(plan({ collateralUsdc: U(30) }), { repay: (U(30) * 9_240n) / 10_000n, bound: "collateral" });
  assert.equal(plan({ collateralUsdc: 0n }).repay, 0n, "no seizable collateral");
  assert.equal(plan({ debt: 0n }).repay, 0n);
  // the operator never sells: no new seizure once what it holds (plus the new seize, about repay x LI) would pass the ceiling
  const held = plan({ heldValueUsdc: U(190) });
  assert.equal(held.bound, "held-value");
  assert.equal(held.repay, (U(10) * E18) / (108n * 10n ** 16n));
  assert.equal(plan({ heldValueUsdc: U(200) }).repay, 0n);
});

test("share plan: the daily window counts only share-route rounds of the last 24 h", () => {
  const r = (ts: number, repay: number, coll?: string) => ({ ts, repay: String(U(repay)), collateralPToken: coll });
  const rounds = [r(0, 30, ADDR.pShare), r(50_000, 20, ADDR.pShare.toUpperCase().replace("0X", "0x")), r(60_000, 40), r(80_000, 10, A(0x77))];
  assert.equal(shareRepaidInWindow(rounds, ADDR.pShare, 86_400), U(20), "the round at t=0 is exactly 24 h old and out; pWAVAX and other-market rounds do not count");
  assert.equal(shareRepaidInWindow(rounds, ADDR.pShare, 80_000), U(50));
});

test("seize fit: the controller's seize amount must be covered by the borrower's pTokens, else the repayment is cut proportionally (never above the balance)", () => {
  assert.equal(fitRepayToSeize({ repay: U(50), seizeTokens: 100n, balance: 100n, minRepay: U(1) }), U(50), "exactly covered: unchanged");
  const cut = fitRepayToSeize({ repay: U(50), seizeTokens: 200n, balance: 100n, minRepay: U(1) });
  assert.equal(cut, (U(25) * 9_990n) / 10_000n, "half the balance, minus the 10 bp margin");
  assert.equal(fitRepayToSeize({ repay: U(50), seizeTokens: 100_000n, balance: 100n, minRepay: U(1) }), 0n, "below the minimum: give up");
  assert.equal(fitRepayToSeize({ repay: U(50), seizeTokens: 0n, balance: 0n, minRepay: U(1) }), U(50));
});

test("break-even floor for a collateral the operator will not sell: the value of the pTokens received, net of the protocol seize share, must be >= the USDC repaid", () => {
  const ex = 2n * 10n ** 14n;
  const seize = (U(50) * (108n * 10n ** 16n) * 10n ** 30n) / (102n * 10n ** 28n * ex); // what the controller computes at LI 108%
  const ok = checkNetSeizeValue({ repay: U(50), seizeTokens: seize, protocolSeizeShareMantissa: 28n * 10n ** 15n, exchangeRate: ex, priceShare: 102n * 10n ** 28n, priceUsdc: 10n ** 30n });
  assert.equal(ok.ok, true);
  assert.ok(ok.valueUsdc > U(52) && ok.valueUsdc < U(53), `about 50 x 1.08 x 0.972 = 52.5 USDC, got ${ok.valueUsdc}`);
  assert.equal(liquidatorSeizeTokens(1000n, 28n * 10n ** 15n), 972n);
  const bad = checkNetSeizeValue({ repay: U(50), seizeTokens: seize, protocolSeizeShareMantissa: 10n * 10n ** 16n, exchangeRate: ex, priceShare: 102n * 10n ** 28n, priceUsdc: 10n ** 30n });
  assert.equal(bad.ok, false, "a protocol share of 10% turns 108% into 97%: declined");
  assert.equal(checkNetSeizeValue({ repay: U(50), seizeTokens: seize, protocolSeizeShareMantissa: 0n, exchangeRate: ex, priceShare: 0n, priceUsdc: 10n ** 30n }).ok, false, "no share price: declined");
  assert.equal(pTokenValueUsdc(5n * 10n ** 9n, ex, 10n ** 30n, 10n ** 30n), U(1), "50 pTokens at 0.0002 = 1 share = 1 USDC");
});

test("collateral route: accounts without share collateral (or with the route off) always take the pWAVAX path; mixed accounts take pWAVAX when it can pay a full close-factor repayment", () => {
  const b = { debt: U(100), closeFactor: 5n * 10n ** 17n, wavaxCollateralUsdc: U(1000), wavaxRepay: U(50), shareRepay: U(50), shareActive: true };
  assert.equal(chooseCollateralRoute({ ...b, shareActive: false }), "wavax");
  assert.equal(chooseCollateralRoute({ ...b, shareActive: false, wavaxRepay: 0n }), "none");
  assert.equal(chooseCollateralRoute(b), "wavax", "WAVAX alone is enough");
  assert.equal(chooseCollateralRoute({ ...b, wavaxCollateralUsdc: U(20), wavaxRepay: U(18.48), shareRepay: U(50) }), "share", "WAVAX nearly exhausted: shares clear more debt");
  assert.equal(chooseCollateralRoute({ ...b, wavaxCollateralUsdc: 0n, wavaxRepay: 0n }), "share", "share collateral only");
  assert.equal(chooseCollateralRoute({ ...b, wavaxCollateralUsdc: 0n, wavaxRepay: 0n, shareRepay: 0n }), "none");
  assert.equal(chooseCollateralRoute({ ...b, wavaxCollateralUsdc: U(20), wavaxRepay: U(18.48), shareRepay: U(18.48) }), "wavax", "ties go to the sellable collateral");
});

// ------------------------------------------------------------------ the executor against the mock chain
const lc = (a: string) => a.toLowerCase();
async function runExecutor(chain: MockChain, cfgRaw: any = withWrapper(), state = emptyExecutorState(), nowS = 1_700_000_100) {
  const cfg: MonitorConfig = requireValidConfig(cfgRaw);
  const sink = new MemorySink();
  const alerts = new AlertManager(sink, [3600]);
  let persisted = state;
  const out = await executorStep({ ctx: { provider: chain.provider(), cfg, poolIdentityOk: true }, signer: chain.signer(), alerts, slippageBoundBp: 100, accounts: async () => [ADDR.borrower, ADDR.other], persist: (s: any) => (persisted = s), now: () => nowS } as any, state);
  return { out, sink, persisted: out.state ?? persisted };
}
const shareBorrower = (chain: MockChain, debt = 100, shareUsd = 110): void => {
  chain.accounts[lc(ADDR.borrower)] = { debt: U(debt), pShare: (U(shareUsd) * E18) / (2n * 10n ** 14n) / 1n, shortfall: true };
};

test("executor: a share-collateral account is liquidated SEIZE-AND-KEEP: exact allowance, the seized pTokens kept, no redeem, no swap, inventory counts USDC only", async () => {
  const chain = new MockChain();
  shareBorrower(chain, 100, 110);
  const usdcBefore = chain.usdc[lc(ADDR.operator)]!;
  const { out, sink } = await runExecutor(chain);
  assert.equal(out.halted, false);
  assert.ok(out.round, JSON.stringify(out.skipped));
  const repay = U(50); // close factor 50% of 100, under the 60 per-call cap and the 92.4% collateral bound
  assert.equal(out.round!.repay, repay.toString());
  assert.equal(out.round!.collateralPToken!.toLowerCase(), lc(ADDR.pShare));
  assert.equal(out.round!.keptCollateral, true);
  const names = chain.sent.map((s) => s.name);
  assert.deepEqual(names, ["approve", "liquidateBorrow"], "approve exactly (the market consumes it all, nothing left to reset), liquidate: no redeem, no swap");
  assert.equal(chain.allowance, 0n, "allowance reset to 0");
  assert.equal(chain.usdc[lc(ADDR.operator)], usdcBefore - repay, "USDC left == repay");
  const seize = chain.seizeTokens(repay, ADDR.pShare);
  const kept = seize - (seize * chain.protocolShare) / E18;
  assert.equal(chain.poolBal(ADDR.pShare, ADDR.operator), kept, "the operator holds the seized pTokens");
  assert.equal(out.round!.seizedPTokens, kept.toString());
  assert.equal(chain.sent.some((s) => /redeem|exactInputSingle/.test(s.name)), false);
  const msg = sink.messages.find((m) => /SEIZE-AND-KEEP/.test(m.text))!;
  assert.ok(msg, "an alert says what was seized");
  assert.match(msg.text, new RegExp(`SEIZED ${kept} bpPHAR-USDC pTokens`));
  assert.match(msg.text, /KEPT them: no redeem, no swap/);
  assert.match(msg.text, /not counted as USDC inventory/);
});

test("executor: the per-call cap (60) and the rolling 24 h cap (100) bound the allowance; a used-up cap sends nothing and alerts", async () => {
  const chain = new MockChain();
  shareBorrower(chain, 1000, 2000);
  const r1 = await runExecutor(chain);
  assert.equal(r1.out.round!.repay, U(60).toString(), "per-call cap");
  assert.equal(chain.sent.find((s) => s.name === "approve")!.data.slice(-64), U(60).toString(16).padStart(64, "0"), "the allowance is exactly the repayment");
  // 70 USDC already repaid through the share route within 24 h: only 30 remain
  const chain2 = new MockChain();
  shareBorrower(chain2, 1000, 2000);
  const st = emptyExecutorState();
  st.rounds.push({ ts: 1_700_000_000, borrower: "0x", repay: U(70).toString(), seizedPTokens: "1", liquidateTx: "0x", collateralPToken: ADDR.pShare, keptCollateral: true });
  const r2 = await runExecutor(chain2, withWrapper(), st);
  assert.equal(r2.out.round!.repay, U(30).toString(), "daily cap remainder");
  // used up: nothing is sent, a crit alert is raised
  const chain3 = new MockChain();
  shareBorrower(chain3, 1000, 2000);
  const st3 = emptyExecutorState();
  st3.rounds.push({ ts: 1_700_000_000, borrower: "0x", repay: U(100).toString(), seizedPTokens: "1", liquidateTx: "0x", collateralPToken: ADDR.pShare, keptCollateral: true });
  const r3 = await runExecutor(chain3, withWrapper(), st3);
  assert.equal(r3.out.round, undefined);
  assert.equal(chain3.sent.length, 0, "nothing sent");
  assert.ok(r3.sink.messages.some((m) => m.severity === "crit" && /daily share-repayment cap is used up/.test(m.text)));
  // the rolling window: a round older than 24 h no longer counts
  const chain4 = new MockChain();
  shareBorrower(chain4, 1000, 2000);
  const st4 = emptyExecutorState();
  st4.rounds.push({ ts: 1_700_000_100 - 86_401, borrower: "0x", repay: U(100).toString(), seizedPTokens: "1", liquidateTx: "0x", collateralPToken: ADDR.pShare });
  assert.equal((await runExecutor(chain4, withWrapper(), st4)).out.round!.repay, U(60).toString());
});

test("executor: the held-value ceiling stops a seller-less operator from accumulating shares without bound", async () => {
  const chain = new MockChain();
  shareBorrower(chain, 1000, 2000);
  // the operator already holds 200 USDC worth of share pTokens (the configured ceiling)
  chain.pBal[lc(ADDR.pShare)] = { [lc(ADDR.operator)]: (U(200) * E18) / (2n * 10n ** 14n) };
  const r = await runExecutor(chain);
  assert.equal(r.out.round, undefined);
  assert.equal(chain.sent.length, 0);
  assert.ok(r.sink.messages.some((m) => /already holds shares up to its ceiling/.test(m.text)));
});

test("executor: the pWAVAX path is unchanged for accounts without share collateral (same calldata as before the share route existed)", async () => {
  const chain = new MockChain();
  chain.accounts[lc(ADDR.borrower)] = { debt: U(100), pWavax: (U(110) * 10n ** 30n * E18) / (WAVAX_PRICE * 2n * 10n ** 26n) / 1n, shortfall: true };
  const r = await runExecutor(chain);
  assert.ok(r.out.round, JSON.stringify(r.out.skipped));
  assert.equal(r.out.round!.collateralPToken, undefined);
  const liq = chain.sent.find((s) => s.name === "liquidateBorrow")!;
  assert.match(liq.data, new RegExp(ADDR.pWavax.slice(2).toLowerCase() + "$"), "collateral = pWAVAX");
  assert.equal(chain.sent.some((s) => s.data.toLowerCase().includes(ADDR.pShare.slice(2).toLowerCase())), false, "the share market is never touched");
});

test("executor: before the market is listed, or with the route disabled, an account is handled exactly as before (the build runs ahead of the listing)", async () => {
  const c1 = new MockChain();
  c1.listShare = false;
  shareBorrower(c1);
  const r1 = await runExecutor(c1);
  assert.equal(r1.out.round, undefined);
  assert.equal(c1.sent.length, 0);
  const c2 = new MockChain();
  shareBorrower(c2);
  const r2 = await runExecutor(c2, withWrapper(true, false));
  assert.equal(r2.out.round, undefined);
  assert.equal(c2.sent.length, 0, "route disabled: nothing is sent");
});

test("executor: an unpriced share market (the wrapper returns 0), a wrong underlying, or a declined break-even all keep the route OFF without sending anything", async () => {
  const c1 = new MockChain();
  shareBorrower(c1);
  c1.prices[lc(ADDR.pShare)] = 0n;
  const r1 = await runExecutor(c1);
  assert.equal(c1.sent.length, 0);
  assert.ok(r1.sink.messages.some((m) => /no price for the share market/.test(m.text)));
  const c2 = new MockChain();
  shareBorrower(c2);
  c2.vaultUnderlying = A(0x999);
  const r2 = await runExecutor(c2);
  assert.equal(c2.sent.length, 0);
  assert.ok(r2.sink.messages.some((m) => m.severity === "crit" && /not the configured/.test(m.text)));
  const c3 = new MockChain();
  shareBorrower(c3);
  c3.protocolShare = 15n * 10n ** 16n; // 15% protocol seize share: 108% x 85% < 100%
  const r3 = await runExecutor(c3);
  assert.equal(c3.sent.length, 0, "declined before any approval");
  assert.ok(r3.sink.messages.some((m) => /break-even floor/.test(m.text)));
});

test("executor: a failed simulation resets the allowance (nothing was sent), a read-back mismatch HALTS", async () => {
  const c1 = new MockChain();
  shareBorrower(c1);
  c1.simulateCode = 3n;
  const r1 = await runExecutor(c1);
  assert.equal(r1.out.round, undefined);
  assert.deepEqual(c1.sent.map((s) => s.name), ["approve", "approve"], "approve then reset, never a liquidation");
  assert.equal(c1.allowance, 0n);
  const c2 = new MockChain();
  shareBorrower(c2);
  c2.shortReceive = 1n; // the operator receives one pToken unit less than the event says
  const r2 = await runExecutor(c2);
  assert.equal(r2.out.halted, true);
  assert.ok(r2.persisted.halted, "halt persisted");
  assert.match(r2.persisted.halted!.reason, /read-back failed.*pToken delta/);
  assert.equal(c2.allowance, 0n);
});

// ------------------------------------------------------------------ the monitor and the treasury keeper
test("monitor: an account with share collateral gets the ALERT-ONLY finding, is flagged in the report, and does not trigger the unknown-price page", async () => {
  const chain = new MockChain();
  shareBorrower(chain, 100, 110);
  chain.accounts[lc(ADDR.other)] = { debt: U(10), pWavax: 10n ** 12n, shortfall: false };
  const cfg = requireValidConfig(withWrapper());
  const sink = new MemorySink();
  const alerts = new AlertManager(sink, [3600]);
  const { report } = await runCycle({ provider: chain.provider(), cfg, poolIdentityOk: true }, emptyMonitorState(cfg), alerts, { extraAccounts: [ADDR.borrower, ADDR.other], hooks: undefined });
  const b = report.accounts.find((a) => a.account === lc(ADDR.borrower))!;
  const o = report.accounts.find((a) => a.account === lc(ADDR.other))!;
  assert.equal(b.shareCollateral, true);
  assert.equal(b.shareShortfall, true);
  assert.equal(o.shareCollateral, undefined, "other accounts are untouched");
  const f = report.findings.find((x) => x.key === `acct:${lc(ADDR.borrower)}:share-collateral`)!;
  assert.ok(f, "finding raised");
  assert.equal(f.severity, "crit");
  assert.match(f.message, /ALERT-ONLY.*will NOT repay this account automatically/);
  assert.equal(report.findings.some((x) => x.key === "unknown-price"), false, "the missing share reference is expected, not an outage");
  assert.notEqual(b.verdictCode, Verdict.DEFAULT_EXHAUSTED, "the rule itself can never fire for it (no reference price for the share market)");
});

test("treasury keeper: ALERT-ONLY for an account with share collateral even if a report says DEFAULT_EXHAUSTED; other accounts behave as before", async () => {
  const kc = withWrapper(true, false);
  kc.executor.enabled = false;
  kc.keeper.enabled = true;
  kc.shareCollateral.liquidation = { enabled: false };
  const cfg: MonitorConfig = requireValidConfig(kc);
  const sent: string[] = [];
  const signer: any = { getAddress: async () => cfg.treasury.address, sendTransaction: async () => { sent.push("tx"); throw new Error("must not send"); } };
  const providerCalls: string[] = [];
  const provider: any = new Proxy({}, { get: (_t, p) => async () => { providerCalls.push(String(p)); throw new Error("must not read the chain"); } });
  const raised: string[] = [];
  const alerts: any = { raise: async (f: any) => { raised.push(f.key); return []; }, clear: async () => {} };
  const rep = (accounts: any[]): any => ({
    blockNumber: 100, blockTimestamp: 1_000, blind: false, indexBehindBlocks: 0, counts: {}, findings: [], alertsSent: [], reference: { status: "ok", detail: "" }, expectedTreasuryCall: "0",
    unrecoverableDebt: { usd: "0", rawUsd: "0", reservesUsd: "0", complete: true }, margin: { classified: 0, unknownFlags: [], positions: [] }, accounts,
  });
  const share = { account: A(0xaa), verdict: "DEFAULT_EXHAUSTED", verdictCode: Verdict.DEFAULT_EXHAUSTED, debtUnits: "50000000", debtUsd: "0", collUsd: "0", maxRecoveryUsd: "0", shortfallUsd: "0", shareCollateral: true, shareShortfall: true };
  const plain = { ...share, account: A(0xbb), shareCollateral: undefined, shareShortfall: undefined };
  // a state in which BOTH accounts already have enough confirmations: only the share account must be refused outright
  const confirmed: KeeperState = { ...emptyKeeperState(), seen: { [A(0xaa)]: { count: 9, firstAt: 1, lastAt: 999, lastBlock: 99 }, [A(0xbb)]: { count: 1, firstAt: 1_000, lastAt: 1_000, lastBlock: 99 } } };
  const o = await keeperStep({ ctx: { cfg, provider } as any, signer, alerts, persist: () => {} } as any, confirmed, rep([share, plain]));
  assert.equal(o.paid.length, 0);
  assert.equal(sent.length, 0, "no transaction");
  assert.equal(providerCalls.length, 0, "the share account never reached the execution path (no chain read, no approval)");
  const shareSkip = o.skipped.find((s) => s.account === A(0xaa))!;
  assert.match(shareSkip.reason, /^ALERT-ONLY \(vault-share collateral\).*will NOT repay this account automatically.*human decision/);
  assert.equal(o.state.seen[A(0xaa).toLowerCase()], undefined, "no confirmation is ever accumulated for it");
  const plainSkip = o.skipped.find((s) => s.account === A(0xbb))!;
  assert.match(plainSkip.reason, /awaiting confirmation/, "a plain DEFAULT_EXHAUSTED account is treated exactly as before");
  assert.equal(raised.length, 0);
  // the execution-time re-check is independent of the report flag: see keeper.ts payOne (covered by the fork suite); here the flagged account was excluded before it
});

test("treasury keeper: the execution-time re-check refuses a share-collateral account even when the report did not flag it (nothing approved, nothing sent)", async () => {
  const chain = new MockChain();
  shareBorrower(chain, 100, 110);
  const kc = withWrapper(true, false);
  kc.executor.enabled = false;
  kc.keeper.enabled = true;
  kc.shareCollateral.liquidation = { enabled: false };
  const cfg: MonitorConfig = requireValidConfig(kc);
  const signer = chain.signer();
  signer.getAddress = async () => cfg.treasury.address;
  const raised: string[] = [];
  const alerts: any = { raise: async (f: any) => { raised.push(f.message); return []; }, clear: async () => {}, notify: async () => ({}) };
  const report: any = {
    blockNumber: 100, blockTimestamp: 1_700_000_000, blind: false, indexBehindBlocks: 0, counts: {}, findings: [], alertsSent: [], reference: { status: "ok", detail: "" }, expectedTreasuryCall: "0",
    unrecoverableDebt: { usd: "0", rawUsd: "0", reservesUsd: "0", complete: true }, margin: { classified: 0, unknownFlags: [], positions: [] },
    accounts: [{ account: ADDR.borrower, verdict: "DEFAULT_EXHAUSTED", verdictCode: Verdict.DEFAULT_EXHAUSTED, debtUnits: "100000000", debtUsd: "0", collUsd: "0", maxRecoveryUsd: "0", shortfallUsd: "0" }],
  };
  const st: KeeperState = { ...emptyKeeperState(), seen: { [ADDR.borrower.toLowerCase()]: { count: 9, firstAt: 1, lastAt: 999, lastBlock: 99 } } };
  const o = await keeperStep({ ctx: { cfg, provider: chain.provider(), poolIdentityOk: true } as any, signer, alerts, persist: () => {}, now: () => 1_700_000_100 } as any, st, report);
  assert.equal(o.paid.length, 0);
  assert.equal(chain.sent.length, 0, "no approval, no repayment");
  assert.ok(raised.some((m) => /ALERT-ONLY \(vault-share collateral\)/.test(m) && /did NOT pay/.test(m)), raised.join(" | "));
  assert.equal(o.halted, false);
});

// The treasury TRUTH TABLE (treasury document 2.2, 17 rows) reproduced THROUGH THE MONITOR: the full `runCycle` path (borrower index from
// events, block-pinned multicall reads with accrual first, reference price from the TWAP pool, the rule, health checks, alerts) against a
// local anvil fork of Avalanche C-Chain at block 99,200,000, with the same fixture as the Foundry test `testDetect_TruthTable_...`:
// PW40, cap USD 5,000, three full-power borrowers, one half-power borrower, one debt-free account, 30 days of interest, AVAX -20% / -75%,
// liquidation to exhaustion, a stale price, a zero answer, a treasury repayment.
// Differences from the Foundry run, stated: accounts act through impersonation on a local fork (no key anywhere); every transaction mines a
// block (a few blocks of extra interest); the independent reference is the TWAP of a MOCK pool whose tick is set to the same price (so its
// value is quantised to 1 bp); the controller is the pilot's opt-in no-reward-token build. Verdicts are compared EXACTLY, amounts within 5 bp.
import test from "node:test";
import assert from "node:assert/strict";
import { BigNumber, Contract, utils } from "ethers";
import { AVAX_FEED, USDC, USDC_FEED, WAVAX } from "../../src/constants";
import { AlertManager, MemorySink } from "../../src/alerts";
import { checkPoolIdentity } from "../../src/reference";
import { requireValidConfig } from "../../src/config";
import type { MonitorConfig } from "../../src/config";
import { emptyMonitorState, runCycle } from "../../src/monitor";
import { crossCheckIndex } from "../../src/borrowers";
import type { CycleReport, MonitorState } from "../../src/monitor";
import { Verdict, VERDICT_NAMES } from "../../src/detect";
import { art, artifacts, deployCashOnly, ForkChain, Mocks, rpcAvailable } from "./harness";
import type { Deployed } from "./harness";

const SKIP = !rpcAvailable() ? "AVALANCHE_MAINNET_RPC_URL not set (no archive endpoint): fork tests are SKIPPED, not passed" : !artifacts().present ? "forge artifacts missing: run `npm run build:contracts` first" : false;

const E18 = BigNumber.from(10).pow(18);
const ADMIN = "0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD"; // the operator's Ledger address; IMPERSONATED on the local fork only
const LP = "0x0000000000000000000000000000000000001001";
const CAROL = "0x00000000000000000000000000000000000CA201";
const TREASURY = "0x0000000000000000000000000000000000007EA5";
const HEALTHY_ACCT = "0x0000000000000000000000000000000000004EA1";
const NO_DEBT_ACCT = "0x00000000000000000000000000000000000040DB";
const OP_A = "0x0000000000000000000000000000000000000a01";
const OP_B = "0x0000000000000000000000000000000000000a02";
const borrower = (i: number) => utils.getAddress("0x" + (0x9000 + i).toString(16).padStart(40, "0"));
const CAP_USD = 5_000;
const CF = utils.parseEther("0.40"); // PW40, as the Foundry truth table
const DUST_USD6 = 10_000;

const erc20Abi = ["function balanceOf(address) view returns (uint256)", "function approve(address,uint256) returns (bool)"];

test("monitor reproduces the treasury truth table on a mainnet fork", { skip: SKIP, timeout: 3_000_000 }, async (t) => {
  const chain = await ForkChain.start();
  t.after(() => chain.stop());
  await chain.send("anvil_setBlockTimestampInterval", [1]); // deterministic: one second per block, no wall-clock drift
  for (const a of [ADMIN, LP, CAROL, TREASURY, HEALTHY_ACCT, NO_DEBT_ACCT, OP_A, OP_B, ...[0, 1, 2].map(borrower)]) await chain.setBalance(a);
  const mocks = new Mocks(chain, ADMIN);
  const usdcErc = new Contract(USDC, erc20Abi, chain.provider);
  const wavaxErc = new Contract(WAVAX, erc20Abi, chain.provider);

  // ------------------------------------------------------------ real prices at the pin, then the mocks take over
  const feedRead = new Contract(AVAX_FEED, ["function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)"], chain.provider);
  const realAvax: BigNumber = (await feedRead.latestRoundData())[1];
  const usdcRead = new Contract(USDC_FEED, ["function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)"], chain.provider);
  const usdcAnswer: BigNumber = (await usdcRead.latestRoundData())[1];
  await mocks.install();
  let avaxAnswer = realAvax;
  const refresh = async (poolLiquidity = BigNumber.from("1000000000000"), observeReverts = false, refUsd?: number) => {
    const now = await chain.now();
    await (await mocks.feed(AVAX_FEED).set(avaxAnswer, now)).wait();
    await (await mocks.feed(USDC_FEED).set(usdcAnswer, now)).wait();
    // the independent reference = the same price, expressed as a mean tick of the (mock) 0.05% pool; 1 tick = 1 bp
    const usd = refUsd ?? Number(avaxAnswer.toString()) / 1e8 / (Number(usdcAnswer.toString()) / 1e8);
    const tick = Math.round(Math.log(usd * 1e-12) / Math.log(1.0001));
    await (await mocks.pool().set(tick, poolLiquidity, observeReverts)).wait();
  };
  await refresh();
  const setAvaxBps = async (bps: number) => {
    avaxAnswer = realAvax.mul(bps).div(10_000);
    await refresh();
  };

  // ------------------------------------------------------------ deployment (pilot controller: opt-in, no reward token) and PW40 setup
  const d: Deployed = await deployCashOnly(chain, ADMIN);
  const admin = chain.signer(ADMIN);
  const ctrl: any = d.controller.connect(admin);
  const pU = (who: string) => d.pUsdc.connect(chain.signer(who));
  const pW = (who: string) => d.pWavax.connect(chain.signer(who));
  const ok = async (p: Promise<any>) => {
    const r = await (await p).wait();
    assert.equal(r.status, 1);
  };
  const price = async (p: any): Promise<BigNumber> => ctrl.callStatic.oracle().then((o: string) => new Contract(o, ["function getUnderlyingPrice(address) view returns (uint256)"], chain.provider).getUnderlyingPrice(p.address));
  const fund = async (token: string, who: string, amount: BigNumber) => {
    const bal: BigNumber = await new Contract(token, erc20Abi, chain.provider).balanceOf(who);
    await chain.setErc20Balance(token, who, bal.add(amount));
  };
  const mintP = async (p: any, underlying: string, who: string, amount: BigNumber) => {
    await fund(underlying, who, amount);
    await ok(new Contract(underlying, erc20Abi, chain.signer(who)).approve(p.address, amount));
    await ok(p.connect(chain.signer(who)).mint(amount));
  };
  const enter = (who: string) => ok(ctrl.connect(chain.signer(who)).enterMarkets([d.pWavax.address, d.pUsdc.address]));

  const cap6 = BigNumber.from(CAP_USD).mul(1_000_000);
  const supply6 = cap6.mul(10).div(8);
  await ok(ctrl._setCollateralFactor(d.pWavax.address, CF));
  await ok(ctrl._setCollateralFactor(d.pUsdc.address, 0));
  await ok(ctrl._setBorrowPaused(d.pUsdc.address, false)); // USDC borrowing on; WAVAX borrowing stays paused
  await ok(ctrl._setMarketBorrowCaps([d.pUsdc.address], [cap6.add(1)]));
  await ok(ctrl._setBorrowCashFloor(d.pUsdc.address, supply6.div(5))); // 20% of supply
  await mintP(d.pUsdc, USDC, LP, supply6); // the research supplier population (one account suffices for detection)

  const pu = await price(d.pUsdc);
  const pw = await price(d.pWavax);
  const borrowMax = async (who: string, want: BigNumber) => {
    for (let k = 0; k < 60; k++) {
      try {
        const code = await pU(who).callStatic.borrow(want);
        if (code.eq(0)) {
          await ok(pU(who).borrow(want));
          return want;
        }
      } catch {
        /* refused: try one unit less */
      }
      want = want.sub(1);
    }
    throw new Error("borrow at full capacity failed");
  };
  for (let i = 0; i < 3; i++) {
    const target6 = i < 2 ? cap6.div(3) : cap6.sub(cap6.div(3).mul(2));
    const wavaxUnits = target6.mul(E18).div(CF).mul(pu).div(pw).add("2000000000000");
    await mintP(d.pWavax, WAVAX, borrower(i), wavaxUnits);
    await enter(borrower(i));
    const liq: BigNumber = (await ctrl.getAccountLiquidity(borrower(i)))[1];
    const maxBorrow = liq.mul(E18).div(pu);
    const totalBorrows: BigNumber = await d.pUsdc.callStatic.totalBorrows();
    await borrowMax(borrower(i), maxBorrow.lt(cap6.sub(totalBorrows)) ? maxBorrow : cap6.sub(totalBorrows));
  }

  // 30 days of interest: 2,592,000 blocks of accrual (the Foundry `_roll`), done by moving the market's accrual checkpoint back
  const rollBlocks = async (blocks: number) => {
    const target: BigNumber = await d.pUsdc.accrualBlockNumber();
    let slot = -1;
    for (let s = 0; s < 60; s++) {
      const v: string = await chain.send("eth_getStorageAt", [d.pUsdc.address, "0x" + s.toString(16), "latest"]);
      if (BigNumber.from(v).eq(target)) {
        assert.equal(slot, -1, "accrualBlockNumber slot must be unique");
        slot = s;
      }
    }
    assert.ok(slot >= 0, "accrualBlockNumber slot found");
    await chain.send("anvil_setStorageAt", [d.pUsdc.address, "0x" + slot.toString(16), utils.hexZeroPad(target.sub(blocks).toHexString(), 32)]);
    await refresh();
    await ok(d.pUsdc.accrueInterest());
  };
  await rollBlocks(30 * 86_400);

  // the half-power account and the debt-free account (Foundry: _healthyHalf, NO_DEBT_ACCT)
  {
    const target6 = cap6.div(3);
    await mintP(d.pWavax, WAVAX, HEALTHY_ACCT, target6.mul(E18).div(CF).mul(pu).div(pw));
    await enter(HEALTHY_ACCT);
    const liq: BigNumber = (await ctrl.getAccountLiquidity(HEALTHY_ACCT))[1];
    await ok(ctrl._setMarketBorrowCaps([d.pUsdc.address], [cap6.mul(2)]));
    await ok(ctrl._setBorrowCashFloor(d.pUsdc.address, 0));
    await borrowMax(HEALTHY_ACCT, liq.mul(E18).div(pu).div(2));
    await mintP(d.pWavax, WAVAX, NO_DEBT_ACCT, E18.mul(10));
    await enter(NO_DEBT_ACCT);
  }
  // operators (inventory) and treasury for the health checks
  await fund(USDC, OP_A, BigNumber.from(4_440_000_000));
  await fund(USDC, OP_B, BigNumber.from(4_440_000_000));
  await fund(USDC, TREASURY, BigNumber.from(1_191_000_000));

  // ------------------------------------------------------------ the monitor configuration (synthetic operator decisions)
  const rawCfg = JSON.parse(JSON.stringify(require("../../../config/pilot.example.json")));
  rawCfg.deployment = { ...d.addresses, deploymentBlock: d.deployBlock };
  rawCfg.pilot = { ...rawCfg.pilot, label: "PW40-fork-test", wavaxCollateralFactorBp: 4000, usdcBorrowCapUsd: CAP_USD, cashFloorBp: 0 };
  rawCfg.operators = [{ name: "op-a", address: OP_A }, { name: "op-b", address: OP_B }];
  rawCfg.signer.type = "ledger";
  rawCfg.alerts.channel = "webhook";
  rawCfg.execution.slippageBoundBp = 100;
  rawCfg.reference.minPoolLiquidity = "1000";
  rawCfg.treasury.address = TREASURY;
  rawCfg.monitor.statePath = "state/fork-test-state.json";
  const cfg: MonitorConfig = requireValidConfig(rawCfg);
  const identity = await checkPoolIdentity(chain.provider);
  assert.equal(identity, null, "pool identity confirmed against the factory on the fork");
  const sink = new MemorySink();
  const alerts = new AlertManager(sink, cfg.monitor.escalationSeconds);
  let state: MonitorState = emptyMonitorState(cfg);
  const ctx = { provider: chain.provider, cfg, poolIdentityOk: identity === null };
  const cycle = async (hooks?: { mutation?: 0 | 1 | 3 }, keepState = true): Promise<CycleReport> => {
    const out = await runCycle(ctx, state, alerts, { hooks, extraAccounts: [NO_DEBT_ACCT] }); // the debt-free account never borrowed, so the event index cannot know it
    if (keepState) state = out.state;
    return out.report;
  };
  const row = (r: CycleReport, who: string) => {
    const a = r.accounts.find((x) => x.account.toLowerCase() === who.toLowerCase());
    assert.ok(a, `account ${who} is in the report (index found it)`);
    return a!;
  };
  const num6 = (s: string) => Number(s) / 1e6;
  const usd = (s: string) => Number(BigInt(s)) / 1e18;
  const close = (got: number, want: number, what: string) => {
    const tol = Math.max(Math.abs(want) * 5e-4, 0.01); // 5 bp, or one cent
    assert.ok(Math.abs(got - want) <= tol, `${what}: got ${got}, want ${want} (tolerance ${tol})`);
  };
  /** one truth-table row: verdict EXACT; amounts within 5 bp of the Foundry table values */
  const expectRow = (r: CycleReport, who: string, verdict: keyof typeof Verdict, debt?: number, debtUsd?: number, coll?: number, maxRec?: number, shortfall?: number) => {
    const a = row(r, who);
    assert.equal(a.verdict, verdict, `${who}: verdict`);
    if (debt !== undefined) close(num6(a.debtUnits), debt, `${verdict} debt`);
    if (debtUsd !== undefined) close(usd(a.debtUsd), debtUsd, `${verdict} debtUsd`);
    if (coll !== undefined) close(usd(a.collUsd), coll, `${verdict} collUsd`);
    if (maxRec !== undefined) close(usd(a.maxRecoveryUsd), maxRec, `${verdict} maxRecovery`);
    if (shortfall !== undefined) close(usd(a.shortfallUsd), shortfall, `${verdict} shortfall`);
  };

  // ============================================================ STAGE 1: price unchanged, 30 days of interest
  await t.test("stage 1: healthy half-power, no debt, full-power underwater from interest alone", async () => {
    await refresh();
    const r = await cycle();
    assert.equal(r.reference.status, "ok");
    expectRow(r, HEALTHY_ACCT, "HEALTHY", 833.33, 832.9794, 4164.8971, 0, 0);
    assert.equal(row(r, NO_DEBT_ACCT)?.verdict ?? "NO_DEBT", "NO_DEBT");
    expectRow(r, borrower(0), "LIQUIDATABLE_RECOVERABLE", 1683.11, 1682.3902, 4164.8971, 3856.3862, 16.4314);
    assert.ok(!r.findings.some((f) => f.severity === "crit" && f.key.startsWith("acct:")), "no account-level critical finding yet");
  });
  // ============================================================ STAGE 2: AVAX -20%
  await t.test("stage 2: AVAX -20%", async () => {
    await setAvaxBps(8_000);
    const r = await cycle();
    expectRow(r, borrower(1), "LIQUIDATABLE_RECOVERABLE", 1683.11, 1682.3902, 3331.9177, 3085.109, 349.6231);
    expectRow(r, HEALTHY_ACCT, "HEALTHY", 833.33, 832.9794, 3331.9177, 0, 0);
  });
  // ============================================================ STAGE 3: AVAX -75%: tail
  await t.test("stage 3: AVAX -75%: tail accounts are NOT paid; the half-power account is still recoverable", async () => {
    await setAvaxBps(2_500);
    const r = await cycle();
    expectRow(r, borrower(0), "UNRECOVERABLE_LIQUIDATE_FIRST", 1683.11, 1682.3902, 1041.2243, 964.0966, 1265.9005);
    expectRow(r, borrower(1), "UNRECOVERABLE_LIQUIDATE_FIRST", 1683.11, 1682.3902, 1041.2243, 964.0966, 1265.9005);
    expectRow(r, HEALTHY_ACCT, "LIQUIDATABLE_RECOVERABLE", 833.33, 832.9794, 1041.2243, 964.0965, 416.4897);
    assert.ok(r.findings.some((f) => f.key.startsWith("acct:") && f.key.endsWith("UNRECOVERABLE_LIQUIDATE_FIRST") && f.severity === "crit"), "tail alert (crit) raised");
    assert.ok(!r.findings.some((f) => f.key.endsWith("DEFAULT_EXHAUSTED")), "nothing is a default yet");
    assert.ok(BigInt(r.expectedTreasuryCall) > 0n, "expected treasury call computed");
  });
  // ============================================================ STAGE 4: liquidation to exhaustion
  const liquidate = async (b: string, repay: BigNumber) => {
    await fund(USDC, CAROL, repay);
    await ok(new Contract(USDC, erc20Abi, chain.signer(CAROL)).approve(d.pUsdc.address, repay));
    try {
      const code = await pU(CAROL).callStatic.liquidateBorrow(b, repay, d.pWavax.address);
      if (!code.eq(0)) return false;
      await ok(pU(CAROL).liquidateBorrow(b, repay, d.pWavax.address));
      return true;
    } catch {
      return false;
    }
  };
  const collUsdc6 = async (b: string): Promise<BigNumber> => {
    const bal: BigNumber = await d.pWavax.balanceOf(b);
    const ex: BigNumber = await d.pWavax.callStatic.exchangeRateCurrent();
    return bal.mul(ex).div(E18).mul(await price(d.pWavax)).div(await price(d.pUsdc));
  };
  const clear = async (b: string) => {
    for (let calls = 0; calls < 60; calls++) {
      if ((await ctrl.getAccountLiquidity(b))[2].eq(0)) break;
      const colBal: BigNumber = await d.pWavax.balanceOf(b);
      if ((await collUsdc6(b)).lt(DUST_USD6)) break;
      let repay: BigNumber = (await d.pUsdc.callStatic.borrowBalanceCurrent(b)).div(2);
      const seize: BigNumber = (await ctrl.liquidateCalculateSeizeTokens(d.pUsdc.address, d.pWavax.address, repay))[1];
      if (seize.gt(colBal)) repay = repay.mul(colBal).div(seize);
      let done = false;
      for (let a = 0; a < 8 && repay.gt(0); a++) {
        if (repay.lt(DUST_USD6)) {
          repay = BigNumber.from(0);
          break;
        }
        if (await liquidate(b, repay)) {
          done = true;
          break;
        }
        repay = repay.mul(99_999).div(100_000);
      }
      if (!done) break;
    }
  };
  await t.test("stage 4: exhausted account fires, partially liquidated and untouched tail accounts do not", async () => {
    await clear(borrower(0));
    assert.ok(await liquidate(borrower(1), (await d.pUsdc.callStatic.borrowBalanceCurrent(borrower(1))).div(2)), "one liquidation round on account 1");
    await refresh();
    const r = await cycle();
    expectRow(r, borrower(0), "DEFAULT_EXHAUSTED", 718.6, 718.2937, 0, 0, 718.2937);
    expectRow(r, borrower(1), "UNRECOVERABLE_LIQUIDATE_FIRST", 841.55, 841.1951, 132.7336, 122.9014, 788.1017);
    expectRow(r, borrower(2), "UNRECOVERABLE_LIQUIDATE_FIRST", 1683.11, 1682.3902, 1041.2243, 964.0966, 1265.9005);
    expectRow(r, HEALTHY_ACCT, "LIQUIDATABLE_RECOVERABLE", 833.33, 832.9794, 1041.2243, 964.0965, 416.4897);
    // the rule fires EXACTLY once
    assert.equal(r.counts["DEFAULT_EXHAUSTED"], 1);
    const def = r.findings.filter((f) => f.key.endsWith("DEFAULT_EXHAUSTED"));
    assert.equal(def.length, 1);
    assert.ok(def[0]!.severity === "crit" && def[0]!.escalates, "default is a critical, escalating finding (T0)");
    // exhaustion corroborated on chain: a liquidation of a whole USDC is refused
    assert.equal(await liquidate(borrower(0), BigNumber.from(1_000_000)), false, "a liquidation of 1 USDC on the exhausted account is refused");
    assert.ok(usd(row(r, borrower(0)).maxRecoveryUsd) <= 0.01 / 1.08 + 1e-9, "remaining recovery <= dust / LI");
  });
  await t.test("escalation timers: the unpaid default re-alerts at 1 h, 4 h and 24 h (and the alert stream carries the T0 message first)", async () => {
    const before = sink.messages.filter((m) => m.kind === "escalation").length;
    assert.ok(sink.messages.some((m) => m.key.endsWith("DEFAULT_EXHAUSTED") && m.kind === "new" && /DEFAULT/.test(m.text)), "T0 message was sent");
    for (const [secs, expectedTotal] of [[3600, 1], [3 * 3600, 2], [20 * 3600, 3]] as const) {
      await chain.increaseTime(secs);
      await refresh();
      await cycle();
      assert.equal(sink.messages.filter((m) => m.kind === "escalation").length - before, expectedTotal, `after +${secs}s`);
    }
  });
  // ============================================================ stale / zero
  await t.test("stale AVAX price (1,201 s): nothing fires; an account without debt needs no price", async () => {
    const snap = await chain.snapshot();
    await refresh();
    await chain.increaseTime(1_201);
    const r = await cycle(undefined, false);
    expectRow(r, borrower(0), "STALE_OR_ZERO_PRICE", 718.6, 0, 0, 0, 0);
    expectRow(r, borrower(2), "STALE_OR_ZERO_PRICE", 1683.11, 0, 0, 0, 0);
    assert.ok(!r.accounts.some((a) => a.verdict === "DEFAULT_EXHAUSTED"));
    assert.ok(r.findings.some((f) => f.key === "feed:avax" && f.severity === "crit"), "feed age finding raised");
    assert.ok(r.findings.some((f) => f.key.startsWith("oracle-zero:")), "guarded oracle zero finding raised");
    await chain.revert(snap);
  });
  await t.test("a zero AVAX answer: nothing fires", async () => {
    const keep = avaxAnswer;
    avaxAnswer = BigNumber.from(0);
    await refresh(undefined, false, 1);
    const r = await cycle(undefined, false);
    expectRow(r, borrower(0), "STALE_OR_ZERO_PRICE");
    assert.ok(!r.accounts.some((a) => a.verdict === "DEFAULT_EXHAUSTED"));
    avaxAnswer = keep;
    await refresh();
  });

  // ============================================================ oracle failure and reference failure (the specification's fail-closed list)
  await t.test("oracle failure: a manipulated-low oracle with an honest reference reads PRICE_DIVERGENCE, never DEFAULT; the page tells the guardian", async () => {
    const snap = await chain.snapshot();
    const honestUsd = Number(avaxAnswer.toString()) / 1e8;
    avaxAnswer = BigNumber.from(1); // 1e-8 USD
    await refresh(undefined, false, honestUsd);
    const r = await cycle(undefined, false);
    for (const who of [borrower(0), borrower(1), borrower(2), HEALTHY_ACCT]) assert.equal(row(r, who).verdict, "PRICE_DIVERGENCE", `${who}`);
    assert.ok(!r.accounts.some((a) => a.verdict === "DEFAULT_EXHAUSTED"), "no payment on a divergent oracle");
    const f = r.findings.find((x) => x.key === "price-divergence");
    assert.ok(f && f.severity === "crit" && f.audience === "guardian" && /pausing borrowing/.test(f.message));
    await chain.revert(snap);
    avaxAnswer = realAvax.mul(2_500).div(10_000);
    await refresh();
  });
  for (const [name, args] of [
    ["observe() reverts (pool history shorter than the window)", [BigNumber.from("1000000000000"), true] as const],
    ["pool liquidity below the configured floor", [BigNumber.from(999), false] as const],
  ] as const) {
    await t.test(`reference failure fails closed: ${name} -> NO_REFERENCE_PRICE, nothing fires, page after the persistence window`, async () => {
      await refresh(args[0], args[1]);
      const r = await cycle(undefined, false);
      assert.equal(r.reference.status, "none");
      for (const who of [borrower(0), borrower(1), borrower(2)]) assert.equal(row(r, who).verdict, "NO_REFERENCE_PRICE", who);
      assert.ok(!r.accounts.some((a) => a.verdict === "DEFAULT_EXHAUSTED"));
      assert.ok(r.findings.some((f) => f.key === "unknown-price" && f.severity === "warn"), "first a warning");
      const later = await runCycle(ctx, { ...state, unknownPriceSince: (await chain.now()) - cfg.monitor.noReferencePageSeconds - 1 }, alerts, {});
      assert.ok(later.report.findings.some((f) => f.key === "unknown-price" && f.severity === "crit"), "then a page");
      await refresh();
    });
  }
  await t.test("a wrong reference can only delay: reference at 10x or 1/10 of the oracle never produces a payment", async () => {
    const usdNow = Number(avaxAnswer.toString()) / 1e8;
    for (const factor of [10, 0.1, 1.2, 0.8]) {
      await refresh(undefined, false, usdNow * factor);
      const r = await cycle(undefined, false);
      assert.deepEqual(r.accounts.filter((a) => a.verdict === "DEFAULT_EXHAUSTED").map((a) => a.account.toLowerCase()), factor === 10 || factor === 0.1 ? [] : [], `reference x${factor}`);
      assert.ok(r.accounts.every((a) => a.verdict === "PRICE_DIVERGENCE" || a.verdict === "NO_DEBT" || a.verdict === "DEFAULT_EXHAUSTED" || a.verdict.startsWith("UNRECOVERABLE") || a.verdict.startsWith("LIQUIDATABLE")), `reference x${factor}`);
      // x1.2 and x0.8 are beyond 5% too -> divergence; the exhausted account must never read DEFAULT under any of them
      assert.notEqual(row(r, borrower(0)).verdict, "DEFAULT_EXHAUSTED", `reference x${factor} cannot create (or hide-then-create) a fire`);
    }
    await refresh();
  });

  // ============================================================ mutants are caught by the table
  await t.test("MUTATION 1 (fire on shortfall alone) and MUTATION 3 (no divergence gate) change a verdict this suite pins", async () => {
    await refresh();
    const base = await cycle(undefined, false);
    const m1 = await cycle({ mutation: 1 }, false);
    assert.equal(row(base, borrower(2)).verdict, "UNRECOVERABLE_LIQUIDATE_FIRST");
    assert.equal(row(m1, borrower(2)).verdict, "DEFAULT_EXHAUSTED", "mutant 1 would pay the untouched tail account");
    assert.equal(row(m1, HEALTHY_ACCT).verdict, "DEFAULT_EXHAUSTED", "mutant 1 would pay a recoverable account");
    const snap = await chain.snapshot();
    const honestUsd = Number(avaxAnswer.toString()) / 1e8;
    avaxAnswer = BigNumber.from(1);
    await refresh(undefined, false, honestUsd);
    const m3 = await cycle({ mutation: 3 }, false);
    const clean = await cycle(undefined, false);
    assert.equal(row(clean, borrower(2)).verdict, "PRICE_DIVERGENCE");
    assert.notEqual(row(m3, borrower(2)).verdict, "PRICE_DIVERGENCE", "mutant 3 has no divergence gate");
    await chain.revert(snap);
    avaxAnswer = realAvax.mul(2_500).div(10_000);
    await refresh();
  });

  // ============================================================ health checks on the real market, and the last row
  await t.test("health: exchange rate, shares consistency, operator inventory, treasury, configuration drift are all quiet on the pilot fixture", async () => {
    await refresh();
    // the Foundry fixture lifted the cap to twice the pilot's for the half-power account: the monitor must say so (configuration drift) ...
    const drifted = await cycle(undefined, false);
    assert.ok(drifted.findings.some((f) => f.key === "drift:cap-usdc"), "cap drift detected");
    // ... and be quiet once the pilot's cap is back
    await ok(ctrl._setMarketBorrowCaps([d.pUsdc.address], [cap6.add(1)]));
    const r = await cycle();
    const bad = r.findings.filter((f) => ["shares:mismatch", "shares:disabled", "market-read", "drift:", "market-missing", "market-underlying", "exchange-rate"].some((p) => f.key.startsWith(p)));
    assert.deepEqual(bad.map((f) => f.key), [], "no accounting or drift findings");
    const inv = r.findings.filter((f) => f.key.startsWith("inventory:") || f.key.startsWith("gas:"));
    assert.deepEqual(inv, [], "operators hold the pilot inventory and gas");
  });
  await t.test("the incremental borrower index equals a full re-scan of the events from the deployment block", async () => {
    const head = await chain.provider.getBlockNumber();
    const diff = await crossCheckIndex(chain.provider, d.addresses.pUsdc, state.index, d.deployBlock, head, 2000);
    assert.deepEqual(diff, { missingFromIndex: [], extraInIndex: [] });
    assert.deepEqual(state.index.borrowers, [borrower(0), borrower(1), borrower(2), HEALTHY_ACCT].map((a) => a.toLowerCase()).sort());
  });
  await t.test("after the treasury repays the exhausted account the same account reads NO_DEBT and the default alert resolves", async () => {
    await fund(USDC, TREASURY, BigNumber.from(1_000_000).mul(1_000_000));
    await ok(new Contract(USDC, erc20Abi, chain.signer(TREASURY)).approve(d.pUsdc.address, BigNumber.from(2).pow(256).sub(1)));
    await ok(pU(TREASURY).repayBorrowBehalf(borrower(0), BigNumber.from(2).pow(256).sub(1))); // the full-repay sentinel
    await refresh();
    const r = await cycle();
    assert.equal(row(r, borrower(0)).verdict, "NO_DEBT");
    assert.ok(sink.messages.some((m) => m.kind === "resolved" && m.key.endsWith("DEFAULT_EXHAUSTED")), "the default alert was announced as resolved");
    assert.equal(r.counts["DEFAULT_EXHAUSTED"] ?? 0, 0);
    // the shares of the repaid account are gone: the index (events) still lists it, the sum still matches totalBorrowShares
    assert.ok(!r.findings.some((f) => f.key === "shares:mismatch"));
    void VERDICT_NAMES;
  });
});

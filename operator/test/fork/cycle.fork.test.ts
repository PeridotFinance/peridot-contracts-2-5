// The LIQUIDATOR EXECUTOR reproducing the liquidation-cycle study (docs/deployment-handoffs/avalanche-cash-only-liquidation-cycle.md, Foundry suite
// AvalancheCashOnlyLiquidationCycleFork) on a local anvil fork of Avalanche C-Chain at block 99,200,000, with the SAME mechanics:
//   * borrowers borrow 100% of their borrowing power while the AVAX feed is mocked UP (price at borrowing = pin / (1 - gap)); the feed is then set to
//     the real pinned price, so liquidation, seizure value and conversion all run at the real price and the REAL Uniswap V3 0.05% pool;
//   * each operator is an executor with its own Foundry-keystore signer (a THROWAWAY key created inside this run), its own USDC inventory and gas;
//   * the only outside USDC an operator ever sees is its initial inventory; afterwards it moves only by repayments (out) and swap proceeds (in);
//   * conversion is revert-protected by min-out = oracle value minus the slippage bound (100 bp), no fallback route.
// Differences from the Foundry suite, stated: the executors run their own algorithm one step at a time (the Foundry test scripts each round), so round
// ORDER between operators may differ and only totals are compared; every transaction mines a block (a few blocks of interest); accounts are
// impersonated, operators sign with throwaway keystores; a SUBSET of the Foundry grid is run (see the matrix below); the research "fallback route"
// variant is not an executor behaviour and is not reproduced.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { BigNumber, Contract, Wallet, utils } from "ethers";
import { AVAX_FEED, USDC, USDC_FEED, WAVAX, UNIV3_POOL_WAVAX_USDC_500, UNIV3_SWAP_ROUTER02 } from "../../src/constants";
import { AlertManager, MemorySink } from "../../src/alerts";
import { requireValidConfig } from "../../src/config";
import type { MonitorConfig } from "../../src/config";
import { emptyExecutorState, executorStep, verifyExecutorSigner } from "../../src/executor";
import type { ExecutorDeps, ExecutorOutcome, ExecutorState } from "../../src/executor";
import { KeystoreSigner } from "../../src/signer";
import type { ExternalSigner, TxRequest } from "../../src/signer";
import { decidedConfig } from "../fixtures";
import { artifacts, deployCashOnly, ForkChain, Mocks, rpcAvailable } from "./harness";

const SKIP = !rpcAvailable() ? "AVALANCHE_MAINNET_RPC_URL not set (no archive endpoint): fork tests are SKIPPED, not passed" : !artifacts().present ? "forge artifacts missing: run `npm run build:contracts` first" : false;

const E18 = BigNumber.from(10).pow(18);
const ADMIN = "0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD"; // the Ledger address, IMPERSONATED on the local fork only (it is the admin of the test stack)
const LP = "0x0000000000000000000000000000000000001001";
const WHALE = "0x000000000000000000000000000000000DEAD002";
const COMPETITOR = "0x0000000000000000000000000000000000CA2201";
const KS_PASSWORD = "fork-test-only-operator-password-3b9d"; // protects THROWAWAY keystores that exist only for this local-fork run
const borrowerAddr = (i: number) => utils.getAddress("0x" + (0xbb000 + i).toString(16).padStart(40, "0"));
const erc20Abi = ["function balanceOf(address) view returns (uint256)", "function approve(address,uint256) returns (bool)", "function allowance(address,address) view returns (uint256)"];
const UNLIMITED = BigNumber.from(10).pow(15); // USD 1 billion in USDC units: used only to MEASURE the requirement

interface Cfg {
  tag: string;
  cf: number; // 3000 / 4000
  capUsd: number;
  n: number;
  gapBp: number;
  convert: boolean;
  invA: BigNumber;
  invB: BigNumber;
  aUp: boolean;
  bUp: boolean;
  interleave: boolean;
  adverseBp: number;
  limitBp: number;
  stage2Bp: number;
}
interface Res {
  debt0: BigNumber;
  repaid: BigNumber;
  rounds: number;
  swaps: number;
  blocked: number;
  unfunded: number;
  peakNeed: [BigNumber, BigNumber];
  shortfallAccts: number;
  debtLeft: BigNumber;
  bad6: BigNumber;
  shortfallAcctsS2: number;
  bad6S2: BigNumber;
  wavaxHeld: BigNumber;
  pHeld: BigNumber;
  invEnd: [BigNumber, BigNumber];
  minRatioBp: number;
  halted: boolean;
}

test("executor reproduces the liquidation cycle (cases 1, 2, 3, 5) on a mainnet fork", { skip: SKIP, timeout: 3_300_000 }, async (t) => {
  const chain = await ForkChain.start();
  t.after(() => chain.stop());
  await chain.send("anvil_setBlockTimestampInterval", [1]);
  const ksDir = fs.mkdtempSync(path.join(os.tmpdir(), "operator-ks-"));
  t.after(() => fs.rmSync(ksDir, { recursive: true, force: true }));
  const wallets = [Wallet.createRandom(), Wallet.createRandom()]; // THROWAWAY keys of operator A and operator B
  const ksFiles: string[] = [];
  for (let i = 0; i < 2; i++) {
    const f = path.join(ksDir, `operator${i}`);
    fs.writeFileSync(f, await wallets[i]!.encrypt(KS_PASSWORD, { scrypt: { N: 1024 } }), { mode: 0o600 });
    ksFiles.push(f);
  }
  const OP = [wallets[0]!.address, wallets[1]!.address];
  for (const a of [ADMIN, LP, WHALE, COMPETITOR, ...OP, ...Array.from({ length: 5 }, (_, i) => borrowerAddr(i))]) await chain.setBalance(a);

  // ------------------------------------------------------------ prices: feeds are mocks (to move the price); the Uniswap pool stays REAL
  const mocks = new Mocks(chain, ADMIN);
  const lr = ["function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)"];
  const realAvax: BigNumber = (await new Contract(AVAX_FEED, lr, chain.provider).latestRoundData())[1];
  const usdcAnswer: BigNumber = (await new Contract(USDC_FEED, lr, chain.provider).latestRoundData())[1];
  await mocks.installFeedsOnly();
  let avaxAnswer = realAvax;
  const refresh = async () => {
    const now = await chain.now();
    await (await mocks.feed(AVAX_FEED).set(avaxAnswer, now)).wait();
    await (await mocks.feed(USDC_FEED).set(usdcAnswer, now)).wait();
  };
  await refresh();

  // ------------------------------------------------------------ the cash-only stack (opt-in controller) with the pilot-shaped fixture of the Foundry suite
  const dbg = (m: string) => { if (process.env.CYCLE_DEBUG) console.error(`[cycle ${new Date().toISOString().slice(11, 19)}] ${m}`); };
  dbg("deploying");
  const d = await deployCashOnly(chain, ADMIN);
  dbg("deployed");
  const ctrl: any = d.controller.connect(chain.signer(ADMIN));
  const ok = async (p: Promise<any>) => assert.equal((await (await p).wait()).status, 1);
  const fund = async (token: string, who: string, amount: BigNumber) => {
    const bal: BigNumber = await new Contract(token, erc20Abi, chain.provider).balanceOf(who);
    await chain.setErc20Balance(token, who, bal.add(amount));
  };
  const balOf = async (token: string, who: string): Promise<BigNumber> => new Contract(token, erc20Abi, chain.provider).balanceOf(who);
  const mintP = async (p: any, underlying: string, who: string, amount: BigNumber) => {
    await fund(underlying, who, amount);
    await ok(new Contract(underlying, erc20Abi, chain.signer(who)).approve(p.address, amount));
    await ok(p.connect(chain.signer(who)).mint(amount));
  };
  await ok(ctrl._setCollateralFactor(d.pWavax.address, utils.parseEther("0.40")));
  await ok(ctrl._setCollateralFactor(d.pUsdc.address, 0));
  await ok(ctrl._setBorrowPaused(d.pUsdc.address, false)); // WAVAX borrowing stays paused
  const setCap = (units: BigNumber) => ok(ctrl._setMarketBorrowCaps([d.pUsdc.address], [units]));
  await setCap(BigNumber.from(320_000).mul(1_000_000));
  await ok(ctrl._setBorrowCashFloor(d.pUsdc.address, BigNumber.from(80_000).mul(1_000_000)));
  assert.equal((await d.pUsdc.protocolSeizeShareMantissa()).toString(), "28000000000000000", "protocol seize share 2.8%");
  assert.equal((await ctrl.closeFactorMantissa()).toString(), utils.parseEther("0.5").toString());
  assert.equal((await ctrl.liquidationIncentiveMantissa()).toString(), utils.parseEther("1.08").toString());
  dbg("minting LP");
  await mintP(d.pUsdc, USDC, LP, BigNumber.from(400_000).mul(1_000_000));
  await mintP(d.pWavax, WAVAX, LP, E18.mul(12_000));

  const price = async (p: any): Promise<BigNumber> => new Contract(await ctrl.oracle(), ["function getUnderlyingPrice(address) view returns (uint256)"], chain.provider).getUnderlyingPrice(p.address);
  const wavaxToUsdc = async (w: BigNumber): Promise<BigNumber> => w.mul(await price(d.pWavax)).div(await price(d.pUsdc));

  // ------------------------------------------------------------ executors (one per operator, throwaway Foundry keystore)
  const signers: ExternalSigner[] = [];
  for (let i = 0; i < 2; i++) signers.push(await KeystoreSigner.load(chain.provider, ksFiles[i]!, "OPERATOR_KEYSTORE_PASSWORD", { OPERATOR_KEYSTORE_PASSWORD: KS_PASSWORD }));
  const cfgFor = (k: number, over: Partial<MonitorConfig["executor"]> = {}): MonitorConfig => {
    const raw = decidedConfig({ operators: [OP[0]!, OP[1]!] });
    raw.deployment = { ...d.addresses, deploymentBlock: d.deployBlock };
    raw.executor = { ...raw.executor, enabled: true, operator: k === 0 ? "op-a" : "op-b", keystorePath: ksFiles[k], convertToUsdc: true, ...over };
    raw.keeper.enabled = false;
    raw.reference.minPoolLiquidity = "500";
    return requireValidConfig(raw);
  };
  for (let k = 0; k < 2; k++) await verifyExecutorSigner(signers[k]!, cfgFor(k), chain.provider);

  // ------------------------------------------------------------ one scenario
  const sinkOf = new MemorySink();
  const baseCfg = (tag: string, cf: number, capUsd: number, n: number, gapBp: number): Cfg => ({ tag, cf, capUsd, n, gapBp, convert: true, invA: UNLIMITED, invB: BigNumber.from(0), aUp: true, bUp: false, interleave: false, adverseBp: 0, limitBp: 100, stage2Bp: 0 });

  const openBorrowers = async (c: Cfg): Promise<{ debt0: BigNumber; borrowers: string[] }> => {
    const capUnits = BigNumber.from(c.capUsd).mul(1_000_000);
    await ok(ctrl._setCollateralFactor(d.pWavax.address, BigNumber.from(c.cf).mul(BigNumber.from(10).pow(14))));
    await setCap(capUnits.add(1_000)); // strict bound: leave 0.001 USDC for rounding at 100% of capacity
    const hi = realAvax.mul(10_000).div(10_000 - c.gapBp);
    avaxAnswer = hi;
    await refresh();
    const each = capUnits.div(c.n);
    let debt0 = BigNumber.from(0);
    const borrowers: string[] = [];
    for (let i = 0; i < c.n; i++) {
      const b = borrowerAddr(i);
      borrowers.push(b);
      const coll = each.mul(BigNumber.from(10).pow(20)).mul(10_000).div(hi.mul(c.cf));
      await mintP(d.pWavax, WAVAX, b, coll);
      await ok(ctrl.connect(chain.signer(b)).enterMarkets([d.pWavax.address, d.pUsdc.address]));
      const liq: BigNumber = (await ctrl.getAccountLiquidity(b))[1];
      let max6 = liq.div(BigNumber.from(10).pow(12));
      let done = false;
      for (let k = 0; k < 3 && !done; k++) {
        try {
          if ((await d.pUsdc.connect(chain.signer(b)).callStatic.borrow(max6)).eq(0)) {
            await ok(d.pUsdc.connect(chain.signer(b)).borrow(max6));
            done = true;
          }
        } catch {
          /* retry one unit lower */
        }
        if (!done) max6 = max6.sub(1);
      }
      assert.ok(done, "borrow at 100% of borrowing power");
      debt0 = debt0.add(await d.pUsdc.borrowBalanceStored(b));
      assert.equal((await ctrl.getAccountLiquidity(b))[2].toString(), "0", "healthy right after borrowing");
    }
    avaxAnswer = realAvax; // the real pinned price from here on
    await refresh();
    return { debt0, borrowers };
  };

  const spot8 = async (): Promise<number> => {
    const slot0 = await new Contract(UNIV3_POOL_WAVAX_USDC_500, ["function slot0() view returns (uint160,int24,uint16,uint16,uint16,uint8,bool)"], chain.provider).slot0();
    const s = Number(slot0[0].toString()) / 2 ** 96;
    return s * s * 1e12 * 1e8;
  };
  const pushPoolDown = async (bp: number): Promise<void> => {
    const target = (Number(realAvax.toString()) * (10_000 - bp)) / 10_000;
    const chunk = BigNumber.from(20_000).mul(1_000_000).mul(BigNumber.from(10).pow(12)).mul(BigNumber.from(10).pow(8)).div(realAvax);
    const rt = new Contract(UNIV3_SWAP_ROUTER02, ["function exactInputSingle((address,address,uint24,address,uint256,uint256,uint160)) payable returns (uint256)"], chain.signer(WHALE));
    for (let k = 0; k < 80 && (await spot8()) > target; k++) {
      await fund(WAVAX, WHALE, chunk);
      await ok(new Contract(WAVAX, erc20Abi, chain.signer(WHALE)).approve(UNIV3_SWAP_ROUTER02, chunk));
      await ok(rt.exactInputSingle([WAVAX, USDC, 500, WHALE, chunk, 0, 0], { gasLimit: 3_000_000 }));
    }
  };

  const depsFor = (k: number, accounts: string[], states: ExecutorState[], alerts: AlertManager, limitBp: number, sgn?: ExternalSigner, over: Partial<MonitorConfig["executor"]> = {}): ExecutorDeps => ({
    ctx: { provider: chain.provider, cfg: cfgFor(k, over), poolIdentityOk: true },
    signer: sgn ?? signers[k]!,
    alerts,
    slippageBoundBp: limitBp,
    accounts: async () => accounts,
    persist: (s: ExecutorState) => (states[k] = s),
    trace: (m: string) => { if (process.env.CYCLE_DEBUG) console.error(`[cycle ${new Date().toISOString().slice(11, 19)}]      ${m}`); },
  });

  const dbg2 = (m: string) => { if (process.env.CYCLE_DEBUG) console.error(`[cycle ${new Date().toISOString().slice(11, 19)}]   ${m}`); };
  const runInner0 = async (c: Cfg): Promise<{ res: Res; states: ExecutorState[]; alerts: AlertManager; sink: MemorySink; borrowers: string[] }> => {
    dbg2("opening borrowers");
    const { debt0, borrowers } = await openBorrowers(c);
    dbg2("borrowers open");
    const cashBefore: BigNumber = await d.pUsdc.getCash();
    await chain.setErc20Balance(USDC, OP[0]!, c.invA);
    await chain.setErc20Balance(USDC, OP[1]!, c.invB);
    for (const o of OP) {
      await chain.setErc20Balance(WAVAX, o, BigNumber.from(0));
      assert.equal((await d.pWavax.balanceOf(o)).toString(), "0");
    }
    const inv0 = [await balOf(USDC, OP[0]!), await balOf(USDC, OP[1]!)];
    if (c.adverseBp > 0) await pushPoolDown(c.adverseBp);
    const sink = new MemorySink();
    const alerts = new AlertManager(sink, [3600, 14400, 86400]);
    const states: ExecutorState[] = [emptyExecutorState(), emptyExecutorState()];
    const deps = [0, 1].map((k) => depsFor(k, borrowers, states, alerts, c.limitBp, undefined, { convertToUsdc: c.convert }));
    const up = [c.aUp, c.bUp];
    const cumRepaid = [BigNumber.from(0), BigNumber.from(0)];
    const cumProceeds = [BigNumber.from(0), BigNumber.from(0)];
    const res: Res = { debt0, repaid: BigNumber.from(0), rounds: 0, swaps: 0, blocked: 0, unfunded: 0, peakNeed: [BigNumber.from(0), BigNumber.from(0)], shortfallAccts: 0, debtLeft: BigNumber.from(0), bad6: BigNumber.from(0), shortfallAcctsS2: 0, bad6S2: BigNumber.from(0), wavaxHeld: BigNumber.from(0), pHeld: BigNumber.from(0), invEnd: [BigNumber.from(0), BigNumber.from(0)], minRatioBp: 99_999, halted: false };
    let turn = 0;
    dbg2("executing");
    for (let pass = 0; pass < 80; pass++) {
      let progress = false;
      // which operators act this pass: both alternate when interleaved; otherwise the first operator that is up
      const actors = up[0] && up[1] ? (c.interleave ? [turn++ % 2] : [0]) : up[0] ? [0] : up[1] ? [1] : [];
      for (const k of actors) {
        await refresh();
        const before = [await balOf(USDC, OP[k]!), await balOf(WAVAX, OP[k]!), await d.pWavax.balanceOf(OP[k]!)];
        dbg2(`pass ${pass} op ${k} step`);
        const o: ExecutorOutcome = await executorStep(deps[k]!, states[k]!);
        dbg2(`pass ${pass} op ${k} -> round=${!!o.round} skipped=${o.skipped.join("|")} halted=${o.halted}`);
        states[k] = o.state;
        if (o.halted) res.halted = true;
        if (o.unfunded) res.unfunded++;
        if (o.swapBlocked) res.blocked++;
        if (o.round) {
          res.rounds++;
          const repay = BigNumber.from(o.round.repay);
          res.repaid = res.repaid.add(repay);
          cumRepaid[k] = cumRepaid[k]!.add(repay);
          const need = cumRepaid[k]!.sub(cumProceeds[k]!); // before this round's proceeds
          if (need.gt(res.peakNeed[k]!)) res.peakNeed[k] = need;
          if (o.round.usdcOut) {
            const out = BigNumber.from(o.round.usdcOut);
            cumProceeds[k] = cumProceeds[k]!.add(out);
            res.swaps++;
            const oracleVal = await wavaxToUsdc(BigNumber.from(o.round.wavaxIn!));
            const ratio = out.mul(10_000).div(oracleVal).toNumber();
            if (ratio < res.minRatioBp) res.minRatioBp = ratio;
          }
        }
        const after = [await balOf(USDC, OP[k]!), await balOf(WAVAX, OP[k]!), await d.pWavax.balanceOf(OP[k]!)];
        if (o.round || before.some((x, i) => !x.eq(after[i]!))) progress = true;
        if (o.halted) break;
      }
      if (!progress) break;
    }
    for (let k = 0; k < 2; k++) {
      res.invEnd[k] = await balOf(USDC, OP[k]!);
      res.wavaxHeld = res.wavaxHeld.add(await balOf(WAVAX, OP[k]!));
      res.pHeld = res.pHeld.add(await wavaxToUsdc((await d.pWavax.balanceOf(OP[k]!)).mul(await d.pWavax.exchangeRateStored()).div(E18)));
    }
    // accounting identities
    const cashAfter: BigNumber = await d.pUsdc.getCash();
    assert.equal(cashAfter.toString(), cashBefore.add(res.repaid).toString(), "market cash grew by exactly the repayments");
    if (res.blocked === 0) {
      const proceeds = cumProceeds[0]!.add(cumProceeds[1]!);
      assert.equal(inv0[0]!.add(inv0[1]!).add(proceeds).toString(), res.invEnd[0]!.add(res.invEnd[1]!).add(res.repaid).toString(), "operator USDC conservation: start + proceeds = end + repaid");
    }
    // end state
    const evalAccts = async (stage2: boolean) => {
      let n = 0;
      let bad = BigNumber.from(0);
      let debtLeft = BigNumber.from(0);
      for (const b of borrowers) {
        const debt: BigNumber = await d.pUsdc.callStatic.borrowBalanceCurrent(b);
        const sf: BigNumber = (await ctrl.getAccountLiquidity(b))[2];
        const coll = await wavaxToUsdc((await d.pWavax.balanceOf(b)).mul(await d.pWavax.exchangeRateStored()).div(E18));
        debtLeft = debtLeft.add(debt);
        if (sf.gt(0)) n++;
        if (stage2) dbg(`S2 ${b.slice(-4)} debt=${debt.toString()} coll=${coll.toString()} pW=${(await price(d.pWavax)).toString()} sf=${sf.toString()}`);
        if (debt.gt(coll)) bad = bad.add(debt.sub(coll));
      }
      return { n, bad, debtLeft };
    };
    const e1 = await evalAccts(false);
    res.shortfallAccts = e1.n;
    res.bad6 = e1.bad;
    res.debtLeft = e1.debtLeft;
    if (c.stage2Bp > 0) {
      avaxAnswer = realAvax.mul(10_000 - c.stage2Bp).div(10_000);
      await refresh();
      const e2 = await evalAccts(true);
      res.shortfallAcctsS2 = e2.n;
      res.bad6S2 = e2.bad;
      avaxAnswer = realAvax;
    }
    return { res, states, alerts, sink, borrowers };
  };
  const runInner = async (c: Cfg) => { dbg(`run ${c.tag} cf=${c.cf} cap=${c.capUsd} n=${c.n} convert=${c.convert}`); const r = await runInner0(c); dbg(`done ${c.tag} rounds=${r.res.rounds}`); return r; };
  const fresh = async (c: Cfg): Promise<Res> => {
    const snap = await chain.snapshot();
    try {
      return (await runInner(c)).res;
    } finally {
      await chain.revert(snap);
      avaxAnswer = realAvax;
    }
  };
  const approx = (got: BigNumber, want: BigNumber, relBp: number, what: string) => {
    const tol = want.mul(relBp).div(10_000).add(2);
    assert.ok(got.sub(want).abs().lte(tol), `${what}: got ${got.toString()}, want ${want.toString()} (+-${tol.toString()})`);
  };
  const U = (usd: number) => BigNumber.from(Math.round(usd * 1e6));

  // ============================================================ CASE 1: single borrower, recycling vs no recycling, the funding requirement
  const case1 = async (cf: number, cap: number, gap: number) => {
    await t.test(`case 1: PW${cf / 100} cap ${cap} gap ${gap / 100}%: recycling clears the account; the funding numbers are exact`, async () => {
      const rec = await fresh({ ...baseCfg("rec", cf, cap, 1, gap) });
      assert.equal(rec.halted, false);
      assert.equal(rec.shortfallAccts, 0, "recycling run clears the account");
      assert.equal(rec.bad6.toString(), "0", "no bad debt");
      assert.equal(rec.unfunded, 0, "unlimited inventory");
      assert.equal(rec.blocked, 0, "conversion not blocked at this size within the 100 bp limit");
      if (gap === 3500) {
        assert.equal(rec.rounds, 2, "two rounds (close factor 50%, then 50% of the rest)");
        approx(rec.repaid, rec.debt0.mul(75).div(100), 5, "total repaid = 0.75 x debt (doc 3)");
        approx(rec.peakNeed[0], rec.debt0.div(2), 5, "funding WITH recycling = 0.50 x debt");
        assert.ok(rec.minRatioBp >= 9_980, `conversion output vs oracle >= 99.8% (worst ${rec.minRatioBp} bp)`);
      }
      const nor = await fresh({ ...baseCfg("nor", cf, cap, 1, gap), convert: false });
      assert.equal(nor.shortfallAccts, 0, "no-recycling run (unlimited inventory) clears the account");
      approx(nor.repaid, rec.repaid, 2, "same liquidations either way");
      if (gap === 3500) approx(nor.repaid, nor.debt0.mul(75).div(100), 5, "funding WITHOUT recycling = 0.75 x debt");
      // TEST the funding numbers: the measured requirement funds every step; one unit less leaves a step unfunded
      const exact = await fresh({ ...baseCfg("exact", cf, cap, 1, gap), invA: rec.peakNeed[0] });
      assert.equal(exact.unfunded, 0, "recycling: the peak need funds every step");
      assert.equal(exact.shortfallAccts, 0);
      const short = await fresh({ ...baseCfg("short", cf, cap, 1, gap), invA: rec.peakNeed[0].sub(1) });
      if (gap === 3500) assert.ok(short.unfunded > 0, "recycling: one unit less than the peak need leaves a step unfunded");
      const exactNor = await fresh({ ...baseCfg("exactnor", cf, cap, 1, gap), convert: false, invA: nor.repaid });
      assert.equal(exactNor.unfunded, 0, "no recycling: the sum of repayments funds every step");
      assert.equal(exactNor.invEnd[0].toString(), "0", "no recycling: inventory fully spent");
      assert.equal(exactNor.shortfallAccts, 0);
      const ninety = await fresh({ ...baseCfg("ninety", cf, cap, 1, gap), convert: false, invA: nor.repaid.mul(9).div(10) });
      if (gap === 3500) {
        assert.ok(ninety.unfunded > 0, "no recycling: 90% of the sum leaves a step unfunded");
        assert.ok(ninety.shortfallAccts > 0 || ninety.debtLeft.gt(0), "the 90% inventory leaves debt behind");
      }
    });
  };
  const only = process.env.CYCLE_ONLY; // debugging / mutation-testing aid: run one case group (1, 2, 3, 5), the discipline tests (e) or "quick" (a small cut of all)
  if (!only || only === "1") {
    for (const cf of [3000, 4000]) await case1(cf, 5_000, 3_500);
    await case1(3000, 1_000, 3_500);
    await case1(3000, 10_000, 3_500);
    await case1(3000, 5_000, 1_000);
  }

  // ============================================================ CASE 2: concurrent borrowers, two operators
  const case2 = async (cf: number, cap: number, n: number) => {
    await t.test(`case 2: PW${cf / 100} cap ${cap}, ${n} borrowers, gap 35%: interleaved operators with cap/2 each`, async () => {
      const seq = await fresh({ ...baseCfg("seq", cf, cap, n, 3_500) });
      assert.equal(seq.shortfallAccts, 0, "sequential: all accounts cleared");
      assert.equal(seq.bad6.toString(), "0");
      approx(seq.repaid, seq.debt0.mul(75).div(100), 5, "total repaid = 0.75 x debt");
      const half = U(cap / 2);
      const inter = await fresh({ ...baseCfg("inter", cf, cap, n, 3_500), interleave: true, bUp: true, invA: half, invB: half });
      assert.equal(inter.halted, false);
      assert.equal(inter.unfunded, 0, "interleaved: the first-round inventory per operator suffices with recycling");
      assert.equal(inter.shortfallAccts, 0, "all accounts cleared");
      approx(inter.repaid, seq.repaid, 5, "same total repayments as sequential");
      assert.ok(inter.peakNeed[0].gt(0) && inter.peakNeed[1].gt(0), "both operators worked");
      const norInter = await fresh({ ...baseCfg("norinter", cf, cap, n, 3_500), convert: false, interleave: true, bUp: true, invA: half, invB: half });
      assert.ok(norInter.repaid.lte(half.mul(2)), "no recycling: repayments bounded by the inventories");
      const seqNor = await fresh({ ...baseCfg("seqnor", cf, cap, n, 3_500), convert: false });
      approx(seqNor.repaid, seq.repaid, 2, "same repayments without recycling");
      const exact = await fresh({ ...baseCfg("exact", cf, cap, n, 3_500), invA: seq.peakNeed[0] });
      assert.equal(exact.unfunded, 0, "the peak need funds every step");
      assert.equal(exact.shortfallAccts, 0);
      const less = await fresh({ ...baseCfg("less", cf, cap, n, 3_500), invA: seq.peakNeed[0].sub(1) });
      assert.ok(less.unfunded > 0, "one unit less leaves a step unfunded");
    });
  };
  if (!only || only === "2") {
    await case2(3000, 5_000, 3);
    await case2(3000, 5_000, 5);
    await case2(4000, 5_000, 3);
    await case2(3000, 1_000, 5);
  }

  // ============================================================ CASE 3: one operator unavailable (A down, B covers everything)
  const case3 = async (cf: number, cap: number, n: number, div: number, convert: boolean) => {
    await t.test(`case 3: PW${cf / 100} cap ${cap}, ${n} borrowers, operator B alone with cap/${div}, ${convert ? "recycling" : "no recycling"}`, async () => {
      const r = await fresh({ ...baseCfg("c3", cf, cap, n, 3_500), aUp: false, bUp: true, invA: BigNumber.from(0), invB: U(cap / div), convert, stage2Bp: 6_000 });
      assert.equal(r.halted, false);
      dbg(`case3 result: unfunded=${r.unfunded} shortfall=${r.shortfallAccts} bad6=${r.bad6.toString()} S2 shortfall=${r.shortfallAcctsS2} bad6S2=${r.bad6S2.toString()} debtLeft=${r.debtLeft.toString()} repaid=${r.repaid.toString()} debt0=${r.debt0.toString()}`);
      assert.equal(r.invEnd[0].toString(), "0", "operator A (unavailable) held and received nothing");
      if (convert) {
        assert.equal(r.unfunded, 0, "recycling restores the inventory every round: all rounds funded");
        assert.equal(r.shortfallAccts, 0, "no account left in shortfall");
        assert.equal(r.bad6S2.toString(), "0", "no bad debt at the second fall");
      } else {
        assert.ok(r.unfunded > 0, "without recycling the half-cap inventory runs out");
        assert.ok(r.shortfallAccts > 0, "accounts stay in shortfall");
        // NOT asserted: bad debt at the second fall. The Foundry study works borrower by borrower (finish one, start the next) and measures USD 26.6 to 133.0
        // there; the executor serves the account with the LARGEST shortfall first, which spreads the same repayments over all accounts (one round each), and in
        // this scenario that leaves no bad debt at -60%. Recorded, not asserted, because it depends on the ordering policy.
        dbg(`case 3 no-recycling: bad debt at the second fall = ${r.bad6S2.toString()} (study, borrower-by-borrower order: positive)`);
      }
    });
  };
  if (!only || only === "3") {
    await case3(3000, 5_000, 5, 2, true);
    await case3(3000, 5_000, 5, 4, true);
    await case3(3000, 5_000, 5, 2, false);
    await case3(3000, 1_000, 3, 2, false);
    await case3(4000, 5_000, 3, 2, true);
  }

  // ============================================================ CASE 5: the min-out limit blocks the conversion
  const case5 = async (cf: number, n: number, div: number, adverse: number, limit: number, expectBlocked: boolean) => {
    await t.test(`case 5: PW${cf / 100}, ${n} borrowers, inventory cap/${div}, adverse pool move ${adverse} bp, limit ${limit} bp -> ${expectBlocked ? "conversion BLOCKED, no fallback" : "swaps proceed"}`, async () => {
      const snap = await chain.snapshot();
      try {
        const c = { ...baseCfg("c5", cf, 5_000, n, 3_500), invA: U(5_000 / div), adverseBp: adverse, limitBp: limit };
        const { res, alerts } = await runInner(c);
        assert.equal(res.halted, false, "a blocked swap is NOT a halt");
        if (expectBlocked) {
          assert.ok(res.blocked > 0, "the limit blocks the conversion");
          assert.equal(res.swaps, 0, "no conversion happened");
          assert.ok(res.wavaxHeld.gt(0), "the operator is left holding WAVAX (no second route, limit not loosened)");
          assert.equal((await new Contract(WAVAX, erc20Abi, chain.provider).allowance(OP[0], UNIV3_SWAP_ROUTER02)).toString(), "0", "no allowance left to the router");
          assert.ok(Object.keys(alerts.toJson().active).some((k) => k.startsWith("executor:swap-blocked:")), "a critical alert says the conversion is blocked");
          if (div === 2 && n === 1) {
            approx(res.repaid, res.debt0.div(2), 5, "only the first round is funded (0.50 x debt)");
            assert.ok(res.unfunded > 0 && res.shortfallAccts === 1, "second round unfunded, 1 account left in shortfall");
          }
          if (div === 1) approx(res.repaid, res.debt0.mul(75).div(100), 5, "inventory = cap: both rounds are funded without any swap (0.75 x debt)");
          if (n === 5) assert.ok(res.shortfallAccts >= 1 && res.unfunded > 0, "five borrowers: unfunded steps and accounts left in shortfall");
        } else {
          assert.ok(res.swaps > 0 && res.blocked === 0, "swaps proceed inside the limit");
          assert.ok(res.minRatioBp >= 9_940, `output vs oracle >= 99.4% (worst ${res.minRatioBp} bp)`);
          assert.equal(res.shortfallAccts, 0);
        }
      } finally {
        await chain.revert(snap);
        avaxAnswer = realAvax;
      }
    });
  };
  if (!only || only === "5") for (const cf of [3000, 4000]) {
    await case5(cf, 1, 2, 300, 100, true);
    await case5(cf, 1, 1, 300, 100, true);
    await case5(cf, 1, 2, 30, 100, false);
    await case5(cf, 1, 2, 100, 50, true);
  }
  if (!only || only === "5") await case5(3000, 5, 2, 300, 100, true);

  if (only === "quick") {
    await case1(3000, 5_000, 3_500);
    await case5(3000, 1, 2, 300, 100, true);
    await case5(3000, 1, 2, 30, 100, false);
  }
  // ============================================================ discipline of the executor itself
  const scenario = async (c: Cfg = baseCfg("e", 3000, 5_000, 1, 3_500)) => {
    const { borrowers } = await openBorrowers(c);
    await chain.setErc20Balance(USDC, OP[0]!, c.invA);
    await chain.setErc20Balance(USDC, OP[1]!, BigNumber.from(0));
    await chain.setErc20Balance(WAVAX, OP[0]!, BigNumber.from(0));
    const sink = new MemorySink();
    const alerts = new AlertManager(sink, [3600]);
    const states: ExecutorState[] = [emptyExecutorState(), emptyExecutorState()];
    return { borrowers, sink, alerts, states };
  };
  const nonce = (k: number) => chain.provider.getTransactionCount(OP[k]!);
  const inSnapshot = async (name: string, fn: () => Promise<void>) =>
    t.test(name, async () => {
      const snap = await chain.snapshot();
      try {
        await fn();
      } finally {
        await chain.revert(snap);
        avaxAnswer = realAvax;
      }
    });

  await inSnapshot("executor: refuses to act on a stale or a zero oracle price (accounts in shortfall are left alone)", async () => {
    const s = await scenario();
    await chain.increaseTime(1_201); // the AVAX feed is now older than the 1,200 s guard
    let o = await executorStep(depsFor(0, s.borrowers, s.states, s.alerts, 100), s.states[0]!);
    assert.equal(await nonce(0), 0, "no transaction at a stale price");
    assert.ok(o.skipped.some((x) => /oracle price unavailable/.test(x)));
    await refresh();
    avaxAnswer = BigNumber.from(0);
    await refresh();
    o = await executorStep(depsFor(0, s.borrowers, s.states, s.alerts, 100), s.states[0]!);
    assert.equal(await nonce(0), 0, "no transaction at a zero answer");
    assert.equal(o.round, undefined);
    avaxAnswer = realAvax;
    await refresh();
    o = await executorStep(depsFor(0, s.borrowers, s.states, s.alerts, 100), s.states[0]!);
    assert.ok(o.round, "with a healthy price it liquidates");
  });
  await inSnapshot("executor: a pending marker at start-up or a halted state stops everything; a wrong signer is refused", async () => {
    const s = await scenario();
    s.states[0] = { ...emptyExecutorState(), pending: { stage: "swap", borrower: s.borrowers[0]!, at: 1 } };
    let o = await executorStep(depsFor(0, s.borrowers, s.states, s.alerts, 100), s.states[0]!);
    assert.equal(o.halted, true);
    assert.equal(await nonce(0), 0);
    assert.ok(s.sink.messages.some((m) => m.key.startsWith("executor:halted:") && m.severity === "crit"));
    s.states[0] = { ...emptyExecutorState(), halted: { reason: "test", at: 1 } };
    o = await executorStep(depsFor(0, s.borrowers, s.states, s.alerts, 100), s.states[0]!);
    assert.equal(o.round, undefined);
    assert.equal(await nonce(0), 0, "halted: no transaction although an account is in shortfall");
    await assert.rejects(verifyExecutorSigner(signers[1]!, cfgFor(0), chain.provider), /is not the configured address/);
  });
  await inSnapshot("executor: fee above the cap and AVAX below the floor -> no transaction", async () => {
    const s = await scenario();
    let o = await executorStep(depsFor(0, s.borrowers, s.states, s.alerts, 100, undefined, { maxFeeGwei: 1 }), s.states[0]!);
    assert.equal(await nonce(0), 0);
    assert.ok(o.skipped.some((x) => /above the cap/.test(x)));
    o = await executorStep(depsFor(0, s.borrowers, s.states, s.alerts, 100, undefined, { minGasWei: "1" + "0".repeat(30) }), s.states[0]!);
    assert.equal(await nonce(0), 0);
    assert.ok(o.skipped.some((x) => /below the floor/.test(x)));
    assert.ok(Object.keys(s.alerts.toJson().active).some((k) => k.startsWith("executor:gas:")), "a critical gas alert");
  });
  await inSnapshot("executor: a competing liquidator is first -> the simulation fails, the allowance is reset, a cooldown prevents a retry storm, no halt", async () => {
    const s = await scenario();
    // a signer that lets a competitor liquidate the same borrower right after the executor's USDC approval was mined
    const base = signers[0]!;
    const racing: ExternalSigner = {
      kind: "test-race", getAddress: () => base.getAddress(),
      sendTransaction: async (tx: TxRequest) => {
        const sent = await base.sendTransaction(tx);
        const m = await sent.wait();
        if (tx.to.toLowerCase() === USDC.toLowerCase() && !raced) {
          raced = true;
          const half: BigNumber = (await d.pUsdc.callStatic.borrowBalanceCurrent(s.borrowers[0])).div(2);
          await fund(USDC, COMPETITOR, half);
          await ok(new Contract(USDC, erc20Abi, chain.signer(COMPETITOR)).approve(d.pUsdc.address, half));
          await ok(d.pUsdc.connect(chain.signer(COMPETITOR)).liquidateBorrow(s.borrowers[0], half, d.pWavax.address));
        }
        return { hash: sent.hash, wait: async () => m };
      },
    };
    let raced = false;
    const o = await executorStep(depsFor(0, s.borrowers, s.states, s.alerts, 100, racing), s.states[0]!);
    assert.equal(o.halted, false, "losing a race is not an emergency");
    assert.equal(o.round, undefined);
    assert.match(o.skipped.join(" | "), /simulation failed|reverted/);
    assert.equal((await new Contract(USDC, erc20Abi, chain.provider).allowance(OP[0], d.pUsdc.address)).toString(), "0", "allowance reset to 0");
    assert.ok(Object.keys(s.states[0]!.cooldown).length === 1 && Object.values(s.states[0]!.cooldown)[0]! > (await chain.now()), "cooldown set");
    assert.equal(s.states[0]!.pending, null, "pending marker cleared");
  });
  await inSnapshot("executor: the swap reverts at the min-out between simulation and send -> blocked (allowance reset, WAVAX held), not a halt", async () => {
    const s = await scenario();
    const base = signers[0]!;
    let pushed = false;
    const sgn: ExternalSigner = {
      kind: "test-pool-move", getAddress: () => base.getAddress(),
      sendTransaction: async (tx: TxRequest) => {
        if (tx.to.toLowerCase() === UNIV3_SWAP_ROUTER02.toLowerCase() && !pushed) {
          pushed = true;
          await pushPoolDown(300); // the pool moves after the simulation passed
        }
        return base.sendTransaction(tx);
      },
    };
    const o = await executorStep(depsFor(0, s.borrowers, s.states, s.alerts, 100, sgn), s.states[0]!);
    assert.equal(o.halted, false);
    assert.equal(o.swapBlocked, true);
    assert.ok(o.round && !o.round.usdcOut && o.round.swapBlocked, "the round is recorded as blocked");
    assert.ok((await balOf(WAVAX, OP[0]!)).gt(0), "the WAVAX stays in the wallet");
    assert.equal((await new Contract(WAVAX, erc20Abi, chain.provider).allowance(OP[0], UNIV3_SWAP_ROUTER02)).toString(), "0");
    assert.equal(s.states[0]!.pending, null);
  });
  await inSnapshot("executor: WAVAX held after a blocked swap is converted by a LATER step once the conversion is inside the limit again (no second route, no loosened limit in between)", async () => {
    const s = await scenario();
    await pushPoolDown(100); // the pool is 100 bp below the oracle
    const blockedStep = await executorStep(depsFor(0, s.borrowers, s.states, s.alerts, 50), s.states[0]!); // limit 50 bp: blocked
    s.states[0] = blockedStep.state;
    assert.equal(blockedStep.swapBlocked, true);
    const held = await balOf(WAVAX, OP[0]!);
    assert.ok(held.gt(0), "WAVAX held");
    assert.ok(Object.keys(s.alerts.toJson().active).some((k) => k.startsWith("executor:swap-blocked:")));
    // the operator has no USDC left: without converting the WAVAX it holds it CANNOT liquidate again
    await chain.setErc20Balance(USDC, OP[0]!, BigNumber.from(0));
    const next = await executorStep(depsFor(0, s.borrowers, s.states, s.alerts, 300), s.states[0]!); // limit 300 bp: inside the limit now
    s.states[0] = next.state;
    assert.equal(next.halted, false);
    assert.ok(next.round, "the leftover conversion restored the inventory, so the SAME step liquidates again (impossible with zero USDC otherwise)");
    assert.equal((await balOf(WAVAX, OP[0]!)).toString(), "0", "the held WAVAX was converted");
    assert.equal(Object.keys(s.alerts.toJson().active).some((k) => k.startsWith("executor:swap-blocked:")), false, "the blocked alert resolved once a swap went through");
  });
  await inSnapshot("executor: an unexpected error while sending the swap -> allowances revoked and the executor HALTS", async () => {
    const s = await scenario();
    const base = signers[0]!;
    const sgn: ExternalSigner = {
      kind: "test-break", getAddress: () => base.getAddress(),
      sendTransaction: async (tx: TxRequest) => {
        if (tx.to.toLowerCase() === UNIV3_SWAP_ROUTER02.toLowerCase()) throw new Error("simulated provider failure");
        return base.sendTransaction(tx);
      },
    };
    const o = await executorStep(depsFor(0, s.borrowers, s.states, s.alerts, 100, sgn), s.states[0]!);
    assert.equal(o.halted, true);
    assert.equal((await new Contract(WAVAX, erc20Abi, chain.provider).allowance(OP[0], UNIV3_SWAP_ROUTER02)).toString(), "0", "no allowance left to the router");
    assert.equal((await new Contract(USDC, erc20Abi, chain.provider).allowance(OP[0], d.pUsdc.address)).toString(), "0");
    assert.ok(s.states[0]!.pending, "the pending marker stays so that a human sees where it stopped");
    assert.ok(s.sink.messages.some((m) => m.key.startsWith("executor:halted:")));
    const again = await executorStep(depsFor(0, s.borrowers, s.states, s.alerts, 100), s.states[0]!);
    assert.equal(again.round, undefined);
    void sinkOf;
  });
});

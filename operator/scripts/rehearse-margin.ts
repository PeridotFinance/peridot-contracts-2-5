// R-B / R-C REHEARSAL of the operator's margin handling, on a LOCAL anvil fork of the current Avalanche head (nothing real is signed or sent):
//   * the real PW30 lending stack + the real margin stack are deployed by the real ceremony wrappers (scripts/margin-fork-lib.ts);
//   * the two operators are THROWAWAY Foundry keystores created inside this run and are the funded liquidators of the stack;
//   * the monitor (runCycle), the treasury keeper (keeperStep, with a signer that records and refuses to send) and the liquidator executor
//     (executorStep, the margin step) run against it, with the AVAX/USD Chainlink feed replaced on the FORK by a settable mock;
//   * every scenario starts from the same snapshot; every MUTATION (a deliberately broken rule) is run through the scenario that must catch it.
// Usage:  AVALANCHE_MAINNET_RPC_URL=... node dist/scripts/rehearse-margin.js [--out evidence.json]
// Exit code 0 = every check passed AND every mutation was detected.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { BigNumber, Contract, Wallet, utils } from "ethers";
import { AlertManager, MemorySink } from "../src/alerts";
import { requireValidConfig } from "../src/config";
import type { MonitorConfig } from "../src/config";
import { emptyExecutorState, executorStep } from "../src/executor";
import type { ExecutorState } from "../src/executor";
import { emptyKeeperState, keeperStep } from "../src/keeper";
import { emptyMonitorState, runCycle } from "../src/monitor";
import type { CycleReport, MonitorState } from "../src/monitor";
import { KeystoreSigner } from "../src/signer";
import type { ExternalSigner } from "../src/signer";
import { AVAX_FEED, USDC } from "../src/constants";
import { safeError } from "../src/mask";
import { decidedConfig } from "../test/fixtures";
import { ForkChain } from "../test/fork/harness";
import { abi, bringUpMarginFork, openLong, okTx } from "./margin-fork-lib";
import type { BroughtUp } from "./margin-fork-lib";

const KS_PASSWORD = "fork-rehearsal-only-password-7c1e"; // protects THROWAWAY keystores that exist only for this local-fork run
const BORROWER = "0x00000000000000000000000000000000000B0A01";
const PW = "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7"; // WAVAX
const erc = ["function balanceOf(address) view returns (uint256)", "function allowance(address,address) view returns (uint256)", "function approve(address,uint256) returns (bool)"];
const U6 = (n: number): bigint => BigInt(Math.round(n * 1e6));
const ci = (x: number): number => Math.max(1, Math.floor(x)); // whole USD for the configuration

interface Check {
  scenario: string;
  name: string;
  pass: boolean;
  detail: string;
}
const checks: Check[] = [];
let currentScenario = "";
function check(name: string, pass: boolean, detail = ""): boolean {
  checks.push({ scenario: currentScenario, name, pass, detail });
  console.log(`  ${pass ? "PASS" : "FAIL"}  ${name}${detail ? "  [" + detail + "]" : ""}`);
  return pass;
}

interface Mut {
  monitorNoClassifier?: boolean;
  execNoClassifier?: boolean;
  noAllowanceBound?: boolean;
  noDailyCap?: boolean;
  noFloor?: boolean; // the on-chain floor AND the insolvent pre-filter are both removed
}

(async () => {
  const outIdx = process.argv.indexOf("--out");
  const report: Record<string, any> = { startedAt: new Date().toISOString() };
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "rehearse-margin-"));
  const chain = await ForkChain.start("latest");
  let failed = false;
  try {
    // ---- throwaway operator keystores (they are the funders of the margin stack)
    const wallets = [Wallet.createRandom(), Wallet.createRandom(), Wallet.createRandom()]; // op-a, op-b, op-c (NOT a funder)
    const ks: string[] = [];
    for (let i = 0; i < 3; i++) {
      const f = path.join(tmp, `ks-${i}.json`);
      fs.writeFileSync(f, await wallets[i]!.encrypt(KS_PASSWORD, { scrypt: { N: 1024 } }), { mode: 0o600 });
      ks.push(f);
    }
    const addr = wallets.map((w) => w.address);
    const signerOf = (i: number): Promise<KeystoreSigner> => KeystoreSigner.load(chain.provider, ks[i]!, "OPERATOR_KEYSTORE_PASSWORD", { OPERATOR_KEYSTORE_PASSWORD: KS_PASSWORD });

    // R-D: the pipeline log. Every ceremony step is run by the real wrapper; what it prints (rehearsal only: public addresses, no secret) is condensed here.
    console.log("== PIPELINE: PW30 ceremony, then margin stages 1-4 (real wrappers, impersonated accounts on the fork)");
    const keep = /(verify|stage|passed|deployed|pass|ok\b|queued|executed|unpause|opens|owner|hook|funded|check)/i;
    const b: BroughtUp = await bringUpMarginFork(chain, {
      funders: [addr[0]!, addr[1]!],
      onStep: (name, out) => {
        const lines = out.split("\n").map((l) => l.trim()).filter((l) => l && keep.test(l) && !/^(Warning|warning|Compiler|Solc|Script ran|##|====)/.test(l));
        console.log(`  [${name}] ${out.split("\n").length} lines of output; ${lines.length} status lines`);
        for (const l of lines.slice(-6)) console.log(`      ${l.slice(0, 160)}`);
      },
    });
    const forkHead: number = b.report.forkHead;
    report.forkHead = forkHead;
    for (const a of addr) await chain.setBalance(a, utils.parseEther("1000"));
    const M = b.deployed;
    const CAP = b.capUsd; // the pilot's one sizing number: every amount below is a ratio of it (0.89 operator inventory, 0.5 margin, 0.3 / 0.5 caps)
    report.capUsd = CAP;
    const avaxUsd = Number(b.realAvax.toString()) / 1e8;
    for (const a of addr) await chain.setErc20Balance(USDC, a, BigNumber.from(U6(CAP * 0.89).toString())); // operator inventory 0.89 x CAP
    const usdcC = new Contract(USDC, erc, chain.provider);
    const pUsdcC: any = new Contract(b.pw.pUsdc, ["function borrowBalanceStored(address) view returns (uint256)", "function balanceOf(address) view returns (uint256)", "function mint(uint256) returns (uint256)", "function borrow(uint256) returns (uint256)"], chain.provider);
    const pWavaxC: any = new Contract(b.pw.pWavax, ["function balanceOf(address) view returns (uint256)", "function mint(uint256) returns (uint256)"], chain.provider);
    const wavaxC = new Contract(PW, erc, chain.provider);
    const ctrlC: any = new Contract(b.pw.controller, ["function enterMarkets(address[]) returns (uint256[])"], chain.provider);
    const riskC: any = new Contract(M.M_RISK_ENGINE!, abi("IsolatedMarginRiskEngine"), chain.provider);
    const execC: any = new Contract(M.M_EXECUTOR!, abi("IsolatedMarginExecutor"), chain.provider);
    const avaxFeed = b.mocks.feed(AVAX_FEED);
    const setAvaxBps = async (bps: number): Promise<void> => {
      const now = await chain.now();
      const answer = b.realAvax.mul(bps).div(10_000);
      await okTx(avaxFeed.set(answer, now));
      await okTx(b.mocks.feed("0xF096872672F44d6EBA71458D74fe67F9a77a23B9").set(b.realUsdc, now));
    };
    await setAvaxBps(10_000);

    // ---- the standing state: one 2x position for ALICE, one lending borrower (collateral WAVAX at 30%, borrows 500 USDC: healthy at every price used below; a second, fragile one is made in S6)
    const pos1 = await openLong(chain, b, "0x000000000000000000000000000000000000A11C", U6(process.env.REHEARSE_POSITION_MARGIN_USDC ? Number(process.env.REHEARSE_POSITION_MARGIN_USDC) : CAP * 0.5)); // margin = half the position cap (REHEARSE_POSITION_MARGIN_USDC overrides it, to try pilot-size positions)
    const acct1 = pos1.account.toLowerCase();
    await chain.setBalance(BORROWER, utils.parseEther("1000"));
    await chain.setErc20Balance(PW, BORROWER, BigNumber.from("1000000000000000000000"));
    const bs = chain.signer(BORROWER);
    await okTx(new Contract(PW, erc, bs).approve(b.pw.pWavax, BigNumber.from("1000000000000000000000")));
    await okTx(pWavaxC.connect(bs).mint(BigNumber.from("1000000000000000000000")));
    await okTx(ctrlC.connect(bs).enterMarkets([b.pw.pWavax]));
    await okTx(pUsdcC.connect(bs).borrow(BigNumber.from(U6(CAP * 0.1).toString())));
    report.position = pos1;

    // ---- configuration
    const mkCfg = (over: (c: any) => void = () => {}): MonitorConfig => {
      const c: any = decidedConfig();
      c.deployment = { controller: b.pw.controller, pWavax: b.pw.pWavax, pUsdc: b.pw.pUsdc, oracle: b.pw.oracle, deploymentBlock: forkHead + 1 }; // the log scans stay on LOCAL blocks (older blocks would go to the upstream endpoint)
      c.operators = [{ name: "op-a", address: addr[0] }, { name: "op-b", address: addr[1] }, { name: "op-c", address: addr[2] }];
      c.executor = { ...c.executor, enabled: true, operator: "op-a", keystorePath: ks[0], convertToUsdc: true, minRepayUsdc: 1, maxFeeGwei: 1000 };
      c.keeper.enabled = false;
      c.monitor.logChunkBlocks = 2000;
      c.margin = {
        enabled: true, executor: M.M_EXECUTOR, liquidator: M.M_LIQUIDATOR, riskEngine: M.M_RISK_ENGINE, config: M.M_CONFIG, watchHealthBps: 13000,
        liquidation: { enabled: true, dailyRepayCapUsdc: ci(CAP * 0.5), maxRepayPerCallUsdc: ci(CAP * 0.3), minRepayUsdc: 1, retryCooldownSeconds: 30, insolventCooldownSeconds: 600 },
      };
      over(c);
      return requireValidConfig(c);
    };
    const ctxOf = (cfg: MonitorConfig) => ({ provider: chain.provider, cfg, poolIdentityOk: true });

    let snap = await chain.snapshot();
    const fresh = async (): Promise<void> => {
      await chain.revert(snap);
      snap = await chain.snapshot();
      await setAvaxBps(10_000);
    };

    // ---- helpers
    const near = (a: bigint, b: bigint, tol = 5_000n): boolean => (a > b ? a - b : b - a) <= tol; // interest accrues between reads (a few micro-USDC)
    const nonce = (i: number): Promise<number> => chain.provider.getTransactionCount(addr[i]!);
    const debtOf = async (a: string): Promise<bigint> => BigInt((await pUsdcC.borrowBalanceStored(a)).toString());
    const usdcOf = async (a: string): Promise<bigint> => BigInt((await usdcC.balanceOf(a)).toString());
    const allowanceTo = async (i: number): Promise<bigint> => BigInt((await usdcC.allowance(addr[i]!, M.M_LIQUIDATOR)).toString());
    const monitor = async (cfg: MonitorConfig, hooks?: { noClassifier?: boolean }): Promise<{ report: CycleReport; state: MonitorState; sink: MemorySink }> => {
      const sink = new MemorySink();
      const out = await runCycle(ctxOf(cfg), emptyMonitorState(cfg), new AlertManager(sink, cfg.monitor.escalationSeconds), { hooks });
      return { ...out, sink };
    };
    const execStep = async (cfg: MonitorConfig, signerIdx: number, accounts: string[], st: ExecutorState, mut: Mut = {}, sink = new MemorySink()) => {
      const signer = await signerOf(signerIdx);
      let state = st;
      const o = await executorStep(
        {
          ctx: ctxOf(cfg), signer, alerts: new AlertManager(sink, cfg.monitor.escalationSeconds), slippageBoundBp: cfg.execution.slippageBoundBp, accounts: async () => accounts,
          persist: (s: ExecutorState) => { state = s; },
          testHooks: { noMarginClassifier: mut.execNoClassifier, noAllowanceBound: mut.noAllowanceBound, noDailyCap: mut.noDailyCap, noInsolventPrefilter: mut.noFloor, minSeizeValueBps: mut.noFloor ? 0 : undefined },
        },
        st,
      );
      return { o, state: o.state ?? state, sink };
    };
    const keeperCheck = async (cfg: MonitorConfig, rep: CycleReport): Promise<{ paid: number; sent: number }> => {
      let sent = 0;
      const stub: ExternalSigner = { kind: "recording-stub", getAddress: async () => cfg.treasury.address, sendTransaction: async () => { sent++; throw new Error("the rehearsal keeper must never send"); } };
      const kcfg: MonitorConfig = { ...cfg, executor: { ...cfg.executor, enabled: false }, keeper: { ...cfg.keeper, enabled: true } };
      const o = await keeperStep({ ctx: ctxOf(kcfg), signer: stub, alerts: new AlertManager(new MemorySink(), cfg.monitor.escalationSeconds), persist: () => {} }, emptyKeeperState(), rep);
      return { paid: o.paid.length, sent };
    };
    const scenario = async (name: string, fn: () => Promise<void>): Promise<void> => {
      currentScenario = name;
      console.log(`\n== ${name}`);
      await fresh();
      try {
        await fn();
      } catch (e) {
        check("scenario ran without an unexpected error", false, safeError(e));
      }
    };

    const cfg = mkCfg();
    const allBorrowers = async (): Promise<string[]> => (await monitor(cfg)).state.index.borrowers;

    // =========================================================== S0: a healthy margin account is invisible to the lending machinery
    const S0 = async (m: Mut): Promise<void> => {
      const mon = await monitor(cfg, m.monitorNoClassifier ? { noClassifier: true } : undefined);
      const r = mon.report;
      check("the controller flags exactly the margin account (classified = 1)", r.margin.classified === 1, `classified ${r.margin.classified}`);
      check("margin position 1 is read and HEALTHY", r.margin.positions.length === 1 && r.margin.positions[0]!.verdict === "HEALTHY" && r.margin.positions[0]!.account === acct1, JSON.stringify(r.margin.positions[0]));
      check("the margin account is NOT in the lending verdict list", !r.accounts.some((a) => a.account === acct1), `accounts: ${r.accounts.map((a) => a.account.slice(0, 8) + ":" + a.verdict).join(", ")}`);
      check("the lending borrower is still evaluated (HEALTHY)", r.accounts.some((a) => a.account === BORROWER.toLowerCase() && a.verdict === "HEALTHY"));
      check("no lending finding names the margin account", !r.findings.some((f) => f.key.includes(acct1)), r.findings.map((f) => f.key).join(", "));
      const n0 = await nonce(0);
      const ex = await execStep(cfg, 0, mon.state.index.borrowers, emptyExecutorState(), m);
      check("the lending executor sends NO transaction (no approve/reset pair for the margin account)", (await nonce(0)) === n0 && !ex.o.round, `nonce ${n0} -> ${await nonce(0)}; skipped: ${ex.o.skipped.join(" | ")}`);
    };
    await scenario("S0 healthy margin account", () => S0({}));

    // =========================================================== S1: -35%: the operator liquidates through the funded route
    let s1Repaid = 0n;
    const S1 = async (): Promise<void> => {
      await setAvaxBps(6_500);
      const mon = await monitor(cfg);
      const r = mon.report;
      check("monitor: position 1 is LIQUIDATABLE", r.margin.positions[0]?.verdict === "LIQUIDATABLE", r.margin.positions[0]?.verdict);
      const f = r.findings.find((x) => x.key === "margin:1:LIQUIDATABLE");
      check("monitor: a warn finding for the liquidators", !!f && f.severity === "warn" && f.audience === "liquidators");
      check("monitor: nothing for the treasury signers (no lending finding, expected treasury call 0)", r.expectedTreasuryCall === "0" && !r.findings.some((x) => x.audience === "treasury-signers" && x.key.startsWith("acct:")));
      const k = await keeperCheck(cfg, r);
      check("keeper: pays nothing and sends nothing", k.paid === 0 && k.sent === 0, `paid ${k.paid}, sent ${k.sent}`);
      const debt0 = await debtOf(acct1);
      const inv0 = await usdcOf(addr[0]!);
      const n0 = await nonce(0);
      const sink = new MemorySink();
      const ex = await execStep(cfg, 0, mon.state.index.borrowers, emptyExecutorState(), {}, sink);
      const round = ex.o.round;
      check("executor op-a: one margin round on position 1", !!round && round.marginPositionId === "1", JSON.stringify(round ?? ex.o.skipped));
      const debt1 = await debtOf(acct1);
      const inv1 = await usdcOf(addr[0]!);
      s1Repaid = round ? BigInt(round.repay) : 0n;
      check("the debt fell by the repaid amount (to within accrued interest)", near(debt0 - debt1, s1Repaid) && s1Repaid > 0n, `repaid ${s1Repaid}, debt ${debt0} -> ${debt1}`);
      check("the operator's allowance to the liquidator is back to 0", (await allowanceTo(0)) === 0n);
      check("the operator holds no pWAVAX and no WAVAX (redeemed and converted)", BigInt((await pWavaxC.balanceOf(addr[0]!)).toString()) === 0n && BigInt((await wavaxC.balanceOf(addr[0]!)).toString()) === 0n);
      check("USDC inventory is not lower than before (oracle-only shock: the pool pays the real price)", inv1 >= inv0, `inventory ${inv0} -> ${inv1}`);
      check("repayment is within the per-call bound (0.3 x CAP)", s1Repaid <= U6(ci(CAP * 0.3)), `${s1Repaid}`);
      check("state: one margin round recorded, nothing pending, not halted", (ex.state.marginRounds?.length ?? 0) === 1 && ex.state.pending === null && ex.state.halted === null);
      check("an action alert was sent", sink.messages.some((x) => x.kind === "action" && /LIQUIDATED margin position 1/.test(x.text)));
      report.s1 = { repaid: s1Repaid.toString(), seizedPTokens: round?.seizedPTokens, usdcOut: round?.usdcOut, txs: (await nonce(0)) - n0 };
      // the second operator finds the position back above maintenance: nothing to do
      const mon2 = await monitor(cfg);
      const n1 = await nonce(1);
      const ex2 = await execStep(cfg, 1, mon2.state.index.borrowers, emptyExecutorState());
      const still = mon2.report.margin.positions[0]?.verdict;
      check("op-b: no second liquidation when the position is back above maintenance", still !== "LIQUIDATABLE" ? (await nonce(1)) === n1 && !ex2.o.round : true, `verdict after op-a: ${still}`);
    };
    await scenario("S1 -35%: funded liquidation by op-a", S1);

    // =========================================================== S2: -55%: insolvent, declined, nothing is paid
    const big = mkCfg((c) => { c.margin.liquidation.dailyRepayCapUsdc = ci(CAP * 0.5); c.margin.liquidation.maxRepayPerCallUsdc = ci(CAP * 0.5); }); // caps above the repayment the engine wants: only the floor can stop it
    const S2 = async (m: Mut): Promise<void> => {
      await setAvaxBps(4_500);
      const mon = await monitor(big);
      const r = mon.report;
      check("monitor: position 1 is INSOLVENT", r.margin.positions[0]?.verdict === "INSOLVENT", r.margin.positions[0]?.verdict);
      const f = r.findings.find((x) => x.key === "margin:1:INSOLVENT");
      check("monitor: critical, escalating, addressed to the treasury signers as a human decision", !!f && f.severity === "crit" && f.escalates === true && f.audience === "treasury-signers");
      check("monitor: the margin deficit is in the unrecoverable-debt figure", BigInt(r.unrecoverableDebt.rawUsd) > 0n, r.unrecoverableDebt.rawUsd);
      check("monitor: no lending verdict and no expected treasury call for the margin account", r.expectedTreasuryCall === "0" && !r.accounts.some((a) => a.account === acct1));
      const k = await keeperCheck(big, r);
      check("keeper: pays nothing and sends nothing for the insolvent margin account", k.paid === 0 && k.sent === 0, `paid ${k.paid}, sent ${k.sent}`);
      const debt0 = await debtOf(acct1);
      const inv0 = await usdcOf(addr[0]!);
      const n0 = await nonce(0);
      const sink = new MemorySink();
      const ex = await execStep(big, 0, mon.state.index.borrowers, emptyExecutorState(), m, sink);
      const debt1 = await debtOf(acct1);
      check("executor op-a: DECLINES (margin debt untouched, no round)", near(debt1, debt0) && !ex.o.round, `debt ${debt0} -> ${debt1}; ${ex.o.skipped.join(" | ")}`);
      check("executor op-a: USDC inventory untouched", (await usdcOf(addr[0]!)) === inv0, `${inv0} -> ${await usdcOf(addr[0]!)}`);
      check("executor op-a: a critical 'declines' alert for the treasury signers", sink.messages.some((x) => x.severity === "crit" && x.audience === "treasury-signers" && /DECLINES margin position 1/.test(x.text)));
      check("executor op-a: allowance 0 afterwards", (await allowanceTo(0)) === 0n);
      if (!m.noFloor) check("executor op-a: the pre-filter sent no transaction at all", (await nonce(0)) === n0, `${n0} -> ${await nonce(0)}`);
      report.s2 = { unrecoverableRawUsd18: r.unrecoverableDebt.rawUsd };
    };
    await scenario("S2 -55%: insolvent position is declined", () => S2({}));

    // =========================================================== S2b: the on-chain floor refuses when the pre-filter is absent
    await scenario("S2b -55%: the break-even floor itself refuses (pre-filter removed)", async () => {
      await setAvaxBps(4_500);
      const mon = await monitor(big);
      const debt0 = await debtOf(acct1);
      const n0 = await nonce(0);
      const sink = new MemorySink();
      // only the pre-filter is removed; the on-chain floor stays at 10,000 bp
      const signer = await signerOf(0);
      let st = emptyExecutorState();
      const o = await executorStep(
        { ctx: ctxOf(big), signer, alerts: new AlertManager(sink, big.monitor.escalationSeconds), slippageBoundBp: big.execution.slippageBoundBp, accounts: async () => mon.state.index.borrowers, persist: (s) => { st = s; }, testHooks: { noInsolventPrefilter: true } },
        emptyExecutorState(),
      );
      check("simulation reverts with LiquidationError 32 and the step reports it", o.skipped.some((s) => /LiquidationError 32|break-even floor/.test(s)), o.skipped.join(" | "));
      check("debt untouched, allowance reset to 0", near(await debtOf(acct1), debt0) && (await allowanceTo(0)) === 0n);
      check("only the approve and the reset were sent (no liquidation)", (await nonce(0)) - n0 === 2, `txs: ${(await nonce(0)) - n0}`);
      check("a decline cooldown is recorded for the position", (st.cooldown["margin:1"] ?? 0) > 0);
    });

    // =========================================================== S3: the allowance bound and the daily cap
    const S3a = async (m: Mut): Promise<void> => {
      await setAvaxBps(6_500);
      const small = mkCfg((c) => { c.margin.liquidation.dailyRepayCapUsdc = ci(CAP * 0.5); c.margin.liquidation.maxRepayPerCallUsdc = ci(CAP * 0.02); });
      const mon = await monitor(small);
      const debt0 = await debtOf(acct1);
      const sink = new MemorySink();
      const ex = await execStep(small, 0, mon.state.index.borrowers, emptyExecutorState(), m, sink);
      const debt1 = await debtOf(acct1);
      check(`per-call bound ${ci(CAP * 0.02)} USDC (0.02 x CAP): the contract refuses the larger repayment (debt untouched)`, near(debt1, debt0) && !ex.o.round, `debt ${debt0} -> ${debt1}; ${ex.o.skipped.join(" | ")}`);
      check("allowance reset to 0", (await allowanceTo(0)) === 0n);
      if (!m.noAllowanceBound) check("an alert says the bound is too low for this position", sink.messages.some((x) => /needs a larger repayment|cannot liquidate margin/.test(x.text)));
    };
    await scenario("S3a per-call bound", () => S3a({}));

    const S3b = async (m: Mut): Promise<void> => {
      await setAvaxBps(6_500);
      const cap = mkCfg((c) => { c.margin.liquidation.dailyRepayCapUsdc = ci(CAP * 0.26); c.margin.liquidation.maxRepayPerCallUsdc = ci(CAP * 0.26); });
      const mon = await monitor(cap);
      const sink = new MemorySink();
      const ex1 = await execStep(cap, 0, mon.state.index.borrowers, emptyExecutorState(), m, sink);
      const repaid1 = ex1.o.round ? BigInt(ex1.o.round.repay) : 0n;
      check("first round within the daily cap", repaid1 > 0n && repaid1 <= U6(ci(CAP * 0.26)), `${repaid1}`);
      await setAvaxBps(5_200); // the position falls below maintenance again
      const mon2 = await monitor(cap);
      const debt0 = await debtOf(acct1);
      const ex2 = await execStep(cap, 0, mon2.state.index.borrowers, ex1.state, m, sink);
      const repaid2 = ex2.o.round ? BigInt(ex2.o.round.repay) : 0n;
      check(`the second attempt cannot exceed the daily cap (total repaid <= ${ci(CAP * 0.26)} USDC)`, repaid1 + repaid2 <= U6(ci(CAP * 0.26)), `first ${repaid1}, second ${repaid2}, debt ${debt0} -> ${await debtOf(acct1)}`);
      check("allowance reset to 0 after both", (await allowanceTo(0)) === 0n);
    };
    await scenario("S3b daily cap", () => S3b({}));

    // =========================================================== S4: an operator that is not a funded liquidator
    await scenario("S4 op-c is not a funded liquidator", async () => {
      await setAvaxBps(6_500);
      const cfgC = mkCfg((c) => { c.executor.operator = "op-c"; c.executor.keystorePath = ks[2]; });
      const mon = await monitor(cfgC);
      check("monitor: a warn finding that op-c is not a funder", mon.report.findings.some((f) => f.key === "margin:not-funder:op-c"));
      const n0 = await nonce(2);
      const sink = new MemorySink();
      const ex = await execStep(cfgC, 2, mon.state.index.borrowers, emptyExecutorState(), {}, sink);
      check("executor op-c: no transaction, no round, a warn alert", (await nonce(2)) === n0 && !ex.o.round && sink.messages.some((x) => /not a funded liquidator/.test(x.text)), ex.o.skipped.join(" | "));
    });

    // =========================================================== S5: interrupted step halts; configuration drift halts
    await scenario("S5 safety stops", async () => {
      await setAvaxBps(6_500);
      const mon = await monitor(cfg);
      const n0 = await nonce(0);
      const sink = new MemorySink();
      const interrupted: ExecutorState = { ...emptyExecutorState(), pending: { stage: "margin", borrower: acct1, at: 1 } };
      const ex = await execStep(cfg, 0, mon.state.index.borrowers, interrupted, {}, sink);
      check("a pending marker found at start HALTS the executor with no transaction", ex.o.halted && (await nonce(0)) === n0 && sink.messages.some((x) => /HALTED/.test(x.text)));
      const drift = mkCfg((c) => { c.margin.riskEngine = "0x00000000000000000000000000000000000000d1"; });
      const sink2 = new MemorySink();
      const ex2 = await execStep(drift, 0, mon.state.index.borrowers, emptyExecutorState(), {}, sink2);
      check("a liquidator whose riskEngine() differs from the configuration HALTS before any allowance", ex2.o.halted && (await nonce(0)) === n0 && sink2.messages.some((x) => /configuration drift/.test(x.text)));
      const mon2 = await monitor(drift);
      check("monitor: the hook differing from the configured engine is a critical finding", mon2.report.findings.some((f) => f.key === "margin:hook-drift" && f.severity === "crit"));
    });

    // =========================================================== S6: the lending path still works next to a margin position
    await scenario("S6 lending liquidation is unchanged next to a margin position", async () => {
      // a second, fragile lending borrower: collateral 0.1 x CAP in WAVAX at 30% (power 0.03 x CAP) borrows 0.025 x CAP (power about 0.0195 x CAP at -35%)
      const B2 = "0x00000000000000000000000000000000000B0A02";
      await chain.setBalance(B2, utils.parseEther("1000"));
      await chain.setErc20Balance(PW, B2, utils.parseEther(String((CAP * 0.1) / avaxUsd)));
      const b2s = chain.signer(B2);
      await okTx(new Contract(PW, erc, b2s).approve(b.pw.pWavax, utils.parseEther(String((CAP * 0.1) / avaxUsd))));
      await okTx(pWavaxC.connect(b2s).mint(utils.parseEther(String((CAP * 0.1) / avaxUsd))));
      await okTx(ctrlC.connect(b2s).enterMarkets([b.pw.pWavax]));
      await okTx(pUsdcC.connect(b2s).borrow(BigNumber.from(U6(CAP * 0.025).toString())));
      await setAvaxBps(6_500);
      const mon = await monitor(cfg);
      // the treasury rule fails closed on an oracle/TWAP divergence (the shock moved the oracle only): PRICE_DIVERGENCE is the designed verdict here, and the executor is not gated by it
      const b2v = mon.report.accounts.find((a) => a.account === B2.toLowerCase())?.verdict;
      check("monitor: B2 is a lending account in shortfall (verdict LIQUIDATABLE_RECOVERABLE or the fail-closed PRICE_DIVERGENCE), the margin account is not in the lending list", (b2v === "LIQUIDATABLE_RECOVERABLE" || b2v === "PRICE_DIVERGENCE") && !mon.report.accounts.some((a) => a.account === acct1), `B2 verdict ${b2v}`);
      const b2debt0 = await debtOf(B2.toLowerCase());
      const mdebt0 = await debtOf(acct1);
      const ex1 = await execStep(cfg, 0, mon.state.index.borrowers, emptyExecutorState());
      check("step 1: the margin position goes first (margin round)", ex1.o.round?.marginPositionId === "1", JSON.stringify(ex1.o.round?.marginPositionId ?? ex1.o.skipped));
      check("step 1: B2's debt is untouched in the margin step", near(await debtOf(B2.toLowerCase()), b2debt0));
      await setAvaxBps(6_500);
      const mon2 = await monitor(cfg);
      const ex2 = await execStep(cfg, 0, mon2.state.index.borrowers, ex1.state);
      check("step 2: the lending round liquidates B2 (not a margin round)", !!ex2.o.round && ex2.o.round.marginPositionId === undefined && ex2.o.round.borrower === B2.toLowerCase(), JSON.stringify(ex2.o.round ?? ex2.o.skipped));
      check("step 2: B2's debt fell, the margin account was not touched by the lending path", (await debtOf(B2.toLowerCase())) < b2debt0 && near(await debtOf(acct1), mdebt0 - BigInt(ex1.o.round?.repay ?? "0"), 5_000n));
      check("no allowance left to the pUSDC market or the liquidator", (await allowanceTo(0)) === 0n);
    });

    // ===================================================================== R-C: every mutation must be caught by the scenario that owns it
    const mutations: Array<{ name: string; run: () => Promise<void> }> = [
      { name: "monitor classifier off", run: () => S0({ monitorNoClassifier: true }) },
      { name: "executor classifier off", run: () => S0({ execNoClassifier: true }) },
      { name: "insolvent pre-filter AND break-even floor off", run: () => S2({ noFloor: true }) },
      { name: "per-call allowance bound off", run: () => S3a({ noAllowanceBound: true }) },
      { name: "daily cap off", run: () => S3b({ noDailyCap: true }) },
    ];
    const mutationResults: Array<{ mutation: string; detected: boolean; failedChecks: string[] }> = [];
    for (const mu of mutations) {
      const before = checks.length;
      currentScenario = `MUTATION ${mu.name}`;
      console.log(`\n== ${currentScenario} (must be caught)`);
      await fresh();
      try {
        await mu.run();
      } catch (e) {
        check("scenario ran without an unexpected error", false, safeError(e));
      }
      const mine = checks.splice(before); // the mutation's own checks are not part of the pass/fail of the main run
      // a scenario that CRASHED proves nothing: it is inconclusive, never "detected"
      const crashed = mine.some((c) => !c.pass && c.name === "scenario ran without an unexpected error");
      const bad = mine.filter((c) => !c.pass && c.name !== "scenario ran without an unexpected error").map((c) => c.name);
      mutationResults.push({ mutation: mu.name, detected: !crashed && bad.length > 0, failedChecks: crashed ? ["INCONCLUSIVE: the scenario crashed"] : bad });
      console.log(`  => mutation ${crashed ? "INCONCLUSIVE (crashed)" : bad.length > 0 ? "DETECTED" : "NOT DETECTED"} (${bad.length} failing check${bad.length === 1 ? "" : "s"})`);
    }

    const mainFail = checks.filter((c) => !c.pass);
    const undetected = mutationResults.filter((m) => !m.detected);
    failed = mainFail.length > 0 || undetected.length > 0;
    report.checks = { total: checks.length, passed: checks.length - mainFail.length, failed: mainFail.map((c) => `${c.scenario}: ${c.name} [${c.detail}]`) };
    report.mutations = mutationResults;
    report.ok = !failed;
    console.log(`\nchecks: ${checks.length - mainFail.length}/${checks.length} passed; mutations detected: ${mutationResults.length - undetected.length}/${mutationResults.length}`);
  } catch (e) {
    failed = true;
    report.ok = false;
    report.error = safeError(e);
    console.error("rehearsal failed: " + safeError(e));
  } finally {
    report.finishedAt = new Date().toISOString();
    report.allChecks = checks;
    if (outIdx >= 0) fs.writeFileSync(process.argv[outIdx + 1]!, JSON.stringify(report, null, 2) + "\n");
    await chain.stop();
    fs.rmSync(tmp, { recursive: true, force: true });
  }
  process.exit(failed ? 1 : 0);
})();

// FORK TESTS: the real order keeper (real KeystoreSigner with a throwaway funded wallet, real state file, real encoding / simulation / read-back) against the REAL margin
// stack (PW30 + margin ceremony stages 1 to 4, deployed on a local anvil fork of the live head) with the two Chainlink feeds replaced by settable mocks on the fork.
// One bring-up for the file; evm_snapshot / evm_revert between scenarios. Run through test/fork/run.sh (shared fork lock). A 429 from the endpoint stops everything.
import { after, before, beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { BigNumber, Contract, Wallet, utils } from "ethers";
import { AlertManager, MemorySink } from "../../src/alerts";
import type { KeeperConfig } from "../../src/config";
import { classifyRevert, revertData } from "../../src/errors";
import { keeperStep, verifySigner } from "../../src/keeper";
import type { KeeperOutcome } from "../../src/keeper";
import { KeystoreSigner } from "../../src/signer";
import { emptyState, loadState, saveState } from "../../src/state";
import type { KeeperState } from "../../src/state";
import { REGISTRY_ABI } from "../../src/abi";
import { AVAX_FEED, ForkChain, rpcAvailable, USDC_FEED } from "./harness";
import { abi, ALICE, bringUpMarginFork, LEDGER, OP1, OP2, openLong, USDC, WAVAX } from "./margin-fork-lib";
import type { BroughtUp } from "./margin-fork-lib";

const PW_ENV = "ORDER_KEEPER_KEYSTORE_PASSWORD";
const ORDERS_ABI = [...REGISTRY_ABI, "function createOrder(uint256 positionId, uint8 kind, bool triggerAbove, uint256 triggerPriceE18, uint16 closeBps, uint16 maxSlippageBps, uint64 expiry) returns (uint256 orderId)"];
const ADAPTER_PRICE_ABI = ["function oraclePriceE18(uint256 positionId) view returns (uint256 priceE18, bool ok)"];
// the pinned Pharaoh CL pool the swap module sells into (WAVAX is token0, USDC token1)
const PHARAOH_POOL = "0xf01449C0bA930B6e2CaCA3DEF3CCBd7a3E589534";
const POOL_ABI = ["function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint24 feeProtocol, bool unlocked)"];
const ERC = ["function balanceOf(address) view returns (uint256)", "function approve(address,uint256) returns (bool)"];
const BOB = "0x0000000000000000000000000000000000000B0B";
const CAROL = "0x000000000000000000000000000000000000CA20";
const E18 = 10n ** 18n;
const U = (x: number): bigint => BigInt(Math.round(x * 1e6));

describe("order keeper on a fork of the live head", { skip: !rpcAvailable() && "AVALANCHE_MAINNET_RPC_URL is not set" }, () => {
  let chain: ForkChain;
  let b: BroughtUp;
  let cfg: KeeperConfig;
  let keeperWallet: Wallet;
  let dir: string;
  let snap: string;
  let sink: MemorySink;
  let alerts: AlertManager;
  let state: KeeperState;
  let stateFile: string;
  let registry: Contract;
  let adapter: Contract;
  let pool: Contract;
  let vault: Contract;
  let executor: Contract;
  let nonceAtStart = 0;
  let reported = 0;

  const chainNow = async (): Promise<number> => chain.now();
  /** the pinned pool's own spot price of 1 WAVAX in USD as a Chainlink-style 8-decimal answer. The close path's minimum is derived from the ORACLE (the quoter is
   *  oracle-based) and the pool must pay within the pair's 100 bp of it, so the scenarios move the ORACLE relative to this pool price. */
  const poolAnswer8 = async (): Promise<bigint> => {
    const sqrt = BigInt((await pool.slot0()).sqrtPriceX96.toString());
    return (sqrt * sqrt * 10n ** 20n) >> 192n;
  };
  const setAvax = async (answer8: bigint, age = 0): Promise<void> => {
    const now = await chainNow();
    await (await b.mocks.feed(AVAX_FEED).set(answer8.toString(), now - age)).wait();
  };
  const refreshUsdc = async (): Promise<void> => {
    const now = await chainNow();
    await (await b.mocks.feed(USDC_FEED).set(b.realUsdc, now)).wait();
  };
  const bps = (v: bigint, n: number): bigint => (v * BigInt(n)) / 10_000n;
  const open = async (user: string, usdc: number): Promise<string> => (await openLong(chain, b, user, U(usdc))).id;
  const createOrder = async (owner: string, positionId: string, kind: 0 | 1, above: boolean, trigger: bigint, closeBps: number, slip: number, lifetime = 7 * 86_400): Promise<string> => {
    const expiry = (await chainNow()) + lifetime;
    const r = await (await registry.connect(chain.signer(owner)).createOrder(positionId, kind, above, trigger.toString(), closeBps, slip, expiry, { gasLimit: 1_000_000 })).wait();
    const ev = r.logs.map((l: any) => { try { return registry.interface.parseLog(l); } catch { return undefined; } }).find((x: any) => x?.name === "OrderCreated");
    return ev!.args.orderId.toString();
  };
  const order = async (id: string): Promise<any> => registry.getOrder(id);
  const entryPrice = async (positionId: string): Promise<bigint> => BigInt((await adapter.oraclePriceE18(positionId)).priceE18.toString());
  const posStatus = async (id: string): Promise<number> => Number((await executor.positions(id)).status);
  const keeperNonce = async (): Promise<number> => chain.provider.getTransactionCount(keeperWallet.address);

  /** one keeper cycle with the REAL keystore signer and the REAL state file */
  async function cycle(): Promise<KeeperOutcome> {
    const signer = await KeystoreSigner.load(chain.provider, path.join(dir, "keeper.json"), PW_ENV);
    await verifySigner(signer, cfg, chain.provider);
    const now = (await chainNow()) + 1;
    const o = await keeperStep({ provider: chain.provider, cfg, signer, alerts, persist: (s) => { state = s; saveState(stateFile, { ...s, alerts: alerts.toJson() }); }, now: () => now }, state);
    state = o.state;
    for (const s of state.sends.slice(reported)) {
      const rc = await chain.provider.getTransactionReceipt(s.tx);
      console.log(`SEND ${s.kind} order ${s.orderId}: ${s.outcome} tx ${s.tx} block ${rc?.blockNumber} gasUsed ${rc?.gasUsed.toString()}`);
    }
    reported = state.sends.length;
    assert.equal(chain.proxyStats.http429, 0, "the endpoint answered 429");
    return o;
  }
  const alertKeys = (): string[] => sink.messages.map((m) => `${m.kind}:${m.key}`);

  before(async () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), "order-keeper-fork-"));
    chain = await ForkChain.start(process.env.ORDER_KEEPER_FORK_BLOCK ? Number(process.env.ORDER_KEEPER_FORK_BLOCK) : "latest"); // pinned by run.sh: the upstream cache is reused on a re-run
    b = await bringUpMarginFork(chain, { workDir: dir });
    // the stack's addresses (public, from the ceremony wrapper's own addresses file)
    const d = b.deployed;
    registry = new Contract(d.M_REGISTRY!, ORDERS_ABI, chain.provider);
    adapter = new Contract(d.M_CLOSE_ADAPTER!, ADAPTER_PRICE_ABI, chain.provider);
    pool = new Contract(PHARAOH_POOL, POOL_ABI, chain.provider);
    vault = new Contract(d.M_VAULT!, abi("IsolatedMarginVault"), chain.provider);
    executor = new Contract(d.M_EXECUTOR!, abi("IsolatedMarginExecutor"), chain.provider);
    // the throwaway keeper wallet: a fresh key, an encrypted keystore (mode 600), the password only in this process's environment; funded with AVAX on the fork
    keeperWallet = Wallet.createRandom();
    const password = crypto.randomBytes(24).toString("hex");
    process.env[PW_ENV] = password;
    const json = await keeperWallet.encrypt(password, { scrypt: { N: 1024 } });
    fs.writeFileSync(path.join(dir, "keeper.json"), json, { mode: 0o600 });
    await chain.setBalance(keeperWallet.address, utils.parseEther("5"));
    cfg = {
      schemaVersion: 1, chainId: 43114, label: "fork", registry: d.M_REGISTRY!, closeAdapter: d.M_CLOSE_ADAPTER!, marginExecutor: d.M_EXECUTOR!, marginVault: d.M_VAULT!,
      keeper: { address: keeperWallet.address, keystorePath: path.join(dir, "keeper.json"), passwordEnv: PW_ENV },
      limits: { maxFeeGwei: 500, minGasWei: utils.parseEther("0.05").toString(), maxGasLimit: 6_000_000, maxSendsPerCycle: 3, maxSendsPerDay: 60, maxMinedRevertsPerDay: 3, sweep: true, maxIdsPerCycle: 500, retryCooldownSeconds: 30, retryCooldownMaxSeconds: 300, unknownRevertCooldownSeconds: 900, unfilledAlertSeconds: 600 },
      logs: { enabled: false, chunkBlocks: 10, maxChunksPerCycle: 5, minIntervalMs: 0, reorgMarginBlocks: 10, behindWarnBlocks: 600 },
      monitor: { pollSeconds: 15, maxBlockLagSeconds: 3600, statePath: path.join(dir, "state.json") },
      alerts: { channel: "log" }, escalationSeconds: [3600, 14400, 86400],
    };
    stateFile = cfg.monitor.statePath;
    nonceAtStart = await keeperNonce();
    snap = await chain.snapshot();
  });
  beforeEach(async () => {
    await chain.revert(snap);
    snap = await chain.snapshot();
    sink = new MemorySink();
    alerts = new AlertManager(sink, cfg.escalationSeconds);
    try { fs.unlinkSync(stateFile); } catch { /* fresh */ }
    state = loadState(stateFile, cfg.registry);
    reported = 0;
    assert.deepEqual(state, emptyState(cfg.registry));
  });
  after(async () => {
    console.log(`proxy: ${chain?.proxyStats.requests} upstream requests, ${chain?.proxyStats.non200} non-200, ${chain?.proxyStats.http429} HTTP 429`);
    await chain?.stop();
    if (dir) fs.rmSync(dir, { recursive: true, force: true });
  });

  it("the keeper wallet is a throwaway key: a wrong password and a different signer address are refused", async () => {
    const real = process.env[PW_ENV];
    try {
      process.env[PW_ENV] = "wrong";
      await assert.rejects(KeystoreSigner.load(chain.provider, path.join(dir, "keeper.json"), PW_ENV), /could not be decrypted/);
      process.env[PW_ENV] = crypto.randomBytes(24).toString("hex");
      const other = Wallet.createRandom();
      fs.writeFileSync(path.join(dir, "other.json"), await other.encrypt(process.env[PW_ENV]!, { scrypt: { N: 1024 } }), { mode: 0o600 });
      const s = await KeystoreSigner.load(chain.provider, path.join(dir, "other.json"), PW_ENV);
      await assert.rejects(verifySigner(s, cfg, chain.provider), /not the configured keeper address/);
    } finally {
      process.env[PW_ENV] = real; // the other tests sign with the real keeper keystore
    }
  });

  it("take-profit executes: the order fills when the price crosses, the owner is credited, the keeper gets nothing", async () => {
    const P = await poolAnswer8();
    await setAvax(P);
    await refreshUsdc();
    const pid = await open(ALICE, 40);
    const entry = await entryPrice(pid);
    const id = await createOrder(ALICE, pid, 0, true, bps(entry, 10_030), 10_000, 100);
    let o = await cycle();
    assert.deepEqual([o.executed, o.swept, o.skipped.length], [[], [], 0], "trigger not reached: nothing is done");
    assert.equal(await keeperNonce(), nonceAtStart);
    await setAvax(bps(P, 10_050));
    const freeBefore: BigNumber = await vault.freeBalance(ALICE, b.pw.pUsdc);
    o = await cycle();
    assert.deepEqual(o.executed, [id], JSON.stringify(o.skipped));
    assert.equal(Number((await order(id)).status), 2, "EXECUTED");
    assert.equal(await posStatus(pid), 5, "CLOSED");
    assert.ok((await vault.freeBalance(ALICE, b.pw.pUsdc)).gt(freeBefore), "the owner was credited");
    assert.ok((await new Contract(USDC, ERC, chain.provider).balanceOf(keeperWallet.address)).isZero(), "the executor receives nothing");
    assert.ok((await new Contract(b.pw.pUsdc, ERC, chain.provider).balanceOf(keeperWallet.address)).isZero());
    assert.equal(state.halted, null);
    assert.equal(state.pending, null);
    assert.equal(state.sends.length, 1);
    assert.equal(await keeperNonce(), nonceAtStart + 1);
    assert.deepEqual(JSON.parse(fs.readFileSync(stateFile, "utf8")).sends.length, 1, "the state file on disk has it");
    console.log(`TP executed order ${id}: tx ${state.sends[0]!.tx}`);
  });

  it("stop-loss executes (full close) and cancels its sibling take-profit in the same transaction", async () => {
    const P = await poolAnswer8();
    await setAvax(P);
    await refreshUsdc();
    const pid = await open(BOB, 40);
    const entry = await entryPrice(pid);
    const sl = await createOrder(BOB, pid, 1, false, bps(entry, 9_970), 10_000, 100);
    const tp = await createOrder(BOB, pid, 0, true, bps(entry, 13_000), 10_000, 100);
    await cycle();
    assert.equal(await keeperNonce(), nonceAtStart);
    await setAvax(bps(P, 9_950));
    const o = await cycle();
    assert.deepEqual(o.executed, [sl], JSON.stringify(o.skipped));
    assert.equal(await posStatus(pid), 5);
    assert.equal(Number((await order(sl)).status), 2);
    assert.equal(Number((await order(tp)).status), 3, "the sibling was CANCELLED by the registry");
    const o2 = await cycle();
    assert.deepEqual([o2.executed, o2.swept], [[], []]);
    assert.deepEqual(state.open, []);
    assert.equal(state.halted, null);
  });

  it("partial close (50 %): the position stays active, the order is executed, the read-back accepts it", async () => {
    const P = await poolAnswer8();
    await setAvax(P);
    await refreshUsdc();
    const pid = await open(ALICE, 40);
    const entry = await entryPrice(pid);
    const id = await createOrder(ALICE, pid, 0, true, bps(entry, 10_030), 5_000, 100);
    await setAvax(bps(P, 10_050));
    const o = await cycle();
    assert.deepEqual(o.executed, [id], JSON.stringify(o.skipped));
    assert.equal(await posStatus(pid), 2, "still ACTIVE");
    assert.equal(state.halted, null);
  });

  it("oracle unavailable: canExecute is false (reason 5), the registry refuses, NOTHING is sent, an alert is raised; it executes once the price is fresh", async () => {
    const P = await poolAnswer8();
    await setAvax(P);
    await refreshUsdc();
    const pid = await open(ALICE, 40);
    const entry = await entryPrice(pid);
    const id = await createOrder(ALICE, pid, 1, false, bps(entry, 10_100), 10_000, 100); // crossed at the current price
    await setAvax(P, 1_300); // the answer is 1,300 s old: past the 1,200 s guard
    const can = await registry.canExecute(id);
    assert.deepEqual([can.executable, Number(can.reason)], [false, 5]);
    await assert.rejects((registry as any).callStatic.executeOrder(id, "0x", { from: keeperWallet.address }), (e: unknown) => {
      console.log(`oracle unavailable: canExecute reason ${can.reason}; executeOrder revert data ${revertData(e)} (${classifyRevert(e).name})`);
      return classifyRevert(e).name === "OracleUnavailable";
    });
    const o = await cycle();
    assert.deepEqual([o.executed, o.swept], [[], []]);
    assert.equal(await keeperNonce(), nonceAtStart, "nothing sent");
    assert.equal(Number((await order(id)).status), 1, "the order waits, nothing is cancelled");
    assert.ok(alertKeys().includes("new:oracle:unavailable"));
    assert.equal(state.halted, null);
    await setAvax(P);
    const o2 = await cycle();
    assert.deepEqual(o2.executed, [id], JSON.stringify(o2.skipped));
    assert.ok(alertKeys().includes("resolved:oracle:unavailable"));
  });

  it("slippage clamp: an order asking for 300 bp is clamped to the pair's 100 bp; a fill outside the clamp fails in the simulation and the order stays open; inside it fills", async () => {
    const P = await poolAnswer8();
    await setAvax(P);
    await refreshUsdc();
    const pid = await open(ALICE, 40);
    const entry = await entryPrice(pid);
    // a stop-loss with its trigger ABOVE the price (crossed from the start), maxSlippageBps 300: the owner asked for 3 %
    const id = await createOrder(ALICE, pid, 1, false, bps(entry, 10_300), 10_000, 300);
    // the oracle is 2 % ABOVE what the pool pays: a 3 % allowance would let it through, the pair's 1 % clamp must not
    await setAvax(bps(P, 10_200));
    assert.equal((await registry.canExecute(id)).executable, true, "the trigger is crossed");
    let thrown: unknown;
    try {
      await (registry as any).callStatic.executeOrder(id, "0x", { from: keeperWallet.address });
    } catch (e) {
      thrown = e;
    }
    assert.ok(thrown, "the registry's close path refuses the fill");
    const cls = classifyRevert(thrown);
    console.log(`clamp revert at an oracle 2 % above the pool: ${cls.name} ${cls.detail}; revert data ${revertData(thrown)}`);
    assert.equal(cls.kind, "wait", `a known wait, got ${cls.name}`);
    let o = await cycle();
    assert.deepEqual([o.executed, o.reverted], [[], [id]]);
    assert.equal(await keeperNonce(), nonceAtStart, "no transaction was sent");
    assert.equal(Number((await order(id)).status), 1, "the order stays OPEN");
    assert.equal(await posStatus(pid), 2);
    assert.equal(state.cooldown[id]!.fails, 1);
    assert.equal(state.halted, null);
    // inside the cooldown the keeper does not even simulate
    const o1 = await cycle();
    assert.ok(o1.skipped.some((s) => /cooling down/.test(s)), JSON.stringify(o1.skipped));
    // 1.5 % is still outside the 1 % clamp
    await chain.increaseTime(31);
    await setAvax(bps(P, 10_150));
    await refreshUsdc();
    o = await cycle();
    assert.deepEqual(o.reverted, [id]);
    assert.equal(state.cooldown[id]!.fails, 2);
    assert.equal(await keeperNonce(), nonceAtStart);
    // 0.5 % is inside it
    await chain.increaseTime(61);
    await setAvax(bps(P, 10_050));
    await refreshUsdc();
    o = await cycle();
    assert.deepEqual(o.executed, [id], JSON.stringify(o.skipped));
    assert.equal(await posStatus(pid), 5);
    assert.equal(state.cooldown[id], undefined);
  });

  it("liquidation: the position is liquidated first; its orders are then swept (CANCELLED, no revert), the keeper never executes against it and does not halt", async () => {
    const P = await poolAnswer8();
    await setAvax(P);
    await refreshUsdc();
    const pid = await open(CAROL, 40);
    const entry = await entryPrice(pid);
    const sl = await createOrder(CAROL, pid, 1, false, bps(entry, 7_000), 10_000, 100);
    const sl2 = await createOrder(CAROL, pid, 1, false, bps(entry, 5_000), 5_000, 100);
    const tp = await createOrder(CAROL, pid, 0, true, bps(entry, 13_000), 10_000, 100);
    // the oracle falls 36 %: the funded liquidators act (as in the rehearsal), repeating at lower prices until the position is gone
    const liq: any = new Contract(b.deployed.M_LIQUIDATOR!, abi("IsolatedMarginLiquidator"), chain.provider);
    const risk: any = new Contract(b.deployed.M_RISK_ENGINE!, abi("IsolatedMarginRiskEngine"), chain.provider);
    const account: string = (await executor.positions(pid)).account;
    {
      const cfgC: any = new Contract(b.deployed.M_CONFIG!, abi("IsolatedMarginConfig"), chain.provider);
      const pr = await cfgC.getPairRisk(b.pw.pUsdc, b.pw.pWavax, b.pw.pUsdc).catch(() => undefined);
      if (pr) console.log(`pair risk: initialMarginBps ${pr.initialMarginBps} maintenanceMarginBps ${pr.maintenanceMarginBps} maxLiquidationBps ${pr.maxLiquidationBps} fullLiquidationHealthBps ${pr.fullLiquidationHealthBps} liquidationTargetBps ${pr.liquidationTargetBps} maxSlippageBps ${pr.maxSlippageBps}`);
    }
    const usdc: any = new Contract(USDC, ERC, chain.provider);
    // The stack's pilot sizing is small (CAP 200), so positions here are 40 USDC of margin. One funded call at -36 % with minSeizeValueBps 0 (the funder accepts
    // the loss; the break-even floor is the liquidator's own business, not the keeper's) takes the whole position (status LIQUIDATED).
    for (const [op, factor] of [[OP1, 6_400], [OP2, 5_200], [OP1, 4_000], [OP2, 3_000]] as Array<[string, number]>) {
      if ((await posStatus(pid)) !== 2) break;
      await setAvax(bps(P, factor));
      await refreshUsdc();
      await chain.setErc20Balance(USDC, op, BigNumber.from(U(3_750).toString()));
      await (await usdc.connect(chain.signer(op)).approve(b.deployed.M_LIQUIDATOR!, U(3_750).toString())).wait();
      // diagnostics: after a PARTIAL funded liquidation the position is healthy again, so the next call may legitimately revert before the deeper price is tried
      const liquidatable = await risk.isLiquidatable(account).catch(() => "n/a");
      const hf = await risk.getMetrics(account).then((m: any) => m.healthFactorBps.toString()).catch(() => "n/a");
      try {
        const rc = await (await liq.connect(chain.signer(op)).liquidateFunded([pid, op, U(3_750).toString(), 0, 0, 0], { gasLimit: 6_000_000 })).wait();
        const ev = rc.logs.map((l: any) => { try { return liq.interface.parseLog(l); } catch { return undefined; } }).find((x: any) => x?.name === "FundedPositionLiquidated");
        console.log(`funded call at ${factor / 100} %: isLiquidatable=${liquidatable} healthFactorBps=${hf} debtRepaid=${ev?.args.debtRepaid.toString()}`);
      } catch (e) {
        console.log(`funded call at ${factor / 100} % by ${op} refused (isLiquidatable=${liquidatable} healthFactorBps=${hf}): ${classifyRevert(e).name}`);
      }
      console.log(`after the funded call at ${factor / 100} %: position status ${await posStatus(pid)}`);
    }
    const status = await posStatus(pid);
    assert.ok(status === 6 || status === 5, `the position is liquidated (status ${status})`);
    // the oracle is fresh and the stop-losses are crossed: the keeper must still NOT execute; it sweeps
    await setAvax(bps(P, 4_600));
    await refreshUsdc();
    for (const id of [sl, sl2, tp]) {
      const c = await registry.canExecute(id);
      assert.deepEqual([c.executable, Number(c.reason)], [false, 3], `order ${id}: position inactive`);
    }
    const o = await cycle();
    assert.deepEqual(o.executed, [], "no execution against a liquidated position");
    assert.deepEqual([...o.swept].sort(), [sl, sl2, tp].sort(), JSON.stringify(o.skipped));
    for (const id of [sl, sl2, tp]) assert.equal(Number((await order(id)).status), 3, `order ${id} CANCELLED`);
    assert.equal(await posStatus(pid), status, "the keeper did not touch the position");
    assert.equal(state.halted, null);
    assert.equal(state.pending, null);
    assert.deepEqual(state.open, []);
    const o2 = await cycle();
    assert.deepEqual([o2.executed, o2.swept, o2.skipped], [[], [], []]);
  });

  it("an expired order is swept to EXPIRED without touching the position; owner-closed positions cancel the orders the same way", async () => {
    const P = await poolAnswer8();
    await setAvax(P);
    await refreshUsdc();
    const pid = await open(ALICE, 40);
    const entry = await entryPrice(pid);
    const id = await createOrder(ALICE, pid, 0, true, bps(entry, 20_000), 10_000, 100, 3_600);
    // another position closed directly by its owner
    const pid2 = await open(BOB, 40);
    const entry2 = await entryPrice(pid2);
    const id2 = await createOrder(BOB, pid2, 1, false, bps(entry2, 8_000), 10_000, 100);
    const ex: any = new Contract(b.deployed.M_EXECUTOR!, abi("IsolatedMarginExecutor"), chain.signer(BOB));
    await (await ex.closePosition({ positionId: pid2, closeBps: 10_000, maxClosingFeePToken: BigNumber.from(2).pow(256).sub(1), minDebtUnderlying: 0, minMarginUnderlying: 0, positionToDebtSwapData: "0x", debtToMarginSwapData: "0x" }, { gasLimit: 6_000_000 })).wait();
    await chain.increaseTime(3_700);
    await setAvax(P);
    await refreshUsdc();
    const o = await cycle();
    assert.deepEqual([...o.swept].sort(), [id, id2].sort(), JSON.stringify(o.skipped));
    assert.equal(Number((await order(id)).status), 4, "EXPIRED");
    assert.equal(Number((await order(id2)).status), 3, "CANCELLED: position closed by its owner");
    assert.equal(await posStatus(pid), 2);
    assert.equal(state.halted, null);
  });

  it("a pending marker left in the state file halts the keeper at start; nothing is sent", async () => {
    const P = await poolAnswer8();
    await setAvax(P);
    await refreshUsdc();
    const pid = await open(ALICE, 40);
    const entry = await entryPrice(pid);
    await createOrder(ALICE, pid, 1, false, bps(entry, 10_100), 10_000, 100);
    saveState(stateFile, { ...state, pending: { orderId: "1", kind: "execute", at: 1 } });
    state = loadState(stateFile, cfg.registry);
    const o = await cycle();
    assert.equal(o.halted, true);
    assert.equal(await keeperNonce(), nonceAtStart);
    assert.ok(alertKeys().includes("new:keeper:halted"));
  });
});

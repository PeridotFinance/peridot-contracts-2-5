// END-TO-END with the REAL PharaohDlmmVault (behind the proxy, initialised as the ceremony does) and W4's mocks on a throwaway local anvil (no fork, no lock).
// The keeper runs its real step with the real keystore signer; the pool is moved by real market swaps through the mock router (and, for the repeated cycles, by the mock's forceActiveId).
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { utils } from "ethers";
import { AlertManager, MemorySink } from "../../src/alerts";
import { keeperStep } from "../../src/keeper";
import { KeystoreSigner } from "../../src/signer";
import { emptyState, loadState, readHalt, resumeKeeper, saveState } from "../../src/state";
import type { KeeperState } from "../../src/state";
import { toolsAvailable } from "./harness";
import type { Anvil } from "./harness";
import { startAnvil } from "./harness";
import { compileReal, deployRealWorld, ID0, realToolsAvailable } from "./realworld";
import type { RealWorld } from "./realworld";

const skip = !toolsAvailable() || !realToolsAvailable() ? "anvil/forge or contracts/lib symlinks missing" : false;
let anvil: Anvil;
test.before(async () => {
  if (skip) return;
  compileReal();
  anvil = await startAnvil();
});
test.after(() => anvil?.stop());

interface Rig {
  w: RealWorld;
  sink: MemorySink;
  state: KeeperState;
  step(o?: { dry?: boolean; openBand?: boolean; skipWait?: boolean }): ReturnType<typeof keeperStep>;
  nonce(): Promise<number>;
  resume(): ReturnType<typeof resumeKeeper>;
  keys(): string[];
}
async function rig(mut?: Parameters<typeof deployRealWorld>[1]): Promise<Rig> {
  const w = await deployRealWorld(anvil, mut);
  const sink = new MemorySink();
  const alerts = new AlertManager(sink);
  const ks = path.join(w.dir, "ks.json");
  const pw = path.join(w.dir, "pw");
  fs.writeFileSync(ks, await w.keeper.encrypt("harness-password-not-a-secret", { scrypt: { N: 256 } }), { mode: 0o600 });
  fs.writeFileSync(pw, "harness-password-not-a-secret\n", { mode: 0o600 });
  const signer = await KeystoreSigner.load(anvil.provider, { DLMM_KEEPER_KEYSTORE_PATH: ks, DLMM_KEEPER_KEYSTORE_PASSWORD_FILE: pw });
  const r: Rig = {
    w, sink, state: emptyState(w.cfg.vault),
    step: async (o = {}) => {
      const now = await w.now();
      const out = await keeperStep(
        { provider: anvil.provider, cfg: { ...w.cfg, mode: o.dry ? "dry-run" : "live" }, signer: o.dry ? undefined : signer, alerts, persist: (s) => { r.state = s; saveState(w.cfg.monitor.statePath, { ...s, alerts: alerts.toJson() }); }, now: () => now, sleep: async () => {} },
        r.state, { skipWait: o.skipWait, openBand: o.openBand },
      );
      r.state = out.state;
      return out;
    },
    nonce: () => anvil.provider.getTransactionCount(w.keeper.address),
    resume: () => {
      const res = resumeKeeper(w.cfg.monitor.statePath, w.cfg.monitor.haltPath, w.cfg.vault, 1);
      r.state = loadState(w.cfg.monitor.statePath, w.cfg.vault);
      return res;
    },
    keys: () => sink.messages.map((m) => `${m.kind}:${m.key}`),
  };
  return r;
}
const big = (x: { toString(): string }): bigint => BigInt(x.toString());
const bandOf = async (w: RealWorld): Promise<{ lo: number; hi: number; has: boolean }> => {
  const b = await w.vault.bandState();
  return { lo: Number(b.lowerId), hi: Number(b.upperId), has: Boolean(b.hasBand) };
};
const events = async (w: RealWorld, name: string): Promise<any[]> => w.vault.queryFilter((w.vault.filters as any)[name](), 0, "latest");
/** deposit 100 USDC and open the first band through the keeper's open-band step */
async function openFirstBand(r: Rig): Promise<void> {
  await r.w.deposit(100n * 1_000_000n);
  await r.w.tick(1);
  const o = await r.step({ openBand: true, skipWait: true });
  assert.equal(o.status, "sent", JSON.stringify(o.notes));
}
const exitUpByMarket = async (r: Rig): Promise<number> => {
  await r.w.marketSwap(true, 350_000n * 1_000_000n);
  const a = Number(await r.w.pair.getActiveId());
  assert.ok(a > (await bandOf(r.w)).hi, `the market swap pushed the active bin out (active ${a})`);
  return a;
};

test("real vault: the world is what the ceremony builds (paused at init then unpaused, cap 200, rebalancer = the keeper wallet, X = USDt, guard clean)", { skip }, async () => {
  const r = await rig();
  assert.equal(await r.w.vault.rebalancer(), r.w.keeper.address);
  assert.equal(big(await r.w.vault.depositCap()), 200_000_000n);
  assert.equal(await r.w.pair.getTokenX(), r.w.usdt.address);
  const g = await r.w.vault.guardState();
  assert.equal(big(g.reasons), 0n);
  assert.equal(g.latched, false);
  assert.equal((await r.w.vault.bandState()).hasBand, false);
});

test("real vault, open-band: dry-run simulates against the real vault and sends nothing; --send opens the band once; NAV bound holds; the swap the keeper predicted is the swap the vault made", { skip }, async () => {
  const r = await rig();
  await r.w.deposit(100n * 1_000_000n);
  await r.w.tick(1);
  const navBefore = big(await r.w.vault.totalAssets());
  // no band yet: a plain run (not open-band) only warns
  assert.equal((await r.step({ skipWait: true })).status, "no-band");
  const dry = await r.step({ dry: true, openBand: true, skipWait: true });
  assert.equal(dry.status, "dry-run", JSON.stringify(dry.notes));
  assert.equal(await r.nonce(), 0);
  assert.equal((await r.w.vault.bandState()).hasBand, false);
  const o = await r.step({ openBand: true, skipWait: true });
  assert.equal(o.status, "sent", JSON.stringify(o.notes));
  assert.equal(await r.nonce(), 1);
  const b = await bandOf(r.w);
  assert.deepEqual(b, { lo: ID0 - 1, hi: ID0 + 1, has: true });
  assert.equal((await events(r.w, "BandOpened")).length, 1);
  const navAfter = big(await r.w.vault.totalAssets());
  assert.ok(navAfter * 10_000n >= navBefore * 9950n, `NAV bound: ${navBefore} -> ${navAfter}`);
  const h = await r.w.holdings();
  // the vault swapped (100 - 0) / 2 = 50 USDC for USDt: about 50 USDC and 50 USDt in the band
  assert.ok(h.usdc > 49_900_000n && h.usdc < 50_100_000n, `usdc ${h.usdc}`);
  assert.ok(h.usdt > 49_900_000n && h.usdt < 50_100_000n, `usdt ${h.usdt}`);
  if (o.plan && o.plan.ok) assert.equal(o.plan.swapIn, 50_000_000n, "the keeper predicted the vault's own swap size");
  // a second open-band is refused (BandExists), nothing sent
  await r.w.tick(5);
  assert.equal((await r.step({ openBand: true, skipWait: true })).status, "blocked");
  assert.equal(await r.nonce(), 1);
});

test("real vault: a market swap pushes the active bin out; the keeper waits 60 s and re-centres EXACTLY ONCE around the real active id; NAV bound; inventory evened; no second send", { skip }, async () => {
  const r = await rig();
  await openFirstBand(r);
  const a = await exitUpByMarket(r);
  const navBefore = big(await r.w.vault.totalAssets());
  await r.w.tick(1);
  assert.equal((await r.step()).status, "exit-detected");
  await r.w.tick(30);
  assert.equal((await r.step()).status, "waiting");
  assert.equal(await r.nonce(), 1, "only the open-band so far");
  await r.w.tick(31);
  const o = await r.step();
  assert.equal(o.status, "sent", JSON.stringify(o.notes));
  assert.equal(await r.nonce(), 2);
  const ev = await events(r.w, "Rebalanced");
  assert.equal(ev.length, 1);
  assert.equal(Number(ev[0].args.activeId), a, "the band is built around the REAL active id");
  const b = await bandOf(r.w);
  assert.deepEqual(b, { lo: a - 1, hi: a + 1, has: true });
  // expectedActiveId sent = the id the keeper read (within idSlippage of the real one)
  const sent = await anvil.provider.getTransaction(o.sent[0]!);
  const args = new utils.Interface(["function rebalance(uint24,uint24,bool,uint256,uint256,uint256,uint256,uint256)"]).decodeFunctionData("rebalance", sent.data);
  assert.equal(Number(args[0]), a);
  assert.equal(Number(args[1]), 2);
  const navAfter = big(await r.w.vault.totalAssets());
  assert.ok(navAfter * 10_000n >= navBefore * 9950n, `NAV bound: ${navBefore} -> ${navAfter}`);
  assert.ok(big(ev[0].args.navAfter) * 10_000n >= big(ev[0].args.navBefore) * 9950n, "the event's own NAV bound");
  const h = await r.w.holdings();
  const total = h.usdc + h.usdt;
  assert.ok(h.usdc * 100n / total >= 45n && h.usdc * 100n / total <= 55n, `even by value: usdc ${h.usdc} usdt ${h.usdt}`);
  assert.equal(Number(await r.w.vault.rebalancesToday()), 1);
  // the active bin is inside the new band: nothing more is sent, however many cycles run
  for (let i = 0; i < 4; i++) {
    await r.w.tick(3);
    assert.equal((await r.step()).status, "in-range");
  }
  assert.equal(await r.nonce(), 2);
  assert.equal((await events(r.w, "Rebalanced")).length, 1);
});

test("real vault, cooldown: the vault's own cooldown (raised by the owner to 600 s) holds the keeper back through rebalanceAllowed bit 256 until readyAt; zero transactions meanwhile", { skip }, async () => {
  const r = await rig();
  await openFirstBand(r);
  await (await r.w.vault.connect(r.w.owner).setGuardParams([50, 93_600, 60, 600, 48, 6000, 50])).wait();
  await r.w.pair.forceActiveId(ID0 + 3).then((t: any) => t.wait());
  await r.w.tick(1);
  await r.step();
  await r.w.tick(61);
  assert.equal((await r.step()).status, "sent"); // lastRebalanceAt == 0: the first rebalance has no cooldown
  const t1 = Number(await r.w.vault.lastRebalanceAt());
  await r.w.pair.forceActiveId(ID0 - 3).then((t: any) => t.wait());
  await r.w.tick(1);
  await r.step();
  await r.w.tick(130); // the keeper's own 120 s gate has passed; the vault's 600 s has not
  const n = await r.nonce();
  const o = await r.step();
  assert.equal(o.status, "cooldown");
  assert.equal(await r.nonce(), n, "no transaction, no gas");
  assert.equal(r.state.backoff?.until, t1 + 600);
  await r.w.tick(t1 + 601 - (await r.w.now()));
  await r.w.refreshFeeds();
  assert.equal((await r.step()).status, "sent");
});

test("real vault, daily cap: with maxRebalancesPerDay 4 the 5th exit of the UTC day is NOT sent (rebalanceAllowed bit 512, readyAt = next midnight); after midnight it is", { skip }, async () => {
  const r = await rig();
  await openFirstBand(r);
  await (await r.w.vault.connect(r.w.owner).setGuardParams([50, 93_600, 60, 120, 4, 6000, 50])).wait();
  for (let k = 0; k < 4; k++) {
    await r.w.pair.forceActiveId(k % 2 === 0 ? ID0 + 3 : ID0 - 3).then((t: any) => t.wait());
    await r.w.tick(1);
    await r.step();
    await r.w.tick(130);
    const o = await r.step();
    assert.equal(o.status, "sent", `cycle ${k}: ${JSON.stringify(o.notes)}`);
  }
  assert.equal(Number(await r.w.vault.rebalancesToday()), 4);
  const n = await r.nonce();
  await r.w.pair.forceActiveId(ID0 + 3).then((t: any) => t.wait());
  await r.w.tick(1);
  await r.step();
  await r.w.tick(130);
  const o = await r.step();
  assert.equal(o.status, "cooldown", JSON.stringify(o.notes));
  assert.equal(await r.nonce(), n);
  assert.ok(r.sink.messages.some((m) => m.key === "limit:daily"));
  const midnight = Math.floor(T0_DAY(await r.w.now())) + 86_400;
  await r.w.tick(midnight - (await r.w.now()) + 5);
  await r.w.refreshFeeds();
  const o2 = await r.step();
  assert.equal(o2.status, "sent", JSON.stringify(o2.notes));
  assert.equal(Number(await r.w.vault.rebalancesToday()), 1, "the vault's counter reset at UTC midnight");
});
const T0_DAY = (t: number): number => t - (t % 86_400);

test("real vault, guard latch: a feed out of band HALTS the keeper (HALT file, no sends); autoTripGuard sends ONE real tripGuard; the Safe cannot clear while unsafe, can after; only a manual resume restarts the keeper", { skip }, async () => {
  const r = await rig((c) => { c.guard.autoTripGuard = true; c.guard.tripDebounceSeconds = 0; });
  await openFirstBand(r);
  await r.w.pair.forceActiveId(ID0 + 3).then((t: any) => t.wait());
  await (await r.w.feedUsdt.setAnswer(98_000_000)).wait(); // USDT/USD 0.98: out of the 0.5 % leg band
  await r.w.tick(1);
  const n = await r.nonce();
  const o = await r.step();
  assert.equal(o.status, "halting", JSON.stringify(o.notes));
  const h = readHalt(r.w.cfg.monitor.haltPath)!;
  assert.equal(h.kind, "guard");
  assert.ok((h.reasons! & 8) !== 0, `reasons ${h.reasons}`);
  assert.match(h.trip!, /^sent 0x/);
  assert.equal(await r.nonce(), n + 1, "exactly the one tripGuard");
  const g = await r.w.vault.guardState();
  assert.equal(g.latched, true);
  // the keeper calls nothing while halted
  const before = anvil.provider.stateRequests;
  for (let i = 0; i < 4; i++) {
    await r.w.tick(3);
    assert.equal((await r.step()).status, "halted");
  }
  assert.equal(anvil.provider.stateRequests - before, 0);
  // the Safe: clearGuard reverts while the feed is still bad, works after it recovers
  await assert.rejects((r.w.vault.connect(r.w.owner).callStatic as any).clearGuard(), /GuardStillUnsafe|0x/);
  await (await r.w.feedUsdt.setAnswer(99_934_000)).wait();
  await (await r.w.vault.connect(r.w.owner).clearGuard()).wait();
  assert.equal((await r.w.vault.guardState()).latched, false);
  // cleared on chain, but the keeper is NEVER auto-resumed
  await r.w.tick(3);
  assert.equal((await r.step()).status, "halted");
  r.resume();
  assert.equal(readHalt(r.w.cfg.monitor.haltPath), null);
  await r.w.tick(1);
  await r.step();
  await r.w.tick(130);
  const o2 = await r.step();
  assert.equal(o2.status, "sent", JSON.stringify(o2.notes));
  assert.equal((await events(r.w, "Rebalanced")).length, 1);
});

test("real vault, EXIT PROBE: a failing Pharaoh hook (beforeBurn reverts) blocks every exit while guardState reads 0 and deposits stay open; the keeper alerts 'EXIT PROBE FAILED: pause deposits', stops re-centring, keeps probing, and recovers when the hook does", { skip }, async () => {
  const r = await rig();
  await openFirstBand(r);
  await r.w.pair.forceActiveId(ID0 + 3).then((t: any) => t.wait());
  await (await r.w.rewarder.setRevert(false, false, true)).wait(); // beforeBurn reverts
  const g = await r.w.vault.guardState();
  assert.equal(big(g.reasons), 0n, "the guard cannot see it");
  await r.w.deposit(1_000_000n); // deposits stay open
  await r.w.tick(1);
  const o0 = await r.step();
  const m = r.sink.messages.find((x) => x.key === "exit:probe");
  assert.ok(m && m.severity === "crit", `${o0.status} ${JSON.stringify(o0.notes)} ${r.keys().join()}`);
  assert.match(m!.text, /EXIT PROBE FAILED: pause deposits/);
  assert.ok(r.state.exitProbe);
  // the real exit really does revert (what the probe predicted)
  const aliceShares = await r.w.vault.balanceOf(r.w.alice.address);
  await assert.rejects((r.w.vault.connect(r.w.alice).callStatic as any).redeemInKind(aliceShares, r.w.alice.address, r.w.alice.address), /hook|revert|Pharaoh|0x/i);
  await r.w.tick(61);
  const n = await r.nonce();
  const o = await r.step();
  assert.equal(o.status, "blocked");
  assert.equal(await r.nonce(), n, "no re-centring while a burn would revert");
  assert.equal(readHalt(r.w.cfg.monitor.haltPath), null, "not a HALT: it clears itself");
  await (await r.w.rewarder.setRevert(false, false, false)).wait();
  await r.w.tick(31);
  const o2 = await r.step();
  assert.equal(o2.status, "sent", JSON.stringify(o2.notes));
  assert.equal(r.state.exitProbe, null);
  assert.ok(r.keys().includes("resolved:exit:probe"));
});

test("real vault, wiring: a keeper wallet that is NOT the vault's rebalancer HALTS (kind wiring) and sends nothing", { skip }, async () => {
  const r = await rig();
  await openFirstBand(r);
  await (await r.w.vault.connect(r.w.owner).setRebalancer(r.w.trader.address)).wait();
  await r.w.pair.forceActiveId(ID0 + 3).then((t: any) => t.wait());
  await r.w.tick(1);
  await r.step();
  await r.w.tick(61);
  const n = await r.nonce();
  assert.equal((await r.step()).status, "halting");
  assert.equal(readHalt(r.w.cfg.monitor.haltPath)!.kind, "wiring");
  assert.equal(await r.nonce(), n);
});

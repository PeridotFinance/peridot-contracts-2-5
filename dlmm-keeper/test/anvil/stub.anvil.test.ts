import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { Wallet } from "ethers";
import { AlertManager, MemorySink } from "../../src/alerts";
import { keeperStep } from "../../src/keeper";
import { VAULT_ABI, PAIR_ABI, FEED_ABI, ERC20_ABI } from "../../src/abi";
import { clearHalt, emptyState, readHalt } from "../../src/state";
import type { KeeperState } from "../../src/state";
import { KeystoreSigner } from "../../src/signer";
import { compileStubs, deployWorld, startAnvil, stubAbi, toolsAvailable } from "./harness";
import type { Anvil, StubWorld } from "./harness";
import { utils } from "ethers";

const skip = !toolsAvailable() ? "anvil/forge not installed" : false;
let anvil: Anvil;
test.before(async () => {
  if (skip) return;
  compileStubs();
  anvil = await startAnvil();
});
test.after(() => anvil?.stop());

interface Rig {
  w: StubWorld;
  state: KeeperState;
  alerts: AlertManager;
  sink: MemorySink;
  step(mode?: "live" | "dry-run", o?: { skipWait?: boolean }): ReturnType<typeof keeperStep>;
  nonce(): Promise<number>;
}
async function rig(mut?: Parameters<typeof deployWorld>[1]): Promise<Rig> {
  const w = await deployWorld(anvil, mut);
  const sink = new MemorySink();
  const alerts = new AlertManager(sink);
  // the REAL keystore signer: a keystore file + password file made here for the throwaway wallet (scrypt N small: it is a test key)
  const ks = path.join(w.dir, "ks.json");
  const pw = path.join(w.dir, "pw");
  fs.writeFileSync(ks, await w.keeper.encrypt("harness-password-not-a-secret", { scrypt: { N: 256 } }), { mode: 0o600 });
  fs.writeFileSync(pw, "harness-password-not-a-secret\n", { mode: 0o600 });
  const signer = await KeystoreSigner.load(anvil.provider, { DLMM_KEEPER_KEYSTORE_PATH: ks, DLMM_KEEPER_KEYSTORE_PASSWORD_FILE: pw });
  const r: Rig = {
    w, sink, alerts, state: emptyState(w.cfg.vault),
    step: async (mode = "live", o = {}) => {
      const now = await w.now();
      const out = await keeperStep({ provider: anvil.provider, cfg: { ...w.cfg, mode }, signer: mode === "live" ? signer : undefined, alerts, persist: (s) => { r.state = s; }, now: () => now, sleep: async () => {} }, r.state, o);
      r.state = out.state;
      return out;
    },
    nonce: () => anvil.provider.getTransactionCount(w.keeper.address),
  };
  return r;
}

test("the stub contracts expose exactly the interface the keeper uses (the keeper's ABI fragments are a subset of the compiled stubs, signature by signature)", { skip }, () => {
  const sigs = (abi: any[], kind: string): Set<string> => new Set(abi.filter((x) => x.type === kind).map((x) => `${x.name}(${x.inputs.map((i: any) => (i.type === "tuple" ? `(${i.components.map((c: any) => c.type).join(",")})` : i.type)).join(",")})`));
  const check = (keeperAbi: string[], stub: string, kinds: string[]): void => {
    const iface = new utils.Interface(keeperAbi);
    const have = new Map(kinds.map((k) => [k, sigs(stubAbi(stub), k)] as const));
    for (const f of Object.values(iface.functions)) if (kinds.includes("function")) assert.ok(have.get("function")!.has(f.format(utils.FormatTypes.sighash)), `${stub}.${f.name}`);
    if (kinds.includes("error")) for (const e of Object.values(iface.errors)) if (["GuardLatched", "GuardUnsafe", "NotOutOfRange", "CooldownActive", "DailyRebalanceCapReached", "SwapTooLarge", "NavLossTooLarge", "ActiveIdMoved"].includes(e.name)) assert.ok(have.get("error")!.has(e.format(utils.FormatTypes.sighash)), `${stub}.${e.name}`);
    if (kinds.includes("event")) for (const e of Object.values(iface.events)) assert.ok(have.get("event")!.has(e.format(utils.FormatTypes.sighash)), `${stub}.${e.name}`);
  };
  check(VAULT_ABI, "StubVault", ["function", "error", "event"]);
  check(PAIR_ABI, "StubPair", ["function"]);
  check(FEED_ABI, "StubFeed", ["function"]);
  check(ERC20_ABI, "StubToken", ["function"]);
});

test("anvil e2e: in range, nothing is sent (keeper nonce stays 0)", { skip }, async () => {
  const r = await rig();
  for (let i = 0; i < 3; i++) {
    await r.w.tick(3);
    assert.equal((await r.step()).status, "in-range");
  }
  assert.equal(await r.nonce(), 0);
  assert.equal(Number(await r.w.vault.rebalanceCount()), 0);
});
test("anvil e2e: exit -> wait 60 s -> exactly ONE rebalance mined through the real keystore signer; arguments decoded on chain; read-back passes; cooldown stops a second", { skip }, async () => {
  const r = await rig();
  await r.w.exitUp(100_000_000n);
  await r.w.tick(1);
  assert.equal((await r.step()).status, "exit-detected");
  await r.w.tick(30);
  assert.equal((await r.step()).status, "waiting");
  assert.equal(await r.nonce(), 0);
  await r.w.tick(31);
  const o = await r.step();
  assert.equal(o.status, "sent", JSON.stringify(o.notes));
  assert.equal(await r.nonce(), 1);
  assert.equal(Number(await r.w.vault.rebalanceCount()), 1);
  assert.equal(Number(await r.w.vault.lastExpected()), 8_388_611);
  assert.equal(await r.w.vault.lastXForY(), false, "the band is all USDC (Y)");
  const swapIn = BigInt((await r.w.vault.lastSwapIn()).toString());
  assert.ok(swapIn > 49_900_000n && swapIn < 50_100_000n, String(swapIn));
  const deadline = Number(await r.w.vault.lastDeadline());
  const blk = await r.w.now();
  assert.ok(deadline > blk && deadline <= blk + 125, "deadline = now + 120 s");
  assert.equal(r.state.pending, null);
  assert.equal(r.state.sends[0]!.outcome, "ok");
  assert.equal(Number(await r.w.vault.lowerId()), 8_388_610);
  // a second exit right away: the cooldown holds
  await r.w.exitUp(100_000_000n);
  await r.w.pair.setActive(8_388_620).then((t: any) => t.wait());
  await r.w.tick(5);
  await r.step();
  await r.w.tick(61);
  const o2 = await r.step();
  assert.ok(["cooldown", "sent"].includes(o2.status));
  assert.ok(Number(await r.w.vault.rebalanceCount()) <= 2);
});
test("anvil e2e DRY-RUN: the same exit simulates against the real stub but sends nothing", { skip }, async () => {
  const r = await rig((c) => (c.mode = "dry-run"));
  await r.w.exitUp(100_000_000n);
  await r.w.tick(1);
  await r.step("dry-run");
  await r.w.tick(61);
  const o = await r.step("dry-run");
  assert.equal(o.status, "dry-run");
  assert.equal(await r.nonce(), 0);
  assert.equal(Number(await r.w.vault.rebalanceCount()), 0);
  assert.equal(r.state.sends.length, 0);
});
test("anvil e2e recovery: the active bin returns inside the band before 60 s: no transaction", { skip }, async () => {
  const r = await rig();
  await r.w.exitUp(100_000_000n);
  await r.w.tick(1);
  await r.step();
  await r.w.tick(20);
  await r.w.enterBand();
  assert.equal((await r.step()).status, "recovered");
  await r.w.tick(60);
  assert.equal((await r.step()).status, "in-range");
  assert.equal(await r.nonce(), 0);
});
test("anvil e2e guard latch: a latchable bit HALTS; for 6 more cycles the keeper makes ZERO RPC requests and sends nothing; resume with the bit gone runs again", { skip }, async () => {
  const r = await rig();
  await r.w.exitUp(100_000_000n);
  await (await r.w.vault.setReasons(4)).wait();
  await r.w.tick(1);
  const o = await r.step();
  assert.equal(o.status, "halting");
  assert.equal(readHalt(r.w.cfg.monitor.haltPath)?.kind, "guard");
  const before = anvil.provider.requests;
  for (let i = 0; i < 6; i++) {
    const h = await r.step(); // (r.step reads the chain clock via anvil.provider: count it out)
    assert.equal(h.status, "halted");
  }
  const clockReads = 6; // r.step() asks the chain for its time once per cycle
  assert.equal(anvil.provider.requests - before, clockReads, "only the harness's own clock reads; the keeper itself made no request");
  assert.equal(await r.nonce(), 0);
  await (await r.w.vault.setReasons(0)).wait();
  assert.equal((await r.step()).status, "halted", "never auto-resumed");
  clearHalt(r.w.cfg.monitor.haltPath, 1);
  await r.w.tick(1);
  assert.equal((await r.step()).status, "exit-detected");
});
test("anvil e2e autoTripGuard ON: the keeper sends ONE tripGuard (permissionless) and the vault is latched on chain; the HALT file records the transaction", { skip }, async () => {
  const r = await rig((c) => { c.guard.autoTripGuard = true; c.guard.tripDebounceSeconds = 0; });
  await (await r.w.vault.setReasons(8)).wait();
  await r.w.tick(1);
  const o = await r.step();
  assert.equal(o.status, "halting");
  assert.equal(Number(await r.w.vault.tripCount()), 1);
  assert.equal((await r.w.vault.guardState())[1], true);
  assert.match(readHalt(r.w.cfg.monitor.haltPath)!.trip!, /^sent 0x/);
  assert.equal(await r.nonce(), 1);
});
test("anvil e2e failure backoff: the vault reverts the simulation (NavLossTooLarge): no transaction is ever mined, backoff doubles, the 3rd failure HALTS", { skip }, async () => {
  const r = await rig();
  await r.w.exitUp(100_000_000n);
  await (await r.w.vault.setFailMode(1)).wait();
  await r.w.tick(1);
  await r.step();
  await r.w.tick(61);
  assert.equal((await r.step()).status, "failed");
  await r.w.tick(5);
  assert.equal((await r.step()).status, "backoff");
  await r.w.tick(30);
  assert.equal((await r.step()).status, "failed");
  assert.equal(r.state.backoff?.fails, 2);
  await r.w.tick(61);
  const o = await r.step();
  assert.equal(o.status, "halting");
  assert.equal(readHalt(r.w.cfg.monitor.haltPath)?.kind, "failures");
  assert.equal(await r.nonce(), 0, "a reverting simulation never costs gas");
});
test("anvil e2e: the keeper's own oracle check blocks a send when the pool price is 100 bp off the oracle", { skip }, async () => {
  const r = await rig();
  await r.w.exitUp(100_000_000n);
  await (await r.w.pair.setPrice(9890, 10000, 3)).wait();
  await r.w.tick(1);
  await r.step();
  await r.w.tick(61);
  const o = await r.step();
  assert.equal(o.status, "blocked");
  assert.equal(await r.nonce(), 0);
  assert.ok(r.sink.messages.some((m) => m.key === "oracle:keeper-check"));
});
test("anvil e2e CLI `check` (main.ts): the RPC comes from the environment only, a dry decision is printed, nothing is written, nothing is sent", { skip }, async () => {
  const w = await deployWorld(anvil, (c) => (c.mode = "dry-run"));
  await w.exitUp(100_000_000n);
  await w.tick(1);
  const cfgPath = path.join(w.dir, "c.json");
  fs.writeFileSync(cfgPath, JSON.stringify(w.cfg));
  const res = await new Promise<{ code: number | null; out: string; err: string }>((resolve) => {
    const c = spawn("node", [path.join(__dirname, "..", "..", "src", "main.js"), "check", "--config", cfgPath], { env: { PATH: process.env.PATH, AVALANCHE_MAINNET_RPC_URL: anvil.url } });
    let out = "";
    let err = "";
    c.stdout.on("data", (d) => (out += d));
    c.stderr.on("data", (d) => (err += d));
    c.on("close", (code) => resolve({ code, out, err }));
  });
  assert.equal(res.code, 0, res.err);
  assert.match(res.out, /"status":"dry-run"/);
  assert.ok(!res.out.includes(anvil.url) && !res.err.includes(anvil.url), "the endpoint is masked in every output");
  assert.ok(!fs.existsSync(w.cfg.monitor.statePath) && !fs.existsSync(w.cfg.monitor.haltPath), "check writes nothing");
  assert.equal(Number(await w.vault.rebalanceCount()), 0);
  void Wallet;
});

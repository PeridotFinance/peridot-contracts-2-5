import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { requireValidConfig, validateConfig } from "../src/config";
import type { MonitorConfig } from "../src/config";
import { AlertManager, MemorySink } from "../src/alerts";
import { executorStep, emptyExecutorState } from "../src/executor";
import { emptyMonitorState, runCycle } from "../src/monitor";
import type { MonitorState } from "../src/monitor";
import { POKE_IN_FLIGHT_SECONDS, wrapperIface, POKE_RETRY_COOLDOWN_SECONDS, emptyPokeState, pokeDue, pokeSettings, pokeStep, shareWatchFindings } from "../src/poke";
import type { PokeState, ShareState } from "../src/poke";
import { decidedConfig, A } from "./fixtures";
import { ADDR, MockChain } from "./mockchain";

const U = (n: number) => BigInt(Math.round(n * 1e6));
const E18 = 10n ** 18n;
const lc = (a: string) => a.toLowerCase();
const T0 = 1_700_000_000; // the mock chain's block time

function baseCfg(poke?: Record<string, unknown>, liquidation = true): any {
  const c = decidedConfig();
  c.deployment = { controller: ADDR.controller, pWavax: ADDR.pWavax, pUsdc: ADDR.pUsdc, oracle: ADDR.guarded, oracleWrapper: ADDR.wrapper, deploymentBlock: 99_000_000 };
  c.operators = [{ name: "op-a", address: ADDR.operator }, { name: "op-b", address: A(0x102) }];
  c.executor.enabled = true;
  c.keeper.enabled = false;
  c.executor.convertToUsdc = false;
  c.shareCollateral = { pToken: ADDR.pShare, underlying: ADDR.vault, liquidation: { enabled: liquidation, maxRepayPerCallUsdc: 60, dailyRepayCapUsdc: 100, minRepayUsdc: 1, retryCooldownSeconds: 30, maxHeldValueUsdc: 200 } };
  if (poke) c.shareCollateral.poke = poke;
  return c;
}
const cfgOn = (extra: Record<string, unknown> = {}): MonitorConfig => requireValidConfig(baseCfg({ enabled: true, ...extra }));

interface Run {
  out: Awaited<ReturnType<typeof pokeStep>>;
  persisted: PokeState[];
}
async function poke(chain: MockChain, state: PokeState = emptyPokeState(), cfg: MonitorConfig = cfgOn(), over: { now?: number; signer?: any; provider?: any } = {}): Promise<Run> {
  const persisted: PokeState[] = [];
  const alerts = new AlertManager(new MemorySink(), [3600]);
  const out = await pokeStep({ ctx: { provider: over.provider ?? chain.provider(), cfg, poolIdentityOk: true }, signer: over.signer ?? chain.signer(), alerts, persist: (s) => persisted.push(s), now: () => over.now ?? chain.ts }, state);
  return { out, persisted };
}
const pokes = (c: MockChain): number => c.sent.filter((s) => s.name === "poke").length;

// ------------------------------------------------------------------ configuration
test("poke config: optional, DEFAULT OFF; enabled needs the executor and the wrapper; the age bounds keep it above the wrapper's 1 h gate and below the stall alert", () => {
  assert.ok(requireValidConfig(baseCfg()), "no poke block (the state of every host until it is configured)");
  assert.equal(pokeSettings(requireValidConfig(baseCfg())), undefined, "absent = off");
  assert.equal(pokeSettings(requireValidConfig(baseCfg({ enabled: false }))), undefined, "enabled false = off (op2 and the treasury host: they still monitor)");
  const s = pokeSettings(cfgOn())!;
  assert.deepEqual(s, { enabled: true, pokeMinAgeSeconds: 3_700, maxFeeGwei: 100, minGasWei: "500000000000000000" }, "defaults: 3700 s, the executor's fee cap and gas floor");
  const custom = pokeSettings(cfgOn({ pokeMinAgeSeconds: 4000, maxFeeGwei: 40, minGasWei: "5000000000000000" }))!;
  assert.deepEqual([custom.pokeMinAgeSeconds, custom.maxFeeGwei, custom.minGasWei], [4000, 40, "5000000000000000"]);
  const bad = (mut: (x: any) => void, re: RegExp) => {
    const x = baseCfg({ enabled: true });
    mut(x);
    const { problems } = validateConfig(x);
    assert.ok(problems.some((p) => re.test(p.path)), `${re}: ${JSON.stringify(problems)}`);
  };
  bad((x) => (x.shareCollateral.poke.enabled = "yes"), /poke\.enabled/);
  bad((x) => (x.executor.enabled = false), /poke\.enabled/);
  bad((x) => delete x.deployment.oracleWrapper, /poke\.enabled/);
  bad((x) => (x.shareCollateral.poke.pokeMinAgeSeconds = 3600), /pokeMinAgeSeconds/); // not above the 1 h upward gate
  bad((x) => (x.shareCollateral.poke.pokeMinAgeSeconds = 20_000), /pokeMinAgeSeconds/); // beyond the stall alert
  bad((x) => (x.shareCollateral.poke.maxFeeGwei = 0), /maxFeeGwei/);
  bad((x) => (x.shareCollateral.poke.minGasWei = "0"), /minGasWei/);
  const disabledNoExecutor = baseCfg({ enabled: false });
  disabledNoExecutor.executor.enabled = false;
  disabledNoExecutor.keeper.enabled = true;
  disabledNoExecutor.shareCollateral.liquidation = { enabled: false };
  assert.ok(requireValidConfig(disabledNoExecutor), "the treasury-keeper host: poke.enabled false needs nothing");
});

test("the example block in config/share-collateral.example.json validates when its placeholders are filled, on every host role", () => {
  const ex = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "config", "share-collateral.example.json"), "utf8"));
  const fill = (v: any): any => JSON.parse(JSON.stringify(v).replace(/"<WRAPPER ADDRESS>"/g, `"${ADDR.wrapper}"`).replace(/"<bpPHAR-USDC pToken>"/g, `"${ADDR.pShare}"`));
  const filled = fill(ex);
  assert.ok(filled.op1.shareCollateral.poke.enabled === true, "op1 pokes");
  assert.ok(filled.op2.shareCollateral.poke.enabled === false && filled.keeper.shareCollateral.poke.enabled === false, "op2 and the treasury host only monitor");
  for (const role of ["op1", "op2", "keeper"] as const) {
    const host = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "config", "hosts", `${role}.json`), "utf8"));
    const merged = { ...host, deployment: { ...host.deployment, ...filled[role].deployment }, shareCollateral: filled[role].shareCollateral };
    const { problems } = validateConfig(merged);
    assert.deepEqual(problems, [], `${role}: ${JSON.stringify(problems)}`);
    assert.equal(!!pokeSettings(requireValidConfig(merged)), role === "op1");
  }
  // unfilled, the example is refused (placeholders): it can never be staged by accident
  const raw = ex.op1;
  assert.ok(validateConfig({ ...JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "config", "hosts", "op1.json"), "utf8")), deployment: { ...raw.deployment }, shareCollateral: raw.shareCollateral }).problems.length > 0);
});

// ------------------------------------------------------------------ the decision
test("pokeDue: the vault must answer and the stored value must be at least pokeMinAgeSeconds old (boundary exact)", () => {
  const s = (over: Partial<ShareState> = {}): ShareState => ({ live: 1_020_000n, stored: 1_020_000n, storedAt: 1000, usingFallback: false, fallbackSecondsLeft: 0, ...over });
  assert.equal(pokeDue(s(), 1000 + 3699, 3700).due, false);
  assert.equal(pokeDue(s(), 1000 + 3700, 3700).due, true, "exactly the age: due");
  assert.equal(pokeDue(s({ live: 0n }), 1000 + 90_000, 3700).due, false, "the vault cannot answer: nothing to store");
  assert.equal(pokeDue(s(), 1000, 3700).due, false);
});

// ------------------------------------------------------------------ the poke loop against the mock chain
test("poke: sends poke() once when due, confirms the receipt, the stored time moves, the in-flight record is cleared, and gas is the estimate plus 50%", async () => {
  const chain = new MockChain(); // stored 4000 s ago, vault answers
  const gas: string[] = [];
  const signer = chain.signer();
  const orig = signer.sendTransaction;
  signer.sendTransaction = async (tx: any) => {
    gas.push(tx.gasLimit.toString());
    assert.equal(lc(tx.to), lc(ADDR.wrapper));
    assert.equal(tx.data, wrapperIface.encodeFunctionData("poke"), "calldata is exactly poke()");
    return orig(tx);
  };
  const r = await poke(chain, emptyPokeState(), cfgOn(), { signer });
  assert.equal(r.out.result, "poked", r.out.note);
  assert.equal(pokes(chain), 1);
  assert.deepEqual(gas, ["105000"], "estimate 70,000 x 1.5");
  assert.equal(chain.lastGoodTime, T0, "the wrapper stored at the block time");
  assert.equal(r.out.state.inFlight, null);
  assert.equal(r.out.state.lastError, null);
  assert.ok(r.out.state.last && r.out.state.last.hash === r.out.hash);
  assert.ok(r.persisted.some((s) => s.inFlight !== null), "the in-flight record was persisted BEFORE the transaction");
  // the next round (as after a restart, from the persisted state): nothing to do, nothing sent
  const r2 = await poke(chain, r.out.state);
  assert.equal(r2.out.result, "not-due");
  assert.equal(pokes(chain), 1, "idempotent: one poke in total");
});

test("poke: not due (stored value younger than 3,700 s) or the vault cannot answer: nothing is sent", async () => {
  const young = new MockChain();
  young.lastGoodTime = T0 - 3_699;
  assert.equal((await poke(young)).out.result, "not-due");
  assert.equal(pokes(young), 0);
  const edge = new MockChain();
  edge.lastGoodTime = T0 - 3_700;
  assert.equal((await poke(edge)).out.result, "poked", "exactly 3,700 s: due");
  const dead = new MockChain();
  dead.vaultLive = 0n; // the vault's feed is stale: it cannot answer, the fallback is in use; poking would be refused anyway
  dead.lastGoodTime = T0 - 50_000;
  const d = await poke(dead);
  assert.equal(d.out.result, "not-due");
  assert.equal(pokes(dead), 0);
});

test("poke: an upward move is never refused at the default age (the wrapper's 1 h gate is below 3,700 s) and the +2% cap is the wrapper's business", async () => {
  const chain = new MockChain();
  chain.vaultLive = 1_100_000n; // +7.8%: the wrapper stores 1.02 x 1.02
  const r = await poke(chain);
  assert.equal(r.out.result, "poked", r.out.note);
  assert.equal(chain.lastGood, 1_040_400n);
});

test("poke: DISABLED (absent block, or enabled false) does nothing at all", async () => {
  for (const cfg of [requireValidConfig(baseCfg()), requireValidConfig(baseCfg({ enabled: false }))]) {
    const chain = new MockChain();
    const calls: string[] = [];
    const p: any = new Proxy(chain.provider(), { get: (t, k) => (typeof t[k] === "function" ? (...a: any[]) => (calls.push(String(k)), t[k](...a)) : t[k]) });
    const r = await poke(chain, emptyPokeState(), cfg, { provider: p });
    assert.equal(r.out.result, "disabled");
    assert.equal(calls.length, 0, "no chain read");
    assert.equal(chain.sent.length, 0);
  }
});

test("poke: a simulation that returns false sends nothing (no gas wasted), counts rounds, and the monitor warns after 3; a later success resets it", async () => {
  const chain = new MockChain();
  chain.forcePokeFalse = true;
  let st = emptyPokeState();
  for (let i = 1; i <= 3; i++) {
    const r = await poke(chain, st);
    assert.equal(r.out.result, "refused");
    st = r.out.state;
    assert.equal(st.refusedRounds, i);
  }
  assert.equal(pokes(chain), 0, "never sent");
  const f = shareWatchFindings({ state: { live: 1_020_000n, stored: 1_020_000n, storedAt: T0 - 4000, usingFallback: false, fallbackSecondsLeft: 82_400 }, price: 1n }, T0, st);
  assert.ok(f.some((x) => x.key === "share:poke-refused" && x.severity === "warn"));
  assert.equal(shareWatchFindings({ price: 1n }, T0, { ...st, refusedRounds: 2 }).some((x) => x.key === "share:poke-refused"), false, "2 rounds: not yet");
  chain.forcePokeFalse = false;
  const ok = await poke(chain, st);
  assert.equal(ok.out.result, "poked");
  assert.equal(ok.out.state.refusedRounds, 0);
});

test("poke: a reverting simulation, a low fee cap, a gas floor, an absurd gas estimate: nothing is sent; failures are recorded as errors with a retry cooldown", async () => {
  // simulation reverts
  const c1 = new MockChain();
  c1.pokeCallReverts = true;
  const r1 = await poke(c1);
  assert.equal(r1.out.result, "error");
  assert.equal(pokes(c1), 0);
  assert.match(r1.out.state.lastError!.message, /simulation reverted/);
  assert.equal(r1.out.state.retryAfter, T0 + POKE_RETRY_COOLDOWN_SECONDS);
  c1.ts = T0 + POKE_RETRY_COOLDOWN_SECONDS - 1;
  const cool = await poke(c1, r1.out.state);
  assert.equal(cool.out.result, "skipped", "inside the cooldown no new attempt");
  assert.match(cool.out.note!, /retry cooldown/);
  c1.pokeCallReverts = false;
  c1.ts = T0 + POKE_RETRY_COOLDOWN_SECONDS;
  const after = await poke(c1, r1.out.state);
  assert.equal(after.out.result, "poked");
  assert.equal(after.out.state.lastError, null, "cleared by the success");
  // fee above the cap (the mock network fee is 30 gwei)
  const c2 = new MockChain();
  const r2 = await poke(c2, emptyPokeState(), cfgOn({ maxFeeGwei: 20 }));
  assert.equal(r2.out.result, "skipped");
  assert.match(r2.out.note!, /above the cap 20 gwei/);
  assert.equal(pokes(c2), 0);
  // gas floor
  const c3 = new MockChain();
  const r3 = await poke(c3, emptyPokeState(), cfgOn({ minGasWei: "2000000000000000000" }));
  assert.equal(r3.out.result, "error");
  assert.match(r3.out.state.lastError!.message, /below the poke floor/);
  assert.equal(pokes(c3), 0);
  // an estimate that is not a poke
  const c4 = new MockChain();
  c4.pokeGas = 600_000;
  const r4 = await poke(c4);
  assert.equal(r4.out.result, "error");
  assert.equal(pokes(c4), 0);
});

test("poke: restart safety: an in-flight record blocks a second poke for 10 minutes, a pending nonce blocks it, and a stale record does not", async () => {
  const chain = new MockChain();
  const st: PokeState = { ...emptyPokeState(), inFlight: { at: T0 - 100 } };
  assert.equal((await poke(chain, st)).out.result, "skipped");
  assert.equal(pokes(chain), 0);
  const stale: PokeState = { ...emptyPokeState(), inFlight: { at: T0 - POKE_IN_FLIGHT_SECONDS } };
  assert.equal((await poke(chain, stale)).out.result, "poked", "the record is 10 minutes old: the earlier attempt is considered lost");
  const c2 = new MockChain();
  c2.pendingExtra = 1; // the wallet has a transaction in the mempool
  const r2 = await poke(c2);
  assert.equal(r2.out.result, "skipped");
  assert.match(r2.out.note!, /still pending/);
  assert.equal(pokes(c2), 0);
  // a fresh stored value confirms a poke that was in flight: the record is dropped
  const c3 = new MockChain();
  c3.lastGoodTime = T0 - 30;
  const r3 = await poke(c3, { ...emptyPokeState(), inFlight: { at: T0 - 60 } });
  assert.equal(r3.out.result, "not-due");
  assert.equal(r3.out.state.inFlight, null);
});

test("poke: one poke at a time (two concurrent rounds send exactly one transaction)", async () => {
  const chain = new MockChain();
  const [a, b] = await Promise.all([poke(chain), poke(chain)]);
  assert.equal(pokes(chain), 1);
  assert.deepEqual([a.out.result, b.out.result].sort(), ["poked", "skipped"]);
});

test("poke: a mined-but-reverted poke, a poke that did not move the stored time, and an unconfirmed poke are errors (never exceptions); the unconfirmed one keeps the in-flight guard", async () => {
  const c1 = new MockChain();
  c1.pokeTxReverts = true;
  const r1 = await poke(c1);
  assert.equal(r1.out.result, "error");
  assert.match(r1.out.state.lastError!.message, /mined and reverted/);
  assert.equal(r1.out.state.inFlight, null);
  const c2 = new MockChain();
  c2.pokeTxNoop = true;
  const r2 = await poke(c2);
  assert.equal(r2.out.result, "error");
  assert.match(r2.out.state.lastError!.message, /stored time did not move/);
  const c3 = new MockChain();
  const s3 = c3.signer();
  s3.sendTransaction = async () => {
    throw new Error("nonce too low (mock)");
  };
  const r3 = await poke(c3, emptyPokeState(), cfgOn(), { signer: s3 });
  assert.equal(r3.out.result, "error");
  assert.ok(r3.out.state.inFlight, "a send that failed in an unknown way keeps the guard (it may have been broadcast)");
  // everything throws: still no exception
  const bad: any = new Proxy({}, { get: () => async () => { throw new Error("rpc down (mock)"); } });
  const r4 = await poke(new MockChain(), emptyPokeState(), cfgOn(), { provider: bad });
  assert.equal(r4.out.result, "error");
  // a persistence failure does not crash it either
  const c5 = new MockChain();
  const out5 = await pokeStep({ ctx: { provider: c5.provider(), cfg: cfgOn(), poolIdentityOk: true }, signer: c5.signer(), alerts: new AlertManager(new MemorySink(), [3600]), persist: () => { throw new Error("disk full (mock)"); }, now: () => T0 }, emptyPokeState());
  assert.equal(out5.result, "poked");
});

test("poke: a stale RPC (latest block older than maxBlockLagSeconds) sends nothing", async () => {
  const chain = new MockChain();
  const r = await poke(chain, emptyPokeState(), cfgOn(), { now: T0 + 61 });
  assert.equal(r.out.result, "skipped");
  assert.match(r.out.note!, /RPC is stale/);
  assert.equal(pokes(chain), 0);
});

test("poke: the signer must be the configured operator", async () => {
  const chain = new MockChain();
  const s = chain.signer();
  s.getAddress = async () => A(0x999);
  const r = await poke(chain, emptyPokeState(), cfgOn(), { signer: s });
  assert.equal(r.out.result, "error");
  assert.equal(pokes(chain), 0);
});

// ------------------------------------------------------------------ monitoring
const keys = (fs_: Array<{ key: string }>): string[] => fs_.map((x) => x.key).sort();
const SS = (over: Partial<ShareState> = {}): ShareState => ({ live: 1_020_000n, stored: 1_020_000n, storedAt: T0 - 600, usingFallback: false, fallbackSecondsLeft: 85_800, ...over });

test("share watch findings: severities, thresholds and keys", () => {
  assert.deepEqual(shareWatchFindings(undefined, T0, undefined), [], "no wrapper configured: silent");
  assert.deepEqual(shareWatchFindings({ state: SS(), price: 1n }, T0, emptyPokeState()), [], "healthy");
  // fallback in use with plenty of window: crit "served from fallback" only
  const fb = shareWatchFindings({ state: SS({ live: 0n, usingFallback: true, storedAt: T0 - 10_000, fallbackSecondsLeft: 76_400 }), price: 1n }, T0, undefined);
  assert.deepEqual(keys(fb), ["share:fallback"]);
  assert.equal(fb[0]!.severity, "crit");
  assert.match(fb[0]!.message, /^share price served from fallback/);
  // exactly 6 h left: not yet; one second less: crit
  assert.deepEqual(keys(shareWatchFindings({ state: SS({ live: 0n, usingFallback: true, fallbackSecondsLeft: 21_600 }), price: 1n }, T0, undefined)), ["share:fallback"]);
  const low = shareWatchFindings({ state: SS({ live: 0n, usingFallback: true, storedAt: T0 - 70_000, fallbackSecondsLeft: 21_599 }), price: 1n }, T0, undefined);
  assert.deepEqual(keys(low), ["share:fallback", "share:fallback-expiring"]);
  assert.ok(low.every((x) => x.severity === "crit"));
  assert.match(low.find((x) => x.key === "share:fallback-expiring")!.message, /^fallback time left below 6 h/);
  // low time left but NOT using the fallback (vault answers): no expiring alert
  assert.equal(shareWatchFindings({ state: SS({ fallbackSecondsLeft: 100, storedAt: T0 - 86_300 }), price: 1n }, T0, undefined).some((x) => x.key === "share:fallback-expiring"), false);
  // price 0: crit
  const z = shareWatchFindings({ state: SS({ live: 0n, stored: 1_020_000n, usingFallback: false, fallbackSecondsLeft: 0, storedAt: T0 - 90_000 }), price: 0n }, T0, undefined);
  assert.ok(z.some((x) => x.key === "share:price-zero" && x.severity === "crit" && /^wrapper price for the share market is 0/.test(x.message)));
  assert.equal(shareWatchFindings({ price: 0n, stateError: "x" }, T0, undefined).some((x) => x.key === "share:price-zero"), true, "price 0 is reported even when shareState is unreadable");
  // stalled: warn when older than 3 h while the vault answers; silent exactly at 3 h; silent when the vault cannot answer (that is the fallback alert's business)
  assert.deepEqual(keys(shareWatchFindings({ state: SS({ storedAt: T0 - 10_801 }), price: 1n }, T0, undefined)), ["share:poke-stalled"]);
  assert.equal(shareWatchFindings({ state: SS({ storedAt: T0 - 10_800 }), price: 1n }, T0, undefined).length, 0);
  assert.equal(shareWatchFindings({ state: SS({ live: 0n, usingFallback: true, storedAt: T0 - 20_000, fallbackSecondsLeft: 66_400 }), price: 1n }, T0, undefined).some((x) => x.key === "share:poke-stalled"), false);
  assert.equal(shareWatchFindings({ state: SS({ storedAt: T0 - 10_801 }), price: 1n }, T0, undefined)[0]!.severity, "warn");
  // poke failing and unreadable wrapper: warn
  const e = shareWatchFindings({ state: SS(), price: 1n }, T0, { ...emptyPokeState(), lastError: { at: T0, message: "boom" } });
  assert.deepEqual(keys(e), ["share:poke-error"]);
  assert.equal(e[0]!.severity, "warn");
  assert.deepEqual(keys(shareWatchFindings({ stateError: "no code", priceError: "no code" }, T0, undefined)), ["share:price-unreadable", "share:state-unreadable"]);
});

function monitorCfg(): MonitorConfig {
  const c = baseCfg({ enabled: false });
  return requireValidConfig(c);
}
async function cycle(chain: MockChain, cfg: MonitorConfig, state: MonitorState, alerts: AlertManager) {
  return runCycle({ provider: chain.provider(), cfg, poolIdentityOk: true }, state, alerts, { extraAccounts: [] });
}

test("monitor cycle: the fallback alerts are raised on a host that does NOT poke, with severity labels, and de-duplicated across cycles", async () => {
  const chain = new MockChain();
  chain.vaultLive = 0n; // the vault's feed is stale
  chain.lastGoodTime = T0 - 70_000; // 16,400 s of window left: under 6 h
  const cfg = monitorCfg();
  assert.equal(pokeSettings(cfg), undefined, "this host does not poke");
  const sink = new MemorySink();
  const alerts = new AlertManager(sink, [3600]);
  const r1 = await cycle(chain, cfg, emptyMonitorState(cfg), alerts);
  const share = sink.messages.filter((m) => m.key.startsWith("share:"));
  assert.deepEqual(share.map((m) => `${m.severity}:${m.key}`).sort(), ["crit:share:fallback", "crit:share:fallback-expiring"]);
  assert.ok(share.some((m) => /^share price served from fallback/.test(m.text)));
  assert.ok(share.some((m) => /^fallback time left below 6 h/.test(m.text)));
  assert.ok(r1.report.findings.some((f) => f.key === "share:fallback"));
  // the same condition next cycle: no second message
  const n = sink.messages.length;
  await cycle(chain, cfg, r1.state, alerts);
  assert.equal(sink.messages.length, n, "de-duplicated");
  // the price goes to 0 (the window ran out): a new crit
  chain.ts += 20_000;
  chain.wrapperPrice = 0n;
  await cycle(chain, cfg, r1.state, alerts);
  assert.ok(sink.messages.some((m) => m.key === "share:price-zero" && m.severity === "crit" && /^wrapper price for the share market is 0/.test(m.text)));
  // recovery: the vault answers again, price back
  chain.vaultLive = 1_020_000n;
  chain.lastGoodTime = chain.ts - 100;
  chain.wrapperPrice = undefined;
  await cycle(chain, cfg, r1.state, alerts);
  for (const k of ["share:fallback", "share:fallback-expiring", "share:price-zero"]) assert.ok(sink.messages.some((m) => m.kind === "resolved" && m.key === k), `${k} resolved`);
});

test("monitor cycle: stalled poke is a WARNING while the vault answers; a poke state with errors and refusals is carried through the cycle and shown", async () => {
  const chain = new MockChain();
  chain.lastGoodTime = T0 - 11_000;
  const cfg = monitorCfg();
  const sink = new MemorySink();
  const alerts = new AlertManager(sink, [3600]);
  const st: MonitorState = { ...emptyMonitorState(cfg), poke: { ...emptyPokeState(), refusedRounds: 3, lastError: { at: T0 - 5, message: "x" } } };
  const out = await cycle(chain, cfg, st, alerts);
  assert.deepEqual(sink.messages.filter((m) => m.key.startsWith("share:")).map((m) => `${m.severity}:${m.key}`).sort(), ["warn:share:poke-error", "warn:share:poke-refused", "warn:share:poke-stalled"]);
  assert.deepEqual(out.state.poke, st.poke, "the poke state survives the cycle");
});

test("monitor cycle: hosts without the wrapper or the share block, or with an unreadable wrapper, behave as stated", async () => {
  const chain = new MockChain();
  chain.vaultLive = 0n;
  const noWrapper = baseCfg();
  delete noWrapper.deployment.oracleWrapper;
  delete noWrapper.shareCollateral;
  const cfg0 = requireValidConfig(noWrapper);
  const sink = new MemorySink();
  await cycle(chain, cfg0, emptyMonitorState(cfg0), new AlertManager(sink, [3600]));
  assert.equal(sink.messages.some((m) => m.key.startsWith("share:")), false, "silent until configured");
  // wrapper configured but the call fails (wrong address / RPC): a warning, the cycle still completes
  const bad = new MockChain();
  const prov = bad.provider();
  const call = prov.call;
  prov.call = async (tx: any, ...rest: any[]) => {
    if (lc(tx.to) === lc(ADDR.wrapper)) throw new Error("call revert exception (mock)");
    return call(tx, ...rest);
  };
  const cfg = monitorCfg();
  const sink2 = new MemorySink();
  const r = await runCycle({ provider: prov, cfg, poolIdentityOk: true }, emptyMonitorState(cfg), new AlertManager(sink2, [3600]), { extraAccounts: [] });
  assert.equal(r.report.blind, false);
  assert.deepEqual(sink2.messages.filter((m) => m.key.startsWith("share:")).map((m) => m.key).sort(), ["share:price-unreadable", "share:state-unreadable"]);
});

test("a failing alert sink does not break the poke findings path: the cycle still completes (the base branch's non-fatal sink)", async () => {
  const chain = new MockChain();
  chain.vaultLive = 0n;
  const cfg = monitorCfg();
  const sink = { send: async () => { throw new Error("telegram 429 (mock)"); } };
  const origErr = console.error;
  const origLog = console.log;
  console.error = () => {};
  console.log = () => {};
  try {
    const r = await cycle(chain, cfg, emptyMonitorState(cfg), new AlertManager(sink, [3600]));
    assert.ok(r.report.findings.some((f) => f.key === "share:fallback"));
  } finally {
    console.error = origErr;
    console.log = origLog;
  }
});

// ------------------------------------------------------------------ the liquidation route does not know the fallback
const shareBorrower = (chain: MockChain, debt = 100, shareUsd = 110): void => {
  chain.accounts[lc(ADDR.borrower)] = { debt: U(debt), pShare: (U(shareUsd) * E18) / (2n * 10n ** 14n), shortfall: true };
};
async function liquidate(chain: MockChain) {
  const cfg = requireValidConfig(baseCfg({ enabled: false }, true));
  const alerts = new AlertManager(new MemorySink(), [3600]);
  return executorStep({ ctx: { provider: chain.provider(), cfg, poolIdentityOk: true }, signer: chain.signer(), alerts, slippageBoundBp: 100, accounts: async () => [ADDR.borrower], persist: () => {}, now: () => T0 + 100 } as any, emptyExecutorState());
}

test("share liquidation while the price is the FALLBACK price: the route is unchanged (same calls as with the live price at the same price) and the executor has no fallback logic", async () => {
  const price = 989_400n * 10n ** 24n; // the wrapper's fallback price: 1.02 x 97% = 0.9894 USD per share (Peridot scale for a 6-decimal share)
  const live = new MockChain();
  live.prices[lc(ADDR.pShare)] = price;
  shareBorrower(live);
  const fb = new MockChain();
  fb.vaultLive = 0n; // shareState says usingFallback = true
  fb.prices[lc(ADDR.pShare)] = price;
  shareBorrower(fb);
  const o1 = await liquidate(live);
  const o2 = await liquidate(fb);
  assert.ok(o1.round && o2.round, JSON.stringify([o1.skipped, o2.skipped]));
  assert.deepEqual(fb.sent, live.sent, "byte-identical transactions with and without the fallback");
  assert.deepEqual(fb.sent.map((s) => s.name), ["approve", "liquidateBorrow"]);
  assert.equal(o2.round!.keptCollateral, true);
  assert.equal(o2.round!.repay, o1.round!.repay);
  // the executor reads the controller's price and the controller's account liquidity only: no wrapper-specific symbol appears in its source or in share.ts
  for (const f of ["executor.ts", "share.ts"]) {
    const src = fs.readFileSync(path.join(__dirname, "..", "..", "src", f), "utf8");
    assert.equal(/shareState|usingFallback|lastGood|FallbackPriceStored|wrapperIface|from "\.\/poke"/.test(src), false, `${f} must not special-case the fallback`);
  }
});

test("share liquidation when the price is 0 (the 24 h window ran out, or the vault is broken): nothing is sent, whatever the controller reports", async () => {
  const chain = new MockChain();
  chain.vaultLive = 0n;
  chain.lastGoodTime = T0 - 90_000; // expired
  chain.prices[lc(ADDR.pShare)] = 0n;
  shareBorrower(chain);
  const out = await liquidate(chain);
  assert.equal(out.round, undefined);
  assert.equal(chain.sent.length, 0, "no approval, no liquidation");
});

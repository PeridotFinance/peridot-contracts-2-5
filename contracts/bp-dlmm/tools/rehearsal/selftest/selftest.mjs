// SELF-TEST of the harness plumbing against a LOCAL anvil WITHOUT a fork (chain id 43114, fixtures from Fixtures.sol): results writer, 50 % gas headroom, failure tracing with custom-error
// decoding, impersonation, balance forcing (slot 0 and slot 9 layouts), mock feeds + re-pin after a warp, snapshots, prestate tracer, timestamp control. It tests NO product logic.
// Started by selftest.sh (REH_SELFTEST=1 REH_FIXTURE_OUT=<dir with Fixtures.sol/*.json>).
import fs from "node:fs";
import path from "node:path";
import { ethers, utils, BN, A, C, check, note, group, finish, results, provider, rpc, impersonate, setErc20Balance, tx, expectRevert, codeOrRevert, addErrorAbi, decodeErr,
  etchFeed, setFeed, repin, warp, warpTo, headTs, readFeed, scenario, touched, mocks, signer, setNextTimestamp, mine, LIVE, OUTDIR, checkpoint, blockNumber, progress, where, failuresOf } from "../lib.mjs";
import { shareExpect, fallbackLeg, expectPoke } from "../outage.mjs";
import { crossCheckModel } from "../phar.mjs";

const FX = process.env.REH_FIXTURE_OUT;
const art = (n) => JSON.parse(fs.readFileSync(path.join(FX, "Fixtures.sol", `${n}.json`), "utf8"));
async function deploy(name, from, args = []) {
  const a = art(name); const f = new ethers.ContractFactory(a.abi, a.bytecode.object, signer(from));
  const c = await f.deploy(...args); await c.deployed(); return new ethers.Contract(c.address, a.abi, provider);
}
const dep = A("DE17");

await group("P0 plumbing", async () => {
  check("P0.1", (await provider.getNetwork()).chainId === 43114 && !!(await rpc("anvil_nodeInfo")), "local anvil, chain id 43114, anvil_nodeInfo answers");
  check("P0.2", Object.keys(LIVE).length >= 30 && LIVE.LEDGER === "0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD", `live-addresses.env parsed and checksummed (${Object.keys(LIVE).length} addresses)`);
  await impersonate(dep);
  check("P0.3", (await provider.getBalance(dep)).gt(0), "impersonate + anvil_setBalance");
  const t0 = await deploy("Erc20Slot0", dep), t9 = await deploy("Erc20Slot9", dep), th = await deploy("Thrower", dep);
  const who = A("B0B0");
  const s0 = await setErc20Balance(t0.address, who, 12345), s9 = await setErc20Balance(t9.address, who, 777);
  check("P0.4", s0 === 0 && s9 === 9 && (await t0.balanceOf(who)).eq(12345) && (await t9.balanceOf(who)).eq(777), `setErc20Balance found slot ${s0} and slot ${s9} (the FiatToken-like layout)`);

  // 50 % gas headroom: the mined transaction's gas limit is 1.5 x the estimate
  const r = await tx("ok()", (o) => th.connect(signer(dep)).ok(o));
  const t = await provider.getTransaction(r.transactionHash);
  check("P0.5", t.gasLimit.gte(r.gasUsed.mul(14).div(10)) && results.gas["ok()"] === r.gasUsed.toNumber(), `gas headroom: limit ${t.gasLimit} vs used ${r.gasUsed} (>= 1.4 x), gas recorded in results`);

  // failure tracing: nested custom error decoded through the call tracer; the revert text carries it
  addErrorAbi(["error Boom(uint256 code)"]);
  let msg = ""; try { await tx("inner()", (o) => th.connect(signer(dep)).inner(o)); } catch (e) { msg = e.message; }
  check("P0.6", /Boom\(7\)/.test(msg), `tx() failure path: estimateGas failed -> replayed with a fixed gas limit -> traced -> decoded: "${msg.slice(0, 90)}"`);
  const e1 = await expectRevert(() => th.callStatic.req()), e2 = await expectRevert(() => th.callStatic.panic()), e3 = await expectRevert(() => th.callStatic.boom(9)), e4 = await expectRevert(() => th.callStatic.ok());
  check("P0.7", e1 === 'Error("nope")' && /^Panic\(0x32\)/.test(e2) && e3 === "Boom(9)" && e4 === null, `expectRevert decodes Error(string), Panic(uint256) and a custom error; no revert -> null (${e1} / ${e2} / ${e3})`);
  const cr = await codeOrRevert(() => th.callStatic.boom(1));
  check("P0.8", cr.revert === "Boom(1)", `codeOrRevert reports a revert as { revert: ... } (${cr.revert})`);
  check("P0.9", decodeErr(new Error("some 0x08c379a0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000026869000000000000000000000000000000000000000000000000000000000000 data")) === 'Error("hi")', "decodeErr extracts revert data from an error message");
});

await group("P1 feeds, time, snapshots", async () => {
  // a pre-existing feed stand-in at a fixed address (as the real feeds are on the fork), then the harness etches/sets it
  const feed = A("FEED01"); const mock = JSON.parse(fs.readFileSync(path.join(path.dirname(new URL(import.meta.url).pathname), "..", "MockFeed.json"), "utf8"));
  await rpc("anvil_setCode", [feed, "0x" + mock.deployedBytecode.replace(/^0x/, "")]);
  await rpc("anvil_setStorageAt", [feed, "0x0", utils.hexZeroPad("0x5f5e100", 32)]); await rpc("anvil_setStorageAt", [feed, "0x1", utils.hexZeroPad(BN(await headTs()).toHexString(), 32)]);
  const real = await etchFeed(feed);
  check("P1.1", real.answer.eq(100000000) && (await readFeed(feed)).answer.eq(100000000), "etchFeed keeps the real answer (1.00000000) and writes it into the mock");
  await setFeed(feed, 99_000_000);
  check("P1.2", (await readFeed(feed)).answer.eq(99_000_000) && (await readFeed(feed)).age <= 2, "setFeed: answer 0.99, age ~0");
  await warp(100_000);
  const f2 = await readFeed(feed);
  check("P1.3", f2.age <= 2 && f2.answer.eq(99_000_000), `warp(100000 s) then repin: the mock is fresh again (age ${f2.age} s) with the same answer`);
  // warp while a 1 s block-timestamp interval is set (the real harness sets it in B0 and B4 warps afterwards)
  await rpc("anvil_setBlockTimestampInterval", [1]); await mine(1); const tA = await headTs(); await mine(1); const tB = await headTs();
  await warp(100_000); const tC = await headTs();
  check("P1.3b", tB - tA === 1 && tC - tB >= 100_000, `with anvil_setBlockTimestampInterval(1): blocks are 1 s apart (${tB - tA}) and warp(100000) still jumps the head by ${tC - tB} s`);
  await setFeed(feed, 99_000_000, (await headTs()) - 4000);
  await warp(10);
  check("P1.4", (await readFeed(feed)).age >= 4000, "a deliberately stale mock (explicit updatedAt) is NOT re-pinned by a warp");
  await setFeed(feed, 99_000_000);

  const tkn = A("70C1");
  const t0 = await deploy("Erc20Slot0", dep); const holder = A("AB1E");
  await setErc20Balance(t0.address, holder, 100);
  await scenario("revert-test", async () => { await setErc20Balance(t0.address, holder, 555); await setFeed(feed, 50_000_000); });
  check("P1.5", (await t0.balanceOf(holder)).eq(100) && (await readFeed(feed)).answer.eq(99_000_000) && (await readFeed(feed)).age <= 2, "scenario(): state returns to the snapshot, the mock answer is restored and the feed is re-pinned fresh");

  // timestamp control: set the next block's timestamp exactly
  const want = (await headTs()) + 777; await setNextTimestamp(want); await mine(1);
  check("P1.6", (await headTs()) === want, `evm_setNextBlockTimestamp pins the next block (${want})`);
  // prestate tracer: which contracts a transaction touched
  const th = await deploy("Thrower", dep);
  const r = await tx("ok2", (o) => th.connect(signer(dep)).ok(o));
  const tc = await touched(r.transactionHash);
  check("P1.7", tc.addresses.map((a) => a.toLowerCase()).includes(th.address.toLowerCase()), `touched(): ${tc.mode} lists the called contract (${tc.addresses.length} addresses)`);
  note("P1.8", "this NOTE line exercises the third result type (neither pass nor fail)");
});

// ---- P3: the harness's group-B10 helpers against the REAL v2 wrapper bytecode (BP_OUT), deployed on stand-in vault / base oracle / pToken fixtures. This is the only place the outage arithmetic, the poke
//      expectations, shareState() indices, warpTo and the exact-24 h boundary have ever met the real contract code; the vault, the feeds and the controller are NOT the live ones.
await group("P3 v2 wrapper vs the outage helpers", async () => {
  const wa = path.join(process.env.BP_OUT || "/nonexistent", "PharaohDlmmShareOracle.sol", "PharaohDlmmShareOracle.json");
  if (!fs.existsSync(wa)) { note("P3.0", `no wrapper artifact at ${wa}: the v2 helper test was skipped`); return; }
  const j = JSON.parse(fs.readFileSync(wa, "utf8"));
  const asset = await deploy("FxAsset", dep), base = await deploy("FxBase", dep), vault = await deploy("FxVault", dep, [asset.address]), market = await deploy("FxMarket", dep, [vault.address]);
  const wf = new ethers.ContractFactory(j.abi, j.bytecode.object, signer(dep)); const wc = await wf.deploy(base.address, market.address); await wc.deployed();
  const w = new ethers.Contract(wc.address, j.abi, provider), sig = signer(dep);
  const runtime = (await provider.getCode(w.address)).length / 2 - 1;
  const state = async () => { const x = await w.shareState(); return { live: x[0], stored: x[1], at: x[2].toNumber(), fb: x[3], left: x[4] }; };
  const price = () => w.getUnderlyingPrice(market.address);
  const usd = () => base.usd();
  check("P3.1", (await price()).eq(shareExpect(1_050_000, await usd())) && (await w.getShareUsdPrice()).eq((await price()).div(BN(10).pow(12))) && (await w.lastGoodAssetsPerShare()).eq(1_050_000) && (await state()).live.eq(1_050_000),
    `live path: price = shareExpect(1,050,000, 1e18) = ${await price()}, getShareUsdPrice = price / 1e12, constructor stored 1,050,000 (the fixture wrapper's runtime is ${runtime} bytes; the product build is 3,628)`);

  // poke(): the harness's expectPoke (written from the specification) against the contract over a scripted sequence
  const steps = [["10 s later, live +4.8 % (inside the 1 h gate)", 10, 1_100_000, false], ["3,601 s later, live still +4.8 %", 3601, 1_100_000, false], ["3,601 s later again", 3601, 1_100_000, false],
    ["5 s later, live DOWN to 1,000,000", 5, 1_000_000, false], ["10 s later, the vault is DEAD", 10, 1_000_000, true], ["90,000 s later (older than 24 h), alive again at 2,000,000", 90_000, 2_000_000, false]];
  let all = true; const lines = [];
  for (const [label, dt, leg, dead] of steps) {
    await warp(dt); await tx("fixture set", (o) => vault.connect(sig).set(leg, dead, o));
    const before = await state(), staticRet = await w.callStatic.poke();
    const exStatic = dead ? { stored: false } : expectPoke(before.stored, before.at, leg, await headTs());
    const r = await tx("poke", (o) => w.connect(sig).poke(o)); const bts = (await provider.getBlock(r.blockNumber)).timestamp;
    const ex = dead ? { stored: false } : expectPoke(before.stored, before.at, leg, bts), after = await state();
    const okStep = staticRet === exStatic.stored && (ex.stored ? after.stored.eq(ex.value) && after.at === bts : after.stored.eq(before.stored) && after.at === before.at);
    all = all && okStep; lines.push(`${label}: ${okStep ? "ok" : "MISMATCH"} stored ${before.stored} -> ${after.stored}`);
  }
  check("P3.2", all, `expectPoke() (written from BRIEF-v2) agrees with the real contract on ${steps.length} scripted pokes (upward refused inside 1 h, capped +2 %, downward at once, refused while the vault is dead, uncapped after 24 h): ${lines.join(" | ")}`, lines.join(" | "));

  // the fallback: price, window, the exact boundary (eth_call sees the head block's timestamp)
  await tx("fixture alive", (o) => vault.connect(sig).set(1_000_000, false, o)); await warp(5);
  await tx("poke", (o) => w.connect(sig).poke(o)); const base0 = await state();
  await tx("fixture dead", (o) => vault.connect(sig).set(1_000_000, true, o));
  const sOut = await state(), want = shareExpect(fallbackLeg(sOut.stored), await usd());
  check("P3.3", sOut.fb === true && sOut.live.eq(0) && (await price()).eq(want) && want.gt(0) && sOut.left.eq(86400 - ((await headTs()) - sOut.at)) && (await w.callStatic.poke()) === false,
    `fallback: usingFallback true, live 0, price ${await price()} = floor(stored ${sOut.stored} x 0.97) x USD price (recomputed ${want}), ${sOut.left} s left; poke() returns false while the vault is dead`);
  await warpTo(base0.at + 86400);
  const e1 = await state(), p1 = await price();
  await warpTo(base0.at + 86401);
  const e2 = await state(), p2 = await price();
  check("P3.4", e1.fb === true && e1.left.eq(0) && p1.eq(want) && p1.gt(0) && e2.fb === false && e2.left.eq(0) && p2.eq(0),
    `the 24 h boundary: at age EXACTLY 86,400 s the fallback is valid (usingFallback ${e1.fb}, 0 s left, price ${p1}); one second later it is 0 (usingFallback ${e2.fb}, price ${p2}) - both read with static calls at the head block's timestamp`);
  await tx("fixture alive", (o) => vault.connect(sig).set(1_000_000, false, o)); await tx("poke", (o) => w.connect(sig).poke(o));
  await tx("fixture dead", (o) => vault.connect(sig).set(1_000_000, true, o)); await tx("USD price 0", (o) => base.connect(sig).setUsd(0, o));
  const nz = await state();
  check("P3.5", nz.fb === false && (await price()).eq(0), "never a fallback when the base oracle has no USDC price (usingFallback false, price 0), even inside the window");
  // v3: ONLY the vault's own FeedInvalid(uint8) is an outage. Every other failure is a BROKEN vault: price 0 at once, usingFallback false, even with a fresh stored value and a live USDC price
  await tx("fixture alive", (o) => vault.connect(sig).set(1_000_000, false, o)); await tx("USD price back", (o) => base.connect(sig).setUsd(ethers.constants.WeiPerEther, o));
  await tx("poke", (o) => w.connect(sig).poke(o));
  const kinds = [[2, "ExitFailed() (a failed pair read)"], [3, "an answer of 0 (NAV rounds to nothing)"], [4, "an EMPTY revert (out of gas)"], [5, 'Error("boom")'], [6, "a short return (16 bytes)"]];
  let allBroken = true; const klines = [];
  for (const [m, label] of kinds) {
    await tx("fixture broken", (o) => vault.connect(sig).setMode(1_000_000, m, o));
    const sb = await state(), pb = await price(), pk = await w.callStatic.poke();
    const ok = pb.eq(0) && sb.fb === false && sb.live.eq(0) && pk === false && sb.left.gt(0); allBroken = allBroken && ok; klines.push(`${label}: ${ok ? "price 0, no fallback" : "WRONG price " + pb + " fb " + sb.fb}`);
  }
  await tx("fixture FeedInvalid", (o) => vault.connect(sig).setMode(1_000_000, 1, o));
  const sf = await state();
  check("P3.7", allBroken && sf.fb === true && (await price()).gt(0), `v3: ${klines.join(" | ")}; the SAME stored value and window serve the fallback again as soon as the vault reverts with FeedInvalid(2) (usingFallback ${sf.fb}, price ${await price()})`, klines.join(" | "));
  await tx("fixture alive", (o) => vault.connect(sig).set(1_000_000, false, o)); await tx("poke", (o) => w.connect(sig).poke(o));
  await tx("fixture dead", (o) => vault.connect(sig).set(1_000_000, true, o)); await tx("USD price 0", (o) => base.connect(sig).setUsd(0, o));
  await tx("USD price back", (o) => base.connect(sig).setUsd(ethers.constants.WeiPerEther, o));
  check("P3.6", (await price()).eq(shareExpect(fallbackLeg((await state()).stored), ethers.constants.WeiPerEther)), "fallback resumes when the USDC price returns (still inside the window)");
});

await group("P4 PHAR expected-split model vs the generator", async () => {
  const proj = process.env.REH_REWARDS_PROJ || "", gfile = path.join(proj, "tools", "dlmm-rewards-root.mjs");
  if (!proj || !fs.existsSync(gfile)) { note("P4.0", "the rewards project's generator is not available: the model cross-check was skipped"); return; }
  process.env.ETHERS_DIR = path.join(process.env.REH_ETHERS_DIR, "node_modules", "ethers");
  const R = await import(gfile);
  const cc = crossCheckModel(R, 11), cc2 = crossCheckModel(R, 4242);
  check("P4.1", cc.ok && cc2.ok, `the harness's expected-split model equals the generator's exported wrapperSplit on ${cc.cases + cc2.cases} random histories (two seeds; one event in four shares its block with the previous one)`, cc.detail || cc2.detail);
});

// ---- P5: the run-2 hang. After B1m's ~60 transactions inside one evm snapshot and the evm_revert, group B2 stalled FOR 20 MINUTES inside the wait of its first transactions with no RPC in flight. ethers v5 never lets its block
//      number go down after a revert (provider.getBlockNumber() stayed above the chain's real head) and its poll loop skips pending-transaction checks while that clamped number does not change. The harness now (a) resets
//      ethers' caches after every evm_revert, (b) never uses provider.getBlockNumber() / ethers' wait(): it sends with eth_sendTransaction and polls eth_getTransactionReceipt itself, tracked and bounded.
//      The offline run did NOT hang with the old code either (the stall needs a particular poll timing the fork run produced); what P5 pins down is the part that IS reproducible: the stale block number, and that
//      the new send/wait path works across reverts, with the 1 s timestamp interval, nested snapshots and the tracer, and that every step announces itself.
await group("P5 transactions across evm_revert", async () => {
  const a = A("A11CE5"), b = A("B0B015"); await impersonate(a); await impersonate(b);
  await rpc("anvil_setBlockTimestampInterval", [1]);
  const send = async (n) => { const r = await tx(`p5 send ${n}`, (o) => signer(a).sendTransaction({ to: b, value: 1, ...o })); await touched(r.transactionHash); return r; };
  const within = async (label, p, ms = 15000) => { let t; const to = new Promise((_, rej) => { t = setTimeout(() => rej(new Error(`HANG: ${label} did not finish in ${ms / 1000} s`)), ms); }); try { return await Promise.race([p, to]); } finally { clearTimeout(t); } };
  for (let i = 0; i < 3; i++) await send("pre" + i);
  let staleSeen = 0;
  await scenario("p5 outer", async () => {
    for (let i = 0; i < 60; i++) { await send(i); if (i === 30) await scenario("p5 inner", async () => { for (let k = 0; k < 10; k++) await send("in" + k); }); }
    staleSeen = await provider.getBlockNumber();   // ethers' own view while the chain is at its highest
  });
  const real = await blockNumber(), ethersView = await provider.getBlockNumber();
  check("P5.1", staleSeen > real && ethersView === real && real === parseInt(await rpc("eth_blockNumber"), 16), `after the revert the chain is at block ${real} (it was ${staleSeen} inside the snapshot); blockNumber() = the real head, and ethers' own getBlockNumber() (${ethersView}) is back in line because the caches are reset after every evm_revert`);
  let okAll = true; const seen = [];
  for (let i = 0; i < 4; i++) { try { const r = await within(`post-revert tx ${i}`, send("post" + i)); seen.push(r.blockNumber); } catch (e) { okAll = false; seen.push(e.message); } }
  check("P5.2", okAll && seen.every((x, i) => i === 0 || x === seen[i - 1] + 1) && seen[0] === real + 1, `the first four transactions after the revert are mined and returned within seconds (blocks ${seen.join(", ")}; the chain was at ${real})`, seen.join(" | "));
  const r2 = await within("a transaction with logs and a receipt", send("logs")); 
  check("P5.3", r2.status === 1 && r2.confirmations === 1 && Array.isArray(r2.logs) && r2.gasUsed.gt(0) && r2.transactionHash.length === 66 && /mined 0x/.test(where.step), `the receipt the harness builds itself has status, confirmations, logs, gasUsed, transactionHash; the current step reads "${where.step}"`);
  progress("P5 a progress line"); check("P5.4", where.step === "P5 a progress line", "progress() sets the step the heartbeat reports");
});

// ---- P6: RUN 3 ROOT CAUSE, reproduced with the REAL v3 wrapper. A transaction whose outcome depends on a nested read whose failure is TOLERATED (the wrapper prices the share 0 when the vault read fails; the controller then RETURNS
//      PRICE_ERROR with status 1) is estimated at the lowest non-reverting gas, which starves the vault read: the simulation (eth_call, huge gas) says 0, the mined transaction returns 13. Also: a mined transaction that
//      carries a Failure(error, info, detail) event is detected by tx() (TXCODE line, throws) instead of being silently accepted.
await group("P6 estimateGas starvation and Failure-code detection", async () => {
  const wa = path.join(process.env.BP_OUT || "/nonexistent", "PharaohDlmmShareOracle.sol", "PharaohDlmmShareOracle.json");
  if (!fs.existsSync(wa)) { note("P6.0", `no wrapper artifact at ${wa}: P6 skipped`); return; }
  const j = JSON.parse(fs.readFileSync(wa, "utf8"));
  const asset = await deploy("FxAsset", dep), base = await deploy("FxBase", dep), vault = await deploy("FxVault", dep, [asset.address]), market = await deploy("FxMarket", dep, [vault.address]);
  const wc = await new ethers.ContractFactory(j.abi, j.bytecode.object, signer(dep)).deploy(base.address, market.address); await wc.deployed();
  const ctl = await deploy("FxCtl", dep, [wc.address]), sig = signer(dep);
  await tx("expensive vault read", (o) => vault.connect(sig).setMode(1_000_000, 7, o));
  const stat = await ctl.callStatic.setIfPriced(market.address);
  const data = ctl.interface.encodeFunctionData("setIfPriced", [market.address]);
  const est = BN(await rpc("eth_estimateGas", [{ from: dep, to: ctl.address, data }])), old = est.mul(150).div(100);
  // (1) the OLD behaviour: gas = 1.5 x the estimate (what the harness did through run 3)
  const rcOld = await (await sig.sendTransaction({ to: ctl.address, data, gasLimit: old })).wait();
  const f0 = failuresOf(rcOld), storedOld = await ctl.stored();
  check("P6.1", stat.eq(0) && storedOld.eq(0) && f0.length === 1 && f0[0].error === 13 && rcOld.status === 1,
    `REPRODUCED: the simulation returns ${stat} (priced), eth_estimateGas says ${est} gas, the tx mined with 1.5 x that (${old}) has status ${rcOld.status}, emitted Failure(error ${f0[0]?.error}) and stored ${storedOld}: the vault read was starved of gas, the real v3 wrapper priced the share 0 and the controller RETURNED PRICE_ERROR (gas used ${rcOld.gasUsed})`);
  // (2) the harness now: tx() with the new headroom
  await tx("setIfPriced with the harness's gas", (o) => ctl.connect(sig).setIfPriced(market.address, o));
  const storedNew = await ctl.stored();
  check("P6.2", storedNew.gt(0) && results.gas["setIfPriced with the harness's gas"] > est.toNumber(), `with max(1.5 x estimate, estimate + 2,000,000) the same call stores the price (${storedNew}) and uses ${results.gas["setIfPriced with the harness's gas"]} gas (> the estimate ${est})`);
  // (3) a Failure code is a FAILURE of the step
  let msg = "", allowed = null;
  try { await tx("starved on purpose", (o) => ctl.connect(sig).setIfPriced(market.address, { ...o, gasLimit: old })); } catch (e) { msg = e.message; }
  try { allowed = await tx("starved, allowed", (o) => ctl.connect(sig).setIfPriced(market.address, { ...o, gasLimit: old }), { allowFailure: true }); } catch (e) { allowed = null; }
  check("P6.3", /RETURNED error code PRICE_ERROR \(13\)/.test(msg) && !!allowed && failuresOf(allowed).length === 1 && results.data.txCodes?.length >= 2, `tx() throws on a mined Failure event ("${msg.slice(0, 120)}...") and records it in results.data.txCodes; opts.allowFailure returns the receipt`);
});

await group("P2 results writer", async () => {
  check("P2.1", results.checks.length >= 15 && results.notes >= 1 && results.fail === 0, `results object: ${results.pass} pass, ${results.fail} fail, ${results.notes} note`);
  const cp = JSON.parse(fs.readFileSync(path.join(OUTDIR, "results.json"), "utf8"));
  check("P2.3", cp.partial === true && /^P1/.test(cp.lastGroup) === false && cp.checks.length >= 15, `checkpoint(): results.json already exists mid-run after each group (partial: ${cp.partial}, last finished group "${cp.lastGroup}", ${cp.checks.length} checks so far): a killed run keeps its finished groups`);
  // a deliberate failure must be counted, written and make the process exit 1 -- the shell wrapper checks that by running with REH_SELFTEST_FAIL=1
  if (process.env.REH_SELFTEST_FAIL === "1") check("P2.2", false, "deliberate failure (REH_SELFTEST_FAIL=1)", "expected by the self-test");
});
finish();

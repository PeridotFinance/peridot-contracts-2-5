// SELF-TEST of the harness plumbing against a LOCAL anvil WITHOUT a fork (chain id 43114, fixtures from Fixtures.sol): results writer, 50 % gas headroom, failure tracing with custom-error
// decoding, impersonation, balance forcing (slot 0 and slot 9 layouts), mock feeds + re-pin after a warp, snapshots, prestate tracer, timestamp control. It tests NO product logic.
// Started by selftest.sh (REH_SELFTEST=1 REH_FIXTURE_OUT=<dir with Fixtures.sol/*.json>).
import fs from "node:fs";
import path from "node:path";
import { ethers, utils, BN, A, C, check, note, group, finish, results, provider, rpc, impersonate, setErc20Balance, tx, expectRevert, codeOrRevert, addErrorAbi, decodeErr,
  etchFeed, setFeed, repin, warp, headTs, readFeed, scenario, touched, mocks, signer, setNextTimestamp, mine, LIVE, OUTDIR } from "../lib.mjs";

const FX = process.env.REH_FIXTURE_OUT;
const art = (n) => JSON.parse(fs.readFileSync(path.join(FX, "Fixtures.sol", `${n}.json`), "utf8"));
async function deploy(name, from) {
  const a = art(name); const f = new ethers.ContractFactory(a.abi, a.bytecode.object, signer(from));
  const c = await f.deploy(); await c.deployed(); return new ethers.Contract(c.address, a.abi, provider);
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

await group("P2 results writer", async () => {
  check("P2.1", results.checks.length >= 14 && results.notes === 1 && results.fail === 0, `results object: ${results.pass} pass, ${results.fail} fail, ${results.notes} note`);
  // a deliberate failure must be counted, written and make the process exit 1 -- the shell wrapper checks that by running with REH_SELFTEST_FAIL=1
  if (process.env.REH_SELFTEST_FAIL === "1") check("P2.2", false, "deliberate failure (REH_SELFTEST_FAIL=1)", "expected by the self-test");
});
finish();

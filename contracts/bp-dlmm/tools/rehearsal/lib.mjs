// Shared plumbing of the bpPHAR-USDC fork rehearsal (and of its offline self-test): provider with 50 % gas headroom, results writer (PASS / FAIL / NOTE), failure tracing
// (debug_traceTransaction callTracer + custom-error decoding), impersonation, ERC-20 balance forcing, mock Chainlink feeds with re-pinning, time control, snapshots.
// ethers v5 is taken from REH_ETHERS_DIR (a directory that has node_modules/ethers v5, found by rehearsal.sh). Everything talks to the LOCAL endpoint REH_RPC only.
import { createRequire } from "node:module";
import fs from "node:fs";
import path from "node:path";
import util from "node:util";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

export const HERE = path.dirname(fileURLToPath(import.meta.url));
const ETHERS_DIR = process.env.REH_ETHERS_DIR;
if (!ETHERS_DIR) { console.error("REH_ETHERS_DIR is required (a directory with node_modules/ethers v5)"); process.exit(2); }
const req = createRequire(path.join(ETHERS_DIR, "package.json"));
export const { ethers } = req("ethers");
export const { BigNumber, utils, providers, Wallet } = ethers;

// ---------------------------------------------------------------------------------------------------------------- run-2 hardening (the run-1 harness went silent after the oracle swap and nobody could tell where)
// 1. every console line is ALSO appended, redacted, to REH_LOGFILE by THIS process (synchronously): the log no longer depends on a sed | tee pipeline that buffers or can stall.
// 2. every RPC call and every child process is TRACKED (label, start time) and has a TIMEOUT: a call that never answers becomes an error naming the call, not a hang.
// 3. a HEARTBEAT line every 60 s names the current group, the last check id and every call in flight; a per-group WATCHDOG fails the group (and ends the run, results saved) with the calls in flight.
const LOGFILE = process.env.REH_LOGFILE;
const redactUrl = (x) => String(x).replace(/https?:\/\/[^\s"')]+/g, "<url-redacted>");
for (const k of ["log", "error"]) {
  const orig = console[k].bind(console);
  console[k] = (...a) => { if (LOGFILE) { try { fs.appendFileSync(LOGFILE, redactUrl(util.format(...a)) + "\n"); } catch { /* the log file is a convenience: never end the run for it */ } } orig(...a); };
}
export const flight = new Map(); let flightId = 0;
export const where = { group: "", id: "", idAt: Date.now() };
/** race a promise against a timeout; the label (what is being waited for) is printed when the timeout fires and kept in the in-flight table meanwhile */
export function track(label, promise, ms) {
  const id = ++flightId; flight.set(id, { label, t: Date.now() }); let timer;
  const to = new Promise((_, rej) => { timer = setTimeout(() => { console.log(`TIMEOUT after ${Math.round(ms / 1000)} s waiting for: ${label}`); rej(Object.assign(new Error(`timeout after ${Math.round(ms / 1000)} s: ${label}`), { code: "REH_TIMEOUT" })); }, ms); });
  return Promise.race([promise, to]).finally(() => { clearTimeout(timer); flight.delete(id); });
}
/** run a child process ASYNCHRONOUSLY (the event loop, the heartbeat and the watchdogs stay alive) with stdin CLOSED, a timeout and the in-flight label. Returns { code, out } (stdout + stderr, urls redacted). */
export function runProc(cmd, args, { env = {}, cwd, timeoutMs = 25 * 60 * 1000, label = "" } = {}) {
  return new Promise((resolve) => {
    const lab = `process ${label || `${cmd} ${args.slice(0, 3).join(" ")}`}`;
    const id = ++flightId; flight.set(id, { label: lab, t: Date.now() });
    let out = "", done = false, killed = false;
    const child = spawn(cmd, args, { cwd, env, stdio: ["ignore", "pipe", "pipe"] });   // stdin is /dev/null: a tool that waits for input gets EOF instead of hanging
    const add = (d) => { if (out.length < 64 * 1024 * 1024) out += d.toString(); };
    child.stdout.on("data", add); child.stderr.on("data", add);
    const timer = setTimeout(() => { killed = true; console.log(`TIMEOUT after ${Math.round(timeoutMs / 1000)} s waiting for: ${lab} (killing it)`); child.kill("SIGKILL"); }, timeoutMs);
    const fin = (code) => { if (done) return; done = true; clearTimeout(timer); flight.delete(id); resolve({ code: killed ? 124 : code, out: redactUrl(out) + (killed ? `\n[killed after ${Math.round(timeoutMs / 1000)} s]` : "") }); };
    child.on("error", (e) => { out += `spawn error: ${e.message}\n`; fin(127); });
    child.on("exit", (code) => { setTimeout(() => fin(code), 2000).unref(); });   // 'close' can wait forever for a grandchild that kept the pipe open: after the exit, give the pipes 2 s, then go on
    child.on("close", (code) => fin(code));
  });
}
const heartbeat = setInterval(() => {
  const now_ = Date.now(), fl = [...flight.values()].map((f) => `${f.label} (${Math.round((now_ - f.t) / 1000)} s)`).join(" | ") || "none";
  console.log(`HEARTBEAT ${new Date().toISOString().slice(11, 19)} group="${where.group}" last check ${where.id || "-"} (${Math.round((now_ - where.idAt) / 1000)} s ago) in flight: ${fl}`);
}, Number(process.env.REH_HEARTBEAT_MS) || 60_000); heartbeat.unref();
export const BN = (x) => BigNumber.from(x);
export const RPC = process.env.REH_RPC;
const OUTJSON = process.env.REH_RESULTS || path.join(process.env.REH_SCRATCH || ".", "results.json");
export const OUTDIR = path.dirname(OUTJSON);
export const CHAIN_ID = Number(process.env.REH_CHAIN_ID || 43114);

export const LIVE = Object.fromEntries(
  fs.readFileSync(path.join(HERE, "live-addresses.env"), "utf8").split("\n").filter((l) => l.startsWith("export ")).map((l) => l.slice(7).split("=")),
);
for (const [k, v] of Object.entries(LIVE)) LIVE[k] = utils.getAddress(v); // throws on a bad checksum

export const provider = new providers.StaticJsonRpcProvider(RPC, { chainId: CHAIN_ID, name: "avalanche" });
provider.pollingInterval = 100;
// 50 % headroom over eth_estimateGas on EVERY harness transaction (lesson of the range-tp run 5). ethers' JsonRpcSigner calls provider.estimateGas when no gasLimit is given.
const estimateGas0 = provider.estimateGas.bind(provider);
provider.estimateGas = async (txr) => { const g = await estimateGas0(txr); const m = g.mul(150).div(100); return m.gt(14_000_000) ? BN(14_000_000) : m; };
const send0 = provider.send.bind(provider);   // every JSON-RPC call (ours and ethers' own) goes through here: tracked, with a timeout (tracers get longer)
const RPC_TIMEOUT = Number(process.env.REH_RPC_TIMEOUT_MS) || 180_000;
provider.send = (method, params) => track(`rpc ${method} ${JSON.stringify(params ?? []).slice(0, 90)}`, send0(method, params), /^debug_/.test(method) ? Math.max(RPC_TIMEOUT, 600_000) : RPC_TIMEOUT);
export const rpc = (m, p = []) => provider.send(m, p);
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const now = () => new Date().toISOString().slice(11, 19);
export const log = (...a) => console.log(`[${now()}]`, ...a);

// ---------------------------------------------------------------------------------------------------------------- results: PASS / FAIL / NOTE
export const results = { startedAt: new Date().toISOString(), pin: process.env.REH_PIN, pass: 0, fail: 0, notes: 0, checks: [], gas: {}, data: {} };
export function check(id, ok, text, detail = "") {
  where.id = id; where.idAt = Date.now();
  results.checks.push({ id, ok: !!ok, text, detail: ok ? "" : String(detail).slice(0, 600) });
  if (ok) { results.pass++; console.log(`PASS ${id} ${text}`); } else { results.fail++; console.log(`FAIL ${id} ${text}${detail ? ` :: ${String(detail).slice(0, 600)}` : ""}`); }
  return !!ok;
}
/** an observation that is recorded but is neither a PASS nor a FAIL (a decision input for the integrator) */
export function note(id, text) { where.id = id; where.idAt = Date.now(); results.notes++; results.checks.push({ id, ok: null, text, detail: "" }); console.log(`NOTE ${id} ${text}`); }
export async function group(name, fn, opts = {}) {
  log(`>>> GROUP ${name}`); where.group = name;
  const ms = opts.timeoutMs ?? (Number(process.env.REH_GROUP_TIMEOUT_MS) || 20 * 60 * 1000);
  let timer, expired = false;
  const watchdog = new Promise((res) => { timer = setTimeout(() => { expired = true; res(); }, ms); });
  try { await Promise.race([fn(), watchdog]); }
  catch (e) { check(`${name.split(" ")[0]}.exception`, false, `group ${name} aborted by an exception`, e?.message || e?.reason || e); await traceFailure(e); }
  finally { clearTimeout(timer); }
  if (expired) {   // the group is still running somewhere: the chain state is unknown, so the run ENDS here (results so far are saved), it does not carry on into the next group
    const fl = [...flight.values()].map((f) => `${f.label} (${Math.round((Date.now() - f.t) / 1000)} s)`).join(" | ") || "none";
    check(`${name.split(" ")[0]}.watchdog`, false, `group ${name} exceeded ${Math.round(ms / 1000)} s and was stopped by the watchdog; last check ${where.id}; calls in flight: ${fl}`, fl);
    finish({ aborted: `watchdog in ${name}` });
  }
  checkpoint(name);
}
/** write the results so far (run 2 is long: a killed run must still leave the finished groups on disk). finish() overwrites it. */
export function checkpoint(afterGroup = "") {
  try { fs.writeFileSync(OUTJSON, JSON.stringify({ ...results, partial: true, lastGroup: afterGroup, checkpointAt: new Date().toISOString() }, bnReplacer, 1)); } catch { /* the output directory is the user's: a write error must not end the run */ }
}
export function finish(extra = {}) {
  results.finishedAt = new Date().toISOString();
  Object.assign(results, extra);
  fs.writeFileSync(OUTJSON, JSON.stringify(results, bnReplacer, 1));
  console.log(`RESULTS pass=${results.pass} fail=${results.fail} notes=${results.notes} (${OUTJSON})`);
  console.log(results.fail === 0 ? "REHEARSAL PASSED" : "REHEARSAL FAILED");
  process.exit(results.fail === 0 ? 0 : 1);
}
const bnReplacer = (k, v) => (v && v.type === "BigNumber" && v.hex ? BN(v.hex).toString() : v);

// ---------------------------------------------------------------------------------------------------------------- error decoding and failure tracing
const ERR_IFACES = [];
/** register ABIs (human-readable or JSON) whose custom errors the decoder should know */
export function addErrorAbi(abi) { try { ERR_IFACES.push(new utils.Interface(abi)); } catch (e) { console.log(`addErrorAbi skipped: ${String(e.message).slice(0, 120)}`); } }
export function decodeData(data) {
  if (typeof data !== "string" || !data.startsWith("0x") || data.length < 10) return null;
  if (data.startsWith("0x08c379a0")) { try { return `Error("${utils.defaultAbiCoder.decode(["string"], "0x" + data.slice(10))[0]}")`; } catch { /* fall through */ } }
  if (data.startsWith("0x4e487b71")) { try { return `Panic(${utils.defaultAbiCoder.decode(["uint256"], "0x" + data.slice(10))[0].toHexString()})`; } catch { /* fall through */ } }
  for (const i of ERR_IFACES) { try { const d = i.parseError(data); return `${d.name}(${d.args.map(String).join(",")})`; } catch { /* next */ } }
  return `raw ${data.slice(0, 74)}`;
}
export function decodeErr(e) {
  const data = e?.error?.data || e?.data || e?.error?.error?.data || e?.error?.body && (String(e.error.body).match(/"data":"(0x[0-9a-fA-F]+)"/) || [])[1] || (String(e?.message || "").match(/0x[0-9a-fA-F]{8,}/) || [])[0];
  const d = typeof data === "object" && data?.data ? data.data : data;
  const dec = decodeData(d);
  if (dec) return dec;
  return String(e?.reason || e?.message || e).replace(/https?:\/\/[^\s"]+/g, "<url>").slice(0, 240);
}
/** replay a mined, failed transaction with the call tracer and print every reverting frame (deepest last). Returns the decoded deepest revert (string) or "". */
export async function traceFailure(e) {
  try {
    const h = typeof e === "string" ? e : e?.transactionHash || e?.receipt?.transactionHash;
    if (!h) { console.log(`TRACE (no transaction hash on the error: ${String(e?.code || "")})`); return ""; }
    const t = await rpc("debug_traceTransaction", [h, { tracer: "callTracer" }]);
    const frames = [];
    const walk = (f, d) => { if (f.error || f.revertReason) frames.push({ d, f }); for (const c of f.calls || []) walk(c, d + 1); };
    walk(t, 0);
    console.log(`TRACE tx ${h} gasUsed ${t.gasUsed}: ${frames.length} reverting frame(s)`);
    let deepest = "";
    for (const { d, f } of frames.slice(-6)) {
      const out = f.output && f.output !== "0x" ? decodeData(f.output) || `raw ${String(f.output).slice(0, 74)}` : "(empty)";
      deepest = out;
      console.log(`TRACE  depth ${d} ${f.type} to ${f.to} sel ${String(f.input).slice(0, 10)} error "${f.error || ""}" ${f.revertReason ? `reason "${f.revertReason}" ` : ""}output ${out}`.slice(0, 420));
    }
    return deepest;
  } catch (x) { console.log(`TRACE failed: ${String(x?.message || x).slice(0, 200)}`); return ""; }
}
/** run a read / callStatic that is EXPECTED to revert: returns the decoded revert, or null when it did not revert */
export async function expectRevert(fn) { try { await fn(); return null; } catch (e) { return decodeErr(e); } }
/** run a call that either returns a Compound-style error code (uint), reverts with a controller-rejection error (code inside) or reverts otherwise: { code } | { code, revert } | { revert } */
export async function codeOrRevert(fn) {
  try { const r = await fn(); return { code: BN(r).toNumber() }; }
  catch (e) { // the pToken user functions REVERT with XxxPeridottrollerRejection(code) instead of returning the code: both shapes yield { code }
    const d = decodeErr(e); const m = /Rejection\((\d+)\)/.exec(d);
    return m ? { code: Number(m[1]), revert: d } : { revert: d };
  }
}

/**
 * Send ONE transaction through `fn(overrides)` (which must return the ethers tx response), wait, and on any failure print the revert chain. When estimateGas itself fails
 * (no transaction exists to trace) the call is replayed once with a fixed gas limit so that a mined, failed transaction can be traced. Throws on failure.
 */
export async function tx(label, fn) {
  let resp;
  try { resp = await fn({}); }
  catch (e) {
    if (e?.code === "UNPREDICTABLE_GAS_LIMIT" || /cannot estimate gas|estimateGas|execution reverted/i.test(String(e?.message))) {
      console.log(`TXFAIL ${label}: estimateGas failed (${decodeErr(e)}); replaying with a fixed gas limit to trace it`);
      try { resp = await fn({ gasLimit: 6_000_000 }); } catch (e2) { throw Object.assign(new Error(`${label}: ${decodeErr(e2)}`), { cause: e2 }); }
    } else throw Object.assign(new Error(`${label}: ${decodeErr(e)}`), { cause: e });
  }
  try {
    const r = await resp.wait();
    results.gas[label] = r.gasUsed.toNumber();
    return r;
  } catch (e) {
    const deepest = await traceFailure(e);
    throw Object.assign(new Error(`${label} reverted: ${deepest || decodeErr(e)}`), { cause: e, transactionHash: e?.transactionHash });
  }
}

// ---------------------------------------------------------------------------------------------------------------- chain helpers
export const A = (tag) => utils.getAddress(utils.hexZeroPad("0x" + tag, 20)); // a valid checksummed address from a short hex tag
export const signer = (addr) => provider.getSigner(addr);
export const C = (addr, abi, who) => new ethers.Contract(addr, abi, who ? signer(who) : provider);
export async function impersonate(addr, eth = "0x56BC75E2D63100000") { await rpc("anvil_impersonateAccount", [addr]); await rpc("anvil_setBalance", [addr, eth]); return signer(addr); }
export async function setStorage(addr, slot, value) { await rpc("anvil_setStorageAt", [addr, slot, utils.hexZeroPad(BN(value).toHexString(), 32)]); }
const slotCache = {};
/** force an ERC-20 balance by writing the balances mapping (tries slots 0..79, verifies by balanceOf, restores a wrong guess). Works for OZ layouts and for FiatToken's slot 9. */
export async function setErc20Balance(token, who, amount) {
  const t = C(token, ["function balanceOf(address) view returns (uint256)"]), val = BN(amount);
  const order = slotCache[token] !== undefined ? [slotCache[token]] : Array.from({ length: 80 }, (_, i) => i);
  for (const i of order) {
    const slot = utils.keccak256(utils.defaultAbiCoder.encode(["address", "uint256"], [who, i]));
    const prev = await provider.getStorageAt(token, slot);
    await setStorage(token, slot, val);
    if ((await t.balanceOf(who)).eq(val)) { slotCache[token] = i; return i; }
    await rpc("anvil_setStorageAt", [token, slot, prev]);
  }
  throw new Error(`could not find the balance slot of ${token}`);
}
export async function headTs() { return (await provider.getBlock("latest")).timestamp; }
export async function mine(n = 1) { for (let i = 0; i < n; i++) await rpc("evm_mine", []); }

// ---- time. Instant mining: a block per transaction, timestamps from the wall clock unless pinned. `warp` moves time and re-pins every mock feed so the feeds that must stay fresh are fresh.
/** move time forward WITHOUT re-pinning (feeds age). evm_increaseTime is ignored while a block-timestamp interval is set, so the next block's timestamp is set explicitly. */
export async function warpRaw(seconds) {
  const t = (await headTs()) + Number(seconds);
  await rpc("evm_setNextBlockTimestamp", [t]);
  await mine(1);
  if ((await headTs()) < t) throw new Error(`warp did not reach ${t}`);
}
export async function warp(seconds) {
  await warpRaw(seconds);
  await repin();
}
/** move the head block to EXACTLY timestamp `ts` (>= head + 1) and re-pin every mock feed that is not deliberately stale. eth_call / callStatic then see block.timestamp == ts (probed on anvil 1.7.1). */
export async function warpTo(ts) {
  const head = await headTs();
  if (Number(ts) <= head) throw new Error(`warpTo(${ts}): the head is already at ${head}`);
  await rpc("evm_setNextBlockTimestamp", [Number(ts)]);
  await mine(1);
  if ((await headTs()) !== Number(ts)) throw new Error(`warpTo did not land on ${ts} (head ${await headTs()})`);
  await repin();
}
export async function setNextTimestamp(ts) { await rpc("evm_setNextBlockTimestamp", [Number(ts)]); }

// ---- mock Chainlink feeds: MockFeed runtime code is placed at the real feed address (anvil_setCode), answer in slot 0, updatedAt in slot 1. 8 decimals. NOT real feed behaviour.
const FEED_ABI = ["function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)", "function decimals() view returns (uint8)"];
export const mocks = {}; // lower-case address -> { answer: BigNumber, updatedAt: number|null } ; updatedAt null = follow the head block
const MOCK = JSON.parse(fs.readFileSync(path.join(HERE, "MockFeed.json"), "utf8"));
export async function readFeed(addr) {
  const r = await C(addr, FEED_ABI).latestRoundData(); const ts = await headTs();
  return { roundId: r[0], answer: r[1], updatedAt: r[3], age: ts - r[3].toNumber(), answeredInRound: r[4] };
}
export async function etchFeed(addr, answer) {
  const real = await readFeed(addr);
  await rpc("anvil_setCode", [addr, "0x" + MOCK.deployedBytecode.replace(/^0x/, "")]);
  await setFeed(addr, answer ?? real.answer);
  return real;
}
export async function setFeed(addr, answer, updatedAt) {
  const key = addr.toLowerCase(); const a = BN(answer);
  mocks[key] = { answer: a, updatedAt: updatedAt ?? null };
  const ts = updatedAt ?? (await headTs());
  await setStorage(addr, "0x0", a.lt(0) ? BN(2).pow(256).add(a) : a); await setStorage(addr, "0x1", ts);
}
/** re-write updatedAt = head block timestamp for every mock that is not deliberately stale (call after any time movement or revert) */
export async function repin() {
  const ts = await headTs();
  for (const [addr, m] of Object.entries(mocks)) if (m.updatedAt === null) await setStorage(addr, "0x1", ts);
}

// ---- snapshots. A scenario starts from the current state and returns to it; time and feeds are re-pinned after the revert.
export async function scenario(name, fn) {
  const id = await rpc("evm_snapshot", []);
  log(`--- scenario ${name} (snapshot ${id})`);
  const saved = JSON.stringify(mocks, (k, v) => (v && v.type === "BigNumber" ? BN(v.hex).toString() : v));
  try { await fn(); }
  finally {
    const ok = await rpc("evm_revert", [id]);
    if (!ok) console.log(`WARN evm_revert of ${name} returned false`);
    for (const k of Object.keys(mocks)) delete mocks[k];
    for (const [k, v] of Object.entries(JSON.parse(saved))) mocks[k] = { answer: BN(v.answer), updatedAt: v.updatedAt };
    await mine(1); await repin();
    log(`--- scenario ${name} reverted`);
  }
}

// ---- which contracts did a transaction touch (state diff through the prestate tracer; falls back to the call tracer). Used for "which contracts in the account's path were touched".
export async function touched(txHash) {
  try {
    const t = await rpc("debug_traceTransaction", [txHash, { tracer: "prestateTracer", tracerConfig: { diffMode: true } }]);
    const post = Object.keys(t.post || {}), pre = Object.keys(t.pre || {});
    return { mode: "state-diff", addresses: [...new Set([...post, ...pre])].map((a) => utils.getAddress(a)) };
  } catch { /* fall back */ }
  try {
    const t = await rpc("debug_traceTransaction", [txHash, { tracer: "callTracer" }]);
    const s = new Set(); const walk = (f) => { if (f.to) s.add(utils.getAddress(f.to)); for (const c of f.calls || []) walk(c); }; walk(t);
    return { mode: "call-targets", addresses: [...s] };
  } catch (e) { return { mode: "unavailable", addresses: [], error: String(e?.message || e).slice(0, 120) }; }
}

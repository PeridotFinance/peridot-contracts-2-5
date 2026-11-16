// FORK REHEARSAL of ONE FULL EPOCH of the PHAR distribution (design A) on a LOCAL anvil fork of Avalanche mainnet. Started by rehearsal.sh (which holds the shared fork lock, starts the
// proxy and anvil, runs the argv check and removes everything on exit). Nothing real: the Ledger (the Safe's only owner), the deployer, a second depositor and a stranger are
// impersonated on the fork; every transaction goes to the LOCAL endpoint REH_RPC; the real endpoint is never in this process's environment.
//
// Output: `PASS <id> <text>` / `FAIL <id> <text>` lines, `INFO` lines, a final `RESULTS {json}` line and ONE verdict line:
//   `REHEARSAL PASSED: N checks, 0 failures`   (exit 0)      `REHEARSAL FAILED: N checks, M failures: <ids>` (exit 1)      `FATAL ...` (exit 2)      `NO PHAR ACCRUED ...` (exit 43)
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const PROJ = process.env.REH_PROJ; // contracts/vault-dlmm
const SCRATCH = process.env.REH_SCRATCH;
const RPC = process.env.REH_RPC; // http://127.0.0.1:<port> (the LOCAL anvil)
const OUTJSON = process.env.REH_RESULTS || path.join(SCRATCH, "results.json");
const INT_TOOLS = process.env.REH_INT_TOOLS;
const SCAN_FROM = process.env.REH_SCAN_FROM;
const WARP = Number(process.env.REH_WARP_SECONDS || 86400);
const CHUNK = process.env.REH_CHUNK || "100";
const SLEEP_MS = process.env.REH_SLEEP_MS || "0";
const EPOCH_OUT = process.env.REH_EPOCH_OUT;
if (!PROJ || !SCRATCH || !RPC || !INT_TOOLS || !SCAN_FROM) { console.log("FATAL: rehearsal.mjs is started by rehearsal.sh (missing environment)"); process.exit(2); }
const req = createRequire(path.join(PROJ, "package.json"));
const { ethers } = req(process.env.ETHERS_DIR || "ethers");
const { BigNumber, utils, providers, Wallet } = ethers;
const BN = (x) => BigNumber.from(x);

const A = {
  SAFE: "0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12",
  LEDGER: "0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD",
  VAULT: "0x278B1b625C74B1926C5F989ddE601f3C5Ba27f7D",
  PHAR: "0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7",
  REWARDER: "0x32E68C4b8Edc6d1F16E99EbA826B292FDC18daDC",
  DEAD: "0x000000000000000000000000000000000000dEaD",
};
const FIRST_START_BLOCK = 100488395;
const CLAIM_DELAY = 86400, CLAIM_DEADLINE = 15552000;
const ZERO32 = "0x" + "00".repeat(32);
const provider = new providers.StaticJsonRpcProvider(RPC, { chainId: 43114, name: "avalanche" });
provider.pollingInterval = 100;
const rpc = (m, p = []) => provider.send(m, p);

// ---------------------------------------------------------------------------------------------------------------- ABIs
const VAULT_ABI = [
  "function owner() view returns (address)", "function rewardToken() view returns (address)", "function rewarder() view returns (address)", "function balanceOf(address) view returns (uint256)",
  "function totalSupply() view returns (uint256)", "function transfer(address,uint256) returns (bool)", "function bandState() view returns (uint24,uint24,uint24,bool,bool)", "function decimals() view returns (uint8)",
  "event PharHarvested(address indexed token,uint256 amount,uint256 totalSupplyShares,uint256 totalAssets)", "event Transfer(address indexed from,address indexed to,uint256 value)",
];
const ERC20_ABI = ["function balanceOf(address) view returns (uint256)", "function allowance(address,address) view returns (uint256)", "function decimals() view returns (uint8)"];
const REWARDER_ABI = ["function getPendingRewards(address,uint256[]) view returns (uint256)"];
const DIST_ABI = [
  "function owner() view returns (address)", "function pendingOwner() view returns (address)", "function PHAR() view returns (address)", "function CLAIM_DELAY() view returns (uint256)", "function CLAIM_DEADLINE() view returns (uint256)",
  "function epochCount() view returns (uint256)",
  "function epochInfo(uint256) view returns (tuple(bytes32 root,uint256 total,uint256 claimed,uint256 publishedAt,uint256 claimOpensAt,uint256 claimDeadline,uint256 fromBlock,uint256 toBlock,bytes32 dataHash,uint8 status))",
  "function isClaimed(uint256,address) view returns (bool)", "function isClaimWindowOpen(uint256) view returns (bool)", "function verifyLeaf(uint256,address,uint256,bytes32[]) view returns (bool)",
  "function claim(uint256 epochId,address account,uint256 amount,bytes32[] proof)", "function cancelEpoch(uint256)", "function sweepUnclaimed(uint256)",
  "function publishEpoch(bytes32,uint256,uint64,uint64,bytes32)",
  "event EpochPublished(uint256 indexed epochId,bytes32 root,uint256 total,uint64 fromBlock,uint64 toBlock,bytes32 dataHash,uint256 publishedAt,uint256 claimOpensAt,uint256 claimDeadline)",
  "event EpochCancelled(uint256 indexed epochId,address indexed to,uint256 refunded)", "event Claimed(uint256 indexed epochId,address indexed account,uint256 amount)", "event EpochSwept(uint256 indexed epochId,address indexed to,uint256 amount)",
  "error ZeroAddress()", "error NotAContract()", "error BadWindow()", "error ZeroRoot()", "error ZeroTotal()", "error ZeroDataHash()", "error BadBlockRange()", "error TotalTooLarge()",
  "error TransferAmountMismatch(uint256 expected,uint256 received)", "error NoSuchEpoch()", "error EpochNotOpen(uint8 status)", "error WindowOver()", "error ClaimsNotOpen(uint256 opensAt)",
  "error ClaimsClosed(uint256 deadline)", "error DeadlineNotReached(uint256 deadline)", "error AlreadyClaimed()", "error ZeroAmount()", "error InvalidProof()", "error ExceedsEpochTotal(uint256 claimedAfter,uint256 total)",
  "error RenounceDisabled()", "error OwnableUnauthorizedAccount(address account)", "error OwnableInvalidOwner(address owner)", "error ReentrancyGuardReentrantCall()",
];
const dIface = new utils.Interface(DIST_ABI);
const STATUS = { None: 0, Open: 1, Cancelled: 2, Swept: 3 };

// ---------------------------------------------------------------------------------------------------------------- reporting
const results = { checks: [], failures: [], info: {}, steps: [], gas: {} };
const now = () => new Date().toISOString().slice(11, 19);
const log = (...a) => console.log(`[${now()}]`, ...a);
const redact = (s) => String(s).replace(/https?:\/\/[^\s"')]+/g, "<url-redacted>");
function check(id, ok, text) {
  const line = `${ok ? "PASS" : "FAIL"} ${id} ${text}`;
  console.log(line);
  results.checks.push({ id, ok: !!ok, text });
  if (!ok) results.failures.push(`${id} ${text}`);
  return !!ok;
}
const info = (text) => console.log(`INFO ${text}`);
class Abort extends Error { constructor(code, msg) { super(msg); this.code = code; } }
async function step(name, fn) {
  const t0 = Date.now(); log(`>>> ${name}`);
  try { const r = await fn(); results.steps.push({ name, ms: Date.now() - t0, ok: true }); return r; }
  catch (e) { results.steps.push({ name, ms: Date.now() - t0, ok: false, error: redact(e?.message || e).slice(0, 300) }); throw e; }
}
function revertName(e) {
  const cands = [e?.data, e?.error?.data, e?.error?.error?.data, e?.error?.body, e?.body, e?.error?.message, e?.message];
  for (const c of cands) {
    const s = typeof c === "string" ? c : c && typeof c.data === "string" ? c.data : "";
    const m = s.match(/0x[0-9a-fA-F]{8,}/);
    if (m) {
      try { const d = dIface.parseError(m[0]); return `${d.name}(${d.args.map(String).join(",")})`; } catch { /* not ours */ }
      if (m[0].startsWith("0x08c379a0")) { try { return `Error("${utils.defaultAbiCoder.decode(["string"], "0x" + m[0].slice(10))[0]}")`; } catch { /* */ } }
    }
  }
  const m = JSON.stringify(e, Object.getOwnPropertyNames(e || {})).match(/\\?"data\\?":\\?"(0x[0-9a-fA-F]{8,})/);
  if (m) { try { const d = dIface.parseError(m[1]); return `${d.name}(${d.args.map(String).join(",")})`; } catch { /* */ } }
  return `unparsed: ${redact(e?.reason || e?.message || e).slice(0, 160)}`;
}
/** runs fn expecting a revert; returns the decoded error name or null when it did NOT revert */
async function revertsWith(fn) { try { await fn(); return null; } catch (e) { return revertName(e); } }

// ---------------------------------------------------------------------------------------------------------------- processes
const BASE_ENV = { PATH: process.env.PATH, HOME: process.env.HOME, ETHERS_DIR: process.env.ETHERS_DIR || "", ETH_RPC_URL: RPC, AVALANCHE_MAINNET_RPC_URL: RPC, RPC_LOCAL: RPC, FOUNDRY_DISABLE_NIGHTLY_WARNING: "1" };
const run = (cmd, args, env = {}, cwd = PROJ) => {
  const r = spawnSync(cmd, args, { encoding: "utf8", cwd, env: { ...BASE_ENV, ...env }, maxBuffer: 256 * 1024 * 1024, timeout: 60 * 60 * 1000 });
  return { code: r.status, out: redact((r.stdout || "") + (r.stderr || "")) };
};
const tail = (s, n = 400) => s.trim().split("\n").slice(-6).join(" | ").slice(-n);
const impersonate = async (addr, ethBalance = "0x56BC75E2D63100000") => { await rpc("anvil_impersonateAccount", [addr]); await rpc("anvil_setBalance", [addr, ethBalance]); return provider.getSigner(addr); };
const warp = async (secs) => { await rpc("evm_increaseTime", [secs]); await rpc("evm_mine", []); return (await provider.getBlock("latest")).timestamp; };
const sha256File = (f) => crypto.createHash("sha256").update(fs.readFileSync(f)).digest("hex");
const E = (x) => BN(x).toString();

async function main() {
  const t00 = Date.now();
  const vault = new ethers.Contract(A.VAULT, VAULT_ABI, provider);
  const phar = new ethers.Contract(A.PHAR, ERC20_ABI, provider);
  const rewarder = new ethers.Contract(A.REWARDER, REWARDER_ABI, provider);
  const SAFE = utils.getAddress(A.SAFE), LEDGER = utils.getAddress(A.LEDGER);

  // ------------------------------------------------------------------ S0 facts
  const facts = await step("S0 facts of the fork", async () => {
    const chainId = (await provider.getNetwork()).chainId;
    const blk = await provider.getBlock("latest");
    const [lo, up, , has] = await vault.bandState();
    const f = {
      chainId, block: blk.number, blockTs: blk.timestamp, owner: await vault.owner(), rewardToken: await vault.rewardToken(), rewarder: await vault.rewarder(), hasBand: has, band: [lo, up],
      ledgerShares: (await vault.balanceOf(LEDGER)).toString(), deadShares: (await vault.balanceOf(A.DEAD)).toString(), supply: (await vault.totalSupply()).toString(),
      safePhar: (await phar.balanceOf(SAFE)).toString(), scanFrom: Number(SCAN_FROM),
    };
    results.info.facts = f;
    log("   facts", JSON.stringify(f));
    return f;
  });
  check("P00", facts.chainId === 43114 && facts.block > FIRST_START_BLOCK, `anvil fork of chain 43114 at block ${facts.block} (> the first epoch start ${FIRST_START_BLOCK}); vault supply ${facts.supply} shares`);
  check("P01", facts.owner.toLowerCase() === SAFE.toLowerCase() && facts.rewardToken.toLowerCase() === A.PHAR.toLowerCase() && facts.rewarder.toLowerCase() === A.REWARDER.toLowerCase() && facts.hasBand,
    `the REAL vault: owner = the Safe, rewardToken = PHAR, rewarder = ${A.REWARDER}, has a band [${facts.band.join(",")}]`);
  if (!facts.hasBand) throw new Abort(2, "the live vault has no band: nothing accrues, the scenario cannot run");
  const ledgerShares = BN(facts.ledgerShares);
  check("P02", ledgerShares.gt(1000) && BN(facts.deadShares).gt(0), `the Ledger holds ${ledgerShares} shares, the dead seed ${facts.deadShares} shares`);
  if (ledgerShares.lte(1000)) throw new Abort(2, "the Ledger holds no shares on this fork: the scenario needs an EOA holder");

  // ------------------------------------------------------------------ S1 actors (fork only)
  const bobAddr = Wallet.createRandom().address, strangerAddr = Wallet.createRandom().address, deployerAddr = Wallet.createRandom().address;
  const ledger = await impersonate(LEDGER, "0x8AC7230489E80000");
  const stranger = await impersonate(strangerAddr), bob = await impersonate(bobAddr);
  await impersonate(deployerAddr, "0x56BC75E2D63100000"); // the throwaway deployer: a fresh keyless address, nonce 0, gas only
  const safeSigner = await impersonate(SAFE); // (the Safe's own address as a caller: used only for callStatic checks of owner-only reverts)
  log("   deployer (fresh, keyless, impersonated):", deployerAddr, " bob:", bobAddr, " stranger:", strangerAddr);

  // ------------------------------------------------------------------ S2 share movements (before the warp)
  const holder = await step("S2 shares: the Ledger sends 20 % to Bob (an EOA) and 10 % to a contract", async () => {
    const art = JSON.parse(fs.readFileSync(path.join(PROJ, "out/FixedFeed.sol/FixedFeed.json"), "utf8"));
    const c = await new ethers.ContractFactory(art.abi, art.bytecode.object, stranger).deploy(1, 1, false);
    await c.deployed();
    const toBob = ledgerShares.div(5), toContract = ledgerShares.div(10);
    const v = vault.connect(ledger);
    await (await v.transfer(bobAddr, toBob, { gasLimit: 300000 })).wait();
    await (await v.transfer(c.address, toContract, { gasLimit: 300000 })).wait();
    const h = { contract: c.address, toBob: toBob.toString(), toContract: toContract.toString(), code: (await provider.getCode(c.address)).length > 2, bobCode: (await provider.getCode(bobAddr)).length > 2 };
    results.info.holders = h;
    return h;
  });
  check("P03", holder.code && !holder.bobCode && (await vault.balanceOf(bobAddr)).toString() === holder.toBob && (await vault.balanceOf(holder.contract)).toString() === holder.toContract,
    `Bob (EOA ${bobAddr}) holds ${holder.toBob} shares and the contract ${holder.contract} holds ${holder.toContract} shares (both moved by the impersonated Ledger)`);

  // ------------------------------------------------------------------ S3 warp, S4 harvest through the Safe
  const t0 = (await provider.getBlock("latest")).timestamp;
  const t1 = await step(`S3 evm time warp ${WARP} s`, () => warp(WARP));
  check("P04", t1 - t0 >= WARP, `chain time advanced by ${t1 - t0} s (>= ${WARP}); the Chainlink feeds are now stale on this fork: harvestRewards does not read them (the event's totalAssets may be 0), no later step needs the oracle`);
  const ids = []; { const [lo, up] = await vault.bandState(); for (let i = Number(lo); i <= Number(up); i++) ids.push(i); }
  const pending = await rewarder.getPendingRewards(A.VAULT, ids);
  check("P05", pending.gt(0), `pending PHAR on the band ${ids[0]}..${ids[ids.length - 1]} = ${pending} wei after the warp`);
  if (pending.isZero()) throw new Abort(43, "pending PHAR is 0 after the warp");
  const safeBefore = await phar.balanceOf(SAFE);
  const pinBlock = facts.block;
  const harvest = await step("S4 harvestRewards through the Safe (tools/dlmm-harvest.sh send, SEND_MODE=unlocked: simulation first)", async () => {
    const r = run("bash", [path.join(INT_TOOLS, "dlmm-harvest.sh"), "send"], { VAULT: A.VAULT, SEND_MODE: "unlocked" });
    log("   " + r.out.split("\n").filter((l) => /BAND|DECODED|SIMULATION|ABOUT|SAFE PHAR|status/.test(l)).join("\n   "));
    if (r.code !== 0) throw new Error("dlmm-harvest.sh failed: " + tail(r.out));
    const evs = await vault.queryFilter(vault.filters.PharHarvested(), pinBlock, "latest");
    const ev = evs[evs.length - 1];
    if (!ev) throw new Error("no PharHarvested event after the harvest");
    return { tx: ev.transactionHash, block: ev.blockNumber, amount: ev.args.amount, count: evs.length };
  });
  const safeAfter = await phar.balanceOf(SAFE);
  check("P06", harvest.amount.gt(0) && safeAfter.sub(safeBefore).gte(harvest.amount),
    `harvest ${harvest.tx} at block ${harvest.block}: PharHarvested.amount ${harvest.amount} wei, the Safe's PHAR rose by ${safeAfter.sub(safeBefore)} (whole vault balance forwarded; pending was ${pending})`);
  if (harvest.amount.isZero()) throw new Abort(43, "PharHarvested.amount is 0");
  results.info.harvest = { tx: harvest.tx, block: harvest.block, amount: harvest.amount.toString() };

  // ------------------------------------------------------------------ S5 the generator against the LOCAL anvil, twice
  const gen = (cacheDir, outDir) => run("node", [path.join(PROJ, "tools/dlmm-rewards-root.mjs"), "--local-rpc", RPC, "--cache-dir", cacheDir, "--out-dir", outDir, "--epoch-id", "0", "--scan-from", SCAN_FROM,
    "--first-epoch", "--to-harvest", harvest.tx, "--chunk", CHUNK, "--sleep-ms", SLEEP_MS]);
  const dir0 = path.join(SCRATCH, "epoch0"), dir0b = path.join(SCRATCH, "epoch0-recompute");
  const g1 = await step("S5 generator run 1 (live RpcSource path against the local anvil: getLogs chunks, block timestamps, eth_getCode)", async () => {
    const tt = Date.now(); const r = gen(path.join(SCRATCH, "cache1"), dir0);
    log(`   generator: exit ${r.code} in ${((Date.now() - tt) / 1000).toFixed(0)} s`);
    console.log(r.out.split("\n").filter((l) => /^epoch |^root|^leaves|^stays|^checks|^dataHash|^publishEpoch|scan complete|LOCAL ANVIL|ERROR/.test(l)).map((l) => "   | " + l.slice(0, 400)).join("\n"));
    return r;
  });
  const manifestPath = path.join(dir0, "manifest.json"), epochPath = path.join(dir0, "epoch.json");
  const okGen = g1.code === 0 && fs.existsSync(epochPath) && fs.existsSync(manifestPath);
  check("P07", okGen, okGen ? "the generator exited 0 against the local anvil and wrote epoch.json + manifest.json (manifest.rehearsalEndpoint marks it as a rehearsal output)" : `the generator FAILED (exit ${g1.code}): ${tail(g1.out)}`);
  if (!okGen) throw new Abort(2, "the generator failed: " + tail(g1.out));
  const epoch = JSON.parse(fs.readFileSync(epochPath, "utf8")), manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  if (EPOCH_OUT) { const keep = path.join(EPOCH_OUT, "epoch-rehearsal-NOT-PUBLISHABLE"); fs.mkdirSync(keep, { recursive: true }); fs.copyFileSync(epochPath, path.join(keep, "epoch.json")); fs.copyFileSync(manifestPath, path.join(keep, "manifest.json")); }
  const inp = epoch.inputs;
  check("P08", manifest.rehearsalEndpoint === "local-anvil" && inp.epochId === 0 && inp.firstEpoch === true && inp.startBlock === FIRST_START_BLOCK && inp.endBlock === harvest.block && inp.userBps === 9000
    && inp.harvest.transactions.some((h) => h.txHash.toLowerCase() === harvest.tx.toLowerCase()) && BN(inp.harvest.sum).gte(harvest.amount) && inp.scanFromBlock === Number(SCAN_FROM),
    `first-epoch parameters: epoch 0, start ${inp.startBlock}, end ${inp.endBlock} = the fork harvest block, user-bps ${inp.userBps}, ${inp.harvest.count} harvest(s) summing ${inp.harvest.sum} wei (the fork's own: ${harvest.amount}), scan-from ${inp.scanFromBlock}`);
  check("P09", Object.values(epoch.checks).every((v) => v === true), `every generator check is true (${Object.keys(epoch.checks).join(", ")})`);
  const exByAddr = new Map(epoch.exclusions.list.map((e) => [e.address.toLowerCase(), e]));
  const leafByAddr = new Map(epoch.leaves.map((l) => [l.account.toLowerCase(), l]));
  const dead = exByAddr.get(A.DEAD.toLowerCase());
  check("P10", dead?.reason === "dead-seed" && BN(dead.returnedToSafe).gt(0) && !leafByAddr.has(A.DEAD.toLowerCase()), `the dead seed is excluded (reason ${dead?.reason}), its slice ${dead?.returnedToSafe} wei stays with the Safe, and it has no leaf`);
  const cx = exByAddr.get(holder.contract.toLowerCase());
  check("P11", cx?.reason === "contract" && BN(cx.returnedToSafe).gt(0) && !leafByAddr.has(holder.contract.toLowerCase()), `the contract holder ${holder.contract} is excluded (reason ${cx?.reason}), its slice ${cx?.returnedToSafe} wei stays with the Safe, and it has no leaf`);
  const pool = BN(epoch.totals.pool), totalWeight = BN(epoch.totals.totalWeight);
  const rowOk = (a) => { const h = epoch.holders.find((x) => x.address.toLowerCase() === a.toLowerCase()); const l = leafByAddr.get(a.toLowerCase()); return !!h && !!l && l.amount === pool.mul(h.weight).div(totalWeight).toString() && BN(l.amount).gt(0); };
  const ledgerLeaf = leafByAddr.get(LEDGER.toLowerCase()), bobLeaf = leafByAddr.get(bobAddr.toLowerCase());
  check("P12", rowOk(LEDGER) && rowOk(bobAddr), `the Ledger (${ledgerLeaf?.amount}) and Bob (${bobLeaf?.amount}) have leaves equal to floor(pool * weight / totalWeight) recomputed here from epoch.json (pool ${pool}, totalWeight ${totalWeight}); ${epoch.leaves.length} leaves in all`);
  const t = epoch.totals;
  check("P13", BN(t.publishTotal).add(t.stayWithSafe.excludedHoldersSlice).add(t.stayWithSafe.roundingAndDust).add(t.stayWithSafe.safeShareOfBps).eq(inp.pharTotal) && epoch.leaves.reduce((a, l) => a.add(l.amount), BN(0)).eq(t.publishTotal),
    `partition of ${inp.pharTotal} wei: publish ${t.publishTotal} + excluded ${t.stayWithSafe.excludedHoldersSlice} + rounding ${t.stayWithSafe.roundingAndDust} + the 10 % part ${t.stayWithSafe.safeShareOfBps}; the leaves add up to the publish total`);
  const g2 = await step("S5b generator run 2 from a FRESH cache and out dir (determinism)", async () => gen(path.join(SCRATCH, "cache2"), dir0b));
  const same = g2.code === 0 && fs.existsSync(path.join(dir0b, "epoch.json")) && sha256File(path.join(dir0b, "epoch.json")) === sha256File(epochPath);
  const m2 = same ? JSON.parse(fs.readFileSync(path.join(dir0b, "manifest.json"), "utf8")) : null;
  check("P14", same && m2.dataHash === manifest.dataHash && m2.root === manifest.root, same ? `second run: byte-identical epoch.json (sha256 ${sha256File(epochPath).slice(0, 16)}...), dataHash ${manifest.dataHash}, root ${manifest.root}` : `the second run DIFFERS or failed (exit ${g2.code}): ${tail(g2.out)}`);
  const pa = manifest.publishEpochArguments;

  // ------------------------------------------------------------------ S6 deploy the distributor (throwaway deployer, tools/dlmm-rewards-ceremony.sh)
  const addrFile = path.join(SCRATCH, "dlmm-rewards-addresses.rehearsal.env");
  const cenv = { DEPLOYER: deployerAddr, DLMM_REWARDS_ADDRESSES_FILE: addrFile, FOUNDRY_BROADCAST: path.join(SCRATCH, "broadcast"), FOUNDRY_CACHE_PATH: path.join(SCRATCH, "forge-cache") };
  const nonceBefore = await provider.getTransactionCount(deployerAddr);
  const dist = await step("S6 deploy the distributor with tools/dlmm-rewards-ceremony.sh deploy rehearsal (a fresh unlocked throwaway deployer)", async () => {
    const ce = run("bash", ["tools/dlmm-rewards-ceremony.sh", "check-env", "rehearsal"], cenv);
    if (ce.code !== 0) throw new Error("check-env failed: " + tail(ce.out));
    const d = run("bash", ["tools/dlmm-rewards-ceremony.sh", "deploy", "rehearsal"], cenv);
    console.log(d.out.split("\n").filter((l) => /PHAR_DISTRIBUTOR|== DEPLOYED|addresses written|values found|^Error:|reverted|preflight:|ONCHAIN EXECUTION/.test(l)).map((l) => "   | " + l.slice(0, 300)).join("\n"));
    if (d.code !== 0) throw new Error("deploy failed: " + tail(d.out));
    const env = fs.readFileSync(addrFile, "utf8");
    const m = env.match(/PHAR_DISTRIBUTOR=(0x[0-9a-fA-F]{40})/);
    if (!m) throw new Error("no PHAR_DISTRIBUTOR in the addresses file");
    return m[1];
  });
  const D = new ethers.Contract(dist, DIST_ABI, provider);
  const nonceAfter = await provider.getTransactionCount(deployerAddr);
  check("P15", (await provider.getCode(dist)).length > 2 && nonceBefore === 0 && nonceAfter === 1, `distributor deployed at ${dist} in ONE transaction by the fresh deployer ${deployerAddr} (nonce ${nonceBefore} -> ${nonceAfter}); runtime codehash ${utils.keccak256(await provider.getCode(dist))} (the live deployment with the same constructor arguments must show the same codehash)`);
  const vr = run("bash", ["tools/dlmm-rewards-ceremony.sh", "verify", "rehearsal"], { ...cenv, DISTRIBUTOR: dist, EXPECT_OWNER_SAFE: "true", EXPECT_DELAY: String(CLAIM_DELAY), EXPECT_DEADLINE: String(CLAIM_DEADLINE) });
  check("P16", vr.code === 0 && (await D.owner()).toLowerCase() === SAFE.toLowerCase() && (await D.owner()).toLowerCase() !== deployerAddr.toLowerCase() && (await D.pendingOwner()) === ethers.constants.AddressZero
    && (await D.PHAR()).toLowerCase() === A.PHAR.toLowerCase() && (await D.CLAIM_DELAY()).eq(CLAIM_DELAY) && (await D.CLAIM_DEADLINE()).eq(CLAIM_DEADLINE) && (await D.epochCount()).isZero(),
    `read-back: owner = the Safe (not the deployer), pendingOwner 0, PHAR, CLAIM_DELAY ${CLAIM_DELAY}, CLAIM_DEADLINE ${CLAIM_DEADLINE}, epochCount 0 (verify exit ${vr.code})`);

  // ------------------------------------------------------------------ S7 Safe approve + publishEpoch (tools/dlmm-rewards-safe-call.sh, SEND_MODE=unlocked)
  const senv = { DIST: dist, SEND_MODE: "unlocked" };
  const sc = (args, extra = {}) => run("bash", ["tools/dlmm-rewards-safe-call.sh", ...args], { ...senv, ...extra });
  const safeBeforeApprove = await phar.balanceOf(SAFE);
  const big = sc(["simulate", "approve", "1" + "0".repeat(31)]);
  const ap = sc(["send", "approve", pa.total]);
  const allowance = await phar.allowance(SAFE, dist);
  check("P17", big.code !== 0 && /refusing an approval above/.test(big.out) && ap.code === 0 && allowance.eq(pa.total), `the Safe approved EXACTLY ${pa.total} wei to the distributor (a 10^31 approval was refused by the tool); allowance ${allowance}`);
  const pubArgs = ["publish", pa.root, pa.total, String(pa.fromBlock), String(pa.toBlock), pa.dataHash];
  const wrongId = sc(["simulate", ...pubArgs], { EXPECT_EPOCH_ID: "5" });
  const pubSim = sc(["simulate", ...pubArgs], { EXPECT_EPOCH_ID: "0" });
  const pub = await step("S7 publishEpoch with the manifest's exact arguments, through the Safe", async () => sc(["send", ...pubArgs], { EXPECT_EPOCH_ID: "0" }));
  console.log(pub.out.split("\n").filter((l) => /^PUBLISH|DECODED|SIMULATION|ABOUT|^after|refus|FAILED/.test(l)).map((l) => "   | " + l.slice(0, 300)).join("\n"));
  const ei0 = await D.epochInfo(0);
  const pubEvs = await D.queryFilter(D.filters.EpochPublished(0), 0, "latest");
  const distPhar = await phar.balanceOf(dist);
  check("P18", wrongId.code !== 0 && pubSim.code === 0 && pub.code === 0 && (await D.epochCount()).eq(1) && ei0.status === STATUS.Open && ei0.root === pa.root && ei0.total.eq(pa.total) && ei0.fromBlock.eq(pa.fromBlock) && ei0.toBlock.eq(pa.toBlock)
    && ei0.dataHash === pa.dataHash && ei0.claimOpensAt.sub(ei0.publishedAt).eq(CLAIM_DELAY) && ei0.claimDeadline.sub(ei0.publishedAt).eq(CLAIM_DEADLINE) && distPhar.eq(pa.total) && (await phar.allowance(SAFE, dist)).isZero() && pubEvs.length === 1 && safeBeforeApprove.sub(await phar.balanceOf(SAFE)).eq(pa.total),
    `epoch 0 published: status Open, root/total/from/to/dataHash equal the manifest's publishEpochArguments, claim opens at publish + ${CLAIM_DELAY}, deadline + ${CLAIM_DEADLINE}; the distributor holds ${distPhar} PHAR, allowance back to 0, EpochPublished logged; a wrong EXPECT_EPOCH_ID was refused by the tool`);
  const again = sc(["simulate", ...pubArgs], { EXPECT_EPOCH_ID: "0" });
  info(`a second publish of the same id is refused by the tool (epochCount is 1): exit ${again.code}: ${tail(again.out, 160)}`);
  results.info.publishedAt = ei0.publishedAt.toString();

  // ------------------------------------------------------------------ S8 claims refused inside the window
  const proofOf = (a) => leafByAddr.get(a.toLowerCase());
  const early = await revertsWith(() => D.connect(ledger).callStatic.claim(0, LEDGER, ledgerLeaf.amount, ledgerLeaf.proof, { gasLimit: 500000 }));
  check("P19", /^ClaimsNotOpen\(/.test(early ?? "") && !(await D.isClaimWindowOpen(0)) && (await D.verifyLeaf(0, LEDGER, ledgerLeaf.amount, ledgerLeaf.proof)), `a claim inside the 24 h window is refused: ${early}; isClaimWindowOpen false; the Ledger's proof does verify against the on-chain root (verifyLeaf true)`);

  // ------------------------------------------------------------------ S9 the cancel path on a second published (test) epoch
  const safeBeforeTest = await phar.balanceOf(SAFE);
  const testRoot = utils.id("rehearsal-test-epoch-root"), testHash = utils.id("rehearsal-test-epoch-data");
  const ap1 = sc(["send", "approve", "1"]);
  const pub1 = sc(["send", "publish", testRoot, "1", String(pa.fromBlock), String(pa.toBlock), testHash], { EXPECT_EPOCH_ID: "1" });
  const ei1 = await D.epochInfo(1);
  check("P20", ap1.code === 0 && pub1.code === 0 && (await D.epochCount()).eq(2) && ei1.status === STATUS.Open && ei1.total.eq(1) && (await phar.balanceOf(dist)).eq(BN(pa.total).add(1)), `a second epoch (id 1, 1 wei, a test root) is published; the distributor holds ${await phar.balanceOf(dist)} PHAR`);
  const notOwner = await revertsWith(() => D.connect(stranger).callStatic.cancelEpoch(1));
  const can = sc(["send", "cancel", "1"]);
  const ei1b = await D.epochInfo(1);
  const cancelledClaim = await revertsWith(() => D.connect(stranger).callStatic.claim(1, LEDGER, 1, [], { gasLimit: 500000 }));
  check("P21", /^OwnableUnauthorizedAccount\(/.test(notOwner ?? "") && can.code === 0 && ei1b.status === STATUS.Cancelled && (await phar.balanceOf(SAFE)).eq(safeBeforeTest) && (await phar.balanceOf(dist)).eq(pa.total) && (await D.epochCount()).eq(2) && /^EpochNotOpen\(/.test(cancelledClaim ?? ""),
    `cancel inside the window: a non-owner is refused (${notOwner}); the Safe's cancel (tool) set status Cancelled, refunded the 1 wei (Safe PHAR back to ${safeBeforeTest}), epochCount stays 2 (id 1 is burnt); a claim on it is refused: ${cancelledClaim}`);

  // ------------------------------------------------------------------ S10 warp 24 h + 1 s
  await step("S10 evm time warp 24 h + 1 s", () => warp(CLAIM_DELAY + 1));
  const lateCancel = sc(["simulate", "cancel", "0"]);
  const lateCancelC = await revertsWith(() => D.connect(safeSigner).callStatic.cancelEpoch(0));
  check("P22", (await D.isClaimWindowOpen(0)) && lateCancel.code !== 0 && /challenge window of epoch 0 is over/.test(lateCancel.out) && /^WindowOver\(\)/.test(lateCancelC ?? ""),
    `after the 24 h window: isClaimWindowOpen true; cancel is refused by the tool ("challenge window ... is over") and by the contract (${lateCancelC})`);

  // ------------------------------------------------------------------ S11 claims
  const bal = async (a) => phar.balanceOf(a);
  const GL = { gasLimit: 500000 };
  const wrongAmt = await revertsWith(() => D.connect(stranger).callStatic.claim(0, LEDGER, BN(ledgerLeaf.amount).add(1), ledgerLeaf.proof, GL));
  const othersProof = await revertsWith(() => D.connect(stranger).callStatic.claim(0, bobAddr, bobLeaf.amount, ledgerLeaf.proof, GL));
  check("P23", wrongAmt === "InvalidProof()" && othersProof === "InvalidProof()" && !(await D.verifyLeaf(0, LEDGER, BN(ledgerLeaf.amount).add(1), ledgerLeaf.proof)),
    `a changed amount (${wrongAmt}) and another holder's proof (${othersProof}) are refused; verifyLeaf is false for the changed amount`);
  const ledgerBefore = await bal(LEDGER);
  const rc1 = await (await D.connect(ledger).claim(0, LEDGER, ledgerLeaf.amount, ledgerLeaf.proof, GL)).wait();
  results.gas.claimLedger = rc1.gasUsed.toNumber();
  const claimedEv = rc1.logs.map((l) => { try { return dIface.parseLog(l); } catch { return null; } }).find((e) => e?.name === "Claimed");
  check("P24", (await bal(LEDGER)).sub(ledgerBefore).toString() === ledgerLeaf.amount && claimedEv?.args.account === LEDGER && claimedEv.args.amount.toString() === ledgerLeaf.amount && (await D.isClaimed(0, LEDGER)),
    `the Ledger claimed with the proof from epoch.json: PHAR received ${(await bal(LEDGER)).sub(ledgerBefore)} = epoch.json amount ${ledgerLeaf.amount}; Claimed logged; isClaimed true (claim gas ${rc1.gasUsed})`);
  const dbl = await revertsWith(() => D.connect(ledger).callStatic.claim(0, LEDGER, ledgerLeaf.amount, ledgerLeaf.proof, GL));
  check("P25", dbl === "AlreadyClaimed()", `a double claim is refused: ${dbl}`);
  const bobBefore = await bal(bobAddr), strangerBefore = await bal(strangerAddr);
  await (await D.connect(stranger).claim(0, bobAddr, bobLeaf.amount, bobLeaf.proof, GL)).wait();
  check("P26", (await bal(bobAddr)).sub(bobBefore).toString() === bobLeaf.amount && (await bal(strangerAddr)).eq(strangerBefore), `Bob's claim submitted by a STRANGER paid Bob ${bobLeaf.amount} and the stranger nothing`);
  const deadClaim = await revertsWith(() => D.connect(stranger).callStatic.claim(0, A.DEAD, dead.returnedToSafe, [], GL));
  const contractClaim = await revertsWith(() => D.connect(stranger).callStatic.claim(0, holder.contract, cx.returnedToSafe, [], GL));
  const borrowed = await revertsWith(() => D.connect(stranger).callStatic.claim(0, holder.contract, cx.returnedToSafe, bobLeaf.proof, GL));
  check("P27", deadClaim === "InvalidProof()" && contractClaim === "InvalidProof()" && borrowed === "InvalidProof()",
    `the dead seed (${deadClaim}) and the contract holder (${contractClaim}; with a borrowed proof ${borrowed}) cannot claim their slices even with the amount from epoch.json: those slices were never published`);
  const claimedSoFar = BN(ledgerLeaf.amount).add(bobLeaf.amount);
  const ei0c = await D.epochInfo(0);
  const safeNow = await phar.balanceOf(SAFE);
  const excludedTotal = BN(t.stayWithSafe.excludedHoldersSlice);
  check("P28", ei0c.claimed.eq(claimedSoFar) && (await phar.balanceOf(dist)).eq(BN(pa.total).sub(claimedSoFar)) && safeBeforeApprove.sub(safeNow).eq(pa.total) && excludedTotal.gt(0),
    `accounting: claimed ${ei0c.claimed} of ${pa.total}; the distributor holds ${await phar.balanceOf(dist)}; the Safe paid only the publish total ${pa.total} (Safe PHAR ${safeBeforeApprove} -> ${safeNow}): the excluded slices (${excludedTotal} wei), the 10 % part and the rounding never left it`);

  // ------------------------------------------------------------------ S12 sweep refused before the deadline
  const sweepTool = sc(["simulate", "sweep", "0"]);
  const sweepC = await revertsWith(() => D.connect(safeSigner).callStatic.sweepUnclaimed(0));
  check("P29", sweepTool.code !== 0 && /sweep is not possible yet/.test(sweepTool.out) && /^DeadlineNotReached\(/.test(sweepC ?? ""), `sweep before publishedAt + 180 days is refused by the tool and by the contract (${sweepC})`);

  // ------------------------------------------------------------------ S13 warp past 180 days, sweep
  await step("S13 evm time warp past the 180 day deadline", () => warp(CLAIM_DEADLINE));
  const leftover = [...leafByAddr.values()].find((l) => ![LEDGER, bobAddr].some((a) => a.toLowerCase() === l.account.toLowerCase()));
  const lateClaim = await revertsWith(() => D.connect(stranger).callStatic.claim(0, leftover ? leftover.account : LEDGER, leftover ? leftover.amount : ledgerLeaf.amount, leftover ? leftover.proof : ledgerLeaf.proof, { gasLimit: 500000 }));
  check("P30", /^ClaimsClosed\(/.test(lateClaim ?? "") || (!leftover && lateClaim === "AlreadyClaimed()"), `after the deadline a claim is refused: ${lateClaim} (${leftover ? "an unclaimed leaf of " + leftover.account : "every leaf was claimed: the already-claimed check comes first"}); isClaimWindowOpen ${await D.isClaimWindowOpen(0)}`);
  const safeBeforeSweep = await phar.balanceOf(SAFE);
  const sw = await step("S13 sweepUnclaimed through the Safe (tools/dlmm-rewards-safe-call.sh)", async () => sc(["send", "sweep", "0"]));
  const ei0s = await D.epochInfo(0);
  const expectedSweep = BN(pa.total).sub(claimedSoFar);
  check("P31", sw.code === 0 && ei0s.status === STATUS.Swept && (await phar.balanceOf(SAFE)).sub(safeBeforeSweep).eq(expectedSweep) && (await phar.balanceOf(dist)).isZero(),
    `the sweep returned ${expectedSweep} wei (total - claimed) to the Safe, status Swept, the distributor holds ${await phar.balanceOf(dist)} PHAR`);
  const sw2 = await revertsWith(() => D.connect(safeSigner).callStatic.sweepUnclaimed(0));
  check("P32", /^EpochNotOpen\(/.test(sw2 ?? "") && (await phar.balanceOf(dist)).isZero(), `a second sweep is refused (${sw2}); nothing is stranded in the distributor (PHAR balance ${await phar.balanceOf(dist)})`);

  results.info.gas = results.gas;
  results.info.totalSeconds = (Date.now() - t00) / 1000;
}

function finish(code, verdict) {
  const passed = results.checks.filter((c) => c.ok).length;
  const summary = { checks: results.checks.length, passed, failures: results.failures, info: results.info, steps: results.steps.map((s) => ({ name: s.name, ok: s.ok, ms: s.ms })) };
  try { fs.writeFileSync(OUTJSON, JSON.stringify({ ...summary, checkList: results.checks }, null, 2)); } catch { /* */ }
  console.log("RESULTS " + JSON.stringify({ checks: summary.checks, passed, failed: results.failures.length, failures: results.failures, harvest: results.info.harvest, holders: results.info.holders, publishedAt: results.info.publishedAt, gas: results.gas, totalSeconds: results.info.totalSeconds }));
  console.log(verdict);
  process.exit(code);
}

main().then(() => {
  const n = results.checks.length;
  if (results.failures.length === 0) finish(0, `REHEARSAL PASSED: ${n} checks, 0 failures`);
  finish(1, `REHEARSAL FAILED: ${n} checks, ${results.failures.length} failures: ${results.failures.map((f) => f.split(" ")[0]).join(", ")}`);
}).catch((e) => {
  if (e instanceof Abort && e.code === 43) finish(43, `NO PHAR ACCRUED: ${e.message}. Nothing was published. Run again with REH_WARP_SECONDS=172800 (a longer warp); if it still pays 0, report it: the live band earns nothing on this fork.`);
  if (e instanceof Abort) finish(2, `FATAL: ${redact(e.message)}`);
  finish(2, `FATAL: ${redact(String(e?.stack || e)).slice(0, 1500)}`);
});

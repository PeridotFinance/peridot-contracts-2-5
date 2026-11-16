// FORK REHEARSAL of the whole Pharaoh DLMM vault ceremony on a LOCAL anvil fork of Avalanche mainnet. Started by rehearsal.sh (which holds the shared fork lock,
// starts anvil and removes everything on exit). Nothing real: the deployer is a fresh keyless address (impersonated on the fork), the Safe's only owner (the Ledger)
// is impersonated on the fork, the keeper wallet is a throwaway made in memory (a temporary keystore is the only file, mode 600, removed on exit), balances are
// written with anvil_setStorageAt. Every transaction goes to the LOCAL endpoint REH_RPC; the real endpoint is never in this process's environment.
import { createRequire } from "node:module";
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const KDIR = process.env.REH_KEEPER_DIR; // scratch copy of dlmm-keeper (node_modules + dist)
const PROJ = process.env.REH_PROJ; // contracts/vault-dlmm
const SCRATCH = process.env.REH_SCRATCH;
const RPC = process.env.REH_RPC; // http://127.0.0.1:<port>
const OUTJSON = process.env.REH_RESULTS || path.join(SCRATCH, "results.json");
const KEEPER_WAIT_MS = Number(process.env.REH_EXIT_WAIT_MS || 0);
const req = createRequire(path.join(KDIR, "package.json"));
const { ethers } = req("ethers");
const { BigNumber, utils, providers, Wallet } = ethers;
const BN = (x) => BigNumber.from(x);

const A = {
  SAFE: "0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12",
  LEDGER: "0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD",
  USDC: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E",
  USDT: "0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7",
  PHAR: "0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7",
  PAIR: "0x16888EE58E706C253b821EAA637ae9b2cFeA255C",
  ROUTER: "0xff2BEFC4ff86CB0f3e8D3d9D6200B7A05BF5D93d",
  REWARDER: "0x32E68C4b8Edc6d1F16E99EbA826B292FDC18daDC",
  FEED_USDC: "0xF096872672F44d6EBA71458D74fe67F9a77a23B9",
  FEED_USDT: "0xEBE676ee90Fe1112671f19b6B7459bC678B67e8a",
  MULTISEND: "0x9641d764fc13c8B624c04430C7356C1C7C8102e2",
  DEAD: "0x000000000000000000000000000000000000dEaD",
};
const provider = new providers.StaticJsonRpcProvider(RPC, { chainId: 43114, name: "avalanche" });
provider.pollingInterval = 100;
const rpc = (m, p = []) => provider.send(m, p);

// ---------------------------------------------------------------------------------------------------------------- ABIs
const VAULT_ABI = [
  "function owner() view returns (address)", "function paused() view returns (bool)", "function rebalancer() view returns (address)",
  "function totalSupply() view returns (uint256)", "function totalAssets() view returns (uint256)", "function balanceOf(address) view returns (uint256)",
  "function convertToAssets(uint256) view returns (uint256)", "function maxDeposit(address) view returns (uint256)", "function depositCap() view returns (uint256)",
  "function deposit(uint256,address) returns (uint256)", "function redeem(uint256,address,address) returns (uint256)", "function redeemInKind(uint256,address,address) returns (uint256,uint256)",
  "function openBand(uint24,uint24,uint256,uint256,uint256,uint256)", "function harvestRewards()", "function tripGuard()", "function clearGuard()", "function pause()", "function unpause()",
  "function setRebalancer(address)", "function setDepositCap(uint256)", "function bandState() view returns (uint24,uint24,uint24,bool,bool)",
  "function guardState() view returns (bool,bool,uint256)", "function rebalanceAllowed() view returns (bool,uint256,uint256)", "function lastRebalanceAt() view returns (uint48)",
  "function rebalancesToday() view returns (uint16)", "function rebalance(uint24,uint24,bool,uint256,uint256,uint256,uint256,uint256)",
  "function transferOwnership(address)", "function renounceOwnership()",
  "event BandOpened(uint24 lowerId,uint24 upperId,uint24 activeId,uint256 amountX,uint256 amountY)",
  "event Rebalanced(uint24 oldLowerId,uint24 oldUpperId,uint24 newLowerId,uint24 newUpperId,uint24 activeId,bool swapXForY,uint256 swapIn,uint256 swapOut,uint256 navBefore,uint256 navAfter)",
  "event PharHarvested(address indexed token,uint256 amount,uint256 totalSupplyShares,uint256 totalAssets)",
  "event RedeemedInKind(address indexed owner,address indexed receiver,uint256 shares,uint256 amountX,uint256 amountY)",
  "event GuardTripped(address indexed by,uint256 reasons)", "event GuardCleared(address indexed by)",
  "error CapExceeded(uint256 cap,uint256 totalAssetsAfter)", "error GuardLatched()", "error GuardUnsafe(uint256 reasons)", "error GuardStillUnsafe(uint256 reasons)",
  "error NotOutOfRange(uint24 activeId,uint24 lowerId,uint24 upperId)", "error CooldownActive(uint256 readyAt)", "error NotRebalancer()", "error NoBand()", "error BandExists()",
  "error EnforcedPause()", "error ExpectedPause()", "error OwnableUnauthorizedAccount(address account)", "error ZeroShares()", "error ZeroAmount()", "error ExitFailed()",
  "error ActiveIdMoved(uint24 expected,uint24 actual,uint24 idSlippage)", "error NavLossTooLarge(uint256 navBefore,uint256 navAfter)", "error FeedInvalid(uint8 which)",
  "error ERC4626ExceededMaxRedeem(address owner,uint256 shares,uint256 max)", "error SwapTooLarge(uint256 swapIn,uint256 maxIn)", "error PairValidationFailed(uint8 check)",
  "error NothingToDeploy()", "error DeadlineExpired(uint256 deadline)", "error ParamOutOfBounds()", "error DailyRebalanceCapReached()",
  "error SupplyBelowMinimum(uint256 resultingSupply)", "error RenounceDisabled()",
];
const ERC20_ABI = ["function balanceOf(address) view returns (uint256)", "function transfer(address,uint256) returns (bool)", "function approve(address,uint256) returns (bool)", "function allowance(address,address) view returns (uint256)", "function decimals() view returns (uint8)"];
const SAFE_ABI = ["function execTransaction(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,bytes signatures) payable returns (bool)", "function nonce() view returns (uint256)", "function getOwners() view returns (address[])"];
const PAIR_ABI = [
  "function getActiveId() view returns (uint24)", "function getBin(uint24) view returns (uint128,uint128)", "function balanceOf(address,uint256) view returns (uint256)", "function totalSupply(uint256) view returns (uint256)",
  "function getTokenX() view returns (address)", "function getTokenY() view returns (address)",
];
const ROUTER_ABI = ["function swapExactTokensForTokens(uint256 amountIn,uint256 amountOutMin,(uint256[] pairBinSteps,uint8[] versions,address[] tokenPath) path,address to,uint256 deadline) returns (uint256)"];
const FEED_ABI = ["function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)", "function decimals() view returns (uint8)"];
const REWARDER_ABI = ["function getPendingRewards(address,uint256[]) view returns (uint256)", "function owner() view returns (address)"];
const vIface = new utils.Interface(VAULT_ABI);

// ---------------------------------------------------------------------------------------------------------------- helpers
const results = { steps: [], gas: {}, ppm: {}, notes: [], failures: [] };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const now = () => new Date().toISOString().slice(11, 19);
const log = (...a) => console.log(`[${now()}]`, ...a);
const fmt6 = (b) => (Number(BN(b)) / 1e6).toFixed(6);
const ppmOf = (before, after) => (before.isZero() ? 0 : Number(before.sub(after).mul(1_000_000_000).div(before)) / 1000); // ppm with 3 decimals (positive = loss)
function revertReason(e) {
  let data;
  const cands = [e?.data, e?.error?.data, e?.error?.error?.data, e?.error?.body, e?.body];
  for (const c of cands) {
    if (typeof c === "string") { const m = c.match(/0x[0-9a-fA-F]{8,}/); if (m) { data = m[0]; break; } }
    if (c && typeof c === "object" && typeof c.data === "string") { data = c.data; break; }
  }
  if (!data) { const m = JSON.stringify(e, Object.getOwnPropertyNames(e || {})).match(/\\?"data\\?":\\?"(0x[0-9a-fA-F]{8,})/); if (m) data = m[1]; }
  if (data) {
    try { const d = vIface.parseError(data); return `${d.name}(${d.args.map(String).join(",")})`; } catch { /* not ours */ }
    if (data.startsWith("0x08c379a0")) { try { return `Error("${utils.defaultAbiCoder.decode(["string"], "0x" + data.slice(10))[0]}")`; } catch { /* */ } }
    return `raw ${data.slice(0, 74)}`;
  }
  return String(e?.reason || e?.message || e).slice(0, 200);
}
async function expectRevert(label, fn) {
  try { await fn(); } catch (e) { const r = revertReason(e); log(`   EXPECTED REVERT ok  ${label} -> ${r}`); return r; }
  results.failures.push(`${label}: expected a revert but the call succeeded`); log(`   !! UNEXPECTED SUCCESS ${label}`); return null;
}
async function step(name, fn, { fatal = true } = {}) {
  const t0 = Date.now(); log(`>>> STEP ${name}`);
  try { const r = await fn(); const ms = Date.now() - t0; results.steps.push({ name, ms, ok: true }); log(`<<< ${name} ok in ${(ms / 1000).toFixed(1)} s`); return r; }
  catch (e) { const ms = Date.now() - t0; results.steps.push({ name, ms, ok: false, error: String(e?.message || e).slice(0, 400) }); results.failures.push(`${name}: ${String(e?.message || e).slice(0, 300)}`); log(`!!! ${name} FAILED in ${(ms / 1000).toFixed(1)} s: ${String(e?.message || e).slice(0, 600)}`); if (fatal) throw e; }
}
const gasOf = async (tx, label) => { const r = await tx.wait(1); results.gas[label] = r.gasUsed.toNumber(); log(`   gas ${label}: ${r.gasUsed.toString()}`); if (r.status !== 1) throw new Error(`${label} reverted on chain`); return r; };
const FALLBACK_SLOT = utils.id("fallback_manager.handler.address"), GUARD_SLOT = utils.id("guard_manager.guard.address");
async function safeSnap() {
  const slots = {}; for (let i = 0; i < 10; i++) if (i !== 5) slots[i] = await provider.getStorageAt(A.SAFE, i); // slot 5 is the nonce
  slots.fallback = await provider.getStorageAt(A.SAFE, FALLBACK_SLOT); slots.guard = await provider.getStorageAt(A.SAFE, GUARD_SLOT);
  const sf = new ethers.Contract(A.SAFE, ["function getOwners() view returns (address[])", "function getThreshold() view returns (uint256)", "function getModulesPaginated(address,uint256) view returns (address[],address)", "function nonce() view returns (uint256)"], provider);
  return { slots, owners: (await sf.getOwners()).join(","), threshold: (await sf.getThreshold()).toString(), modules: (await sf.getModulesPaginated("0x0000000000000000000000000000000000000001", 10))[0].join(","), code: utils.keccak256(await provider.getCode(A.SAFE)), nonce: (await sf.nonce()).toNumber(), usdc: (await usdc_.balanceOf(A.SAFE)).toString() };
}
const asLedger = () => provider.getSigner(A.LEDGER);
async function impersonate(addr, ethBalance = "0x56BC75E2D63100000") { await rpc("anvil_impersonateAccount", [addr]); await rpc("anvil_setBalance", [addr, ethBalance]); return provider.getSigner(addr); }
const slotCache = {};
const usdc_ = new ethers.Contract(A.USDC, ERC20_ABI, provider);
async function setErc20Balance(token, who, amount) {
  const t = new ethers.Contract(token, ERC20_ABI, provider);
  const val = utils.hexZeroPad(BN(amount).toHexString(), 32);
  const tryslots = slotCache[token] !== undefined ? [slotCache[token]] : Array.from({ length: 80 }, (_, i) => i);
  for (const s of tryslots) {
    const key = utils.keccak256(utils.defaultAbiCoder.encode(["address", "uint256"], [who, s]));
    const old = await provider.getStorageAt(token, key);
    await rpc("anvil_setStorageAt", [token, key, val]);
    if ((await t.balanceOf(who)).eq(amount)) { slotCache[token] = s; return s; }
    await rpc("anvil_setStorageAt", [token, key, old]);
  }
  throw new Error(`no balance slot found for ${token}`);
}
const run = (cmd, args, opts = {}) => {
  const r = spawnSync(cmd, args, { encoding: "utf8", cwd: opts.cwd || PROJ, env: opts.env, maxBuffer: 64 * 1024 * 1024 });
  const out = ((r.stdout || "") + (r.stderr || "")).replace(/https?:\/\/[^\s"]+/g, "<url-redacted>");
  return { code: r.status, out };
};
const BASE_ENV = { PATH: process.env.PATH, HOME: process.env.HOME, AVALANCHE_MAINNET_RPC_URL: RPC, ETH_RPC_URL: RPC, RPC_LOCAL: RPC, FOUNDRY_DISABLE_NIGHTLY_WARNING: "1" };
const indent = (s) => s.split("\n").map((l) => "      | " + l).join("\n");

// ---------------------------------------------------------------------------------------------------------------- the rehearsal
async function main() {
  const t00 = Date.now();
  const pair = new ethers.Contract(A.PAIR, PAIR_ABI, provider);
  const usdc = new ethers.Contract(A.USDC, ERC20_ABI, provider);
  const usdt = new ethers.Contract(A.USDT, ERC20_ABI, provider);
  const phar = new ethers.Contract(A.PHAR, ERC20_ABI, provider);
  const safe = new ethers.Contract(A.SAFE, SAFE_ABI, provider);
  const feedA = new ethers.Contract(A.FEED_USDC, FEED_ABI, provider);
  const feedP = new ethers.Contract(A.FEED_USDT, FEED_ABI, provider);
  const router = new ethers.Contract(A.ROUTER, ROUTER_ABI, provider);
  const ZERO = ethers.constants.AddressZero;

  // ------------------------------------------------------------------ S0 facts
  const facts = await step("S0 fork facts", async () => {
    const blk = await provider.getBlock("latest");
    const [ra, rp] = [await feedA.latestRoundData(), await feedP.latestRoundData()];
    const beacon = await (async () => { const voter = await new ethers.Contract(A.REWARDER, REWARDER_ABI, provider).owner(); const b = await provider.call({ to: voter, data: utils.id("dlmmRewarderFactory()").slice(0, 10) }); return { voter, beacon: utils.getAddress("0x" + b.slice(26)) }; })();
    const implRaw = await provider.call({ to: beacon.beacon, data: utils.id("implementation()").slice(0, 10) });
    const impl = utils.getAddress("0x" + implRaw.slice(26));
    const codehash = utils.keccak256(await provider.getCode(impl));
    const f = { chainId: (await provider.getNetwork()).chainId, block: blk.number, blockTs: blk.timestamp, wall: Math.floor(Date.now() / 1000), feedUsdcAns: ra[1].toString(), feedUsdcAgeS: blk.timestamp - ra[3].toNumber(), feedUsdtAns: rp[1].toString(), feedUsdtAgeS: blk.timestamp - rp[3].toNumber(), activeId: await pair.getActiveId(), safeOwners: await safe.getOwners(), safeNonce: (await safe.nonce()).toString(), ledgerUsdc: fmt6(await usdc.balanceOf(A.LEDGER)), ledgerAvax: utils.formatEther(await provider.getBalance(A.LEDGER)), rewarderBeaconImpl: impl, rewarderImplCodehash: codehash };
    log("   facts", JSON.stringify(f));
    results.facts = f;
    return f;
  });
  const EXPECT_HASH = facts.rewarderImplCodehash;

  // ------------------------------------------------------------------ S1 actors (all keyless or throwaway, fork only)
  const deployerAddr = Wallet.createRandom().address; // only the ADDRESS is used: the deployer is impersonated on the fork, no key is ever used
  const keeperW = Wallet.createRandom();
  const bobAddr = Wallet.createRandom().address;
  const traderAddr = Wallet.createRandom().address;
  const strangerAddr = Wallet.createRandom().address;
  await step("S1 actors, funding (anvil_setBalance / anvil_setStorageAt, fork only)", async () => {
    await impersonate(deployerAddr, "0x0"); // the deployer starts with NOTHING: the Ledger funds it through tools/dlmm-ledger-step.sh (step S1b)
    for (const a of [bobAddr, traderAddr, strangerAddr]) await impersonate(a);
    await impersonate(A.LEDGER, "0x8AC7230489E80000"); // 10 AVAX
    // the keeper wallet starts with nothing too (funded in S1b)
    await setErc20Balance(A.USDC, A.LEDGER, 300_000_000);
    await setErc20Balance(A.USDC, bobAddr, 300_000_000);
    await setErc20Balance(A.USDC, traderAddr, 3_000_000_000_000);
    await setErc20Balance(A.USDT, traderAddr, 3_000_000_000_000);
    log("   deployer (fresh, keyless, impersonated):", deployerAddr, " keeper (throwaway):", keeperW.address, " bob:", bobAddr);
    log("   deployer nonce", await provider.getTransactionCount(deployerAddr), " Safe USDC", fmt6(await usdc.balanceOf(A.SAFE)));
  });

  const stepEnv = { ...BASE_ENV, SEND_MODE: "unlocked", DEPLOYER: deployerAddr, KEEPER_WALLET: keeperW.address };
  const ledgerStep = (mode, name, extra = {}) => run("bash", ["tools/dlmm-ledger-step.sh", mode, name], { env: { ...stepEnv, ...extra } });
  await step("S1b Ledger funds the deployer (0.3 AVAX) and the keeper wallet (1 AVAX) with tools/dlmm-ledger-step.sh (simulation first)", async () => {
    for (const name of ["fund-deployer", "fund-keeper"]) {
      const r = ledgerStep("send", name);
      console.log(indent(r.out.split("\n").filter((l) => /^STEP|signer|to |decoded|simulation|ABOUT|after|AVAX/.test(l)).join("\n")));
      if (r.code !== 0) throw new Error(name + " failed: " + r.out.slice(-400));
    }
    log("   deployer AVAX", utils.formatEther(await provider.getBalance(deployerAddr)), " keeper AVAX", utils.formatEther(await provider.getBalance(keeperW.address)));
    const bad = ledgerStep("simulate", "fund-keeper", { KEEPER_WALLET: A.SAFE });
    log(`   fund-keeper to the Safe refused: exit ${bad.code}: ${bad.out.trim().split("\n").pop()}`);
    const bad2 = ledgerStep("simulate", "fund-safe-usdc", { USDC_TOTAL: "5000" });
    log(`   fund-safe-usdc 5000 (more than the Ledger holds) -> simulation exit ${bad2.code}: ${bad2.out.trim().split("\n").pop().slice(0, 140)}`);
    if (bad.code === 0 || bad2.code === 0) results.failures.push("a bad ledger step was not refused");
  });

  const ENV = { ...BASE_ENV, DEPLOYER: deployerAddr, REBALANCER: keeperW.address, EXPECTED_REWARDER_IMPL_CODEHASH: EXPECT_HASH };
  const ceremony = (args, extra = {}) => run("bash", ["tools/dlmm-vault-ceremony.sh", ...args], { env: { ...ENV, ...extra } });

  // ------------------------------------------------------------------ S2 negative pre-flights (nothing may be sent)
  await step("S2a STAGE 0 read-only pre-flight with cast (tools/dlmm-vault-stage0.sh)", async () => {
    const s0 = run("bash", ["tools/dlmm-vault-stage0.sh"], { env: { ...BASE_ENV, DEPLOYER: deployerAddr, KEEPER: keeperW.address } });
    console.log(indent(s0.out));
    results.stage0 = s0.out;
    if (s0.code !== 0) throw new Error("stage 0 failed");
    const got = (s0.out.match(/REWARDER_IMPL_CODEHASH = (0x[0-9a-f]{64})/) || [])[1];
    log(`   stage-0 codehash ${got} equals the harness's keccak ${EXPECT_HASH}: ${got === EXPECT_HASH}`);
    if (got !== EXPECT_HASH) results.failures.push("stage-0 codehash differs from the harness keccak");
    const ch = run("cast", ["codehash", facts.rewarderBeaconImpl], { env: BASE_ENV });
    log(`   (for the record) cast codehash on this anvil fork: ${ch.out.trim().slice(0, 80)} ; cast keccak of the code: ${got}`);
  });
  await step("S2 negative pre-flights: nothing is broadcast", async () => {
    const bad = ceremony(["deploy", "rehearsal"], { EXPECTED_REWARDER_IMPL_CODEHASH: "0x" + "11".repeat(32), DLMM_ADDRESSES_FILE: path.join(SCRATCH, "neg.env") });
    log(`   wrong expected codehash: exit ${bad.code}; ${(bad.out.match(/preflight:[^\n]*/) || ["(no preflight line)"])[0]}`);
    if (bad.code === 0) results.failures.push("wrong codehash did not stop the deploy");
    const bad2 = ceremony(["check-env", "rehearsal"], { DEPLOYER: A.LEDGER });
    log(`   deployer == Ledger: exit ${bad2.code}; ${bad2.out.trim().split("\n")[0]}`);
    const bad3 = ceremony(["check-env", "rehearsal"], { REBALANCER: A.LEDGER });
    log(`   rebalancer == Ledger: exit ${bad3.code}; ${bad3.out.trim().split("\n")[0]}`);
    const n = await provider.getTransactionCount(deployerAddr);
    log("   deployer nonce after the refused runs:", n);
    if (n !== 0) results.failures.push("deployer nonce moved by a refused deploy");
  });

  // ------------------------------------------------------------------ S3 deploy
  const dep = await step("S3 DEPLOY (ceremony wrapper, rehearsal mode)", async () => {
    const addrFile = path.join(SCRATCH, "addresses.env");
    const t0 = Date.now();
    const r = ceremony(["deploy", "rehearsal"], { DLMM_ADDRESSES_FILE: addrFile });
    const secs = (Date.now() - t0) / 1000;
    console.log(indent(r.out.split("\n").filter((l) => !/^\s*$/.test(l)).slice(-40).join("\n")));
    if (r.code !== 0) throw new Error("deploy failed (exit " + r.code + ")");
    const env = Object.fromEntries(fs.readFileSync(addrFile, "utf8").split("\n").filter(Boolean).map((l) => l.replace(/^export /, "").split("=")));
    const bc = JSON.parse(fs.readFileSync(path.join(PROJ, "broadcast/DeployPharaohDlmmVault.s.sol/43114/run-latest.json"), "utf8"));
    const txs = bc.receipts.map((x, i) => ({ hash: x.transactionHash, gasUsed: parseInt(x.gasUsed, 16), gasPrice: parseInt(x.effectiveGasPrice || "0x0", 16), kind: bc.transactions[i].contractName || bc.transactions[i].function || "?", addr: x.contractAddress }));
    results.gas.deployImplementation = txs[0].gasUsed; results.gas.deployProxyInit = txs[1].gasUsed;
    log("   deploy transactions:", JSON.stringify(txs));
    log(`   deploy wall time ${secs.toFixed(1)} s; deployer nonce now ${await provider.getTransactionCount(deployerAddr)}; deployer AVAX spent ${utils.formatEther(utils.parseEther("0.3").sub(await provider.getBalance(deployerAddr)))} (funded 0.3 AVAX; gas price ${txs[0].gasPrice} wei)`);
    results.deployTxs = txs;
    return { env, secs };
  });
  const V = dep.env.DLMM_VAULT, IMPL = dep.env.DLMM_IMPLEMENTATION, PADMIN = dep.env.DLMM_PROXY_ADMIN;
  const vault = new ethers.Contract(V, VAULT_ABI, provider);
  const VENV = { ...ENV, VAULT: V, EXPECTED_IMPLEMENTATION: IMPL };

  // ------------------------------------------------------------------ S4 read-back stage 1 (+ a negative)
  await step("S4 READ-BACK stage 1 (forge script, read-only) + negative", async () => {
    const r = ceremony(["verify", "rehearsal"], { ...VENV, STAGE: "1" });
    console.log(indent(r.out.split("\n").filter((l) => !/^\s*$/.test(l)).join("\n")));
    if (r.code !== 0 || !/READ-BACK OK/.test(r.out)) throw new Error("read-back stage 1 failed");
    results.readbackStage1 = r.out;
    const neg = ceremony(["verify", "rehearsal"], { ...VENV, STAGE: "1", REBALANCER: A.LEDGER });
    log(`   negative read-back (REBALANCER wrong): exit ${neg.code}`);
    if (neg.code === 0) results.failures.push("read-back accepted a wrong REBALANCER");
    const again = ceremony(["deploy", "rehearsal"], { DLMM_ADDRESSES_FILE: path.join(SCRATCH, "again.env") });
    log(`   a second deploy with the same deployer: exit ${again.code}; ${(again.out.match(/preflight:[^\n]*/) || ["(no preflight line)"])[0]}`);
    if (again.code === 0) results.failures.push("a second deploy was not refused");
    const vc = run("bash", ["tools/dlmm-verify-runtime-code.sh", V], { env: { ...BASE_ENV } });
    console.log(indent(vc.out));
    results.runtimeCode = vc.out;
    if (vc.code !== 0 || (vc.out.match(/equals the build output/g) || []).length !== 4) throw new Error("runtime code verification failed");
    {
      const validator = vc.out.match(/validator\(CREATE\(impl,1\)\) (0x[0-9a-fA-F]{40})/)[1];
      const orig = await provider.getCode(validator);
      const bad = orig.slice(0, 202) + (orig.slice(202, 204) === "ff" ? "00" : "ff") + orig.slice(204);
      await rpc("anvil_setCode", [validator, bad]);
      const neg2 = run("bash", ["tools/dlmm-verify-runtime-code.sh", V], { env: { ...BASE_ENV } });
      log(`   negative: one byte of the validator's code flipped -> exit ${neg2.code}: ${(neg2.out.match(/MISMATCH[^\n]*/) || ["(no mismatch line)"])[0]}`);
      if (neg2.code === 0) results.failures.push("runtime-code check accepted a tampered validator");
      await rpc("anvil_setCode", [validator, orig]);
      // the immutables are ASSERTED: point the implementation's VALIDATOR immutable at another address (one byte) and the ceiling at another value
      const implAddr = vc.out.match(/implementation (0x[0-9a-fA-F]{40})/)[1];
      const art = JSON.parse(fs.readFileSync(path.join(PROJ, "out/PharaohDlmmVault.sol/PharaohDlmmVault.json"), "utf8"));
      const groups = Object.values(art.deployedBytecode.immutableReferences);
      const validatorRef = groups.find((g) => g.length === 1)[0], ceilRef = groups.find((g) => g.length > 1)[0];
      const implCode = await provider.getCode(implAddr);
      for (const [label, ref] of [["VALIDATOR immutable", validatorRef], ["DEPOSIT_CAP_CEILING immutable", ceilRef]]) {
        const pos = 2 + (ref.start + ref.length - 1) * 2; const b = implCode.slice(pos, pos + 2);
        await rpc("anvil_setCode", [implAddr, implCode.slice(0, pos) + (b === "ff" ? "00" : "ff") + implCode.slice(pos + 2)]);
        const neg3 = run("bash", ["tools/dlmm-verify-runtime-code.sh", V], { env: { ...BASE_ENV } });
        log(`   negative: ${label} of the implementation changed by one byte -> exit ${neg3.code}: ${(neg3.out.match(/IMMUTABLES DIFFER[^\n]*/) || neg3.out.match(/MISMATCH[^\n]*/) || ["(none)"])[0].slice(0, 220)}`);
        if (neg3.code === 0) results.failures.push("runtime-code check accepted a changed " + label);
        await rpc("anvil_setCode", [implAddr, implCode]);
      }
    }
    // the deployer holds nothing: it cannot do anything owner-only
    const dsig = provider.getSigner(deployerAddr);
    await expectRevert("deployer calls unpause()", () => vault.connect(dsig).callStatic.unpause());
    await expectRevert("deployer calls pause()", () => vault.connect(dsig).callStatic.pause());
    await expectRevert("deployer calls setRebalancer()", () => vault.connect(dsig).callStatic.setRebalancer(deployerAddr));
    const padmin = new ethers.Contract(PADMIN, ["function upgradeAndCall(address,address,bytes)", "function owner() view returns (address)"], provider);
    await expectRevert("deployer calls ProxyAdmin.upgradeAndCall()", () => padmin.connect(dsig).callStatic.upgradeAndCall(V, deployerAddr, "0x"));
    {
      const sw = ledgerStep("send", "sweep-deployer");
      console.log(indent(sw.out.split("\n").filter((l) => /^STEP|signer|decoded|simulation|ABOUT|after|AVAX/.test(l)).join("\n")));
      if (sw.code !== 0) throw new Error("sweep failed: " + sw.out.slice(-400));
      log("   deployer AVAX after the sweep:", utils.formatEther(await provider.getBalance(deployerAddr)), " nonce", await provider.getTransactionCount(deployerAddr), "(3 = implementation, proxy, sweep)");
    }
    log("   ProxyAdmin.owner() =", await padmin.owner(), " vault.owner() =", await vault.owner(), " paused =", await vault.paused());
  });

  // ------------------------------------------------------------------ S5 the vault is paused: nothing can enter or open
  await step("S5 while paused (the window before the MultiSend)", async () => {
    const bob = provider.getSigner(bobAddr);
    await (await usdc.connect(bob).approve(V, ethers.constants.MaxUint256)).wait();
    await expectRevert("deposit while paused", () => vault.connect(bob).callStatic.deposit(1_000_000, bobAddr));
    await expectRevert("keeper openBand while paused", () => vault.connect(provider.getSigner(keeperW.address)).callStatic.openBand(8388608, 0, 0, 0, 0, 9999999999));
    log("   maxDeposit(bob) while paused:", (await vault.maxDeposit(bobAddr)).toString());
  });

  // ------------------------------------------------------------------ S6 the ONE atomic MultiSend: unpause + approve + seed deposit
  const SEED = "1000000", REST = "199000000";
  await step("S6 Ledger funds the Safe with 200 USDC (tools/dlmm-ledger-step.sh), then the SAFE MultiSend [unpause, approve 200, deposit(1, 0xdEaD), deposit(199, Ledger)] (tools/dlmm-safe-multisend.sh)", async () => {
    const msEnv = { ...BASE_ENV, VAULT: V };
    const snapBefore = await safeSnap();
    const refusals = [["REST_RECEIVER = the dead address", { REST_RECEIVER: A.DEAD }], ["SEED_USDC=6 (over 5)", { SEED_USDC: "6", REST_USDC: "100" }], ["SEED_USDC=0", { SEED_USDC: "0" }], ["total above the cap", { REST_USDC: "200" }]];
    for (const [label, e] of refusals) { const r = run("bash", ["tools/dlmm-safe-multisend.sh", "build"], { env: { ...msEnv, ...e } }); log(`   refused: ${label} -> exit ${r.code}: ${r.out.trim().split("\n")[0].slice(0, 150)}`); if (r.code === 0) results.failures.push("multisend accepted: " + label); }
    const ov = run("bash", ["tools/dlmm-safe-multisend.sh", "build"], { env: { ...msEnv, SEED_USDC: "6", REST_USDC: "100", OVERRIDE_DEAD_ALLOW: "yes" } });
    log(`   with OVERRIDE_DEAD_ALLOW=yes the 6/100 split builds: exit ${ov.code}`);
    if (ov.code !== 0) results.failures.push("override did not allow");
    const b = run("bash", ["tools/dlmm-safe-multisend.sh", "build"], { env: msEnv });
    console.log(indent(b.out.split("\n").slice(0, 12).join("\n")));
    const s0 = run("bash", ["tools/dlmm-safe-multisend.sh", "simulate"], { env: msEnv });
    log(`   simulate BEFORE the Ledger funds the Safe: exit ${s0.code}: ${s0.out.trim().split("\n").pop()}`);
    if (s0.code === 0) results.failures.push("multisend simulate passed with an unfunded Safe");
    // step 2a: Ledger -> Safe, 200 USDC, with the mandatory simulation
    const f = ledgerStep("send", "fund-safe-usdc");
    console.log(indent(f.out.split("\n").filter((l) => /^STEP|signer|to |decoded|simulation|ABOUT|after|Safe USDC|gasUsed/.test(l)).join("\n")));
    if (f.code !== 0) throw new Error("fund-safe-usdc failed: " + f.out.slice(-400));
    results.gas["step 2a Ledger USDC.transfer(Safe, 200)"] = Number((f.out.match(/gasUsed\s+(\d+)/) || [])[1]);
    const sim = run("bash", ["tools/dlmm-safe-multisend.sh", "simulate"], { env: msEnv });
    console.log(indent(sim.out.split("\n").filter((l) => /SAFE NONCE|SIMULATION|vault paused/.test(l)).join("\n")));
    if (sim.code !== 0) throw new Error("simulate failed");
    const t0 = Date.now();
    const snd = run("bash", ["tools/dlmm-safe-multisend.sh", "send"], { env: { ...msEnv, SEND_MODE: "unlocked" } });
    console.log(indent(snd.out.split("\n").filter((l) => /SAFE NONCE|SIMULATION|ABOUT|gasUsed|transactionHash|status|Safe nonce after/.test(l)).join("\n")));
    if (snd.code !== 0) throw new Error("send failed: " + snd.out.slice(-600));
    const gu = (snd.out.match(/gasUsed\s+(\d+)/) || [])[1]; if (gu) results.gas.safeMultiSend = Number(gu);
    log(`   MultiSend wall time ${((Date.now() - t0) / 1000).toFixed(1)} s`);
    log("   paused:", await vault.paused(), " shares at DEAD:", (await vault.balanceOf(A.DEAD)).toString(), " shares at Ledger:", (await vault.balanceOf(A.LEDGER)).toString(), " totalSupply:", (await vault.totalSupply()).toString(), " totalAssets:", (await vault.totalAssets()).toString(), " maxDeposit:", (await vault.maxDeposit(bobAddr)).toString());
    if (await vault.paused()) throw new Error("still paused");
    if (!(await vault.balanceOf(A.DEAD)).eq(SEED) || !(await vault.balanceOf(A.LEDGER)).eq(REST) || !(await vault.totalAssets()).eq(200_000_000)) throw new Error("split is not 1 to the dead address and 199 to the Ledger with totalAssets 200");
    {
      const after = await safeSnap();
      const same = JSON.stringify({ ...snapBefore, nonce: 0, usdc: 0 }) === JSON.stringify({ ...after, nonce: 0, usdc: 0 });
      log(`   SAFE UNCHANGED by the delegatecall MultiSend: owners/threshold/singleton+storage slots 0-9 (except the nonce)/fallback handler/guard/modules/Safe code hash identical: ${same}; nonce ${snapBefore.nonce} -> ${after.nonce}; Safe USDC ${snapBefore.usdc} -> ${after.usdc}; owners ${after.owners}; threshold ${after.threshold}; modules [${after.modules}]; guard slot ${after.slots.guard}; fallback slot ${after.slots.fallback}`);
      if (!same || after.nonce !== snapBefore.nonce + 1) throw new Error("the Safe's configuration changed during the MultiSend");
    }
    const rb = ceremony(["verify", "rehearsal"], { ...VENV, STAGE: "2", SEED, REST, EXPECTED_DEPLOYER_NONCE: "3" });
    console.log(indent(rb.out.split("\n").filter((l) => !/^\s*$/.test(l)).join("\n")));
    if (rb.code !== 0 || !/READ-BACK OK/.test(rb.out)) throw new Error("read-back stage 2 failed");
    results.readbackStage2 = rb.out;
  });

  // ------------------------------------------------------------------ S7 the cap is full: no outside deposit fits; a second holder is made by a share transfer
  let ledgerShares, bobShares;
  await step("S7 cap full: outside deposits revert; Ledger shares 199 -> 100 + 99 to a second holder (ERC-20 transfer) for the exit test", async () => {
    const bob = provider.getSigner(bobAddr);
    await (await usdc.connect(bob).approve(V, ethers.constants.MaxUint256)).wait();
    log("   maxDeposit(Bob) =", (await vault.maxDeposit(bobAddr)).toString(), " totalAssets =", (await vault.totalAssets()).toString());
    await expectRevert("Bob deposits 1 USDC into the full vault", () => vault.connect(bob).callStatic.deposit(1_000_000, bobAddr));
    await expectRevert("Bob deposits 1 raw unit into the full vault", () => vault.connect(bob).callStatic.deposit(1, bobAddr));
    const lv = await vault.convertToAssets(await vault.balanceOf(A.LEDGER));
    results.ppm.depositLedger = ppmOf(BN(199_000_000), lv);
    log(`   Ledger's 199 USDC deposit is worth ${fmt6(lv)} USDC right after the MultiSend -> loss ${results.ppm.depositLedger} ppm (the seed deposit first, then the rest: both 1:1)`);
    const tx = await new ethers.Contract(V, ["function transfer(address,uint256) returns (bool)"], provider).connect(asLedger()).transfer(bobAddr, 99_000_000);
    await gasOf(tx, "ERC-20 transfer of 99 shares Ledger -> second holder");
    ledgerShares = await vault.balanceOf(A.LEDGER); bobShares = await vault.balanceOf(bobAddr);
    log(`   Ledger ${ledgerShares} shares, second holder ${bobShares} shares, dead ${(await vault.balanceOf(A.DEAD)).toString()}`);
  });

  // ------------------------------------------------------------------ S8 keeper: config, check, open-band (live)
  const KS = path.join(SCRATCH, "keeper-ks.json"), PW = path.join(SCRATCH, "keeper-pw");
  const CFG = path.join(SCRATCH, "keeper-config.json");
  const pw = utils.hexlify(utils.randomBytes(16));
  fs.writeFileSync(PW, pw + "\n", { mode: 0o600 });
  fs.writeFileSync(KS, await keeperW.encrypt(pw, { scrypt: { N: 1024 } }), { mode: 0o600 });
  const cfg = JSON.parse(fs.readFileSync(path.join(KDIR, "config", "dlmm-keeper.example.json"), "utf8"));
  Object.assign(cfg, { label: "rehearsal-fork", mode: "live", vault: V, assetToken: A.USDC, pairToken: A.USDT });
  cfg.feeds = { asset: A.FEED_USDC, pair: A.FEED_USDT }; cfg.keeper = { address: keeperW.address }; cfg.alerts = { channel: "log" };
  cfg.monitor = { statePath: path.join(SCRATCH, "keeper-state.json"), haltPath: path.join(SCRATCH, "KEEPER-HALT") };
  fs.writeFileSync(CFG, JSON.stringify(cfg, null, 2));
  const KENV = { PATH: process.env.PATH, HOME: process.env.HOME, AVALANCHE_MAINNET_RPC_URL: RPC, DLMM_KEEPER_KEYSTORE_PATH: KS, DLMM_KEEPER_KEYSTORE_PASSWORD_FILE: PW };
  const keeperCli = (args) => run("node", ["dist/src/main.js", ...args, "--config", CFG], { cwd: KDIR, env: KENV });
  const nav = async () => await vault.totalAssets();

  await step("S8 keeper: validate-config, dry `check`, dry open-band, LIVE `open-band --send`", async () => {
    log("   validate-config:", keeperCli(["validate-config"]).out.trim());
    const ck = keeperCli(["check"]);
    console.log(indent(ck.out.slice(0, 1800)));
    const dry = keeperCli(["open-band"]);
    console.log(indent(dry.out.slice(-1500)));
    const navB = await nav();
    const idleB = { usdc: await usdc.balanceOf(V), usdt: await usdt.balanceOf(V) };
    const t0 = Date.now();
    const live = keeperCli(["open-band", "--send"]);
    const secs = (Date.now() - t0) / 1000;
    console.log(indent(live.out.slice(-2500)));
    if (live.code !== 0) throw new Error("open-band --send failed exit " + live.code);
    const navA = await nav();
    const [lo, up, act, has, oor] = await vault.bandState();
    results.ppm.openBand = ppmOf(navB, navA);
    log(`   openBand (keeper, live) took ${secs.toFixed(1)} s; NAV ${navB} -> ${navA}: loss ${results.ppm.openBand} ppm of NAV; band [${lo},${up}] active ${act} hasBand ${has} outOfRange ${oor}; idle before ${fmt6(idleB.usdc)} USDC`);
    // gas from the BandOpened log
    const ev = await provider.getLogs({ address: V, topics: [vIface.getEventTopic("BandOpened")], fromBlock: facts.block });
    const rc = await provider.getTransactionReceipt(ev[ev.length - 1].transactionHash);
    results.gas.openBand = rc.gasUsed.toNumber(); log("   gas openBand:", rc.gasUsed.toString(), "from", rc.from, "(keeper wallet", keeperW.address, ")");
    const e = vIface.parseLog(ev[ev.length - 1]); log("   BandOpened", e.args.map(String).join(","));
    // ceremony 2d read-backs
    log("   guardState", (await vault.guardState()).map(String).join(","), " totalAssets", (await vault.totalAssets()).toString());
    for (let id = lo; id <= up; id++) log(`   bin ${id}: vault LB shares ${(await pair.balanceOf(V, id)).toString()}  reserves ${(await pair.getBin(id)).map(String).join("/")}`);
    const probeA = await vault.connect(asLedger()).callStatic.redeemInKind(10, A.LEDGER, A.LEDGER);
    const probeB = await vault.connect(asLedger()).callStatic.redeem(10, A.LEDGER, A.LEDGER);
    log("   EXIT PROBE (read-only simulation): redeemInKind(10) ->", probeA.map(String).join("/"), " redeem(10) ->", probeB.toString());
    await expectRevert("keeper openBand again (BandExists)", () => vault.connect(provider.getSigner(keeperW.address)).callStatic.openBand(act, 0, 0, 0, 0, 9999999999));
  });

  // ------------------------------------------------------------------ S9 keeper daemon + real swap pushing the active bin out of the band
  let kproc, klog = "";
  const kstop = () => { if (kproc && !kproc.killed) kproc.kill("SIGTERM"); };
  process.on("exit", kstop);
  const exitInfo = await step("S9 keeper daemon (live) + REAL swap pushes the active bin out; watch the re-centre", async () => {
    const klogPath = path.join(SCRATCH, "keeper-run.log");
    kproc = spawn("node", ["dist/src/main.js", "run", "--config", CFG], { cwd: KDIR, env: KENV, stdio: ["ignore", "pipe", "pipe"] });
    fs.writeFileSync(path.join(SCRATCH, "keeper.pid"), String(kproc.pid));
    kproc.stdout.on("data", (d) => { const s = String(d).replace(/https?:\/\/[^\s"]+/g, "<url-redacted>"); klog += s; fs.appendFileSync(klogPath, s); });
    kproc.stderr.on("data", (d) => { const s = String(d).replace(/https?:\/\/[^\s"]+/g, "<url-redacted>"); klog += s; fs.appendFileSync(klogPath, s); });
    await sleep(8000);
    log("   keeper started, pid", kproc.pid, "; first lines:\n" + indent(klog.split("\n").slice(0, 6).join("\n")));
    const [lo0, up0, act0] = await vault.bandState();
    const tr = provider.getSigner(traderAddr);
    await (await usdc.connect(tr).approve(A.ROUTER, ethers.constants.MaxUint256)).wait();
    await (await usdt.connect(tr).approve(A.ROUTER, ethers.constants.MaxUint256)).wait();
    const swapUp = async (amt) => router.connect(tr).swapExactTokensForTokens(amt, 0, { pairBinSteps: [1], versions: [2], tokenPath: [A.USDC, A.USDT] }, traderAddr, Math.floor(Date.now() / 1000) + 3600, { gasLimit: 6_000_000 });
    // USDt reserves between the active id and upper + 1 (buying USDt with USDC consumes X)
    let needX = BN(0);
    for (let id = act0; id <= up0 + 1; id++) needX = needX.add((await pair.getBin(id))[0]);
    log(`   band [${lo0},${up0}] active ${act0}; USDt (X) reserves from active to upper+1: ${fmt6(needX)}  -> a swap of about that much USDC (+0.5 %) moves the active id past the band`);
    const t0 = Date.now();
    let amt = needX.mul(1005).div(1000).add(1_000_000);
    const rcpt = await (await swapUp(amt)).wait(); results.gas.traderSwap = rcpt.gasUsed.toNumber();
    let act = await pair.getActiveId();
    for (let i = 0; i < 20 && act <= up0; i++) { await (await swapUp(BN(2_000_000))).wait(); act = await pair.getActiveId(); }
    const tExit = Date.now();
    log(`   REAL swap(s) done: active id ${act0} -> ${act} (band was [${lo0},${up0}]); trader spent about ${fmt6(amt)} USDC; guardState ${(await vault.guardState()).map(String).join(",")}`);
    if (act <= up0) throw new Error("could not push the active id out of the band");
    // watch for the re-centre
    let rec = null; const deadline = Date.now() + 360_000;
    while (Date.now() < deadline) {
      const [lo, up, a, has, oor] = await vault.bandState();
      if (has && !oor && (lo !== lo0 || up !== up0)) { rec = { lo, up, a }; break; }
      await sleep(1500);
    }
    const tRec = Date.now();
    if (!rec) throw new Error("the keeper did not re-centre within 360 s; keeper log tail:\n" + klog.slice(-1500));
    log(`   RE-CENTRED after ${((tRec - tExit) / 1000).toFixed(1)} s (exit wait is 60 s): new band [${rec.lo},${rec.up}] active ${rec.a}`);
    const ev = await provider.getLogs({ address: V, topics: [vIface.getEventTopic("Rebalanced")], fromBlock: facts.block });
    const e = vIface.parseLog(ev[ev.length - 1]); const rc = await provider.getTransactionReceipt(ev[ev.length - 1].transactionHash);
    results.gas.rebalance = rc.gasUsed.toNumber();
    results.ppm.rebalance = ppmOf(e.args.navBefore, e.args.navAfter);
    log(`   Rebalanced event: swapXForY ${e.args.swapXForY} swapIn ${e.args.swapIn} swapOut ${e.args.swapOut} navBefore ${e.args.navBefore} navAfter ${e.args.navAfter} -> loss ${results.ppm.rebalance} ppm (oracle-marked, vault's own bound); gas ${rc.gasUsed}`);
    log("   keeper log (tail):\n" + indent(klog.split("\n").slice(-12).join("\n")));
    await sleep(5000);
    const sendsAfter = (klog.match(/rebalance.*sent|sent 0x|tx 0x/gi) || []).length;
    log("   second look 5 s later: band", (await vault.bandState()).map(String).join(","), " lastRebalanceAt", (await vault.lastRebalanceAt()).toString(), " keeper wallet nonce", await provider.getTransactionCount(keeperW.address));
    results.exitToRecentreSec = (tRec - tExit) / 1000;
    return rec;
  }, { fatal: false });
  kstop();
  await sleep(1500);

  // ------------------------------------------------------------------ S10 harvest
  await step("S10 harvestRewards after 6 h of chain time (keeper stopped)", async () => {
    await rpc("evm_increaseTime", [21600]); await rpc("evm_mine", []);
    const [lo, up] = await vault.bandState();
    const ids = []; for (let i = lo; i <= up; i++) ids.push(i);
    const rw = new ethers.Contract(A.REWARDER, REWARDER_ABI, provider);
    const pend = await rw.getPendingRewards(V, ids);
    const before = await phar.balanceOf(A.SAFE);
    const keeperSigner = keeperW.connect(provider);
    const tx = await vault.connect(keeperSigner).harvestRewards({ gasLimit: 2_000_000 });
    const r = await gasOf(tx, "harvestRewards");
    const paid = (await phar.balanceOf(A.SAFE)).sub(before);
    const evs = r.logs.filter((l) => l.address.toLowerCase() === V.toLowerCase()).map((l) => { try { return vIface.parseLog(l); } catch { return null; } }).filter(Boolean);
    log(`   PHAR pending ${pend.toString()}; PharHarvested ${evs.map((e) => e.name + ":" + e.args.amount).join(",")}; PHAR forwarded to the Safe (owner) ${paid.toString()}; vault PHAR left ${(await phar.balanceOf(V)).toString()}; guardState ${(await vault.guardState()).map(String).join(",")}`);
    results.pharHarvested = paid.toString();
    await expectRevert("a stranger calls harvestRewards", () => vault.connect(provider.getSigner(strangerAddr)).callStatic.harvestRewards());
  }, { fatal: false });

  // ------------------------------------------------------------------ S11 pause / rollback procedure
  const SIG = "0x" + "000000000000000000000000" + A.LEDGER.slice(2).toLowerCase() + "0".repeat(64) + "01";
  const safeExec = async (to, data, label) => {
    const s = safe.connect(asLedger());
    const ok = await s.callStatic.execTransaction(to, 0, data, 0, 0, 0, 0, ZERO, ZERO, SIG);
    if (!ok) throw new Error("simulation returned false for " + label);
    const tx = await s.execTransaction(to, 0, data, 0, 0, 0, 0, ZERO, ZERO, SIG, { gasLimit: 1_500_000 });
    return gasOf(tx, "Safe tx: " + label);
  };
  const toolEnv = { ...BASE_ENV, SEND_MODE: "unlocked" };
  const toolRun = (mode, sig, ...args) => run("bash", ["tools/dlmm-safe-call.sh", mode, V, sig, ...args.map(String)], { env: toolEnv });
  const toolSend = (label, sig, ...args) => {
    const r = toolRun("send", sig, ...args);
    console.log(indent(r.out.split("\n").filter((l) => /^vault|^before|^simulation|^after|gasUsed/.test(l)).join("\n")));
    if (r.code !== 0) throw new Error(`${label}: ${r.out.slice(-400)}`);
    const gu = (r.out.match(/gasUsed\s+(\d+)/) || [])[1]; results.gas["Safe tx: " + label] = Number(gu);
  };
  const toolMustFail = (label, sig, ...args) => {
    const r = toolRun("simulate", sig, ...args);
    log(`   EXPECTED FAILURE ${r.code !== 0 ? "ok " : "!! (it passed) "} ${label} -> exit ${r.code}: ${(r.out.match(/simulation FAILED[^\n]*/) || [r.out.trim().split("\n").pop()])[0].slice(0, 120)} | ${(r.out.match(/inner call as the Safe[^\n]*/) || [""])[0].slice(0, 260)}`);
    if (r.code === 0) results.failures.push(label + ": the simulation passed but must fail");
  };
  await step("S11 PAUSE / ROLLBACK procedure on the fork", async () => {
    const bob = provider.getSigner(bobAddr);
    const abiv = (f, ...a) => vIface.encodeFunctionData(f, a);
    log("   -- 11a Safe pause()");
    toolSend("pause()", "pause()");
    log("   paused:", await vault.paused(), " maxDeposit(Bob):", (await vault.maxDeposit(bobAddr)).toString());
    await expectRevert("deposit while paused", () => vault.connect(bob).callStatic.deposit(1_000_000, bobAddr));
    await expectRevert("keeper rebalance/openBand while paused", () => vault.connect(provider.getSigner(keeperW.address)).callStatic.openBand(8388608, 0, 0, 0, 0, 9999999999));
    const e1 = await vault.connect(bob).callStatic.redeemInKind(1000, bobAddr, bobAddr);
    log("   exits are NOT gated by pause: redeemInKind(1000 shares) simulation ->", e1.map(String).join("/"), "; redeem(1000):", (await vault.connect(bob).callStatic.redeem(1000, bobAddr, bobAddr)).toString());
    const rp = await vault.connect(bob).redeemInKind(1000, bobAddr, bobAddr, { gasLimit: 3_000_000 });
    await gasOf(rp, "REAL redeemInKind(1000) while PAUSED");
    const rp2 = await vault.connect(bob).redeem(1000, bobAddr, bobAddr, { gasLimit: 3_000_000 });
    await gasOf(rp2, "REAL redeem(1000, USDC out) while PAUSED");
    log("   -- 11b Safe unpause()");
    toolSend("unpause()", "unpause()");
    log("   paused:", await vault.paused());
    log("   -- 11c close the cap: setDepositCap(1), then restore 200000000");
    toolSend("setDepositCap(1)", "setDepositCap(uint256)", 1);
    log("   maxDeposit(Bob):", (await vault.maxDeposit(bobAddr)).toString());
    await expectRevert("deposit with cap 1", () => vault.connect(bob).callStatic.deposit(1_000_000, bobAddr));
    toolSend("setDepositCap(0) (zero-cap behaviour: closed, NOT unlimited as in R3)", "setDepositCap(uint256)", 0);
    log("   cap 0: maxDeposit(Bob):", (await vault.maxDeposit(bobAddr)).toString());
    await expectRevert("deposit with cap 0", () => vault.connect(bob).callStatic.deposit(1_000_000, bobAddr));
    toolSend("setDepositCap(200000000)", "setDepositCap(uint256)", 200000000);
    log("   depositCap:", (await vault.depositCap()).toString());
    toolMustFail("setDepositCap(200000001) above the ceiling", "setDepositCap(uint256)", 200000001);
    log("   -- 11c2 re-tune the guard: setGuardParams legBandBps 75 (bounds 10..200), a cooldown of 111 is refused (new lower bound 112), then restore the defaults");
    toolSend("setGuardParams(legBandBps 75)", "setGuardParams((uint16,uint32,uint16,uint32,uint16,uint16,uint16))", "(75,93600,60,120,48,6000,50)");
    log("   guardParams legBandBps now", (await new ethers.Contract(V, ["function guardParams() view returns (uint16,uint32,uint16,uint32,uint16,uint16,uint16)"], provider).guardParams()).map(String).join(","));
    toolMustFail("setGuardParams with cooldown 111 (below the bound 112)", "setGuardParams((uint16,uint32,uint16,uint32,uint16,uint16,uint16))", "(50,93600,60,111,48,6000,50)");
    toolSend("setGuardParams(defaults restored)", "setGuardParams((uint16,uint32,uint16,uint32,uint16,uint16,uint16))", "(50,93600,60,120,48,6000,50)");
    log("   -- 11d revoke the keeper: setRebalancer(Ledger), then restore");
    toolSend("setRebalancer(Ledger)", "setRebalancer(address)", A.LEDGER);
    log("   rebalancer:", await vault.rebalancer());
    await expectRevert("old keeper harvestRewards is not owner-gated; keeper rebalance reverts NotRebalancer", () => vault.connect(provider.getSigner(keeperW.address)).callStatic.rebalance(8388608, 0, true, 0, 0, 0, 0, 9999999999));
    toolSend("setRebalancer(keeper)", "setRebalancer(address)", keeperW.address);
    log("   rebalancer restored:", await vault.rebalancer());
    log("   -- 11e guard latch: the USDT/USD feed answer is overridden with a mock (anvil_setCode of a storage-less FixedFeed; fork only)");
    const realCode = await provider.getCode(A.FEED_USDT);
    const art = JSON.parse(fs.readFileSync(path.join(PROJ, "out/FixedFeed.sol/FixedFeed.json"), "utf8"));
    const blk = await provider.getBlock("latest");
    const factory = new ethers.ContractFactory(art.abi, art.bytecode.object, provider.getSigner(strangerAddr));
    const mockDeployed = await factory.deploy(97_000_000, blk.timestamp, false); await mockDeployed.deployed();
    await rpc("anvil_setCode", [A.FEED_USDT, await provider.getCode(mockDeployed.address)]);
    const gs = await vault.guardState();
    log("   feed overridden to 0.97: guardState (unsafe, latched, reasons) =", gs.map(String).join(","), "(bit 8 = pair leg out of band)");
    await expectRevert("deposit under an unsafe feed", () => vault.connect(bob).callStatic.deposit(1_000_000, bobAddr));
    const tg = await vault.connect(provider.getSigner(strangerAddr)).tripGuard();
    await gasOf(tg, "tripGuard (anyone)");
    log("   after tripGuard: guardState =", (await vault.guardState()).map(String).join(","));
    toolMustFail("Safe clearGuard while the feed is still out of band", "clearGuard()");
    toolMustFail("the tool refuses a function outside the whitelist (transferOwnership)", "transferOwnership(address)", A.LEDGER);
    // exits are never gated by the latch or the bad feed: redeemInKind works, redeem (USDC out) may revert on the oracle
    const e2 = await vault.connect(bob).callStatic.redeemInKind(1000, bobAddr, bobAddr);
    log("   exits under the latch and the out-of-band feed: redeemInKind(1000) simulation ->", e2.map(String).join("/"));
    const rl = await vault.connect(bob).redeemInKind(1000, bobAddr, bobAddr, { gasLimit: 3_000_000 });
    await gasOf(rl, "REAL redeemInKind(1000) while LATCHED with the feed out of band");
    await rpc("anvil_setCode", [A.FEED_USDT, realCode]); // the real feed back
    log("   real feed code restored; guardState =", (await vault.guardState()).map(String).join(","), "(latched stays true until the owner clears it)");
    await expectRevert("deposit while latched, feed healthy again", () => vault.connect(bob).callStatic.deposit(1_000_000, bobAddr));
    toolSend("clearGuard()", "clearGuard()");
    log("   after clearGuard: guardState =", (await vault.guardState()).map(String).join(","), " maxDeposit(Bob):", (await vault.maxDeposit(bobAddr)).toString());
    log("   renounceOwnership by the Safe:");
    await expectRevert("Safe renounceOwnership (W2 disables it; if this does NOT revert the vault can be orphaned)", async () => { const s = safe.connect(asLedger()); await s.callStatic.execTransaction(V, 0, abiv("renounceOwnership"), 0, 0, 0, 0, ZERO, ZERO, SIG); const tx = await s.execTransaction(V, 0, abiv("renounceOwnership"), 0, 0, 0, 0, ZERO, ZERO, SIG, { gasLimit: 1_500_000 }); const r = await tx.wait(); if (r.status !== 1) throw new Error("inner call failed"); });
    log("   owner now:", await vault.owner(), "(must still be the Safe)");
  }, { fatal: false });

  // ------------------------------------------------------------------ S12 exits: in kind by everyone, then the seed (fork only)
  await step("S12 EXITS: redeem (USDC out) and redeemInKind by everyone; seed last (fork only); vault empty", async () => {
    const [pa, pp] = [(await feedA.latestRoundData())[1], (await feedP.latestRoundData())[1]];
    const val = (x, y) => y.mul(pp).div(pa).add(x.mul(0)).add(0); // helper not used
    const valueUsdc = (usdcAmt, usdtAmt) => usdcAmt.add(usdtAmt.mul(pp).div(pa));
    const bob = provider.getSigner(bobAddr);
    const recv = { Ledger: BN(0), Bob: BN(0), Seed: BN(0) };
    // Ledger: half by redeem (USDC out), half in kind
    const half = ledgerShares.div(2);
    const navPerShare = async (s) => await vault.convertToAssets(s);
    {
      const exp = await navPerShare(half);
      const b0 = await usdc.balanceOf(A.LEDGER);
      const tx = await vault.connect(asLedger()).redeem(half, A.LEDGER, A.LEDGER, { gasLimit: 4_000_000 });
      await gasOf(tx, "redeem (USDC out) half of the Ledger shares");
      const got = (await usdc.balanceOf(A.LEDGER)).sub(b0);
      results.ppm.redeemUsdcOut = ppmOf(exp, got); recv.Ledger = recv.Ledger.add(got);
      log(`   Ledger redeem(USDC) of ${half}: NAV value ${fmt6(exp)} paid ${fmt6(got)} USDC -> loss ${results.ppm.redeemUsdcOut} ppm`);
    }
    const kindOut = async (who, signer, label) => {
      const shares = await vault.balanceOf(who);
      const exp = await navPerShare(shares);
      const bx0 = await usdt.balanceOf(who), by0 = await usdc.balanceOf(who);
      const tx = await vault.connect(signer).redeemInKind(shares, who, who, { gasLimit: 4_000_000 });
      await gasOf(tx, `redeemInKind ${label}`);
      const dx = (await usdt.balanceOf(who)).sub(bx0), dy = (await usdc.balanceOf(who)).sub(by0);
      const got = valueUsdc(dy, dx);
      results.ppm["redeemInKind " + label] = ppmOf(exp, got); recv[who === A.LEDGER ? "Ledger" : who === A.DEAD ? "Seed" : "Bob"] = recv[who === A.LEDGER ? "Ledger" : who === A.DEAD ? "Seed" : "Bob"].add(got);
      log(`   ${label} redeemInKind ${shares} shares: NAV value ${fmt6(exp)} ; received ${fmt6(dy)} USDC + ${fmt6(dx)} USDt (oracle value ${fmt6(got)}) -> loss ${results.ppm["redeemInKind " + label]} ppm`);
    };
    await kindOut(A.LEDGER, asLedger(), "Ledger (remaining half)");
    await kindOut(bobAddr, bob, "Bob");
    log("   before the seed: totalSupply", (await vault.totalSupply()).toString(), " seed shares", (await vault.balanceOf(A.DEAD)).toString());
    const dead = await impersonate(A.DEAD, "0x56BC75E2D63100000");
    await kindOut(A.DEAD, dead, "seed holder 0xdEaD (FORK ONLY: on mainnet the seed is never redeemed)");
    {
      const base = { Ledger: BN(100_000_000), Bob: BN(99_000_000).sub(2000), Seed: BN(1_000_000) }; // Bob's two 1000-share exits under pause are excluded
      for (const k of Object.keys(base)) {
        results.ppm["ROUND TRIP " + k] = ppmOf(base[k], recv[k]);
        log(`   ROUND TRIP ${k}: deposited ${fmt6(base[k])} USDC, received (oracle value, PHAR excluded) ${fmt6(recv[k])} -> ${results.ppm["ROUND TRIP " + k]} ppm lost (negative = received more than deposited)`);
      }
    }
    const [lo, up, , has] = await vault.bandState();
    await expectRevert("deposit of 500000 raw USDC into the EMPTY vault (supply would be < 1e6)", () => vault.connect(bob).callStatic.deposit(500_000, bobAddr));
    await expectRevert("deposit of 4 raw USDC into the EMPTY vault (the W10 F1 4-wei attacker)", () => vault.connect(bob).callStatic.deposit(4, bobAddr));
    log("   VAULT EMPTY CHECK: totalSupply", (await vault.totalSupply()).toString(), " totalAssets", (await vault.totalAssets()).toString(), " hasBand", has, " vault USDC", (await usdc.balanceOf(V)).toString(), " USDt", (await usdt.balanceOf(V)).toString(), " PHAR", (await phar.balanceOf(V)).toString());
    for (let id = lo; id <= up; id++) log(`   bin ${id}: vault LB shares ${(await pair.balanceOf(V, id)).toString()}`);
    results.vaultEmpty = (await vault.totalSupply()).isZero();
  }, { fatal: false });

  results.totalSeconds = (Date.now() - t00) / 1000;
  fs.writeFileSync(OUTJSON, JSON.stringify(results, null, 2));
  log("RESULTS", JSON.stringify({ gas: results.gas, ppm: results.ppm, failures: results.failures, exitToRecentreSec: results.exitToRecentreSec, pharHarvested: results.pharHarvested, vaultEmpty: results.vaultEmpty, totalSeconds: results.totalSeconds }));
  return results.failures.length ? 1 : 0;
}

main().then((c) => process.exit(c)).catch((e) => { log("FATAL", String(e?.stack || e).slice(0, 1500)); try { fs.writeFileSync(OUTJSON, JSON.stringify(results, null, 2)); } catch { /* */ } process.exit(2); });

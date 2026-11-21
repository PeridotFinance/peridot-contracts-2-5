// B11: the PHAR DISTRIBUTION step (design A, generator 2.1.0 --wrappers), run as the LAST group of the same process: same lock, same proxy, same anvil, same results file as B0..B10.
// It is the rewards work's fork rehearsal (branch feat/dlmm-rewards-boosted, contracts/vault-dlmm/tools/rewards-rehearsal/rehearsal.mjs, checks P00..P32 + W01..W06) folded into this harness, with ONE
// substantive change: the wrapper holder is NOT a stand-in contract. It is THE bpPHAR-USDC MARKET THIS RUN JUST DEPLOYED AND LISTED (address and deployment block go into a wrappers.json), its suppliers are
// split by pToken balance, the permanent seed at 0x...dEaD is excluded, and nothing in any contract is changed. Everything the rewards project owns (the generator, the distributor deploy script, the Safe tools,
// the harvest tool of the vault work) is RUN from its own worktree, read-only: REH_REWARDS_PROJ / REH_INT_TOOLS; forge output goes to the run's scratch directory.
// Ids: B11.p00..p32 = the rewards rehearsal's P00..P32, B11.w01..w06 = its W01..W06 (w01 is new: the expected split is reconciled with the chain before the generator runs).
// THE ASSISTANT HAS NOT RUN THIS ON A FORK (it has no endpoint): the model below is cross-checked offline against the generator's own exported wrapperSplit (selftest, DRY); everything else is DRY / syntax only.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { ethers, utils, BN, Wallet, A, C, LIVE, HERE, OUTDIR, check, note, group, runProc, blockNumber, provider, rpc, log, impersonate, tx, expectRevert, addErrorAbi, headTs, warp } from "./lib.mjs";

const FIRST_START_BLOCK = 100488395;
const CLAIM_DELAY = 86400, CLAIM_DEADLINE = 15552000;
const TRANSFER = utils.id("Transfer(address,address,uint256)");
const DEAD = LIVE.DEAD, ZERO = ethers.constants.AddressZero;
const lc = (a) => String(a).toLowerCase();

const VAULT_X = ["function owner() view returns (address)", "function rewardToken() view returns (address)", "function rewarder() view returns (address)", "function balanceOf(address) view returns (uint256)", "function totalSupply() view returns (uint256)",
  "function transfer(address,uint256) returns (bool)", "function approve(address,uint256) returns (bool)", "function bandState() view returns (uint24,uint24,uint24,bool,bool)", "function decimals() view returns (uint8)",
  "event PharHarvested(address indexed token,uint256 amount,uint256 totalSupplyShares,uint256 totalAssets)"];
const ERC20_X = ["function balanceOf(address) view returns (uint256)", "function allowance(address,address) view returns (uint256)"];
const REWARDER_ABI = ["function getPendingRewards(address,uint256[]) view returns (uint256)"];
const DIST_ABI = [
  "function owner() view returns (address)", "function pendingOwner() view returns (address)", "function PHAR() view returns (address)", "function CLAIM_DELAY() view returns (uint256)", "function CLAIM_DEADLINE() view returns (uint256)",
  "function epochCount() view returns (uint256)",
  "function epochInfo(uint256) view returns (tuple(bytes32 root,uint256 total,uint256 claimed,uint256 publishedAt,uint256 claimOpensAt,uint256 claimDeadline,uint256 fromBlock,uint256 toBlock,bytes32 dataHash,uint8 status))",
  "function isClaimed(uint256,address) view returns (bool)", "function isClaimWindowOpen(uint256) view returns (bool)", "function verifyLeaf(uint256,address,uint256,bytes32[]) view returns (bool)",
  "function claim(uint256 epochId,address account,uint256 amount,bytes32[] proof)", "function cancelEpoch(uint256)", "function sweepUnclaimed(uint256)",
  "event Claimed(uint256 indexed epochId,address indexed account,uint256 amount)",
  "error ZeroAddress()", "error NotAContract()", "error BadWindow()", "error ZeroRoot()", "error ZeroTotal()", "error ZeroDataHash()", "error BadBlockRange()", "error TotalTooLarge()",
  "error TransferAmountMismatch(uint256 expected,uint256 received)", "error NoSuchEpoch()", "error EpochNotOpen(uint8 status)", "error WindowOver()", "error ClaimsNotOpen(uint256 opensAt)",
  "error ClaimsClosed(uint256 deadline)", "error DeadlineNotReached(uint256 deadline)", "error AlreadyClaimed()", "error ZeroAmount()", "error InvalidProof()", "error ExceedsEpochTotal(uint256 claimedAfter,uint256 total)",
  "error RenounceDisabled()", "error OwnableUnauthorizedAccount(address account)", "error OwnableInvalidOwner(address owner)", "error ReentrancyGuardReentrantCall()",
];
const STATUS = { None: 0, Open: 1, Cancelled: 2, Swept: 3 };

// ---------------------------------------------------------------------------------------------------------------- the expected split (an independent model, written from the generator's documented rule)
/**
 * The split of a wrapper holder's vault-share-seconds among its suppliers by pToken balance, from an ordered event list. Rule (generator 2.1.0, header of wrapperSplit): the time axis is cut where the END state of a block differs
 * from its state before; in a segment of dt seconds each supplier i gets floor(V * dt * p_i / P); the remainder of V * dt is `rounding`; V * dt with P == 0 is `noSupplier`.
 * events: [{ blockNumber, logIndex, t, dV: bigint, dP: [[address, bigint]] }] ; returns { weights: Map(lowercase address -> bigint), rounding, noSupplier, vSeconds, V, bal: Map }
 */
export function expectedSplit(events, endTs) {
  const ev = [...events].sort((a, b) => a.blockNumber - b.blockNumber || a.logIndex - b.logIndex);
  let V = 0n; let bal = new Map(); const w = new Map(); let rounding = 0n, noSupplier = 0n, vSeconds = 0n, segStart = null;
  const sum = (m) => { let x = 0n; for (const b of m.values()) x += b; return x; };
  const same = (m1, m2) => { if (m1.size !== m2.size) return false; for (const [a, b] of m1) if (m2.get(a) !== b) return false; return true; };
  const integrate = (v, m, T) => {
    if (segStart === null || T <= segStart) return;
    const u = v * BigInt(T - segStart); vSeconds += u; if (u === 0n) return;
    const P = sum(m); if (P === 0n) { noSupplier += u; return; }
    let acc = 0n; for (const [a, b] of m) { const x = (u * b) / P; if (x > 0n) w.set(a, (w.get(a) ?? 0n) + x); acc += x; }
    rounding += u - acc;
  };
  for (let i = 0; i < ev.length;) {
    let j = i; while (j < ev.length && ev[j].blockNumber === ev[i].blockNumber) j++;
    const beforeV = V, beforeBal = new Map(bal);
    for (let k = i; k < j; k++) {
      V += ev[k].dV; if (V < 0n) throw new Error("expected-split model: negative vault-share balance");
      for (const [a, d] of ev[k].dP) { const key = lc(a); const nb = (bal.get(key) ?? 0n) + d; if (nb < 0n) throw new Error(`expected-split model: negative pToken balance for ${a}`); if (nb === 0n) bal.delete(key); else bal.set(key, nb); }
    }
    if (V !== beforeV || !same(bal, beforeBal)) { integrate(beforeV, beforeBal, ev[i].t); segStart = ev[i].t; }
    i = j;
  }
  integrate(V, bal, endTs);
  return { weights: w, rounding, noSupplier, vSeconds, V, bal };
}

/** OFFLINE cross-check of the model against the generator's own exported wrapperSplit on synthetic histories (used by DRY and by the self-test). Returns { ok, cases, detail }. */
export function crossCheckModel(R, seed = 7) {
  let s = seed; const rnd = (n) => { s = (s * 1103515245 + 12345) & 0x7fffffff; return s % n; };
  const addr = (n) => utils.getAddress(utils.hexZeroPad(`0x${(0xa00 + n).toString(16)}`, 20));
  const holders = [1, 2, 3, 4, 5].map(addr); const P = addr(99), DEADX = utils.getAddress(R.DEAD ?? DEAD);
  const T_BASE = 1_800_000_000, B_BASE = 1000; let cases = 0;
  for (let c = 0; c < 40; c++) {
    const vT = [], pT = [], events = []; let block = B_BASE, li = 0; const bal = new Map(); let V = 0n;
    const nEv = 6 + rnd(14);
    for (let e = 0; e < nEv; e++) {
      if (!(e > 0 && rnd(4) === 0)) { block += 1 + rnd(3) * (rnd(2) ? 5 : 1); li = 0; }   // one event in four lands in the SAME block as the previous one (the generator applies a block's events together and cuts a segment only when the END state differs)
      const t = T_BASE + (block - B_BASE) * 2; const kind = rnd(4);
      const h = holders[rnd(holders.length)];
      if (kind === 0) { const v = BigInt(1 + rnd(5_000_000)); vT.push({ blockNumber: block, logIndex: li, from: ZERO, to: P, value: v }); V += v; events.push({ blockNumber: block, logIndex: li++, t, dV: v, dP: [] }); }               // a donation / a mint of shares into the market
      else if (kind === 1) { const p = BigInt(1 + rnd(5000)) * 5000n; pT.push({ blockNumber: block, logIndex: li, from: P, to: h, value: p }); bal.set(h, (bal.get(h) ?? 0n) + p); events.push({ blockNumber: block, logIndex: li++, t, dV: 0n, dP: [[h, p]] }); }   // supply: pTokens minted
      else if (kind === 2 && (bal.get(h) ?? 0n) > 0n) { const b = bal.get(h); const p = b / BigInt(1 + rnd(3)); if (p > 0n) { pT.push({ blockNumber: block, logIndex: li, from: h, to: P, value: p }); bal.set(h, b - p); events.push({ blockNumber: block, logIndex: li++, t, dV: 0n, dP: [[h, -p]] }); } }
      else if (kind === 3 && V > 0n) { const v = V / BigInt(1 + rnd(4)); if (v > 0n) { vT.push({ blockNumber: block, logIndex: li, from: P, to: ZERO, value: v }); V -= v; events.push({ blockNumber: block, logIndex: li++, t, dV: -v, dP: [] }); } }                 // redeem: shares leave
      else { const p = 5_000_000n; pT.push({ blockNumber: block, logIndex: li, from: P, to: DEADX, value: p }); bal.set(DEADX, (bal.get(DEADX) ?? 0n) + p); events.push({ blockNumber: block, logIndex: li++, t, dV: 0n, dP: [[DEADX, p]] }); }          // a seed to the dead address
    }
    const endBlock = block + 10, t0 = T_BASE, t1 = T_BASE + (endBlock - B_BASE) * 2; const tsOf = (b) => T_BASE + (b - B_BASE) * 2;
    const g = R.wrapperSplit({ pToken: P, vaultTransfers: vT, pTokenTransfers: pT, startBlock: B_BASE - 1, endBlock, t0, t1, ts: tsOf });
    const m = expectedSplit(events, t1);
    const gw = new Map([...g.weights].map(([a, x]) => [lc(a), x])); let ok = gw.size === m.weights.size && g.rounding === m.rounding && g.noSupplier === m.noSupplier && g.vaultShareSeconds === m.vSeconds;
    if (ok) for (const [a, x] of gw) if (m.weights.get(a) !== x) ok = false;
    if (!ok) return { ok: false, cases, detail: `case ${c}: generator weights ${JSON.stringify([...gw].map(([a, x]) => [a.slice(-4), String(x)]))} rounding ${g.rounding} noSupplier ${g.noSupplier} vs model ${JSON.stringify([...m.weights].map(([a, x]) => [a.slice(-4), String(x)]))} rounding ${m.rounding} noSupplier ${m.noSupplier}` };
    cases++;
  }
  return { ok: true, cases, detail: "" };
}

// ---------------------------------------------------------------------------------------------------------------- the group
export async function runPhar(c) {
  const { D, pBP, ctl, PT, CTL, runStep, step } = c;
  const E = process.env, RPC = E.REH_RPC;
  const PROJ = E.REH_REWARDS_PROJ, INT_TOOLS = E.REH_INT_TOOLS, SCAN_FROM = E.REH_SCAN_FROM, SCRATCH = E.REH_SCRATCH;
  const WARP = Number(E.REH_WARP_SECONDS || 86400), CHUNK = E.REH_CHUNK || "100", SLEEP_MS = E.REH_SLEEP_MS || "0", RERUN = E.REH_RERUN !== "0", EPOCH_OUT = E.REH_EPOCH_OUT || OUTDIR;
  const redact = (x) => String(x).replace(/https?:\/\/[^\s"')]+/g, "<url-redacted>");
  const ETHERS_PKG = path.join(E.REH_ETHERS_DIR, "node_modules", "ethers");
  const BASE_ENV = { PATH: E.PATH, HOME: E.HOME, ETHERS_DIR: ETHERS_PKG, ETH_RPC_URL: RPC, AVALANCHE_MAINNET_RPC_URL: RPC, RPC_LOCAL: RPC, FOUNDRY_DISABLE_NIGHTLY_WARNING: "1" };
  // every child process: async (heartbeat and watchdog keep running), stdin closed, its own timeout (the generator's log scan gets the longest)
  const run = async (cmd, args, env = {}, cwd = PROJ, timeoutMs = (Number(E.REH_TOOL_TIMEOUT_MS) || 30 * 60 * 1000)) => { const r = await runProc(cmd, args, { cwd, env: { ...BASE_ENV, ...env }, timeoutMs, label: `${path.basename(String(args[0] || cmd))} ${args.slice(1, 3).join(" ")}` }); return { code: r.code, out: r.out }; };
  const tail = (s, n = 400) => s.trim().split("\n").slice(-6).join(" | ").slice(-n);
  const sha256File = (f) => crypto.createHash("sha256").update(fs.readFileSync(f)).digest("hex");
  const S = (x) => BN(x).toString();

  addErrorAbi(DIST_ABI.filter((x) => x.startsWith("error")));
  const vault = C(LIVE.VAULT, VAULT_X), phar = C(LIVE.PHAR, ERC20_X), rewarder = C("0x32E68C4b8Edc6d1F16E99EbA826B292FDC18daDC", REWARDER_ABI);
  const SAFE = LIVE.SAFE, LEDGER = LIVE.LEDGER;

  await group("B11 PHAR distribution: the deployed bpPHAR-USDC market as the wrapper holder (LAST group)", async () => {
    if (!SCAN_FROM || !/^\d+$/.test(SCAN_FROM)) throw new Error("REH_SCAN_FROM (the vault's deployment block) is required for the PHAR step; REH_WRAPPER=0 skips it");
    const startBlock = await blockNumber();
    const t00 = Date.now();

    // ------------------------------------------------------------------ p00-p02 facts of the fork
    const blk0 = await provider.getBlock("latest");
    const [lo, up, , has] = await vault.bandState();
    const facts = { block: blk0.number, ledgerShares: await vault.balanceOf(LEDGER), deadShares: await vault.balanceOf(DEAD), supply: await vault.totalSupply(), band: [lo, up], hasBand: has };
    check("B11.p00", (await provider.getNetwork()).chainId === 43114 && facts.block > FIRST_START_BLOCK, `anvil fork of chain 43114 at block ${facts.block} (> the first epoch start ${FIRST_START_BLOCK}); vault supply ${facts.supply} shares; the market under test is ${D.PBP} (deployed by this run at block ${D.blocks?.market ?? "?"})`);
    check("B11.p01", lc(await vault.owner()) === lc(SAFE) && lc(await vault.rewardToken()) === lc(LIVE.PHAR) && lc(await vault.rewarder()) === lc(rewarder.address) && has,
      `the REAL vault: owner = the Safe, rewardToken = PHAR, rewarder = ${rewarder.address}, has a band [${lo},${up}]`);
    check("B11.p02", facts.ledgerShares.gt(2_000_000) && facts.deadShares.gt(0), `the Ledger holds ${facts.ledgerShares} shares, the dead seed ${facts.deadShares} shares`);
    if (!has) throw new Error("the live vault has no band: nothing accrues, the scenario cannot run");
    const L0 = facts.ledgerShares;

    // ------------------------------------------------------------------ the actors (fork only) and the share movements
    const bob = A("B0B11"), carol = A("CA2011"), stranger = A("57A11"), contractHolder = A("C0C0A11");
    for (const a of [bob, carol, stranger]) await impersonate(a);
    const deployer = Wallet.createRandom().address; await impersonate(deployer); // a fresh keyless address, nonce 0: the distributor's throwaway deployer
    await impersonate(SAFE);
    const mock = JSON.parse(fs.readFileSync(path.join(HERE, "MockFeed.json"), "utf8"));
    await rpc("anvil_setCode", [contractHolder, "0x" + mock.deployedBytecode.replace(/^0x/, "")]);   // any contract: it holds vault shares directly and must be EXCLUDED as a contract holder
    const toBob = L0.div(5), toContract = L0.div(10), mL = L0.div(20), dn = L0.div(200), cShares = L0.div(50), bobSupply = toBob.div(4).mul(2);
    await tx("Ledger -> Bob (an EOA holds shares directly)", (o) => C(LIVE.VAULT, VAULT_X, LEDGER).transfer(bob, toBob, o));
    await tx("Ledger -> a contract holder", (o) => C(LIVE.VAULT, VAULT_X, LEDGER).transfer(contractHolder, toContract, o));
    check("B11.p03", (await vault.balanceOf(bob)).eq(toBob) && (await vault.balanceOf(contractHolder)).eq(toContract) && (await provider.getCode(contractHolder)).length > 2 && (await provider.getCode(bob)) === "0x",
      `Bob (EOA ${bob}) holds ${toBob} shares and the contract ${contractHolder} holds ${toContract} shares (both sent by the impersonated Ledger)`);

    // ------------------------------------------------------------------ the market's suppliers: the Ledger, Carol (a PURE supplier), Bob (a direct holder AND a supplier), a donation; the seed and dave are already there
    if (await ctl.mintGuardianPaused(D.PBP)) await runStep(step("mintOpen"));
    const supply = async (who, shares, label) => {
      await tx(`${label} approves the market`, (o) => C(LIVE.VAULT, VAULT_X, who).approve(D.PBP, shares, o));
      const before = await pBP.balanceOf(who);
      await tx(`${label} supplies ${shares} raw shares`, (o) => C(D.PBP, PT, who).mint(shares, o));
      return (await pBP.balanceOf(who)).sub(before);
    };
    const ledgerP = await supply(LEDGER, mL, "Ledger");
    await tx("Ledger -> Carol (shares for a pure supplier)", (o) => C(LIVE.VAULT, VAULT_X, LEDGER).transfer(carol, cShares, o));
    const carolP = await supply(carol, cShares, "Carol");
    const bobP = await supply(bob, bobSupply, "Bob");
    await tx("Ledger donates shares directly to the market", (o) => C(LIVE.VAULT, VAULT_X, LEDGER).transfer(D.PBP, dn, o));
    note("B11.n1", `suppliers added: Ledger ${ledgerP} pTokens (${mL} shares), Carol ${carolP} (${cShares}, her only holding is the market), Bob ${bobP} (${bobSupply}), a donation of ${dn} shares straight to the market; the permanent seed (${await pBP.balanceOf(DEAD)} pTokens at 0xdEaD) and the B3 account dave were already in the market`);

    // the expected split is built from the LOCAL chain's own logs (pToken Transfers + vault Transfers to/from the market) and reconciled with direct state reads BEFORE the generator runs
    const tsCache = new Map(); const tsOfBlock = async (n) => { if (!tsCache.has(n)) tsCache.set(n, (await provider.getBlock(n)).timestamp); return tsCache.get(n); };
    const modelEvents = async (toBlock) => {
      const out = [];
      const fromBlock = D.blocks?.market ?? startBlock - 1;
      for (const l of await provider.getLogs({ address: D.PBP, topics: [TRANSFER], fromBlock, toBlock })) {
        const from = utils.getAddress(utils.hexDataSlice(l.topics[1], 12)), to = utils.getAddress(utils.hexDataSlice(l.topics[2], 12)), v = BigInt(BN(l.data).toString()); const dP = [];
        if (from === to) continue;
        if (lc(from) !== lc(D.PBP) && from !== ZERO) dP.push([from, -v]);
        if (lc(to) !== lc(D.PBP) && to !== ZERO && v > 0n) dP.push([to, v]);
        out.push({ blockNumber: l.blockNumber, logIndex: l.logIndex, t: await tsOfBlock(l.blockNumber), dV: 0n, dP });
      }
      for (const l of await provider.getLogs({ address: LIVE.VAULT, topics: [TRANSFER], fromBlock, toBlock })) {
        const from = utils.getAddress(utils.hexDataSlice(l.topics[1], 12)), to = utils.getAddress(utils.hexDataSlice(l.topics[2], 12)), v = BigInt(BN(l.data).toString());
        if (from === to) continue; let dV = 0n; if (lc(from) === lc(D.PBP)) dV -= v; if (lc(to) === lc(D.PBP)) dV += v;
        if (dV !== 0n) out.push({ blockNumber: l.blockNumber, logIndex: l.logIndex, t: await tsOfBlock(l.blockNumber), dV, dP: [] });
      }
      return out;
    };
    const ev0 = await modelEvents("latest"), m0 = expectedSplit(ev0, await headTs());
    const problems = [];
    if (!BN(m0.V).eq((await vault.balanceOf(D.PBP)).toString())) problems.push(`V model ${m0.V} chain ${await vault.balanceOf(D.PBP)}`);
    let pSum = 0n; for (const [a, b] of m0.bal) { pSum += b; if (!(await pBP.balanceOf(a)).eq(b.toString())) problems.push(`pToken balance of ${a}: model ${b} chain ${await pBP.balanceOf(a)}`); }
    if (!(await pBP.totalSupply()).eq(pSum.toString())) problems.push(`pToken supply model ${pSum} chain ${await pBP.totalSupply()}`);
    check("B11.w01", problems.length === 0 && m0.bal.has(lc(DEAD)) && m0.bal.has(lc(carol)) && m0.bal.has(lc(bob)) && m0.bal.has(lc(LEDGER)),
      `the harness's expected-split model (built from the local chain's pToken and vault Transfer logs since the market's deployment block ${D.blocks?.market ?? "?"}: ${ev0.length} events) equals the chain: the market holds ${m0.V} vault shares for ${pSum} pTokens across ${m0.bal.size} suppliers (seed at 0xdEaD, the Ledger, Carol, Bob and the earlier test accounts)`, problems.join("; "));
    const holders0 = new Set(m0.bal.keys());

    // ------------------------------------------------------------------ time: half the warp, Bob redeems half of HIS pTokens, the other half
    const t0 = await headTs();
    await warp(Math.floor(WARP / 2));
    const half = (await pBP.balanceOf(bob)).div(2);
    await tx("Bob redeems half of his pTokens (mid-epoch change of balances and held shares)", (o) => C(D.PBP, PT, bob).redeem(half, o));
    await warp(WARP - Math.floor(WARP / 2));
    const t1 = await headTs();
    check("B11.p04", t1 - t0 >= WARP, `chain time advanced by ${t1 - t0} s (>= ${WARP}); feeds were re-pinned after every warp`);
    const ids = []; for (let i = Number(lo); i <= Number(up); i++) ids.push(i);
    const pending = await rewarder.getPendingRewards(LIVE.VAULT, ids);
    check("B11.p05", pending.gt(0), `pending PHAR on the band ${ids[0]}..${ids[ids.length - 1]} = ${pending} wei after the warp (0 means REH_WARP_SECONDS=172800 and run again)`);
    if (pending.isZero()) throw new Error("pending PHAR is 0 after the warp: nothing to harvest, nothing to distribute (REH_WARP_SECONDS=172800)");

    // ------------------------------------------------------------------ the harvest through the Safe (the vault work's tool, SEND_MODE=unlocked: simulation first)
    const safeBefore = await phar.balanceOf(SAFE);
    const hv = new utils.Interface(VAULT_X), hvTopic = hv.getEventTopic("PharHarvested");
    const hr = await run("bash", [path.join(INT_TOOLS, "dlmm-harvest.sh"), "send"], { VAULT: LIVE.VAULT, SEND_MODE: "unlocked" });
    log("   " + hr.out.split("\n").filter((l) => /BAND|DECODED|SIMULATION|ABOUT|SAFE PHAR|status/.test(l)).join("\n   "));
    if (hr.code !== 0) throw new Error("dlmm-harvest.sh failed: " + tail(hr.out));
    const hlogs = await provider.getLogs({ address: LIVE.VAULT, topics: [hvTopic], fromBlock: startBlock, toBlock: "latest" });
    if (!hlogs.length) throw new Error("no PharHarvested event after the harvest");
    const hl = hlogs[hlogs.length - 1], harvest = { tx: hl.transactionHash, block: hl.blockNumber, amount: BN(hv.parseLog(hl).args[1]) };
    const safeAfter = await phar.balanceOf(SAFE);
    check("B11.p06", harvest.amount.gt(0) && safeAfter.sub(safeBefore).gte(harvest.amount), `harvest ${harvest.tx} at block ${harvest.block}: PharHarvested.amount ${harvest.amount} wei, the Safe's PHAR rose by ${safeAfter.sub(safeBefore)} (pending was ${pending})`);
    if (harvest.amount.isZero()) throw new Error("PharHarvested.amount is 0");

    // ------------------------------------------------------------------ the generator against the LOCAL anvil, with --wrappers = a wrappers.json naming THIS market
    const wfile = path.join(SCRATCH, "wrappers.json");
    const wjson = { schema: "peridot-dlmm-rewards-wrappers/1", wrappers: [{ pToken: D.PBP, underlying: LIVE.VAULT, fromBlock: D.blocks?.market ?? startBlock - 1, label: "bpPHAR-USDC (deployed by this run)" }] };
    fs.writeFileSync(wfile, JSON.stringify(wjson, null, 1)); try { fs.mkdirSync(EPOCH_OUT, { recursive: true }); fs.copyFileSync(wfile, path.join(EPOCH_OUT, "wrappers.json")); } catch { /* the copy is a convenience */ }
    const gen = (cacheDir, outDir) => run("node", [path.join(PROJ, "tools/dlmm-rewards-root.mjs"), "--local-rpc", RPC, "--cache-dir", cacheDir, "--out-dir", outDir, "--epoch-id", "0", "--scan-from", SCAN_FROM,
      "--first-epoch", "--to-harvest", harvest.tx, "--chunk", CHUNK, "--sleep-ms", SLEEP_MS, "--wrappers", wfile], {}, PROJ, (Number(E.REH_GEN_TIMEOUT_MS) || 150 * 60 * 1000));
    const dir0 = path.join(SCRATCH, "epoch0"), dir0b = path.join(SCRATCH, "epoch0-recompute");
    const tg = Date.now(); const g1 = await gen(path.join(SCRATCH, "cache1"), dir0);
    log(`   generator: exit ${g1.code} in ${((Date.now() - tg) / 1000).toFixed(0)} s`);
    console.log(g1.out.split("\n").filter((l) => /^epoch |^root|^leaves|^stays|^checks|^dataHash|^publishEpoch|scan complete|LOCAL ANVIL|ERROR|wrapper/.test(l)).map((l) => "   | " + l.slice(0, 400)).join("\n"));
    const manifestPath = path.join(dir0, "manifest.json"), epochPath = path.join(dir0, "epoch.json");
    const okGen = g1.code === 0 && fs.existsSync(epochPath) && fs.existsSync(manifestPath);
    check("B11.p07", okGen, okGen ? "the generator exited 0 against the local anvil with --wrappers and wrote epoch.json + manifest.json (manifest.rehearsalEndpoint marks it as a rehearsal output)" : `the generator FAILED (exit ${g1.code}): ${tail(g1.out)}${/negative balance|misses earlier history/.test(g1.out) ? " -- REH_SCAN_FROM is later than the vault's first share mint: use an earlier block" : ""}`);
    if (!okGen) throw new Error("the generator failed: " + tail(g1.out));
    const epoch = JSON.parse(fs.readFileSync(epochPath, "utf8")), manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
    try { const keep = path.join(EPOCH_OUT, "epoch-rehearsal-NOT-PUBLISHABLE"); fs.mkdirSync(keep, { recursive: true }); fs.copyFileSync(epochPath, path.join(keep, "epoch.json")); fs.copyFileSync(manifestPath, path.join(keep, "manifest.json")); } catch { /* convenience */ }
    const inp = epoch.inputs;
    check("B11.p08", manifest.rehearsalEndpoint === "local-anvil" && inp.epochId === 0 && inp.firstEpoch === true && inp.startBlock === FIRST_START_BLOCK && inp.endBlock === harvest.block && inp.userBps === 9000
      && inp.harvest.transactions.some((h) => lc(h.txHash) === lc(harvest.tx)) && BN(inp.harvest.sum).gte(harvest.amount) && inp.scanFromBlock === Number(SCAN_FROM),
      `first-epoch parameters: epoch 0, start ${inp.startBlock}, end ${inp.endBlock} = the fork harvest block, user-bps ${inp.userBps}, ${inp.harvest.count} harvest(s) summing ${inp.harvest.sum} wei (the fork's own: ${harvest.amount}), scan-from ${inp.scanFromBlock}`);
    check("B11.p09", Object.values(epoch.checks).every((v) => v === true), `every generator check is true (${Object.keys(epoch.checks).join(", ")})`);
    const exByAddr = new Map(epoch.exclusions.list.map((e) => [lc(e.address), e])), leafByAddr = new Map(epoch.leaves.map((l) => [lc(l.account), l]));
    const dead = exByAddr.get(lc(DEAD));
    check("B11.p10", dead?.reason === "dead-seed" && BN(dead.returnedToSafe).gt(0) && !leafByAddr.has(lc(DEAD)), `the dead seed is excluded (reason ${dead?.reason}), its slice ${dead?.returnedToSafe} wei stays with the Safe, and it has no leaf`);
    const cx = exByAddr.get(lc(contractHolder));
    check("B11.p11", cx?.reason === "contract" && BN(cx.returnedToSafe).gt(0) && !leafByAddr.has(lc(contractHolder)), `the contract holder ${contractHolder} is excluded (reason ${cx?.reason}), its slice ${cx?.returnedToSafe} wei stays with the Safe, and it has no leaf`);
    const pool = BN(epoch.totals.pool), totalWeight = BN(epoch.totals.totalWeight);
    const rowOk = (a) => { const h = epoch.holders.find((x) => lc(x.address) === lc(a)); const l = leafByAddr.get(lc(a)); return !!h && !!l && l.amount === pool.mul(h.weight).div(totalWeight).toString() && BN(l.amount).gt(0); };
    const ledgerLeaf = leafByAddr.get(lc(LEDGER)), bobLeaf = leafByAddr.get(lc(bob));
    check("B11.p12", rowOk(LEDGER) && rowOk(bob), `the Ledger (${ledgerLeaf?.amount}) and Bob (${bobLeaf?.amount}) have leaves equal to floor(pool * weight / totalWeight) recomputed here from epoch.json (pool ${pool}, totalWeight ${totalWeight}); ${epoch.leaves.length} leaves in all`);
    const t = epoch.totals;
    check("B11.p13", BN(t.publishTotal).add(t.stayWithSafe.excludedHoldersSlice).add(t.stayWithSafe.roundingAndDust).add(t.stayWithSafe.safeShareOfBps).eq(inp.pharTotal) && epoch.leaves.reduce((a, l) => a.add(l.amount), BN(0)).eq(t.publishTotal),
      `partition of ${inp.pharTotal} wei: publish ${t.publishTotal} + excluded ${t.stayWithSafe.excludedHoldersSlice} + rounding ${t.stayWithSafe.roundingAndDust} + the 10 % part ${t.stayWithSafe.safeShareOfBps}; the leaves add up to the publish total`);
    if (RERUN) {
      const g2 = await gen(path.join(SCRATCH, "cache2"), dir0b);
      const same = g2.code === 0 && fs.existsSync(path.join(dir0b, "epoch.json")) && sha256File(path.join(dir0b, "epoch.json")) === sha256File(epochPath);
      const m2 = same ? JSON.parse(fs.readFileSync(path.join(dir0b, "manifest.json"), "utf8")) : null;
      check("B11.p14", same && m2.dataHash === manifest.dataHash && m2.root === manifest.root, same ? `second run from a FRESH cache: byte-identical epoch.json (sha256 ${sha256File(epochPath).slice(0, 16)}...), dataHash ${manifest.dataHash}, root ${manifest.root}` : `the second run DIFFERS or failed (exit ${g2.code}): ${tail(g2.out)}`);
    } else note("B11.p14", "the determinism re-run was skipped (REH_RERUN=0)");
    const pa = manifest.publishEpochArguments;

    // ---- w02..w05: the wrapper split in epoch.json against the harness's own expectation (events up to the harvest block, from the local chain's logs; the harness knows no generator code)
    const evAll = (await modelEvents(harvest.block)), endTs = await tsOfBlock(harvest.block), exp = expectedSplit(evAll, endTs);
    const rep0 = (epoch.wrappers ?? []).find((x) => lc(x.pToken) === lc(D.PBP));
    check("B11.w02", !!rep0 && epoch.generator.version === "2.1.0" && inp.wrappers?.length === 1 && lc(inp.wrappers[0].pToken) === lc(D.PBP) && manifest.wrapperCount === 1 && inp.wrappers[0].fromBlock === wjson.wrappers[0].fromBlock
      && epoch.checks.wrapperSplitSumsToPTokenHolding === true && epoch.checks.seedExcluded === true && epoch.checks.wrapperHoldersHaveNoLeaf === true,
      `epoch.json carries the wrapper config (THIS run's market ${D.PBP}, from block ${wjson.wrappers[0].fromBlock}) and report (generator ${epoch.generator.version}, ${inp.wrappers?.length} wrapper(s)) and the checks wrapperSplitSumsToPTokenHolding, seedExcluded, wrapperHoldersHaveNoLeaf are true`);
    const sup = new Map((rep0?.suppliers ?? []).map((x) => [lc(x.address), x]));
    const sameW = (a) => (sup.get(lc(a))?.weight ?? "0") === (exp.weights.get(lc(a)) ?? 0n).toString();
    const everyone = [...new Set([...holders0, lc(carol), lc(bob), lc(LEDGER), lc(DEAD)])];
    check("B11.w03", !!rep0 && everyone.every(sameW) && rep0.vaultShareSeconds === exp.vSeconds.toString() && rep0.roundingWeight === exp.rounding.toString() && rep0.noSupplierWeight === exp.noSupplier.toString()
      && BN(rep0.suppliersWeight).add(rep0.returnedToSafeWeight).eq(rep0.vaultShareSeconds),
      `supplier weights equal the harness's own expectation for all ${everyone.length} suppliers (Ledger ${sup.get(lc(LEDGER))?.weight}, Bob ${sup.get(lc(bob))?.weight}, Carol ${sup.get(lc(carol))?.weight}, dead seed ${sup.get(lc(DEAD))?.weight}); integral of the shares in the market ${rep0?.vaultShareSeconds}, rounding ${rep0?.roundingWeight}, no-supplier ${rep0?.noSupplierWeight}`);
    const wRow = epoch.holders.find((h) => lc(h.address) === lc(D.PBP));
    check("B11.w04", (BN(rep0?.returnedToSafeWeight ?? 0).isZero() ? !wRow : wRow?.excludedReason === "wrapper-residual" && wRow.weight === rep0.returnedToSafeWeight) && !leafByAddr.has(lc(D.PBP)) && dead?.reason === "dead-seed"
      && BN(rep0?.deadSeed.weight ?? 0).gt(0) && epoch.holders.find((h) => lc(h.address) === lc(DEAD))?.wrapperWeight === rep0?.deadSeed.weight && !leafByAddr.has(lc(DEAD)),
      `the market itself has no leaf and only its residual (${rep0?.returnedToSafeWeight}) as an excluded row; the seed's pTokens at the dead address earned ${rep0?.deadSeed.weight} share-seconds that stay with the Safe (dead-seed, no leaf)`);
    const carolLeaf = leafByAddr.get(lc(carol));
    const hr2 = (a) => epoch.holders.find((h) => lc(h.address) === lc(a));
    const sumsOk = [LEDGER, bob, carol].every((a) => hr2(a) && BN(hr2(a).weight).eq(BN(hr2(a).directWeight).add(hr2(a).wrapperWeight)) && hr2(a).wrapperWeight === (exp.weights.get(lc(a)) ?? 0n).toString());
    check("B11.w05", sumsOk && !!carolLeaf && carolLeaf.amount === pool.mul(hr2(carol).weight).div(totalWeight).toString() && BN(carolLeaf.amount).gt(0),
      `the Ledger and Bob (direct holders AND suppliers) have weight = direct + wrapper; Carol (a pure supplier of the REAL market: her only direct weight is ${hr2(carol)?.directWeight} share-seconds between receiving the shares and supplying them) has a leaf of ${carolLeaf?.amount} wei = floor(pool * weight / totalWeight), almost all of it from her pToken balance`);

    // ------------------------------------------------------------------ the distributor: deploy with the rewards project's own tool (a fresh throwaway deployer), verify
    const addrFile = path.join(SCRATCH, "dlmm-rewards-addresses.rehearsal.env");
    const cenv = { DEPLOYER: deployer, DLMM_REWARDS_ADDRESSES_FILE: addrFile, FOUNDRY_BROADCAST: path.join(SCRATCH, "broadcast"), FOUNDRY_CACHE_PATH: path.join(SCRATCH, "forge-cache"), FOUNDRY_OUT: path.join(SCRATCH, "forge-out") };
    const nonceBefore = await provider.getTransactionCount(deployer);
    const ce = await run("bash", ["tools/dlmm-rewards-ceremony.sh", "check-env", "rehearsal"], cenv);
    if (ce.code !== 0) throw new Error("check-env failed: " + tail(ce.out));
    const dd = await run("bash", ["tools/dlmm-rewards-ceremony.sh", "deploy", "rehearsal"], cenv);
    console.log(dd.out.split("\n").filter((l) => /PHAR_DISTRIBUTOR|== DEPLOYED|addresses written|values found|^Error:|reverted|preflight:|ONCHAIN EXECUTION/.test(l)).map((l) => "   | " + l.slice(0, 300)).join("\n"));
    if (dd.code !== 0) throw new Error("distributor deploy failed: " + tail(dd.out));
    const dm = fs.readFileSync(addrFile, "utf8").match(/PHAR_DISTRIBUTOR=(0x[0-9a-fA-F]{40})/);
    if (!dm) throw new Error("no PHAR_DISTRIBUTOR in the addresses file");
    const dist = utils.getAddress(dm[1]);
    const Dc = (who) => C(dist, DIST_ABI, who), Dv = C(dist, DIST_ABI);
    const nonceAfter = await provider.getTransactionCount(deployer);
    check("B11.p15", (await provider.getCode(dist)).length > 2 && nonceBefore === 0 && nonceAfter === 1, `distributor deployed at ${dist} in ONE transaction by the fresh deployer ${deployer} (nonce ${nonceBefore} -> ${nonceAfter}); runtime codehash ${utils.keccak256(await provider.getCode(dist))} (the live deployment with the same constructor arguments must show the same codehash)`);
    const vr = await run("bash", ["tools/dlmm-rewards-ceremony.sh", "verify", "rehearsal"], { ...cenv, DISTRIBUTOR: dist, EXPECT_OWNER_SAFE: "true", EXPECT_DELAY: String(CLAIM_DELAY), EXPECT_DEADLINE: String(CLAIM_DEADLINE) });
    check("B11.p16", vr.code === 0 && lc(await Dv.owner()) === lc(SAFE) && lc(await Dv.owner()) !== lc(deployer) && (await Dv.pendingOwner()) === ZERO && lc(await Dv.PHAR()) === lc(LIVE.PHAR) && (await Dv.CLAIM_DELAY()).eq(CLAIM_DELAY) && (await Dv.CLAIM_DEADLINE()).eq(CLAIM_DEADLINE) && (await Dv.epochCount()).isZero(),
      `read-back: owner = the Safe (not the deployer), pendingOwner 0, PHAR, CLAIM_DELAY ${CLAIM_DELAY}, CLAIM_DEADLINE ${CLAIM_DEADLINE}, epochCount 0 (verify exit ${vr.code})`);

    // ------------------------------------------------------------------ Safe approve + publishEpoch with the manifest's exact arguments (the rewards project's Safe tool, SEND_MODE=unlocked)
    const sc = (args, extra = {}) => run("bash", ["tools/dlmm-rewards-safe-call.sh", ...args], { DIST: dist, SEND_MODE: "unlocked", ...extra });
    const safeBeforeApprove = await phar.balanceOf(SAFE);
    const big = await sc(["simulate", "approve", "1" + "0".repeat(31)]);
    const ap = await sc(["send", "approve", pa.total]);
    const allowance = await phar.allowance(SAFE, dist);
    check("B11.p17", big.code !== 0 && /refusing an approval above/.test(big.out) && ap.code === 0 && allowance.eq(pa.total), `the Safe approved EXACTLY ${pa.total} wei to the distributor (a 10^31 approval was refused by the tool); allowance ${allowance}`);
    const pubArgs = ["publish", pa.root, pa.total, String(pa.fromBlock), String(pa.toBlock), pa.dataHash];
    const wrongId = await sc(["simulate", ...pubArgs], { EXPECT_EPOCH_ID: "5" }), pubSim = await sc(["simulate", ...pubArgs], { EXPECT_EPOCH_ID: "0" });
    const pub = await sc(["send", ...pubArgs], { EXPECT_EPOCH_ID: "0" });
    console.log(pub.out.split("\n").filter((l) => /^PUBLISH|DECODED|SIMULATION|ABOUT|^after|refus|FAILED/.test(l)).map((l) => "   | " + l.slice(0, 300)).join("\n"));
    const ei0 = await Dv.epochInfo(0);
    const pubEvs = await provider.getLogs({ address: dist, topics: [utils.id("EpochPublished(uint256,bytes32,uint256,uint64,uint64,bytes32,uint256,uint256,uint256)"), utils.hexZeroPad("0x00", 32)], fromBlock: startBlock, toBlock: "latest" });
    const distPhar = await phar.balanceOf(dist);
    check("B11.p18", wrongId.code !== 0 && pubSim.code === 0 && pub.code === 0 && (await Dv.epochCount()).eq(1) && ei0.status === STATUS.Open && ei0.root === pa.root && ei0.total.eq(pa.total) && ei0.fromBlock.eq(pa.fromBlock) && ei0.toBlock.eq(pa.toBlock)
      && ei0.dataHash === pa.dataHash && ei0.claimOpensAt.sub(ei0.publishedAt).eq(CLAIM_DELAY) && ei0.claimDeadline.sub(ei0.publishedAt).eq(CLAIM_DEADLINE) && distPhar.eq(pa.total) && (await phar.allowance(SAFE, dist)).isZero() && pubEvs.length === 1 && safeBeforeApprove.sub(await phar.balanceOf(SAFE)).eq(pa.total),
      `epoch 0 published: status Open, root/total/from/to/dataHash equal the manifest's publishEpochArguments, claim opens at publish + ${CLAIM_DELAY}, deadline + ${CLAIM_DEADLINE}; the distributor holds ${distPhar} PHAR, allowance back to 0, EpochPublished logged; a wrong EXPECT_EPOCH_ID was refused by the tool`);
    const again = await sc(["simulate", ...pubArgs], { EXPECT_EPOCH_ID: "0" });
    note("B11.n2", `a second publish of the same id is refused by the tool (epochCount is 1): exit ${again.code}: ${tail(again.out, 160)}`);

    // ------------------------------------------------------------------ claims refused inside the 24 h window
    const early = await expectRevert(() => Dc(LEDGER).callStatic.claim(0, LEDGER, ledgerLeaf.amount, ledgerLeaf.proof));
    check("B11.p19", /^ClaimsNotOpen\(/.test(early ?? "") && !(await Dv.isClaimWindowOpen(0)) && (await Dv.verifyLeaf(0, LEDGER, ledgerLeaf.amount, ledgerLeaf.proof)), `a claim inside the 24 h window is refused: ${early}; isClaimWindowOpen false; the Ledger's proof does verify against the on-chain root (verifyLeaf true)`);

    // ------------------------------------------------------------------ the cancel path on a second published (test) epoch
    const safeBeforeTest = await phar.balanceOf(SAFE);
    const testRoot = utils.id("rehearsal-test-epoch-root"), testHash = utils.id("rehearsal-test-epoch-data");
    const ap1 = await sc(["send", "approve", "1"]);
    const pub1 = await sc(["send", "publish", testRoot, "1", String(pa.fromBlock), String(pa.toBlock), testHash], { EXPECT_EPOCH_ID: "1" });
    const ei1 = await Dv.epochInfo(1);
    check("B11.p20", ap1.code === 0 && pub1.code === 0 && (await Dv.epochCount()).eq(2) && ei1.status === STATUS.Open && ei1.total.eq(1) && (await phar.balanceOf(dist)).eq(BN(pa.total).add(1)), `a second epoch (id 1, 1 wei, a test root) is published; the distributor holds ${await phar.balanceOf(dist)} PHAR`);
    const notOwner = await expectRevert(() => Dc(stranger).callStatic.cancelEpoch(1));
    const can = await sc(["send", "cancel", "1"]);
    const ei1b = await Dv.epochInfo(1);
    const cancelledClaim = await expectRevert(() => Dc(stranger).callStatic.claim(1, LEDGER, 1, []));
    check("B11.p21", /^OwnableUnauthorizedAccount\(/.test(notOwner ?? "") && can.code === 0 && ei1b.status === STATUS.Cancelled && (await phar.balanceOf(SAFE)).eq(safeBeforeTest) && (await phar.balanceOf(dist)).eq(pa.total) && (await Dv.epochCount()).eq(2) && /^EpochNotOpen\(/.test(cancelledClaim ?? ""),
      `cancel inside the window: a non-owner is refused (${notOwner}); the Safe's cancel (tool) set status Cancelled, refunded the 1 wei (Safe PHAR back to ${safeBeforeTest}), epochCount stays 2 (id 1 is burnt); a claim on it is refused: ${cancelledClaim}`);

    // ------------------------------------------------------------------ 24 h + 1 s, claims
    await warp(CLAIM_DELAY + 1);
    const lateCancel = await sc(["simulate", "cancel", "0"]), lateCancelC = await expectRevert(() => Dc(SAFE).callStatic.cancelEpoch(0));
    check("B11.p22", (await Dv.isClaimWindowOpen(0)) && lateCancel.code !== 0 && /challenge window of epoch 0 is over/.test(lateCancel.out) && /^WindowOver\(\)/.test(lateCancelC ?? ""),
      `after the 24 h window: isClaimWindowOpen true; cancel is refused by the tool ("challenge window ... is over") and by the contract (${lateCancelC})`);
    const bal = (a) => phar.balanceOf(a);
    const wrongAmt = await expectRevert(() => Dc(stranger).callStatic.claim(0, LEDGER, BN(ledgerLeaf.amount).add(1), ledgerLeaf.proof));
    const othersProof = await expectRevert(() => Dc(stranger).callStatic.claim(0, bob, bobLeaf.amount, ledgerLeaf.proof));
    check("B11.p23", wrongAmt === "InvalidProof()" && othersProof === "InvalidProof()" && !(await Dv.verifyLeaf(0, LEDGER, BN(ledgerLeaf.amount).add(1), ledgerLeaf.proof)),
      `a changed amount (${wrongAmt}) and another holder's proof (${othersProof}) are refused; verifyLeaf is false for the changed amount`);
    const ledgerBefore = await bal(LEDGER);
    const rc1 = await tx("Ledger claims", (o) => Dc(LEDGER).claim(0, LEDGER, ledgerLeaf.amount, ledgerLeaf.proof, o));
    const claimedEv = rc1.logs.map((l) => { try { return Dv.interface.parseLog(l); } catch { return null; } }).find((e) => e?.name === "Claimed");
    check("B11.p24", (await bal(LEDGER)).sub(ledgerBefore).toString() === ledgerLeaf.amount && lc(claimedEv?.args[1]) === lc(LEDGER) && claimedEv.args[2].toString() === ledgerLeaf.amount && (await Dv.isClaimed(0, LEDGER)),
      `the Ledger claimed with the proof from epoch.json: PHAR received ${(await bal(LEDGER)).sub(ledgerBefore)} = epoch.json amount ${ledgerLeaf.amount}; Claimed logged; isClaimed true (claim gas ${rc1.gasUsed})`);
    const dbl = await expectRevert(() => Dc(LEDGER).callStatic.claim(0, LEDGER, ledgerLeaf.amount, ledgerLeaf.proof));
    check("B11.p25", dbl === "AlreadyClaimed()", `a double claim is refused: ${dbl}`);
    const bobBefore = await bal(bob), strangerBefore = await bal(stranger);
    await tx("a stranger submits Bob's claim", (o) => Dc(stranger).claim(0, bob, bobLeaf.amount, bobLeaf.proof, o));
    check("B11.p26", (await bal(bob)).sub(bobBefore).toString() === bobLeaf.amount && (await bal(stranger)).eq(strangerBefore), `Bob's claim submitted by a STRANGER paid Bob ${bobLeaf.amount} and the stranger nothing`);
    const deadClaim = await expectRevert(() => Dc(stranger).callStatic.claim(0, DEAD, dead.returnedToSafe, []));
    const contractClaim = await expectRevert(() => Dc(stranger).callStatic.claim(0, contractHolder, cx.returnedToSafe, []));
    const borrowed = await expectRevert(() => Dc(stranger).callStatic.claim(0, contractHolder, cx.returnedToSafe, bobLeaf.proof));
    check("B11.p27", deadClaim === "InvalidProof()" && contractClaim === "InvalidProof()" && borrowed === "InvalidProof()",
      `the dead seed (${deadClaim}) and the contract holder (${contractClaim}; with a borrowed proof ${borrowed}) cannot claim their slices even with the amount from epoch.json: those slices were never published`);
    let claimedSoFar = BN(ledgerLeaf.amount).add(bobLeaf.amount);
    const ei0c = await Dv.epochInfo(0), safeNow = await phar.balanceOf(SAFE), excludedTotal = BN(t.stayWithSafe.excludedHoldersSlice);
    check("B11.p28", ei0c.claimed.eq(claimedSoFar) && (await phar.balanceOf(dist)).eq(BN(pa.total).sub(claimedSoFar)) && safeBeforeApprove.sub(safeNow).eq(pa.total) && excludedTotal.gt(0),
      `accounting: claimed ${ei0c.claimed} of ${pa.total}; the distributor holds ${await phar.balanceOf(dist)}; the Safe paid only the publish total ${pa.total} (Safe PHAR ${safeBeforeApprove} -> ${safeNow}): the excluded slices (${excludedTotal} wei), the 10 % part and the rounding never left it`);
    // w06: a supplier of the REAL market claims from the SAME distributor
    const carolBefore = await bal(carol);
    const rcC = await tx("a stranger submits Carol's claim", (o) => Dc(stranger).claim(0, carol, carolLeaf.amount, carolLeaf.proof, o));
    claimedSoFar = claimedSoFar.add(carolLeaf.amount);
    check("B11.w06", (await bal(carol)).sub(carolBefore).toString() === carolLeaf.amount && (await Dv.isClaimed(0, carol)) && (await Dv.epochInfo(0)).claimed.eq(claimedSoFar),
      `Carol, who holds only pTokens of the bpPHAR-USDC market, claimed ${carolLeaf.amount} wei of PHAR to HER address (the one she supplied from) with a proof from epoch.json, submitted by a stranger (claim gas ${rcC.gasUsed})`);

    // ------------------------------------------------------------------ sweep refused before the deadline, then after it
    const sweepTool = await sc(["simulate", "sweep", "0"]), sweepC = await expectRevert(() => Dc(SAFE).callStatic.sweepUnclaimed(0));
    check("B11.p29", sweepTool.code !== 0 && /sweep is not possible yet/.test(sweepTool.out) && /^DeadlineNotReached\(/.test(sweepC ?? ""), `sweep before publishedAt + 180 days is refused by the tool and by the contract (${sweepC})`);
    await warp(CLAIM_DEADLINE);
    const claimedAddrs = [LEDGER, bob, carol].map(lc);
    const leftover = [...leafByAddr.values()].find((l) => !claimedAddrs.includes(lc(l.account)));
    const lateClaim = await expectRevert(() => Dc(stranger).callStatic.claim(0, leftover ? leftover.account : LEDGER, leftover ? leftover.amount : ledgerLeaf.amount, leftover ? leftover.proof : ledgerLeaf.proof));
    check("B11.p30", /^ClaimsClosed\(/.test(lateClaim ?? "") || (!leftover && lateClaim === "AlreadyClaimed()"), `after the deadline a claim is refused: ${lateClaim} (${leftover ? "an unclaimed leaf of " + leftover.account : "every leaf was claimed: the already-claimed check comes first"}); isClaimWindowOpen ${await Dv.isClaimWindowOpen(0)}`);
    const safeBeforeSweep = await phar.balanceOf(SAFE);
    const sw = await sc(["send", "sweep", "0"]);
    const ei0s = await Dv.epochInfo(0), expectedSweep = BN(pa.total).sub(claimedSoFar);
    check("B11.p31", sw.code === 0 && ei0s.status === STATUS.Swept && (await phar.balanceOf(SAFE)).sub(safeBeforeSweep).eq(expectedSweep) && (await phar.balanceOf(dist)).isZero(),
      `the sweep returned ${expectedSweep} wei (total - claimed) to the Safe, status Swept, the distributor holds ${await phar.balanceOf(dist)} PHAR`);
    const sw2 = await expectRevert(() => Dc(SAFE).callStatic.sweepUnclaimed(0));
    check("B11.p32", /^EpochNotOpen\(/.test(sw2 ?? "") && (await phar.balanceOf(dist)).isZero(), `a second sweep is refused (${sw2}); nothing is stranded in the distributor (PHAR balance ${await phar.balanceOf(dist)})`);
    note("B11.n3", `PHAR step finished in ${((Date.now() - t00) / 1000).toFixed(0)} s (generator run 1: ${((Date.now() - tg) / 1000).toFixed(0)} s incl. later steps); the epoch files of this rehearsal are in ${path.join(EPOCH_OUT, "epoch-rehearsal-NOT-PUBLISHABLE")} and are NOT publishable`);
  }, { timeoutMs: (Number(E.REH_PHAR_TIMEOUT_MS) || 4 * 3600 * 1000) });   // the generator's log scan and the forge compile are long: this group gets 4 h, the others REH_GROUP_TIMEOUT_MS (20 min)
}

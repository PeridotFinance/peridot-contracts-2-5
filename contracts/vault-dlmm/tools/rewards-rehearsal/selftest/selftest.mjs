// SELF-TEST of the rehearsal scripts WITHOUT any endpoint: a non-fork local anvil of chain 43114 whose genesis block number is 100488300, with test doubles (src/Mocks.sol) put at the
// REAL addresses of the Safe, the vault, PHAR and the rewarder, then the whole of rehearsal.mjs (the generator's live RpcSource path via --local-rpc, tools/dlmm-harvest.sh and
// dlmm-safe-call.sh of the integration worktree, tools/dlmm-rewards-ceremony.sh with forge script, tools/dlmm-rewards-safe-call.sh, the distributor contract) runs against it.
// What this proves: the scripts' logic, argument passing, parsing and every assertion. What it cannot prove: the real vault's, rewarder's and Safe's behaviour (the real run does), the
// proxy / fork / lock / argv-check wrapper (rehearsal.sh), the public endpoint's behaviour.
//   run from contracts/vault-dlmm:   node tools/rewards-rehearsal/selftest/selftest.mjs        (needs anvil, forge, cast; ETHERS_DIR or ../../dlmm-keeper/node_modules)
import { spawn, spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PROJ = path.resolve(HERE, "../../..");
const REH = path.join(HERE, "..");
const INT_TOOLS = process.env.REH_INT_TOOLS || "/Users/joshua/Peridot/.wt-dlmm-int/contracts/vault-dlmm/tools";
const ETHERS_DIR = process.env.ETHERS_DIR || [path.join(PROJ, "../../dlmm-keeper/node_modules/ethers"), "/Users/joshua/Peridot/.wt-dlmm-keeper/dlmm-keeper/node_modules/ethers"].find((p) => fs.existsSync(p));
if (!ETHERS_DIR) { console.error("ethers v5 not found (ETHERS_DIR)"); process.exit(2); }
const { ethers } = createRequire(import.meta.url)(ETHERS_DIR);
const { utils, providers } = ethers;
const N0 = 100488300; // genesis block number: below the first epoch's start block 100488395
const A = {
  SAFE: "0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12", LEDGER: "0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD", VAULT: "0x278B1b625C74B1926C5F989ddE601f3C5Ba27f7D",
  PHAR: "0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7", REWARDER: "0x32E68C4b8Edc6d1F16E99EbA826B292FDC18daDC", DEAD: "0x000000000000000000000000000000000000dEaD", KEEPER: "0xCf8387DE198413347BA4EEB2E7d3Bcc1fE3705d2",
};
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "rewards-selftest-"));
let anvil;
const free = () => new Promise((res) => { const s = net.createServer(); s.listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => res(p)); }); });
const cleanup = () => { try { anvil?.kill("SIGKILL"); } catch { /* */ } try { fs.rmSync(scratch, { recursive: true, force: true }); } catch { /* */ } };
process.on("exit", cleanup);

async function main() {
  // 1. compile the doubles (own project, outputs in the scratch dir)
  const out = path.join(scratch, "out");
  const b = spawnSync("forge", ["build", "--root", HERE], { encoding: "utf8", env: { ...process.env, FOUNDRY_OUT: out, FOUNDRY_CACHE_PATH: path.join(scratch, "cache") } });
  if (b.status !== 0) throw new Error("forge build of the doubles failed: " + (b.stdout + b.stderr).slice(-600));
  const art = (n) => { const j = JSON.parse(fs.readFileSync(path.join(out, "Mocks.sol", `${n}.json`), "utf8")); return { abi: j.abi, bytecode: j.bytecode.object, runtime: j.deployedBytecode.object }; };
  // 2. anvil with a genesis block number
  const genesis = { config: { chainId: 43114, homesteadBlock: 0, eip150Block: 0, eip155Block: 0, eip158Block: 0, byzantiumBlock: 0, constantinopleBlock: 0, petersburgBlock: 0, istanbulBlock: 0, berlinBlock: 0, londonBlock: 0 },
    nonce: "0x0", timestamp: "0x" + (Math.floor(Date.now() / 1000) - 86400 * 3).toString(16), extraData: "0x", gasLimit: "0x1c9c380", difficulty: "0x0", mixHash: "0x" + "00".repeat(32), coinbase: "0x" + "00".repeat(20), number: "0x" + N0.toString(16), alloc: {} };
  fs.writeFileSync(path.join(scratch, "genesis.json"), JSON.stringify(genesis));
  const port = await free();
  anvil = spawn("anvil", ["--init", path.join(scratch, "genesis.json"), "--silent", "--port", String(port), "--host", "127.0.0.1"], { stdio: "ignore" });
  const RPC = `http://127.0.0.1:${port}`;
  const provider = new providers.StaticJsonRpcProvider(RPC, { chainId: 43114, name: "avalanche" });
  provider.pollingInterval = 100;
  for (let i = 0; i < 100; i++) { try { await provider.send("eth_chainId", []); break; } catch { await new Promise((r) => setTimeout(r, 100)); } }
  const rpc = (m, p = []) => provider.send(m, p);
  if ((await provider.getBlockNumber()) !== N0) throw new Error("anvil did not start at the genesis block number " + N0 + ": " + (await provider.getBlockNumber()));
  // 3. the doubles at the real addresses
  const deployerAddr = ethers.Wallet.createRandom().address;
  await rpc("anvil_impersonateAccount", [deployerAddr]); await rpc("anvil_setBalance", [deployerAddr, "0x56BC75E2D63100000"]);
  const deployer = provider.getSigner(deployerAddr);
  const place = async (name, addr) => { const a = art(name); const c = await new ethers.ContractFactory(a.abi, a.bytecode, deployer).deploy(); await c.deployed(); await rpc("anvil_setCode", [addr, await provider.getCode(c.address)]); return new ethers.Contract(addr, a.abi, deployer); };
  await place("MockSafe", A.SAFE); await place("MockPhar", A.PHAR); await place("MockRewarder", A.REWARDER);
  const vault = await place("MockVault", A.VAULT);
  await (await vault.init(A.KEEPER)).wait();
  const alice = ethers.Wallet.createRandom().address;
  await (await vault.mintTo(A.DEAD, 1_000_000)).wait();      // the seed
  await (await vault.mintTo(A.LEDGER, 199_000_000)).wait();  // the Ledger's holding
  await (await vault.mintTo(alice, 50_000_000)).wait();      // another depositor who will never claim (the sweep has something to return)
  const CONTROL = process.env.SELFTEST_CONTROL || ""; // "" = the normal run; "no-accrual" = the vault pays nothing (expect exit 43); "no-harvest" = the harvest tool does nothing (expect exit 2)
  if (CONTROL === "no-accrual") await (await vault.setRate(0)).wait();
  await rpc("anvil_mine", ["0x78", "0x2"]);                  // 120 blocks, 2 s apart: the head passes the first epoch's start block 100488395
  const head = await provider.getBlockNumber();
  if (head <= 100488395) throw new Error("head " + head + " is not above the first epoch start block");
  console.log(`selftest: mock world ready at head ${head} (genesis block ${N0}), vault ${A.VAULT}, Safe ${A.SAFE}, alice ${alice} holds 50 shares and never claims`);

  // 4. --dry of the wrapper (inputs only) and its refusals
  const dryOk = spawnSync("bash", [path.join(REH, "rehearsal.sh"), "--dry"], { encoding: "utf8", env: { ...process.env, REH_SCAN_FROM: String(N0), ETHERS_DIR, REH_INT_TOOLS: INT_TOOLS } });
  const dryBad = spawnSync("bash", [path.join(REH, "rehearsal.sh"), "--dry"], { encoding: "utf8", env: { ...process.env, REH_SCAN_FROM: "", ETHERS_DIR, REH_INT_TOOLS: INT_TOOLS } });
  const dryBad2 = spawnSync("bash", [path.join(REH, "rehearsal.sh"), "--dry"], { encoding: "utf8", env: { ...process.env, REH_SCAN_FROM: "100488396", ETHERS_DIR, REH_INT_TOOLS: INT_TOOLS } });
  const dryBad3 = spawnSync("bash", [path.join(REH, "rehearsal.sh"), "--dry"], { encoding: "utf8", env: { ...process.env, REH_SCAN_FROM: String(N0), ETHERS_DIR, REH_INT_TOOLS: "/nonexistent" } });
  const noEndpoint = spawnSync("bash", [path.join(REH, "rehearsal.sh"), path.join(scratch, "o")], { encoding: "utf8", env: { PATH: process.env.PATH, HOME: process.env.HOME, REH_SCAN_FROM: String(N0), ETHERS_DIR } });
  const drySays = (dryOk.stdout + dryOk.stderr);
  const dryChecks = [
    ["--dry with good inputs exits 0 and says so", dryOk.status === 0 && /DRY: all inputs OK/.test(drySays)],
    ["--dry without REH_SCAN_FROM exits 2", dryBad.status === 2 && /REH_SCAN_FROM is not set/.test(dryBad.stdout)],
    ["--dry with REH_SCAN_FROM above the first epoch start exits 2", dryBad2.status === 2 && /outside 100000000/.test(dryBad2.stdout)],
    ["--dry with a missing integration tool directory exits 2", dryBad3.status === 2 && /missing integration tool/.test(dryBad3.stdout)],
    ["a real run without an endpoint exits 2 and starts nothing", noEndpoint.status === 2 && /no endpoint in the environment/.test(noEndpoint.stdout)],
    ["no endpoint value is printed by --dry", !/https?:\/\//.test(drySays.replace(/<url-redacted>/g, ""))],
  ];
  let bad = 0;
  for (const [t, ok] of dryChecks) { console.log(`${ok ? "SELFTEST PASS" : "SELFTEST FAIL"} ${t}`); if (!ok) bad++; }

  if (CONTROL) {
    // NEGATIVE CONTROLS: the rehearsal must stop with its documented exit code and message
    let tools = INT_TOOLS;
    if (CONTROL === "no-harvest") { tools = path.join(scratch, "badtools"); fs.mkdirSync(tools); fs.copyFileSync(path.join(INT_TOOLS, "dlmm-safe-call.sh"), path.join(tools, "dlmm-safe-call.sh")); fs.writeFileSync(path.join(tools, "dlmm-harvest.sh"), "#!/usr/bin/env bash\necho 'harvest tool replaced by a no-op'\nexit 0\n"); }
    fs.mkdirSync(path.join(scratch, "reh"));
    const r = spawnSync("node", [path.join(REH, "rehearsal.mjs")], { encoding: "utf8", env: { PATH: process.env.PATH, HOME: process.env.HOME, ETHERS_DIR, REH_PROJ: PROJ, REH_SCRATCH: path.join(scratch, "reh"), REH_RPC: RPC, REH_RESULTS: path.join(scratch, "r.json"), REH_INT_TOOLS: tools, REH_SCAN_FROM: String(N0), REH_WARP_SECONDS: "86400", REH_CHUNK: "100", REH_SLEEP_MS: "0" } });
    console.log((r.stdout + r.stderr).split("\n").filter((l) => /^(PASS|FAIL|REHEARSAL|FATAL|NO PHAR)/.test(l)).slice(-4).join("\n"));
    const want = CONTROL === "no-accrual" ? 43 : 2;
    console.log(`CONTROL ${CONTROL}: exit ${r.status} (expected ${want}) ${r.status === want ? "OK" : "WRONG"}`);
    return r.status === want ? 0 : 1;
  }
  if (process.env.SELFTEST_WRAPPER === "1") {
    // THE WRAPPER END TO END: rehearsal.sh with the mock world playing the "live chain" upstream (the proxy forwards to it, a second anvil forks the proxy at head-4, the argv check runs, the
    // shared lock is taken and released). Needs the shared fork lock /tmp/pilot-fork.lock to be FREE (it is skipped, not waited for, when another job holds it).
    if (fs.existsSync("/tmp/pilot-fork.lock")) { console.log("SELFTEST SKIP wrapper mode: /tmp/pilot-fork.lock is held by another job"); return 0; }
    const evidence = path.join(scratch, "rel-evidence"); // a RELATIVE out-dir, run from another directory: the wrapper must make it absolute
    const r = spawnSync("bash", [path.join(REH, "rehearsal.sh"), "rel-evidence"], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, cwd: scratch,
      env: { PATH: process.env.PATH, HOME: process.env.HOME, TMPDIR: scratch, AVALANCHE_RPC: RPC, REH_SCAN_FROM: String(N0), ETHERS_DIR, REH_INT_TOOLS: INT_TOOLS, REH_PORT: String(await free()), REH_PROXY_PORT: String(await free()), ...(process.env.SELFTEST_REH_WRAPPER === "1" ? { REH_WRAPPER: "1" } : {}) } });
    const NW = process.env.SELFTEST_REH_WRAPPER === "1" ? 39 : 33;
    const outTxt = r.stdout + r.stderr;
    const argv = (outTxt.match(/argv check: (\d+) of (\d+) processes carry the upstream endpoint/) || [])[1];
    const checks = [
      ["rehearsal.sh exits 0 on the mock world", r.status === 0],
      [`the verdict line is REHEARSAL PASSED: ${NW} checks, 0 failures`, new RegExp(`^REHEARSAL PASSED: ${NW} checks, 0 failures$`, "m").test(outTxt)],
      ["the argv check ran and found 0 processes carrying the upstream", argv === "0"],
      ["the proxy wrote its upstream status counts and saw no 429", /upstream HTTP status counts seen by the proxy: \{"requests":\d+,"errors":0,"upstreamStatus":\{"200":\d+\}\}/.test(outTxt)],
      ["the fork pin is head - 4", /fork pin block: \d+/.test(outTxt)],
      ["the shared lock was released", !fs.existsSync("/tmp/pilot-fork.lock")],
      ["lock-minutes.log has acquire and release lines", /acquire/.test(fs.readFileSync(path.join(evidence, "lock-minutes.log"), "utf8")) && /release/.test(fs.readFileSync(path.join(evidence, "lock-minutes.log"), "utf8"))],
      ["no endpoint string is in the output", !outTxt.replace(/<url-redacted>/g, "").includes(RPC)],
      ["a relative out-dir worked: pin-block.txt, argv-check.txt, upstream-status.json and the log are in it", ["pin-block.txt", "argv-check.txt", "upstream-status.json", "rehearsal-run.log"].every((f) => fs.existsSync(path.join(evidence, f)))],
      ["the scratch dir was removed", fs.readdirSync(scratch).filter((n) => n.startsWith("dlmm-rewards-reh.")).length === 0],
    ];
    for (const [t, ok] of checks) { console.log(`${ok ? "SELFTEST PASS" : "SELFTEST FAIL"} wrapper: ${t}`); if (!ok) bad++; }
    if (bad) console.log(outTxt.split("\n").slice(-25).join("\n"));
    console.log(bad === 0 ? "SELFTEST PASSED (wrapper mode)" : `SELFTEST FAILED (${bad})`);
    return bad === 0 ? 0 : 1;
  }
  // 5. the whole rehearsal against the doubles
  const resultsFile = path.join(scratch, "results.json");
  const keep = path.join(scratch, "evidence"); fs.mkdirSync(keep);
  const env = { PATH: process.env.PATH, HOME: process.env.HOME, ETHERS_DIR, REH_PROJ: PROJ, REH_SCRATCH: path.join(scratch, "reh"), REH_RPC: RPC, REH_RESULTS: resultsFile, REH_INT_TOOLS: INT_TOOLS,
    REH_SCAN_FROM: String(N0), REH_WARP_SECONDS: "86400", REH_CHUNK: "100", REH_SLEEP_MS: "0", REH_EPOCH_OUT: keep, ...(process.env.SELFTEST_REH_WRAPPER === "1" ? { REH_WRAPPER: "1" } : {}) };
  const WRAP = process.env.SELFTEST_REH_WRAPPER === "1"; // the OPTIONAL wrapper step of the rehearsal (REH_WRAPPER=1): 33 + 6 checks (P00..P32, W01..W06)
  const NCHECKS = WRAP ? 39 : 33;
  fs.mkdirSync(env.REH_SCRATCH);
  const lines = [];
  const code = await new Promise((resolve) => {
    const c = spawn("node", [path.join(REH, "rehearsal.mjs")], { env });
    const onData = (d) => { const s = d.toString(); process.stdout.write(s); lines.push(...s.split("\n")); };
    c.stdout.on("data", onData); c.stderr.on("data", onData);
    c.on("close", resolve);
  });
  const txt = lines.join("\n");
  const verdict = lines.filter((l) => /^REHEARSAL (PASSED|FAILED)|^FATAL|^NO PHAR/.test(l)).pop();
  const passLines = lines.filter((l) => /^PASS [PW]\d\d /.test(l)).length;
  const failLines = lines.filter((l) => /^FAIL /.test(l));
  const wholeChecks = [
    ["rehearsal.mjs exits 0", code === 0],
    [`verdict line is 'REHEARSAL PASSED: ${NCHECKS} checks, 0 failures'`, verdict === `REHEARSAL PASSED: ${NCHECKS} checks, 0 failures`],
    [`${NCHECKS} PASS lines (P00..P32${WRAP ? ", W01..W06" : ""}) and no FAIL line`, passLines === NCHECKS && failLines.length === 0],
    ["a RESULTS json line is printed", /^RESULTS \{/m.test(txt)],
    ["results.json was written", fs.existsSync(resultsFile)],
    ["the rehearsal epoch files were copied for inspection, marked NOT-PUBLISHABLE", fs.existsSync(path.join(keep, "epoch-rehearsal-NOT-PUBLISHABLE", "epoch.json"))],
    ["no endpoint appears in the output", !/https?:\/\/(?!<url)/.test(txt.replace(/<url-redacted>/g, ""))],
  ];
  for (const [t, ok] of wholeChecks) { console.log(`${ok ? "SELFTEST PASS" : "SELFTEST FAIL"} ${t}`); if (!ok) bad++; }
  console.log(bad === 0 ? "SELFTEST PASSED" : `SELFTEST FAILED (${bad})`);
  return bad === 0 ? 0 : 1;
}
main().then((c) => process.exit(c), (e) => { console.error("SELFTEST FATAL:", e?.stack || e); process.exit(2); });

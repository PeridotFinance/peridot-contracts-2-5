// FORK RECIPE for the margin 2x stack (for the TP/SL keeper and range take-profit work, and for the operator rehearsals).
// It brings up a LOCAL anvil fork of the current Avalanche head and runs, with accounts IMPERSONATED (nothing real is signed):
//   1. the PW30 lending ceremony (exact wrapper, exact pilot inputs) and its post-deploy steps,
//   2. the margin ceremony stages 1 to 4 (exact wrapper `contracts/tools/avalanche-margin-ceremony.sh`): deploy by a throwaway deployer,
//      wire / execute / enable by the Ledger, with the 24 h timelock crossed by moving the fork clock,
//   3. optionally (--demo-position) one open 2x long for ALICE so that orders have a position to act on.
// The Chainlink AVAX/USD and USDC/USD feeds are replaced on the FORK by settable mocks (the real ones go stale when the clock moves); the
// mock feeds are `set(int256 answer8, uint256 updatedAt)`; the addresses are in the addresses file. The pool, router and tokens are real.
// The private endpoint is read from the ENVIRONMENT and reached through a local pass-through proxy; it is never printed.
//   AVALANCHE_MAINNET_RPC_URL=... node dist/scripts/margin-fork-up.js [--demo-position] [--out margin-fork.json]
// The process keeps the fork (and the proxy) alive until it receives SIGINT/SIGTERM; the file written to --out holds the local RPC URL.
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { BigNumber, Contract, utils } from "ethers";
import { ForkChain, Mocks } from "../test/fork/harness";
import { AVAX_FEED, USDC_FEED } from "../src/constants";
import { safeError } from "../src/mask";

const LEDGER = "0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD";
const WAVAX = "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7";
const USDC = "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E";
const THROWAWAY = "0x000000000000000000000000000000000000DE17";
const OP1 = "0x0000000000000000000000000000000000000A01";
const OP2 = "0x0000000000000000000000000000000000000A02";
const ALICE = "0x000000000000000000000000000000000000A11C";
const TEAM = "0x00000000000000000000000000000000005077E1";
const CONTRACTS = path.join(__dirname, "..", "..", "..", "contracts");
const ABI = path.join(__dirname, "..", "..", "..", "docs", "deployment-handoffs", "avalanche-margin-abi");
const abi = (n: string): any[] => JSON.parse(fs.readFileSync(path.join(ABI, `${n}.json`), "utf8"));
const erc = ["function balanceOf(address) view returns (uint256)", "function approve(address,uint256) returns (bool)"];

function readEnvFile(file: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const l of fs.readFileSync(file, "utf8").split("\n")) {
    const m = l.match(/^export ([A-Z0-9_]+)=(.*)$/);
    if (m) out[m[1]!] = m[2]!.trim();
  }
  return out;
}
// ASYNC on purpose: this process hosts the RPC proxy that the anvil fork (and through it forge) depends on.
function run(script: string, step: string, env: Record<string, string>): Promise<{ status: number; out: string }> {
  return new Promise((resolve) => {
    const child = spawn("bash", [script, step, "rehearsal"], { cwd: CONTRACTS, env: { ...process.env, ...env, AVALANCHE_MAINNET_RPC_URL: "", AVALANCHE_RPC: "" } });
    let out = "";
    child.stdout.on("data", (d) => (out += String(d)));
    child.stderr.on("data", (d) => (out += String(d)));
    child.on("close", (code) => resolve({ status: code ?? 1, out }));
  });
}
const okTx = async (p: Promise<any>) => {
  const r = await (await p).wait();
  if (r.status !== 1) throw new Error("tx failed");
  return r;
};

(async () => {
  const report: Record<string, any> = { startedAt: new Date().toISOString() };
  const demo = process.argv.includes("--demo-position");
  const chain = await ForkChain.start("latest");
  let keepAlive = false;
  try {
    report.forkHead = await chain.provider.getBlockNumber();
    report.rpcLocal = chain.url;
    const pw30 = readEnvFile(path.join(CONTRACTS, "ceremony", "pilot-pw30.env"));
    for (const a of [LEDGER, THROWAWAY, OP1, OP2, ALICE, TEAM]) await chain.setBalance(a, utils.parseEther("1000"));
    await chain.setErc20Balance(WAVAX, LEDGER, BigNumber.from(pw30.LENDING_WAVAX_SEED_AMOUNT));
    await chain.setErc20Balance(USDC, LEDGER, BigNumber.from(pw30.LENDING_USDC_SEED_AMOUNT).add(2_500_000_000).add(250_000_000));

    // ---- 1. PW30
    const env30 = { ...pw30, RPC_LOCAL: chain.url };
    const dep = await run("tools/avalanche-ceremony.sh", "deploy", env30);
    if (dep.status !== 0) throw new Error("PW30 deploy failed:\n" + dep.out.split("\n").slice(-25).join("\n"));
    const grab = (label: string): string => {
      const m = dep.out.match(new RegExp(label + "\\s+(0x[0-9a-fA-F]{40})"));
      if (!m) throw new Error("address not found in the deploy output: " + label);
      return m[1]!;
    };
    const pw = { controller: grab("Unitroller/controller"), oracle: grab("guarded oracle"), pWavax: grab("pWAVAX"), pUsdc: grab("pUSDC") };
    report.pw30 = pw;
    const led = chain.signer(LEDGER);
    const ctrl: any = new Contract(pw.controller, ["function _setCollateralFactor(address,uint256) returns (uint256)", "function _setBorrowPaused(address,bool) returns (bool)"], led);
    await okTx(ctrl._setCollateralFactor(pw.pWavax, utils.parseEther("0.30")));
    await chain.setErc20Balance(USDC, TEAM, BigNumber.from(6_250_000_000));
    await okTx(new Contract(USDC, erc, chain.signer(TEAM)).approve(pw.pUsdc, BigNumber.from(6_250_000_000)));
    await okTx(new Contract(pw.pUsdc, ["function mint(uint256) returns (uint256)"], chain.signer(TEAM)).mint(BigNumber.from(6_250_000_000)));
    await okTx(ctrl._setBorrowPaused(pw.pUsdc, false));

    // ---- 2. margin stages
    const addrFile = path.join(CONTRACTS, "ceremony", "margin-addresses.rehearsal.env");
    const menv: Record<string, string> = {
      MARGIN_DEPLOYER: THROWAWAY, MARGIN_OWNER: LEDGER, CONTROLLER: pw.controller, PWAVAX: pw.pWavax, PUSDC: pw.pUsdc,
      MARGIN_FLASH_SEED_USDC: "2500000000", MARGIN_INSURANCE_SEED_USDC: "250000000", MARGIN_FUNDERS: `${OP1},${OP2}`,
      MARGIN_ACTION_DELAY: "86400", MARGIN_ADDRESSES_FILE: addrFile, RPC_LOCAL: chain.url,
    };
    const M = "tools/avalanche-margin-ceremony.sh";
    const stage = async (step: string, extra: Record<string, string> = {}) => {
      const r = await run(M, step, { ...menv, ...extra });
      if (r.status !== 0) throw new Error(`margin ${step} failed:\n` + r.out.split("\n").slice(-30).join("\n"));
      return r;
    };
    await stage("check-env");
    await stage("deploy");
    const deployed = readEnvFile(addrFile);
    const denv = { ...menv, ...deployed };
    await stage("verify", { ...denv, STAGE: "1" });
    // the feeds become settable mocks BEFORE the clock moves; the answers are the real ones read now
    const realAvax = await new Contract(AVAX_FEED, ["function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)"], chain.provider).latestRoundData();
    const realUsdc = await new Contract(USDC_FEED, ["function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)"], chain.provider).latestRoundData();
    const mocks = new Mocks(chain, LEDGER);
    await mocks.installFeedsOnly();
    const setFeeds = async () => {
      const now = await chain.now();
      await okTx(mocks.feed(AVAX_FEED).set(realAvax[1], now));
      await okTx(mocks.feed(USDC_FEED).set(realUsdc[1], now));
    };
    await setFeeds();
    await stage("wire", denv);
    await stage("verify", { ...denv, STAGE: "2" });
    await chain.increaseTime(86_400 + 60);
    await setFeeds();
    await stage("execute", denv);
    await stage("verify", { ...denv, STAGE: "3" });
    await stage("enable", denv);
    await stage("verify", { ...denv, STAGE: "4" });
    report.margin = deployed;
    report.mockFeeds = { avax: AVAX_FEED, usdc: USDC_FEED, note: "set(int256 answer8, uint256 updatedAt) — keep updatedAt fresh (max age 1200 s for AVAX)", avaxAnswer8: realAvax[1].toString(), usdcAnswer8: realUsdc[1].toString() };
    report.accounts = { ledger: LEDGER, operator1: OP1, operator2: OP2, alice: ALICE, team: TEAM, throwawayDeployer: THROWAWAY, note: "impersonated on the fork: send from any of them without a key" };

    // ---- 3. an open position for ALICE
    if (demo) {
      await chain.setErc20Balance(USDC, ALICE, BigNumber.from(2_500_000_000));
      const alice = chain.signer(ALICE);
      const pUsdc: any = new Contract(pw.pUsdc, ["function mint(uint256) returns (uint256)", "function balanceOf(address) view returns (uint256)", "function approve(address,uint256) returns (bool)", "function exchangeRateCurrent() returns (uint256)"], alice);
      await okTx(new Contract(USDC, erc, alice).approve(pw.pUsdc, BigNumber.from(2_500_000_000)));
      await okTx(pUsdc.mint(BigNumber.from(2_500_000_000)));
      const shares: BigNumber = await pUsdc.balanceOf(ALICE);
      const vault: any = new Contract(deployed.M_VAULT!, abi("IsolatedMarginVault"), alice);
      await okTx(pUsdc.approve(deployed.M_VAULT!, shares));
      await okTx(vault.deposit(pw.pUsdc, shares));
      const rate: BigNumber = await pUsdc.callStatic.exchangeRateCurrent();
      const quoter: any = new Contract(deployed.M_QUOTER!, abi("IsolatedMarginQuoter"), alice);
      const q = await quoter.quoteOpen(pw.pUsdc, pw.pWavax, pw.pUsdc, shares.mul(rate).div(utils.parseEther("1")), 200);
      const exec: any = new Contract(deployed.M_EXECUTOR!, abi("IsolatedMarginExecutor"), alice);
      const next: BigNumber = await exec.nextPositionId();
      await okTx(exec.openPosition({ marginPToken: pw.pUsdc, positionPToken: pw.pWavax, debtPToken: pw.pUsdc, marginPTokenAmount: shares, leverageX100: 200, maxOpeningFeePToken: 0, minPositionUnderlying: q[1], side: 0, swapData: "0x" }, { gasLimit: 6_000_000 }));
      const pos = await exec.positions(next);
      report.demoPosition = { id: next.toString(), owner: pos.owner, account: pos.account, status: pos.status, borrowedPrincipal: pos.borrowedPrincipal.toString() };
    }
    report.ok = true;
    keepAlive = true;
  } catch (e) {
    report.ok = false;
    report.error = safeError(e);
  }
  report.finishedAt = new Date().toISOString();
  const text = JSON.stringify(report, null, 2);
  const outIdx = process.argv.indexOf("--out");
  if (outIdx >= 0) fs.writeFileSync(process.argv[outIdx + 1]!, text + "\n");
  console.log(text);
  if (!keepAlive) {
    await chain.stop();
    process.exit(1);
  }
  console.log("\nfork is up; Ctrl-C to stop");
  const stop = async () => {
    await chain.stop();
    process.exit(0);
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
})();

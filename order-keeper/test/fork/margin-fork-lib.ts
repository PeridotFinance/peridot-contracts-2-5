// COPIED from operator/scripts/margin-fork-lib.ts (the fork recipe of the margin 2x stack), with the addresses file moved out of the repository and the
// imports pointed at this package's harness. Behaviour is unchanged: PW30 ceremony + the four margin stages on a local anvil fork, feeds replaced by mocks.
// SHARED BODY of the margin fork recipe (scripts/margin-fork-up.ts is the CLI over it; scripts/rehearse-margin.ts is the operator rehearsal over it).
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
import os from "node:os";
import path from "node:path";
import { BigNumber, Contract, utils } from "ethers";
import { AVAX_FEED, ForkChain, Mocks, repoRoot, USDC_FEED } from "./harness";

export const LEDGER = "0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD";
export const WAVAX = "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7";
export const USDC = "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E";
export const THROWAWAY = "0x000000000000000000000000000000000000DE17";
export const OP1 = "0x0000000000000000000000000000000000000A01";
export const OP2 = "0x0000000000000000000000000000000000000A02";
export const ALICE = "0x000000000000000000000000000000000000A11C";
export const TEAM = "0x00000000000000000000000000000000005077E1";
export const CONTRACTS = path.join(repoRoot(), "contracts");
const ABI = path.join(repoRoot(), "docs", "deployment-handoffs", "avalanche-margin-abi");
export const abi = (n: string): any[] => JSON.parse(fs.readFileSync(path.join(ABI, `${n}.json`), "utf8"));
export const erc = ["function balanceOf(address) view returns (uint256)", "function approve(address,uint256) returns (bool)"];

export function readEnvFile(file: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const l of fs.readFileSync(file, "utf8").split("\n")) {
    const m = l.match(/^export ([A-Z0-9_]+)=(.*)$/);
    if (m) out[m[1]!] = m[2]!.trim();
  }
  return out;
}
// ASYNC on purpose: this process hosts the RPC proxy that the anvil fork (and through it forge) depends on.
export function run(script: string, step: string, env: Record<string, string>): Promise<{ status: number; out: string }> {
  return new Promise((resolve) => {
    const child = spawn("bash", [script, step, "rehearsal"], { cwd: CONTRACTS, env: { ...process.env, ...env, AVALANCHE_MAINNET_RPC_URL: "", AVALANCHE_RPC: "" } });
    let out = "";
    child.stdout.on("data", (d) => (out += String(d)));
    child.stderr.on("data", (d) => (out += String(d)));
    child.on("close", (code) => resolve({ status: code ?? 1, out }));
  });
}
export const okTx = async (p: Promise<any>) => {
  const r = await (await p).wait();
  if (r.status !== 1) throw new Error("tx failed");
  return r;
};


export interface BringUpOptions {
  demo?: boolean;
  /** the two funded liquidators (default: the impersonated OP1 / OP2) */
  funders?: [string, string];
  /** receives the wrapper's name and (redacted-by-construction: rehearsal only) output of each ceremony step, for the pipeline log */
  onStep?: (name: string, output: string) => void;
  /** directory for the addresses file of the ceremony wrapper (default: the OS temp directory) */
  workDir?: string;
}
export interface BroughtUp {
  /** the pilot's one sizing number (USD): LENDING_USDC_BORROW_CAP of ceremony/pilot-pw30.env; every amount below scales with it */
  capUsd: number;
  report: Record<string, any>;
  pw: { controller: string; oracle: string; pWavax: string; pUsdc: string };
  deployed: Record<string, string>;
  setFeeds: () => Promise<void>;
  mocks: Mocks;
  realAvax: BigNumber;
  realUsdc: BigNumber;
}

/** PW30 + the four margin stages (+ an optional demo position) on a started fork. Throws on failure. */
export async function bringUpMarginFork(chain: ForkChain, opts: BringUpOptions = {}): Promise<BroughtUp> {
  const demo = !!opts.demo;
  const [f1, f2] = opts.funders ?? [OP1, OP2];
  const report: Record<string, any> = { startedAt: new Date().toISOString() };
  {
    report.forkHead = await chain.provider.getBlockNumber();
    report.rpcLocal = chain.url;
    const pw30 = readEnvFile(path.join(CONTRACTS, "ceremony", "pilot-pw30.env"));
    const capUsd = Number(BigInt(pw30.LENDING_USDC_BORROW_CAP!) / 1_000_000n);
    const U = (x: number): bigint => BigInt(Math.round(x * 1e6)); // USDC units of a USD amount
    const flashSeed = U(capUsd * 0.5);
    const insSeed = U(capUsd * 0.05);
    report.capUsd = capUsd;
    for (const a of [LEDGER, THROWAWAY, f1, f2, ALICE, TEAM]) await chain.setBalance(a, utils.parseEther("1000"));
    await chain.setErc20Balance(WAVAX, LEDGER, BigNumber.from(pw30.LENDING_WAVAX_SEED_AMOUNT));
    await chain.setErc20Balance(USDC, LEDGER, BigNumber.from(pw30.LENDING_USDC_SEED_AMOUNT).add(flashSeed.toString()).add(insSeed.toString()));

    // ---- 1. PW30
    const env30 = { ...pw30, RPC_LOCAL: chain.url };
    const dep = await run("tools/avalanche-ceremony.sh", "deploy", env30);
    opts.onStep?.("PW30 deploy", dep.out);
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
    const teamSupply = BigNumber.from(U(capUsd * 1.25).toString()); // team supply: 1.25 x CAP
    await chain.setErc20Balance(USDC, TEAM, teamSupply);
    await okTx(new Contract(USDC, erc, chain.signer(TEAM)).approve(pw.pUsdc, teamSupply));
    await okTx(new Contract(pw.pUsdc, ["function mint(uint256) returns (uint256)"], chain.signer(TEAM)).mint(teamSupply));
    await okTx(ctrl._setBorrowPaused(pw.pUsdc, false));

    // ---- 2. margin stages
    const addrFile = path.join(opts.workDir ?? os.tmpdir(), `order-keeper-margin-addresses-${process.pid}.env`); // NOT contracts/ceremony: nothing is written into the repository
    const menv: Record<string, string> = {
      MARGIN_DEPLOYER: THROWAWAY, MARGIN_OWNER: LEDGER, CONTROLLER: pw.controller, PWAVAX: pw.pWavax, PUSDC: pw.pUsdc,
      MARGIN_CAP_USD: String(capUsd), MARGIN_FLASH_SEED_USDC: flashSeed.toString(), MARGIN_INSURANCE_SEED_USDC: insSeed.toString(), MARGIN_FUNDERS: `${f1},${f2}`,
      MARGIN_ACTION_DELAY: "86400", MARGIN_ADDRESSES_FILE: addrFile, RPC_LOCAL: chain.url,
    };
    const M = "tools/avalanche-margin-ceremony.sh";
    const stage = async (step: string, extra: Record<string, string> = {}) => {
      const r = await run(M, step, { ...menv, ...extra });
      opts.onStep?.(`margin ${step}${extra.STAGE ? " " + extra.STAGE : ""}`, r.out);
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
    report.accounts = { ledger: LEDGER, operator1: f1, operator2: f2, alice: ALICE, team: TEAM, throwawayDeployer: THROWAWAY, note: "impersonated on the fork: send from any of them without a key" };

    // ---- 3. an open position for ALICE
    const brought: BroughtUp = { capUsd, report, pw, deployed, setFeeds, mocks, realAvax: realAvax[1], realUsdc: realUsdc[1] };
    if (demo) report.demoPosition = await openLong(chain, brought, ALICE, U(capUsd * 0.5)); // margin = half the position cap (2x)
    return brought;
  }
}

/** One 2x long for `user` with `marginUsdc` (USDC units) of margin, through the real vault and executor. Returns the position as read back. */
export async function openLong(chain: ForkChain, b: BroughtUp, user: string, marginUsdc: bigint): Promise<{ id: string; owner: string; account: string; status: number; borrowedPrincipal: string }> {
  const { pw, deployed } = b;
  await chain.setBalance(user, utils.parseEther("1000"));
  await chain.setErc20Balance(USDC, user, BigNumber.from(marginUsdc.toString()));
  const s = chain.signer(user);
  const pUsdc: any = new Contract(pw.pUsdc, ["function mint(uint256) returns (uint256)", "function balanceOf(address) view returns (uint256)", "function approve(address,uint256) returns (bool)", "function exchangeRateCurrent() returns (uint256)"], s);
  await okTx(new Contract(USDC, erc, s).approve(pw.pUsdc, BigNumber.from(marginUsdc.toString())));
  const before: BigNumber = await pUsdc.balanceOf(user);
  await okTx(pUsdc.mint(BigNumber.from(marginUsdc.toString())));
  const shares: BigNumber = (await pUsdc.balanceOf(user)).sub(before);
  const vault: any = new Contract(deployed.M_VAULT!, abi("IsolatedMarginVault"), s);
  await okTx(pUsdc.approve(deployed.M_VAULT!, shares));
  await okTx(vault.deposit(pw.pUsdc, shares));
  const rate: BigNumber = await pUsdc.callStatic.exchangeRateCurrent();
  const quoter: any = new Contract(deployed.M_QUOTER!, abi("IsolatedMarginQuoter"), s);
  const q = await quoter.quoteOpen(pw.pUsdc, pw.pWavax, pw.pUsdc, shares.mul(rate).div(utils.parseEther("1")), 200);
  const exec: any = new Contract(deployed.M_EXECUTOR!, abi("IsolatedMarginExecutor"), s);
  const next: BigNumber = await exec.nextPositionId();
  await okTx(exec.openPosition({ marginPToken: pw.pUsdc, positionPToken: pw.pWavax, debtPToken: pw.pUsdc, marginPTokenAmount: shares, leverageX100: 200, maxOpeningFeePToken: 0, minPositionUnderlying: q[1], side: 0, swapData: "0x" }, { gasLimit: 6_000_000 }));
  const pos = await exec.positions(next);
  return { id: next.toString(), owner: pos.owner, account: pos.account, status: pos.status, borrowedPrincipal: pos.borrowedPrincipal.toString() };
}

// REHEARSAL of the mainnet deployment ceremony on a local anvil fork of the CURRENT mainnet head: the exact wrapper (contracts/tools/avalanche-ceremony.sh)
// runs the exact deploy script with the exact inputs (contracts/ceremony/pilot-pw30.env), the Ledger address is impersonated on the fork (nothing real is
// signed), then the post-deploy steps of the ceremony document are executed and read back, followed by a smoke test of the product (supply, borrow, repay).
// The private endpoint is read from the ENVIRONMENT and reached through a local pass-through proxy; it is never printed.
//   AVALANCHE_MAINNET_RPC_URL=... node dist/scripts/rehearse-ceremony.js [--out <report.json>]
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { BigNumber, Contract, utils } from "ethers";
import { ForkChain } from "../test/fork/harness";
import { safeError } from "../src/mask";

const LEDGER = "0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD";
const WAVAX = "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7";
const USDC = "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E";
const CONTRACTS = path.join(__dirname, "..", "..", "..", "contracts");
const erc = ["function balanceOf(address) view returns (uint256)", "function approve(address,uint256) returns (bool)"];

function readEnvFile(file: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const l of fs.readFileSync(file, "utf8").split("\n")) {
    const m = l.match(/^export ([A-Z0-9_]+)=(.*)$/);
    if (m) out[m[1]!] = m[2]!.trim();
  }
  return out;
}
// ASYNC on purpose: this process hosts the RPC proxy that the anvil fork (and through it forge) depends on; a blocking spawn would starve it.
function run(step: string, env: Record<string, string>): Promise<{ status: number; out: string }> {
  return new Promise((resolve) => {
    const child = spawn("bash", ["tools/avalanche-ceremony.sh", step, "rehearsal"], { cwd: CONTRACTS, env: { ...process.env, ...env, AVALANCHE_MAINNET_RPC_URL: "" } });
    let out = "";
    child.stdout.on("data", (d) => (out += String(d)));
    child.stderr.on("data", (d) => (out += String(d)));
    child.on("close", (code) => resolve({ status: code ?? 1, out }));
  });
}

(async () => {
  const report: Record<string, unknown> = { startedAt: new Date().toISOString() };
  const chain = await ForkChain.start("latest");
  try {
    const head = await chain.provider.getBlockNumber();
    report.forkHead = head;
    const inputs = readEnvFile(path.join(CONTRACTS, "ceremony", "pilot-pw30.env"));
    // the Ledger on the fork: AVAX for gas, the two seed balances, and (for the supply step) the operator's USDC
    await chain.setBalance(LEDGER, utils.parseEther("100"));
    await chain.setErc20Balance(WAVAX, LEDGER, BigNumber.from(inputs.LENDING_WAVAX_SEED_AMOUNT));
    await chain.setErc20Balance(USDC, LEDGER, BigNumber.from(inputs.LENDING_USDC_SEED_AMOUNT));
    const env = { ...inputs, RPC_LOCAL: chain.url };
    const ce = await run("check-env", env);
    report.checkEnv = ce.out.trim();
    if (ce.status !== 0) throw new Error("check-env failed: " + ce.out);
    const dep = await run("deploy", env);
    fs.writeFileSync(path.join(__dirname, "..", "..", "rehearsal-deploy.log"), dep.out);
    if (dep.status !== 0) throw new Error("deploy failed:\n" + dep.out.split("\n").slice(-30).join("\n"));
    const grab = (label: string): string => {
      const m = dep.out.match(new RegExp(label + "\\s+(0x[0-9a-fA-F]{40})"));
      if (!m) throw new Error("address not found in the deploy output: " + label);
      return m[1]!;
    };
    const addrs = { controller: grab("Unitroller/controller"), implementation: grab("implementation"), oracle: grab("guarded oracle"), pWavax: grab("pWAVAX"), pUsdc: grab("pUSDC") };
    report.addresses = addrs;
    // the broadcast file: transactions, gas
    const bfile = path.join(CONTRACTS, "broadcast", "DeployAvalancheCashOnlyLending.s.sol", "43114", "run-latest.json");
    const b = JSON.parse(fs.readFileSync(bfile, "utf8"));
    const gas = (b.receipts as Array<{ gasUsed: string }>).reduce((a, r) => a + parseInt(r.gasUsed, 16), 0);
    report.deployTransactions = (b.transactions as unknown[]).length;
    report.deployGasUsed = gas;
    report.deployGasCostAvaxAt3gwei = (gas * 3) / 1e9;
    const ver = await run("verify", { ...env, CONTROLLER: addrs.controller, PWAVAX: addrs.pWavax, PUSDC: addrs.pUsdc, EXPECTED_ADMIN: LEDGER });
    report.verifyBeforeEnable = ver.status === 0 ? "ok" : ver.out.split("\n").slice(-12).join("\n");
    if (ver.status !== 0) throw new Error("verify failed: " + ver.out);

    // ---- post-deploy steps of the ceremony (as the impersonated Ledger)
    const led = chain.signer(LEDGER);
    const ctrl: any = new Contract(addrs.controller, ["function _setCollateralFactor(address,uint256) returns (uint256)", "function _setBorrowPaused(address,bool) returns (bool)", "function borrowGuardianPaused(address) view returns (bool)", "function markets(address) view returns (bool,uint256,bool)", "function borrowCaps(address) view returns (uint256)", "function borrowCashFloor(address) view returns (uint256)", "function enterMarkets(address[]) returns (uint256[])", "function admin() view returns (address)", "function getAccountLiquidity(address) view returns (uint256,uint256,uint256)"], led);
    const okTx = async (p: Promise<any>) => { const r = await (await p).wait(); if (r.status !== 1) throw new Error("tx failed"); return r; };
    await okTx(ctrl._setCollateralFactor(addrs.pWavax, utils.parseEther("0.30")));
    // supply side: the operator's USDC (USD 6,250 intended) from a supplier account, BEFORE borrowing is enabled
    const SUPPLIER = "0x00000000000000000000000000000000005077E1";
    await chain.setBalance(SUPPLIER);
    await chain.setErc20Balance(USDC, SUPPLIER, BigNumber.from(6_250_000_000));
    const pUsdc: any = new Contract(addrs.pUsdc, ["function mint(uint256) returns (uint256)", "function borrow(uint256) returns (uint256)", "function repayBorrow(uint256) returns (uint256)", "function getCash() view returns (uint256)", "function totalBorrows() view returns (uint256)", "function borrowRatePerBlock() view returns (uint256)", "function supplyRatePerBlock() view returns (uint256)", "function borrowBalanceCurrent(address) returns (uint256)", "function totalSupply() view returns (uint256)"], chain.signer(SUPPLIER));
    await okTx(new Contract(USDC, erc, chain.signer(SUPPLIER)).approve(addrs.pUsdc, BigNumber.from(6_250_000_000)));
    await okTx(pUsdc.mint(BigNumber.from(6_250_000_000)));
    await okTx(ctrl._setBorrowPaused(addrs.pUsdc, false));
    const pw = new Contract(addrs.pWavax, ["function mint(uint256) returns (uint256)"], chain.signer(LEDGER));
    void pw;
    report.postState = {
      admin: await ctrl.admin(),
      pWavaxCollateralFactor: (await ctrl.markets(addrs.pWavax))[1].toString(),
      pUsdcCollateralFactor: (await ctrl.markets(addrs.pUsdc))[1].toString(),
      pUsdcBorrowPaused: await ctrl.borrowGuardianPaused(addrs.pUsdc),
      pWavaxBorrowPaused: await ctrl.borrowGuardianPaused(addrs.pWavax),
      pUsdcBorrowCap: (await ctrl.borrowCaps(addrs.pUsdc)).toString(),
      pUsdcCashFloor: (await ctrl.borrowCashFloor(addrs.pUsdc)).toString(),
      pUsdcCash: (await pUsdc.getCash()).toString(),
    };
    // ---- smoke test of the product: collateral, borrow within the cap, repay
    const BORROWER = "0x0000000000000000000000000000000000B0AA01";
    await chain.setBalance(BORROWER);
    const bw = utils.parseEther("400"); // about USD 3,350 of WAVAX at USD 8.37: borrowing power 30% = about USD 1,000
    await chain.setErc20Balance(WAVAX, BORROWER, bw);
    const pWavaxB = new Contract(addrs.pWavax, ["function mint(uint256) returns (uint256)"], chain.signer(BORROWER));
    await okTx(new Contract(WAVAX, erc, chain.signer(BORROWER)).approve(addrs.pWavax, bw));
    await okTx(pWavaxB.mint(bw));
    await okTx(new Contract(addrs.controller, ["function enterMarkets(address[]) returns (uint256[])"], chain.signer(BORROWER)).enterMarkets([addrs.pWavax, addrs.pUsdc]));
    const pUsdcB: any = pUsdc.connect(chain.signer(BORROWER));
    await okTx(pUsdcB.borrow(BigNumber.from(500_000_000)));
    const debt = await pUsdcB.callStatic.borrowBalanceCurrent(BORROWER);
    // a borrow beyond the borrowing power must be refused
    let refused = false;
    try { const c = await pUsdcB.callStatic.borrow(BigNumber.from(4_000_000_000)); refused = !c.eq(0); } catch { refused = true; }
    // a WAVAX borrow must be refused (paused)
    let wavaxRefused = false;
    try { const pwb: any = new Contract(addrs.pWavax, ["function borrow(uint256) returns (uint256)"], chain.signer(BORROWER)); await pwb.callStatic.borrow(utils.parseEther("1")); } catch { wavaxRefused = true; }
    await okTx(new Contract(USDC, erc, chain.signer(BORROWER)).approve(addrs.pUsdc, BigNumber.from(2).pow(255)));
    await chain.setErc20Balance(USDC, BORROWER, (await new Contract(USDC, erc, chain.provider).balanceOf(BORROWER)).add(10_000_000));
    await okTx(pUsdcB.repayBorrow(BigNumber.from(2).pow(256).sub(1)));
    // yield at the pilot's intended load: a second borrower takes USD 4,900 of the USD 6,350 in the market (the cap is USD 5,000)
    const B2 = "0x0000000000000000000000000000000000B0AA02";
    await chain.setBalance(B2);
    const w2 = utils.parseEther("2000");
    await chain.setErc20Balance(WAVAX, B2, w2);
    await okTx(new Contract(WAVAX, erc, chain.signer(B2)).approve(addrs.pWavax, w2));
    await okTx(new Contract(addrs.pWavax, ["function mint(uint256) returns (uint256)"], chain.signer(B2)).mint(w2));
    await okTx(new Contract(addrs.controller, ["function enterMarkets(address[]) returns (uint256[])"], chain.signer(B2)).enterMarkets([addrs.pWavax, addrs.pUsdc]));
    const pUsdcB2: any = pUsdc.connect(chain.signer(B2));
    await okTx(pUsdcB2.borrow(BigNumber.from(4_900_000_000)));
    const util = Number((await pUsdc.totalBorrows()).toString()) / (Number((await pUsdc.getCash()).toString()) + Number((await pUsdc.totalBorrows()).toString()));
    const loaded = { utilisation: util, borrowRatePerBlock: (await pUsdc.borrowRatePerBlock()).toString(), supplyRatePerBlock: (await pUsdc.supplyRatePerBlock()).toString() };
    // the cap: one more USD 200 would pass USD 5,000 and must be refused
    let capRefused = false;
    try { const c = await pUsdcB2.callStatic.borrow(BigNumber.from(200_000_000)); capRefused = !c.eq(0); } catch { capRefused = true; }
    const rates = loaded;
    report.smoke = { borrowed: "500000000", debtAfterAccrual: debt.toString(), overBorrowRefused: refused, wavaxBorrowRefused: wavaxRefused, borrowCapRefused: capRefused, debtAfterRepay: (await pUsdcB.callStatic.borrowBalanceCurrent(BORROWER)).toString(), rates };
    const bpy = Number(inputs.LENDING_BLOCKS_PER_YEAR);
    report.rateApr = { atUtilisation: rates.utilisation, borrowApr: (Number(rates.borrowRatePerBlock) * bpy) / 1e18, supplyApr: (Number(rates.supplyRatePerBlock) * bpy) / 1e18 };
    report.ok = true;
  } catch (e) {
    report.ok = false;
    report.error = safeError(e);
  } finally {
    await chain.stop();
  }
  report.finishedAt = new Date().toISOString();
  const outIdx = process.argv.indexOf("--out");
  const text = JSON.stringify(report, null, 2);
  if (outIdx >= 0) fs.writeFileSync(process.argv[outIdx + 1]!, text + "\n");
  console.log(text);
  process.exit(report.ok ? 0 : 1);
})();

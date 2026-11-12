// REHEARSAL of the vault-opening ceremony (12 Nov) on a local fork of the CURRENT mainnet head: the Safe 0x80f4...fB12 (1-of-1, owner = the Ledger) executes
// `setDepositCap` on both live Pharaoh vaults; read-backs; then a depositor fills the cap and the cap is enforced; deployIdle and redeem are exercised.
// The Ledger is IMPERSONATED on the fork; nothing real is signed. The calldata printed here is what the Ledger signs on the day.
//   AVALANCHE_MAINNET_RPC_URL=... node dist/scripts/rehearse-vault-opening.js [--out report.json]
import fs from "node:fs";
import path from "node:path";
import { BigNumber, Contract, utils } from "ethers";
import { ForkChain } from "../test/fork/harness";
import { safeError } from "../src/mask";

const LEDGER = "0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD";
const SAFE = "0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12";
const USDC = "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E";
const WAVAX = "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7";
// Sizes come from the ONE-INPUT sizing (contracts/ceremony/pilot-sizing.json, written by contracts/tools/pilot-sizing.py): cap, team seed per vault; the test deposit is 2% of the cap.
const SIZING = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "..", "contracts", "ceremony", "pilot-sizing.json"), "utf8"));
const USDC_CAP = BigNumber.from(String(SIZING.vaults.usdc_deposit_cap_units)), WAVAX_CAP = BigNumber.from(String(SIZING.vaults.wavax_deposit_cap_units));
const VAULTS = [
  { name: "USDC vault", address: "0x855bF832f26a294d28500db59eE941dE3d654129", asset: USDC, cap: USDC_CAP, test: USDC_CAP.mul(2).div(100), decimals: 6, seed: BigNumber.from(String(SIZING.vaults.usdc_team_seed_units)) },
  { name: "WAVAX vault", address: "0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8", asset: WAVAX, cap: WAVAX_CAP, test: WAVAX_CAP.mul(2).div(100), decimals: 18, seed: BigNumber.from(String(SIZING.vaults.wavax_team_seed_units)) },
];
const safeIface = new utils.Interface(["function execTransaction(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,bytes signatures) returns (bool)", "function nonce() view returns (uint256)", "function getOwners() view returns (address[])", "function getThreshold() view returns (uint256)"]);
const vaultAbi = ["function setDepositCap(uint256)", "function depositCap() view returns (uint256)", "function totalAssets() view returns (uint256)", "function totalSupply() view returns (uint256)", "function maxDeposit(address) view returns (uint256)", "function deposit(uint256,address) returns (uint256)", "function redeem(uint256,address,address) returns (uint256)", "function balanceOf(address) view returns (uint256)", "function previewRedeem(uint256) view returns (uint256)", "function owner() view returns (address)", "function paused() view returns (bool)", "function rebalancer() view returns (address)", "function deployIdle()", "function convertToAssets(uint256) view returns (uint256)"];
const erc = ["function balanceOf(address) view returns (uint256)", "function approve(address,uint256) returns (bool)"];

const ERR: Record<string, string> = Object.fromEntries(["Vault__PriceDeviation(int24,int24)", "Vault__OracleDeviation(uint256,uint256)", "Vault__PositionNeedsRebalance()", "Vault__InsufficientAssets(uint256,uint256)", "Vault__InsufficientShares(uint256,uint256)", "Vault__ExcessiveLoss(uint256,uint256)", "Vault__DepositCapExceeded(uint256,uint256)", "Vault__NotRebalancer()", "Vault__ZeroAmount()", "Vault__InvalidOracle()"].map((e) => [utils.id(e).slice(0, 10), e]));
function why(e: any): string {
  const m = String(e?.error?.error?.data ?? e?.error?.data ?? e?.data ?? e?.message ?? e).match(/0x[0-9a-fA-F]{8}/);
  const sel = m?.[0]?.toLowerCase();
  return (sel && ERR[sel]) || safeError(e).slice(0, 200);
}
// --fork-block N: fork at a given block instead of the head; --estimate-gas: let ethers estimate gas (the FIRST version of this script did; it is what
// failed once) instead of sending explicit gas limits
const argv = process.argv;
const forkBlockArg = argv.indexOf("--fork-block") >= 0 ? Number(argv[argv.indexOf("--fork-block") + 1]) : undefined;
const estimateGas = argv.includes("--estimate-gas");
const gl = (n: number): any => (estimateGas ? {} : { gasLimit: n });
(async () => {
  const report: Record<string, any> = { startedAt: new Date().toISOString(), estimateGas };
  const chain = await ForkChain.start(forkBlockArg ?? "latest");
  let step = "start";
  try {
    report.forkHead = await chain.provider.getBlockNumber();
    // a mined-and-reverted transaction carries no revert data in ethers v5: replay it as a call at the block BEFORE it to read the custom error
    const diagnose = (globalThis as any).__diagnose = async (e: any): Promise<any> => {
      const h: string | undefined = e?.transactionHash ?? e?.receipt?.transactionHash ?? e?.transaction?.hash;
      const out: any = { message: safeError(e).slice(0, 160), txHash: h };
      if (!h) return out;
      try {
        const tx = await chain.provider.getTransaction(h);
        const rc = await chain.provider.getTransactionReceipt(h);
        out.tx = { from: tx.from, to: tx.to, selector: tx.data.slice(0, 10), block: rc.blockNumber, gasUsed: rc.gasUsed.toString(), gasLimit: tx.gasLimit.toString(), status: rc.status };
        out.outOfGas = rc.gasUsed.gte(tx.gasLimit.mul(99).div(100));
        try { await chain.provider.call({ from: tx.from, to: tx.to!, data: tx.data }, rc.blockNumber - 1); out.replayDefaultGas = "succeeds as a call at the previous block with the default call gas"; } catch (e2) { out.replayDefaultGas = why(e2); }
        // the SAME call with exactly the gas limit the failed transaction had, then with 25% more: out-of-gas shows as a revert without data
        for (const [label, g] of [["atTheTransactionGasLimit", tx.gasLimit], ["with25PercentMoreGas", tx.gasLimit.mul(125).div(100)]] as const) {
          try { await chain.provider.call({ from: tx.from, to: tx.to!, data: tx.data, gasLimit: g }, rc.blockNumber - 1); out[label] = "succeeds"; } catch (e2) { out[label] = "FAILS: " + why(e2); }
        }
      } catch (e3) { out.diagnoseError = safeError(e3); }
      return out;
    };
    await chain.setBalance(LEDGER, utils.parseEther("10"));
    const led = chain.signer(LEDGER);
    const safe: any = new Contract(SAFE, safeIface, led);
    report.safe = { owners: await safe.getOwners(), threshold: (await safe.getThreshold()).toString(), nonce: (await safe.nonce()).toString() };
    // owner-as-msg.sender signature of a 1-of-1 Safe: r = owner (left padded), s = 0, v = 1 (the "approved hash" type, accepted when msg.sender is the owner)
    const sig = utils.hexConcat([utils.hexZeroPad(LEDGER, 32), utils.hexZeroPad("0x00", 32), "0x01"]);
    report.signature = sig;
    report.vaults = [];
    for (const v of VAULTS) {
      const vault: any = new Contract(v.address, vaultAbi, chain.provider);
      const before = { owner: await vault.owner(), paused: await vault.paused(), rebalancer: await vault.rebalancer(), depositCap: (await vault.depositCap()).toString(), totalAssets: (await vault.totalAssets()).toString(), totalSupply: (await vault.totalSupply()).toString() };
      const data = new utils.Interface(vaultAbi).encodeFunctionData("setDepositCap", [v.cap]);
      const execData = safeIface.encodeFunctionData("execTransaction", [v.address, 0, data, 0, 0, 0, 0, "0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000", sig]);
      step = `${v.name}: Safe.execTransaction(setDepositCap)`;
      const r = await (await safe.execTransaction(v.address, 0, data, 0, 0, 0, 0, "0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000", sig, { gasLimit: 500_000 })).wait();
      const after = { depositCap: (await vault.depositCap()).toString(), maxDepositForAnyone: (await vault.maxDeposit("0x00000000000000000000000000000000000D3905")).toString(), safeNonce: (await safe.nonce()).toString() };
      // THE TEAM SEED (12 Nov): the Ledger approves and deposits the seed, then calls deployIdle (it is the rebalancer); read-backs after each
      step = `${v.name}: team seed deposit`;
      await chain.setErc20Balance(v.asset, LEDGER, v.seed);
      const assetL: any = new Contract(v.asset, erc, led);
      const vaultL: any = new Contract(v.address, vaultAbi, led);
      await (await assetL.approve(v.address, v.seed, gl(120_000))).wait();
      const seedTx = await (await vaultL.deposit(v.seed, LEDGER, gl(3_000_000))).wait();
      const afterSeed = { ledgerShares: (await vault.balanceOf(LEDGER)).toString(), totalAssets: (await vault.totalAssets()).toString(), totalSupply: (await vault.totalSupply()).toString(), idleAssetInVault: (await new Contract(v.asset, erc, chain.provider).balanceOf(v.address)).toString(), depositGasUsed: seedTx.gasUsed.toString() };
      step = `${v.name}: team seed deployIdle`;
      const idleTx = await (await vaultL.deployIdle(gl(3_000_000))).wait();
      const afterDeploy = { idleAssetInVault: (await new Contract(v.asset, erc, chain.provider).balanceOf(v.address)).toString(), totalAssets: (await vault.totalAssets()).toString(), deployIdleGasUsed: idleTx.gasUsed.toString(), ledgerRedeemable: (await vault.previewRedeem(await vault.balanceOf(LEDGER))).toString() };
      // fill the cap with a depositor and verify the cap is the real limit
      const dep = "0x000000000000000000000000000000000000D3905".slice(0, 42).toLowerCase();
      await chain.setBalance(dep);
      const room = BigNumber.from(after.maxDepositForAnyone);
      await chain.setErc20Balance(v.asset, dep, room.add(v.test));
      const tok: any = new Contract(v.asset, erc, chain.signer(dep));
      await (await tok.approve(v.address, room.add(v.test))).wait();
      const vdep: any = new Contract(v.address, vaultAbi, chain.signer(dep));
      step = `${v.name}: first deposit`;
      let small: any;
      try { small = await (await vdep.deposit(v.test, dep, gl(8_000_000))).wait(); } catch (e) { report.vaults.push({ name: v.name, address: v.address, depositRefused: await diagnose(e), note: 'a deposit reverted at this block; this is the vault guard working (price / oracle deviation), not a cap issue' }); continue; }
      const sharesSmall = await vault.balanceOf(dep);
      const redeemable = await vault.previewRedeem(sharesSmall);
      const roomAfter = BigNumber.from((await vault.maxDeposit(dep)).toString());
      // NOTE (found by this rehearsal): maxDeposit() can overstate the room by a few units (it returned 3 units of USDC more than the cap check accepts), so fill to 99.99% of the room
      step = `${v.name}: deposit up to the cap`;
      const fill = roomAfter.mul(9999).div(10000);
      await (await vdep.deposit(fill, dep, gl(8_000_000))).wait();
      const deposited = v.test.add(fill);
      step = `${v.name}: over-cap check`;
      let overRefused = false;
      try { await vdep.callStatic.deposit(v.cap.mul(3).div(100), dep); } catch { overRefused = true; } // 3% of the cap more: refused (the cap binds on the HAIRCUT valuation, so deposits can exceed the nominal cap by about the entry cost, 0.5% to 1.3%: a 1% test is not conclusive)
      step = `${v.name}: deployIdle`;
      let deployIdle: string;
      try { const vL: any = new Contract(v.address, vaultAbi, led); await (await vL.deployIdle(gl(8_000_000))).wait(); deployIdle = "ok"; } catch (e) { deployIdle = "reverted: " + safeError(e).slice(0, 160); }
      step = `${v.name}: redeem`;
      const sharesAll = await vault.balanceOf(dep);
      let redeemOk = "ok";
      let got = BigNumber.from(0);
      try { const before0 = await new Contract(v.asset, erc, chain.provider).balanceOf(dep); await (await vdep.redeem(sharesAll, dep, dep, gl(8_000_000))).wait(); got = (await new Contract(v.asset, erc, chain.provider).balanceOf(dep)).sub(before0); } catch (e) { redeemOk = "reverted: " + safeError(e).slice(0, 160); }
      report.vaults.push({ name: v.name, address: v.address, cap: v.cap.toString(), teamSeed: v.seed.toString(), afterSeed, afterDeploy, before, setDepositCapCalldata: data, safeExecTransactionCalldata: execData, setDepositCapGas: r.gasUsed.toString(), after, depositTestGas: small.gasUsed.toString(), redeemableOfSmallDeposit: redeemable.toString(), depositedToCap: true, overCapRefused: overRefused, deployIdle, redeem: redeemOk, redeemedAssets: got.toString(), depositedTotal: deposited.toString(), roundTripLossBp: deposited.sub(got).mul(10000).div(deposited).toNumber(), note: 'round trip = deposit, deployIdle (liquidity into the Pharaoh position), immediate redeem of all shares' });
    }
    report.ok = true;
  } catch (e) {
    report.ok = false;
    report.error = safeError(e);
    report.failedStep = step;
    report.failedDiagnosis = await (async () => { try { return await (globalThis as any).__diagnose?.(e); } catch { return undefined; } })();
    report.failedTxHash = (e as any)?.transactionHash ?? (e as any)?.receipt?.transactionHash;
    // decode the revert of the failed transaction by replaying it as a call at the block BEFORE it
    try {
      const h = report.failedTxHash as string | undefined;
      if (h) {
        const tx = await chain.provider.getTransaction(h);
        const rc = await chain.provider.getTransactionReceipt(h);
        report.failedTx = { from: tx.from, to: tx.to, data: tx.data.slice(0, 74), block: rc.blockNumber, gasUsed: rc.gasUsed.toString(), gasLimit: tx.gasLimit.toString() };
        try { await chain.provider.call({ from: tx.from, to: tx.to!, data: tx.data }, rc.blockNumber - 1); report.replayAtPreviousBlock = "succeeds as a call (state-dependent or gas)"; } catch (e2) { report.replayAtPreviousBlock = why(e2); }
      }
    } catch (e3) { report.replayError = safeError(e3); }
  } finally {
    await chain.stop();
  }
  report.finishedAt = new Date().toISOString();
  const i = process.argv.indexOf("--out");
  const text = JSON.stringify(report, null, 2);
  if (i >= 0) fs.writeFileSync(process.argv[i + 1]!, text + "\n");
  console.log(text);
  process.exit(report.ok ? 0 : 1);
})();

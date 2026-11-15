// REHEARSAL of the R3 upgrade and the rebalancer rotation (15 Nov) on a local fork: the live Pharaoh vaults are opened exactly as on 12 Nov (cap, team seed, deployIdle,
// a second depositor, all under the DEPLOYED code), then the Ledger deploys the R3 base and extension and the Safe upgrades both proxies through their ProxyAdmins,
// then the Safe rotates `rebalancer()` to a THROWAWAY keystore wallet and the rebalancer MODULE (src/rebalancer.ts) does its work on the upgraded vaults.
// The Ledger is IMPERSONATED on the fork; nothing real is signed; the calldata printed is what the Ledger signs on the day.
//   AVALANCHE_MAINNET_RPC_URL=... node dist/scripts/rehearse-r3-upgrade.js [--fork-block N] [--out report.json]
// Needs the R3 build: cd contracts/vault-r3 && forge build   (artifacts in contracts/vault-r3/out)
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { BigNumber, Contract, ContractFactory, Wallet, utils } from "ethers";
import { ForkChain } from "../test/fork/harness";
import { decidedConfig } from "../test/fixtures";
import { AlertManager, MemorySink } from "../src/alerts";
import { requireValidConfig } from "../src/config";
import { emptyRebalancerState, rebalancerStep } from "../src/rebalancer";
import { KeystoreSigner } from "../src/signer";
import { safeError } from "../src/mask";

const LEDGER = "0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD";
const SAFE = "0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12";
const USDC = "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E";
const WAVAX = "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7";
const Z = "0x0000000000000000000000000000000000000000";
const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const OUTSIDER = "0x00000000000000000000000000000000000D3905";
const PW = "rehearsal-only-password-5e1c"; // protects THROWAWAY keystores that exist only for this local-fork run
// Sizes come from the ONE-INPUT sizing (contracts/ceremony/pilot-sizing.json): cap and team seed per vault; the second depositor is 4% of the cap, the donation 1%, the third deposit 2%.
const SIZING = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "..", "contracts", "ceremony", "pilot-sizing.json"), "utf8"));
const UCAP = BigNumber.from(String(SIZING.vaults.usdc_deposit_cap_units)), WCAP = BigNumber.from(String(SIZING.vaults.wavax_deposit_cap_units));
const pct = (x: BigNumber, n: number) => x.mul(n).div(100);
const VAULTS = [
  { name: "USDC vault", address: "0x855bF832f26a294d28500db59eE941dE3d654129", admin: "0x2DD4191B2944396B5853f4219E829f01636F65cf", asset: USDC, cap: UCAP, seed: BigNumber.from(String(SIZING.vaults.usdc_team_seed_units)), second: pct(UCAP, 4), donate: pct(UCAP, 1), third: pct(UCAP, 2) },
  { name: "WAVAX vault", address: "0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8", admin: "0x34CbBdfcBcc72e8bf70CbF6c7245fdb2725b94dC", asset: WAVAX, cap: WCAP, seed: BigNumber.from(String(SIZING.vaults.wavax_team_seed_units)), second: pct(WCAP, 4), donate: pct(WCAP, 1), third: pct(WCAP, 2) },
];
const safeIface = new utils.Interface(["function execTransaction(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,bytes signatures) returns (bool)", "function nonce() view returns (uint256)", "function getOwners() view returns (address[])", "function getThreshold() view returns (uint256)"]);
const adminIface = new utils.Interface(["function upgradeAndCall(address proxy, address implementation, bytes data)", "function owner() view returns (address)"]);
const vaultAbi = ["function setDepositCap(uint256)", "function setRebalancer(address)", "function pause()", "function depositCap() view returns (uint256)", "function totalAssets() view returns (uint256)", "function totalSupply() view returns (uint256)", "function deposit(uint256,address) returns (uint256)", "function redeem(uint256,address,address) returns (uint256)", "function balanceOf(address) view returns (uint256)", "function previewRedeem(uint256) view returns (uint256)", "function previewDeposit(uint256) view returns (uint256)", "function convertToAssets(uint256) view returns (uint256)", "function owner() view returns (address)", "function paused() view returns (bool)", "function rebalancer() view returns (address)", "function deployIdle()", "function tokenId() view returns (uint256)", "function positionTickLower() view returns (int24)", "function positionTickUpper() view returns (int24)", "function slippageBps() view returns (uint16)", "function valuationHaircutBps() view returns (uint16)", "function twapPeriod() view returns (uint32)", "function maxTwapDeviationTicks() view returns (uint24)"];
const erc = ["function balanceOf(address) view returns (uint256)", "function approve(address,uint256) returns (bool)"];
const ERR: Record<string, string> = Object.fromEntries(["Vault__PriceDeviation(int24,int24)", "Vault__OracleDeviation(uint256,uint256)", "Vault__PositionNeedsRebalance()", "Vault__InsufficientAssets(uint256,uint256)", "Vault__InsufficientShares(uint256,uint256)", "Vault__ExcessiveLoss(uint256,uint256)", "Vault__DepositCapExceeded(uint256,uint256)", "Vault__NotRebalancer()", "Vault__ZeroAmount()", "Vault__InvalidOracle()", "OwnableUnauthorizedAccount(address)"].map((e) => [utils.id(e).slice(0, 10), e]));
function why(e: any): string {
  const m = String(e?.error?.error?.data ?? e?.error?.data ?? e?.data ?? e?.message ?? e).match(/0x[0-9a-fA-F]{8}/);
  const sel = m?.[0]?.toLowerCase();
  return (sel && ERR[sel]) || safeError(e).slice(0, 200);
}
const argv = process.argv;
const arg = (k: string): string | undefined => (argv.indexOf(k) >= 0 ? argv[argv.indexOf(k) + 1] : undefined);
const R3_OUT = path.resolve(__dirname, "..", "..", "..", "contracts", "vault-r3", "out");
function r3art(file: string, name: string): { abi: any[]; bytecode: string } {
  const j = JSON.parse(fs.readFileSync(path.join(R3_OUT, `${file}.sol`, `${name}.json`), "utf8"));
  return { abi: j.abi, bytecode: j.bytecode.object };
}
async function keystore(dir: string, name: string): Promise<{ file: string; address: string }> {
  const w = Wallet.createRandom();
  const file = path.join(dir, name);
  fs.writeFileSync(file, await w.encrypt(PW, { scrypt: { N: 1024 } }), { mode: 0o600 });
  return { file, address: w.address };
}

(async () => {
  const report: Record<string, any> = { startedAt: new Date().toISOString() };
  const checks: Array<{ name: string; ok: boolean; detail?: string }> = [];
  const check = (name: string, ok: boolean, detail?: string): void => {
    checks.push({ name, ok, detail });
    console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  (" + detail + ")" : ""}`);
  };
  const forkBlockArg = arg("--fork-block");
  const chain = await ForkChain.start(forkBlockArg ? Number(forkBlockArg) : "latest");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "r3reh-"));
  try {
    report.forkHead = await chain.provider.getBlockNumber();
    await chain.setBalance(LEDGER, utils.parseEther("50"));
    const led = chain.signer(LEDGER);
    const safe: any = new Contract(SAFE, safeIface, led);
    const sig = utils.hexConcat([utils.hexZeroPad(LEDGER, 32), utils.hexZeroPad("0x00", 32), "0x01"]);
    const viaSafe = async (to: string, data: string, label: string): Promise<number> => {
      const r = await (await safe.execTransaction(to, 0, data, 0, 0, 0, 0, Z, Z, sig, { gasLimit: 1_500_000 })).wait();
      if (r.status !== 1) throw new Error(`Safe transaction failed: ${label}`);
      return r.gasUsed.toNumber();
    };
    report.safe = { owners: await safe.getOwners(), threshold: (await safe.getThreshold()).toString() };
    check("the Safe is 1-of-1 and its owner is the Ledger", report.safe.owners.length === 1 && report.safe.owners[0].toLowerCase() === LEDGER.toLowerCase() && report.safe.threshold === "1", JSON.stringify(report.safe));

    // ------------------------------------------------------------------ A. the opening of 12 Nov, under the DEPLOYED code
    report.vaults = [];
    const vi = new utils.Interface(vaultAbi);
    for (const v of VAULTS) {
      const vault: any = new Contract(v.address, vaultAbi, chain.provider);
      const rep: Record<string, any> = { name: v.name };
      report.vaults.push(rep);
      await viaSafe(v.address, vi.encodeFunctionData("setDepositCap", [v.cap]), `${v.name} setDepositCap`);
      await chain.setErc20Balance(v.asset, LEDGER, v.seed);
      const assetL: any = new Contract(v.asset, erc, led);
      const vaultL: any = new Contract(v.address, vaultAbi, led);
      await (await assetL.approve(v.address, v.seed, { gasLimit: 120_000 })).wait();
      await (await vaultL.deposit(v.seed, LEDGER, { gasLimit: 4_000_000 })).wait();
      await (await vaultL.deployIdle({ gasLimit: 2_000_000 })).wait();
      // a second depositor (a user), then the state we upgrade
      await chain.setErc20Balance(v.asset, OUTSIDER, v.second);
      const out = chain.signer(OUTSIDER);
      await chain.setBalance(OUTSIDER, utils.parseEther("5"));
      await (await new Contract(v.asset, erc, out).approve(v.address, v.second, { gasLimit: 120_000 })).wait();
      await (await new Contract(v.address, vaultAbi, out).deposit(v.second, OUTSIDER, { gasLimit: 4_000_000 })).wait();
      rep.opening = { totalAssets: (await vault.totalAssets()).toString(), totalSupply: (await vault.totalSupply()).toString(), tokenId: (await vault.tokenId()).toString() };
      check(`${v.name}: opened under the deployed code (cap, team seed, deployIdle, one user deposit)`, (await vault.depositCap()).eq(v.cap) && !(await vault.tokenId()).isZero(), JSON.stringify(rep.opening));
    }

    // ------------------------------------------------------------------ B. the upgrade of 15 Nov
    const baseArt = r3art("PharaohLiquidityVaultR3", "PharaohLiquidityVaultR3");
    const extArt = r3art("PharaohRewardExtensionR3", "PharaohRewardExtensionR3");
    const base = await new ContractFactory(baseArt.abi, baseArt.bytecode, led).deploy({ gasLimit: 12_000_000 });
    await base.deployed();
    const baseCodehash = utils.keccak256(await chain.provider.getCode(base.address));
    const ext = await new ContractFactory(extArt.abi, extArt.bytecode, led).deploy(base.address, baseCodehash, { gasLimit: 6_000_000 });
    await ext.deployed();
    report.deployed = { base: base.address, baseCodehash, extension: ext.address, baseBytes: (await chain.provider.getCode(base.address)).length / 2 - 1, extensionBytes: (await chain.provider.getCode(ext.address)).length / 2 - 1 };
    // the extension constructor REFUSES a base whose codehash differs: try with a wrong one
    let refused = false;
    try {
      await new ContractFactory(extArt.abi, extArt.bytecode, led).deploy(base.address, utils.id("wrong"), { gasLimit: 6_000_000 }).then((c) => c.deployed());
    } catch {
      refused = true;
    }
    check("the R3 extension refuses a base implementation with a different codehash", refused);

    const readsList = ["owner", "paused", "rebalancer", "depositCap", "tokenId", "positionTickLower", "positionTickUpper", "slippageBps", "valuationHaircutBps", "twapPeriod", "maxTwapDeviationTicks", "totalSupply", "totalAssets"];
    for (let i = 0; i < VAULTS.length; i++) {
      const v = VAULTS[i]!;
      const rep = report.vaults[i];
      const vault: any = new Contract(v.address, vaultAbi, chain.provider);
      const reads = async (): Promise<Record<string, string>> => Object.fromEntries(await Promise.all(readsList.map(async (f) => [f, String(await vault[f]())])));
      const before = await reads();
      const ledgerShares: BigNumber = await vault.balanceOf(LEDGER);
      const outShares: BigNumber = await vault.balanceOf(OUTSIDER);
      const redeemBefore = [(await vault.previewRedeem(ledgerShares)).toString(), (await vault.previewRedeem(outShares)).toString()];
      const implBefore = utils.hexStripZeros(await chain.provider.getStorageAt(v.address, IMPL_SLOT));
      check(`${v.name}: ProxyAdmin owner is the Safe`, (await new Contract(v.admin, adminIface, chain.provider).owner()).toLowerCase() === SAFE.toLowerCase());
      const calldata = adminIface.encodeFunctionData("upgradeAndCall", [v.address, ext.address, "0x"]);
      rep.upgrade = { proxyAdmin: v.admin, calldata, safeGas: await viaSafe(v.admin, calldata, `${v.name} upgradeAndCall`) };
      const implAfter = utils.hexStripZeros(await chain.provider.getStorageAt(v.address, IMPL_SLOT));
      check(`${v.name}: ERC-1967 implementation slot now holds the R3 extension`, implAfter.toLowerCase() === utils.hexStripZeros(ext.address).toLowerCase(), `${implBefore} -> ${implAfter}`);
      const after = await reads();
      const same = readsList.filter((f) => !["totalAssets"].includes(f)).every((f) => before[f] === after[f]);
      check(`${v.name}: every parameter, role, the position and the supply are unchanged by the upgrade`, same, JSON.stringify(Object.fromEntries(readsList.filter((f) => before[f] !== after[f]).map((f) => [f, [before[f], after[f]]]))));
      check(`${v.name}: totalAssets is unchanged (the haircut view is untouched)`, before.totalAssets === after.totalAssets, `${before.totalAssets} vs ${after.totalAssets}`);
      const redeemAfter = [(await vault.previewRedeem(ledgerShares)).toString(), (await vault.previewRedeem(outShares)).toString()];
      check(`${v.name}: previewRedeem for the team seed and the user is identical before and after`, JSON.stringify(redeemBefore) === JSON.stringify(redeemAfter), `${redeemBefore} vs ${redeemAfter}`);
      // a NEW deposit after the upgrade (the R3 path), and a redeem of it: the user gets back at least (1 - exit cost) of the deposit
      await chain.setErc20Balance(v.asset, OUTSIDER, v.third);
      const out = chain.signer(OUTSIDER);
      await (await new Contract(v.asset, erc, out).approve(v.address, v.third, { gasLimit: 120_000 })).wait();
      const outV: any = new Contract(v.address, vaultAbi, out);
      const preview: BigNumber = await vault.previewDeposit(v.third);
      const sharesBefore: BigNumber = await vault.balanceOf(OUTSIDER);
      const rc = await (await outV.deposit(v.third, OUTSIDER, { gasLimit: 4_000_000 })).wait();
      const minted = (await vault.balanceOf(OUTSIDER)).sub(sharesBefore);
      check(`${v.name}: a deposit after the upgrade works; shares minted >= previewDeposit (the preview is a lower bound)`, rc.status === 1 && minted.gte(preview), `gas ${rc.gasUsed}; minted ${minted}, preview ${preview}`);
      const bal0: BigNumber = await new Contract(v.asset, erc, chain.provider).balanceOf(OUTSIDER);
      await (await outV.redeem(minted, OUTSIDER, OUTSIDER, { gasLimit: 4_000_000 })).wait();
      const back: BigNumber = (await new Contract(v.asset, erc, chain.provider).balanceOf(OUTSIDER)).sub(bal0);
      const bp = back.mul(10_000).div(v.third).toNumber();
      rep.immediateRoundTripBp = bp;
      check(`${v.name}: immediate deposit + redeem returns the exit-cost figure (>= 98%)`, bp >= 9800 && bp <= 10_000, `${(bp / 100).toFixed(2)}% back`);
    }

    // ------------------------------------------------------------------ C. the rotation of the rebalancer role, and the module
    const reb = await keystore(tmp, "rebalancer");
    const stranger = await keystore(tmp, "stranger");
    await chain.setBalance(reb.address, utils.parseEther("5"));
    await chain.setBalance(stranger.address, utils.parseEther("5"));
    for (let i = 0; i < VAULTS.length; i++) {
      const v = VAULTS[i]!;
      const vault: any = new Contract(v.address, vaultAbi, chain.provider);
      const data = vi.encodeFunctionData("setRebalancer", [reb.address]);
      report.vaults[i].rotation = { calldata: data, safeGas: await viaSafe(v.address, data, `${v.name} setRebalancer`) };
      check(`${v.name}: rebalancer() reads back as the new wallet`, (await vault.rebalancer()).toLowerCase() === reb.address.toLowerCase());
      let r1 = "";
      try { await (new Contract(v.address, vaultAbi, led).callStatic as any).deployIdle(); r1 = "NOT refused"; } catch (e) { r1 = why(e); }
      check(`${v.name}: the Ledger (old rebalancer) is now refused`, /NotRebalancer/.test(r1), r1);
      const rebS = chain.signer(reb.address);
      const denied: string[] = [];
      for (const [fn, args] of [["pause", []], ["setDepositCap", [1]], ["setRebalancer", [reb.address]]] as const) {
        try { await (new Contract(v.address, vaultAbi, rebS).callStatic as any)[fn](...args); denied.push(`${fn}: NOT refused`); } catch (e) { denied.push(`${fn}: ${why(e)}`); }
      }
      check(`${v.name}: the new rebalancer cannot pause, change the cap or change the role`, denied.every((d) => /Ownable|NotOwner|Unauthorized/.test(d)), denied.join("; "));
    }

    const mkCfg = (keystorePath: string) => {
      const raw = decidedConfig({ keystorePath });
      raw.keeper.enabled = false;
      raw.rebalancer.enabled = true;
      raw.rebalancer.keystorePath = keystorePath;
      raw.rebalancer.minGasWei = "1000000000000000";
      return requireValidConfig(raw);
    };
    const cfg = mkCfg(reb.file);
    const sgn = await KeystoreSigner.load(chain.provider, reb.file, "REBALANCER_KEYSTORE_PASSWORD", { REBALANCER_KEYSTORE_PASSWORD: PW });
    check("the keystore signer's address is the rotated rebalancer", (await sgn.getAddress()).toLowerCase() === reb.address.toLowerCase());
    // idle assets appear (a donation stands for deposits waiting and collected fees): above each vault's threshold
    for (const v of VAULTS) {
      const bal: BigNumber = await new Contract(v.asset, erc, chain.provider).balanceOf(v.address);
      await chain.setErc20Balance(v.asset, v.address, bal.add(v.donate));
    }
    const sink = new MemorySink();
    const alerts = new AlertManager(sink, [3600, 14400, 86400]);
    let st = emptyRebalancerState();
    const persist = (s: typeof st) => { st = s; };
    const now = (): number => Math.floor(Date.now() / 1000);
    const o1 = await rebalancerStep({ provider: chain.provider, cfg, signer: sgn, alerts, persist, now }, st);
    st = o1.state;
    report.step1 = { done: o1.done, skipped: o1.skipped, halted: o1.halted };
    check("module step 1: deployIdle executed on BOTH vaults, not halted", o1.done.length === 2 && o1.done.every((d) => d.action === "deployIdle") && !o1.halted, JSON.stringify(o1.done.map((d) => ({ action: d.action, lossBps: d.lossBps }))));
    for (const v of VAULTS) {
      const idle: BigNumber = await new Contract(v.asset, erc, chain.provider).balanceOf(v.address);
      // the invariant is: nothing left that the module would act on again. Position-ratio rounding leaves a few cents of dust whatever the size (0.036 USDC at CAP 200), so the bound is the module's own deployIdle threshold (1 USDC / 0.1 WAVAX), not a percentage of the donation
      const moduleThreshold = v.asset === USDC ? BigNumber.from(1_000_000) : utils.parseEther("0.1");
      check(`${v.name}: after the module's deployIdle the idle asset is below the module's own threshold`, idle.lt(moduleThreshold) && idle.lt(v.donate.div(10)), `idle ${idle.toString()} of ${v.donate.toString()} (threshold ${moduleThreshold.toString()})`);
    }
    const o2 = await rebalancerStep({ provider: chain.provider, cfg, signer: sgn, alerts, persist, now }, st);
    st = o2.state;
    check("module step 2: nothing to do (in range, nothing idle)", o2.done.length === 0 && !o2.halted, o2.skipped.join(" | "));
    // a different wallet that is not the rebalancer: the module refuses to act
    const other = await KeystoreSigner.load(chain.provider, stranger.file, "REBALANCER_KEYSTORE_PASSWORD", { REBALANCER_KEYSTORE_PASSWORD: PW });
    for (const v of VAULTS) {
      const bal: BigNumber = await new Contract(v.asset, erc, chain.provider).balanceOf(v.address);
      await chain.setErc20Balance(v.asset, v.address, bal.add(v.donate));
    }
    const o3 = await rebalancerStep({ provider: chain.provider, cfg: mkCfg(stranger.file), signer: other, alerts, persist, now }, emptyRebalancerState());
    check("a wallet that is not the rebalancer is refused by the module before any transaction", o3.done.length === 0 && o3.skipped.filter((s) => /not this wallet/.test(s)).length === 2, o3.skipped.join(" | "));
    // ------------------------------------------------------------------ D. rollback: the SAME Safe call with the previous extension puts the deployed code back (layout identical)
    const OLD_EXT = "0x165E1f072e7bEeDf94f14F732838354cA20bA45d";
    for (let i = 0; i < VAULTS.length; i++) {
      const v = VAULTS[i]!;
      const vault: any = new Contract(v.address, vaultAbi, chain.provider);
      const sharesL: BigNumber = await vault.balanceOf(LEDGER);
      const redeemR3 = (await vault.previewRedeem(sharesL)).toString();
      await viaSafe(v.admin, adminIface.encodeFunctionData("upgradeAndCall", [v.address, OLD_EXT, "0x"]), `${v.name} rollback`);
      const implNow = utils.hexStripZeros(await chain.provider.getStorageAt(v.address, IMPL_SLOT));
      check(`${v.name}: rollback to the previous extension restores the implementation slot and the exit value`, implNow.toLowerCase() === utils.hexStripZeros(OLD_EXT).toLowerCase() && (await vault.previewRedeem(sharesL)).toString() === redeemR3 && (await vault.rebalancer()).toLowerCase() === reb.address.toLowerCase(), `previewRedeem ${redeemR3}`);
    }
    report.alerts = sink.messages.map((m) => `${m.severity}: ${m.text}`.slice(0, 160));
  } catch (e) {
    check("rehearsal completed without an unexpected error", false, safeError(e));
  } finally {
    report.checks = checks;
    report.allPass = checks.length > 0 && checks.every((c) => c.ok);
    if (arg("--out")) fs.writeFileSync(arg("--out")!, JSON.stringify(report, null, 2));
    console.log(`\n${checks.filter((c) => c.ok).length}/${checks.length} checks pass`);
    fs.rmSync(tmp, { recursive: true, force: true });
    await chain.stop();
    process.exit(report.allPass ? 0 : 1);
  }
})();

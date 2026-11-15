// THE REAL VAULT on a local non-fork anvil: contracts/vault-dlmm/src/PharaohDlmmVault.sol (behind OpenZeppelin's TransparentUpgradeableProxy, initialised as the ceremony does)
// together with W4's mocks (pair, router, rewarder, voter, beacon, factory, feeds, tokens) from contracts/vault-dlmm/test/mocks, compiled by forge from test/realvault (own project).
// Throwaway wallets made with Wallet.createRandom and funded with anvil_setBalance; chain id 43114; chain time pinned to 1,800,000,000 (08:00 UTC) so the vault's UTC-day cap cannot flake.
// The mock pair has no getSwapOut (the real one does, MEASURED): the keeper's optional `quoter` config points at MockPairQuoter (active-bin price and fee, no bin crossing).
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { BigNumber, Contract, ContractFactory, Wallet, utils } from "ethers";
import { MULTICALL3 } from "../../src/constants";
import type { KeeperConfig } from "../../src/config";
import { decidedConfig } from "../fixtures";
import type { Anvil } from "./harness";
import { compileStubs, stubArt } from "./harness";

export const T0 = 1_800_000_000;
export const ID0 = 1 << 23;
const E6 = 1_000_000n;

export function realToolsAvailable(): boolean {
  const lib = path.join(__dirname, "..", "..", "..", "..", "contracts", "lib", "openzeppelin-contracts");
  return fs.existsSync(lib) && spawnSync("forge", ["--version"]).status === 0;
}

let outDir: string | undefined;
export function compileReal(): string {
  if (outDir) return outDir;
  const out = fs.mkdtempSync(path.join(os.tmpdir(), "dlmm-real-out-"));
  const cache = fs.mkdtempSync(path.join(os.tmpdir(), "dlmm-real-cache-"));
  const libs = path.join(__dirname, "..", "..", "..", "..", "contracts", "lib");
  // the three lib entries are symlinks to another checkout: forge must be allowed to read their real parent directories
  const allow = [...new Set(fs.readdirSync(libs).map((n) => path.dirname(fs.realpathSync(path.join(libs, n)))))];
  const r = spawnSync("forge", ["build", "--root", path.join(__dirname, "..", "..", "..", "test", "realvault")], { encoding: "utf8", env: { ...process.env, FOUNDRY_OUT: out, FOUNDRY_CACHE_PATH: cache, FOUNDRY_ALLOW_PATHS: JSON.stringify([...allow, path.join(libs, "..")]) } });
  if (r.status !== 0) throw new Error(`forge build of the real vault failed: ${(r.stdout + r.stderr).slice(-1500)}`);
  outDir = out;
  return out;
}
const art = (file: string, name: string): { abi: any[]; bytecode: string } => {
  const j = JSON.parse(fs.readFileSync(path.join(compileReal(), `${file}.sol`, `${name}.json`), "utf8"));
  return { abi: j.abi, bytecode: j.bytecode.object };
};

export interface RealWorld {
  anvil: Anvil;
  cfg: KeeperConfig;
  dir: string;
  deployer: Wallet;
  owner: Wallet;
  keeper: Wallet;
  trader: Wallet;
  alice: Wallet;
  usdc: Contract;
  usdt: Contract;
  phar: Contract;
  feedUsdc: Contract;
  feedUsdt: Contract;
  pair: Contract;
  router: Contract;
  rewarder: Contract;
  vault: Contract;
  quoter: Contract;
  rpc<T = unknown>(method: string, params?: unknown[]): Promise<T>;
  tick(secs: number): Promise<number>;
  now(): Promise<number>;
  /** the vault's holdings in (usdc, usdt) raw by independent arithmetic (idle + pro-rata band bins) */
  holdings(): Promise<{ usdc: bigint; usdt: bigint }>;
  /** a third-party market swap through the mock router: sells `amountIn` of USDC (true) or USDt (false) */
  marketSwap(sellUsdc: boolean, amountIn: bigint): Promise<void>;
  /** the depositor puts `usdc` raw into the vault */
  deposit(usdc: bigint): Promise<void>;
  /** refreshes both feeds' updatedAt to the chain time */
  refreshFeeds(): Promise<void>;
}

export async function deployRealWorld(anvil: Anvil, mut?: (c: KeeperConfig) => void): Promise<RealWorld> {
  compileStubs();
  const rpc = async <T,>(method: string, params: unknown[] = []): Promise<T> => (await anvil.provider.send(method, params)) as T;
  const mk = (): Wallet => Wallet.createRandom().connect(anvil.provider);
  const [deployer, owner, keeper, trader, whale, alice] = [mk(), mk(), mk(), mk(), mk(), mk()];
  for (const w of [deployer, owner, trader, whale, alice]) await rpc("anvil_setBalance", [w.address, "0x56BC75E2D63100000"]);
  await rpc("anvil_setBalance", [keeper.address, "0xDE0B6B3A7640000"]);
  await rpc("anvil_setCode", [MULTICALL3, stubArt("StubMulticall3").deployed]);
  // the next 08:00 UTC after the chain's current time (several worlds share one anvil): the vault's UTC-day cap then cannot flake on a midnight crossing
  const latest = (await anvil.provider.getBlock("latest")).timestamp;
  const day = 86_400;
  const at8 = Math.max(T0, Math.ceil((latest + 1 - 8 * 3600) / day) * day + 8 * 3600);
  await rpc("evm_setNextBlockTimestamp", [at8]);
  await rpc("evm_mine");
  const dep = async (file: string, name: string, ...args: unknown[]): Promise<Contract> => {
    const a = art(file, name);
    const c = await new ContractFactory(a.abi, a.bytecode, deployer).deploy(...args);
    await c.deployed();
    return c;
  };
  // the live token order: USDt (X) has the lower address; deploy two tokens and name them by address order
  const t1 = await dep("MockERC20", "MockERC20", "T1", "T1", 6);
  const t2 = await dep("MockERC20", "MockERC20", "T2", "T2", 6);
  const [usdt, usdc] = BigInt(t1.address) < BigInt(t2.address) ? [t1, t2] : [t2, t1];
  const phar = await dep("MockERC20", "MockERC20", "Pharaoh", "PHAR", 18);
  const feedUsdc = await dep("MockChainlinkFeed", "MockChainlinkFeed", 99_975_000);
  const feedUsdt = await dep("MockChainlinkFeed", "MockChainlinkFeed", 99_934_000);
  const factory = await dep("MockDlmmInfra", "MockDlmmFactory");
  const voter = await dep("MockDlmmInfra", "MockDlmmVoter");
  const implA = await dep("MockDlmmInfra", "MockRewarderImplA");
  const beacon = await dep("MockDlmmInfra", "MockRewarderBeacon", implA.address);
  await (await voter.setBeacon(beacon.address)).wait();
  const pair = await dep("MockLBPair", "MockLBPair", usdt.address, usdc.address, 1, ID0, factory.address);
  await (await factory.setPair(usdt.address, usdc.address, 1, pair.address)).wait();
  const router = await dep("MockRouter", "MockRouter", factory.address);
  await (await voter.setManager(router.address, true)).wait();
  const rewarder = await dep("MockRewarder", "MockRewarder", pair.address, phar.address, voter.address);
  await (await beacon.setRewarder(pair.address, rewarder.address)).wait();
  await (await pair.setHook(rewarder.address)).wait();
  const quoter = await dep("Compile", "MockPairQuoter", pair.address);

  // a whale LP (11 bins, USD 600k each token, as the mocks' own World) so the vault is a small LP like on chain
  await (await usdc.mint(whale.address, 600_000n * E6)).wait();
  await (await usdt.mint(whale.address, 600_000n * E6)).wait();
  await (await usdc.connect(whale).approve(router.address, ethersMax())).wait();
  await (await usdt.connect(whale).approve(router.address, ethersMax())).wait();
  const d: number[] = [];
  const dX: bigint[] = [];
  const dY: bigint[] = [];
  for (let i = 0; i < 11; i++) {
    d.push(i - 5);
    dY.push(i - 5 <= 0 ? 10n ** 18n / 6n : 0n);
    dX.push(i - 5 >= 0 ? 10n ** 18n / 6n : 0n);
  }
  const now0 = (await anvil.provider.getBlock("latest")).timestamp;
  await (await router.connect(whale).addLiquidity([usdt.address, usdc.address, 1, 600_000n * E6, 600_000n * E6, 0, 0, ID0, 0, d, dX, dY, whale.address, whale.address, now0 + 3600])).wait();

  // the vault: implementation + proxy (admin = owner), initialised in the proxy constructor data (cap 200, rebalancer = the keeper wallet)
  const impl = await dep("PharaohDlmmVault", "PharaohDlmmVault");
  const vaultArt = art("PharaohDlmmVault", "PharaohDlmmVault");
  const implCodehash = utils.keccak256(await anvil.provider.getCode(implA.address));
  const initData = new utils.Interface(vaultArt.abi).encodeFunctionData("initialize", [[usdc.address, usdt.address, pair.address, router.address, factory.address, rewarder.address, implCodehash, feedUsdc.address, feedUsdt.address, 1, owner.address, keeper.address, 200n * E6, "Peridot Pharaoh DLMM USDC/USDt", "pDLMM"]]);
  const proxy = await dep("TransparentUpgradeableProxy", "TransparentUpgradeableProxy", impl.address, owner.address, initData);
  const vault = new Contract(proxy.address, vaultArt.abi, deployer);
  await (await vault.connect(owner).unpause()).wait(); // initialize leaves the vault paused (DEVIATIONS.md)

  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "dlmm-real-"));
  const cfg = decidedConfig(dir);
  cfg.vault = vault.address;
  cfg.pair = pair.address;
  cfg.quoter = quoter.address;
  cfg.assetToken = usdc.address;
  cfg.pairToken = usdt.address;
  cfg.feeds = { asset: feedUsdc.address, pair: feedUsdt.address };
  cfg.keeper = { address: keeper.address };
  cfg.limits.minWalletWei = "1000000000000";
  cfg.probe.everyCycles = 1;
  mut?.(cfg);

  const w: RealWorld = {
    anvil, cfg, dir, deployer, owner, keeper, trader, alice, usdc, usdt, phar, feedUsdc, feedUsdt, pair, router, rewarder, vault, quoter, rpc,
    now: async () => (await anvil.provider.getBlock("latest")).timestamp,
    tick: async (secs) => {
      if (secs > 0) await rpc("evm_increaseTime", [secs]);
      await rpc("evm_mine");
      return (await anvil.provider.getBlock("latest")).timestamp;
    },
    holdings: async () => {
      let u = BigInt((await usdc.balanceOf(vault.address)).toString());
      let t = BigInt((await usdt.balanceOf(vault.address)).toString());
      const act = Number(await pair.getActiveId());
      for (let id = act - 12; id <= act + 12; id++) {
        const sh = BigInt((await pair.balanceOf(vault.address, id)).toString());
        if (sh === 0n) continue;
        const sup = BigInt((await pair.totalSupply(id)).toString());
        const bin = await pair.getBin(id);
        t += (sh * BigInt(bin[0].toString())) / sup; // X = USDt
        u += (sh * BigInt(bin[1].toString())) / sup; // Y = USDC
      }
      return { usdc: u, usdt: t };
    },
    marketSwap: async (sellUsdc, amountIn) => {
      const tin = sellUsdc ? usdc : usdt;
      const tout = sellUsdc ? usdt : usdc;
      await (await tin.mint(trader.address, amountIn)).wait();
      await (await tin.connect(trader).approve(router.address, amountIn)).wait();
      const nowT = (await anvil.provider.getBlock("latest")).timestamp;
      await (await router.connect(trader).swapExactTokensForTokens(amountIn, 0, [[1], [2], [tin.address, tout.address]], trader.address, nowT + 3600)).wait();
    },
    deposit: async (amt) => {
      await (await usdc.mint(alice.address, amt)).wait();
      await (await usdc.connect(alice).approve(vault.address, amt)).wait();
      await (await vault.connect(alice).deposit(amt, alice.address)).wait();
    },
    refreshFeeds: async () => {
      const ts = await w.now();
      await (await feedUsdc.setUpdatedAt(ts)).wait();
      await (await feedUsdt.setUpdatedAt(ts)).wait();
    },
  };
  return w;
}
const ethersMax = (): BigNumber => BigNumber.from(2).pow(256).sub(1);

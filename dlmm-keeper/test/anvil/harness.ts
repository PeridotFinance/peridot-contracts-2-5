// LOCAL anvil harness WITHOUT a fork: a throwaway chain (chain id 43114, so the keeper's chain check passes), the stub contracts of test/stub compiled on demand
// with forge (solc 0.8.24 from the local cache, offline), a throwaway keeper wallet made with Wallet.createRandom and funded with anvil_setBalance.
// No lock is needed (nothing touches a remote endpoint). No real key exists anywhere in it; nothing is signed except on the local chain.
import { ChildProcess, spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { BigNumber, ContractFactory, providers, utils, Wallet } from "ethers";
import { MULTICALL3 } from "../../src/constants";
import type { KeeperConfig } from "../../src/config";
import { decidedConfig } from "../fixtures";

export const hasTool = (name: string): boolean => spawnSync(name, ["--version"], { encoding: "utf8" }).status === 0;
export function toolsAvailable(): boolean {
  return hasTool("anvil") && hasTool("forge");
}

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.listen(0, "127.0.0.1", () => {
      const p = (s.address() as net.AddressInfo).port;
      s.close(() => resolve(p));
    });
    s.on("error", reject);
  });
}

/** counts every JSON-RPC request that leaves the keeper (the proof of "calls nothing while halted") */
export class CountingProvider extends providers.StaticJsonRpcProvider {
  requests = 0;
  async send(method: string, params: Array<unknown>): Promise<unknown> {
    this.requests++;
    return super.send(method, params);
  }
}

let artifacts: { out: string } | undefined;
export function compileStubs(): string {
  if (artifacts) return artifacts.out;
  const out = fs.mkdtempSync(path.join(os.tmpdir(), "dlmm-stub-out-"));
  const cache = fs.mkdtempSync(path.join(os.tmpdir(), "dlmm-stub-cache-"));
  const r = spawnSync("forge", ["build", "--root", path.join(__dirname, "..", "..", "..", "test", "stub")], { encoding: "utf8", env: { ...process.env, FOUNDRY_OUT: out, FOUNDRY_CACHE_PATH: cache } });
  if (r.status !== 0) throw new Error(`forge build of the stubs failed: ${(r.stdout + r.stderr).slice(-800)}`);
  artifacts = { out };
  return out;
}
const art = (name: string): { abi: any[]; bytecode: string; deployed: string } => {
  const j = JSON.parse(fs.readFileSync(path.join(compileStubs(), "Stubs.sol", `${name}.json`), "utf8"));
  return { abi: j.abi, bytecode: j.bytecode.object, deployed: j.deployedBytecode.object };
};
export const stubAbi = (name: string): any[] => art(name).abi;

export interface Anvil {
  url: string;
  proc: ChildProcess;
  provider: CountingProvider;
  stop(): void;
}
export async function startAnvil(blockTimeSeconds?: number): Promise<Anvil> {
  const port = await freePort();
  const args = ["--chain-id", "43114", "--port", String(port), "--host", "127.0.0.1", "--silent", "--accounts", "1"];
  if (blockTimeSeconds) args.push("--block-time", String(blockTimeSeconds));
  const proc = spawn("anvil", args, { stdio: "ignore" });
  const url = `http://127.0.0.1:${port}`;
  const provider = new CountingProvider(url, { chainId: 43114, name: "avalanche" });
  for (let i = 0; i < 100; i++) {
    try {
      await new providers.StaticJsonRpcProvider(url, { chainId: 43114, name: "x" }).send("eth_chainId", []);
      return { url, proc, provider, stop: () => void proc.kill("SIGKILL") };
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  proc.kill("SIGKILL");
  throw new Error("anvil did not start");
}

export interface StubWorld {
  anvil: Anvil;
  cfg: KeeperConfig;
  dir: string;
  keeper: Wallet;
  usdc: string;
  usdt: string;
  pair: any;
  vault: any;
  feedAsset: any;
  feedPair: any;
  rpc<T = unknown>(method: string, params?: unknown[]): Promise<T>;
  /** advance chain time by `secs` and mine a block; returns the new block timestamp */
  tick(secs: number): Promise<number>;
  now(): Promise<number>;
  /** put `y` raw USDC (all-Y band) in the vault's 3 bins and move the active id above the band, or back */
  exitUp(y: bigint): Promise<void>;
  enterBand(): Promise<void>;
}

/** A fresh stub world on a running anvil: tokens (X = USDt, Y = USDC as on the live pair), feeds, pair, vault with the keeper wallet as rebalancer, Multicall3 at its standard address. */
export async function deployWorld(anvil: Anvil, mut?: (c: KeeperConfig) => void): Promise<StubWorld> {
  const rpc = async <T,>(method: string, params: unknown[] = []): Promise<T> => (await anvil.provider.send(method, params)) as T;
  const deployer = Wallet.createRandom().connect(anvil.provider);
  const keeper = Wallet.createRandom().connect(anvil.provider);
  await rpc("anvil_setBalance", [deployer.address, "0x56BC75E2D63100000"]); // 100
  await rpc("anvil_setBalance", [keeper.address, "0xDE0B6B3A7640000"]); // 1
  const dep = async (name: string, ...args: unknown[]): Promise<any> => {
    const a = art(name);
    const c = await new ContractFactory(a.abi, a.bytecode, deployer).deploy(...args);
    await c.deployed();
    return c;
  };
  await rpc("anvil_setCode", [MULTICALL3, art("StubMulticall3").deployed]);
  const usdt = await dep("StubToken");
  const usdc = await dep("StubToken");
  const feedAsset = await dep("StubFeed");
  const feedPair = await dep("StubFeed");
  const now0 = (await anvil.provider.getBlock("latest")).timestamp;
  await (await feedAsset.set(99_975_000, now0 - 3600)).wait();
  await (await feedPair.set(99_934_000, now0 - 3600)).wait();
  const ACTIVE = 8_388_608;
  const pair = await dep("StubPair", usdt.address, usdc.address, ACTIVE);
  const vault = await dep("StubVault", pair.address, keeper.address, ACTIVE - 1, ACTIVE + 1);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "dlmm-anvil-"));
  const cfg = decidedConfig(dir);
  cfg.vault = vault.address;
  cfg.pair = pair.address;
  cfg.assetToken = usdc.address;
  cfg.pairToken = usdt.address;
  cfg.feeds = { asset: feedAsset.address, pair: feedPair.address };
  cfg.keeper = { address: keeper.address };
  cfg.limits.minWalletWei = "1000000000000";
  mut?.(cfg);
  const w: StubWorld = {
    anvil, cfg, dir, keeper, usdc: usdc.address, usdt: usdt.address, pair, vault, feedAsset, feedPair, rpc,
    now: async () => (await anvil.provider.getBlock("latest")).timestamp,
    tick: async (secs) => {
      if (secs > 0) await rpc("evm_increaseTime", [secs]);
      await rpc("evm_mine");
      return (await anvil.provider.getBlock("latest")).timestamp;
    },
    exitUp: async (y) => {
      for (const id of [ACTIVE - 1, ACTIVE, ACTIVE + 1]) await (await pair.setBin(id, 0, BigNumber.from(y).mul(10).div(3), 10_000, vault.address, 1000)).wait();
      await (await pair.setActive(ACTIVE + 3)).wait();
    },
    enterBand: async () => void (await (await pair.setActive(ACTIVE)).wait()),
  };
  return w;
}
export const fmt = utils.formatUnits;

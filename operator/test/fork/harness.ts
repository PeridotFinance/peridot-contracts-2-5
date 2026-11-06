// Fork harness: a LOCAL anvil fork of Avalanche C-Chain at the pinned block 99,200,000 (the block every Foundry fork suite uses).
//   * The private archive RPC is read from the ENVIRONMENT and reached through a tiny local pass-through proxy, so the URL is never an
//     argument of the anvil process, never printed and never written; anvil only ever sees http://127.0.0.1:<port>.
//   * Nothing is signed: accounts are IMPERSONATED on the local fork (`--auto-impersonate`). No key exists in this package.
//   * The deployment replays the cash-only fixture of `AvalancheCashOnlyBase` (opt-in controller, no reward token), compiled by
//     `forge build` with the debt_accounting profile into operator/.forge-out.
import { ChildProcess, spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import https from "node:https";
import net from "node:net";
import path from "node:path";
import { BigNumber, Contract, ContractFactory, providers, utils } from "ethers";
import { AVAX_FEED, UNIV3_POOL_WAVAX_USDC_500, USDC, USDC_FEED, WAVAX } from "../../src/constants";
import { requireRpcUrlFromEnv } from "../../src/config";
import { safeError } from "../../src/mask";

export const PIN_BLOCK = 99_200_000;
utils.Logger.setLogLevel(utils.Logger.levels.ERROR); // silences ethers' warning for the overloaded ActionPaused event

/** Merge ABIs, dropping exact duplicates (same type, name and input types). */
function mergeAbi(...abis: any[][]): any[] {
  const seen = new Set<string>();
  const out: any[] = [];
  for (const abi of abis) for (const e of abi) {
    const k = `${e.type}:${e.name ?? ""}(${(e.inputs ?? []).map((i: any) => i.type).join(",")})`;
    if (!seen.has(k)) { seen.add(k); out.push(e); }
  }
  return out;
}
const OUT = path.join(__dirname, "..", "..", "..", ".forge-out");

export function artifacts(): { present: boolean } {
  return { present: fs.existsSync(path.join(OUT, "PErc20Delegator.sol", "PErc20Delegator.json")) };
}
export function art(file: string, name: string): { abi: any[]; bytecode: string; deployed: string } {
  const j = JSON.parse(fs.readFileSync(path.join(OUT, `${file}.sol`, `${name}.json`), "utf8"));
  return { abi: j.abi, bytecode: j.bytecode.object, deployed: j.deployedBytecode.object };
}

export function rpcAvailable(): boolean {
  try {
    requireRpcUrlFromEnv();
    return true;
  } catch {
    return false;
  }
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

/** Pass-through to the private endpoint. Never logs a URL, header or body. */
function startProxy(upstream: string): Promise<{ server: http.Server; port: number; stats: { requests: number; non200: number } }> {
  const u = new URL(upstream);
  const stats = { requests: 0, non200: 0 };
  const server = http.createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      stats.requests++;
      const body = Buffer.concat(chunks);
      const lib = u.protocol === "https:" ? https : http;
      const up = lib.request({ hostname: u.hostname, port: u.port || (u.protocol === "https:" ? 443 : 80), path: u.pathname + u.search, method: "POST", headers: { "content-type": "application/json", "content-length": body.length, ...(u.username ? { authorization: "Basic " + Buffer.from(decodeURIComponent(u.username) + ":" + decodeURIComponent(u.password)).toString("base64") } : {}) } }, (r) => {
        if (r.statusCode !== 200) stats.non200++;
        res.writeHead(r.statusCode ?? 502, { "content-type": "application/json" });
        r.pipe(res);
      });
      up.on("error", () => {
        stats.non200++;
        res.writeHead(502);
        res.end('{"error":"upstream unreachable"}');
      });
      up.end(body);
    });
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve({ server, port: (server.address() as net.AddressInfo).port, stats })));
}

export class ForkChain {
  provider!: providers.JsonRpcProvider;
  private anvil!: ChildProcess;
  private proxy!: http.Server;
  proxyStats!: { requests: number; non200: number };
  anvilLog = "";

  static async start(): Promise<ForkChain> {
    const f = new ForkChain();
    const upstream = requireRpcUrlFromEnv();
    const px = await startProxy(upstream);
    f.proxy = px.server;
    f.proxyStats = px.stats;
    const port = await freePort();
    f.anvil = spawn("anvil", ["--fork-url", `http://127.0.0.1:${px.port}`, "--fork-block-number", String(PIN_BLOCK), "--port", String(port), "--auto-impersonate", "--code-size-limit", "1000000", "--gas-limit", "1000000000", "--retries", "20", "--fork-retry-backoff", "1000", "--compute-units-per-second", "200", "--no-rate-limit", "--silent"], { stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, AVALANCHE_MAINNET_RPC_URL: "", AVALANCHE_RPC: "" } });
    f.anvil.stdout?.on("data", (d) => (f.anvilLog += String(d)));
    f.anvil.stderr?.on("data", (d) => (f.anvilLog += String(d)));
    f.provider = new providers.JsonRpcProvider(`http://127.0.0.1:${port}`, { chainId: 43114, name: "avalanche-fork" });
    for (let i = 0; i < 120; i++) {
      try {
        await f.provider.send("eth_chainId", []);
        break;
      } catch {
        await new Promise((r) => setTimeout(r, 500));
        if (i === 119) throw new Error("anvil did not start: " + safeError(f.anvilLog));
      }
    }
    return f;
  }

  async stop(): Promise<void> {
    this.anvil?.kill("SIGTERM");
    await new Promise<void>((r) => this.proxy?.close(() => r()));
  }

  send(method: string, params: unknown[] = []): Promise<any> {
    return this.provider.send(method, params);
  }
  signer(addr: string): providers.JsonRpcSigner {
    return this.provider.getSigner(addr);
  }
  async setBalance(addr: string, wei: BigNumber = utils.parseEther("1000000")): Promise<void> {
    await this.send("anvil_setBalance", [addr, wei.toHexString()]);
  }
  async setCode(addr: string, code: string): Promise<void> {
    await this.send("anvil_setCode", [addr, code]);
  }
  async mine(n = 1, intervalSeconds = 1): Promise<void> {
    await this.send("anvil_mine", ["0x" + n.toString(16), "0x" + intervalSeconds.toString(16)]);
  }
  async increaseTime(seconds: number): Promise<void> {
    // with a fixed block timestamp interval anvil ignores evm_increaseTime, so set the next block's timestamp explicitly
    await this.send("evm_setNextBlockTimestamp", [(await this.now()) + seconds]);
    await this.send("evm_mine", []);
  }
  async snapshot(): Promise<string> {
    return this.send("evm_snapshot");
  }
  async revert(id: string): Promise<void> {
    if (!(await this.send("evm_revert", [id]))) throw new Error("evm_revert failed");
  }
  async now(): Promise<number> {
    return (await this.provider.getBlock("latest")).timestamp;
  }

  /** Set an ERC-20 balance by finding the balance mapping slot (tries slots 0..30 and checks the effect). */
  async setErc20Balance(token: string, holder: string, amount: BigNumber): Promise<void> {
    const erc = new Contract(token, ["function balanceOf(address) view returns (uint256)"], this.provider);
    for (let slot = 0; slot < 31; slot++) {
      const key = utils.keccak256(utils.defaultAbiCoder.encode(["address", "uint256"], [holder, slot]));
      const old: string = await this.send("eth_getStorageAt", [token, key, "latest"]);
      await this.send("anvil_setStorageAt", [token, key, utils.hexZeroPad(amount.toHexString(), 32)]);
      if ((await erc.balanceOf(holder)).eq(amount)) return;
      await this.send("anvil_setStorageAt", [token, key, old]);
    }
    throw new Error("balance slot not found for " + token);
  }
}

/** Test-only mocks (contracts/test/helpers/MonitorForkMocks.sol) etched over the real feeds and the real pool. */
export class Mocks {
  feedAbi = art("MonitorForkMocks", "MonitorMockFeed");
  poolAbi = art("MonitorForkMocks", "MonitorMockPool");
  constructor(private readonly chain: ForkChain, private readonly admin: string) {}
  async install(): Promise<void> {
    for (const feed of [AVAX_FEED, USDC_FEED]) await this.chain.setCode(feed, this.feedAbi.deployed);
    await this.chain.setCode(UNIV3_POOL_WAVAX_USDC_500, this.poolAbi.deployed);
  }
  feed(addr: string): any {
    return new Contract(addr, this.feedAbi.abi, this.chain.signer(this.admin));
  }
  pool(): any {
    return new Contract(UNIV3_POOL_WAVAX_USDC_500, this.poolAbi.abi, this.chain.signer(this.admin));
  }
}

export interface Deployed {
  // ethers Contract objects with dynamic ABIs; typed `any` because the generated method names are not known to the compiler
  controller: any;
  pWavax: any;
  pUsdc: any;
  oracle: any;
  inner: any;
  addresses: { controller: string; pWavax: string; pUsdc: string; oracle: string };
  deployBlock: number;
}

export async function deployCashOnly(chain: ForkChain, admin: string): Promise<Deployed> {
  const s = chain.signer(admin);
  const deploy = async (file: string, name: string, args: unknown[] = []): Promise<any> => {
    const a = art(file, name);
    const c = await new ContractFactory(a.abi, a.bytecode, s).deploy(...args, { gasLimit: 60_000_000 });
    await c.deployed();
    return c;
  };
  const tx = async (p: Promise<any>) => (await (await p).wait()).status === 1 || (() => { throw new Error("tx failed"); })();
  const deployBlock = (await chain.provider.getBlockNumber()) + 1;
  const inner = await deploy("AvalanchePriceOracle", "AvalanchePriceOracle", [admin]);
  await tx(inner.configureFeed(WAVAX, AVAX_FEED, 1200));
  await tx(inner.configureFeed(USDC, USDC_FEED, 90000));
  const oracle = await deploy("GuardedAvalanchePriceOracle", "GuardedAvalanchePriceOracle", [inner.address]);
  const unitroller = await deploy("Unitroller", "Unitroller");
  const impl = await deploy("PeridottrollerAvalanche", "PeridottrollerAvalanche", [ethersZero(), true]); // the pilot's explicit no-reward-token opt-in
  await tx(unitroller._setPendingImplementation(impl.address));
  await tx(impl._become(unitroller.address));
  const controller: any = new Contract(unitroller.address, art("PeridottrollerAvalanche", "PeridottrollerAvalanche").abi, s);
  const irm = await deploy("ConfigurableJumpRateModelV2", "ConfigurableJumpRateModelV2", [31_536_000, utils.parseEther("0.02"), utils.parseEther("0.1"), utils.parseEther("1"), utils.parseEther("0.8"), admin]);
  const delegate = await deploy("PErc20Delegate", "PErc20Delegate");
  const market = async (underlying: string, initialRate: BigNumber, name: string, symbol: string): Promise<any> => {
    const c = await deploy("PErc20Delegator", "PErc20Delegator", [underlying, controller.address, irm.address, initialRate, name, symbol, 8, admin, delegate.address, "0x"]);
    return new Contract(c.address, mergeAbi(art("PErc20", "PErc20").abi, art("PToken", "PToken").abi.filter((x: any) => x.type === "function" || x.type === "event")), s);
  };
  const pWavax = await market(WAVAX, BigNumber.from(2).mul(BigNumber.from(10).pow(26)), "Peridot Wrapped AVAX", "pWAVAX");
  const pUsdc = await market(USDC, BigNumber.from(2).mul(BigNumber.from(10).pow(14)), "Peridot USD Coin", "pUSDC");
  await tx(controller._setPriceOracle(oracle.address));
  await tx(controller._setCloseFactor(utils.parseEther("0.5")));
  await tx(controller._setLiquidationIncentive(utils.parseEther("1.08")));
  await tx(controller._setPauseGuardian(admin));
  await tx(controller._supportMarket(pWavax.address));
  await tx(controller._supportMarket(pUsdc.address));
  await tx(controller._setBorrowPaused(pWavax.address, true));
  await tx(controller._setBorrowPaused(pUsdc.address, true));
  await tx(pWavax._setFlashLoansPaused(true));
  await tx(pUsdc._setFlashLoansPaused(true));
  await tx(pWavax._setReserveFactor(utils.parseEther("0.1")));
  await tx(pUsdc._setReserveFactor(utils.parseEther("0.1")));
  await tx(inner.registerMarket(pWavax.address, WAVAX));
  await tx(inner.registerMarket(pUsdc.address, USDC));
  return { controller, pWavax, pUsdc, oracle, inner, addresses: { controller: controller.address, pWavax: pWavax.address, pUsdc: pUsdc.address, oracle: oracle.address }, deployBlock };
}

function ethersZero(): string {
  return "0x0000000000000000000000000000000000000000";
}

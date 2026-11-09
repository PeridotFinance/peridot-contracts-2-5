// Fork harness (copied from operator/test/fork/harness.ts, trimmed): a LOCAL anvil fork of the CURRENT Avalanche head.
//   * the private RPC endpoint is read from the ENVIRONMENT (AVALANCHE_MAINNET_RPC_URL) and reached through a tiny local pass-through proxy, so the URL is
//     never an argument of the anvil process, never printed and never written; anvil only ever sees http://127.0.0.1:<port>.
//   * the proxy counts upstream answers; HTTP 429 is counted separately and the suite STOPS on the first one (free-tier endpoint: no retries, no switching).
//   * nothing real is signed: the stack's accounts are IMPERSONATED (`--auto-impersonate`); the KEEPER wallet is a throwaway key whose keystore the test writes.
import { ChildProcess, spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import https from "node:https";
import net from "node:net";
import path from "node:path";
import { BigNumber, Contract, providers, utils } from "ethers";
import { requireRpcUrlFromEnv } from "../../src/config";
import { safeError } from "../../src/mask";

export const AVAX_FEED = "0x0A77230d17318075983913bC2145DB16C7366156";
export const USDC_FEED = "0xF096872672F44d6EBA71458D74fe67F9a77a23B9";
utils.Logger.setLogLevel(utils.Logger.levels.ERROR);

export function repoRoot(): string {
  let d = __dirname;
  for (let i = 0; i < 8; i++) {
    if (fs.existsSync(path.join(d, "contracts", "foundry.toml")) && fs.existsSync(path.join(d, "docs"))) return d;
    d = path.dirname(d);
  }
  throw new Error("repository root not found");
}
/** compiled artifacts holding MonitorForkMocks (settable Chainlink feed mock): ORDER_KEEPER_FORGE_OUT, else the operator's build (read only) */
function forgeOut(): string {
  return process.env.ORDER_KEEPER_FORGE_OUT || path.join(repoRoot(), "operator", ".forge-out");
}
export function art(file: string, name: string): { abi: any[]; deployed: string } {
  const j = JSON.parse(fs.readFileSync(path.join(forgeOut(), `${file}.sol`, `${name}.json`), "utf8"));
  return { abi: j.abi, deployed: j.deployedBytecode.object };
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
function startProxy(upstream: string, onRateLimit: () => void): Promise<{ server: http.Server; port: number; stats: { requests: number; non200: number; http429: number } }> {
  const u = new URL(upstream);
  const stats = { requests: 0, non200: 0, http429: 0 };
  const server = http.createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      stats.requests++;
      const body = Buffer.concat(chunks);
      const lib = u.protocol === "https:" ? https : http;
      const up = lib.request({ hostname: u.hostname, port: u.port || (u.protocol === "https:" ? 443 : 80), path: u.pathname + u.search, method: "POST", headers: { "content-type": "application/json", "content-length": body.length, ...(u.username ? { authorization: "Basic " + Buffer.from(decodeURIComponent(u.username) + ":" + decodeURIComponent(u.password)).toString("base64") } : {}) } }, (r) => {
        if (r.statusCode !== 200) stats.non200++;
        if (r.statusCode === 429) {
          stats.http429++;
          onRateLimit();
        }
        res.writeHead(r.statusCode ?? 502, { "content-type": "application/json" });
        r.pipe(res);
      });
      // a stalled upstream request must not hang the fork: after 15 s answer 504 so that anvil's own retry logic re-asks
      up.setTimeout(15_000, () => up.destroy(new Error("upstream timeout")));
      up.on("error", () => {
        stats.non200++;
        if (!res.headersSent) res.writeHead(504);
        res.end('{"error":"upstream timeout or unreachable"}');
      });
      up.end(body);
    });
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve({ server, port: (server.address() as net.AddressInfo).port, stats })));
}

/**
 * ethers v5 re-checks pending transactions only when its polling sees a NEW block number, which an instant-mining local node (or a node that has just
 * been reverted to a lower block) may never produce for an already-mined transaction: `tx.wait()` then stalls forever. For the fork tests the wait is
 * replaced by a direct receipt poll. (Production code uses the stock provider; this class exists only in the test harness.)
 */
class ForkProvider extends providers.JsonRpcProvider {
  async _waitForTransaction(hash: string, confirmations: number, timeout: number, _replaceable: unknown): Promise<providers.TransactionReceipt> {
    const deadline = Date.now() + (timeout || 120_000);
    for (;;) {
      const raw = await this.send("eth_getTransactionReceipt", [hash]);
      if (raw && raw.blockNumber) {
        const r = this.formatter.receipt(raw);
        r.confirmations = Math.max(1, confirmations);
        return r;
      }
      if (Date.now() > deadline) throw new Error(`timeout waiting for ${hash}`);
      await new Promise((res) => setTimeout(res, 20));
    }
  }
}

export class ForkChain {
  provider!: providers.JsonRpcProvider;
  private anvil!: ChildProcess;
  private proxy!: http.Server;
  proxyStats!: { requests: number; non200: number; http429: number };
  anvilLog = "";

  url = "";

  /** `forkBlock`: a block number, or "latest" for the current mainnet head (the ceremony rehearsal); default = the pinned block of the study. */
  static async start(forkBlock: number | "latest" = "latest"): Promise<ForkChain> {
    const f = new ForkChain();
    const upstream = requireRpcUrlFromEnv();
    const px = await startProxy(upstream, () => {
      // the free-tier endpoint answered 429: STOP the fork work at once, do not retry, do not switch providers
      console.error("UPSTREAM-HTTP-429: the state endpoint rate-limited the fork; stopping (no retry, no other provider)");
      f.anvil?.kill("SIGKILL");
      process.exit(42);
    });
    f.proxy = px.server;
    f.proxyStats = px.stats;
    const port = await freePort();
    f.anvil = spawn("anvil", ["--fork-url", `http://127.0.0.1:${px.port}`, ...(forkBlock === "latest" ? [] : ["--fork-block-number", String(forkBlock)]), "--port", String(port), "--auto-impersonate", "--code-size-limit", "1000000", "--gas-limit", "1000000000", "--retries", "20", "--fork-retry-backoff", "1000", "--compute-units-per-second", process.env.ORDER_KEEPER_FORK_CUPS ?? "40", "--silent"], { stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, AVALANCHE_MAINNET_RPC_URL: "", AVALANCHE_RPC: "" } });
    f.anvil.stdout?.on("data", (d) => (f.anvilLog += String(d)));
    f.anvil.stderr?.on("data", (d) => (f.anvilLog += String(d)));
    f.url = `http://127.0.0.1:${port}`;
    f.provider = new ForkProvider(`http://127.0.0.1:${port}`, { chainId: 43114, name: "avalanche-fork" });
    f.provider.pollingInterval = 100; // ethers polls receipts every 4 s by default; the local fork mines instantly
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
  constructor(private readonly chain: ForkChain, private readonly admin: string) {}
  /** only the Chainlink feeds (the real Uniswap pool stays real: the executor swaps through it) */
  async installFeedsOnly(): Promise<void> {
    for (const feed of [AVAX_FEED, USDC_FEED]) await this.chain.setCode(feed, this.feedAbi.deployed);
  }
  feed(addr: string): any {
    return new Contract(addr, this.feedAbi.abi, this.chain.signer(this.admin));
  }
}


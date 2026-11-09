// Fork harness for the keeper's ANVIL test. A LOCAL anvil fork of Avalanche C-Chain at the fixture's pinned block:
//   * the private RPC is read from the ENVIRONMENT (AVALANCHE_MAINNET_RPC_URL) and reached through a local pass-through proxy, so the URL is never an
//     argument of the anvil process, never printed and never written (same device as operator/test/fork/harness.ts, copied here);
//   * nothing real is signed or sent: accounts are IMPERSONATED on the LOCAL fork (127.0.0.1) and every transaction goes to the local node only;
//   * the fixture (margin stack, range upgrade, a 2x long with a 70/20/10 ladder, the market traded through all rungs) is the state dumped by
//     contracts/range-tp/test/KeeperFixtureDump.t.sol and is replayed with anvil_set* calls.
import { ChildProcess, spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import https from "node:https";
import net from "node:net";
import path from "node:path";
import { providers } from "ethers";
import type { ExternalSigner, SentTx, TxRequest } from "../../src/signer";
import { safeError } from "../../src/mask";

export const FIXTURE_DIR = path.join(__dirname, "..", "..", "..", "..", "contracts", "range-tp", "fixtures");
export const MOCK_FEED_ARTIFACT = path.join(__dirname, "..", "..", "..", "..", "contracts", "range-tp", "out", "MockFeed.sol", "MockFeed.json");

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
function startProxy(upstream: string): Promise<{ server: http.Server; port: number; stats: { requests: number; non200: number; last429: boolean } }> {
  const u = new URL(upstream);
  const stats = { requests: 0, non200: 0, last429: false };
  const server = http.createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      stats.requests++;
      const body = Buffer.concat(chunks);
      const lib = u.protocol === "https:" ? https : http;
      const up = lib.request({ hostname: u.hostname, port: u.port || (u.protocol === "https:" ? 443 : 80), path: u.pathname + u.search, method: "POST", headers: { "content-type": "application/json", "content-length": body.length, ...(u.username ? { authorization: "Basic " + Buffer.from(decodeURIComponent(u.username) + ":" + decodeURIComponent(u.password)).toString("base64") } : {}) } }, (r) => {
        if (r.statusCode !== 200) stats.non200++;
        if (r.statusCode === 429) stats.last429 = true;
        res.writeHead(r.statusCode ?? 502, { "content-type": "application/json" });
        r.pipe(res);
      });
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

/** ethers v5 may never re-check an already-mined tx on an instant-mining local node: poll the receipt directly (test harness only). */
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

export class Fork {
  provider!: providers.JsonRpcProvider;
  stats!: { requests: number; non200: number; last429: boolean };
  url = "";
  private anvil!: ChildProcess;
  private proxy!: http.Server;
  anvilLog = "";

  static async start(forkBlock: number): Promise<Fork> {
    const f = new Fork();
    const upstream = process.env.AVALANCHE_MAINNET_RPC_URL;
    if (!upstream) throw new Error("AVALANCHE_MAINNET_RPC_URL is not set");
    const px = await startProxy(upstream);
    f.proxy = px.server;
    f.stats = px.stats;
    const port = await freePort();
    f.anvil = spawn("anvil", ["--fork-url", `http://127.0.0.1:${px.port}`, "--fork-block-number", String(forkBlock), "--port", String(port), "--auto-impersonate", "--code-size-limit", "1000000", "--gas-limit", "1000000000", "--retries", "20", "--fork-retry-backoff", "1000", "--compute-units-per-second", "200", "--no-rate-limit", "--silent"], { stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, AVALANCHE_MAINNET_RPC_URL: "", AVALANCHE_RPC: "" } });
    f.anvil.stdout?.on("data", (d) => (f.anvilLog += String(d)));
    f.anvil.stderr?.on("data", (d) => (f.anvilLog += String(d)));
    f.url = `http://127.0.0.1:${port}`;
    f.provider = new ForkProvider(f.url, { chainId: 43114, name: "avalanche-fork" });
    f.provider.pollingInterval = 100;
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
    // ethers' poller and the proxy's keep-alive sockets would keep the process alive after the test
    this.provider?.removeAllListeners();
    (this.provider as providers.JsonRpcProvider & { polling: boolean }).polling = false;
    this.anvil?.kill("SIGKILL");
    this.anvil?.stdout?.destroy(); // the pipes to the child keep the event loop alive otherwise (found with process._getActiveHandles())
    this.anvil?.stderr?.destroy();
    this.anvil?.unref();
    this.proxy?.closeAllConnections();
    this.proxy?.close();
  }
  rpc<T = any>(method: string, params: unknown[] = []): Promise<T> {
    return this.provider.send(method, params);
  }

  /** replays a `vm.dumpState` file: balance, nonce, code and every storage slot of every account */
  async loadDump(file: string): Promise<number> {
    const dump = JSON.parse(fs.readFileSync(file, "utf8")) as Record<string, { nonce: string | number; balance: string; code: string; storage: Record<string, string> }>;
    const hex = (v: string | number): string => (typeof v === "number" ? "0x" + v.toString(16) : v.startsWith("0x") ? v : "0x" + BigInt(v).toString(16));
    const skip = new Set(["0x7109709ecfa91a80626ff3989d68f67f5b1dd12d", "0x000000000000000000636f6e736f6c652e6c6f67"]);
    let slots = 0;
    for (const [addr, a] of Object.entries(dump)) {
      if (skip.has(addr.toLowerCase())) continue;
      await this.rpc("anvil_setBalance", [addr, hex(a.balance)]);
      await this.rpc("anvil_setNonce", [addr, hex(a.nonce)]);
      if (a.code && a.code !== "0x") await this.rpc("anvil_setCode", [addr, a.code]);
      for (const [k, v] of Object.entries(a.storage ?? {})) {
        await this.rpc("anvil_setStorageAt", [addr, hexPad(k), hexPad(v)]);
        slots++;
      }
    }
    return slots;
  }

  async setNextTimestampAndMine(ts: number): Promise<void> {
    await this.rpc("evm_setNextBlockTimestamp", [ts]);
    await this.rpc("evm_mine", []);
  }

  /** replaces the aggregator at `feed` by the MockFeed code and sets its two words (slot 0 answer, slot 1 updatedAt) */
  async mockFeed(feed: string, answer8: bigint, updatedAt: number): Promise<void> {
    const art = JSON.parse(fs.readFileSync(MOCK_FEED_ARTIFACT, "utf8"));
    await this.rpc("anvil_setCode", [feed, art.deployedBytecode.object]);
    await this.setFeed(feed, answer8, updatedAt);
  }
  async setFeed(feed: string, answer8: bigint, updatedAt: number): Promise<void> {
    await this.rpc("anvil_setStorageAt", [feed, hexPad("0x0"), hexPad("0x" + answer8.toString(16))]);
    await this.rpc("anvil_setStorageAt", [feed, hexPad("0x1"), hexPad("0x" + updatedAt.toString(16))]);
  }
}
function hexPad(v: string): string {
  const h = (v.startsWith("0x") ? v.slice(2) : BigInt(v).toString(16)).padStart(64, "0");
  return "0x" + h;
}

/** Test-only signer: an IMPERSONATED account on the local fork. Production uses KeystoreSigner. */
export class ImpersonatedSigner implements ExternalSigner {
  readonly kind = "anvil-impersonated";
  constructor(private readonly provider: providers.JsonRpcProvider, private readonly address: string) {}
  async getAddress(): Promise<string> {
    return this.address;
  }
  async sendTransaction(tx: TxRequest): Promise<SentTx> {
    const sent = await this.provider.getSigner(this.address).sendTransaction({ type: 2, to: tx.to, data: tx.data, value: 0, gasLimit: tx.gasLimit, maxFeePerGas: tx.maxFeePerGas, maxPriorityFeePerGas: tx.maxPriorityFeePerGas });
    return {
      hash: sent.hash,
      wait: async () => {
        const r = await sent.wait(1);
        return { status: r.status, blockNumber: r.blockNumber, gasUsed: r.gasUsed };
      },
    };
  }
}

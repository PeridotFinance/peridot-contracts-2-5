// Fork harness (trimmed from the production keeper's): a LOCAL anvil fork of Avalanche at a pinned block.
//   * the private RPC endpoint is read from the ENVIRONMENT (AVALANCHE_MAINNET_RPC_URL) and reached through a tiny local pass-through proxy, so the URL is
//     never an argument of the anvil process, never printed and never written; anvil only ever sees http://127.0.0.1:<port>.
//   * HTTP 429 from upstream STOPS the suite at once (exit 42): no retry, no other provider.
//   * UNVERIFIED: this file has been compiled but NOT run (the fork queue belongs to the main thread; see README).
import { ChildProcess, spawn } from "node:child_process";
import http from "node:http";
import https from "node:https";
import net from "node:net";
import { providers } from "ethers";
import { requireRpcUrlFromEnv } from "../../src/config";
import { safeError } from "../../src/mask";

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

export class ForkChain {
  provider!: providers.JsonRpcProvider;
  private anvil!: ChildProcess;
  private proxy!: http.Server;
  proxyStats!: { requests: number; non200: number; http429: number };
  anvilLog = "";
  url = "";
  static async start(forkBlock?: number): Promise<ForkChain> {
    const f = new ForkChain();
    const px = await startProxy(requireRpcUrlFromEnv(), () => {
      console.error("UPSTREAM-HTTP-429: the state endpoint rate-limited the fork; stopping (no retry, no other provider)");
      f.anvil?.kill("SIGKILL");
      process.exit(42);
    });
    f.proxy = px.server;
    f.proxyStats = px.stats;
    const port = await freePort();
    f.anvil = spawn("anvil", ["--fork-url", `http://127.0.0.1:${px.port}`, ...(forkBlock ? ["--fork-block-number", String(forkBlock)] : []), "--port", String(port), "--auto-impersonate", "--retries", "20", "--fork-retry-backoff", "1000", "--compute-units-per-second", "40", "--silent"], { stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, AVALANCHE_MAINNET_RPC_URL: "", AVALANCHE_RPC: "", ETH_RPC_URL: "" } });
    f.anvil.stdout?.on("data", (d) => (f.anvilLog += String(d)));
    f.anvil.stderr?.on("data", (d) => (f.anvilLog += String(d)));
    f.url = `http://127.0.0.1:${port}`;
    f.provider = new providers.StaticJsonRpcProvider(f.url, { chainId: 43114, name: "avalanche-fork" });
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
}

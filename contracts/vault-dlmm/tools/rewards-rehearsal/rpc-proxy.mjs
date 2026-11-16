// (Identical to tools/rehearsal/rpc-proxy.mjs of the vault rehearsal.) Local pass-through proxy for the FORK REHEARSAL: anvil's --fork-url is given THIS proxy's local address, so no real endpoint ever appears in any argument vector.
// The upstream URL comes ONLY from the environment variable REH_UPSTREAM of this process; it is never printed or logged. The proxy counts the upstream HTTP status codes
// (so a 429 is visible, which anvil's own retry layer would hide) and writes the counts to REH_PROXY_STATS on exit and on SIGTERM.
//   REH_UPSTREAM=<url> REH_PROXY_PORT=<port> REH_PROXY_STATS=<file> node rpc-proxy.mjs
import http from "node:http";
import fs from "node:fs";
const UP = process.env.REH_UPSTREAM, PORT = Number(process.env.REH_PROXY_PORT), STATS = process.env.REH_PROXY_STATS;
if (!UP || !PORT) { console.error("REH_UPSTREAM and REH_PROXY_PORT are required"); process.exit(2); }
const counts = {}; let requests = 0, errors = 0;
const flush = () => { try { if (STATS) fs.writeFileSync(STATS, JSON.stringify({ requests, errors, upstreamStatus: counts }) + "\n"); } catch { /* */ } };
const server = http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", async () => {
    requests++;
    try {
      const r = await fetch(UP, { method: "POST", headers: { "content-type": "application/json" }, body: Buffer.concat(chunks) });
      counts[r.status] = (counts[r.status] || 0) + 1;
      const body = Buffer.from(await r.arrayBuffer());
      res.writeHead(r.status, { "content-type": "application/json" });
      res.end(body);
    } catch {
      errors++;
      res.writeHead(502, { "content-type": "application/json" });
      res.end(JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32603, message: "upstream unreachable" } }));
    }
    if (requests % 50 === 0) flush();
  });
});
server.listen(PORT, "127.0.0.1");
const stop = () => { flush(); server.close(); process.exit(0); };
process.on("SIGTERM", stop); process.on("SIGINT", stop); process.on("exit", flush);

// A fake upstream that answers every request with HTTP 429 (self-test of the exit-42 path). usage: node stub429.mjs <port>
import http from "node:http";
http.createServer((req, res) => { req.resume(); req.on("end", () => { res.writeHead(429, { "content-type": "application/json" }); res.end(JSON.stringify({ jsonrpc: "2.0", id: 1, error: { code: 429, message: "Too Many Requests" } })); }); }).listen(Number(process.argv[2]), "127.0.0.1");

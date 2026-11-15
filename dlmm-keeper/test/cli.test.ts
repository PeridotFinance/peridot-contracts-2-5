import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { decidedConfig } from "./fixtures";

const MAIN = path.join(__dirname, "..", "src", "main.js");
const TPL = path.join(__dirname, "..", "..", "config", "dlmm-keeper.example.json");
interface R { code: number | null; out: string; err: string }
function run(args: string[], env: NodeJS.ProcessEnv): Promise<R> {
  return new Promise((resolve) => {
    const c = spawn("node", [MAIN, ...args], { env: { PATH: process.env.PATH, ...env } });
    let out = "";
    let err = "";
    c.stdout.on("data", (d) => (out += d));
    c.stderr.on("data", (d) => (err += d));
    c.on("close", (code) => resolve({ code, out, err }));
  });
}
function setup(mode: "dry-run" | "live" = "dry-run"): { dir: string; cfgPath: string; haltPath: string; statePath: string } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "dk-cli-"));
  const cfg = decidedConfig(dir);
  cfg.mode = mode;
  const cfgPath = path.join(dir, "c.json");
  fs.writeFileSync(cfgPath, JSON.stringify(cfg));
  return { dir, cfgPath, haltPath: cfg.monitor.haltPath, statePath: cfg.monitor.statePath };
}

test("usage: an unknown command exits 2", async () => {
  assert.equal((await run(["bogus"], {})).code, 2);
});
test("start is REFUSED (78) on the template with placeholders, with every unset path named", async () => {
  const r = await run(["run", "--config", TPL], {});
  assert.equal(r.code, 78);
  assert.match(r.err, /configuration refused/);
  assert.match(r.err, /unset \(placeholder\)/);
  assert.match(r.err, /the process did not start/);
});
test("validate-config accepts a decided configuration; run refuses without AVALANCHE_MAINNET_RPC_URL and names the variable, not a value", async () => {
  const s = setup();
  assert.equal((await run(["validate-config", "--config", s.cfgPath], {})).code, 0);
  const r = await run(["run", "--config", s.cfgPath], {});
  assert.equal(r.code, 78);
  assert.match(r.err, /AVALANCHE_MAINNET_RPC_URL/);
});
test("a dead endpoint: start is refused and the RPC URL (with its key-like path) appears in NO output", async () => {
  const s = setup();
  const url = "http://127.0.0.1:1/v2/SECRETKEYSECRETKEY123456";
  const r = await run(["run", "--config", s.cfgPath], { AVALANCHE_MAINNET_RPC_URL: url });
  assert.equal(r.code, 78);
  assert.ok(!(r.out + r.err).includes("SECRETKEY"), r.err);
  assert.ok(!(r.out + r.err).includes("127.0.0.1:1"));
});
test("live mode against a (mock, local) endpoint: refused (78) without the keystore / password-file variables; the error names them", async () => {
  const s = setup("live");
  const srv = http.createServer((req, res) => {
    req.resume();
    req.on("end", () => res.end(JSON.stringify({ jsonrpc: "2.0", id: 1, result: "0xa86a" })));
  });
  await new Promise<void>((r) => srv.listen(0, "127.0.0.1", () => r()));
  const port = (srv.address() as { port: number }).port;
  try {
    const r = await run(["run", "--config", s.cfgPath], { AVALANCHE_MAINNET_RPC_URL: `http://127.0.0.1:${port}/k` });
    assert.equal(r.code, 78);
    assert.match(r.err, /DLMM_KEEPER_KEYSTORE_PATH/);
  } finally {
    srv.close();
  }
});
test("status and resume are OFFLINE (no RPC variable): status shows the HALT; resume removes it, clears a pending marker and leaves an audit line", async () => {
  const s = setup();
  fs.writeFileSync(s.haltPath, JSON.stringify({ kind: "guard", reason: "vault guard UNSAFE: ASSET_LEG_OUT_OF_BAND", at: 5, reasons: 4 }));
  fs.writeFileSync(s.statePath, JSON.stringify({ schemaVersion: 1, vault: decidedConfig().vault.toLowerCase(), pending: { kind: "rebalance", at: 3 }, exit: null, backoff: null, sends: [], lastRebalanceSeen: null, lastGasCheckAt: 0 }));
  let r = await run(["status", "--config", s.cfgPath], {});
  assert.equal(r.code, 1, "halted -> exit 1");
  assert.match(r.out, /"halted": true/);
  assert.match(r.out, /ASSET_LEG_OUT_OF_BAND/);
  r = await run(["resume", "--config", s.cfgPath], {});
  assert.equal(r.code, 0, r.err);
  assert.match(r.out, /HALT removed \(was guard/);
  assert.match(r.out, /cleared the pending marker/);
  assert.ok(!fs.existsSync(s.haltPath));
  assert.ok(fs.readFileSync(`${s.haltPath}.log`, "utf8").includes("resumedAt"));
  assert.equal(JSON.parse(fs.readFileSync(s.statePath, "utf8")).pending, null);
  r = await run(["status", "--config", s.cfgPath], {});
  assert.equal(r.code, 0);
  assert.match(r.out, /"halted": false/);
  r = await run(["resume", "--config", s.cfgPath], {});
  assert.match(r.out, /there was no HALT file/);
});

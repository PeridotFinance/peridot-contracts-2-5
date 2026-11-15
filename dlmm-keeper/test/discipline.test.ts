import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { AlertManager, MemorySink } from "../src/alerts";
import { mask, safeError, registerSecret } from "../src/mask";

const ROOT = path.join(__dirname, "..", "..");
const SRC = path.join(ROOT, "src");
const read = (f: string): string => fs.readFileSync(path.join(SRC, f), "utf8");
const stripComments = (t: string): string => t.replace(/^\s*\/\/.*$/gm, "");
const URL_WITH_KEY = "https://avax-mainnet.example.org/v2/SECRETKEYSECRETKEY123456";

test("key material is touched only by signer.ts; sending only by txkit.ts through the ExternalSigner; the keystore password is read only from a FILE named by the environment", () => {
  for (const f of fs.readdirSync(SRC)) {
    const t = stripComments(read(f));
    if (f !== "signer.ts" && f !== "config.ts") assert.ok(!/\bWallet\b|fromEncryptedJson|privateKey|mnemonic/.test(t), `${f} must not touch key material`);
    if (f !== "txkit.ts" && f !== "signer.ts") assert.ok(!/\.sendTransaction\(|\.sendRawTransaction|eth_sendRawTransaction|sendUncheckedTransaction/.test(t), `${f} must send only through txkit's makeSender`);
    assert.ok(!/KEYSTORE_PASSWORD(?!_FILE)\b/.test(t.replace(/KEYSTORE_PASSWORD_FILE/g, "")) || f === "signer.ts", `${f}: no password in the environment, only a file path`);
  }
  assert.match(read("signer.ts"), /DLMM_KEEPER_KEYSTORE_PASSWORD_FILE/);
  assert.match(read("signer.ts"), /DLMM_KEEPER_KEYSTORE_PATH/);
});
test("the keeper sends only two things: rebalance(...) and tripGuard(); both go through makeSender", () => {
  const t = stripComments(read("keeper.ts"));
  assert.equal((t.match(/makeSender\(/g) ?? []).length, 2);
  // (lastRebalanceAt is a read used by the read-back)
  assert.deepEqual([...new Set([...t.matchAll(/encodeFunctionData\("(\w+)"/g)].map((m) => m[1]))].sort(), ["lastRebalanceAt", "rebalance", "tripGuard"]);
});
test("the RPC URL is read from the environment in ONE place and is not a CLI argument anywhere in the project", () => {
  const hits = fs.readdirSync(SRC).filter((f) => /process\.env\.AVALANCHE|env\.AVALANCHE|AVALANCHE_MAINNET_RPC_URL/.test(stripComments(read(f))));
  assert.deepEqual(hits.sort(), ["config.ts", "mask.ts"]);
  for (const f of ["deploy/dlmm-keeper-host.sh", "test/fork/run.sh", "run-fork-test.sh"]) {
    const p = path.join(ROOT, f);
    if (!fs.existsSync(p)) continue;
    const t = fs.readFileSync(p, "utf8").replace(/^\s*#.*$/gm, "");
    assert.ok(!/--rpc-url|--fork-url\s+"?\$|\s-f\s+"?\$\{?AVALANCHE/.test(t), `${f}: the endpoint must never be an argument`);
    assert.ok(!/(curl|cast|anvil)[^\n|]*\$\{?AVALANCHE_MAINNET_RPC_URL/.test(t), `${f}: no command line carries the endpoint`);
  }
});
test("mask(): the endpoint and its key-like parts never leave the process in text, errors or alerts", async () => {
  const env = { AVALANCHE_MAINNET_RPC_URL: URL_WITH_KEY, AVALANCHE_LOGS_RPC_URL: "https://logs.example.org/key/ANOTHERSECRETVALUE9999" } as NodeJS.ProcessEnv;
  const out = mask(`request to ${URL_WITH_KEY} failed; logs ${env.AVALANCHE_LOGS_RPC_URL}`, env);
  assert.ok(!out.includes("SECRETKEY") && !out.includes("ANOTHERSECRET") && !out.includes("avax-mainnet.example.org"));
  Object.assign(process.env, env);
  const e = new Error(`server response 429 (url="${URL_WITH_KEY}")`);
  assert.ok(!safeError(e).includes("SECRETKEY"));
  const sink = new MemorySink();
  const am = new AlertManager(sink);
  await am.notify({ kind: "action", key: "k", severity: "info", audience: "keeper-operator", text: `see ${URL_WITH_KEY}` });
  await am.raise({ key: "r", severity: "warn", message: `bad ${URL_WITH_KEY}`, audience: "keeper-operator" }, 1);
  assert.ok(sink.messages.every((m) => !m.text.includes("SECRETKEY")));
  assert.ok(sink.messages.every((m) => m.text.includes("[RPC-MASKED]")));
  delete process.env.AVALANCHE_MAINNET_RPC_URL;
  delete process.env.AVALANCHE_LOGS_RPC_URL;
});
test("a registered secret (the keystore password read from its file) is masked everywhere", () => {
  registerSecret("correct-horse-battery-staple");
  assert.ok(!mask("password is correct-horse-battery-staple ok").includes("correct-horse"));
});
test("no file of the project carries a key, a password, an RPC URL or an order-keeper resource name", () => {
  const skip = new Set(["node_modules", "dist", "state", ".git"]);
  const walk = (d: string): string[] => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => (skip.has(e.name) ? [] : e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]));
  for (const f of walk(ROOT)) {
    if (/package-lock\.json$|\.test\.ts$|fakeworld\.ts$/.test(f)) continue;
    const t = fs.readFileSync(f, "utf8");
    assert.ok(!/\b0x[0-9a-fA-F]{64}\b/.test(t) || /abi|Stub|run-fork/.test(f), `${f}: 32-byte hex`);
    assert.ok(!/alchemy|infura|quiknode|ankr\.com/i.test(t), `${f}: provider name`);
    assert.ok(!/order-?keeper/i.test(t.replace(/the (production )?order keeper/gi, "")), `${f}: leftover name of the production keeper's resources`);
  }
});

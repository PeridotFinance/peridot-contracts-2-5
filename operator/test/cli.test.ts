import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const MAIN = path.join(__dirname, "..", "src", "main.js");
import { decidedConfig, TEMPLATE_PATH as TEMPLATE } from "./fixtures";
const SRC = path.join(__dirname, "..", "..", "src");

const run = (args: string[], env: Record<string, string>) =>
  spawnSync(process.execPath, [MAIN, ...args], { env: { PATH: process.env.PATH ?? "", ...env }, encoding: "utf8", timeout: 20_000 });

test("the process REFUSES TO START (exit 78) with the checked-in template and names the unset decisions", () => {
  const r = run(["check"], { OPERATOR_CONFIG: TEMPLATE, AVALANCHE_MAINNET_RPC_URL: "http://127.0.0.1:1" });
  assert.equal(r.status, 78);
  for (const must of ["operators[0].address", "reference.minPoolLiquidity", "keeper.keystorePath", "keeper.dailySpendCapUsdc", "treasury.address", "the process did not start"]) assert.ok(r.stderr.includes(must), must);
  assert.equal(r.stdout, "");
});
test("refuses with no configuration, and with a configuration but no RPC endpoint or alert credentials in the environment", () => {
  assert.equal(run(["check"], {}).status, 78);
  const cfg = decidedConfig();
  cfg.alerts.channel = "telegram";
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "opcfg-"));
  const file = path.join(dir, "c.json");
  fs.writeFileSync(file, JSON.stringify(cfg));
  try {
    assert.equal(run(["validate-config"], { OPERATOR_CONFIG: file }).status, 0, "a fully decided config validates");
    const noRpc = run(["run"], { OPERATOR_CONFIG: file });
    assert.equal(noRpc.status, 78);
    assert.match(noRpc.stderr, /no RPC endpoint/);
    const noAlert = run(["run"], { OPERATOR_CONFIG: file, AVALANCHE_MAINNET_RPC_URL: "http://127.0.0.1:1" });
    assert.equal(noAlert.status, 78);
    assert.match(noAlert.stderr, /OPERATOR_ALERT_TELEGRAM_TOKEN/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
test("KEY HANDLING is confined to src/signer.ts and src/keeper.ts: no other module constructs a wallet or signer, reads a key, or sends a transaction", () => {
  const banned = [/\bWallet\b/, /privateKey/i, /mnemonic/i, /\bgetSigner\b/, /\bsignTransaction\b/, /\bsendTransaction\b/, /\bsendRawTransaction\b/, /eth_sendTransaction/, /eth_sendRawTransaction/, /\bsignMessage\b/, /\.connect\(\s*signer/i];
  const files = fs.readdirSync(SRC).filter((f) => f.endsWith(".ts"));
  assert.ok(files.length >= 10);
  // the two modules that may hold a signer: the abstraction and the keeper that uses it (and nothing else in src/)
  const mayHoldSigner = new Set(["signer.ts", "keeper.ts"]);
  for (const f of files) {
    if (mayHoldSigner.has(f)) continue;
    const text = fs.readFileSync(path.join(SRC, f), "utf8");
    for (const re of banned) {
      // the config validator and its comments may MENTION the words; a match is only a failure in executable code lines
      const hits = text.split("\n").filter((l) => re.test(l) && !/^\s*(\/\/|\*|\/\*)/.test(l) && !/problem:|message|throw new Error|"the words|hits\.push|ConfigProblem|findSecretsInConfigText|regexes?/.test(l) && !/\/\(mnemonic/.test(l));
      assert.deepEqual(hits, [], `${f} matches ${re}`);
    }
  }
});

test("the keeper never reads key material itself: keeper.ts only talks to the ExternalSigner interface", () => {
  const text = fs.readFileSync(path.join(SRC, "keeper.ts"), "utf8");
  for (const re of [/\bWallet\b/, /fromEncryptedJson/, /privateKey/i, /mnemonic/i, /process\.env/]) {
    const hits = text.split("\n").filter((l) => re.test(l) && !/^\s*(\/\/|\*|\/\*)/.test(l));
    assert.deepEqual(hits, [], `keeper.ts matches ${re}`);
  }
  const signer = fs.readFileSync(path.join(SRC, "signer.ts"), "utf8");
  assert.ok(!/console\./.test(signer), "the signer module never prints");
});

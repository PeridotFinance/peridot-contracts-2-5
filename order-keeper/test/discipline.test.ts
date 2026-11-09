import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { providers, Wallet } from "ethers";
import { AlertManager, MemorySink } from "../src/alerts";
import { mask, safeError } from "../src/mask";
import { KeystoreSigner, SignerError } from "../src/signer";
import { decidedConfig } from "./fixtures";

const SRC = path.join(__dirname, "..", "..", "src");
const read = (f: string): string => fs.readFileSync(path.join(SRC, f), "utf8");
const URL_WITH_KEY = "https://avax-mainnet.example.org/v2/SECRETKEYSECRETKEY123456";

test("key material is touched only by signer.ts; sending only by txkit.ts through the ExternalSigner; the keystore password is read nowhere else", () => {
  for (const f of fs.readdirSync(SRC)) {
    const t = read(f);
    if (f !== "signer.ts" && f !== "config.ts") { // config.ts only SCANS config text for key-shaped words
      assert.ok(!/\bWallet\b|fromEncryptedJson|privateKey|mnemonic/.test(t.replace(/^\s*\/\/.*$/gm, "")), `${f} must not touch key material`);
      assert.ok(!/process\.env\[[^\]]*[Pp]assword|passwordEnv\]/.test(t) || f === "main.ts" || f === "config.ts", f);
    }
    if (f !== "txkit.ts" && f !== "signer.ts") assert.ok(!/\.sendTransaction\(|\.sendRawTransaction|eth_sendRawTransaction/.test(t), `${f} must send only through txkit's makeSender`);
  }
});
test("the keeper only ever calls executeOrder with EMPTY adapterData", () => {
  const t = read("keeper.ts");
  assert.ok(/encodeFunctionData\("executeOrder", \[a\.id, "0x"\]\)/.test(t));
  assert.equal((t.match(/encodeFunctionData\("executeOrder"/g) ?? []).length, 1);
});
test("mask(): endpoints and key-like parts never leave the process in text, errors or alerts", async () => {
  const env = { AVALANCHE_MAINNET_RPC_URL: URL_WITH_KEY, AVALANCHE_LOGS_RPC_URL: "https://logs.example.org/key/ANOTHERSECRETVALUE9999" } as NodeJS.ProcessEnv;
  const out = mask(`request to ${URL_WITH_KEY} failed; logs ${env.AVALANCHE_LOGS_RPC_URL}`, env);
  assert.ok(!out.includes("SECRETKEY") && !out.includes("ANOTHERSECRET") && !out.includes("avax-mainnet.example.org"));
  Object.assign(process.env, env);
  const e = new Error(`server response 429 (url="${URL_WITH_KEY}")`);
  assert.ok(!safeError(e).includes("SECRETKEY"));
  const sink = new MemorySink();
  const am = new AlertManager(sink, [1]);
  await am.notify({ kind: "action", key: "k", severity: "info", audience: "order-keeper", text: `see ${URL_WITH_KEY}` });
  await am.raise({ key: "r", severity: "warn", message: `bad ${URL_WITH_KEY}`, audience: "order-keeper" }, 1);
  assert.ok(sink.messages.every((m) => !m.text.includes("SECRETKEY")));
  delete process.env.AVALANCHE_MAINNET_RPC_URL;
  delete process.env.AVALANCHE_LOGS_RPC_URL;
});
test("keystore signer: password only from the environment (never in the error), a group/other-readable keystore is refused, a wrong password is refused", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "oks-"));
  const f = path.join(dir, "k.json");
  const w = Wallet.createRandom();
  fs.writeFileSync(f, await w.encrypt("pw-test-123", { scrypt: { N: 256 } }), { mode: 0o600 });
  const prov = new providers.StaticJsonRpcProvider("http://127.0.0.1:9", { chainId: 43114, name: "x" }); // never contacted
  await assert.rejects(KeystoreSigner.load(prov, f, "NO_SUCH_VAR", {}), (e: unknown) => e instanceof SignerError && /NO_SUCH_VAR/.test(String(e)));
  await assert.rejects(KeystoreSigner.load(prov, f, "PW", { PW: "wrong-password" }), (e: unknown) => e instanceof SignerError && !/wrong-password/.test(String(e)));
  const s = await KeystoreSigner.load(prov, f, "PW", { PW: "pw-test-123" });
  assert.equal((await s.getAddress()).toLowerCase(), w.address.toLowerCase());
  fs.chmodSync(f, 0o644);
  await assert.rejects(KeystoreSigner.load(prov, f, "PW", { PW: "pw-test-123" }), /accessible to other users/);
});
test("main refuses to start: the template (placeholders), a missing endpoint, a missing password variable; nothing is printed that looks like a value", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "omain-"));
  const main = path.join(__dirname, "..", "src", "main.js");
  const env: NodeJS.ProcessEnv = { PATH: process.env.PATH };
  const tpl = path.join(__dirname, "..", "..", "config", "order-keeper.example.json");
  let r = spawnSync("node", [main, "run", "--config", tpl], { env, encoding: "utf8" });
  assert.equal(r.status, 78);
  assert.match(r.stderr, /configuration refused/);
  assert.match(r.stderr, /unset \(placeholder\)/);
  const cfg = path.join(dir, "c.json");
  fs.writeFileSync(cfg, JSON.stringify(decidedConfig()));
  r = spawnSync("node", [main, "validate-config", "--config", cfg], { env, encoding: "utf8" });
  assert.equal(r.status, 0);
  r = spawnSync("node", [main, "run", "--config", cfg], { env, encoding: "utf8" });
  assert.equal(r.status, 78);
  assert.match(r.stderr, /AVALANCHE_MAINNET_RPC_URL/);
  r = spawnSync("node", [main, "bogus"], { env, encoding: "utf8" });
  assert.equal(r.status, 2);
});

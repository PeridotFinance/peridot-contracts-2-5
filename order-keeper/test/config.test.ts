import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { findSecretsInConfigText, requireRpcUrlFromEnv, requireValidConfig, validateConfig, ConfigError } from "../src/config";
import { loadConfig } from "../src/main";
import { emptyState, loadState, saveState, StateError } from "../src/state";
import { decidedConfig } from "./fixtures";

const template = (): any => JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "config", "order-keeper.example.json"), "utf8"));

test("the checked-in template is REFUSED (every undecided value is a placeholder) and the refusal lists them", () => {
  assert.throws(() => requireValidConfig(template()), (e: unknown) => e instanceof ConfigError && /registry/.test(e.message) && /keeper\.address/.test(e.message) && /alerts\.channel/.test(e.message));
});
test("a fully decided configuration is accepted; a placeholder or a bad value in any decided field is refused", () => {
  assert.ok(requireValidConfig(decidedConfig()));
  const bad = (mut: (c: any) => void, re: RegExp) => {
    const c: any = decidedConfig();
    mut(c);
    assert.ok(validateConfig(c).problems.some((p) => re.test(p.path)), re.source);
  };
  bad((c) => (c.registry = "UNSET"), /^registry$/);
  bad((c) => (c.keeper.address = "0x123"), /keeper\.address/);
  bad((c) => (c.chainId = 1), /chainId/);
  bad((c) => (c.keeper.passwordEnv = "my password"), /passwordEnv/);
  bad((c) => (c.limits.maxFeeGwei = 0), /maxFeeGwei/);
  bad((c) => (c.limits.retryCooldownMaxSeconds = 1), /retryCooldownMaxSeconds/);
  bad((c) => (c.logs.chunkBlocks = 101), /chunkBlocks/);
  bad((c) => (c.alerts.channel = "email"), /alerts\.channel/);
  bad((c) => (c.monitor.statePath = ""), /statePath/);
  bad((c) => delete c.limits.sweep, /sweep/);
});
test("a config file with an endpoint URL carrying a key, a 32-byte hex key, or the word mnemonic is refused (secrets live in the environment)", () => {
  assert.ok(findSecretsInConfigText('{"rpc":"https://avax-mainnet.g.alchemy.com/v2/abcdefghijklmnopqrstuvwx"}').length);
  assert.ok(findSecretsInConfigText(`{"k":"0x${"ab".repeat(32)}"}`).length);
  assert.ok(findSecretsInConfigText('{"x":"my mnemonic"}').length);
  assert.equal(findSecretsInConfigText(JSON.stringify(decidedConfig())).length, 0);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "okcfg-"));
  const f = path.join(dir, "c.json");
  fs.writeFileSync(f, JSON.stringify({ ...decidedConfig(), rpc: "https://example.org/v2/abcdefghijklmnopqrstuvwx" }));
  assert.throws(() => loadConfig({}, ["--config", f]), /must not contain secrets/);
  fs.writeFileSync(f, JSON.stringify(decidedConfig()));
  assert.ok(loadConfig({}, ["--config", f]));
  assert.throws(() => loadConfig({}, []), /no configuration/);
});
test("the state endpoint comes from the environment only; the message names the variable, never a value", () => {
  assert.throws(() => requireRpcUrlFromEnv({}), (e: unknown) => /AVALANCHE_MAINNET_RPC_URL/.test(String(e)));
  assert.equal(requireRpcUrlFromEnv({ AVALANCHE_MAINNET_RPC_URL: "http://x" }), "http://x");
});
test("state: fresh start when absent; round trip; a state of another registry or a corrupt file is REFUSED, never reset", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "okstate-"));
  const f = path.join(dir, "sub", "state.json");
  const reg = decidedConfig().registry;
  assert.deepEqual(loadState(f, reg), emptyState(reg));
  const s = { ...emptyState(reg), pending: { orderId: "3", kind: "execute" as const, at: 5 }, halted: { reason: "r", at: 6 }, highWater: 9, open: ["4"] };
  saveState(f, s);
  assert.deepEqual(loadState(f, reg), s);
  assert.equal(fs.statSync(f).mode & 0o077, 0, "the state file is private to the user");
  assert.throws(() => loadState(f, "0x00000000000000000000000000000000000000dd"), StateError);
  fs.writeFileSync(f, "{ broken");
  assert.throws(() => loadState(f, reg), StateError);
});

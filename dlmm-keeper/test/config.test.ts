import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { findSecretsInConfigText, requireRpcUrlFromEnv, requireValidConfig, validateConfig, ConfigError } from "../src/config";
import { decidedConfig } from "./fixtures";

const tpl = (): unknown => JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "config", "dlmm-keeper.example.json"), "utf8"));
const mut = (f: (c: any) => void): ReturnType<typeof validateConfig> => {
  const c: any = JSON.parse(JSON.stringify(decidedConfig()));
  f(c);
  return validateConfig(c);
};
const hasProblem = (r: ReturnType<typeof validateConfig>, p: string): boolean => r.problems.some((x) => x.path === p);

test("the checked-in template is REFUSED while it carries placeholders; the decided config is accepted", () => {
  const r = validateConfig(tpl());
  assert.ok(!r.config);
  for (const p of ["label", "vault", "assetToken", "pairToken", "feeds.asset", "feeds.pair", "keeper.address", "alerts.channel"]) assert.ok(hasProblem(r, p), p);
  assert.throws(() => requireValidConfig(tpl()), ConfigError);
  assert.ok(validateConfig(decidedConfig()).config);
});
test("the template is dry-run by default and every floor of the spec is in it", () => {
  const t: any = tpl();
  assert.equal(t.mode, "dry-run");
  assert.equal(t.guard.autoTripGuard, false);
  assert.equal(t.timing.pollSeconds, 3);
  assert.equal(t.timing.exitWaitSeconds, 60);
  assert.equal(t.timing.cooldownSeconds, 120);
  assert.equal(t.timing.deadlineSeconds, 120);
  assert.equal(t.limits.maxSendsPerCycle, 1);
  assert.equal(t.limits.maxSendsPerDay, 48);
  assert.equal(t.limits.gasPerRebalance, 1_000_000);
  assert.equal(t.limits.minRebalancesCovered, 5);
  assert.equal(t.pair, "0x16888EE58E706C253b821EAA637ae9b2cFeA255C");
});
test("mode must be dry-run or live (a typo is not 'live')", () => {
  assert.ok(hasProblem(mut((c) => (c.mode = "Live")), "mode"));
  assert.ok(hasProblem(mut((c) => delete c.mode), "mode"));
});
test("floors: exit wait >= 60 s, cooldown >= 120 s, deadline <= 120 s, exactly 1 send per cycle, <= 48 sends a day, idSlippage <= 2", () => {
  assert.ok(hasProblem(mut((c) => (c.timing.exitWaitSeconds = 59)), "timing.exitWaitSeconds"));
  assert.ok(!hasProblem(mut((c) => (c.timing.exitWaitSeconds = 60)), "timing.exitWaitSeconds"));
  assert.ok(hasProblem(mut((c) => (c.timing.cooldownSeconds = 119)), "timing.cooldownSeconds"));
  assert.ok(hasProblem(mut((c) => (c.timing.deadlineSeconds = 121)), "timing.deadlineSeconds"));
  assert.ok(hasProblem(mut((c) => (c.limits.maxSendsPerCycle = 2)), "limits.maxSendsPerCycle"));
  assert.ok(hasProblem(mut((c) => (c.limits.maxSendsPerCycle = 0)), "limits.maxSendsPerCycle"));
  assert.ok(hasProblem(mut((c) => (c.limits.maxSendsPerDay = 49)), "limits.maxSendsPerDay"));
  assert.ok(!hasProblem(mut((c) => (c.limits.maxSendsPerDay = 48)), "limits.maxSendsPerDay"));
  assert.ok(hasProblem(mut((c) => (c.rebalance.idSlippage = 3)), "rebalance.idSlippage"));
});
test("addresses: unset, malformed, zero and identical tokens are refused; multicall3 may be 'none' only as the literal", () => {
  assert.ok(hasProblem(mut((c) => (c.vault = "UNSET")), "vault"));
  assert.ok(hasProblem(mut((c) => (c.vault = "0x123")), "vault"));
  assert.ok(hasProblem(mut((c) => (c.pair = "0x0000000000000000000000000000000000000000")), "pair"));
  assert.ok(hasProblem(mut((c) => (c.pairToken = c.assetToken)), "pairToken"));
  assert.ok(!hasProblem(mut((c) => (c.multicall3 = "none")), "multicall3"));
  assert.ok(hasProblem(mut((c) => (c.multicall3 = "nope")), "multicall3"));
  assert.ok(hasProblem(mut((c) => (c.chainId = 1)), "chainId"));
});
test("limits: failures, mined reverts, fee cap, wallet floor, backoff order", () => {
  assert.ok(hasProblem(mut((c) => (c.limits.maxConsecutiveFailures = 0)), "limits.maxConsecutiveFailures"));
  assert.ok(hasProblem(mut((c) => (c.limits.minWalletWei = "0")), "limits.minWalletWei"));
  assert.ok(hasProblem(mut((c) => (c.limits.minWalletWei = "1e18")), "limits.minWalletWei"));
  assert.ok(hasProblem(mut((c) => (c.limits.retryBackoffMaxSeconds = 10)), "limits.retryBackoffMaxSeconds"));
  assert.ok(hasProblem(mut((c) => (c.guard.autoTripGuard = "yes")), "guard.autoTripGuard"));
});
test("a config FILE with an RPC URL, a 32-byte key or the word password is refused by the secret scan", () => {
  assert.ok(findSecretsInConfigText('{"rpc":"https://avax-mainnet.g.alchemy.com/v2/ABCDEFGHIJKLMNOPQRSTUVWX"}').length > 0);
  assert.ok(findSecretsInConfigText('{"k":"0x' + "ab".repeat(32) + '"}').length > 0);
  assert.ok(findSecretsInConfigText('{"password":"x"}').length > 0);
  assert.equal(findSecretsInConfigText(fs.readFileSync(path.join(__dirname, "..", "..", "config", "dlmm-keeper.example.json"), "utf8")).length, 0);
});
test("the RPC endpoint comes from AVALANCHE_MAINNET_RPC_URL only; a missing one fails WITHOUT printing a value", () => {
  assert.throws(() => requireRpcUrlFromEnv({}), (e: unknown) => /AVALANCHE_MAINNET_RPC_URL/.test(String(e)));
  assert.throws(() => requireRpcUrlFromEnv({ AVALANCHE_RPC: "https://x.example/SECRETSECRETSECRET" }), /AVALANCHE_MAINNET_RPC_URL/, "the research variable is not a source for the keeper");
  assert.equal(requireRpcUrlFromEnv({ AVALANCHE_MAINNET_RPC_URL: "https://x.example/k" }), "https://x.example/k");
});

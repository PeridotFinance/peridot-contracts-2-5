import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { findSecretsInConfigText, requireValidConfig, validateConfig, ConfigError } from "../src/config";
import { loadConfig } from "../src/main";

import { decidedConfig, template, TEMPLATE_PATH as TEMPLATE, A as _A } from "./fixtures";
const tpl = template;
const filled = () => decidedConfig();
void _A;

test("the checked-in template is REFUSED, and every operator decision is reported", () => {
  const { problems, config } = validateConfig(tpl());
  assert.equal(config, undefined);
  const paths = problems.map((p) => p.path);
  for (const must of ["operators[0].name", "operators[0].address", "operators[1].address", "reference.minPoolLiquidity", "treasury.address", "keeper.keystorePath", "keeper.dailySpendCapUsdc", "deployment.controller", "deployment.pUsdc", "deployment.deploymentBlock"]) {
    assert.ok(paths.includes(must), `${must} must be reported as unset; got ${paths.join(", ")}`);
  }
  assert.throws(() => requireValidConfig(tpl()), ConfigError);
});
test("a fully decided configuration is accepted", () => {
  const { problems, config } = validateConfig(filled());
  assert.deepEqual(problems, []);
  assert.ok(config);
});
test("each operator decision and each recorded-source rule, unset or broken alone, refuses the start", () => {
  const cases: Array<[string, (c: any) => void]> = [
    ["operators", (c) => (c.operators = [{ name: "UNSET", address: "UNSET" }, { name: "op-b", address: _A(0x202) }])],
    ["operators (one only)", (c) => (c.operators = [c.operators[0]])],
    ["signer type", (c) => (c.signer.type = "UNSET")],
    ["alert channel", (c) => (c.alerts.channel = "UNSET")],
    ["slippage bound", (c) => (c.execution.slippageBoundBp = "UNSET")],
    ["pool liquidity floor", (c) => (c.reference.minPoolLiquidity = "UNSET")],
    ["floor without its source range", (c) => delete c.reference.minPoolLiquiditySource],
    ["floor that is not 50% of the recorded median", (c) => (c.reference.minPoolLiquidity = "501")],
    ["keeper daily spend cap", (c) => (c.keeper.dailySpendCapUsdc = "UNSET")],
    ["keeper keystore path", (c) => (c.keeper.keystorePath = "UNSET")],
    ["keeper password env name replaced by a password-looking value", (c) => (c.keeper.passwordEnv = "hunter2 !")],
    ["signer type that is not implemented (ledger)", (c) => (c.signer.type = "ledger")],
    ["slippage bound missing", (c) => delete c.execution],
    ["signer type unknown", (c) => (c.signer.type = "private-key-file")],
    ["slippage out of range", (c) => (c.execution.slippageBoundBp = 5000)],
    ["duplicate operator", (c) => (c.operators[1].address = c.operators[0].address)],
    ["wrong chain", (c) => (c.chainId = 43113)],
  ];
  for (const [name, mutate] of cases) {
    const c = filled();
    mutate(c);
    assert.throws(() => requireValidConfig(c), ConfigError, name);
  }
});
test("a config file carrying a URL with a key, a 32-byte hex string or key words is refused", () => {
  assert.ok(findSecretsInConfigText('{"rpc": "https://node.example.com/ext/bc/C/rpc/AbCdEf0123456789AbCdEf0123456789"}').length > 0);
  assert.ok(findSecretsInConfigText('{"k": "0x' + "ab".repeat(32) + '"}').length > 0);
  assert.ok(findSecretsInConfigText('{"note": "private key here"}').length > 0);
  assert.equal(findSecretsInConfigText(JSON.stringify(filled())).length, 0, "a normal config has none (addresses are 20 bytes)");
});
test("loadConfig refuses the template file and a file with secrets, and names the problems", () => {
  assert.throws(() => loadConfig({ OPERATOR_CONFIG: TEMPLATE } as any, []), /refused/);
  const tmp = path.join(__dirname, "..", "tmp-secret-config.json");
  fs.writeFileSync(tmp, JSON.stringify({ ...filled(), rpc: "https://x.example/AbCdEf0123456789AbCdEf0123456789" }));
  try {
    assert.throws(() => loadConfig({ OPERATOR_CONFIG: tmp } as any, []), /must not contain secrets/);
  } finally {
    fs.unlinkSync(tmp);
  }
  assert.throws(() => loadConfig({} as any, []), /no configuration/);
});

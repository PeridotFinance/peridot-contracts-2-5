import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { planRepay, minOutFor, oracleValueUsdc, emptyExecutorState } from "../src/executor";
import { pIface } from "../src/chain";
import { requireValidConfig, validateConfig } from "../src/config";
import { decidedConfig } from "./fixtures";
import { utils } from "ethers";
import { ERC20_ABI, SWAP_ROUTER02_ABI } from "../src/abi";

const CF = 5n * 10n ** 17n; // close factor 50%
const U = (n: number) => BigInt(Math.round(n * 1e6));
const base = { debt: U(5000), closeFactor: CF, collateralUsdc: U(100_000), inventory: U(10_000), minRepay: U(1) };

test("plan: close factor of the debt when the collateral and the inventory allow it", () => {
  assert.deepEqual(planRepay(base), { repay: U(2500), unfunded: false });
});
test("plan: capped by what the collateral can pay for (0.2% below the 1/LI limit), then by the inventory", () => {
  const p = planRepay({ ...base, collateralUsdc: U(1000) });
  assert.equal(p.repay, (U(1000) * 9_240n) / 10_000n);
  assert.equal(p.unfunded, false);
  assert.equal(planRepay({ ...base, collateralUsdc: 0n }).repay, 0n);
});
test("plan: an underfunded operator liquidates partially with all it holds (<= the close factor); below the minimum it does nothing; both are 'unfunded' steps", () => {
  assert.deepEqual(planRepay({ ...base, inventory: U(1200) }), { repay: U(1200), unfunded: true });
  assert.deepEqual(planRepay({ ...base, inventory: U(2500) - 1n }), { repay: U(2500) - 1n, unfunded: true });
  assert.deepEqual(planRepay({ ...base, inventory: U(2500) }), { repay: U(2500), unfunded: false }, "exactly enough is funded");
  const none = planRepay({ ...base, inventory: U(1) - 1n });
  assert.equal(none.repay, 0n);
  assert.equal(none.unfunded, true);
  assert.equal(planRepay({ ...base, debt: 0n }).repay, 0n);
});
test("min-out: oracle value minus the slippage bound, integer arithmetic", () => {
  assert.equal(oracleValueUsdc(10n ** 18n, 25n * 10n ** 18n, 10n ** 30n), 25_000_000n, "1 WAVAX at USD 25 = 25 USDC");
  assert.equal(minOutFor(25_000_000n, 100), 24_750_000n);
  assert.equal(minOutFor(25_000_000n, 1), 24_997_500n);
});
test("state: starts clean", () => {
  assert.deepEqual(emptyExecutorState(), { halted: null, pending: null, rounds: [], cooldown: {} });
});
test("every function the executor encodes or decodes is in the ABI it uses", () => {
  const text = fs.readFileSync(path.join(__dirname, "..", "..", "src", "executor.ts"), "utf8");
  const erc = new utils.Interface(ERC20_ABI);
  const rt = new utils.Interface(SWAP_ROUTER02_ABI);
  const names = new Set<string>();
  for (const m of text.matchAll(/(pIface|erc20|router)\.(?:encodeFunctionData|decodeFunctionResult)\("([A-Za-z0-9_]+)"/g)) names.add(`${m[1]}:${m[2]}`);
  assert.ok(names.size >= 7, [...names].join(", "));
  for (const n of names) {
    const [which, fn] = n.split(":");
    assert.doesNotThrow(() => (which === "pIface" ? pIface : which === "erc20" ? erc : rt).getFunction(fn!), n);
  }
  assert.doesNotThrow(() => pIface.getEvent("LiquidateBorrow"));
});
test("config: the executor block is validated only when enabled, must name an operator, and cannot run beside the keeper", () => {
  const c = decidedConfig();
  assert.ok(requireValidConfig(c));
  c.executor.enabled = true;
  c.keeper.enabled = false;
  assert.ok(requireValidConfig(c), "an enabled executor with its keystore, operator name and password variable is valid");
  const bad = (mut: (x: any) => void, re: RegExp) => {
    const x = decidedConfig();
    x.executor.enabled = true;
    x.keeper.enabled = false;
    mut(x);
    const { problems } = validateConfig(x);
    assert.ok(problems.some((p) => re.test(p.path)), `${re}: ${JSON.stringify(problems)}`);
  };
  bad((x) => (x.executor.operator = "UNSET"), /executor\.operator/);
  bad((x) => (x.executor.operator = "nobody"), /executor\.operator/);
  bad((x) => (x.executor.keystorePath = "UNSET"), /executor\.keystorePath/);
  bad((x) => (x.executor.passwordEnv = "my password"), /executor\.passwordEnv/);
  bad((x) => (x.keeper.enabled = true), /executor\.enabled/);
  bad((x) => (x.executor.minRepayUsdc = 0), /executor\.minRepayUsdc/);
  bad((x) => delete x.executor.convertToUsdc, /executor\.convertToUsdc/);
});

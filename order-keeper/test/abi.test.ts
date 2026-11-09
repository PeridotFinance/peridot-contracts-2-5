import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { utils } from "ethers";
import { ADAPTER_ABI, EXECUTOR_ABI, REGISTRY_ABI, VAULT_ABI } from "../src/abi";

const dir = path.join(__dirname, "..", "..", "..", "docs", "deployment-handoffs", "avalanche-margin-abi");
const sigs = (file: string): Set<string> => {
  const abi = JSON.parse(fs.readFileSync(path.join(dir, file), "utf8"));
  const i = new utils.Interface(Array.isArray(abi) ? abi : abi.abi);
  return new Set([...Object.values(i.functions).map((f) => `function ${f.format()}`), ...Object.values(i.events).map((f) => `event ${f.format()}`), ...Object.values(i.errors).map((f) => `error ${f.format()}`)]);
};
function check(file: string, fragments: string[]): void {
  const have = sigs(file);
  for (const f of fragments) {
    const frag = utils.Fragment.from(f);
    const key = `${frag.type} ${frag.format()}`;
    assert.ok(have.has(key), `${file} has no ${key}`);
  }
}
test("every function, event and error the keeper uses exists, with the same signature, in the deployed-ABI handoff files", () => {
  check("MarginOrderRegistry.json", REGISTRY_ABI);
  check("AvalancheMarginCloseAdapter.json", ADAPTER_ABI.filter((x) => !x.includes("NotRegistry") || true));
  check("IsolatedMarginExecutor.json", EXECUTOR_ABI);
  check("IsolatedMarginVault.json", VAULT_ABI);
});

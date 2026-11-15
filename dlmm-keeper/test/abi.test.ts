import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { utils } from "ethers";
import { VAULT_ABI } from "../src/abi";

// The keeper's vault ABI must be the FROZEN interface contracts/vault-dlmm/src/IPharaohDlmmVault.sol, signature by signature.
const SOL = path.join(__dirname, "..", "..", "..", "contracts", "vault-dlmm", "src", "IPharaohDlmmVault.sol");
const sol = fs.readFileSync(SOL, "utf8").replace(/\/\/.*$/gm, "");
const GP = "(uint16,uint32,uint16,uint32,uint16,uint16,uint16)";
const norm = (types: string): string => types.split(",").map((t) => t.trim().replace(/\s+(memory|calldata|indexed)\b/g, "").replace(/\s+\w+$/, "").replace(/^GuardParams$/, GP)).filter(Boolean).join(",");
const types = (params: string): string => norm(params.replace(/\s+/g, " "));
const fromSol = (kind: "function" | "event" | "error"): Map<string, string> => {
  const m = new Map<string, string>();
  const re = new RegExp(`\\b${kind}\\s+(\\w+)\\s*\\(([^)]*)\\)`, "g");
  for (const x of sol.matchAll(re)) m.set(x[1]!, `${x[1]}(${types(x[2]!)})`);
  return m;
};
const iface = new utils.Interface(VAULT_ABI);

test("every function the keeper calls has the signature of the frozen interface", () => {
  const fns = fromSol("function");
  for (const f of Object.values(iface.functions)) {
    const sig = fns.get(f.name);
    assert.ok(sig, `${f.name} is in the frozen interface`);
    assert.equal(f.format(utils.FormatTypes.sighash), sig, f.name);
  }
});
test("every event and error in the keeper's ABI has the signature of the frozen interface; every frozen error is in the keeper's ABI", () => {
  const evs = fromSol("event");
  for (const e of Object.values(iface.events)) {
    const sig = evs.get(e.name)!;
    assert.ok(sig, e.name);
    assert.equal(e.format(utils.FormatTypes.sighash), sig, e.name);
  }
  const errs = fromSol("error");
  for (const e of Object.values(iface.errors)) assert.equal(e.format(utils.FormatTypes.sighash), errs.get(e.name), e.name);
  for (const [n] of errs) assert.ok(Object.values(iface.errors).some((e) => e.name === n), `the frozen error ${n} is classified`);
});
test("the keeper never calls anything outside the read list of spec section 6 plus rebalance and tripGuard", () => {
  const allowed = new Set(["bandState", "guardState", "rebalanceAllowed", "guardParams", "rebalancesToday", "lastRebalanceAt", "rebalance", "tripGuard"]);
  for (const f of Object.values(iface.functions)) assert.ok(allowed.has(f.name), f.name);
});

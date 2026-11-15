import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Wallet, providers } from "ethers";
import { allowanceFor, checkBudget, emptyKeeperState, isConfirmed, spentInWindow, updateConfirmations } from "../src/keeper";
import { KeystoreSigner } from "../src/signer";
import { requireValidConfig } from "../src/config";
import { decidedConfig } from "./fixtures";
import { mask } from "../src/mask";

const cfg = requireValidConfig(decidedConfig());

test("confirmation: N consecutive evaluations on distinct blocks spanning S seconds; any gap resets", () => {
  let seen = updateConfirmations({}, ["0xAA"], 100, 1000);
  assert.equal(isConfirmed(seen["0xaa"], cfg), false, "first sighting");
  seen = updateConfirmations(seen, ["0xAA"], 100, 1000); // same block again: counts once
  assert.equal(seen["0xaa"]!.count, 1);
  seen = updateConfirmations(seen, ["0xAA"], 101, 1030);
  assert.equal(isConfirmed(seen["0xaa"], cfg), false, "two evaluations but only 30 s of chain time (needs 60)");
  seen = updateConfirmations(seen, ["0xAA"], 150, 1070);
  assert.equal(isConfirmed(seen["0xaa"], cfg), true);
  seen = updateConfirmations(seen, [], 151, 1071); // the account left DEFAULT_EXHAUSTED (any other verdict, blind cycle ...)
  assert.deepEqual(seen, {});
  seen = updateConfirmations(seen, ["0xAA"], 152, 1072);
  assert.equal(seen["0xaa"]!.count, 1, "starts over");
});
test("allowance is exactly the debt plus the margin, rounded up, never more", () => {
  assert.equal(allowanceFor(1_000_000n, 10), 1_001_000n);
  assert.equal(allowanceFor(718_600_001n, 10), 718_600_001n + 718_601n); // ceil(718600001 * 10 / 10000) = 718601
  assert.equal(allowanceFor(1n, 0), 1n);
});
test("budget: refuses with no debt, insufficient balance (no partial repayment) and the daily cap", () => {
  const base = { debt: 700_000_000n, keeperUsdc: 1_191_000_000n, spent24h: 0n, capUnits: 1_500_000_000n, marginBp: 10 };
  assert.equal(checkBudget(base).ok, true);
  assert.equal(checkBudget({ ...base, debt: 0n }).ok, false);
  assert.match(checkBudget({ ...base, keeperUsdc: 700_000_000n }).reason!, /no partial repayment/);
  assert.equal(checkBudget({ ...base, keeperUsdc: 700_700_000n }).ok, true, "exactly debt + margin");
  assert.equal(checkBudget({ ...base, keeperUsdc: 700_699_999n }).ok, false, "one unit short");
  assert.match(checkBudget({ ...base, spent24h: 800_000_000n }).reason!, /daily spend cap/);
  assert.equal(checkBudget({ ...base, spent24h: 799_300_000n }).ok, true, "exactly at the cap");
  assert.equal(checkBudget({ ...base, spent24h: 799_300_001n }).ok, false, "one unit over the cap");
});
test("rolling 24 h window", () => {
  const p = (ts: number, a: number) => ({ ts, account: "0x", amountUsdc: String(a), debtAtDecision: String(a), txHash: "0x", blockNumber: 1 });
  assert.equal(spentInWindow([p(0, 5), p(50_000, 7), p(80_000, 11)], 86_400), 18n, "the payment at t=0 is exactly 24 h old and out");
  assert.equal(spentInWindow([p(1, 5)], 86_400), 5n);
  assert.deepEqual(emptyKeeperState(), { halted: null, seen: {}, payments: [], pending: null, cooldown: {} });
});

// ------------------------------------------------------------------ the Foundry-keystore signer (throwaway key, never a real one)
async function makeKeystore(password: string): Promise<{ file: string; dir: string; address: string }> {
  const w = Wallet.createRandom();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ks-"));
  const file = path.join(dir, "keeper");
  fs.writeFileSync(file, await w.encrypt(password, { scrypt: { N: 1024 } }), { mode: 0o600 });
  return { file, dir, address: w.address };
}
const provider = new providers.JsonRpcProvider("http://127.0.0.1:1"); // never contacted by these tests

test("keystore signer: loads with the password from the environment, reports its address, never leaks the password", async () => {
  const PW = "correct horse battery staple 8841";
  const k = await makeKeystore(PW);
  try {
    const s = await KeystoreSigner.load(provider, k.file, "KEEPER_KEYSTORE_PASSWORD", { KEEPER_KEYSTORE_PASSWORD: PW });
    assert.equal(await s.getAddress(), k.address);
    assert.equal(s.kind, "foundry-keystore");
    assert.equal(mask(`something ${PW} something`), "something [RPC-MASKED] something", "the password is registered with the masker");
    await assert.rejects(KeystoreSigner.load(provider, k.file, "KEEPER_KEYSTORE_PASSWORD", { KEEPER_KEYSTORE_PASSWORD: "wrong-password-xyz" }), (e: Error) => /could not be decrypted/.test(e.message) && !e.message.includes("wrong-password-xyz"));
    await assert.rejects(KeystoreSigner.load(provider, k.file, "KEEPER_KEYSTORE_PASSWORD", {}), /not set/);
    await assert.rejects(KeystoreSigner.load(provider, path.join(k.dir, "missing"), "KEEPER_KEYSTORE_PASSWORD", { KEEPER_KEYSTORE_PASSWORD: PW }), /not found/);
    fs.chmodSync(k.file, 0o644);
    await assert.rejects(KeystoreSigner.load(provider, k.file, "KEEPER_KEYSTORE_PASSWORD", { KEEPER_KEYSTORE_PASSWORD: PW }), /accessible to other users/);
  } finally {
    fs.rmSync(k.dir, { recursive: true, force: true });
  }
});

import { pIface } from "../src/chain";
test("every contract function the keeper encodes or decodes is in the ABI it uses (a missing entry must not surface mid-payment)", () => {
  const text = fs.readFileSync(path.join(__dirname, "..", "..", "src", "keeper.ts"), "utf8");
  const names = new Set<string>();
  for (const m of text.matchAll(/(pIface|erc20)\.(?:encodeFunctionData|decodeFunctionResult)\("([A-Za-z0-9_]+)"/g)) names.add(`${m[1]}:${m[2]}`);
  assert.ok(names.size >= 5, `found ${[...names].join(", ")}`);
  const { utils } = require("ethers");
  const { ERC20_ABI } = require("../src/abi");
  const erc = new utils.Interface(ERC20_ABI);
  for (const n of names) {
    const [which, fn] = n.split(":");
    assert.doesNotThrow(() => (which === "pIface" ? pIface : erc).getFunction(fn!), n);
  }
  for (const ev of ["RepayBorrow"]) assert.doesNotThrow(() => pIface.getEvent(ev));
});

test("keeper pays NOTHING while the borrower index (log scan) is behind or failing, and its confirmations restart", async () => {
  const { keeperStep, emptyKeeperState } = await import("../src/keeper");
  const cfg = decidedConfig();
  cfg.keeper.enabled = true;
  const sent: string[] = [];
  const signer: any = { getAddress: async () => cfg.treasury.address, sendTransaction: async () => { sent.push("tx"); throw new Error("must not send"); } };
  const mk = (behind: number, err?: string): any => ({
    blockNumber: 100, blockTimestamp: 1_000, blind: false, indexBehindBlocks: behind, indexError: err, counts: {}, findings: [], alertsSent: [],
    reference: { status: "ok", detail: "" }, expectedTreasuryCall: "0", unrecoverableDebt: { usd: "0", rawUsd: "0", reservesUsd: "0", complete: true }, margin: { classified: 0, unknownFlags: [], positions: [] },
    accounts: [{ account: "0x" + "ab".repeat(20), verdictCode: 3, debtUnits: "1000000" }],
  });
  const state0 = { ...emptyKeeperState(), seen: { x: { count: 5, firstAt: 1, lastAt: 2, lastBlock: 3 } } as any };
  for (const r of [mk(250), mk(0, "rate limited")]) {
    const o = await keeperStep({ ctx: { cfg } as any, signer, alerts: { raise: async () => {} } as any, persist: () => {} } as any, state0, r);
    assert.equal(o.paid.length, 0);
    assert.deepEqual(o.state.seen, {}, "the confirmation counters restart");
    assert.match(o.skipped[0]!.reason, /no payment while the borrower index is incomplete/);
  }
  assert.equal(sent.length, 0);
});

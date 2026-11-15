import test from "node:test";
import assert from "node:assert/strict";
import { utils } from "ethers";
import { VAULT_ABI } from "../src/abi";
import { classifyRevert, revertData } from "../src/errors";

const iface = new utils.Interface(VAULT_ABI);
const rev = (name: string, args: unknown[] = []): Error => Object.assign(new Error("execution reverted"), { data: iface.encodeErrorResult(name, args) });

test("GuardLatched and GuardUnsafe with a latchable bit are HALT; GuardUnsafe with only 16/32 is benign", () => {
  assert.equal(classifyRevert(rev("GuardLatched")).kind, "halt");
  for (const bits of [1, 2, 4, 8, 5, 21]) assert.equal(classifyRevert(rev("GuardUnsafe", [bits])).kind, "halt", String(bits));
  for (const bits of [16, 32, 48]) assert.equal(classifyRevert(rev("GuardUnsafe", [bits])).kind, "benign", String(bits));
});
test("NotOutOfRange, CooldownActive, DailyRebalanceCapReached are benign; CooldownActive carries readyAt", () => {
  assert.equal(classifyRevert(rev("NotOutOfRange", [1, 2, 3])).kind, "benign");
  const c = classifyRevert(rev("CooldownActive", [1_800_000_123]));
  assert.equal(c.kind, "benign");
  assert.equal(c.readyAt, 1_800_000_123);
  assert.equal(classifyRevert(rev("DailyRebalanceCapReached")).kind, "benign");
});
test("ActiveIdMoved is the one retry class and carries the actual id", () => {
  const c = classifyRevert(rev("ActiveIdMoved", [8_388_608, 8_388_610, 2]));
  assert.equal(c.kind, "retry");
  assert.equal(c.actualId, 8_388_610);
});
test("NavLossTooLarge, SwapTooLarge, PairValidationFailed, unknown selectors, Error(string) and Panic are counted failures", () => {
  assert.equal(classifyRevert(rev("NavLossTooLarge", [2, 1])).kind, "failure");
  assert.equal(classifyRevert(rev("SwapTooLarge", [2, 1])).kind, "failure");
  assert.equal(classifyRevert(rev("PairValidationFailed", [3])).kind, "failure");
  assert.equal(classifyRevert(Object.assign(new Error("x"), { data: "0xdeadbeef" })).name, "unknown");
  const strData = "0x08c379a0" + utils.defaultAbiCoder.encode(["string"], ["Too little received"]).slice(2);
  const c = classifyRevert(Object.assign(new Error("x"), { data: strData }));
  assert.equal(c.kind, "failure");
  assert.match(c.detail, /Too little received/);
  assert.equal(classifyRevert(Object.assign(new Error("x"), { data: "0x4e487b71" + "00".repeat(31) + "11" })).name, "Panic");
});
test("a node problem is 'endpoint' (not the vault's fault); a revert without data is a failure", () => {
  assert.equal(classifyRevert(new Error("429 Too Many Requests")).kind, "endpoint");
  assert.equal(classifyRevert(new Error("SERVER_ERROR")).kind, "endpoint");
  assert.equal(classifyRevert(new Error("execution reverted")).kind, "failure");
});
test("revertData finds the data in nested ethers v5 error shapes and in a JSON body", () => {
  const data = iface.encodeErrorResult("GuardLatched", []);
  assert.equal(revertData({ error: { error: { data } } }), data);
  assert.equal(revertData({ body: JSON.stringify({ error: { data } }) }), data);
  assert.equal(revertData(new Error(`call revert exception; data=${data}`)), data);
});

import test from "node:test";
import assert from "node:assert/strict";
import { utils } from "ethers";
import { classifyRevert, revertData } from "../src/errors";
import { ADAPTER_ABI, REGISTRY_ABI, SWAP_ERRORS_ABI } from "../src/abi";

const iface = new utils.Interface([...REGISTRY_ABI.filter((x) => x.startsWith("error ")), ...ADAPTER_ABI.filter((x) => x.startsWith("error ")), ...SWAP_ERRORS_ABI, "error ExecutorError(uint8 code)"]);
const enc = (n: string, a: unknown[] = []) => iface.encodeErrorResult(n, a);

test("the known waits: trigger, oracle, pause, close-path price/fee, swap minimum floors", () => {
  for (const [n, a] of [["TriggerNotReached", [1, 2]], ["OracleUnavailable", []], ["ExecutionPaused", []], ["InvalidClose", [6]], ["InvalidClose", [5]], ["SwapError", [5]], ["SwapError", [7]], ["InsufficientOutput", []]] as Array<[string, unknown[]]>) {
    assert.equal(classifyRevert({ data: enc(n, a) }).kind, "wait", n);
  }
});
test("OrderNotOpen is final; everything else (other codes, ExecutorError, strings, panics, unknown selectors, no data) needs attention", () => {
  assert.equal(classifyRevert({ data: enc("OrderNotOpen") }).kind, "final");
  for (const d of [enc("InvalidClose", [3]), enc("SwapError", [1]), enc("ExecutorError", [24]), "0x4e487b710000000000000000000000000000000000000000000000000000000000000011", "0xdeadbeef"]) assert.equal(classifyRevert({ data: d }).kind, "attention", d);
  const tooLittle = new utils.Interface(["function Error(string)"]).encodeFunctionData("Error", ["Too little received"]);
  assert.equal(classifyRevert({ data: tooLittle }).kind, "wait", "the router's min-out revert is a wait");
  const str = new utils.Interface(["function Error(string)"]).encodeFunctionData("Error", ["MarginVault: insufficient free balance"]);
  const c = classifyRevert({ data: str });
  assert.equal(c.kind, "attention");
  assert.match(c.detail, /insufficient free balance/);
  assert.equal(classifyRevert(new Error("execution reverted")).kind, "attention");
});
test("revert data is found in every shape ethers v5 produces; an endpoint failure is a wait, not a verdict about the order", () => {
  const d = enc("OracleUnavailable");
  assert.equal(revertData({ data: d }), d);
  assert.equal(revertData({ error: { data: d } }), d);
  assert.equal(revertData({ error: { error: { data: { data: d } } } }), d);
  assert.equal(revertData({ error: { body: JSON.stringify({ error: { data: d } }) } }), d);
  assert.equal(revertData(new Error(`call revert exception [ See: ... ] (data="${d}", errorArgs=null)`)), d);
  assert.equal(classifyRevert(new Error("server response 429 Too Many Requests")).kind, "wait");
});

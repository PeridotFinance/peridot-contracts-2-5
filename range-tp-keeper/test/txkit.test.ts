import test from "node:test";
import assert from "node:assert/strict";
import { BigNumber } from "ethers";
import { makeSender, TxReverted } from "../src/txkit";
import type { ExternalSigner } from "../src/signer";

const fees = { maxFeePerGas: BigNumber.from(1), maxPriorityFeePerGas: BigNumber.from(1) };
const signer = (status: number): ExternalSigner => ({
  kind: "fake",
  getAddress: async () => "0x0000000000000000000000000000000000004B33",
  sendTransaction: async () => ({ hash: "0xabc", wait: async () => ({ status, blockNumber: 5, gasUsed: BigNumber.from(7) }) }),
});

test("a mined transaction returns its receipt data and leaves no timer behind (the wait timeout is cleared)", async () => {
  const before = process.getActiveResourcesInfo().filter((r) => r === "Timeout").length;
  const r = await makeSender(signer(1), fees)("0x0000000000000000000000000000000000000001", "0x", BigNumber.from(1));
  assert.equal(r.blockNumber, 5);
  assert.equal(process.getActiveResourcesInfo().filter((x) => x === "Timeout").length, before, "no pending 180 s timer");
});

test("status 0 is a TxReverted, also without a leftover timer", async () => {
  const before = process.getActiveResourcesInfo().filter((r) => r === "Timeout").length;
  await assert.rejects(() => makeSender(signer(0), fees)("0x0000000000000000000000000000000000000001", "0x", BigNumber.from(1)), TxReverted);
  assert.equal(process.getActiveResourcesInfo().filter((x) => x === "Timeout").length, before);
});

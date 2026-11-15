// FORK TEST (read-only) of the keeper's pair-side reads against the REAL Pharaoh USDC/USDt pair on a local anvil fork. UNVERIFIED: compiled, not run (the fork queue is the main thread's).
// Run through run-fork-test.sh (shared lock, endpoint from the environment, block pinned). The vault does not exist yet, so this covers what does not need it:
// the pair ABI (orientation, getBin, getPriceFromId, getSwapOut), the one-sided composition of the bins around the active id, and the swap sizing against the real quote.
// The vault-side end-to-end (rebalance on the real pair with the real vault) is the next fork job, after W2.
import test from "node:test";
import assert from "node:assert/strict";
import { Contract } from "ethers";
import { PAIR_ABI } from "../../src/abi";
import { planSwap } from "../../src/plan";
import { pool18 } from "../../src/sanity";
import { ForkChain, rpcAvailable } from "./harness";

const PAIR = "0x16888EE58E706C253b821EAA637ae9b2cFeA255C";
const USDT = "0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7";
const USDC = "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E";
const skip = rpcAvailable() ? false : "needs AVALANCHE_MAINNET_RPC_URL in the environment (run through run-fork-test.sh)";

test("the live pair: X = USDt, Y = USDC, bin step 1; bins above the active id hold only X, below only Y; the quote and the sizing work on the real pair", { skip, timeout: 600_000 }, async () => {
  const block = process.env.DLMM_FORK_BLOCK ? Number(process.env.DLMM_FORK_BLOCK) : undefined;
  const fork = await ForkChain.start(block);
  try {
    const pair = new Contract(PAIR, PAIR_ABI, fork.provider);
    assert.equal((await pair.getTokenX()).toLowerCase(), USDT.toLowerCase());
    assert.equal((await pair.getTokenY()).toLowerCase(), USDC.toLowerCase());
    assert.equal(Number(await pair.getBinStep()), 1);
    const id: number = Number(await pair.getActiveId());
    const up = await pair.getBin(id + 1);
    const down = await pair.getBin(id - 1);
    assert.equal(up[1].toString(), "0", "a bin above the active id holds no Y");
    assert.equal(down[0].toString(), "0", "a bin below the active id holds no X");
    const p18 = pool18(BigInt((await pair.getPriceFromId(id)).toString()));
    assert.ok(p18 > 990_000_000_000_000_000n && p18 < 1_010_000_000_000_000_000n, `pool price ${p18}`);
    const quote = async (xForY: boolean, amountIn: bigint) => {
      const r = await pair.getSwapOut(amountIn.toString(), xForY);
      return { amountInLeft: BigInt(r[0].toString()), amountOut: BigInt(r[1].toString()) };
    };
    // a hypothetical inventory: 100 USDC after an exit upward (all Y). The oracle is taken from the pool itself here (the feeds are the vault's; the keeper's feed check is unit-tested)
    const plan = await planSwap({ x: 0n, y: 100_000_000n, oracle18: p18, maxSwapBps: 6000, effLossBps: 50, swapSlippageBps: 10, addSlippageBps: 50, quote });
    assert.ok(plan.ok, JSON.stringify(plan, (_k, v) => (typeof v === "bigint" ? v.toString() : v)));
    if (plan.ok) {
      assert.equal(plan.swapXForY, false);
      assert.ok(plan.swapIn > 49_000_000n && plan.swapIn < 51_000_000n);
      assert.ok(plan.residualImbalanceBps < 20);
    }
    assert.equal(fork.proxyStats.http429, 0);
  } finally {
    await fork.stop();
  }
});

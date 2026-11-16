import test from "node:test";
import assert from "node:assert/strict";
import type { providers } from "ethers";
import { checkWiring } from "../src/chain";
import { preflight } from "../src/preflight";
import { A, decidedConfig } from "./fixtures";
import { FakeProvider, newWorld } from "./fakeworld";
import type { World } from "./fakeworld";

const run = async (mut?: (w: World) => void, vaultKnown = true): Promise<{ lines: Array<{ level: string; text: string }>; fails: string[] }> => {
  const w = newWorld();
  mut?.(w);
  const lines = await preflight(new FakeProvider(w) as unknown as providers.Provider, decidedConfig(), w.now, vaultKnown);
  return { lines, fails: lines.filter((l) => l.level === "FAIL").map((l) => l.text) };
};

test("preflight on a healthy world: every check passes (RPC, gas, pair orientation, bin step, active id, feeds, depeg band, pool vs oracle, exit-probe pair reads, quote, vault wiring)", async () => {
  const { lines, fails } = await run();
  assert.deepEqual(fails, []);
  const text = lines.map((l) => l.text).join("\n");
  for (const must of ["RPC reachable", "gas price 3.5 gwei", "pair tokens X=", "bin step 1", "pair active id", "USDC/USD answer", "USDT/USD answer", "pool price at the active id vs the oracle ratio", "exit-probe pair reads", "quote (getSwapOut)", "vault.rebalancer() == the keeper wallet"]) assert.ok(text.includes(must), must);
});
test("preflight without a vault (the host is bootstrapped first): the vault-independent checks run and the vault line is INFO, never a FAIL", async () => {
  const { lines, fails } = await run(undefined, false);
  assert.deepEqual(fails, []);
  assert.ok(lines.some((l) => l.level === "INFO" && /not wired yet/.test(l.text)));
  assert.ok(!lines.some((l) => /vault\.rebalancer/.test(l.text)));
});
test("preflight fails on: a feed out of the depeg band, a stale feed, a pool far from the oracle, a wrong pair orientation, a stale node, a gas price above the cap", async () => {
  assert.ok((await run((w) => { w.feedPair.answer = 99_500_000n; })).fails.some((f) => /USDT\/USD answer/.test(f)));
  assert.ok((await run((w) => { w.feedAsset.updatedAt = w.now - 200_000; })).fails.some((f) => /USDC\/USD age/.test(f)));
  assert.ok((await run((w) => { w.priceNum = 99_100n; })).fails.some((f) => /pool price/.test(f)));
  assert.ok((await run((w) => { w.tokenY = A.keeper; })).fails.some((f) => /pair tokens/.test(f)));
  assert.ok((await run((w) => { w.blockLag = 900; })).fails.some((f) => /RPC reachable/.test(f)));
  assert.ok((await run((w) => { w.gasPrice = 500_000_000_000n; })).fails.some((f) => /gas price/.test(f)));
});
test("the depeg band is the STRICTER of the keeper's (40 bp) and the vault default (50 bp): a leg 45 bp off fails", async () => {
  const { fails } = await run((w) => { w.feedAsset.answer = 99_550_000n; });
  assert.ok(fails.some((f) => /USDC\/USD answer/.test(f) && /= 45 bp/.test(f) && /40 bp/.test(f)), fails.join("|"));
});
test("wiring: pair, feeds, asset, pair token and rebalancer == the keeper wallet are each checked; a latched or unsafe guard FAILS", async () => {
  for (const mut of [(w: World) => { w.wiring.rebalancer = A.vault; }, (w: World) => { w.wiring.pair = A.keeper; }, (w: World) => { w.wiring.feedAsset = A.keeper; }, (w: World) => { w.wiring.feedPair = A.keeper; }, (w: World) => { w.wiring.asset = A.keeper; }, (w: World) => { w.wiring.pairToken = A.keeper; }, (w: World) => { w.latched = true; }]) {
    const w = newWorld();
    mut(w);
    const r = await checkWiring(new FakeProvider(w) as unknown as providers.Provider, decidedConfig());
    assert.ok(r.some((l) => l.level === "FAIL"));
  }
  const ok = await checkWiring(new FakeProvider(newWorld()) as unknown as providers.Provider, decidedConfig());
  assert.ok(!ok.some((l) => l.level === "FAIL"));
});

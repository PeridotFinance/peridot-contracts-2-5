import test from "node:test";
import assert from "node:assert/strict";
import { decide, lossBps, emptyRebalancerState } from "../src/rebalancer";
import type { VaultView } from "../src/rebalancer";
import { requireValidConfig, validateConfig } from "../src/config";
import { decidedConfig } from "./fixtures";

const view = (o: Partial<VaultView> = {}): VaultView => ({ paused: false, tokenId: 7n, tickLower: -100, tickUpper: 100, spotTick: 0, idleAsset: 0n, idlePaired: 0n, ...o });
const base = { edgeTicks: 5, deployIdleMinAssetUnits: 1_000_000n, lastRebalanceAt: undefined as number | undefined, now: 1_000_000, minRebalanceIntervalSeconds: 3600 };

test("decide: nothing to do in range with nothing idle; paused vault is left alone", () => {
  assert.equal(decide({ ...base, v: view() }).action, null);
  assert.equal(decide({ ...base, v: view({ paused: true, idleAsset: 10n ** 12n, spotTick: 500 }) }).action, null);
});
test("decide: idle assets above the threshold are deployed (exactly at the threshold too, not below)", () => {
  assert.equal(decide({ ...base, v: view({ idleAsset: 1_000_000n }) }).action, "deployIdle");
  assert.equal(decide({ ...base, v: view({ idleAsset: 999_999n }) }).action, null);
});
test("decide: out of range or within the edge buffer -> rebalance, once per interval", () => {
  assert.equal(decide({ ...base, v: view({ spotTick: 100 }) }).action, "rebalance", "on the upper bound = outside (the vault requires spot strictly inside)");
  assert.equal(decide({ ...base, v: view({ spotTick: -250 }) }).action, "rebalance");
  assert.equal(decide({ ...base, v: view({ spotTick: 95 }) }).action, "rebalance", "within 5 ticks of the upper edge");
  assert.equal(decide({ ...base, v: view({ spotTick: 94 }) }).action, null, "6 ticks from the edge: fine");
  assert.equal(decide({ ...base, v: view({ spotTick: -96 }) }).action, "rebalance");
  const recent = decide({ ...base, lastRebalanceAt: base.now - 100, v: view({ spotTick: 150 }) });
  assert.equal(recent.action, null);
  assert.match(recent.why, /minimum 3600s/);
  assert.equal(decide({ ...base, lastRebalanceAt: base.now - 3600, v: view({ spotTick: 150 }) }).action, "rebalance", "exactly at the interval");
});
test("decide: no position yet -> deploy when something is idle (the vault creates the position)", () => {
  assert.equal(decide({ ...base, v: view({ tokenId: 0n, idleAsset: 5_000_000n }) }).action, "deployIdle");
  assert.equal(decide({ ...base, v: view({ tokenId: 0n }) }).action, null);
});
test("a rebalance has priority over a deploy when both are wanted", () => {
  assert.equal(decide({ ...base, v: view({ spotTick: 98, idleAsset: 10n ** 12n }) }).action, "rebalance");
});
test("lossBps: zero when value rises, integer basis points of the earlier value otherwise", () => {
  assert.equal(lossBps(1000n, 1000n), 0);
  assert.equal(lossBps(1000n, 1200n), 0);
  assert.equal(lossBps(10_000n, 9_950n), 50);
  assert.equal(lossBps(10_000n, 9_949n), 51);
  assert.equal(lossBps(0n, 0n), 0);
  assert.deepEqual(emptyRebalancerState(), { halted: null, pending: null, lastRebalanceAt: {}, actions: [] });
});
test("config: the rebalancer block is validated only when enabled and cannot share a process with the keeper or executor", () => {
  const c = decidedConfig();
  c.keeper.enabled = false;
  c.rebalancer.enabled = true;
  c.rebalancer.keystorePath = "/data/keystore/rebalancer";
  assert.ok(requireValidConfig(c));
  const bad = (mut: (x: any) => void, re: RegExp) => {
    const x = decidedConfig();
    x.keeper.enabled = false;
    x.rebalancer.enabled = true;
    x.rebalancer.keystorePath = "/data/keystore/rebalancer";
    mut(x);
    assert.ok(validateConfig(x).problems.some((p) => re.test(p.path)), String(re));
  };
  bad((x) => (x.rebalancer.keystorePath = "UNSET"), /rebalancer\.keystorePath/);
  bad((x) => (x.rebalancer.vaults = []), /rebalancer\.vaults/);
  bad((x) => (x.rebalancer.vaults[0].address = "UNSET"), /vaults\[0\]\.address/);
  bad((x) => (x.rebalancer.maxRebalanceLossBps = 0), /maxRebalanceLossBps/);
  bad((x) => (x.keeper.enabled = true), /rebalancer\.enabled/);
});

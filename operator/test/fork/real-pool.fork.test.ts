// The REAL Uniswap V3 WAVAX/USDC 0.05% pool and the REAL Chainlink AVAX/USD feed at the pinned block: the monitor's TWAP path (observe over the
// pool's own history, floor mean tick, integer tick math) must land within the specified tolerance of Chainlink, and the factory identity check
// must confirm the pool. No mocks, no deployment.
import test from "node:test";
import assert from "node:assert/strict";
import { BigNumber } from "ethers";
import { AVAX_FEED, UNIV3_POOL_WAVAX_USDC_500 } from "../../src/constants";
import { ctrlIface, feedIface } from "../../src/chain";
import { checkPoolIdentity, interpretReference, OBSERVE_SECONDS_AGO, poolIface } from "../../src/reference";
import { multicall } from "../../src/multicall";
import { artifacts, ForkChain, PIN_BLOCK, rpcAvailable } from "./harness";

const SKIP = !rpcAvailable() ? "AVALANCHE_MAINNET_RPC_URL not set: fork tests are SKIPPED, not passed" : false;

test("real pool TWAP at the pinned block agrees with Chainlink within the 500 bp tolerance", { skip: SKIP, timeout: 300_000 }, async (t) => {
  void artifacts; void ctrlIface;
  const chain = await ForkChain.start();
  t.after(() => chain.stop());
  assert.equal(await checkPoolIdentity(chain.provider), null, "factory confirms the pool, tokens and fee");
  const res = await multicall(chain.provider, [
    { target: UNIV3_POOL_WAVAX_USDC_500, iface: poolIface, fn: "liquidity" },
    { target: UNIV3_POOL_WAVAX_USDC_500, iface: poolIface, fn: "observe", args: [OBSERVE_SECONDS_AGO] },
    { target: AVAX_FEED, iface: feedIface, fn: "latestRoundData" },
  ], PIN_BLOCK);
  const ref = interpretReference({ poolIdentityOk: true, liquidity: res[0], observe: res[1], minPoolLiquidity: 1000n, usdcOraclePrice: 10n ** 30n });
  assert.equal(ref.status, "ok");
  if (ref.status !== "ok") return;
  const twapUsd = Number(ref.wavaxReference) / 1e18;
  const chainlinkUsd = Number(BigNumber.from(res[2]!.value![1]).toString()) / 1e8;
  const gapBp = Math.abs(twapUsd / chainlinkUsd - 1) * 1e4;
  console.log(`      real pool at ${PIN_BLOCK}: TWAP ${twapUsd.toFixed(4)} USD, Chainlink ${chainlinkUsd.toFixed(4)} USD, gap ${gapBp.toFixed(1)} bp (tolerance 500 bp; 14-day max 308 bp)`);
  assert.ok(gapBp < 500, `gap ${gapBp} bp`);
  assert.ok(twapUsd > 1 && twapUsd < 1000);
});

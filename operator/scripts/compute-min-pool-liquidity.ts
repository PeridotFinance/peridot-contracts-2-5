// Computes `reference.minPoolLiquidity` (operator decision 2026-11-06): 50% of the trailing 7-day median of the Uniswap V3 WAVAX/USDC 0.05% pool's
// in-range liquidity, sampled hourly. READ-ONLY (eth_getBlockByNumber / eth_call at past blocks; needs an ARCHIVE endpoint). Run it ONCE at
// deployment and record the result in the config (--write); the config loader refuses a floor that is not 50% of the recorded median.
//
//   AVALANCHE_MAINNET_RPC_URL=<archive endpoint> node dist/scripts/compute-min-pool-liquidity.js [--days 7] [--step-seconds 3600]
//        [--to-block N] [--write <config.json>]
// The endpoint is read from the environment only; it is never printed, written or passed as an argument; output passes through mask().
import fs from "node:fs";
import { providers, utils } from "ethers";
import { UNIV3_POOL_WAVAX_USDC_500 } from "../src/constants";
import { UNIV3_POOL_ABI } from "../src/abi";
import { requireRpcUrlFromEnv } from "../src/config";
import { floorFromMedian, medianBig, sampleBlocks } from "../src/liquidity";
import { safeError } from "../src/mask";

const arg = (name: string, dflt?: string): string | undefined => {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : dflt;
};

async function main(): Promise<void> {
  const days = Number(arg("--days", "7"));
  const step = Number(arg("--step-seconds", "3600"));
  const provider = new providers.StaticJsonRpcProvider(requireRpcUrlFromEnv(), { chainId: 43114, name: "avalanche" });
  const tip = arg("--to-block") ? Number(arg("--to-block")) : (await provider.getBlock("latest")).number;
  const tTip = (await provider.getBlock(tip)).timestamp;
  const tOld = (await provider.getBlock(tip - 200_000)).timestamp;
  const spb = (tTip - tOld) / 200_000;
  const blocks = sampleBlocks(tip, days, step, spb);
  const iface = new utils.Interface(UNIV3_POOL_ABI);
  const data = iface.encodeFunctionData("liquidity");
  const samples: bigint[] = [];
  let failed = 0;
  const WORKERS = 6;
  let next = 0;
  await Promise.all(Array.from({ length: WORKERS }, async () => {
    for (;;) {
      const i = next++;
      if (i >= blocks.length) return;
      for (let attempt = 0; attempt < 5; attempt++) {
        try {
          const out = await provider.call({ to: UNIV3_POOL_WAVAX_USDC_500, data }, blocks[i]!);
          samples.push(BigInt(iface.decodeFunctionResult("liquidity", out)[0].toString()));
          break;
        } catch (e) {
          if (attempt === 4) failed++;
          await new Promise((r) => setTimeout(r, 1000 * (attempt + 1)));
        }
      }
    }
  }));
  if (samples.length < 100) throw new Error(`only ${samples.length} usable samples (${failed} failed); the floor needs at least 100; the endpoint must be an archive node`);
  const median = medianBig(samples);
  const floor = floorFromMedian(median);
  const result = {
    minPoolLiquidity: floor.toString(),
    minPoolLiquiditySource: {
      fromBlock: blocks[0]!,
      toBlock: tip,
      samples: samples.length,
      medianLiquidity: median.toString(),
      method: `50% of the median of pool.liquidity() sampled every ${step} s over ${days} days (block time ${spb.toFixed(3)} s); min ${samples.reduce((a, b) => (a < b ? a : b)).toString()}, max ${samples.reduce((a, b) => (a > b ? a : b)).toString()}; ${failed} failed samples`,
    },
  };
  const w = arg("--write");
  if (w) {
    const cfg = JSON.parse(fs.readFileSync(w, "utf8"));
    cfg.reference = { ...(cfg.reference ?? {}), ...result };
    fs.writeFileSync(w, JSON.stringify(cfg, null, 2) + "\n");
    console.log(`recorded in ${w}`);
  }
  console.log(JSON.stringify(result, null, 2));
}

main().catch((e) => {
  console.error(`failed: ${safeError(e)}`);
  process.exit(1);
});

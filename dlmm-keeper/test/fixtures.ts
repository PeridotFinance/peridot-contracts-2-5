import { utils } from "ethers";
import type { KeeperConfig } from "../src/config";

export const A = {
  vault: utils.getAddress("0x00000000000000000000000000000000000d1001"),
  pair: "0x16888EE58E706C253b821EAA637ae9b2cFeA255C",
  usdc: utils.getAddress("0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E"), // asset = pair token Y on the live pair
  usdt: utils.getAddress("0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7"), // pair token = X on the live pair
  feedAsset: utils.getAddress("0x00000000000000000000000000000000000f0001"),
  feedPair: utils.getAddress("0x00000000000000000000000000000000000f0002"),
  keeper: utils.getAddress("0x00000000000000000000000000000000000000ee"),
};

export function decidedConfig(dir = "/tmp/dlmm-keeper-test-unused"): KeeperConfig {
  return {
    schemaVersion: 1,
    chainId: 43114,
    label: "test",
    mode: "live",
    vault: A.vault,
    pair: A.pair,
    assetToken: A.usdc,
    pairToken: A.usdt,
    feeds: { asset: A.feedAsset, pair: A.feedPair },
    multicall3: "0xcA11bde05977b3631167028862bE2a173976CA11",
    keeper: { address: A.keeper },
    timing: { pollSeconds: 3, exitWaitSeconds: 60, cooldownSeconds: 120, deadlineSeconds: 120, maxBlockLagSeconds: 60 },
    limits: { maxSendsPerCycle: 1, maxSendsPerDay: 48, maxConsecutiveFailures: 3, maxMinedRevertsPerDay: 2, maxFeeGwei: 100, maxGasLimit: 3_000_000, minWalletWei: "1000", gasPerRebalance: 1_000_000, minRebalancesCovered: 5, gasRunwayCheckSeconds: 300, retryBackoffSeconds: 30, retryBackoffMaxSeconds: 900, maxBandBins: 9 },
    rebalance: { idSlippage: 2, swapSlippageBps: 10, addSlippageBps: 50, maxQuoteLossBps: 40, maxPoolOracleDevBps: 50, keeperLegBandBps: 40, maxActiveIdShift: 4 },
    guard: { autoTripGuard: false, tripDebounceSeconds: 15 },
    probe: { everyCycles: 20 },
    monitor: { statePath: `${dir}/state.json`, haltPath: `${dir}/HALT` },
    alerts: { channel: "log" },
  };
}

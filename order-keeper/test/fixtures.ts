import { utils } from "ethers";
import type { KeeperConfig } from "../src/config";

export const A = {
  registry: "0x2C731a83548fFeD57f5FB6929229e332B08A17ba",
  adapter: "0xFcF4Af996d714376b1D27747A46BD063B4962507",
  executor: "0x88Ef3924d5f5AeA3Cbf4e52Bd7215FaB9B348713",
  vault: "0x659D4Be42ceFeB469330f20aAf609F1068382314",
  keeper: utils.getAddress("0x00000000000000000000000000000000000000ee"),
  owner: utils.getAddress("0x000000000000000000000000000000000000a11c"),
  pUsdc: "0x1000000000000000000000000000000000000001",
  pWavax: "0x1000000000000000000000000000000000000002",
};

export function decidedConfig(): KeeperConfig {
  return {
    schemaVersion: 1,
    chainId: 43114,
    label: "test",
    registry: A.registry,
    closeAdapter: A.adapter,
    marginExecutor: A.executor,
    marginVault: A.vault,
    keeper: { address: A.keeper, keystorePath: "/tmp/does-not-matter.json", passwordEnv: "ORDER_KEEPER_KEYSTORE_PASSWORD" },
    limits: { maxFeeGwei: 100, minGasWei: "1000", maxGasLimit: 4_000_000, maxSendsPerCycle: 3, maxSendsPerDay: 60, maxMinedRevertsPerDay: 3, sweep: true, maxIdsPerCycle: 500, retryCooldownSeconds: 30, retryCooldownMaxSeconds: 300, unknownRevertCooldownSeconds: 900, unfilledAlertSeconds: 600 },
    logs: { enabled: true, chunkBlocks: 10, maxChunksPerCycle: 5, minIntervalMs: 0, reorgMarginBlocks: 10, behindWarnBlocks: 600 },
    monitor: { pollSeconds: 15, maxBlockLagSeconds: 60, statePath: "/tmp/unused.json" },
    alerts: { channel: "log" },
    escalationSeconds: [3600, 14400, 86400],
  };
}

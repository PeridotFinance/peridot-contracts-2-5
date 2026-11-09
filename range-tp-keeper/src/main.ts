// CLI: `check` (read-only: chain id, custodian reads, keeper balance; sends nothing), `once` (one step), `run` (loop).
//   RANGE_KEEPER_CONFIG=path.json  AVALANCHE_MAINNET_RPC_URL=...  RANGE_KEEPER_KEYSTORE_PASSWORD=...  node dist/src/main.js once
// The endpoint is read from the environment and never printed; every string that leaves the process is masked.
import { providers } from "ethers";
import { Alerts, ConsoleSink } from "./alerts";
import { loadConfig, requireRpcUrl } from "./config";
import { configureLogPace } from "./logpace";
import { keeperStep } from "./keeper";
import { safeError } from "./mask";
import { EthersPort } from "./port";
import { KeystoreSigner } from "./signer";
import { loadState, saveState } from "./state";

async function main(): Promise<void> {
  const cmd = process.argv[2] ?? "check";
  const cfg = loadConfig(process.env.RANGE_KEEPER_CONFIG ?? "config/keeper.json");
  const provider = new providers.StaticJsonRpcProvider({ url: requireRpcUrl(cfg.rpcEnv), throttleLimit: 1 }, cfg.chainId);
  const logProvider = cfg.logRpcEnv ? new providers.StaticJsonRpcProvider({ url: requireRpcUrl(cfg.logRpcEnv), throttleLimit: 1 }, cfg.chainId) : provider;
  configureLogPace({ minIntervalMs: cfg.logMinIntervalMs });
  const signer = await KeystoreSigner.load(provider, cfg.keystore.path, cfg.keystore.passwordEnv);
  const port = new EthersPort(provider, signer, { custodian: cfg.custodian, maxFeeGwei: cfg.maxFeeGwei, logChunkBlocks: cfg.logChunkBlocks }, logProvider);
  const alerts = new Alerts(new ConsoleSink());
  if ((await port.chainId()) !== cfg.chainId) throw new Error(`chain id differs from ${cfg.chainId}`);
  if (cmd === "check") {
    const h = await port.head();
    const next = await port.nextPositionId();
    process.stdout.write(`ok: chain ${cfg.chainId}, head ${h.number}, positions ${next - 1n}, keeper ${await port.keeperAddress()}, AVAX wei ${await port.keeperBalanceWei()}\n`);
    return;
  }
  const deps = { port, alerts, limits: cfg.limits, persist: (s: ReturnType<typeof loadState>) => saveState(cfg.statePath, s) };
  let state = loadState(cfg.statePath);
  const step = async (): Promise<void> => {
    const r = await keeperStep(deps, state);
    state = r.state;
    for (const d of r.decisions) process.stdout.write(`${new Date().toISOString()} position ${d.positionId}: ${d.kind}${"reason" in d ? ` - ${d.reason}` : ""}\n`);
    if (r.halted) process.stdout.write("HALTED: see the state file; a human clears it\n");
  };
  if (cmd === "once") return step();
  for (;;) {
    try {
      await step();
    } catch (e) {
      process.stderr.write(`step failed: ${safeError(e)}\n`);
    }
    await new Promise((res) => setTimeout(res, cfg.pollSeconds * 1000));
  }
}
main().catch((e) => {
  process.stderr.write(`fatal: ${safeError(e)}\n`);
  process.exit(1);
});

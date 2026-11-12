// FORK RECIPE for the margin 2x stack (for the TP/SL keeper and range take-profit work, and for the operator rehearsals).
// It brings up a LOCAL anvil fork of the current Avalanche head and runs, with accounts IMPERSONATED (nothing real is signed):
//   1. the PW30 lending ceremony (exact wrapper, exact pilot inputs) and its post-deploy steps,
//   2. the margin ceremony stages 1 to 4 (exact wrapper `contracts/tools/avalanche-margin-ceremony.sh`): deploy by a throwaway deployer,
//      wire / execute / enable by the Ledger, with the 24 h timelock crossed by moving the fork clock,
//   3. optionally (--demo-position) one open 2x long for ALICE so that orders have a position to act on.
// The Chainlink AVAX/USD and USDC/USD feeds are replaced on the FORK by settable mocks (the real ones go stale when the clock moves); the
// mock feeds are `set(int256 answer8, uint256 updatedAt)`; the addresses are in the addresses file. The pool, router and tokens are real.
// The private endpoint is read from the ENVIRONMENT and reached through a local pass-through proxy; it is never printed.
//   AVALANCHE_MAINNET_RPC_URL=... node dist/scripts/margin-fork-up.js [--demo-position] [--out margin-fork.json]
// The process keeps the fork (and the proxy) alive until it receives SIGINT/SIGTERM; the file written to --out holds the local RPC URL.
// (The body is in scripts/margin-fork-lib.ts, shared with the operator rehearsal; behaviour and output are unchanged.)
import fs from "node:fs";
import { ForkChain } from "../test/fork/harness";
import { safeError } from "../src/mask";
import { bringUpMarginFork } from "./margin-fork-lib";

(async () => {
  const demo = process.argv.includes("--demo-position");
  const chain = await ForkChain.start("latest");
  let keepAlive = false;
  let report: Record<string, any> = { startedAt: new Date().toISOString() };
  try {
    const b = await bringUpMarginFork(chain, { demo });
    report = b.report;
    report.ok = true;
    keepAlive = true;
  } catch (e) {
    report.ok = false;
    report.error = safeError(e);
  }
  report.finishedAt = new Date().toISOString();
  const text = JSON.stringify(report, null, 2);
  const outIdx = process.argv.indexOf("--out");
  if (outIdx >= 0) fs.writeFileSync(process.argv[outIdx + 1]!, text + "\n");
  console.log(text);
  if (!keepAlive) {
    await chain.stop();
    process.exit(1);
  }
  console.log("\nfork is up; Ctrl-C to stop");
  const stop = async () => {
    await chain.stop();
    process.exit(0);
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
})();

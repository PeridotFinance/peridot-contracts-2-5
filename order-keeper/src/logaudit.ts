// OPTIONAL LOG CROSS-CHECK through the SEPARATE log endpoint. Discovery does not depend on it (the registry is read by id at the head): this only
// confirms, from an independent source, that every OrderCreated event seen in the logs has an id the keeper has already read. It starts at the head
// when first run (no history scan: a free-tier endpoint serves 10 blocks per request, which makes a history scan impractical), goes forward in bounded
// chunks with the pacing and 429 back-off of logpace.ts, and NEVER throws: a rate-limited or failing log endpoint is a warning, not a stop.
import type { providers } from "ethers";
import type { AlertManager } from "./alerts";
import type { KeeperConfig } from "./config";
import { LogRateLimitedError, pacedGetLogs } from "./logpace";
import { safeError } from "./mask";
import { registryIface } from "./orders";
import type { KeeperState } from "./state";

export interface LogAuditResult {
  cursor: number | null;
  scannedBlocks: number;
  created: string[];
  /** OrderCreated ids in the logs that the id scan has not read yet although the log is older than the reorg margin */
  uncovered: string[];
  limited: boolean;
  failed: boolean;
}

export async function logCrossCheck(deps: { logProvider: providers.Provider; cfg: KeeperConfig; alerts: AlertManager; now: () => number }, state: KeeperState, headBlock: number, caughtUp = true): Promise<LogAuditResult> {
  const { cfg, alerts } = deps;
  const g = cfg.logs;
  const res: LogAuditResult = { cursor: state.logCursor, scannedBlocks: 0, created: [], uncovered: [], limited: false, failed: false };
  const safeTo = headBlock - g.reorgMarginBlocks;
  if (state.logCursor === null) {
    res.cursor = safeTo; // start at the head: orders created from now on are cross-checked
    return res;
  }
  const topic = registryIface.getEventTopic("OrderCreated");
  let cursor = state.logCursor;
  try {
    for (let chunk = 0; chunk < g.maxChunksPerCycle && cursor < safeTo; chunk++) {
      const from = cursor + 1;
      const to = Math.min(safeTo, from + g.chunkBlocks - 1);
      const logs = await pacedGetLogs(deps.logProvider, { address: cfg.registry, topics: [topic], fromBlock: from, toBlock: to });
      for (const l of logs) {
        const id = BigInt(l.topics[1]!);
        res.created.push(id.toString());
        // only meaningful once the id scan has caught up with nextOrderId (a cycle that hit maxIdsPerCycle legitimately leaves highWater behind)
        if (caughtUp && id >= BigInt(state.highWater)) res.uncovered.push(id.toString());
      }
      res.scannedBlocks += to - from + 1;
      cursor = to;
    }
    await alerts.clear("logs:limited", deps.now());
    await alerts.clear("logs:failed", deps.now());
  } catch (e) {
    if (e instanceof LogRateLimitedError) {
      res.limited = true;
      await alerts.raise({ key: "logs:limited", severity: "warn", message: `the log endpoint rate-limited the order cross-check (${safeError(e)}). Order discovery is unaffected (it reads the registry by id); the cross-check resumes after the back-off`, audience: "keeper-operator" }, deps.now());
    } else {
      res.failed = true;
      await alerts.raise({ key: "logs:failed", severity: "warn", message: `the log endpoint failed the order cross-check (${safeError(e)}). Order discovery is unaffected`, audience: "keeper-operator" }, deps.now());
    }
  }
  res.cursor = cursor;
  if (res.uncovered.length) await alerts.raise({ key: "logs:uncovered", severity: "crit", message: `OrderCreated for id(s) ${res.uncovered.slice(0, 8).join(", ")} appears in the logs but the keeper's id scan has not read it (it has read ids below ${state.highWater}): the state endpoint may be serving old state, or nextOrderId is wrong`, audience: "keeper-operator" }, deps.now());
  else await alerts.clear("logs:uncovered", deps.now());
  if (safeTo - cursor > g.behindWarnBlocks) await alerts.raise({ key: "logs:behind", severity: "warn", message: `the log cross-check is ${safeTo - cursor} blocks behind the head (limit ${g.behindWarnBlocks}); the endpoint is slow or limited. Discovery is unaffected`, audience: "keeper-operator" }, deps.now());
  else await alerts.clear("logs:behind", deps.now());
  return res;
}

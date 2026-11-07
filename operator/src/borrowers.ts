// Borrower index. The pUSDC borrower mapping is not enumerable on chain, so the index is built from the market's own events
// (Borrow, RepayBorrow, LiquidateBorrow) from the deployment block, with a persisted cursor, a reorg margin, and a periodic full re-scan.
// The index only says WHO MAY HAVE DEBT; whether they do is always re-read from chain at the evaluation block.
import { providers, utils } from "ethers";
import fs from "node:fs";
import path from "node:path";
import { PTOKEN_ABI } from "./abi";

const iface = new utils.Interface(PTOKEN_ABI);
const TOPICS = ["Borrow", "RepayBorrow", "LiquidateBorrow"].map((n) => iface.getEventTopic(n));

export interface IndexState {
  lastScannedBlock: number;
  borrowers: string[]; // lower-case, sorted
}

export function emptyIndex(deploymentBlock: number): IndexState {
  return { lastScannedBlock: deploymentBlock - 1, borrowers: [] };
}

export async function scanBorrowers(provider: providers.Provider, pUsdc: string, from: number, to: number, chunk: number): Promise<Set<string>> {
  const found = new Set<string>();
  for (let s = from; s <= to; s += chunk) {
    const e = Math.min(to, s + chunk - 1);
    const logs = await provider.getLogs({ address: pUsdc, fromBlock: s, toBlock: e, topics: [TOPICS] });
    for (const l of logs) {
      const p = iface.parseLog(l);
      const who = (p.name === "Borrow" ? p.args.borrower : p.args.borrower) as string; // all three events name the borrower
      found.add(who.toLowerCase());
    }
  }
  return found;
}

/** Incremental update: re-scan the last `reorgMargin` blocks again, then everything up to `toBlock`. Returns the new state (does not mutate). */
export async function updateIndex(provider: providers.Provider, pUsdc: string, state: IndexState, toBlock: number, chunk: number, reorgMargin: number): Promise<IndexState> {
  const from = Math.max(state.lastScannedBlock - reorgMargin + 1, 1);
  if (toBlock < from) return state;
  const found = await scanBorrowers(provider, pUsdc, from, toBlock, chunk);
  const all = new Set(state.borrowers);
  for (const a of found) all.add(a);
  return { lastScannedBlock: toBlock, borrowers: [...all].sort() };
}

/** Full re-scan from the deployment block; returns accounts present in one index but not the other (cross-check of the incremental index). */
export async function crossCheckIndex(provider: providers.Provider, pUsdc: string, state: IndexState, deploymentBlock: number, toBlock: number, chunk: number): Promise<{ missingFromIndex: string[]; extraInIndex: string[] }> {
  const full = await scanBorrowers(provider, pUsdc, deploymentBlock, toBlock, chunk);
  const have = new Set(state.borrowers);
  return { missingFromIndex: [...full].filter((a) => !have.has(a)).sort(), extraInIndex: [...have].filter((a) => !full.has(a)).sort() };
}

// ---- persistence: public data only (addresses and block numbers), written atomically
export function loadState<T>(file: string, fallback: T): T {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8")) as T;
  } catch {
    return fallback;
  }
}
export function saveState(file: string, data: unknown): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(data, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2));
  fs.renameSync(tmp, file);
}

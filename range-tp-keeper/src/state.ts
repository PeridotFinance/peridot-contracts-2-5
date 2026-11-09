// KEEPER STATE. Persisted as JSON, atomically (write to a temp file, then rename), BEFORE any transaction is sent and after every change.
// Same discipline as operator/src/keeper.ts: `halted` stops everything until a human clears it; `pending` is set before a send and cleared
// when the send is finished, so a process killed between the two is found at start-up and halts (it cannot know whether the send happened).
import fs from "node:fs";
import path from "node:path";

export interface Finalisation {
  positionId: string;
  ts: number;
  txHash: string;
  blockNumber: number;
  gasUsed: string;
  rungsFinalised: number;
  orderSettled: boolean;
  positionClosed: boolean;
}
export interface Removal {
  positionId: string;
  ts: number;
  kind: "risk-path-or-owner" | "finalised-by-another-caller";
}
export interface KeeperState {
  halted: null | { reason: string; at: number };
  /** set (and persisted) BEFORE the send, cleared when the send is finished; found set at start-up = interrupted = HALT */
  pending: null | { positionId: string; at: number };
  /** position ids whose order was seen ACTIVE: used to notice, once, that a band went away without us */
  watching: Record<string, { firstSeen: number }>;
  /** position ids that need no further reading (position terminal, or order ended) */
  done: Record<string, true>;
  /** next position id to scan from (everything below is `done` or has no order) */
  cursor: string;
  /** retry-not-before (unix s) per position, set after a refusal that is not a plain wait */
  cooldown: Record<string, number>;
  finalisations: Finalisation[];
  removals: Removal[];
}
export const emptyState = (): KeeperState => ({ halted: null, pending: null, watching: {}, done: {}, cursor: "1", cooldown: {}, finalisations: [], removals: [] });

export function loadState(file: string): KeeperState {
  if (!fs.existsSync(file)) return emptyState();
  const raw = JSON.parse(fs.readFileSync(file, "utf8")) as Partial<KeeperState>;
  return { ...emptyState(), ...raw };
}
export function saveState(file: string, s: KeeperState): void {
  const tmp = path.join(path.dirname(file), `.${path.basename(file)}.tmp`);
  fs.writeFileSync(tmp, JSON.stringify(s, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, file);
}

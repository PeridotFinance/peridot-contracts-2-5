// The keeper's persistent state: public data only, written atomically (tmp + rename) on a mounted volume. A human clears `halted` / `pending`.
import fs from "node:fs";
import path from "node:path";
import type { AlertStateJson } from "./alerts";

export interface PendingMarker {
  orderId: string;
  kind: "execute" | "sweep";
  at: number;
  /** filled in as soon as the transaction hash is known and the state is saved again */
  tx?: string;
}
export interface CooldownEntry {
  /** unix s: not retried before */
  until: number;
  /** consecutive failed simulations (drives the doubling) */
  fails: number;
  firstFailAt: number;
  why: string;
}
export interface SendRecord {
  ts: number;
  orderId: string;
  kind: "execute" | "sweep";
  tx: string;
  outcome: "ok" | "reverted";
}
export interface KeeperState {
  schemaVersion: 1;
  /** the registry these ids belong to: a state file of another registry is refused at start */
  registry: string;
  halted: null | { reason: string; at: number };
  /** set (and persisted) BEFORE every transaction; found set at start-up = interrupted = HALT */
  pending: null | PendingMarker;
  /** every order id below this has been read at least once (ids start at 1) */
  highWater: number;
  /** ids last seen OPEN (decimal strings): the only ids read again; terminal states never come back */
  open: string[];
  cooldown: Record<string, CooldownEntry>;
  /** rolling 7 days: the per-day limits and the history */
  sends: SendRecord[];
  /** log cross-check position (block number of the last scanned block), null until the first run */
  logCursor: number | null;
  alerts?: AlertStateJson;
}
export const emptyState = (registry: string): KeeperState => ({ schemaVersion: 1, registry: registry.toLowerCase(), halted: null, pending: null, highWater: 1, open: [], cooldown: {}, sends: [], logCursor: null });

export class StateError extends Error {}

/** A missing file is a fresh start; a file that exists but cannot be read, parsed or that belongs to another registry is REFUSED (never silently reset). */
export function loadState(file: string, registry: string): KeeperState {
  let text: string;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return emptyState(registry);
    throw new StateError("the state file exists but cannot be read");
  }
  let s: KeeperState;
  try {
    s = JSON.parse(text) as KeeperState;
  } catch {
    throw new StateError("the state file is not valid JSON (it is not replaced automatically: a pending marker or halt flag may be in it)");
  }
  if (s.schemaVersion !== 1) throw new StateError("unknown state schema version");
  if (typeof s.registry !== "string" || s.registry.toLowerCase() !== registry.toLowerCase()) throw new StateError("the state file belongs to a different registry; ids from one registry mean nothing in another. Use a new state path");
  return { ...emptyState(registry), ...s };
}

export function saveState(file: string, data: KeeperState): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp`;
  const fd = fs.openSync(tmp, "w", 0o600);
  try {
    fs.writeFileSync(fd, JSON.stringify(data, null, 2));
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(tmp, file);
}

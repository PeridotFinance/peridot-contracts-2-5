// Persistent state: public data only, written atomically (tmp + rename) on a mounted volume.
//
// THE HALT FILE is the single authority on "halted". Its EXISTENCE halts the keeper: it is checked at the start of every cycle (a plain fs read, no chain I/O),
// so there is no second in-memory flag or state-file flag that can drift from it. The keeper creates it (guard latch, repeated failures, an interrupted send,
// a read-back mismatch, a rebalance it did not make) and NEVER removes it. Only the explicit manual command `dlmm-keeper resume` removes it (and appends an
// audit line to <haltPath>.log). A HALT file that cannot be parsed still halts.
import fs from "node:fs";
import path from "node:path";
import type { AlertStateJson } from "./alerts";

export type HaltKind = "guard" | "failures" | "mined-reverts" | "pending-interrupted" | "readback" | "unexpected" | "foreign-rebalance" | "wiring" | "manual";
export interface HaltRecord {
  kind: HaltKind;
  reason: string;
  at: number;
  /** guardState().reasons at the moment of the halt, when it was a guard halt */
  reasons?: number;
  /** tripGuard(): "disabled" | "dry-run" | "not-needed (already latched)" | "condition cleared" | "sent <hash>" | "failed: ..." */
  trip?: string;
}
export interface PendingMarker {
  kind: "rebalance" | "tripGuard";
  at: number;
  tx?: string;
}
export interface SendRecord {
  ts: number;
  kind: "rebalance" | "tripGuard";
  tx: string;
  outcome: "ok" | "reverted";
}
export interface ExitMarker {
  /** unix s the keeper first saw the active id outside the band */
  since: number;
  lowerId: number;
  upperId: number;
}
export interface BackoffEntry {
  until: number;
  /** consecutive counted failures */
  fails: number;
  firstFailAt: number;
  why: string;
}
export interface KeeperState {
  schemaVersion: 1;
  vault: string;
  /** set (and persisted) BEFORE every transaction; found set at start-up = interrupted = HALT */
  pending: null | PendingMarker;
  exit: null | ExitMarker;
  backoff: null | BackoffEntry;
  /** rolling 7 days: the per-day limits and the history */
  sends: SendRecord[];
  /** vault.lastRebalanceAt as of the last time the keeper looked after its own send (null until first observed): a different value later = someone else rebalanced */
  lastRebalanceSeen: number | null;
  lastGasCheckAt: number;
  alerts?: AlertStateJson;
}
export const emptyState = (vault: string): KeeperState => ({ schemaVersion: 1, vault: vault.toLowerCase(), pending: null, exit: null, backoff: null, sends: [], lastRebalanceSeen: null, lastGasCheckAt: 0 });

export class StateError extends Error {}

/** A missing file is a fresh start; a file that exists but cannot be read, parsed or that belongs to another vault is REFUSED (never silently reset). */
export function loadState(file: string, vault: string): KeeperState {
  let text: string;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return emptyState(vault);
    throw new StateError("the state file exists but cannot be read");
  }
  let s: KeeperState;
  try {
    s = JSON.parse(text) as KeeperState;
  } catch {
    throw new StateError("the state file is not valid JSON (it is not replaced automatically: a pending marker may be in it)");
  }
  if (s.schemaVersion !== 1) throw new StateError("unknown state schema version");
  if (typeof s.vault !== "string" || s.vault.toLowerCase() !== vault.toLowerCase()) throw new StateError("the state file belongs to a different vault. Use a new state path");
  return { ...emptyState(vault), ...s };
}

function writeAtomic(file: string, data: string): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp`;
  const fd = fs.openSync(tmp, "w", 0o600);
  try {
    fs.writeFileSync(fd, data);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(tmp, file);
}
export function saveState(file: string, data: KeeperState): void {
  writeAtomic(file, JSON.stringify(data, null, 2));
}

// ---------------------------------------------------------------- the HALT file
/** null = not halted. Any existing file halts, even an unreadable one. */
export function readHalt(haltPath: string): HaltRecord | null {
  let text: string;
  try {
    text = fs.readFileSync(haltPath, "utf8");
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return null;
    return { kind: "manual", reason: "the HALT file exists but cannot be read (treated as halted)", at: 0 };
  }
  try {
    const r = JSON.parse(text) as HaltRecord;
    if (r && typeof r === "object" && typeof r.reason === "string") return r;
  } catch {
    /* fall through */
  }
  return { kind: "manual", reason: "the HALT file exists but is not valid JSON (treated as halted)", at: 0 };
}
/** Creates the HALT file. An existing one is KEPT (the first cause stays) unless `update` is set (the trip outcome is added to the same record). */
export function writeHalt(haltPath: string, rec: HaltRecord, update = false): void {
  if (!update && fs.existsSync(haltPath)) return;
  writeAtomic(haltPath, JSON.stringify(rec, null, 2));
}
/** The manual `resume` command only. Appends an audit line. Returns the record that was removed (null when there was none). */
export function clearHalt(haltPath: string, nowSeconds: number): HaltRecord | null {
  const rec = readHalt(haltPath);
  if (!rec) return null;
  fs.appendFileSync(`${haltPath}.log`, JSON.stringify({ resumedAt: nowSeconds, was: rec }) + "\n", { mode: 0o600 });
  fs.unlinkSync(haltPath);
  return rec;
}

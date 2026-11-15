import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { clearHalt, emptyState, loadState, readHalt, saveState, StateError, writeHalt } from "../src/state";

const tmp = (): string => fs.mkdtempSync(path.join(os.tmpdir(), "dk-state-"));
const V = "0x00000000000000000000000000000000000D1001";

test("HALT file: absent = not halted; present = halted; the FIRST cause is kept; resume removes it and appends an audit line", () => {
  const f = path.join(tmp(), "HALT");
  assert.equal(readHalt(f), null);
  writeHalt(f, { kind: "guard", reason: "first", at: 1, reasons: 4 });
  writeHalt(f, { kind: "failures", reason: "second", at: 2 });
  assert.equal(readHalt(f)?.reason, "first");
  writeHalt(f, { kind: "guard", reason: "first", at: 1, reasons: 4, trip: "disabled" }, true);
  assert.equal(readHalt(f)?.trip, "disabled");
  const was = clearHalt(f, 99);
  assert.equal(was?.kind, "guard");
  assert.equal(readHalt(f), null);
  const log = fs.readFileSync(`${f}.log`, "utf8").trim().split("\n");
  assert.equal(JSON.parse(log[0]!).resumedAt, 99);
  assert.equal(clearHalt(f, 100), null, "nothing to resume");
});
test("a HALT file that is empty, garbage or unreadable STILL halts", () => {
  const d = tmp();
  const f = path.join(d, "HALT");
  fs.writeFileSync(f, "");
  assert.ok(readHalt(f));
  fs.writeFileSync(f, "not json{");
  assert.match(readHalt(f)!.reason, /not valid JSON/);
  fs.rmSync(f);
  fs.mkdirSync(f); // a directory where the file should be: unreadable
  assert.match(readHalt(f)!.reason, /cannot be read/);
});
test("state: missing = fresh; round trip; another vault's file and a corrupt file are REFUSED, never silently reset", () => {
  const f = path.join(tmp(), "s.json");
  assert.deepEqual(loadState(f, V), emptyState(V));
  const s = { ...emptyState(V), exit: { since: 5, lowerId: 1, upperId: 3 }, lastRebalanceSeen: 7 };
  saveState(f, s);
  assert.deepEqual(loadState(f, V), s);
  assert.equal((fs.statSync(f).mode & 0o077), 0, "state file is private");
  assert.throws(() => loadState(f, "0x00000000000000000000000000000000000D1002"), StateError);
  fs.writeFileSync(f, "{broken");
  assert.throws(() => loadState(f, V), StateError);
});

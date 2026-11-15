import test, { beforeEach } from "node:test";
import assert from "node:assert/strict";
import { utils } from "ethers";
import { updateIndexBounded } from "../src/borrowers";
import { configureLogPace } from "../src/logpace";
import { PTOKEN_ABI } from "../src/abi";
import { validateConfig } from "../src/config";
import { decidedConfig, A } from "./fixtures";

beforeEach(() => configureLogPace({ minIntervalMs: 0, now: () => Date.now() })); // the back-off state is module-level: a test that provokes a rate limit must not leak into the next
const iface = new utils.Interface(PTOKEN_ABI);
const PUSDC = A(0x12);
/** a fake log endpoint with a hard range limit, a list of borrowers per block and optional failures */
function fake(opts: { limit: number; borrowAt?: Record<number, string>; failFrom?: number }): { provider: any; calls: Array<[number, number]> } {
  const calls: Array<[number, number]> = [];
  const provider = {
    async getLogs(f: { fromBlock: number; toBlock: number }) {
      calls.push([f.fromBlock, f.toBlock]);
      if (f.toBlock - f.fromBlock + 1 > opts.limit) throw new Error("range too large");
      if (opts.failFrom !== undefined && f.fromBlock >= opts.failFrom) throw new Error("rate limited");
      const out: any[] = [];
      for (const [b, who] of Object.entries(opts.borrowAt ?? {})) {
        const bn = Number(b);
        if (bn >= f.fromBlock && bn <= f.toBlock) out.push({ ...iface.encodeEventLog(iface.getEvent("Borrow"), [who, 1, 1, 1]), blockNumber: bn, address: PUSDC });
      }
      return out;
    },
  };
  return { provider, calls };
}
const st0 = { lastScannedBlock: 999, borrowers: [] as string[] };

test("log scan: a range limit of 2,048 is respected and the whole range is covered in chunks", async () => {
  const f = fake({ limit: 2048, borrowAt: { 1500: A(0xb1), 7000: A(0xb2) } });
  const r = await updateIndexBounded(f.provider, PUSDC, st0, 9999, 2048, 10, 1000);
  assert.equal(r.error, undefined);
  assert.equal(r.behindBlocks, 0);
  assert.equal(r.state.lastScannedBlock, 9999);
  assert.deepEqual(r.state.borrowers, [A(0xb1), A(0xb2)]);
  assert.ok(f.calls.every(([a, b]) => b - a + 1 <= 2048), "no request above the limit");
});
test("log scan: the per-cycle bound keeps progress and says how far behind it is", async () => {
  const f = fake({ limit: 2048, borrowAt: { 1500: A(0xb1) } });
  const r = await updateIndexBounded(f.provider, PUSDC, st0, 20_000, 2048, 10, 3);
  assert.equal(r.chunksScanned, 3);
  assert.ok(r.behindBlocks > 0 && /bounded/.test(r.error ?? ""));
  assert.equal(r.state.lastScannedBlock, 990 + 3 * 2048 - 1, "the cursor sits at the end of the last scanned chunk");
  assert.deepEqual(r.state.borrowers, [A(0xb1)]);
  // the next cycle resumes from the cursor (minus the reorg margin), not from the start
  const g = fake({ limit: 2048 });
  const r2 = await updateIndexBounded(g.provider, PUSDC, r.state, 20_000, 2048, 10, 100);
  assert.equal(g.calls[0]![0], r.state.lastScannedBlock - 10 + 1);
  assert.equal(r2.behindBlocks, 0);
});
test("log scan: a failing endpoint never throws, never moves the cursor past the failed chunk, and keeps what it found", async () => {
  const f = fake({ limit: 2048, borrowAt: { 1500: A(0xb1), 9000: A(0xb2) }, failFrom: 5000 });
  const r = await updateIndexBounded(f.provider, PUSDC, st0, 12_000, 2048, 10, 100);
  assert.match(r.error ?? "", /rate.?limit/i);
  assert.ok(r.state.lastScannedBlock < 5000 + 2048);
  assert.ok(r.state.borrowers.includes(A(0xb1)) && !r.state.borrowers.includes(A(0xb2)), "found before the failure kept, after it not invented");
  assert.ok(r.behindBlocks > 0);
  const dead = fake({ limit: 2048, failFrom: 0 });
  const r2 = await updateIndexBounded(dead.provider, PUSDC, st0, 12_000, 2048, 10, 100);
  assert.equal(r2.state.lastScannedBlock, st0.lastScannedBlock, "nothing scanned: the cursor stays");
});
test("log scan: nothing to do when the cursor is at the head", async () => {
  const f = fake({ limit: 2048 });
  const r = await updateIndexBounded(f.provider, PUSDC, { lastScannedBlock: 5000, borrowers: [A(1)] }, 5000, 2048, 0, 10);
  assert.equal(r.chunksScanned, 0);
  assert.equal(r.behindBlocks, 0);
});

test("config: the log block is optional, bounded by the public endpoint's 2,048 blocks, and ordered", () => {
  const c = decidedConfig();
  assert.equal(validateConfig(c).problems.length, 0);
  assert.equal(c.monitor.logs.chunkBlocks, 100, "the template ships the MEASURED 100-block limit of the public endpoint (9 Nov 2026), not the 2,048 once assumed");
  delete c.monitor.logs;
  assert.equal(validateConfig(c).problems.length, 0, "old configurations still load");
  const bad = (x: any) => validateConfig({ ...decidedConfig(), monitor: { ...decidedConfig().monitor, logs: x } }).problems.map((p) => p.path);
  assert.ok(bad({ chunkBlocks: 5000, maxChunksPerCycle: 10, behindWarnBlocks: 600, behindCritBlocks: 3900 }).includes("monitor.logs.chunkBlocks"));
  assert.ok(bad({ chunkBlocks: 2048, maxChunksPerCycle: 0, behindWarnBlocks: 600, behindCritBlocks: 3900 }).includes("monitor.logs.maxChunksPerCycle"));
  assert.ok(bad({ chunkBlocks: 2048, maxChunksPerCycle: 10, behindWarnBlocks: 4000, behindCritBlocks: 3900 }).includes("monitor.logs.behindWarnBlocks"));
});

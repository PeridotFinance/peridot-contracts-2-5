// OFFLINE tests of the WRAPPER HOLDER split of tools/dlmm-rewards-root.mjs (--wrappers): the vault shares held by a lending market's pToken are split among the market's suppliers by
// pToken balance, time-weighted; the permanent seed (pTokens at 0x...dEaD) is excluded; rounding, the no-supplier time and the pToken's own row return to the Safe.
// Synthetic Transfer histories only (no network, no endpoint). The generic generator tests stay in dlmm-rewards-root.test.mjs (they must stay byte-identical: golden files).
//   run from contracts/vault-dlmm:   node --test tools/rewards-test/dlmm-rewards-wrapper.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync, mkdtempSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as R from '../dlmm-rewards-root.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const TOOL = join(HERE, '../dlmm-rewards-root.mjs');
const FIX_DIR = join(HERE, '../../test/rewards/fixtures');
const eu = R.ethers.utils;

// ------------------------------------------------------------------------------------------------------------------------------ the synthetic chain
const A = (hex) => eu.getAddress(`0x${hex.padStart(40, '0')}`);
const LEDGER = A('064efe76812f5f18bd1aa9708739fb33c810b2dd');
const ALICE = A('a11ce'), BOB = A('b0b'), CAROL = A('ca401'), DAVE = A('da0e'), ERIN = A('e41'), X = A('ac1'), SX = A('5a1'), SY = A('5a2'), SZ = A('5a3');
const ROUTER = A('c0de01'); // a contract that supplies to the market: excluded like any contract holder
const PT = A('b9ffa0'), PT2 = A('b9ffa1'); // two wrapper holders (pTokens whose underlying is the vault share)
const VAULT = eu.getAddress(R.VAULT);
const T_BASE = 1_800_000_000, B_BASE = 1000, INTERVAL = 2;
const tsOfBlock = (b) => T_BASE + (b - B_BASE) * INTERVAL;
const pad = (a) => eu.hexZeroPad(a, 32);
const E18 = 10n ** 18n;
const xfer = (b, i, from, to, value) => ({ blockNumber: b, logIndex: i, transactionHash: eu.id(`tx-${b}-${i}`), topics: [R.TRANSFER_TOPIC, pad(from), pad(to)], data: eu.hexZeroPad(eu.hexlify(value), 32) });
const harvest = (b, i, amount) => ({ blockNumber: b, logIndex: i, transactionHash: eu.id(`h-${b}-${i}`), topics: [R.HARVEST_TOPIC, pad(R.PHAR)], data: eu.defaultAbiCoder.encode(['uint256', 'uint256', 'uint256'], [amount, 1, 1]) });
class Chain {
  constructor() { this.logs = []; }
  v(b, i, from, to, value) { this.logs.push(xfer(b, i, from, to, value)); return this; }              // a vault share Transfer
  p(pt, b, i, from, to, value) { this.logs.push({ ...xfer(b, i, from, to, value), address: pt }); return this; } // a pToken Transfer
  h(b, i, amount) { this.logs.push(harvest(b, i, amount)); return this; }
  fixture(extra = {}) {
    return { head: 3500, timeModel: { block: B_BASE, ts: T_BASE, interval: INTERVAL }, code: { [ROUTER]: '0x6080604052', [PT]: '0x6080', [PT2]: '0x6080' },
      underlying: { [PT]: VAULT, [PT2]: VAULT }, logs: this.logs, ...extra };
  }
}
const ARGS = (over = {}) => ({ epochId: 2, userBps: 9000, vault: R.VAULT, scanFrom: 1000, firstEpoch: true, startBlock: 2000, toHarvest: '1', allowContract: [], exclude: [], extraPhar: 0n, minAmount: 1n, chunk: 100, sleepMs: 0, uri: '', ...over });
const W = (pt = PT, over = {}) => ({ pToken: pt, underlying: R.VAULT, fromBlock: 1000, label: pt === PT ? 'bpPHAR-USDC' : 'second', ...over });
const noSleep = async () => {};
const run = (fx, over = {}, srcOpts = {}) => R.generate({ source: new R.FixtureSource(fx, srcOpts), cacheFile: null, args: ARGS(over), sleep: noSleep, git: { commit: 'test', dirty: false } });
const row = (epoch, a) => epoch.holders.find((h) => h.address === a);
const wrapperOf = (epoch, pt) => epoch.wrappers.find((w) => w.pToken === pt);

// ------------------------------------------------------------------------------------------------------------------------------ small histories with hand-computed numbers
/** X holds 4,000,000 shares and puts them all into the market: SX gets 3,000 pTokens, SY 1,000. Constant for the whole epoch (2000 s): V*dt = 8e9 share-seconds. */
function evenChain(withHarvest = true) {
  const c = new Chain().v(1000, 0, R.ZERO, X, 4_000_000).v(1001, 0, X, PT, 4_000_000).p(PT, 1001, 1, PT, SX, 3_000).p(PT, 1001, 2, PT, SY, 1_000);
  if (withHarvest) c.h(3000, 0, 1000n * E18);
  return c;
}
/** 1,000,000 shares, three suppliers with one pToken each: V*dt = 2e9 does not divide by 3. */
function unevenChain() {
  return new Chain().v(1000, 0, R.ZERO, X, 1_000_000).v(1001, 0, X, PT, 1_000_000).p(PT, 1001, 1, PT, SX, 1).p(PT, 1001, 2, PT, SY, 1).p(PT, 1001, 3, PT, SZ, 1).h(3000, 0, 1000n * E18);
}

test('hand-computed, divides evenly: 3/4 and 1/4 of V*dt = 8e9 share-seconds; the pToken row keeps nothing; amounts are floor(pool * weight / total)', async () => {
  const { epoch } = await run(evenChain().fixture(), { wrappers: [W()] });
  assert.equal(row(epoch, SX).weight, '6000000000');
  assert.equal(row(epoch, SY).weight, '2000000000');
  assert.equal(epoch.totals.totalWeight, '8000000000');
  assert.equal(row(epoch, PT), undefined, 'no residual: the pToken has no row at all');
  const w = wrapperOf(epoch, PT);
  assert.deepEqual([w.vaultShareSeconds, w.suppliersWeight, w.roundingWeight, w.noSupplierWeight, w.returnedToSafeWeight], ['8000000000', '8000000000', '0', '0', '0']);
  assert.equal(row(epoch, SX).amount, (675n * E18).toString());
  assert.equal(row(epoch, SY).amount, (225n * E18).toString());
  assert.equal(epoch.totals.publishTotal, (900n * E18).toString());
  assert.equal(row(epoch, SX).status, 'paid');
  assert.ok(epoch.leaves.some((l) => l.account === SX) && epoch.leaves.some((l) => l.account === SY));
  assert.ok(!epoch.leaves.some((l) => l.account === PT));
  assert.equal(epoch.checks.wrapperSplitSumsToPTokenHolding, true);
  assert.equal(epoch.checks.seedExcluded, true);
  assert.equal(epoch.generator.version, '2.1.0');
  assert.deepEqual(epoch.inputs.wrappers, [{ pToken: PT, underlying: VAULT, fromBlock: 1000, label: 'bpPHAR-USDC' }]);
  // the same history WITHOUT the wrapper config: the pToken is a contract holder, holds every share and nobody is paid (the problem this feature solves)
  await assert.rejects(run(evenChain().fixture(), {}), /no holder earned anything/);
});

test('hand-computed, does not divide: 3 suppliers of 1 pToken each get floor(2e9 / 3) = 666,666,666, the 2 left over stay on the pToken row and return to the Safe', async () => {
  const { epoch } = await run(unevenChain().fixture(), { wrappers: [W()] });
  for (const s of [SX, SY, SZ]) assert.equal(row(epoch, s).weight, '666666666');
  const w = wrapperOf(epoch, PT);
  assert.equal(w.roundingWeight, '2'); assert.equal(w.noSupplierWeight, '0'); assert.equal(w.returnedToSafeWeight, '2');
  assert.equal(row(epoch, PT).weight, '2');
  assert.equal(row(epoch, PT).status, 'excluded'); assert.equal(row(epoch, PT).excludedReason, 'wrapper-residual');
  assert.equal(epoch.totals.totalWeight, '2000000000', 'the denominator is the supply integral, unchanged');
  const pool = 900n * E18;
  assert.equal(row(epoch, SX).amount, ((pool * 666666666n) / 2000000000n).toString());
  assert.equal(row(epoch, PT).unpaidSlice, ((pool * 2n) / 2000000000n).toString());
  assert.ok(Object.values(epoch.checks).every((v) => v === true));
  assert.equal(epoch.exclusions.list.find((e) => e.address === PT).reason, 'wrapper-residual');
});

// ------------------------------------------------------------------------------------------------------------------------------ the rich history
/**
 * One market (PT; with two:true a second one, PT2) with mint, partial redeem, a transfer between suppliers, a liquidation seize, the permanent seed, a donation, a contract supplier,
 * a mint+redeem inside one block (a no-op), a supplier that also holds shares directly and (two) a supplier of both markets. pTokens are 50 per share when minted.
 * epoch = (2000, 3000] = 2000 s.   V (shares in PT): 21M at the start; 31M at 2200; 32M at 2300; 24M at 2400; 26M at 2800 (donation).
 * pTokens (p): start ALICE 1000M, DEAD 50M;  2200 BOB +500M;  2300 ROUTER +50M;  2400 ALICE -400M;  2600 ALICE -100M, CAROL +100M;  2900 BOB -41M (ERIN +40M, 1M burnt to the pToken = reserves).
 */
function richChain({ two = false, noop = true } = {}) {
  const c = new Chain();
  c.v(1000, 0, R.ZERO, R.DEAD, 1_000_000)                  // the vault's dead seed
    .v(1001, 0, R.ZERO, LEDGER, 100_000_000)
    .v(1100, 0, LEDGER, ALICE, two ? 28_000_000 : 23_000_000) // 20M go into the market, 3M stay direct (ALICE is a direct holder AND a supplier)
    .v(1100, 1, LEDGER, BOB, 10_000_000).v(1100, 2, LEDGER, DAVE, 3_000_000).v(1100, 3, LEDGER, ROUTER, 1_000_000);
  if (two) c.v(1100, 4, LEDGER, CAROL, 2_000_000);
  c.v(1500, 0, ALICE, PT, 20_000_000).p(PT, 1500, 1, PT, ALICE, 1_000_000_000)          // a supply (mint: Transfer from the pToken)
    .v(1501, 0, LEDGER, PT, 1_000_000).p(PT, 1501, 1, PT, LEDGER, 50_000_000).p(PT, 1501, 2, LEDGER, R.DEAD, 50_000_000) // the permanent seed: minted, then sent to the dead address
    .h(1999, 0, 5n * E18);
  if (two) {
    c.v(1700, 0, CAROL, PT2, 2_000_000).p(PT2, 1700, 1, PT2, CAROL, 20_000_000)
      .v(1701, 0, LEDGER, PT2, 1_000_000).p(PT2, 1701, 1, PT2, LEDGER, 10_000_000).p(PT2, 1701, 2, LEDGER, R.DEAD, 10_000_000);
  }
  c.v(2200, 0, BOB, PT, 10_000_000).p(PT, 2200, 1, PT, BOB, 500_000_000)
    .v(2300, 0, ROUTER, PT, 1_000_000).p(PT, 2300, 1, PT, ROUTER, 50_000_000)
    .v(2400, 0, PT, ALICE, 8_000_000).p(PT, 2400, 1, ALICE, PT, 400_000_000)                // a partial redeem: Transfer to the pToken
    .p(PT, 2600, 0, ALICE, CAROL, 100_000_000);                                             // a transfer between suppliers (no vault share moves)
  if (two) c.v(2100, 0, ALICE, PT2, 5_000_000).p(PT2, 2100, 1, PT2, ALICE, 50_000_000);
  if (noop) c.v(2700, 0, DAVE, PT, 1_000_000).p(PT, 2700, 1, PT, DAVE, 50_000_000).v(2700, 2, PT, DAVE, 1_000_000).p(PT, 2700, 3, DAVE, PT, 50_000_000); // mint + redeem in ONE block
  c.v(2800, 0, DAVE, PT, 2_000_000)                                                          // a donation: shares to the pToken, no pToken event
    .p(PT, 2900, 0, BOB, ERIN, 40_000_000).p(PT, 2900, 1, BOB, PT, 1_000_000);              // a liquidation seize: to the liquidator, and the protocol part burnt to the pToken
  if (two) c.p(PT, 2950, 0, CAROL, PT2, 10_000_000);                                        // pTokens of market 1 sent to the contract address of market 2 (a mistake)
  c.h(3000, 9, 1000n * E18)
    .p(PT, 3001, 0, CAROL, ALICE, 1);                                                       // after the epoch: ignored
  return c;
}
const richFx = (o) => richChain(o).fixture();

/** An independent oracle, second by second, EXACT rational (BigInt over a common denominator): the weight of every supplier of `pt` and the integral of V. */
function exactOracle(fx, pt, { startBlock = 2000, endBlock = 3000 } = {}) {
  const evs = fx.logs.filter((l) => l.topics[0] === R.TRANSFER_TOPIC && l.blockNumber <= endBlock && ((!l.address && (eu.hexDataSlice(l.topics[1], 12).toLowerCase() === pt.toLowerCase() || eu.hexDataSlice(l.topics[2], 12).toLowerCase() === pt.toLowerCase())) || (l.address === pt)))
    .sort((a, b) => a.blockNumber - b.blockNumber || a.logIndex - b.logIndex)
    .map((l) => ({ ts: tsOfBlock(l.blockNumber), vault: !l.address, from: eu.getAddress(eu.hexDataSlice(l.topics[1], 12)), to: eu.getAddress(eu.hexDataSlice(l.topics[2], 12)), v: BigInt(l.data) }));
  const t0 = tsOfBlock(startBlock), t1 = tsOfBlock(endBlock);
  const bal = new Map(); let V = 0n; let i = 0;
  const seconds = [];
  for (let s = t0; s < t1; s++) {
    while (i < evs.length && evs[i].ts <= s) {
      const e = evs[i++];
      if (e.vault) { if (e.from === pt) V -= e.v; if (e.to === pt) V += e.v; }
      else {
        if (e.from !== pt && e.from !== R.ZERO) bal.set(e.from, (bal.get(e.from) ?? 0n) - e.v);
        if (e.to !== pt && e.to !== R.ZERO) bal.set(e.to, (bal.get(e.to) ?? 0n) + e.v);
      }
    }
    let P = 0n; for (const b of bal.values()) P += b;
    seconds.push({ V, P, bal: new Map(bal) });
  }
  const gcd = (a, b) => (b === 0n ? a : gcd(b, a % b));
  let D = 1n; for (const s of seconds) if (s.P > 0n) D = (D * s.P) / gcd(D, s.P);
  const num = new Map(); let noSup = 0n; let vSeconds = 0n;
  for (const s of seconds) {
    vSeconds += s.V;
    if (s.V === 0n) continue;
    if (s.P === 0n) { noSup += s.V; continue; }
    for (const [a, b] of s.bal) if (b > 0n) num.set(a, (num.get(a) ?? 0n) + s.V * b * (D / s.P));
  }
  return { D, num, noSup, vSeconds };
}
/** impl <= exact < impl + segments for every supplier; the exact slices plus the no-supplier time add up to the integral of V. */
function assertAgainstOracle(epoch, fx, pt) {
  const o = exactOracle(fx, pt);
  const w = wrapperOf(epoch, pt);
  assert.equal(w.vaultShareSeconds, o.vSeconds.toString(), 'the integral of the shares held by the pToken');
  assert.equal(w.noSupplierWeight, o.noSup.toString());
  let sumExact = 0n;
  for (const s of w.suppliers) {
    const exactNum = o.num.get(s.address) ?? 0n; sumExact += exactNum;
    const impl = BigInt(s.weight);
    assert.ok(impl * o.D <= exactNum, `${s.address}: the generator never rounds up`);
    assert.ok(exactNum < (impl + BigInt(w.segments)) * o.D, `${s.address}: at most one share-second lost per segment (${w.segments})`);
  }
  for (const a of o.num.keys()) assert.ok(w.suppliers.some((s) => s.address === a), `${a} missing from the report`);
  assert.equal(sumExact + o.noSup * o.D <= o.vSeconds * o.D, true);
  assert.ok(o.vSeconds * o.D - sumExact - o.noSup * o.D < BigInt(w.segments) * BigInt(w.suppliers.length) * o.D);
}

test('rich history vs the exact second-by-second oracle: mint, partial redeem, transfer between suppliers, seize, seed to dead, donation, contract supplier', async () => {
  const fx = richFx();
  const { epoch } = await run(fx, { wrappers: [W(PT, { fromBlock: 1500 })] });
  assertAgainstOracle(epoch, fx, PT);
  const w = wrapperOf(epoch, PT);
  assert.equal(w.openingVaultShares, '21000000'); assert.equal(w.closingVaultShares, '26000000');
  assert.equal(w.openingPTokenSupply, '1050000000'); assert.equal(w.closingPTokenSupply, '1199000000', '1200M after 2400, minus the 1M burnt to the pToken in the seize');
  const sup = Object.fromEntries(w.suppliers.map((s) => [s.address, s]));
  assert.deepEqual([sup[ALICE].openingPTokens, sup[ALICE].closingPTokens], ['1000000000', '500000000'], 'ALICE: partial redeem then a transfer out');
  assert.deepEqual([sup[BOB].openingPTokens, sup[BOB].closingPTokens], ['0', '459000000'], 'BOB: minted, then seized (40M to the liquidator, 1M reserves)');
  assert.deepEqual([sup[CAROL].openingPTokens, sup[CAROL].closingPTokens], ['0', '100000000'], 'CAROL: received a transfer');
  assert.deepEqual([sup[ERIN].openingPTokens, sup[ERIN].closingPTokens], ['0', '40000000'], 'ERIN: the liquidator');
  assert.deepEqual([w.deadSeed.openingPTokens, w.deadSeed.closingPTokens], ['50000000', '50000000']);
  assert.equal(sup[DAVE], undefined, 'DAVE: the mint and the redeem inside one block left no pToken balance and gave no weight');
  assert.equal(sup[LEDGER], undefined, 'the seeder holds no pTokens any more');
  // the exact segments: hand-computed weight of the dead seed (50M pTokens, V and P as listed above)
  const seg = [[2000, 2200, 21_000_000n, 1_050_000_000n], [2200, 2300, 31_000_000n, 1_550_000_000n], [2300, 2400, 32_000_000n, 1_600_000_000n], [2400, 2600, 24_000_000n, 1_200_000_000n], [2600, 2800, 24_000_000n, 1_200_000_000n], [2800, 2900, 26_000_000n, 1_200_000_000n], [2900, 3000, 26_000_000n, 1_199_000_000n]];
  let deadW = 0n; for (const [b0, b1, V, P] of seg) deadW += (V * BigInt((b1 - b0) * INTERVAL) * 50_000_000n) / P;
  assert.equal(w.deadSeed.weight, deadW.toString(), 'hand-computed: the sum over the seven segments of floor(V * dt * 50M / P)');
  assert.equal(w.segments, 7, 'seven segments: 2200, 2300, 2400, 2600 (a pToken transfer), 2800 (the donation), 2900 are boundaries; 2700 (mint+redeem in one block) is not');
  // the dead seed is one row: the vault's own dead seed (1M shares) PLUS the wrapper's slice; excluded as dead-seed; no leaf
  const d = row(epoch, R.DEAD);
  assert.equal(d.excludedReason, 'dead-seed'); assert.equal(d.wrapperWeight, w.deadSeed.weight);
  assert.equal(BigInt(d.weight), BigInt(d.directWeight) + BigInt(w.deadSeed.weight)); assert.equal(d.directWeight, String(1_000_000 * 2000));
  assert.ok(!epoch.leaves.some((l) => l.account === R.DEAD));
  assert.equal(epoch.checks.seedExcluded, true);
  // the contract supplier is excluded like any contract holder; its slice returns to the Safe
  assert.equal(row(epoch, ROUTER).excludedReason, 'contract'); assert.ok(BigInt(row(epoch, ROUTER).weight) > 0n);
  assert.ok(!epoch.leaves.some((l) => l.account === ROUTER));
  // ALICE is a direct holder (3M shares) and a supplier: both parts are summed into one row and one leaf
  const al = row(epoch, ALICE);
  assert.equal(al.directWeight, String(3_000_000 * 2000 + 8_000_000 * 1200), 'ALICE direct: 3M for the whole epoch, plus the 8M shares she redeemed from the market at 2400 (1200 s)'); assert.equal(al.wrapperWeight, sup[ALICE].weight);
  assert.equal(BigInt(al.weight), BigInt(al.directWeight) + BigInt(al.wrapperWeight));
  assert.equal(epoch.leaves.filter((l) => l.account === ALICE).length, 1);
  // the pToken: its own row holds only the residual, is excluded as wrapper-residual and has no leaf
  const pr = row(epoch, PT);
  assert.equal(pr.status, 'excluded'); assert.equal(pr.excludedReason, 'wrapper-residual'); assert.equal(pr.weight, w.returnedToSafeWeight); assert.equal(pr.directWeight, '0');
  assert.ok(!epoch.leaves.some((l) => l.account === PT));
  // closing/opening direct shares of a supplier are the direct vault holding only
  assert.equal(al.closingShares, String(3_000_000 + 8_000_000), 'ALICE: 3M direct + 8M redeemed from the market');
  // every global check, the partition and the proofs
  assert.ok(Object.values(epoch.checks).every((v) => v === true));
  for (const c of epoch.leaves) assert.ok(R.verifyProof(c.proof, epoch.root, c.leaf));
  assert.equal(R.verifyProof(epoch.leaves[0].proof, epoch.root, R.leafHash(2, PT, '1')), false);
});

test('other holders do not move: the denominator, the pool and every non-supplier amount equal the run WITHOUT --wrappers; only the pToken\'s slice is redistributed', async () => {
  const fx = richFx();
  const a = (await run(fx, {})).epoch;
  const b = (await run(fx, { wrappers: [W(PT, { fromBlock: 1500 })] })).epoch;
  assert.equal(b.totals.totalWeight, a.totals.totalWeight);
  assert.equal(b.totals.pool, a.totals.pool);
  const suppliers = new Set(wrapperOf(b, PT).suppliers.map((s) => s.address));
  for (const h of a.holders) {
    if (h.address === PT || suppliers.has(h.address)) continue;
    const bh = row(b, h.address);
    assert.equal(bh.weight, h.weight, h.address); assert.equal(bh.amount, h.amount, h.address); assert.equal(bh.status, h.status, h.address);
  }
  assert.equal(row(a, PT).excludedReason, 'contract');
  assert.equal(BigInt(row(a, PT).weight), BigInt(wrapperOf(b, PT).vaultShareSeconds), 'what was one contract row is now the suppliers + the residual');
  assert.ok(BigInt(b.totals.publishTotal) > BigInt(a.totals.publishTotal), 'suppliers are paid now');
  // pToken slices that go to the Safe: dead seed, contract supplier, residual
  const stay = BigInt(b.totals.stayWithSafe.excludedHoldersSlice);
  assert.ok(stay > BigInt(a.totals.stayWithSafe.excludedHoldersSlice) - BigInt(row(a, PT).unpaidSlice), 'the seed and the contract supplier are still returned');
  // sum of paid amounts of the wrapper's suppliers <= the pToken's slice of the pool in the run without wrappers
  let paid = 0n; for (const s of suppliers) paid += BigInt(row(b, s).amount) - BigInt(row(a, s)?.amount ?? 0n);
  assert.ok(paid <= BigInt(row(a, PT).unpaidSlice));
});

test('a mint and a redeem inside ONE block (no net change) are no segment boundary: the result equals the history without them', async () => {
  const withNoop = (await run(richFx({ noop: true }), { wrappers: [W(PT, { fromBlock: 1500 })] })).epoch;
  const without = (await run(richFx({ noop: false }), { wrappers: [W(PT, { fromBlock: 1500 })] })).epoch;
  // DAVE's own direct weight is the same too (his 1M shares are in the pToken only between two logs of one block)
  assert.deepEqual(wrapperOf(withNoop, PT), wrapperOf(without, PT));
  assert.equal(withNoop.root, without.root);
});

test('two wrapper holders: each splits its own shares by its own pTokens; a supplier of both is summed; a market\'s pTokens sent to the other market\'s address end in an excluded row', async () => {
  const fx = richFx({ two: true });
  const wr = [W(PT, { fromBlock: 1500 }), W(PT2, { fromBlock: 1700 })];
  const { epoch } = await run(fx, { wrappers: wr });
  assertAgainstOracle(epoch, fx, PT); assertAgainstOracle(epoch, fx, PT2);
  const w1 = wrapperOf(epoch, PT), w2 = wrapperOf(epoch, PT2);
  assert.deepEqual(epoch.wrappers.map((w) => w.pToken), [PT, PT2].sort((x, y) => (x.toLowerCase() < y.toLowerCase() ? -1 : 1)), 'sorted by pToken address');
  assert.equal(w2.openingVaultShares, '3000000'); assert.equal(w2.closingVaultShares, '8000000'); // CAROL 2M + seed 1M, then ALICE +5M
  for (const w of [w1, w2]) assert.equal(BigInt(w.suppliersWeight) + BigInt(w.returnedToSafeWeight), BigInt(w.vaultShareSeconds));
  // ALICE and CAROL are suppliers of both; their wrapper weight is the sum of both slices
  for (const s of [ALICE, CAROL]) {
    const a = BigInt(w1.suppliers.find((x) => x.address === s)?.weight ?? 0) + BigInt(w2.suppliers.find((x) => x.address === s)?.weight ?? 0);
    assert.equal(row(epoch, s).wrapperWeight, a.toString());
    assert.ok(BigInt(w2.suppliers.find((x) => x.address === s).weight) > 0n && BigInt(w1.suppliers.find((x) => x.address === s).weight) > 0n);
  }
  // PT2 received market-1 pTokens (a slice of market 1) AND is the second wrapper: ONE row, excluded as wrapper-residual, no leaf
  const p2 = row(epoch, PT2);
  assert.equal(p2.excludedReason, 'wrapper-residual');
  assert.ok(BigInt(p2.wrapperWeight) > 0n, 'the slice it got as a "supplier" of market 1');
  assert.equal(BigInt(p2.weight), BigInt(p2.wrapperWeight) + BigInt(w2.returnedToSafeWeight));
  assert.ok(!epoch.leaves.some((l) => l.account === PT2 || l.account === PT));
  assert.ok(Object.values(epoch.checks).every((v) => v === true));
  assert.equal(epoch.totals.totalWeight, (await run(fx, {})).epoch.totals.totalWeight);
  assert.equal(epoch.inputs.wrappers.length, 2);
});

test('shares in the pToken but nobody holds pTokens (a donation before the first supply): that time is returned to the Safe, not paid to anyone', async () => {
  const c = new Chain().v(1000, 0, R.ZERO, X, 1_000_000).v(1001, 0, X, PT, 400_000)                 // donated: V = 400k, P = 0
    .v(2500, 0, X, PT, 600_000).p(PT, 2500, 1, PT, SX, 1_000)                                        // the first supply, half-way through the epoch
    .h(3000, 0, 1000n * E18);
  const fx = c.fixture();
  const { epoch } = await run(fx, { wrappers: [W()] });
  const w = wrapperOf(epoch, PT);
  assert.equal(w.noSupplierWeight, String(400_000 * 1000), '400k shares for the first 1000 s');
  assert.equal(row(epoch, SX).weight, String(1_000_000 * 1000), 'SX owns everything after the first supply, including the donated shares');
  assert.equal(w.returnedToSafeWeight, w.noSupplierWeight);
  assert.equal(row(epoch, PT).excludedReason, 'wrapper-residual');
  assertAgainstOracle(epoch, fx, PT);
  // a full exit leaves donated dust: the same rule
  const c2 = new Chain().v(1000, 0, R.ZERO, X, 1_000_000).v(1001, 0, X, PT, 1_000_000).p(PT, 1001, 1, PT, SX, 1_000)
    .p(PT, 2500, 0, SX, PT, 1_000).v(2500, 1, PT, X, 900_000).h(3000, 0, 1000n * E18);                  // everything redeemed, 100k shares of "dust" stay in the pToken
  const r2 = (await run(c2.fixture(), { wrappers: [W()] })).epoch;
  assert.equal(wrapperOf(r2, PT).noSupplierWeight, String(100_000 * 1000));
  assert.equal(row(r2, SX).weight, String(1_000_000 * 1000), 'SX: 1M shares for the first 1000 s; after the exit the 100k dust has no owner');
});

test('window edges: an event AT the start block is part of the opening state; an event at the end block has zero duration and earns nothing', async () => {
  const c = new Chain().v(1000, 0, R.ZERO, X, 3_000_000)
    .v(2000, 0, X, PT, 2_000_000).p(PT, 2000, 1, PT, SX, 1_000)      // exactly at the start block: opening state, SX earns for the whole epoch
    .v(3000, 0, X, PT, 1_000_000).p(PT, 3000, 1, PT, SY, 1_000)      // exactly at the end block: zero seconds
    .h(3000, 5, 1000n * E18);
  const fx = c.fixture();
  const { epoch } = await run(fx, { wrappers: [W()] });
  const w = wrapperOf(epoch, PT);
  assert.equal(w.openingVaultShares, '2000000'); assert.equal(w.closingVaultShares, '3000000');
  assert.equal(w.openingPTokenSupply, '1000'); assert.equal(w.closingPTokenSupply, '2000');
  assert.equal(row(epoch, SX).weight, String(2_000_000 * 2000));
  assert.equal(row(epoch, SY), undefined, 'SY supplied at the end block: no weight, no row');
  assert.equal(w.segments, 1);
  assertAgainstOracle(epoch, fx, PT);
});

test('a supplier on --exclude is excluded (its slice stays in the denominator); --allow-contract lets a contract supplier claim; a wrapper itself can not be allowed or excluded', async () => {
  const fx = richFx();
  const base = (await run(fx, { wrappers: [W(PT, { fromBlock: 1500 })] })).epoch;
  const ex = (await run(fx, { wrappers: [W(PT, { fromBlock: 1500 })], exclude: [CAROL] })).epoch;
  assert.equal(row(ex, CAROL).excludedReason, 'explicit'); assert.ok(!ex.leaves.some((l) => l.account === CAROL));
  assert.equal(row(ex, CAROL).weight, row(base, CAROL).weight);
  assert.equal(row(ex, BOB).amount, row(base, BOB).amount, 'nobody else moves');
  const al = (await run(fx, { wrappers: [W(PT, { fromBlock: 1500 })], allowContract: [ROUTER] })).epoch;
  assert.equal(row(al, ROUTER).status, 'paid'); assert.ok(al.leaves.some((l) => l.account === ROUTER));
  await assert.rejects(run(fx, { wrappers: [W(PT)], allowContract: [PT] }), /also on --allow-contract/);
  await assert.rejects(run(fx, { wrappers: [W(PT)], exclude: [PT] }), /also on --exclude/);
});

// ------------------------------------------------------------------------------------------------------------------------------ the config
test('config validation: underlying must be the vault, no zero/dead/vault, no duplicates, known fields only, fromBlock and label sanity; sorted output', () => {
  const ok = R.normalizeWrappers([W(PT2, { label: 'b' }), W(PT, { fromBlock: undefined })], { vault: R.VAULT });
  assert.deepEqual(ok.map((w) => w.pToken), [PT, PT2].sort((x, y) => (x.toLowerCase() < y.toLowerCase() ? -1 : 1)));
  assert.equal(ok.find((w) => w.pToken === PT).fromBlock, null);
  assert.deepEqual(R.normalizeWrappers([]), []);
  assert.throws(() => R.normalizeWrappers([W(PT, { underlying: LEDGER })]), /not the vault/);
  for (const bad of [R.ZERO, R.DEAD, R.VAULT]) assert.throws(() => R.normalizeWrappers([W(PT, { pToken: bad })]), /cannot be wrapper holders/);
  assert.throws(() => R.normalizeWrappers([W(PT), W(PT.toLowerCase())]), /listed twice/);
  assert.throws(() => R.normalizeWrappers([{ ...W(PT), extra: 1 }]), /unknown field extra/);
  assert.throws(() => R.normalizeWrappers([W(PT, { fromBlock: -1 })]), /fromBlock/);
  assert.throws(() => R.normalizeWrappers([W(PT, { fromBlock: 1.5 })]), /fromBlock/);
  assert.throws(() => R.normalizeWrappers([W(PT, { label: 'x'.repeat(65) })]), /label/);
  assert.throws(() => R.normalizeWrappers({}), /array/);
  assert.throws(() => R.normalizeWrappers(['x']), /object/);
  assert.throws(() => R.normalizeWrappers([{ pToken: 'nope', underlying: R.VAULT }]));
  assert.throws(() => R.parseWrappersFile({ schema: 'other', wrappers: [] }), /wrappers file must be/);
  assert.equal(R.parseWrappersFile({ schema: R.WRAPPERS_SCHEMA, wrappers: [W(PT)] }).length, 1);
  assert.equal(R.parseArgs(['--epoch-id', '1', '--scan-from', '10', '--first-epoch', '--to-harvest', '2', '--wrappers', 'w.json']).wrappersFile, 'w.json');
});

test('pToken.underlying() is checked when the source can answer: a pToken of another asset is refused', async () => {
  const fx = evenChain().fixture({ underlying: { [PT]: LEDGER } });
  await assert.rejects(run(fx, { wrappers: [W()] }), /underlying\(\) is/);
});

test('without --wrappers nothing changes: no wrapper fields, generator 2.0.0, the pToken is an ordinary contract holder', async () => {
  const { epoch, manifest } = await run(richFx(), {});
  assert.equal(epoch.generator.version, '2.0.0');
  for (const k of ['wrappers']) assert.ok(!(k in epoch) && !(k in epoch.inputs));
  for (const k of ['wrapperSplitSumsToPTokenHolding', 'seedExcluded']) assert.ok(!(k in epoch.checks));
  assert.ok(!('directWeight' in epoch.holders[0]));
  assert.ok(!('wrappersHash' in manifest));
});

// ------------------------------------------------------------------------------------------------------------------------------ negative balances, determinism, caches, scan windows
test('an incomplete pToken history is detected (negative pToken balance), also when --from-block of the wrapper is too late; a wrapper deployed after the epoch contributes nothing', async () => {
  await assert.rejects(run(richFx(), { wrappers: [W(PT, { fromBlock: 1550 })] }), /negative pToken balance/);
  const c = new Chain().v(1000, 0, R.ZERO, X, 4_000_000).v(1001, 0, X, SX, 1_000_000).h(3000, 0, 1000n * E18);
  const r = await run(c.fixture(), { wrappers: [W(PT, { fromBlock: 3200 })] });
  assert.equal(wrapperOf(r.epoch, PT).vaultShareSeconds, '0');
  assert.equal(row(r.epoch, PT), undefined);
});

test('deterministic: byte-identical for every chunk size, from a fresh cache, from a resumed cache; the wrapper has its own resumable cache file scanned from its fromBlock', async () => {
  const fx = richFx({ two: true });
  const wr = [W(PT, { fromBlock: 1500 }), W(PT2, { fromBlock: 1700 })];
  const base = (await run(fx, { wrappers: wr })).text;
  for (const chunk of [1, 7, 100, 999, 5000]) assert.equal((await run(fx, { wrappers: wr, chunk })).text, base, `chunk ${chunk}`);
  assert.equal((await run(fx, { wrappers: [...wr].reverse() })).text, base, 'the order of the config does not matter');
  const dir = mkdtempSync(join(tmpdir(), 'rewards-wrap-'));
  const file = join(dir, `scan-43114-${R.VAULT.toLowerCase()}.json`);
  const s1 = new R.FixtureSource(fx);
  const r1 = await R.generate({ source: s1, cacheFile: file, args: ARGS({ wrappers: wr }), sleep: noSleep });
  assert.equal(r1.text, base);
  assert.ok(existsSync(join(dir, `scan-43114-${PT.toLowerCase()}.json`)) && existsSync(join(dir, `scan-43114-${PT2.toLowerCase()}.json`)));
  assert.equal(s1.addressCalls.filter(([a]) => a === PT.toLowerCase())[0][1], 1500, 'scanned from the wrapper\'s own fromBlock');
  assert.equal(s1.addressCalls.filter(([a]) => a === PT2.toLowerCase())[0][1], 1700);
  const s2 = new R.FixtureSource(fx);
  const r2 = await R.generate({ source: s2, cacheFile: file, args: ARGS({ wrappers: wr }), sleep: noSleep });
  assert.equal(r2.text, base);
  assert.equal(s2.calls.length, 0, 'no vault log call on a resumed run'); assert.equal(s2.addressCalls?.length ?? 0, 0, 'no pToken log call on a resumed run');
  assert.equal(s2.tsCalls, 0, 'timestamps cached');
  // a transient failure of the pToken log calls is retried
  const s3 = new R.FixtureSource(fx, { failFirst: 0 }); const orig = s3.getAddressLogs.bind(s3); let fails = 0;
  s3.getAddressLogs = async (r) => { if (fails++ < 3) throw new Error('hiccup'); return orig(r); };
  assert.equal((await run(fx, { wrappers: wr }, {})).text, base);
  const r3 = await R.generate({ source: s3, cacheFile: null, args: ARGS({ wrappers: wr }), sleep: noSleep });
  assert.equal(r3.text, base);
});

test('manifest: wrappersHash and wrapperCount; the wrappers are part of dataHash (another wrapper list gives another hash)', async () => {
  const a = await run(evenChain().fixture(), { wrappers: [W()] });
  assert.equal(a.manifest.wrapperCount, 1);
  assert.equal(a.manifest.wrappersHash, eu.keccak256(eu.toUtf8Bytes(JSON.stringify(a.epoch.inputs.wrappers))));
  assert.equal(a.manifest.dataHash, eu.keccak256(eu.toUtf8Bytes(a.text)));
  const b = await run(evenChain().fixture(), { wrappers: [W(PT, { label: 'other' })] });
  assert.notEqual(a.manifest.dataHash, b.manifest.dataHash);
});

test('the claim side: leaves of the suppliers verify against the root with the contract\'s leaf format (epoch id bound); amounts are the floor of pool * weight / total', async () => {
  const { epoch } = await run(richFx(), { wrappers: [W(PT, { fromBlock: 1500 })] });
  const pool = BigInt(epoch.totals.pool); const W0 = BigInt(epoch.totals.totalWeight);
  for (const l of epoch.leaves) {
    const h = row(epoch, l.account);
    assert.equal(l.amount, ((pool * BigInt(h.weight)) / W0).toString());
    assert.equal(l.leaf, eu.keccak256(eu.keccak256(eu.defaultAbiCoder.encode(['uint256', 'address', 'uint256'], [2, l.account, l.amount]))));
  }
  for (const s of [ALICE, BOB, CAROL, ERIN]) assert.ok(epoch.leaves.some((l) => l.account === s), `${s} has a leaf`);
});

// ------------------------------------------------------------------------------------------------------------------------------ the live network path (a fake JSON-RPC node), --wrappers on the CLI
async function fakeNode(fx) {
  const seen = { logAddresses: [], calls: [] };
  const hex = (n) => `0x${BigInt(n).toString(16)}`;
  const handle = (method, params) => {
    switch (method) {
      case 'anvil_nodeInfo': return { currentBlockNumber: hex(fx.head) };
      case 'eth_chainId': return hex(43114);
      case 'eth_blockNumber': return hex(fx.head);
      case 'eth_getLogs': {
        const f = params[0]; const from = Number(f.fromBlock); const to = Number(f.toBlock);
        if (to - from + 1 > 100) throw Object.assign(new Error('query returned more than the allowed range'), { code: -32005 });
        const a = f.address.toLowerCase(); seen.logAddresses.push([a, from]);
        const mine = fx.logs.filter((l) => (l.address ? l.address.toLowerCase() === a : a === R.VAULT.toLowerCase()) && l.blockNumber >= from && l.blockNumber <= to);
        const topics = f.topics[0]; const allowed = Array.isArray(topics) ? topics : [topics];
        return mine.filter((l) => allowed.includes(l.topics[0])).map((l) => ({ address: a, blockNumber: hex(l.blockNumber), blockHash: eu.id(`block-${l.blockNumber}`), transactionIndex: '0x0', logIndex: hex(l.logIndex), transactionHash: l.transactionHash, topics: l.topics, data: l.data, removed: false }));
      }
      case 'eth_getBlockByNumber': {
        const b = Number(params[0]); const z = '0x' + '00'.repeat(32);
        return { number: hex(b), hash: eu.id(`block-${b}`), parentHash: z, nonce: '0x0000000000000000', sha3Uncles: z, logsBloom: '0x' + '00'.repeat(256), transactionsRoot: z, stateRoot: z, receiptsRoot: z, miner: R.ZERO, difficulty: '0x1', totalDifficulty: '0x1', extraData: '0x', size: '0x1', gasLimit: '0xe4e1c0', gasUsed: '0x0', timestamp: hex(tsOfBlock(b)), transactions: [], uncles: [] };
      }
      case 'eth_getCode': return fx.code?.[eu.getAddress(params[0])] ?? '0x';
      case 'eth_call': {
        const c = params[0]; seen.calls.push([c.to.toLowerCase(), c.data, params[1]]);
        if (c.data !== R.UNDERLYING_SELECTOR) throw new Error('unexpected call');
        { const u = fx.underlying[eu.getAddress(c.to)]; return u === undefined ? '0x' : eu.hexZeroPad(u, 32); } // no data = no contract / no such function
      }
      default: throw Object.assign(new Error(`method ${method} not supported by the fake node`), { code: -32601 });
    }
  };
  const server = http.createServer((req, res) => {
    const chunks = []; req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const one = (r) => { try { return { jsonrpc: '2.0', id: r.id, result: handle(r.method, r.params ?? []) }; } catch (e) { return { jsonrpc: '2.0', id: r.id, error: { code: e.code ?? -32000, message: e.message } }; } };
      const body = JSON.parse(Buffer.concat(chunks).toString());
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(Array.isArray(body) ? body.map(one) : one(body)));
    });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return { url: `http://127.0.0.1:${server.address().port}`, seen, close: () => server.close() };
}
const cli = (args) => new Promise((resolve) => {
  const c = spawn(process.execPath, [TOOL, ...args], { env: { PATH: process.env.PATH, ETHERS_DIR: process.env.ETHERS_DIR ?? '' } });
  let out = ''; let err = ''; c.stdout.on('data', (d) => (out += d)); c.stderr.on('data', (d) => (err += d));
  c.on('close', (code) => resolve({ code, out, err }));
});

test('the live RpcSource path with --wrappers (a fake node): pToken logs by address, underlying() through eth_call, per-pToken cache; the epoch.json equals the fixture path byte for byte; nothing leaks the endpoint', async () => {
  const fx = richFx({ two: true });
  const wr = [W(PT, { fromBlock: 1500 }), W(PT2, { fromBlock: 1700 })];
  const expected = (await run(fx, { wrappers: wr })).text;
  const node = await fakeNode(fx);
  try {
    const d = mkdtempSync(join(tmpdir(), 'rewards-wrap-rpc-')); const wf = join(d, 'wrappers.json'); const out = join(d, 'out'); const cache = join(d, 'cache');
    writeFileSync(wf, JSON.stringify({ schema: R.WRAPPERS_SCHEMA, wrappers: wr }));
    const r = await cli(['--local-rpc', node.url, '--cache-dir', cache, '--out-dir', out, '--epoch-id', '2', '--scan-from', '1000', '--first-epoch', '--start-block', '2000', '--to-harvest', '1', '--wrappers', wf]);
    assert.equal(r.code, 0, r.err);
    assert.equal(readFileSync(join(out, 'epoch.json'), 'utf8'), expected);
    assert.ok(!(r.out + r.err).includes('127.0.0.1'));
    const m = JSON.parse(readFileSync(join(out, 'manifest.json'), 'utf8'));
    assert.equal(m.rehearsalEndpoint, 'local-anvil'); assert.equal(m.wrapperCount, 2);
    const addrs = new Set(node.seen.logAddresses.map(([a]) => a));
    assert.deepEqual([...addrs].sort(), [R.VAULT.toLowerCase(), PT.toLowerCase(), PT2.toLowerCase()].sort());
    assert.equal(Math.min(...node.seen.logAddresses.filter(([a]) => a === PT.toLowerCase()).map(([, f]) => f)), 1500);
    assert.ok(node.seen.calls.length === 2 && node.seen.calls.every(([, data]) => data === R.UNDERLYING_SELECTOR));
    assert.ok(existsSync(join(cache, `scan-43114-${PT.toLowerCase()}.json`)));
    assert.match(r.out, /wrapper-residual|checks: .*wrapperSplitSumsToPTokenHolding=true.*seedExcluded=true/);
    // a wrong underlying on chain is refused
    const bad = await fakeNode({ ...fx, underlying: { [PT]: LEDGER, [PT2]: VAULT } });
    try {
      const o2 = join(d, 'out2');
      const r2 = await cli(['--local-rpc', bad.url, '--cache-dir', join(d, 'cache2'), '--out-dir', o2, '--epoch-id', '2', '--scan-from', '1000', '--first-epoch', '--start-block', '2000', '--to-harvest', '1', '--wrappers', wf]);
      assert.equal(r2.code, 1); assert.match(r2.err, /underlying\(\) is/); assert.ok(!existsSync(o2));
    } finally { bad.close(); }
  } finally { node.close(); }
}, { timeout: 120_000 });

test('a wrapper that is not deployed at the end block contributes nothing on the live path too (underlying() returns no data, no code); an address with code that answers nothing is refused', async () => {
  const fx = new Chain().v(1000, 0, R.ZERO, X, 4_000_000).v(1001, 0, X, SX, 1_000_000).h(3000, 0, 1000n * E18).fixture({ underlying: {}, code: { [PT]: '0x' } });
  const node = await fakeNode(fx);
  try {
    const d = mkdtempSync(join(tmpdir(), 'rewards-wrap-nodeploy-')); const wf = join(d, 'w.json');
    writeFileSync(wf, JSON.stringify({ schema: R.WRAPPERS_SCHEMA, wrappers: [W(PT, { fromBlock: 3200 })] }));
    const base = ['--local-rpc', node.url, '--epoch-id', '2', '--scan-from', '1000', '--first-epoch', '--start-block', '2000', '--to-harvest', '1', '--wrappers', wf];
    const r = await cli([...base, '--cache-dir', join(d, 'c1'), '--out-dir', join(d, 'o1')]);
    assert.equal(r.code, 0, r.err);
    assert.match(r.err, /no contract at block 3000/);
    assert.equal(wrapperOf(JSON.parse(readFileSync(join(d, 'o1', 'epoch.json'), 'utf8')), PT).vaultShareSeconds, '0');
    fx.code[PT] = '0x6080'; // code, but no underlying(): not a pToken
    const r2 = await cli([...base, '--cache-dir', join(d, 'c2'), '--out-dir', join(d, 'o2')]);
    assert.equal(r2.code, 1); assert.match(r2.err, /returned nothing although the address has code/);
  } finally { node.close(); }
}, { timeout: 120_000 });

test('the committed golden fixture is untouched by the wrapper code (no wrapper config, byte-identical)', async () => {
  const fx = JSON.parse(readFileSync(join(FIX_DIR, 'events.fixture.json'), 'utf8'));
  const text = (await R.generate({ source: new R.FixtureSource(fx), cacheFile: null, args: ARGS({ allowContract: [A('c0de02')], toHarvest: '3' }), sleep: noSleep, git: { commit: 'golden', dirty: false } })).text;
  assert.equal(text, readFileSync(join(FIX_DIR, 'expected.epoch.json'), 'utf8'));
});

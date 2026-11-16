// OFFLINE tests of tools/dlmm-rewards-root.mjs on a synthetic event fixture (no network, no endpoint).
//   run from contracts/vault-dlmm:   node --test tools/rewards-test/dlmm-rewards-root.test.mjs
//   regenerate the committed golden files (fixture + expected epoch.json + manifest.json, also read by test/rewards/PharRewardsCrossCheck.t.sol):
//     UPDATE_GOLDEN=1 node --test tools/rewards-test/dlmm-rewards-root.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as R from '../dlmm-rewards-root.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const FIX_DIR = join(HERE, '../../test/rewards/fixtures');
const FX_FILE = join(FIX_DIR, 'events.fixture.json');
const EPOCH_FILE = join(FIX_DIR, 'expected.epoch.json');
const MANIFEST_FILE = join(FIX_DIR, 'expected.manifest.json');
const eu = R.ethers.utils;

// ------------------------------------------------------------------------------------------------------------------------------ the synthetic chain
const A = (hex) => eu.getAddress(`0x${hex.padStart(40, '0')}`);
const LEDGER = A('064efe76812f5f18bd1aa9708739fb33c810b2dd');
const ALICE = A('a11ce'), BOB = A('b0b'), CAROL = A('ca401'), DAVE = A('da0e'), ERIN = A('e41'), FRANK = A('f4a2c');
const ROUTER = A('c0de01');   // a contract holding shares: excluded
const SAFE_LIKE = A('c0de02'); // a contract holding shares that the operator allows
const D7702 = A('7702');      // an EOA with an EIP-7702 delegation: paid
const T_BASE = 1_800_000_000, B_BASE = 1000, INTERVAL = 2;
const tsOfBlock = (b) => T_BASE + (b - B_BASE) * INTERVAL;
const pad = (a) => eu.hexZeroPad(a, 32);
const txh = (tag) => eu.id(`tx-${tag}`);
const xfer = (blockNumber, logIndex, from, to, value) => ({ blockNumber, logIndex, transactionHash: txh(`t${blockNumber}-${logIndex}`), topics: [R.TRANSFER_TOPIC, pad(from), pad(to)], data: eu.hexZeroPad(eu.hexlify(value), 32) });
const harvest = (blockNumber, logIndex, amount, token = R.PHAR) => ({
  blockNumber, logIndex, transactionHash: txh(`h${blockNumber}-${logIndex}`), topics: [R.HARVEST_TOPIC, pad(token)], data: eu.defaultAbiCoder.encode(['uint256', 'uint256', 'uint256'], [amount, 1, 1]),
});
const E18 = 10n ** 18n;
const H = (b, i) => txh(`h${b}-${i}`); // the tx hash of a harvest of the fixture

function makeFixture() {
  const logs = [
    xfer(1000, 0, R.ZERO, R.DEAD, 1_000_000),          // the dead seed
    xfer(1001, 0, R.ZERO, LEDGER, 199_000_000),         // the rest of the cap, minted to the Ledger
    xfer(1500, 0, LEDGER, ALICE, 50_000_000),           // a depositor buys in before the epoch
    xfer(1600, 0, ALICE, BOB, 20_000_000),              // a transfer before the epoch
    harvest(1999, 0, 111n * E18),                       // a previous epoch
    xfer(2000, 5, ALICE, FRANK, 1_000_000),             // exactly at the start block: part of the OPENING balances
    harvest(2000, 6, 7n * E18),                         // the start block of the epoch: a harvest block, not inside (2000, ...]
    harvest(2050, 0, 600n * E18),                       // harvest 1 after the start
    xfer(2100, 0, R.ZERO, CAROL, 30_000_000),           // a mint inside the epoch
    xfer(2200, 0, BOB, BOB, 1_000_000),                 // self transfer: no change
    xfer(2210, 0, ALICE, ALICE, 0),                     // zero-value transfer: no change
    xfer(2300, 0, ALICE, DAVE, 25_000_000),             // a mid-epoch transfer
    xfer(2400, 0, LEDGER, ROUTER, 3_000_000),           // a contract holds shares from here (excluded)
    xfer(2500, 1, BOB, R.ZERO, 20_000_000),             // BOB exits completely (burn)
    xfer(2500, 3, CAROL, ALICE, 10_000_000),            // same block, later log
    xfer(2600, 0, DAVE, ERIN, 2_000_000),               // two hops inside one block: ERIN only passes it on
    xfer(2600, 1, ERIN, FRANK, 2_000_000),
    xfer(2650, 0, CAROL, SAFE_LIKE, 2_000_000),         // an allowed contract (the operator lists it)
    xfer(2700, 0, FRANK, VAULT_ADDR(), 500_000),        // the vault itself ends up with shares (excluded)
    xfer(2750, 0, DAVE, D7702, 1_000_000),              // an EOA with a 7702 delegation (paid)
    xfer(2800, 0, DAVE, R.DEAD, 5_000_000),             // shares sent to the dead address: they stop earning for DAVE
    harvest(2900, 0, 400n * E18),                       // harvest 2
    xfer(3000, 2, R.ZERO, ERIN, 1_000_000),             // minted AT the end block: zero duration, zero weight
    harvest(3000, 4, 5n * E18),                         // harvest 3 (the end block of the golden epoch)
    xfer(3001, 0, ALICE, BOB, 1),                       // after the epoch: must be ignored
    harvest(3001, 1, 99n * E18),                        // harvest 4
    harvest(2950, 0, 3n * E18, A('1234')),              // another token: not a PHAR harvest
  ];
  const code = {
    [ROUTER]: '0x6080604052',                           // a contract
    [SAFE_LIKE]: '0x608060405260043610',                // a contract (allowed by --allow-contract)
    [D7702]: `0xef0100${'ab'.repeat(20)}`,              // an EIP-7702 delegation designator: 23 bytes, an EOA
  };
  return { head: 3500, timeModel: { block: B_BASE, ts: T_BASE, interval: INTERVAL }, code, logs };
}
function VAULT_ADDR() { return eu.getAddress(R.VAULT); }

const ARGS = (over = {}) => ({
  epochId: 2, userBps: 9000, vault: R.VAULT, scanFrom: 1000, firstEpoch: true, startBlock: 2000, toHarvest: '3', allowContract: [SAFE_LIKE], exclude: [],
  extraPhar: 0n, minAmount: 1n, chunk: 100, sleepMs: 0, uri: '', ...over,
});
const noSleep = async () => {};
const run = (fx, over = {}, srcOpts = {}, extra = {}) => R.generate({ source: new R.FixtureSource(fx, srcOpts), cacheFile: null, args: ARGS(over), sleep: noSleep, git: { commit: 'golden', dirty: false }, ...extra });

// ------------------------------------------------------------------------------------------------------------------------------ an independent oracle: second by second
function oracle(fx, { startBlock, endBlock }) {
  const evs = fx.logs.filter((l) => l.topics[0] === R.TRANSFER_TOPIC && l.blockNumber <= endBlock)
    .sort((a, b) => a.blockNumber - b.blockNumber || a.logIndex - b.logIndex)
    .map((l) => ({ ts: tsOfBlock(l.blockNumber), from: eu.getAddress(eu.hexDataSlice(l.topics[1], 12)), to: eu.getAddress(eu.hexDataSlice(l.topics[2], 12)), v: BigInt(l.data) }));
  const t0 = tsOfBlock(startBlock), t1 = tsOfBlock(endBlock);
  const bal = new Map(); const w = new Map(); let i = 0;
  for (let s = t0; s < t1; s++) {
    while (i < evs.length && evs[i].ts <= s) {
      const e = evs[i++];
      if (e.from !== R.ZERO) bal.set(e.from, (bal.get(e.from) ?? 0n) - e.v);
      if (e.to !== R.ZERO) bal.set(e.to, (bal.get(e.to) ?? 0n) + e.v);
    }
    for (const [a, b] of bal) w.set(a, (w.get(a) ?? 0n) + b);
  }
  return w;
}

// ------------------------------------------------------------------------------------------------------------------------------ tests
test('weights equal an independent per-second simulation, and the hand-computed ALICE / BOB / DEAD values', async () => {
  const fx = makeFixture();
  const { epoch } = await run(fx);
  const o = oracle(fx, { startBlock: 2000, endBlock: 3000 });
  const row = (a) => epoch.holders.find((h) => h.address === a);
  for (const [a, w] of o) { if (w === 0n && !row(a)) continue; assert.equal(row(a)?.weight, w.toString(), `weight of ${a}`); }
  assert.equal(row(ALICE).weight, String(29_000_000 * 600 + 4_000_000 * 400 + 14_000_000 * 1000), 'ALICE: 29M for 600 s, 4M for 400 s, 14M for 1000 s');
  assert.equal(row(ALICE).openingShares, '29000000');
  assert.equal(row(ALICE).closingShares, '14000000');
  assert.equal(row(BOB).weight, String(20_000_000 * 1000), 'BOB: 20M (the 1M self transfer changes nothing) for 1000 s, then 0');
  assert.equal(row(R.DEAD).weight, String(1_000_000 * 2000 + 5_000_000 * 400));
  assert.equal(epoch.totals.totalWeight, [...o.values()].reduce((a, b) => a + b, 0n).toString());
  assert.equal(epoch.inputs.durationSeconds, 2000);
});

test('exclusions: zero, dead seed, vault, contracts (except --allow-contract), 7702 delegations are EOAs; reasons and the PHAR returned are listed', async () => {
  const { epoch } = await run(makeFixture());
  const reasons = Object.fromEntries(epoch.exclusions.list.map((e) => [e.address, e.reason]));
  assert.deepEqual(reasons, { [R.DEAD]: 'dead-seed', [VAULT_ADDR()]: 'vault', [ROUTER]: 'contract' });
  assert.ok(!(R.ZERO in reasons) && !epoch.holders.some((h) => h.address === R.ZERO), 'the zero address is never a holder');
  const row = (a) => epoch.holders.find((h) => h.address === a);
  assert.equal(row(SAFE_LIKE).status, 'paid', 'allowed contract is paid');
  assert.equal(row(D7702).status, 'paid', 'a 7702 delegated EOA is paid');
  assert.equal(row(ROUTER).status, 'excluded');
  assert.equal(row(ROUTER).excludedReason, 'contract');
  assert.equal(row(BOB).excludedReason, null);
  const cc = Object.fromEntries(epoch.codeChecks.map((c) => [c.address, c]));
  assert.equal(cc[D7702].class, 'eoa-7702');
  assert.equal(cc[SAFE_LIKE].class, 'contract'); assert.equal(cc[SAFE_LIKE].allowed, true);
  assert.equal(cc[ROUTER].allowed, false);
  assert.equal(cc[ALICE].class, 'eoa');
  assert.ok(!(R.DEAD in cc) && !(VAULT_ADDR() in cc), 'no code lookup for the always-excluded');
  // the PHAR returned to the Safe, per address, sums to the reported slice; every excluded weight stays in the denominator
  const sum = epoch.exclusions.list.reduce((a, e) => a + BigInt(e.returnedToSafe), 0n);
  assert.equal(sum.toString(), epoch.exclusions.totalReturnedToSafe);
  assert.equal(epoch.totals.stayWithSafe.excludedHoldersSlice, sum.toString());
  for (const e of epoch.exclusions.list) assert.ok(BigInt(e.returnedToSafe) > 0n && BigInt(e.weight) > 0n);
  assert.equal(epoch.exclusions.listHash, eu.keccak256(eu.toUtf8Bytes(JSON.stringify(epoch.exclusions.list))));
  assert.ok(!epoch.leaves.some((l) => l.account in reasons));
  // without --allow-contract the Safe-like contract is excluded too
  const strict = await run(makeFixture(), { allowContract: [] });
  assert.equal(strict.epoch.exclusions.list.find((e) => e.address === SAFE_LIKE).reason, 'contract');
  assert.ok(BigInt(strict.epoch.totals.publishTotal) < BigInt(epoch.totals.publishTotal));
  // the others keep exactly their amounts: the denominator did not change
  for (const l of strict.epoch.leaves) assert.equal(l.amount, epoch.leaves.find((x) => x.account === l.account).amount);
  // explicit exclusion
  const ex = await run(makeFixture(), { exclude: [LEDGER] });
  assert.equal(ex.epoch.exclusions.list.find((e) => e.address === LEDGER).reason, 'explicit');
});

test('classifyCode: empty, contract, exactly-23-byte 0xef0100 designator, near misses', () => {
  assert.equal(R.classifyCode('0x'), 'eoa');
  assert.equal(R.classifyCode(''), 'eoa');
  assert.equal(R.classifyCode('0x6080'), 'contract');
  assert.equal(R.classifyCode(`0xef0100${'00'.repeat(20)}`), 'eoa-7702');
  assert.equal(R.classifyCode(`0xEF0100${'AB'.repeat(20)}`), 'eoa-7702');
  assert.equal(R.classifyCode(`0xef0100${'00'.repeat(21)}`), 'contract', '24 bytes');
  assert.equal(R.classifyCode(`0xef0100${'00'.repeat(19)}`), 'contract', '22 bytes');
  assert.equal(R.classifyCode(`0xef0101${'00'.repeat(20)}`), 'contract', 'another version byte');
  assert.equal(R.classifyCode(`0xef0200${'00'.repeat(20)}`), 'contract', 'another magic');
});

test('epochs end at harvests: --to-harvest by index and by transaction hash, spanning several harvests; PHAR total = the harvest sum only', async () => {
  const fx = makeFixture();
  const e1 = (await run(fx, { toHarvest: '1' })).epoch;
  assert.equal(e1.inputs.endBlock, 2050);
  assert.equal(e1.inputs.harvest.sum, (600n * E18).toString());
  assert.equal(e1.inputs.harvest.count, 1);
  const e2 = (await run(fx, { toHarvest: '2' })).epoch;
  assert.equal(e2.inputs.endBlock, 2900);
  assert.equal(e2.inputs.harvest.sum, (1000n * E18).toString());
  const e3 = (await run(fx, { toHarvest: '3' })).epoch;
  assert.equal(e3.inputs.endBlock, 3000);
  assert.equal(e3.inputs.harvest.sum, (1005n * E18).toString(), '600 + 400 + 5; the 7 at the start block, the 111, the 99 and the foreign token do not count');
  assert.deepEqual(e3.inputs.harvest.transactions.map((h) => h.txHash), [H(2050, 0), H(2900, 0), H(3000, 4)]);
  assert.equal(e3.inputs.extraPhar, '0');
  assert.equal(e3.inputs.pharTotal, e3.inputs.harvest.sum);
  // by tx hash: identical output
  const byTx = await run(fx, { toHarvest: H(3000, 4) });
  assert.equal(byTx.text, (await run(fx, { toHarvest: '3' })).text);
  assert.equal((await run(fx, { toHarvest: H(2900, 0) })).epoch.inputs.endBlock, 2900);
  // not found
  await assert.rejects(run(fx, { toHarvest: '9' }), /not found/);
  await assert.rejects(run(fx, { toHarvest: eu.id('nope') }), /not found/);
  await assert.rejects(run(fx, { toHarvest: H(1999, 0) }), /not found/, 'a harvest at or before the start block cannot end the epoch');
  await assert.rejects(run(fx, { toHarvest: 'last' }), /--to-harvest/);
});

test('--to-harvest scans only as far as needed (and stops at the chunk that holds the harvest)', async () => {
  const src = new R.FixtureSource(makeFixture());
  await R.generate({ source: src, cacheFile: null, args: ARGS({ toHarvest: '1' }), sleep: noSleep });
  assert.equal(src.calls.at(-1)[1], 2099, 'the chunk 2000..2099 holds the harvest at 2050; nothing beyond is requested');
});

test('--extra-phar is added and shown separately; donated PHAR is otherwise not distributed', async () => {
  const fx = makeFixture();
  const base = (await run(fx)).epoch;
  const ex = (await run(fx, { extraPhar: 100n * E18 })).epoch;
  assert.equal(ex.inputs.harvest.sum, base.inputs.harvest.sum);
  assert.equal(ex.inputs.extraPhar, (100n * E18).toString());
  assert.equal(ex.inputs.pharTotal, (1105n * E18).toString());
  assert.ok(BigInt(ex.totals.publishTotal) > BigInt(base.totals.publishTotal));
});

test('consecutive epochs tile: the second starts at the first one\'s end block (a harvest block) via its manifest', async () => {
  const fx = makeFixture();
  const a = await run(fx, { toHarvest: '1', epochId: 0 });
  const b = await run(fx, { toHarvest: '1', epochId: 1, firstEpoch: false, startBlock: undefined }, {}, { previous: a.manifest });
  assert.equal(b.epoch.inputs.startBlock, a.epoch.inputs.endBlock);
  assert.equal(b.epoch.inputs.endBlock, 2900);
  assert.equal(b.epoch.inputs.previousEpochId, 0);
  assert.equal(b.epoch.inputs.firstEpoch, false);
  assert.equal(BigInt(a.epoch.inputs.harvest.sum) + BigInt(b.epoch.inputs.harvest.sum), 1000n * E18, 'no harvest counted twice or lost');
  assert.equal(b.manifest.publishEpochArguments.fromBlock, a.manifest.publishEpochArguments.toBlock);
  // the whole thing in one epoch has the same PHAR total
  const whole = await run(fx, { toHarvest: '2' });
  assert.equal(whole.epoch.inputs.pharTotal, (BigInt(a.epoch.inputs.pharTotal) + BigInt(b.epoch.inputs.pharTotal)).toString());
  // refusals
  await assert.rejects(run(fx, { epochId: 1, firstEpoch: false, startBlock: undefined }, {}, { previous: { ...a.manifest, vault: LEDGER } }), /not a manifest of this vault/);
  await assert.rejects(run(fx, { epochId: 0, firstEpoch: false, startBlock: undefined }, {}, { previous: a.manifest }), /larger than the previous/);
  await assert.rejects(run(fx, { epochId: 1, firstEpoch: false, startBlock: undefined }, {}, { previous: { ...a.manifest, endBlock: 2100 } }), /no PharHarvested event/);
  await assert.rejects(run(fx, { epochId: 1, firstEpoch: true, startBlock: undefined }, {}, { previous: a.manifest }), /do not give/);
  await assert.rejects(run(fx, { firstEpoch: false, startBlock: undefined }), /--previous-manifest/);
});

test('the first epoch defaults to the vault\'s first harvest-eligible block', () => {
  assert.equal(R.FIRST_EPOCH_START_BLOCK, 100488395);
  const a = R.parseArgs(['--epoch-id', '0', '--scan-from', '100000000', '--first-epoch', '--to-harvest', '1']);
  assert.equal(a.startBlock, undefined); // generate() then uses FIRST_EPOCH_START_BLOCK
});

test('dead seed excluded, BOB exits fully, ERIN has zero weight (zero), the rest is paid', async () => {
  const { epoch } = await run(makeFixture());
  const row = (a) => epoch.holders.find((h) => h.address === a);
  assert.equal(row(R.DEAD).status, 'excluded');
  assert.ok(BigInt(row(R.DEAD).unpaidSlice) > 0n);
  assert.equal(row(BOB).status, 'paid');
  assert.equal(row(BOB).closingShares, '0');
  assert.equal(row(ERIN).status, 'zero');
  assert.equal(row(ERIN).weight, '0');
  assert.equal(row(FRANK).openingShares, '1000000');
});

test('amounts are floor(pool * weight / totalWeight); sum of leaves <= pool <= phar * bps / 10000; the publish total is the sum of the leaves', async () => {
  const { epoch } = await run(makeFixture());
  const phar = BigInt(epoch.inputs.pharTotal);
  const pool = (phar * 9000n) / 10000n;
  assert.equal(epoch.totals.pool, pool.toString());
  const W = BigInt(epoch.totals.totalWeight);
  let sum = 0n;
  for (const h of epoch.holders) {
    const would = (pool * BigInt(h.weight)) / W;
    if (h.status === 'paid') { assert.equal(h.amount, would.toString()); sum += would; }
  }
  assert.equal(epoch.totals.publishTotal, sum.toString());
  assert.ok(sum <= pool && pool <= phar * 9000n / 10000n);
  const stay = epoch.totals.stayWithSafe;
  assert.equal(BigInt(stay.total), phar - sum);
  assert.equal(BigInt(stay.safeShareOfBps) + BigInt(stay.excludedHoldersSlice) + BigInt(stay.roundingAndDust), phar - sum);
  assert.ok(Object.values(epoch.checks).every((v) => v === true));
});

test('every proof verifies against the root with an independent verifier; leaves are sorted; the leaf format is the spec one; ids are bound', async () => {
  const { epoch } = await run(makeFixture());
  const sortedLeaves = epoch.leaves.map((c) => c.leaf);
  assert.deepEqual(sortedLeaves, [...sortedLeaves].sort());
  for (const c of epoch.leaves) {
    const leaf = eu.keccak256(eu.keccak256(eu.defaultAbiCoder.encode(['uint256', 'address', 'uint256'], [2, c.account, c.amount])));
    assert.equal(c.leaf, leaf);
    let h = leaf;
    for (const s of c.proof) h = BigInt(h) < BigInt(s) ? eu.keccak256(eu.hexConcat([h, s])) : eu.keccak256(eu.hexConcat([s, h]));
    assert.equal(h, epoch.root);
    assert.ok(!R.verifyProof(c.proof, epoch.root, R.leafHash(2, c.account, (BigInt(c.amount) + 1n).toString())));
    for (const other of [1, 3]) assert.ok(!R.verifyProof(c.proof, epoch.root, R.leafHash(other, c.account, c.amount)));
  }
  const b = await run(makeFixture(), { epochId: 3 });
  assert.notEqual(b.epoch.root, epoch.root);
  assert.equal(b.epoch.totals.publishTotal, epoch.totals.publishTotal);
});

test('manifest: block range, harvest tx hashes, pharTotal, userBps, exclusion list hash, dataHash = keccak256(epoch.json), root, free-text uri, git info only in the manifest', async () => {
  const { epoch, text, manifest } = await run(makeFixture(), { uri: 'ipfs://example-not-on-chain' });
  assert.equal(manifest.dataHash, eu.keccak256(eu.toUtf8Bytes(text)));
  assert.equal(manifest.root, epoch.root);
  assert.equal(manifest.startBlock, 2000); assert.equal(manifest.endBlock, 3000);
  assert.deepEqual(manifest.harvestTxHashes, [H(2050, 0), H(2900, 0), H(3000, 4)]);
  assert.equal(manifest.pharTotal, epoch.inputs.pharTotal);
  assert.equal(manifest.userBps, 9000);
  assert.equal(manifest.exclusionListHash, epoch.exclusions.listHash);
  assert.equal(manifest.uri, 'ipfs://example-not-on-chain');
  assert.equal(manifest.leavesFile, 'epoch.json');
  assert.equal(manifest.gitCommit, 'golden');
  assert.deepEqual(manifest.publishEpochArguments, { root: epoch.root, total: epoch.totals.publishTotal, fromBlock: 2000, toBlock: 3000, dataHash: manifest.dataHash });
  assert.equal(manifest.generator.version, R.GENERATOR.version);
  // the hashed file does not contain the volatile bits and the user-bps is inside it (so it is committed on chain only through dataHash)
  assert.ok(!text.includes('golden') && !text.includes('ipfs://'));
  assert.equal(epoch.inputs.userBps, 9000);
  // user-bps changes the data hash
  const other = await run(makeFixture(), { userBps: 8000 });
  assert.notEqual(other.manifest.dataHash, manifest.dataHash);
  assert.equal(other.manifest.userBps, 8000);
});

test('deterministic: byte-identical output for any chunk size; retry with back-off', async () => {
  const fx = makeFixture();
  const base = (await run(fx)).text;
  for (const chunk of [1, 7, 100, 999, 5000]) assert.equal((await run(fx, { chunk })).text, base, `chunk ${chunk}`);
  let n = 0; const waits = [];
  const v = await R.withRetry(async () => { if (++n < 4) throw new Error('boom'); return 'ok'; }, { sleep: async (ms) => waits.push(ms), baseMs: 100 });
  assert.equal(v, 'ok'); assert.equal(waits.length, 3);
  assert.ok(waits[1] > waits[0] - 1 && waits[2] > waits[1] * 0.9, 'back-off grows');
  await assert.rejects(R.withRetry(async () => { throw new Error('always'); }, { retries: 2, sleep: noSleep }), /always/);
});

test('scan: 100-block chunks, contiguous, resumable (a later run scans only the new blocks), transient errors are retried', async () => {
  const fx = makeFixture();
  const dir = mkdtempSync(join(tmpdir(), 'rewards-cache-'));
  const file = join(dir, 'scan.json');
  const s1 = new R.FixtureSource(fx);
  await R.generate({ source: s1, cacheFile: file, args: ARGS({ toHarvest: '2' }), sleep: noSleep });
  assert.equal(s1.calls[0][0], 1000);
  for (const [f, t] of s1.calls) assert.ok(t - f + 1 <= 100 && t >= f);
  for (let i = 1; i < s1.calls.length; i++) assert.equal(s1.calls[i][0], s1.calls[i - 1][1] + 1, 'contiguous');
  assert.equal(s1.calls.at(-1)[1], 2999, 'the chunk 2900..2999 holds the harvest at 2900');
  const s2 = new R.FixtureSource(fx, { failFirst: 2 }); // every chunk fails twice before it works
  const r2 = await R.generate({ source: s2, cacheFile: file, args: ARGS({ toHarvest: '3' }), sleep: noSleep });
  assert.equal(s2.calls[0][0], 3000, 'resumed after the last scanned block');
  assert.equal(s2.calls.at(-1)[1], 3099);
  const s3 = new R.FixtureSource(fx);
  const again = await R.generate({ source: s3, cacheFile: file, args: ARGS({ toHarvest: '3' }), sleep: noSleep });
  assert.equal(s3.calls.length, 0, 'a third run needs no log call');
  assert.equal(again.text, r2.text);
  assert.equal(r2.text, (await run(fx)).text, 'resumed result == direct result');
  assert.equal(s3.tsCalls, 0, 'timestamps are cached too');
});

test('a scan that starts too late is detected (negative balance) instead of silently giving wrong weights', async () => {
  await assert.rejects(run(makeFixture(), { scanFrom: 1550 }), /negative balance/);
});

test('block timestamps by binary search: lookups are logarithmic', async () => {
  const src = new R.FixtureSource(makeFixture());
  const ts = new R.Timestamps(src, { data: { timestamps: {} } });
  assert.equal(await ts.blockAtOrBefore(tsOfBlock(3000), 1000, 3500), 3000);
  assert.equal(await ts.blockAtOrBefore(tsOfBlock(3000) + 1, 1000, 3500), 3000);
  assert.equal(await ts.blockAtOrAfter(tsOfBlock(3000) + 1, 1000, 3500), 3001);
  assert.equal(await ts.blockAtOrAfter(tsOfBlock(1000), 1000, 3500), 1000);
  assert.ok(src.tsCalls < 60);
});

test('--user-bps: sum of leaves never exceeds phar * bps / 10000; 0 and above 10000 are refused', async () => {
  for (const bps of [1, 5000, 9000, 9999, 10000]) {
    const { epoch } = await run(makeFixture(), { userBps: bps });
    assert.ok(BigInt(epoch.totals.publishTotal) * 10000n <= BigInt(epoch.inputs.pharTotal) * BigInt(bps), `bps ${bps}`);
  }
  const hi = BigInt((await run(makeFixture(), { userBps: 10000 })).epoch.totals.publishTotal);
  const lo = BigInt((await run(makeFixture(), { userBps: 9000 })).epoch.totals.publishTotal);
  assert.ok(hi > lo);
  await assert.rejects(run(makeFixture(), { userBps: 0 }), /no holder earned anything/);
  await assert.rejects(run(makeFixture(), { userBps: 10001 }), /user-bps/);
});

test('--min-amount drops small leaves into "dust" and the checks still hold', async () => {
  const fx = makeFixture();
  const base = await run(fx);
  const amounts = base.epoch.leaves.map((c) => BigInt(c.amount)).sort((x, y) => (x < y ? -1 : 1));
  const r = await run(fx, { minAmount: amounts[1] + 1n }); // drops the two smallest leaves
  assert.equal(r.epoch.leaves.length, base.epoch.leaves.length - 2);
  assert.equal(r.epoch.holders.filter((h) => h.status === 'dust').length, 2);
  assert.ok(BigInt(r.epoch.totals.droppedDust) > 0n);
  assert.ok(Object.values(r.epoch.checks).every(Boolean));
});

test('inputs that cannot work are refused', async () => {
  const fx = makeFixture();
  await assert.rejects(run(fx, { startBlock: 9999 }), /not below the chain head/);
  await assert.rejects(run(fx, { startBlock: 900 }), /scan-from/);
  // an epoch whose only harvest sum is zero
  const zero = makeFixture(); zero.logs = zero.logs.map((l) => (l.topics[0] === R.HARVEST_TOPIC ? { ...l, data: eu.defaultAbiCoder.encode(['uint256', 'uint256', 'uint256'], [0, 1, 1]) } : l));
  await assert.rejects(run(zero), /nothing to distribute/);
});

test('CLI argument parsing: no RPC / end block / PHAR amount option, redaction hides urls, required options are enforced', () => {
  for (const bad of ['--rpc-url', '--end-block', '--phar-total', '--from-harvest-events']) assert.throws(() => R.parseArgs([bad, 'x']), /unknown argument/);
  assert.equal(R.redact('failed: https://api.avax.network/ext/bc/C/rpc?x=1 end'), 'failed: <url-redacted> end');
  const need = ['--epoch-id', '1', '--scan-from', '10', '--first-epoch', '--to-harvest', '2'];
  assert.throws(() => R.parseArgs(need.slice(0, 4)), /--to-harvest is required/);
  assert.throws(() => R.parseArgs(['--epoch-id', '1', '--scan-from', '10', '--to-harvest', '2']), /exactly one of/);
  assert.throws(() => R.parseArgs([...need, '--previous-manifest', 'm.json']), /exactly one of/);
  assert.throws(() => R.parseArgs(['--epoch-id', '1', '--scan-from', '10', '--previous-manifest', 'm.json', '--to-harvest', '2', '--start-block', '5']), /only for --first-epoch/);
  assert.throws(() => R.parseArgs([...need, '--user-bps', '10001']), /user-bps/);
  assert.throws(() => R.parseArgs([...need.slice(0, 5), '--to-harvest', '0']), /--to-harvest/);
  assert.throws(() => R.parseArgs(['--epoch-id', 'x']), /integer/);
  const ok = R.parseArgs([...need, '--allow-contract', SAFE_LIKE.toLowerCase(), '--exclude', LEDGER.toLowerCase(), '--extra-phar', '5']);
  assert.equal(ok.userBps, 9000, 'default 90 %');
  assert.equal(ok.allowContract[0], SAFE_LIKE);
  assert.equal(ok.exclude[0], LEDGER);
  assert.equal(ok.extraPhar, 5n);
  assert.equal(ok.chunk, 100);
  assert.throws(() => new R.RpcSource({ url: 'https://other.example/rpc' }), /public endpoint/);
});

test('the merkle tree: single leaf = root with an empty proof; odd sizes promote the unpaired node', () => {
  const one = R.buildTree(['0x' + '11'.repeat(32)]);
  assert.equal(one.root, '0x' + '11'.repeat(32));
  assert.deepEqual(R.proofOf(one.layers, 0), []);
  for (let n = 1; n <= 17; n++) {
    const leaves = Array.from({ length: n }, (_, i) => eu.keccak256(eu.hexlify(i + 1)));
    const t = R.buildTree(leaves);
    for (let i = 0; i < n; i++) assert.ok(R.verifyProof(R.proofOf(t.layers, i), t.root, leaves[i]), `n=${n} i=${i}`);
  }
});

test('golden files: fixture, expected epoch.json and manifest.json are byte-identical to what the tool generates now (also read by the forge cross-check); the CLI writes the same files', async () => {
  const fx = makeFixture();
  const { epoch, text, manifest } = await run(fx);
  const fxJson = `${JSON.stringify(fx, null, 2)}\n`;
  if (process.env.UPDATE_GOLDEN) {
    mkdirSync(FIX_DIR, { recursive: true });
    writeFileSync(FX_FILE, fxJson); writeFileSync(EPOCH_FILE, text); writeFileSync(MANIFEST_FILE, R.toJson(manifest));
  }
  assert.equal(readFileSync(FX_FILE, 'utf8'), fxJson, 'fixture differs (UPDATE_GOLDEN=1 to rewrite)');
  assert.equal(readFileSync(EPOCH_FILE, 'utf8'), text);
  assert.equal(readFileSync(MANIFEST_FILE, 'utf8'), R.toJson(manifest));
  assert.ok(epoch.totals.leafCount >= 5);
  // the CLI path (fixture file, out dir); the manifest differs only in the git fields, which the test pins
  const out = mkdtempSync(join(tmpdir(), 'rewards-cli-'));
  const code = await R.main(['--fixture', FX_FILE, '--epoch-id', '2', '--scan-from', '1000', '--first-epoch', '--start-block', '2000', '--to-harvest', '3',
    '--allow-contract', SAFE_LIKE, '--out-dir', out], { git: { commit: 'golden', dirty: false } });
  assert.equal(code, 0);
  assert.equal(readFileSync(join(out, 'epoch.json'), 'utf8'), readFileSync(EPOCH_FILE, 'utf8'));
  assert.equal(readFileSync(join(out, 'manifest.json'), 'utf8'), readFileSync(MANIFEST_FILE, 'utf8'));
  // a published epoch file is never silently replaced
  await assert.rejects(R.main(['--fixture', FX_FILE, '--epoch-id', '2', '--scan-from', '1000', '--first-epoch', '--start-block', '2000', '--to-harvest', '2',
    '--allow-contract', SAFE_LIKE, '--out-dir', out], { git: null }), /exists and differs/);
});

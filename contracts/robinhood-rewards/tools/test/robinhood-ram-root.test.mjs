// Offline tests of tools/robinhood-ram-root.mjs. Run: node --test tools/test/  (UPDATE_FIXTURES=1 rewrites the golden files)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import {
  generate, FixtureSource, parseArgs, checkRpcUrl, sideValues, splitHeld, timeWeights, getLogsSplitting, verifyProof, leafHash,
  classifyCode, toJson, main, LEDGER, OLD_SIGNER, DEAD, TIMELOCK, STOCK_MARKET, DOLLAR_MARKET, PUBLIC_RPC, ethers,
} from '../robinhood-ram-root.mjs';
import { buildFixture, ALICE, BOB, CAROL, DAVE, POOL, DELEGATED, SCAN_FROM } from './fixture.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const FIX = join(HERE, '../../test/fixtures');
const noSleep = async () => {};
const GIT = { commit: 'fixture', dirty: false };
const base = { epochId: 0, userBps: 9000, minAmount: 1n, extraReward: 0n, exclude: [], allowContract: [], scanFrom: SCAN_FROM, firstEpoch: true, toHarvest: '0x' + '0'.repeat(64) };
const tx = (t) => ethers.utils.id(`tx-${t}`);
const run = (over = {}, previous = null, fx = buildFixture()) => generate({ source: new FixtureSource(fx), args: { ...base, toHarvest: tx('h3'), ...over }, previous, sleep: noSleep, git: GIT });
const leafOf = (epoch, a) => epoch.leaves.find((l) => l.account.toLowerCase() === a.toLowerCase());
const B = (x) => BigInt(x);

test('golden: epoch 0 and epoch 1 are byte-identical to the committed fixtures (also used by the Foundry cross-check)', async () => {
  const r0 = await run();
  const r1 = await run({ epochId: 1, firstEpoch: false, toHarvest: tx('h4') }, r0.manifest);
  const files = { 'events.fixture.json': toJson(buildFixture()), 'expected.epoch0.json': r0.text, 'expected.manifest0.json': toJson(r0.manifest),
    'expected.epoch1.json': r1.text, 'expected.manifest1.json': toJson(r1.manifest) };
  if (process.env.UPDATE_FIXTURES) { mkdirSync(FIX, { recursive: true }); for (const [k, v] of Object.entries(files)) writeFileSync(join(FIX, k), v); }
  for (const [k, v] of Object.entries(files)) assert.equal(readFileSync(join(FIX, k), 'utf8'), v, k);
});

test('deterministic: two runs give the same bytes', async () => {
  assert.equal((await run()).text, (await run()).text);
});

test('the epoch range, the held events and the market split follow the PairCheckpoints', async () => {
  const { epoch } = await run();
  const i = epoch.inputs;
  assert.equal(i.startBlock, SCAN_FROM); assert.equal(i.endBlock, 2500);
  assert.deepEqual(i.held.map((h) => h.block), [1050, 1800, 2000, 2500], 'other token and other pair ignored');
  const [early, h1, pending, h3] = i.held;
  assert.equal(early.checkpoint, null); assert.equal(early.unattributed, String(7n * 10n ** 15n));
  // h1: stock $8 vs usdg $5 of 3e16
  assert.equal(h1.toStockMarket, String((3n * 10n ** 16n * 8n) / 13n));
  assert.equal(B(h1.toStockMarket) + B(h1.toDollarMarket), 3n * 10n ** 16n);
  // pending: loss-branch checkpoint at 1900: benchmark 14 + pnl -1 = 13 => stock 8, usdg 5
  assert.equal(pending.checkpoint.block, 1900); assert.equal(pending.stockUSD18, String(8n * 10n ** 18n));
  // h3 gain branch: 19 + 1 = 20, usdg 8 => stock 12
  assert.equal(h3.stockUSD18, String(12n * 10n ** 18n)); assert.equal(h3.usdgUSD18, String(8n * 10n ** 18n));
  assert.equal(epoch.totals.heldSum, String(97n * 10n ** 15n));
});

test('independent arithmetic: alice, carol, dave and the protocol leaf', async () => {
  const { epoch } = await run();
  const t0 = 1_800_000_000; const ts = (b) => t0 + (b - 1000) * 2; const t1 = ts(2500);
  const stockReward = B(epoch.totals.toStockMarket); const dollarReward = B(epoch.totals.toDollarMarket);
  // rpSPY supply-seconds: timelock 5e6 (whole window after 1010), dead 1e8, alice 3e8 from 1200 then 2e8 from 1500, bob 1e8 1300..1700, pool 2e8 from 1400, ledger 1e8 from 1450, delegated 5e7 from 1460, carol 1e8 from 1500
  const wS = { tl: 5_000_000n * B(t1 - ts(1010)), dead: 100_000_000n * B(t1 - ts(1010)), alice: 300_000_000n * B(ts(1500) - ts(1200)) + 200_000_000n * B(t1 - ts(1500)),
    bob: 100_000_000n * B(ts(1700) - ts(1300)), pool: 200_000_000n * B(t1 - ts(1400)), ledger: 100_000_000n * B(t1 - ts(1450)), del: 50_000_000n * B(t1 - ts(1460)), carol: 100_000_000n * B(t1 - ts(1500)) };
  // the window starts at ts(1000) and the seeds arrive at 1010 (inside the window)
  const totS = Object.values(wS).reduce((a, b) => a + b, 0n);
  assert.equal(epoch.markets[0].totalWeight, String(totS));
  const poolS = stockReward * 9000n / 10000n;
  const wD = { tl: 49_900_000_000n * B(t1 - ts(1010)), dead: 100_000_000n * B(t1 - ts(1010)), dave: 20_000_000_000n * B(t1 - ts(1250)), alice: 10_000_000_000n * B(t1 - ts(1350)), old: 5_000_000_000n * B(t1 - ts(1600)) };
  const totD = Object.values(wD).reduce((a, b) => a + b, 0n);
  const poolD = dollarReward * 9000n / 10000n;
  const alice = poolS * wS.alice / totS + poolD * wD.alice / totD;
  assert.equal(leafOf(epoch, ALICE).amount, String(alice), 'alice: both markets in ONE leaf');
  assert.equal(leafOf(epoch, CAROL).amount, String(poolS * wS.carol / totS));
  assert.equal(leafOf(epoch, BOB).amount, String(poolS * wS.bob / totS), 'bob is paid for the time he held');
  assert.equal(leafOf(epoch, DAVE).amount, String(poolD * wD.dave / totD));
  assert.equal(leafOf(epoch, DELEGATED).amount, String(poolS * wS.del / totS), 'EIP-7702 counts as EOA');
  const ledgerHolder = poolS * wS.ledger / totS;
  const sumOthers = epoch.leaves.filter((l) => l.account.toLowerCase() !== LEDGER.toLowerCase()).reduce((a, l) => a + B(l.amount), 0n);
  assert.equal(B(leafOf(epoch, LEDGER).amount), 97n * 10n ** 15n - sumOthers, 'the protocol leaf takes the rest');
  assert.equal(epoch.totals.protocol.asHolder, String(ledgerHolder));
  assert.equal(leafOf(epoch, POOL), undefined); assert.equal(leafOf(epoch, OLD_SIGNER), undefined);
  assert.equal(leafOf(epoch, DEAD), undefined); assert.equal(leafOf(epoch, TIMELOCK), undefined);
  const reasons = Object.fromEntries(epoch.exclusions.list.map((e) => [`${e.market}:${e.address}`, e.reason]));
  assert.equal(reasons[`rpSPY:${POOL}`], 'contract'); assert.equal(reasons[`rpUSDGs:${OLD_SIGNER}`], 'old-signer-never-paid');
  assert.equal(reasons[`rpSPY:${DEAD}`], 'dead-seed'); assert.equal(reasons[`rpSPY:${TIMELOCK}`], 'timelock');
  assert.equal(epoch.leaves.reduce((a, l) => a + B(l.amount), 0n), 97n * 10n ** 15n);
  for (const l of epoch.leaves) assert.ok(verifyProof(l.proof, epoch.root, leafHash(0, l.account, l.amount)));
});

test('epoch 1 chains from the previous manifest; the stock side has no principal so all of it goes to rpUSDGs', async () => {
  const r0 = await run();
  const { epoch } = await run({ epochId: 1, firstEpoch: false, toHarvest: tx('h4') }, r0.manifest);
  assert.equal(epoch.inputs.startBlock, 2500); assert.equal(epoch.inputs.endBlock, 3000);
  assert.equal(epoch.totals.toStockMarket, '0'); assert.equal(epoch.totals.toDollarMarket, String(10n ** 16n));
  assert.equal(epoch.leaves.reduce((a, l) => a + B(l.amount), 0n), 10n ** 16n);
  // dave moved half to carol at 2600: both paid in epoch 1
  assert.ok(leafOf(epoch, DAVE) && leafOf(epoch, CAROL));
  await assert.rejects(run({ epochId: 0, firstEpoch: false, toHarvest: tx('h4') }, r0.manifest), /larger than the previous/);
  const bad = { ...r0.manifest, endBlock: 2400 };
  await assert.rejects(run({ epochId: 1, firstEpoch: false, toHarvest: tx('h4') }, bad), /boundaries must be harvest blocks/);
});

test('user-bps 10000 and 0, protocol recipient override, old signer refused everywhere', async () => {
  const all = (await run({ userBps: 10000 })).epoch;
  assert.equal(all.totals.protocol.bpsPart, '0');
  const none = (await run({ userBps: 0 })).epoch;
  assert.equal(none.leaves.length, 1); assert.equal(none.leaves[0].account, LEDGER);
  const other = '0x00000000000000000000000000000000000ABCDE';
  const r = (await run({ protocolRecipient: other })).epoch;
  assert.equal(leafOf(r, other).amount, r.totals.protocol.leafTotal);
  assert.equal(leafOf(r, LEDGER).amount, r.markets[0].holders.find((h) => h.address === LEDGER).amount, 'the Ledger keeps only its holder part');
  await assert.rejects(run({ protocolRecipient: OLD_SIGNER }), /old signer/);
  await assert.rejects(run({ allowContract: [OLD_SIGNER] }), /old signer/);
  assert.throws(() => parseArgs(['--epoch-id', '0', '--first-epoch', '--to-harvest', '1', '--protocol-recipient', OLD_SIGNER]), /old signer/);
});

test('allow-contract pays a contract holder; explicit exclude removes an EOA', async () => {
  const a = (await run({ allowContract: [POOL] })).epoch;
  assert.ok(B(leafOf(a, POOL).amount) > 0n);
  const e = (await run({ exclude: [ALICE] })).epoch;
  assert.equal(leafOf(e, ALICE), undefined);
  assert.ok(e.exclusions.list.some((x) => x.address === ALICE && x.reason === 'explicit'));
});

test('extra reward (swept/cancelled RAM already in the distributor) goes to the protocol leaf only', async () => {
  const a = (await run()).epoch; const b = (await run({ extraReward: 123n })).epoch;
  assert.equal(B(b.totals.publishTotal), B(a.totals.publishTotal) + 123n);
  assert.equal(B(leafOf(b, LEDGER).amount), B(leafOf(a, LEDGER).amount) + 123n);
  assert.equal(leafOf(b, ALICE).amount, leafOf(a, ALICE).amount);
});

test('a scan that starts too late fails on a negative balance', async () => {
  await assert.rejects(run({ scanFrom: 1400, startBlock: 1400 }), /negative balance/);
});

test('the chosen harvest must exist; index and "last" work', async () => {
  await assert.rejects(run({ toHarvest: '0x' + 'ab'.repeat(32) }), /not found/);
  assert.equal((await run({ toHarvest: '2' })).epoch.inputs.endBlock, 1800);
  assert.equal((await run({ toHarvest: 'last' })).epoch.inputs.endBlock, 3000);
});

test('wrong chain id is refused', async () => {
  const fx = buildFixture(); fx.chainId = 43114;
  await assert.rejects(run({}, null, fx), /not 4663/);
});

test('getLogs splitting: a range limit is handled by halving', async () => {
  const fx = buildFixture(); fx.maxRange = 300;
  const src = new FixtureSource(fx);
  const logs = await getLogsSplitting(src, 1000, 3100);
  assert.equal(logs.length, fx.logs.length);
  assert.ok(src.calls.every(([a, b]) => b - a + 1 <= 300));
  const r = await generate({ source: new FixtureSource(fx), args: { ...base, toHarvest: tx('h3'), chunk: 5000 }, sleep: noSleep, git: GIT });
  assert.equal(r.text, (await run()).text);
});

test('rpc url: only the public endpoint or loopback http', () => {
  assert.equal(checkRpcUrl(PUBLIC_RPC), PUBLIC_RPC);
  assert.equal(checkRpcUrl('http://127.0.0.1:8545'), 'http://127.0.0.1:8545');
  for (const bad of ['https://evil.example', 'http://10.0.0.1:8545', 'http://user:pw@127.0.0.1:8545', 'https://127.0.0.1:8545', 'nonsense']) assert.throws(() => checkRpcUrl(bad));
});

test('sideValues: all three checkpoint branches value the post principals as benchmark + pnl', () => {
  const v = sideValues({ benchmark: 10n * 10n ** 18n, pnl: -2n * 10n ** 18n, usdgPrincipal: 3_000_000n });
  assert.equal(v.usdgUSD, 3n * 10n ** 18n); assert.equal(v.stockUSD, 5n * 10n ** 18n);
  assert.equal(sideValues({ benchmark: 1n, pnl: 0n, usdgPrincipal: 5_000_000n }).stockUSD, 0n, 'clamped at zero');
  const s = splitHeld([{ blockNumber: 5, logIndex: 0, amount: 100n }], [{ blockNumber: 5, logIndex: 1, benchmark: 1n, pnl: 0n, usdgPrincipal: 0n, stockPrincipal: 0n }]);
  assert.equal(s.unattributed, 100n, 'a checkpoint AFTER the held log does not count');
});

test('timeWeights: the market address and 0x0 are mint/burn sentinels; supply integral equals the sum', () => {
  const M = STOCK_MARKET;
  const tr = [{ blockNumber: 1, logIndex: 0, from: M, to: ALICE, value: 10n }, { blockNumber: 5, logIndex: 0, from: ALICE, to: M, value: 4n }, { blockNumber: 7, logIndex: 0, from: '0x0000000000000000000000000000000000000000', to: BOB, value: 2n }];
  const w = timeWeights({ transfers: tr, market: M, startBlock: 0, endBlock: 10, t0: 0, t1: 10, ts: (b) => b });
  assert.equal(w.weights.get(ALICE), 10n * 4n + 6n * 5n); assert.equal(w.weights.get(BOB), 2n * 3n);
  assert.equal(w.totalWeight, 76n); assert.equal(w.supplyAtEnd, 8n);
  assert.throws(() => timeWeights({ transfers: tr, market: DOLLAR_MARKET, startBlock: 0, endBlock: 10, t0: 0, t1: 10, ts: (b) => b }), /negative balance/, 'another market address is NOT a sentinel');
});

test('classifyCode', () => {
  assert.equal(classifyCode('0x'), 'eoa'); assert.equal(classifyCode(`0xef0100${'ab'.repeat(20)}`), 'eoa-7702'); assert.equal(classifyCode('0x6080'), 'contract');
});

test('CLI: writes epoch.json + manifest.json from a fixture, refuses to overwrite a different file', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'ramroot-'));
  const fxFile = join(dir, 'fx.json'); writeFileSync(fxFile, toJson(buildFixture()));
  const args = ['--epoch-id', '0', '--first-epoch', '--scan-from', String(SCAN_FROM), '--to-harvest', tx('h3'), '--fixture', fxFile, '--out-dir', join(dir, 'e0')];
  const orig = process.stdout.write.bind(process.stdout); process.stdout.write = () => true;
  try {
    await main(args, { git: GIT });
    assert.ok(existsSync(join(dir, 'e0/epoch.json')) && existsSync(join(dir, 'e0/manifest.json')));
    const m = JSON.parse(readFileSync(join(dir, 'e0/manifest.json'), 'utf8'));
    assert.equal(m.dataHash, ethers.utils.keccak256(readFileSync(join(dir, 'e0/epoch.json'))));
    assert.equal(m.forwardExternalRewardArguments.amount, m.publishTotal);
    await assert.rejects(main([...args, '--user-bps', '8000'], { git: GIT }), /exists and differs/);
  } finally { process.stdout.write = orig; }
  assert.throws(() => parseArgs(['--epoch-id', '0', '--first-epoch', '--to-harvest', '1', '--rpc-url', 'https://x.example']), /loopback/);
  assert.throws(() => parseArgs(['--epoch-id', '0', '--to-harvest', '1']), /exactly one/);
});

// OFFLINE tests of the LIVE NETWORK PATH of tools/dlmm-rewards-root.mjs (RpcSource: eth_getLogs in chunks, block timestamps, eth_getCode) and of --local-rpc.
// A fake JSON-RPC node on 127.0.0.1 serves the committed event fixture the way a node would (hex quantities, full block and log objects, a 100-block getLogs limit that REJECTS a wider
// request, a node that does not know old state for eth_getCode, transient errors) and the generator is run against it through its CLI entry point `main`. Nothing leaves the machine.
//   run from contracts/vault-dlmm:   node --test tools/rewards-test/dlmm-rewards-root.rpc.test.mjs     (ETHERS_DIR=<...>/node_modules/ethers if dlmm-keeper has no node_modules)
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { readFileSync, mkdtempSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as R from '../dlmm-rewards-root.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const FIX_DIR = join(HERE, '../../test/rewards/fixtures');
const FX = JSON.parse(readFileSync(join(FIX_DIR, 'events.fixture.json'), 'utf8'));
const EXPECTED_EPOCH = readFileSync(join(FIX_DIR, 'expected.epoch.json'), 'utf8');
const hex = (n) => `0x${BigInt(n).toString(16)}`;
const SAFE_LIKE = '0x0000000000000000000000000000000000c0De02';

/** opts: { anvil: true, chainId, maxRange, failEvery, noOldState, log: [] } */
async function fakeNode(opts = {}) {
  const o = { anvil: true, chainId: 43114, maxRange: 100, failEvery: 0, noOldState: false, ...opts };
  const seen = { methods: {}, ranges: [], codeCalls: [] };
  let n = 0;
  const handle = (method, params) => {
    seen.methods[method] = (seen.methods[method] ?? 0) + 1;
    if (o.failEvery && ++n % o.failEvery === 0) throw Object.assign(new Error('upstream hiccup'), { code: -32000 });
    switch (method) {
      case 'anvil_nodeInfo': if (!o.anvil) throw Object.assign(new Error('the method anvil_nodeInfo does not exist/is not available'), { code: -32601 }); return { currentBlockNumber: hex(FX.head) };
      case 'eth_chainId': return hex(o.chainId);
      case 'eth_blockNumber': return hex(FX.head);
      case 'eth_getLogs': {
        const f = params[0]; const from = Number(f.fromBlock); const to = Number(f.toBlock);
        seen.ranges.push([from, to]);
        if (to - from + 1 > o.maxRange) throw Object.assign(new Error('query returned more than the allowed range'), { code: -32005 });
        assert.equal(f.address.toLowerCase(), R.VAULT.toLowerCase());
        return FX.logs.filter((l) => l.blockNumber >= from && l.blockNumber <= to).map((l) => ({
          address: R.VAULT.toLowerCase(), blockNumber: hex(l.blockNumber), blockHash: R.ethers.utils.id(`block-${l.blockNumber}`), transactionIndex: '0x0', logIndex: hex(l.logIndex),
          transactionHash: l.transactionHash, topics: l.topics, data: l.data, removed: false,
        }));
      }
      case 'eth_getBlockByNumber': {
        const b = Number(params[0]); const m = FX.timeModel;
        const z = '0x' + '00'.repeat(32);
        return { number: hex(b), hash: R.ethers.utils.id(`block-${b}`), parentHash: z, nonce: '0x0000000000000000', sha3Uncles: z, logsBloom: '0x' + '00'.repeat(256), transactionsRoot: z, stateRoot: z, receiptsRoot: z,
          miner: '0x0000000000000000000000000000000000000000', difficulty: '0x1', totalDifficulty: '0x1', extraData: '0x', size: '0x1', gasLimit: '0xe4e1c0', gasUsed: '0x0', timestamp: hex(m.ts + (b - m.block) * m.interval), transactions: [], uncles: [] };
      }
      case 'eth_getCode': {
        const [a, blk] = params; seen.codeCalls.push([a.toLowerCase(), blk]);
        if (o.noOldState && blk !== 'latest') throw Object.assign(new Error('missing trie node (historical state not available)'), { code: -32000 });
        const c = FX.code?.[a] ?? FX.code?.[R.ethers.utils.getAddress(a)] ?? Object.entries(FX.code ?? {}).find(([k]) => k.toLowerCase() === a.toLowerCase())?.[1];
        return c ?? '0x';
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
  const url = `http://127.0.0.1:${server.address().port}`;
  return { url, seen, close: () => server.close() };
}
const cliArgs = (url, out, cache, extra = []) => ['--local-rpc', url, '--cache-dir', cache, '--out-dir', out, '--epoch-id', '2', '--scan-from', '1000', '--first-epoch', '--start-block', '2000', '--to-harvest', '3', '--allow-contract', SAFE_LIKE, ...extra];
const dirs = () => { const d = mkdtempSync(join(tmpdir(), 'rewards-rpc-')); return { out: join(d, 'out'), cache: join(d, 'cache') }; };
const TOOL = join(HERE, '../dlmm-rewards-root.mjs');
/** the real CLI in a child process (its output is captured): resolves { code, out, err } */
const cli = (args) => new Promise((resolve) => {
  const c = spawn(process.execPath, [TOOL, ...args], { env: { PATH: process.env.PATH, ETHERS_DIR: process.env.ETHERS_DIR ?? '' } });
  let out = ''; let err = ''; c.stdout.on('data', (d) => (out += d)); c.stderr.on('data', (d) => (err += d));
  c.on('close', (code) => resolve({ code, out, err }));
});

test('the RpcSource path (getLogs chunks of <= 100 blocks, block timestamps, eth_getCode) produces the byte-identical golden epoch.json of the fixture path; the manifest is flagged as a rehearsal output', async () => {
  const node = await fakeNode();
  try {
    const { out, cache } = dirs();
    const r = await cli(cliArgs(node.url, out, cache));
    assert.equal(r.code, 0, r.err);
    assert.match(r.err, /LOCAL ANVIL \(REHEARSAL\)/);
    assert.ok(!(r.out + r.err).includes('127.0.0.1'), 'the endpoint is never printed');
    assert.equal(readFileSync(join(out, 'epoch.json'), 'utf8'), EXPECTED_EPOCH, 'the live-path epoch.json must equal the fixture-path golden file byte for byte');
    const m = JSON.parse(readFileSync(join(out, 'manifest.json'), 'utf8'));
    assert.equal(m.rehearsalEndpoint, 'local-anvil');
    assert.ok(!JSON.stringify(m).includes('127.0.0.1') && !readFileSync(join(out, 'epoch.json'), 'utf8').includes('127.0.0.1'), 'the endpoint is in no output file');
    assert.ok(node.seen.ranges.length >= 10, 'many chunks');
    for (const [a, b] of node.seen.ranges) assert.ok(b - a + 1 <= 100, `chunk ${a}-${b}`);
    assert.ok(node.seen.codeCalls.length >= 1 && node.seen.codeCalls.every(([, blk]) => blk === hex(3000)), 'eth_getCode is asked at the epoch end block');
    assert.ok(existsSync(join(cache, `scan-43114-${R.VAULT.toLowerCase()}.json`)), 'the scan cache is in the explicit --cache-dir');
  } finally { node.close(); }
});

test('determinism through the network path: a second run with a FRESH cache and out dir gives the same bytes and the same dataHash; a resumed run (same cache) scans nothing new', async () => {
  const node = await fakeNode();
  try {
    const a = dirs(); const b = dirs();
    await cli(cliArgs(node.url, a.out, a.cache));
    const callsAfterFirst = node.seen.ranges.length;
    await cli(cliArgs(node.url, b.out, b.cache));
    assert.ok(node.seen.ranges.length > callsAfterFirst, 'the fresh cache rescans');
    const ta = readFileSync(join(a.out, 'epoch.json'), 'utf8');
    assert.equal(readFileSync(join(b.out, 'epoch.json'), 'utf8'), ta);
    assert.equal(JSON.parse(readFileSync(join(a.out, 'manifest.json'), 'utf8')).dataHash, JSON.parse(readFileSync(join(b.out, 'manifest.json'), 'utf8')).dataHash);
    const c = dirs(); // resumed: the cache of the first run, a new out dir
    const before = node.seen.ranges.length;
    await cli(cliArgs(node.url, c.out, a.cache));
    assert.equal(node.seen.ranges.length, before, 'the cache already covers the range');
    assert.equal(readFileSync(join(c.out, 'epoch.json'), 'utf8'), ta);
  } finally { node.close(); }
});

test('transient upstream errors are retried (every 7th call fails) and a node without old state falls back to the latest code, recorded per address (checkedAt)', async () => {
  const node = await fakeNode({ failEvery: 7, noOldState: true });
  try {
    const { out, cache } = dirs();
    const r = await cli(cliArgs(node.url, out, cache, ['--sleep-ms', '0']));
    assert.equal(r.code, 0, r.err);
    const e = JSON.parse(readFileSync(join(out, 'epoch.json'), 'utf8'));
    assert.ok(e.codeChecks.length > 0 && e.codeChecks.every((c) => c.checkedAt === 'latest'), 'every code check says latest');
    // same holders and amounts as the golden file; only the checkedAt fields differ
    const g = JSON.parse(EXPECTED_EPOCH);
    assert.equal(e.root, g.root);
  } finally { node.close(); }
}, { timeout: 120_000 });

test('--local-rpc refusals: not a loopback URL, credentials, a path, no explicit cache/out dir, a node that is not anvil, a node with another chain id', async () => {
  const base = ['--epoch-id', '1', '--scan-from', '10', '--first-epoch', '--to-harvest', '2'];
  for (const bad of ['https://api.avax.network/ext/bc/C/rpc', 'http://example.com:8545', 'http://127.0.0.1', 'http://user:pw@127.0.0.1:8545', 'http://127.0.0.1:8545/v2/key', 'http://127.0.0.1.evil.example:8545', 'ws://127.0.0.1:8545']) {
    assert.throws(() => R.parseArgs([...base, '--local-rpc', bad, '--cache-dir', 'c', '--out-dir', 'o']), /loopback/, bad);
  }
  assert.throws(() => R.parseArgs([...base, '--local-rpc', 'http://127.0.0.1:8545']), /explicit --cache-dir and --out-dir/);
  assert.throws(() => R.parseArgs([...base, '--local-rpc', 'http://127.0.0.1:8545', '--cache-dir', 'c']), /explicit --cache-dir and --out-dir/);
  assert.throws(() => R.parseArgs([...base, '--local-rpc', 'http://127.0.0.1:8545', '--cache-dir', 'c', '--out-dir', 'o', '--fixture', 'f.json']), /exclusive/);
  assert.equal(R.parseArgs([...base, '--local-rpc', 'http://localhost:8545', '--cache-dir', 'c', '--out-dir', 'o']).localRpc, 'http://localhost:8545');
  assert.throws(() => new R.RpcSource({ url: 'http://127.0.0.1:8545' }), /public endpoint/, 'the constructor refuses a local URL unless allowLocal is passed');
  assert.throws(() => new R.RpcSource({ url: 'http://example.com:8545', allowLocal: true }), /public endpoint/);
  const notAnvil = await fakeNode({ anvil: false });
  try {
    const { out, cache } = dirs();
    const r = await cli(cliArgs(notAnvil.url, out, cache));
    assert.equal(r.code, 1);
    assert.match(r.err, /anvil_nodeInfo/);
    assert.ok(!r.err.includes('127.0.0.1'));
    assert.ok(!existsSync(out), 'nothing was written');
  } finally { notAnvil.close(); }
  const wrongChain = await fakeNode({ chainId: 1 });
  try {
    const { out, cache } = dirs();
    const r = await cli(cliArgs(wrongChain.url, out, cache));
    assert.equal(r.code, 1);
    assert.match(r.err, /chain id is 1/);
  } finally { wrongChain.close(); }
});

test('the public-endpoint path is unchanged: no --local-rpc means the hard-wired endpoint, and the redaction hides any url in an error', async () => {
  assert.equal(R.PUBLIC_RPC, 'https://api.avax.network/ext/bc/C/rpc');
  const s = new R.RpcSource();
  assert.equal(s.local, false);
  assert.equal(R.redact('boom http://127.0.0.1:18545 end'), 'boom <url-redacted> end');
});

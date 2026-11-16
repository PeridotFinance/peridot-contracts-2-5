#!/usr/bin/env node
// Generator version: 2 (epochs are harvest-to-harvest, contracts/EIP-7702 handled, manifest + data hash). Off-chain root generator of the PHAR distribution (design A) for the Peridot Pharaoh DLMM USDC/USDt vault.
// Reads ONLY public data: the vault's ERC-20 Transfer events (the shares) and PharHarvested events, from the public Avalanche C-chain endpoint
// (no RPC url or key is ever taken from, or printed to, the environment). Computes every holder's TIME-WEIGHTED share balance over the epoch,
// splits the epoch's PHAR pro rata, and writes a deterministic JSON report plus the Merkle proofs file for contracts/vault-dlmm/src/rewards/PharRewardsDistributor.sol.
//
// Needs ethers v5 (the same as dlmm-keeper): resolved from ETHERS_DIR, from ./node_modules, or from ../../../dlmm-keeper/node_modules (run `npm ci` there once).
// Usage: see `node tools/dlmm-rewards-root.mjs --help` and docs/deployment-handoffs/avalanche-dlmm-vault-rewards-distribution.md.
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync, mkdirSync, renameSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// ---------------------------------------------------------------------------------------------------------------------------------- ethers
const HERE = dirname(fileURLToPath(import.meta.url));
function loadEthers() {
  const req = createRequire(import.meta.url);
  const candidates = [process.env.ETHERS_DIR, 'ethers', join(HERE, 'node_modules/ethers'), join(HERE, '../../../dlmm-keeper/node_modules/ethers')].filter(Boolean);
  let last;
  for (const c of candidates) {
    try { return req(c).ethers ?? req(c); } catch (e) { last = e; }
  }
  throw new Error(`ethers v5 not found (tried ETHERS_DIR, ethers, tools/node_modules, ../../../dlmm-keeper/node_modules): ${last?.message ?? ''}`);
}
const ethers = loadEthers();
const { utils } = ethers;
export { ethers };

// ---------------------------------------------------------------------------------------------------------------------------------- constants
export const PUBLIC_RPC = 'https://api.avax.network/ext/bc/C/rpc'; // the only endpoint this tool ever talks to
export const CHAIN_ID = 43114;
export const VAULT = '0x278B1b625C74B1926C5F989ddE601f3C5Ba27f7D';
export const PHAR = '0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7';
export const DEAD = '0x000000000000000000000000000000000000dEaD';
export const ZERO = '0x0000000000000000000000000000000000000000';
export const TRANSFER_TOPIC = utils.id('Transfer(address,address,uint256)');
export const HARVEST_TOPIC = utils.id('PharHarvested(address,uint256,uint256,uint256)');
export const SCHEMA = 'peridot-dlmm-rewards-epoch/2';
export const MANIFEST_SCHEMA = 'peridot-dlmm-rewards-manifest/2';
export const GENERATOR = { name: 'dlmm-rewards-root', version: '2.0.0' };
// The vault's first harvest-eligible block (openBand tx 0x58e31159ad11de27e80ed6871f00e53923077c1c18a5e31b07722ae25e8634ab): the default start of the FIRST epoch.
export const FIRST_EPOCH_START_BLOCK = 100488395;
export const DEFAULT_CHUNK = 100; // blocks per eth_getLogs call

// ---------------------------------------------------------------------------------------------------------------------------------- small helpers
export function redact(text) { return String(text).replace(/https?:\/\/[^\s"')]+/g, '<url-redacted>'); }
const lc = (a) => a.toLowerCase();
const addr = (a) => utils.getAddress(a);
const big = (x) => BigInt(x);
export const sleepReal = (ms) => new Promise((r) => setTimeout(r, ms));

export async function withRetry(fn, { retries = 8, baseMs = 500, maxMs = 30000, sleep = sleepReal, onRetry = () => {} } = {}) {
  for (let attempt = 0; ; attempt++) {
    try { return await fn(); } catch (e) {
      if (attempt >= retries) throw e;
      const wait = Math.min(maxMs, baseMs * 2 ** attempt) * (0.75 + 0.5 * pseudoRandom(attempt)); // jitter, no Math.random needed for determinism of tests
      onRetry(attempt + 1, wait, e);
      await sleep(wait);
    }
  }
}
let _seed = 0x9e3779b9;
function pseudoRandom(salt) { _seed = (Math.imul(_seed ^ (salt + 1), 0x85ebca6b) + 0xc2b2ae35) >>> 0; return (_seed % 1000) / 1000; }

// ---------------------------------------------------------------------------------------------------------------------------------- chain sources
/** A source answers: getHead(), getLogs({fromBlock,toBlock}) (the vault's Transfer + PharHarvested logs), getTimestamp(block). */
export class RpcSource {
  constructor({ url = PUBLIC_RPC, vault = VAULT } = {}) {
    if (url !== PUBLIC_RPC) throw new Error('only the public endpoint is allowed');
    this.provider = new ethers.providers.StaticJsonRpcProvider({ url, timeout: 30000 }, { chainId: CHAIN_ID, name: 'avalanche' });
    this.vault = vault;
  }
  async getHead() { return this.provider.getBlockNumber(); }
  async getLogs({ fromBlock, toBlock }) {
    const logs = await this.provider.getLogs({ address: this.vault, fromBlock, toBlock, topics: [[TRANSFER_TOPIC, HARVEST_TOPIC]] });
    return logs.map((l) => ({ blockNumber: l.blockNumber, logIndex: l.logIndex, transactionHash: l.transactionHash, topics: l.topics, data: l.data }));
  }
  /** Code of an address at `block`. The public endpoint may not serve old state: then (and only then) the latest code is used and `at` says so. */
  async getCode(address, block) {
    try { return { code: await this.provider.getCode(address, block), at: block }; } catch (e) {
      if (!/missing trie node|historical state|state .*(not available|pruned)|header not found|unknown block|not found/i.test(String(e?.message ?? e))) throw e;
      return { code: await this.provider.getCode(address, 'latest'), at: 'latest' };
    }
  }
  async getTimestamp(n) {
    const b = await this.provider.getBlock(n);
    if (!b) throw new Error(`block ${n} not found`);
    return b.timestamp;
  }
}

/** Wraps a source so that every call is retried with exponential back-off (the public endpoint rate-limits and drops calls). */
export function withBackoff(source, { sleep = sleepReal, log = () => {}, retries = 8 } = {}) {
  const wrap = (what, fn) => withRetry(fn, { retries, sleep, onRetry: (n, w, e) => log(`  retry ${n} of ${what} in ${Math.round(w)} ms: ${redact(e?.reason ?? e?.code ?? e?.message ?? e).slice(0, 120)}`) });
  return {
    getHead: () => wrap('head', () => source.getHead()),
    getLogs: (r) => wrap(`logs ${r.fromBlock}-${r.toBlock}`, () => source.getLogs(r)),
    getTimestamp: (n) => wrap(`block ${n}`, () => source.getTimestamp(n)),
    getCode: (a, b) => wrap(`code ${a}`, () => source.getCode(a, b)),
  };
}

/** Offline source over a fixture: { head, timeModel: {block, ts, interval}, timestamps?: {block: ts}, code?: {address: hex}, logs: [...] }. Used by the tests and for dry runs without network. */
export class FixtureSource {
  constructor(fx, { failFirst = 0 } = {}) { this.fx = fx; this.calls = []; this.failFirst = failFirst; this._fails = new Map(); this.tsCalls = 0; }
  async getHead() { return this.fx.head; }
  async getLogs({ fromBlock, toBlock }) {
    const key = `${fromBlock}-${toBlock}`;
    const n = this._fails.get(key) ?? 0;
    if (n < this.failFirst) { this._fails.set(key, n + 1); throw new Error('transient failure (fixture)'); }
    this.calls.push([fromBlock, toBlock]);
    return this.fx.logs.filter((l) => l.blockNumber >= fromBlock && l.blockNumber <= toBlock).map((l) => ({ ...l }));
  }
  async getCode(address, block) { return { code: this.fx.code?.[address] ?? this.fx.code?.[address.toLowerCase()] ?? '0x', at: block }; }
  async getTimestamp(n) {
    this.tsCalls++;
    const o = this.fx.timestamps?.[String(n)];
    if (o !== undefined) return o;
    const m = this.fx.timeModel; return m.ts + (n - m.block) * m.interval;
  }
}

// ---------------------------------------------------------------------------------------------------------------------------------- cache (resumable scan)
export class Cache {
  constructor(file) { this.file = file; this.data = { schema: 'peridot-dlmm-rewards-cache/1', vault: null, chainId: CHAIN_ID, fromBlock: null, scannedTo: null, logs: [], timestamps: {} }; }
  load(vault) {
    if (this.file && existsSync(this.file)) {
      const d = JSON.parse(readFileSync(this.file, 'utf8'));
      if (d.schema !== this.data.schema) throw new Error('cache file has another schema');
      if (lc(d.vault) !== lc(vault) || d.chainId !== CHAIN_ID) throw new Error('cache file belongs to another vault/chain; use another --cache-dir');
      this.data = d;
    } else this.data.vault = vault;
    return this;
  }
  save() {
    if (!this.file) return;
    mkdirSync(dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`;
    writeFileSync(tmp, JSON.stringify(this.data)); renameSync(tmp, this.file);
  }
}

/**
 * Scans from scanFrom in `chunk`-block pieces, appending to the cache and resuming after the last scanned block. Either to a known `endBlock`, or (endBlock null)
 * forward until `resolve(cacheLogs)` returns a block number (e.g. the block of the chosen harvest) or the chain head is reached. Returns the end block.
 */
export async function scanLogs({ source, cache, scanFrom, endBlock = null, head = null, resolve = null, chunk = DEFAULT_CHUNK, sleepMs = 0, sleep = sleepReal, log = () => {}, saveEvery = 25 }) {
  const c = cache.data;
  if (c.fromBlock !== null && c.fromBlock > scanFrom) throw new Error(`the cache starts at block ${c.fromBlock}, later than --scan-from ${scanFrom}: delete it or use another --cache-dir`);
  if (c.fromBlock === null) { c.fromBlock = scanFrom; c.scannedTo = scanFrom - 1; }
  // `resolve` is a stateful function fed with batches of logs (first the cached ones, then every new chunk) that returns the end block as soon as it is known
  let resolvedAt = resolve ? resolve(c.logs) : null;
  if (endBlock === null && resolvedAt !== null) endBlock = resolvedAt;
  const limit = () => endBlock ?? head;
  let next = Math.max(c.scannedTo + 1, scanFrom);
  if (endBlock !== null && next > endBlock) { log(`cache already covers up to block ${c.scannedTo}`); return endBlock; }
  if (endBlock === null && next > head) throw new Error('the chosen harvest was not found up to the chain head');
  log(`scanning from block ${next} to ${endBlock ?? 'the chosen harvest (or the head)'} in chunks of ${chunk}${c.scannedTo >= scanFrom ? ` (resuming after block ${c.scannedTo})` : ''}`);
  let done = 0;
  try {
    while (next <= limit()) {
      const to = Math.min(next + chunk - 1, limit());
      const logs = await source.getLogs({ fromBlock: next, toBlock: to });
      for (const l of logs) c.logs.push(l);
      c.scannedTo = to; next = to + 1; done++;
      if (endBlock === null && resolve) { const r = resolve(logs); if (r !== null) endBlock = r; }
      if (done % saveEvery === 0) { cache.save(); log(`  ${done} chunks, scanned to block ${c.scannedTo}, ${c.logs.length} logs`); }
      if (sleepMs) await sleep(sleepMs);
    }
  } finally { cache.save(); }
  log(`scan complete to block ${c.scannedTo}, ${c.logs.length} logs in the cache`);
  return endBlock;
}

// ---------------------------------------------------------------------------------------------------------------------------------- timestamps
export class Timestamps {
  constructor(source, cache) { this.source = source; this.map = cache?.data?.timestamps ?? {}; this.cache = cache; }
  async get(n) {
    const k = String(n);
    if (this.map[k] === undefined) this.map[k] = await this.source.getTimestamp(n);
    return this.map[k];
  }
  /** Smallest block whose timestamp is >= ts (binary search on a monotone block->time map), within [lo, hi]. */
  async blockAtOrAfter(ts, lo, hi) {
    if ((await this.get(hi)) < ts) throw new Error(`no block at or after timestamp ${ts} up to block ${hi}`);
    while (lo < hi) { const mid = Math.floor((lo + hi) / 2); if ((await this.get(mid)) >= ts) hi = mid; else lo = mid + 1; }
    return lo;
  }
  /** Largest block whose timestamp is <= ts. */
  async blockAtOrBefore(ts, lo, hi) {
    if ((await this.get(lo)) > ts) throw new Error(`no block at or before timestamp ${ts} from block ${lo}`);
    while (lo < hi) { const mid = Math.floor((lo + hi + 1) / 2); if ((await this.get(mid)) <= ts) lo = mid; else hi = mid - 1; }
    return lo;
  }
}

// ---------------------------------------------------------------------------------------------------------------------------------- event decoding
export function decodeLogs(rawLogs, { phar = PHAR } = {}) {
  const transfers = []; const harvests = [];
  for (const l of rawLogs) {
    const t0 = l.topics[0];
    if (t0 === TRANSFER_TOPIC && l.topics.length === 3) {
      transfers.push({ blockNumber: l.blockNumber, logIndex: l.logIndex, from: addr(utils.hexDataSlice(l.topics[1], 12)), to: addr(utils.hexDataSlice(l.topics[2], 12)), value: big(l.data) });
    } else if (t0 === HARVEST_TOPIC && l.topics.length === 2) {
      const token = addr(utils.hexDataSlice(l.topics[1], 12));
      if (lc(token) !== lc(phar)) continue;
      harvests.push({ blockNumber: l.blockNumber, logIndex: l.logIndex, txHash: l.transactionHash ?? null, amount: big(utils.hexDataSlice(l.data, 0, 32)) });
    }
  }
  const order = (a, b) => a.blockNumber - b.blockNumber || a.logIndex - b.logIndex;
  transfers.sort(order); harvests.sort(order);
  for (let i = 1; i < transfers.length; i++) if (order(transfers[i - 1], transfers[i]) === 0) throw new Error(`duplicate log position ${transfers[i].blockNumber}/${transfers[i].logIndex} (corrupt cache?)`);
  return { transfers, harvests };
}

// ---------------------------------------------------------------------------------------------------------------------------------- time weighted balances
/**
 * Balances are replayed from the first transfer. The epoch is the half-open block range (startBlock, endBlock]: events in blocks <= startBlock only build the
 * OPENING balances (state after block startBlock), events in (startBlock, endBlock] change balances at the timestamp of their block. A balance is integrated
 * over [t0, t1] with t0 = ts(startBlock), t1 = ts(endBlock): weight(holder) = sum over seconds of the holder's share balance. Same-block events are applied in
 * log order (they share one timestamp, so only the end state of a block counts). Mints (from 0x0) and burns (to 0x0) move the total supply.
 * Returns the weights of EVERY non-zero holder (the dead seed included) and the integral of the total supply, which must equal their sum.
 */
export function timeWeights({ transfers, startBlock, endBlock, t0, t1, ts }) {
  if (!(t1 > t0)) throw new Error(`the epoch has no duration (t0=${t0}, t1=${t1})`);
  const bal = new Map(); const last = new Map(); const weight = new Map();
  let supply = 0n; let supplyLast = t0; let supplyWeight = 0n;
  const touch = (a, T) => { weight.set(a, (weight.get(a) ?? 0n) + (bal.get(a) ?? 0n) * BigInt(T - (last.get(a) ?? t0))); last.set(a, T); };
  for (const e of transfers) {
    if (e.blockNumber > endBlock) break;
    const inWindow = e.blockNumber > startBlock;
    const T = inWindow ? ts(e.blockNumber) : t0;
    if (inWindow) {
      if (T < t0 || T > t1) throw new Error(`block ${e.blockNumber} has timestamp ${T} outside [${t0}, ${t1}]`);
      if (e.from !== ZERO) touch(e.from, T);
      if (e.to !== ZERO) touch(e.to, T);
      if (e.from === ZERO || e.to === ZERO) { supplyWeight += supply * BigInt(T - supplyLast); supplyLast = T; }
    }
    if (e.from !== ZERO) {
      const b = (bal.get(e.from) ?? 0n) - e.value;
      if (b < 0n) throw new Error(`negative balance for ${e.from} at block ${e.blockNumber}: the scan misses earlier history (use an earlier --scan-from)`);
      bal.set(e.from, b);
    } else supply += e.value;
    if (e.to !== ZERO) bal.set(e.to, (bal.get(e.to) ?? 0n) + e.value); else supply -= e.value;
  }
  let sumBal = 0n;
  for (const [a, b] of bal) { touch(a, t1); sumBal += b; }
  supplyWeight += supply * BigInt(t1 - supplyLast);
  const out = new Map(); let sumW = 0n;
  for (const [a, w] of weight) { if (w > 0n || (bal.get(a) ?? 0n) > 0n) out.set(a, w); sumW += w; }
  if (sumBal !== supply) throw new Error(`balances (${sumBal}) do not add up to the supply (${supply})`);
  if (sumW !== supplyWeight) throw new Error(`sum of weights ${sumW} != integral of the supply ${supplyWeight}`);
  const opening = new Map(); // balances at the end of the epoch for the report
  for (const [a, b] of bal) opening.set(a, b);
  return { weights: out, totalWeight: sumW, supplyAtEnd: supply, balancesAtEnd: opening };
}

/** Opening balances (after block startBlock), for the report. */
export function openingBalances(transfers, startBlock) {
  const bal = new Map();
  for (const e of transfers) {
    if (e.blockNumber > startBlock) break;
    if (e.from !== ZERO) bal.set(e.from, (bal.get(e.from) ?? 0n) - e.value);
    if (e.to !== ZERO) bal.set(e.to, (bal.get(e.to) ?? 0n) + e.value);
  }
  return bal;
}

// ---------------------------------------------------------------------------------------------------------------------------------- code classification
/** 'eoa' (no code), 'eoa-7702' (an EIP-7702 delegation designator: exactly 0xef0100 + a 20 byte address = 23 bytes, still an EOA) or 'contract'. */
export function classifyCode(code) {
  const hex = String(code ?? '0x').toLowerCase();
  if (hex === '0x' || hex === '') return 'eoa';
  if (/^0xef0100[0-9a-f]{40}$/.test(hex)) return 'eoa-7702';
  return 'contract';
}

// ---------------------------------------------------------------------------------------------------------------------------------- split
/**
 * pool = floor((harvested + extra) * userBps / 10000) is split pro rata over the TOTAL time-weighted supply: the weight of every excluded holder (the dead seed, the
 * zero address, the vault, contracts, explicit exclusions) stays in the denominator, their slice is simply not paid and stays with the Safe.
 * amount = floor(pool * weight / totalWeight); amounts below minAmount (default 1 wei) are dropped (dust).  `excluded` is a Map address -> reason.
 */
export function split({ weights, totalWeight, pharTotal, userBps, excluded, minAmount = 1n }) {
  if (userBps < 0 || userBps > 10000) throw new Error('--user-bps must be 0..10000');
  if (totalWeight <= 0n) throw new Error('no share was outstanding during the epoch');
  const pool = (pharTotal * BigInt(userBps)) / 10000n;
  const rows = []; let sumLeaves = 0n; let excludedSlice = 0n; let dust = 0n;
  for (const [a, w] of weights) {
    const would = (pool * w) / totalWeight;
    let status; let amount = 0n; const reason = excluded.get(a) ?? null;
    if (reason) { status = 'excluded'; excludedSlice += would; }
    else if (would === 0n) status = 'zero';
    else if (would < minAmount) { status = 'dust'; dust += would; }
    else { status = 'paid'; amount = would; sumLeaves += amount; }
    rows.push({ address: a, weight: w, would, amount, status, reason });
  }
  rows.sort((x, y) => (lc(x.address) < lc(y.address) ? -1 : 1));
  return { pool, rows, sumLeaves, excludedSlice, dust };
}

// ---------------------------------------------------------------------------------------------------------------------------------- merkle (same rules as OpenZeppelin MerkleProof + the contract's leaf)
export const leafHash = (epochId, account, amount) => utils.keccak256(utils.keccak256(utils.defaultAbiCoder.encode(['uint256', 'address', 'uint256'], [epochId, account, amount])));
export const hashPair = (a, b) => (lc(a) < lc(b) ? utils.keccak256(utils.concat([a, b])) : utils.keccak256(utils.concat([b, a])));
export function buildTree(leafHashes) {
  if (leafHashes.length === 0) throw new Error('no leaves');
  const layers = [leafHashes.slice()];
  while (layers[layers.length - 1].length > 1) {
    const l = layers[layers.length - 1]; const n = [];
    for (let i = 0; i < l.length; i += 2) n.push(i + 1 < l.length ? hashPair(l[i], l[i + 1]) : l[i]); // an unpaired node is promoted
    layers.push(n);
  }
  return { layers, root: layers[layers.length - 1][0] };
}
export function proofOf(layers, index) {
  const p = []; let i = index;
  for (let k = 0; k < layers.length - 1; k++) { const sib = i ^ 1; if (sib < layers[k].length) p.push(layers[k][sib]); i >>= 1; }
  return p;
}
export function verifyProof(proof, root, leaf) { let h = leaf; for (const s of proof) h = hashPair(h, s); return lc(h) === lc(root); }


// ---------------------------------------------------------------------------------------------------------------------------------- epoch boundaries (harvest blocks)
/** --to-harvest: a 0x...64 hex transaction hash of the harvest, or an integer N >= 1 = the N-th PharHarvested event after the start block. */
export function parseToHarvest(v) {
  const t = String(v ?? '');
  if (/^0x[0-9a-fA-F]{64}$/.test(t)) return { kind: 'tx', hash: lc(t) };
  if (/^[1-9]\d*$/.test(t)) return { kind: 'index', n: Number(t) };
  throw new Error('--to-harvest must be a transaction hash (0x + 64 hex) or an index >= 1 (the N-th harvest after the start block)');
}
/** A stateful resolver for scanLogs: fed with log batches, returns the block of the chosen harvest once seen (blocks <= startBlock never count). */
export function harvestResolver(startBlock, target) {
  const seen = []; const done = new Set();
  return (logs) => {
    for (const l of logs) {
      if (l.topics[0] !== HARVEST_TOPIC || l.blockNumber <= startBlock) continue;
      const key = `${l.blockNumber}/${l.logIndex}`; if (done.has(key)) continue; done.add(key);
      const d = decodeLogs([l]).harvests[0]; if (!d) continue; // another token
      seen.push(d);
    }
    seen.sort((a, b) => a.blockNumber - b.blockNumber || a.logIndex - b.logIndex);
    if (target.kind === 'tx') { const h = seen.find((x) => x.txHash && lc(x.txHash) === target.hash); return h ? h.blockNumber : null; }
    return seen.length >= target.n ? seen[target.n - 1].blockNumber : null;
  };
}

// ---------------------------------------------------------------------------------------------------------------------------------- report
const S = (x) => x.toString();
const sha = (text) => utils.keccak256(utils.toUtf8Bytes(text));
export const toJson = (o) => `${JSON.stringify(o, null, 2)}\n`;

export function buildEpoch({ params, window: w, harvest, weightsRes, splitRes, opening, exclusions, codeChecks }) {
  const { epochId, userBps, pharTotal, extraPhar, minAmount, vault, scanFrom, startBlock, endBlock, firstEpoch, previousEpochId, allowContract, explicitExclude } = params;
  const leavesSorted = splitRes.rows.filter((r) => r.status === 'paid').map((r) => ({ account: r.address, amount: r.amount, leaf: leafHash(epochId, r.address, r.amount) }));
  leavesSorted.sort((a, b) => (lc(a.leaf) < lc(b.leaf) ? -1 : 1));
  if (leavesSorted.length === 0) throw new Error('no holder earned anything: nothing to publish');
  const tree = buildTree(leavesSorted.map((l) => l.leaf));
  const leaves = leavesSorted.map((l, i) => ({ account: l.account, amount: S(l.amount), leaf: l.leaf, proof: proofOf(tree.layers, i) }));
  for (const c of leaves) if (!verifyProof(c.proof, tree.root, c.leaf)) throw new Error(`self-check failed: the proof of ${c.account} does not verify`);

  const publishTotal = splitRes.sumLeaves;
  const safeShare = pharTotal - splitRes.pool; // the (10000 - userBps)/10000 part
  const roundingAndDust = splitRes.pool - publishTotal - splitRes.excludedSlice;
  const exList = exclusions.map((e) => ({ address: e.address, reason: e.reason, weight: S(e.weight), returnedToSafe: S(e.would) }));
  const exTotal = exclusions.reduce((a, e) => a + e.would, 0n);
  const checks = {
    sumLeavesLePool: publishTotal <= splitRes.pool,
    poolLePharTimesBps: splitRes.pool * 10000n <= pharTotal * BigInt(userBps),
    sumLeavesLePharTimesBps: publishTotal * 10000n <= pharTotal * BigInt(userBps),
    weightsSumToSupplyIntegral: true, // timeWeights throws otherwise
    leavesUnique: new Set(leavesSorted.map((l) => lc(l.account))).size === leavesSorted.length,
    allProofsVerify: true, // throws above otherwise
    noZeroAmountLeaf: leavesSorted.every((l) => l.amount > 0n),
    noExcludedHolderHasALeaf: leavesSorted.every((l) => !exclusions.some((e) => lc(e.address) === lc(l.account))),
    exclusionSliceMatches: exTotal === splitRes.excludedSlice,
    balancesPartitionPharTotal: publishTotal + splitRes.excludedSlice + roundingAndDust + safeShare === pharTotal,
  };
  for (const [k, v] of Object.entries(checks)) if (!v) throw new Error(`check failed: ${k}`);
  const dur = BigInt(w.t1 - w.t0);
  const holders = splitRes.rows.map((r) => ({
    address: r.address,
    openingShares: S(opening.get(r.address) ?? 0n),
    closingShares: S(weightsRes.balancesAtEnd.get(r.address) ?? 0n),
    weight: S(r.weight), // share-seconds
    averageShares: S(r.weight / dur),
    amount: S(r.amount),
    status: r.status,
    excludedReason: r.reason,
    unpaidSlice: r.status === 'excluded' || r.status === 'dust' ? S(r.would) : '0',
  }));
  return {
    schema: SCHEMA,
    generator: GENERATOR,
    inputs: {
      chainId: CHAIN_ID, vault: addr(vault), epochId, firstEpoch, previousEpochId: previousEpochId ?? null, scanFromBlock: scanFrom, startBlock, endBlock,
      startTimestamp: w.t0, endTimestamp: w.t1, durationSeconds: w.t1 - w.t0, userBps,
      harvest: { sum: S(harvest.sum), count: harvest.count, transactions: harvest.txs.map((h) => ({ txHash: h.txHash, block: h.blockNumber, logIndex: h.logIndex, amount: S(h.amount) })) },
      extraPhar: S(extraPhar), pharTotal: S(pharTotal), minAmount: S(minAmount),
      allowContracts: allowContract.map(addr).sort(), explicitExcludes: explicitExclude.map(addr).sort(),
    },
    totals: {
      pool: S(splitRes.pool), publishTotal: S(publishTotal), leafCount: leaves.length,
      totalWeight: S(weightsRes.totalWeight), supplyAtEnd: S(weightsRes.supplyAtEnd),
      stayWithSafe: { total: S(pharTotal - publishTotal), safeShareOfBps: S(safeShare), excludedHoldersSlice: S(splitRes.excludedSlice), roundingAndDust: S(roundingAndDust) },
      droppedDust: S(splitRes.dust),
    },
    exclusions: { list: exList, listHash: sha(JSON.stringify(exList)), totalReturnedToSafe: S(exTotal) },
    codeChecks,
    checks,
    root: tree.root,
    holders,
    leaves,
  };
}

/** The manifest of an epoch: the metadata an operator publishes next to the data file. `uri` is a free string the operator fills in (never on chain). */
export function buildManifest({ epoch, text, uri = '', git = null }) {
  const i = epoch.inputs; const t = epoch.totals;
  return {
    schema: MANIFEST_SCHEMA,
    epochId: i.epochId, chainId: i.chainId, vault: i.vault,
    startBlock: i.startBlock, endBlock: i.endBlock, startTimestamp: i.startTimestamp, endTimestamp: i.endTimestamp,
    harvestTxHashes: i.harvest.transactions.map((h) => h.txHash),
    harvestSum: i.harvest.sum, extraPhar: i.extraPhar, pharTotal: i.pharTotal, userBps: i.userBps,
    publishTotal: t.publishTotal, leafCount: t.leafCount,
    generator: epoch.generator, gitCommit: git?.commit ?? null, gitDirty: git?.dirty ?? null,
    exclusionListHash: epoch.exclusions.listHash,
    dataFile: 'epoch.json', leavesFile: 'epoch.json', dataHash: sha(text), root: epoch.root,
    uri,
    publishEpochArguments: { root: epoch.root, total: t.publishTotal, fromBlock: i.startBlock, toBlock: i.endBlock, dataHash: sha(text) },
  };
}

// ---------------------------------------------------------------------------------------------------------------------------------- orchestration
export async function generate({ source: rawSource, cacheFile = null, args, previous = null, log = () => {}, sleep = sleepReal, git = null }) {
  const source = withBackoff(rawSource, { sleep, log });
  const { epochId, userBps, vault, scanFrom, minAmount, chunk, sleepMs } = args;
  const allow = (args.allowContract ?? []).map(addr); const explicit = (args.exclude ?? []).map(addr);
  const extraPhar = args.extraPhar ?? 0n;
  const head = await source.getHead();
  const cache = new Cache(cacheFile).load(vault);
  const ts = new Timestamps(source, cache);

  // ---- boundaries: (end block of the previous epoch, block of the chosen harvest]
  let startBlock; let previousEpochId = null;
  if (previous) {
    if (args.firstEpoch || args.startBlock !== undefined) throw new Error('--previous-manifest fixes the start block: do not give --first-epoch / --start-block');
    if (previous.schema !== MANIFEST_SCHEMA || lc(previous.vault) !== lc(vault) || previous.chainId !== CHAIN_ID) throw new Error('the previous manifest is not a manifest of this vault/chain');
    if (!(previous.epochId < epochId)) throw new Error('--epoch-id must be larger than the previous epoch id');
    startBlock = previous.endBlock; previousEpochId = previous.epochId;
  } else {
    if (!args.firstEpoch) throw new Error('give --previous-manifest <file> (every epoch after the first) or --first-epoch');
    startBlock = args.startBlock ?? FIRST_EPOCH_START_BLOCK;
  }
  if (!(scanFrom <= startBlock)) throw new Error(`--scan-from ${scanFrom} must be <= the start block ${startBlock}`);
  if (startBlock >= head) throw new Error(`the start block ${startBlock} is not below the chain head ${head}`);
  const target = parseToHarvest(args.toHarvest);
  const endBlock = await scanLogs({ source, cache, scanFrom, endBlock: null, head, resolve: harvestResolver(startBlock, target), chunk, sleepMs, sleep, log });
  if (endBlock === null) throw new Error('the chosen harvest was not found');
  if (!(endBlock > startBlock)) throw new Error('the chosen harvest is not after the start block');

  const { transfers, harvests } = decodeLogs(cache.data.logs.filter((l) => l.blockNumber >= scanFrom && l.blockNumber <= endBlock));
  if (previous && !harvests.some((h) => h.blockNumber === startBlock)) throw new Error(`the start block ${startBlock} (end of the previous epoch) has no PharHarvested event: boundaries must be harvest blocks`);
  const t0 = await ts.get(startBlock); const t1 = await ts.get(endBlock);
  for (const b of new Set(transfers.filter((e) => e.blockNumber > startBlock).map((e) => e.blockNumber))) await ts.get(b);
  cache.save();
  const weightsRes = timeWeights({ transfers, startBlock, endBlock, t0, t1, ts: (b) => ts.map[String(b)] });
  const hv = harvests.filter((h) => h.blockNumber > startBlock && h.blockNumber <= endBlock);
  const harvest = { sum: hv.reduce((a, h) => a + h.amount, 0n), count: hv.length, txs: hv };
  if (hv.length === 0) throw new Error('no harvest inside the epoch');
  const pharTotal = harvest.sum + extraPhar; // donated PHAR is NOT in the harvest sum: only an explicit --extra-phar adds it
  if (pharTotal === 0n) throw new Error('the PHAR total is 0: nothing to distribute');

  // ---- who cannot claim: zero (never a holder), the dead seed, the vault, explicit exclusions, contracts at the end block (EIP-7702 delegations count as EOAs)
  const excluded = new Map(); const codeChecks = [];
  for (const a of [...weightsRes.weights.keys()].sort((x, y) => (lc(x) < lc(y) ? -1 : 1))) {
    if (lc(a) === lc(DEAD)) { excluded.set(a, 'dead-seed'); continue; }
    if (lc(a) === lc(vault)) { excluded.set(a, 'vault'); continue; }
    if (explicit.some((x) => lc(x) === lc(a))) { excluded.set(a, 'explicit'); continue; }
    const { code, at } = await source.getCode(a, endBlock);
    const cls = classifyCode(code);
    const allowed = allow.some((x) => lc(x) === lc(a));
    codeChecks.push({ address: a, class: cls, checkedAt: at, allowed: cls === 'contract' && allowed });
    if (cls === 'contract' && !allowed) excluded.set(a, 'contract');
  }
  const splitRes = split({ weights: weightsRes.weights, totalWeight: weightsRes.totalWeight, pharTotal, userBps, excluded, minAmount });
  const exclusions = splitRes.rows.filter((r) => r.status === 'excluded');
  const opening = openingBalances(transfers, startBlock);
  const epoch = buildEpoch({
    params: { epochId, userBps, pharTotal, extraPhar, minAmount, vault, scanFrom, startBlock, endBlock, firstEpoch: !previous, previousEpochId, allowContract: allow, explicitExclude: explicit },
    window: { t0, t1 }, harvest, weightsRes, splitRes, opening, exclusions, codeChecks,
  });
  const text = toJson(epoch);
  return { epoch, text, manifest: buildManifest({ epoch, text, uri: args.uri ?? '', git }) };
}

// ---------------------------------------------------------------------------------------------------------------------------------- CLI
const HELP = `dlmm-rewards-root.mjs: time-weighted PHAR split of the Pharaoh DLMM vault shares -> Merkle root + proofs + manifest (design A)

  node tools/dlmm-rewards-root.mjs --epoch-id N --scan-from B0 (--first-epoch | --previous-manifest FILE) --to-harvest (TXHASH | N) [options]

  An epoch is the block range (start, end]; BOTH boundaries are harvest blocks (the first epoch starts at the vault's first harvest-eligible block).
  required
    --epoch-id N            the id the NEXT publishEpoch will get: cast call <distributor> 'epochCount()(uint256)'   (it is inside every leaf)
    --scan-from B0          first block to replay Transfer events from: the vault's deployment block, so that every opening balance is known
    --first-epoch           the first epoch: starts at block ${FIRST_EPOCH_START_BLOCK} (openBand, tx 0x58e31159...34ab) unless --start-block says otherwise
    --previous-manifest F   every later epoch: starts at the endBlock of that epoch's manifest.json (a harvest block). Exactly one of the two.
    --to-harvest X          the epoch ends at the block of this PharHarvested: a transaction hash, or an index N >= 1 = the N-th harvest after the start block.
                            Every harvest in (start, end] is included (an epoch may span several). PHAR total = the sum of their amounts.
  options
    --out-dir DIR           writes DIR/epoch.json (the hashed data file: inputs, exclusions, holders, leaves WITH proofs) and DIR/manifest.json (default epochs/<N>)
    --uri STRING            free text for manifest.uri (where the operator hosts the files; never on chain)      --force   overwrite an existing, different epoch.json
    --user-bps N            share of PHAR for holders, 0..10000 (default 9000); written into epoch.json, so it is on chain only as part of dataHash
    --extra-phar WEI        PHAR to add to the harvested sum (e.g. donated PHAR the operator decides to distribute); shown separately; default 0
    --allow-contract ADDR   a contract that may claim (e.g. a Safe): repeatable. Every other holder with code at the end block is excluded (EIP-7702 designators are EOAs).
    --exclude ADDR          more holders with no entitlement (repeatable). ALWAYS excluded: 0x0, 0x...dEaD, the vault itself. Their slice returns to the Safe.
    --min-amount WEI        drop leaves below this (default 1)           --vault ADDR      default ${VAULT}
    --start-block N         with --first-epoch only: another first start block   --cache-dir DIR   resumable cache (default ./rewards-cache)
    --chunk N               blocks per getLogs call (default ${DEFAULT_CHUNK})   --sleep-ms N      pause between chunks   --fixture FILE   offline: events from a fixture
  Network: only ${PUBLIC_RPC} (hard-wired; no environment variable is read, no URL is printed).
`;

export function parseArgs(argv) {
  const a = { userBps: 9000, exclude: [], allowContract: [], extraPhar: 0n, minAmount: 1n, vault: VAULT, chunk: DEFAULT_CHUNK, sleepMs: 0, cacheDir: './rewards-cache', firstEpoch: false, uri: '', force: false };
  const need = (i, name) => { if (i + 1 >= argv.length) throw new Error(`${name} needs a value`); return argv[i + 1]; };
  const int = (v, name) => { if (!/^\d+$/.test(v)) throw new Error(`${name} must be a non-negative integer`); return Number(v); };
  const wei = (v, name) => { if (!/^\d+$/.test(v)) throw new Error(`${name} is an integer in wei`); return BigInt(v); };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    switch (k) {
      case '--help': case '-h': a.help = true; break;
      case '--epoch-id': a.epochId = int(need(i++, k), k); break;
      case '--scan-from': a.scanFrom = int(need(i++, k), k); break;
      case '--first-epoch': a.firstEpoch = true; break;
      case '--previous-manifest': a.previousManifest = need(i++, k); break;
      case '--start-block': a.startBlock = int(need(i++, k), k); break;
      case '--to-harvest': a.toHarvest = need(i++, k); break;
      case '--user-bps': a.userBps = int(need(i++, k), k); break;
      case '--extra-phar': a.extraPhar = wei(need(i++, k), k); break;
      case '--allow-contract': a.allowContract.push(addr(need(i++, k))); break;
      case '--exclude': a.exclude.push(addr(need(i++, k))); break;
      case '--min-amount': a.minAmount = wei(need(i++, k), k); break;
      case '--vault': a.vault = addr(need(i++, k)); break;
      case '--cache-dir': a.cacheDir = need(i++, k); break;
      case '--chunk': a.chunk = int(need(i++, k), k); if (a.chunk < 1) throw new Error('--chunk must be >= 1'); break;
      case '--sleep-ms': a.sleepMs = int(need(i++, k), k); break;
      case '--out-dir': a.outDir = need(i++, k); break;
      case '--uri': a.uri = need(i++, k); break;
      case '--force': a.force = true; break;
      case '--fixture': a.fixture = need(i++, k); break;
      default: throw new Error(`unknown argument ${redact(k)} (an RPC url, an end block and a PHAR amount are deliberately not options)`);
    }
  }
  if (a.help) return a;
  for (const [k, n] of [['epochId', '--epoch-id'], ['scanFrom', '--scan-from'], ['toHarvest', '--to-harvest']]) if (a[k] === undefined) throw new Error(`${n} is required`);
  parseToHarvest(a.toHarvest);
  if (a.firstEpoch === (a.previousManifest !== undefined)) throw new Error('give exactly one of --first-epoch / --previous-manifest');
  if (a.startBlock !== undefined && !a.firstEpoch) throw new Error('--start-block is only for --first-epoch');
  if (a.userBps > 10000) throw new Error('--user-bps must be 0..10000');
  return a;
}

export async function main(argv, { git = undefined } = {}) {
  const args = parseArgs(argv);
  if (args.help) { process.stdout.write(HELP); return 0; }
  const log = (m) => process.stderr.write(`${redact(m)}\n`);
  let source; let cacheFile;
  if (args.fixture) { source = new FixtureSource(JSON.parse(readFileSync(args.fixture, 'utf8'))); cacheFile = null; }
  else { source = new RpcSource({ vault: args.vault }); cacheFile = resolve(args.cacheDir, `scan-${CHAIN_ID}-${lc(args.vault)}.json`); }
  const previous = args.previousManifest ? JSON.parse(readFileSync(args.previousManifest, 'utf8')) : null;
  const gitInfo = git !== undefined ? git : gitState();
  const { epoch, text, manifest } = await generate({ source, cacheFile, args, previous, log, git: gitInfo });
  const dir = resolve(args.outDir ?? join('epochs', String(args.epochId)));
  const dataFile = join(dir, 'epoch.json');
  if (existsSync(dataFile) && readFileSync(dataFile, 'utf8') !== text && !args.force) throw new Error(`${dataFile} exists and differs (a published epoch file must not change): use another --out-dir or --force`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(dataFile, text); writeFileSync(join(dir, 'manifest.json'), toJson(manifest));
  const t = epoch.totals; const i = epoch.inputs; const pa = manifest.publishEpochArguments;
  process.stdout.write([
    `epoch ${i.epochId}: blocks (${i.startBlock}, ${i.endBlock}] = ${i.durationSeconds} s, ${i.harvest.count} harvest(s) = ${i.harvest.sum} wei PHAR${i.extraPhar !== '0' ? ` + extra ${i.extraPhar}` : ''} = ${i.pharTotal}, user-bps ${i.userBps}`,
    `root ${epoch.root}`,
    `leaves ${t.leafCount}, PUBLISH TOTAL (sum of leaves) ${t.publishTotal} wei, pool ${t.pool}`,
    `stays with the Safe: ${t.stayWithSafe.total} = bps part ${t.stayWithSafe.safeShareOfBps} + excluded holders ${t.stayWithSafe.excludedHoldersSlice} (${epoch.exclusions.list.length} address(es), hash ${epoch.exclusions.listHash}) + rounding/dust ${t.stayWithSafe.roundingAndDust}`,
    `checks: ${Object.entries(epoch.checks).map(([k, v]) => `${k}=${v}`).join(' ')}`,
    `dataHash ${manifest.dataHash}`,
    `publishEpoch(${pa.root}, ${pa.total}, ${pa.fromBlock}, ${pa.toBlock}, ${pa.dataHash})`,
    `wrote ${dataFile} and ${join(dir, 'manifest.json')} (set manifest.uri when hosting; the files must be published BEFORE publishEpoch)`, '',
  ].join('\n'));
  return 0;
}

function gitState() {
  try {
    const run = (a) => execFileSync('git', a, { cwd: HERE, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    return { commit: run(['rev-parse', 'HEAD']), dirty: run(['status', '--porcelain', '--', 'dlmm-rewards-root.mjs']) !== '' };
  } catch { return null; }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).then((c) => process.exit(c), (e) => { process.stderr.write(`ERROR: ${redact(e?.message ?? e)}\n`); process.exit(1); });
}

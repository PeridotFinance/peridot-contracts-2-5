#!/usr/bin/env node
// Root generator of the RAM distribution of the Robinhood Chain (4663) Ramses SPY/USDG vault (port of the Avalanche design A
// generator dlmm-rewards-root.mjs, branch feat/dlmm-rewards-distributor).
//
// Reads ONLY public events (state on the public endpoint is pruned after ~10 minutes; events are retained):
//   - the vault's ExternalRewardHeld(pair, RAM, amount)  -> the RAM of the epoch (sum over the epoch's block range)
//   - the vault's PairCheckpoint(pair, ...)              -> the USD split of the vault principal between the two markets
//   - ERC-20 Transfer of the two side markets rpSPY / rpUSDGs (pTokens; mint = Transfer(market -> minter), redeem and the
//     protocol seize share = Transfer(holder -> market))
// and writes a deterministic epoch.json (inputs, per-market weights, exclusions, leaves WITH proofs, root) and manifest.json
// for contracts/robinhood-rewards/src/MerkleRewardsDistributor.sol.
//
// Entitlement rule (README section 3): every ExternalRewardHeld amount is split between the two markets by the USD value of
// the vault principal of each side at that moment, read from the PairCheckpoint emitted just before it (the harvest
// transaction checkpoints first): usdgUSD = usdgAccountedAssets * 1e12 (USDG is valued at 1e18 by the guard),
// stockUSD = benchmarkUSDG + pnlUSDG - usdgUSD (= value of the post-checkpoint principals in all three checkpoint branches).
// Inside a market, USER_BPS of its RAM is split pro rata over the market's TIME-WEIGHTED pToken supply (share-seconds over
// [ts(start), ts(end)]). Excluded holders stay in the denominator; their slice, the (10000 - USER_BPS) part, rounding and dust
// go to ONE protocol leaf, so the published total equals the forwarded RAM exactly.
//
// Needs ethers v5: ETHERS_DIR, ./node_modules, or contracts/node_modules of the main checkout.
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync, mkdirSync, renameSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
function loadEthers() {
  const req = createRequire(import.meta.url);
  const candidates = [process.env.ETHERS_DIR, 'ethers', join(HERE, 'node_modules/ethers'), join(HERE, '../../node_modules/ethers'),
    join(HERE, '../../../../peridot-contracts-2-5/contracts/node_modules/ethers')].filter(Boolean);
  let last;
  for (const c of candidates) {
    try { const m = req(c); const e = m.ethers ?? m; if (e.utils && e.providers) return e; } catch (e) { last = e; }
  }
  throw new Error(`ethers v5 not found (set ETHERS_DIR): ${last?.message ?? ''}`);
}
const ethers = loadEthers();
const { utils } = ethers;
export { ethers };

// ------------------------------------------------------------------------------------------------------------- constants
export const PUBLIC_RPC = 'https://rpc.mainnet.chain.robinhood.com';
export const CHAIN_ID = 4663;
export const VAULT = '0x67e7742922f4CC88C545e5aB5Df402b22DB4830b';
export const PAIR = '0x8f81f5d84aa85b29b5114b8ca1a75266c4dc18785b703e8257ca66ecb4ba5435';
export const RAM = '0x5173D45A1191eE33cBB7D8c7e65f21B04eD54802';
export const STOCK_MARKET = '0x14CC6fE0AE856B736fAb6678619cEd3d4738EA8B'; // rpSPY
export const DOLLAR_MARKET = '0x2117c202F356399C9aE2D395D4e155785015ac6B'; // rpUSDGs
export const TIMELOCK = '0x6797FB8Ce049B42C5BC2b42Bf76c6d15C7B12498';
export const LEDGER = '0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD';
export const OLD_SIGNER = '0x94696d767e65a75581145646960FA0eC886cE5d2'; // compromised 2026-11-05: never a recipient
export const DEAD = '0x000000000000000000000000000000000000dEaD';
export const ZERO = '0x0000000000000000000000000000000000000000';
export const USDG_DECIMALS = 6;
// Vault proxy creation block (tx 0x4157505e...fc73 at 110177000); the markets were created at 110177262/110177285.
export const SCAN_FROM = 110177000;
// Robinhood contracts of the SPY/USDG deployment (journal spy-usdg-mainnet.json): named reasons in the exclusion list.
export const KNOWN_CONTRACTS = {
  [VAULT]: 'vault', '0x1E8eAE33d7c2Fc5E8061476099bE2b9E930DA2CC': 'vault-router', '0x128eF69e4D697291BA88F45544f49B85Ac6ac1a7': 'in-kind-redeemer',
  '0x92740aEC3ac91AEC3b964b04233e005FCDd75778': 'loss-reserve', '0x0C6e8a9f43aAB3D6Be780Ac3778a0EDE525da6bE': 'adapter',
  '0xA322CB665B69732F3Ab6A0136bc636EAF81927a3': 'controller', '0xC35bA3864245Bf89F95Af315100Dd65EBFD5E5cd': 'coverage-guard',
  '0x27D44914976640bc9176AcF112D538513D04498d': 'extension', '0xdaF7672706076e9da1ad6104E0D43f9EeD6cA494': 'oracle-guard',
  [STOCK_MARKET]: 'market', [DOLLAR_MARKET]: 'market', [TIMELOCK]: 'timelock',
};
export const TRANSFER_TOPIC = utils.id('Transfer(address,address,uint256)');
export const HELD_TOPIC = utils.id('ExternalRewardHeld(bytes32,address,uint256)');
export const CHECKPOINT_TOPIC = utils.id('PairCheckpoint(bytes32,uint256,uint256,uint256,int256,uint256,uint256)');
export const SCHEMA = 'peridot-robinhood-ram-epoch/1';
export const MANIFEST_SCHEMA = 'peridot-robinhood-ram-manifest/1';
export const GENERATOR = { name: 'robinhood-ram-root', version: '1.0.0' };
export const DEFAULT_CHUNK = 2_000_000; // L2 blocks per eth_getLogs call (0.1 s blocks; halves on error)

// ------------------------------------------------------------------------------------------------------------- helpers
export function redact(text) { return String(text).replace(/https?:\/\/[^\s"')]+/g, '<url-redacted>'); }
const lc = (a) => a.toLowerCase();
const addr = (a) => utils.getAddress(a);
const big = (x) => BigInt(x);
const S = (x) => x.toString();
const sameAddr = (a, b) => lc(a) === lc(b);
export const sleepReal = (ms) => new Promise((r) => setTimeout(r, ms));
export const MARKETS = [{ key: 'stock', name: 'rpSPY', address: STOCK_MARKET }, { key: 'dollar', name: 'rpUSDGs', address: DOLLAR_MARKET }];

/** Only the public endpoint, or a loopback anvil fork (rehearsal). Never a URL with credentials. */
export function checkRpcUrl(url) {
  if (url === PUBLIC_RPC) return url;
  let u; try { u = new URL(url); } catch { throw new Error('--rpc-url is not a URL'); }
  if (u.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(u.hostname) || u.username || u.password) {
    throw new Error('--rpc-url may only be the public endpoint or a loopback http fork (rehearsal)');
  }
  return url;
}

export async function withRetry(fn, { retries = 6, baseMs = 500, maxMs = 20000, sleep = sleepReal, onRetry = () => {} } = {}) {
  for (let attempt = 0; ; attempt++) {
    try { return await fn(); } catch (e) {
      if (attempt >= retries) throw e;
      const wait = Math.min(maxMs, baseMs * 2 ** attempt);
      onRetry(attempt + 1, wait, e);
      await sleep(wait);
    }
  }
}

// ------------------------------------------------------------------------------------------------------------- sources
const QUERIES = [[VAULT, HELD_TOPIC], [VAULT, CHECKPOINT_TOPIC], [STOCK_MARKET, TRANSFER_TOPIC], [DOLLAR_MARKET, TRANSFER_TOPIC]];
const order = (a, b) => a.blockNumber - b.blockNumber || a.logIndex - b.logIndex;
const slim = (l) => ({ address: addr(l.address), blockNumber: l.blockNumber, logIndex: l.logIndex, transactionHash: l.transactionHash, topics: l.topics, data: l.data });

export class RpcSource {
  constructor({ url = PUBLIC_RPC } = {}) {
    checkRpcUrl(url);
    this.provider = new ethers.providers.StaticJsonRpcProvider({ url, timeout: 60000 }, { chainId: CHAIN_ID, name: 'robinhood' });
  }
  async getChainId() { return (await this.provider.getNetwork()).chainId; }
  async getHead() { return this.provider.getBlockNumber(); }
  /** One query per (address, topic0): the public endpoint allows a wide range only with "one value per position" (a
   *  multi-address / multi-topic filter is limited to 100,000 blocks). */
  async getLogs({ fromBlock, toBlock }) {
    const out = [];
    for (const [address, topic] of QUERIES) {
      const logs = await this.provider.send('eth_getLogs', [{ address, topics: [topic], fromBlock: utils.hexValue(fromBlock), toBlock: utils.hexValue(toBlock) }]);
      for (const l of logs) out.push(slim({ ...l, blockNumber: Number(l.blockNumber), logIndex: Number(l.logIndex) }));
    }
    return out.sort(order);
  }
  /** Code at `block`; the public endpoint prunes state after ~10 minutes, so it falls back to the latest code and says so. */
  async getCode(address, block) {
    try { return { code: await this.provider.getCode(address, block), at: block }; } catch (e) {
      if (!/missing trie node|historical state|state .*(not available|pruned)|header not found|unknown block|not found|pruned/i.test(String(e?.message ?? e) + String(e?.body ?? ''))) throw e;
      return { code: await this.provider.getCode(address, 'latest'), at: 'latest' };
    }
  }
  async getTimestamp(n) {
    const b = await this.provider.send('eth_getBlockByNumber', [utils.hexValue(n), false]);
    if (!b) throw new Error(`block ${n} not found`);
    return Number(b.timestamp);
  }
}

export function withBackoff(source, { sleep = sleepReal, log = () => {}, retries = 6 } = {}) {
  const wrap = (what, fn, r = retries) => withRetry(fn, { retries: r, sleep, onRetry: (n, w, e) => log(`  retry ${n} of ${what} in ${Math.round(w)} ms: ${redact(e?.reason ?? e?.code ?? e?.message ?? e).slice(0, 120)}`) });
  return {
    getChainId: () => wrap('chainId', () => source.getChainId()),
    getHead: () => wrap('head', () => source.getHead()),
    // few retries per range: a range that keeps failing is split in two by scanLogs (log-count / range limits)
    getLogs: (r) => wrap(`logs ${r.fromBlock}-${r.toBlock}`, () => source.getLogs(r), r.toBlock > r.fromBlock ? 1 : retries),
    getTimestamp: (n) => wrap(`block ${n}`, () => source.getTimestamp(n)),
    getCode: (a, b) => wrap(`code ${a}`, () => source.getCode(a, b)),
  };
}

/** Offline source: { chainId?, head, timeModel: {block, ts, interval}, timestamps?, code?, logs, maxRange? }. */
export class FixtureSource {
  constructor(fx) { this.fx = fx; this.calls = []; }
  async getChainId() { return this.fx.chainId ?? CHAIN_ID; }
  async getHead() { return this.fx.head; }
  async getLogs({ fromBlock, toBlock }) {
    if (this.fx.maxRange && toBlock - fromBlock + 1 > this.fx.maxRange) throw new Error('query exceeds max block range (fixture)');
    this.calls.push([fromBlock, toBlock]);
    return this.fx.logs.filter((l) => l.blockNumber >= fromBlock && l.blockNumber <= toBlock).map((l) => ({ ...l }));
  }
  async getCode(address) { const c = Object.fromEntries(Object.entries(this.fx.code ?? {}).map(([k, v]) => [lc(k), v])); return { code: c[lc(address)] ?? '0x', at: 'latest' }; }
  async getTimestamp(n) {
    const o = this.fx.timestamps?.[String(n)];
    if (o !== undefined) return o;
    const m = this.fx.timeModel; return m.ts + Math.floor((n - m.block) * m.interval);
  }
}

// ------------------------------------------------------------------------------------------------------------- cache
export class Cache {
  constructor(file) { this.file = file; this.data = { schema: 'peridot-robinhood-ram-cache/1', chainId: CHAIN_ID, vault: VAULT, fromBlock: null, scannedTo: null, logs: [], timestamps: {} }; }
  load() {
    if (this.file && existsSync(this.file)) {
      const d = JSON.parse(readFileSync(this.file, 'utf8'));
      if (d.schema !== this.data.schema || d.chainId !== CHAIN_ID || !sameAddr(d.vault, VAULT)) throw new Error('the cache file belongs to another schema/chain/vault');
      this.data = d;
    }
    return this;
  }
  save() {
    if (!this.file) return;
    mkdirSync(dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`; writeFileSync(tmp, JSON.stringify(this.data)); renameSync(tmp, this.file);
  }
}

/** getLogs over [from, to], splitting a failing range in halves down to one block. */
export async function getLogsSplitting(source, from, to, log = () => {}) {
  try { return await source.getLogs({ fromBlock: from, toBlock: to }); } catch (e) {
    if (to <= from) throw e;
    const mid = Math.floor((from + to) / 2);
    log(`  range ${from}-${to} failed (${redact(e?.message ?? e).slice(0, 80)}); splitting`);
    return [...await getLogsSplitting(source, from, mid, log), ...await getLogsSplitting(source, mid + 1, to, log)];
  }
}

/** Scans [scanFrom, endBlock] in chunks (resumable through the cache). */
export async function scanLogs({ source, cache, scanFrom, endBlock, chunk = DEFAULT_CHUNK, log = () => {} }) {
  const c = cache.data;
  if (c.fromBlock !== null && c.fromBlock > scanFrom) throw new Error(`the cache starts at block ${c.fromBlock}, later than --scan-from ${scanFrom}: use another --cache-dir`);
  if (c.fromBlock === null) { c.fromBlock = scanFrom; c.scannedTo = scanFrom - 1; }
  let next = Math.max(c.scannedTo + 1, scanFrom);
  if (next > endBlock) { log(`cache already covers block ${c.scannedTo}`); return; }
  log(`scanning blocks ${next}..${endBlock} in chunks of ${chunk}`);
  try {
    while (next <= endBlock) {
      const to = Math.min(next + chunk - 1, endBlock);
      const logs = await getLogsSplitting(source, next, to, log);
      const seen = new Set(c.logs.map((l) => `${l.blockNumber}/${l.logIndex}`));
      for (const l of logs) if (!seen.has(`${l.blockNumber}/${l.logIndex}`)) c.logs.push(l);
      c.scannedTo = to; next = to + 1;
    }
  } finally { cache.save(); }
  log(`scan complete to block ${c.scannedTo}, ${c.logs.length} logs cached`);
}

// ------------------------------------------------------------------------------------------------------------- decoding
const word = (data, i) => big(utils.hexDataSlice(data, 32 * i, 32 * (i + 1)));
const sword = (data, i) => BigInt.asIntN(256, word(data, i));
const topicAddr = (t) => addr(utils.hexDataSlice(t, 12));

export function decodeLogs(rawLogs) {
  const transfers = { stock: [], dollar: [] }; const held = []; const checkpoints = [];
  for (const l of rawLogs) {
    const t0 = l.topics[0];
    const from = addr(l.address);
    if (t0 === TRANSFER_TOPIC && l.topics.length === 3) {
      const m = MARKETS.find((x) => sameAddr(x.address, from)); if (!m) continue;
      transfers[m.key].push({ blockNumber: l.blockNumber, logIndex: l.logIndex, from: topicAddr(l.topics[1]), to: topicAddr(l.topics[2]), value: word(l.data, 0) });
    } else if (t0 === HELD_TOPIC && sameAddr(from, VAULT) && l.topics.length === 3) {
      if (lc(l.topics[1]) !== lc(PAIR) || !sameAddr(topicAddr(l.topics[2]), RAM)) continue;
      held.push({ blockNumber: l.blockNumber, logIndex: l.logIndex, txHash: l.transactionHash ?? null, amount: word(l.data, 0) });
    } else if (t0 === CHECKPOINT_TOPIC && sameAddr(from, VAULT) && l.topics.length === 2) {
      if (lc(l.topics[1]) !== lc(PAIR)) continue;
      checkpoints.push({ blockNumber: l.blockNumber, logIndex: l.logIndex, txHash: l.transactionHash ?? null, benchmark: word(l.data, 2), pnl: sword(l.data, 3), stockPrincipal: word(l.data, 4), usdgPrincipal: word(l.data, 5) });
    }
  }
  for (const k of Object.keys(transfers)) transfers[k].sort(order);
  held.sort(order); checkpoints.sort(order);
  for (const list of [...Object.values(transfers), held, checkpoints]) {
    for (let i = 1; i < list.length; i++) if (order(list[i - 1], list[i]) === 0) throw new Error(`duplicate log position ${list[i].blockNumber}/${list[i].logIndex}`);
  }
  return { transfers, held, checkpoints };
}

// ------------------------------------------------------------------------------------------------------------- market split
/** USD18 values of the two sides from a PairCheckpoint: value(post principals) = benchmark + pnl in all three branches. */
export function sideValues(cp) {
  const usdgUSD = cp.usdgPrincipal * 10n ** BigInt(18 - USDG_DECIMALS);
  const total = cp.benchmark + cp.pnl;
  const stockUSD = total > usdgUSD ? total - usdgUSD : 0n;
  return { stockUSD, usdgUSD };
}

/** Splits every held amount between the markets by the latest PairCheckpoint at or before it. */
export function splitHeld(held, checkpoints) {
  const rows = []; let stock = 0n; let dollar = 0n; let unattributed = 0n;
  for (const h of held) {
    let cp = null;
    for (const c of checkpoints) { if (order(c, h) < 0) cp = c; else break; }
    let s = 0n; let d = 0n; let u = 0n; let sv = { stockUSD: 0n, usdgUSD: 0n };
    if (cp) sv = sideValues(cp);
    const denom = sv.stockUSD + sv.usdgUSD;
    if (denom === 0n) u = h.amount; else { s = (h.amount * sv.stockUSD) / denom; d = h.amount - s; }
    stock += s; dollar += d; unattributed += u;
    rows.push({ txHash: h.txHash, block: h.blockNumber, logIndex: h.logIndex, amount: S(h.amount),
      checkpoint: cp ? { txHash: cp.txHash, block: cp.blockNumber, logIndex: cp.logIndex, benchmarkUSD18: S(cp.benchmark), pnlUSD18: S(cp.pnl), stockPrincipal: S(cp.stockPrincipal), usdgPrincipal: S(cp.usdgPrincipal) } : null,
      stockUSD18: S(sv.stockUSD), usdgUSD18: S(sv.usdgUSD), toStockMarket: S(s), toDollarMarket: S(d), unattributed: S(u) });
  }
  return { rows, stock, dollar, unattributed };
}

// ------------------------------------------------------------------------------------------------------------- time weights
/**
 * pToken balances replayed from the first Transfer. The market address itself is the mint/burn sentinel (Compound semantics),
 * as is the zero address. Epoch = (startBlock, endBlock]; weights integrate balances over [t0, t1].
 */
export function timeWeights({ transfers, market, startBlock, endBlock, t0, t1, ts }) {
  if (!(t1 > t0)) throw new Error(`the epoch has no duration (t0=${t0}, t1=${t1})`);
  const isSentinel = (a) => a === ZERO || sameAddr(a, market);
  const bal = new Map(); const last = new Map(); const weight = new Map();
  let supply = 0n; let supplyLast = t0; let supplyWeight = 0n;
  const touch = (a, T) => { weight.set(a, (weight.get(a) ?? 0n) + (bal.get(a) ?? 0n) * BigInt(T - (last.get(a) ?? t0))); last.set(a, T); };
  for (const e of transfers) {
    if (e.blockNumber > endBlock) break;
    const inWindow = e.blockNumber > startBlock;
    const T = inWindow ? ts(e.blockNumber) : t0;
    const fromS = isSentinel(e.from); const toS = isSentinel(e.to);
    if (fromS && toS) continue;
    if (inWindow) {
      if (T < t0 || T > t1) throw new Error(`block ${e.blockNumber} has timestamp ${T} outside [${t0}, ${t1}]`);
      if (!fromS) touch(e.from, T);
      if (!toS) touch(e.to, T);
      if (fromS || toS) { supplyWeight += supply * BigInt(T - supplyLast); supplyLast = T; }
    }
    if (!fromS) {
      const b = (bal.get(e.from) ?? 0n) - e.value;
      if (b < 0n) throw new Error(`negative balance for ${e.from} at block ${e.blockNumber}: the scan misses earlier history`);
      bal.set(e.from, b);
    } else supply += e.value;
    if (!toS) bal.set(e.to, (bal.get(e.to) ?? 0n) + e.value); else supply -= e.value;
  }
  let sumBal = 0n;
  for (const [a, b] of bal) { touch(a, t1); sumBal += b; }
  supplyWeight += supply * BigInt(t1 - supplyLast);
  const out = new Map(); let sumW = 0n;
  for (const [a, w] of weight) { if (w > 0n || (bal.get(a) ?? 0n) > 0n) out.set(a, w); sumW += w; }
  if (sumBal !== supply) throw new Error(`balances (${sumBal}) do not add up to the supply (${supply})`);
  if (sumW !== supplyWeight) throw new Error(`sum of weights ${sumW} != integral of the supply ${supplyWeight}`);
  return { weights: out, totalWeight: sumW, supplyAtEnd: supply, balancesAtEnd: new Map(bal) };
}

export function openingBalances(transfers, market, startBlock) {
  const bal = new Map(); const isSentinel = (a) => a === ZERO || sameAddr(a, market);
  for (const e of transfers) {
    if (e.blockNumber > startBlock) break;
    if (!isSentinel(e.from)) bal.set(e.from, (bal.get(e.from) ?? 0n) - e.value);
    if (!isSentinel(e.to)) bal.set(e.to, (bal.get(e.to) ?? 0n) + e.value);
  }
  return bal;
}

export function classifyCode(code) {
  const hex = String(code ?? '0x').toLowerCase();
  if (hex === '0x' || hex === '') return 'eoa';
  if (/^0xef0100[0-9a-f]{40}$/.test(hex)) return 'eoa-7702';
  return 'contract';
}

/** pool = floor(marketReward * userBps / 10000) over the TOTAL time-weighted supply; excluded weights stay in the denominator. */
export function splitMarket({ weights, totalWeight, reward, userBps, excluded, minAmount = 1n }) {
  const pool = totalWeight > 0n ? (reward * BigInt(userBps)) / 10000n : 0n;
  const rows = []; let paid = 0n; let excludedSlice = 0n; let dust = 0n;
  for (const [a, w] of weights) {
    const would = totalWeight > 0n ? (pool * w) / totalWeight : 0n;
    const reason = excluded.get(a) ?? null; let status; let amount = 0n;
    if (reason) { status = 'excluded'; excludedSlice += would; }
    else if (would === 0n) status = 'zero';
    else if (would < minAmount) { status = 'dust'; dust += would; }
    else { status = 'paid'; amount = would; paid += amount; }
    rows.push({ address: a, weight: w, would, amount, status, reason });
  }
  rows.sort((x, y) => (lc(x.address) < lc(y.address) ? -1 : 1));
  return { pool, rows, paid, excludedSlice, dust, rounding: pool - paid - excludedSlice - dust };
}

// ------------------------------------------------------------------------------------------------------------- merkle
export const leafHash = (epochId, account, amount) => utils.keccak256(utils.keccak256(utils.defaultAbiCoder.encode(['uint256', 'address', 'uint256'], [epochId, account, amount])));
export const hashPair = (a, b) => (lc(a) < lc(b) ? utils.keccak256(utils.concat([a, b])) : utils.keccak256(utils.concat([b, a])));
export function buildTree(leafHashes) {
  if (leafHashes.length === 0) throw new Error('no leaves');
  const layers = [leafHashes.slice()];
  while (layers[layers.length - 1].length > 1) {
    const l = layers[layers.length - 1]; const n = [];
    for (let i = 0; i < l.length; i += 2) n.push(i + 1 < l.length ? hashPair(l[i], l[i + 1]) : l[i]);
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

// ------------------------------------------------------------------------------------------------------------- boundaries
export function parseToHarvest(v) {
  const t = String(v ?? '');
  if (/^0x[0-9a-fA-F]{64}$/.test(t)) return { kind: 'tx', hash: lc(t) };
  if (/^[1-9]\d*$/.test(t)) return { kind: 'index', n: Number(t) };
  if (t === 'last') return { kind: 'last' };
  throw new Error('--to-harvest must be a transaction hash, an index N >= 1 (N-th RAM ExternalRewardHeld after the start block) or "last"');
}

export function resolveEnd(held, startBlock, target) {
  const after = held.filter((h) => h.blockNumber > startBlock);
  let h = null;
  if (target.kind === 'tx') h = after.find((x) => x.txHash && lc(x.txHash) === target.hash) ?? null;
  else if (target.kind === 'index') h = after[target.n - 1] ?? null;
  else h = after[after.length - 1] ?? null;
  if (!h) throw new Error('the chosen RAM ExternalRewardHeld event was not found after the start block (up to the scanned head)');
  return h.blockNumber;
}

// ------------------------------------------------------------------------------------------------------------- report
const sha = (text) => utils.keccak256(utils.toUtf8Bytes(text));
export const toJson = (o) => `${JSON.stringify(o, null, 2)}\n`;

export function buildManifest({ epoch, text, uri = '', git = null }) {
  const i = epoch.inputs; const t = epoch.totals;
  return {
    schema: MANIFEST_SCHEMA, epochId: i.epochId, chainId: i.chainId, vault: i.vault, pair: i.pair, rewardToken: i.rewardToken,
    startBlock: i.startBlock, endBlock: i.endBlock, startTimestamp: i.startTimestamp, endTimestamp: i.endTimestamp,
    heldTxHashes: [...new Set(i.held.map((h) => h.txHash))], heldSum: t.heldSum, extraReward: i.extraReward, userBps: i.userBps,
    protocolRecipient: i.protocolRecipient, publishTotal: t.publishTotal, leafCount: t.leafCount,
    forwardExternalRewardArguments: { pairId: i.pair, token: i.rewardToken, receiver: '<distributor>', amount: t.heldSum },
    generator: epoch.generator, gitCommit: git?.commit ?? null, gitDirty: git?.dirty ?? null,
    exclusionListHash: epoch.exclusions.listHash, dataFile: 'epoch.json', dataHash: sha(text), root: epoch.root, uri,
    publishEpochArguments: { root: epoch.root, total: t.publishTotal, fromBlock: i.startBlock, toBlock: i.endBlock, dataHash: sha(text) },
  };
}

// ------------------------------------------------------------------------------------------------------------- orchestration
export async function generate({ source: rawSource, cacheFile = null, args, previous = null, log = () => {}, sleep = sleepReal, git = null }) {
  const source = withBackoff(rawSource, { sleep, log });
  const { epochId, userBps, minAmount } = args;
  const scanFrom = args.scanFrom ?? SCAN_FROM;
  const protocolRecipient = addr(args.protocolRecipient ?? LEDGER);
  const allow = (args.allowContract ?? []).map(addr); const explicit = (args.exclude ?? []).map(addr);
  const extraReward = args.extraReward ?? 0n;
  if (sameAddr(protocolRecipient, OLD_SIGNER) || allow.some((a) => sameAddr(a, OLD_SIGNER))) throw new Error('the old signer 0x9469...e5d2 can never be a recipient');
  if (protocolRecipient === ZERO || sameAddr(protocolRecipient, DEAD)) throw new Error('the protocol recipient must be a real account');
  if (!(userBps >= 0 && userBps <= 10000)) throw new Error('--user-bps must be 0..10000');
  const chainId = await source.getChainId();
  if (chainId !== CHAIN_ID) throw new Error(`the endpoint is chain ${chainId}, not ${CHAIN_ID}`);
  const head = await source.getHead();
  const cache = new Cache(cacheFile).load();
  const tsMap = cache.data.timestamps;
  const ts = async (n) => { const k = String(n); if (tsMap[k] === undefined) tsMap[k] = await source.getTimestamp(n); return tsMap[k]; };

  let startBlock; let previousEpochId = null;
  if (previous) {
    if (args.firstEpoch || args.startBlock !== undefined) throw new Error('--previous-manifest fixes the start block');
    if (previous.schema !== MANIFEST_SCHEMA || !sameAddr(previous.vault, VAULT) || previous.chainId !== CHAIN_ID || lc(previous.pair) !== lc(PAIR)) throw new Error('the previous manifest is not one of this vault/pair/chain');
    if (!(previous.epochId < epochId)) throw new Error('--epoch-id must be larger than the previous epoch id');
    startBlock = previous.endBlock; previousEpochId = previous.epochId;
  } else {
    if (!args.firstEpoch) throw new Error('give --previous-manifest <file> or --first-epoch');
    startBlock = args.startBlock ?? scanFrom;
  }
  if (!(scanFrom <= startBlock)) throw new Error(`--scan-from ${scanFrom} must be <= the start block ${startBlock}`);
  if (startBlock >= head) throw new Error(`the start block ${startBlock} is not below the head ${head}`);
  const scanTo = args.scanTo ?? head;
  await scanLogs({ source, cache, scanFrom, endBlock: scanTo, chunk: args.chunk ?? DEFAULT_CHUNK, log });
  const all = decodeLogs(cache.data.logs.filter((l) => l.blockNumber >= scanFrom && l.blockNumber <= scanTo));
  const endBlock = resolveEnd(all.held, startBlock, parseToHarvest(args.toHarvest));
  if (previous && !all.held.some((h) => h.blockNumber === startBlock)) throw new Error(`the start block ${startBlock} has no RAM ExternalRewardHeld: boundaries must be harvest blocks`);

  const held = all.held.filter((h) => h.blockNumber > startBlock && h.blockNumber <= endBlock);
  const checkpoints = all.checkpoints.filter((c) => c.blockNumber <= endBlock);
  const heldSum = held.reduce((a, h) => a + h.amount, 0n);
  if (heldSum + extraReward === 0n) throw new Error('nothing to distribute (held sum and extra are 0)');
  const marketSplit = splitHeld(held, checkpoints);

  const t0 = await ts(startBlock); const t1 = await ts(endBlock);
  const markets = [];
  const holderAmount = new Map(); // account -> total over both markets
  const exclusions = []; const codeChecks = []; const codeCache = new Map();
  const classify = async (a) => {
    if (codeCache.has(lc(a))) return codeCache.get(lc(a));
    const { code, at } = await source.getCode(a, endBlock); const cls = classifyCode(code);
    const r = { cls, at }; codeCache.set(lc(a), r); codeChecks.push({ address: a, class: cls, checkedAt: at, allowed: cls === 'contract' && allow.some((x) => sameAddr(x, a)) });
    return r;
  };
  for (const m of MARKETS) {
    const transfers = all.transfers[m.key].filter((e) => e.blockNumber <= endBlock);
    for (const b of new Set(transfers.filter((e) => e.blockNumber > startBlock).map((e) => e.blockNumber))) await ts(b);
    const w = timeWeights({ transfers, market: m.address, startBlock, endBlock, t0, t1, ts: (b) => tsMap[String(b)] });
    const reward = m.key === 'stock' ? marketSplit.stock : marketSplit.dollar;
    const excluded = new Map();
    for (const a of [...w.weights.keys()].sort((x, y) => (lc(x) < lc(y) ? -1 : 1))) {
      const known = Object.entries(KNOWN_CONTRACTS).find(([k]) => sameAddr(k, a));
      if (sameAddr(a, DEAD)) { excluded.set(a, 'dead-seed'); continue; }
      if (sameAddr(a, OLD_SIGNER)) { excluded.set(a, 'old-signer-never-paid'); continue; }
      if (known && !allow.some((x) => sameAddr(x, a))) { excluded.set(a, known[1]); continue; }
      if (explicit.some((x) => sameAddr(x, a))) { excluded.set(a, 'explicit'); continue; }
      const { cls } = await classify(a);
      if (cls === 'contract' && !allow.some((x) => sameAddr(x, a))) excluded.set(a, 'contract');
    }
    const sp = splitMarket({ weights: w.weights, totalWeight: w.totalWeight, reward, userBps, excluded, minAmount });
    for (const r of sp.rows) if (r.status === 'paid') holderAmount.set(r.address, (holderAmount.get(r.address) ?? 0n) + r.amount);
    for (const r of sp.rows) if (r.status === 'excluded') exclusions.push({ market: m.name, address: r.address, reason: r.reason, weight: S(r.weight), toProtocol: S(r.would) });
    const opening = openingBalances(transfers, m.address, startBlock);
    const dur = BigInt(t1 - t0);
    markets.push({
      name: m.name, address: m.address, reward: S(reward), pool: S(sp.pool), protocolPart: S(reward - sp.pool), paidToHolders: S(sp.paid),
      excludedSlice: S(sp.excludedSlice), dust: S(sp.dust), rounding: S(sp.rounding), totalWeight: S(w.totalWeight), supplyAtEnd: S(w.supplyAtEnd),
      noSupply: w.totalWeight === 0n,
      holders: sp.rows.map((r) => ({ address: r.address, openingShares: S(opening.get(r.address) ?? 0n), closingShares: S(w.balancesAtEnd.get(r.address) ?? 0n),
        weight: S(r.weight), averageShares: S(r.weight / dur), amount: S(r.amount), status: r.status, excludedReason: r.reason, unpaidSlice: r.status === 'excluded' || r.status === 'dust' ? S(r.would) : '0' })),
      _sp: sp,
    });
  }

  // ---- leaves: one per account (holder amounts over both markets); the protocol recipient takes everything else
  const publishTotal = heldSum + extraReward;
  let holdersTotal = 0n; for (const v of holderAmount.values()) holdersTotal += v;
  const protocolHolderPart = holderAmount.get(protocolRecipient) ?? [...holderAmount.entries()].find(([k]) => sameAddr(k, protocolRecipient))?.[1] ?? 0n;
  const protocolShare = publishTotal - holdersTotal; // (10000 - bps) part + excluded + rounding/dust + unattributed + extra
  const amounts = new Map(holderAmount);
  const pKey = [...amounts.keys()].find((k) => sameAddr(k, protocolRecipient)) ?? protocolRecipient;
  amounts.set(pKey, protocolHolderPart + protocolShare);
  const leavesSorted = [...amounts.entries()].filter(([, v]) => v > 0n).map(([a, v]) => ({ account: addr(a), amount: v, leaf: leafHash(epochId, a, v) }));
  leavesSorted.sort((a, b) => (lc(a.leaf) < lc(b.leaf) ? -1 : 1));
  const tree = buildTree(leavesSorted.map((l) => l.leaf));
  const leaves = leavesSorted.map((l, i) => ({ account: l.account, amount: S(l.amount), leaf: l.leaf, proof: proofOf(tree.layers, i) }));
  for (const c of leaves) if (!verifyProof(c.proof, tree.root, c.leaf)) throw new Error(`self-check failed for ${c.account}`);

  const sum = (f) => markets.reduce((a, m) => a + f(m._sp), 0n);
  const protocolBreakdown = {
    bpsPart: S(markets.reduce((a, m) => a + (big(m.reward) - m._sp.pool), 0n)), excludedHolders: S(sum((s) => s.excludedSlice)),
    roundingAndDust: S(sum((s) => s.rounding + s.dust)), unattributed: S(marketSplit.unattributed), extraReward: S(extraReward),
    asHolder: S(protocolHolderPart), leafTotal: S(protocolHolderPart + protocolShare),
  };
  const exList = exclusions.sort((a, b) => (a.market + lc(a.address) < b.market + lc(b.address) ? -1 : 1));
  const checks = {
    leavesSumToPublishTotal: leavesSorted.reduce((a, l) => a + l.amount, 0n) === publishTotal,
    publishTotalIsHeldPlusExtra: publishTotal === heldSum + extraReward,
    marketSplitPartitionsHeld: marketSplit.stock + marketSplit.dollar + marketSplit.unattributed === heldSum,
    holdersWithinPools: markets.every((m) => m._sp.paid <= m._sp.pool) && holdersTotal <= sum((s) => s.pool),
    poolsWithinBps: markets.every((m) => m._sp.pool * 10000n <= big(m.reward) * BigInt(userBps)),
    protocolPartsAddUp: big(protocolBreakdown.bpsPart) + big(protocolBreakdown.excludedHolders) + big(protocolBreakdown.roundingAndDust) + marketSplit.unattributed + extraReward === protocolShare,
    leavesUnique: new Set(leavesSorted.map((l) => lc(l.account))).size === leavesSorted.length,
    noZeroLeaf: leavesSorted.every((l) => l.amount > 0n),
    noLeafForAnExcludedHolderExceptTheProtocolRecipient: leavesSorted.every((l) => sameAddr(l.account, protocolRecipient) || !exList.some((e) => sameAddr(e.address, l.account))),
    oldSignerHasNoLeaf: !leavesSorted.some((l) => sameAddr(l.account, OLD_SIGNER)),
    allProofsVerify: true,
  };
  for (const [k, v] of Object.entries(checks)) if (!v) throw new Error(`check failed: ${k}`);
  for (const m of markets) delete m._sp;

  const epoch = {
    schema: SCHEMA, generator: GENERATOR,
    inputs: {
      chainId: CHAIN_ID, vault: VAULT, pair: PAIR, rewardToken: RAM, markets: MARKETS.map((m) => ({ name: m.name, address: m.address })),
      epochId, firstEpoch: !previous, previousEpochId, scanFromBlock: scanFrom, startBlock, endBlock, startTimestamp: t0, endTimestamp: t1,
      durationSeconds: t1 - t0, userBps, protocolRecipient, extraReward: S(extraReward), minAmount: S(minAmount ?? 1n),
      allowContracts: allow.sort(), explicitExcludes: explicit.sort(),
      rule: 'held RAM split between markets by side principal USD at the preceding PairCheckpoint (usdg*1e12 vs benchmark+pnl-usdg*1e12); userBps of each market over time-weighted pToken supply; rest to protocolRecipient',
      held: marketSplit.rows,
    },
    totals: { heldSum: S(heldSum), publishTotal: S(publishTotal), toStockMarket: S(marketSplit.stock), toDollarMarket: S(marketSplit.dollar),
      unattributed: S(marketSplit.unattributed), holdersTotal: S(holdersTotal), protocol: protocolBreakdown, leafCount: leaves.length },
    markets,
    exclusions: { list: exList, listHash: sha(JSON.stringify(exList)) },
    codeChecks: codeChecks.sort((a, b) => (lc(a.address) < lc(b.address) ? -1 : 1)),
    checks, root: tree.root, leaves,
  };
  const text = toJson(epoch);
  return { epoch, text, manifest: buildManifest({ epoch, text, uri: args.uri ?? '', git }) };
}

// ------------------------------------------------------------------------------------------------------------- CLI
const HELP = `robinhood-ram-root.mjs: RAM split of the Ramses SPY/USDG vault -> Merkle root + proofs + manifest

  node tools/robinhood-ram-root.mjs --epoch-id N (--first-epoch | --previous-manifest FILE) --to-harvest (TXHASH | N | last) [options]

  An epoch is the L2 block range (start, end]; end is the block of a RAM ExternalRewardHeld of the pair (a harvest).
  required
    --epoch-id N            cast call <distributor> 'epochCount()(uint256)'  (inside every leaf)
    --first-epoch           starts at --start-block (default --scan-from = ${SCAN_FROM}, vault creation)
    --previous-manifest F   starts at that manifest's endBlock
    --to-harvest X          tx hash, N-th RAM ExternalRewardHeld after start, or "last" (latest scanned)
  options
    --user-bps N            share for depositors, 0..10000 (default 9000)
    --protocol-recipient A  gets the rest in ONE leaf (default the Ledger ${LEDGER}); the old signer is refused
    --extra-reward WEI      RAM already unallocated in the distributor (swept/cancelled) added to the protocol leaf; default 0
    --allow-contract A / --exclude A   (repeatable)        --min-amount WEI (default 1)
    --scan-from B / --scan-to B (default head)   --chunk N (default ${DEFAULT_CHUNK})   --cache-dir DIR   --out-dir DIR   --uri S   --force
    --rpc-url URL           ONLY a loopback http anvil fork (rehearsal); default the public endpoint ${PUBLIC_RPC}
    --fixture FILE          offline: events from a fixture
`;

export function parseArgs(argv) {
  const a = { userBps: 9000, exclude: [], allowContract: [], extraReward: 0n, minAmount: 1n, chunk: DEFAULT_CHUNK, cacheDir: './ram-rewards-cache', firstEpoch: false, uri: '', force: false, rpcUrl: PUBLIC_RPC };
  const need = (i, name) => { if (i + 1 >= argv.length) throw new Error(`${name} needs a value`); return argv[i + 1]; };
  const int = (v, name) => { if (!/^\d+$/.test(v)) throw new Error(`${name} must be a non-negative integer`); return Number(v); };
  const wei = (v, name) => { if (!/^\d+$/.test(v)) throw new Error(`${name} is an integer in wei`); return BigInt(v); };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    switch (k) {
      case '--help': case '-h': a.help = true; break;
      case '--epoch-id': a.epochId = int(need(i++, k), k); break;
      case '--first-epoch': a.firstEpoch = true; break;
      case '--previous-manifest': a.previousManifest = need(i++, k); break;
      case '--start-block': a.startBlock = int(need(i++, k), k); break;
      case '--to-harvest': a.toHarvest = need(i++, k); break;
      case '--user-bps': a.userBps = int(need(i++, k), k); break;
      case '--protocol-recipient': a.protocolRecipient = addr(need(i++, k)); break;
      case '--extra-reward': a.extraReward = wei(need(i++, k), k); break;
      case '--allow-contract': a.allowContract.push(addr(need(i++, k))); break;
      case '--exclude': a.exclude.push(addr(need(i++, k))); break;
      case '--min-amount': a.minAmount = wei(need(i++, k), k); break;
      case '--scan-from': a.scanFrom = int(need(i++, k), k); break;
      case '--scan-to': a.scanTo = int(need(i++, k), k); break;
      case '--chunk': a.chunk = int(need(i++, k), k); if (a.chunk < 1) throw new Error('--chunk must be >= 1'); break;
      case '--cache-dir': a.cacheDir = need(i++, k); break;
      case '--out-dir': a.outDir = need(i++, k); break;
      case '--uri': a.uri = need(i++, k); break;
      case '--force': a.force = true; break;
      case '--rpc-url': a.rpcUrl = checkRpcUrl(need(i++, k)); break;
      case '--fixture': a.fixture = need(i++, k); break;
      default: throw new Error(`unknown argument ${redact(k)}`);
    }
  }
  if (a.help) return a;
  for (const [k, n] of [['epochId', '--epoch-id'], ['toHarvest', '--to-harvest']]) if (a[k] === undefined) throw new Error(`${n} is required`);
  parseToHarvest(a.toHarvest);
  if (a.firstEpoch === (a.previousManifest !== undefined)) throw new Error('give exactly one of --first-epoch / --previous-manifest');
  if (a.startBlock !== undefined && !a.firstEpoch) throw new Error('--start-block is only for --first-epoch');
  if (a.userBps > 10000) throw new Error('--user-bps must be 0..10000');
  if (a.protocolRecipient && sameAddr(a.protocolRecipient, OLD_SIGNER)) throw new Error('the old signer 0x9469...e5d2 can never be a recipient');
  return a;
}

export async function main(argv, { git = undefined } = {}) {
  const args = parseArgs(argv);
  if (args.help) { process.stdout.write(HELP); return 0; }
  const log = (m) => process.stderr.write(`${redact(m)}\n`);
  let source; let cacheFile = null;
  if (args.fixture) source = new FixtureSource(JSON.parse(readFileSync(args.fixture, 'utf8')));
  else {
    source = new RpcSource({ url: args.rpcUrl });
    const tag = args.rpcUrl === PUBLIC_RPC ? 'public' : 'fork';
    cacheFile = resolve(args.cacheDir, `scan-${CHAIN_ID}-${tag}-${lc(VAULT)}.json`);
  }
  const previous = args.previousManifest ? JSON.parse(readFileSync(args.previousManifest, 'utf8')) : null;
  const { epoch, text, manifest } = await generate({ source, cacheFile, args, previous, log, git: git !== undefined ? git : gitState() });
  const dir = resolve(args.outDir ?? join('epochs', String(args.epochId)));
  const dataFile = join(dir, 'epoch.json');
  if (existsSync(dataFile) && readFileSync(dataFile, 'utf8') !== text && !args.force) throw new Error(`${dataFile} exists and differs: use another --out-dir or --force`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(dataFile, text); writeFileSync(join(dir, 'manifest.json'), toJson(manifest));
  const t = epoch.totals; const i = epoch.inputs; const pa = manifest.publishEpochArguments;
  process.stdout.write([
    `epoch ${i.epochId}: blocks (${i.startBlock}, ${i.endBlock}] = ${i.durationSeconds} s, ${i.held.length} RAM harvest event(s) = ${t.heldSum} wei, user-bps ${i.userBps}`,
    `market split: rpSPY ${t.toStockMarket}, rpUSDGs ${t.toDollarMarket}, unattributed ${t.unattributed}`,
    ...epoch.markets.map((m) => `  ${m.name}: reward ${m.reward}, pool ${m.pool}, paid to holders ${m.paidToHolders}, excluded slice ${m.excludedSlice}${m.noSupply ? ' (no supply)' : ''}`),
    `holders ${t.holdersTotal}; protocol leaf ${t.protocol.leafTotal} to ${i.protocolRecipient} (bps part ${t.protocol.bpsPart}, excluded ${t.protocol.excludedHolders}, rounding/dust ${t.protocol.roundingAndDust}, unattributed ${t.protocol.unattributed}, extra ${t.protocol.extraReward})`,
    `exclusions ${epoch.exclusions.list.map((e) => `${e.market}:${e.address}:${e.reason}`).join(' ')}`,
    `root ${epoch.root}`, `leaves ${t.leafCount}, PUBLISH TOTAL ${t.publishTotal}`,
    `checks: ${Object.entries(epoch.checks).map(([k, v]) => `${k}=${v}`).join(' ')}`,
    `forwardExternalReward(${i.pair}, ${i.rewardToken}, <distributor>, ${t.heldSum})`,
    `dataHash ${manifest.dataHash}`,
    `publishEpoch(${pa.root}, ${pa.total}, ${pa.fromBlock}, ${pa.toBlock}, ${pa.dataHash})`,
    `wrote ${dataFile} and ${join(dir, 'manifest.json')}`, '',
  ].join('\n'));
  return 0;
}

function gitState() {
  try {
    const run = (a) => execFileSync('git', a, { cwd: HERE, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    return { commit: run(['rev-parse', 'HEAD']), dirty: run(['status', '--porcelain', '--', 'robinhood-ram-root.mjs']) !== '' };
  } catch { return null; }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).then((c) => process.exit(c), (e) => { process.stderr.write(`ERROR: ${redact(e?.message ?? e)}\n`); process.exit(1); });
}

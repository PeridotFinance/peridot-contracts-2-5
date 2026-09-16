// Read-only Fuji MOCK preflight. Run from contracts/: node script/check-fuji-borrow-accounting.cjs
// No wallet, key, signing, writes or environment-file loading. Fail closed on changed history.
const assert = require('node:assert/strict');
const { ethers } = require('ethers');
const RPC = 'https://api.avax-test.network/ext/bc/C/rpc';
const OWNER = '0x94696d767e65a75581145646960fa0ec886ce5d2';
const LEGACY = '0x87563aab6f1e60441d511d1512f28a0bdfa6faf2';
const markets = [
  { address: '0x81BF2032e98C8F35F2336e1A68baA01B5B2030E4', asset: '0x145700AA1575E7Fb84162D2c8C5201cf683df335', borrower: '0x8280Bb4DDc57447c5a3b04177e67F7bf7C07dAE1', expected: '0' },
  { address: '0x577AC6Ca3Df06D7702740A6A8c136F868f9f0195', asset: '0x614396e98a9042b2Bdc9619E6A556e132A62DC06', borrower: '0xBe80594d30c257f61E3C9ad7A3E189ba6f065Dd4', expected: '8' },
];
const marketAbi = [
  'function admin() view returns(address)', 'function implementation() view returns(address)',
  'function underlying() view returns(address)', 'function totalBorrows() view returns(uint256)',
  'function totalReserves() view returns(uint256)', 'function totalSupply() view returns(uint256)',
  'function getCash() view returns(uint256)', 'function exchangeRateStored() view returns(uint256)',
  'function borrowBalanceStored(address) view returns(uint256)', 'function flashLoansPaused() view returns(bool)',
];
async function main() {
  const p = new ethers.providers.JsonRpcProvider(RPC);
  assert.equal((await p.getNetwork()).chainId, 43113);
  const block = await p.getBlockNumber();
  const header = await p.getBlock(block);
  const from = 58205700; // Before either mock market deployment; verified below.
  const event = new ethers.utils.Interface(['event Borrow(address borrower,uint256 borrowAmount,uint256 accountBorrows,uint256 totalBorrows)']);
  for (const m of markets) {
    assert.equal(await p.getCode(m.address, from), '0x', 'deployment lower bound');
    assert.notEqual(await p.getCode(m.address, 58205715), '0x', 'deployment upper bound');
  }
  const ranges = [];
  for (let n = from; n <= block; n += 2000) ranges.push([n, Math.min(n + 1999, block)]);
  let cursor = 0;
  const logs = [];
  await Promise.all(Array.from({ length: 4 }, async () => {
    while (cursor < ranges.length) {
      const [a, b] = ranges[cursor++];
      logs.push(...await p.send('eth_getLogs', [{ address: markets.map(m => m.address),
        fromBlock: ethers.utils.hexValue(a), toBlock: ethers.utils.hexValue(b), topics: [event.getEventTopic('Borrow')] }]));
    }
  }));
  const result = { chainId: 43113, block, blockHash: header.hash, timestamp: header.timestamp,
    fromBlock: from, checkedRanges: ranges.length, borrowEvents: logs.length, markets: [] };
  for (const m of markets) {
    const c = new ethers.Contract(m.address, marketAbi, p);
    const ownLogs = logs.filter(l => l.address.toLowerCase() === m.address.toLowerCase());
    assert.equal(ownLogs.length, 1, 'borrow history changed: review, do not approve an empty migration');
    assert.equal(event.parseLog(ownLogs[0]).args.borrower.toLowerCase(), m.borrower.toLowerCase());
    const row = { address: m.address, historicalBorrower: m.borrower, activeBorrowers: [] };
    for (const field of ['admin', 'implementation', 'underlying', 'totalBorrows', 'totalReserves', 'totalSupply', 'getCash', 'exchangeRateStored', 'flashLoansPaused']) {
      row[field] = String(await c[field]({ blockTag: block }));
    }
    assert.equal(row.admin.toLowerCase(), OWNER);
    assert.equal(row.implementation.toLowerCase(), LEGACY, 'implementation changed');
    assert.equal(row.underlying.toLowerCase(), m.asset.toLowerCase());
    assert.equal(row.totalBorrows, m.expected, 'aggregate changed');
    assert.equal(row.flashLoansPaused, 'true');
    assert.equal(String(await c.borrowBalanceStored(m.borrower, { blockTag: block })), '0', 'borrower not debt-free');
    assert(BigInt(row.totalReserves) >= BigInt(m.expected), 'insufficient rounding reserves');
    row.implementationCodeHash = ethers.utils.keccak256(await p.getCode(row.implementation, block));
    assert.equal(row.implementationCodeHash, '0x38aefc43d0a808b508524223cdeef1160e05e305bf88435491cbd60ac2e4b7db');
    result.markets.push(row);
  }
  const config = new ethers.Contract('0x6148183676E304dbe63a85C350c208DA3cEAc39C', [
    'function opensPaused() view returns(bool)', 'function queuedActions(bytes32) view returns(uint256)',
  ], p);
  const controller = new ethers.Contract('0x0020998Ef0f159cf225e183BefF212b5dBA8285a', [
    'function borrowGuardianPaused(address) view returns(bool)',
  ], p);
  result.opensPaused = await config.opensPaused({ blockTag: block });
  assert.equal(String(await config.queuedActions(ethers.utils.id('unpauseOpens'), { blockTag: block })), '0', 'queued reopen');
  result.borrowingPaused = await Promise.all(markets.map(m => controller.borrowGuardianPaused(m.address, { blockTag: block })));
  result.phase = result.opensPaused && result.borrowingPaused.every(Boolean) ? 'PAUSED: eligible for separate upgrade review' : 'NOT READY for upgrade: pause receipts required';
  result.signerNonce = await p.getTransactionCount(OWNER, block);
  result.signerPendingNonce = await p.getTransactionCount(OWNER, 'pending');
  result.signerBalanceWei = String(await p.getBalance(OWNER, block));
  assert.equal((await p.getBlock(block)).hash, header.hash, 'snapshot reorg');
  console.log(JSON.stringify(result, null, 2));
}
main().catch(e => { console.error('PRECHECK FAILED:', e.message); process.exitCode = 1; });

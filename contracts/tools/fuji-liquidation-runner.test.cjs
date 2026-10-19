'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { BigNumber: BN, utils, Wallet } = require('ethers');
const {
  A,
  I,
  CAP,
  spec,
  sequence,
  validate,
  reserve,
  journal,
  readJournal,
  recoveryItems,
  send,
  reconcile,
  lock,
  requestGate,
  command,
} = require('./fuji-liquidation-runner.cjs');
const NOW = 1800000000;
test('CLI modes and case approvals match exactly; recovery authority cannot activate a run', () => {
  assert.deepEqual(command(['check', '0'], {}), { mode: 'check', n: 0 });
  assert.deepEqual(command(['run', '0'], { CONFIRM_FUJI_LIQUIDATION_CASE: '0' }), { mode: 'run', n: 0 });
  assert.deepEqual(command(['recover', '0'], { CONFIRM_FUJI_LIQUIDATION_RECOVERY: '0' }), { mode: 'recover', n: 0 });
  for (const args of [
    ['run\n', '0'],
    ['recover\n', '0'],
    ['run', '0\n'],
    ['run', '00'],
    ['run', '8'],
    ['run'],
    ['run', '0', 'extra'],
  ]) {
    assert.throws(() => command(args, { CONFIRM_FUJI_LIQUIDATION_CASE: '0', CONFIRM_FUJI_LIQUIDATION_RECOVERY: '0' }));
  }
  assert.throws(() => command(['run', '0'], { CONFIRM_FUJI_LIQUIDATION_RECOVERY: '0' }));
  assert.throws(() => command(['recover', '0'], { CONFIRM_FUJI_LIQUIDATION_CASE: '0' }));
  assert.throws(() => command(['run', '1'], { CONFIRM_FUJI_LIQUIDATION_CASE: '0' }));
});
test('RPC gate serializes concurrent requests, spaces starts and survives read failures', async () => {
  const gate = requestGate(20),
    starts = [];
  let active = 0,
    maxActive = 0;
  const jobs = [0, 1, 2].map((i) =>
    gate(async () => {
      starts.push(Date.now());
      active++;
      maxActive = Math.max(maxActive, active);
      await new Promise((resolve) => setTimeout(resolve, 5));
      active--;
      if (i === 1) throw Error('read failed');
      return i;
    })
  );
  const result = await Promise.allSettled(jobs);
  assert.deepEqual(
    result.map((x) => x.status),
    ['fulfilled', 'rejected', 'fulfilled']
  );
  assert.equal(maxActive, 1);
  assert(starts[1] - starts[0] >= 15 && starts[2] - starts[1] >= 15);
});
function artifact(n = 0) {
  const s = spec(n),
    next = { [A.owner]: 380, [A.runner]: 34 };
  return {
    transactions: sequence(n).map((step) => {
      let args = step.args;
      if (step.tag === 'open')
        args = [[s.collateral, s.short, s.shares, 500, s.shares.div(100), 1000, NOW + 3600, '0x']];
      if (['close', 'liquidate'].includes(step.tag)) {
        args = [
          [
            s.id,
            step.tag === 'close' || s.full ? 10000 : 5000,
            step.tag === 'close' ? s.shares.div(100) : 0,
            step.tag === 'close' ? s.shares.div(5) : 0,
            1000,
            0,
            0,
            NOW + 3600,
            '0x',
            '0x',
            '0x',
          ],
        ];
        if (step.tag === 'liquidate') args.push(s.insurance);
      }
      return {
        transactionType: 'CALL',
        additionalContracts: [],
        transaction: {
          from: step.from,
          to: step.to,
          chainId: 43113,
          nonce: next[step.from]++,
          value: 0,
          input: I.encodeFunctionData(step.fn, args),
        },
      };
    }),
  };
}
const parse = (a, n = 0) => validate(a, n, NOW, { owner: 380, runner: 34 });
function change(index, fn, n = 0) {
  const a = artifact(n),
    name = sequence(n)[index].fn;
  const args = I.decodeFunctionData(name, a.transactions[index].transaction.input).map((x) =>
    Array.isArray(x) ? [...x] : x
  );
  fn(args);
  a.transactions[index].transaction.input = I.encodeFunctionData(name, args);
  return a;
}
test('eight exact mixed-sender cases: 84 normal calls, bounded insurance and recovery', () => {
  let count = 0;
  for (let n = 0; n < 8; n++) {
    const b = parse(artifact(n), n);
    count += b.length;
    assert.equal(b.filter((x) => x.step.from === A.owner).length, 5);
    assert(b.every((x) => x.tx.chainId === 43113 && x.tx.value === 0));
    assert.equal(b[6].step.tag, 'open');
    assert.equal(b[8].step.tag, 'liquidate');
  }
  assert.equal(count, 84);
  for (const x of [-1, 8, 0.1, NaN]) assert.throws(() => spec(x));
});
test('rejects every envelope change, call insertion/deletion, noncanonical data and deployment', () => {
  for (const [key, value] of [
    ['from', A.runner],
    ['to', A.executor],
    ['chainId', 43114],
    ['nonce', 0],
    ['value', 1],
  ]) {
    const a = artifact();
    a.transactions[0].transaction[key] = value;
    assert.throws(() => parse(a));
  }
  for (const mutate of [
    (a) => a.transactions.pop(),
    (a) => a.transactions.push(a.transactions[0]),
    (a) => (a.transactions[0].transactionType = 'CREATE'),
    (a) => a.transactions[0].additionalContracts.push({}),
    (a) => (a.transactions[0].transaction.input += '00'),
  ]) {
    const a = artifact();
    mutate(a);
    assert.throws(() => parse(a));
  }
  const a = artifact();
  a.transactions[6].additionalContracts.push({});
  assert.equal(parse(a).length, 11);
});
test('rejects price, leverage, collateral, fees, insurance, exits, arbitrary routes and deadlines', () => {
  assert.throws(() => parse(change(0, (a) => (a[0] = 123))));
  for (const [k, v] of [
    [0, A.owner],
    [1, true],
    [2, 1],
    [3, 600],
    [4, 1],
    [5, 0],
    [6, NOW + 599],
    [6, NOW + 3601],
    [7, '0x01'],
  ])
    assert.throws(() => parse(change(6, (a) => (a[0][k] = v))));
  for (const index of [8, 10])
    for (const [k, v] of [
      [0, 18],
      [1, 1],
      [2, 1],
      [3, 1],
      [4, 0],
      [5, 1],
      [6, 1],
      [7, NOW + 599],
      [8, '0x01'],
      [9, '0x01'],
      [10, '0x01'],
    ]) {
      assert.throws(() => parse(change(index, (a) => (a[0][k] = v))));
    }
  assert.throws(() => parse(change(8, (a) => (a[1] = 1))));
  assert.throws(() =>
    parse(
      change(8, (a) => (a[1] = 50000001), 2),
      2
    )
  );
});
test('gas reservation includes recovery, separate signer balances and suite cap', () => {
  const balances = { owner: CAP, runner: CAP },
    b = parse(artifact()),
    price = BN.from(500000000);
  const costs = reserve(b, price, balances);
  assert(costs.owner.add(costs.runner).lte(CAP));
  assert.equal(CAP.mul(8).toString(), utils.parseEther('0.20').toString());
  assert.throws(() => reserve(b, BN.from(1000000000), balances));
  assert.throws(() => reserve(b, BN.from(0), balances));
  for (const who of ['owner', 'runner'])
    assert.throws(() => reserve(b, price, { ...balances, [who]: costs[who].sub(1) }));
});
test('private per-case journals reject replay, symlinks, truncation and wrong cases', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fuji-liquidation-test-'));
  try {
    const log = journal(dir, 0);
    log.write({ phase: 'start', case: 0, chainId: 43113 });
    log.close();
    assert.equal(readJournal(dir, 0).length, 1);
    assert.throws(() => journal(dir, 0));
    const file = path.join(dir, 'fuji-liquidation-v1-case-0.jsonl');
    assert.equal(fs.statSync(file).mode & 0o777, 0o600);
    fs.writeFileSync(file, '{');
    assert.throws(() => readJournal(dir, 0));
    fs.unlinkSync(file);
    fs.symlinkSync(path.join(dir, 'missing'), file);
    assert.throws(() => journal(dir, 0));
    fs.chmodSync(dir, 0o755);
    assert.throws(() => journal(dir, 1));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
test('recovery only writes exact baseline feeds from OWNER; no trading/insurance/withdrawal', () => {
  const r = recoveryItems(400);
  assert.equal(r.length, 2);
  r.forEach((x, i) => {
    assert.equal(x.step.from, A.owner);
    assert.equal(x.tx.nonce, 400 + i);
    assert.equal(x.tx.chainId, 43113);
    assert.equal(x.tx.value, 0);
    assert.equal(x.tx.data, I.encodeFunctionData('setAnswer', [i ? 1000000000 : 100000000]));
  });
});
test('exclusive suite lock prevents simultaneous runs/recoveries and does not erase journals', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fuji-liquidation-lock-'));
  try {
    const release = lock(dir);
    assert.throws(() => lock(dir));
    const j = journal(dir, 0);
    j.write({ phase: 'start', case: 0, chainId: 43113 });
    j.close();
    release();
    const again = lock(dir);
    again();
    assert.equal(readJournal(dir, 0).length, 1);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// Ephemeral key for transport tests only; never loads either real wallet.
function transport(options = {}) {
  const wallet = Wallet.createRandom(),
    records = [],
    sent = [];
  const item = recoveryItems(0)[0];
  item.step.from = wallet.address;
  let nonce = 0,
    signedTx,
    hash;
  const receipt = () => ({
    transactionHash: hash,
    status: options.failed ? 0 : 1,
    from: wallet.address,
    to: item.tx.to,
    blockNumber: 1,
    blockHash: '0xabc',
    gasUsed: BN.from(30000),
  });
  const provider = {
    getNetwork: async () => ({ chainId: options.chain || 43113 }),
    getTransactionCount: async () => (options.nonce ? 1 : nonce),
    estimateGas: async () => BN.from(options.highGas ? 200000 : 30000),
    sendTransaction: async (raw) => {
      assert.equal(records.at(-1).phase, 'signed');
      signedTx = utils.parseTransaction(raw);
      hash = utils.keccak256(raw);
      sent.push(signedTx);
      if (options.timeout) throw Error('timeout');
      nonce++;
      return { hash };
    },
    waitForTransaction: async () => null,
    getTransactionReceipt: async () => (options.unknown ? null : receipt()),
    getTransaction: async () => signedTx,
    getBlock: async () => ({ hash: options.reorg ? '0xdef' : '0xabc' }),
  };
  let guardCalls = 0;
  return {
    sent,
    records,
    args: {
      item,
      provider,
      gasPrice: BN.from(200),
      sign: async (_, tx) => (options.wrongSigner ? Wallet.createRandom() : wallet).signTransaction(tx),
      log: { write: (r) => records.push(r) },
      guard: async (x) => {
        guardCalls++;
        if (options.guard) throw Error('policy');
        if (options.quoteChanged && guardCalls === 2) x.tx.data = I.encodeFunctionData('setAnswer', [1]);
      },
      after: async () => {
        if (options.after) throw Error('state');
      },
    },
  };
}
test('transport journals intent/hash before submission, verifies signer and canonical mined payload', async () => {
  const h = transport();
  await send(h.args);
  assert.equal(h.sent.length, 1);
  assert.deepEqual(
    h.records.map((x) => x.phase),
    ['intent', 'signed', 'mined']
  );
  assert.equal(h.sent[0].chainId, 43113);
});
test('wrong chain, nonce, policy, gas, signer or post-sign state aborts before submission', async () => {
  for (const options of [
    { chain: 43114 },
    { nonce: true },
    { highGas: true },
    { guard: true },
    { wrongSigner: true },
    { quoteChanged: true },
  ]) {
    const h = transport(options);
    await assert.rejects(send(h.args));
    assert.equal(h.sent.length, 0);
  }
});
test('failed/uncertain submission, reorg and postcondition failure never retry', async () => {
  for (const options of [{ failed: true }, { unknown: true }, { timeout: true }, { reorg: true }, { after: true }]) {
    const h = transport(options);
    await assert.rejects(send(h.args));
    assert.equal(h.sent.length, 1);
  }
});
test('reconciliation refuses missing hashes/receipts, nonce changes and mismatched chain evidence', async () => {
  const start = { phase: 'start', nonces: { owner: 1, runner: 2 } };
  const provider = {
    getNetwork: async () => ({ chainId: 43113 }),
    getTransactionCount: async (from) => (from === A.owner ? 1 : 2),
    getTransaction: async () => null,
    getTransactionReceipt: async () => null,
  };
  assert.deepEqual(await reconcile(provider, [start]), start.nonces);
  await assert.rejects(reconcile(provider, [start, { phase: 'intent', tag: 'stress' }]));
  const item = recoveryItems(1)[0];
  await assert.rejects(
    reconcile(provider, [
      start,
      {
        phase: 'intent',
        tag: item.step.tag,
        from: A.owner,
        tx: { ...item.tx, gasPrice: BN.from(200) },
      },
      { phase: 'signed', tag: item.step.tag, hash: '0x1234' },
    ])
  );
  provider.getTransactionCount = async () => 99;
  await assert.rejects(reconcile(provider, [start]));
});
test('recovery reconciliation accepts a known mined revert but rejects replacement payloads and hashes', async () => {
  const item = recoveryItems(380)[0],
    hash = '0x' + '11'.repeat(32);
  const tx = { ...item.tx, gasPrice: BN.from(200) };
  const actual = { ...tx, from: A.owner, hash };
  const records = [
    { phase: 'start', nonces: { owner: 380, runner: 34 } },
    { phase: 'intent', tag: item.step.tag, from: A.owner, tx },
    { phase: 'signed', tag: item.step.tag, hash },
  ];
  const p = {
    getNetwork: async () => ({ chainId: 43113 }),
    getTransactionCount: async (from) => (from === A.owner ? 381 : 34),
    getTransaction: async () => actual,
    getTransactionReceipt: async () => ({
      transactionHash: hash,
      from: A.owner,
      to: tx.to,
      status: 0,
      blockNumber: 1,
      blockHash: '0xabc',
    }),
    getBlock: async () => ({ hash: '0xabc' }),
  };
  assert.deepEqual(await reconcile(p, records), { owner: 381, runner: 34 });
  actual.hash = '0x' + '22'.repeat(32);
  await assert.rejects(reconcile(p, records));
  actual.hash = hash;
  actual.data = I.encodeFunctionData('setAnswer', [123]);
  await assert.rejects(reconcile(p, records));
});
module.exports = { artifact };

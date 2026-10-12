'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { BigNumber: BN, utils, Wallet } = require('ethers');
const { A, TOKEN, EXEC, CAP, sequence, validateBatch, reserveGas, journal, executeBatch } = require('./fuji-margin-runner.cjs');
const NOW = 1800000000;

function artifact() {
  return { transactions: sequence().map((s, nonce) => {
    let input;
    if (s.args) input = TOKEN.encodeFunctionData(s.fn, s.args);
    else if (s.fn === 'openPosition') input = EXEC.encodeFunctionData(s.fn, [[
      s.collateral, s.short, s.budget.mul(5).div(12), s.leverage, s.budget.div(240), 1000, NOW + 3600, '0x',
    ]]);
    else input = EXEC.encodeFunctionData(s.fn, [[s.id, 10000, s.budget.div(240), s.budget.div(30),
      1000, 0, 0, NOW + 3600, '0x', '0x', '0x']]);
    return { transactionType: 'CALL', additionalContracts: [], transaction: {
      from: A.runner, to: s.to, chainId: '0xa869', nonce, value: '0x0', input,
    } };
  }) };
}
const batch = () => validateBatch(artifact(), NOW);
function mutate(index, change) {
  const a = artifact();
  const s = sequence()[index];
  const args = [...EXEC.decodeFunctionData(s.fn, a.transactions[index].transaction.input)[0]];
  change(args);
  a.transactions[index].transaction.input = EXEC.encodeFunctionData(s.fn, [args]);
  return a;
}

test('exact 34-call scope: two deposits and twelve 3x-5x round trips, no withdrawals', () => {
  const b = batch();
  assert.equal(b.length, 34);
  assert.equal(b.filter(x => x.step.fn === 'openPosition').length, 12);
  assert.equal(b.filter(x => x.step.fn === 'closePosition').length, 12);
  assert.equal(b[33].step.id, 16);
  assert.equal(b.every(x => x.tx.value === 0 && x.tx.chainId === 43113), true);
  const a = artifact(); a.transactions[7].additionalContracts.push({ transactionType: 'CREATE2' });
  assert.equal(validateBatch(a, NOW).length, 34); // expected executor-internal isolated account
  Object.values(A).forEach(address => assert.doesNotThrow(() => utils.getAddress(address)));
});

test('rejects altered chain, sender, recipient, nonce, native value, deployment and sequence', () => {
  for (const [key, value] of [['chainId', 43114], ['from', A.owner], ['to', A.owner], ['nonce', 1], ['value', 1]]) {
    const a = artifact(); a.transactions[0].transaction[key] = value;
    assert.throws(() => validateBatch(a, NOW));
  }
  for (const modify of [a => a.transactions.pop(), a => a.transactions.push(a.transactions[0]),
    a => a.transactions[0].transactionType = 'CREATE', a => a.transactions[0].additionalContracts.push({}),
    a => a.transactions[0].transaction.input += '00',
    a => a.transactions[4].transaction.input = TOKEN.encodeFunctionData('approve', [A.owner, 1]),
    a => a.transactions[5].transaction.input = TOKEN.encodeFunctionData('deposit', [A.usdCollateral, 1])]) {
    const a = artifact(); modify(a); assert.throws(() => validateBatch(a, NOW));
  }
});

test('rejects changes to every open and close policy field', () => {
  for (const [field, value] of [[0, A.owner], [1, true], [2, 1], [3, 600], [4, 1], [5, 0],
    [6, NOW + 599], [6, NOW + 3601], [7, '0x01']]) {
    assert.throws(() => validateBatch(mutate(7, p => p[field] = value), NOW));
  }
  for (const [field, value] of [[0, 6], [1, 5000], [2, 1], [3, 1], [4, 0], [5, 1], [6, 1],
    [7, NOW + 599], [8, '0x01'], [9, '0x01'], [10, '0x01']]) {
    assert.throws(() => validateBatch(mutate(8, p => p[field] = value), NOW));
  }
});

test('reserves whole-batch maximum gas, rejects cost above 0.20 test AVAX or available balance', () => {
  const b = batch();
  const amount = reserveGas(b, BN.from(500000000), utils.parseEther('0.25'));
  assert(amount.lte(CAP));
  assert.throws(() => reserveGas(b, BN.from(1000000000), utils.parseEther('0.25')));
  assert.throws(() => reserveGas(b, BN.from(500000000), amount.sub(1)));
  assert.throws(() => reserveGas(b, BN.from(0), CAP));
});

test('journal is private, durable and cannot be reused or replaced by a symlink', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fuji-runner-journal-'));
  try {
    const j = journal(dir); j.write({ phase: 'intent', nonce: 0 }); j.close();
    const file = path.join(dir, 'fuji-margin-roundtrips-v1.jsonl');
    assert.equal(fs.statSync(file).mode & 0o777, 0o600);
    assert.match(fs.readFileSync(file, 'utf8'), /intent/);
    assert.throws(() => journal(dir));
    fs.unlinkSync(file); fs.symlinkSync(path.join(dir, 'missing'), file);
    assert.throws(() => journal(dir));
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

function harness(options = {}) {
  let nonce = 0;
  const records = [], sent = [];
  const wallet = Wallet.createRandom(); // ephemeral test key; NEVER the local Fuji credential
  const receipt = hash => ({ status: options.failed ? 0 : 1, from: A.runner, to: sent.at(-1).to,
    blockNumber: 1, blockHash: '0xabc', gasUsed: BN.from(100), transactionHash: hash });
  return {
    records, sent,
    args: {
      batch: batch(), gasPrice: BN.from(500000000), balance: utils.parseEther('0.25'),
      log: { write: r => records.push(r) }, signer: wallet,
      guard: async () => { if (options.guardFail) throw new Error('policy'); },
      afterReceipt: async () => { if (options.postFail) throw new Error('state'); },
      provider: {
        getNetwork: async () => ({ chainId: options.chain || 43113 }),
        getTransactionCount: async () => options.badNonce ? 1 : nonce,
        estimateGas: async () => BN.from(options.highGas ? 99000000 : 100),
        sendTransaction: async raw => {
          const signed = utils.parseTransaction(raw);
          sent.push(signed);
          assert.equal(records.at(-1).phase, 'signed');
          assert.equal(records.at(-1).hash, utils.keccak256(raw));
          if (options.sendUnknown) throw new Error('timeout');
          return { hash: utils.keccak256(raw) };
        },
        waitForTransaction: async hash => { nonce++; return options.receiptUnknown ? null : receipt(hash); },
        getBlock: async () => ({ hash: options.reorg ? '0xdef' : '0xabc' }),
      },
    },
  };
}

test('all calls use fixed chain, bounded gas and zero value; intent and hash recorded before submission', async () => {
  const h = harness(); await executeBatch(h.args);
  assert.equal(h.sent.length, 34);
  assert.equal(h.records.at(-1).phase, 'complete');
  h.sent.forEach((t, nonce) => {
    assert.equal(t.chainId, 43113); assert.equal(t.nonce, nonce);
    assert(t.value.isZero()); assert(t.gasPrice.eq(500000000));
  });
});

test('wrong chain, pending nonce, changed policy and high estimate stop before first signature/submission', async () => {
  for (const option of [{ chain: 43114 }, { badNonce: true }, { guardFail: true }, { highGas: true }]) {
    const h = harness(option); await assert.rejects(executeBatch(h.args));
    assert.equal(h.sent.length, 0); assert.equal(h.records.some(r => r.phase === 'signed'), false);
  }
});

test('failed/unknown receipt, submission uncertainty, changed state or reorg stops without retry', async () => {
  for (const option of [{ failed: true }, { sendUnknown: true }, { receiptUnknown: true }, { postFail: true }, { reorg: true }]) {
    const h = harness(option); await assert.rejects(executeBatch(h.args));
    assert.equal(h.sent.length, 1); assert.equal(h.records.some(r => r.phase === 'complete'), false);
    assert.equal(h.records.filter(r => r.phase === 'signed').length, 1);
  }
});

module.exports = { artifact };

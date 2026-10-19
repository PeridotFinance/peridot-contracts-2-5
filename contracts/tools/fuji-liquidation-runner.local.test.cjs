'use strict';
// Only an isolated, pinned localhost Anvil. No real keys, no public-chain writes.
const test = require('node:test');
const assert = require('node:assert/strict');
const { providers, utils, BigNumber: BN } = require('ethers');
const {
  A,
  I,
  guards,
  simulate,
  validate,
  reserve,
  nonces,
  recoveryItems,
  reconcile,
} = require('./fuji-liquidation-runner.cjs');
const RPC = 'http://127.0.0.1:18548';
test(
  'local Fuji: all eight scenarios plus recovery after open/stress/liquidation/restore',
  {
    skip: process.env.FUJI_LIQUIDATION_LOCAL_TEST !== 'true',
    timeout: 1200000,
  },
  async () => {
    function client() {
      const provider = new providers.JsonRpcProvider(RPC);
      provider.pollingInterval = 50;
      return provider;
    }
    let p = client();
    async function revert(snapshot) {
      assert(await p.send('evm_revert', [snapshot]));
      // ethers tracks a monotonic high-water block number and emitted receipt hashes.
      // A VM rewind invalidates both; reusing that client can wait forever for an already mined tx.
      p.removeAllListeners();
      p.polling = false;
      p = client();
    }
    assert.match(await p.send('web3_clientVersion', []), /anvil/i);
    assert.equal((await p.getNetwork()).chainId, 43113);
    const forkBlock = Number(process.env.FUJI_LIQUIDATION_FORK_BLOCK || 59499119);
    assert(Number.isSafeInteger(forkBlock) && forkBlock >= 59499119);
    assert.equal(await p.getBlockNumber(), forkBlock);
    const initial = await p.send('evm_snapshot', []);
    const price = BN.from(500000000);
    let count = 0,
      gas = BN.from(0);
    async function execute(item, g, records) {
      await g.guard(item);
      const tx = { ...item.tx, gasPrice: price };
      assert((await p.estimateGas({ ...tx, from: item.step.from })).lte(tx.gasLimit));
      records.push({
        phase: 'intent',
        tag: item.step.tag,
        from: item.step.from,
        tx,
      });
      // Impersonated localhost signing; production uses the separately unit-tested raw-sign transport.
      const response = await p.getSigner(item.step.from).sendTransaction(tx);
      records.push({
        phase: 'signed',
        tag: item.step.tag,
        hash: response.hash,
      });
      const receipt = await p.waitForTransaction(response.hash, 1, 30000);
      assert(receipt, 'Local receipt timed out');
      assert.equal(receipt.status, 1);
      gas = gas.add(receipt.gasUsed);
      count++;
      await g.after(item);
    }
    async function plan(n) {
      const g = await guards(p, n);
      await g.initial();
      const ns = await nonces(p),
        a = simulate(n, RPC);
      const b = validate(a, n, (await p.getBlock('latest')).timestamp, ns);
      reserve(b, price, {
        owner: await p.getBalance(A.owner),
        runner: await p.getBalance(A.runner),
      });
      return { g, b, records: [{ phase: 'start', nonces: ns }] };
    }
    for (let n = 0; n < 8; n++) {
      const { g, b, records } = await plan(n);
      for (const item of b) await execute(item, g, records);
      await g.finished();
      await reconcile(p, records);
      console.log(`LOCAL ONLY case ${n}: ${b.length} mined calls, prices restored, zero debt/locks`);
    }
    assert.equal(count, 84);
    await revert(initial);
    for (const stopAfter of ['open', 'stress', 'liquidate', 'restore']) {
      const snap = await p.send('evm_snapshot', []);
      const { g, b, records } = await plan(0);
      for (const item of b) {
        await execute(item, g, records);
        if (item.step.tag === stopAfter) break;
      }
      const ns = await reconcile(p, records);
      for (const item of recoveryItems(ns.owner)) {
        await execute(item, { guard: g.recoveryGuard, after: async () => {} }, records);
      }
      await reconcile(p, records);
      await g.restored(); // Both baseline feeds, freshness and owners must be verified.
      const feed = new utils.Interface(['function answer() view returns(int256)']);
      assert.equal(
        BN.from(
          await p.call({
            to: A.avaxFeed,
            data: feed.encodeFunctionData('answer'),
          })
        ).toString(),
        '1000000000'
      );
      await assert.rejects(g.finished(), /Aggregate debt/); // An RPC failure must not count as proof of remaining debt.
      console.log(`LOCAL ONLY recovery after ${stopAfter}: baseline restored, open position deliberately retained`);
      await revert(snap);
    }
    p.removeAllListeners();
    p.polling = false;
    console.log(`LOCAL ONLY total ${count} calls, ${gas.toString()} gas; no real signing credentials used.`);
  }
);

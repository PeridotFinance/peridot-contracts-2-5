'use strict';
// Integration against ONLY localhost Anvil; no private key, no public writes.
const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const { providers, utils } = require('ethers');
const { A, validateBatch, liveGuards, reserveGas } = require('./fuji-margin-runner.cjs');

test('actual RPC guard + fresh generated artifact + all 34 transactions on isolated Anvil', {
  skip: process.env.FUJI_RUNNER_LOCAL_TEST !== 'true', timeout: 240000,
}, async () => {
  const rpc = 'http://127.0.0.1:18547';
  const p = new providers.JsonRpcProvider(rpc);
  p.pollingInterval = 100;
  assert.match(await p.send('web3_clientVersion', []), /anvil/i);
  assert.equal((await p.getNetwork()).chainId, 43113);
  assert.equal(await p.getBlockNumber(), 59336291);
  // VM-only impersonation/funding: no key ever read, owner roles remain unchanged.
  await p.send('anvil_setBalance', [A.runner, utils.hexValue(utils.parseEther('0.25'))]);
  const cwd = path.resolve(__dirname, '..');
  function forge(script, extra = []) {
    execFileSync('forge', ['script', `script/${script}.s.sol:${script}`, '--rpc-url', rpc,
      '--skip', 'P_OFTAdapter.sol', '--skip', 'P_OFTAdapterUpgradeable.sol',
      '--skip', 'P_OFTAdapterUpgradeable.t.sol', ...extra], {
      cwd, stdio: 'pipe', timeout: 180000,
      env: { ...process.env, FOUNDRY_PROFILE: 'debt_accounting',
        CONFIRM_FUJI_RUNNER_PREPARATION: 'true', CONFIRM_FUJI_RUNNER_ROUNDTRIPS: 'true' },
    });
  }
  forge('PrepareFujiMarginRunner', ['--sender', A.owner, '--unlocked', '--broadcast', '--slow']);
  forge('ExerciseFujiMarginRunner', ['--sender', A.runner]);
  const artifact = JSON.parse(fs.readFileSync(path.join(cwd,
    'broadcast/ExerciseFujiMarginRunner.s.sol/43113/dry-run/run-latest.json')));
  const batch = validateBatch(artifact, (await p.getBlock('latest')).timestamp);
  const guards = await liveGuards(p);
  const gasPrice = utils.parseUnits('0.5', 'gwei');
  reserveGas(batch, gasPrice, await p.getBalance(A.runner));
  const signer = p.getSigner(A.runner); // anvil impersonation, not local Fuji key
  let gas = 0;
  for (const item of batch) {
    await guards.guard(item);
    const estimate = await p.estimateGas({ ...item.tx, from: A.runner, gasPrice });
    assert(estimate.lte(item.tx.gasLimit), `${item.step.fn} exceeds gas cap`);
    const response = await signer.sendTransaction({ ...item.tx, gasPrice });
    const receipt = await response.wait();
    assert.equal(receipt.status, 1);
    gas += receipt.gasUsed.toNumber();
    await guards.afterReceipt(item, receipt);
  }
  await guards.finished();
  assert.equal(await p.getTransactionCount(A.runner), 34);
  console.log(`LOCAL Anvil only: 34 calls verified, ${gas} gas. No public transactions.`);
});

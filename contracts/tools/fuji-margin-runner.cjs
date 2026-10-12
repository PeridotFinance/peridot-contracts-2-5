'use strict';

// Fixed, one-use Fuji MOCK batch. No arbitrary recipient/calldata/network options.
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { Wallet, providers, Contract, utils, BigNumber: BN } = require('ethers');
const { publicInfo } = require('./fuji-test-wallet.cjs');
const RPC = 'https://api.avax-test.network/ext/bc/C/rpc';
const A = Object.freeze({
  runner: '0x7Eb84484a3e05F611De42c8954D786100917E726',
  owner: '0x94696d767e65a75581145646960FA0eC886cE5d2',
  executor: '0xA1398d06Cf8d0bE8673A46C67e462718FD99Bf9C',
  risk: '0x47d5A13Da78c3De721BB28C9315b581f4998CcBA',
  config: '0xD5CF7e011424524b73cc1100E817646D0d2149C3',
  vault: '0xb24BA4dd6D1436e2D2eb2Cd054B07931C8BDD456',
  pUsd: '0x3312f34EE84884033ea3396FcA8E2454D774260F',
  pAvax: '0xD96e98944F05B6B645bB4Ae00e6EadfDd6274A94',
  usdCollateral: '0x8F2a561E459A4cc569b8e5ed21b7d4B23De33978',
  avaxCollateral: '0xC3AF75b81037137FaE18cD1d390a5824E39FFcA8',
  usdFeed: '0xF7c5D63f1828699665b8f0Dfd8F28bBF0EA2c63d',
  avaxFeed: '0xD1BDAf98B5e2a73Ef2381e9767fEbF5b79ccbACb',
});
const CAP = utils.parseEther('0.20');
const TOKEN = new utils.Interface([
  'function exchangeRateCurrent()', 'function approve(address,uint256)', 'function deposit(address,uint256)',
]);
const EXEC = new utils.Interface([
  'function openPosition((address collateral,bool short,uint256 collateralShares,uint16 leverageX100,uint256 maxFeeShares,uint256 minPositionOut,uint256 deadline,bytes swapData))',
  'function closePosition((uint256 id,uint16 fractionBps,uint256 maxFeeShares,uint256 maxCollateralSharesToSell,uint256 minTradeDebtOut,uint256 minCollateralDebtOut,uint256 minSurplusUsdc,uint256 deadline,bytes tradeData,bytes collateralData,bytes surplusData))',
]);
const same = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();
function need(ok, message) { if (!ok) throw new Error(message); }
const eq = (a, b) => BN.from(a).eq(b);

function sequence() {
  const out = [A.pUsd, A.pAvax, A.usdCollateral, A.avaxCollateral].map(to => ({
    to, fn: 'exchangeRateCurrent', args: [], gas: 150000,
  }));
  for (const [pool, to] of [A.usdCollateral, A.avaxCollateral].entries()) {
    const budget = BN.from(pool === 0 ? '300000000000' : '30000000000');
    out.push({ to, fn: 'approve', args: [A.vault, budget], gas: 100000 },
      { to: A.vault, fn: 'deposit', args: [to, budget], gas: 600000 },
      { to, fn: 'approve', args: [A.vault, 0], gas: 100000 });
    for (const leverage of [300, 400, 500]) for (const short of [false, true]) {
      const id = 5 + pool * 6 + (leverage / 100 - 3) * 2 + Number(short);
      const item = { to: A.executor, collateral: to, budget, leverage, short, id };
      out.push({ ...item, fn: 'openPosition', gas: 16000000 },
        { ...item, fn: 'closePosition', gas: 6000000 });
    }
  }
  return out;
}

// Ignore all transaction-builder hints. Reconstruct ONLY permitted transaction fields.
function validateBatch(artifact, now) {
  const plan = sequence();
  need(artifact.transactions?.length === plan.length, 'Expected exactly 34 calls');
  return plan.map((step, nonce) => {
    const entry = artifact.transactions[nonce];
    const t = entry.transaction;
    // openPosition internally creates its isolated account. Foundry reports that in
    // additionalContracts; it is NOT a separate signed deployment or trusted input.
    need(entry.transactionType === 'CALL', 'No deployment transaction allowed');
    need(step.fn === 'openPosition' || !entry.additionalContracts?.length, 'Unexpected internal deployment');
    need(t && same(t.from, A.runner) && same(t.to, step.to) && eq(t.chainId, 43113)
      && eq(t.nonce, nonce) && eq(t.value || 0, 0), 'Envelope outside scope');
    const iface = step.args ? TOKEN : EXEC;
    const parsed = iface.parseTransaction({ data: t.input });
    need(parsed.name === step.fn, 'Wrong function/order');
    need(same(iface.encodeFunctionData(parsed.name, parsed.args), t.input), 'Noncanonical calldata');
    if (step.args) {
      need(same(t.input, TOKEN.encodeFunctionData(step.fn, step.args)), 'Changed amount/recipient');
    } else {
      const p = parsed.args[0];
      need(p.deadline.gte(now + 600) && p.deadline.lte(now + 3600), 'Expired/excessive deadline');
      need(eq(p.maxFeeShares, step.budget.div(240)), 'Fee cap changed');
      if (step.fn === 'openPosition') {
        need(same(p.collateral, step.collateral) && p.short === step.short
          && eq(p.collateralShares, step.budget.mul(5).div(12)) && eq(p.leverageX100, step.leverage)
          && p.minPositionOut.gt(0) && p.swapData === '0x', 'Open outside scope');
      } else {
        need(eq(p.id, step.id) && eq(p.fractionBps, 10000)
          && eq(p.maxCollateralSharesToSell, step.budget.div(30)) && p.minTradeDebtOut.gt(0)
          && eq(p.minCollateralDebtOut, 0) && eq(p.minSurplusUsdc, 0)
          && [p.tradeData, p.collateralData, p.surplusData].every(x => x === '0x'), 'Close outside scope');
      }
    }
    return { step, tx: { to: step.to, data: t.input, value: 0, nonce, chainId: 43113, gasLimit: step.gas, type: 0 } };
  });
}

function reserveGas(batch, gasPrice, balance) {
  const total = batch.reduce((sum, x) => sum.add(x.tx.gasLimit), BN.from(0)).mul(gasPrice);
  need(gasPrice.gt(0) && total.lte(CAP) && total.lte(balance), 'Whole-batch gas reservation exceeds cap/balance');
  return total;
}

// Exclusive, durable journal: a crash or failed transaction NEVER enables silent replay.
function journal(directory) {
  const file = path.join(directory, 'fuji-margin-roundtrips-v1.jsonl');
  const fd = fs.openSync(file, 'wx', 0o600);
  return {
    write(record) { fs.writeSync(fd, JSON.stringify(record) + '\n'); fs.fsyncSync(fd); },
    close() { fs.closeSync(fd); },
  };
}

async function executeBatch({ batch, provider, signer, guard, afterReceipt, log, gasPrice, balance }) {
  const reserved = reserveGas(batch, gasPrice, balance);
  log.write({ phase: 'reserved', gasWei: reserved.toString(), gasPrice: gasPrice.toString(), calls: batch.length });
  for (const item of batch) {
    need((await provider.getNetwork()).chainId === 43113, 'Wrong network');
    const [latest, pending] = await Promise.all([
      provider.getTransactionCount(A.runner, 'latest'), provider.getTransactionCount(A.runner, 'pending'),
    ]);
    need(latest === item.tx.nonce && pending === latest, 'Unexpected nonce/pending transaction');
    await guard(item);
    const tx = { ...item.tx, gasPrice };
    const estimated = await provider.estimateGas({ ...tx, from: A.runner });
    need(estimated.lte(tx.gasLimit), 'Gas estimate above per-call cap');
    // Persist intent BEFORE signing. Persist deterministic hash BEFORE network submission.
    log.write({ phase: 'intent', nonce: tx.nonce, to: tx.to, data: tx.data, gasLimit: tx.gasLimit });
    const signed = await signer.signTransaction(tx);
    const hash = utils.keccak256(signed);
    log.write({ phase: 'signed', nonce: tx.nonce, hash });
    const response = await provider.sendTransaction(signed);
    need(same(response.hash, hash), 'Broadcast hash mismatch');
    const receipt = await provider.waitForTransaction(hash, 1, 120000);
    need(receipt && receipt.status === 1 && same(receipt.from, A.runner) && same(receipt.to, tx.to), 'Receipt failed/unknown');
    const canonical = await provider.getBlock(receipt.blockNumber);
    need(same(canonical.hash, receipt.blockHash), 'Noncanonical receipt');
    log.write({ phase: 'mined', hash, block: receipt.blockNumber, gasUsed: receipt.gasUsed.toString(), status: receipt.status });
    await afterReceipt(item, receipt);
  }
  log.write({ phase: 'complete', calls: batch.length });
}

const contractsDir = path.resolve(__dirname, '..');
function contract(name, address, provider) {
  const source = name === 'FujiMockPriceFeed' ? 'FujiMockAssets' : name;
  const artifact = JSON.parse(fs.readFileSync(path.join(contractsDir, 'out', `${source}.sol`, `${name}.json`)));
  return new Contract(address, artifact.abi, provider);
}
function simulate() {
  execFileSync('forge', ['script', 'script/ExerciseFujiMarginRunner.s.sol:ExerciseFujiMarginRunner',
    '--rpc-url', RPC, '--sender', A.runner, '--skip', 'P_OFTAdapter.sol', '--skip', 'P_OFTAdapterUpgradeable.sol',
    '--skip', 'P_OFTAdapterUpgradeable.t.sol'], {
    cwd: contractsDir, env: { ...process.env, FOUNDRY_PROFILE: 'debt_accounting', CONFIRM_FUJI_RUNNER_ROUNDTRIPS: 'true' },
    stdio: 'inherit', timeout: 240000,
  }); // NO --broadcast, account, or private key
  return JSON.parse(fs.readFileSync(path.join(contractsDir,
    'broadcast/ExerciseFujiMarginRunner.s.sol/43113/dry-run/run-latest.json')));
}

async function liveGuards(provider) {
  const e = contract('CollateralPreservingExecutor', A.executor, provider);
  const risk = contract('CollateralPreservingRiskEngine', A.risk, provider);
  const config = contract('IsolatedMarginConfigUpgradeable', A.config, provider);
  const vault = contract('IsolatedMarginVaultUpgradeable', A.vault, provider);
  const feeds = [A.usdFeed, A.avaxFeed].map(x => contract('FujiMockPriceFeed', x, provider));
  const quoter = contract('IsolatedMarginQuoter', await e.quoter(), provider);
  async function closed(id) {
    const p = await e.positions(id);
    const a = await risk.accounts(p.account);
    // IsolatedMarginTypes.Status.CLOSED == 5.
    need(same(p.owner, A.runner) && eq(a.status, 5) && eq(p.locked, 0), 'Position not closed');
    const debt = contract('PErc20', p.debt, provider);
    const collateral = contract('PErc20', p.collateral, provider);
    const position = contract('PErc20', p.position, provider);
    need(eq(await debt.borrowBalanceStored(p.account), 0) && eq(await collateral.balanceOf(p.account), 0)
      && eq(await position.balanceOf(p.account), 0), 'Account residue');
  }
  async function guard({ step, tx }) {
    const block = await provider.getBlock('latest');
    need(!await config.opensPaused(), 'Opens paused');
    need(same(await e.risk(), A.risk) && same(await e.config(), A.config) && same(await e.vault(), A.vault), 'Wiring changed');
    need(same(await risk.owner(), A.owner) && same(await config.owner(), A.owner), 'Owner changed');
    need(eq(await config.openFeeBps(), 10) && eq(await config.closeFeeBps(), 10)
      && eq(await config.depositorShareBps(), 5000) && eq(await config.insuranceShareBps(), 5000)
      && eq(await config.treasuryShareBps(), 0), 'Fee policy changed');
    for (const [index, feed] of feeds.entries()) {
      const updated = Number(await feed.updatedAt());
      need(same(await feed.owner(), A.owner) && eq(await feed.answer(), index ? 1000000000 : 100000000)
        && updated <= block.timestamp && block.timestamp - updated <= 900, 'Feed changed/stale');
    }
    if (step.args) return;
    const p = EXEC.decodeFunctionData(step.fn, tx.data)[0];
    need(p.deadline.gte(block.timestamp + 300), 'Deadline near expiry');
    const pair = await config.getPairRisk(step.collateral, step.short ? A.pUsd : A.pAvax, step.short ? A.pAvax : A.pUsd);
    const expected = [true, 500, 2000, 1000, 12500, 5000, 5000, 500, 100, 100, utils.parseEther('10000'), utils.parseEther('5000')];
    need(pair.every((v, i) => i === 0 ? v === expected[i] : eq(v, expected[i])), 'Pair policy changed');
    if (step.fn === 'openPosition') {
      need(eq(await e.nextPositionId(), step.id), 'Position history changed');
      if (step.id > 5) await closed(step.id - 1);
      const quoted = await risk.quoteOpen(p.collateral, p.short, p.collateralShares, p.leverageX100);
      // Refresh only the price minimum, using the live protocol quote (its configured slippage).
      // No deadline, leverage, fee, funding or recipient change is permitted.
      const args = [...p];
      args[5] = quoted[1];
      need(quoted[1].gt(0), 'Zero open quote');
      tx.data = EXEC.encodeFunctionData(step.fn, [args]);
    } else {
      const pos = await e.positions(step.id);
      need(same(pos.owner, A.runner) && eq(await e.nextPositionId(), step.id + 1), 'Close ownership/history');
      const position = contract('PErc20', pos.position, provider);
      const debt = contract('PErc20', pos.debt, provider);
      const underlying = (await position.balanceOf(pos.account)).mul(await position.exchangeRateStored()).div(utils.parseEther('1'));
      const quote = await quoter.expectedOut(await position.underlying(), await debt.underlying(), underlying);
      const args = [...p];
      args[4] = quote.mul(99).div(100);
      need(args[4].gt(0), 'Zero close quote');
      tx.data = EXEC.encodeFunctionData(step.fn, [args]);
    }
  }
  async function afterReceipt({ step }) {
    if (step.fn === 'openPosition') {
      const p = await e.positions(step.id);
      need(same(p.owner, A.runner) && same(p.collateral, step.collateral), 'Opened wrong account');
      const snapshot = await risk.snapshot(p.account, 0);
      const m = snapshot.metrics;
      need(!m.liquidatable && m.healthFactorBps.gte(20000)
        && m.tradingLeverageX100.gt(step.leverage * 90 / 100) && m.tradingLeverageX100.lte(step.leverage), 'Entry risk outside scope');
    }
    if (step.fn === 'closePosition') await closed(step.id);
  }
  async function finished() {
    need(eq(await e.nextPositionId(), 17), 'Incomplete history');
    for (let id = 5; id <= 16; id++) await closed(id);
    for (const token of [A.pUsd, A.pAvax]) need(eq(await contract('PErc20', token, provider).totalBorrows(), 0), 'Aggregate debt');
    for (const [index, token] of [A.usdCollateral, A.avaxCollateral].entries()) {
      const c = contract('PErc20', token, provider);
      const budget = BN.from(index ? '30000000000' : '300000000000');
      const free = await vault.freeBalance(A.runner, token);
      need(free.gte(budget.mul(90).div(100)) && free.lte(budget) && eq(await vault.lockedBalance(A.runner, token), 0)
        && eq(await c.allowance(A.runner, A.vault), 0) && eq(await c.balanceOf(A.runner), 0), 'Final balance mismatch');
    }
  }
  return { guard, afterReceipt, finished };
}

async function main() {
  need(process.argv.length === 3 && ['check', 'run'].includes(process.argv[2]), 'Use check or run');
  const run = process.argv[2] === 'run';
  if (run) need(process.env.CONFIRM_FUJI_RUNNER_BATCH_V1 === 'true', 'Explicit batch approval required');
  const provider = new providers.JsonRpcProvider(RPC);
  need((await provider.getNetwork()).chainId === 43113, 'Fuji only');
  need(await provider.getTransactionCount(A.runner, 'latest') === 0
    && await provider.getTransactionCount(A.runner, 'pending') === 0, 'Runner already used');
  const artifact = simulate(); // must pass fresh policy/funding/oracle and entire-flow simulation
  const batch = validateBatch(artifact, (await provider.getBlock('latest')).timestamp);
  const gasPrice = (await provider.getGasPrice()).mul(125).add(99).div(100);
  const balance = await provider.getBalance(A.runner);
  const reserved = reserveGas(batch, gasPrice, balance);
  const guards = await liveGuards(provider);
  await guards.guard(batch[0]);
  console.log(JSON.stringify({ mode: run ? 'run' : 'check', chainId: 43113, actor: A.runner,
    calls: batch.length, gasCeiling: '0.20 test AVAX', reservedWei: reserved.toString() }));
  if (!run) return;
  const root = path.resolve(contractsDir, '..');
  const directory = path.join(root, 'private-keys');
  const filename = path.join(directory, 'fuji-margin-runner.json');
  execFileSync('git', ['check-ignore', '--quiet', '--', filename], { cwd: root, stdio: 'ignore' });
  need(!execFileSync('git', ['ls-files', '--', filename], { cwd: root, encoding: 'utf8' }).trim(), 'Tracked credential');
  need(same(publicInfo(directory).address, A.runner), 'Wrong wallet');
  const log = journal(directory);
  try {
    const record = JSON.parse(fs.readFileSync(filename, 'utf8'));
    need(record.chainId === 43113 && record.version === 1, 'Wrong credential');
    const signer = new Wallet(record.privateKey);
    need(same(signer.address, A.runner), 'Wrong signer');
    await executeBatch({ batch, provider, signer, ...guards, log, gasPrice, balance });
    await guards.finished();
    log.write({ phase: 'verified' });
    console.log('Fuji mock batch verified. pTokens remain in margin; no withdrawal.');
  } finally { log.close(); }
}

if (require.main === module) main().catch(() => {
  // Exceptions from signing/RPC may contain raw signed transactions. Never print them.
  console.error('Runner stopped. No automatic retry/resume. Review public receipts and the private journal before any further action.');
  process.exitCode = 1;
});
module.exports = { A, TOKEN, EXEC, CAP, sequence, validateBatch, reserveGas, journal, executeBatch, liveGuards };

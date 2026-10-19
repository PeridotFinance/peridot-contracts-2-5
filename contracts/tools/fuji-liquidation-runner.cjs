'use strict';

// Fuji MOCK ONLY. One case per invocation. Never reuse the completed round-trip journal.
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { Wallet, providers, Contract, utils, BigNumber: BN } = require('ethers');
const { A, EXEC } = require('./fuji-margin-runner.cjs');
const { publicInfo } = require('./fuji-test-wallet.cjs');
const RPC = 'https://api.avax-test.network/ext/bc/C/rpc';
// Serialize public RPC requests, including receipt polling, to avoid bursts midway through price stress.
function requestGate(intervalMs = 200) {
  let tail = Promise.resolve(),
    next = 0;
  return (fn) => {
    const task = tail.then(async () => {
      const wait = Math.max(0, next - Date.now());
      if (wait) await new Promise((resolve) => setTimeout(resolve, wait));
      next = Date.now() + intervalMs;
      return fn();
    });
    tail = task.catch(() => {});
    return task;
  };
}
class FujiProvider extends providers.JsonRpcProvider {
  constructor() {
    super(RPC);
    this.gate = requestGate();
  }
  send(method, params) {
    return this.gate(() => super.send(method, params));
  }
}
const DIR = path.resolve(__dirname, '..');
const PRIVATE = path.resolve(DIR, '../private-keys');
const CAP = utils.parseEther('0.025'); // Eight cases, INCLUDING recovery: <=0.20 test AVAX.
const RECOVERY_GAS = 200000; // Two baseline feed writes, 100k each, reserved before any trade.
const I = new utils.Interface([
  ...EXEC.fragments,
  'function liquidate((uint256 id,uint16 fractionBps,uint256 maxFeeShares,uint256 maxCollateralSharesToSell,uint256 minTradeDebtOut,uint256 minCollateralDebtOut,uint256 minSurplusUsdc,uint256 deadline,bytes tradeData,bytes collateralData,bytes surplusData),uint256)',
  'function setAnswer(int256)',
  'function exchangeRateCurrent()',
]);
const same = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();
const eq = (a, b) => BN.from(a).eq(b);
function need(ok, message) {
  if (!ok) throw new Error(message);
}
function spec(n) {
  need(Number.isInteger(n) && n >= 0 && n < 8, 'Case must be 0..7');
  return {
    n,
    id: 17 + n,
    short: !!(n % 2),
    full: n % 4 >= 2,
    collateral: n < 4 ? A.usdCollateral : A.avaxCollateral,
    shares: BN.from(n < 4 ? '50000000000' : '5000000000'),
    stress: [870000000, 1130000000, 500000000, 2000000000, 880000000, 1160000000, 500000000, 2000000000][n],
    insurance: BN.from(n % 4 < 2 ? 0 : n % 2 ? '5000000000000000000' : '50000000'),
  };
}
function sequence(n) {
  const s = spec(n);
  const feed = (tag, to, value) => ({
    tag,
    from: A.owner,
    to,
    fn: 'setAnswer',
    args: [value],
    gas: 100000,
  });
  return [
    feed('usd', A.usdFeed, 100000000),
    feed('baseline', A.avaxFeed, 1000000000),
    ...[A.pUsd, A.pAvax, A.usdCollateral, A.avaxCollateral].map((to, i) => ({
      tag: `accrue${i}`,
      from: A.runner,
      to,
      fn: 'exchangeRateCurrent',
      args: [],
      gas: 200000,
    })),
    {
      tag: 'open',
      from: A.runner,
      to: A.executor,
      fn: 'openPosition',
      gas: 16000000,
    },
    feed('stress', A.avaxFeed, s.stress),
    {
      tag: 'liquidate',
      from: A.owner,
      to: A.executor,
      fn: 'liquidate',
      gas: 12000000,
    },
    feed('restore', A.avaxFeed, 1000000000),
    ...(s.full
      ? []
      : [
          {
            tag: 'close',
            from: A.runner,
            to: A.executor,
            fn: 'closePosition',
            gas: 6000000,
          },
        ]),
  ];
}

function validate(artifact, n, now, nonces) {
  const s = spec(n),
    steps = sequence(n),
    next = { ...nonces };
  need(artifact.transactions?.length === steps.length, 'Unexpected call count');
  return steps.map((step, index) => {
    const e = artifact.transactions[index],
      t = e.transaction;
    const actor = same(step.from, A.owner) ? 'owner' : 'runner';
    need(
      e.transactionType === 'CALL' && (step.tag === 'open' || !e.additionalContracts?.length),
      'Unexpected deployment'
    );
    need(
      t &&
        same(t.from, step.from) &&
        same(t.to, step.to) &&
        eq(t.chainId, 43113) &&
        eq(t.value || 0, 0) &&
        eq(t.nonce, next[actor]++),
      'Envelope outside scope'
    );
    const p = I.parseTransaction({ data: t.input });
    need(p.name === step.fn && same(I.encodeFunctionData(p.name, p.args), t.input), 'Function/order/encoding');
    if (step.args) need(same(t.input, I.encodeFunctionData(step.fn, step.args)), 'Changed fixed argument');
    else {
      const q = p.args[0];
      need(q.deadline.gte(now + 600) && q.deadline.lte(now + 3600), 'Deadline outside one-hour window');
      if (step.tag === 'open') {
        need(
          same(q.collateral, s.collateral) &&
            q.short === s.short &&
            eq(q.collateralShares, s.shares) &&
            eq(q.leverageX100, 500) &&
            eq(q.maxFeeShares, s.shares.div(100)) &&
            q.minPositionOut.gt(0) &&
            q.swapData === '0x',
          'Open scope'
        );
      } else {
        need(
          eq(q.id, s.id) &&
            eq(q.fractionBps, step.tag === 'close' || s.full ? 10000 : 5000) &&
            eq(q.maxFeeShares, step.tag === 'close' ? s.shares.div(100) : 0) &&
            eq(q.maxCollateralSharesToSell, step.tag === 'close' ? s.shares.div(5) : 0) &&
            q.minTradeDebtOut.gt(0) &&
            eq(q.minCollateralDebtOut, 0) &&
            eq(q.minSurplusUsdc, 0) &&
            [q.tradeData, q.collateralData, q.surplusData].every((x) => x === '0x'),
          'Exit scope'
        );
        if (step.tag === 'liquidate') need(eq(p.args[1], s.insurance), 'Insurance scope');
      }
    }
    return {
      step,
      tx: {
        to: step.to,
        data: t.input,
        value: 0,
        nonce: Number(t.nonce),
        chainId: 43113,
        gasLimit: step.gas,
        type: 0,
      },
    };
  });
}
function reserve(batch, gasPrice, balances) {
  need(gasPrice.gt(0), 'Zero gas price');
  const costs = { owner: BN.from(RECOVERY_GAS), runner: BN.from(0) };
  for (const b of batch) {
    const who = same(b.step.from, A.owner) ? 'owner' : 'runner';
    costs[who] = costs[who].add(b.tx.gasLimit);
  }
  for (const who of ['owner', 'runner']) costs[who] = costs[who].mul(gasPrice);
  need(costs.owner.add(costs.runner).lte(CAP), 'Case plus recovery exceeds 0.025 test AVAX');
  need(costs.owner.lte(balances.owner) && costs.runner.lte(balances.runner), 'Insufficient signer balance');
  return costs;
}
function privatePath(file, directory = false) {
  const st = fs.lstatSync(file);
  need(
    !st.isSymbolicLink() &&
      (directory ? st.isDirectory() : st.isFile() && st.nlink === 1) &&
      (st.mode & 0o077) === 0 &&
      (!process.getuid || st.uid === process.getuid()),
    'Unsafe private path'
  );
}
function filename(directory, n) {
  spec(n);
  return path.join(directory, `fuji-liquidation-v1-case-${n}.jsonl`);
}
function readJournal(directory, n) {
  privatePath(directory, true);
  const file = filename(directory, n);
  privatePath(file);
  const text = fs.readFileSync(file, 'utf8');
  need(text.endsWith('\n'), 'Truncated journal');
  const records = text
    .trim()
    .split('\n')
    .map((x) => JSON.parse(x));
  need(records[0].phase === 'start' && records[0].case === n && records[0].chainId === 43113, 'Wrong journal');
  return records;
}
function journal(directory, n, append = false) {
  privatePath(directory, true);
  const file = filename(directory, n);
  if (append) readJournal(directory, n);
  const fd = fs.openSync(
    file,
    (append ? fs.constants.O_APPEND : fs.constants.O_CREAT | fs.constants.O_EXCL) |
      fs.constants.O_WRONLY |
      fs.constants.O_NOFOLLOW,
    0o600
  );
  // Persist the directory entry as well as each record before signing/submission.
  const parent = fs.openSync(directory, fs.constants.O_RDONLY);
  try {
    fs.fsyncSync(parent);
  } finally {
    fs.closeSync(parent);
  }
  return {
    write(r) {
      fs.writeSync(fd, JSON.stringify(r) + '\n');
      fs.fsyncSync(fd);
    },
    close() {
      fs.closeSync(fd);
    },
  };
}
function lock(directory) {
  privatePath(directory, true);
  const file = path.join(directory, 'fuji-liquidation-v1.active');
  const fd = fs.openSync(file, 'wx', 0o600);
  fs.writeSync(fd, JSON.stringify({ pid: process.pid }) + '\n');
  fs.fsyncSync(fd);
  return () => {
    fs.closeSync(fd);
    fs.unlinkSync(file);
  };
}

async function networkNonce(provider, from, nonce) {
  need((await provider.getNetwork()).chainId === 43113, 'Fuji only');
  const [latest, pending] = await Promise.all(['latest', 'pending'].map((t) => provider.getTransactionCount(from, t)));
  need(latest === nonce && pending === latest, 'Changed nonce or pending transaction');
}
async function canonicalReceipt(provider, hash, tx, from) {
  const [r, actual] = await Promise.all([provider.getTransactionReceipt(hash), provider.getTransaction(hash)]);
  need(r && actual && same(r.transactionHash, hash) && same(r.from, from) && same(r.to, tx.to), 'Unknown receipt');
  need(
    same(actual.hash, hash) &&
      actual.chainId === 43113 &&
      same(actual.from, from) &&
      same(actual.to, tx.to) &&
      actual.nonce === tx.nonce &&
      eq(actual.value, 0) &&
      same(actual.data, tx.data) &&
      eq(actual.gasLimit, tx.gasLimit) &&
      eq(actual.gasPrice, tx.gasPrice),
    'Mismatched mined intent'
  );
  need(same((await provider.getBlock(r.blockNumber)).hash, r.blockHash), 'Noncanonical receipt');
  return r;
}
async function send({ item, provider, sign, log, gasPrice, guard, after }) {
  const { step, tx } = item;
  await networkNonce(provider, step.from, tx.nonce);
  await guard(item); // May update ONLY a live quote; never amounts, deadlines, or scope.
  const request = { ...tx, gasPrice };
  need((await provider.estimateGas({ ...request, from: step.from })).lte(tx.gasLimit), 'Gas limit exceeded');
  log.write({ phase: 'intent', tag: step.tag, from: step.from, tx: request });
  const raw = await sign(step.from, request);
  const decoded = utils.parseTransaction(raw);
  need(
    same(decoded.from, step.from) &&
      same(
        utils.serializeTransaction(request),
        utils.serializeTransaction({
          to: decoded.to,
          data: decoded.data,
          value: decoded.value,
          nonce: decoded.nonce,
          chainId: decoded.chainId,
          gasLimit: decoded.gasLimit,
          gasPrice: decoded.gasPrice,
          type: decoded.type,
        })
      ),
    'Signer changed transaction'
  );
  const hash = utils.keccak256(raw);
  log.write({ phase: 'signed', tag: step.tag, hash });
  // A password prompt may take time. Recheck state/nonce/estimate AFTER signing, without changing signed data.
  await networkNonce(provider, step.from, tx.nonce);
  const copy = { step, tx: { ...request } };
  await guard(copy);
  need(same(copy.tx.data, request.data), 'Quote changed while signing; stop without submission');
  need((await provider.estimateGas({ ...request, from: step.from })).lte(tx.gasLimit), 'Post-sign gas limit');
  need(same((await provider.sendTransaction(raw)).hash, hash), 'Broadcast mismatch');
  await provider.waitForTransaction(hash, 1, 120000);
  const r = await canonicalReceipt(provider, hash, request, step.from);
  log.write({
    phase: 'mined',
    tag: step.tag,
    hash,
    status: r.status,
    block: r.blockNumber,
    gasUsed: r.gasUsed.toString(),
  });
  need(r.status === 1, 'Transaction reverted');
  await after(item);
}

function contract(name, address, provider) {
  const source = name === 'FujiMockPriceFeed' ? 'FujiMockAssets' : name;
  return new Contract(
    address,
    JSON.parse(fs.readFileSync(path.join(DIR, 'out', `${source}.sol`, `${name}.json`))).abi,
    provider
  );
}
async function guards(provider, n) {
  const s = spec(n),
    e = contract('CollateralPreservingExecutor', A.executor, provider);
  const risk = contract('CollateralPreservingRiskEngine', A.risk, provider);
  const config = contract('IsolatedMarginConfigUpgradeable', A.config, provider);
  const vault = contract('IsolatedMarginVaultUpgradeable', A.vault, provider);
  const feeds = [A.usdFeed, A.avaxFeed].map((a) => contract('FujiMockPriceFeed', a, provider));
  const token = (a) => contract('PErc20', a, provider);
  const quoter = contract('IsolatedMarginQuoter', await e.quoter(), provider);
  const insurance = await config.insuranceFund();
  need(same(insurance, '0x05067da6ec3b3f20A6ed20e4656596E9e5926C58'), 'Insurance wiring');
  const debtMarket = token(s.short ? A.pAvax : A.pUsd);
  const cash = token(await debtMarket.underlying());
  let before;
  async function prices(expected, fresh) {
    const block = await provider.getBlock('latest');
    for (let i = 0; i < 2; i++) {
      need(
        same(await feeds[i].owner(), A.owner) && eq(await feeds[i].answer(), i ? expected : 100000000),
        'Feed owner/price changed'
      );
      if (fresh) {
        const updated = Number(await feeds[i].updatedAt());
        need(updated <= block.timestamp && block.timestamp - updated <= 900, 'Stale feed');
      }
    }
  }
  async function policy() {
    need((await provider.getNetwork()).chainId === 43113, 'Fuji only');
    need(
      same(await e.risk(), A.risk) &&
        same(await e.config(), A.config) &&
        same(await e.vault(), A.vault) &&
        same(await risk.owner(), A.owner) &&
        same(await risk.executor(), A.executor) &&
        same(await vault.executor(), A.executor) &&
        same(await config.owner(), A.owner) &&
        eq(await e.executionVersion(), utils.id('collateral-preserving-executor-v1')),
      'Changed wiring/owner'
    );
    need(!(await config.opensPaused()), 'Opens paused');
    for (const [fn, v] of Object.entries({
      actionDelay: 3600,
      openFeeBps: 10,
      closeFeeBps: 10,
      depositorShareBps: 5000,
      insuranceShareBps: 5000,
      treasuryShareBps: 0,
      feeImmediateShareBps: 0,
      feeStreamDuration: 604800,
    }))
      need(eq(await config[fn](), v), 'Changed fees/timelock');
    need(
      eq(await risk.usdCollateralWeightBps(), 10000) && eq(await risk.avaxCollateralWeightBps(), 10000),
      'Changed weights'
    );
    const expected = [
      true,
      500,
      2000,
      1000,
      12500,
      5000,
      5000,
      500,
      100,
      100,
      utils.parseEther('10000'),
      utils.parseEther('5000'),
    ];
    for (const c of [A.usdCollateral, A.avaxCollateral]) {
      need(eq(await token(c).allowance(A.runner, A.vault), 0), 'Unexpected approval');
      for (const short of [false, true]) {
        const p = await config.getPairRisk(c, short ? A.pUsd : A.pAvax, short ? A.pAvax : A.pUsd);
        need(
          p.every((x, i) => (i ? eq(x, expected[i]) : x === expected[i])),
          'Changed pair'
        );
      }
    }
  }
  async function finishedPosition(id, status) {
    const p = await e.positions(id),
      a = await risk.accounts(p.account);
    need(
      same(p.owner, A.runner) &&
        eq(a.status, status) &&
        eq(p.locked, 0) &&
        eq(await token(p.debt).borrowBalanceStored(p.account), 0) &&
        eq(await token(p.position).balanceOf(p.account), 0) &&
        eq(await token(p.collateral).balanceOf(p.account), 0),
      'Unfinished account'
    );
  }
  async function noDebt() {
    for (const a of [A.pUsd, A.pAvax]) need(eq(await token(a).totalBorrows(), 0), 'Aggregate debt');
    for (const a of [A.usdCollateral, A.avaxCollateral])
      need(eq(await vault.lockedBalance(A.runner, a), 0), 'Locked collateral');
  }
  async function initial() {
    await policy();
    await prices(1000000000, false);
    await noDebt();
    need(eq(await e.nextPositionId(), s.id), 'History/replay');
    for (let id = 5; id < s.id; id++) await finishedPosition(id, id < 17 || (id - 17) % 4 < 2 ? 5 : 6);
    need(
      (await vault.freeBalance(A.runner, s.collateral)).gte(s.shares.mul(101).div(100)),
      'Insufficient existing margin'
    );
    need((await cash.balanceOf(insurance)).gte(s.insurance), 'Insufficient insurance');
  }
  async function guard(item) {
    const { step, tx } = item;
    await policy();
    const stressed = ['liquidate', 'restore'].includes(step.tag);
    await prices(stressed ? s.stress : 1000000000, !['usd', 'baseline'].includes(step.tag));
    if (step.args) {
      if (step.tag === 'stress') {
        const p = await e.positions(s.id);
        need(eq(await e.nextPositionId(), s.id + 1) && same(p.owner, A.runner), 'Stress history');
        const m = (await risk.snapshot(p.account, 0)).metrics;
        need(!m.liquidatable && m.healthFactorBps.gte(20000), 'Unsafe before stress');
      }
      return;
    }
    const args = [...I.decodeFunctionData(step.fn, tx.data)],
      p = [...args[0]];
    const now = (await provider.getBlock('latest')).timestamp;
    need(BN.from(p[step.tag === 'open' ? 6 : 7]).gte(now + 300), 'Deadline near expiry');
    if (step.tag === 'open') {
      need(eq(await e.nextPositionId(), s.id), 'Open history');
      await noDebt();
      need(eq(await risk.pTokenValue(s.collateral, s.shares), utils.parseEther('10')), 'Changed collateral NAV');
      p[5] = (await risk.quoteOpen(s.collateral, s.short, s.shares, 500))[1];
      need(p[5].gt(0), 'Zero quote');
    } else {
      const pos = await e.positions(s.id);
      need(
        eq(await e.nextPositionId(), s.id + 1) && same(pos.owner, A.runner) && same(pos.collateral, s.collateral),
        'Exit history'
      );
      const position = token(pos.position),
        debt = token(pos.debt);
      const amount = (await position.balanceOf(pos.account))
        .mul(p[1])
        .div(10000)
        .mul(await position.exchangeRateStored())
        .div(utils.parseEther('1'));
      p[4] = (await quoter.expectedOut(await position.underlying(), await debt.underlying(), amount)).mul(99).div(100);
      need(p[4].gt(0), 'Zero exit quote');
      if (step.tag === 'liquidate') {
        const m = (await risk.snapshot(pos.account, 0)).metrics;
        need(m.liquidatable && (!s.full || m.equityUsd.lt(0)), 'Wrong liquidation condition');
        before = {
          cash: await cash.balanceOf(insurance),
          health: m.healthFactorBps,
          debt: await debt.borrowBalanceStored(pos.account),
        };
        need(before.cash.gte(s.insurance), 'Insurance not funded');
      }
    }
    args[0] = p;
    tx.data = I.encodeFunctionData(step.fn, args);
  }
  async function after({ step }) {
    if (step.tag === 'open') {
      const p = await e.positions(s.id),
        m = (await risk.snapshot(p.account, 0)).metrics;
      need(
        !m.liquidatable &&
          m.healthFactorBps.gte(20000) &&
          m.tradingLeverageX100.gte(450) &&
          m.tradingLeverageX100.lte(500) &&
          eq(await token(s.collateral).balanceOf(p.account), s.shares),
        'Entry outside bounds'
      );
      const deadline = (await provider.getBlock('latest')).timestamp + 60;
      const data = I.encodeFunctionData('liquidate', [[s.id, 5000, 0, 0, 1, 0, 0, deadline, '0x', '0x', '0x'], 0]);
      let reason;
      try {
        reason = await provider.call({ from: A.owner, to: A.executor, data });
      } catch (error) {
        reason = error.data;
      }
      need(same(reason, utils.id('UnsafePosition()').slice(0, 10)), 'Healthy liquidation did not reject as expected');
    }
    if (step.tag === 'liquidate') {
      const balance = await cash.balanceOf(insurance);
      if (s.full) {
        need(before.cash.gt(balance) && before.cash.sub(balance).lte(s.insurance), 'Insurance usage');
        await finishedPosition(s.id, 6);
      } else {
        const p = await e.positions(s.id),
          m = (await risk.snapshot(p.account, 0)).metrics;
        const debt = await debtMarket.borrowBalanceStored(p.account);
        need(
          eq(balance, before.cash) && debt.gt(0) && debt.lt(before.debt) && m.healthFactorBps.gt(before.health),
          'Partial liquidation outcome'
        );
      }
    }
    if (step.tag === 'close') await finishedPosition(s.id, 5);
  }
  async function finished() {
    await prices(1000000000, true);
    await noDebt();
    await finishedPosition(s.id, s.full ? 6 : 5);
  }
  // Recovery intentionally ignores opens/policy gates: restoring baseline must remain possible while paused.
  async function recoveryGuard({ step }) {
    need((await provider.getNetwork()).chainId === 43113, 'Fuji only');
    const avax = await feeds[1].answer();
    need(eq(avax, s.stress) || eq(avax, 1000000000), 'Unrelated price change; manual review required');
    need(eq(await feeds[0].answer(), 100000000), 'Unrelated USD price');
    for (const f of feeds) need(same(await f.owner(), A.owner), 'Feed owner changed');
    need(['recoverUsd', 'recoverAvax'].includes(step.tag), 'Recovery scope');
  }
  return {
    initial,
    guard,
    after,
    finished,
    recoveryGuard,
    restored: () => prices(1000000000, true),
  };
}

function simulate(n, rpc = RPC) {
  spec(n);
  execFileSync(
    'forge',
    [
      'script',
      'script/LiquidateFujiMarginRunner.s.sol:LiquidateFujiMarginRunner',
      '--sig',
      'runScenario(uint8)',
      String(n),
      '--rpc-url',
      rpc,
      '--sender',
      A.owner,
      '--legacy',
      '--with-gas-price',
      '1000000000',
      '--compute-units-per-second',
      '40',
      '--skip',
      'P_OFTAdapter.sol',
      '--skip',
      'P_OFTAdapterUpgradeable.sol',
      '--skip',
      'P_OFTAdapterUpgradeable.t.sol',
    ],
    {
      cwd: DIR,
      env: {
        ...process.env,
        FOUNDRY_PROFILE: 'debt_accounting',
        CONFIRM_FUJI_RUNNER_LIQUIDATION: 'true',
      },
      stdio: 'pipe',
      timeout: 240000,
    }
  ); // NO broadcast or signer.
  return JSON.parse(
    fs.readFileSync(path.join(DIR, 'broadcast/LiquidateFujiMarginRunner.s.sol/43113/dry-run/runScenario-latest.json'))
  );
}
async function nonces(provider) {
  const result = {};
  for (const who of ['owner', 'runner']) {
    result[who] = await provider.getTransactionCount(A[who]);
    await networkNonce(provider, A[who], result[who]);
  }
  return result;
}
// Reconcile every signed attempt against canonical chain evidence. Unknown means STOP, not retry.
async function reconcile(provider, records) {
  const start = records[0],
    next = { ...start.nonces };
  let intent;
  for (const r of records.slice(1)) {
    if (r.phase === 'intent') {
      need(!intent, 'Unresolved intent');
      intent = r;
    }
    if (r.phase === 'signed') {
      need(intent && intent.tag === r.tag, 'Missing intent');
      const tx = intent.tx;
      const who = same(intent.from, A.owner) ? 'owner' : 'runner';
      need(tx.nonce === next[who]++, 'Journal nonce gap');
      const receipt = await canonicalReceipt(provider, r.hash, tx, intent.from);
      need(receipt.status === 0 || receipt.status === 1, 'Unknown receipt status');
      intent = undefined;
    }
  }
  need(!intent, 'Unsigned/unresolved intent requires manual review');
  for (const who of ['owner', 'runner']) await networkNonce(provider, A[who], next[who]);
  return next;
}
function recoveryItems(ownerNonce) {
  return [A.usdFeed, A.avaxFeed].map((to, i) => ({
    step: {
      tag: i ? 'recoverAvax' : 'recoverUsd',
      from: A.owner,
      to,
      fn: 'setAnswer',
      args: [i ? 1000000000 : 100000000],
      gas: 100000,
    },
    tx: {
      to,
      data: I.encodeFunctionData('setAnswer', [i ? 1000000000 : 100000000]),
      value: 0,
      nonce: ownerNonce + i,
      chainId: 43113,
      gasLimit: 100000,
      type: 0,
    },
  }));
}
function signer() {
  // Owner key stays in Foundry's encrypted keystore. Only a signature is captured.
  // Each owner signature prompts locally; no password/key flags, files or environment variables.
  let runner;
  return async (from, tx) => {
    if (same(from, A.owner)) {
      const digest = utils.keccak256(utils.serializeTransaction(tx));
      const env = { ...process.env };
      for (const k of Object.keys(env)) if (/^(ETH_|CAST_|PRIVATE_KEY|MNEMONIC)/.test(k)) delete env[k];
      const signature = execFileSync(
        'cast',
        ['wallet', 'sign', '--no-hash', '--account', 'robinhood-deployer', digest],
        {
          cwd: DIR,
          env,
          stdio: ['inherit', 'pipe', 'inherit'],
          encoding: 'utf8',
        }
      ).trim();
      need(
        /^0x[0-9a-f]{130}$/i.test(signature) && same(utils.recoverAddress(digest, signature), A.owner),
        'Wrong owner signature'
      );
      return utils.serializeTransaction(tx, signature);
    }
    need(same(from, A.runner), 'Unknown signer');
    if (!runner) {
      const info = publicInfo(PRIVATE);
      need(same(info.address, A.runner), 'Wrong runner credential');
      runner = new Wallet(JSON.parse(fs.readFileSync(info.filename)).privateKey);
    }
    return runner.signTransaction(tx);
  };
}

function command(args, env) {
  const [mode, raw] = args,
    n = Number(raw);
  need(
    args.length === 2 && ['check', 'run', 'recover'].includes(mode) && raw.length === 1 && /^[0-7]$/.test(raw),
    'Use check/run/recover CASE'
  );
  spec(n);
  if (mode !== 'check')
    need(
      env[mode === 'run' ? 'CONFIRM_FUJI_LIQUIDATION_CASE' : 'CONFIRM_FUJI_LIQUIDATION_RECOVERY'] === raw,
      'Explicit case approval required'
    );
  return { mode, n };
}
async function main() {
  const { mode, n } = command(process.argv.slice(2), process.env);
  const provider = new FujiProvider();
  need((await provider.getNetwork()).chainId === 43113, 'Fuji only');
  const g = await guards(provider, n);
  privatePath(PRIVATE, true);
  for (const file of [filename(PRIVATE, n), path.join(PRIVATE, 'fuji-margin-runner.json')]) {
    execFileSync('git', ['check-ignore', '--quiet', '--', file], {
      cwd: DIR,
      stdio: 'ignore',
    });
    need(
      !execFileSync('git', ['ls-files', '--', file], {
        cwd: DIR,
        encoding: 'utf8',
      }).trim(),
      'Private path tracked'
    );
  }
  const release = lock(PRIVATE); // Also serialize unsigned artifact generation during check.
  try {
    if (mode === 'recover') {
      const records = readJournal(PRIVATE, n);
      need(
        !records.some((r) => ['complete', 'recovery-start', 'recovered'].includes(r.phase)),
        'Completed/already attempted recovery; manual review'
      );
      const next = await reconcile(provider, records);
      const gasPrice = BN.from(records[0].gasPrice);
      const originalCosts = reserve(
        sequence(n).map((step) => ({ step, tx: { gasLimit: step.gas } })),
        gasPrice,
        { owner: CAP, runner: CAP }
      );
      need(originalCosts.owner.add(originalCosts.runner).eq(records[0].reservedTotal), 'Invalid reservation');
      need((await provider.getBalance(A.owner)).gte(gasPrice.mul(RECOVERY_GAS)), 'Recovery gas balance');
      const items = recoveryItems(next.owner);
      for (const item of items) await g.recoveryGuard(item);
      const log = journal(PRIVATE, n, true);
      try {
        log.write({ phase: 'recovery-start' });
        const sign = signer();
        for (const item of items)
          await send({
            item,
            provider,
            sign,
            log,
            gasPrice,
            guard: g.recoveryGuard,
            after: async () => {},
          });
        await g.restored();
        log.write({
          phase: 'recovered',
          note: 'Baseline prices restored ONLY; position may remain open. Case cannot resume.',
        });
        console.log(
          'Baseline prices restored. STOP: review remaining position/debt; no close or liquidation was retried.'
        );
      } finally {
        log.close();
      }
      return;
    }
    // Existing journal is never silently replaced, including after successful recovery.
    need(!fs.existsSync(filename(PRIVATE, n)), 'Case already started');
    for (let previous = 0; previous < n; previous++) {
      const r = readJournal(PRIVATE, previous);
      need(r.at(-1).phase === 'complete', 'Previous case incomplete/recovered');
    }
    await g.initial();
    const starts = await nonces(provider);
    const artifact = simulate(n);
    const batch = validate(artifact, n, (await provider.getBlock('latest')).timestamp, starts);
    const gasPrice = (await provider.getGasPrice()).mul(125).add(99).div(100);
    const balances = {
      owner: await provider.getBalance(A.owner),
      runner: await provider.getBalance(A.runner),
    };
    const costs = reserve(batch, gasPrice, balances);
    await g.initial(); // Recheck after simulation, before signer/journal access.
    console.log(
      JSON.stringify({
        mode,
        case: n,
        calls: batch.length,
        recoveryCallsReserved: 2,
        reservedWei: costs.owner.add(costs.runner).toString(),
        caseGasCap: '0.025 test AVAX',
        insuranceRaw: spec(n).insurance.toString(),
      })
    );
    if (mode === 'check') return;
    const log = journal(PRIVATE, n);
    try {
      log.write({
        phase: 'start',
        case: n,
        chainId: 43113,
        nonces: starts,
        gasPrice: gasPrice.toString(),
        reservedTotal: costs.owner.add(costs.runner).toString(),
      });
      const sign = signer();
      for (const item of batch)
        await send({
          item,
          provider,
          sign,
          log,
          gasPrice,
          guard: g.guard,
          after: g.after,
        });
      await g.finished();
      log.write({ phase: 'complete' });
      console.log('Fuji mock case verified: prices restored, zero debt/locks. No withdrawals.');
    } finally {
      log.close();
    }
  } finally {
    release();
  }
}
if (require.main === module)
  main().catch(() => {
    console.error(
      'Liquidation runner stopped. No automatic retry. Review the private journal and public receipts; recovery requires separate approval.'
    );
    process.exitCode = 1; // Never print RPC/signing exceptions: they can contain sensitive payloads.
  });
module.exports = {
  A,
  I,
  CAP,
  spec,
  sequence,
  validate,
  reserve,
  journal,
  readJournal,
  reconcile,
  recoveryItems,
  send,
  guards,
  simulate,
  nonces,
  canonicalReceipt,
  lock,
  requestGate,
  command,
};

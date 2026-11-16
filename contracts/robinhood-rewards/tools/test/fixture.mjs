// Synthetic, fully offline event fixture for robinhood-ram-root.mjs (the real addresses, made-up history).
import {
  ethers, VAULT, PAIR, RAM, STOCK_MARKET, DOLLAR_MARKET, TIMELOCK, LEDGER, OLD_SIGNER, DEAD,
  TRANSFER_TOPIC, HELD_TOPIC, CHECKPOINT_TOPIC,
} from '../robinhood-ram-root.mjs';

const { utils } = ethers;
const pad = (a) => utils.hexZeroPad(a, 32);
const u = (x) => utils.defaultAbiCoder.encode(['uint256'], [x]);

export const ALICE = utils.getAddress('0x00000000000000000000000000000000000A11CE'.toLowerCase());
export const BOB = utils.getAddress('0x0000000000000000000000000000000000000B0B'.toLowerCase());
export const CAROL = utils.getAddress('0x00000000000000000000000000000000000CA401'.toLowerCase());
export const DAVE = utils.getAddress('0x0000000000000000000000000000000000000DA7'.toLowerCase());
export const POOL = utils.getAddress('0x000000000000000000000000000000000000C0DE'.toLowerCase()); // a contract holder (code below)
export const DELEGATED = utils.getAddress('0x0000000000000000000000000000000000007702'.toLowerCase()); // EIP-7702 delegated EOA
export const SCAN_FROM = 1000;

export function buildFixture() {
  const logs = [];
  let n = 0;
  const tx = (tag) => utils.id(`tx-${tag}`);
  const transfer = (market, block, from, to, value, tag = `t${n}`) => logs.push({ address: market, blockNumber: block, logIndex: n++, transactionHash: tx(tag), topics: [TRANSFER_TOPIC, pad(from), pad(to)], data: u(value) });
  const checkpoint = (block, benchmark, pnl, stock, usdg, tag) => logs.push({ address: VAULT, blockNumber: block, logIndex: n++, transactionHash: tx(tag), topics: [CHECKPOINT_TOPIC, PAIR],
    data: utils.defaultAbiCoder.encode(['uint256', 'uint256', 'uint256', 'int256', 'uint256', 'uint256'], [stock, usdg, benchmark, pnl, stock, usdg]) });
  const held = (block, amount, tag, token = RAM, pair = PAIR) => logs.push({ address: VAULT, blockNumber: block, logIndex: n++, transactionHash: tx(tag), topics: [HELD_TOPIC, pair, pad(token)], data: u(amount) });

  // seeds: timelock mints and burns most of it to 0xdEaD (as the real deployment did)
  transfer(STOCK_MARKET, 1010, STOCK_MARKET, TIMELOCK, 105_000_000n);
  transfer(STOCK_MARKET, 1010, TIMELOCK, DEAD, 100_000_000n);
  transfer(DOLLAR_MARKET, 1010, DOLLAR_MARKET, TIMELOCK, 50_000_000_000n);
  transfer(DOLLAR_MARKET, 1010, TIMELOCK, DEAD, 100_000_000n);
  held(1050, 7n * 10n ** 15n, 'early'); // before any checkpoint: unattributed -> protocol
  // depositors
  transfer(STOCK_MARKET, 1200, STOCK_MARKET, ALICE, 300_000_000n);
  transfer(DOLLAR_MARKET, 1250, DOLLAR_MARKET, DAVE, 20_000_000_000n);
  transfer(STOCK_MARKET, 1300, STOCK_MARKET, BOB, 100_000_000n);
  transfer(DOLLAR_MARKET, 1350, DOLLAR_MARKET, ALICE, 10_000_000_000n);
  transfer(STOCK_MARKET, 1400, STOCK_MARKET, POOL, 200_000_000n);
  transfer(STOCK_MARKET, 1450, STOCK_MARKET, LEDGER, 100_000_000n);
  transfer(STOCK_MARKET, 1460, STOCK_MARKET, DELEGATED, 50_000_000n);
  transfer(STOCK_MARKET, 1500, ALICE, CAROL, 100_000_000n);
  transfer(DOLLAR_MARKET, 1600, DOLLAR_MARKET, OLD_SIGNER, 5_000_000_000n);
  transfer(STOCK_MARKET, 1700, BOB, STOCK_MARKET, 100_000_000n); // bob redeems everything
  // harvest 1: checkpoint then held in the same tx; stock $8, usdg $5 (+pnl 0)
  checkpoint(1800, 13n * 10n ** 18n, 0n, 10n ** 16n, 5_000_000n, 'h1');
  held(1800, 3n * 10n ** 16n, 'h1');
  held(1800, 5n * 10n ** 16n, 'h1-other', '0x00000000000000000000000000000000000000aa'); // another reward token: ignored
  held(1810, 1n * 10n ** 16n, 'otherpair', RAM, utils.id('OTHER')); // another pair: ignored
  checkpoint(1900, 14n * 10n ** 18n, -1n * 10n ** 18n, 10n ** 16n, 5_000_000n, 'ck'); // a loss branch: value 13 => stock 8
  held(2000, 2n * 10n ** 16n, 'pending'); // claimPendingRewards: no checkpoint in its tx, uses the one at 1900
  // harvest 3 = end of epoch 0: gain branch, stock $12 usdg $8
  checkpoint(2500, 19n * 10n ** 18n, 1n * 10n ** 18n, 15n * 10n ** 15n, 8_000_000n, 'h3');
  held(2500, 4n * 10n ** 16n, 'h3');
  // epoch 1
  transfer(DOLLAR_MARKET, 2600, DAVE, CAROL, 10_000_000_000n);
  checkpoint(3000, 10n * 10n ** 18n, 0n, 0n, 10_000_000n, 'h4'); // stock side empty: all to rpUSDGs
  held(3000, 1n * 10n ** 16n, 'h4');

  return {
    chainId: 4663,
    head: 3100,
    timeModel: { block: 1000, ts: 1_800_000_000, interval: 2 },
    code: { [POOL]: '0x6080604052', [TIMELOCK]: '0x60806040', [DELEGATED]: `0xef0100${'11'.repeat(20)}` },
    logs,
  };
}

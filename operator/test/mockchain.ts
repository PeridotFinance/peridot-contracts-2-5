// A tiny in-memory chain for the executor / monitor / keeper tests: just enough of the controller, the oracle, three pTokens and USDC to run
// `readBlockSnapshot`, `readAccountInputs`, a liquidation round and its read-back. Test use only; no network.
import { BigNumber, utils } from "ethers";
import { CONTROLLER_ABI, ERC20_ABI, MULTICALL3_ABI, ORACLE_ABI, PTOKEN_ABI } from "../src/abi";
import { UNIV3_POOL_WAVAX_USDC_500, USDC, WAVAX } from "../src/constants";
import { poolIface } from "../src/reference";
import { wavaxReferenceFromTick } from "../src/tickmath";
import { A } from "./fixtures";
import { wrapperIface } from "../src/poke";

const ctrl = new utils.Interface(CONTROLLER_ABI);
const pt = new utils.Interface(PTOKEN_ABI);
const erc = new utils.Interface(ERC20_ABI);
const orc = new utils.Interface(ORACLE_ABI);
const mc = new utils.Interface(MULTICALL3_ABI);

export const ADDR = {
  controller: A(1),
  pWavax: A(0x11),
  pUsdc: A(0x12),
  guarded: A(0x13),
  wrapper: A(0x14),
  pShare: A(0x15),
  vault: A(0x16),
  operator: A(0x101),
  borrower: A(0x500),
  other: A(0x501),
};
const lc = (a: string) => a.toLowerCase();
const E18 = 10n ** 18n;
/** the oracle's WAVAX price in the mock = the pool TWAP reference at tick -254599 (about USD 8.8), so the reference agrees with the oracle */
export const WAVAX_PRICE = wavaxReferenceFromTick(-254599, 10n ** 30n);

export interface MockAccount {
  debt: bigint; // pUSDC borrow balance (USDC units)
  pWavax?: bigint;
  pShare?: bigint;
  shortfall: boolean;
}
export class MockChain {
  block = 1000;
  ts = 1_700_000_000;
  oracle = ADDR.guarded;
  /** markets listed; the share market is appended when `listShare` */
  listShare = true;
  prices: Record<string, bigint> = { [lc(ADDR.pWavax)]: WAVAX_PRICE, [lc(ADDR.pUsdc)]: 10n ** 30n, [lc(ADDR.pShare)]: 102n * 10n ** 28n };
  exch: Record<string, bigint> = { [lc(ADDR.pWavax)]: 2n * 10n ** 26n, [lc(ADDR.pUsdc)]: 2n * 10n ** 14n, [lc(ADDR.pShare)]: 2n * 10n ** 14n };
  li = 108n * 10n ** 16n;
  cf = 5n * 10n ** 17n;
  protocolShare = 28n * 10n ** 15n; // 2.8%
  accounts: Record<string, MockAccount> = {};
  usdc: Record<string, bigint> = {};
  pBal: Record<string, Record<string, bigint>> = {}; // pToken -> holder -> balance
  allowance = 0n; // operator -> pUSDC
  sent: Array<{ to: string; data: string; name: string }> = [];
  /** fault injection: the liquidator receives this many fewer pTokens than the event says */
  shortReceive = 0n;
  /** if set, a liquidateBorrow simulation (eth_call) returns this error code */
  simulateCode = 0n;
  vaultUnderlying = ADDR.vault;
  /** wrapper v2 (PharaohDlmmShareOracle): the vault leg (assets per whole share, 6 decimals; 0 = the vault cannot answer), the stored fallback value and its time */
  vaultLive = 1_020_000n;
  lastGood = 1_020_000n;
  lastGoodTime = 1_700_000_000 - 4_000;
  /** v3: the vault fails with something OTHER than FeedInvalid (e.g. ExitFailed): live leg 0, NO fallback (the wrapper prices 0 at once); set `vaultLive = 0n` with it */
  vaultBroken = false;
  /** the base oracle's USDC price is usable (false: the wrapper never serves a fallback) */
  assetUsdOk = true;
  /** when set, the wrapper's own getUnderlyingPrice for ANY market returns this (monitor tests); otherwise `prices` */
  wrapperPrice: bigint | undefined;
  /** the next poke transaction is mined with status 0 */
  pokeTxReverts = false;
  /** a poke transaction does not move the stored value (simulates a node/contract that ignored it) */
  pokeTxNoop = false;
  pokeGas = 70_000;
  /** poke() simulates/executes as `false` although the vault answers (a race, or a wrapper that refuses) */
  forcePokeFalse = false;
  /** a call of poke() reverts (eth_call) */
  pokeCallReverts = false;
  /** extra pending transactions of the operator wallet (pending nonce - latest nonce) */
  pendingExtra = 0;
  private nonce = 0;
  private receipts: Record<string, any> = {};

  constructor() {
    this.usdc[lc(ADDR.operator)] = 1_000_000_000n;
  }
  markets(): string[] {
    return [ADDR.pWavax, ADDR.pUsdc, ...(this.listShare ? [ADDR.pShare] : [])];
  }
  private pbal(p: string, who: string): bigint {
    const acct = this.accounts[lc(who)];
    if (this.pBal[lc(p)]?.[lc(who)] !== undefined) return this.pBal[lc(p)]![lc(who)]!;
    if (acct && lc(p) === lc(ADDR.pWavax)) return acct.pWavax ?? 0n;
    if (acct && lc(p) === lc(ADDR.pShare)) return acct.pShare ?? 0n;
    return 0n;
  }
  private setPbal(p: string, who: string, v: bigint): void {
    (this.pBal[lc(p)] ??= {})[lc(who)] = v;
  }
  seizeTokens(repay: bigint, collateral: string): bigint {
    return (repay * this.li * this.prices[lc(ADDR.pUsdc)]!) / (this.prices[lc(collateral)]! * this.exch[lc(collateral)]!);
  }

  // ------------------------------------------------------------------ eth_call
  private callOne(to: string, data: string, from?: string): { ok: boolean; ret: string } {
    const T = lc(to);
    const sel = data.slice(0, 10);
    const fail = { ok: false, ret: "0x" };
    const enc = (i: utils.Interface, fn: string, v: unknown[]) => ({ ok: true, ret: i.encodeFunctionResult(fn, v) });
    const fnOf = (i: utils.Interface): string | undefined => {
      try {
        return i.getFunction(sel).name;
      } catch {
        return undefined;
      }
    };
    if (T === lc(ADDR.controller)) {
      const fn = fnOf(ctrl);
      if (!fn) return fail;
      const args = ctrl.decodeFunctionData(fn, data);
      switch (fn) {
        case "getAllMarkets": return enc(ctrl, fn, [this.markets()]);
        case "oracle": return enc(ctrl, fn, [this.oracle]);
        case "liquidationIncentiveMantissa": return enc(ctrl, fn, [this.li]);
        case "closeFactorMantissa": return enc(ctrl, fn, [this.cf]);
        case "admin": return enc(ctrl, fn, [A(0x900)]);
        case "pauseGuardian": return enc(ctrl, fn, [A(0x901)]);
        case "markets": return enc(ctrl, fn, [true, lc(args[0]) === lc(ADDR.pWavax) ? 3n * 10n ** 17n : 0n, false]);
        case "borrowCaps": return enc(ctrl, fn, [200_000_000n]);
        case "borrowCashFloor": return enc(ctrl, fn, [0n]);
        case "mintGuardianPaused": return enc(ctrl, fn, [false]);
        case "borrowGuardianPaused": return enc(ctrl, fn, [lc(args[0]) !== lc(ADDR.pUsdc)]);
        case "isolatedMarginAccounts": return enc(ctrl, fn, [false]);
        case "getAccountLiquidity": {
          const a = this.accounts[lc(args[0])];
          return enc(ctrl, fn, [0n, a && !a.shortfall ? E18 : 0n, a?.shortfall ? E18 : 0n]);
        }
        case "liquidateCalculateSeizeTokens": return enc(ctrl, fn, [0n, this.seizeTokens(BigInt(args[2].toString()), args[1])]);
        default: return fail;
      }
    }
    if (T === lc(ADDR.wrapper)) {
      const fn = fnOf(wrapperIface);
      if (fn === "shareState") {
        const age = Math.max(0, this.ts - this.lastGoodTime);
        const left = age > 86_400 ? 0 : 86_400 - age;
        return enc(wrapperIface, fn, [this.vaultLive, this.lastGood, this.lastGoodTime, this.vaultLive === 0n && !this.vaultBroken && age <= 86_400 && this.assetUsdOk, left]);
      }
      if (fn === "poke") return this.pokeCallReverts ? fail : enc(wrapperIface, fn, [this.pokeOutcome().stored]);
      if (fn === "getUnderlyingPrice" && T !== lc(this.oracle)) {
        const p = lc(wrapperIface.decodeFunctionData(fn, data)[0]);
        return enc(wrapperIface, fn, [this.wrapperPrice ?? this.prices[p] ?? 0n]);
      }
    }
    if (T === lc(this.oracle) || T === lc(ADDR.guarded) || T === lc(ADDR.wrapper)) {
      if (T !== lc(this.oracle)) return fail;
      const fn = fnOf(orc);
      if (fn !== "getUnderlyingPrice") return fail;
      const p = lc(orc.decodeFunctionData(fn, data)[0]);
      return enc(orc, fn, [this.prices[p] ?? 0n]);
    }
    if (T === lc(WAVAX)) {
      const fn = fnOf(erc);
      if (fn === "balanceOf") return enc(erc, fn, [0n]);
      if (fn === "allowance") return enc(erc, fn, [0n]);
      return fail;
    }
    if (T === lc(USDC)) {
      const fn = fnOf(erc);
      if (!fn) return fail;
      const args = erc.decodeFunctionData(fn, data);
      if (fn === "balanceOf") return enc(erc, fn, [this.usdc[lc(args[0])] ?? 0n]);
      if (fn === "allowance") return enc(erc, fn, [lc(args[0]) === lc(ADDR.operator) && lc(args[1]) === lc(ADDR.pUsdc) ? this.allowance : 0n]);
      return fail;
    }
    if (this.markets().some((m) => lc(m) === T)) {
      const fn = fnOf(pt);
      if (!fn) return fail;
      const args = pt.decodeFunctionData(fn, data);
      switch (fn) {
        case "accrueInterest": return enc(pt, fn, [0n]);
        case "underlying": return enc(pt, fn, [T === lc(ADDR.pWavax) ? WAVAX : T === lc(ADDR.pUsdc) ? USDC : this.vaultUnderlying]);
        case "getCash":
        case "totalBorrows":
        case "totalReserves": return enc(pt, fn, [1_000_000_000n]);
        case "totalSupply": return enc(pt, fn, [10n ** 12n]);
        case "exchangeRateStored": return enc(pt, fn, [this.exch[T]!]);
        case "borrowAccountingEnabled": return enc(pt, fn, [true]);
        case "totalBorrowShares": return enc(pt, fn, [0n]);
        case "protocolSeizeShareMantissa": return enc(pt, fn, [this.protocolShare]);
        case "balanceOf": return enc(pt, fn, [this.pbal(T, args[0])]);
        case "borrowShares": return enc(pt, fn, [0n]);
        case "borrowBalanceStored": return enc(pt, fn, [this.accounts[lc(args[0])]?.debt ?? 0n]);
        case "getAccountSnapshot": {
          const a = lc(args[0]);
          const debt = T === lc(ADDR.pUsdc) ? this.accounts[a]?.debt ?? 0n : 0n;
          return enc(pt, fn, [0n, this.pbal(T, a), debt, this.exch[T]!]);
        }
        case "liquidateBorrow": {
          if (this.simulateCode !== 0n) return enc(pt, fn, [this.simulateCode]);
          const [borrower, repay, coll] = args;
          const seize = this.seizeTokens(BigInt(repay.toString()), coll);
          if (this.allowance < BigInt(repay.toString()) || this.pbal(coll, borrower) < seize || (this.usdc[lc(from ?? "")] ?? 0n) < BigInt(repay.toString())) return fail;
          return enc(pt, fn, [0n]);
        }
        default: return fail;
      }
    }
    if (T === lc(UNIV3_POOL_WAVAX_USDC_500)) {
      const fn = (() => { try { return poolIface.getFunction(sel).name; } catch { return undefined; } })();
      if (fn === "liquidity") return enc(poolIface, fn, [10n ** 12n]);
      if (fn === "observe") return enc(poolIface, fn, [[0n, -254599n * 1800n], [0n, 0n]]);
      return fail;
    }
    if (T === lc("0xcA11bde05977b3631167028862bE2a173976CA11")) {
      const fn = fnOf(mc);
      if (fn === "getEthBalance") return enc(mc, fn, [10n ** 18n]);
      return fail;
    }
    return fail;
  }

  /** the wrapper's poke() rules (PharaohDlmmShareOracle v2): stores the LIVE leg; refused (false) when the vault cannot answer, or when a fresh stored value would move UP inside 1 h; an upward move is capped at +2% */
  pokeOutcome(): { stored: boolean; value: bigint } {
    if (this.vaultLive === 0n || this.forcePokeFalse) return { stored: false, value: this.lastGood };
    let leg = this.vaultLive;
    const age = this.ts - this.lastGoodTime;
    if (age <= 86_400 && leg > this.lastGood) {
      if (age < 3_600) return { stored: false, value: this.lastGood };
      const cap = (this.lastGood * 10_200n) / 10_000n;
      if (leg > cap) leg = cap;
    }
    return { stored: true, value: leg };
  }

  /** the provider surface the operator code uses */
  provider(): any {
    const self = this;
    return {
      getBlock: async (tag: number | string) => ({ number: typeof tag === "number" ? tag : self.block, timestamp: self.ts }),
      getBlockNumber: async () => self.block,
      getNetwork: async () => ({ chainId: 43114 }),
      getBalance: async () => BigNumber.from(10n ** 18n),
      getTransactionCount: async (_a: string, tag?: string) => (tag === "pending" ? self.pendingExtra : 0),
      getFeeData: async () => ({ maxFeePerGas: utilsGwei(30), maxPriorityFeePerGas: utilsGwei(1), gasPrice: utilsGwei(30) }),
      estimateGas: async (tx?: { to?: string }) => BigNumber.from(tx?.to && lc(tx.to) === lc(ADDR.wrapper) ? self.pokeGas : 300_000),
      getLogs: async () => [],
      call: async (tx: { to: string; data: string; from?: string }) => {
        if (lc(tx.to) === "0xca11bde05977b3631167028862be2a173976ca11" && tx.data.startsWith(mc.getSighash("aggregate3"))) {
          const calls = mc.decodeFunctionData("aggregate3", tx.data)[0] as Array<{ target: string; allowFailure: boolean; callData: string }>;
          const res = calls.map((c) => {
            const r = self.callOne(c.target, c.callData, tx.from);
            return { success: r.ok, returnData: r.ret };
          });
          return mc.encodeFunctionResult("aggregate3", [res]);
        }
        const r = self.callOne(tx.to, tx.data, tx.from);
        if (!r.ok) throw Object.assign(new Error("execution reverted (mock)"), { code: "CALL_EXCEPTION" });
        return r.ret;
      },
      getTransactionReceipt: async (hash: string) => self.receipts[hash],
    };
  }

  /** a signer that applies the transaction to the mock state */
  signer(): any {
    const self = this;
    return {
      kind: "mock",
      getAddress: async () => ADDR.operator,
      sendTransaction: async (tx: { to: string; data: string }) => {
        const hash = "0x" + (++self.nonce).toString(16).padStart(64, "0");
        const T = lc(tx.to);
        let name = "unknown";
        const logs: any[] = [];
        if (T === lc(ADDR.wrapper)) {
          name = "poke";
          if (!self.pokeTxReverts && !self.pokeTxNoop) {
            const o = self.pokeOutcome();
            if (o.stored) {
              self.lastGood = o.value;
              self.lastGoodTime = self.ts;
            }
          }
          self.sent.push({ to: tx.to, data: tx.data, name });
          self.block += 1;
          const reverts = self.pokeTxReverts;
          return { hash, wait: async () => { if (reverts) throw Object.assign(new Error("transaction failed"), { code: "CALL_EXCEPTION" }); return { status: 1, blockNumber: self.block, gasUsed: BigNumber.from(60_000) }; } };
        }
        if (T === lc(USDC)) {
          const d = erc.decodeFunctionData("approve", tx.data);
          name = "approve";
          self.allowance = BigInt(d[1].toString());
        } else if (T === lc(ADDR.pUsdc)) {
          const [borrower, repayBn, coll] = pt.decodeFunctionData("liquidateBorrow", tx.data);
          name = "liquidateBorrow";
          const repay = BigInt(repayBn.toString());
          const seize = self.seizeTokens(repay, coll);
          const liq = seize - (seize * self.protocolShare) / E18;
          self.usdc[lc(ADDR.operator)] = (self.usdc[lc(ADDR.operator)] ?? 0n) - repay;
          self.allowance -= repay;
          self.setPbal(coll, borrower, self.pbal(coll, borrower) - seize);
          self.setPbal(coll, ADDR.operator, self.pbal(coll, ADDR.operator) + liq - self.shortReceive);
          self.accounts[lc(borrower)]!.debt -= repay;
          const ev = pt.encodeEventLog(pt.getEvent("LiquidateBorrow"), [ADDR.operator, borrower, repay, coll, seize]);
          logs.push({ address: ADDR.pUsdc, topics: ev.topics, data: ev.data });
        } else if (self.markets().some((m) => lc(m) === T)) {
          name = pt.getFunction(tx.data.slice(0, 10)).name; // redeem etc.: recorded, the tests assert none happens for the share market
        }
        self.sent.push({ to: tx.to, data: tx.data, name });
        self.block += 1;
        self.receipts[hash] = { blockNumber: self.block, logs, status: 1 };
        return { hash, wait: async () => ({ status: 1, blockNumber: self.block, gasUsed: BigNumber.from(200_000) }) };
      },
    };
  }
  poolBal(p: string, who: string): bigint {
    return this.pbal(p, who);
  }
}
function utilsGwei(n: number): BigNumber {
  return utils.parseUnits(String(n), "gwei");
}

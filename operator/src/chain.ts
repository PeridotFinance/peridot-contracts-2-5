// Block-pinned READ layer. Everything the monitor learns about the chain comes from this module, at ONE explicit block number per cycle.
import { providers, utils } from "ethers";
import { AVAX_FEED, AVAX_GUARD_SECONDS, UNIV3_POOL_WAVAX_USDC_500, USDC, USDC_FEED, USDC_GUARD_SECONDS, WAVAX } from "./constants";
import { CONTROLLER_ABI, ERC20_ABI, FEED_ABI, MULTICALL3_ABI, ORACLE_ABI, PTOKEN_ABI } from "./abi";
import type { MonitorConfig } from "./config";
import { big, multicall } from "./multicall";
import type { Call, CallResult } from "./multicall";
import { interpretReference, OBSERVE_SECONDS_AGO, poolIface } from "./reference";
import type { ReferenceResult } from "./reference";
import type { AccountInput, MarketAccountData } from "./detect";

export const ctrlIface = new utils.Interface(CONTROLLER_ABI);
export const pIface = new utils.Interface(PTOKEN_ABI);
export const oracleIface = new utils.Interface(ORACLE_ABI);
export const feedIface = new utils.Interface(FEED_ABI);
export const erc20Iface = new utils.Interface(ERC20_ABI);
export const mcIface = new utils.Interface(MULTICALL3_ABI);

export interface Ctx {
  provider: providers.Provider;
  cfg: MonitorConfig;
  /** result of the start-up / daily factory check of the pool; false fails the reference closed */
  poolIdentityOk: boolean;
  multicallAddress?: string;
}

export interface MarketStat {
  pToken: string;
  underlying: string;
  cash: bigint;
  totalBorrows: bigint;
  totalReserves: bigint;
  totalSupply: bigint;
  /** exchange rate AFTER accrual in the same batch */
  exchangeRate: bigint;
  collateralFactor: bigint;
  borrowCap: bigint;
  cashFloor: bigint;
  mintPaused: boolean;
  borrowPaused: boolean;
  accountingEnabled: boolean;
  totalBorrowShares: bigint;
  readOk: boolean;
}
export interface FeedStat {
  ok: boolean;
  answer: bigint;
  updatedAt: bigint;
  ageSeconds: bigint;
  guardSeconds: number;
}
export interface BlockSnapshot {
  blockNumber: number;
  blockTimestamp: number;
  liquidationIncentive: bigint;
  closeFactor: bigint;
  markets: MarketStat[];
  oraclePrices: bigint[];
  usdcOraclePrice: bigint;
  feeds: { avax: FeedStat; usdc: FeedStat };
  reference: ReferenceResult;
  operators: Array<{ name: string; address: string; usdc: bigint; avaxWei: bigint; nonce: number }>;
  treasury: { address: string; usdc: bigint; allowanceToPUsdc: bigint };
  controller: { admin: string; pauseGuardian: string };
}

const mcOpts = (ctx: Ctx) => ctx.multicallAddress;

export async function latestBlock(provider: providers.Provider): Promise<{ number: number; timestamp: number }> {
  const b = await provider.getBlock("latest");
  return { number: b.number, timestamp: b.timestamp };
}

export async function readBlockSnapshot(ctx: Ctx, blockNumber: number): Promise<BlockSnapshot> {
  const { provider, cfg } = ctx;
  const dep = cfg.deployment;
  const blk = await provider.getBlock(blockNumber);
  // step A (plain calls at the block): the market list, the oracle address the controller really uses, incentive, close factor
  const callAt = async (to: string, iface: utils.Interface, fn: string, args: unknown[] = []) =>
    iface.decodeFunctionResult(fn, await provider.call({ to, data: iface.encodeFunctionData(fn, args) }, blockNumber));
  const marketsList = (await callAt(dep.controller, ctrlIface, "getAllMarkets"))[0] as string[];
  const oracleAddr = (await callAt(dep.controller, ctrlIface, "oracle"))[0] as string;
  if (oracleAddr.toLowerCase() !== dep.oracle.toLowerCase()) throw new Error("controller oracle() differs from the configured oracle (configuration drift or oracle swap)");
  // step B: one batch. Interest accrues first for every market; the reads that follow see the accrued state.
  const calls: Call[] = [];
  const idx: Record<string, number> = {};
  const add = (key: string, c: Call) => {
    idx[key] = calls.length;
    calls.push(c);
  };
  marketsList.forEach((m, i) => add(`accrue${i}`, { target: m, iface: pIface, fn: "accrueInterest" }));
  add("li", { target: dep.controller, iface: ctrlIface, fn: "liquidationIncentiveMantissa" });
  add("cf", { target: dep.controller, iface: ctrlIface, fn: "closeFactorMantissa" });
  add("admin", { target: dep.controller, iface: ctrlIface, fn: "admin" });
  add("guardian", { target: dep.controller, iface: ctrlIface, fn: "pauseGuardian" });
  marketsList.forEach((m, i) => {
    add(`und${i}`, { target: m, iface: pIface, fn: "underlying" });
    add(`price${i}`, { target: oracleAddr, iface: oracleIface, fn: "getUnderlyingPrice", args: [m] });
    add(`cash${i}`, { target: m, iface: pIface, fn: "getCash" });
    add(`tb${i}`, { target: m, iface: pIface, fn: "totalBorrows" });
    add(`tr${i}`, { target: m, iface: pIface, fn: "totalReserves" });
    add(`ts${i}`, { target: m, iface: pIface, fn: "totalSupply" });
    add(`ex${i}`, { target: m, iface: pIface, fn: "exchangeRateStored" });
    add(`mk${i}`, { target: dep.controller, iface: ctrlIface, fn: "markets", args: [m] });
    add(`cap${i}`, { target: dep.controller, iface: ctrlIface, fn: "borrowCaps", args: [m] });
    add(`floor${i}`, { target: dep.controller, iface: ctrlIface, fn: "borrowCashFloor", args: [m] });
    add(`mp${i}`, { target: dep.controller, iface: ctrlIface, fn: "mintGuardianPaused", args: [m] });
    add(`bp${i}`, { target: dep.controller, iface: ctrlIface, fn: "borrowGuardianPaused", args: [m] });
    add(`acc${i}`, { target: m, iface: pIface, fn: "borrowAccountingEnabled" });
    add(`tbs${i}`, { target: m, iface: pIface, fn: "totalBorrowShares" });
  });
  add("avaxFeed", { target: AVAX_FEED, iface: feedIface, fn: "latestRoundData" });
  add("usdcFeed", { target: USDC_FEED, iface: feedIface, fn: "latestRoundData" });
  add("poolLiq", { target: UNIV3_POOL_WAVAX_USDC_500, iface: poolIface, fn: "liquidity" });
  add("observe", { target: UNIV3_POOL_WAVAX_USDC_500, iface: poolIface, fn: "observe", args: [OBSERVE_SECONDS_AGO] });
  cfg.operators.forEach((o, i) => {
    add(`opUsdc${i}`, { target: USDC, iface: erc20Iface, fn: "balanceOf", args: [o.address] });
    add(`opAvax${i}`, { target: ctx.multicallAddress ?? "0xcA11bde05977b3631167028862bE2a173976CA11", iface: mcIface, fn: "getEthBalance", args: [o.address] });
  });
  add("trUsdc", { target: USDC, iface: erc20Iface, fn: "balanceOf", args: [cfg.treasury.address] });
  add("trAllow", { target: USDC, iface: erc20Iface, fn: "allowance", args: [cfg.treasury.address, dep.pUsdc] });
  const res = await multicall(provider, calls, blockNumber, mcOpts(ctx));
  const R = (k: string): CallResult | undefined => res[idx[k]!];

  const liquidationIncentive = big(R("li")) ?? 0n;
  const closeFactor = big(R("cf")) ?? 0n;
  const markets: MarketStat[] = [];
  const oraclePrices: bigint[] = [];
  marketsList.forEach((m, i) => {
    const mk = R(`mk${i}`);
    const need = ["und", "cash", "tb", "tr", "ts", "ex", "cap", "floor", "mp", "bp"].every((p) => R(`${p}${i}`)?.success);
    markets.push({
      pToken: m,
      underlying: (R(`und${i}`)?.value?.[0] as string | undefined) ?? "0x",
      cash: big(R(`cash${i}`)) ?? 0n,
      totalBorrows: big(R(`tb${i}`)) ?? 0n,
      totalReserves: big(R(`tr${i}`)) ?? 0n,
      totalSupply: big(R(`ts${i}`)) ?? 0n,
      exchangeRate: big(R(`ex${i}`)) ?? 0n,
      collateralFactor: mk?.success && mk.value ? BigInt(mk.value[1].toString()) : 0n,
      borrowCap: big(R(`cap${i}`)) ?? 0n,
      cashFloor: big(R(`floor${i}`)) ?? 0n,
      mintPaused: (R(`mp${i}`)?.value?.[0] as boolean | undefined) ?? false,
      borrowPaused: (R(`bp${i}`)?.value?.[0] as boolean | undefined) ?? false,
      accountingEnabled: (R(`acc${i}`)?.value?.[0] as boolean | undefined) ?? false,
      totalBorrowShares: big(R(`tbs${i}`)) ?? 0n,
      readOk: need,
    });
    oraclePrices.push(big(R(`price${i}`)) ?? 0n);
  });
  const usdcIdx = markets.findIndex((m) => m.underlying.toLowerCase() === USDC.toLowerCase());
  const usdcOraclePrice = usdcIdx >= 0 ? oraclePrices[usdcIdx]! : 0n;

  const feed = (key: string, guard: number): FeedStat => {
    const r = R(key);
    if (!r?.success || !r.value) return { ok: false, answer: 0n, updatedAt: 0n, ageSeconds: BigInt(guard) * 1000n, guardSeconds: guard };
    const answer = BigInt(r.value[1].toString());
    const updatedAt = BigInt(r.value[3].toString());
    const age = BigInt(blk.timestamp) > updatedAt ? BigInt(blk.timestamp) - updatedAt : 0n;
    return { ok: answer > 0n, answer, updatedAt, ageSeconds: age, guardSeconds: guard };
  };
  const reference = interpretReference({
    poolIdentityOk: ctx.poolIdentityOk,
    liquidity: R("poolLiq"),
    observe: R("observe"),
    minPoolLiquidity: BigInt(cfg.reference.minPoolLiquidity),
    usdcOraclePrice,
  });
  const nonces = await Promise.all(cfg.operators.map((o) => provider.getTransactionCount(o.address, blockNumber)));
  return {
    blockNumber,
    blockTimestamp: blk.timestamp,
    liquidationIncentive,
    closeFactor,
    markets,
    oraclePrices,
    usdcOraclePrice,
    feeds: { avax: feed("avaxFeed", AVAX_GUARD_SECONDS), usdc: feed("usdcFeed", USDC_GUARD_SECONDS) },
    reference,
    operators: cfg.operators.map((o, i) => ({ name: o.name, address: o.address, usdc: big(R(`opUsdc${i}`)) ?? 0n, avaxWei: big(R(`opAvax${i}`)) ?? 0n, nonce: nonces[i]! })),
    treasury: { address: cfg.treasury.address, usdc: big(R("trUsdc")) ?? 0n, allowanceToPUsdc: big(R("trAllow")) ?? 0n },
    controller: { admin: (R("admin")?.value?.[0] as string | undefined) ?? "", pauseGuardian: (R("guardian")?.value?.[0] as string | undefined) ?? "" },
  };
}

/** The reference price for each market, aligned with snapshot.markets: WAVAX -> TWAP reference, USDC -> the oracle's own price, else missing (0). */
export function referencePrices(snap: BlockSnapshot): bigint[] {
  return snap.markets.map((m, i) => {
    const u = m.underlying.toLowerCase();
    if (u === WAVAX.toLowerCase()) return snap.reference.status === "ok" ? snap.reference.wavaxReference : 0n;
    if (u === USDC.toLowerCase()) return snap.oraclePrices[i]!; // R_usdc := P_usdc (a USDC de-peg is not covered)
    return 0n;
  });
}

/** Per-account reads at the snapshot's block, accrual first inside each batch. Returns the rule inputs. */
export async function readAccountInputs(ctx: Ctx, snap: BlockSnapshot, accounts: string[], chunk = 20): Promise<Map<string, AccountInput>> {
  const out = new Map<string, AccountInput>();
  const refs = referencePrices(snap);
  const debtIdx = snap.markets.findIndex((m) => m.pToken.toLowerCase() === ctx.cfg.deployment.pUsdc.toLowerCase());
  if (debtIdx < 0) throw new Error("the configured pUSDC is not a listed market of the controller");
  for (let s = 0; s < accounts.length; s += chunk) {
    const part = accounts.slice(s, s + chunk);
    const calls: Call[] = snap.markets.map((m) => ({ target: m.pToken, iface: pIface, fn: "accrueInterest" }));
    const base = calls.length;
    for (const a of part) {
      for (const m of snap.markets) calls.push({ target: m.pToken, iface: pIface, fn: "getAccountSnapshot", args: [a] });
      calls.push({ target: ctx.cfg.deployment.controller, iface: ctrlIface, fn: "getAccountLiquidity", args: [a] });
    }
    const res = await multicall(ctx.provider, calls, snap.blockNumber, ctx.multicallAddress);
    const per = snap.markets.length + 1;
    part.forEach((a, k) => {
      const rs = res.slice(base + k * per, base + (k + 1) * per);
      const markets: MarketAccountData[] = snap.markets.map((_, i) => {
        const r = rs[i]!;
        if (!r.success || !r.value) return { snapshotErr: 1n, pTokenBalance: 0n, borrowBalance: 0n, exchangeRate: 0n, oraclePrice: snap.oraclePrices[i]!, referencePrice: refs[i]! };
        return {
          snapshotErr: BigInt(r.value[0].toString()),
          pTokenBalance: BigInt(r.value[1].toString()),
          borrowBalance: BigInt(r.value[2].toString()),
          exchangeRate: BigInt(r.value[3].toString()),
          oraclePrice: snap.oraclePrices[i]!,
          referencePrice: refs[i]!,
        };
      });
      const liq = rs[snap.markets.length]!;
      out.set(a, {
        debtUnits: markets[debtIdx]!.borrowBalance,
        markets,
        liquidityErr: liq.success && liq.value ? BigInt(liq.value[0].toString()) : 1n,
        shortfall: liq.success && liq.value ? BigInt(liq.value[2].toString()) : 0n,
      });
    });
  }
  return out;
}

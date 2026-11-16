// READS. Everything the keeper reads from the chain goes through here: ONE Multicall3 eth_call per poll (getActiveId + bandState + guardState), one more per attempt
// (everything the plan needs, at one block), plus the quote calls. This module has no signer and sends nothing.
import { BigNumber, providers, utils } from "ethers";
import { ERC20_ABI, FEED_ABI, MULTICALL3_ABI, PAIR_ABI, VAULT_ABI, VAULT_EXTRA_ABI } from "./abi";
import type { KeeperConfig } from "./config";
import type { FeedReading } from "./sanity";
import type { Quote } from "./plan";
import { revertData } from "./errors";
import { safeError } from "./mask";

export const vaultIface = new utils.Interface([...VAULT_ABI, ...VAULT_EXTRA_ABI]);
export const pairIface = new utils.Interface(PAIR_ABI);
const feedIface = new utils.Interface(FEED_ABI);
const erc20Iface = new utils.Interface(ERC20_ABI);
const mcIface = new utils.Interface(MULTICALL3_ABI);

export interface Call {
  target: string;
  iface: utils.Interface;
  fn: string;
  args?: readonly unknown[];
}
export interface CallResult {
  success: boolean;
  value?: utils.Result;
  raw: string;
}
export type BlockTag = number | "latest";

/** Batched view calls at ONE block. mc = "none": one eth_call per call (a local chain without Multicall3). Every call may fail without failing the batch (the caller fails closed). */
export async function batch(provider: providers.Provider, mc: string, calls: Call[], block: BlockTag = "latest"): Promise<CallResult[]> {
  if (calls.length === 0) return [];
  const decode = (c: Call, ok: boolean, data: string): CallResult => {
    if (!ok) return { success: false, raw: data };
    try {
      return { success: true, value: c.iface.decodeFunctionResult(c.fn, data), raw: data };
    } catch {
      return { success: false, raw: data }; // malformed return data = failed call (fail closed)
    }
  };
  if (mc === "none") {
    return Promise.all(calls.map(async (c) => {
      try {
        return decode(c, true, await provider.call({ to: c.target, data: c.iface.encodeFunctionData(c.fn, c.args ?? []) }, block));
      } catch (e) {
        if (/rate.?limit|429|timeout|network|ECONN|SERVER_ERROR/i.test(String((e as Error)?.message))) throw e; // an endpoint problem is a failed cycle, not a failed call
        return { success: false, raw: "0x" } as CallResult;
      }
    }));
  }
  const data = mcIface.encodeFunctionData("aggregate3", [calls.map((c) => ({ target: c.target, allowFailure: true, callData: c.iface.encodeFunctionData(c.fn, c.args ?? []) }))]);
  const out = await provider.call({ to: mc, data }, block);
  const decoded = mcIface.decodeFunctionResult("aggregate3", out)[0] as Array<{ success: boolean; returnData: string }>;
  if (decoded.length !== calls.length) throw new Error("multicall: result length mismatch");
  return decoded.map((r, i) => decode(calls[i]!, r.success, r.returnData));
}
const bi = (v: unknown): bigint => BigInt((v as BigNumber).toString());
function need(r: CallResult | undefined, what: string): utils.Result {
  if (!r || !r.success || !r.value) throw new Error(`read failed: ${what}`);
  return r.value;
}

export interface BandState {
  lowerId: number;
  upperId: number;
  activeId: number;
  hasBand: boolean;
  outOfRange: boolean;
}
export interface GuardState {
  unsafe: boolean;
  latched: boolean;
  reasons: number;
}
export interface Poll {
  /** pair.getActiveId() */
  activeId: number;
  band: BandState;
  guard: GuardState;
}
const toBand = (v: utils.Result): BandState => ({ lowerId: Number(v[0]), upperId: Number(v[1]), activeId: Number(v[2]), hasBand: Boolean(v[3]), outOfRange: Boolean(v[4]) });
const toGuard = (v: utils.Result): GuardState => ({ unsafe: Boolean(v[0]), latched: Boolean(v[1]), reasons: Number(bi(v[2])) });

/** The 3 s poll: ONE eth_call. */
export async function readPoll(provider: providers.Provider, cfg: KeeperConfig): Promise<Poll> {
  const r = await batch(provider, cfg.multicall3, [
    { target: cfg.pair, iface: pairIface, fn: "getActiveId" },
    { target: cfg.vault, iface: vaultIface, fn: "bandState" },
    { target: cfg.vault, iface: vaultIface, fn: "guardState" },
  ]);
  return { activeId: Number(need(r[0], "pair.getActiveId")[0]), band: toBand(need(r[1], "vault.bandState")), guard: toGuard(need(r[2], "vault.guardState")) };
}

export interface GuardParams {
  legBandBps: number;
  maxFeedAge: number;
  maxPoolOracleDevBps: number;
  rebalanceCooldown: number;
  maxRebalancesPerDay: number;
  maxSwapBps: number;
  maxRebalanceLossBps: number;
}
export interface BinReading {
  id: number;
  balance: bigint;
  supply: bigint;
  reserveX: bigint;
  reserveY: bigint;
}
export interface Act {
  block: number;
  poll: Poll;
  allowed: { ok: boolean; reasonBits: number; readyAt: number };
  params: GuardParams;
  rebalancesToday: number;
  lastRebalanceAt: number;
  tokenX: string;
  tokenY: string;
  decX: number;
  decY: number;
  bins: BinReading[];
  idleX: bigint;
  idleY: bigint;
  feedX: FeedReading;
  feedY: FeedReading;
  poolPrice128: bigint;
}

/** Everything one attempt needs, in ONE eth_call at block `block` (a number: the quotes and the simulation use the same block). */
export async function readAct(provider: providers.Provider, cfg: KeeperConfig, block: number, ids: number[]): Promise<Act> {
  const V = cfg.vault;
  const P = cfg.pair;
  const calls: Call[] = [
    { target: P, iface: pairIface, fn: "getActiveId" }, // 0
    { target: V, iface: vaultIface, fn: "bandState" }, // 1
    { target: V, iface: vaultIface, fn: "guardState" }, // 2
    { target: V, iface: vaultIface, fn: "rebalanceAllowed" }, // 3
    { target: V, iface: vaultIface, fn: "guardParams" }, // 4
    { target: V, iface: vaultIface, fn: "rebalancesToday" }, // 5
    { target: V, iface: vaultIface, fn: "lastRebalanceAt" }, // 6
    { target: P, iface: pairIface, fn: "getTokenX" }, // 7
    { target: P, iface: pairIface, fn: "getTokenY" }, // 8
    { target: cfg.assetToken, iface: erc20Iface, fn: "decimals" }, // 9
    { target: cfg.pairToken, iface: erc20Iface, fn: "decimals" }, // 10
    { target: cfg.assetToken, iface: erc20Iface, fn: "balanceOf", args: [V] }, // 11
    { target: cfg.pairToken, iface: erc20Iface, fn: "balanceOf", args: [V] }, // 12
    { target: cfg.feeds.asset, iface: feedIface, fn: "latestRoundData" }, // 13
    { target: cfg.feeds.asset, iface: feedIface, fn: "decimals" }, // 14
    { target: cfg.feeds.pair, iface: feedIface, fn: "latestRoundData" }, // 15
    { target: cfg.feeds.pair, iface: feedIface, fn: "decimals" }, // 16
    { target: V, iface: vaultIface, fn: "pair" }, // 17
    { target: V, iface: vaultIface, fn: "rebalancer" }, // 18
    { target: V, iface: vaultIface, fn: "feedAsset" }, // 19
    { target: V, iface: vaultIface, fn: "feedPair" }, // 20
    { target: V, iface: vaultIface, fn: "asset" }, // 21
    { target: V, iface: vaultIface, fn: "pairToken" }, // 22
  ];
  const base = calls.length;
  for (const id of ids) {
    calls.push({ target: P, iface: pairIface, fn: "balanceOf", args: [V, id] }, { target: P, iface: pairIface, fn: "totalSupply", args: [id] }, { target: P, iface: pairIface, fn: "getBin", args: [id] });
  }
  const r = await batch(provider, cfg.multicall3, calls, block);
  const poll: Poll = { activeId: Number(need(r[0], "pair.getActiveId")[0]), band: toBand(need(r[1], "vault.bandState")), guard: toGuard(need(r[2], "vault.guardState")) };
  // the vault's own wiring must be the configured one, and the keeper wallet must be its rebalancer (a rotation or a wrong config HALTS: kind wiring)
  const same = (a: unknown, b: string): boolean => String(a).toLowerCase() === b.toLowerCase();
  const wiring: Array<[string, unknown, string]> = [
    ["vault.pair()", need(r[17], "vault.pair")[0], cfg.pair],
    ["vault.rebalancer()", need(r[18], "vault.rebalancer")[0], cfg.keeper.address],
    ["vault.feedAsset()", need(r[19], "vault.feedAsset")[0], cfg.feeds.asset],
    ["vault.feedPair()", need(r[20], "vault.feedPair")[0], cfg.feeds.pair],
    ["vault.asset()", need(r[21], "vault.asset")[0], cfg.assetToken],
    ["vault.pairToken()", need(r[22], "vault.pairToken")[0], cfg.pairToken],
  ];
  for (const [n, got, want] of wiring) if (!same(got, want)) throw new WiringError(`${n} is ${String(got)}, the configuration says ${want}`);
  const al = need(r[3], "vault.rebalanceAllowed");
  const gp = need(r[4], "vault.guardParams")[0] as utils.Result;
  const bins: BinReading[] = ids.map((id, k) => {
    const o = base + k * 3;
    const bin = need(r[o + 2], `pair.getBin(${id})`);
    return { id, balance: bi(need(r[o], `pair.balanceOf(${id})`)[0]), supply: bi(need(r[o + 1], `pair.totalSupply(${id})`)[0]), reserveX: bi(bin[0]), reserveY: bi(bin[1]) };
  });
  // the pool's price at the CURRENT active id: a second read at the same block (its argument is the id just read)
  const pr = await batch(provider, cfg.multicall3, [{ target: P, iface: pairIface, fn: "getPriceFromId", args: [poll.activeId] }], block);
  return {
    block, poll,
    allowed: { ok: Boolean(al[0]), reasonBits: Number(bi(al[1])), readyAt: Number(bi(al[2])) },
    params: { legBandBps: Number(gp[0]), maxFeedAge: Number(gp[1]), maxPoolOracleDevBps: Number(gp[2]), rebalanceCooldown: Number(gp[3]), maxRebalancesPerDay: Number(gp[4]), maxSwapBps: Number(gp[5]), maxRebalanceLossBps: Number(gp[6]) },
    rebalancesToday: Number(bi(need(r[5], "vault.rebalancesToday")[0])),
    lastRebalanceAt: Number(bi(need(r[6], "vault.lastRebalanceAt")[0])),
    bins,
    poolPrice128: bi(need(pr[0], "pair.getPriceFromId")[0]),
    ...orient(cfg, r),
  };
}

/** token decimals, idle balances and feeds oriented by the PAIR's X/Y (never assumed: X is whichever token getTokenX() returns) */
function orient(cfg: KeeperConfig, r: CallResult[]): Pick<Act, "tokenX" | "tokenY" | "decX" | "decY" | "idleX" | "idleY" | "feedX" | "feedY"> {
  const tokenX = String(need(r[7], "pair.getTokenX")[0]).toLowerCase();
  const tokenY = String(need(r[8], "pair.getTokenY")[0]).toLowerCase();
  const asset = cfg.assetToken.toLowerCase();
  const pairT = cfg.pairToken.toLowerCase();
  if (!((tokenX === asset && tokenY === pairT) || (tokenX === pairT && tokenY === asset))) throw new WiringError(`the pair's tokens (${tokenX}, ${tokenY}) are not the configured asset/pair tokens`);
  const assetIsX = tokenX === asset;
  const decAsset = Number(need(r[9], "asset.decimals")[0]);
  const decPair = Number(need(r[10], "pairToken.decimals")[0]);
  const balAsset = bi(need(r[11], "asset.balanceOf(vault)")[0]);
  const balPair = bi(need(r[12], "pairToken.balanceOf(vault)")[0]);
  const f = (ri: number, di: number, n: string): FeedReading => {
    const v = need(r[ri], `${n}.latestRoundData`);
    return { roundId: bi(v[0]), answer: bi(v[1]), updatedAt: Number(bi(v[3])), answeredInRound: bi(v[4]), decimals: Number(need(r[di], `${n}.decimals`)[0]) };
  };
  const feedAsset = f(13, 14, "feeds.asset");
  const feedPair = f(15, 16, "feeds.pair");
  return assetIsX
    ? { tokenX, tokenY, decX: decAsset, decY: decPair, idleX: balAsset, idleY: balPair, feedX: feedAsset, feedY: feedPair }
    : { tokenX, tokenY, decX: decPair, decY: decAsset, idleX: balPair, idleY: balAsset, feedX: feedPair, feedY: feedAsset };
}
export class WiringError extends Error {}

/** the vault's share of the band, as the spec's NAV: sum(balanceOf * reserve / totalSupply), rounded down per bin */
export function bandInventory(bins: BinReading[]): { x: bigint; y: bigint } {
  let x = 0n;
  let y = 0n;
  for (const b of bins) {
    if (b.supply === 0n) continue;
    x += (b.balance * b.reserveX) / b.supply;
    y += (b.balance * b.reserveY) / b.supply;
  }
  return { x, y };
}

/** the quote function for plan.ts: pair.getSwapOut at the pinned block */
export function pairQuote(provider: providers.Provider, cfg: KeeperConfig, block: BlockTag): Quote {
  return async (swapXForY, amountIn) => {
    const out = await provider.call({ to: cfg.quoter ?? cfg.pair, data: pairIface.encodeFunctionData("getSwapOut", [amountIn.toString(), swapXForY]) }, block);
    const v = pairIface.decodeFunctionResult("getSwapOut", out);
    return { amountInLeft: bi(v[0]), amountOut: bi(v[1]) };
  };
}

// ---------------------------------------------------------------- the EXIT PROBE
export type ProbeResult = { status: "ok" } | { status: "failed"; why: string } | { status: "inconclusive"; why: string };
/**
 * Whether the vault can still BURN its band shares (the first step of every exit, redeemInKind included). A failing Pharaoh hook (rewarder beforeBurn, or the voter's
 * isAntiSybilEnabled / timeThresholdForGauge) makes pair.burn revert while guardState() still reads 0 and deposits stay open.
 * Approach: an eth_call of pair.burn(vault, vault, [id], [balance]) with `from` = the vault: the pair requires from == msg.sender (or an approval), so no shares of a holder
 * and no state override are needed; the call runs the whole burn path incl. the hook and is never mined. It burns the vault's WHOLE balance of its most valuable band bin
 * (a minimal share amount would pay 0 and revert ZeroAmountsOut for the wrong reason). Zero-amount reverts or no shares are INCONCLUSIVE, any other revert is a FAILURE.
 */
export async function probeExit(provider: providers.Provider, cfg: KeeperConfig, ids: number[], block: BlockTag): Promise<ProbeResult> {
  if (ids.length === 0) return { status: "inconclusive", why: "no band" };
  const calls: Call[] = [];
  for (const id of ids) calls.push({ target: cfg.pair, iface: pairIface, fn: "balanceOf", args: [cfg.vault, id] }, { target: cfg.pair, iface: pairIface, fn: "totalSupply", args: [id] }, { target: cfg.pair, iface: pairIface, fn: "getBin", args: [id] });
  const r = await batch(provider, cfg.multicall3, calls, block);
  let best: { id: number; bal: bigint; value: bigint } | undefined;
  ids.forEach((id, k) => {
    const bal = bi(need(r[k * 3], `probe balanceOf(${id})`)[0]);
    const sup = bi(need(r[k * 3 + 1], `probe totalSupply(${id})`)[0]);
    const bin = need(r[k * 3 + 2], `probe getBin(${id})`);
    if (bal === 0n || sup === 0n) return;
    const value = (bal * (bi(bin[0]) + bi(bin[1]))) / sup;
    if (!best || value > best.value) best = { id, bal, value };
  });
  if (!best || best.value === 0n) return { status: "inconclusive", why: "the vault holds no band shares worth a raw unit" };
  try {
    const ret = await provider.call({ from: cfg.vault, to: cfg.pair, data: pairIface.encodeFunctionData("burn", [cfg.vault, cfg.vault, [best.id], [best.bal.toString()]]) }, block);
    // a revert can come back as a plain result (see callVoid): only a result that DECODES as burn's bytes32[] is a pass
    try {
      pairIface.decodeFunctionResult("burn", ret);
    } catch {
      throw Object.assign(new Error("burn simulation returned revert data"), { data: ret });
    }
    return { status: "ok" };
  } catch (e) {
    const data = revertData(e);
    const msg = String((e as Error)?.message ?? e);
    if (!data && /rate.?limit|429|timeout|network|ECONN|ETIMEDOUT|SERVER_ERROR|header not found/i.test(msg)) throw e; // an endpoint problem is a failed cycle, not a hook failure
    if (data) {
      try {
        const frag = pairIface.getError(data.slice(0, 10));
        if (frag.name === "LBPair__ZeroAmount" || frag.name === "LBPair__ZeroAmountsOut") return { status: "inconclusive", why: `${frag.name} on bin ${best.id}` };
      } catch {
        /* not a pair error */
      }
    }
    return { status: "failed", why: data ? `burn of bin ${best.id} reverted with ${data.slice(0, 74)}` : `burn of bin ${best.id} reverted: ${safeError(e)}` };
  }
}

/**
 * eth_call of a function that RETURNS NOTHING (rebalance, openBand, tripGuard). ethers v5 hands the revert data of a reverted eth_call back as an ordinary RESULT for some node
 * error shapes (MEASURED on anvil: a reverting pair.burn came back as 0x08c379a0...), so a "successful" simulation is only one that returned EXACTLY "0x". Anything else is thrown as a
 * revert with that data, so classifyRevert decodes it and nothing is ever sent on the strength of a reverted simulation.
 */
export async function callVoid(provider: providers.Provider, tx: { from: string; to: string; data: string }): Promise<void> {
  const ret = await provider.call(tx);
  if (ret !== "0x" && ret !== "") throw Object.assign(new Error("simulation returned revert data"), { data: ret });
}

// ---------------------------------------------------------------- start-up wiring check
export interface Check {
  level: "PASS" | "FAIL" | "INFO";
  text: string;
}
/** The vault's wiring against the configuration: pair, feeds, asset, pair token, and the keeper wallet == rebalancer(). Read-only. */
export async function checkWiring(provider: providers.Provider, cfg: KeeperConfig): Promise<Check[]> {
  const V = cfg.vault;
  const r = await batch(provider, cfg.multicall3, [
    { target: V, iface: vaultIface, fn: "pair" },
    { target: V, iface: vaultIface, fn: "rebalancer" },
    { target: V, iface: vaultIface, fn: "feedAsset" },
    { target: V, iface: vaultIface, fn: "feedPair" },
    { target: V, iface: vaultIface, fn: "asset" },
    { target: V, iface: vaultIface, fn: "pairToken" },
    { target: cfg.pair, iface: pairIface, fn: "getTokenX" },
    { target: cfg.pair, iface: pairIface, fn: "getTokenY" },
    { target: V, iface: vaultIface, fn: "guardState" },
    { target: V, iface: vaultIface, fn: "bandState" },
  ]);
  const out: Check[] = [];
  const val = (i: number): string | undefined => (r[i]?.success && r[i]!.value ? String(r[i]!.value![0]) : undefined);
  const eq = (name: string, got: string | undefined, want: string): void => {
    if (got === undefined) out.push({ level: "FAIL", text: `${name}: the call failed (is ${V} a vault?)` });
    else if (got.toLowerCase() !== want.toLowerCase()) out.push({ level: "FAIL", text: `${name} is ${got}, the configuration says ${want}` });
    else out.push({ level: "PASS", text: `${name} = ${got}` });
  };
  eq("vault.pair()", val(0), cfg.pair);
  eq("vault.rebalancer() == the keeper wallet", val(1), cfg.keeper.address);
  eq("vault.feedAsset()", val(2), cfg.feeds.asset);
  eq("vault.feedPair()", val(3), cfg.feeds.pair);
  eq("vault.asset()", val(4), cfg.assetToken);
  eq("vault.pairToken()", val(5), cfg.pairToken);
  const tx = val(6);
  const ty = val(7);
  const okTok = tx !== undefined && ty !== undefined && ((tx.toLowerCase() === cfg.pairToken.toLowerCase() && ty.toLowerCase() === cfg.assetToken.toLowerCase()) || (tx.toLowerCase() === cfg.assetToken.toLowerCase() && ty.toLowerCase() === cfg.pairToken.toLowerCase()));
  out.push({ level: okTok ? "PASS" : "FAIL", text: `pair tokens X=${tx} Y=${ty} are the configured asset / pair token` });
  if (r[8]?.success && r[8]!.value) {
    const g = toGuard(r[8]!.value!);
    out.push({ level: g.latched || g.reasons !== 0 ? "FAIL" : "PASS", text: `guardState: latched=${g.latched} reasons=${g.reasons}` });
  } else out.push({ level: "FAIL", text: "vault.guardState() failed" });
  if (r[9]?.success && r[9]!.value) {
    const b = toBand(r[9]!.value!);
    out.push({ level: "INFO", text: `bandState: hasBand=${b.hasBand} band=[${b.lowerId}, ${b.upperId}] active=${b.activeId}` });
  }
  return out;
}

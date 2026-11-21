// WRAPPER FALLBACK KEEPER (bpPHAR-USDC oracle wrapper v2). The wrapper prices the share from the vault's own live answer; when the vault cannot answer (one of
// its Chainlink feeds is stale) it serves a FALLBACK price (last good value x 97% x the live USDC price) for at most 24 h after the last successful `poke()`.
// The fallback is therefore only as good as the last poke. This module does two separate things:
//
//   1. MONITORING (every host, read only): `readShareWatch` + `shareWatchFindings` turn the wrapper's `shareState()` and its share price into findings
//      (served from the fallback, fallback nearly expired, price 0 = the account-freeze condition, poke stalled, poke refused, poke failing).
//   2. THE POKE LOOP (ONE host only: `shareCollateral.poke.enabled`, default off): `pokeStep` calls `poke()` from the operator wallet when the vault can
//      answer and the stored value is older than `pokeMinAgeSeconds` (default 3,700 s, a little over the wrapper's 1 h upward gate, so an upward move is
//      never refused). Simulate first (a `false` result sends nothing), fee cap, gas floor, one poke at a time, restart-safe, every failure is an alert and
//      never an exception. `poke()` is permissionless and moves no funds: the wallet needs only gas.
//
// It never touches the liquidation route: src/executor.ts reads the CONTROLLER's price and account liquidity and does not know the fallback exists (a test
// pins that).
import { BigNumber, utils } from "ethers";
import type { AlertManager } from "./alerts";
import { latestBlock } from "./chain";
import type { Ctx } from "./chain";
import type { MonitorConfig } from "./config";
import type { Finding } from "./health";
import { safeError } from "./mask";
import type { ExternalSigner } from "./signer";
import { feesWithin, makeSender, TxReverted } from "./txkit";

export const WRAPPER_ABI = [
  "function shareState() view returns (uint256 liveAssetsPerShare, uint256 storedAssetsPerShare, uint64 storedAt, bool usingFallback, uint256 fallbackSecondsLeft)",
  "function poke() returns (bool stored)",
  "event FallbackPriceStored(uint256 assetsPerShare, uint256 at)",
  "function lastGoodAssetsPerShare() view returns (uint128)",
  "function lastGoodTime() view returns (uint64)",
  "function getUnderlyingPrice(address pToken) view returns (uint256)",
];
export const wrapperIface = new utils.Interface(WRAPPER_ABI);

/** defaults and thresholds (constants, not configuration: the monitoring thresholds are the same on every host) */
export const POKE_DEFAULT_MIN_AGE_SECONDS = 3_700;
export const FALLBACK_EXPIRING_SECONDS = 6 * 3_600;
export const POKE_STALLED_SECONDS = 3 * 3_600;
export const POKE_REFUSED_ROUNDS = 3;
/** after a failed poke attempt, no new attempt for this long (a persistent failure must not burn gas every poll) */
export const POKE_RETRY_COOLDOWN_SECONDS = 300;
/** a poke sent this recently (possibly still unmined, e.g. across a restart) blocks a second one */
export const POKE_IN_FLIGHT_SECONDS = 600;
/**
 * The poke is sent with an EXPLICIT gas limit and NEVER with an estimate. eth_estimateGas returns the lowest gas at which the transaction does not revert, and
 * poke() does not revert when the wrapper's vault read fails for lack of gas (the read is a swallowed staticcall: poke() then returns false and stores nothing),
 * so an estimate converges on a STARVED amount (observed on a mainnet fork: exactly 60,627 gas, returns false, stores nothing). The live vault read (two Chainlink
 * feeds and the pair's bins through the proxy) needs several hundred thousand gas: the gas of one poke on mainnet is UNMEASURED here. Default limit 1,500,000;
 * a configured value below 1,000,000 is refused by the configuration check. The same limit is used for the eth_call simulation.
 */
export const POKE_DEFAULT_GAS_LIMIT = 1_500_000;

export interface PokeConfig {
  enabled: boolean;
  pokeMinAgeSeconds: number;
  maxFeeGwei: number;
  minGasWei: string;
  gasLimit: number;
}
/** The resolved poke settings, or undefined when the block is absent or `enabled` is false (the default: hosts do nothing until configured). */
export function pokeSettings(cfg: MonitorConfig): PokeConfig | undefined {
  const p = cfg.shareCollateral?.poke;
  if (!p?.enabled) return undefined;
  return { enabled: true, pokeMinAgeSeconds: p.pokeMinAgeSeconds ?? POKE_DEFAULT_MIN_AGE_SECONDS, maxFeeGwei: p.maxFeeGwei ?? cfg.executor.maxFeeGwei, minGasWei: p.minGasWei ?? cfg.executor.minGasWei, gasLimit: p.gasLimit ?? POKE_DEFAULT_GAS_LIMIT };
}

// ------------------------------------------------------------------ state (persisted in the monitor state file under `poke`)
export interface PokeState {
  /** a poke was sent at this time and not yet confirmed (the process may have been restarted meanwhile): blocks another for POKE_IN_FLIGHT_SECONDS */
  inFlight: null | { at: number };
  /** consecutive rounds in which the simulation said `false` */
  refusedRounds: number;
  /** the last failure not yet superseded by a success or by "nothing to do" (shown by the monitor as a warning) */
  lastError: null | { at: number; message: string };
  /** no new attempt before this time (unix s) */
  retryAfter: number;
  last?: { at: number; hash: string; blockNumber: number; gasUsed: string };
}
export const emptyPokeState = (): PokeState => ({ inFlight: null, refusedRounds: 0, lastError: null, retryAfter: 0 });

// ------------------------------------------------------------------ monitoring
export interface ShareState {
  live: bigint;
  stored: bigint;
  storedAt: number;
  usingFallback: boolean;
  fallbackSecondsLeft: number;
}
export interface ShareWatch {
  state?: ShareState;
  stateError?: string;
  /** the wrapper's own price for the share market (getUnderlyingPrice), read directly from the wrapper, whichever oracle the controller uses */
  price?: bigint;
  priceError?: string;
}

export async function readShareState(provider: Ctx["provider"], wrapper: string, block?: number): Promise<ShareState> {
  const r = wrapperIface.decodeFunctionResult("shareState", await provider.call({ to: wrapper, data: wrapperIface.encodeFunctionData("shareState") }, block));
  return { live: BigInt(r[0].toString()), stored: BigInt(r[1].toString()), storedAt: Number(r[2].toString()), usingFallback: r[3] as boolean, fallbackSecondsLeft: Number(r[4].toString()) };
}

/** Everything the monitor needs from the wrapper at one block. Never throws: a failed read is reported in the result. */
export async function readShareWatch(provider: Ctx["provider"], cfg: MonitorConfig, block: number): Promise<ShareWatch | undefined> {
  const wrapper = cfg.deployment.oracleWrapper;
  const sc = cfg.shareCollateral;
  if (!wrapper || !sc) return undefined;
  const w: ShareWatch = {};
  try {
    w.state = await readShareState(provider, wrapper, block);
  } catch (e) {
    w.stateError = safeError(e);
  }
  try {
    w.price = BigInt(wrapperIface.decodeFunctionResult("getUnderlyingPrice", await provider.call({ to: wrapper, data: wrapperIface.encodeFunctionData("getUnderlyingPrice", [sc.pToken]) }, block))[0].toString());
  } catch (e) {
    w.priceError = safeError(e);
  }
  return w;
}

const fmt6 = (v: bigint): string => `${v / 1_000_000n}.${(v % 1_000_000n).toString().padStart(6, "0")}`;
const hours = (s: number): string => `${(s / 3600).toFixed(1)} h`;

/**
 * Findings of the share-price watch. Severities: crit = fallback in use, fallback under 6 h left, wrapper price 0 (an account that entered the share market
 * then returns an error from the controller in EVERY market: no borrow, no redeem, no liquidation); warn = stored value older than 3 h while the vault can answer
 * (the poke has stalled), poke simulation false for 3 rounds, a failing poke, an unreadable wrapper. Keys are stable, so the alert manager de-duplicates them.
 */
export function shareWatchFindings(w: ShareWatch | undefined, now: number, poke: PokeState | undefined): Finding[] {
  const f: Finding[] = [];
  if (!w) return f;
  const s = w.state;
  if (w.stateError) f.push({ key: "share:state-unreadable", severity: "warn", message: `the oracle wrapper's shareState() cannot be read (${w.stateError}): the fallback watch is blind (check the wrapper address in the configuration and the RPC)`, audience: "monitor-operator" });
  if (s) {
    const age = Math.max(0, now - s.storedAt);
    const detail = `vault live ${s.live > 0n ? fmt6(s.live) : "UNAVAILABLE"} USDC per share, stored ${fmt6(s.stored)} ${hours(age)} ago`;
    if (s.usingFallback) {
      f.push({ key: "share:fallback", severity: "crit", message: `share price served from fallback: the vault cannot value its shares (one of its Chainlink feeds is stale or bad), the controller is using the stored value less 3%. ${detail}; ${hours(s.fallbackSecondsLeft)} of fallback left. The price becomes 0 when it runs out: check the vault's feeds (USDC/USD, USDT/USD)`, audience: "guardian", escalates: true });
      if (s.fallbackSecondsLeft < FALLBACK_EXPIRING_SECONDS) f.push({ key: "share:fallback-expiring", severity: "crit", message: `fallback time left below 6 h: ${s.fallbackSecondsLeft} s left, then the share price is 0 and every account that entered the share market is frozen (no borrow, no redeem, no liquidation). ${detail}`, audience: "guardian", escalates: true });
    }
    if (s.live > 0n && age > POKE_STALLED_SECONDS) f.push({ key: "share:poke-stalled", severity: "warn", message: `the stored fallback value is ${hours(age)} old although the vault can answer: the poke loop has stalled (the poking host is down, out of gas, or its fee cap is below the network fee). ${detail}. Fallback window left ${hours(s.fallbackSecondsLeft)}`, audience: "monitor-operator" });
  }
  if (w.priceError) f.push({ key: "share:price-unreadable", severity: "warn", message: `the oracle wrapper's price for the share market cannot be read (${w.priceError})`, audience: "monitor-operator" });
  else if (w.price === 0n) {
    f.push({ key: "share:price-zero", severity: "crit", message: `wrapper price for the share market is 0: any account that has entered the share market now returns a price error in EVERY market (no borrow, no redeem, no exit, no liquidation). ${s ? `shareState: live ${s.live > 0n ? fmt6(s.live) : "unavailable"}, stored ${fmt6(s.stored)}, fallback ${s.usingFallback ? "in use" : "not in use"}, ${s.fallbackSecondsLeft} s of window left.` : "shareState unreadable."} Causes: the vault is BROKEN (asset() changed or unreadable), the 24 h fallback expired, or the USDC price (base oracle) is 0`, audience: "guardian", escalates: true });
  }
  if (poke && poke.refusedRounds >= POKE_REFUSED_ROUNDS) f.push({ key: "share:poke-refused", severity: "warn", message: `the the poke did not store in ${poke.refusedRounds} consecutive rounds (the simulation returned false, or a mined poke emitted no FallbackPriceStored: refused or gas-starved) although the vault answers and the stored value is old. The wrapper refuses to store, or the gas limit is too low for the vault read (shareCollateral.poke.gasLimit) (check shareState() by hand)`, audience: "monitor-operator" });
  if (poke?.lastError) f.push({ key: "share:poke-error", severity: "warn", message: `the poke attempt failed at ${poke.lastError.at}: ${poke.lastError.message}. It is retried (at most every ${POKE_RETRY_COOLDOWN_SECONDS} s) until it succeeds`, audience: "monitor-operator" });
  return f;
}

// ------------------------------------------------------------------ the poke loop
export interface PokeDeps {
  ctx: Ctx;
  signer: ExternalSigner;
  alerts: AlertManager;
  persist: (s: PokeState) => void;
  now?: () => number;
  trace?: (m: string) => void;
}
export type PokeResult = "disabled" | "not-due" | "poked" | "refused" | "skipped" | "error";
export interface PokeOutcome {
  state: PokeState;
  result: PokeResult;
  note?: string;
  hash?: string;
}

/** Pure decision: is a poke due? The vault must be able to answer and the stored value must be at least `minAge` old. */
export function pokeDue(s: ShareState, nowChain: number, minAge: number): { due: boolean; why: string } {
  if (s.live === 0n) return { due: false, why: "the vault cannot answer (nothing to store)" };
  const age = nowChain - s.storedAt;
  if (age < minAge) return { due: false, why: `stored value is ${age} s old (< ${minAge} s)` };
  return { due: true, why: `stored value is ${age} s old` };
}

/** did the mined transaction store a value? receipt event first; with no receipt (lagging node), the stored time at the block against the block time */
async function confirmStored(provider: Ctx["provider"], wrapper: string, hash: string, blockNumber: number): Promise<{ stored: boolean; why: string }> {
  try {
    const topic = wrapperIface.getEventTopic("FallbackPriceStored");
    let rc = await provider.getTransactionReceipt(hash);
    if (!rc) {
      await new Promise((r) => setTimeout(r, 1000));
      rc = await provider.getTransactionReceipt(hash);
    }
    if (rc) {
      const ev = rc.logs.some((l) => l.address.toLowerCase() === wrapper.toLowerCase() && l.topics[0] === topic);
      return ev ? { stored: true, why: "FallbackPriceStored in the receipt" } : { stored: false, why: "no FallbackPriceStored event in the receipt" };
    }
    const blk = await provider.getBlock(blockNumber);
    const s = await readShareState(provider, wrapper, blockNumber);
    return s.storedAt >= blk.timestamp ? { stored: true, why: "stored time at the block" } : { stored: false, why: "no receipt available and the stored time at the block is older than the block" };
  } catch (e) {
    return { stored: false, why: `cannot confirm: ${safeError(e)}` };
  }
}

let pokeBusy = false; // one poke at a time (the step is sequential in the process; this also guards re-entry)

/**
 * One poke round. NEVER throws. Sends at most one transaction, only after: the vault answered, the stored value is old enough, no earlier poke is in flight
 * (local record and the wallet's pending nonce), the fee is under the cap, the wallet has gas, and an eth_call simulation of `poke()` returned true.
 */
export async function pokeStep(deps: PokeDeps, state: PokeState): Promise<PokeOutcome> {
  const cfg = deps.ctx.cfg;
  const pc = pokeSettings(cfg);
  if (!pc) return { state, result: "disabled" };
  if (pokeBusy) return { state, result: "skipped", note: "another poke is running" };
  pokeBusy = true;
  const wall = (): number => deps.now?.() ?? Math.floor(Date.now() / 1000);
  let st: PokeState = { ...emptyPokeState(), ...state };
  const save = (): void => {
    try {
      deps.persist(st);
    } catch {
      /* persistence failure must not crash the loop; the next round re-persists */
    }
  };
  const fail = (message: string, extra: Partial<PokeState> = {}): PokeOutcome => {
    st = { ...st, lastError: { at: wall(), message }, retryAfter: wall() + POKE_RETRY_COOLDOWN_SECONDS, ...extra };
    save();
    return { state: st, result: "error", note: message };
  };
  try {
    const { provider } = deps.ctx;
    const wrapper = cfg.deployment.oracleWrapper!;
    const op = cfg.operators.find((o) => o.name === cfg.executor.operator)!.address;
    const operator = await deps.signer.getAddress();
    if (operator.toLowerCase() !== op.toLowerCase()) return fail("signer address differs from the configured operator address: no poke");
    const blk = await latestBlock(provider);
    if (wall() - blk.timestamp > cfg.monitor.maxBlockLagSeconds) return { state: st, result: "skipped", note: `latest block is ${wall() - blk.timestamp} s old: the RPC is stale, no poke` };
    const s = await readShareState(provider, wrapper, blk.number);
    const due = pokeDue(s, blk.timestamp, pc.pokeMinAgeSeconds);
    if (!due.due) {
      // nothing to do: an earlier failure and the refusal counter are moot; a fresh stored value also confirms a poke that was in flight (e.g. across a restart)
      const confirmed = s.live > 0n && blk.timestamp - s.storedAt < pc.pokeMinAgeSeconds;
      const inFlight = confirmed ? null : st.inFlight;
      if (st.refusedRounds !== 0 || st.lastError || inFlight !== st.inFlight) {
        st = { ...st, refusedRounds: 0, lastError: null, inFlight };
        save();
      }
      return { state: st, result: "not-due", note: due.why };
    }
    // restart / double-send guards
    const nowS = wall();
    if (st.inFlight && nowS - st.inFlight.at < POKE_IN_FLIGHT_SECONDS) return { state: st, result: "skipped", note: `a poke was sent ${nowS - st.inFlight.at} s ago and is not confirmed: waiting` };
    if (nowS < st.retryAfter) return { state: st, result: "skipped", note: `retry cooldown: ${st.retryAfter - nowS} s left after the last failure` };
    const [latestNonce, pendingNonce] = await Promise.all([provider.getTransactionCount(operator, "latest"), provider.getTransactionCount(operator, "pending")]);
    if (pendingNonce !== latestNonce) return { state: st, result: "skipped", note: "a transaction of the operator wallet is still pending: no second poke" };
    const feesR = await feesWithin(provider, pc.maxFeeGwei);
    if (!feesR.ok) return { state: st, result: "skipped", note: `fee: ${feesR.reason}` };
    const gasLimit = BigNumber.from(pc.gasLimit);
    const gasBal = await provider.getBalance(operator);
    // the node requires balance >= gasLimit x maxFeePerGas up front (the unused part is refunded): the floor is the larger of the configured floor and that
    const prefund = gasLimit.mul(feesR.fees.maxFeePerGas);
    const need = prefund.gt(pc.minGasWei) ? prefund : BigNumber.from(pc.minGasWei);
    if (gasBal.lt(need)) return fail(`operator AVAX ${gasBal.toString()} wei is below the poke floor ${need.toString()} wei (the larger of poke.minGasWei and gasLimit ${pc.gasLimit} x max fee ${feesR.fees.maxFeePerGas.toString()}): refill the wallet or the fallback goes stale`);
    // simulate with the SAME gas limit as the transaction (a starved vault read would return false): a false result (or a revert) sends nothing
    const data = wrapperIface.encodeFunctionData("poke");
    let sim: boolean;
    try {
      sim = wrapperIface.decodeFunctionResult("poke", await provider.call({ from: operator, to: wrapper, data, gasLimit }))[0] as boolean;
    } catch (e) {
      return fail(`poke() simulation reverted (${safeError(e)}): nothing sent`);
    }
    if (!sim) {
      st = { ...st, refusedRounds: st.refusedRounds + 1, lastError: null };
      save();
      return { state: st, result: "refused", note: `poke() simulation returned false (round ${st.refusedRounds}): nothing sent` };
    }
    st = { ...st, refusedRounds: 0 };
    // the in-flight record is persisted BEFORE the transaction: a restart between send and receipt cannot send a second one
    st = { ...st, inFlight: { at: nowS } };
    save();
    deps.trace?.(`poke: sending with gas limit ${pc.gasLimit}`);
    let tx: { hash: string; blockNumber: number; gasUsed: BigNumber };
    try {
      tx = await makeSender(deps.signer, feesR.fees)(wrapper, data, gasLimit);
    } catch (e) {
      if (e instanceof TxReverted) return fail(`poke transaction ${e.hash} was mined and reverted`, { inFlight: null });
      return fail(`poke transaction not confirmed: ${safeError(e)} (it may still be mined; no new poke for ${POKE_IN_FLIGHT_SECONDS} s)`); // inFlight stays set
    }
    // A mined transaction is NOT a stored value: poke() returns false without reverting when it refuses or when its vault read starves. Success needs the wrapper's
    // FallbackPriceStored event in the receipt (or, with no receipt, the stored time at the block >= the block time).
    const conf = await confirmStored(provider, wrapper, tx.hash, tx.blockNumber);
    const last = { at: wall(), hash: tx.hash, blockNumber: tx.blockNumber, gasUsed: tx.gasUsed.toString() };
    if (!conf.stored) {
      return fail(`poke ${tx.hash} was mined (gas used ${tx.gasUsed.toString()} of ${pc.gasLimit}) but the wrapper stored NOTHING (${conf.why}): a refused or gas-starved poke. No new attempt for ${POKE_RETRY_COOLDOWN_SECONDS} s`, { inFlight: null, refusedRounds: st.refusedRounds + 1, last });
    }
    st = { ...st, inFlight: null, lastError: null, refusedRounds: 0, last };
    save();
    return { state: st, result: "poked", hash: tx.hash, note: `stored a new fallback value (gas used ${tx.gasUsed.toString()} of ${pc.gasLimit})` };
  } catch (e) {
    return fail(`poke round failed: ${safeError(e)}`);
  } finally {
    pokeBusy = false;
  }
}

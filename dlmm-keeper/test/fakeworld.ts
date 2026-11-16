// A small in-memory world for the unit tests: a vault with the frozen interface's reads and the rebalance / tripGuard effects, the pair's reads (active id, bins, price,
// getSwapOut), the two feeds, ERC-20 balances, Multicall3, receipts, fee data and a signer that "mines" transactions into it. The keeper's REAL encoding, decoding,
// simulation, send and read-back code runs against it; `lies` make the world misbehave after a send.
import { BigNumber, utils } from "ethers";
import { ERC20_ABI, FEED_ABI, MULTICALL3_ABI, PAIR_ABI, VAULT_ABI, VAULT_EXTRA_ABI } from "../src/abi";
import type { ExternalSigner, SentTx, TxRequest } from "../src/signer";
import { A } from "./fixtures";

const vlt = new utils.Interface([...VAULT_ABI, ...VAULT_EXTRA_ABI]);
const pr = new utils.Interface(PAIR_ABI);
const fd = new utils.Interface(FEED_ABI);
const erc = new utils.Interface(ERC20_ABI);
const mc = new utils.Interface(MULTICALL3_ABI);
export const E6 = 1_000_000n;
const Q128 = 2n ** 128n;

export interface FeedW { answer: bigint; updatedAt: number; roundId: bigint; answeredInRound: bigint; decimals: number }
export interface World {
  now: number;
  block: number;
  /** block timestamp lag behind `now` */
  blockLag: number;
  activeId: number;
  /** successive reads of pair.getActiveId return these first (then `activeId`) */
  activeIdQueue: number[];
  band: { lowerId: number; upperId: number; hasBand: boolean };
  latched: boolean;
  reasons: number;
  paused: boolean;
  /** the vault's wiring getters (defaults = the configured values) */
  wiring: { pair: string; rebalancer: string; feedAsset: string; feedPair: string; asset: string; pairToken: string };
  /** pair.burn simulations from the vault: revert (a failing hook) / revert with ZeroAmountsOut (inconclusive) */
  /** revert data comes back as an ordinary eth_call RESULT (what ethers v5 does for some node errors) */
  revertAsResult: boolean;
  hookRevert: boolean;
  burnZero: boolean;
  burnCalls: Array<{ from?: string; args: utils.Result }>;
  params: { legBandBps: number; maxFeedAge: number; maxPoolOracleDevBps: number; rebalanceCooldown: number; maxRebalancesPerDay: number; maxSwapBps: number; maxRebalanceLossBps: number };
  lastRebalanceAt: number;
  rebalancesToday: number;
  tokenX: string;
  tokenY: string;
  decX: number;
  decY: number;
  idle: Map<string, bigint>;
  bins: Map<number, { bal: bigint; supply: bigint; rx: bigint; ry: bigint }>;
  feedAsset: FeedW;
  feedPair: FeedW;
  /** pool price at every id, raw Y per raw X, as a fraction num/den */
  priceNum: bigint;
  priceDen: bigint;
  /** swap fee of the quote in bps */
  quoteFeeBps: bigint;
  /** quote depth: the pair fills at most this much input (undefined = all) */
  quoteMaxIn?: bigint;
  /** the simulation (and the mined transaction, unless minedRevertOnly) of rebalance reverts with this error; consumed one per call when an array */
  simRevert: Array<{ name: string; args: unknown[] }>;
  simRevertAlways?: { name: string; args: unknown[] };
  /** simulation passes, the mined transaction reverts */
  minedRevert: boolean;
  tripSimRevert?: { name: string; args: unknown[] };
  keeperBalance: bigint;
  gasPrice: bigint;
  lies: { noEvent?: boolean; noAdvance?: boolean; wrongBand?: boolean };
  /** what the mined rebalance does to the active id (a post-swap move) */
  newActiveId?: number;
  txs: Map<string, { block: number; status: number; to: string; logs: Array<{ address: string; topics: string[]; data: string; logIndex: number }> }>;
  sent: Array<{ hash: string; to: string; fn: string; args: utils.Result }>;
  calls: { eth_call: number; sims: number; getBalance: number; getBlock: number };
  rebalanceCalls: Array<utils.Result>;
  openBandCalls: Array<utils.Result>;
}

export function newWorld(): World {
  const w: World = {
    now: 1_800_000_000, block: 1000, blockLag: 2,
    activeId: 8_388_608, activeIdQueue: [], band: { lowerId: 8_388_607, upperId: 8_388_609, hasBand: true },
    latched: false, reasons: 0, paused: false,
    wiring: { pair: A.pair, rebalancer: A.keeper, feedAsset: A.feedAsset, feedPair: A.feedPair, asset: A.usdc, pairToken: A.usdt },
    revertAsResult: false, hookRevert: false, burnZero: false, burnCalls: [],
    params: { legBandBps: 50, maxFeedAge: 93_600, maxPoolOracleDevBps: 60, rebalanceCooldown: 120, maxRebalancesPerDay: 48, maxSwapBps: 6000, maxRebalanceLossBps: 50 },
    lastRebalanceAt: 0, rebalancesToday: 0,
    tokenX: A.usdt, tokenY: A.usdc, decX: 6, decY: 6,
    idle: new Map([[A.usdt.toLowerCase(), 0n], [A.usdc.toLowerCase(), 0n]]),
    bins: new Map(),
    feedAsset: { answer: 99_975_000n, updatedAt: 1_800_000_000 - 4 * 3600, roundId: 5n, answeredInRound: 5n, decimals: 8 },
    feedPair: { answer: 99_934_000n, updatedAt: 1_800_000_000 - 5 * 3600, roundId: 7n, answeredInRound: 7n, decimals: 8 },
    priceNum: 99_960n, priceDen: 100_000n, quoteFeeBps: 3n,
    simRevert: [], minedRevert: false, keeperBalance: 10n ** 18n, gasPrice: 3_500_000_000n, lies: {},
    txs: new Map(), sent: [], calls: { eth_call: 0, sims: 0, getBalance: 0, getBlock: 0 }, rebalanceCalls: [], openBandCalls: [],
  };
  return w;
}
/** the active bin is above the band (an exit upward): the band holds only Y (bins below the active id hold only Y), `y` raw USDC in total over 3 bins */
export function bandAllY(w: World, y: bigint): void {
  w.activeId = w.band.upperId + 2;
  w.bins.clear();
  for (const id of [w.band.lowerId, w.band.upperId - 1, w.band.upperId]) w.bins.set(id, { bal: 1000n, supply: 10_000n, rx: 0n, ry: (y * 10n) / 3n });
}
/** the active bin is below the band: the band holds only X */
export function bandAllX(w: World, x: bigint): void {
  w.activeId = w.band.lowerId - 2;
  w.bins.clear();
  for (const id of [w.band.lowerId, w.band.upperId - 1, w.band.upperId]) w.bins.set(id, { bal: 1000n, supply: 10_000n, rx: (x * 10n) / 3n, ry: 0n });
}

const revertErr = (name: string, args: unknown[]): Error => Object.assign(new Error("execution reverted"), { code: "CALL_EXCEPTION", data: vlt.encodeErrorResult(name, args) });
export function swapOut(w: World, xForY: boolean, amountIn: bigint): { left: bigint; out: bigint } {
  let ain = amountIn;
  let left = 0n;
  if (w.quoteMaxIn !== undefined && ain > w.quoteMaxIn) {
    left = ain - w.quoteMaxIn;
    ain = w.quoteMaxIn;
  }
  const gross = xForY ? (ain * w.priceNum) / w.priceDen : (ain * w.priceDen) / w.priceNum;
  return { left, out: (gross * (10_000n - w.quoteFeeBps)) / 10_000n };
}

function dispatch(w: World, to: string, data: string, from?: string): string {
  const T = to.toLowerCase();
  const sel = data.slice(0, 10);
  const enc = (i: utils.Interface, fn: string, vals: unknown[]): string => i.encodeFunctionResult(fn, vals);
  if (T === "0xca11bde05977b3631167028862be2a173976ca11") {
    const calls = mc.decodeFunctionData("aggregate3", data)[0] as Array<{ target: string; callData: string }>;
    const res = calls.map((c) => {
      try {
        return { success: true, returnData: dispatch(w, c.target, c.callData) };
      } catch {
        return { success: false, returnData: "0x" };
      }
    });
    return mc.encodeFunctionResult("aggregate3", [res]);
  }
  if (T === A.vault.toLowerCase()) {
    const f = vlt.getFunction(sel);
    switch (f.name) {
      case "bandState": return enc(vlt, f.name, [w.band.lowerId, w.band.upperId, w.activeId, w.band.hasBand, w.band.hasBand && (w.activeId < w.band.lowerId || w.activeId > w.band.upperId)]);
      case "guardState": return enc(vlt, f.name, [w.latched || w.reasons !== 0, w.latched, w.reasons]);
      case "rebalanceAllowed": {
        // the REAL vault's bits: guard bits 1..32, 64 no band, 128 active in range, 256 cooldown, 512 daily cap, 1024 latched, 2048 paused
        let bits = w.reasons;
        if (w.paused) bits |= 2048;
        if (w.latched) bits |= 1024;
        if (!w.band.hasBand) bits |= 64;
        else if (w.activeId >= w.band.lowerId && w.activeId <= w.band.upperId) bits |= 128;
        const readyAt = w.lastRebalanceAt === 0 ? 0 : w.lastRebalanceAt + w.params.rebalanceCooldown;
        if (w.now < readyAt) bits |= 256;
        let ready2 = readyAt;
        if (w.rebalancesToday >= w.params.maxRebalancesPerDay) {
          bits |= 512;
          ready2 = Math.max(readyAt, (Math.floor(w.now / 86_400) + 1) * 86_400);
        }
        return enc(vlt, f.name, [bits === 0, bits, ready2]);
      }
      case "guardParams": return enc(vlt, f.name, [[w.params.legBandBps, w.params.maxFeedAge, w.params.maxPoolOracleDevBps, w.params.rebalanceCooldown, w.params.maxRebalancesPerDay, w.params.maxSwapBps, w.params.maxRebalanceLossBps]]);
      case "rebalancesToday": return enc(vlt, f.name, [w.rebalancesToday]);
      case "lastRebalanceAt": return enc(vlt, f.name, [w.lastRebalanceAt]);
      case "rebalance": {
        const a = vlt.decodeFunctionData("rebalance", data);
        w.calls.sims++;
        w.rebalanceCalls.push(a);
        const q = w.simRevert.shift();
        if (q) throw revertErr(q.name, q.args);
        if (w.simRevertAlways) throw revertErr(w.simRevertAlways.name, w.simRevertAlways.args);
        return "0x";
      }
      case "pair": return enc(vlt, f.name, [w.wiring.pair]);
      case "rebalancer": return enc(vlt, f.name, [w.wiring.rebalancer]);
      case "feedAsset": return enc(vlt, f.name, [w.wiring.feedAsset]);
      case "feedPair": return enc(vlt, f.name, [w.wiring.feedPair]);
      case "asset": return enc(vlt, f.name, [w.wiring.asset]);
      case "pairToken": return enc(vlt, f.name, [w.wiring.pairToken]);
      case "openBand": {
        const a = vlt.decodeFunctionData("openBand", data);
        w.calls.sims++;
        w.openBandCalls.push(a);
        const q = w.simRevert.shift();
        if (q) throw revertErr(q.name, q.args);
        if (w.simRevertAlways) throw revertErr(w.simRevertAlways.name, w.simRevertAlways.args);
        if (w.band.hasBand) throw revertErr("BandExists", []);
        return "0x";
      }
      case "tripGuard":
        if (w.tripSimRevert) throw revertErr(w.tripSimRevert.name, w.tripSimRevert.args);
        return "0x";
    }
  }
  if (T === A.pair.toLowerCase()) {
    const f = pr.getFunction(sel);
    const a = pr.decodeFunctionData(sel, data);
    switch (f.name) {
      case "getActiveId": return enc(pr, f.name, [w.activeIdQueue.length ? w.activeIdQueue.shift()! : w.activeId]);
      case "getTokenX": return enc(pr, f.name, [w.tokenX]);
      case "getTokenY": return enc(pr, f.name, [w.tokenY]);
      case "getBinStep": return enc(pr, f.name, [1]);
      case "getBin": { const b = w.bins.get(Number(a[0])); return enc(pr, f.name, [b?.rx ?? 0n, b?.ry ?? 0n]); }
      case "balanceOf": return enc(pr, f.name, [w.bins.get(Number(a[1]))?.bal ?? 0n]);
      case "totalSupply": return enc(pr, f.name, [w.bins.get(Number(a[0]))?.supply ?? 0n]);
      case "getPriceFromId": return enc(pr, f.name, [(Q128 * w.priceNum) / w.priceDen]);
      case "burn": {
        w.burnCalls.push({ from, args: a });
        if (w.hookRevert) throw Object.assign(new Error("execution reverted: hook"), { data: "0x08c379a0" + utils.defaultAbiCoder.encode(["string"], ["Pharaoh hook: anti-sybil"]).slice(2) });
        if (w.burnZero) throw Object.assign(new Error("execution reverted"), { data: pr.encodeErrorResult("LBPair__ZeroAmountsOut", [1]) });
        return enc(pr, f.name, [[utils.hexZeroPad("0x01", 32)]]);
      }
      case "getSwapOut": { const r = swapOut(w, Boolean(a[1]), BigInt(a[0].toString())); return enc(pr, f.name, [r.left, r.out, 0n]); }
    }
  }
  if (T === A.feedAsset.toLowerCase() || T === A.feedPair.toLowerCase()) {
    const feed = T === A.feedAsset.toLowerCase() ? w.feedAsset : w.feedPair;
    const f = fd.getFunction(sel);
    if (f.name === "decimals") return enc(fd, f.name, [feed.decimals]);
    return enc(fd, f.name, [feed.roundId, feed.answer, feed.updatedAt, feed.updatedAt, feed.answeredInRound]);
  }
  if (T === A.usdc.toLowerCase() || T === A.usdt.toLowerCase()) {
    const f = erc.getFunction(sel);
    if (f.name === "decimals") return enc(erc, f.name, [T === w.tokenX.toLowerCase() ? w.decX : w.decY]);
    return enc(erc, f.name, [w.idle.get(T) ?? 0n]);
  }
  void from;
  throw new Error(`fake world: unexpected call to ${to} selector ${sel}`);
}

export class FakeProvider {
  constructor(public readonly w: World) {}
  async getNetwork(): Promise<{ chainId: number }> { return { chainId: 43114 }; }
  async call(tx: { from?: string; to: string; data: string }, _block?: unknown): Promise<string> {
    this.w.calls.eth_call++;
    try {
      return dispatch(this.w, tx.to, tx.data, tx.from);
    } catch (e) {
      // ethers v5 returns the revert data of some node error shapes as a plain RESULT (MEASURED on anvil): the keeper must not read that as a pass
      const data = (e as { data?: string }).data;
      if (this.w.revertAsResult && data) return data;
      throw e;
    }
  }
  async estimateGas(): Promise<BigNumber> { return BigNumber.from(500_000); }
  async getBalance(): Promise<BigNumber> { this.w.calls.getBalance++; return BigNumber.from(this.w.keeperBalance); }
  async getFeeData(): Promise<{ gasPrice: BigNumber; maxFeePerGas: BigNumber; maxPriorityFeePerGas: BigNumber }> {
    return { gasPrice: BigNumber.from(this.w.gasPrice), maxFeePerGas: BigNumber.from(this.w.gasPrice), maxPriorityFeePerGas: BigNumber.from(1_000_000_000) };
  }
  async getBlock(): Promise<{ number: number; timestamp: number }> { this.w.calls.getBlock++; return { number: this.w.block, timestamp: this.w.now - this.w.blockLag }; }
  async getTransactionReceipt(hash: string): Promise<{ status: number; to: string; blockNumber: number; logs: Array<{ address: string; topics: string[]; data: string; logIndex: number }> } | null> {
    const t = this.w.txs.get(hash);
    return t ? { status: t.status, to: t.to, blockNumber: t.block, logs: t.logs } : null;
  }
  async send(): Promise<never> { throw new Error("the fake provider never sends"); }
}

export class FakeSigner implements ExternalSigner {
  readonly kind = "fake";
  private n = 0;
  constructor(private readonly w: World, private readonly onSend?: (fn: string) => void) {}
  async getAddress(): Promise<string> { return A.keeper; }
  async sendTransaction(tx: TxRequest): Promise<SentTx> {
    const w = this.w;
    const hash = utils.keccak256(utils.toUtf8Bytes(`tx${this.n++}:${tx.data}`));
    const f = vlt.getFunction(tx.data.slice(0, 10));
    const args = vlt.decodeFunctionData(f.name, tx.data);
    this.onSend?.(f.name);
    w.sent.push({ hash, to: tx.to, fn: f.name, args });
    const logs: Array<{ address: string; topics: string[]; data: string; logIndex: number }> = [];
    let status = 1;
    w.block++;
    if (f.name === "rebalance") {
      if (w.minedRevert) status = 0;
      else {
        const oldL = w.band.lowerId;
        const oldU = w.band.upperId;
        const act = w.newActiveId ?? w.activeId;
        w.activeId = act;
        if (!w.lies.wrongBand) w.band = { lowerId: act - 1, upperId: act + 1, hasBand: true };
        if (!w.lies.noAdvance) w.lastRebalanceAt = w.now;
        w.rebalancesToday++;
        if (!w.lies.noEvent) {
          const ev = vlt.encodeEventLog(vlt.getEvent("Rebalanced"), [oldL, oldU, act - 1, act + 1, act, args.swapXForY, args.swapIn, args.swapMinOut, 1_000_000n, 999_900n]);
          logs.push({ address: A.vault, topics: ev.topics, data: ev.data, logIndex: 0 });
        }
      }
    } else if (f.name === "openBand") {
      if (w.minedRevert) status = 0;
      else {
        const act = w.activeId;
        if (!w.lies.wrongBand) w.band = { lowerId: act - 1, upperId: act + 1, hasBand: true };
        if (!w.lies.noEvent) {
          const ev = vlt.encodeEventLog(vlt.getEvent("BandOpened"), [act - 1, act + 1, act, 1_000_000n, 1_000_000n]);
          logs.push({ address: A.vault, topics: ev.topics, data: ev.data, logIndex: 0 });
        }
      }
    } else if (f.name === "tripGuard") w.latched = true;
    w.txs.set(hash, { block: w.block, status, to: A.vault, logs });
    return {
      hash,
      wait: async () => {
        if (status !== 1) throw Object.assign(new Error("transaction failed"), { code: "CALL_EXCEPTION" });
        return { status, blockNumber: w.block, gasUsed: BigNumber.from(400_000) };
      },
    };
  }
}

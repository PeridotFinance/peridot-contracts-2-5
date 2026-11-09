// A small in-memory world for the unit tests: a registry with the real decision rules (as MarginOrderRegistry.sol), a margin executor / vault / token model,
// a provider that answers eth_call (directly and through Multicall3), receipts and fee data, and a signer that "mines" transactions into it.
// The point is that the keeper's REAL encoding, decoding, simulation, send and read-back code runs against it; `lies` make the world misbehave after a send.
import { BigNumber, utils } from "ethers";
import { ADAPTER_ABI, ERC20_ABI, EXECUTOR_ABI, MULTICALL3_ABI, REGISTRY_ABI, SWAP_ERRORS_ABI, VAULT_ABI } from "../src/abi";
import { MULTICALL3, USDC, WAVAX } from "../src/constants";
import type { ExternalSigner, SentTx, TxRequest } from "../src/signer";
import { A } from "./fixtures";

const reg = new utils.Interface(REGISTRY_ABI);
const adp = new utils.Interface(ADAPTER_ABI);
const exe = new utils.Interface(EXECUTOR_ABI);
const vlt = new utils.Interface(VAULT_ABI);
const erc = new utils.Interface(ERC20_ABI);
const mc = new utils.Interface(MULTICALL3_ABI);
const errs = new utils.Interface([...REGISTRY_ABI.filter((x) => x.startsWith("error ")), ...ADAPTER_ABI.filter((x) => x.startsWith("error ")), ...SWAP_ERRORS_ABI]);

export interface FOrder { positionId: number; owner: string; kind: number; triggerAbove: boolean; trigger: bigint; closeBps: number; expiry: number; status: number }
export interface FPos { owner: string; status: number; margin: string; position: string; debt: string }
export interface World {
  head: number;
  now: number;
  nextOrderId: number;
  paused: boolean;
  adapterOfRegistry: string;
  registryOfAdapter: string;
  executorOfAdapter: string;
  oracleOk: boolean;
  price: bigint;
  orders: Map<number, FOrder>;
  positions: Map<number, FPos>;
  free: Map<string, bigint>; // owner:pToken
  keeperBal: Map<string, bigint>;
  keeperAvax: bigint;
  /** a close path failure: revert data of the simulation AND the transaction (e.g. SwapError(7)) */
  closeRevert?: { name: string; args: unknown[] };
  /** the simulation passes but the mined transaction reverts */
  minedRevert: boolean;
  lies: { noPositionClosed?: boolean; wrongExecutor?: boolean; noVaultCredit?: boolean; keeperGetsTokens?: boolean; noStatusChange?: boolean; noSiblingCancel?: boolean; closedAnythingOnSweep?: boolean };
  returned: bigint;
  /** fee-distributor rewards the vault settles into the owner's free balance in the same call */
  extraCredit: bigint;
  txs: Map<string, { block: number; logs: Array<{ address: string; topics: string[]; data: string; logIndex: number }>; status: number }>;
  sent: string[];
  calls: { simulations: number; getLogs: number };
}
type Snap = Pick<World, "orders" | "positions" | "free" | "keeperBal" | "nextOrderId">;
const clone = (w: World): Snap => ({ orders: new Map([...w.orders].map(([k, v]) => [k, { ...v }])), positions: new Map([...w.positions].map(([k, v]) => [k, { ...v }])), free: new Map(w.free), keeperBal: new Map(w.keeperBal), nextOrderId: w.nextOrderId });

export function newWorld(): World {
  const w: World = {
    head: 1000, now: 1_800_000_000, nextOrderId: 1, paused: false, adapterOfRegistry: A.adapter.toLowerCase(), registryOfAdapter: A.registry.toLowerCase(), executorOfAdapter: A.executor.toLowerCase(),
    oracleOk: true, price: 25n * 10n ** 18n, orders: new Map(), positions: new Map(), free: new Map(), keeperBal: new Map(), keeperAvax: 10n ** 18n, minedRevert: false, lies: {}, returned: 2_000_000_000n, extraCredit: 0n,
    txs: new Map(), sent: [], calls: { simulations: 0, getLogs: 0 },
  };
  for (const t of [A.pUsdc, A.pWavax, USDC, WAVAX]) w.keeperBal.set(t.toLowerCase(), 0n);
  return w;
}
export function addPosition(w: World, id: number, status = 2): void {
  w.positions.set(id, { owner: A.owner.toLowerCase(), status, margin: A.pUsdc.toLowerCase(), position: A.pWavax.toLowerCase(), debt: A.pUsdc.toLowerCase() });
  if (!w.free.has(`${A.owner.toLowerCase()}:${A.pUsdc.toLowerCase()}`)) w.free.set(`${A.owner.toLowerCase()}:${A.pUsdc.toLowerCase()}`, 1000n);
}
/** stop-loss (kind 1, triggerAbove false) by default */
export function addOrder(w: World, positionId: number, o: Partial<FOrder> = {}): number {
  const id = w.nextOrderId++;
  w.orders.set(id, { positionId, owner: A.owner.toLowerCase(), kind: 1, triggerAbove: false, trigger: 30n * 10n ** 18n, closeBps: 10_000, expiry: w.now + 86_400, status: 1, ...o });
  return id;
}

class Revert extends Error {
  constructor(public readonly data: string) {
    super("execution reverted");
  }
}
const revertWith = (name: string, args: unknown[] = []): never => {
  throw new Revert(errs.encodeErrorResult(errs.getError(name), args));
};
const open = (w: World, positionId: number): number[] => [...w.orders].filter(([, o]) => o.positionId === positionId && o.status === 1).map(([id]) => id);
const crossed = (w: World, o: FOrder): boolean => (o.triggerAbove ? w.price >= o.trigger : w.price <= o.trigger);

function canExecute(w: World, id: number): [boolean, bigint, number] {
  const o = w.orders.get(id);
  if (!o || o.status !== 1) return [false, 0n, 1];
  if (w.now > o.expiry) return [false, 0n, 2];
  const p = w.positions.get(o.positionId)!;
  if (p.status !== 2) return [false, 0n, 3];
  if (p.owner !== o.owner) return [false, 0n, 4];
  if (!w.oracleOk) return [false, 0n, 5];
  if (!crossed(w, o)) return [false, w.price, 6];
  if (w.paused) return [false, w.price, 7];
  return [true, w.price, 0];
}
function ev(name: string, values: unknown[]): { address: string; topics: string[]; data: string; logIndex: number } {
  const f = reg.getEvent(name);
  const e = reg.encodeEventLog(f, values);
  return { address: A.registry.toLowerCase(), topics: e.topics, data: e.data, logIndex: 0 };
}

/** The registry's executeOrder against the world. `apply` false = a simulation (state untouched, logs discarded). */
function executeOrder(w: World, id: number, apply: boolean, sender: string): { ret: boolean; logs: ReturnType<typeof ev>[] } {
  if (w.paused) revertWith("ExecutionPaused");
  const o = w.orders.get(id);
  if (!o || o.status !== 1) return revertWith("OrderNotOpen") as never;
  const logs: ReturnType<typeof ev>[] = [];
  if (w.now > o.expiry) {
    if (apply) { o.status = 4; logs.push(ev("OrderExpired", [id, o.positionId])); }
    return { ret: false, logs };
  }
  const p = w.positions.get(o.positionId)!;
  if (p.status !== 2) {
    if (apply) { o.status = 3; logs.push(ev("OrderCancelled", [id, o.positionId, 2])); }
    return { ret: false, logs };
  }
  if (p.owner !== o.owner) {
    if (apply) { o.status = 3; logs.push(ev("OrderCancelled", [id, o.positionId, 3])); }
    return { ret: false, logs };
  }
  if (!w.oracleOk) revertWith("OracleUnavailable");
  if (!crossed(w, o)) revertWith("TriggerNotReached", [w.price, o.trigger]);
  if (w.closeRevert) revertWith(w.closeRevert.name, w.closeRevert.args);
  if (w.minedRevert && apply) throw new Revert("0x");
  if (!apply) return { ret: true, logs };
  if (!w.lies.noStatusChange) o.status = 2;
  const exeAddr = A.executor.toLowerCase();
  const full = o.closeBps === 10_000;
  logs.push(ev("OrderExecuted", [id, o.positionId, w.lies.wrongExecutor ? A.owner : sender, w.price, o.closeBps, w.returned]));
  if (!w.lies.noPositionClosed) {
    const f = exe.getEvent("PositionClosed");
    const e = exe.encodeEventLog(f, [o.positionId, o.closeBps, 1n, w.returned, 0n, 20000n, full]);
    logs.push({ address: exeAddr, topics: e.topics, data: e.data, logIndex: 0 });
  }
  if (!w.lies.noVaultCredit) {
    const k = `${p.owner}:${p.margin}`;
    w.free.set(k, (w.free.get(k) ?? 0n) + w.returned + w.extraCredit);
  }
  if (w.lies.keeperGetsTokens) w.keeperBal.set(p.margin, (w.keeperBal.get(p.margin) ?? 0n) + 5n);
  if (full) {
    p.status = 5;
    if (!w.lies.noSiblingCancel) for (const sid of open(w, o.positionId)) { w.orders.get(sid)!.status = 3; logs.push(ev("OrderCancelled", [sid, o.positionId, 1])); }
  }
  return { ret: true, logs };
}

export class FakeProvider {
  private history = new Map<number, Snap>();
  constructor(public readonly w: World) {
    this.history.set(w.head, clone(w));
  }
  async getNetwork(): Promise<{ chainId: number }> { return { chainId: 43114 }; }
  async getBlockNumber(): Promise<number> { return this.w.head; }
  async getBlock(_tag: string): Promise<{ number: number; timestamp: number }> { return { number: this.w.head, timestamp: this.w.now }; }
  async getBalance(_a: string): Promise<BigNumber> { return BigNumber.from(this.w.keeperAvax); }
  async getFeeData(): Promise<{ maxFeePerGas: BigNumber; maxPriorityFeePerGas: BigNumber; gasPrice: BigNumber }> {
    return { maxFeePerGas: utils.parseUnits("30", "gwei"), maxPriorityFeePerGas: utils.parseUnits("1", "gwei"), gasPrice: utils.parseUnits("25", "gwei") };
  }
  async estimateGas(tx: { to: string; data: string; from?: string }): Promise<BigNumber> {
    await this.call(tx); // a failing call fails the estimate, as on a node
    return BigNumber.from(500_000);
  }
  async getTransactionReceipt(hash: string): Promise<any> {
    const t = this.w.txs.get(hash);
    if (!t) return null;
    return { to: A.registry, status: t.status, blockNumber: t.block, logs: t.logs.map((l, i) => ({ ...l, logIndex: i, blockNumber: t.block, transactionHash: hash })) };
  }
  snapshotNow(): void { this.history.set(this.w.head, clone(this.w)); }
  private view(tag: unknown): Snap {
    if (typeof tag === "number" && this.history.has(tag)) return this.history.get(tag)!;
    return this.w;
  }
  async call(tx: { to: string; data: string; from?: string }, tag?: unknown): Promise<string> {
    const to = tx.to.toLowerCase();
    const w = this.w;
    const v = this.view(tag);
    const d = tx.data;
    if (to === MULTICALL3.toLowerCase()) {
      const [calls] = mc.decodeFunctionData("aggregate3", d) as unknown as [Array<{ target: string; allowFailure: boolean; callData: string }>];
      const res = [];
      for (const c of calls) {
        try {
          res.push({ success: true, returnData: await this.call({ to: c.target, data: c.callData }, tag) });
        } catch (e) {
          if (!c.allowFailure) throw e;
          res.push({ success: false, returnData: "0x" });
        }
      }
      return mc.encodeFunctionResult("aggregate3", [res]);
    }
    if (to === A.registry.toLowerCase()) {
      const f = reg.getFunction(d.slice(0, 10));
      const args = reg.decodeFunctionData(f, d);
      switch (f.name) {
        case "nextOrderId": return reg.encodeFunctionResult(f, [v.nextOrderId]);
        case "adapter": return reg.encodeFunctionResult(f, [w.adapterOfRegistry]);
        case "paused": return reg.encodeFunctionResult(f, [w.paused]);
        case "getOrder": {
          const o = v.orders.get(Number(args[0]));
          const t = o ?? { positionId: 0, owner: "0x" + "0".repeat(40), kind: 0, triggerAbove: false, trigger: 0n, closeBps: 0, expiry: 0, status: 0 };
          return reg.encodeFunctionResult(f, [[t.positionId, t.owner, t.kind, t.triggerAbove, t.trigger, t.closeBps, 100, t.expiry, 1, 1, t.status]]);
        }
        case "canExecute": return reg.encodeFunctionResult(f, canExecute(w, Number(args[0])));
        case "openOrdersOf": return reg.encodeFunctionResult(f, [[...[...v.orders].filter(([, o]) => o.positionId === Number(args[0]) && o.status === 1).map(([id]) => id)]]);
        case "executeOrder": {
          w.calls.simulations++;
          const r = executeOrder(w, Number(args[0]), false, tx.from ?? "");
          return reg.encodeFunctionResult(f, [r.ret]);
        }
      }
    }
    if (to === A.adapter.toLowerCase()) {
      const f = adp.getFunction(d.slice(0, 10));
      return adp.encodeFunctionResult(f, [f.name === "registry" ? w.registryOfAdapter : w.executorOfAdapter]);
    }
    if (to === A.executor.toLowerCase()) {
      const f = exe.getFunction(d.slice(0, 10));
      const id = Number(exe.decodeFunctionData(f, d)[0]);
      const p = v.positions.get(id);
      if (!p) throw new Revert("0x");
      return exe.encodeFunctionResult(f, [id, p.owner, "0x" + "ab".repeat(20), p.margin, p.position, p.debt, 0, 0, 0, 200, 0, p.status]);
    }
    if (to === A.vault.toLowerCase()) {
      const f = vlt.getFunction(d.slice(0, 10));
      const [u, t] = vlt.decodeFunctionData(f, d);
      return vlt.encodeFunctionResult(f, [v.free.get(`${String(u).toLowerCase()}:${String(t).toLowerCase()}`) ?? 0n]);
    }
    const f = erc.getFunction(d.slice(0, 10));
    return erc.encodeFunctionResult(f, [v.keeperBal.get(to) ?? 0n]);
  }
}

export class FakeSigner implements ExternalSigner {
  readonly kind = "fake";
  constructor(private readonly world: World, private readonly provider: FakeProvider, private readonly address: string = A.keeper, private readonly onSend?: () => void) {}
  async getAddress(): Promise<string> { return this.address; }
  async sendTransaction(tx: TxRequest): Promise<SentTx> {
    const w = this.world;
    this.onSend?.();
    const hash = utils.keccak256(utils.toUtf8Bytes(`tx${w.sent.length}${tx.data}`));
    w.sent.push(hash);
    const [id] = reg.decodeFunctionData("executeOrder", tx.data);
    let status = 1;
    let logs: ReturnType<typeof ev>[] = [];
    this.provider.snapshotNow(); // state at the block before
    w.head += 1;
    w.now += 2;
    try {
      logs = executeOrder(w, Number(id), true, this.address).logs;
      if (w.lies.closedAnythingOnSweep) {
        const f = exe.getEvent("PositionClosed");
        const e = exe.encodeEventLog(f, [1, 10000, 1n, 5n, 0n, 20000n, true]);
        logs.push({ address: A.executor.toLowerCase(), topics: e.topics, data: e.data, logIndex: 0 });
      }
    } catch {
      status = 0;
    }
    w.txs.set(hash, { block: w.head, logs, status });
    this.provider.snapshotNow();
    return {
      hash,
      wait: async () => {
        if (status !== 1) throw Object.assign(new Error("transaction failed"), { code: "CALL_EXCEPTION" });
        return { status: 1, blockNumber: w.head, gasUsed: BigNumber.from(400_000) };
      },
    };
  }
}

// The chain port: everything the keeper step needs from the chain, behind an interface so that the decision logic is unit-tested with fakes
// (test/keeper.test.ts) and run for real against an anvil fork (test/fork). `EthersPort` is the real implementation (ethers v5).
import { BigNumber, Contract, providers, utils } from "ethers";
import { custodianIface, EXECUTOR_ABI, CUSTODIAN_ABI } from "./abi";
import type { ExternalSigner } from "./signer";
import { feesWithin, makeSender, TxReverted } from "./txkit";
import { pacedGetLogs } from "./logpace";
import { safeError } from "./mask";

export interface OrderRead {
  status: number;
  rungCount: number;
  rungStatuses: number[];
}
export type Sim = { ok: true; gas: bigint } | { ok: false; name: string; message: string };
export type FeeRead = { ok: true; maxFeePerGas: bigint; maxPriorityFeePerGas: bigint } | { ok: false; reason: string };
export interface Sent {
  hash: string;
  blockNumber: number;
  gasUsed: bigint;
  /** from the receipt's RangeOrderSettled event, when present */
  settled?: { repaid: bigint; remainingDebt: bigint; positionClosed: boolean };
}
export interface ChainPort {
  chainId(): Promise<number>;
  head(): Promise<{ number: number; timestamp: number }>;
  nextPositionId(): Promise<bigint>;
  positionStatus(positionId: bigint): Promise<number>;
  finalizable(positionId: bigint): Promise<{ active: number; ready: number }>;
  order(positionId: bigint): Promise<OrderRead>;
  simulateFinalize(positionId: bigint): Promise<Sim>;
  fees(): Promise<FeeRead>;
  keeperAddress(): Promise<string>;
  keeperBalanceWei(): Promise<bigint>;
  /** throws TxReverted when mined with status 0; any other throw = unknown state */
  sendFinalize(positionId: bigint, gasLimit: bigint, fees: { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint }): Promise<Sent>;
}
export { TxReverted };

export interface PortConfig {
  custodian: string;
  maxFeeGwei: number;
  logChunkBlocks: number;
}

export class EthersPort implements ChainPort {
  private readonly cust: Contract;
  private executorAddr?: string;
  constructor(
    private readonly provider: providers.Provider,
    private readonly signer: ExternalSigner,
    private readonly cfg: PortConfig,
    private readonly logProvider: providers.Provider = provider,
  ) {
    this.cust = new Contract(cfg.custodian, CUSTODIAN_ABI, provider);
  }
  private async executor(): Promise<Contract> {
    if (!this.executorAddr) this.executorAddr = (await this.cust.executor()) as string;
    return new Contract(this.executorAddr, EXECUTOR_ABI, this.provider);
  }
  async chainId(): Promise<number> {
    return (await this.provider.getNetwork()).chainId;
  }
  async head(): Promise<{ number: number; timestamp: number }> {
    const b = await this.provider.getBlock("latest");
    return { number: b.number, timestamp: b.timestamp };
  }
  async nextPositionId(): Promise<bigint> {
    return BigInt(((await (await this.executor()).nextPositionId()) as BigNumber).toString());
  }
  async positionStatus(positionId: bigint): Promise<number> {
    const p = await (await this.executor()).positions(positionId.toString());
    return Number(p.status);
  }
  async finalizable(positionId: bigint): Promise<{ active: number; ready: number }> {
    const r = await this.cust.finalizable(positionId.toString());
    return { active: Number(r.activeRungs), ready: Number(r.readyRungs) };
  }
  async order(positionId: bigint): Promise<OrderRead> {
    const o = await this.cust.getOrder(positionId.toString());
    const n = Number(o.rungCount);
    return { status: Number(o.status), rungCount: n, rungStatuses: [0, 1, 2].slice(0, n).map((i) => Number(o.rungs[i].status)) };
  }
  async simulateFinalize(positionId: bigint): Promise<Sim> {
    const from = await this.signer.getAddress();
    const data = custodianIface.encodeFunctionData("finalize", [positionId.toString()]);
    try {
      await this.provider.call({ from, to: this.cfg.custodian, data });
      const gas = await this.provider.estimateGas({ from, to: this.cfg.custodian, data });
      return { ok: true, gas: BigInt(gas.toString()) };
    } catch (e) {
      const raw = (e as { error?: { data?: string }; data?: string }).data ?? (e as { error?: { data?: string } }).error?.data ?? findRevertData(e);
      if (raw && raw.length >= 10) {
        try {
          const err = custodianIface.parseError(raw);
          return { ok: false, name: err.name, message: `${err.name}(${err.args.map(String).join(",")})` };
        } catch {
          return { ok: false, name: "UnknownError", message: `revert data ${raw.slice(0, 74)}` };
        }
      }
      return { ok: false, name: "SimulationFailed", message: safeError(e) };
    }
  }
  async fees(): Promise<FeeRead> {
    const r = await feesWithin(this.provider, this.cfg.maxFeeGwei);
    return r.ok ? { ok: true, maxFeePerGas: BigInt(r.fees.maxFeePerGas.toString()), maxPriorityFeePerGas: BigInt(r.fees.maxPriorityFeePerGas.toString()) } : r;
  }
  async keeperAddress(): Promise<string> {
    return this.signer.getAddress();
  }
  async keeperBalanceWei(): Promise<bigint> {
    return BigInt((await this.provider.getBalance(await this.signer.getAddress())).toString());
  }
  async sendFinalize(positionId: bigint, gasLimit: bigint, fees: { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint }): Promise<Sent> {
    const send = makeSender(this.signer, { maxFeePerGas: BigNumber.from(fees.maxFeePerGas.toString()), maxPriorityFeePerGas: BigNumber.from(fees.maxPriorityFeePerGas.toString()) });
    const r = await send(this.cfg.custodian, custodianIface.encodeFunctionData("finalize", [positionId.toString()]), BigNumber.from(gasLimit.toString()));
    const receipt = await this.provider.getTransactionReceipt(r.hash);
    let settled: Sent["settled"];
    for (const l of receipt.logs) {
      if (l.address.toLowerCase() !== this.cfg.custodian.toLowerCase()) continue;
      try {
        const ev = custodianIface.parseLog(l);
        if (ev.name === "RangeOrderSettled") settled = { repaid: BigInt(ev.args.repaid.toString()), remainingDebt: BigInt(ev.args.remainingDebt.toString()), positionClosed: Boolean(ev.args.positionClosed) };
      } catch {
        /* not one of ours */
      }
    }
    return { hash: r.hash, blockNumber: r.blockNumber, gasUsed: BigInt(r.gasUsed.toString()), settled };
  }

  /** Optional discovery by `RangeOrderCreated` events (log endpoint, paced, chunked, back-off after a 429). The default discovery is positions 1..nextPositionId-1: no logs. */
  async createdSince(fromBlock: number, toBlock: number): Promise<bigint[]> {
    const topic = custodianIface.getEventTopic("RangeOrderCreated");
    const ids: bigint[] = [];
    for (let s = fromBlock; s <= toBlock; s += this.cfg.logChunkBlocks) {
      const logs = await pacedGetLogs(this.logProvider, { address: this.cfg.custodian, fromBlock: s, toBlock: Math.min(toBlock, s + this.cfg.logChunkBlocks - 1), topics: [topic] });
      for (const l of logs) ids.push(BigInt(utils.hexZeroPad(l.topics[1]!, 32)));
    }
    return ids;
  }
}

function findRevertData(e: unknown): string | undefined {
  const seen = new Set<unknown>();
  const walk = (x: any): string | undefined => {
    if (!x || typeof x !== "object" || seen.has(x)) return undefined;
    seen.add(x);
    for (const k of ["data", "error", "body"]) {
      const v = x[k];
      if (typeof v === "string" && /^0x[0-9a-fA-F]{8,}$/.test(v)) return v;
      if (typeof v === "string" && k === "body") {
        const m = v.match(/"data":"(0x[0-9a-fA-F]{8,})"/);
        if (m) return m[1];
      }
      const r = walk(v);
      if (r) return r;
    }
    return undefined;
  };
  return walk(e);
}

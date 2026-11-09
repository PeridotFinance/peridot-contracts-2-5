// Reads from the registry at the HEAD (never an archive block): order discovery by id, canExecute per order, and the position / vault / balance
// reads used by the read-back. Everything goes through Multicall3 as one eth_call; a reverting call is reported as failed, never as a value.
import { providers, utils } from "ethers";
import { ADAPTER_ABI, ERC20_ABI, EXECUTOR_ABI, REGISTRY_ABI, VAULT_ABI } from "./abi";
import { MULTICALL3, USDC, WAVAX } from "./constants";
import { multicall } from "./multicall";
import type { Call } from "./multicall";

export const registryIface = new utils.Interface(REGISTRY_ABI);
export const adapterIface = new utils.Interface(ADAPTER_ABI);
export const executorIface = new utils.Interface(EXECUTOR_ABI);
export const vaultIface = new utils.Interface(VAULT_ABI);
export const erc20Iface = new utils.Interface(ERC20_ABI);

export interface OrderView {
  id: bigint;
  positionId: bigint;
  owner: string;
  kind: number; // 0 TAKE_PROFIT, 1 STOP_LOSS
  triggerAbove: boolean;
  triggerPriceE18: bigint;
  closeBps: number;
  maxSlippageBps: number;
  expiry: bigint;
  status: number;
}
export interface CanView {
  executable: boolean;
  priceE18: bigint;
  reason: number;
}
export interface OrderItem {
  id: bigint;
  /** null: getOrder itself failed */
  order: OrderView | null;
  /** null: canExecute failed (it should never revert) */
  can: CanView | null;
}
export interface PositionView {
  id: bigint;
  owner: string;
  marginPToken: string;
  positionPToken: string;
  debtPToken: string;
  side: number;
  status: number;
}

const toBig = (x: unknown): bigint => BigInt((x as { toString(): string }).toString());

export function parseOrder(id: bigint, v: any): OrderView {
  return { id, positionId: toBig(v.positionId), owner: String(v.owner).toLowerCase(), kind: Number(v.kind), triggerAbove: !!v.triggerAbove, triggerPriceE18: toBig(v.triggerPriceE18), closeBps: Number(v.closeBps), maxSlippageBps: Number(v.maxSlippageBps), expiry: toBig(v.expiry), status: Number(v.status) };
}

/** nextOrderId, registry.adapter(), adapter.registry(), adapter.executor() and registry.paused(): one batch, one block. */
export async function readRegistryHead(provider: providers.Provider, registry: string, closeAdapter: string): Promise<{ nextOrderId: bigint; adapterOfRegistry: string; registryOfAdapter: string; executorOfAdapter: string; paused: boolean }> {
  const calls: Call[] = [
    { target: registry, iface: registryIface, fn: "nextOrderId", allowFailure: false },
    { target: registry, iface: registryIface, fn: "adapter", allowFailure: false },
    { target: closeAdapter, iface: adapterIface, fn: "registry", allowFailure: false },
    { target: closeAdapter, iface: adapterIface, fn: "executor", allowFailure: false },
    { target: registry, iface: registryIface, fn: "paused", allowFailure: false },
  ];
  const r = await multicall(provider, calls, "latest", MULTICALL3);
  if (r.some((x) => !x.success)) throw new Error("registry head read failed (a call reverted: wrong registry or adapter address?)");
  return {
    nextOrderId: toBig(r[0]!.value![0]),
    adapterOfRegistry: String(r[1]!.value![0]).toLowerCase(),
    registryOfAdapter: String(r[2]!.value![0]).toLowerCase(),
    executorOfAdapter: String(r[3]!.value![0]).toLowerCase(),
    paused: !!r[4]!.value![0],
  };
}

export const IDS_PER_BATCH = 60; // 2 calls each

/** getOrder + canExecute for each id, in batches, at the head. */
export async function readOrders(provider: providers.Provider, registry: string, ids: bigint[]): Promise<OrderItem[]> {
  const out: OrderItem[] = [];
  for (let i = 0; i < ids.length; i += IDS_PER_BATCH) {
    const chunk = ids.slice(i, i + IDS_PER_BATCH);
    const calls: Call[] = chunk.flatMap((id) => [
      { target: registry, iface: registryIface, fn: "getOrder", args: [id.toString()], allowFailure: true },
      { target: registry, iface: registryIface, fn: "canExecute", args: [id.toString()], allowFailure: true },
    ]);
    const r = await multicall(provider, calls, "latest", MULTICALL3);
    chunk.forEach((id, k) => {
      const o = r[2 * k]!;
      const c = r[2 * k + 1]!;
      out.push({
        id,
        order: o.success ? parseOrder(id, o.value![0]) : null,
        can: c.success ? { executable: !!c.value![0], priceE18: toBig(c.value![1]), reason: Number(c.value![2]) } : null,
      });
    });
  }
  return out;
}

export async function readPosition(provider: providers.Provider, executor: string, positionId: bigint, block: number | "latest"): Promise<PositionView> {
  const [r] = await multicall(provider, [{ target: executor, iface: executorIface, fn: "positions", args: [positionId.toString()], allowFailure: false }], block, MULTICALL3);
  if (!r?.success) throw new Error("position read failed");
  const v = r.value!;
  return { id: toBig(v.id), owner: String(v.owner).toLowerCase(), marginPToken: String(v.marginPToken).toLowerCase(), positionPToken: String(v.positionPToken).toLowerCase(), debtPToken: String(v.debtPToken).toLowerCase(), side: Number(v.side), status: Number(v.status) };
}

export interface Snapshot {
  pos: PositionView;
  /** vault free balance of the position owner in the margin pToken (null when the read failed) */
  free: bigint | null;
  /** the keeper wallet's balances of the position's pTokens, USDC and WAVAX */
  keeperBalances: Record<string, bigint>;
  open: bigint[];
  order: OrderView | null;
}
export function trackedTokens(pos: PositionView): string[] {
  return [...new Set([pos.marginPToken, pos.positionPToken, pos.debtPToken, USDC.toLowerCase(), WAVAX.toLowerCase()])];
}
/** Everything the read-back compares, at one block. `pos` must be the position as read before (it names the tokens). */
export async function readSnapshot(provider: providers.Provider, cfg: { registry: string; marginExecutor: string; marginVault: string }, keeper: string, orderId: bigint, pos: PositionView, block: number | "latest"): Promise<Snapshot> {
  const tokens = trackedTokens(pos);
  const calls: Call[] = [
    { target: cfg.marginExecutor, iface: executorIface, fn: "positions", args: [pos.id.toString()], allowFailure: false },
    { target: cfg.marginVault, iface: vaultIface, fn: "freeBalance", args: [pos.owner, pos.marginPToken], allowFailure: true },
    { target: cfg.registry, iface: registryIface, fn: "openOrdersOf", args: [pos.id.toString()], allowFailure: false },
    { target: cfg.registry, iface: registryIface, fn: "getOrder", args: [orderId.toString()], allowFailure: false },
    ...tokens.map((t): Call => ({ target: t, iface: erc20Iface, fn: "balanceOf", args: [keeper], allowFailure: false })),
  ];
  const r = await multicall(provider, calls, block, MULTICALL3);
  if (!r[0]!.success || !r[2]!.success || !r[3]!.success || r.slice(4).some((x) => !x.success)) throw new Error("snapshot read failed");
  const v = r[0]!.value!;
  const keeperBalances: Record<string, bigint> = {};
  tokens.forEach((t, i) => (keeperBalances[t] = toBig(r[4 + i]!.value![0])));
  return {
    pos: { id: toBig(v.id), owner: String(v.owner).toLowerCase(), marginPToken: String(v.marginPToken).toLowerCase(), positionPToken: String(v.positionPToken).toLowerCase(), debtPToken: String(v.debtPToken).toLowerCase(), side: Number(v.side), status: Number(v.status) },
    free: r[1]!.success ? toBig(r[1]!.value![0]) : null,
    keeperBalances,
    open: (r[2]!.value![0] as unknown[]).map(toBig),
    order: parseOrder(orderId, r[3]!.value![0]),
  };
}

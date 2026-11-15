// VAULT REBALANCER module (R3 ship, decision of 2026-11-06). Its own process, its own FOURTH keystore. It is the `rebalancer()` of the two Pharaoh vaults
// (rotated from the Ledger by one Safe transaction per vault) and does only what that role can do:
//   deployIdle()  put idle assets (deposits waiting, collected fees) into the position;
//   rebalance()   re-centre the position when the spot price is out of range or close to an edge.
// It cannot pause, unpause, change a cap, upgrade, harvest rewards or exit the position (those are owner = Safe functions).
//
// What a COMPROMISED rebalancer key can do (read before trusting it): call `rebalance()` repeatedly. Each call is bounded by the contract's own guards (TWAP
// and oracle deviation checks, per-swap slippage, `ExcessiveLoss` of about 3% of value per call) but nothing in the contract limits how OFTEN, so repeated calls
// can bleed value through swap costs. The limits in this module (a minimum interval, a maximum number of actions a day, a per-action loss bound that HALTS it)
// protect against its own mistakes, not against a thief with the key. The mitigation is operational: the Safe can rotate the role away with `setRebalancer`
// in one transaction, the monitor watches totalAssets, and the key is not shared with the keeper's USDC wallet.
//
// Discipline is the same as the keeper and the executor: every transaction is SIMULATED first; gas limit = estimate x 1.5 (a raw estimate is NOT safe for
// these calls: reproduced, vault-opening document); a PENDING marker is persisted before the transaction and cleared after the read-back, one found at start-up
// HALTS; any unexpected result HALTS; fee cap and gas floor; the signer address must be the vault's `rebalancer()`.
import { BigNumber, providers, utils } from "ethers";
import type { AlertManager } from "./alerts";
import type { MonitorConfig } from "./config";
import type { ExternalSigner } from "./signer";
import { feesWithin, makeSender, TxReverted } from "./txkit";
import { safeError } from "./mask";

export const VAULT_REBALANCER_ABI = [
  "function asset() view returns (address)",
  "function pairedToken() view returns (address)",
  "function pool() view returns (address)",
  "function tokenId() view returns (uint256)",
  "function positionTickLower() view returns (int24)",
  "function positionTickUpper() view returns (int24)",
  "function rebalancer() view returns (address)",
  "function paused() view returns (bool)",
  "function totalAssets() view returns (uint256)",
  "function deployIdle()",
  "function rebalance()",
  "event Rebalanced(uint256 indexed oldTokenId, uint256 indexed newTokenId, int24 tickLower, int24 tickUpper, uint256 valueBefore, uint256 valueAfter)",
];
const vIface = new utils.Interface(VAULT_REBALANCER_ABI);
const erc = new utils.Interface(["function balanceOf(address) view returns (uint256)"]);
const poolIface = new utils.Interface(["function slot0() view returns (uint160,int24,uint16,uint16,uint16,uint32,bool)"]);

export type Action = "deployIdle" | "rebalance";
export interface RebalancerState {
  halted: null | { reason: string; at: number };
  pending: null | { vault: string; action: Action; at: number };
  /** unix seconds of the last rebalance per vault */
  lastRebalanceAt: Record<string, number>;
  /** timestamps (unix s) of every action in the last 24 h */
  actions: Array<{ ts: number; vault: string; action: Action; tx: string }>;
}
export const emptyRebalancerState = (): RebalancerState => ({ halted: null, pending: null, lastRebalanceAt: {}, actions: [] });

// ------------------------------------------------------------------ pure decision (unit-tested)
export interface VaultView {
  paused: boolean;
  tokenId: bigint;
  tickLower: number;
  tickUpper: number;
  spotTick: number;
  idleAsset: bigint;
  idlePaired: bigint;
}
export function decide(a: { v: VaultView; edgeTicks: number; deployIdleMinAssetUnits: bigint; lastRebalanceAt: number | undefined; now: number; minRebalanceIntervalSeconds: number }): { action: Action | null; why: string } {
  const { v } = a;
  if (v.paused) return { action: null, why: "vault is paused" };
  if (v.tokenId === 0n) return v.idleAsset >= a.deployIdleMinAssetUnits ? { action: "deployIdle", why: "no position yet and idle assets waiting" } : { action: null, why: "no position and nothing to deploy" };
  const outOfRange = v.spotTick <= v.tickLower || v.spotTick >= v.tickUpper;
  const nearEdge = v.spotTick - v.tickLower <= a.edgeTicks || v.tickUpper - v.spotTick <= a.edgeTicks;
  if (outOfRange || nearEdge) {
    if (a.lastRebalanceAt !== undefined && a.now - a.lastRebalanceAt < a.minRebalanceIntervalSeconds) return { action: null, why: `rebalance wanted (${outOfRange ? "out of range" : "near the edge"}) but the last one was ${a.now - a.lastRebalanceAt}s ago (minimum ${a.minRebalanceIntervalSeconds}s)` };
    return { action: "rebalance", why: outOfRange ? "spot is outside the position range" : "spot is within the edge buffer" };
  }
  if (v.idleAsset >= a.deployIdleMinAssetUnits) return { action: "deployIdle", why: "idle assets above the threshold" };
  return { action: null, why: "in range, nothing idle" };
}

/** loss in bps of `before` (0 when the value rose) */
export function lossBps(before: bigint, after: bigint): number {
  if (before === 0n || after >= before) return 0;
  return Number(((before - after) * 10_000n) / before);
}

// ------------------------------------------------------------------ execution
export interface RebalancerDeps {
  provider: providers.Provider;
  cfg: MonitorConfig;
  signer: ExternalSigner;
  alerts: AlertManager;
  persist: (s: RebalancerState) => void;
  now?: () => number;
}
export interface RebalancerOutcome {
  state: RebalancerState;
  done: Array<{ vault: string; action: Action; tx: string; lossBps: number }>;
  skipped: string[];
  halted: boolean;
}

export async function rebalancerStep(deps: RebalancerDeps, state: RebalancerState): Promise<RebalancerOutcome> {
  const { provider, cfg, alerts } = deps;
  const rc = cfg.rebalancer;
  const nowS = (): number => deps.now?.() ?? Math.floor(Date.now() / 1000);
  const out: RebalancerOutcome = { state, done: [], skipped: [], halted: !!state.halted };
  if (!rc.enabled) return out;
  let st = state;
  const halt = async (reason: string): Promise<RebalancerOutcome> => {
    st = { ...st, halted: { reason, at: nowS() } };
    deps.persist(st);
    await alerts.raise({ key: "rebalancer:halted", severity: "crit", message: `VAULT REBALANCER HALTED: ${reason}. No further transaction until a human clears rebalancer.halted / rebalancer.pending in the state file`, audience: "treasury-signers" }, nowS());
    return { ...out, state: st, halted: true };
  };
  if (st.pending && !st.halted) return halt(`a ${st.pending.action} on ${st.pending.vault} started at ${st.pending.at} was interrupted (process stopped between send and read-back): check the vault`);
  if (st.halted) return out;

  const me = await deps.signer.getAddress();
  const feesR = await feesWithin(provider, rc.maxFeeGwei);
  if (!feesR.ok) {
    out.skipped.push(feesR.reason);
    return out;
  }
  const gas = await provider.getBalance(me);
  if (gas.lt(rc.minGasWei)) {
    out.skipped.push(`AVAX ${gas.toString()} wei below the floor ${rc.minGasWei}`);
    await alerts.raise({ key: "rebalancer:gas", severity: "crit", message: `rebalancer wallet AVAX ${gas.toString()} wei is below the floor ${rc.minGasWei}`, audience: "treasury-signers" }, nowS());
    return out;
  }
  await alerts.clear("rebalancer:gas", nowS());
  const send = makeSender(deps.signer, feesR.fees);
  const day = nowS() - 86_400;
  st = { ...st, actions: st.actions.filter((x) => x.ts > day) };

  for (const vc of rc.vaults) {
    const key = vc.address.toLowerCase();
    const call = async (to: string, iface: utils.Interface, fn: string, args: unknown[] = []) => iface.decodeFunctionResult(fn, await provider.call({ to, data: iface.encodeFunctionData(fn, args) }));
    // 1. am I this vault's rebalancer?
    const reb = (await call(vc.address, vIface, "rebalancer"))[0] as string;
    if (reb.toLowerCase() !== me.toLowerCase()) {
      out.skipped.push(`${vc.name}: the vault's rebalancer() is ${reb}, not this wallet`);
      await alerts.raise({ key: `rebalancer:role:${key}`, severity: "warn", message: `${vc.name}: this wallet is not the vault's rebalancer (it is ${reb}); nothing is done until the Safe rotates the role`, audience: "treasury-signers" }, nowS());
      continue;
    }
    await alerts.clear(`rebalancer:role:${key}`, nowS());
    // 2. read the vault
    const asset = (await call(vc.address, vIface, "asset"))[0] as string;
    const paired = (await call(vc.address, vIface, "pairedToken"))[0] as string;
    const poolAddr = (await call(vc.address, vIface, "pool"))[0] as string;
    const view: VaultView = {
      paused: (await call(vc.address, vIface, "paused"))[0] as boolean,
      tokenId: BigInt((await call(vc.address, vIface, "tokenId"))[0].toString()),
      tickLower: Number((await call(vc.address, vIface, "positionTickLower"))[0]),
      tickUpper: Number((await call(vc.address, vIface, "positionTickUpper"))[0]),
      spotTick: Number((await call(poolAddr, poolIface, "slot0"))[1]),
      idleAsset: BigInt((await call(asset, erc, "balanceOf", [vc.address]))[0].toString()),
      idlePaired: BigInt((await call(paired, erc, "balanceOf", [vc.address]))[0].toString()),
    };
    const d = decide({ v: view, edgeTicks: rc.edgeTicks, deployIdleMinAssetUnits: BigInt(vc.deployIdleMinAssetUnits), lastRebalanceAt: st.lastRebalanceAt[key], now: nowS(), minRebalanceIntervalSeconds: rc.minRebalanceIntervalSeconds });
    if (!d.action) {
      out.skipped.push(`${vc.name}: ${d.why}`);
      continue;
    }
    if (st.actions.length >= rc.maxActionsPerDay) {
      out.skipped.push(`${vc.name}: ${d.action} wanted but ${rc.maxActionsPerDay} actions were already taken in 24 h`);
      await alerts.raise({ key: "rebalancer:daily-limit", severity: "crit", message: `the rebalancer reached its limit of ${rc.maxActionsPerDay} actions in 24 h and wants to do more: unusual activity, a human should look`, audience: "treasury-signers" }, nowS());
      continue;
    }
    // 3. simulate (a guard revert here is normal: price deviation; try again next cycle)
    const data = vIface.encodeFunctionData(d.action);
    let gasLimit: BigNumber;
    try {
      await provider.call({ from: me, to: vc.address, data });
      gasLimit = (await provider.estimateGas({ from: me, to: vc.address, data })).mul(15).div(10); // +50%: a raw estimate is not safe for these calls
    } catch (e) {
      out.skipped.push(`${vc.name}: ${d.action} simulation reverted (${safeError(e)}): the vault's guard, try again later`);
      await alerts.raise({ key: `rebalancer:sim:${key}:${d.action}`, severity: "warn", message: `${vc.name}: ${d.action} (${d.why}) cannot run now: ${safeError(e)}`, audience: "treasury-signers" }, nowS());
      continue;
    }
    await alerts.clear(`rebalancer:sim:${key}:${d.action}`, nowS());
    // 4. send, with the pending marker persisted FIRST
    const before = BigInt((await call(vc.address, vIface, "totalAssets"))[0].toString());
    st = { ...st, pending: { vault: vc.address, action: d.action, at: nowS() } };
    deps.persist(st);
    let tx;
    try {
      tx = await send(vc.address, data, gasLimit);
    } catch (e) {
      st = { ...st, pending: null };
      deps.persist(st);
      if (e instanceof TxReverted) {
        out.skipped.push(`${vc.name}: ${d.action} transaction reverted after a passing simulation (${e.hash})`);
        await alerts.raise({ key: `rebalancer:revert:${key}`, severity: "crit", message: `${vc.name}: ${d.action} was mined and REVERTED (${e.hash}) after a passing simulation`, audience: "treasury-signers" }, nowS());
        continue;
      }
      return halt(`unexpected error while sending ${d.action} on ${vc.name}: ${safeError(e)}`);
    }
    // 5. read-back and bound
    const receipt = await provider.getTransactionReceipt(tx.hash);
    const after = BigInt(vIface.decodeFunctionResult("totalAssets", await provider.call({ to: vc.address, data: vIface.encodeFunctionData("totalAssets") }, receipt.blockNumber))[0].toString());
    const loss = lossBps(before, after);
    const limit = d.action === "rebalance" ? rc.maxRebalanceLossBps : rc.maxDeployIdleLossBps;
    st = { ...st, pending: null, actions: [...st.actions, { ts: nowS(), vault: vc.address, action: d.action, tx: tx.hash }], lastRebalanceAt: d.action === "rebalance" ? { ...st.lastRebalanceAt, [key]: nowS() } : st.lastRebalanceAt };
    deps.persist(st);
    out.done.push({ vault: vc.address, action: d.action, tx: tx.hash, lossBps: loss });
    await alerts.notify({ kind: "action", key: `rebalancer:${d.action}:${key}`, severity: loss > limit ? "crit" : "warn", audience: "treasury-signers", text: `rebalancer ${d.action} on ${vc.name} (${d.why}): ${tx.hash} block ${receipt.blockNumber}; totalAssets ${before} -> ${after} (${loss} bp lost; limit ${limit} bp)` });
    if (loss > limit) return halt(`${d.action} on ${vc.name} lowered totalAssets by ${loss} bp, above the limit of ${limit} bp (${tx.hash})`);
  }
  out.state = st;
  return out;
}

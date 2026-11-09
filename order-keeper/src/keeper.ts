// THE ORDER KEEPER STEP. One cycle: discover orders by id at the head, decide with canExecute, SIMULATE exactly what would be sent, send
// executeOrder(orderId, "0x") through the registry, read back from the receipt, and HALT on anything unexpected.
//
// Discipline (the same as operator/src/executor.ts):
//   * a PENDING marker is persisted BEFORE every transaction (executions and sweeps alike); one found at start-up HALTS the keeper;
//   * every transaction is simulated first (eth_call from the keeper address); a revert puts the order on a cooldown (doubling), it is not retried every cycle;
//   * after a mined transaction the receipt events, the order, the position, the owner's vault balance and the keeper's own balances are read back; any mismatch HALTS;
//   * halt flags are persisted; a human clears `halted` / `pending` in the state file;
//   * the signer's address must equal the configured keeper wallet; fee cap, gas floor, per-cycle and per-day limits; registry/adapter wiring is re-checked each cycle;
//   * the keeper wallet holds gas only and receives nothing (that is verified, not assumed). The route and recipient are fixed on chain: adapterData is always empty.
// Read errors BEFORE a send are an ordinary failed cycle (alert, no halt, nothing was sent). Any error AFTER the pending marker is set HALTS.
import { BigNumber, providers, utils } from "ethers";
import type { AlertManager } from "./alerts";
import type { KeeperConfig } from "./config";
import { CHAIN_ID, REASON_NAMES } from "./constants";
import { decide, nextCooldown } from "./decide";
import type { Action, Decision } from "./decide";
import { classifyRevert } from "./errors";
import { safeError } from "./mask";
import { readPosition, readOrders, readRegistryHead, readSnapshot, registryIface } from "./orders";
import type { OrderItem, Snapshot } from "./orders";
import { parseReceiptEvents, verifyExecution, verifySweep } from "./readback";
import type { ExternalSigner } from "./signer";
import type { KeeperState } from "./state";
import { feesWithin, makeSender, TxReverted } from "./txkit";

export interface KeeperDeps {
  provider: providers.Provider;
  cfg: KeeperConfig;
  /** absent = dry run (`check`): decisions and simulations are reported, nothing is persisted as pending and nothing is sent */
  signer?: ExternalSigner;
  alerts: AlertManager;
  persist: (s: KeeperState) => void;
  now?: () => number;
  trace?: (msg: string) => void;
  /** pause between retries of a receipt-block read (tests pass an instant one) */
  sleep?: (ms: number) => Promise<void>;
}
export interface KeeperOutcome {
  state: KeeperState;
  halted: boolean;
  scanned: number;
  executed: string[];
  swept: string[];
  /** simulated and passed, but not sent (dry run, fee cap, gas floor) */
  due: string[];
  skipped: string[];
  reverted: string[];
  /** every id below nextOrderId has been read at least once (false while a cycle hit maxIdsPerCycle) */
  caughtUp: boolean;
}

const DAY = 86_400;

export async function verifySigner(signer: ExternalSigner, cfg: KeeperConfig, provider: { getNetwork(): Promise<{ chainId: number }> }): Promise<void> {
  const addr = await signer.getAddress();
  if (addr.toLowerCase() !== cfg.keeper.address.toLowerCase()) throw new Error(`signer address ${addr} is not the configured keeper address ${cfg.keeper.address}`);
  if ((await provider.getNetwork()).chainId !== CHAIN_ID) throw new Error("chain id is not 43114");
}

export async function keeperStep(deps: KeeperDeps, state: KeeperState): Promise<KeeperOutcome> {
  const { provider, cfg, alerts } = deps;
  const nowS = (): number => deps.now?.() ?? Math.floor(Date.now() / 1000);
  const sleep = deps.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const tr = (m: string): void => deps.trace?.(m);
  const out: KeeperOutcome = { state, halted: !!state.halted, scanned: 0, executed: [], swept: [], due: [], skipped: [], reverted: [], caughtUp: false };
  let st = state;
  const save = (): void => {
    out.state = st;
    deps.persist(st);
  };
  const halt = async (reason: string): Promise<KeeperOutcome> => {
    st = { ...st, halted: { reason, at: nowS() } };
    save();
    out.halted = true;
    await alerts.raise({ key: "keeper:halted", severity: "crit", message: `ORDER KEEPER HALTED: ${reason}. No further transaction until a human clears halted / pending in the state file`, audience: "keeper-operator" }, nowS());
    return out;
  };

  // ---- gates before anything is read
  if (st.pending && !st.halted) return halt(`a ${st.pending.kind} of order ${st.pending.orderId} started at ${st.pending.at} was interrupted (process stopped between the marker and the read-back): check the keeper wallet's transactions, the order's status and the position before clearing it`);
  if (st.halted) return out;
  const keeper = deps.signer ? await deps.signer.getAddress() : cfg.keeper.address;
  if (keeper.toLowerCase() !== cfg.keeper.address.toLowerCase()) return halt("signer address differs from the configured keeper address");

  // ---- discovery (reads at the head; a failure here is an ordinary failed cycle: nothing has been sent)
  const head = await readRegistryHead(provider, cfg.registry, cfg.closeAdapter);
  if (head.adapterOfRegistry !== cfg.closeAdapter.toLowerCase() || head.registryOfAdapter !== cfg.registry.toLowerCase() || head.executorOfAdapter !== cfg.marginExecutor.toLowerCase()) {
    return halt(`wiring drift: registry.adapter()=${head.adapterOfRegistry}, adapter.registry()=${head.registryOfAdapter}, adapter.executor()=${head.executorOfAdapter} differ from the configured closeAdapter / registry / marginExecutor`);
  }
  const blk = await provider.getBlock("latest");
  if (nowS() - blk.timestamp > cfg.monitor.maxBlockLagSeconds) {
    out.skipped.push(`the node's head block is ${nowS() - blk.timestamp} s old (limit ${cfg.monitor.maxBlockLagSeconds} s): nothing is decided on stale state`);
    await alerts.raise({ key: "node:stale", severity: "warn", message: `the state endpoint's head is ${nowS() - blk.timestamp} s old; the keeper does nothing until it catches up`, audience: "keeper-operator" }, nowS());
    return out;
  }
  await alerts.clear("node:stale", nowS());
  const nextId = Number(head.nextOrderId);
  if (nextId < st.highWater) return halt(`nextOrderId ${nextId} is below the highest id already read (${st.highWater - 1}): the registry was replaced or the node serves old state`);
  if (head.paused) {
    out.skipped.push("the registry is paused: execution (and sweeping) reverts until it is unpaused");
    await alerts.raise({ key: "registry:paused", severity: "warn", message: "the MarginOrderRegistry is paused (execution only; owners and liquidations are unaffected). The keeper sends nothing until it is unpaused", audience: "keeper-operator" }, nowS());
  } else await alerts.clear("registry:paused", nowS());

  const known = st.open.map((x) => BigInt(x));
  const fresh: bigint[] = [];
  for (let i = st.highWater; i < nextId && fresh.length < cfg.limits.maxIdsPerCycle; i++) fresh.push(BigInt(i));
  const nextHigh = fresh.length ? Number(fresh[fresh.length - 1]) + 1 : st.highWater;
  const ids = [...known.slice(0, cfg.limits.maxIdsPerCycle), ...fresh];
  const items: OrderItem[] = await readOrders(provider, cfg.registry, ids);
  out.scanned = items.length;
  tr(`next id ${nextId}, read ${items.length} orders`);

  const sends24 = st.sends.filter((s) => s.ts > nowS() - DAY);
  const budget = Math.min(cfg.limits.maxSendsPerCycle, Math.max(0, cfg.limits.maxSendsPerDay - sends24.length));
  const d: Decision = decide({ items, now: nowS(), cooldown: st.cooldown, sweep: cfg.limits.sweep, budget: head.paused ? 0 : budget });
  // an id whose first read is NONE/failed must not be skipped over: highWater stops before the first such new id
  let hw = nextHigh;
  for (const it of items) {
    if (it.id >= BigInt(st.highWater) && (!it.order || it.order.status === 0)) hw = Math.min(hw, Number(it.id));
  }
  const cd = { ...st.cooldown };
  for (const id of [...d.final, ...d.resetCooldown]) {
    if (cd[id]) {
      delete cd[id];
      await alerts.clear(`order:${id}:unfilled`, nowS());
      await alerts.clear(`order:${id}:simfail`, nowS());
    }
  }
  const newOpen = [...d.open.filter((id) => !d.final.includes(id)), ...known.slice(cfg.limits.maxIdsPerCycle).map((x) => x.toString())];
  for (const id of Object.keys(cd)) if (!newOpen.includes(id)) delete cd[id];
  st = { ...st, highWater: Math.max(hw, st.highWater), open: newOpen, cooldown: cd, sends: st.sends.filter((s) => s.ts > nowS() - 7 * DAY) };
  out.caughtUp = st.highWater >= nextId;
  save();
  for (const a of d.anomalies) await alerts.raise({ key: "registry:anomaly", severity: "warn", message: a, audience: "keeper-operator" }, nowS());
  if (d.anomalies.length === 0) await alerts.clear("registry:anomaly", nowS());
  if (d.oracleDown.length) {
    out.skipped.push(`oracle unavailable for order(s) ${d.oracleDown.join(", ")}: nothing is sent, the orders wait`);
    await alerts.raise({ key: "oracle:unavailable", severity: "warn", message: `the margin oracle reports no usable WAVAX price (stale, zero or invalid) for ${d.oracleDown.length} open order(s) (${d.oracleDown.slice(0, 8).join(", ")}); stop-losses and take-profits cannot fire until it recovers. Liquidation has its own price check`, audience: "keeper-operator" }, nowS());
  } else await alerts.clear("oracle:unavailable", nowS());
  for (const c of d.cooling) out.skipped.push(`order ${c.id}: cooling down for ${c.until - nowS()} s (${c.why})`);
  for (const id of d.deferred) out.skipped.push(`order ${id}: due, beyond this cycle's / this day's send budget`);
  // a due order that has failed for a long time is something a person should know about (a stop-loss that cannot fill)
  for (const [id, e] of Object.entries(st.cooldown)) {
    if (e.fails > 0 && nowS() - e.firstFailAt >= cfg.limits.unfilledAlertSeconds) await alerts.raise({ key: `order:${id}:unfilled`, severity: "warn", message: `order ${id} has been due for ${Math.round((nowS() - e.firstFailAt) / 60)} min but cannot be filled (${e.why}). It stays open; for a stop-loss the funded liquidation is the backstop`, audience: "keeper-operator" }, nowS());
  }
  if (d.actions.length === 0) return out;

  // ---- gas and fees (only when something is due)
  const gasBal = await provider.getBalance(keeper);
  if (gasBal.lt(cfg.limits.minGasWei)) {
    out.skipped.push(`keeper AVAX ${gasBal.toString()} wei is below the floor ${cfg.limits.minGasWei}`);
    await alerts.raise({ key: "keeper:gas", severity: "crit", message: `order keeper AVAX balance ${gasBal.toString()} wei is below the floor ${cfg.limits.minGasWei}; no order is executed until it is refilled`, audience: "keeper-operator" }, nowS());
    return out;
  }
  await alerts.clear("keeper:gas", nowS());
  const feesR = await feesWithin(provider, cfg.limits.maxFeeGwei);
  if (!feesR.ok) {
    out.skipped.push(feesR.reason);
    return out;
  }
  const send = deps.signer ? makeSender(deps.signer, feesR.fees) : undefined;

  // ---- act, one transaction at a time
  const data = (a: Action): string => registryIface.encodeFunctionData("executeOrder", [a.id, "0x"]);
  for (const a of d.actions) {
    const tag = `${a.kind} order ${a.id}`;
    // 1. simulate exactly what would be sent
    const expectBool = a.kind === "execute";
    let gasLimit: BigNumber;
    try {
      const ret = await provider.call({ from: keeper, to: cfg.registry, data: data(a) });
      const executed = registryIface.decodeFunctionResult("executeOrder", ret)[0] as boolean;
      if (executed !== expectBool) {
        out.skipped.push(`${tag}: the simulation returned executed=${executed}; the state moved since canExecute: read again next cycle`);
        continue;
      }
      const est = await provider.estimateGas({ from: keeper, to: cfg.registry, data: data(a) });
      gasLimit = est.mul(13).div(10);
      if (gasLimit.gt(cfg.limits.maxGasLimit)) {
        out.skipped.push(`${tag}: gas estimate ${est.toString()} x 1.3 is above the limit ${cfg.limits.maxGasLimit}`);
        await alerts.raise({ key: `order:${a.id}:gas`, severity: "warn", message: `order ${a.id}: the gas estimate ${est.toString()} exceeds the configured ceiling ${cfg.limits.maxGasLimit}; not sent`, audience: "keeper-operator" }, nowS());
        continue;
      }
    } catch (err) {
      const cls = classifyRevert(err);
      if (cls.kind === "final") {
        out.skipped.push(`${tag}: ${cls.name} (no longer open)`);
        st = { ...st, open: st.open.filter((x) => x !== a.id) };
        save();
        continue;
      }
      const label = `${cls.name}${cls.detail ? ` (${cls.detail})` : ""}`;
      out.skipped.push(`${tag}: simulation reverted: ${label}`);
      out.reverted.push(a.id);
      st = { ...st, cooldown: { ...st.cooldown, [a.id]: nextCooldown(st.cooldown[a.id], nowS(), cls.kind === "wait" ? "wait" : "attention", label, { base: cfg.limits.retryCooldownSeconds, max: cfg.limits.retryCooldownMaxSeconds, unknown: cfg.limits.unknownRevertCooldownSeconds }) } };
      save();
      if (cls.kind === "attention") await alerts.raise({ key: `order:${a.id}:simfail`, severity: "warn", message: `order ${a.id}: the ${a.kind} simulation reverted with an unclassified error: ${safeError(label)}. Not retried for ${cfg.limits.unknownRevertCooldownSeconds} s; a person should look`, audience: "keeper-operator" }, nowS());
      continue;
    }
    if (!send || !deps.signer) {
      out.due.push(a.id);
      continue;
    }
    // 2. what the read-back needs from BEFORE: the position (names the tokens) and a snapshot at the head
    let before: Snapshot;
    try {
      const pos = await readPosition(provider, cfg.marginExecutor, a.positionId, "latest");
      before = await readSnapshot(provider, cfg, keeper, BigInt(a.id), pos, "latest");
    } catch (err) {
      out.skipped.push(`${tag}: pre-send reads failed (${safeError(err)}); nothing sent`);
      continue;
    }
    // 3. PENDING marker, persisted before the transaction
    st = { ...st, pending: { orderId: a.id, kind: a.kind, at: nowS() } };
    save();
    tr(`${tag}: send`);
    let tx: { hash: string; blockNumber: number };
    try {
      tx = await send(cfg.registry, data(a), gasLimit);
    } catch (err) {
      if (err instanceof TxReverted) {
        // mined and reverted after a passing simulation: another keeper or a price move was first. Cost gas, not an emergency, unless it keeps happening.
        const ts = nowS();
        st = { ...st, pending: null, sends: [...st.sends, { ts, orderId: a.id, kind: a.kind, tx: err.hash, outcome: "reverted" }], cooldown: { ...st.cooldown, [a.id]: nextCooldown(st.cooldown[a.id], ts, "attention", `mined revert ${err.hash}`, { base: cfg.limits.retryCooldownSeconds, max: cfg.limits.retryCooldownMaxSeconds, unknown: cfg.limits.unknownRevertCooldownSeconds }) } };
        save();
        out.reverted.push(a.id);
        out.skipped.push(`${tag}: reverted on chain after a passing simulation (${err.hash})`);
        await alerts.notify({ kind: "action", key: `order:${a.id}:mined-revert`, severity: "warn", audience: "keeper-operator", text: `order ${a.id}: ${a.kind} transaction ${err.hash} was mined and reverted after a passing simulation (gas spent). Cooling down` });
        const n = st.sends.filter((s) => s.outcome === "reverted" && s.ts > ts - DAY).length;
        if (n >= cfg.limits.maxMinedRevertsPerDay) return halt(`${n} transactions mined and reverted after passing simulations in 24 h (limit ${cfg.limits.maxMinedRevertsPerDay}): each cost gas`);
        continue;
      }
      return halt(`unexpected error after the pending marker of ${tag} was set: ${safeError(err)}. The transaction may or may not have been mined`);
    }
    // 4. READ-BACK
    try {
      const problems = await readBack({ provider, cfg, keeper, a, tx, before, sleep });
      const ts = nowS();
      const { [a.id]: _gone, ...restCd } = st.cooldown;
      void _gone;
      st = { ...st, pending: null, open: st.open.filter((x) => x !== a.id), cooldown: restCd, sends: [...st.sends, { ts, orderId: a.id, kind: a.kind, tx: tx.hash, outcome: "ok" }] };
      if (problems.length) {
        await alerts.notify({ kind: "action", key: `order:${a.id}:readback`, severity: "crit", audience: "keeper-operator", text: `order ${a.id}: ${a.kind} ${tx.hash} mined (block ${tx.blockNumber}) but the READ-BACK FAILED: ${problems.join("; ")}` });
        return halt(`${tag}: transaction ${tx.hash} mined but read-back failed: ${problems.join("; ")}`);
      }
      save();
      await alerts.clear(`order:${a.id}:unfilled`, ts);
      await alerts.clear(`order:${a.id}:simfail`, ts);
      (a.kind === "execute" ? out.executed : out.swept).push(a.id);
      await alerts.notify({ kind: "action", key: `order:${a.id}:${a.kind}`, severity: "info", audience: "keeper-operator", text: `order ${a.id}: ${a.kind === "execute" ? `EXECUTED (position ${a.positionId}, oracle ${utils.formatEther(a.priceE18)} USD)` : `swept (${REASON_NAMES[a.reason] ?? a.reason})`} ${tx.hash} block ${tx.blockNumber}` });
    } catch (err) {
      return halt(`${tag}: transaction ${tx.hash} mined but the read-back could not be completed: ${safeError(err)}`);
    }
  }
  return out;
}

/** Reads the receipt and the state around its block and returns the list of problems (empty = every check passed). */
async function readBack(p: { provider: providers.Provider; cfg: KeeperConfig; keeper: string; a: Action; tx: { hash: string; blockNumber: number }; before: Snapshot; sleep: (ms: number) => Promise<void> }): Promise<string[]> {
  const { provider, cfg, keeper, a, tx } = p;
  let receipt = await provider.getTransactionReceipt(tx.hash);
  for (let i = 0; !receipt && i < 5; i++) {
    await p.sleep(1000);
    receipt = await provider.getTransactionReceipt(tx.hash);
  }
  if (!receipt) return ["the receipt could not be read"];
  if (receipt.status !== 1) return ["the receipt status is not 1"];
  if (receipt.to?.toLowerCase() !== cfg.registry.toLowerCase()) return ["the receipt is not a call to the registry"];
  const events = parseReceiptEvents(receipt.logs, cfg.registry, cfg.marginExecutor);
  // non-archive node: a state read at the receipt's block can fail on a load-balanced node that has not reached it; once more after a second, then the head (inexact)
  const at = async (block: number): Promise<{ snap: Snapshot; exact: boolean }> => {
    for (let i = 0; i < 2; i++) {
      try {
        return { snap: await readSnapshot(provider, cfg, keeper, BigInt(a.id), p.before.pos, block), exact: true };
      } catch {
        if (i === 0) await p.sleep(1000);
      }
    }
    return { snap: await readSnapshot(provider, cfg, keeper, BigInt(a.id), p.before.pos, "latest"), exact: false };
  };
  const after = await at(receipt.blockNumber);
  const prev = receipt.blockNumber > 0 ? await at(receipt.blockNumber - 1).catch(() => undefined) : undefined;
  const beforeExact = prev?.exact && after.exact;
  const input = { orderId: BigInt(a.id), keeper, events, before: beforeExact && prev ? prev.snap : p.before, after: after.snap, exact: !!beforeExact };
  return a.kind === "execute" ? verifyExecution(input) : verifySweep(input, a.reason);
}

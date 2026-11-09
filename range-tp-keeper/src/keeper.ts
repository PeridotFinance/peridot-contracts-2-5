// RANGE TAKE-PROFIT FINALISATION KEEPER (PROTOTYPE). A gas-only wallet with NO role: `finalize` is permissionless on the custodian and pays the
// caller nothing. Semantics ported from PR #7's keeper (contracts/tools/orders/orders_keeper.py, range phase), adapted to rungs:
//   * for every position with an ACTIVE order it reads `finalizable` (active rungs, rungs the pool has FULLY crossed);
//   * it SIMULATES `finalize` and sends it only when the simulation passes (at least one rung fully converted);
//   * BandNotFullyConverted (not reached, partly filled, reversed), OracleUnavailable and PoolOracleDeviation are WAITS, not errors;
//   * it NEVER unwinds (the ABI has no unwind): when the owner, the liquidator or the order adapter removes a band, it records that once;
//   * it applies the gas-price cap, the gas-balance floor and a per-step send budget.
// Operator disciplines carried over from operator/src/keeper.ts:
//   * PENDING MARKER persisted BEFORE a send, cleared when the send is finished; found set at start-up = interrupted = HALT;
//   * HALT on anything unexpected after a send (mined revert, read-back mismatch, unknown error): nothing is sent until a human clears
//     `halted` in the state file; every halt is alerted;
//   * a failed simulation that is not a plain wait sets a cooldown so a polling loop cannot spam;
//   * the log endpoint (only for the optional event discovery) is paced with back-off after a 429 (logpace.ts);
//   * every string that leaves the process is masked (the RPC URL and the keystore password never appear).
import type { Alerts } from "./alerts";
import { PositionStatus, Status } from "./abi";
import type { ChainPort } from "./port";
import { TxReverted } from "./port";
import { safeError } from "./mask";
import type { KeeperState } from "./state";

export interface KeeperLimits {
  /** minimum keeper AVAX (wei) to send at all */
  minGasWei: bigint;
  /** at most this many finalisations are SENT in one step */
  maxSendsPerStep: number;
  /** after a refusal that is not a plain wait */
  cooldownSeconds: number;
  /** gas limit = estimate * gasMarginPct / 100 */
  gasMarginPct: number;
  /** positions read per step at most (bounds the RPC use of one cycle) */
  maxReadsPerStep: number;
}
export const DEFAULT_LIMITS: KeeperLimits = { minGasWei: 40_000_000_000_000_000n, maxSendsPerStep: 3, cooldownSeconds: 300, gasMarginPct: 130, maxReadsPerStep: 200 };

export interface KeeperDeps {
  port: ChainPort;
  alerts: Alerts;
  limits: KeeperLimits;
  /** persists the state; called BEFORE a transaction is sent and after every change */
  persist: (s: KeeperState) => void;
  now?: () => number;
}

export type Decision =
  | { positionId: string; kind: "waiting"; reason: string }
  | { positionId: string; kind: "finalised"; txHash: string; rungs: number; gasUsed: string; positionClosed: boolean }
  | { positionId: string; kind: "skipped"; reason: string }
  | { positionId: string; kind: "removed"; reason: string };

export interface StepOutcome {
  state: KeeperState;
  decisions: Decision[];
  sent: number;
  halted: boolean;
}

/** Simulation errors that mean "not yet / not now": a wait, not an error. */
export const WAIT_ERRORS = new Set(["BandNotFullyConverted", "OracleUnavailable", "PoolOracleDeviation"]);

const waitReason = (name: string, ready: number, active: number): string =>
  name === "BandNotFullyConverted"
    ? `waiting: no rung fully crossed (${ready}/${active} by the pool tick when read; not reached, partly filled or reversed)`
    : name === "OracleUnavailable"
      ? "waiting: the margin oracle has no fresh price"
      : "waiting: the pool is further from the oracle than the pair's deviation bound";

export async function keeperStep(deps: KeeperDeps, input: KeeperState): Promise<StepOutcome> {
  const { port, alerts, limits } = deps;
  const nowS = (): number => deps.now?.() ?? Math.floor(Date.now() / 1000);
  let st: KeeperState = input;
  const out: StepOutcome = { state: st, decisions: [], sent: 0, halted: !!st.halted };

  // ---- halt / pending-marker discipline
  if (st.pending && !st.halted) {
    const reason = `a finalisation of position ${st.pending.positionId} started at ${st.pending.at} was interrupted (the process stopped between the marker and the end of the send): read the order and the position on chain, then clear pending and halted in the state file`;
    st = { ...st, halted: { reason, at: nowS() } };
    deps.persist(st);
    await alerts.raise("range-keeper:halted", "crit", `RANGE KEEPER HALTED: ${reason}`);
    return { state: st, decisions: [], sent: 0, halted: true };
  }
  if (st.halted) return out;

  const halt = async (reason: string, keepPending: boolean): Promise<StepOutcome> => {
    st = { ...st, halted: { reason, at: nowS() }, pending: keepPending ? st.pending : null };
    deps.persist(st);
    await alerts.raise("range-keeper:halted", "crit", `RANGE KEEPER HALTED: ${reason}. Nothing is sent until a human clears halted in the state file`);
    return { state: st, decisions: out.decisions, sent: out.sent, halted: true };
  };

  let next: bigint;
  try {
    next = await port.nextPositionId();
  } catch (e) {
    await alerts.raise("range-keeper:read", "warn", `cannot read nextPositionId: ${safeError(e)}`);
    return out;
  }
  let reads = 0;
  let newCursor = BigInt(st.cursor);
  let cursorStuck = false;
  for (let id = BigInt(st.cursor); id < next; id++) {
    const key = id.toString();
    if (st.done[key]) {
      if (!cursorStuck) newCursor = id + 1n;
      continue;
    }
    if (++reads > limits.maxReadsPerStep) break;
    let fz: { active: number; ready: number };
    try {
      fz = await port.finalizable(id);
    } catch (e) {
      out.decisions.push({ positionId: key, kind: "skipped", reason: `cannot read the order: ${safeError(e)}` });
      cursorStuck = true;
      continue;
    }

    if (fz.active === 0) {
      // no active order: a band that went away without us is recorded ONCE; a position that is over needs no more reading
      let ord;
      let pos;
      try {
        ord = await port.order(id);
        pos = await port.positionStatus(id);
      } catch (e) {
        out.decisions.push({ positionId: key, kind: "skipped", reason: `cannot read the order status: ${safeError(e)}` });
        cursorStuck = true;
        continue;
      }
      if (st.watching[key] && (ord.status === Status.UNWOUND || ord.status === Status.SETTLED)) {
        const kind = ord.status === Status.UNWOUND ? "risk-path-or-owner" : "finalised-by-another-caller";
        const w = { ...st.watching };
        delete w[key];
        st = { ...st, watching: w, removals: [...st.removals, { positionId: key, ts: nowS(), kind }] };
        deps.persist(st);
        const why = kind === "risk-path-or-owner" ? "removed by the owner, the liquidator or the order adapter (UNWOUND); the keeper never unwinds" : "finalised by another caller (SETTLED)";
        out.decisions.push({ positionId: key, kind: "removed", reason: why });
        await alerts.raise(`range-keeper:removed:${key}`, "info", `order on position ${key} ${why}`);
      }
      const orderOver = ord.status === Status.UNWOUND || ord.status === Status.SETTLED;
      const positionOver = pos === PositionStatus.CLOSED || pos === PositionStatus.LIQUIDATED;
      if (orderOver || positionOver) st = { ...st, done: { ...st.done, [key]: true } };
      if (!cursorStuck && (orderOver || positionOver)) newCursor = id + 1n;
      else cursorStuck = true; // an order may still be created on this position
      continue;
    }

    cursorStuck = true;
    if (!st.watching[key]) st = { ...st, watching: { ...st.watching, [key]: { firstSeen: nowS() } } };
    if (fz.ready === 0) {
      out.decisions.push({ positionId: key, kind: "waiting", reason: waitReason("BandNotFullyConverted", fz.ready, fz.active) });
      continue;
    }
    if ((st.cooldown[key] ?? 0) > nowS()) {
      out.decisions.push({ positionId: key, kind: "skipped", reason: `cooling down until ${st.cooldown[key]} after a refused simulation` });
      continue;
    }
    if (out.sent >= limits.maxSendsPerStep) {
      out.decisions.push({ positionId: key, kind: "skipped", reason: `per-step send budget (${limits.maxSendsPerStep}) used; next step` });
      continue;
    }

    // ---- simulate: only a passing simulation is sent
    const sim = await port.simulateFinalize(id);
    if (!sim.ok) {
      if (WAIT_ERRORS.has(sim.name)) {
        out.decisions.push({ positionId: key, kind: "waiting", reason: waitReason(sim.name, fz.ready, fz.active) });
        continue;
      }
      st = { ...st, cooldown: { ...st.cooldown, [key]: nowS() + limits.cooldownSeconds } };
      deps.persist(st);
      const text = sim.name === "SlippageFloor" ? `finalisation of position ${key} refused by the slippage floor (${sim.message}); not sent, retry after the cooldown. If this persists the owner should cancel` : `simulation of finalize(${key}) failed: ${sim.message}`;
      out.decisions.push({ positionId: key, kind: "skipped", reason: text });
      await alerts.raise(`range-keeper:refused:${key}`, "warn", text);
      continue;
    }

    // ---- fee cap and gas floor
    const fees = await port.fees();
    if (!fees.ok) {
      out.decisions.push({ positionId: key, kind: "skipped", reason: `fee cap: ${fees.reason}` });
      continue;
    }
    const bal = await port.keeperBalanceWei();
    if (bal < limits.minGasWei) {
      out.decisions.push({ positionId: key, kind: "skipped", reason: `keeper AVAX ${bal} wei is below the floor ${limits.minGasWei}` });
      await alerts.raise("range-keeper:gas", "crit", `keeper AVAX ${bal} wei is below the floor ${limits.minGasWei}: top up`);
      continue;
    }

    // ---- pending marker BEFORE the send
    st = { ...st, pending: { positionId: key, at: nowS() } };
    deps.persist(st);
    let sent;
    try {
      sent = await port.sendFinalize(id, (sim.gas * BigInt(limits.gasMarginPct)) / 100n, fees);
    } catch (e) {
      out.sent++;
      if (e instanceof TxReverted) {
        // mined and reverted although the simulation passed: the chain moved between the two; state is known, but a human looks
        return await halt(`finalize(${key}) was mined and REVERTED after a passing simulation (${e.hash})`, false);
      }
      return await halt(`unexpected error while finalising position ${key}: ${safeError(e)} (the transaction may or may not have been mined; check the order on chain)`, true);
    }
    out.sent++;

    // ---- read-back
    let after;
    let pos;
    try {
      after = await port.order(id);
      pos = await port.positionStatus(id);
    } catch (e) {
      return await halt(`finalize(${key}) mined in ${sent.hash} but the read-back failed: ${safeError(e)}`, false);
    }
    const rungsDone = after.rungStatuses.filter((s) => s === Status.SETTLED).length;
    const problems: string[] = [];
    if (rungsDone < fz.ready) problems.push(`only ${rungsDone} rungs SETTLED after the send, ${fz.ready} were ready`);
    if (!sent.settled) problems.push("no RangeOrderSettled event in the receipt");
    else if (sent.settled.positionClosed && pos !== PositionStatus.CLOSED) problems.push("the event says the position closed but it is not CLOSED");
    if (problems.length) return await halt(`finalize(${key}) mined in ${sent.hash} but the read-back failed: ${problems.join("; ")}`, false);

    const orderSettled = after.status === Status.SETTLED;
    st = {
      ...st,
      pending: null,
      finalisations: [...st.finalisations, { positionId: key, ts: nowS(), txHash: sent.hash, blockNumber: sent.blockNumber, gasUsed: sent.gasUsed.toString(), rungsFinalised: rungsDone, orderSettled, positionClosed: !!sent.settled?.positionClosed }],
      ...(orderSettled ? { done: { ...st.done, [key]: true }, watching: Object.fromEntries(Object.entries(st.watching).filter(([k]) => k !== key)) } : {}),
    };
    deps.persist(st);
    await alerts.raise(`range-keeper:finalised:${key}`, "info", `finalised position ${key}: ${rungsDone} rung(s), repaid ${sent.settled?.repaid ?? 0n}, remaining debt ${sent.settled?.remainingDebt ?? 0n}, position ${sent.settled?.positionClosed ? "CLOSED" : "still open"}, tx ${sent.hash}, gas ${sent.gasUsed}`);
    out.decisions.push({ positionId: key, kind: "finalised", txHash: sent.hash, rungs: rungsDone, gasUsed: sent.gasUsed.toString(), positionClosed: !!sent.settled?.positionClosed });
  }
  st = { ...st, cursor: newCursor.toString() };
  deps.persist(st);
  out.state = st;
  return out;
}

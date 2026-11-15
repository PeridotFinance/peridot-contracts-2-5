// THE REBALANCE KEEPER STEP. One cycle (every pollSeconds): read the active bin; on a band exit wait exitWaitSeconds, re-read, check the vault's own gates, size the
// swap for an even-value 3-bin mix, run the keeper's SECOND oracle check, SIMULATE exactly what would be sent, and send ONE rebalance. Never a loop on a revert.
//
// Discipline:
//   * the HALT FILE (state.ts) is the only authority on "halted"; it is read first, and while it exists the cycle returns BEFORE any chain call;
//   * a latchable guard bit (1,2,4,8) or a latched vault HALTS: no send, no vault call (except the one optional tripGuard, see maybeTrip), alert, HALT file, manual `resume`;
//   * a PENDING marker is persisted BEFORE every transaction; one found at start-up HALTS the keeper;
//   * every transaction is simulated first (eth_call from the keeper address); a revert sets a backoff and is counted, it is never retried in the same cycle
//     (the single exception: ONE adaptive re-simulation after ActiveIdMoved with the id the vault reported, still a simulation, not a send);
//   * at most ONE transaction per cycle, at most maxSendsPerDay (<= 48) per rolling 24 h, at least cooldownSeconds (>= 120) between two rebalances;
//   * read errors BEFORE a send are an ordinary failed cycle (alert, nothing was sent). Any error AFTER the pending marker HALTS.
import { providers, utils } from "ethers";
import type { AlertManager } from "./alerts";
import { bandInventory, pairQuote, readAct, readPoll, vaultIface, WiringError } from "./chain";
import type { Act, Poll } from "./chain";
import type { KeeperConfig } from "./config";
import { DAY, LATCHABLE_MASK, LIVE_MASK, bitNames } from "./constants";
import { classifyRevert } from "./errors";
import type { RevertClass } from "./errors";
import { safeError } from "./mask";
import { planSwap } from "./plan";
import type { Plan } from "./plan";
import { checkOracle } from "./sanity";
import type { ExternalSigner } from "./signer";
import { readHalt, writeHalt } from "./state";
import type { HaltKind, HaltRecord, KeeperState } from "./state";
import { feesWithin, makeSender, TxReverted } from "./txkit";

export interface KeeperDeps {
  provider: providers.Provider;
  cfg: KeeperConfig;
  /** present only in live mode; absent = dry-run: everything is simulated, nothing is signed, no pending marker is set */
  signer?: ExternalSigner;
  alerts: AlertManager;
  persist: (s: KeeperState) => void;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
  trace?: (msg: string) => void;
}
export interface StepOptions {
  /** `check`: do not wait for exitWaitSeconds (a one-shot dry look at what the keeper would do now) */
  skipWait?: boolean;
  /** `check` writes NOTHING: a halt decision is reported but no HALT file is created */
  noHaltWrite?: boolean;
}
export type Status =
  | "halted" | "halting" | "no-band" | "in-range" | "recovered" | "exit-detected" | "waiting" | "backoff" | "cooldown" | "limit" | "stale" | "blocked" | "failed" | "dry-run" | "sent";
export interface KeeperOutcome {
  state: KeeperState;
  status: Status;
  halted: boolean;
  /** transaction hashes sent in THIS cycle (rebalance or tripGuard) */
  sent: string[];
  notes: string[];
  plan?: Plan;
  halt?: HaltRecord;
}

export async function verifySigner(signer: ExternalSigner, cfg: KeeperConfig, provider: { getNetwork(): Promise<{ chainId: number }> }): Promise<void> {
  const addr = await signer.getAddress();
  if (addr.toLowerCase() !== cfg.keeper.address.toLowerCase()) throw new Error(`signer address ${addr} is not the configured keeper address ${cfg.keeper.address}`);
  if ((await provider.getNetwork()).chainId !== cfg.chainId) throw new Error(`chain id is not ${cfg.chainId}`);
}

export async function keeperStep(deps: KeeperDeps, state: KeeperState, opts: StepOptions = {}): Promise<KeeperOutcome> {
  const { provider, cfg, alerts } = deps;
  const live = cfg.mode === "live" && !!deps.signer;
  if (cfg.mode === "live" && !deps.signer) throw new Error("mode is live but no signer was loaded");
  const nowS = (): number => deps.now?.() ?? Math.floor(Date.now() / 1000);
  const sleep = deps.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const tr = (m: string): void => deps.trace?.(m);
  const keeper = cfg.keeper.address;
  const out: KeeperOutcome = { state, status: "in-range", halted: false, sent: [], notes: [] };
  let st = state;
  const save = (): void => {
    out.state = st;
    deps.persist(st);
  };
  const done = (status: Status): KeeperOutcome => {
    out.status = status;
    out.state = st;
    return out;
  };

  // ---------------------------------------------------------------- 0. THE HALT FILE (no chain I/O before this line has passed)
  const existing = readHalt(cfg.monitor.haltPath);
  if (existing) {
    out.halted = true;
    out.halt = existing;
    await alerts.raise({ key: "keeper:halted", severity: "crit", message: `DLMM KEEPER HALTED (${existing.kind}): ${existing.reason}. It calls nothing and sends nothing until a person runs \`dlmm-keeper resume\``, audience: "keeper-operator" }, nowS());
    return done("halted");
  }

  const putHalt = (rec: HaltRecord, update = false): void => {
    if (!opts.noHaltWrite) writeHalt(cfg.monitor.haltPath, rec, update);
  };
  /** writes the HALT file FIRST, alerts, then (optionally) the one tripGuard; returns the outcome */
  const halt = async (kind: HaltKind, reason: string, o: { reasons?: number; latched?: boolean } = {}): Promise<KeeperOutcome> => {
    const rec: HaltRecord = { kind, reason, at: nowS(), ...(o.reasons !== undefined ? { reasons: o.reasons } : {}) };
    putHalt(rec);
    out.halted = true;
    out.halt = rec;
    await alerts.raise({ key: "keeper:halted", severity: "crit", message: `DLMM KEEPER HALTED (${kind}): ${reason}. HALT file written; no further call or transaction until a person runs \`dlmm-keeper resume\``, audience: "keeper-operator" }, nowS());
    if (kind === "guard") {
      rec.trip = o.latched ? "not needed (the vault is already latched)" : await maybeTrip();
      putHalt(rec, true);
      out.halt = rec;
    }
    return done("halting");
  };

  /**
   * THE ONE EXCEPTION TO "call nothing": the permissionless tripGuard(). Default OFF (config guard.autoTripGuard). Only after the HALT file is written, only when a latchable bit
   * STILL holds after tripDebounceSeconds and the vault is not latched, at most once per halt, through the same simulate / fee cap / pending-marker / send path as a rebalance.
   */
  const maybeTrip = async (): Promise<string> => {
    if (!cfg.guard.autoTripGuard) return "disabled (guard.autoTripGuard is false)";
    if (!live || !deps.signer) return "dry-run (would send tripGuard)";
    try {
      if (cfg.guard.tripDebounceSeconds > 0) await sleep(cfg.guard.tripDebounceSeconds * 1000);
      const p = await readPoll(provider, cfg);
      if (p.guard.latched) return "not needed (already latched)";
      if ((p.guard.reasons & LATCHABLE_MASK) === 0) return `condition cleared during the ${cfg.guard.tripDebounceSeconds} s debounce (reasons now ${bitNames(p.guard.reasons)}); not tripped`;
      const bal = await provider.getBalance(keeper);
      if (bal.lt(cfg.limits.minWalletWei)) return "skipped: wallet below the floor";
      const data = vaultIface.encodeFunctionData("tripGuard", []);
      let gasLimit;
      try {
        await provider.call({ from: keeper, to: cfg.vault, data });
        gasLimit = (await provider.estimateGas({ from: keeper, to: cfg.vault, data })).mul(13).div(10);
      } catch (e) {
        const c = classifyRevert(e);
        return `simulation reverted: ${c.name}${c.detail ? ` (${c.detail})` : ""}; not sent`;
      }
      const f = await feesWithin(provider, cfg.limits.maxFeeGwei);
      if (!f.ok) return `skipped: ${f.reason}`;
      st = { ...st, pending: { kind: "tripGuard", at: nowS() } };
      save();
      try {
        const tx = await makeSender(deps.signer, f.fees)(cfg.vault, data, gasLimit);
        st = { ...st, pending: null, sends: [...st.sends, { ts: nowS(), kind: "tripGuard" as const, tx: tx.hash, outcome: "ok" as const }] };
        save();
        out.sent.push(tx.hash);
        return `sent ${tx.hash}`;
      } catch (e) {
        if (e instanceof TxReverted) {
          st = { ...st, pending: null, sends: [...st.sends, { ts: nowS(), kind: "tripGuard" as const, tx: e.hash, outcome: "reverted" as const }] };
          save();
          return `mined and reverted ${e.hash}`;
        }
        return `failed after the pending marker (kept): ${safeError(e)}`;
      }
    } catch (e) {
      return `failed: ${safeError(e)}`;
    }
  };

  const backoffSoft = (secondsOrUntil: { until: number } | { seconds: number }, why: string): void => {
    const until = "until" in secondsOrUntil ? secondsOrUntil.until : nowS() + secondsOrUntil.seconds;
    st = { ...st, backoff: { until, fails: st.backoff?.fails ?? 0, firstFailAt: st.backoff?.firstFailAt ?? nowS(), why } };
    save();
  };
  /** a COUNTED failure: doubling backoff, alert, and a HALT when maxConsecutiveFailures is reached */
  const fail = async (why: string): Promise<KeeperOutcome> => {
    const fails = (st.backoff?.fails ?? 0) + 1;
    const wait = Math.min(cfg.limits.retryBackoffMaxSeconds, cfg.limits.retryBackoffSeconds * 2 ** (fails - 1));
    st = { ...st, backoff: { until: nowS() + wait, fails, firstFailAt: st.backoff?.firstFailAt ?? nowS(), why } };
    save();
    out.notes.push(`failure ${fails}/${cfg.limits.maxConsecutiveFailures}: ${why}; backoff ${wait} s`);
    await alerts.raise({ key: "attempt:failed", severity: "warn", message: `rebalance attempt failed (${fails} consecutive, limit ${cfg.limits.maxConsecutiveFailures}): ${why}. Next attempt not before ${wait} s`, audience: "keeper-operator" }, nowS());
    if (fails >= cfg.limits.maxConsecutiveFailures) return halt("failures", `${fails} consecutive failed rebalance attempts (last: ${why})`);
    return done("failed");
  };

  // ---------------------------------------------------------------- pending marker found: interrupted
  if (st.pending) return halt("pending-interrupted", `a ${st.pending.kind} started at ${st.pending.at} was interrupted (the process stopped between the marker and the read-back): check the keeper wallet's transactions and the vault's band before running \`dlmm-keeper resume\``);

  // ---------------------------------------------------------------- 1. the poll: ONE call
  const poll: Poll = await readPoll(provider, cfg);

  // gas runway on its own cadence (the balance and fee reads are NOT part of the 3 s poll)
  if (nowS() - st.lastGasCheckAt >= cfg.limits.gasRunwayCheckSeconds) {
    st = { ...st, lastGasCheckAt: nowS() };
    try {
      const [bal, fd] = await Promise.all([provider.getBalance(keeper), provider.getFeeData()]);
      const price = fd.gasPrice ?? fd.maxFeePerGas;
      if (price && price.gt(0)) {
        const per = price.mul(cfg.limits.gasPerRebalance);
        const covered = bal.div(per).toNumber();
        if (covered < cfg.limits.minRebalancesCovered) {
          const need = per.mul(cfg.limits.minRebalancesCovered);
          await alerts.raise({ key: "keeper:gas-runway", severity: "warn", message: `DLMM keeper AVAX ${utils.formatEther(bal)} covers ${covered} rebalance(s) at ${utils.formatUnits(price, "gwei")} gwei (${utils.formatEther(per)} AVAX each at ${cfg.limits.gasPerRebalance} gas), fewer than ${cfg.limits.minRebalancesCovered}; top up by about ${utils.formatEther(need.gt(bal) ? need.sub(bal) : 0)} AVAX`, audience: "keeper-operator" }, nowS());
        } else await alerts.clear("keeper:gas-runway", nowS());
      }
    } catch (e) {
      out.notes.push(`gas runway not checked this cycle: ${safeError(e)}`);
    }
  }

  // ---------------------------------------------------------------- 2. the guard (latchable bits and the latch HALT)
  const g = poll.guard;
  if (g.latched || (g.reasons & LATCHABLE_MASK) !== 0) {
    return halt("guard", `vault guard ${g.latched ? "LATCHED" : "UNSAFE"}: ${bitNames(g.reasons)} (reasons=${g.reasons})`, { reasons: g.reasons, latched: g.latched });
  }
  if ((g.reasons & LIVE_MASK) !== 0) await alerts.raise({ key: "guard:live", severity: "warn", message: `vault guard reports a LIVE-only condition (${bitNames(g.reasons)}): deposits and rebalances are blocked while it holds; the keeper waits (no halt: it is not latched)`, audience: "keeper-operator" }, nowS());
  else await alerts.clear("guard:live", nowS());

  // ---------------------------------------------------------------- 3. band and exit detection
  const b = poll.band;
  if (!b.hasBand) {
    await alerts.raise({ key: "band:none", severity: "warn", message: "the vault has no band (openBand has not been called): nothing to rebalance", audience: "keeper-operator" }, nowS());
    if (st.exit) {
      st = { ...st, exit: null };
      save();
    }
    return done("no-band");
  }
  await alerts.clear("band:none", nowS());
  const outOfRange = poll.activeId < b.lowerId || poll.activeId > b.upperId; // spec section 5: outside [lowerId, upperId]
  if (!outOfRange) {
    if (st.exit) {
      st = { ...st, exit: null, backoff: null };
      save();
      out.notes.push(`the active bin ${poll.activeId} is back inside [${b.lowerId}, ${b.upperId}]: no rebalance`);
      await alerts.notify({ kind: "action", key: "band:recovered", severity: "info", audience: "keeper-operator", text: `active bin ${poll.activeId} returned inside the band [${b.lowerId}, ${b.upperId}] before a rebalance was needed; nothing sent` });
      return done("recovered");
    }
    return done("in-range");
  }
  if (!st.exit || st.exit.lowerId !== b.lowerId || st.exit.upperId !== b.upperId) {
    st = { ...st, exit: { since: nowS(), lowerId: b.lowerId, upperId: b.upperId } };
    save();
    out.notes.push(`band exit: active ${poll.activeId} outside [${b.lowerId}, ${b.upperId}]; waiting ${cfg.timing.exitWaitSeconds} s`);
    await alerts.notify({ kind: "action", key: "band:exit", severity: "info", audience: "keeper-operator", text: `band exit: active bin ${poll.activeId} is outside [${b.lowerId}, ${b.upperId}]; the keeper waits ${cfg.timing.exitWaitSeconds} s, then re-reads` });
    if (!opts.skipWait) return done("exit-detected");
  }
  const waited = nowS() - (st.exit?.since ?? nowS());
  if (!opts.skipWait && waited < cfg.timing.exitWaitSeconds) return done("waiting");

  // ---------------------------------------------------------------- 4. gates of the keeper itself
  if (st.backoff && st.backoff.until > nowS()) return done("backoff");
  const rebalances24 = st.sends.filter((s) => s.kind === "rebalance" && s.ts > nowS() - DAY);
  if (rebalances24.length >= cfg.limits.maxSendsPerDay) {
    await alerts.raise({ key: "limit:daily", severity: "warn", message: `${rebalances24.length} rebalance transactions in the last 24 h (limit ${cfg.limits.maxSendsPerDay}); the keeper sends no more until the oldest ages out`, audience: "keeper-operator" }, nowS());
    return done("limit");
  }
  await alerts.clear("limit:daily", nowS());
  const lastSend = rebalances24.reduce((m, s) => Math.max(m, s.ts), 0);
  if (lastSend > 0 && nowS() - lastSend < cfg.timing.cooldownSeconds) return done("cooldown");

  // ---------------------------------------------------------------- 5. the attempt: re-read EVERYTHING at one pinned block
  const blk = await provider.getBlock("latest");
  if (nowS() - blk.timestamp > cfg.timing.maxBlockLagSeconds) {
    out.notes.push(`the node's head block is ${nowS() - blk.timestamp} s old (limit ${cfg.timing.maxBlockLagSeconds} s): nothing is decided on stale state`);
    await alerts.raise({ key: "node:stale", severity: "warn", message: `the state endpoint's head is ${nowS() - blk.timestamp} s old; the keeper decides nothing until it catches up`, audience: "keeper-operator" }, nowS());
    return done("stale");
  }
  await alerts.clear("node:stale", nowS());
  const width = b.upperId - b.lowerId + 1;
  if (width < 1 || width > cfg.limits.maxBandBins) return fail(`the vault's band [${b.lowerId}, ${b.upperId}] is ${width} bins wide (limit ${cfg.limits.maxBandBins})`);
  const ids = Array.from({ length: width }, (_, i) => b.lowerId + i);
  let A: Act;
  try {
    A = await readAct(provider, cfg, blk.number, ids);
  } catch (e) {
    if (e instanceof WiringError) return halt("wiring", e.message);
    throw e;
  }
  const ag = A.poll.guard;
  if (ag.latched || (ag.reasons & LATCHABLE_MASK) !== 0) return halt("guard", `vault guard ${ag.latched ? "LATCHED" : "UNSAFE"} at the re-read: ${bitNames(ag.reasons)} (reasons=${ag.reasons})`, { reasons: ag.reasons, latched: ag.latched });
  const stillOut = A.poll.activeId < A.poll.band.lowerId || A.poll.activeId > A.poll.band.upperId;
  if (!stillOut || !A.poll.band.outOfRange || !A.poll.band.hasBand) {
    st = { ...st, exit: null, backoff: null };
    save();
    out.notes.push(`at the re-read the active bin ${A.poll.activeId} is inside [${A.poll.band.lowerId}, ${A.poll.band.upperId}] (vault outOfRange=${A.poll.band.outOfRange}): no send`);
    return done("recovered");
  }
  if ((ag.reasons & LIVE_MASK) !== 0) {
    out.notes.push(`live-only guard condition ${bitNames(ag.reasons)}: waiting`);
    backoffSoft({ seconds: cfg.limits.retryBackoffSeconds }, `live guard ${bitNames(ag.reasons)}`);
    return done("blocked");
  }
  if (st.lastRebalanceSeen === null) {
    st = { ...st, lastRebalanceSeen: A.lastRebalanceAt };
    save();
  } else if (A.lastRebalanceAt !== st.lastRebalanceSeen) {
    return halt("foreign-rebalance", `vault.lastRebalanceAt is ${A.lastRebalanceAt} but the keeper last saw ${st.lastRebalanceSeen} after its own send: the vault was rebalanced by someone else (a second keeper instance, or the rebalancer key is in other hands)`);
  }
  if (!A.allowed.ok) {
    if (A.allowed.readyAt > blk.timestamp) {
      out.notes.push(`rebalanceAllowed: not before ${A.allowed.readyAt} (cooldown / daily cap); reasonBits=${A.allowed.reasonBits}`);
      backoffSoft({ until: A.allowed.readyAt }, `vault not ready until ${A.allowed.readyAt}`);
      return done("cooldown");
    }
    out.notes.push(`rebalanceAllowed is false (reasonBits=${A.allowed.reasonBits}, readyAt=${A.allowed.readyAt})`);
    await alerts.raise({ key: "rebalance:not-allowed", severity: "warn", message: `the vault says rebalance is not allowed (reasonBits=${A.allowed.reasonBits}, readyAt=${A.allowed.readyAt}) while the active bin is outside the band; the keeper waits`, audience: "keeper-operator" }, nowS());
    backoffSoft({ seconds: cfg.limits.retryBackoffSeconds }, `rebalanceAllowed=false bits=${A.allowed.reasonBits}`);
    return done("blocked");
  }
  await alerts.clear("rebalance:not-allowed", nowS());
  // the vault's own limits, mirrored: the effective daily cap and cooldown are the stricter of the keeper's and the vault's
  if (rebalances24.length >= A.params.maxRebalancesPerDay || A.rebalancesToday >= A.params.maxRebalancesPerDay) {
    await alerts.raise({ key: "limit:daily", severity: "warn", message: `the vault's daily rebalance cap (${A.params.maxRebalancesPerDay}) is reached (vault says ${A.rebalancesToday} today, keeper sent ${rebalances24.length} in 24 h)`, audience: "keeper-operator" }, nowS());
    backoffSoft({ seconds: 600 }, "vault daily cap");
    return done("limit");
  }

  // ---------------------------------------------------------------- 6. the keeper's SECOND oracle check, then the plan
  const sane = checkOracle({
    feedX: A.feedX, feedY: A.feedY, chainNow: blk.timestamp, maxFeedAge: A.params.maxFeedAge, legBandBps: A.params.legBandBps, keeperLegBandBps: cfg.rebalance.keeperLegBandBps,
    poolPrice128: A.poolPrice128, tokenDecX: A.decX, tokenDecY: A.decY, maxPoolOracleDevBps: cfg.rebalance.maxPoolOracleDevBps, vaultMaxPoolOracleDevBps: A.params.maxPoolOracleDevBps,
  });
  if (sane.problems.length || sane.oracle18 === undefined) {
    out.notes.push(`keeper oracle check failed: ${sane.problems.join("; ")}`);
    await alerts.raise({ key: "oracle:keeper-check", severity: "warn", message: `the keeper's own oracle check refuses to send: ${sane.problems.join("; ")}. Nothing sent; retrying after ${cfg.limits.retryBackoffSeconds} s`, audience: "keeper-operator" }, nowS());
    backoffSoft({ seconds: cfg.limits.retryBackoffSeconds }, "oracle check");
    return done("blocked");
  }
  await alerts.clear("oracle:keeper-check", nowS());
  const inv = bandInventory(A.bins);
  const plan = await planSwap({
    x: inv.x + A.idleX, y: inv.y + A.idleY, oracle18: sane.oracle18, maxSwapBps: A.params.maxSwapBps,
    effLossBps: Math.min(cfg.rebalance.maxQuoteLossBps, A.params.maxRebalanceLossBps), swapSlippageBps: cfg.rebalance.swapSlippageBps, addSlippageBps: cfg.rebalance.addSlippageBps,
    quote: pairQuote(provider, cfg, blk.number),
  });
  out.plan = plan;
  if (!plan.ok) {
    out.notes.push(`no plan: ${plan.code}: ${plan.reason}`);
    await alerts.raise({ key: `plan:${plan.code}`, severity: "warn", message: `the keeper cannot size the rebalance (${plan.code}): ${plan.reason}. Nothing sent`, audience: "keeper-operator" }, nowS());
    backoffSoft({ seconds: cfg.limits.retryBackoffSeconds }, `plan ${plan.code}`);
    return done("blocked");
  }
  for (const k of ["empty", "depth", "quote-below-oracle", "bad-input"]) await alerts.clear(`plan:${k}`, nowS());

  // ---------------------------------------------------------------- 7. build and SIMULATE exactly what would be sent
  const deadline = Math.max(blk.timestamp, nowS()) + cfg.timing.deadlineSeconds;
  const build = (expectedActiveId: number): string => vaultIface.encodeFunctionData("rebalance", [expectedActiveId, cfg.rebalance.idSlippage, plan.swapXForY, plan.swapIn.toString(), plan.swapMinOut.toString(), plan.amountXMin.toString(), plan.amountYMin.toString(), deadline]);
  let expected = A.poll.activeId;
  let data = build(expected);
  let gasLimit;
  let adapted = false;
  for (;;) {
    try {
      await provider.call({ from: keeper, to: cfg.vault, data });
      const est = await provider.estimateGas({ from: keeper, to: cfg.vault, data });
      gasLimit = est.mul(13).div(10);
      if (gasLimit.gt(cfg.limits.maxGasLimit)) return fail(`gas estimate ${est.toString()} x 1.3 is above the ceiling ${cfg.limits.maxGasLimit}`);
      break;
    } catch (err) {
      const cls: RevertClass = classifyRevert(err);
      out.notes.push(`simulation reverted: ${cls.name}${cls.detail ? ` (${cls.detail})` : ""}`);
      if (cls.kind === "retry" && !adapted && cls.actualId !== undefined && Math.abs(cls.actualId - A.poll.activeId) <= cfg.rebalance.maxActiveIdShift) {
        adapted = true;
        expected = cls.actualId;
        data = build(expected);
        continue; // ONE more simulation with the id the vault reported
      }
      if (cls.kind === "halt") return halt("guard", `the simulation reverted with ${cls.name} (${cls.detail})`, { ...(cls.reasons !== undefined ? { reasons: cls.reasons } : {}), latched: cls.name === "GuardLatched" });
      if (cls.kind === "benign") {
        if (cls.name === "NotOutOfRange") {
          st = { ...st, exit: null, backoff: null };
          save();
          return done("recovered");
        }
        backoffSoft(cls.readyAt ? { until: cls.readyAt } : { seconds: cls.name === "DailyRebalanceCapReached" ? 3600 : cfg.limits.retryBackoffSeconds }, `${cls.name}`);
        return done(cls.name === "CooldownActive" ? "cooldown" : "blocked");
      }
      if (cls.kind === "endpoint") {
        backoffSoft({ seconds: cfg.limits.retryBackoffSeconds }, "endpoint");
        return done("blocked");
      }
      return fail(`${cls.name}${cls.detail ? ` (${cls.detail})` : ""}`);
    }
  }

  // ---------------------------------------------------------------- 8. dry-run ends here
  const summary = `rebalance(expected=${expected}, idSlip=${cfg.rebalance.idSlippage}, xForY=${plan.swapXForY}, in=${plan.swapIn}, minOut=${plan.swapMinOut}, xMin=${plan.amountXMin}, yMin=${plan.amountYMin}, deadline=${deadline}) gas~${gasLimit.toString()}`;
  if (!live || !deps.signer) {
    out.notes.push(`DRY-RUN: simulation passed, NOT sent: ${summary}`);
    backoffSoft({ seconds: cfg.timing.cooldownSeconds }, "dry-run");
    return done("dry-run");
  }

  // ---------------------------------------------------------------- 9. live: wallet floor, fee cap, PENDING marker, the ONE send, read-back
  const bal = await provider.getBalance(keeper);
  if (bal.lt(cfg.limits.minWalletWei)) {
    out.notes.push(`wallet ${bal.toString()} wei is below the floor ${cfg.limits.minWalletWei}`);
    await alerts.raise({ key: "keeper:gas", severity: "crit", message: `DLMM keeper wallet balance ${bal.toString()} wei is below the floor ${cfg.limits.minWalletWei}; no rebalance is sent until it is refilled`, audience: "keeper-operator" }, nowS());
    backoffSoft({ seconds: cfg.limits.retryBackoffSeconds }, "wallet below floor");
    return done("blocked");
  }
  await alerts.clear("keeper:gas", nowS());
  const fees = await feesWithin(provider, cfg.limits.maxFeeGwei);
  if (!fees.ok) {
    out.notes.push(fees.reason);
    backoffSoft({ seconds: cfg.limits.retryBackoffSeconds }, "fee cap");
    return done("blocked");
  }
  st = { ...st, pending: { kind: "rebalance", at: nowS() } };
  save();
  tr(`send ${summary}`);
  let tx: { hash: string; blockNumber: number };
  try {
    tx = await makeSender(deps.signer, fees.fees)(cfg.vault, data, gasLimit);
  } catch (err) {
    if (err instanceof TxReverted) {
      const ts = nowS();
      st = { ...st, pending: null, sends: [...st.sends, { ts, kind: "rebalance" as const, tx: err.hash, outcome: "reverted" as const }].filter((s) => s.ts > ts - 7 * DAY) };
      save();
      out.sent.push(err.hash);
      await alerts.notify({ kind: "action", key: "rebalance:mined-revert", severity: "warn", audience: "keeper-operator", text: `rebalance ${err.hash} was mined and REVERTED after a passing simulation (gas spent). Backing off` });
      const n = st.sends.filter((s) => s.outcome === "reverted" && s.ts > ts - DAY).length;
      if (n >= cfg.limits.maxMinedRevertsPerDay) return halt("mined-reverts", `${n} rebalances mined and reverted after passing simulations in 24 h (limit ${cfg.limits.maxMinedRevertsPerDay})`);
      return fail(`mined revert ${err.hash}`);
    }
    return halt("unexpected", `unexpected error after the pending marker was set: ${safeError(err)}. The transaction may or may not have been mined`);
  }
  out.sent.push(tx.hash);
  try {
    const problems = await readBack({ provider, cfg, tx, expectedLast: A.lastRebalanceAt, sleep });
    const ts = nowS();
    if (problems.issues.length) {
      st = { ...st, pending: null, sends: [...st.sends, { ts, kind: "rebalance" as const, tx: tx.hash, outcome: "ok" as const }] };
      save();
      await alerts.notify({ kind: "action", key: "rebalance:readback", severity: "crit", audience: "keeper-operator", text: `rebalance ${tx.hash} mined (block ${tx.blockNumber}) but the READ-BACK FAILED: ${problems.issues.join("; ")}` });
      return halt("readback", `transaction ${tx.hash} mined but the read-back failed: ${problems.issues.join("; ")}`);
    }
    st = { ...st, pending: null, exit: null, backoff: null, lastRebalanceSeen: problems.lastRebalanceAt, sends: [...st.sends, { ts, kind: "rebalance" as const, tx: tx.hash, outcome: "ok" as const }].filter((s) => s.ts > ts - 7 * DAY) };
    save();
    for (const k of ["attempt:failed", "rebalance:not-allowed", "oracle:keeper-check"]) await alerts.clear(k, ts);
    await alerts.notify({ kind: "action", key: "rebalance:sent", severity: "info", audience: "keeper-operator", text: `REBALANCED ${tx.hash} block ${tx.blockNumber}: ${problems.eventText}` });
    return done("sent");
  } catch (err) {
    return halt("readback", `transaction ${tx.hash} mined but the read-back could not be completed: ${safeError(err)}`);
  }
}

/** Reads the receipt and the vault around it. Empty `issues` = every check passed. */
async function readBack(p: { provider: providers.Provider; cfg: KeeperConfig; tx: { hash: string; blockNumber: number }; expectedLast: number; sleep: (ms: number) => Promise<void> }): Promise<{ issues: string[]; lastRebalanceAt: number; eventText: string }> {
  const { provider, cfg, tx } = p;
  const issues: string[] = [];
  let receipt = await provider.getTransactionReceipt(tx.hash);
  for (let i = 0; !receipt && i < 5; i++) {
    await p.sleep(1000);
    receipt = await provider.getTransactionReceipt(tx.hash);
  }
  if (!receipt) return { issues: ["the receipt could not be read"], lastRebalanceAt: p.expectedLast, eventText: "" };
  if (receipt.status !== 1) issues.push("the receipt status is not 1");
  if (receipt.to?.toLowerCase() !== cfg.vault.toLowerCase()) issues.push("the receipt is not a call to the vault");
  const topic = vaultIface.getEventTopic("Rebalanced");
  const ev = receipt.logs.find((l) => l.address.toLowerCase() === cfg.vault.toLowerCase() && l.topics[0] === topic);
  let eventText = "no Rebalanced event";
  let newLower = 0;
  let newUpper = 0;
  let activeId = 0;
  if (!ev) issues.push("no Rebalanced event from the vault in the receipt");
  else {
    const d = vaultIface.parseLog(ev).args;
    newLower = Number(d.newLowerId);
    newUpper = Number(d.newUpperId);
    activeId = Number(d.activeId);
    eventText = `band [${Number(d.oldLowerId)},${Number(d.oldUpperId)}] -> [${newLower},${newUpper}] active ${activeId}, swap ${d.swapXForY ? "X->Y" : "Y->X"} in ${d.swapIn.toString()} out ${d.swapOut.toString()}, NAV ${d.navBefore.toString()} -> ${d.navAfter.toString()}`;
    if (!(newLower <= activeId && activeId <= newUpper)) issues.push(`the Rebalanced event's active id ${activeId} is outside its new band [${newLower}, ${newUpper}]`);
  }
  const after = await readPoll(provider, cfg);
  if (!after.band.hasBand) issues.push("the vault reports no band after the rebalance");
  else if (ev && (after.band.lowerId !== newLower || after.band.upperId !== newUpper)) issues.push(`bandState [${after.band.lowerId}, ${after.band.upperId}] differs from the event's new band [${newLower}, ${newUpper}]`);
  const lastR = await batchLast(provider, cfg);
  if (lastR <= p.expectedLast) issues.push(`vault.lastRebalanceAt ${lastR} did not advance past ${p.expectedLast}`);
  return { issues, lastRebalanceAt: lastR, eventText };
}
async function batchLast(provider: providers.Provider, cfg: KeeperConfig): Promise<number> {
  const out = await provider.call({ to: cfg.vault, data: vaultIface.encodeFunctionData("lastRebalanceAt", []) });
  return Number(vaultIface.decodeFunctionResult("lastRebalanceAt", out)[0].toString());
}

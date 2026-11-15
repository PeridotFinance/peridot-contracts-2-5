// LIQUIDATOR EXECUTOR (build step 3). One instance per operator: its own process, host, Foundry keystore, USDC inventory and AVAX gas. The
// operator wallet has NO admin right of any kind; `liquidateBorrow` is permissionless. Behaviour reproduces the liquidation-cycle study
// (docs/deployment-handoffs/avalanche-cash-only-liquidation-cycle.md, test AvalancheCashOnlyLiquidationCycleFork):
//
//   find accounts in shortfall -> repay up to the close factor from OWN inventory (capped by what the collateral can pay for, then by the inventory)
//   -> receive pWAVAX -> redeem pWAVAX -> WAVAX -> swap WAVAX -> USDC on Uniswap V3 0.05% with a REVERT-PROTECTED min-out derived from the oracle's
//   (Chainlink) value minus the slippage bound -> the next round is funded from whatever USDC the operator then holds.
//
// Safety discipline (the same as the treasury keeper): bounded allowances (the exact need, reset to 0 after each use); every transaction is simulated
// first; a PENDING marker is persisted before the first transaction of a round and cleared when the round is finished, and one found at start-up HALTS
// the executor; anything unexpected after a transaction was sent HALTS it (a human clears `executor.halted` / `executor.pending` in the state file);
// a fee cap and an AVAX gas floor are checked before every round; the signer's address must equal this operator's configured address.
//
// A min-out block with no fallback route STOPS the conversion and alerts: the WAVAX stays in the wallet, no second route is tried, the limit is never
// loosened (the tested behaviour; "no silent second route"). Liquidators are NOT gated by the reference price (a TWAP lags a real crash by up to 30
// minutes); the controller itself refuses any liquidation at a zero (stale or unreadable) oracle price, and the executor refuses to act on one too.
import { BigNumber, utils } from "ethers";
import type { AlertManager } from "./alerts";
import { ERC20_ABI, SWAP_ROUTER02_ABI } from "./abi";
import { ctrlIface, latestBlock, pIface, readAccountInputs, readBlockSnapshot } from "./chain";
import type { BlockSnapshot, Ctx } from "./chain";
import type { MonitorConfig } from "./config";
import { UNIV3_FEE, UNIV3_SWAP_ROUTER02, USDC, WAVAX } from "./constants";
import type { ExternalSigner } from "./signer";
import { feesWithin, makeSender, TxReverted } from "./txkit";
import { classifyMargin, evaluateMarginPositions, liquidationErrorCode, LIQ_NOT_FUNDER, LIQ_REPAY_ABOVE_MAX, LIQ_VALUE_FLOOR, marginConfigIface, marginLiquidatorIface, MIN_SEIZE_VALUE_BPS, planMarginRepay, readMarginPositions, readPairBonusBps, repaidInWindow } from "./margin";
import type { MarginRound } from "./margin";
import { safeError } from "./mask";

const erc20 = new utils.Interface(ERC20_ABI);
const router = new utils.Interface(SWAP_ROUTER02_ABI);

// ------------------------------------------------------------------ state
export interface RoundRecord {
  ts: number;
  borrower: string;
  repay: string;
  seizedPTokens: string;
  liquidateTx: string;
  redeemTx?: string;
  swapTx?: string;
  wavaxIn?: string;
  usdcOut?: string;
  swapBlocked?: string;
  /** set for a funded margin liquidation (`borrower` then names the position's margin account) */
  marginPositionId?: string;
}
export type Stage = "liquidate" | "redeem" | "swap" | "margin";
export interface ExecutorState {
  halted: null | { reason: string; at: number };
  /** set (and persisted) BEFORE the first transaction of a stage; found set at start-up = interrupted = HALT */
  pending: null | { stage: Stage; borrower: string; at: number };
  rounds: RoundRecord[];
  /** per-borrower retry-not-before (unix s) after a liquidation that reverted (another liquidator was first) */
  cooldown: Record<string, number>;
  /** funded margin liquidations (rolling 24 h cap, read-back history); optional so that a state file from before the margin step still loads */
  marginRounds?: MarginRound[];
}
export const emptyExecutorState = (): ExecutorState => ({ halted: null, pending: null, rounds: [], cooldown: {} });
export const LIQUIDATION_RETRY_COOLDOWN_SECONDS = 30;

export interface ExecutorOutcome {
  state: ExecutorState;
  round?: RoundRecord;
  /** the wanted repayment exceeded the inventory (counted by the cycle study as an "unfunded step") */
  unfunded: boolean;
  /** a conversion was blocked by the min-out limit in this step */
  swapBlocked: boolean;
  skipped: string[];
  halted: boolean;
}

// ------------------------------------------------------------------ pure parts (unit-tested)
/** Close factor of the debt, capped by what the borrower's collateral can pay for (0.2% below the 1/LI limit, as in the cycle study), then by the inventory. */
export function planRepay(a: { debt: bigint; closeFactor: bigint; collateralUsdc: bigint; inventory: bigint; minRepay: bigint }): { repay: bigint; unfunded: boolean; reason?: string } {
  if (a.debt === 0n) return { repay: 0n, unfunded: false, reason: "no debt" };
  let repay = (a.debt * a.closeFactor) / 10n ** 18n;
  const maxBySeize = (a.collateralUsdc * 9_240n) / 10_000n;
  if (repay > maxBySeize) repay = maxBySeize;
  if (repay === 0n) return { repay: 0n, unfunded: false, reason: "no seizable collateral" };
  if (a.inventory < repay) {
    if (a.inventory < a.minRepay) return { repay: 0n, unfunded: true, reason: "inventory below the minimum repayment" };
    return { repay: a.inventory, unfunded: true }; // partial liquidation with all the operator holds (<= close factor)
  }
  return { repay, unfunded: false };
}
/** Value of `wavaxIn` in USDC units at the oracle's prices (price of WAVAX per 1e18 / price of USDC per 1e6). */
export function oracleValueUsdc(wavaxIn: bigint, pWavax: bigint, pUsdc: bigint): bigint {
  return (wavaxIn * pWavax) / pUsdc;
}
export function minOutFor(oracleValue: bigint, slippageBoundBp: number): bigint {
  return (oracleValue * (10_000n - BigInt(slippageBoundBp))) / 10_000n;
}

// ------------------------------------------------------------------ execution
export interface ExecutorDeps {
  ctx: Ctx;
  signer: ExternalSigner;
  alerts: AlertManager;
  slippageBoundBp: number;
  /** the borrower accounts to consider (the event index, in production) */
  accounts: () => Promise<string[]>;
  persist: (s: ExecutorState) => void;
  now?: () => number;
  /** optional progress trace (debugging); never carries secrets */
  trace?: (msg: string) => void;
  /** mutation-testing hooks (R-C); `main` never passes them */
  testHooks?: { noMarginClassifier?: boolean; noAllowanceBound?: boolean; noDailyCap?: boolean; skipMarginReadBack?: boolean; minSeizeValueBps?: number; noInsolventPrefilter?: boolean };
}

export function operatorEntry(cfg: MonitorConfig): { name: string; address: string } {
  const e = cfg.operators.find((o) => o.name === cfg.executor.operator);
  if (!e) throw new Error(`executor.operator "${cfg.executor.operator}" is not an entry of operators`);
  return e;
}

export async function verifyExecutorSigner(signer: ExternalSigner, cfg: MonitorConfig, provider: { getNetwork(): Promise<{ chainId: number }> }): Promise<void> {
  const addr = await signer.getAddress();
  const want = operatorEntry(cfg).address;
  if (addr.toLowerCase() !== want.toLowerCase()) throw new Error(`signer address ${addr} is not the configured address ${want} of operator ${cfg.executor.operator}`);
  if ((await provider.getNetwork()).chainId !== 43114) throw new Error("chain id is not 43114");
}

export async function executorStep(deps: ExecutorDeps, state: ExecutorState): Promise<ExecutorOutcome> {
  const { ctx, alerts } = deps;
  const cfg = ctx.cfg;
  const nowS = (): number => deps.now?.() ?? Math.floor(Date.now() / 1000);
  const out: ExecutorOutcome = { state, unfunded: false, swapBlocked: false, skipped: [], halted: !!state.halted };
  if (!cfg.executor.enabled) return out;
  const opName = cfg.executor.operator;
  const tr = (m: string): void => deps.trace?.(`${opName}: ${m}`);
  let st = state;
  const halt = async (reason: string): Promise<ExecutorOutcome> => {
    st = { ...st, halted: { reason, at: nowS() } };
    deps.persist(st);
    await alerts.raise({ key: `executor:halted:${opName}`, severity: "crit", message: `LIQUIDATOR EXECUTOR ${opName} HALTED: ${reason}. No further transaction until a human clears executor.halted / executor.pending in the state file`, audience: "liquidators" }, nowS());
    return { ...out, state: st, halted: true };
  };
  if (state.pending && !state.halted) return halt(`a ${state.pending.stage} step for ${state.pending.borrower} started at ${state.pending.at} was interrupted (process stopped between transactions): check the wallet's USDC, WAVAX, pWAVAX, allowances and the borrower's debt`);
  if (state.halted) return out;

  const { provider } = ctx;
  const operator = await deps.signer.getAddress();
  if (operator.toLowerCase() !== operatorEntry(cfg).address.toLowerCase()) return halt("signer address differs from the configured operator address");
  let blk = await latestBlock(provider);
  tr(`block ${blk.number}`);
  let snap = await readBlockSnapshot(ctx, blk.number);
  tr("snapshot read");
  const dep = cfg.deployment;
  const wIdx = snap.markets.findIndex((m) => m.pToken.toLowerCase() === dep.pWavax.toLowerCase());
  const uIdx = snap.markets.findIndex((m) => m.pToken.toLowerCase() === dep.pUsdc.toLowerCase());
  if (wIdx < 0 || uIdx < 0) return halt("pWAVAX or pUSDC is not a listed market of the controller");
  let pW = snap.oraclePrices[wIdx]!;
  let pU = snap.oraclePrices[uIdx]!;
  if (pW === 0n || pU === 0n) {
    out.skipped.push("oracle price unavailable (stale, zero or unreadable): no action");
    await alerts.raise({ key: `executor:price:${opName}`, severity: "warn", message: `operator ${opName}: the oracle returns no usable price; the executor does nothing until it does`, audience: "monitor-operator" }, nowS());
    return out;
  }
  await alerts.clear(`executor:price:${opName}`, nowS());

  const feesR = await feesWithin(provider, cfg.executor.maxFeeGwei);
  if (!feesR.ok) {
    out.skipped.push(feesR.reason);
    return out;
  }
  const gasBal = await provider.getBalance(operator);
  if (gasBal.lt(cfg.executor.minGasWei)) {
    out.skipped.push(`operator AVAX ${gasBal.toString()} wei is below the floor ${cfg.executor.minGasWei}`);
    await alerts.raise({ key: `executor:gas:${opName}`, severity: "crit", message: `operator ${opName}: AVAX ${gasBal.toString()} wei is below the floor ${cfg.executor.minGasWei}; no liquidation until refilled`, audience: "liquidators" }, nowS());
    return out;
  }
  await alerts.clear(`executor:gas:${opName}`, nowS());
  const send = makeSender(deps.signer, feesR.fees);

  const setPending = (stage: Stage | null, borrower = ""): void => {
    st = { ...st, pending: stage ? { stage, borrower, at: nowS() } : null };
    deps.persist(st); // BEFORE the first transaction of the stage
  };
  const bal = async (token: string, who: string, block?: number): Promise<bigint> => {
    const read = async (b?: number): Promise<bigint> => BigInt(erc20.decodeFunctionResult("balanceOf", await provider.call({ to: token, data: erc20.encodeFunctionData("balanceOf", [who]) }, b))[0].toString());
    if (block === undefined) return read();
    try {
      return await read(block);
    } catch {
      // a load-balanced node that has not reached the receipt's block yet ("header not found"): once more after a second, then the latest state
      await new Promise((r) => setTimeout(r, 1000));
      try {
        return await read(block);
      } catch {
        return read();
      }
    }
  };
  const allowance = async (token: string, spender: string): Promise<bigint> => BigInt(erc20.decodeFunctionResult("allowance", await provider.call({ to: token, data: erc20.encodeFunctionData("allowance", [operator, spender]) }))[0].toString());
  const approve = (token: string, spender: string, amount: bigint) => send(token, erc20.encodeFunctionData("approve", [spender, amount.toString()]), BigNumber.from(120_000));

  try {
    // 1. anything left over from an earlier step: redeem unredeemed pWAVAX, convert held WAVAX (one attempt each)
    if (cfg.executor.convertToUsdc) {
      const r = await finishConversion(null);
      if (r.halt) return halt(r.halt);
      // transactions may have been sent and waited on: a non-archive node serves state for about the last 128 blocks, so the snapshot is re-read at a fresh block
      blk = await latestBlock(provider);
      snap = await readBlockSnapshot(ctx, blk.number);
      pW = snap.oraclePrices[wIdx]!;
      pU = snap.oraclePrices[uIdx]!;
      if (pW === 0n || pU === 0n) {
        out.skipped.push("oracle price unavailable after the conversion step: no further action this cycle");
        return out;
      }
    }
    // 2. choose an account in shortfall
    // 1b. isolated margin: funded liquidation of margin positions (this operator's own inventory), before the lending accounts
    if (cfg.margin?.enabled && cfg.margin.liquidation.enabled) {
      const mr = await marginStep();
      if (mr === "halt") return { ...out, state: st, halted: true };
      if (mr) {
        out.round = mr;
        st = { ...st, rounds: [...st.rounds, mr] };
        deps.persist(st);
        out.state = st;
        return out; // one liquidation round per step
      }
    }
    tr("choosing an account");
    // isolated margin accounts are NOT lending borrowers: the controller refuses liquidateBorrow for them, so trying would cost an approve/reset pair per cycle
    const allAccounts = await deps.accounts();
    const cls = deps.testHooks?.noMarginClassifier ? { margin: new Set<string>(), unknown: [] as string[] } : await classifyMargin(ctx, dep.controller, allAccounts.map((a) => a.toLowerCase()), blk.number);
    const accounts = allAccounts.filter((a) => !cls.margin.has(a.toLowerCase()) && !cls.unknown.includes(a.toLowerCase()));
    const inputs = await readAccountInputs(ctx, snap, accounts.map((a) => a.toLowerCase()));
    const cands = accounts
      .map((a) => ({ a: a.toLowerCase(), i: inputs.get(a.toLowerCase())! }))
      .filter((c) => c.i && c.i.liquidityErr === 0n && c.i.shortfall > 0n && c.i.debtUnits > 0n)
      .sort((x, y) => (y.i.shortfall > x.i.shortfall ? 1 : y.i.shortfall < x.i.shortfall ? -1 : 0));
    const inventory = await bal(USDC, operator);
    for (const c of cands) {
      if ((st.cooldown[c.a] ?? 0) > nowS()) {
        out.skipped.push(`${c.a}: cooling down`);
        continue;
      }
      const wm = c.i.markets[wIdx]!;
      const collateralUsdc = oracleValueUsdc((wm.pTokenBalance * wm.exchangeRate) / 10n ** 18n, pW, pU);
      const plan = planRepay({ debt: c.i.debtUnits, closeFactor: snap.closeFactor, collateralUsdc, inventory, minRepay: BigInt(cfg.executor.minRepayUsdc) * 1_000_000n });
      if (plan.unfunded) {
        out.unfunded = true;
        await alerts.raise({ key: `executor:unfunded:${opName}`, severity: "warn", message: `operator ${opName}: USDC inventory ${inventory} is below the repayment wanted for ${c.a}${plan.repay > 0n ? ` (partial liquidation of ${plan.repay})` : "; this account stays in shortfall"}. Top the inventory up`, audience: "liquidators" }, nowS());
      }
      if (plan.repay === 0n) {
        out.skipped.push(`${c.a}: ${plan.reason}`);
        continue;
      }
      const r = await liquidateRound(c.a, plan.repay);
      if (r === "halt") return { ...out, state: st, halted: true };
      if (r === "skipped") continue;
      out.round = r;
      st = { ...st, rounds: [...st.rounds, r] };
      deps.persist(st);
      break; // one liquidation round per step
    }
    if (!out.unfunded) await alerts.clear(`executor:unfunded:${opName}`, nowS());
    out.state = st;
    return out;
  } catch (e) {
    // best effort: never leave an allowance behind when stopping (each is bounded to one round's need anyway)
    for (const [token, spender] of [[USDC, dep.pUsdc], [WAVAX, UNIV3_SWAP_ROUTER02], ...(cfg.margin?.enabled ? ([[USDC, cfg.margin.liquidator]] as const) : [])] as const) {
      try {
        if ((await allowance(token, spender)) > 0n) await approve(token, spender, 0n);
      } catch {
        /* the halt message tells a human to check the allowances */
      }
    }
    return halt(`unexpected error: ${safeError(e)}`);
  }

  // ---------------------------------------------------------------- isolated margin: one FUNDED liquidation (+ the shared redeem + conversion)
  // The operator repays from its own USDC and receives the position pTokens (bonus <= 5%). The repayment is chosen by the risk engine, not by the
  // operator, so the allowance is BOUNDED, not exact: maxRepayUnderlying = min(inventory, daily-cap remaining, per-call cap, debt), approved to the
  // liquidator proxy and refused on chain above that (LiquidationError 28). minSeizeValueBps is FIXED at 10,000 (break-even): an insolvent position
  // is declined (LiquidationError 32), the debt stays in the market and the monitor alerts (decision D3). The allowance is reset to 0 in every outcome.
  async function marginStep(): Promise<RoundRecord | "halt" | undefined> {
    const m = cfg.margin!;
    const lq = m.liquidation;
    const wantMin = deps.testHooks?.minSeizeValueBps ?? MIN_SEIZE_VALUE_BPS;
    // drift checks: the liquidator must be wired to the configured engine and config (a swapped proxy must not receive an allowance)
    const mi = marginLiquidatorIface;
    const readAddr = async (to: string, iface: utils.Interface, fn: string): Promise<string> => (iface.decodeFunctionResult(fn, await provider.call({ to, data: iface.encodeFunctionData(fn) }))[0] as string).toLowerCase();
    if ((await readAddr(m.liquidator, mi, "riskEngine")) !== m.riskEngine.toLowerCase() || (await readAddr(m.liquidator, mi, "config")) !== m.config.toLowerCase()) return halt("the margin liquidator's riskEngine()/config() differ from the configured addresses (configuration drift): no allowance is given").then(() => "halt" as const);
    const isFunder = marginConfigIface.decodeFunctionResult("fundedLiquidators", await provider.call({ to: m.config, data: marginConfigIface.encodeFunctionData("fundedLiquidators", [operator]) }))[0] as boolean;
    if (!isFunder) {
      out.skipped.push("margin: this operator is not on the funded-liquidator allowlist");
      await alerts.raise({ key: `executor:margin-not-funder:${opName}`, severity: "warn", message: `operator ${opName} is not a funded liquidator: it cannot liquidate margin positions`, audience: "liquidators" }, nowS());
      return undefined;
    }
    await alerts.clear(`executor:margin-not-funder:${opName}`, nowS());
    const positions = await readMarginPositions(ctx, m.executor, blk.number);
    const bonus = await readPairBonusBps(ctx, m.config, positions.find((p) => p.status === 2), blk.number);
    const evals = (await evaluateMarginPositions(ctx, m.riskEngine, positions, blk.number, m.watchHealthBps, bonus)).filter((e) => e.verdict === "LIQUIDATABLE" || e.verdict === "INSOLVENT");
    evals.sort((a, b) => (b.metrics!.debtValueUsd > a.metrics!.debtValueUsd ? 1 : -1));
    for (const e of evals) {
      const p = e.position;
      const ckey = `margin:${p.id}`;
      if ((st.cooldown[ckey] ?? 0) > nowS()) {
        out.skipped.push(`margin position ${p.id}: cooling down`);
        continue;
      }
      if (e.verdict === "INSOLVENT" && !deps.testHooks?.noInsolventPrefilter) {
        // declined without sending anything: the break-even floor would refuse it; the monitor raises the human-decision alert
        out.skipped.push(`margin position ${p.id}: insolvent (equity <= 0), declined at the break-even floor; the debt stays in the market`);
        await alerts.raise({ key: `executor:margin-declined:${opName}:${p.id}`, severity: "crit", message: `operator ${opName} DECLINES margin position ${p.id}: collateral no longer covers the debt, the break-even floor would refuse it. The debt stays in the pUSDC market. Human decision needed`, audience: "treasury-signers" }, nowS());
        st = { ...st, cooldown: { ...st.cooldown, [ckey]: nowS() + lq.insolventCooldownSeconds } };
        deps.persist(st);
        continue;
      }
      await alerts.clear(`executor:margin-declined:${opName}:${p.id}`, nowS());
      const debt = BigInt(utils.defaultAbiCoder.decode(["uint256"], await provider.call({ to: p.debtPToken, data: pIface.encodeFunctionData("borrowBalanceStored", [p.account]) }))[0].toString());
      const inventory = await bal(USDC, operator);
      const rounds = st.marginRounds ?? [];
      const plan = planMarginRepay({
        debt,
        inventory,
        dailyCap: deps.testHooks?.noDailyCap ? 10n ** 15n : BigInt(lq.dailyRepayCapUsdc) * 1_000_000n,
        repaidToday: repaidInWindow(rounds, nowS()),
        perCallCap: deps.testHooks?.noAllowanceBound ? 10n ** 15n : BigInt(lq.maxRepayPerCallUsdc) * 1_000_000n,
        minRepay: BigInt(lq.minRepayUsdc) * 1_000_000n,
      });
      if (plan.maxRepay === 0n) {
        out.skipped.push(`margin position ${p.id}: ${plan.reason}`);
        if (plan.bound === "inventory") out.unfunded = true;
        await alerts.raise({ key: `executor:margin-bounded:${opName}`, severity: plan.bound === "daily-cap" ? "crit" : "warn", message: `operator ${opName} cannot liquidate margin position ${p.id}: ${plan.reason}${plan.bound === "inventory" ? ". Top the USDC inventory up" : plan.bound === "daily-cap" ? ". The daily repayment cap is used up; raise it deliberately (config) or let the other operator act" : ""}`, audience: "liquidators" }, nowS());
        continue;
      }
      await alerts.clear(`executor:margin-bounded:${opName}`, nowS());
      const params = [p.id.toString(), operator, plan.maxRepay.toString(), "0", "0", String(wantMin)];
      const data = marginLiquidatorIface.encodeFunctionData("liquidateFunded", [params]);
      const usdcBefore = await bal(USDC, operator);
      const pBefore = await bal(p.positionPToken, operator);
      const mBefore = p.marginPToken === p.positionPToken ? pBefore : await bal(p.marginPToken, operator);
      setPending("margin", p.account);
      tr(`margin: approve <= ${plan.maxRepay} USDC for position ${p.id} (bound: ${plan.bound})`);
      await approve(USDC, m.liquidator, plan.maxRepay);
      const reset = async (): Promise<void> => {
        if ((await allowance(USDC, m.liquidator)) > 0n) await approve(USDC, m.liquidator, 0n);
      };
      let gasLimit: BigNumber;
      try {
        await provider.call({ from: operator, to: m.liquidator, data });
        gasLimit = (await provider.estimateGas({ from: operator, to: m.liquidator, data })).mul(13).div(10);
      } catch (err) {
        await reset();
        setPending(null);
        const code = liquidationErrorCode(err);
        if (code === LIQ_VALUE_FLOOR) {
          out.skipped.push(`margin position ${p.id}: declined by the break-even floor (LiquidationError 32); allowance reset`);
          await alerts.raise({ key: `executor:margin-declined:${opName}:${p.id}`, severity: "crit", message: `operator ${opName} DECLINES margin position ${p.id}: the value received would be below the value repaid (break-even floor, LiquidationError 32). The debt stays in the pUSDC market. Human decision needed`, audience: "treasury-signers" }, nowS());
          st = { ...st, cooldown: { ...st.cooldown, [ckey]: nowS() + lq.insolventCooldownSeconds } };
        } else if (code === LIQ_REPAY_ABOVE_MAX) {
          out.skipped.push(`margin position ${p.id}: the repayment the risk engine wants exceeds the bound ${plan.maxRepay} (${plan.bound}); allowance reset`);
          if (plan.bound === "inventory") out.unfunded = true;
          await alerts.raise({ key: `executor:margin-bounded:${opName}`, severity: "crit", message: `operator ${opName}: margin position ${p.id} needs a larger repayment than the ${plan.bound} bound allows (${plan.maxRepay} USDC units). ${plan.bound === "inventory" ? "Top the inventory up" : "Raise the cap deliberately in the configuration"}; the other operator may act`, audience: "liquidators" }, nowS());
          st = { ...st, cooldown: { ...st.cooldown, [ckey]: nowS() + lq.retryCooldownSeconds } };
        } else if (code === LIQ_NOT_FUNDER) {
          out.skipped.push(`margin position ${p.id}: LiquidationError 27 (not a funded liquidator); allowance reset`);
          st = { ...st, cooldown: { ...st.cooldown, [ckey]: nowS() + lq.retryCooldownSeconds } };
        } else {
          out.skipped.push(`margin position ${p.id}: funded liquidation simulation failed (${code !== undefined ? `LiquidationError ${code}` : safeError(err)}); allowance reset`);
          st = { ...st, cooldown: { ...st.cooldown, [ckey]: nowS() + lq.retryCooldownSeconds } };
        }
        deps.persist(st);
        continue;
      }
      let tx;
      try {
        tr(`margin: send funded liquidation of position ${p.id}`);
        tx = await send(m.liquidator, data, gasLimit);
      } catch (err) {
        if (err instanceof TxReverted) {
          await reset();
          setPending(null);
          st = { ...st, cooldown: { ...st.cooldown, [ckey]: nowS() + lq.retryCooldownSeconds } };
          deps.persist(st);
          out.skipped.push(`margin position ${p.id}: funded liquidation reverted after a passing simulation (${err.hash}); allowance reset`);
          continue;
        }
        throw err;
      }
      // read-back from the receipt: the event names this operator as funder AND recipient; USDC left == debtRepaid <= the bound; the seized pTokens arrived
      const receipt = await provider.getTransactionReceipt(tx.hash);
      const usdcAfter = await bal(USDC, operator, receipt.blockNumber);
      const pAfter = await bal(p.positionPToken, operator, receipt.blockNumber);
      const mAfter = p.marginPToken === p.positionPToken ? pAfter : await bal(p.marginPToken, operator, receipt.blockNumber);
      const ev = receipt.logs.filter((l) => l.address.toLowerCase() === m.liquidator.toLowerCase()).map((l) => { try { return marginLiquidatorIface.parseLog(l); } catch { return undefined; } }).find((x) => x?.name === "FundedPositionLiquidated");
      const problems: string[] = [];
      const spent = usdcBefore - usdcAfter;
      if (!ev) problems.push("no FundedPositionLiquidated event");
      else {
        if (ev.args.positionId.toString() !== p.id.toString()) problems.push("event names a different position");
        if ((ev.args.funder as string).toLowerCase() !== operator.toLowerCase() || (ev.args.recipient as string).toLowerCase() !== operator.toLowerCase()) problems.push("event names a different funder or recipient");
        if (BigInt(ev.args.debtRepaid.toString()) !== spent) problems.push(`USDC delta ${spent} != debtRepaid ${ev.args.debtRepaid.toString()}`);
        if (p.marginPToken === p.positionPToken ? BigInt(ev.args.positionPTokensSeized.toString()) + BigInt(ev.args.marginPTokensSeized.toString()) !== pAfter - pBefore : BigInt(ev.args.positionPTokensSeized.toString()) !== pAfter - pBefore || BigInt(ev.args.marginPTokensSeized.toString()) !== mAfter - mBefore) problems.push("pToken delta differs from the event's seized amounts");
      }
      if (spent > plan.maxRepay) problems.push(`USDC delta ${spent} exceeds the allowance bound ${plan.maxRepay}`);
      if (spent <= 0n) problems.push("no USDC was repaid");
      if (pAfter <= pBefore && mAfter <= mBefore) problems.push("no pTokens received");
      if (deps.testHooks?.skipMarginReadBack) problems.length = 0;
      await reset();
      const round: RoundRecord = { ts: nowS(), borrower: p.account, repay: spent.toString(), seizedPTokens: (pAfter - pBefore).toString(), liquidateTx: tx.hash, marginPositionId: p.id.toString() };
      st = { ...st, marginRounds: [...(st.marginRounds ?? []).filter((r) => r.ts > nowS() - 7 * 86_400), { ts: round.ts, positionId: p.id.toString(), repay: spent.toString() }] };
      deps.persist(st);
      await alerts.notify({ kind: "action", key: `executor:margin-liquidation:${opName}`, severity: "warn", audience: "liquidators", text: `operator ${opName} LIQUIDATED margin position ${p.id}: repaid ${spent} USDC units, received ${pAfter - pBefore} position pTokens${mAfter > mBefore && p.marginPToken !== p.positionPToken ? ` and ${mAfter - mBefore} margin pTokens` : ""} (${tx.hash}, block ${receipt.blockNumber})${problems.length ? `. READ-BACK PROBLEMS: ${problems.join("; ")}` : ""}` });
      if (problems.length) {
        st = { ...st, rounds: [...st.rounds, round] };
        await halt(`margin liquidation ${tx.hash} mined but read-back failed: ${problems.join("; ")}`);
        return "halt";
      }
      // margin pTokens (pUSDC) seized by the funded route are redeemed to USDC here (exactly what arrived, never the wallet's whole balance)
      const marginGot = p.marginPToken === p.positionPToken ? 0n : mAfter - mBefore;
      if (marginGot > 0n && cfg.executor.convertToUsdc) {
        try {
          const rd = pIface.encodeFunctionData("redeem", [marginGot.toString()]);
          const code = pIface.decodeFunctionResult("redeem", await provider.call({ from: operator, to: p.marginPToken, data: rd }))[0] as BigNumber;
          if (!code.eq(0)) throw new Error(`redeem simulation returned error code ${code.toString()}`);
          await send(p.marginPToken, rd, (await provider.estimateGas({ from: operator, to: p.marginPToken, data: rd })).mul(13).div(10));
        } catch (err) {
          out.skipped.push(`margin: the seized margin pTokens stay in the wallet (${safeError(err)})`);
        }
      }
      if (!cfg.executor.convertToUsdc) {
        setPending(null);
        return round;
      }
      const f = await finishConversion(round);
      if (f.halt) {
        st = { ...st, rounds: [...st.rounds, round] };
        await halt(f.halt);
        return "halt";
      }
      setPending(null);
      return round;
    }
    return undefined;
  }

  // ---------------------------------------------------------------- one liquidation round (+ redeem + conversion)
  async function liquidateRound(borrower: string, repay: bigint): Promise<RoundRecord | "skipped" | "halt"> {
    const liqData = pIface.encodeFunctionData("liquidateBorrow", [borrower, repay.toString(), dep.pWavax]);
    const pBefore = await bal(dep.pWavax, operator);
    const usdcBefore = await bal(USDC, operator);
    setPending("liquidate", borrower);
    tr(`approve ${repay} USDC`);
    await approve(USDC, dep.pUsdc, repay);
    tr("simulate liquidation");
    let gasLimit: BigNumber;
    try {
      const code = pIface.decodeFunctionResult("liquidateBorrow", await provider.call({ from: operator, to: dep.pUsdc, data: liqData }))[0] as BigNumber;
      if (!code.eq(0)) throw new Error(`simulation returned error code ${code.toString()}`);
      gasLimit = (await provider.estimateGas({ from: operator, to: dep.pUsdc, data: liqData })).mul(13).div(10);
    } catch (e) {
      await approve(USDC, dep.pUsdc, 0n);
      setPending(null);
      st = { ...st, cooldown: { ...st.cooldown, [borrower]: nowS() + LIQUIDATION_RETRY_COOLDOWN_SECONDS } };
      deps.persist(st);
      out.skipped.push(`${borrower}: liquidation simulation failed (${safeError(e)}); allowance reset`);
      return "skipped";
    }
    let tx;
    try {
      tr("send liquidation");
      tx = await send(dep.pUsdc, liqData, gasLimit);
      tr("liquidation mined");
    } catch (e) {
      if (e instanceof TxReverted) {
        // another liquidator was first, or the account recovered: not an emergency
        await approve(USDC, dep.pUsdc, 0n);
        setPending(null);
        st = { ...st, cooldown: { ...st.cooldown, [borrower]: nowS() + LIQUIDATION_RETRY_COOLDOWN_SECONDS } };
        deps.persist(st);
        out.skipped.push(`${borrower}: liquidation transaction reverted after a passing simulation (${e.hash}); allowance reset`);
        return "skipped";
      }
      throw e;
    }
    // read-back: USDC pulled == repay, pWAVAX received, allowance used up
    const receipt = await provider.getTransactionReceipt(tx.hash);
    const usdcAfter = await bal(USDC, operator, receipt.blockNumber);
    const pAfter = await bal(dep.pWavax, operator, receipt.blockNumber);
    const ev = receipt.logs.filter((l) => l.address.toLowerCase() === dep.pUsdc.toLowerCase()).map((l) => { try { return pIface.parseLog(l); } catch { return undefined; } }).find((p) => p?.name === "LiquidateBorrow");
    const problems: string[] = [];
    if (usdcBefore - usdcAfter !== repay) problems.push(`USDC delta ${usdcBefore - usdcAfter} != repay ${repay}`);
    if (pAfter <= pBefore) problems.push("no pWAVAX received");
    if (!ev) problems.push("no LiquidateBorrow event");
    else if ((ev.args.borrower as string).toLowerCase() !== borrower.toLowerCase() || (ev.args.liquidator as string).toLowerCase() !== operator.toLowerCase()) problems.push("LiquidateBorrow names a different borrower or liquidator");
    if ((await allowance(USDC, dep.pUsdc)) > 0n) await approve(USDC, dep.pUsdc, 0n);
    const round: RoundRecord = { ts: nowS(), borrower, repay: repay.toString(), seizedPTokens: (pAfter - pBefore).toString(), liquidateTx: tx.hash };
    await alerts.notify({ kind: "action", key: `executor:liquidation:${opName}`, severity: "warn", audience: "liquidators", text: `operator ${opName} LIQUIDATED ${borrower}: repaid ${repay} USDC units, received ${pAfter - pBefore} pWAVAX (${tx.hash}, block ${receipt.blockNumber})${problems.length ? `. READ-BACK PROBLEMS: ${problems.join("; ")}` : ""}` });
    if (problems.length) {
      st = { ...st, rounds: [...st.rounds, round] };
      await halt(`liquidation ${tx.hash} mined but read-back failed: ${problems.join("; ")}`);
      return "halt";
    }
    if (!cfg.executor.convertToUsdc) {
      setPending(null);
      return round;
    }
    const f = await finishConversion(round);
    if (f.halt) {
      st = { ...st, rounds: [...st.rounds, round] };
      await halt(f.halt);
      return "halt";
    }
    setPending(null);
    return round;
  }

  // ---------------------------------------------------------------- redeem every pWAVAX the wallet holds, convert every WAVAX it holds
  async function finishConversion(round: RoundRecord | null): Promise<{ halt?: string }> {
    // redeem
    const pAll = await bal(dep.pWavax, operator);
    if (pAll > 0n) {
      const exch = BigInt((await pWavaxExchange()).toString());
      const expected = (pAll * exch) / 10n ** 18n;
      const w0 = await bal(WAVAX, operator);
      setPending("redeem", round?.borrower ?? "");
      try {
        const data = pIface.encodeFunctionData("redeem", [pAll.toString()]);
        const code = pIface.decodeFunctionResult("redeem", await provider.call({ from: operator, to: dep.pWavax, data }))[0] as BigNumber;
        if (!code.eq(0)) throw new Error(`redeem simulation returned error code ${code.toString()}`);
        const gl = (await provider.estimateGas({ from: operator, to: dep.pWavax, data })).mul(13).div(10);
        const tx = await send(dep.pWavax, data, gl);
        const got = (await bal(WAVAX, operator)) - w0;
        const tol = expected / 1_000_000n + 2n;
        if (got + tol < expected || got > expected + tol) return { halt: `redeem ${tx.hash}: WAVAX received ${got} differs from pTokens x exchange rate ${expected}` };
        if (round) round.redeemTx = tx.hash;
      } catch (e) {
        if (e instanceof Error && !(e instanceof TxReverted) && !/simulation|error code/.test(e.message)) throw e;
        out.skipped.push(`redeem not possible now (${safeError(e)}); the pWAVAX stays in the wallet and is retried`);
        setPending(null);
        return {};
      }
    }
    // convert
    const wavaxIn = await bal(WAVAX, operator);
    if (wavaxIn === 0n) {
      setPending(null);
      return {};
    }
    const oracleVal = oracleValueUsdc(wavaxIn, pW, pU);
    const minOut = minOutFor(oracleVal, deps.slippageBoundBp);
    const swapData = router.encodeFunctionData("exactInputSingle", [{ tokenIn: WAVAX, tokenOut: USDC, fee: UNIV3_FEE, recipient: operator, amountIn: wavaxIn.toString(), amountOutMinimum: minOut.toString(), sqrtPriceLimitX96: 0 }]);
    setPending("swap", round?.borrower ?? "");
    await approve(WAVAX, UNIV3_SWAP_ROUTER02, wavaxIn);
    const blocked = async (why: string): Promise<{ halt?: string }> => {
      await approve(WAVAX, UNIV3_SWAP_ROUTER02, 0n);
      out.swapBlocked = true;
      if (round) round.swapBlocked = why;
      await alerts.raise({ key: `executor:swap-blocked:${opName}`, severity: "crit", message: `operator ${opName}: the WAVAX -> USDC conversion is BLOCKED (${why}). No fallback route is tried and the limit is not loosened: ${wavaxIn} WAVAX units stay in the wallet (price exposure) and USDC inventory is not restored until it clears`, audience: "liquidators" }, nowS());
      setPending(null);
      return {};
    };
    let outSim: bigint;
    try {
      outSim = BigInt(router.decodeFunctionResult("exactInputSingle", await provider.call({ from: operator, to: UNIV3_SWAP_ROUTER02, data: swapData }))[0].toString());
    } catch (e) {
      return blocked(`simulation failed or would fall below the min-out (${safeError(e)})`);
    }
    if (outSim < minOut) return blocked(`simulated output ${outSim} is below the min-out ${minOut}`);
    const usdc0 = await bal(USDC, operator);
    let tx;
    try {
      tx = await send(UNIV3_SWAP_ROUTER02, swapData, (await provider.estimateGas({ from: operator, to: UNIV3_SWAP_ROUTER02, data: swapData })).mul(13).div(10));
    } catch (e) {
      if (e instanceof TxReverted) return blocked(`swap transaction reverted at the min-out (${e.hash})`);
      throw e;
    }
    const got = (await bal(USDC, operator)) - usdc0;
    const wavaxLeft = await bal(WAVAX, operator);
    const problems: string[] = [];
    if (got < minOut) problems.push(`USDC received ${got} is below the min-out ${minOut}`);
    if (wavaxLeft !== 0n) problems.push(`WAVAX left after the swap: ${wavaxLeft}`);
    if ((await allowance(WAVAX, UNIV3_SWAP_ROUTER02)) > 0n) await approve(WAVAX, UNIV3_SWAP_ROUTER02, 0n);
    if (round) {
      round.swapTx = tx.hash;
      round.wavaxIn = wavaxIn.toString();
      round.usdcOut = got.toString();
    }
    if (problems.length) return { halt: `swap ${tx.hash} mined but read-back failed: ${problems.join("; ")}` };
    await alerts.clear(`executor:swap-blocked:${opName}`, nowS());
    setPending(null);
    return {};
  }

  async function pWavaxExchange(): Promise<BigNumber> {
    return pIface.decodeFunctionResult("exchangeRateStored", await provider.call({ to: dep.pWavax, data: pIface.encodeFunctionData("exchangeRateStored") }))[0] as BigNumber;
  }
}

export type { BlockSnapshot };
void ctrlIface;

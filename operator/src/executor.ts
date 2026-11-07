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
}
export type Stage = "liquidate" | "redeem" | "swap";
export interface ExecutorState {
  halted: null | { reason: string; at: number };
  /** set (and persisted) BEFORE the first transaction of a stage; found set at start-up = interrupted = HALT */
  pending: null | { stage: Stage; borrower: string; at: number };
  rounds: RoundRecord[];
  /** per-borrower retry-not-before (unix s) after a liquidation that reverted (another liquidator was first) */
  cooldown: Record<string, number>;
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
  const blk = await latestBlock(provider);
  tr(`block ${blk.number}`);
  const snap = await readBlockSnapshot(ctx, blk.number);
  tr("snapshot read");
  const dep = cfg.deployment;
  const wIdx = snap.markets.findIndex((m) => m.pToken.toLowerCase() === dep.pWavax.toLowerCase());
  const uIdx = snap.markets.findIndex((m) => m.pToken.toLowerCase() === dep.pUsdc.toLowerCase());
  if (wIdx < 0 || uIdx < 0) return halt("pWAVAX or pUSDC is not a listed market of the controller");
  const pW = snap.oraclePrices[wIdx]!;
  const pU = snap.oraclePrices[uIdx]!;
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
  const bal = async (token: string, who: string, block?: number): Promise<bigint> => BigInt(erc20.decodeFunctionResult("balanceOf", await provider.call({ to: token, data: erc20.encodeFunctionData("balanceOf", [who]) }, block))[0].toString());
  const allowance = async (token: string, spender: string): Promise<bigint> => BigInt(erc20.decodeFunctionResult("allowance", await provider.call({ to: token, data: erc20.encodeFunctionData("allowance", [operator, spender]) }))[0].toString());
  const approve = (token: string, spender: string, amount: bigint) => send(token, erc20.encodeFunctionData("approve", [spender, amount.toString()]), BigNumber.from(120_000));

  try {
    // 1. anything left over from an earlier step: redeem unredeemed pWAVAX, convert held WAVAX (one attempt each)
    if (cfg.executor.convertToUsdc) {
      const r = await finishConversion(null);
      if (r.halt) return halt(r.halt);
    }
    // 2. choose an account in shortfall
    tr("choosing an account");
    const accounts = await deps.accounts();
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
    for (const [token, spender] of [[USDC, dep.pUsdc], [WAVAX, UNIV3_SWAP_ROUTER02]] as const) {
      try {
        if ((await allowance(token, spender)) > 0n) await approve(token, spender, 0n);
      } catch {
        /* the halt message tells a human to check the allowances */
      }
    }
    return halt(`unexpected error: ${safeError(e)}`);
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

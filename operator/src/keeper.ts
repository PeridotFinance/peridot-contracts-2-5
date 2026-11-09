// TREASURY KEEPER (operator decision 2026-11-06). A hot wallet that holds the PROTECTION USDC and executes `repayBorrowBehalf` ITSELF when the
// monitor's rule returns DEFAULT_EXHAUSTED. The Avalanche Safe is the cold reserve that funds it; this is the only execution path.
//
// The rule is the monitor's (src/detect.ts), unchanged: same fail-closed verdicts, same reference-price check and tolerance. On top of it the keeper
// adds only restrictions, never a way to pay in a case the rule does not name:
//   1. CONFIRMATION: the account must read DEFAULT_EXHAUSTED on `confirmEvaluations` consecutive evaluations on distinct blocks spanning at least
//      `confirmSeconds` of chain time (treasury document 2.3.1 "persistence hardening"); any other verdict, a blind cycle or an RPC failure resets it.
//   2. RE-VERIFICATION at execution: a fresh evaluation at the latest block must read DEFAULT_EXHAUSTED again, with a healthy reference.
//   3. AMOUNT BOUNDED BY THE DEBT at execution: the allowance is exactly debt-now plus `allowanceMarginBp` (interest until inclusion), never more;
//      the full-repay sentinel then pulls at most that; the transaction is SIMULATED first; the pulled amount is read back and checked.
//   4. DAILY SPEND CAP over a rolling 24 h; the keeper's balance must cover the payment (no partial repayments: that is a human decision).
//   5. FEE CAP, GAS BALANCE, signer address == configured treasury address, chain id 43114.
//   6. HALT on anything unexpected after a transaction was sent (revert, read-back mismatch, unknown error): no further payment until a human
//      clears `keeper.halted` in the state file; every payment and every halt is alerted.
import { BigNumber, providers, utils } from "ethers";
import { pacedGetLogs } from "./logpace";
import type { AlertManager } from "./alerts";
import { ERC20_ABI } from "./abi";
import { CONTROLLER_ABI } from "./abi";
import { latestBlock, pIface, readAccountInputs, readBlockSnapshot } from "./chain";
import type { Ctx } from "./chain";
import type { MonitorConfig } from "./config";
import { evaluateRule, Verdict } from "./detect";
import type { CycleReport } from "./monitor";
import type { ExternalSigner, TxRequest } from "./signer";
import { USDC } from "./constants";
import { safeError } from "./mask";

const MAX_UINT = BigNumber.from(2).pow(256).sub(1);
const erc20 = new utils.Interface(ERC20_ABI);
void CONTROLLER_ABI;

export interface KeeperPayment {
  ts: number;
  account: string;
  amountUsdc: string;
  debtAtDecision: string;
  txHash: string;
  blockNumber: number;
}
export interface KeeperState {
  halted: null | { reason: string; at: number };
  seen: Record<string, { count: number; firstAt: number; lastAt: number; lastBlock: number }>;
  payments: KeeperPayment[];
  /** set (and persisted) BEFORE the first transaction of a payment is sent, cleared when it is finished; found set at start-up = interrupted = HALT */
  pending: null | { account: string; at: number };
  /** per-account retry-not-before (unix s), set after a failure that cost gas, so a polling loop cannot spam approvals */
  cooldown: Record<string, number>;
}
export const emptyKeeperState = (): KeeperState => ({ halted: null, seen: {}, payments: [], pending: null, cooldown: {} });
export const RETRY_COOLDOWN_SECONDS = 300;

export type Skip = { account: string; reason: string };
export interface KeeperOutcome {
  state: KeeperState;
  paid: KeeperPayment[];
  skipped: Skip[];
  halted: boolean;
}

// ------------------------------------------------------------------ pure parts (unit-tested)
export function updateConfirmations(seen: KeeperState["seen"], defaults: string[], blockNumber: number, blockTimestamp: number): KeeperState["seen"] {
  const next: KeeperState["seen"] = {};
  for (const a of defaults.map((x) => x.toLowerCase())) {
    const cur = seen[a];
    if (!cur) next[a] = { count: 1, firstAt: blockTimestamp, lastAt: blockTimestamp, lastBlock: blockNumber };
    else if (blockNumber > cur.lastBlock) next[a] = { ...cur, count: cur.count + 1, lastAt: blockTimestamp, lastBlock: blockNumber };
    else next[a] = cur; // the same block seen twice counts once
  }
  return next; // an account that is no longer DEFAULT_EXHAUSTED is dropped: its confirmation starts over
}
export function isConfirmed(e: KeeperState["seen"][string] | undefined, cfg: MonitorConfig): boolean {
  return !!e && e.count >= cfg.keeper.confirmEvaluations && e.lastAt - e.firstAt >= cfg.keeper.confirmSeconds;
}
export function spentInWindow(payments: KeeperPayment[], now: number, windowSeconds = 86_400): bigint {
  return payments.filter((p) => p.ts > now - windowSeconds).reduce((s, p) => s + BigInt(p.amountUsdc), 0n);
}
/** Exact-need allowance: the debt read now plus the margin, rounded up. */
export function allowanceFor(debt: bigint, marginBp: number): bigint {
  return debt + (debt * BigInt(marginBp) + 9_999n) / 10_000n;
}
export interface BudgetCheck {
  ok: boolean;
  reason?: string;
  allowance: bigint;
}
export function checkBudget(args: { debt: bigint; keeperUsdc: bigint; spent24h: bigint; capUnits: bigint; marginBp: number }): BudgetCheck {
  const allowance = allowanceFor(args.debt, args.marginBp);
  if (args.debt === 0n) return { ok: false, reason: "no debt at execution", allowance };
  if (args.keeperUsdc < allowance) return { ok: false, reason: `keeper USDC ${args.keeperUsdc} cannot cover the debt plus margin ${allowance} (no partial repayment: top up from the Safe, or a human decides)`, allowance };
  if (args.spent24h + allowance > args.capUnits) return { ok: false, reason: `daily spend cap: spent ${args.spent24h} + ${allowance} would exceed ${args.capUnits}`, allowance };
  return { ok: true, allowance };
}

/**
 * The AUTHORITATIVE 24 h spend: every RepayBorrow on pUSDC whose payer is the keeper wallet, read from the chain. The state file's ledger can be
 * lost (an ephemeral container filesystem, a restored backup, an operator deleting it); the daily cap must not depend on it. Looks back
 * `lookbackBlocks` (0.8 s per block is assumed, a conservative bound against the measured 0.94 s, so 24 h = 108,000 blocks; 53 requests at 2,048 blocks) and filters by block time.
 */
export async function spentOnChain(provider: providers.Provider, pUsdc: string, keeper: string, nowSeconds: number, chunkBlocks: number, notBefore: number, windowSeconds = 86_400, minBlockSeconds = 0.5): Promise<{ spent: bigint; payments: KeeperPayment[] }> {
  const head = await provider.getBlockNumber();
  const from = Math.max(1, notBefore, head - Math.ceil(windowSeconds / minBlockSeconds)); // no repayment can predate the deployment of pUSDC
  const topic = pIface.getEventTopic("RepayBorrow");
  const payments: KeeperPayment[] = [];
  const tsCache = new Map<number, number>();
  for (let s = from; s <= head; s += chunkBlocks) {
    const logs = await pacedGetLogs(provider, { address: pUsdc, fromBlock: s, toBlock: Math.min(head, s + chunkBlocks - 1), topics: [topic] });
    for (const l of logs) {
      const ev = pIface.parseLog(l);
      if ((ev.args.payer as string).toLowerCase() !== keeper.toLowerCase()) continue;
      let ts = tsCache.get(l.blockNumber);
      if (ts === undefined) {
        ts = (await provider.getBlock(l.blockNumber)).timestamp;
        tsCache.set(l.blockNumber, ts);
      }
      if (ts <= nowSeconds - windowSeconds) continue;
      payments.push({ ts, account: ev.args.borrower as string, amountUsdc: (ev.args.repayAmount as BigNumber).toString(), debtAtDecision: "0", txHash: l.transactionHash, blockNumber: l.blockNumber });
    }
  }
  return { spent: payments.reduce((a, p) => a + BigInt(p.amountUsdc), 0n), payments };
}

// ------------------------------------------------------------------ execution
export interface KeeperDeps {
  ctx: Ctx;
  signer: ExternalSigner;
  alerts: AlertManager;
  /** persists the keeper state; called BEFORE any transaction is sent and after every change */
  persist: (s: KeeperState) => void;
  now?: () => number;
}

export async function verifySigner(signer: ExternalSigner, cfg: MonitorConfig, provider: providers.Provider): Promise<void> {
  const addr = await signer.getAddress();
  if (addr.toLowerCase() !== cfg.treasury.address.toLowerCase()) throw new Error(`signer address ${addr} is not the configured treasury address ${cfg.treasury.address}`);
  const net = await provider.getNetwork();
  if (net.chainId !== 43114) throw new Error(`chain id ${net.chainId} is not 43114`);
}

export async function keeperStep(deps: KeeperDeps, state: KeeperState, report: CycleReport): Promise<KeeperOutcome> {
  const { ctx, alerts } = deps;
  const cfg = ctx.cfg;
  const out: KeeperOutcome = { state, paid: [], skipped: [], halted: !!state.halted };
  if (!cfg.keeper.enabled) return out;
  if (state.pending && !state.halted) {
    const reason = `a payment to ${state.pending.account} started at ${state.pending.at} was interrupted (process stopped between transactions): check the keeper's allowance, USDC balance and the account's debt, then clear keeper.pending and keeper.halted`;
    const halted = { ...state, halted: { reason, at: deps.now?.() ?? report.blockTimestamp } };
    deps.persist(halted);
    await alerts.raise({ key: "keeper:halted", severity: "crit", message: `TREASURY KEEPER HALTED: ${reason}`, audience: "treasury-signers" }, deps.now?.() ?? report.blockTimestamp);
    return { state: halted, paid: [], skipped: [], halted: true };
  }
  if (state.halted) return out;
  if (report.blind) {
    out.state = { ...state, seen: {} };
    return out;
  }
  // the borrower index (chain events from the log endpoint) must be COMPLETE: while the scan is behind or failing the keeper pays nothing and its confirmations restart
  if ((report.indexBehindBlocks ?? 0) > 0 || report.indexError) {
    out.state = { ...state, seen: {} };
    out.skipped.push({ account: "*", reason: `the log scan is behind by ${report.indexBehindBlocks} blocks${report.indexError ? ` (${report.indexError.slice(0, 80)})` : ""}: no payment while the borrower index is incomplete` });
    return out;
  }
  const defaults = report.accounts.filter((a) => a.verdictCode === Verdict.DEFAULT_EXHAUSTED).sort((x, y) => (BigInt(y.debtUnits) > BigInt(x.debtUnits) ? 1 : -1));
  let st: KeeperState = { ...state, seen: updateConfirmations(state.seen, defaults.map((d) => d.account), report.blockNumber, report.blockTimestamp) };
  deps.persist(st);
  for (const d of defaults) {
    const key = d.account.toLowerCase();
    if (!isConfirmed(st.seen[key], cfg)) {
      const e = st.seen[key]!;
      out.skipped.push({ account: d.account, reason: `awaiting confirmation (${e.count}/${cfg.keeper.confirmEvaluations} evaluations, ${e.lastAt - e.firstAt}/${cfg.keeper.confirmSeconds} s)` });
      continue;
    }
    if ((st.cooldown[key] ?? 0) > (deps.now?.() ?? report.blockTimestamp)) {
      out.skipped.push({ account: d.account, reason: `cooling down after a failed attempt until ${st.cooldown[key]}` });
      continue;
    }
    try {
      st = { ...st, pending: { account: d.account, at: deps.now?.() ?? report.blockTimestamp } };
      deps.persist(st); // BEFORE the first transaction
      const r = await payOne(deps, st, d.account);
      st = { ...st, pending: null };
      if (r.kind === "paid") {
        st = { ...st, payments: [...st.payments, r.payment] };
        out.paid.push(r.payment);
        await alerts.clear(`keeper:blocked:${key}`, deps.now?.() ?? report.blockTimestamp);
      } else {
        out.skipped.push({ account: d.account, reason: r.reason });
        if (r.cost) st = { ...st, cooldown: { ...st.cooldown, [key]: (deps.now?.() ?? report.blockTimestamp) + RETRY_COOLDOWN_SECONDS } };
        await alerts.raise({ key: `keeper:blocked:${key}`, severity: "crit", message: `treasury keeper did NOT pay ${d.account}: ${r.reason}`, audience: "treasury-signers" }, deps.now?.() ?? report.blockTimestamp);
        if (r.halt) {
          st = { ...st, halted: { reason: r.reason, at: deps.now?.() ?? report.blockTimestamp } };
          await alerts.raise({ key: "keeper:halted", severity: "crit", message: `TREASURY KEEPER HALTED: ${r.reason}. No further payment until a human clears keeper.halted in the state file`, audience: "treasury-signers" }, deps.now?.() ?? report.blockTimestamp);
          deps.persist(st);
          out.halted = true;
          break;
        }
      }
    } catch (e) {
      // an unexpected error: if it happened after a send we cannot know the state: HALT (fail closed)
      const reason = `unexpected error while paying ${d.account}: ${safeError(e)}`;
      st = { ...st, halted: { reason, at: deps.now?.() ?? report.blockTimestamp } };
      deps.persist(st);
      await alerts.raise({ key: "keeper:halted", severity: "crit", message: `TREASURY KEEPER HALTED: ${reason}`, audience: "treasury-signers" }, deps.now?.() ?? report.blockTimestamp);
      out.halted = true;
      break;
    }
    deps.persist(st);
  }
  out.state = st;
  return out;
}

type PayResult = { kind: "paid"; payment: KeeperPayment } | { kind: "skip"; reason: string; halt?: boolean; cost?: boolean };

async function payOne(deps: KeeperDeps, st: KeeperState, account: string): Promise<PayResult> {
  const { ctx, signer, alerts } = deps;
  const { provider, cfg } = ctx;
  const nowS = (): number => deps.now?.() ?? Math.floor(Date.now() / 1000);
  const keeper = await signer.getAddress();
  if (keeper.toLowerCase() !== cfg.treasury.address.toLowerCase()) return { kind: "skip", reason: "signer address differs from the configured treasury address", halt: true };

  // 2. RE-VERIFICATION at the latest block, full rule, healthy reference
  const blk = await latestBlock(provider);
  if (nowS() - blk.timestamp > cfg.monitor.maxBlockLagSeconds && !deps.now) return { kind: "skip", reason: `latest block is ${nowS() - blk.timestamp}s old` };
  const snap = await readBlockSnapshot(ctx, blk.number);
  if (snap.reference.status !== "ok") return { kind: "skip", reason: `no healthy reference price at execution (${snap.reference.reason})` };
  const inputs = await readAccountInputs(ctx, snap, [account.toLowerCase()]);
  const fresh = evaluateRule(inputs.get(account.toLowerCase())!, { liquidationIncentive: snap.liquidationIncentive, dustUsd: BigInt(cfg.monitor.dustUsd1e18), toleranceBp: BigInt(cfg.reference.toleranceBp) });
  if (fresh.verdict !== Verdict.DEFAULT_EXHAUSTED) return { kind: "skip", reason: `re-verification at block ${blk.number} reads verdict ${fresh.verdict} instead of DEFAULT_EXHAUSTED (rule unchanged: no payment)` };
  const debt = fresh.debtUnits;

  // 3-5. budget, gas, fee
  const usdcBal: BigNumber = erc20.decodeFunctionResult("balanceOf", await provider.call({ to: USDC, data: erc20.encodeFunctionData("balanceOf", [keeper]) }))[0];
  // the daily cap uses the larger of the state ledger and the chain's own record of this wallet's repayments (the ledger file may have been lost)
  let onChain: { spent: bigint };
  try {
    onChain = await spentOnChain(ctx.logProvider ?? provider, cfg.deployment.pUsdc, keeper, nowS(), cfg.monitor.logs?.chunkBlocks ?? cfg.monitor.logChunkBlocks, cfg.deployment.deploymentBlock, 86_400, 0.8);
  } catch (e) {
    // the cap cannot be verified (typically an RPC plan that limits eth_getLogs ranges): FAIL CLOSED, no payment, a human is told why
    return { kind: "skip", reason: `the 24 h spend cannot be verified from the chain (eth_getLogs failed: ${safeError(e)}); no payment without a verifiable daily cap. The log endpoint (AVALANCHE_LOGS_RPC_URL, default the Avalanche public RPC) must allow eth_getLogs over the configured chunk` };
  }
  const spent24h = (() => { const a = spentInWindow(st.payments, nowS()); return a > onChain.spent ? a : onChain.spent; })();
  const budget = checkBudget({ debt, keeperUsdc: BigInt(usdcBal.toString()), spent24h, capUnits: BigInt(cfg.keeper.dailySpendCapUsdc) * 1_000_000n, marginBp: cfg.keeper.allowanceMarginBp });
  if (!budget.ok) return { kind: "skip", reason: budget.reason! };
  const gas = await provider.getBalance(keeper);
  if (gas.lt(cfg.keeper.minGasWei)) return { kind: "skip", reason: `keeper AVAX ${gas.toString()} wei is below the floor ${cfg.keeper.minGasWei}` };
  const fee = await provider.getFeeData();
  const maxFee = fee.maxFeePerGas ?? fee.gasPrice;
  if (!maxFee) return { kind: "skip", reason: "no fee data" };
  const capWei = utils.parseUnits(String(cfg.keeper.maxFeeGwei), "gwei");
  if (maxFee.gt(capWei)) return { kind: "skip", reason: `max fee ${utils.formatUnits(maxFee, "gwei")} gwei is above the cap ${cfg.keeper.maxFeeGwei} gwei` };
  let priority = fee.maxPriorityFeePerGas ?? utils.parseUnits("1", "gwei");
  if (priority.gt(maxFee)) priority = maxFee;
  const send = async (to: string, data: string, gasLimit: BigNumber): Promise<{ hash: string; blockNumber: number }> => {
    const tx: TxRequest = { to, data, gasLimit, maxFeePerGas: maxFee, maxPriorityFeePerGas: priority };
    const sent = await signer.sendTransaction(tx);
    const mined = await sent.wait();
    if (mined.status !== 1) throw new Error(`transaction ${sent.hash} reverted`);
    return { hash: sent.hash, blockNumber: mined.blockNumber };
  };
  const allowanceNow = async (): Promise<BigNumber> => erc20.decodeFunctionResult("allowance", await provider.call({ to: USDC, data: erc20.encodeFunctionData("allowance", [keeper, cfg.deployment.pUsdc]) }))[0];
  const approve = (amount: bigint) => send(USDC, erc20.encodeFunctionData("approve", [cfg.deployment.pUsdc, amount.toString()]), BigNumber.from(120_000));

  // exact-need allowance, then simulate, then the sentinel repay. Everything that can throw WITHOUT sending is prepared BEFORE the approval.
  // a standing allowance to the market before this payment means an earlier payment was interrupted (possibly with the state file lost): stop and let a human look
  if ((await allowanceNow()).gt(0)) return { kind: "skip", reason: "the keeper wallet already has a non-zero USDC allowance to pUSDC before this payment (an interrupted earlier payment?): check it, reset it to 0, then clear the halt", halt: true };
  const startBal = usdcBal;
  const repayData = pIface.encodeFunctionData("repayBorrowBehalf", [account, MAX_UINT]);
  await approve(budget.allowance);
  try {
    return await afterApproval();
  } catch (e) {
    try {
      await approve(0n);
    } catch {
      /* the halt tells a human to check the allowance */
    }
    return { kind: "skip", reason: `unexpected error after the approval: ${safeError(e)}; allowance reset attempted; check the keeper's allowance, balance and the account's debt`, halt: true, cost: true };
  }

  async function afterApproval(): Promise<PayResult> {
  if (!(await allowanceNow()).eq(budget.allowance.toString())) return { kind: "skip", reason: "allowance read-back differs from the approved amount", halt: true, cost: true };
  let gasLimit: BigNumber;
  try {
    const code = pIface.decodeFunctionResult("repayBorrowBehalf", await provider.call({ from: keeper, to: cfg.deployment.pUsdc, data: repayData }))[0] as BigNumber;
    if (!code.eq(0)) throw new Error(`simulation returned error code ${code.toString()}`);
    gasLimit = (await provider.estimateGas({ from: keeper, to: cfg.deployment.pUsdc, data: repayData })).mul(13).div(10);
  } catch (e) {
    await approve(0n); // do not leave an allowance behind
    return { kind: "skip", reason: `simulation of repayBorrowBehalf failed: ${safeError(e)} (allowance reset to 0)`, cost: true };
  }
  let sent: { hash: string; blockNumber: number };
  try {
    sent = await send(cfg.deployment.pUsdc, repayData, gasLimit);
  } catch (e) {
    try {
      await approve(0n);
    } catch {
      /* the halt below tells a human to check the allowance */
    }
    return { kind: "skip", reason: `repayBorrowBehalf failed after simulation passed: ${safeError(e)}; allowance reset attempted; check the keeper's allowance and balance`, halt: true };
  }
  // read-back: the RepayBorrow event, the debt, the balance, the allowance
  const receipt = await provider.getTransactionReceipt(sent.hash);
  const ev = receipt.logs.filter((l) => l.address.toLowerCase() === cfg.deployment.pUsdc.toLowerCase()).map((l) => { try { return pIface.parseLog(l); } catch { return undefined; } }).find((p) => p?.name === "RepayBorrow");
  const endBal: BigNumber = erc20.decodeFunctionResult("balanceOf", await provider.call({ to: USDC, data: erc20.encodeFunctionData("balanceOf", [keeper]) }, receipt.blockNumber))[0];
  const pulled = startBal.sub(endBal);
  const debtAfter: BigNumber = pIface.decodeFunctionResult("borrowBalanceStored", await provider.call({ to: cfg.deployment.pUsdc, data: pIface.encodeFunctionData("borrowBalanceStored", [account]) }, receipt.blockNumber))[0];
  const problems: string[] = [];
  if (!ev) problems.push("no RepayBorrow event in the receipt");
  else {
    if ((ev.args.borrower as string).toLowerCase() !== account.toLowerCase()) problems.push("RepayBorrow names a different borrower");
    if ((ev.args.payer as string).toLowerCase() !== keeper.toLowerCase()) problems.push("RepayBorrow payer is not the keeper");
    if (!(ev.args.repayAmount as BigNumber).eq(pulled)) problems.push(`event amount ${ev.args.repayAmount.toString()} differs from the balance delta ${pulled.toString()}`);
  }
  if (pulled.gt(budget.allowance.toString())) problems.push("pulled more than the allowance (impossible; stop)");
  if (pulled.lt(debt.toString())) problems.push(`pulled ${pulled.toString()} is below the debt read at decision ${debt}`);
  if (!debtAfter.eq(0)) problems.push(`debt after payment is ${debtAfter.toString()}, expected 0`);
  const left = await allowanceNow();
  if (left.gt(0)) {
    try {
      await approve(0n);
    } catch (e) {
      problems.push(`allowance reset failed: ${safeError(e)}`);
    }
  }
  const payment: KeeperPayment = { ts: nowS(), account, amountUsdc: pulled.toString(), debtAtDecision: debt.toString(), txHash: sent.hash, blockNumber: receipt.blockNumber };
  deps.persist({ ...st, payments: [...st.payments, payment] });
  await alerts.notify({ kind: "payment", key: `keeper:payment:${account.toLowerCase()}`, severity: problems.length ? "crit" : "warn", audience: "treasury-signers", text: `TREASURY KEEPER PAID ${account}: ${(Number(pulled.toString()) / 1e6).toFixed(6)} USDC (debt at decision ${(Number(debt) / 1e6).toFixed(6)}) in ${sent.hash} at block ${receipt.blockNumber}; keeper USDC left ${(Number(endBal.toString()) / 1e6).toFixed(6)}${problems.length ? `. READ-BACK PROBLEMS: ${problems.join("; ")}` : ". Read-back ok: debt 0, allowance 0"}` });
  if (problems.length) return { kind: "skip", reason: `payment ${sent.hash} mined but read-back failed: ${problems.join("; ")}`, halt: true };
  return { kind: "paid", payment };
  }
}

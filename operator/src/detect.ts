// THE DEFAULT-DETECTION RULE (treasury document section 2.1 / 2.3.1), as a pure function over data read at ONE block.
// Port of `TreasuryDefaultDetector.evaluate` (contracts/test/AvalancheCashOnlyTreasuryRepayFork.t.sol), same verdict numbers, same order of
// checks, same integer arithmetic (Solidity `/` truncates; all operands here are non-negative, so bigint `/` is identical).
//
// The rule fires (DEFAULT_EXHAUSTED, the ONLY verdict that leads to a payment) only if, for every market the account touches, both the
// oracle price P and the independent reference price R are non-zero and agree within TOL_BP, the controller reports no error, the account has
// debt and a shortfall, a FULL liquidation could not clear the debt (collUsd < debtUsd x LI), and what is left to seize is dust.
// Collateral is valued at max(P, R), debt at min(P, R): a wrong reference can only DELAY a payment, never cause one.
import { absDiff, E18, max, min } from "./bigmath";

export const Verdict = {
  NO_DEBT: 0,
  STALE_OR_ZERO_PRICE: 1,
  NO_REFERENCE_PRICE: 2,
  HEALTHY: 3,
  LIQUIDATABLE_RECOVERABLE: 4,
  UNRECOVERABLE_LIQUIDATE_FIRST: 5,
  DEFAULT_EXHAUSTED: 6,
  PRICE_DIVERGENCE: 7,
} as const;
export type VerdictCode = (typeof Verdict)[keyof typeof Verdict];
export const VERDICT_NAMES: Record<number, string> = Object.fromEntries(Object.entries(Verdict).map(([k, v]) => [v, k]));

export interface MarketAccountData {
  /** error code of `getAccountSnapshot` (non-zero = the market could not report) */
  snapshotErr: bigint;
  pTokenBalance: bigint;
  borrowBalance: bigint; // underlying units, after accrual
  exchangeRate: bigint; // 1e18
  /** oracle.getUnderlyingPrice(pToken): 0 when the guarded oracle returns the fail-closed value */
  oraclePrice: bigint;
  /** independent reference price in the SAME scale as the oracle price; 0 = missing */
  referencePrice: bigint;
}

export interface AccountInput {
  /** borrow balance of the debt market (pUSDC), after accrual; the rule's first test */
  debtUnits: bigint;
  /** all listed markets in `controller.getAllMarkets()` order */
  markets: MarketAccountData[];
  /** `controller.getAccountLiquidity(account)` read AFTER interest accrual in the same call */
  liquidityErr: bigint;
  shortfall: bigint;
}

export interface RuleParams {
  liquidationIncentive: bigint; // 1e18
  dustUsd: bigint; // 1e18
  toleranceBp: bigint;
}

export interface RuleResult {
  verdict: VerdictCode;
  debtUnits: bigint;
  debtUsd: bigint;
  collUsd: bigint;
  collUsdOracle: bigint;
  shortfallUsd: bigint;
  maxRecoveryUsd: bigint;
}

/** Test hook for mutation testing only: 1 = fire on shortfall alone, 3 = no divergence gate. `main` never passes it. */
export interface RuleTestHooks {
  mutation?: 0 | 1 | 3;
}

export function evaluateRule(input: AccountInput, params: RuleParams, hooks: RuleTestHooks = {}): RuleResult {
  const r: RuleResult = { verdict: Verdict.NO_DEBT, debtUnits: input.debtUnits, debtUsd: 0n, collUsd: 0n, collUsdOracle: 0n, shortfallUsd: 0n, maxRecoveryUsd: 0n };
  const mutation = hooks.mutation ?? 0;
  // 1. debt
  if (input.debtUnits === 0n) return r;
  // 2. conservative valuation with an independent reference price per market
  for (const m of input.markets) {
    if (m.snapshotErr !== 0n) return { ...r, verdict: Verdict.STALE_OR_ZERO_PRICE };
    if (m.pTokenBalance === 0n && m.borrowBalance === 0n) continue;
    const p = m.oraclePrice;
    if (p === 0n) return { ...r, verdict: Verdict.STALE_OR_ZERO_PRICE };
    const ref = m.referencePrice;
    if (ref === 0n) return { ...r, verdict: Verdict.NO_REFERENCE_PRICE };
    // oracle and reference must AGREE within the tolerance, else one of them is wrong and nothing is paid (mutation 3 removes this check)
    if (mutation !== 3 && absDiff(p, ref) * 10_000n > ref * params.toleranceBp) return { ...r, verdict: Verdict.PRICE_DIVERGENCE };
    if (m.borrowBalance > 0n) r.debtUsd += (m.borrowBalance * min(p, ref)) / E18; // lower price: harder to call the debt unrecoverable
    if (m.pTokenBalance > 0n) {
      const underlying = (m.pTokenBalance * m.exchangeRate) / E18;
      r.collUsd += (underlying * max(p, ref)) / E18; // higher price: harder to call the collateral exhausted
      r.collUsdOracle += (underlying * p) / E18;
    }
  }
  // 3. shortfall at oracle prices (an error code, e.g. 13 = price error, means: unknown, do not act)
  if (input.liquidityErr !== 0n) return { ...r, verdict: Verdict.STALE_OR_ZERO_PRICE };
  r.shortfallUsd = input.shortfall;
  if (input.shortfall === 0n) return { ...r, verdict: Verdict.HEALTHY };
  r.maxRecoveryUsd = (r.collUsd * E18) / params.liquidationIncentive;
  if (mutation === 1) return { ...r, verdict: Verdict.DEFAULT_EXHAUSTED }; // MUTATION 1: fire on shortfall alone
  // 4. a full liquidation clears the debt: C / LI >= D
  if (r.collUsd * E18 >= r.debtUsd * params.liquidationIncentive) return { ...r, verdict: Verdict.LIQUIDATABLE_RECOVERABLE };
  // 5. liquidation exhausted: what is left to seize is dust
  if (r.collUsd > params.dustUsd) return { ...r, verdict: Verdict.UNRECOVERABLE_LIQUIDATE_FIRST };
  return { ...r, verdict: Verdict.DEFAULT_EXHAUSTED };
}

/** Only this verdict leads to a treasury payment. Everything else is: alert, wait, or hand to the liquidators. */
export const isPayable = (v: VerdictCode): boolean => v === Verdict.DEFAULT_EXHAUSTED;

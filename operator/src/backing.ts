// "Unrecoverable debt" (operator definition, 2026-11-06; replaces the ambiguous "claims minus cash" alert of treasury document 5.3):
//
//     unrecoverable debt = sum over borrowers of  max(0, debtUsd - seizableCollateralUsd)  -  reserves
//
// with debtUsd the conservative debt value (lower of oracle and reference price), seizableCollateralUsd = collUsd / LI (what a liquidator
// repaying from this collateral can clear: the rule's "max recovery"), both from the SAME rule evaluation, and reserves = pUSDC totalReserves at
// the oracle's USDC price. The result is clipped at zero; the unclipped value is reported too. Accounts whose valuation is incomplete (stale or
// zero price, no reference, divergence) are not counted and make the figure INCOMPLETE (reported, never silently low).
import { E18 } from "./bigmath";
import { Verdict } from "./detect";
import type { RuleResult } from "./detect";

export interface BackingResult {
  /** sum of per-account shortfalls of recovery, before reserves (1e18 USD) */
  rawUsd: bigint;
  reservesUsd: bigint;
  /** max(0, raw - reserves) */
  unrecoverableUsd: bigint;
  /** false when at least one indebted account could not be valued */
  complete: boolean;
  accountsCounted: number;
}

const valued = (v: number): boolean =>
  v === Verdict.HEALTHY || v === Verdict.LIQUIDATABLE_RECOVERABLE || v === Verdict.UNRECOVERABLE_LIQUIDATE_FIRST || v === Verdict.DEFAULT_EXHAUSTED;

export function unrecoverableDebt(results: Iterable<RuleResult>, liquidationIncentive: bigint, reservesUsd: bigint): BackingResult {
  let raw = 0n;
  let complete = true;
  let counted = 0;
  for (const r of results) {
    if (r.verdict === Verdict.NO_DEBT) continue;
    if (!valued(r.verdict)) {
      complete = false;
      continue;
    }
    counted++;
    const seizable = (r.collUsd * E18) / liquidationIncentive;
    if (r.debtUsd > seizable) raw += r.debtUsd - seizable;
  }
  return { rawUsd: raw, reservesUsd, unrecoverableUsd: raw > reservesUsd ? raw - reservesUsd : 0n, complete, accountsCounted: counted };
}

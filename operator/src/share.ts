// VAULT-SHARE COLLATERAL (market bpPHAR-USDC: underlying = the share token of the DLMM USDC/USDt vault). PURE helpers, no chain access, no signer.
//
// Two different rules apply to an account whose collateral includes this market:
//   * LIQUIDATOR EXECUTOR: SEIZE-AND-KEEP. The operator repays USDC from its own inventory (bounded: close factor, what the collateral can pay for, its
//     inventory, a per-call cap, a rolling 24 h cap, and a ceiling on the value of the share pTokens it already holds) and KEEPS the seized pTokens.
//     There is no redeem and no swap: the shares have no independent exit price, so the operator never sells them in the pilot. Value received is
//     checked against value repaid (a break-even floor, net of the pToken's protocol seize share) BEFORE anything is sent.
//   * TREASURY KEEPER: ALERT-ONLY. It cannot price vault shares independently (its rule needs an independent reference price per market), so it NEVER repays
//     an account that holds this collateral; the alert says so and a human decides.
import type { BlockSnapshot } from "./chain";
import type { MonitorConfig } from "./config";
import type { AccountInput } from "./detect";

const E18 = 10n ** 18n;
/** break-even floor: value of the pTokens the liquidator receives / value repaid, in bp, at the oracle's prices. NOT configurable. */
export const SHARE_MIN_NET_VALUE_BPS = 10_000n;
/** a repayment cut to fit the borrower's pToken balance keeps this much room (bp) for interest accruing between the read and the block */
export const SHARE_FIT_MARGIN_BP = 10n;
/** the same 0.2% below the 1/LI limit as the pWAVAX path: 92.4% of the collateral's value */
export const COLLATERAL_REPAY_LIMIT_BP = 9_240n;

/** index of the share market in the snapshot's market list, or -1 (not configured, or not listed yet: the build runs before the listing) */
export function shareMarketIndex(snap: Pick<BlockSnapshot, "markets">, cfg: Pick<MonitorConfig, "shareCollateral">): number {
  const sc = cfg.shareCollateral;
  if (!sc) return -1;
  return snap.markets.findIndex((m) => m.pToken.toLowerCase() === sc.pToken.toLowerCase());
}

export function holdsShareCollateral(input: Pick<AccountInput, "markets"> | undefined, idx: number): boolean {
  return !!input && idx >= 0 && (input.markets[idx]?.pTokenBalance ?? 0n) > 0n;
}

/** oracle value, in USDC units, of `pTokens` of a market with the given exchange rate (1e18) and oracle prices of its underlying and of USDC */
export function pTokenValueUsdc(pTokens: bigint, exchangeRate: bigint, priceUnderlying: bigint, priceUsdc: bigint): bigint {
  if (priceUsdc === 0n) return 0n;
  return (((pTokens * exchangeRate) / E18) * priceUnderlying) / priceUsdc;
}

export type ShareBound = "close-factor" | "collateral" | "inventory" | "daily-cap" | "per-call-cap" | "held-value";
export interface SharePlan {
  repay: bigint;
  /** the binding bound (for the alert text) */
  bound: ShareBound;
  /** nothing to do: why */
  reason?: string;
}
export interface SharePlanArgs {
  debt: bigint;
  closeFactor: bigint; // 1e18
  liquidationIncentive: bigint; // 1e18
  /** oracle value in USDC units of the borrower's share pTokens */
  collateralUsdc: bigint;
  inventory: bigint;
  dailyCap: bigint;
  repaidToday: bigint;
  perCallCap: bigint;
  minRepay: bigint;
  /** oracle value in USDC units of the share pTokens THIS operator already holds, and the ceiling on it */
  heldValueUsdc: bigint;
  maxHeldValueUsdc: bigint;
}
/** The repayment of one share-collateral liquidation: the smallest of every bound. Below `minRepay` it does nothing. The allowance given to the market is exactly this amount. */
export function planShareRepay(a: SharePlanArgs): SharePlan {
  if (a.debt === 0n) return { repay: 0n, bound: "close-factor", reason: "no debt" };
  const dailyRemaining = a.dailyCap > a.repaidToday ? a.dailyCap - a.repaidToday : 0n;
  const heldHeadroom = a.maxHeldValueUsdc > a.heldValueUsdc ? a.maxHeldValueUsdc - a.heldValueUsdc : 0n;
  // the pTokens received are worth about repay x LI: the headroom bounds the repayment so that held value stays under the ceiling
  const heldBound = (heldHeadroom * E18) / a.liquidationIncentive;
  const bounds: Array<[ShareBound, bigint]> = [
    ["close-factor", (a.debt * a.closeFactor) / E18],
    ["collateral", (a.collateralUsdc * COLLATERAL_REPAY_LIMIT_BP) / 10_000n],
    ["inventory", a.inventory],
    ["daily-cap", dailyRemaining],
    ["per-call-cap", a.perCallCap],
    ["held-value", heldBound],
  ];
  let [bound, repay] = bounds[0]!;
  for (const [b, v] of bounds) if (v < repay) [bound, repay] = [b, v];
  if (repay === 0n || repay < a.minRepay) return { repay: 0n, bound, reason: `${bound} bound ${repay} is below the minimum repayment ${a.minRepay}` };
  return { repay, bound };
}

/** The controller's seize amount (`liquidateCalculateSeizeTokens`) must be covered by the borrower's pToken balance, or the seize reverts. Returns the repayment to retry with (0 = give up). */
export function fitRepayToSeize(a: { repay: bigint; seizeTokens: bigint; balance: bigint; minRepay: bigint }): bigint {
  if (a.seizeTokens <= a.balance) return a.repay;
  if (a.seizeTokens === 0n) return 0n;
  const fitted = (((a.repay * a.balance) / a.seizeTokens) * (10_000n - SHARE_FIT_MARGIN_BP)) / 10_000n;
  return fitted < a.minRepay ? 0n : fitted;
}

/** What the liquidator actually receives of `seizeTokens`: the market keeps `protocolSeizeShareMantissa` of them (exactly the market's integer arithmetic). */
export function liquidatorSeizeTokens(seizeTokens: bigint, protocolSeizeShareMantissa: bigint): bigint {
  return seizeTokens - (seizeTokens * protocolSeizeShareMantissa) / E18;
}

export interface NetSeize {
  liquidatorTokens: bigint;
  valueUsdc: bigint;
  ok: boolean;
}
/** Break-even floor for a collateral that will NOT be sold: the oracle value of what the operator receives must be at least the USDC it repays (net of the protocol seize share). */
export function checkNetSeizeValue(a: { repay: bigint; seizeTokens: bigint; protocolSeizeShareMantissa: bigint; exchangeRate: bigint; priceShare: bigint; priceUsdc: bigint }): NetSeize {
  const liquidatorTokens = liquidatorSeizeTokens(a.seizeTokens, a.protocolSeizeShareMantissa);
  const valueUsdc = pTokenValueUsdc(liquidatorTokens, a.exchangeRate, a.priceShare, a.priceUsdc);
  return { liquidatorTokens, valueUsdc, ok: a.priceShare > 0n && a.priceUsdc > 0n && valueUsdc * 10_000n >= a.repay * SHARE_MIN_NET_VALUE_BPS };
}

/** USDC repaid in the rolling window through the share route (rounds are tagged with the collateral pToken) */
export function shareRepaidInWindow(rounds: ReadonlyArray<{ ts: number; repay: string; collateralPToken?: string }>, pToken: string, now: number, windowSeconds = 86_400): bigint {
  let sum = 0n;
  for (const r of rounds) if (r.collateralPToken?.toLowerCase() === pToken.toLowerCase() && r.ts > now - windowSeconds) sum += BigInt(r.repay);
  return sum;
}

export type CollateralRoute = "wavax" | "share" | "none";
/**
 * Which collateral an account in shortfall is liquidated through, per round. Accounts without share collateral (or with the share route inactive) always
 * take the unchanged pWAVAX path. A mixed account takes pWAVAX when its WAVAX collateral alone can pay a full close-factor repayment (the sellable collateral
 * first); otherwise the route that clears MORE debt this round, with ties going to pWAVAX.
 */
export function chooseCollateralRoute(a: { debt: bigint; closeFactor: bigint; wavaxCollateralUsdc: bigint; wavaxRepay: bigint; shareRepay: bigint; shareActive: boolean }): CollateralRoute {
  if (!a.shareActive) return a.wavaxRepay > 0n ? "wavax" : "none";
  const wavaxSufficient = (a.wavaxCollateralUsdc * COLLATERAL_REPAY_LIMIT_BP) / 10_000n >= (a.debt * a.closeFactor) / E18;
  if (wavaxSufficient && a.wavaxRepay > 0n) return "wavax";
  if (a.shareRepay > 0n && a.shareRepay > a.wavaxRepay) return "share";
  return a.wavaxRepay > 0n ? "wavax" : "none";
}

/** The text the TREASURY KEEPER side shows for an account holding this collateral. */
export function shareAlertOnlyText(account: string, debtUnits: bigint, shortfall: boolean): string {
  return `account ${account} holds bpPHAR-USDC (DLMM vault-share) collateral and has ${(Number(debtUnits) / 1e6).toFixed(6)} USDC of pUSDC debt${shortfall ? " and is IN SHORTFALL" : ""}. ALERT-ONLY: the treasury keeper cannot price vault shares independently (no independent reference price), so it will NOT repay this account automatically; a funded liquidator may seize the shares (seize-and-keep). Any treasury repayment (repayBorrowBehalf) is a human decision`;
}

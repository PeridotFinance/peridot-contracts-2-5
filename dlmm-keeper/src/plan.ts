// THE SWAP SIZING, PURE (inventory + oracle price + vault parameters in, the rebalance arguments out). No chain access except through the injected `quote`.
//
// Target (README, "Target mix"): after the swap the inventory is EVEN BY ORACLE VALUE between the two legs. This is the plain reading of "even-value 3-bin mix":
// the new band is ids a-1, a, a+1 around the new active id a; a-1 holds only Y, a+1 holds only X (MEASURED on the live pair: bins below the active id hold only Y,
// bins above only X), and the active bin takes the rest; with V/3 of value in each bin and the active bin split 50/50 the TOTAL inventory is 50/50 by value.
// UNVERIFIED against the vault implementation (W2) which computes the distributions itself: if W2 targets a different mix, only `targetXShareBps` changes here.
//
// Inventory = the vault's band share (sum over band bins of balanceOf x reserve / totalSupply, rounded down, as the spec's NAV does) plus the vault's idle token balances.
//
//   over-held X (swap X for Y, rate r = out/in measured by the QUOTE):  (x - s) * pO = y + r * s      =>  s = (x*pO - y) / (pO + r)
//   over-held Y (swap Y for X):                                          (x + r * s) * pO = y - s      =>  s = (y - x*pO) / (1 + r*pO)
// pO = the oracle price of X in Y raw units (1e18 scaled), r from one quote at the first-order size s0 = half the imbalance. A second quote at s1 verifies the fill.
export const E18 = 10n ** 18n;
const U128 = 2n ** 128n;
export interface QuoteResult {
  amountInLeft: bigint;
  amountOut: bigint;
}
export type Quote = (swapXForY: boolean, amountIn: bigint) => Promise<QuoteResult>;

export interface PlanParams {
  /** inventory in raw token units */
  x: bigint;
  y: bigint;
  /** oracle price: raw Y per raw X, scaled 1e18 */
  oracle18: bigint;
  /** the vault's guardParams().maxSwapBps */
  maxSwapBps: number;
  /** effective loss bound = min(keeper config, the vault's maxRebalanceLossBps), in bps of the oracle-implied output */
  effLossBps: number;
  swapSlippageBps: number;
  addSlippageBps: number;
  quote: Quote;
}
export type PlanSkip = "empty" | "depth" | "quote-below-oracle" | "bad-input" | "swap-too-large";
export type Plan =
  | {
      ok: true;
      swapXForY: boolean;
      swapIn: bigint;
      swapMinOut: bigint;
      amountXMin: bigint;
      amountYMin: bigint;
      /** the quote at swapIn (0 when no swap) and the oracle-implied output */
      quoteOut: bigint;
      oracleOut: bigint;
      navY: bigint;
      /** swapIn was cut to the vault's maxSwapBps of NAV */
      capped: boolean;
      /** |x'*pO - y'| / NAV after the swap at the quoted output, in bps */
      residualImbalanceBps: number;
    }
  | { ok: false; code: PlanSkip; reason: string };

const ceilDiv = (a: bigint, b: bigint): bigint => (a + b - 1n) / b;
const bps = (v: bigint, b: number): bigint => (v * BigInt(10_000 - b)) / 10_000n;

export async function planSwap(p: PlanParams): Promise<Plan> {
  const { x, y, oracle18: pO } = p;
  if (x < 0n || y < 0n || pO <= 0n || p.maxSwapBps < 1 || p.maxSwapBps > 10_000) return { ok: false, code: "bad-input", reason: "negative inventory, non-positive oracle price or maxSwapBps outside 1..10000" };
  const valueX = (x * pO) / E18;
  const navY = valueX + y;
  if (navY === 0n) return { ok: false, code: "empty", reason: "the band and the idle balances are worth nothing" };
  const xForY = valueX > y;
  const diff = xForY ? valueX - y : y - valueX; // in Y units
  const noSwap = (): Plan => ({
    ok: true, swapXForY: false, swapIn: 0n, swapMinOut: 0n, quoteOut: 0n, oracleOut: 0n, navY, capped: false,
    amountXMin: bps(x, p.addSlippageBps), amountYMin: bps(y, p.addSlippageBps), residualImbalanceBps: Number((diff * 10_000n) / navY),
  });
  const s0 = xForY ? (diff * E18) / (2n * pO) : diff / 2n;
  if (s0 === 0n) return noSwap();
  if (s0 >= U128) return { ok: false, code: "bad-input", reason: "swap size does not fit uint128" };
  const q0 = await p.quote(xForY, s0);
  if (q0.amountInLeft > 0n) return { ok: false, code: "depth", reason: `the pair cannot fill the first-order size ${s0} (left ${q0.amountInLeft})` };
  if (q0.amountOut === 0n) return { ok: false, code: "depth", reason: "the quote returned no output" };
  const r18 = (q0.amountOut * E18) / s0; // out per in, 1e18 scaled (Y per X when xForY, X per Y otherwise)
  let s1 = xForY ? (diff * E18) / (pO + r18) : (diff * E18) / (E18 + (r18 * pO) / E18);
  const maxValue = (((navY * BigInt(p.maxSwapBps)) / 10_000n) * 99n) / 100n; // 1 % margin under the vault's SwapTooLarge bound
  const valueOf = (s: bigint): bigint => (xForY ? (s * pO) / E18 : s);
  let capped = false;
  if (valueOf(s1) > maxValue) {
    s1 = xForY ? (maxValue * E18) / pO : maxValue;
    capped = true;
  }
  const inv = xForY ? x : y;
  if (s1 > inv) s1 = inv;
  if (s1 === 0n) return noSwap();
  const q1 = await p.quote(xForY, s1);
  if (q1.amountInLeft > 0n) return { ok: false, code: "depth", reason: `the pair cannot fill ${s1} (left ${q1.amountInLeft})` };
  const oracleOut = xForY ? (s1 * pO) / E18 : (s1 * E18) / pO;
  const oracleFloor = ceilDiv(oracleOut * BigInt(10_000 - p.effLossBps), 10_000n);
  if (q1.amountOut < oracleFloor) return { ok: false, code: "quote-below-oracle", reason: `the pair pays ${q1.amountOut} for ${s1}, below the oracle floor ${oracleFloor} (oracle-implied ${oracleOut}, tolerance ${p.effLossBps} bp)` };
  const quoteFloor = (q1.amountOut * BigInt(10_000 - p.swapSlippageBps)) / 10_000n;
  const swapMinOut = quoteFloor > oracleFloor ? quoteFloor : oracleFloor;
  // inventory after the swap: worst case at swapMinOut for the amount minimums, quoted output for the residual
  const xWorst = xForY ? x - s1 : x + swapMinOut;
  const yWorst = xForY ? y + swapMinOut : y - s1;
  const xq = xForY ? x - s1 : x + q1.amountOut;
  const yq = xForY ? y + q1.amountOut : y - s1;
  const vxq = (xq * pO) / E18;
  const resid = vxq > yq ? vxq - yq : yq - vxq;
  return {
    ok: true, swapXForY: xForY, swapIn: s1, swapMinOut, quoteOut: q1.amountOut, oracleOut, navY, capped,
    amountXMin: bps(xWorst, p.addSlippageBps), amountYMin: bps(yWorst, p.addSlippageBps), residualImbalanceBps: Number((resid * 10_000n) / navY),
  };
}

// ---------------------------------------------------------------- openBand
export interface OpenBandParams extends Omit<PlanParams, "x" | "y"> {
  /** the vault's idle balances (no band yet), raw units, by the pair's X / Y */
  x: bigint;
  y: bigint;
  /** true when the vault's asset (USDC) is the pair's token X */
  assetIsX: boolean;
}
/**
 * openBand has NO swapIn parameter: the vault sizes its own swap from its idle balances (PharaohDlmmVault.openBand, read on 16 Nov 2026):
 *   pv = the pair-token balance valued in asset units at the ORACLE; if asset > pv + 1: swap (asset - pv) / 2 of the asset;
 *   else if pv > asset + 1: swap min(assetToPair((pv - asset) / 2), pair balance) of the pair token; the swap obeys SwapTooLarge (value <= maxSwapBps of NAV) and the oracle floor.
 * The keeper mirrors that EXACTLY (same formula, same oracle price) to learn the swap the vault will make, quotes it, and returns the arguments the vault does take:
 * swapMinOut (>= quote x (1 - slippage) and >= the oracle floor) and amountXMin / amountYMin (the worst-case inventory after the swap, x (1 - add slippage)).
 * `swapIn` in the result is what the VAULT will swap (informational, not sent). Rounding differs from the vault by a few wei at most; swapMinOut sits well above that.
 */
export async function planOpenBand(p: OpenBandParams): Promise<Plan> {
  const { x, y, oracle18: pO, assetIsX } = p;
  if (x < 0n || y < 0n || pO <= 0n || p.maxSwapBps < 1 || p.maxSwapBps > 10_000) return { ok: false, code: "bad-input", reason: "negative inventory, non-positive oracle price or maxSwapBps outside 1..10000" };
  const aAmt = assetIsX ? x : y;
  const pAmt = assetIsX ? y : x;
  const pairToAsset = (a: bigint): bigint => (assetIsX ? (a * E18) / pO : (a * pO) / E18);
  const assetToPair = (a: bigint): bigint => (assetIsX ? (a * pO) / E18 : (a * E18) / pO);
  const pv = pairToAsset(pAmt);
  const nav = aAmt + pv;
  if (nav === 0n) return { ok: false, code: "empty", reason: "the vault holds no idle assets: nothing to open a band with" };
  let swapAsset: boolean | undefined;
  let s = 0n;
  if (aAmt > pv + 1n) {
    swapAsset = true;
    s = (aAmt - pv) / 2n;
  } else if (pv > aAmt + 1n) {
    swapAsset = false;
    const want = assetToPair((pv - aAmt) / 2n);
    s = want < pAmt ? want : pAmt;
  }
  const noSwap = (): Plan => ({ ok: true, swapXForY: false, swapIn: 0n, swapMinOut: 0n, quoteOut: 0n, oracleOut: 0n, navY: nav, capped: false, amountXMin: bps(x, p.addSlippageBps), amountYMin: bps(y, p.addSlippageBps), residualImbalanceBps: 0 });
  if (swapAsset === undefined || s === 0n) return noSwap();
  if (s >= U128) return { ok: false, code: "bad-input", reason: "swap size does not fit uint128" };
  const inValue = swapAsset ? s : pairToAsset(s);
  const maxIn = (nav * BigInt(p.maxSwapBps)) / 10_000n;
  if (inValue > maxIn) return { ok: false, code: "swap-too-large", reason: `the vault would swap ${inValue} (asset units) which exceeds maxSwapBps of NAV (${maxIn}): openBand would revert SwapTooLarge` };
  const xForY = swapAsset ? assetIsX : !assetIsX;
  const q = await p.quote(xForY, s);
  if (q.amountInLeft > 0n) return { ok: false, code: "depth", reason: `the pair cannot fill ${s} (left ${q.amountInLeft})` };
  const oracleOut = swapAsset ? assetToPair(s) : pairToAsset(s);
  const oracleFloor = ceilDiv(oracleOut * BigInt(10_000 - p.effLossBps), 10_000n);
  if (q.amountOut < oracleFloor) return { ok: false, code: "quote-below-oracle", reason: `the pair pays ${q.amountOut} for ${s}, below the oracle floor ${oracleFloor} (oracle-implied ${oracleOut}, tolerance ${p.effLossBps} bp)` };
  const quoteFloor = (q.amountOut * BigInt(10_000 - p.swapSlippageBps)) / 10_000n;
  const swapMinOut = quoteFloor > oracleFloor ? quoteFloor : oracleFloor;
  const xWorst = xForY ? x - s : x + swapMinOut;
  const yWorst = xForY ? y + swapMinOut : y - s;
  const xq = xForY ? x - s : x + q.amountOut;
  const yq = xForY ? y + q.amountOut : y - s;
  const vxq = (xq * pO) / E18;
  const resid = vxq > yq ? vxq - yq : yq - vxq;
  return { ok: true, swapXForY: xForY, swapIn: s, swapMinOut, quoteOut: q.amountOut, oracleOut, navY: (x * pO) / E18 + y, capped: false, amountXMin: bps(xWorst, p.addSlippageBps), amountYMin: bps(yWorst, p.addSlippageBps), residualImbalanceBps: Number((resid * 10_000n) / ((x * pO) / E18 + y || 1n)) };
}

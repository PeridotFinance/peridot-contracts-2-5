// Pure helpers for the pool-liquidity floor of the reference price (operator decision of 2026-11-06): the floor is 50% of the pool's
// trailing 7-day median IN-RANGE liquidity (`pool.liquidity()`), computed ONCE at deployment and recorded with its source block range.
export const FLOOR_NUMERATOR = 1n;
export const FLOOR_DENOMINATOR = 2n;

/** Median of bigint samples; for an even count the floor of the mean of the two middle values. */
export function medianBig(values: bigint[]): bigint {
  if (values.length === 0) throw new Error("median of nothing");
  const v = [...values].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  const m = v.length >> 1;
  return v.length % 2 === 1 ? v[m]! : (v[m - 1]! + v[m]!) / 2n;
}
export function floorFromMedian(median: bigint): bigint {
  return (median * FLOOR_NUMERATOR) / FLOOR_DENOMINATOR;
}
/** Block numbers spaced `stepSeconds` apart going back from `toBlock`, oldest first, given the measured seconds per block. */
export function sampleBlocks(toBlock: number, days: number, stepSeconds: number, secondsPerBlock: number): number[] {
  const n = Math.floor((days * 86_400) / stepSeconds);
  const out: number[] = [];
  for (let i = n; i >= 0; i--) out.push(Math.max(1, toBlock - Math.round((i * stepSeconds) / secondsPerBlock)));
  return out;
}

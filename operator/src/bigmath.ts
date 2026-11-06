// Integer helpers. All monetary and price arithmetic in the monitor is bigint, never floating point.
export const E18 = 10n ** 18n;
export const Q192 = 1n << 192n;

export function absDiff(a: bigint, b: bigint): bigint {
  return a > b ? a - b : b - a;
}
export function min(a: bigint, b: bigint): bigint {
  return a < b ? a : b;
}
export function max(a: bigint, b: bigint): bigint {
  return a > b ? a : b;
}
/** Division rounding toward minus infinity (Solidity's `/` truncates toward zero; Uniswap's OracleLibrary floors negative non-multiples). */
export function floorDiv(a: bigint, b: bigint): bigint {
  if (b <= 0n) throw new Error("floorDiv: divisor must be positive");
  const q = a / b;
  return a % b !== 0n && a < 0n ? q - 1n : q;
}

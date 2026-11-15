// THE KEEPER'S OWN, INDEPENDENT ORACLE CHECKS (pure). The vault has its own guard (bits 1,2,4,8 latched, 16 live); this is a second look that is computed
// by the keeper from the two Chainlink feeds directly (NOT from guardState bit 16) and compared with the pool's own price at the active bin, with the keeper's own
// (tighter) thresholds from its configuration. A problem here is never a latch and never a halt: nothing is sent this attempt, a human is warned, backoff.
import { E18 } from "./plan";

export interface FeedReading {
  roundId: bigint;
  answer: bigint;
  updatedAt: number;
  answeredInRound: bigint;
  decimals: number;
}
const pow10 = (n: number): bigint => 10n ** BigInt(n);

/**
 * Oracle price of X in Y in RAW units, scaled 1e18: (usdX / usdY) * 10^decY / 10^decX, where usdX = ansX / 10^feedDecX etc.
 * feedX is the USD feed of token X, feedY of token Y.
 */
export function oraclePrice18(feedX: FeedReading, feedY: FeedReading, tokenDecX: number, tokenDecY: number): bigint {
  if (feedX.answer <= 0n || feedY.answer <= 0n) throw new Error("oracle answer is not positive");
  return (feedX.answer * pow10(feedY.decimals) * pow10(tokenDecY) * E18) / (feedY.answer * pow10(feedX.decimals) * pow10(tokenDecX));
}
/** the pool's price at an id (128.128 fixed point, raw Y per raw X) as 1e18 scaled */
export const pool18 = (price128: bigint): bigint => (price128 * E18) >> 128n;

export function legBandBpsOf(f: FeedReading): number {
  const one = pow10(f.decimals);
  const d = f.answer > one ? f.answer - one : one - f.answer;
  return Number((d * 10_000n) / one);
}

export interface SanityInput {
  feedX: FeedReading;
  feedY: FeedReading;
  chainNow: number;
  /** the vault's guardParams().maxFeedAge and legBandBps; the effective values are the stricter of these and the keeper's own */
  maxFeedAge: number;
  legBandBps: number;
  keeperLegBandBps: number;
  poolPrice128: bigint;
  tokenDecX: number;
  tokenDecY: number;
  maxPoolOracleDevBps: number;
  vaultMaxPoolOracleDevBps: number;
}
export interface SanityResult {
  problems: string[];
  oracle18?: bigint;
  poolDevBps?: number;
}
export function checkOracle(i: SanityInput): SanityResult {
  const problems: string[] = [];
  const feeds: Array<[string, FeedReading]> = [["feedX", i.feedX], ["feedY", i.feedY]];
  const legBand = Math.min(i.legBandBps, i.keeperLegBandBps);
  for (const [n, f] of feeds) {
    if (f.answer <= 0n) problems.push(`${n}: non-positive answer`);
    if (f.updatedAt <= 0 || f.answeredInRound < f.roundId) problems.push(`${n}: round incomplete`);
    else if (i.chainNow - f.updatedAt > i.maxFeedAge) problems.push(`${n}: stale (${i.chainNow - f.updatedAt} s old, limit ${i.maxFeedAge} s)`);
    if (f.answer > 0n && legBandBpsOf(f) > legBand) problems.push(`${n}: ${legBandBpsOf(f)} bp from 1.00 USD (limit ${legBand} bp)`);
  }
  if (problems.length) return { problems };
  const oracle18 = oraclePrice18(i.feedX, i.feedY, i.tokenDecX, i.tokenDecY);
  const p18 = pool18(i.poolPrice128);
  const dev = p18 > oracle18 ? p18 - oracle18 : oracle18 - p18;
  const devBps = Number((dev * 10_000n) / oracle18);
  const limit = Math.min(i.maxPoolOracleDevBps, i.vaultMaxPoolOracleDevBps);
  if (devBps > limit) problems.push(`pool price differs from the oracle ratio by ${devBps} bp (limit ${limit} bp)`);
  return { problems, oracle18, poolDevBps: devBps };
}

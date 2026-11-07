// Reference price for WAVAX: Uniswap V3 WAVAX/USDC 0.05% 30-minute TWAP (treasury document 2.3.1). Monitor-side only.
// The pool read ITSELF happens inside the block snapshot multicall (same block as every oracle and controller read, so "the reference and
// the oracle were read at different blocks" cannot occur). This module holds the pure parts: turning raw results into a verdict-ready
// reference, with the fail-closed reasons of the specification.
import { providers, utils } from "ethers";
import { UNIV3_FACTORY, UNIV3_FEE, UNIV3_POOL_WAVAX_USDC_500, TWAP_WINDOW_SECONDS, USDC, WAVAX } from "./constants";
import { UNIV3_FACTORY_ABI, UNIV3_POOL_ABI } from "./abi";
import type { CallResult } from "./multicall";
import { meanTick, wavaxReferenceFromTick } from "./tickmath";

export type ReferenceResult =
  | { status: "ok"; wavaxReference: bigint; tick: number; poolLiquidity: bigint }
  | { status: "none"; reason: string };

export const poolIface = new utils.Interface(UNIV3_POOL_ABI);
export const factoryIface = new utils.Interface(UNIV3_FACTORY_ABI);
export const OBSERVE_SECONDS_AGO = [TWAP_WINDOW_SECONDS, 0];

/**
 * Fail-closed interpretation. `pool*` come from the block's multicall (liquidity, observe); `poolIdentityOk` is the result of the
 * start-up / daily factory check; `usdcOraclePrice` is the oracle's own USDC price (R_usdc := P_usdc; a USDC de-peg is NOT covered).
 */
export function interpretReference(args: {
  poolIdentityOk: boolean;
  liquidity: CallResult | undefined;
  observe: CallResult | undefined;
  minPoolLiquidity: bigint;
  usdcOraclePrice: bigint;
}): ReferenceResult {
  if (!args.poolIdentityOk) return { status: "none", reason: "pool identity not confirmed against the factory (getPool(WAVAX, USDC, 500))" };
  if (args.usdcOraclePrice === 0n) return { status: "none", reason: "USDC oracle price is zero, WAVAX reference cannot be converted to USD" };
  const liq = args.liquidity;
  if (!liq || !liq.success || !liq.value) return { status: "none", reason: "pool liquidity() call failed" };
  const poolLiquidity = BigInt(liq.value[0].toString());
  if (poolLiquidity < args.minPoolLiquidity) return { status: "none", reason: `pool liquidity ${poolLiquidity} below the configured floor ${args.minPoolLiquidity}` };
  const obs = args.observe;
  if (!obs || !obs.success || !obs.value) return { status: "none", reason: "pool observe() reverted or failed (history shorter than the window?)" };
  const cum = obs.value[0] as unknown as Array<{ toString(): string }>;
  if (!Array.isArray(cum) || cum.length !== 2) return { status: "none", reason: "pool observe() returned a malformed result" };
  const c0 = BigInt(cum[0]!.toString());
  const c1 = BigInt(cum[1]!.toString());
  const tick = meanTick(c0, c1, TWAP_WINDOW_SECONDS);
  let ref: bigint;
  try {
    ref = wavaxReferenceFromTick(tick, args.usdcOraclePrice);
  } catch {
    return { status: "none", reason: "derived tick out of range" };
  }
  if (ref === 0n) return { status: "none", reason: "derived reference price is zero" };
  return { status: "ok", wavaxReference: ref, tick, poolLiquidity };
}

/** Start-up and daily check of the pool identity (not part of the per-block multicall). Returns an error text or null when confirmed. */
export async function checkPoolIdentity(provider: providers.Provider, factory: string = UNIV3_FACTORY, pool: string = UNIV3_POOL_WAVAX_USDC_500): Promise<string | null> {
  try {
    const fac = new utils.Interface(UNIV3_FACTORY_ABI);
    const out = await provider.call({ to: factory, data: fac.encodeFunctionData("getPool", [WAVAX, USDC, UNIV3_FEE]) });
    const derived = fac.decodeFunctionResult("getPool", out)[0] as string;
    if (derived.toLowerCase() !== pool.toLowerCase()) return `factory returns a different pool for (WAVAX, USDC, ${UNIV3_FEE})`;
    const t0 = poolIface.decodeFunctionResult("token0", await provider.call({ to: pool, data: poolIface.encodeFunctionData("token0") }))[0] as string;
    const t1 = poolIface.decodeFunctionResult("token1", await provider.call({ to: pool, data: poolIface.encodeFunctionData("token1") }))[0] as string;
    if (t0.toLowerCase() !== WAVAX.toLowerCase() || t1.toLowerCase() !== USDC.toLowerCase()) return "pool token0/token1 are not WAVAX/USDC";
    const fee = Number(poolIface.decodeFunctionResult("fee", await provider.call({ to: pool, data: poolIface.encodeFunctionData("fee") }))[0]);
    if (fee !== UNIV3_FEE) return `pool fee ${fee} is not ${UNIV3_FEE}`;
    return null;
  } catch (e) {
    return "pool identity check failed to run (RPC error)";
  }
}

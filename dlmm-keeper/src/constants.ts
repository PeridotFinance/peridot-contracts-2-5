// Chain facts and the hard floors of the keeper. The floors mirror the vault's frozen spec (docs/deployment-handoffs/avalanche-pharaoh-dlmm-vault-spec.md):
// the configuration may be stricter than these, never looser; config.ts refuses anything below / above.
export const CHAIN_ID = 43114;
/** Multicall3, the same address on every EVM chain it is deployed on (Avalanche C-Chain included) */
export const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11";
/** guardState().reasons bit flags (IPharaohDlmmVault.sol) */
export const BIT_FEED_ASSET = 1;
export const BIT_FEED_PAIR = 2;
export const BIT_ASSET_LEG = 4;
export const BIT_PAIR_LEG = 8;
export const BIT_POOL_ORACLE = 16;
export const BIT_REWARDER = 32;
/** bits 1,2,4,8: tripGuard() latches them; the keeper HALTS on any of them */
export const LATCHABLE_MASK = BIT_FEED_ASSET | BIT_FEED_PAIR | BIT_ASSET_LEG | BIT_PAIR_LEG;
/** bits 16,32: live only, never latched; the keeper waits and warns */
export const LIVE_MASK = BIT_POOL_ORACLE | BIT_REWARDER;
export const BIT_NAMES: Record<number, string> = {
  1: "FEED_ASSET_STALE_OR_BAD",
  2: "FEED_PAIR_STALE_OR_BAD",
  4: "ASSET_LEG_OUT_OF_BAND",
  8: "PAIR_LEG_OUT_OF_BAND",
  16: "POOL_ORACLE_DEVIATION",
  32: "REWARDER_UNLINKED_OR_CODEHASH_CHANGED",
};
export function bitNames(reasons: number): string {
  const n = Object.entries(BIT_NAMES).filter(([b]) => (reasons & Number(b)) !== 0).map(([, v]) => v);
  return n.length ? n.join("+") : "none";
}
/** hard floors / ceilings (spec section 5 and 6) */
export const MIN_EXIT_WAIT_SECONDS = 60;
export const MIN_COOLDOWN_SECONDS = 120;
export const MAX_SENDS_PER_DAY = 48;
export const MAX_DEADLINE_SECONDS = 120;
export const MAX_ID_SLIPPAGE = 2;
export const DAY = 86_400;

// Facts of Avalanche C-Chain that the keeper treats as fixed.
export const CHAIN_ID = 43114;
export const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11";
/** Measured Avalanche C-Chain block time (14-day measurement 0.936 s). */
export const BLOCK_SECONDS = 0.94;

// MarginOrderRegistry / IsolatedMarginTypes enums, as numbers
export const ORDER_STATUS = { NONE: 0, OPEN: 1, EXECUTED: 2, CANCELLED: 3, EXPIRED: 4 } as const;
export const POSITION_STATUS = { NONE: 0, OPENING: 1, ACTIVE: 2, CLOSING: 3, LIQUIDATING: 4, CLOSED: 5, LIQUIDATED: 6 } as const;
/** canExecute reason codes (docs/margin-orders/SPEC.md; 7 is the reference implementation's pause). */
export const REASON = { OK: 0, NOT_OPEN: 1, EXPIRED: 2, INACTIVE: 3, OWNER_CHANGED: 4, ORACLE: 5, TRIGGER: 6, PAUSED: 7 } as const;
export const REASON_NAMES: Record<number, string> = { 0: "executable", 1: "final", 2: "expired", 3: "position inactive", 4: "owner changed", 5: "oracle unavailable", 6: "trigger not reached", 7: "paused" };
// OrderCancelled reasons
export const CANCEL_REASON_NAMES: Record<number, string> = { 0: "owner", 1: "sibling executed", 2: "position inactive", 3: "owner changed" };
export const USDC = "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E";
export const WAVAX = "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7";

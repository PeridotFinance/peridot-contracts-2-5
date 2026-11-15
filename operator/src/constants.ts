// Facts of Avalanche C-Chain that the monitor treats as fixed (each re-checked on chain at start-up by the monitor, see monitor.ts).
export const CHAIN_ID = 43114;
export const WAVAX = "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7";
export const USDC = "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E";
export const AVAX_FEED = "0x0A77230d17318075983913bC2145DB16C7366156";
export const USDC_FEED = "0xF096872672F44d6EBA71458D74fe67F9a77a23B9";
export const UNIV3_FACTORY = "0x740b1c1de25031C31FF4fC9A62f554A55cdC1baD";
export const UNIV3_POOL_WAVAX_USDC_500 = "0xfAe3f424a0a47706811521E3ee268f00cFb5c45E";
export const UNIV3_FEE = 500;
export const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11";
/** The oracle guard limits that the pilot deployment uses (deploy script inputs AVAX_FEED_MAX_AGE / USDC_FEED_MAX_AGE). */
export const AVAX_GUARD_SECONDS = 1200;
export const USDC_GUARD_SECONDS = 90000;
export const TWAP_WINDOW_SECONDS = 1800;
export const LIQUIDATION_DUST_USD = 10n ** 16n; // USD 0.01 in 1e18
/** Uniswap V3 SwapRouter02 on Avalanche (cycle document section 1: factory() and WETH9() checked on chain) and the pool fee used for the conversion. */
export const UNIV3_SWAP_ROUTER02 = "0xbb00FF08d01D300023C629E8fFfFcb65A5a578cE";
/** Default LOG endpoint (public, no key): eth_getLogs up to 2,048 blocks per request. Override with the environment variable AVALANCHE_LOGS_RPC_URL (never in a file). */
export const DEFAULT_LOGS_RPC_URL = "https://api.avax.network/ext/bc/C/rpc";
/** Measured Avalanche C-Chain block time (14-day measurement 0.936 s); used for look-back windows. */
export const BLOCK_SECONDS = 0.94;

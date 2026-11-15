// Human-readable ABI fragments of exactly the calls the keeper makes. VAULT_ABI mirrors the FROZEN interface
// contracts/vault-dlmm/src/IPharaohDlmmVault.sol (test/abi.test.ts compares every fragment with the .sol file).
// PAIR_ABI is the Pharaoh DLMM LBPair (a Liquidity Book fork). MEASURED against the live pair 0x1688... on 15 Nov 2026 with read-only eth_calls:
//   getTokenX() = USDt, getTokenY() = USDC, getBinStep() = 1, getActiveId(), getBin(id) -> (reserveX, reserveY), totalSupply(id), balanceOf(account, id),
//   getPriceFromId(id) (128.128 fixed point, raw Y per raw X), getSwapOut(amountIn, swapForY) -> (amountInLeft, amountOut, fee).
// Bins above the active id hold only X and bins below only Y (MEASURED on the live pair: id+1 = X only, id-1 = Y only).
export const VAULT_ABI = [
  "function bandState() view returns (uint24 lowerId, uint24 upperId, uint24 activeId, bool hasBand, bool outOfRange)",
  "function guardState() view returns (bool unsafe, bool latched, uint256 reasons)",
  "function rebalanceAllowed() view returns (bool ok, uint256 reasonBits, uint256 readyAt)",
  "function guardParams() view returns (tuple(uint16 legBandBps, uint32 maxFeedAge, uint16 maxPoolOracleDevBps, uint32 rebalanceCooldown, uint16 maxRebalancesPerDay, uint16 maxSwapBps, uint16 maxRebalanceLossBps))",
  "function rebalancesToday() view returns (uint16)",
  "function lastRebalanceAt() view returns (uint48)",
  "function rebalance(uint24 expectedActiveId, uint24 idSlippage, bool swapXForY, uint256 swapIn, uint256 swapMinOut, uint256 amountXMin, uint256 amountYMin, uint256 deadline)",
  "function tripGuard()",
  "event Rebalanced(uint24 oldLowerId, uint24 oldUpperId, uint24 newLowerId, uint24 newUpperId, uint24 activeId, bool swapXForY, uint256 swapIn, uint256 swapOut, uint256 navBefore, uint256 navAfter)",
  "event GuardTripped(address indexed by, uint256 reasons)",
  "error CapExceeded(uint256 cap, uint256 totalAssetsAfter)",
  "error CapAboveCeiling(uint256 requested, uint256 ceiling)",
  "error GuardLatched()",
  "error GuardUnsafe(uint256 reasons)",
  "error NotOutOfRange(uint24 activeId, uint24 lowerId, uint24 upperId)",
  "error CooldownActive(uint256 readyAt)",
  "error DailyRebalanceCapReached()",
  "error SwapTooLarge(uint256 swapIn, uint256 maxIn)",
  "error NavLossTooLarge(uint256 navBefore, uint256 navAfter)",
  "error ActiveIdMoved(uint24 expected, uint24 actual, uint24 idSlippage)",
  "error GuardStillUnsafe(uint256 reasons)",
  "error ParamOutOfBounds()",
  "error PairValidationFailed(uint8 check)",
  "error NoBand()",
];
export const PAIR_ABI = [
  "function getActiveId() view returns (uint24)",
  "function getBin(uint24 id) view returns (uint128 binReserveX, uint128 binReserveY)",
  "function balanceOf(address account, uint256 id) view returns (uint256)",
  "function totalSupply(uint256 id) view returns (uint256)",
  "function getTokenX() view returns (address)",
  "function getTokenY() view returns (address)",
  "function getBinStep() view returns (uint16)",
  "function getPriceFromId(uint24 id) view returns (uint256)",
  "function getSwapOut(uint128 amountIn, bool swapForY) view returns (uint128 amountInLeft, uint128 amountOut, uint128 fee)",
];
export const FEED_ABI = [
  "function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
  "function decimals() view returns (uint8)",
];
export const ERC20_ABI = ["function balanceOf(address) view returns (uint256)", "function decimals() view returns (uint8)"];
export const MULTICALL3_ABI = [
  "function aggregate3(tuple(address target, bool allowFailure, bytes callData)[] calls) payable returns (tuple(bool success, bytes returnData)[] returnData)",
];

// The ONLY custodian functions the keeper knows. There is deliberately NO `unwind` here: the keeper can finalise, never cancel or remove.
// (A test asserts that this interface has no function that removes a band.)
import { utils } from "ethers";

export const CUSTODIAN_ABI = [
  "function finalize(uint256 positionId)",
  "function finalizable(uint256 positionId) view returns (uint8 activeRungs, uint8 readyRungs)",
  "function getOrder(uint256 positionId) view returns (tuple(address owner, address account, uint8 status, uint8 preset, uint8 rungCount, uint16 userFeeBps, uint16 protocolFeeBps, uint16 reserveFeeBps, uint64 createdAt, uint256 entryPriceX96, tuple(uint8 status, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 tokenId, uint256 collateralCommitted, uint256 collateralIdle, uint256 quoteExpected)[3] rungs))",
  "function executor() view returns (address)",
  "function activeOrders() view returns (uint256)",
  "event RangeOrderCreated(uint256 indexed positionId, address indexed owner, uint8 preset, uint8 rungCount, uint256 collateralCommitted, uint16 userFeeBps, uint16 protocolFeeBps, uint16 reserveFeeBps)",
  "event RangeOrderSettled(uint256 indexed positionId, uint256 repaid, uint256 remainingDebt, bool positionClosed)",
  "event RangeOrderUnwound(uint256 indexed positionId, address indexed by, uint256 repaid)",
  "error NotAdmin()",
  "error NotOwner()",
  "error NotAuthorized()",
  "error InvalidPreset()",
  "error InvalidFeeSplit()",
  "error PositionNotEligible(uint8 code)",
  "error OracleUnavailable()",
  "error PoolOracleDeviation(uint256 poolPriceX96, uint256 oraclePriceX96)",
  "error BandNotFullyConverted()",
  "error SlippageFloor(uint8 rung, uint256 quoteGot, uint256 quoteMin)",
  "error RangeTooSmall(uint8 rung)",
  "error WouldBeLiquidatable()",
  "error NoActiveOrder()",
  "error NotWired()",
  "error NothingClaimable()",
];
export const custodianIface = new utils.Interface(CUSTODIAN_ABI);

export const EXECUTOR_ABI = [
  "function nextPositionId() view returns (uint256)",
  "function positions(uint256) view returns (uint256 id, address owner, address account, address marginPToken, address positionPToken, address debtPToken, uint256 lockedMarginPTokens, uint256 initialNotionalUsd, uint256 borrowedPrincipal, uint16 requestedLeverageX100, uint8 side, uint8 status)",
];
export const executorIface = new utils.Interface(EXECUTOR_ABI);

/** Order and rung status (RangeTakeProfit.Status) and the executor's position status. */
export const Status = { NONE: 0, ACTIVE: 1, SETTLED: 2, UNWOUND: 3 } as const;
export const PositionStatus = { NONE: 0, OPENING: 1, ACTIVE: 2, CLOSING: 3, LIQUIDATING: 4, CLOSED: 5, LIQUIDATED: 6 } as const;

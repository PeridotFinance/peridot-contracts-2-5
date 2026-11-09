// Human-readable ABI fragments of exactly the calls and events the keeper uses. (The deployed ABIs are in docs/deployment-handoffs/avalanche-margin-abi;
// they are NOT read at run time, and a test checks that every function and event here exists in them.)
export const REGISTRY_ABI = [
  "function nextOrderId() view returns (uint256)",
  "function getOrder(uint256 orderId) view returns (tuple(uint256 positionId, address owner, uint8 kind, bool triggerAbove, uint256 triggerPriceE18, uint16 closeBps, uint16 maxSlippageBps, uint64 expiry, uint64 createdAt, uint64 updatedAt, uint8 status))",
  "function canExecute(uint256 orderId) view returns (bool executable, uint256 oraclePriceE18, uint8 reason)",
  "function executeOrder(uint256 orderId, bytes adapterData) returns (bool executed)",
  "function openOrdersOf(uint256 positionId) view returns (uint256[])",
  "function adapter() view returns (address)",
  "function paused() view returns (bool)",
  "event OrderCreated(uint256 indexed orderId, uint256 indexed positionId, address indexed owner, tuple(uint256 positionId, address owner, uint8 kind, bool triggerAbove, uint256 triggerPriceE18, uint16 closeBps, uint16 maxSlippageBps, uint64 expiry, uint64 createdAt, uint64 updatedAt, uint8 status) order)",
  "event OrderCancelled(uint256 indexed orderId, uint256 indexed positionId, uint8 reason)",
  "event OrderExpired(uint256 indexed orderId, uint256 indexed positionId)",
  "event OrderExecuted(uint256 indexed orderId, uint256 indexed positionId, address indexed executor, uint256 oraclePriceE18, uint16 closeBps, uint256 returnedMargin)",
  "error NotPositionOwner()",
  "error PositionNotActive()",
  "error InvalidOrder(uint8 code)",
  "error OrderNotOpen()",
  "error TriggerNotReached(uint256 oraclePriceE18, uint256 triggerPriceE18)",
  "error OracleUnavailable()",
  "error ExecutionPaused()",
];
export const ADAPTER_ABI = [
  "function registry() view returns (address)",
  "function executor() view returns (address)",
  "function isActive(uint256 positionId) view returns (bool)",
  "error NotRegistry()",
  "error AdapterDataNotSupported()",
  "error InvalidClose(uint8 code)",
];
export const SWAP_ERRORS_ABI = ["error SwapError(uint8 code)", "error InsufficientOutput()", "error InvalidSwap()", "error UnexpectedBalance()"];
export const EXECUTOR_ABI = [
  "function positions(uint256 positionId) view returns (uint256 id, address owner, address account, address marginPToken, address positionPToken, address debtPToken, uint256 lockedMarginPTokens, uint256 initialNotionalUsd, uint256 borrowedPrincipal, uint16 requestedLeverageX100, uint8 side, uint8 status)",
  "function orderExecutor() view returns (address)",
  "event PositionClosed(uint256 indexed positionId, uint16 closeBps, uint256 debtRepaid, uint256 returnedMarginPTokens, uint256 closingFeePTokens, uint256 healthFactorBps, bool fullyClosed)",
];
export const VAULT_ABI = ["function freeBalance(address user, address pToken) view returns (uint256)"];
export const ERC20_ABI = ["function balanceOf(address) view returns (uint256)"];
export const MULTICALL3_ABI = [
  "function aggregate3(tuple(address target, bool allowFailure, bytes callData)[] calls) payable returns (tuple(bool success, bytes returnData)[] returnData)",
];

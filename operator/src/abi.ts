// Minimal human-readable ABIs: ONLY views (and the market `accrueInterest`, which is called inside an eth_call and never sent).
export const CONTROLLER_ABI = [
  "function getAllMarkets() view returns (address[])",
  "function getAssetsIn(address) view returns (address[])",
  "function liquidateCalculateSeizeTokens(address pTokenBorrowed, address pTokenCollateral, uint256 actualRepayAmount) view returns (uint256 err, uint256 seizeTokens)",
  "function oracle() view returns (address)",
  "function admin() view returns (address)",
  "function pauseGuardian() view returns (address)",
  "function liquidationIncentiveMantissa() view returns (uint256)",
  "function closeFactorMantissa() view returns (uint256)",
  "function getAccountLiquidity(address) view returns (uint256 err, uint256 liquidity, uint256 shortfall)",
  "function borrowCaps(address) view returns (uint256)",
  "function borrowCashFloor(address) view returns (uint256)",
  "function mintGuardianPaused(address) view returns (bool)",
  "function borrowGuardianPaused(address) view returns (bool)",
  "function markets(address) view returns (bool isListed, uint256 collateralFactorMantissa, bool isPeridoted)",
  // isolated margin: the controller's own registry of margin accounts (the flag it uses to refuse liquidateBorrow/seize for them)
  "function isolatedMarginAccounts(address) view returns (bool)",
  "function isolatedMarginRiskHook() view returns (address)",
  "function isolatedMarginRegistrar() view returns (address)",
];
export const PTOKEN_ABI = [
  "function accrueInterest() returns (uint256)",
  "function repayBorrowBehalf(address borrower, uint256 repayAmount) returns (uint256)",
  "function borrowBalanceStored(address) view returns (uint256)",
  "function liquidateBorrow(address borrower, uint256 repayAmount, address pTokenCollateral) returns (uint256)",
  "function redeem(uint256 redeemTokens) returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function protocolSeizeShareMantissa() view returns (uint256)",
  "function underlying() view returns (address)",
  "function getAccountSnapshot(address) view returns (uint256 err, uint256 pTokenBalance, uint256 borrowBalance, uint256 exchangeRate)",
  "function exchangeRateStored() view returns (uint256)",
  "function getCash() view returns (uint256)",
  "function totalBorrows() view returns (uint256)",
  "function totalReserves() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function borrowIndex() view returns (uint256)",
  "function borrowAccountingEnabled() view returns (bool)",
  "function totalBorrowShares() view returns (uint256)",
  "function borrowShares(address) view returns (uint256)",
  "event Borrow(address borrower, uint256 borrowAmount, uint256 accountBorrows, uint256 totalBorrows)",
  "event RepayBorrow(address payer, address borrower, uint256 repayAmount, uint256 accountBorrows, uint256 totalBorrows)",
  "event LiquidateBorrow(address liquidator, address borrower, uint256 repayAmount, address pTokenCollateral, uint256 seizeTokens)",
];
export const ORACLE_ABI = ["function getUnderlyingPrice(address) view returns (uint256)"];
export const FEED_ABI = [
  "function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
  "function decimals() view returns (uint8)",
];
export const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function decimals() view returns (uint8)",
];
export const UNIV3_FACTORY_ABI = ["function getPool(address,address,uint24) view returns (address)"];
export const UNIV3_POOL_ABI = [
  "function observe(uint32[] secondsAgos) view returns (int56[] tickCumulatives, uint160[] secondsPerLiquidityCumulativeX128s)",
  "function liquidity() view returns (uint128)",
  "function token0() view returns (address)",
  "function token1() view returns (address)",
  "function fee() view returns (uint24)",
];
export const MULTICALL3_ABI = [
  "function aggregate3(tuple(address target, bool allowFailure, bytes callData)[] calls) payable returns (tuple(bool success, bytes returnData)[] returnData)",
  "function getBlockNumber() view returns (uint256)",
  "function getEthBalance(address) view returns (uint256)",
];
export const SAFE_ABI = ["function nonce() view returns (uint256)", "function getThreshold() view returns (uint256)", "function getOwners() view returns (address[])"];
export const SWAP_ROUTER02_ABI = [
  "function exactInputSingle(tuple(address tokenIn, address tokenOut, uint24 fee, address recipient, uint256 amountIn, uint256 amountOutMinimum, uint160 sqrtPriceLimitX96) params) payable returns (uint256 amountOut)",
];

// ---- isolated margin (read layer and the funded-liquidation step); the same signatures as docs/deployment-handoffs/avalanche-margin-abi/
export const MARGIN_EXECUTOR_ABI = [
  "function nextPositionId() view returns (uint256)",
  "function positions(uint256) view returns (uint256 id, address owner, address account, address marginPToken, address positionPToken, address debtPToken, uint256 lockedMarginPTokens, uint256 initialNotionalUsd, uint256 borrowedPrincipal, uint16 requestedLeverageX100, uint8 side, uint8 status)",
  "function riskEngine() view returns (address)",
];
export const MARGIN_RISK_ENGINE_ABI = [
  "function getMetrics(address) view returns (tuple(uint256 grossAssetValueUsd, uint256 debtValueUsd, int256 equityUsd, uint256 initialRequirementUsd, uint256 maintenanceRequirementUsd, uint256 healthFactorBps, uint256 leverageX100))",
  "function isLiquidatable(address) view returns (bool)",
  "function isIsolatedMarginAccount(address) view returns (bool)",
  "function config() view returns (address)",
];
export const MARGIN_LIQUIDATOR_ABI = [
  "function liquidateFunded(tuple(uint256 positionId, address recipient, uint256 maxRepayUnderlying, uint256 minPositionPTokens, uint256 minMarginPTokens, uint256 minSeizeValueBps) params)",
  "function config() view returns (address)",
  "function riskEngine() view returns (address)",
  "function executor() view returns (address)",
  "error LiquidationError(uint8 code)",
  "event FundedPositionLiquidated(uint256 indexed positionId, address indexed funder, address indexed recipient, uint256 debtRepaid, uint256 positionPTokensSeized, uint256 marginPTokensSeized, uint256 positionPTokensReturnedToOwner, uint256 marginPTokensReturnedToVault, uint256 lockedMarginReduction, bool fullyLiquidated)",
];
export const MARGIN_CONFIG_ABI = [
  "function fundedLiquidators(address) view returns (bool)",
  "function opensPaused() view returns (bool)",
  "function getPairRisk(address marginPToken, address positionPToken, address debtPToken) view returns (tuple(bool enabled, uint16 maxLeverageX100, uint16 initialMarginBps, uint16 maintenanceMarginBps, uint16 liquidationTargetBps, uint16 fullLiquidationHealthBps, uint16 maxLiquidationBps, uint16 liquidationBonusBps, uint16 maxSlippageBps, uint16 oracleDeviationBps, uint128 maxPositionValueUsd, uint128 maxDebtValueUsd))",
];

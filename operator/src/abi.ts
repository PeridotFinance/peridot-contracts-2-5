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

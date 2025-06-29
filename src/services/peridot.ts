import { ethers } from "ethers";

// Peridot pToken ABI (adapted from Compound cToken)
const PTOKEN_ABI = [
  "function mint(uint256 mintAmount) external returns (uint256)",
  "function redeem(uint256 redeemTokens) external returns (uint256)",
  "function redeemUnderlying(uint256 redeemAmount) external returns (uint256)",
  "function borrow(uint256 borrowAmount) external returns (uint256)",
  "function repayBorrow(uint256 repayAmount) external returns (uint256)",
  "function balanceOf(address owner) external view returns (uint256)",
  "function borrowBalanceStored(address account) external view returns (uint256)",
  "function exchangeRateStored() external view returns (uint256)",
  "function getAccountSnapshot(address account) external view returns (uint256, uint256, uint256, uint256)",
  "function getCash() external view returns (uint256)",
  "function totalBorrows() external view returns (uint256)",
  "function totalReserves() external view returns (uint256)",
  "function totalSupply() external view returns (uint256)",
  "function borrowRatePerBlock() external view returns (uint256)",
  "function supplyRatePerBlock() external view returns (uint256)",
];

const PERIDOTTROLLER_ABI = [
  "function enterMarkets(address[] calldata pTokens) external returns (uint256[] memory)",
  "function exitMarket(address pTokenAddress) external returns (uint256)",
  "function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256)",
  "function markets(address pTokenAddress) external view returns (bool, uint256)",
  "function getAllMarkets() external view returns (address[] memory)",
];

export class PeridotService {
  private provider: ethers.providers.JsonRpcProvider;
  private peridottrollerAddress: string;

  constructor(rpcUrl: string, peridottrollerAddress: string) {
    // Configure provider with network details for BSC Testnet
    this.provider = new ethers.providers.JsonRpcProvider(
      {
        url: rpcUrl,
        timeout: 30000, // 30 second timeout
      },
      {
        name: "bsc-testnet",
        chainId: 97,
      }
    );
    this.peridottrollerAddress = peridottrollerAddress;
  }

  async getMarketInfo(pTokenAddress: string) {
    try {
      const pToken = new ethers.Contract(
        pTokenAddress,
        PTOKEN_ABI,
        this.provider
      );

      const [
        cash,
        totalBorrows,
        totalReserves,
        totalSupply,
        exchangeRate,
        borrowRate,
        supplyRate,
      ] = await Promise.all([
        pToken.getCash(),
        pToken.totalBorrows(),
        pToken.totalReserves(),
        pToken.totalSupply(),
        pToken.exchangeRateStored(), // Use stored version - view only
        pToken.borrowRatePerBlock(),
        pToken.supplyRatePerBlock(),
      ]);

      return {
        cash: ethers.utils.formatEther(cash), // PUSD has 18 decimals (standard ERC20)
        totalBorrows: ethers.utils.formatEther(totalBorrows), // PUSD has 18 decimals
        totalReserves: ethers.utils.formatEther(totalReserves), // PUSD has 18 decimals
        totalSupply: ethers.utils.formatUnits(totalSupply, 8), // pToken decimals
        exchangeRate: ethers.utils.formatEther(exchangeRate), // Always 18 decimals (mantissa)
        borrowRatePerBlock: ethers.utils.formatUnits(borrowRate, 18),
        supplyRatePerBlock: ethers.utils.formatUnits(supplyRate, 18),
      };
    } catch (error) {
      throw new Error(`Failed to get market info: ${error}`);
    }
  }

  async getUserPosition(userAddress: string, pTokenAddress: string) {
    try {
      const pToken = new ethers.Contract(
        pTokenAddress,
        PTOKEN_ABI,
        this.provider
      );

      // Use getAccountSnapshot for efficient data retrieval
      // Returns: (error, pTokenBalance, borrowBalance, exchangeRateMantissa)
      // Note: error = 0 means SUCCESS in Compound V2
      const [error, pTokenBalance, borrowBalance, exchangeRateMantissa] =
        await pToken.getAccountSnapshot(userAddress);

      console.log(`getAccountSnapshot raw response:`, {
        error: error.toString(),
        errorType: typeof error,
        pTokenBalance: pTokenBalance.toString(),
        borrowBalance: borrowBalance.toString(),
        exchangeRateMantissa: exchangeRateMantissa.toString(),
      });

      const errorCode = typeof error === "number" ? error : error.toNumber();
      console.log(`Error code processed: ${errorCode}`);

      if (errorCode !== 0) {
        throw new Error(`getAccountSnapshot returned error code: ${errorCode}`);
      }

      // --- Major Assumption ---
      // Based on observed behavior, `getAccountSnapshot` for this market returns
      // the pToken balance in FULL TOKEN UNITS, not base units (wei).
      // This is non-standard but required for the math to work as expected.
      const pTokenBalanceFormatted = pTokenBalance.toString();

      // Borrows are still assumed to be in wei (standard)
      const borrowBalanceFormatted = ethers.utils.formatEther(borrowBalance);

      // Exchange rate is always scaled by 1e18 (mantissa)
      const exchangeRateFormatted =
        ethers.utils.formatEther(exchangeRateMantissa);

      // --- Calculation based on the assumption ---
      // Formula: underlyingTokens = pTokenTokens * (exchangeRateMantissa / 1e18)
      const underlyingBalanceRaw = pTokenBalance
        .mul(exchangeRateMantissa)
        .div(ethers.utils.parseEther("1"));

      // The result is already in full token units for the underlying asset.
      const underlyingBalance = underlyingBalanceRaw.toString();

      console.log(
        `Position calculation for ${userAddress} in ${pTokenAddress}:`,
        {
          pTokenBalanceRaw: pTokenBalance.toString(),
          exchangeRateRaw: exchangeRateMantissa.toString(),
          pTokenBalanceFormatted,
          exchangeRateFormatted,
          underlyingBalanceCalculated: underlyingBalance,
          underlyingBalanceRaw: underlyingBalanceRaw.toString(),
        }
      );

      return {
        pTokenBalance: pTokenBalanceFormatted,
        borrowBalance: borrowBalanceFormatted,
        underlyingBalance: underlyingBalance,
        exchangeRate: exchangeRateFormatted,
      };
    } catch (error) {
      throw new Error(`Failed to get user position: ${error}`);
    }
  }

  async getAccountLiquidity(userAddress: string) {
    try {
      const peridottroller = new ethers.Contract(
        this.peridottrollerAddress,
        PERIDOTTROLLER_ABI,
        this.provider
      );
      const [error, liquidity, shortfall] =
        await peridottroller.getAccountLiquidity(userAddress);

      // Based on on-chain tests, this contract returns liquidity as a raw integer
      // representing the dollar value, NOT a standard wei-formatted value.
      // Therefore, we just need to convert it to a string.
      return {
        error: error.toString(),
        liquidity: liquidity.toString(),
        shortfall: shortfall.toString(),
      };
    } catch (error) {
      throw new Error(`Failed to get account liquidity: ${error}`);
    }
  }

  async getAllMarkets(): Promise<string[]> {
    try {
      const peridottroller = new ethers.Contract(
        this.peridottrollerAddress,
        PERIDOTTROLLER_ABI,
        this.provider
      );

      return await peridottroller.getAllMarkets();
    } catch (error) {
      throw new Error(`Failed to get all markets: ${error}`);
    }
  }

  async getMarketStatus(pTokenAddress: string): Promise<{
    isListed: boolean;
    collateralFactorMantissa: string;
  }> {
    try {
      const peridottroller = new ethers.Contract(
        this.peridottrollerAddress,
        PERIDOTTROLLER_ABI,
        this.provider
      );

      const [isListed, collateralFactorMantissa] = await peridottroller.markets(
        pTokenAddress
      );

      return {
        isListed,
        collateralFactorMantissa: ethers.utils.formatEther(
          collateralFactorMantissa
        ),
      };
    } catch (error) {
      throw new Error(`Failed to get market status: ${error}`);
    }
  }

  // Calculate APY from per-block rates
  calculateAPY(ratePerBlock: string, blocksPerYear: number = 2102400): number {
    const rate = parseFloat(ratePerBlock);
    return (Math.pow(1 + rate, blocksPerYear) - 1) * 100;
  }

  // Get utilization rate
  async getUtilizationRate(pTokenAddress: string): Promise<number> {
    try {
      const info = await this.getMarketInfo(pTokenAddress);
      const totalBorrows = parseFloat(info.totalBorrows);
      const totalCash = parseFloat(info.cash);

      if (totalBorrows === 0) return 0;

      return (totalBorrows / (totalBorrows + totalCash)) * 100;
    } catch (error) {
      throw new Error(`Failed to calculate utilization rate: ${error}`);
    }
  }

  // Test network connectivity
  async testConnection(): Promise<boolean> {
    try {
      await this.provider.getNetwork();
      await this.provider.getBlockNumber();
      return true;
    } catch (error) {
      console.error("Peridot service network connection test failed:", error);
      return false;
    }
  }
}

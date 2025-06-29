import { ethers } from "ethers";

export class BlockchainService {
  private provider: ethers.providers.JsonRpcProvider;

  constructor(rpcUrl: string) {
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
  }

  async getBalance(address: string): Promise<string> {
    try {
      const balance = await this.provider.getBalance(address);
      return ethers.utils.formatEther(balance);
    } catch (error) {
      throw new Error(`Failed to get balance: ${error}`);
    }
  }

  async getBlockNumber(): Promise<number> {
    try {
      return await this.provider.getBlockNumber();
    } catch (error) {
      throw new Error(`Failed to get block number: ${error}`);
    }
  }

  async isValidAddress(address: string): Promise<boolean> {
    return ethers.utils.isAddress(address);
  }

  async getGasPrice(): Promise<string> {
    try {
      const gasPrice = await this.provider.getGasPrice();
      return ethers.utils.formatUnits(gasPrice, "gwei");
    } catch (error) {
      throw new Error(`Failed to get gas price: ${error}`);
    }
  }

  // Test network connectivity
  async testConnection(): Promise<boolean> {
    try {
      await this.provider.getNetwork();
      await this.provider.getBlockNumber();
      return true;
    } catch (error) {
      console.error("Network connection test failed:", error);
      return false;
    }
  }

  getProvider(): ethers.providers.JsonRpcProvider {
    return this.provider;
  }
}

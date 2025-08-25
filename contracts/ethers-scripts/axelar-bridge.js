#!/usr/bin/env node

/**
 * Axelar Token Bridge using AxelarJS SDK
 * This script uses the recommended deposit address method for token transfers
 *
 * Usage:
 *   node axelar-bridge.js \
     --token WBNB \
     --amount 0.1 \
     --recipient 0xF450B38cccFdcfAD2f98f7E4bB533151a2fB00E9
 */

const { ethers } = require("ethers");
const {
  AxelarAssetTransfer,
  AxelarQueryAPI,
  CHAINS,
  Environment,
} = require("@axelar-network/axelarjs-sdk");

// Configuration
const CONFIG = {
  // Use SDK chain constants for accurate identifiers
  get SOURCE_CHAIN() {
    return CHAINS.TESTNET.BINANCE || "binance";
  },
  SOURCE_RPC: "https://bsc-testnet.public.blastapi.io",

  // Arbitrum Sepolia
  get DEST_CHAIN() {
    return CHAINS.TESTNET.ARBITRUM || "arbitrum-sepolia";
  },
  DEST_CHAIN_ID: 421614,

  // Tokens (symbol -> denom mapping)
  TOKENS: {
    WBNB: "wbnb-wei",
    axlUSDC: "uausdc",
    BNB: "bnb-wei", // For wrapping native BNB
  },

  // Contract addresses on BNB Chain Testnet
  CONTRACTS: {
    WBNB: "0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd",
  },
};

class AxelarBridge {
  constructor() {
    this.sdk = new AxelarAssetTransfer({
      environment: Environment.TESTNET,
    });
    this.queryAPI = new AxelarQueryAPI({
      environment: Environment.TESTNET,
    });

    // Setup provider and wallet
    this.provider = new ethers.JsonRpcProvider(CONFIG.SOURCE_RPC);
    this.wallet = new ethers.Wallet(process.env.PRIVATE_KEY, this.provider);

    console.log("🚀 Axelar Bridge initialized");
    console.log(`📍 Source: ${CONFIG.SOURCE_CHAIN}`);
    console.log(`📍 Destination: ${CONFIG.DEST_CHAIN}`);
    console.log(`💳 Wallet: ${this.wallet.address}`);
  }

  /**
   * Debug: Show available chains
   */
  showAvailableChains() {
    console.log("\n🔍 Available Testnet Chains:");
    console.log("Source chains (EVM):", Object.keys(CHAINS.TESTNET));
    console.log("\n📋 Common chain identifiers:");
    console.log("- BNB Chain:", CHAINS.TESTNET.BINANCE || "binance");
    console.log("- Arbitrum:", CHAINS.TESTNET.ARBITRUM || "arbitrum");
    console.log("- Polygon:", CHAINS.TESTNET.POLYGON || "polygon");
    console.log("- Avalanche:", CHAINS.TESTNET.AVALANCHE || "avalanche");
  }

  /**
   * Get transfer fee estimate
   */
  async getTransferFee(tokenSymbol, amount) {
    console.log("\n💰 Estimating transfer fees...");

    const denom = CONFIG.TOKENS[tokenSymbol];
    if (!denom) {
      throw new Error(`Unsupported token: ${tokenSymbol}`);
    }

    try {
      const fee = await this.queryAPI.getTransferFee(
        CONFIG.SOURCE_CHAIN,
        CONFIG.DEST_CHAIN,
        denom,
        amount
      );

      console.log(`✅ Transfer fee: ${fee.fee.amount} ${fee.fee.denom}`);
      return fee;
    } catch (error) {
      console.error("❌ Failed to get transfer fee:", error.message);
      throw error;
    }
  }

  /**
   * Generate deposit address for token transfer
   */
  async generateDepositAddress(tokenSymbol, destinationAddress, amount) {
    console.log("\n🏦 Generating deposit address...");

    const denom = CONFIG.TOKENS[tokenSymbol];
    if (!denom) {
      throw new Error(`Unsupported token: ${tokenSymbol}`);
    }

    try {
      // Get transfer fee first
      const feeInfo = await this.getTransferFee(tokenSymbol, amount);

      // Generate deposit address
      const depositAddress = await this.sdk.getDepositAddress({
        fromChain: CONFIG.SOURCE_CHAIN,
        toChain: CONFIG.DEST_CHAIN,
        destinationAddress: destinationAddress,
        asset: denom,
        options: {
          shouldUnwrapIntoNative: tokenSymbol === "BNB", // Unwrap to native on destination
        },
      });

      console.log(`✅ Deposit address generated: ${depositAddress}`);
      console.log(
        `💡 Send ${tokenSymbol} to this address to initiate transfer`
      );
      console.log(
        `⚠️  Minimum amount: ${feeInfo.fee.amount} + transfer amount`
      );

      return {
        depositAddress,
        fee: feeInfo.fee,
        denom,
      };
    } catch (error) {
      console.error("❌ Failed to generate deposit address:", error.message);
      throw error;
    }
  }

  /**
   * Send WBNB tokens to deposit address
   */
  async sendWBNB(depositAddress, amount) {
    console.log("\n📤 Sending WBNB to deposit address...");

    // WBNB contract
    const wbnbAbi = [
      "function transfer(address to, uint256 amount) external returns (bool)",
      "function balanceOf(address owner) view returns (uint256)",
      "function decimals() view returns (uint8)",
    ];

    const wbnbContract = new ethers.Contract(
      CONFIG.CONTRACTS.WBNB,
      wbnbAbi,
      this.wallet
    );

    try {
      // Check balance
      const balance = await wbnbContract.balanceOf(this.wallet.address);
      const decimals = await wbnbContract.decimals();
      const amountWei = ethers.parseUnits(amount.toString(), decimals);

      console.log(
        `💰 WBNB Balance: ${ethers.formatUnits(balance, decimals)} WBNB`
      );
      console.log(`📤 Sending: ${amount} WBNB (${amountWei} wei)`);

      if (balance < amountWei) {
        throw new Error(
          `Insufficient WBNB balance. Need: ${amount}, Have: ${ethers.formatUnits(
            balance,
            decimals
          )}`
        );
      }

      // Send transaction
      const tx = await wbnbContract.transfer(depositAddress, amountWei);
      console.log(`📡 Transaction sent: ${tx.hash}`);

      // Wait for confirmation
      const receipt = await tx.wait();
      console.log(`✅ Transaction confirmed in block: ${receipt.blockNumber}`);
      console.log(
        `⏳ Cross-chain transfer initiated. Monitor on AxelarScan...`
      );

      return {
        txHash: tx.hash,
        blockNumber: receipt.blockNumber,
        amount: amountWei,
      };
    } catch (error) {
      console.error("❌ Failed to send WBNB:", error.message);
      throw error;
    }
  }

  /**
   * Send native BNB (will be wrapped automatically by Axelar)
   */
  async sendBNB(depositAddress, amount) {
    console.log("\n📤 Sending native BNB to deposit address...");

    try {
      // Check balance
      const balance = await this.provider.getBalance(this.wallet.address);
      const amountWei = ethers.parseEther(amount.toString());

      console.log(`💰 BNB Balance: ${ethers.formatEther(balance)} BNB`);
      console.log(`📤 Sending: ${amount} BNB (${amountWei} wei)`);

      if (balance < amountWei) {
        throw new Error(
          `Insufficient BNB balance. Need: ${amount}, Have: ${ethers.formatEther(
            balance
          )}`
        );
      }

      // Send transaction
      const tx = await this.wallet.sendTransaction({
        to: depositAddress,
        value: amountWei,
      });

      console.log(`📡 Transaction sent: ${tx.hash}`);

      // Wait for confirmation
      const receipt = await tx.wait();
      console.log(`✅ Transaction confirmed in block: ${receipt.blockNumber}`);
      console.log(
        `⏳ Cross-chain transfer initiated. Monitor on AxelarScan...`
      );

      return {
        txHash: tx.hash,
        blockNumber: receipt.blockNumber,
        amount: amountWei,
      };
    } catch (error) {
      console.error("❌ Failed to send BNB:", error.message);
      throw error;
    }
  }

  /**
   * Complete bridge process
   */
  async bridge(tokenSymbol, amount, destinationAddress) {
    console.log(
      `\n🌉 Starting bridge: ${amount} ${tokenSymbol} → ${CONFIG.DEST_CHAIN}`
    );
    console.log(`📍 Destination: ${destinationAddress}`);

    try {
      // Step 1: Generate deposit address
      const { depositAddress, fee } = await this.generateDepositAddress(
        tokenSymbol,
        destinationAddress,
        ethers.parseUnits(amount.toString(), 18) // Assuming 18 decimals
      );

      // Step 2: Send tokens to deposit address
      let result;
      if (tokenSymbol === "WBNB") {
        result = await this.sendWBNB(depositAddress, amount);
      } else if (tokenSymbol === "BNB") {
        result = await this.sendBNB(depositAddress, amount);
      } else {
        throw new Error(`Token ${tokenSymbol} not yet implemented`);
      }

      // Step 3: Provide monitoring info
      console.log("\n🎉 Bridge initiated successfully!");
      console.log(`📊 Transaction Hash: ${result.txHash}`);
      console.log(`🔍 Monitor progress:`);
      console.log(
        `   • AxelarScan: https://testnet.axelarscan.io/transfer/${result.txHash}`
      );
      console.log(
        `   • BNB Testnet: https://testnet.bscscan.com/tx/${result.txHash}`
      );
      console.log(`⏱️  Expected time: 1-20 minutes`);

      return result;
    } catch (error) {
      console.error("❌ Bridge failed:", error.message);
      throw error;
    }
  }
}

// CLI Interface
async function main() {
  const args = process.argv.slice(2);
  const getArg = (flag) => {
    const index = args.indexOf(flag);
    return index !== -1 ? args[index + 1] : null;
  };

  const token = getArg("--token") || "WBNB";
  const amount = parseFloat(getArg("--amount")) || 0.1;
  const recipient = getArg("--recipient");
  const showChains = args.includes("--debug-chains");

  // Debug mode - show available chains
  if (showChains) {
    const bridge = new AxelarBridge();
    bridge.showAvailableChains();
    process.exit(0);
  }

  if (!recipient) {
    console.error("❌ Error: --recipient address is required");
    console.log("\n📖 Usage:");
    console.log(
      "node scripts/axelar-bridge.js --token WBNB --amount 0.1 --recipient 0x123..."
    );
    console.log("\n📝 Supported tokens: WBNB, BNB");
    console.log("\n🔍 Debug available chains:");
    console.log("node scripts/axelar-bridge.js --debug-chains");
    process.exit(1);
  }

  if (!process.env.PRIVATE_KEY) {
    console.error("❌ Error: PRIVATE_KEY environment variable is required");
    process.exit(1);
  }

  try {
    const bridge = new AxelarBridge();
    await bridge.bridge(token, amount, recipient);
  } catch (error) {
    console.error("💥 Fatal error:", error.message);
    process.exit(1);
  }
}

// Handle unhandled promise rejections
process.on("unhandledRejection", (reason, promise) => {
  console.error("💥 Unhandled Rejection at:", promise, "reason:", reason);
  process.exit(1);
});

if (require.main === module) {
  main();
}

module.exports = { AxelarBridge, CONFIG };

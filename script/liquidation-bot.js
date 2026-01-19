require("dotenv").config();
const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

// ABI imports - using correct paths for Foundry output
const {
  abi: PeridottrollerABI,
} = require("../contracts/out/PeridottrollerG7Fixed.sol/PeridottrollerG7Fixed.json");
const { abi: PTokenABI } = require("../contracts/out/PToken.sol/PToken.json");

// --- Configuration ---
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const MONAD_TESTNET_RPC_URL = process.env.MONAD_TESTNET_RPC_URL;
const PERIDOTTROLLER_ADDRESS = process.env.PERIDOTTROLLER_ADDRESS;
const CHECK_INTERVAL_MINUTES = process.env.CHECK_INTERVAL_MINUTES || 2;
const MIN_PROFIT_THRESHOLD = process.env.MIN_PROFIT_THRESHOLD
  ? ethers.utils.parseEther(process.env.MIN_PROFIT_THRESHOLD.toString())
  : ethers.utils.parseEther("0.001"); // Minimum profit in ETH

// Contract deployment block on Monad Testnet
const DEPLOYMENT_BLOCK = 24321249;
const LAST_SCANNED_BLOCK = 26881487; // Last block we fully scanned

// Checkpoint file to save progress
const CHECKPOINT_FILE = path.join(__dirname, "liquidation-checkpoint.json");

// Global borrower cache to avoid re-scanning old blocks
let globalBorrowerCache = new Set();
let hasBootstrapped = false;
let lastScannedBlock = LAST_SCANNED_BLOCK;

const ERC20_ABI = [
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
  "function balanceOf(address) view returns (uint256)",
];

/**
 * Load checkpoint data from file
 */
function loadCheckpoint() {
  try {
    if (fs.existsSync(CHECKPOINT_FILE)) {
      const data = JSON.parse(fs.readFileSync(CHECKPOINT_FILE, "utf8"));
      lastScannedBlock = data.lastScannedBlock || LAST_SCANNED_BLOCK;
      hasBootstrapped = data.hasBootstrapped || false;

      if (data.borrowerCache && Array.isArray(data.borrowerCache)) {
        globalBorrowerCache = new Set(data.borrowerCache);
        console.log(
          `📋 Loaded ${globalBorrowerCache.size} borrowers from cache`
        );
      }

      console.log(
        `🔄 Resuming from block ${lastScannedBlock} (bootstrap: ${hasBootstrapped})`
      );
      return true;
    }
  } catch (error) {
    console.log(`Could not load checkpoint: ${error.message}`);
  }
  return false;
}

/**
 * Save checkpoint data to file
 */
function saveCheckpoint(currentBlock) {
  try {
    const data = {
      lastScannedBlock: currentBlock,
      hasBootstrapped: true,
      borrowerCache: Array.from(globalBorrowerCache),
      timestamp: new Date().toISOString(),
    };

    fs.writeFileSync(CHECKPOINT_FILE, JSON.stringify(data, null, 2));
    lastScannedBlock = currentBlock;
    console.log(
      `💾 Checkpoint saved: block ${currentBlock}, ${globalBorrowerCache.size} borrowers cached`
    );
  } catch (error) {
    console.error(`Failed to save checkpoint: ${error.message}`);
  }
}

// --- Helper Functions ---

/**
 * Get all markets from the Peridottroller
 */
async function getAllMarkets(peridottroller) {
  console.log("Getting all markets from Peridottroller...");
  const markets = await peridottroller.getAllMarkets();
  console.log(`Found ${markets.length} markets`);

  // Filter out WMON markets as requested by user
  const filteredMarkets = [];
  for (const marketAddress of markets) {
    const pToken = new ethers.Contract(
      marketAddress,
      PTokenABI,
      peridottroller.provider
    );
    try {
      const symbol = await pToken.symbol();
      if (!symbol.includes("WMON")) {
        filteredMarkets.push(marketAddress);
      } else {
        console.log(`Skipping WMON market: ${symbol} at ${marketAddress}`);
      }
    } catch (error) {
      // If we can't get the symbol, include it anyway
      filteredMarkets.push(marketAddress);
    }
  }

  console.log(
    `After filtering WMON: ${filteredMarkets.length} markets to scan`
  );
  return filteredMarkets;
}

/**
 * Get account liquidity for a user
 */
async function getAccountLiquidity(peridottroller, account) {
  try {
    const [error, liquidity, shortfall] =
      await peridottroller.getAccountLiquidity(account);

    // Handle Compound protocol error codes (0 = success)
    if (error.toNumber() !== 0) {
      const errorMessages = {
        1: "Unauthorized",
        2: "Bad input",
        3: "Comptroller rejection",
        4: "Comptroller calculation error",
        5: "Interest rate model error",
        6: "Invalid account pair",
        7: "Invalid close amount",
        8: "Invalid collateral factor",
        9: "Math error",
        10: "Market not fresh",
        11: "Market not listed",
        12: "Token insufficient allowance",
        13: "Token insufficient balance",
        14: "Token insufficient cash",
        15: "Token transfer in failed",
        16: "Token transfer out failed",
      };

      const errorMsg =
        errorMessages[error.toNumber()] || `Unknown error code: ${error}`;
      console.log(`Account ${account} liquidity check failed: ${errorMsg}`);
      return null;
    }

    console.log(`Account ${account} liquidity check successful:`);
    console.log(`  Liquidity: ${ethers.utils.formatEther(liquidity)} ETH`);
    console.log(`  Shortfall: ${ethers.utils.formatEther(shortfall)} ETH`);
    return {
      liquidity: ethers.BigNumber.from(liquidity),
      shortfall: ethers.BigNumber.from(shortfall),
      isLiquidatable: shortfall > 0,
    };
  } catch (error) {
    console.error(`Error checking account liquidity for ${account}:`, error);
    return null;
  }
}

/**
 * Get users who have borrowed from a market (with chunked queries to avoid RPC limits)
 */
async function getBorrowersFromMarket(pToken, provider, isBootstrap = false) {
  try {
    const symbol = await pToken.symbol();
    console.log(`Scanning borrowers for market ${symbol}...`);

    const currentBlock = await provider.getBlockNumber();
    console.log(`Current block: ${currentBlock}`);

    // Debug: Check total borrows to confirm there should be borrowers
    try {
      const totalBorrows = await pToken.totalBorrows();
      const totalBorrowsEth = parseFloat(
        ethers.utils.formatEther(totalBorrows)
      );
      console.log(
        `  📊 Total borrows in ${symbol}: ${totalBorrowsEth.toFixed(6)} tokens`
      );

      if (totalBorrowsEth > 0) {
        console.log(
          `  🎯 Market has active borrows - there SHOULD be borrowers to find!`
        );
      }
    } catch (borrowError) {
      console.log(`  ❌ Cannot get total borrows: ${borrowError.message}`);
    }

    let totalBlocksToScan;
    let fromBlock;

    // For pUSDC specifically, let's scan from deployment to find ALL historical borrowers
    if (symbol === "pUSDC" && !hasBootstrapped) {
      fromBlock = DEPLOYMENT_BLOCK;
      totalBlocksToScan = currentBlock - DEPLOYMENT_BLOCK;
      console.log(
        `  🚀 COMPREHENSIVE SCAN for ${symbol}: From deployment block ${DEPLOYMENT_BLOCK} (${totalBlocksToScan} blocks)`
      );
      console.log(
        `  🔍 This will find ALL borrowers who ever borrowed ${symbol}...`
      );
    } else if (!hasBootstrapped) {
      // Other markets: scan from last known checkpoint
      fromBlock = lastScannedBlock;
      totalBlocksToScan = currentBlock - lastScannedBlock;
      console.log(
        `  🚀 RESUMING SCAN: From block ${lastScannedBlock} (${totalBlocksToScan} new blocks)`
      );
    } else {
      // Normal mode: scan recent blocks only
      const recentBlocks = 1000; // Check last 1000 blocks for new activity
      fromBlock = Math.max(lastScannedBlock, currentBlock - recentBlocks);
      totalBlocksToScan = currentBlock - fromBlock;

      if (totalBlocksToScan > 0) {
        console.log(
          `  🔍 Recent scan: ${totalBlocksToScan} blocks from ${fromBlock}`
        );
      } else {
        console.log(`  ✅ No new blocks since last scan`);
        return []; // No new blocks to scan
      }
    }

    // Don't scan if there are no new blocks
    if (totalBlocksToScan <= 0) {
      console.log(`  ✅ No new blocks to scan for ${symbol}`);
      return [];
    }

    // Use comprehensive approach: get all accounts that ever borrowed
    const chunkSize = 5000; // Larger chunks for comprehensive scan
    const allBorrowers = new Set();

    if (symbol === "pUSDC" && !hasBootstrapped) {
      // Comprehensive historical scan for pUSDC
      console.log(`  📈 Comprehensive historical scan for ${symbol}...`);

      for (let i = 0; i < totalBlocksToScan; i += chunkSize) {
        const chunkFromBlock = fromBlock + i;
        const chunkToBlock = Math.min(
          currentBlock,
          chunkFromBlock + chunkSize - 1
        );

        console.log(
          `  📊 Scanning chunk ${chunkFromBlock} to ${chunkToBlock}...`
        );

        try {
          const accounts = await getAllBorrowAccounts(
            pToken,
            provider,
            chunkFromBlock,
            chunkToBlock
          );
          accounts.forEach((account) => allBorrowers.add(account));

          // Small delay between chunks
          await new Promise((resolve) => setTimeout(resolve, 100));
        } catch (error) {
          console.log(`  ❌ Chunk failed: ${error.message}`);
          continue;
        }
      }

      console.log(
        `  🎯 Found ${allBorrowers.size} unique accounts that ever borrowed ${symbol}`
      );

      // Now check current borrow balances for all these accounts
      if (allBorrowers.size > 0) {
        console.log(`  🔍 Checking current borrow balances...`);
        const activeBorrowers = await checkCurrentBorrowBalances(
          pToken,
          Array.from(allBorrowers)
        );

        // Return both historical and active borrowers for comprehensive liquidation check
        console.log(
          `  ✅ ${activeBorrowers.length} active borrowers, ${allBorrowers.size} total historical borrowers`
        );
        return Array.from(allBorrowers); // Return all historical borrowers for liquidity checks
      }
    } else {
      // Standard event-based scan for other markets or normal mode
      const chunkSize = 99; // Smaller chunks for regular scans
      let totalEventsFound = 0;

      // Query in chunks
      for (let i = 0; i < totalBlocksToScan; i += chunkSize) {
        const chunkFromBlock = fromBlock + i;
        const chunkToBlock = Math.min(
          currentBlock,
          chunkFromBlock + chunkSize - 1
        );

        if (chunkFromBlock > currentBlock) break; // Don't scan future blocks

        try {
          // Try different event names that might exist
          const eventNames = ["Borrow", "BorrowEvent", "Borrowed"];
          let foundEvents = false;

          for (const eventName of eventNames) {
            try {
              const filter = pToken.filters[eventName]();
              const events = await pToken.queryFilter(
                filter,
                chunkFromBlock,
                chunkToBlock
              );

              if (events.length > 0) {
                totalEventsFound += events.length;
                if (!hasBootstrapped || i < 200) {
                  // Only log details for bootstrap or first few chunks
                  console.log(
                    `  Found ${events.length} ${eventName} events in blocks ${chunkFromBlock}-${chunkToBlock}`
                  );

                  // Debug first few events
                  if (events.length > 0 && totalEventsFound <= 5) {
                    const event = events[0];
                    console.log(`    🔍 First event args:`, event.args);
                    console.log(
                      `    🔍 Event block: ${event.blockNumber}, tx: ${event.transactionHash}`
                    );
                  }
                }
                foundEvents = true;

                // Add borrowers to our set
                events.forEach((event) => {
                  if (event.args && event.args.borrower) {
                    allBorrowers.add(event.args.borrower);
                    globalBorrowerCache.add(event.args.borrower); // Add to global cache
                  } else if (event.args && event.args.user) {
                    allBorrowers.add(event.args.user);
                    globalBorrowerCache.add(event.args.user);
                  } else if (event.args && event.args.account) {
                    allBorrowers.add(event.args.account);
                    globalBorrowerCache.add(event.args.account);
                  } else {
                    console.log(
                      `    ⚠️  Event with no recognizable borrower field:`,
                      event.args
                    );
                  }
                });
                break; // Found the right event name, no need to try others
              }
            } catch (eventError) {
              // Event name doesn't exist, try next one
              continue;
            }
          }

          if (!foundEvents && (!hasBootstrapped || i < 5)) {
            // Only log for bootstrap or first few chunks to avoid spam
            console.log(
              `  No borrow events found in blocks ${chunkFromBlock}-${chunkToBlock}`
            );
          }

          // Small delay to be nice to the RPC (shorter for initial scan)
          await new Promise((resolve) =>
            setTimeout(resolve, hasBootstrapped ? 50 : 25)
          );
        } catch (chunkError) {
          console.log(
            `  Chunk ${chunkFromBlock}-${chunkToBlock} failed: ${chunkError.message}`
          );
          continue;
        }
      }

      const borrowers = Array.from(allBorrowers);
      const scanType = hasBootstrapped ? "recent" : "checkpoint";
      console.log(
        `Found ${borrowers.length} unique borrowers in ${symbol} (${scanType} scan: ${totalBlocksToScan} blocks, ${totalEventsFound} total events)`
      );

      // If we still don't find borrowers but there are total borrows, this is concerning
      if (borrowers.length === 0 && totalEventsFound === 0) {
        try {
          const totalBorrows = await pToken.totalBorrows();
          const totalBorrowsEth = parseFloat(
            ethers.utils.formatEther(totalBorrows)
          );
          if (totalBorrowsEth > 0) {
            console.log(
              `  🚨 WARNING: Market has ${totalBorrowsEth.toFixed(
                6
              )} total borrows but NO borrow events found!`
            );
            console.log(
              `  🔍 This could mean events were emitted before our scan range, or event name is different`
            );
          }
        } catch (error) {
          console.log(`  Could not get total borrows: ${error.message}`);
        }
      }

      return borrowers;
    }

    return Array.from(allBorrowers);
  } catch (error) {
    console.error(`Error getting borrowers from market:`, error);
    return [];
  }
}

/**
 * Calculate liquidation profitability
 */
async function calculateLiquidationProfit(
  peridottroller,
  pTokenBorrowed,
  pTokenCollateral,
  repayAmount,
  liquidator
) {
  try {
    const [error, seizeTokens] =
      await peridottroller.liquidateCalculateSeizeTokens(
        pTokenBorrowed.address,
        pTokenCollateral.address,
        repayAmount
      );

    if (error !== 0) {
      return { profitable: false, profit: ethers.constants.Zero };
    }

    // Get exchange rate to convert seized tokens to underlying
    const exchangeRate = await pTokenCollateral.exchangeRateStored();
    const underlyingSeized = seizeTokens
      .mul(exchangeRate)
      .div(ethers.utils.parseEther("1"));

    // Simple profit calculation: seized value - repay amount
    // In practice, you'd want to factor in gas costs and slippage
    const profit = underlyingSeized.sub(repayAmount);
    const profitable = profit.gt(MIN_PROFIT_THRESHOLD);

    return { profitable, profit, seizeTokens, underlyingSeized };
  } catch (error) {
    console.error("Error calculating liquidation profit:", error);
    return { profitable: false, profit: ethers.constants.Zero };
  }
}

/**
 * Execute liquidation using normal liquidateBorrow (flashloans disabled)
 */
async function executeLiquidation(
  peridottroller,
  pTokenBorrowed,
  pTokenCollateral,
  borrower,
  repayAmount,
  wallet
) {
  try {
    console.log(`Executing normal liquidation (flashloans disabled):`);
    console.log(`  Borrower: ${borrower}`);
    console.log(`  Borrowed Asset: ${await pTokenBorrowed.symbol()}`);
    console.log(`  Collateral Asset: ${await pTokenCollateral.symbol()}`);
    console.log(`  Repay Amount: ${ethers.utils.formatEther(repayAmount)}`);

    // Get the underlying token to approve and transfer
    const underlyingAddress = await pTokenBorrowed.underlying();
    const underlyingToken = new ethers.Contract(
      underlyingAddress,
      ERC20_ABI,
      wallet
    );

    // Check if we have enough balance
    const balance = await underlyingToken.balanceOf(wallet.address);
    if (balance.lt(repayAmount)) {
      console.log(
        `❌ Insufficient balance. Need: ${ethers.utils.formatEther(
          repayAmount
        )}, Have: ${ethers.utils.formatEther(balance)}`
      );
      return false;
    }

    // Approve the pToken to spend our tokens
    console.log(
      `Approving ${await underlyingToken.symbol()} for liquidation...`
    );
    const approveTx = await underlyingToken.approve(
      pTokenBorrowed.address,
      repayAmount,
      {
        gasLimit: 100000,
      }
    );
    await approveTx.wait();

    // Execute the liquidation
    console.log(`Calling liquidateBorrow...`);
    const tx = await pTokenBorrowed.liquidateBorrow(
      borrower,
      repayAmount,
      pTokenCollateral.address,
      {
        gasLimit: 1000000,
      }
    );

    console.log(`Liquidation transaction sent: ${tx.hash}`);
    const receipt = await tx.wait();

    if (receipt.status === 1) {
      console.log(
        `✅ Liquidation successful! Gas used: ${receipt.gasUsed.toString()}`
      );
      return true;
    } else {
      console.log(`❌ Liquidation failed`);
      return false;
    }
  } catch (error) {
    if (error.reason) {
      console.log(`❌ Liquidation failed: ${error.reason}`);
    } else {
      console.error(`❌ Liquidation failed:`, error);
    }
    return false;
  }
}

/**
 * Check a single borrower for liquidation opportunities
 */
async function checkBorrowerForLiquidation(
  peridottroller,
  markets,
  borrower,
  wallet
) {
  try {
    const liquidityInfo = await getAccountLiquidity(peridottroller, borrower);

    if (!liquidityInfo || !liquidityInfo.isLiquidatable) {
      return false; // Not liquidatable
    }

    console.log(`🎯 Found liquidatable account: ${borrower}`);
    console.log(
      `  Shortfall: ${ethers.utils.formatEther(liquidityInfo.shortfall)} ETH`
    );

    // Find the borrower's positions
    for (const marketAddress of markets) {
      const pToken = new ethers.Contract(marketAddress, PTokenABI, wallet);

      try {
        const borrowBalance = await pToken.borrowBalanceStored(borrower);

        if (borrowBalance.gt(0)) {
          console.log(
            `  Borrow in ${await pToken.symbol()}: ${ethers.utils.formatEther(
              borrowBalance
            )}`
          );

          // Calculate max repay amount (close factor)
          const closeFactor = await peridottroller.closeFactorMantissa();
          const maxRepay = borrowBalance
            .mul(closeFactor)
            .div(ethers.utils.parseEther("1"));

          // Find collateral markets
          for (const collateralAddress of markets) {
            if (collateralAddress === marketAddress) continue; // Can't liquidate same asset

            const pTokenCollateral = new ethers.Contract(
              collateralAddress,
              PTokenABI,
              wallet
            );
            const collateralBalance = await pTokenCollateral.balanceOf(
              borrower
            );

            if (collateralBalance.gt(0)) {
              console.log(
                `  Collateral in ${await pTokenCollateral.symbol()}: ${ethers.utils.formatEther(
                  collateralBalance
                )}`
              );

              // Check profitability
              const profitInfo = await calculateLiquidationProfit(
                peridottroller,
                pToken,
                pTokenCollateral,
                maxRepay,
                wallet.address
              );

              if (profitInfo.profitable) {
                console.log(
                  `💰 Profitable liquidation found! Estimated profit: ${ethers.utils.formatEther(
                    profitInfo.profit
                  )} ETH`
                );

                // Execute the liquidation using Peridottroller's flashloan
                const success = await executeLiquidation(
                  peridottroller,
                  pToken,
                  pTokenCollateral,
                  borrower,
                  maxRepay,
                  wallet
                );

                if (success) {
                  return true; // Successfully liquidated, move to next borrower
                }
              } else {
                console.log(
                  `📉 Liquidation not profitable. Estimated profit: ${ethers.utils.formatEther(
                    profitInfo.profit
                  )} ETH`
                );
              }
            }
          }
        }
      } catch (error) {
        // Skip this market if there's an error
        continue;
      }
    }

    return false;
  } catch (error) {
    console.error(`Error checking borrower ${borrower}:`, error);
    return false;
  }
}

/**
 * Get all accounts that have ever interacted with borrowing in a market
 */
async function getAllBorrowAccounts(pToken, provider, fromBlock, toBlock) {
  try {
    const symbol = await pToken.symbol();
    const allAccounts = new Set();

    // Get accounts from Borrow events
    try {
      const borrowFilter = pToken.filters.Borrow();
      const borrowEvents = await pToken.queryFilter(
        borrowFilter,
        fromBlock,
        toBlock
      );
      borrowEvents.forEach((event) => {
        if (event.args && event.args.borrower) {
          allAccounts.add(event.args.borrower);
        }
      });
      if (borrowEvents.length > 0) {
        console.log(
          `    Found ${borrowEvents.length} Borrow events in ${symbol}`
        );
      }
    } catch (error) {
      console.log(`    No Borrow events accessible for ${symbol}`);
    }

    // Get accounts from RepayBorrow events (these accounts previously borrowed)
    try {
      const repayFilter = pToken.filters.RepayBorrow();
      const repayEvents = await pToken.queryFilter(
        repayFilter,
        fromBlock,
        toBlock
      );
      repayEvents.forEach((event) => {
        if (event.args && event.args.borrower) {
          allAccounts.add(event.args.borrower);
        }
      });
      if (repayEvents.length > 0) {
        console.log(
          `    Found ${repayEvents.length} RepayBorrow events in ${symbol} (accounts that previously borrowed)`
        );
      }
    } catch (error) {
      console.log(`    No RepayBorrow events accessible for ${symbol}`);
    }

    return Array.from(allAccounts);
  } catch (error) {
    console.error(`Error getting all borrow accounts from ${symbol}:`, error);
    return [];
  }
}

/**
 * Check current borrow balances for a list of accounts
 */
async function checkCurrentBorrowBalances(pToken, accounts) {
  try {
    const symbol = await pToken.symbol();
    const activeBorrowers = [];

    for (const account of accounts) {
      try {
        const borrowBalance = await pToken.borrowBalanceStored(account);
        if (borrowBalance.gt(0)) {
          activeBorrowers.push(account);
          console.log(
            `    🎯 Active borrower in ${symbol}: ${account} owes ${ethers.utils.formatEther(
              borrowBalance
            )}`
          );
        }
      } catch (error) {
        // Account might not exist or other error
        continue;
      }
    }

    return activeBorrowers;
  } catch (error) {
    console.error(`Error checking borrow balances:`, error);
    return [];
  }
}

/**
 * Main liquidation scanning function
 */
async function scanForLiquidations(provider, wallet) {
  try {
    const currentBlock = await provider.getBlockNumber();

    if (!hasBootstrapped) {
      console.log(
        `🚀 CHECKPOINT RESUME: Scanning from block ${lastScannedBlock} to ${currentBlock}`
      );
      console.log(
        `🔍 This will scan ${currentBlock - lastScannedBlock} new blocks...`
      );
    } else {
      console.log(
        `🔍 Scanning for liquidation opportunities (recent blocks)...`
      );
    }

    const peridottroller = new ethers.Contract(
      PERIDOTTROLLER_ADDRESS,
      PeridottrollerABI,
      wallet
    );

    // Get all markets
    const markets = await getAllMarkets(peridottroller);

    if (markets.length === 0) {
      console.log("No markets found");
      return;
    }

    // Collect all borrowers from all markets
    let allBorrowers = new Set();

    if (!hasBootstrapped) {
      // First scan: resume from checkpoint
      for (const marketAddress of markets) {
        const pToken = new ethers.Contract(marketAddress, PTokenABI, provider);
        const borrowers = await getBorrowersFromMarket(pToken, provider, false);
        borrowers.forEach((borrower) => allBorrowers.add(borrower));
      }

      hasBootstrapped = true;
      console.log(
        `🎉 CHECKPOINT SCAN COMPLETE! Found ${allBorrowers.size} new borrowers`
      );
      console.log(
        `📋 Global borrower cache now contains ${globalBorrowerCache.size} addresses`
      );

      // Save progress
      saveCheckpoint(currentBlock);
    } else {
      // Normal mode: quick recent scan + cached borrowers
      for (const marketAddress of markets) {
        const pToken = new ethers.Contract(marketAddress, PTokenABI, provider);
        const borrowers = await getBorrowersFromMarket(pToken, provider, false);
        borrowers.forEach((borrower) => allBorrowers.add(borrower));
      }

      // Add all cached borrowers to ensure we don't miss anyone
      globalBorrowerCache.forEach((borrower) => allBorrowers.add(borrower));

      // Save progress if we scanned new blocks
      if (currentBlock > lastScannedBlock) {
        saveCheckpoint(currentBlock);
      }
    }

    console.log(`📊 Total unique borrowers to check: ${allBorrowers.size}`);

    let liquidationsExecuted = 0;

    // Check each borrower for liquidation opportunities
    for (const borrower of allBorrowers) {
      const liquidated = await checkBorrowerForLiquidation(
        peridottroller,
        markets,
        borrower,
        wallet
      );

      if (liquidated) {
        liquidationsExecuted++;
      }

      // Add small delay to avoid rate limiting
      await new Promise((resolve) => setTimeout(resolve, 100));
    }

    console.log(
      `✅ Scan complete. Liquidations executed: ${liquidationsExecuted}`
    );
  } catch (error) {
    console.error("Error in liquidation scan:", error);
  }
}

async function main() {
  console.log("🤖 Starting Peridot Liquidation Bot...");

  // Validate environment variables
  const requiredEnvVars = {
    PRIVATE_KEY: process.env.PRIVATE_KEY,
    MONAD_TESTNET_RPC_URL: process.env.MONAD_TESTNET_RPC_URL,
    PERIDOTTROLLER_ADDRESS: process.env.PERIDOTTROLLER_ADDRESS,
  };

  const missingEnvVars = Object.entries(requiredEnvVars)
    .filter(([key, value]) => !value)
    .map(([key]) => key);

  if (missingEnvVars.length > 0) {
    throw new Error(
      `Please set required environment variables: ${missingEnvVars.join(", ")}`
    );
  }

  const provider = new ethers.providers.JsonRpcProvider(MONAD_TESTNET_RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);

  console.log(`🔗 Connected to Monad Testnet`);
  console.log(`👛 Liquidator address: ${wallet.address}`);
  console.log(`🏦 Peridottroller: ${PERIDOTTROLLER_ADDRESS}`);
  console.log(`⏰ Check interval: ${CHECK_INTERVAL_MINUTES} minutes`);
  console.log(
    `💰 Min profit threshold: ${ethers.utils.formatEther(
      MIN_PROFIT_THRESHOLD
    )} ETH`
  );

  // Load checkpoint
  loadCheckpoint();

  // Run initial scan
  await scanForLiquidations(provider, wallet);

  // Set up interval for continuous monitoring
  setInterval(async () => {
    await scanForLiquidations(provider, wallet);
  }, CHECK_INTERVAL_MINUTES * 60 * 1000);
}

main().catch((error) => {
  console.error("An error occurred:", error);
  process.exit(1);
});

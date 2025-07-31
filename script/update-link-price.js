const dotenvResult = require("dotenv").config();

if (dotenvResult.error) {
  console.error("Error loading .env file:", dotenvResult.error);
  throw dotenvResult.error;
}

const { ethers } = require("ethers");
const { Pool, Route, Trade } = require("@uniswap/v3-sdk");
const { Token, CurrencyAmount } = require("@uniswap/sdk-core");
const IUniswapV3PoolABI =
  require("@uniswap/v3-core/artifacts/contracts/interfaces/IUniswapV3Pool.sol/IUniswapV3Pool.json").abi;
const {
  abi: SimplePriceOracleABI,
} = require("../contracts/out/SimplePriceOracle.sol/SimplePriceOracle.json");
const IUniswapV3FactoryABI =
  require("@uniswap/v3-core/artifacts/contracts/interfaces/IUniswapV3Factory.sol/IUniswapV3Factory.json").abi;

const ERC20_ABI = [
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
];

// --- Configuration ---
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const MONAD_TESTNET_RPC_URL = process.env.MONAD_TESTNET_RPC_URL;
const PRICE_ORACLE_CONTRACT_ADDRESS = process.env.PRICE_ORACLE_CONTRACT_ADDRESS;
const UPDATE_INTERVAL_MINUTES = process.env.UPDATE_INTERVAL_MINUTES || 5;
const LINK_TOKEN_ADDRESS = process.env.LINK_TOKEN_ADDRESS;
const USD_TOKEN_ADDRESS = process.env.USD_TOKEN_ADDRESS;
const WMONAD_TOKEN_ADDRESS = process.env.WMONAD_TOKEN_ADDRESS;
const UNISWAP_FACTORY_ADDRESS = process.env.UNISWAP_FACTORY_ADDRESS;
// $P token and its direct USDC pool
const P_TOKEN_ADDRESS = process.env.P_TOKEN_ADDRESS;
const P_USDC_POOL_ADDRESS = process.env.P_USDC_POOL_ADDRESS;

// --- Helper Functions ---

async function findLiquidPool(factory, tokenA, tokenB, provider, chainId) {
  console.log(
    `Searching for a liquid pool for ${tokenA.symbol}/${tokenB.symbol}...`
  );
  const feeTiers = [3000, 500, 10000, 100]; // Common fee tiers: 0.3%, 0.05%, 1%, 0.01%

  for (const fee of feeTiers) {
    const poolAddress = await factory.getPool(
      tokenA.address,
      tokenB.address,
      fee
    );

    if (poolAddress !== ethers.constants.AddressZero) {
      console.log(
        `Found potential pool at ${poolAddress} with fee tier ${fee}...`
      );
      const poolContract = new ethers.Contract(
        poolAddress,
        IUniswapV3PoolABI,
        provider
      );
      const liquidity = await poolContract.liquidity();

      if (liquidity.gt(0)) {
        console.log(`Found liquid pool! Address: ${poolAddress}`);
        const [slot0, token0Address, token1Address] = await Promise.all([
          poolContract.slot0(),
          poolContract.token0(),
          poolContract.token1(),
        ]);

        console.log(`Pool ${poolAddress} details:`);
        console.log(
          `  Token0: ${token0Address} (expected: ${tokenA.address} or ${tokenB.address})`
        );
        console.log(
          `  Token1: ${token1Address} (expected: ${tokenA.address} or ${tokenB.address})`
        );
        console.log(`  Liquidity: ${liquidity.toString()}`);
        console.log(`  Tick: ${slot0.tick}`);

        const [token0, token1] = tokenA.sortsBefore(tokenB)
          ? [tokenA, tokenB]
          : [tokenB, tokenA];

        console.log(
          `Uniswap SDK sorted order: ${token0.symbol} (${token0.address}) / ${token1.symbol} (${token1.address})`
        );
        console.log(`Pool contract order: ${token0Address} / ${token1Address}`);

        if (token0.address.toLowerCase() !== token0Address.toLowerCase()) {
          console.warn(
            `WARNING: Token order mismatch! SDK expects ${token0.address} as token0, but pool has ${token0Address}`
          );
          // Let's use the actual pool order instead
          const actualToken0 =
            tokenA.address.toLowerCase() === token0Address.toLowerCase()
              ? tokenA
              : tokenB;
          const actualToken1 =
            tokenB.address.toLowerCase() === token1Address.toLowerCase()
              ? tokenB
              : tokenA;

          return new Pool(
            actualToken0,
            actualToken1,
            fee,
            slot0.sqrtPriceX96.toString(),
            liquidity.toString(),
            slot0.tick
          );
        }

        return new Pool(
          token0,
          token1,
          fee,
          slot0.sqrtPriceX96.toString(),
          liquidity.toString(),
          slot0.tick
        );
      }
    }
  }
  throw new Error(`No liquid pool found for ${tokenA.symbol}/${tokenB.symbol}`);
}

/**
 * Fetches the price of LINK in USD from a Uniswap V3 pool.
 * @param {ethers.providers.Provider} provider Ethers.js provider instance.
 * @returns {Promise<ethers.BigNumber>} The price of LINK in USD, formatted with 18 decimals.
 */
async function getLinkPriceFromUniswap(provider) {
  console.log("Fetching LINK/USD price from Uniswap via multi-hop...");

  const { chainId } = await provider.getNetwork();
  console.log(`Connected to chain with ID: ${chainId}`);

  const factory = new ethers.Contract(
    UNISWAP_FACTORY_ADDRESS,
    IUniswapV3FactoryABI,
    provider
  );

  // Define tokens
  const linkContract = new ethers.Contract(
    LINK_TOKEN_ADDRESS,
    ERC20_ABI,
    provider
  );
  const wmonadContract = new ethers.Contract(
    WMONAD_TOKEN_ADDRESS,
    ERC20_ABI,
    provider
  );
  const usdContract = new ethers.Contract(
    USD_TOKEN_ADDRESS,
    ERC20_ABI,
    provider
  );
  const [
    linkDecimals,
    linkSymbol,
    wmonadDecimals,
    wmonadSymbol,
    usdDecimals,
    usdSymbol,
  ] = await Promise.all([
    linkContract.decimals(),
    linkContract.symbol(),
    wmonadContract.decimals(),
    wmonadContract.symbol(),
    usdContract.decimals(),
    usdContract.symbol(),
  ]);

  console.log(
    `DEBUG: LINK Symbol: ${linkSymbol}, WMONAD Symbol: ${wmonadSymbol}, USD Symbol: ${usdSymbol}`
  );

  const LINK = new Token(chainId, LINK_TOKEN_ADDRESS, linkDecimals, linkSymbol);
  const WMONAD = new Token(
    chainId,
    WMONAD_TOKEN_ADDRESS,
    wmonadDecimals,
    wmonadSymbol
  );
  const USD = new Token(chainId, USD_TOKEN_ADDRESS, usdDecimals, usdSymbol);

  console.log("Finding pools...");
  const linkWmonadPool = await findLiquidPool(
    factory,
    LINK,
    WMONAD,
    provider,
    chainId
  );
  console.log(
    `LINK/WMON pool created: ${linkWmonadPool.token0.symbol}/${linkWmonadPool.token1.symbol}, liquidity: ${linkWmonadPool.liquidity}`
  );

  const wmonadUsdPool = await findLiquidPool(
    factory,
    WMONAD,
    USD,
    provider,
    chainId
  );
  console.log(
    `WMON/USD pool created: ${wmonadUsdPool.token0.symbol}/${wmonadUsdPool.token1.symbol}, liquidity: ${wmonadUsdPool.liquidity}`
  );

  // Create the route
  console.log("Calculating route...");
  console.log(
    `Pool 1: ${linkWmonadPool.token0.symbol}/${linkWmonadPool.token1.symbol} (fee: ${linkWmonadPool.fee})`
  );
  console.log(
    `Pool 2: ${wmonadUsdPool.token0.symbol}/${wmonadUsdPool.token1.symbol} (fee: ${wmonadUsdPool.fee})`
  );
  console.log(`Route input: ${LINK.symbol}, output: ${USD.symbol}`);

  // Instead of using Trade.fromRoute, let's calculate the price manually
  console.log("Calculating price manually from pool states...");

  // Get the current price from each pool
  const linkWmonPrice = linkWmonadPool.token0Price; // LINK per WMON or WMON per LINK
  const wmonUsdPrice = wmonadUsdPool.token0Price; // WMON per USD or USD per WMON

  console.log(
    `Pool 1 token0Price: ${linkWmonPrice.toSignificant(6)} ${
      linkWmonadPool.token1.symbol
    }/${linkWmonadPool.token0.symbol}`
  );
  console.log(
    `Pool 2 token0Price: ${wmonUsdPrice.toSignificant(6)} ${
      wmonadUsdPool.token1.symbol
    }/${wmonadUsdPool.token0.symbol}`
  );

  // Calculate LINK/USD price through the route
  let linkUsdPrice;

  if (linkWmonadPool.token0.symbol === "LINK") {
    // LINK is token0 in first pool, so token0Price gives us WMON/LINK
    const wmonPerLink = linkWmonPrice;

    if (wmonadUsdPool.token0.symbol === "WMON") {
      // WMON is token0 in second pool, so token0Price gives us USD/WMON
      const usdPerWmon = wmonUsdPrice;
      linkUsdPrice = wmonPerLink.multiply(usdPerWmon);
    } else {
      // USDC is token0 in second pool, so we need the inverse
      const wmonPerUsd = wmonUsdPrice;
      linkUsdPrice = wmonPerLink.divide(wmonPerUsd);
    }
  } else {
    // WMON is token0 in first pool, so we need the inverse
    const linkPerWmon = linkWmonPrice;

    if (wmonadUsdPool.token0.symbol === "WMON") {
      const usdPerWmon = wmonUsdPrice;
      linkUsdPrice = linkPerWmon.multiply(usdPerWmon);
    } else {
      const wmonPerUsd = wmonUsdPrice;
      linkUsdPrice = linkPerWmon.divide(wmonPerUsd);
    }
  }

  console.log(`Calculated LINK/USD price: ${linkUsdPrice.toSignificant(6)}`);

  // Debug the price conversion
  console.log(`Price object type: ${typeof linkUsdPrice}`);
  console.log(`Price object methods: ${Object.getOwnPropertyNames(linkUsdPrice)}`);

  // Convert using a more robust approach
  const priceAsFloat = parseFloat(linkUsdPrice.toSignificant(18));
  console.log(`Price as float: ${priceAsFloat}`);

  const priceMantissa = ethers.utils.parseEther(priceAsFloat.toString());
  console.log(`Price mantissa: ${priceMantissa.toString()}`);

  return priceMantissa;
}

/**
 * Fetches the price of $P in USD (USDC) from its direct Uniswap V3 pool.
 * @param {ethers.providers.Provider} provider Ethers.js provider instance.
 * @returns {Promise<ethers.BigNumber>} The price of $P in USD, formatted with 18 decimals.
 */
async function getPPriceFromUniswap(provider) {
  console.log("Fetching $P/USD price from direct Uniswap pool...");

  if (!P_USDC_POOL_ADDRESS) {
    throw new Error("P_USDC_POOL_ADDRESS env variable not set");
  }

  const poolContract = new ethers.Contract(
    P_USDC_POOL_ADDRESS,
    IUniswapV3PoolABI,
    provider
  );

  const [token0Address, token1Address, fee, slot0, liquidity] = await Promise.all([
    poolContract.token0(),
    poolContract.token1(),
    poolContract.fee(),
    poolContract.slot0(),
    poolContract.liquidity(),
  ]);

  const { chainId } = await provider.getNetwork();

  // Gather metadata for the two tokens
  const token0Contract = new ethers.Contract(token0Address, ERC20_ABI, provider);
  const token1Contract = new ethers.Contract(token1Address, ERC20_ABI, provider);

  const [token0Decimals, token0Symbol, token1Decimals, token1Symbol] = await Promise.all([
    token0Contract.decimals(),
    token0Contract.symbol(),
    token1Contract.decimals(),
    token1Contract.symbol(),
  ]);

  const token0 = new Token(chainId, token0Address, token0Decimals, token0Symbol);
  const token1 = new Token(chainId, token1Address, token1Decimals, token1Symbol);

  const pool = new Pool(
    token0,
    token1,
    fee,
    slot0.sqrtPriceX96.toString(),
    liquidity.toString(),
    slot0.tick
  );

  let pUsdPrice;

  if (token0.address.toLowerCase() === USD_TOKEN_ADDRESS.toLowerCase()) {
    // token0 is USDC – price of $P is token1Price (USDC per $P)
    pUsdPrice = pool.token1Price;
  } else if (token1.address.toLowerCase() === USD_TOKEN_ADDRESS.toLowerCase()) {
    // token1 is USDC – price of $P is token0Price (USDC per $P)
    pUsdPrice = pool.token0Price;
  } else {
    throw new Error("Neither token in the pool is USDC; cannot derive $P price in USD");
  }

  console.log(`Calculated $P/USD price: ${pUsdPrice.toSignificant(6)}`);

  const priceAsFloat = parseFloat(pUsdPrice.toSignificant(18));
  const priceMantissa = ethers.utils.parseEther(priceAsFloat.toString());

  return priceMantissa;
}

async function main() {
  console.log("Starting price update script...");

  const requiredEnvVars = {
    PRIVATE_KEY: process.env.PRIVATE_KEY,
    MONAD_TESTNET_RPC_URL: process.env.MONAD_TESTNET_RPC_URL,
    PRICE_ORACLE_CONTRACT_ADDRESS: process.env.PRICE_ORACLE_CONTRACT_ADDRESS,
    LINK_TOKEN_ADDRESS: process.env.LINK_TOKEN_ADDRESS,
    USD_TOKEN_ADDRESS: process.env.USD_TOKEN_ADDRESS,
    WMONAD_TOKEN_ADDRESS: process.env.WMONAD_TOKEN_ADDRESS,
    UNISWAP_FACTORY_ADDRESS: process.env.UNISWAP_FACTORY_ADDRESS,
    P_TOKEN_ADDRESS: process.env.P_TOKEN_ADDRESS,
    P_USDC_POOL_ADDRESS: process.env.P_USDC_POOL_ADDRESS,
  };

  const missingEnvVars = Object.entries(requiredEnvVars)
    .filter(([key, value]) => !value)
    .map(([key]) => key);

  if (missingEnvVars.length > 0) {
    throw new Error(
      `Please set required environment variables in .env file. Missing or empty: ${missingEnvVars.join(
        ", "
      )}`
    );
  }

  const provider = new ethers.providers.JsonRpcProvider(MONAD_TESTNET_RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
  const priceOracleContract = new ethers.Contract(
    PRICE_ORACLE_CONTRACT_ADDRESS,
    SimplePriceOracleABI,
    wallet
  );

  console.log(`Wallet address: ${wallet.address}`);
  console.log(`Price Oracle contract address: ${priceOracleContract.address}`);

  const updatePrice = async () => {
    try {
      const [linkPrice, pPrice] = await Promise.all([
        getLinkPriceFromUniswap(provider),
        getPPriceFromUniswap(provider),
      ]);
      console.log(
        `Updating LINK price oracle: ${ethers.utils.formatUnits(linkPrice, 18)} | $P price: ${ethers.utils.formatUnits(pPrice, 18)}`
      );

      // Submit LINK price
      const tx1 = await priceOracleContract.setDirectPrice(
        LINK_TOKEN_ADDRESS,
        linkPrice
      );
      console.log(`LINK price tx sent: ${tx1.hash}`);
      await tx1.wait();
      console.log("LINK price update confirmed.");

      // Submit $P price
      const tx2 = await priceOracleContract.setDirectPrice(
        P_TOKEN_ADDRESS,
        pPrice
      );
      console.log(`$P price tx sent: ${tx2.hash}`);
      await tx2.wait();
      console.log("$P price update confirmed.");
    } catch (error) {
      console.error("Failed to update price:", error);
    }
  };

  // Run once immediately, then on an interval
  await updatePrice();
  setInterval(updatePrice, UPDATE_INTERVAL_MINUTES * 60 * 1000);
}

main().catch((error) => {
  console.error("An error occurred:", error);
  process.exit(1);
});

require("@nomicfoundation/hardhat-toolbox");

const dotenv = require("dotenv");
const path = require("path");

dotenv.config();

module.exports = {
  solidity: {
    compilers: [
      {
        version: "0.5.16",
        settings: {
          optimizer: { enabled: true, runs: 200 },
        },
      },
      {
        version: "0.6.6",
        settings: {
          optimizer: { enabled: true, runs: 200 },
        },
      },
      {
        version: "0.6.12",
        settings: {
          optimizer: { enabled: true, runs: 200 },
        },
      },
      {
        version: "0.8.0",
        settings: {
          optimizer: { enabled: true, runs: 200 },
        },
      },
      {
        version: "0.8.20",
        settings: {
          optimizer: { enabled: true, runs: 200 },
        },
      },
      {
        version: "0.8.24",
        settings: {
          optimizer: { enabled: true, runs: 200 },
        },
      },
      {
        version: "0.8.26",
        settings: {
          optimizer: { enabled: false, runs: 200 },
        },
      },
      {
        version: "0.8.27",
        settings: {
          optimizer: { enabled: true, runs: 200 },
        },
      },
      {
        version: "0.8.30",
        settings: {
          optimizer: { enabled: true, runs: 200 },
          viaIR: true,
          metadata: {
            bytecodeHash: "none",
            useLiteralContent: true,
          },
        },
      },
    ],
  },
  networks: {
    arbitrumSepolia: {
      url: process.env.ARBITRUM_SEPOLIA_URL,
      accounts: process.env.PRIVATE_KEY_TEST ? [process.env.PRIVATE_KEY_TEST] : [],
    },
    "somnia-testnet": {
      url: process.env.SOMNIARPC || "https://dream-rpc.somnia.network",
      accounts: process.env.PRIVATEMAIN ? [process.env.PRIVATEMAIN] : [],
      chainId: 50312,
    },
  },
  etherscan: {
    apiKey: {
      arbitrumSepolia: process.env.ARBITRUMSCAN_KEY || "",
      "somnia-testnet": "empty",
    },
    customChains: [
      {
        network: "arbitrumSepolia",
        chainId: 421614,
        urls: {
          apiURL: "https://api-sepolia.arbiscan.io/api",
          browserURL: "https://sepolia.arbiscan.io/",
        },
      },
      {
        network: "somnia-testnet",
        chainId: 50312,
        urls: {
          apiURL: "https://somnia.w3us.site/api",
          browserURL: "https://somnia.w3us.site",
        },
      },
    ],
  },
  paths: {
    sources: path.join(__dirname, "contracts"),
    artifacts: path.join(__dirname, "artifacts"),
    cache: path.join(__dirname, "cache"),
    tests: path.join(__dirname, "test"),
  },
};

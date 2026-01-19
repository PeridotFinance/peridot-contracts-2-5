# Peridot Price Updater

This script fetches the price of LINK/USD from a Uniswap V3 pool on the Monad Testnet and updates the `SimplePriceOracle.sol` contract at a regular interval.

## Setup

1.  **Install Dependencies:**

    ```bash
    npm install
    ```

2.  **Compile Contracts:**

    You need to compile the Solidity contracts to generate the necessary ABI files for the script.

    - First, install `solc` globally if you haven't already:
      ```bash
      npm install -g solc
      ```
    - Then, compile the contracts:
      ```bash
      solc --abi --base-path . --include-path ./node_modules/ --bin -o contracts/build contracts/SimplePriceOracle.sol
      ```
      This command will output the ABI and BIN files into the `contracts/build` directory.

3.  **Environment Variables:**

    Create a `.env` file in the root of the project by copying the example:

    ```bash
    cp .env.example .env
    ```

    Now, edit the `.env` file with your details:

    - `PRIVATE_KEY`: The private key of the wallet that will be used to send transactions. This wallet must have admin permissions on the `SimplePriceOracle` contract.
    - `MONAD_TESTNET_RPC_URL`: The RPC endpoint for the Monad Testnet.
    - `PRICE_ORACLE_CONTRACT_ADDRESS`: The deployed address of your `SimplePriceOracle` contract.
    - `UPDATE_INTERVAL_MINUTES`: The interval in minutes to update the price.
    - `LINK_TOKEN_ADDRESS`: The address of the LINK token on the Monad Testnet.
    - `USD_TOKEN_ADDRESS`: The address of the stablecoin (e.g., USDC) to be used as the quote currency.

4.  **Uniswap Pool Configuration:**

    Open `script/update-link-price.js` and update the following placeholder:

    - `POOL_ADDRESS`: Replace `"0x..."` with the actual address of the LINK/USD Uniswap V3 pool on the Monad Testnet. You may also need to adjust the token order and fee tier.

## Running the Script

Once everything is configured, you can start the price updater with:

```bash
npm start
```

The script will then run continuously, fetching the price and updating your contract at the specified interval.

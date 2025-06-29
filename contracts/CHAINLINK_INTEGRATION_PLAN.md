### Peridot Protocol - Chainlink Integration Plan

This plan outlines the steps to integrate Chainlink services into the Peridot protocol, enhancing its capabilities with cross-chain functionality, reliable price data, and MEV protection.

## 🎯 **Current Status Summary**

✅ **Phase 1 Complete**: Basic CCIP infrastructure established  
✅ **Phase 2 Complete**: Read-only cross-chain integration with Peridot  
✅ **Phase 3 Complete**: State-changing cross-chain operations  
✅ **Phase 4 Complete**: Chainlink Data Feeds price oracle  
✅ **Phase 5 Complete**: VRF-based MEV protection for liquidations

**🏗️ Contracts Created:**

- `CCIPSender.sol` & `CCIPReceiver.sol` - Basic CCIP proof of concept
- `PeridotCCIPReader.sol` & `PeridotCCIPSender.sol` - Read-only cross-chain queries
- `PeridotCCIPAdapter.sol` & `PeridotCCIPController.sol` - State-changing operations
- `ChainlinkPriceOracle.sol` - Chainlink Data Feeds integration
- `PeridotVRFLiquidator.sol` - VRF-powered fair liquidation system

**✅ All contracts compile successfully!**

#### Phase 1: Foundational CCIP Proof of Concept (The Skateboard)

The goal of this phase is to establish a basic, one-way communication channel between two blockchains using CCIP. This will validate the setup and configuration without touching the core Peridot contracts.

- [x] **Setup Development Environment**: Configure the project for multi-chain development, targeting two testnets (e.g., Ethereum Sepolia and Avalanche Fuji).
- [x] **Create a `CCIPSender` contract**: Develop a simple sender contract on the source chain that can send a text message and pay for the transaction in LINK tokens.
- [x] **Create a `CCIPReceiver` contract**: Develop a receiver contract on the destination chain that can receive a message from the `CCIPSender`, verify the source, and store the received text.
- [x] **Deploy and Test**: Deploy both contracts, configure the necessary allow-lists on-chain, and execute a cross-chain message transaction to verify the connection.

#### Phase 2: Read-Only Integration with Peridot Contracts

This phase connects CCIP to the live Peridot protocol in a safe, read-only manner. We will fetch data from the `Peridottroller` on one chain, triggered by a transaction from another.

- [x] **Create `PeridotCCIPReader` contract**: This contract will act as the CCIP receiver on the destination chain where Peridot is deployed.
- [x] **Implement Cross-Chain `getAccountLiquidity`**:
  - The `PeridotCCIPSender` on the source chain can send a request for a user's liquidity on the destination chain.
  - The `PeridotCCIPReader` will receive this request, call the `getAccountLiquidity` function on the `Peridottroller` contract for the specified user, and emit an event with the result.
- [ ] **Test Read-Only Call**: Initiate a transaction on the source chain and verify that the correct liquidity data is emitted in an event on the destination chain.

#### Phase 3: State-Changing Integration with Peridot Contracts (The Car)

Now we'll enable users to modify their state in the Peridot protocol from a different blockchain. This requires careful security considerations and potential modifications to the core contracts.

- [x] **Security Analysis**: Identify which `Peridottroller` functions are safe to expose to cross-chain calls.
- [x] **Modify `Peridottroller` for CCIP**:
  - Created `PeridotCCIPAdapter` contract that can call `enterMarkets` and `exitMarket` functions.
  - Implemented proper authorization checks to ensure only whitelisted sources can execute operations.
- [x] **Implement `PeridotCCIPAdapter`**: This contract acts as the CCIP receiver and can execute `enterMarkets` and `exitMarket` on behalf of users.
- [x] **Implement `PeridotCCIPController`**: This contract allows users to send cross-chain requests with proper authorization mechanisms.
- [ ] **End-to-End Test**: Execute a full cross-chain transaction that allows a user on the source chain to successfully enter a market on the destination chain's Peridot protocol.

#### Phase 4: Integrate Chainlink Data Feeds for Reliable Prices

This phase replaces the existing price oracle with Chainlink's highly reliable and decentralized Data Feeds to secure the protocol against price manipulation.

- [x] **Develop a `ChainlinkPriceOracle` contract**: Create a new oracle contract that implements Peridot's `PriceOracle` interface but fetches prices from Chainlink Data Feeds.
- [ ] **Deploy and Configure New Oracle**: Deploy the `ChainlinkPriceOracle` and configure it with the correct data feed addresses for each supported asset.
- [ ] **Migrate `Peridottroller`**: Atomically update the `Peridottroller` to use the new `ChainlinkPriceOracle` as its source of truth for asset prices.
- [ ] **Test Price Updates**: Verify that the protocol correctly ingests prices from Chainlink and that all functions (mint, borrow, liquidate) behave as expected with the new oracle.

#### Phase 5: Integrate Chainlink VRF for MEV Protection (The Supercar)

In this final phase, we'll explore using Chainlink's Verifiable Random Function (VRF) to introduce fairness and mitigate Miner Extractable Value (MEV), particularly in liquidations.

- [x] **Design VRF-based Liquidation Mechanism**: Conceptualize a system where VRF is used to fairly select a liquidator from a pool or to introduce a randomized delay, preventing front-running.
- [x] **Implement VRF-aware components**: Created `PeridotVRFLiquidator` contract that uses VRF to fairly select liquidators and provides MEV protection through time delays.
- [ ] **End-to-End Test of Fair Liquidation**: Simulate market conditions that lead to a liquidation and verify that the VRF-based mechanism executes fairly and predictably.

# Peridot V2 

This repository contains the smart contracts & Frontend for Peridot V2, a decentralized lending protocol, potentially with cross-chain capabilities facilitated by a Hub and Spoke architecture.

# Backend

## Overview

The Peridot V2 protocol allows users to lend and borrow assets. Key components include:

- `Peridottroller`: The risk management and governance layer of the protocol.
- `PToken`: Represents supplied assets (e.g., `PErc20`, `PEther`). Users mint PTokens when supplying assets and earn interest.
- `PriceOracle`: Provides price feeds for assets.
- `PeridotHub` / `PeridotSpoke`: Components likely enabling cross-chain functionality, possibly interacting with messaging layers like Wormhole.
- `NTTSpokeToken`: Potentially related to Native Token Transfers across chains.

The contracts are built and deployed using the [Foundry](https://github.com/foundry-rs/foundry) development toolkit.

## Prerequisites

- [Git](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git)
- [Foundry](https://book.getfoundry.sh/getting-started/installation)

## Setup

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/PeridotFinance/PeridotV2Full.git
    ```
2.  **Install contracts:**
    ```bash
    npm install
    ```

## Deployment

The contracts are deployed using Hardhat &d Forge scripts located in the `script/` directory.

**Environment Variables:**

Before running deployment scripts, you typically need to set environment variables, such as:

- `RPC_URL`: The RPC endpoint for the target blockchain.
- `PRIVATE_KEY`: The private key of the deployer account.

You can also

```bash
export PRIVATE_KEY=YOURPRIVATEEKEY
```

instead of using Environment Variables

Note that Wormhole is currently not available on Soneium and IOTA yet.

**Example Deployment Command:**

```bash
forge script script/DeployHub.s.sol:DeployHubScript --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv
```

Replace `script/DeployHub.s.sol:DeployHubScript` with the specific script and contract name you want to deploy. Add necessary constructor arguments or script variables via command-line flags or environment variables as defined within your scripts.

**Key Deployment Scripts & Order:**

Deploying Peridot V2 involves multiple steps, and the order matters due to dependencies between contracts. While the exact sequence might vary based on specific configurations, the typical order is:

1.  **Price Oracle:** Deploy the chosen price feed mechanism.
    - `DeployOracle.s.sol`: Deploys the `SimplePriceOracle` or potentially configures another oracle source.
2.  **Peridottroller Implementation:** Deploy the main logic contract.
    - `DeployPeridottroller.s.sol`: Deploys the `Peridottroller` implementation (e.g., `PeridottrollerG7`).
3.  **Unitroller (Proxy Admin & Storage):** Deploy the proxy contract that holds storage and points to the implementation. The `Peridottroller` implementation address is needed here.
    - `DeployEIP1967Proxy.s.sol` (or similar logic within `DeployPeridottroller.s.sol`): Deploys the `Unitroller` proxy and sets its initial implementation.
4.  **Interest Rate Models:** Deploy the interest rate model(s) to be used by PTokens.
    - _(Script name might vary - could be part of PToken deployment or separate, e.g., deploying `JumpRateModelV2`)_
5.  **PToken Implementations & Proxies:** Deploy the logic for each PToken market and its corresponding proxy (delegator). These often need the `Peridottroller` address and an interest rate model address.
    - `DeployPErc20.s.sol`: Deploys `PErc20Immutable` (implementation) and `PErc20Delegator` (proxy) for a given underlying ERC20 token.
    - `DeployPEther.s.sol`: Deploys the `PEther` market.
6.  **Hub/Spoke (If applicable):**
    - `DeployHub.s.sol`: Deploys the `PeridotHub` contract.
    - `DeploySpoke.s.sol`: Deploys `PeridotSpoke` contracts on connected chains. Hub address might be needed.
7.  **NTT (If applicable):**
    - `DeployNttSpokeToken.s.sol`: Deploys the `NTTSpokeToken` contract, likely needing Hub/Spoke addresses.
8.  **Initial Configuration:** Run scripts to link components, e.g., listing markets in the `Peridottroller`, setting price feeds in the oracle, setting emitters for cross-chain communication.
    - `SetEmitter.s.sol`: Configures cross-chain emitter addresses.

## Running Scripts

The `script/` directory also contains utility scripts for interacting with the deployed contracts.

**Example Script Execution:**

```bash
forge script script/AttestToken.s.sol:AttestTokenScript --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv
```

Similar to deployment, ensure required environment variables are set and pass any necessary arguments.

**Available Scripts:**

- `AttestToken.s.sol`: For registering tokens with the Wormhole cross-chain bridge.
- `CompletePayload.s.sol` / `CompleteTransfer.s.sol`: Used to finalize cross-chain operations initiated via Wormhole/NTT by submitting the VAA (Verified Action Approval).
- `DeployEIP1967Proxy.s.sol`: Deploys a standard EIP-1967 compliant proxy contract, often used for `Unitroller` or PToken delegators.
- `DeployERC20.s.sol`: Deploys a standard ERC20 token contract (For testing).
- `DeployHub.s.sol`: Deploys the `PeridotHub` contract.
- `DeployNttSpokeToken.s.sol`: Deploys the `NTTSpokeToken` contract.
- `DeployOracle.s.sol`: Deploys the `SimplePriceOracle`.
- `DeployPErc20.s.sol`: Deploys a `PErc20Immutable` implementation and a `PErc20Delegator` proxy for a specific underlying ERC20 token.
- `DeployPEther.s.sol`: Deploys the `PEther` market contract.
- `DeployPeridottoken.s.sol`: Deploys the `PeridotToken` contract.
- `DeployPeridottroller.s.sol`: Deploys the `Peridottroller` (or `PeridottrollerG7`) implementation contract.
- `DeploySpoke.s.sol`: Deploys the `PeridotSpoke` contract.
- `FetchPrice.s.sol`: Queries the deployed `PriceOracle` for an asset's price.
- `SetEmitter.s.sol`: Configures trusted emitter addresses in Hub/Spoke contracts.
- `SpokeDeposit.s.sol`: Initiates a deposit action on a `PeridotSpoke` contract.
- `TransferNttToken.s.sol`: Transfers NTT tokens, likely part of the cross-chain workflow.
- `TransferToken.s.sol`: Transfers standard ERC20 tokens (useful for setup or testing).
- `WrappedToken.s.sol`: Deploys Wrapped Token for Wormhole Bridge.

## Testing

Run the test suite using:

```bash
forge test
```

## Wormhole Integration for Cross-Chain Operations

Peridot V2 leverages Wormhole's interoperability protocol to enable its Hub & Spoke architecture for cross-chain lending and borrowing. This involves Wormhole's Core Messaging (via Relayers) and the Token Bridge, likely in conjunction with Native Token Transfers (NTT).

### Core Components and Flow

1.  **`PeridotHub.sol` (Hub Chain)**:

    - Acts as the central clearinghouse and logic center for all cross-chain operations.
    - **Receives Messages**: Implements `IWormholeReceiver` to accept messages originating from Spoke contracts. These messages are delivered by a Wormhole Relayer and typically contain user intents (e.g., deposit, borrow, repay, withdraw) along with necessary parameters. The Hub verifies that these messages come from trusted, registered Spoke contract addresses (emitters) on specific chains.
    - **Processes Actions**: Upon receiving a valid message, the `PeridotHub` decodes the payload and interacts with the core Peridot V2 lending protocol logic. This includes operations like minting `PToken`s upon deposit, processing borrow requests against available liquidity (managed by `Peridottroller`), handling repayments, and processing withdrawals.
    - **Handles Token Transfers (Receiving)**: When users deposit assets or make repayments from a Spoke chain, the underlying tokens are bridged to the Hub chain using Wormhole's Token Bridge. The `PeridotHub` uses `tokenBridge.completeTransfer()` to finalize the receipt of these assets, typically by processing the VAA (Verifiable Action Approval) generated by the Token Bridge for that transfer.
    - **Handles Token Transfers (Sending)**: When users borrow assets or withdraw their collateral, the `PeridotHub` initiates a token transfer from the Hub chain back to the user's address on the respective Spoke chain. This is done using `tokenBridge.transferTokens()`.
    - **Sends Receipts/Data**: After processing an action or sending tokens, the `PeridotHub` often sends a message back to the originating `PeridotSpoke` contract. This message, sent via `IWormholeRelayerSend`, can serve as a receipt, confirm the status of an operation, or carry data like the amount of tokens successfully sent.

2.  **`PeridotSpoke.sol` (Spoke Chains)**:
    - Serves as the user's interaction point on each connected non-Hub blockchain.
    - **Initiates Actions**: Users trigger cross-chain operations by calling functions like `deposit()`, `borrow()`, `repay()`, or `withdraw()` on their local `PeridotSpoke` contract.
    - **Sends Messages & Tokens to Hub**:
      - The `PeridotSpoke` contract constructs a payload detailing the user's action (e.g., "user A wants to deposit X amount of Token Y").
      - It uses `IWormholeRelayerSend` to send this payload as a Wormhole message to the `PeridotHub`'s address on the Hub chain. The user typically pays the fees for this cross-chain message relay.
      - For actions that involve sending tokens _to_ the Hub (like deposits and repayments), the `PeridotSpoke` contract first facilitates the transfer of the user's assets to itself, then approves the Wormhole Token Bridge to spend these tokens, and finally calls `tokenBridge.transferTokens()` to bridge the assets to the `PeridotHub`. The VAA from this token transfer is crucial for the Hub to later complete the transfer.
    - **Receives Messages & Tokens from Hub**:
      - The `PeridotSpoke` contract also implements `IWormholeReceiver`. This allows it to receive messages back from the `PeridotHub`, such as confirmations or, importantly, tokens being sent from the Hub (e.g., borrowed assets or withdrawn collateral).
      - When tokens are bridged from the Hub, the `PeridotSpoke` contract (or the user directly, depending on the flow) uses `tokenBridge.completeTransfer()` with the corresponding VAA to receive the actual assets on the Spoke chain.

### Native Token Transfers (NTT) and Token Bridge Attestation

- **NTT for Seamless Transfers**: The protocol appears to use Wormhole's Native Token Transfer (NTT) standard, as indicated by the presence of `NTTSpokeToken.sol` and related scripts. NTT allows tokens to be transferred across chains in a way that they retain their "native" characteristics on each chain, rather than always being represented as a generic "wrapped" asset. This can lead to a better user experience, improved composability, and potentially more gas-efficient transfers. In a Hub & Spoke model, NTT enables the `PeridotHub` to manage the canonical representation or total supply of a token, while Spoke chains can have native-feeling versions that are minted/burned (or locked/unlocked) in coordination with actions on the Hub.

- **Token Bridge Attestation for Trust and Integrity**:
  - **What it is**: Before any token can be transferred using the Wormhole Token Bridge (which is the mechanism for moving the actual value in Peridot V2's cross-chain lend/borrow operations), it must be "attested." Attestation is the process of registering an existing token on its source chain with Wormhole. This creates a canonical, Wormhole-recognized representation of that token. When this token is subsequently bridged to other chains, those chains receive a Wormhole-standard representation (wrapped, or native via NTT) that is verifiably linked to the original attested token.
  - **Importance for Peridot V2**:
    - **Asset Integrity & Security**: Attestation is fundamental to ensuring that the "USDC" (for example) deposited on Spoke Chain A is recognized and treated as the same legitimate "USDC" by the `PeridotHub` and by users on Spoke Chain B. It prevents the system from accepting spoofed or non-standard tokens.
    - **Consistent Valuation & Risk Management**: For the `PeridotHub` to accurately value collateral, calculate borrowing limits, and manage overall protocol risk, it needs a definitive understanding of each asset. Token attestation provides a single, cross-chain source of truth for token identity, which is a prerequisite for reliable price feeds and consistent accounting.
    - **Fungibility**: It ensures that the assets users receive (e.g., when borrowing or withdrawing) are the legitimate, Wormhole-recognized versions, fungible with other instances of that same token within the Wormhole ecosystem and on their native chains.
    - **Hub & Spoke Cohesion**: The entire Hub & Spoke model relies on the `PeridotHub` being able to trust the identity of assets coming from various Spoke chains. Token Bridge attestation establishes this trust by ensuring all participating tokens adhere to a common, verifiable standard recognized by Wormhole.

By combining Wormhole's generic messaging (via Relayers) for command-and-control, the Token Bridge (underpinned by attestation) for secure asset transfers, and potentially NTT for an enhanced native token experience, Peridot V2 aims to provide a robust and user-friendly platform for cross-chain lending and borrowing.


Wormholescan: https://wormholescan.io/#/tx/0x27130715563e782086fee736fed044d52dadc2a9c2fab5bfc3d8591dd9615de2?network=Testnet&view=overview

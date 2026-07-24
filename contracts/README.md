# Peridot Protocol

A cross-chain lending and rewards protocol built on **BNB Smart Chain (BSC)** and compatible with other EVM networks.

## Technology Stack

- Blockchain: BNB Smart Chain + EVM-compatible chains
- Smart Contracts: Solidity ^0.8.x
- Development: Foundry, OpenZeppelin libraries, Chainlink price feeds, Axelar GMP (cross-chain)

## Supported Networks

- BNB Smart Chain Mainnet (Chain ID: 56)
- BNB Smart Chain Testnet (Chain ID: 97)
- Arbitrum Sepolia / other EVM testnets for spokes

## Contract Addresses

| Network     | Core Comptroller (Proxy)                   | PERIDOT Token ($P)                         | Optional (Oracle / Rate Model)                                                                      |
| ----------- | ------------------------------------------ | ------------------------------------------ | --------------------------------------------------------------------------------------------------- |
| BNB Mainnet | 0xc1306A30490C8566D09f617e85BB503B55B547eC | 0x96650BebC549456F253974c11Fc6cBE28172A2d2 | Oracle: 0x42D5B37CD3682eDD0a3dBb242C579bDCB108f47C, IRM: 0x16d8e28777581d8A4bf282aDB694e9F987019111 |
| BNB Testnet | 0xe8F09917d56Cc5B634f4DE091A2c82189dc41b54 | 0x5A5063a749fCF050CE58Cae6bB76A29bb37BA4Ed | —                                                                                                   |

See `addresses.MD` for the full list (spokes, markets, adapters).

## Features

- Compound-style lending markets (PToken, PEther) on BNB Chain
- Cross-chain supply/borrow via Axelar (Hub/Spoke architecture)
- PERIDOT incentives (supply/borrow rewards) with on-chain claiming
- xPeridot vault + staking with APR and tiered rewards (V2)
- Chainlink-integrated price oracle with staleness fallback
- Robinhood Chain pUSDG market whose delegator is the USDG side account of the paired
  NVDA/USDG vault

## Repository Layout

- `contracts/`
  - `core/`: Core lending and protocol contracts (PTokens, Peridottroller, models, oracle)
  - `cross-chain/`: Hub/Spoke and PErc20CrossChain for Axelar flows
  - `xperidot/`: xPeridot vault, staking, tier rewards
  - `interfaces/`, `helpers/`, `proxy/`, `utils/`: supporting modules
- `script/`: Foundry scripts for deployment and ops on BNB Chain + spokes
- `test/`: Foundry tests (forge-std)
- `docs/`: Design notes and integration guides (Axelar flows, APYs)

## Build, Test, and Deploy

- Compile: `forge build`
- Run tests: `forge test`
- Fork tests: set `MONAD_RPC_URL` (and optionally `WMON_ADDRESS`, `MAGMA_ADDRESS`) for Monad fork tests; some skip if required system contracts are missing on the RPC.
- Local node: `anvil`
- Deploy Comptroller (BNB): `forge script script/DeployPeridottroller.s.sol --rpc-url $BNBMAIN_RPC --private-key $PRIVATE_KEY --broadcast`
- Deploy pToken: `forge script script/DeployPErc20Fixed.s.sol --rpc-url $BNBMAIN_RPC --private-key $PRIVATE_KEY --broadcast`
- Deploy the initially paused Robinhood pUSDG delegator:
  `forge script script/DeployRobinhoodBoostedDelegator.s.sol:DeployRobinhoodBoostedDelegator --rpc-url $ROBINHOOD_RPC_URL --broadcast`
- Verify (BscScan): `forge verify-contract --chain bsc <address> <path:Contract> --etherscan-api-key $BNB_KEY`

### Robinhood pUSDG activation order

`RobinhoodBoostedDelegate` is a specialized `PErc20Delegate`; do not connect the paired
vault through the generic `IBoostedYieldAdapter`. Delegate calls execute from the
`PErc20Delegator`, so the deployed pUSDG delegator is the vault's `USDG_SIDE_ACCOUNT`.

1. Deploy the delegate and delegator with empty initialization data. It starts
   unconfigured and paused.
2. Register the production `NVDA/USDG` vault pair with the delegator as its USDG side
   account.
3. From the pToken admin/timelock, queue `setVaultConfig(vault, pairId, buffer, operator)`,
   wait for `actionDelay`, then execute `_setVaultConfig`.
4. Through vault governance, unpause allocation for the production pair while leaving
   settlement swaps paused.
5. Queue `setVaultPaused(false)`, wait, execute it, and verify the delegator remains the
   vault-reported side account and its vault allowance is zero after operations.

`ConfigureRobinhoodBoostedDelegator.s.sol` emits the queue/execute timelock payload for
each pUSDG admin action. Choose one of `queue-config`, `execute-config`,
`queue-unpause`, or `execute-unpause` through `PUSDG_ADMIN_ACTION`. It prints calldata by
default; `DIRECT_ADMIN_BROADCAST=true` is an explicit EOA-admin-only escape hatch.

Exchange-rate accounting includes the full `accountedAssets` claim. Cash/liquidity checks
include only `liquidAssets`. Vault withdrawal loss is applied before redemption tokens
are burned or underlying is paid, while idle-only exits remain available if the vault's
LP path is unavailable.

Environment

- Set envs in `.env` (see `.env.example`): `BNBMAIN_RPC`, `BNB_TESTNET_RPC_URL`, `PRIVATE_KEY`, `BNB_KEY`, etc.

## BNB Chain Repository Submission Guidelines

This repository is intended for deployment on BNB Chain and includes strong indicators:

- README and scripts explicitly target BNB Chain
- BNB Chain addresses in `addresses.MD`
- Axelar hub on BNB and spokes on other EVM chains
- Chainlink feeds configured for BNB

## Security

- Follows checks-effects-interactions; reentrancy guards where appropriate
- Admin-controlled parameters are isolated and validated
- Never commit secrets; use `.env`

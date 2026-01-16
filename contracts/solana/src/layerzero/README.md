## LayerZero OFT (Solana) – next step placeholder

This directory is reserved for the Solana-side LayerZero OFT integration.

Planned contents:

- Scripts to deploy/configure the Solana OFT program or adapter (depending on LayerZero’s recommended architecture)
- Peer wiring helpers:
  - Solana peer -> EVM `setPeer(eid, bytes32(peer))`
  - EVM peer -> Solana pubkey bytes32
- Config files tracking:
  - Solana OFT program ID
  - Solana mint address
  - Solana endpoint IDs (EIDs)
  - EVM adapter addresses (BSC testnet, Base Sepolia, etc.)

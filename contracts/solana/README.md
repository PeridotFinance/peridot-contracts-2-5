## Peridot Solana

This folder contains a standalone Node/TypeScript setup to:

- Create a fungible SPL token mint
- Mint supply to an account (ATA)
- Create Metaplex Token Metadata (name/symbol/uri) for the mint

### Setup

```bash
cd /home/josh/peridot-ccip/contracts/solana
npm install
cp env.example .env
```

Fill in:

- `SOLANA_RPC_URL`
- `SOLANA_KEYPAIR_PATH` (a Solana CLI keypair JSON file)

### Create mint (optionally mint initial supply)

```bash
npm run token:create
```

If you set `MINT_TO` + `MINT_AMOUNT` in `.env`, it will mint right after creating the mint.

### Mint more to an address

```bash
npm run token:mint
```

### Set Metaplex metadata for the mint

```bash
npm run token:metadata
```

### Next (LayerZero OFT on Solana)

Once the Solana mint + metadata are deployed, the next step is wiring the mint into the LayerZero Solana OFT flow and setting peers between:

- Solana OFT program / adapter
- EVM `P_OFTAdapterUpgradeable` proxies

## Peridot: Solana ↔ EVM OFT (LayerZero V2)

This directory is a vendored copy of LayerZero’s official `oft-solana` example, placed here so you can:

- Deploy **your own Solana OFT Program** (you control the upgrade authority)
- Create an **OFT Store** for an **existing SPL mint** (Adapter pattern)
- Wire it to your existing EVM `P_OFTAdapterUpgradeable` proxies

LayerZero docs:

- [Getting Started with Solana](https://docs.layerzero.network/v2/developers/solana/getting-started)
- [Solana OFT Overview](https://docs.layerzero.network/v2/developers/solana/oft/overview)

### What you already did

You minted an SPL token on devnet:

- **Mint**: `ENiCZ2pc3uhD8zewSYxRaBnATdF8G8d9UfiVHquY3gW9`

### Setup

```bash
cd /home/josh/peridot-ccip/contracts/solana/layerzero-oft
cp env.example .env
```

If `pnpm` is missing in your terminal, enable it via corepack (recommended for this workspace):

```bash
corepack enable
corepack prepare pnpm@8.15.6 --activate
pnpm --version
```

Set in `.env`:

- `SOLANA_KEYPAIR_PATH=/home/josh/peridot-ccip/contracts/solana/id.json`
- `RPC_URL_SOLANA_TESTNET=https://api.devnet.solana.com`
- `SOLANA_MINT_ADDRESS=ENiCZ2pc3uhD8zewSYxRaBnATdF8G8d9UfiVHquY3gW9`

If Solana Hardhat tasks fail with `TypeError: fetch failed` / `UND_ERR_CONNECT_TIMEOUT`, export:

```bash
export NODE_OPTIONS=--dns-result-order=ipv4first
```

### 1) Create the OFT Program ID keypair

```bash
anchor keys sync -p oft
anchor keys list
```

Copy the `oft:` program id.

### 2) Build + deploy the Solana OFT Program (devnet)

LayerZero recommends verifiable builds; you’ll need Docker for `anchor build -v`.

```bash
# IMPORTANT: use `-e OFT_ID=...` so the verifiable docker build embeds the correct program id
anchor build -v -e OFT_ID=<OFT_PROGRAM_ID>
solana program deploy --program-id target/deploy/oft-keypair.json target/verifiable/oft.so -u devnet
```

### 3) Create an OFT **Adapter** (OFT Store) for your existing mint

This creates the **OFT Store PDA** + escrow needed for the adapter model.

LayerZero’s Solana “testnet” EID is **40168** (devnet).

```bash
npm install
npx hardhat lz:oft-adapter:solana:create \\
  --eid 40168 \\
  --mint $SOLANA_MINT_ADDRESS \\
  --program-id <OFT_PROGRAM_ID>
```

This writes a deployment file under `deployments/` with:

- `programId`
- `escrow`
- `oftStore`

### Important: “seeding escrow” vs “seeding TVL” (why inbound can fail)

For Solana **Adapter** OFTs, the program tracks locked liquidity in `oft_store.tvl_ld` (total value locked).

- **Solana → EVM send**: transfers tokens into escrow **and increments** `tvl_ld`
- **EVM → Solana receive**: transfers tokens out of escrow **and decrements** `tvl_ld`

So **minting/transferring tokens directly into the escrow token account is NOT sufficient** to allow EVM → Solana receives:
it increases the token account balance, but **does not** increase `tvl_ld`, and `lz_receive` will revert (underflow on `tvl_ld -= amount`).

#### How to seed Solana-side liquidity correctly

Do **at least one** Solana → EVM OFT send (even a small one) to create TVL:

```bash
cd /home/josh/peridot-ccip/contracts/solana/layerzero-oft

# Example: Solana devnet (40168) -> BSC testnet (40102)
# `--oft-address` for Solana is the OFT Store PDA (base58).
LZ_ASSUME_YES=1 pnpm hardhat lz:oft:send \
  --src-eid 40168 \
  --dst-eid 40102 \
  --amount 10 \
  --to 0xYOUR_EVM_ADDRESS \
  --oft-address 7AHDsHiJrbrhVQBRuPkbH6MqUAi7xMePuMk1zJwKRB4C
```

Once you have `tvl_ld > 0`, EVM → Solana receives can succeed (subject to normal wiring/options).

### Next: peer wiring to EVM

Once you have the `oftStore` address, we can:

- Set **EVM adapter peer → Solana** with `setPeer(solEid, bytes32(oftStorePubkey))`
- Set **Solana OFT Store peer → EVM** using LayerZero’s wiring tasks

In our Peridot EVM world, the relevant EIDs are:

- **BSC testnet**: `40102`
- **Base Sepolia**: `40245`

#### EVM adapter peer → Solana (Foundry)

On each EVM chain, run your existing peer config script but set:

- `REMOTE_EID=40168` (Solana devnet)
- `REMOTE_PEER=0x<64-hex-chars>` (32-byte value from the Solana `oftStore` pubkey)

For bytes32 encoding: the Solana pubkey is already 32 bytes; you can use its raw 32 bytes as `bytes32`.

To convert Solana base58 pubkey → bytes32 hex:

```bash
cd /home/josh/peridot-ccip/contracts/solana
node --input-type=module -e "import bs58 from 'bs58'; const pk=process.argv[1]; console.log('0x'+Buffer.from(bs58.decode(pk)).toString('hex'))" <SOLANA_PUBKEY_BASE58>
```

Then set the peer on the EVM adapter:

```bash
cd /home/josh/peridot-ccip/contracts
forge script script/SetOAppPeer.s.sol \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --sig "run()" \
  -- \
  --env LOCAL_OAPP=$OFT_ADAPTER \
  --env REMOTE_EID=40168 \
  --env REMOTE_PEER=0x...
```

#### Solana OFT Store peer → EVM

From this workspace, once you have the EVM adapter address on e.g. Base Sepolia, you can use the Solana config tasks to set peer config for the EVM chain(s).
We’ll do this after you paste:

- the deployed Solana `OFT_ID` (program id)
- the created `oftStore` address
- your EVM adapter proxy addresses on BSC + Base

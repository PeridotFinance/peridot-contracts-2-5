import "dotenv/config";
import { createUmi } from "@metaplex-foundation/umi-bundle-defaults";
import { keypairIdentity, publicKey } from "@metaplex-foundation/umi";
import {
  createMetadataAccountV3,
  findMetadataPda,
  mplTokenMetadata,
} from "@metaplex-foundation/mpl-token-metadata";

import { loadKeypairFromFile, mustEnv, pubkeyFromAny } from "../lib/solana.js";

/**
 * Creates Metaplex Token Metadata for an existing SPL mint.
 *
 * For fungible SPL tokens, this is the common “Metaplex metadata” pattern:
 * - metadata PDA = ['metadata', mpl_token_metadata_program_id, mint]
 * - data includes name/symbol/uri
 */
async function main() {
  const payerWeb3 = loadKeypairFromFile(mustEnv("SOLANA_KEYPAIR_PATH"));
  const umi = createUmi(mustEnv("SOLANA_RPC_URL")).use(mplTokenMetadata());
  const payer = umi.eddsa.createKeypairFromSecretKey(payerWeb3.secretKey);
  umi.use(keypairIdentity(payer));

  const mint = publicKey(pubkeyFromAny(mustEnv("MINT_ADDRESS")).toBase58());
  const name = mustEnv("TOKEN_NAME");
  const symbol = mustEnv("TOKEN_SYMBOL");
  const uri = mustEnv("TOKEN_URI");

  const metadataPda = findMetadataPda(umi, { mint });
  const builder = createMetadataAccountV3(umi, {
    metadata: metadataPda,
    mint,
    mintAuthority: umi.identity,
    payer: umi.payer,
    updateAuthority: umi.identity.publicKey,
    data: {
      name,
      symbol,
      uri,
      sellerFeeBasisPoints: 0,
      creators: null,
      collection: null,
      uses: null,
    },
    isMutable: true,
    collectionDetails: null,
  });

  const result = await builder.sendAndConfirm(umi);

  console.log("Mint:", mint.toString());
  console.log("Metadata PDA:", metadataPda.toString());
  console.log("Update authority:", umi.identity.publicKey.toString());
  console.log("Name:", name);
  console.log("Symbol:", symbol);
  console.log("URI:", uri);
  console.log("Tx:", result.signature.toString());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

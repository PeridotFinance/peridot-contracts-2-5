import "dotenv/config";
import { Keypair, PublicKey } from "@solana/web3.js";
import {
  createMint,
  getOrCreateAssociatedTokenAccount,
  mintTo,
} from "@solana/spl-token";

import {
  envNumber,
  getConnection,
  loadKeypairFromFile,
  mustEnv,
  pubkeyFromAny,
} from "../lib/solana.js";

async function main() {
  const connection = getConnection();
  const payer = loadKeypairFromFile(mustEnv("SOLANA_KEYPAIR_PATH"));

  const decimals = envNumber("TOKEN_DECIMALS");
  const mintAuthority = payer.publicKey;
  const freezeAuthority: PublicKey | null = payer.publicKey;

  const mint = await createMint(
    connection,
    payer,
    mintAuthority,
    freezeAuthority,
    decimals
  );

  console.log("Mint:", mint.toBase58());
  console.log("Mint authority:", mintAuthority.toBase58());
  console.log("Decimals:", decimals);

  // Optional: mint an initial amount to a recipient (ATA)
  const mintToStr = process.env.MINT_TO;
  const mintAmountStr = process.env.MINT_AMOUNT;
  if (mintToStr && mintAmountStr) {
    const owner = pubkeyFromAny(mintToStr);
    const amount = BigInt(mintAmountStr);

    const ata = await getOrCreateAssociatedTokenAccount(
      connection,
      payer,
      mint,
      owner
    );

    const sig = await mintTo(
      connection,
      payer,
      mint,
      ata.address,
      payer,
      amount
    );
    console.log("Minted to:", owner.toBase58());
    console.log("ATA:", ata.address.toBase58());
    console.log("Amount (raw):", amount.toString());
    console.log("Tx:", sig);
  } else {
    console.log(
      "Skipped initial mint (set MINT_TO and MINT_AMOUNT to mint immediately)."
    );
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

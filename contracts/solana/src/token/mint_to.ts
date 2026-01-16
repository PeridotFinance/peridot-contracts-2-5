import "dotenv/config";
import { getOrCreateAssociatedTokenAccount, mintTo } from "@solana/spl-token";

import {
  getConnection,
  loadKeypairFromFile,
  mustEnv,
  pubkeyFromAny,
} from "../lib/solana.js";

async function main() {
  const connection = getConnection();
  const payer = loadKeypairFromFile(mustEnv("SOLANA_KEYPAIR_PATH"));

  const mint = pubkeyFromAny(mustEnv("MINT_ADDRESS"));
  const to = pubkeyFromAny(mustEnv("MINT_TO"));
  const amount = BigInt(mustEnv("MINT_AMOUNT"));

  const ata = await getOrCreateAssociatedTokenAccount(
    connection,
    payer,
    mint,
    to
  );
  const sig = await mintTo(connection, payer, mint, ata.address, payer, amount);

  console.log("Mint:", mint.toBase58());
  console.log("To:", to.toBase58());
  console.log("ATA:", ata.address.toBase58());
  console.log("Amount (raw):", amount.toString());
  console.log("Tx:", sig);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

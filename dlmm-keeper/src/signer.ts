// EXTERNAL SIGNER ABSTRACTION (adapted from the production keeper). The keeper logic never touches key material: it talks to an `ExternalSigner`.
// First implementation: a Foundry keystore account (an encrypted Web3 Secret Storage v3 JSON file, as made by `cast wallet new` / `cast wallet import`).
// BOTH the keystore PATH and the PASSWORD FILE path come from the environment (DLMM_KEEPER_KEYSTORE_PATH, DLMM_KEEPER_KEYSTORE_PASSWORD_FILE). The password
// is read from the file, registered with mask() at once, and is never in the configuration, an argument, a log or an alert. This module (and main.ts, which builds
// it) are the ONLY places in src/ that may hold or use a signer; a test enforces that.
import fs from "node:fs";
import { BigNumber, providers, Wallet } from "ethers";
import { registerSecret } from "./mask";

export interface TxRequest {
  to: string;
  data: string;
  gasLimit: BigNumber;
  maxFeePerGas: BigNumber;
  maxPriorityFeePerGas: BigNumber;
}
export interface MinedTx {
  status?: number;
  blockNumber: number;
  gasUsed: BigNumber;
}
export interface SentTx {
  hash: string;
  wait(): Promise<MinedTx>;
}
export interface ExternalSigner {
  readonly kind: string;
  getAddress(): Promise<string>;
  /** sign with the external key and broadcast; the keeper decides WHAT to send, the signer only signs and sends it */
  sendTransaction(tx: TxRequest): Promise<SentTx>;
}
export class SignerError extends Error {}

function secretFileChecks(file: string, what: string): void {
  let st: fs.Stats;
  try {
    st = fs.statSync(file);
  } catch {
    throw new SignerError(`${what} file not found or unreadable`);
  }
  if (!st.isFile()) throw new SignerError(`${what} path is not a file`);
  if (process.platform !== "win32" && (st.mode & 0o077) !== 0) throw new SignerError(`${what} file is accessible to group/other (chmod 600)`);
}

export class KeystoreSigner implements ExternalSigner {
  readonly kind = "foundry-keystore";
  private constructor(private readonly wallet: Wallet) {}

  /** Decrypts the keystore (scrypt, can take seconds). Errors never carry the password or the file content. */
  static async load(provider: providers.Provider, env: NodeJS.ProcessEnv = process.env): Promise<KeystoreSigner> {
    const ksPath = env.DLMM_KEEPER_KEYSTORE_PATH;
    const pwPath = env.DLMM_KEEPER_KEYSTORE_PASSWORD_FILE;
    if (!ksPath) throw new SignerError("DLMM_KEEPER_KEYSTORE_PATH is not set in the environment");
    if (!pwPath) throw new SignerError("DLMM_KEEPER_KEYSTORE_PASSWORD_FILE is not set in the environment");
    secretFileChecks(pwPath, "keystore password");
    const password = fs.readFileSync(pwPath, "utf8").replace(/[\r\n]+$/, "");
    if (!password) throw new SignerError("the keystore password file is empty");
    registerSecret(password);
    secretFileChecks(ksPath, "keystore");
    const json = fs.readFileSync(ksPath, "utf8");
    let wallet: Wallet;
    try {
      wallet = await Wallet.fromEncryptedJson(json, password);
    } catch {
      throw new SignerError("keystore could not be decrypted (wrong password or not a Web3 Secret Storage keystore)");
    }
    return new KeystoreSigner(wallet.connect(provider));
  }
  async getAddress(): Promise<string> {
    return this.wallet.address;
  }
  async sendTransaction(tx: TxRequest): Promise<SentTx> {
    const sent = await this.wallet.sendTransaction({ type: 2, to: tx.to, data: tx.data, value: 0, gasLimit: tx.gasLimit, maxFeePerGas: tx.maxFeePerGas, maxPriorityFeePerGas: tx.maxPriorityFeePerGas });
    return {
      hash: sent.hash,
      wait: async () => {
        const r = await sent.wait(1);
        return { status: r.status, blockNumber: r.blockNumber, gasUsed: r.gasUsed };
      },
    };
  }
}

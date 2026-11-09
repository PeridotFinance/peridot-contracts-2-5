// COPIED from operator/src (no runtime import from operator/).
// EXTERNAL SIGNER ABSTRACTION. The keeper (and, later, the liquidator executor) never touches key material: it talks to an `ExternalSigner`.
// First implementation: a Foundry keystore account (an encrypted Web3 Secret Storage v3 JSON file, as made by `cast wallet new` /
// `cast wallet import`). The PASSWORD is read from the environment variable NAMED by the configuration (the host's secret store injects it);
// it is never in a file, an argument, a log or an alert (it is registered with mask() the moment it is read). This module and keeper.ts are the
// ONLY places in src/ that may hold or use a signer; a test enforces that.
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

export class KeystoreSigner implements ExternalSigner {
  readonly kind = "foundry-keystore";
  private constructor(private readonly wallet: Wallet) {}

  /** Decrypts the keystore (scrypt, can take seconds). Errors never carry the password or the file content. */
  static async load(provider: providers.Provider, keystorePath: string, passwordEnv: string, env: NodeJS.ProcessEnv = process.env): Promise<KeystoreSigner> {
    const password = env[passwordEnv];
    if (!password) throw new SignerError(`keystore password: the environment variable ${passwordEnv} is not set (inject it from the host's secret store)`);
    registerSecret(password);
    let st: fs.Stats;
    try {
      st = fs.statSync(keystorePath);
    } catch {
      throw new SignerError("keystore file not found or unreadable");
    }
    if (!st.isFile()) throw new SignerError("keystore path is not a file");
    if (process.platform !== "win32" && (st.mode & 0o007) !== 0) throw new SignerError("keystore file is accessible to other users (mode must have no 'other' permissions; chmod 600)");
    const json = fs.readFileSync(keystorePath, "utf8");
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

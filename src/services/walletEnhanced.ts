import { ethers } from "ethers";
import * as crypto from "crypto";
import { promisify } from "util";

const scrypt = promisify(crypto.scrypt);

export interface GeneratedWallet {
  address: string;
  privateKey: string;
  mnemonic: string;
  encryptedPrivateKey?: string;
}

export interface StoredWallet {
  address: string;
  encryptedPrivateKey: string;
  encryptedMnemonic: string;
  salt: string;
  kdfParams: {
    algorithm: string;
    N: number;
    r: number;
    p: number;
    keylen: number;
  };
  createdAt: Date;
  userId: number;
  hasPassphrase: boolean;
}

export interface UserPassphrase {
  userId: number;
  hashedPassphrase: string;
  salt: string;
  createdAt: Date;
}

export class WalletEnhancedService {
  private wallets: Map<number, StoredWallet> = new Map();
  private passphrases: Map<number, UserPassphrase> = new Map();

  // Scrypt parameters for key derivation
  private readonly kdfParams = {
    algorithm: "scrypt",
    N: 16384, // CPU/memory cost parameter
    r: 8, // Block size parameter
    p: 1, // Parallelization parameter
    keylen: 32, // Key length in bytes
  };

  /**
   * Generate a new wallet for a user
   */
  generateWallet(): GeneratedWallet {
    const wallet = ethers.Wallet.createRandom();
    return {
      address: wallet.address,
      privateKey: wallet.privateKey,
      mnemonic: wallet.mnemonic?.phrase || "",
    };
  }

  /**
   * Set or update user passphrase
   */
  async setUserPassphrase(userId: number, passphrase: string): Promise<void> {
    const salt = crypto.randomBytes(32);
    const hashedPassphrase = (await scrypt(passphrase, salt, 64)) as Buffer;

    this.passphrases.set(userId, {
      userId,
      hashedPassphrase: hashedPassphrase.toString("hex"),
      salt: salt.toString("hex"),
      createdAt: new Date(),
    });
  }

  /**
   * Verify user passphrase
   */
  async verifyPassphrase(userId: number, passphrase: string): Promise<boolean> {
    const stored = this.passphrases.get(userId);
    if (!stored) return false;

    const salt = Buffer.from(stored.salt, "hex");
    const hashedInput = (await scrypt(passphrase, salt, 64)) as Buffer;
    const storedHash = Buffer.from(stored.hashedPassphrase, "hex");

    return crypto.timingSafeEqual(hashedInput, storedHash);
  }

  /**
   * Derive encryption key from user passphrase and salt
   */
  private async deriveKey(
    userId: number,
    passphrase?: string
  ): Promise<Buffer> {
    const userPassphrase = this.passphrases.get(userId);

    if (userPassphrase && passphrase) {
      // Use user-defined passphrase
      const isValid = await this.verifyPassphrase(userId, passphrase);
      if (!isValid) {
        throw new Error("Invalid passphrase");
      }

      const salt = Buffer.from(userPassphrase.salt, "hex");
      return (await scrypt(passphrase, salt, this.kdfParams.keylen)) as Buffer;
    } else {
      // Fall back to user ID-based key (for backwards compatibility)
      const salt = crypto
        .createHash("sha256")
        .update(`user_${userId}_salt`)
        .digest();
      return (await scrypt(
        `user_${userId}`,
        salt,
        this.kdfParams.keylen
      )) as Buffer;
    }
  }

  /**
   * Encrypt private key with enhanced security
   */
  private async encryptPrivateKey(
    privateKey: string,
    userId: number,
    passphrase?: string
  ): Promise<{ encrypted: string; salt: string }> {
    const key = await this.deriveKey(userId, passphrase);
    const salt = crypto.randomBytes(16);
    const iv = crypto.randomBytes(16);

    const cipher = crypto.createCipher("aes-256-gcm", key);
    cipher.setAAD(salt);

    let encrypted = cipher.update(privateKey, "utf8", "hex");
    encrypted += cipher.final("hex");

    const authTag = cipher.getAuthTag();

    // Combine IV, auth tag, and encrypted data
    const combined = Buffer.concat([
      iv,
      authTag,
      Buffer.from(encrypted, "hex"),
    ]);

    return {
      encrypted: combined.toString("hex"),
      salt: salt.toString("hex"),
    };
  }

  /**
   * Decrypt private key with enhanced security
   */
  private async decryptPrivateKey(
    encryptedData: string,
    salt: string,
    userId: number,
    passphrase?: string
  ): Promise<string> {
    const key = await this.deriveKey(userId, passphrase);
    const combined = Buffer.from(encryptedData, "hex");

    // Extract IV, auth tag, and encrypted data
    const iv = combined.slice(0, 16);
    const authTag = combined.slice(16, 32);
    const encrypted = combined.slice(32);

    const decipher = crypto.createDecipher("aes-256-gcm", key);
    decipher.setAAD(Buffer.from(salt, "hex"));
    decipher.setAuthTag(authTag);

    let decrypted = decipher.update(encrypted, undefined, "utf8");
    decrypted += decipher.final("utf8");

    return decrypted;
  }

  /**
   * Create and store a wallet for a user with optional passphrase
   */
  async createWalletForUser(
    userId: number,
    passphrase?: string
  ): Promise<GeneratedWallet> {
    const wallet = this.generateWallet();

    // Encrypt the wallet data
    const encryptedPrivateKey = await this.encryptPrivateKey(
      wallet.privateKey,
      userId,
      passphrase
    );
    const encryptedMnemonic = await this.encryptPrivateKey(
      wallet.mnemonic,
      userId,
      passphrase
    );

    const storedWallet: StoredWallet = {
      address: wallet.address,
      encryptedPrivateKey: encryptedPrivateKey.encrypted,
      encryptedMnemonic: encryptedMnemonic.encrypted,
      salt: encryptedPrivateKey.salt,
      kdfParams: this.kdfParams,
      createdAt: new Date(),
      userId,
      hasPassphrase: !!passphrase,
    };

    this.wallets.set(userId, storedWallet);

    return {
      ...wallet,
      encryptedPrivateKey: encryptedPrivateKey.encrypted,
    };
  }

  /**
   * Get stored wallet for a user
   */
  getUserWallet(userId: number): StoredWallet | null {
    return this.wallets.get(userId) || null;
  }

  /**
   * Get decrypted private key for a user
   */
  async getPrivateKey(
    userId: number,
    passphrase?: string
  ): Promise<string | null> {
    const wallet = this.wallets.get(userId);
    if (!wallet) return null;

    try {
      return await this.decryptPrivateKey(
        wallet.encryptedPrivateKey,
        wallet.salt,
        userId,
        passphrase
      );
    } catch (error) {
      console.error("Error decrypting private key:", error);
      return null;
    }
  }

  /**
   * Get mnemonic for a user
   */
  async getMnemonic(
    userId: number,
    passphrase?: string
  ): Promise<string | null> {
    const wallet = this.wallets.get(userId);
    if (!wallet) return null;

    try {
      return await this.decryptPrivateKey(
        wallet.encryptedMnemonic,
        wallet.salt,
        userId,
        passphrase
      );
    } catch (error) {
      console.error("Error decrypting mnemonic:", error);
      return null;
    }
  }

  /**
   * Check if user has a wallet
   */
  hasWallet(userId: number): boolean {
    return this.wallets.has(userId);
  }

  /**
   * Check if user has set a passphrase
   */
  hasPassphrase(userId: number): boolean {
    const wallet = this.wallets.get(userId);
    return wallet?.hasPassphrase || false;
  }

  /**
   * Remove wallet for a user
   */
  removeWallet(userId: number): boolean {
    const removed = this.wallets.delete(userId);
    this.passphrases.delete(userId);
    return removed;
  }

  /**
   * Get wallet statistics
   */
  getStats(): {
    totalWallets: number;
    walletsCreatedToday: number;
    walletsWithPassphrase: number;
  } {
    const today = new Date();
    today.setHours(0, 0, 0, 0);

    let walletsCreatedToday = 0;
    let walletsWithPassphrase = 0;

    for (const wallet of this.wallets.values()) {
      if (wallet.createdAt >= today) {
        walletsCreatedToday++;
      }
      if (wallet.hasPassphrase) {
        walletsWithPassphrase++;
      }
    }

    return {
      totalWallets: this.wallets.size,
      walletsCreatedToday,
      walletsWithPassphrase,
    };
  }
}

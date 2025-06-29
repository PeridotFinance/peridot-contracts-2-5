import { ethers } from "ethers";
import * as crypto from "crypto";

export interface GeneratedWallet {
  address: string;
  privateKey: string;
  mnemonic: string;
  encryptedPrivateKey?: string;
}

export interface StoredWallet {
  address: string;
  encryptedPrivateKey: string;
  createdAt: Date;
  userId: number;
}

export class WalletService {
  private wallets: Map<number, StoredWallet> = new Map();

  /**
   * Generate a new wallet for a user
   */
  generateWallet(): GeneratedWallet {
    // Create a random wallet
    const wallet = ethers.Wallet.createRandom();

    return {
      address: wallet.address,
      privateKey: wallet.privateKey,
      mnemonic: wallet.mnemonic?.phrase || "",
    };
  }

  /**
   * Encrypt a private key with a simple encryption (for demo purposes)
   * In production, use proper encryption with user passwords
   */
  private encryptPrivateKey(privateKey: string, userId: number): string {
    const cipher = crypto.createCipher("aes192", `user_${userId}_salt`);
    let encrypted = cipher.update(privateKey, "utf8", "hex");
    encrypted += cipher.final("hex");
    return encrypted;
  }

  /**
   * Decrypt a private key
   */
  private decryptPrivateKey(
    encryptedPrivateKey: string,
    userId: number
  ): string {
    const decipher = crypto.createDecipher("aes192", `user_${userId}_salt`);
    let decrypted = decipher.update(encryptedPrivateKey, "hex", "utf8");
    decrypted += decipher.final("utf8");
    return decrypted;
  }

  /**
   * Create and store a wallet for a user
   */
  createWalletForUser(userId: number): GeneratedWallet {
    const wallet = this.generateWallet();

    // Encrypt and store the wallet
    const encryptedPrivateKey = this.encryptPrivateKey(
      wallet.privateKey,
      userId
    );

    const storedWallet: StoredWallet = {
      address: wallet.address,
      encryptedPrivateKey,
      createdAt: new Date(),
      userId,
    };

    this.wallets.set(userId, storedWallet);

    return {
      ...wallet,
      encryptedPrivateKey,
    };
  }

  /**
   * Get stored wallet for a user
   */
  getUserWallet(userId: number): StoredWallet | null {
    return this.wallets.get(userId) || null;
  }

  /**
   * Get decrypted private key for a user (use carefully)
   */
  getPrivateKey(userId: number): string | null {
    const wallet = this.wallets.get(userId);
    if (!wallet) return null;

    try {
      return this.decryptPrivateKey(wallet.encryptedPrivateKey, userId);
    } catch (error) {
      console.error("Error decrypting private key:", error);
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
   * Remove wallet for a user
   */
  removeWallet(userId: number): boolean {
    return this.wallets.delete(userId);
  }

  /**
   * Get wallet statistics
   */
  getStats(): { totalWallets: number; walletsCreatedToday: number } {
    const today = new Date();
    today.setHours(0, 0, 0, 0);

    let walletsCreatedToday = 0;

    for (const wallet of this.wallets.values()) {
      if (wallet.createdAt >= today) {
        walletsCreatedToday++;
      }
    }

    return {
      totalWallets: this.wallets.size,
      walletsCreatedToday,
    };
  }
}

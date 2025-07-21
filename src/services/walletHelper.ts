import { GeneratedWallet, WalletService } from "./wallet";
import { UserSessionService } from "./userSession";
import { Context } from "telegraf";

/**
 * Create a new wallet for the Telegram user and update session.
 * Returns the generated wallet so caller can present it.
 */
export function createNewUserWallet(
  ctx: Context,
  walletService: WalletService,
  userSessions: UserSessionService
): GeneratedWallet {
  const wallet = walletService.createWalletForUser(ctx.from!.id);
  userSessions.setWallet(ctx.from!.id, wallet.address);
  return wallet;
}

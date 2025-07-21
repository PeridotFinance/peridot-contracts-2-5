import { Markup } from "telegraf";

/**
 * Wallet management keyboard utilities for enhanced UX
 */

export const walletKeyboard = () => {
  return Markup.inlineKeyboard([
    [
      Markup.button.callback("🔑 Show Keys", "wallet_show_keys"),
      Markup.button.callback("💰 Check Balance", "wallet_check_balance"),
    ],
    [
      Markup.button.callback("📊 View Positions", "wallet_positions"),
      Markup.button.callback("❓ Help", "wallet_help"),
    ],
  ]);
};

export const exportKeyboard = () => {
  return Markup.inlineKeyboard([
    [
      Markup.button.callback("🔐 Private Key", "export_private_key"),
      Markup.button.callback("📋 Mnemonic", "export_mnemonic"),
    ],
    [Markup.button.callback("❌ Cancel", "export_cancel")],
  ]);
};

export const confirmationKeyboard = (action: string, data?: any) => {
  const callbackData = data ? `${action}_${JSON.stringify(data)}` : action;
  return Markup.inlineKeyboard([
    [
      Markup.button.callback("✅ Confirm", `confirm_${callbackData}`),
      Markup.button.callback("❌ Cancel", `cancel_${action}`),
    ],
  ]);
};

export const writeOperationsKeyboard = () => {
  return Markup.inlineKeyboard([
    [
      Markup.button.callback("💰 Supply", "write_supply"),
      Markup.button.callback("📉 Borrow", "write_borrow"),
    ],
    [
      Markup.button.callback("💸 Repay", "write_repay"),
      Markup.button.callback("🔄 Redeem", "write_redeem"),
    ],
    [
      Markup.button.callback("🎁 Claim", "write_claim"),
      Markup.button.callback("✅ Approve", "write_approve"),
    ],
  ]);
};

export const marketSelectionKeyboard = (markets: string[]) => {
  const buttons = markets.map((market) => [
    Markup.button.callback(market, `market_select_${market}`),
  ]);

  return Markup.inlineKeyboard([
    ...buttons,
    [Markup.button.callback("❌ Cancel", "market_cancel")],
  ]);
};

export const amountInputKeyboard = (presets: number[]) => {
  const presetButtons = presets.map((amount) => [
    Markup.button.callback(`${amount}`, `amount_${amount}`),
  ]);

  return Markup.inlineKeyboard([
    ...presetButtons,
    [Markup.button.callback("✏️ Custom Amount", "amount_custom")],
    [Markup.button.callback("❌ Cancel", "amount_cancel")],
  ]);
};

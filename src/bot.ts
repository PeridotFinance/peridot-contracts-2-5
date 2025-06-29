import { Telegraf, Markup } from "telegraf";
import * as dotenv from "dotenv";
import { BlockchainService } from "./services/blockchain";
import { PeridotService } from "./services/peridot";
import { AIService } from "./services/ai";
import { UserSessionService } from "./services/userSession";
import { WalletService } from "./services/wallet";

dotenv.config();

// Validate required environment variables
const requiredEnvVars = [
  "TELEGRAM_BOT_TOKEN",
  "RPC_URL",
  "PERIDOTTROLLER_ADDRESS",
];

for (const envVar of requiredEnvVars) {
  if (!process.env[envVar]) {
    console.error(`Missing required environment variable: ${envVar}`);
    process.exit(1);
  }
}

const bot = new Telegraf(process.env.TELEGRAM_BOT_TOKEN!);
const blockchain = new BlockchainService(process.env.RPC_URL!);
const peridot = new PeridotService(
  process.env.RPC_URL!,
  process.env.PERIDOTTROLLER_ADDRESS!
);

// Initialize AI service if OpenAI key is available
const ai = process.env.OPENAI_API_KEY
  ? new AIService(process.env.OPENAI_API_KEY)
  : null;

const userSessions = new UserSessionService();
const walletService = new WalletService();

// Market addresses for BSC Testnet
const MARKETS: Record<string, string> = {
  PPUSD:
    process.env.PPUSD_ADDRESS || "0xEDdC65ECaF2e67c301a01fDc1da6805084f621D0",
};

// Utility function to format large numbers
function formatNumber(num: number, decimals: number = 2): string {
  if (num >= 1e9) return (num / 1e9).toFixed(decimals) + "B";
  if (num >= 1e6) return (num / 1e6).toFixed(decimals) + "M";
  if (num >= 1e3) return (num / 1e3).toFixed(decimals) + "K";
  return num.toFixed(decimals);
}

// --- COMMAND HANDLERS ---

async function handleMarkets(ctx: any) {
  ctx.reply("📊 Loading market data...");

  try {
    let marketSummary = `📊 <b>Peridot Markets (BSC Testnet)</b>\n\n`;

    for (const [symbol, address] of Object.entries(MARKETS)) {
      try {
        const marketInfo = await peridot.getMarketInfo(address);
        const marketStatus = await peridot.getMarketStatus(address);

        const supplyAPY = peridot.calculateAPY(marketInfo.supplyRatePerBlock);
        const borrowAPY = peridot.calculateAPY(marketInfo.borrowRatePerBlock);
        const utilizationRate = await peridot.getUtilizationRate(address);
        const collateralFactor =
          parseFloat(marketStatus.collateralFactorMantissa) * 100;

        marketSummary += `<b>${symbol} Market</b>\n`;
        marketSummary += `📍 Address: <code>${address.slice(
          0,
          6
        )}...${address.slice(-4)}</code>\n`;
        marketSummary += `💰 Total Supply: ${formatNumber(
          parseFloat(marketInfo.totalSupply)
        )}\n`;
        marketSummary += `📈 Supply APY: ${supplyAPY.toFixed(2)}%\n`;
        marketSummary += `📉 Borrow APY: ${borrowAPY.toFixed(2)}%\n`;
        marketSummary += `🔄 Utilization: ${utilizationRate.toFixed(1)}%\n`;
        marketSummary += `🏦 Collateral Factor: ${collateralFactor.toFixed(
          0
        )}%\n`;
        marketSummary += `💧 Available Cash: ${formatNumber(
          parseFloat(marketInfo.cash)
        )}\n`;
        marketSummary += `🔗 Listed: ${
          marketStatus.isListed ? "✅" : "❌"
        }\n\n`;
      } catch (error) {
        marketSummary += `<b>${symbol} Market</b>\n❌ Error loading market data\n\n`;
        console.error(`Error loading ${symbol} market:`, error);
      }
    }

    marketSummary += `🎯 <b>Quick Actions:</b>\n• /position - View your positions\n• /liquidity - Check account health\n• /wallet <address> - Connect wallet`;
    ctx.reply(marketSummary, { parse_mode: "HTML" });
  } catch (error) {
    console.error("Markets command error:", error);
    ctx.reply("❌ Error loading market data. Please try again.");
  }
}

async function handlePosition(ctx: any) {
  const session = userSessions.getSession(ctx.from.id);

  if (!session.walletAddress) {
    ctx.reply(
      "❌ Please set your wallet first: `/wallet <address>` or create one with `/create_wallet`",
      { parse_mode: "HTML" }
    );
    return;
  }

  ctx.reply("💼 Analyzing your positions...");

  try {
    const positions = [];
    for (const [symbol, address] of Object.entries(MARKETS)) {
      try {
        const position = await peridot.getUserPosition(
          session.walletAddress,
          address
        );
        const pTokenBalance = parseFloat(position.pTokenBalance);
        const underlyingBalance = parseFloat(position.underlyingBalance);
        const borrowBalance = parseFloat(position.borrowBalance);

        if (pTokenBalance > 0 || underlyingBalance > 0 || borrowBalance > 0) {
          positions.push({ symbol, ...position });
        }
      } catch (error) {
        console.error(`Error fetching ${symbol} position:`, error);
      }
    }

    if (positions.length === 0) {
      ctx.reply(
        `💼 <b>No Active Positions</b>\n\nAddress: <code>${session.walletAddress.slice(
          0,
          6
        )}...${session.walletAddress.slice(
          -4
        )}</code>\n\nYou don't appear to have any active positions in Peridot protocol.`,
        { parse_mode: "HTML" }
      );
      return;
    }

    let positionSummary = `💼 <b>Your Peridot Positions</b>\n\nAddress: <code>${session.walletAddress.slice(
      0,
      6
    )}...${session.walletAddress.slice(-4)}</code>\n\n`;
    positions.forEach((pos) => {
      const underlyingBalance = parseFloat(pos.underlyingBalance);
      const borrowBalance = parseFloat(pos.borrowBalance);
      const pTokenBalance = parseFloat(pos.pTokenBalance);

      positionSummary += `<b>${pos.symbol} Position:</b>\n`;

      if (underlyingBalance > 0) {
        positionSummary += `💰 Supplied: ${underlyingBalance.toFixed(
          6
        )} (${pTokenBalance.toFixed(2)} pTokens)\n`;
        positionSummary += `📊 Exchange Rate: ${parseFloat(
          pos.exchangeRate
        ).toFixed(6)}\n`;
      }

      if (borrowBalance > 0) {
        positionSummary += `📉 Borrowed: ${borrowBalance.toFixed(6)}\n`;
      }

      positionSummary += "\n";
    });

    // Get market status for the primary market to get a representative collateral factor
    const marketStatus = await peridot.getMarketStatus(
      Object.values(MARKETS)[0]
    );
    const collateralFactor = parseFloat(marketStatus.collateralFactorMantissa);
    const liquidity = await peridot.getAccountLiquidity(session.walletAddress);

    positionSummary += `<b>🏥 Account Health:</b>\n`;
    positionSummary += `💚 Available Liquidity: $${parseFloat(
      liquidity.liquidity
    ).toFixed(2)}\n`;

    if (parseFloat(liquidity.shortfall) > 0) {
      positionSummary += `🚨 Shortfall: $${parseFloat(
        liquidity.shortfall
      ).toFixed(2)} - AT RISK!\n`;
    } else {
      positionSummary += `✅ Account is healthy\n`;
    }

    // --- Enhanced Debug Info ---
    positionSummary += `\n🔍 <b>Debug Info:</b>\n`;
    positionSummary += `Collateral Factor: <b>${(
      collateralFactor * 100
    ).toFixed(0)}%</b>\n`;
    positionSummary += `Raw Liquidity: ${liquidity.liquidity}\n`;
    positionSummary += `Raw Shortfall: ${liquidity.shortfall}\n`;

    if (collateralFactor === 0) {
      positionSummary += `⚠️ <b>Note:</b> Collateral factor is 0%, which provides no borrowing power.\n`;
    }

    positionSummary += `\nUse <code>/analyze</code> for AI-powered insights!`;

    ctx.reply(positionSummary, { parse_mode: "HTML" });
  } catch (error) {
    console.error("Position command error:", error);
    ctx.reply("❌ Error analyzing positions. Please try again.");
  }
}

async function handleAnalyze(ctx: any) {
  const session = userSessions.getSession(ctx.from.id);

  if (!session.walletAddress) {
    ctx.reply(
      "❌ Please set your wallet first: `/wallet <address>` or create one with `/create_wallet`",
      { parse_mode: "HTML" }
    );
    return;
  }
  if (!ai) {
    ctx.reply(
      "🤖 AI assistant is not available. Please configure an OpenAI API key."
    );
    return;
  }

  ctx.reply("🧠 AI is analyzing your position...");

  try {
    const positions: Record<string, any> = {};
    for (const [symbol, address] of Object.entries(MARKETS)) {
      try {
        const position = await peridot.getUserPosition(
          session.walletAddress,
          address
        );
        if (
          parseFloat(position.pTokenBalance) > 0 ||
          parseFloat(position.borrowBalance) > 0
        ) {
          positions[symbol] = position;
        }
      } catch (error) {
        /* Skip failed positions */
      }
    }

    const liquidity = await peridot.getAccountLiquidity(session.walletAddress);
    const analysisData = {
      address: session.walletAddress,
      positions,
      liquidity,
    };
    const analysis = await ai.analyzePosition(analysisData);
    ctx.reply(`🧠 <b>AI Position Analysis:</b>\n\n${analysis}`, {
      parse_mode: "HTML",
    });
  } catch (error) {
    ctx.reply("❌ Error generating analysis. Please try again.");
  }
}

async function handleCreateWallet(ctx: any) {
  if (walletService.hasWallet(ctx.from.id)) {
    const existingWallet = walletService.getUserWallet(ctx.from.id);
    ctx.reply(
      `💳 <b>You already have a wallet!</b>\n\n📍 Address: <code>${existingWallet?.address}</code>`,
      { parse_mode: "HTML" }
    );
    return;
  }

  ctx.reply(
    "💳 <b>Create New Wallet</b>\n\nWould you like to create a new wallet?",
    {
      parse_mode: "HTML",
      ...Markup.inlineKeyboard([
        Markup.button.callback(
          "✅ Yes, create wallet",
          "create_wallet_confirm"
        ),
        Markup.button.callback("❌ Cancel", "create_wallet_cancel"),
      ]),
    }
  );
}

// --- ONBOARDING & WELCOME ---

const showWelcomeMessage = (ctx: any) => {
  const session = userSessions.getSession(ctx.from.id);

  // Check if user has a wallet set up
  const hasWallet =
    session.walletAddress || walletService.hasWallet(ctx.from.id);

  let welcomeMessage = `Welcome to your Peridot DeFi Assistant!

<b>Peridot Protocol</b> - Advanced lending & borrowing on BNB Chain

<b>I can help you with:</b>
📊 Analyze markets and positions
💰 Check your Peridot balances
🤖 Get personalized DeFi advice
⚡ Monitor liquidation risks
📈 Track yields and opportunities

`;

  if (!hasWallet) {
    welcomeMessage += `🔧 <b>Get Started:</b>
/create_wallet - Create a new wallet to get started
/wallet &lt;address&gt; - Connect your existing wallet

`;
  } else {
    welcomeMessage += `🔧 <b>Quick Actions:</b>
/markets - View available markets
/position - Check your positions
/analyze - AI-powered analysis

`;
  }

  welcomeMessage += `/help - See all commands

💡 <b>Pro Tip:</b> Just type naturally! I understand requests like:
"Show me USDC market info" or "What's my position?"`;

  ctx.reply(welcomeMessage, {
    parse_mode: "HTML",
  });
};

const handleOnboardingNone = (ctx: any) => {
  const explanation = `Welcome to the world of decentralized finance.

<b>What is Peridot?</b>
Think of Peridot as a community bank, but on the blockchain. You can:
1.  <b>Lend:</b> Deposit your digital assets (like stablecoins) to earn interest. It's like a high-yield savings account.
2.  <b>Borrow:</b> Use your deposited assets as collateral to borrow other assets.

<b>What is a Wallet?</b>
A crypto wallet is like your personal bank account for the digital world. It's where you'll store your assets securely. We will create one for you to get started, and you'll have full control over it.

<b>🚀 Next Step:</b>
To get started, use <code>/create_wallet</code> to create your first wallet, or <code>/wallet &lt;address&gt;</code> if you already have one.

We're here to guide you every step of the way!`;

  ctx.reply(explanation, { parse_mode: "HTML" });
  userSessions.setOnboardingStage(ctx.from.id, "done");
  showWelcomeMessage(ctx);
};

const askStrategyQuestion = (ctx: any) => {
  userSessions.setOnboardingStage(ctx.from.id, "asked_strategy");
  ctx.reply(
    "That's great. To help me give you the best advice, what's your primary focus or strategy with crypto?",
    Markup.inlineKeyboard([
      [Markup.button.callback("Long-term holding", "strategy_holding")],
      [Markup.button.callback("Yield farming", "strategy_yield")],
      [Markup.button.callback("Trading", "strategy_trading")],
      [Markup.button.callback("DeFi lending/borrowing", "strategy_defi")],
      [Markup.button.callback("Diversified portfolio", "strategy_diversified")],
    ])
  );
};

const askWalletChoice = (ctx: any) => {
  userSessions.setOnboardingStage(ctx.from.id, "wallet_choice");
  ctx.reply(
    "Do you want to set your own existing wallet or should we create a new one for you to start with?",
    Markup.inlineKeyboard([
      Markup.button.callback("Set my own wallet", "wallet_set_own"),
      Markup.button.callback("Create one for me", "wallet_create_new"),
    ])
  );
};

const askCryptoQuestion = (ctx: any) => {
  userSessions.setOnboardingStage(ctx.from.id, "asked_crypto");
  ctx.reply(
    "Got it. How much experience do you have with crypto?",
    Markup.inlineKeyboard([
      Markup.button.callback("A lot", "crypto_lot"),
      Markup.button.callback("A bit", "crypto_bit"),
      Markup.button.callback("None", "crypto_none"),
    ])
  );
};

// Bot startup message
bot.start((ctx) => {
  const session = userSessions.getSession(ctx.from.id);

  if (session.onboardingStage === "done") {
    showWelcomeMessage(ctx);
    return;
  }

  const welcomeMessage = `Welcome to your Peridot DeFi Assistant!

To get started, let's personalize your experience.`;
  ctx.reply(welcomeMessage);

  // Start onboarding
  userSessions.setOnboardingStage(ctx.from.id, "asked_finance");
  ctx.reply(
    "First, how informed are you with traditional finance?",
    Markup.inlineKeyboard([
      Markup.button.callback("A lot", "finance_lot"),
      Markup.button.callback("A bit", "finance_bit"),
      Markup.button.callback("None", "finance_none"),
    ])
  );
});

// --- ONBOARDING ACTIONS ---

bot.action(/finance_(.+)/, (ctx) => {
  const level = ctx.match[1] as "lot" | "bit" | "none";
  userSessions.setUserKnowledge(ctx.from.id, { financeKnowledge: level });
  ctx.answerCbQuery(`You selected: ${level}`);
  ctx.editMessageReplyMarkup(undefined);

  if (level === "none") {
    handleOnboardingNone(ctx);
  } else {
    askCryptoQuestion(ctx);
  }
});

bot.action(/crypto_(.+)/, (ctx) => {
  const level = ctx.match[1] as "lot" | "bit" | "none";
  userSessions.setUserKnowledge(ctx.from.id, { cryptoExperience: level });
  ctx.answerCbQuery(`You selected: ${level}`);
  ctx.editMessageReplyMarkup(undefined);

  if (level === "none") {
    handleOnboardingNone(ctx);
  } else if (level === "bit") {
    askWalletChoice(ctx);
  } else {
    askStrategyQuestion(ctx);
  }
});

bot.action("wallet_set_own", (ctx) => {
  userSessions.setOnboardingStage(ctx.from.id, "done");
  ctx.answerCbQuery();
  ctx.editMessageReplyMarkup(undefined);
  ctx.reply(
    "Great! Please use the <code>/wallet &lt;your-address&gt;</code> command to connect your existing wallet.\n\nExample: <code>/wallet 0x742d35Cc6869C4e5B7b8d5e6b9A8B9b8B9b8B9b8</code>",
    { parse_mode: "HTML" }
  );
  showWelcomeMessage(ctx);
});

bot.action("wallet_create_new", async (ctx) => {
  userSessions.setOnboardingStage(ctx.from.id, "done");
  ctx.answerCbQuery();
  ctx.editMessageReplyMarkup(undefined);

  try {
    // Create wallet for user
    const newWallet = walletService.createWalletForUser(ctx.from.id);

    // Set the wallet address in user session
    userSessions.setWallet(ctx.from.id, newWallet.address);

    const walletMessage = `🎉 <b>Wallet Created Successfully!</b>

<b>Your New Wallet:</b>
📍 Address: <code>${newWallet.address}</code>

<b>🔐 Your Private Key (SAVE THIS!):</b>
<code>${newWallet.privateKey}</code>

<b>🔑 Your Secret Recovery Phrase:</b>
<code>${newWallet.mnemonic}</code>

<b>⚠️ CRITICAL SECURITY WARNINGS:</b>
• <b>SAVE THESE KEYS IMMEDIATELY!</b> Write them down securely
• Never share your private key or recovery phrase with anyone
• Anyone with these keys can access your wallet and funds
• We cannot recover these keys if you lose them
• Store them offline in a safe place
• This wallet starts with 0 balance - you'll need to fund it

<b>🚀 Next Steps:</b>
• Save your keys in a secure location NOW
• Fund your wallet with test tokens
• Start exploring Peridot markets
• Use DeFi features safely!

<b>This message contains sensitive information. Please save your keys and then you can delete this message.</b>`;

    ctx.reply(walletMessage, { parse_mode: "HTML" });
    showWelcomeMessage(ctx);
  } catch (error) {
    console.error("Error creating wallet:", error);
    ctx.reply(
      "❌ Sorry, there was an error creating your wallet. Please try again later."
    );
    showWelcomeMessage(ctx);
  }
});

bot.action(/strategy_(.+)/, (ctx) => {
  const strategy = ctx.match[1];
  const strategyMap: Record<string, string> = {
    holding: "Long-term holding",
    yield: "Yield farming",
    trading: "Trading",
    defi: "DeFi lending/borrowing",
    diversified: "Diversified portfolio",
  };

  userSessions.setUserKnowledge(ctx.from.id, {
    cryptoStrategy: strategyMap[strategy],
  });
  userSessions.setOnboardingStage(ctx.from.id, "done");

  ctx.answerCbQuery(`You selected: ${strategyMap[strategy]}`);
  ctx.editMessageReplyMarkup(undefined);
  ctx.reply(
    "Perfect, thank you! I've saved your strategy to personalize my advice.\n\n🚀 <b>Ready to get started?</b>\nUse <code>/create_wallet</code> to create your first wallet!",
    { parse_mode: "HTML" }
  );
  showWelcomeMessage(ctx);
});

bot.action("create_wallet_confirm", async (ctx) => {
  ctx.answerCbQuery();
  ctx.editMessageReplyMarkup(undefined);

  try {
    // Create wallet for user
    const newWallet = walletService.createWalletForUser(ctx.from.id);

    // Set the wallet address in user session
    userSessions.setWallet(ctx.from.id, newWallet.address);

    const walletMessage = `🎉 <b>Wallet Created Successfully!</b>

<b>Your New Wallet:</b>
📍 Address: <code>${newWallet.address}</code>

<b>🔐 Your Private Key (SAVE THIS!):</b>
<code>${newWallet.privateKey}</code>

<b>🔑 Your Secret Recovery Phrase:</b>
<code>${newWallet.mnemonic}</code>

<b>⚠️ CRITICAL SECURITY WARNINGS:</b>
• <b>SAVE THESE KEYS IMMEDIATELY!</b> Write them down securely
• Never share your private key or recovery phrase with anyone
• Anyone with these keys can access your wallet and funds
• We cannot recover these keys if you lose them
• Store them offline in a safe place
• This wallet starts with 0 balance - you'll need to fund it

<b>🚀 Next Steps:</b>
• Save your keys in a secure location NOW
• Fund your wallet with test tokens
• Start exploring Peridot markets
• Use DeFi features safely!

<b>This message contains sensitive information. Please save your keys and then you can delete this message.</b>`;

    ctx.reply(walletMessage, { parse_mode: "HTML" });
  } catch (error) {
    console.error("Error creating wallet:", error);
    ctx.reply(
      "❌ Sorry, there was an error creating your wallet. Please try again later."
    );
  }
});

bot.action("create_wallet_cancel", (ctx) => {
  ctx.answerCbQuery();
  ctx.editMessageReplyMarkup(undefined);
  ctx.reply("❌ Wallet creation cancelled.");
});

// Help command
bot.help((ctx) => {
  const helpMessage = `🆘 <b>Peridot Bot Commands</b>

<b>💼 Wallet & Position:</b>
/wallet &lt;address&gt; - Set your wallet address
/create_wallet - Create a new wallet
/wallet_info - View your wallet information
/wallet_balance - Check your wallet balance
/export_wallet - Export private key (⚠️ Use carefully!)
/connect_wallet - Connect your created wallet
/position - View your positions
/liquidity - Check account health

<b>📊 Market Data:</b>
/markets - List all markets
/market &lt;symbol&gt; - Get market details
/rates - Current supply/borrow rates
/tvl - Total value locked

<b>🤖 AI Assistant:</b>
/ask &lt;question&gt; - Ask anything about DeFi
/analyze - AI position analysis
/advice - Get personalized advice
/strategy - Investment strategies

<b>⚙️ Settings:</b>
/settings - User preferences
/alerts - Manage price alerts
/stats - Bot statistics

<b>🎯 Natural Language:</b>
Just type what you want! Examples:
• "How much USDC can I borrow?"
• "Show me the best rates"
• "Is my position safe?"`;

  ctx.reply(helpMessage, { parse_mode: "HTML" });
});

// Wallet command
bot.command("wallet", async (ctx) => {
  const args = ctx.message.text.split(" ");
  if (args.length < 2) {
    ctx.reply(
      `💰 <b>Set Your Wallet</b>

Usage: <code>/wallet &lt;address&gt;</code>

Example: <code>/wallet 0x742d35Cc6869C4e5B7b8d5e6b9A8B9b8B9b8B9b8</code>

This allows me to:
• Check your positions
• Calculate health ratios
• Provide personalized advice
• Set up alerts`,
      { parse_mode: "HTML" }
    );
    return;
  }

  const address = args[1];
  if (!(await blockchain.isValidAddress(address))) {
    ctx.reply("❌ Invalid wallet address format");
    return;
  }

  userSessions.setWallet(ctx.from.id, address);
  ctx.reply(
    `✅ <b>Wallet Connected</b>
    
Address: <code>${address.slice(0, 6)}...${address.slice(-4)}</code>

Now I can provide personalized analysis! Try:
• /position - View your positions
• /analyze - AI-powered analysis
• /liquidity - Check health status`,
    { parse_mode: "HTML" }
  );
});

// Wallet info command
bot.command("wallet_info", async (ctx) => {
  const storedWallet = walletService.getUserWallet(ctx.from.id);

  if (!storedWallet) {
    ctx.reply(
      "❌ You don't have a wallet yet. Use <code>/create_wallet</code> to create one or <code>/wallet &lt;address&gt;</code> to connect your existing wallet."
    );
    return;
  }

  const session = userSessions.getSession(ctx.from.id);
  const isConnected = session.walletAddress === storedWallet.address;

  const walletInfo = `💳 <b>Your Wallet Information</b>

📍 <b>Address:</b> <code>${storedWallet.address}</code>
📅 <b>Created:</b> ${storedWallet.createdAt.toLocaleDateString()}
🔗 <b>Status:</b> ${isConnected ? "✅ Connected" : "❌ Not connected"}

<b>🔧 Actions:</b>
• /export_wallet - Export private key (⚠️ Use carefully!)
• /connect_wallet - Connect this wallet to your session
• /wallet_balance - Check wallet balance`;

  ctx.reply(walletInfo, { parse_mode: "HTML" });
});

// Export wallet command (dangerous - should be used carefully)
bot.command("export_wallet", async (ctx) => {
  const storedWallet = walletService.getUserWallet(ctx.from.id);

  if (!storedWallet) {
    ctx.reply("❌ You don't have a wallet to export.");
    return;
  }

  ctx.reply(
    "⚠️ <b>Export Private Key</b>\n\nThis will show your private key. Make sure you're in a private chat and no one can see your screen!",
    Markup.inlineKeyboard([
      Markup.button.callback("🔐 Show Private Key", "export_private_key"),
      Markup.button.callback("📋 Show Mnemonic", "export_mnemonic"),
      Markup.button.callback("❌ Cancel", "export_cancel"),
    ])
  );
});

bot.action("export_private_key", async (ctx) => {
  ctx.answerCbQuery();
  ctx.editMessageReplyMarkup(undefined);

  const privateKey = walletService.getPrivateKey(ctx.from.id);

  if (!privateKey) {
    ctx.reply("❌ Error retrieving private key.");
    return;
  }

  const message = `🔐 <b>Your Private Key</b>

<code>${privateKey}</code>

⚠️ <b>SECURITY WARNING:</b>
• Never share this private key with anyone
• Store it securely offline
• Anyone with this key can access your wallet
• Delete this message after saving the key

<b>This message will be deleted in 60 seconds for security.</b>`;

  const sentMessage = await ctx.reply(message, { parse_mode: "HTML" });

  // Delete the message after 60 seconds
  setTimeout(() => {
    ctx.deleteMessage(sentMessage.message_id).catch(() => {});
  }, 60000);
});

bot.action("export_mnemonic", async (ctx) => {
  ctx.answerCbQuery();
  ctx.editMessageReplyMarkup(undefined);
  ctx.reply(
    "🔧 Mnemonic phrase export is not available for security reasons. Use private key export instead."
  );
});

bot.action("export_cancel", (ctx) => {
  ctx.answerCbQuery();
  ctx.editMessageReplyMarkup(undefined);
  ctx.reply("❌ Export cancelled.");
});

// Connect wallet command
bot.command("connect_wallet", async (ctx) => {
  const storedWallet = walletService.getUserWallet(ctx.from.id);

  if (!storedWallet) {
    ctx.reply(
      "❌ You don't have a wallet to connect. Create one first with /create_wallet."
    );
    return;
  }

  userSessions.setWallet(ctx.from.id, storedWallet.address);
  ctx.reply(
    `✅ <b>Wallet Connected</b>

📍 Address: <code>${storedWallet.address}</code>

You can now use all wallet features!`,
    { parse_mode: "HTML" }
  );
});

// Wallet balance command
bot.command("wallet_balance", async (ctx) => {
  const storedWallet = walletService.getUserWallet(ctx.from.id);

  if (!storedWallet) {
    ctx.reply(
      "❌ You don't have a wallet. Create one first with /create_wallet."
    );
    return;
  }

  try {
    const balance = await blockchain.getBalance(storedWallet.address);
    ctx.reply(
      `💰 <b>Wallet Balance</b>

📍 Address: <code>${storedWallet.address.slice(
        0,
        6
      )}...${storedWallet.address.slice(-4)}</code>
💎 Balance: ${balance} ETH

<b>Note:</b> This shows your native ETH balance. Use /position to see your Peridot positions.`,
      { parse_mode: "HTML" }
    );
  } catch (error) {
    ctx.reply("❌ Error checking wallet balance. Please try again.");
  }
});

// Create wallet command
bot.command("create_wallet", handleCreateWallet);

// Markets command
bot.command("markets", handleMarkets);

// Market details command
bot.command("market", async (ctx) => {
  const args = ctx.message.text.split(" ");
  if (args.length < 2) {
    ctx.reply(
      `🎯 <b>Market Details</b>

Usage: <code>/market &lt;symbol&gt;</code>

Example: <code>/market PPUSD</code>

Available markets: ${Object.keys(MARKETS).join(", ")}`,
      { parse_mode: "HTML" }
    );
    return;
  }

  const symbol = args[1].toUpperCase();
  const marketAddress = MARKETS[symbol];

  if (!marketAddress) {
    ctx.reply(`❌ Market "${symbol}" not found.

Available markets: ${Object.keys(MARKETS).join(", ")}

Use \`/markets\` to see all market data.`);
    return;
  }

  ctx.reply(`📊 Loading ${symbol} market details...`);

  try {
    const marketInfo = await peridot.getMarketInfo(marketAddress);
    const marketStatus = await peridot.getMarketStatus(marketAddress);

    const supplyAPY = peridot.calculateAPY(marketInfo.supplyRatePerBlock);
    const borrowAPY = peridot.calculateAPY(marketInfo.borrowRatePerBlock);
    const utilizationRate = await peridot.getUtilizationRate(marketAddress);
    const collateralFactor =
      parseFloat(marketStatus.collateralFactorMantissa) * 100;

    const marketDetails = `🎯 <b>${symbol} Market Details</b>

📍 <b>Contract:</b> <code>${marketAddress}</code>
🔗 <b>Status:</b> ${marketStatus.isListed ? "✅ Listed" : "❌ Not Listed"}

💹 <b>Rates & APY:</b>
📈 Supply APY: ${supplyAPY.toFixed(2)}% 
📉 Borrow APY: ${borrowAPY.toFixed(2)}%
🔄 Utilization Rate: ${utilizationRate.toFixed(1)}%

🏦 <b>Market Stats:</b>
💰 Total Supply: ${formatNumber(parseFloat(marketInfo.totalSupply))}
💸 Total Borrows: ${formatNumber(parseFloat(marketInfo.totalBorrows))}
💧 Available Cash: ${formatNumber(parseFloat(marketInfo.cash))}
🏛️ Reserves: ${formatNumber(parseFloat(marketInfo.totalReserves))}

⚖️ <b>Risk Parameters:</b>
🏦 Collateral Factor: ${collateralFactor.toFixed(0)}%
🔄 Exchange Rate: ${parseFloat(marketInfo.exchangeRate).toFixed(6)}

${
  collateralFactor === 0
    ? "⚠️ <b>Note:</b> 0% collateral factor means this asset cannot be used as collateral for borrowing."
    : "✅ This asset can be used as collateral for borrowing."
}

🎯 <b>Quick Actions:</b>
• /position - View your positions
• /liquidity - Check account health`;

    ctx.reply(marketDetails, { parse_mode: "HTML" });
  } catch (error) {
    console.error(`Market details error for ${symbol}:`, error);
    ctx.reply(`❌ Error loading ${symbol} market details. Please try again.`);
  }
});

// Position command
bot.command("position", handlePosition);

// Liquidity check command
bot.command("liquidity", async (ctx) => {
  const session = userSessions.getSession(ctx.from.id);

  if (!session.walletAddress) {
    ctx.reply("❌ Please set your wallet first: `/wallet <address>`");
    return;
  }

  try {
    const liquidity = await peridot.getAccountLiquidity(session.walletAddress);
    const availableLiquidity = parseFloat(liquidity.liquidity);
    const shortfall = parseFloat(liquidity.shortfall);

    console.log("Liquidity check:", { availableLiquidity, shortfall });

    // Check if user has any positions to explain zero liquidity
    let totalSuppliedValue = 0;
    for (const [symbol, address] of Object.entries(MARKETS)) {
      try {
        const position = await peridot.getUserPosition(
          session.walletAddress,
          address
        );
        const marketStatus = await peridot.getMarketStatus(address);
        const underlyingBalance = parseFloat(position.underlyingBalance);

        if (underlyingBalance > 0) {
          totalSuppliedValue += underlyingBalance; // Simplified - in real case would need USD price
        }
      } catch (error) {
        console.error(`Error checking ${symbol} for liquidity:`, error);
      }
    }

    let healthMessage = `🏥 <b>Account Health Check</b>

Address: <code>${session.walletAddress.slice(
      0,
      6
    )}...${session.walletAddress.slice(-4)}</code>

`;

    if (shortfall > 0) {
      healthMessage += `🚨 <b>LIQUIDATION RISK</b>
❌ Shortfall: $${shortfall.toFixed(2)}
⚠️ Your account is underwater!

<b>Immediate Actions:</b>
• Add more collateral
• Repay some debt
• Consider closing risky positions`;
    } else if (availableLiquidity === 0 && totalSuppliedValue > 0) {
      const marketStatus = await peridot.getMarketStatus(MARKETS.PPUSD);
      const collateralFactor = parseFloat(
        marketStatus.collateralFactorMantissa
      );

      healthMessage += `ℹ️ <b>NO BORROWING POWER</b>
💰 You have supplied assets (${totalSuppliedValue.toFixed(2)} tokens)
🔒 Available Liquidity: $${availableLiquidity.toFixed(2)}

<b>Reason:</b> Collateral factor is ${(collateralFactor * 100).toFixed(0)}%
${
  collateralFactor === 0
    ? "⚠️ This market currently has 0% collateral factor - no borrowing allowed"
    : "📊 Your collateral provides limited borrowing power"
}

<b>Status:</b> ✅ Account is healthy (no debt)`;
    } else if (availableLiquidity < 100) {
      healthMessage += `⚠️ <b>LOW LIQUIDITY</b>
💛 Available: $${availableLiquidity.toFixed(2)}
📊 Consider adding more collateral for safety`;
    } else {
      healthMessage += `✅ <b>HEALTHY ACCOUNT</b>
💚 Available Liquidity: $${availableLiquidity.toFixed(2)}
🛡️ You have good collateral coverage`;
    }

    // Add debug info
    healthMessage += `\n\n🔍 <b>Debug Info:</b>
Supplied Value: ${totalSuppliedValue.toFixed(2)}
Liquidity: ${availableLiquidity.toFixed(2)}
Shortfall: ${shortfall.toFixed(2)}`;

    ctx.reply(healthMessage, { parse_mode: "HTML" });
  } catch (error) {
    console.error("Liquidity command error:", error);
    ctx.reply("❌ Error checking account liquidity.");
  }
});

// AI Ask command
if (ai) {
  bot.command("ask", async (ctx) => {
    const args = ctx.message.text.split(" ").slice(1);
    if (args.length === 0) {
      ctx.reply(
        "🤖 <b>Ask me anything about DeFi!</b>\n\nExample: <code>/ask What is the best strategy for yield farming?</code>",
        { parse_mode: "HTML" }
      );
      return;
    }

    const question = args.join(" ");
    ctx.reply("🤔 Thinking...");

    try {
      const advice = await ai.getAdvice(question);
      ctx.reply(`🤖 <b>AI Assistant:</b>\n\n${advice}`, { parse_mode: "HTML" });
    } catch (error) {
      ctx.reply("❌ Sorry, I couldn't process your question right now.");
    }
  });

  // AI Analyze command
  bot.command("analyze", handleAnalyze);
}

// Natural language processing for general messages
bot.on("text", async (ctx) => {
  const text = ctx.message.text;
  const session = userSessions.getSession(ctx.from.id);

  // Skip commands
  if (text.startsWith("/")) {
    return;
  }

  if (!ai) {
    ctx.reply(
      "🤖 AI assistant is not available. Please configure OpenAI API key."
    );
    return;
  }

  // Simple keyword detection for common queries
  const lowerText = text.toLowerCase();

  if (
    lowerText.includes("market") &&
    (lowerText.includes("usdc") || lowerText.includes("usdt"))
  ) {
    const symbol = lowerText.includes("usdc") ? "USDC" : "USDT";
    ctx.message.text = `/market ${symbol}`;
    return;
  }

  if (lowerText.includes("position") || lowerText.includes("balance")) {
    ctx.message.text = "/position";
    return;
  }

  if (lowerText.includes("health") || lowerText.includes("liquidity")) {
    ctx.message.text = "/liquidity";
    return;
  }

  // Default to AI assistance
  try {
    let context = {};

    // Add user context if wallet is set
    if (session.walletAddress) {
      try {
        const liquidity = await peridot.getAccountLiquidity(
          session.walletAddress
        );
        context = { userLiquidity: liquidity };
      } catch (error) {
        // Continue without context
      }
    }

    const advice = await ai.getAdvice(
      text,
      Object.keys(context).length > 0 ? context : undefined
    );
    ctx.reply(`🤖 ${advice}`);
  } catch (error) {
    ctx.reply(
      "❌ I couldn't process your message. Try asking a specific question!"
    );
  }
});

// Keyboard button handlers disabled - using commands only for now

// Error handling
bot.catch((err, ctx) => {
  console.error("Bot error:", err);
  ctx.reply("❌ Something went wrong. Please try again.");
});

// Enable graceful stop
process.once("SIGINT", () => bot.stop("SIGINT"));
process.once("SIGTERM", () => bot.stop("SIGTERM"));

// Test network connectivity before starting
async function initializeBot() {
  console.log("🔍 Testing network connectivity...");

  const blockchainConnected = await blockchain.testConnection();
  const peridotConnected = await peridot.testConnection();

  if (!blockchainConnected || !peridotConnected) {
    console.error("❌ Network connectivity failed!");
    console.error(`Blockchain: ${blockchainConnected ? "✅" : "❌"}`);
    console.error(`Peridot: ${peridotConnected ? "✅" : "❌"}`);
    console.error("Please check your RPC_URL and network configuration.");
    process.exit(1);
  }

  console.log("✅ Network connectivity test passed!");

  // Start the bot
  await bot.launch();
  console.log("🚀 Peridot DeFi Bot is running!");
  console.log(`🌐 Network: BSC Testnet (Chain ID: 97)`);
  console.log(`📊 Monitoring ${Object.keys(MARKETS).length} markets`);
  console.log(`🤖 AI Assistant: ${ai ? "Enabled" : "Disabled"}`);
}

// Initialize the bot
initializeBot().catch((error) => {
  console.error("Failed to initialize bot:", error);
  process.exit(1);
});

// Clean up old sessions periodically (every 24 hours)
setInterval(() => {
  userSessions.cleanupOldSessions();
}, 24 * 60 * 60 * 1000);

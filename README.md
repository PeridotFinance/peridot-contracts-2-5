# 🧿 Peridot DeFi Bot

A sophisticated Telegram bot for interacting with the Peridot Protocol (Compound V2 fork) on Arbitrum. Get real-time market data, manage your positions, and receive AI-powered DeFi advice through Telegram.

## ✨ Features

### 🤖 AI-Powered Assistant

- Natural language processing for DeFi queries
- Position analysis and risk assessment
- Personalized investment advice
- Market insights and trends

### 📊 Market Data

- Real-time market information
- APY calculations (supply/borrow rates)
- Utilization rates and liquidity data
- Market health indicators

### 💼 Portfolio Management

- Multi-token position tracking
- Account health monitoring
- Liquidation risk warnings
- Historical performance (coming soon)

### 🎯 User Experience

- Natural language commands
- Intuitive keyboard interface
- Personalized settings
- Multi-language support (coming soon)

## 🚀 Quick Start

### Prerequisites

- Node.js 18+ installed
- Telegram Bot Token (from @BotFather)
- OpenAI API key (optional, for AI features)
- RPC endpoint for Arbitrum Sepolia

### Installation

1. **Clone and Install**

```bash
git clone <your-repo>
cd peridot-defi-bot
npm install
```

2. **Environment Setup**

```bash
cp env.example .env
# Edit .env with your configuration
```

3. **Required Environment Variables**

```bash
# Telegram Bot Configuration
TELEGRAM_BOT_TOKEN=your_telegram_bot_token

# Blockchain Configuration
RPC_URL=https://sepolia-rollup.arbitrum.io/rpc
PERIDOTTROLLER_ADDRESS=0xfB3f8837B1Ad7249C1B253898b3aa7FaB22E68aD

# Market Addresses
PUSDC_ADDRESS=0xFb08502090318eA69595ad5D80Ff854B87f457eb
PUSDT_ADDRESS=0x3ed59D5D0a2236cDAd22aDFFC5414df74Ccb3040

# AI Configuration (Optional)
OPENAI_API_KEY=your_openai_api_key
```

4. **Start the Bot**

```bash
# Development
npm run dev

# Production
npm run build
npm start
```

## 🎮 Bot Commands

### 💼 Wallet & Position Commands

- `/wallet <address>` - Connect your wallet
- `/position` - View your current positions
- `/liquidity` - Check account health
- `/balance <address>` - Check ETH balance

### 📊 Market Commands

- `/markets` - List all available markets
- `/market <symbol>` - Get detailed market info
- `/rates` - Current supply/borrow rates

### 🤖 AI Assistant Commands

- `/ask <question>` - Ask anything about DeFi
- `/analyze` - AI-powered position analysis
- `/advice` - Get personalized recommendations

### 🎯 Natural Language Examples

The bot understands natural language! Try:

- "Show me USDC market info"
- "What's my position?"
- "Is my account healthy?"
- "How much can I borrow?"
- "What are the best rates?"

## 🏗️ Architecture

### Core Services

#### `BlockchainService`

- Ethereum/Arbitrum blockchain interactions
- Address validation
- Balance queries
- Gas price estimation

#### `PeridotService`

- Peridot protocol interactions
- Market data retrieval
- User position analysis
- APY calculations

#### `AIService`

- OpenAI integration
- Natural language processing
- Position analysis
- Market insights

#### `UserSessionService`

- User state management
- Wallet address storage
- Preferences handling
- Alert management

### Key Adaptations for Peridot

This bot is specifically adapted for the Peridot protocol:

- **pTokens** instead of cTokens (e.g., pUSDC, pUSDT)
- **Peridottroller** instead of Comptroller
- Custom market addresses on Arbitrum Sepolia
- Peridot-specific terminology and branding

## 🛠️ Development

### Project Structure

```
src/
├── bot.ts                 # Main bot logic
├── services/
│   ├── blockchain.ts      # Blockchain interactions
│   ├── peridot.ts        # Peridot protocol service
│   ├── ai.ts             # OpenAI integration
│   └── userSession.ts    # User state management
├── types/                # TypeScript type definitions
└── utils/                # Utility functions
```

### Available Scripts

```bash
npm run dev        # Development with hot reload
npm run build      # Build TypeScript
npm start          # Start production bot
npm test           # Run tests
npm run lint       # Lint code
```

### Environment Variables

| Variable                 | Description                    | Required |
| ------------------------ | ------------------------------ | -------- |
| `TELEGRAM_BOT_TOKEN`     | Bot token from @BotFather      | ✅       |
| `RPC_URL`                | Arbitrum Sepolia RPC endpoint  | ✅       |
| `PERIDOTTROLLER_ADDRESS` | Peridottroller proxy address   | ✅       |
| `PUSDC_ADDRESS`          | pUSDC token address            | ✅       |
| `PUSDT_ADDRESS`          | pUSDT token address            | ✅       |
| `OPENAI_API_KEY`         | OpenAI API key for AI features | ❌       |

## 🔒 Security Considerations

- **No Private Keys**: Bot only reads blockchain data
- **Rate Limiting**: Built-in protection against spam
- **Input Validation**: All user inputs are validated
- **Error Handling**: Graceful error management
- **Session Management**: Secure user data handling

## 📊 Supported Networks

Currently supports:

- **Arbitrum Sepolia** (Testnet)

Coming soon:

- Arbitrum One (Mainnet)
- Additional networks where Peridot is deployed

## 🎯 Peridot Protocol Integration

### Supported Markets

- **USDC** - USD Coin lending/borrowing
- **USDT** - Tether lending/borrowing
- More markets coming soon!

### Key Features

- Real-time APY calculations
- Health factor monitoring
- Liquidation risk warnings
- Market utilization tracking

## 🤝 Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Development Guidelines

- Follow TypeScript best practices
- Add tests for new features
- Update documentation
- Ensure backwards compatibility

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🆘 Support

- **Telegram**: [@peridot_support](https://t.me/peridot_support)
- **Discord**: [Peridot Community](https://discord.gg/peridot)
- **GitHub Issues**: For bug reports and feature requests

## 🗺️ Roadmap

### Phase 1: Core Features ✅

- [x] Basic bot functionality
- [x] Market data integration
- [x] Position tracking
- [x] AI assistant

### Phase 2: Advanced Features 🔄

- [ ] Transaction execution
- [ ] Price alerts
- [ ] Historical analytics
- [ ] Advanced trading strategies

### Phase 3: Enterprise Features 📋

- [ ] Multi-chain support
- [ ] Advanced risk management
- [ ] Institutional features
- [ ] API access

## 🎉 Acknowledgments

- [Peridot Protocol](https://peridot.finance) - The underlying DeFi protocol
- [Compound V2](https://compound.finance) - Protocol inspiration
- [Telegraf](https://telegraf.js.org) - Telegram bot framework
- [OpenAI](https://openai.com) - AI assistance capabilities

---

**Built with ❤️ for the Peridot community**

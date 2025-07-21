# Quick ElizaOS Setup for Peridot Bot Integration

This guide helps you set up ElizaOS to test your Peridot Telegram Bot's write operations.

## Option 1: Docker Setup (Easiest)

```bash
# Clone ElizaOS
git clone https://github.com/elizaos/eliza.git
cd eliza

# Run with Docker
docker-compose up -d

# ElizaOS will be available at http://localhost:3000
```

## Option 2: Development Mock (For Testing)

If you want to test without full ElizaOS setup, you can create a mock server:

```bash
# In your project root
mkdir mock-eliza
cd mock-eliza
npm init -y
npm install express cors
```

Create `mock-eliza/server.js`:

```javascript
const express = require("express");
const cors = require("cors");

const app = express();
app.use(cors());
app.use(express.json());

// Mock the /tx endpoint that your bot calls
app.post("/tx", (req, res) => {
  const { method, args, from } = req.body;

  console.log(`Mock TX: ${method}`, args, "from:", from);

  // Return a fake transaction hash
  const mockTxHash = "0x" + Math.random().toString(16).substr(2, 64);

  res.json({
    success: true,
    txHash: mockTxHash,
    message: `Mock ${method} transaction submitted`,
  });
});

app.get("/health", (req, res) => {
  res.json({ status: "ok", message: "Mock ElizaOS running" });
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Mock ElizaOS running on http://localhost:${PORT}`);
});
```

Run the mock:

```bash
node server.js
```

## Option 3: Full ElizaOS Development Setup

```bash
# Clone and setup ElizaOS
git clone https://github.com/elizaos/eliza.git
cd eliza

# Install dependencies
npm install

# Configure for your environment
cp .env.example .env
# Edit .env with your RPC URLs and keys

# Start ElizaOS
npm run dev
```

## Testing Your Integration

Once ElizaOS (real or mock) is running on http://localhost:3000:

1. Start your Peridot bot: `npm run dev`
2. In Telegram, use `/start` to create a wallet
3. Try `/supply USDC 10` or `/borrow USDT 5`
4. Check the logs to see the API calls

## Next Steps

After testing the Skateboard stage, we'll move to **Scooter stage** improvements:

- Better UX with inline keyboards
- Enhanced security with scrypt encryption
- Additional operations (repay, redeem, claim, approve)

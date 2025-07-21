const express = require("express");
const cors = require("cors");

const app = express();
app.use(cors());
app.use(express.json());

// Mock transaction database (in-memory)
const transactions = new Map();

// Mock the /tx endpoint that your Peridot bot calls
app.post("/tx", (req, res) => {
  const { method, args, from } = req.body;

  console.log("\n🔥 MOCK TRANSACTION RECEIVED:");
  console.log(`   Method: ${method}`);
  console.log(`   Args:`, args);
  console.log(`   From: ${from}`);

  // Simulate some validation
  if (!method || !args || !from) {
    return res.status(400).json({
      success: false,
      error: "Missing required fields: method, args, from",
    });
  }

  // Generate a realistic-looking transaction hash
  const mockTxHash =
    "0x" +
    Array.from({ length: 64 }, () =>
      Math.floor(Math.random() * 16).toString(16)
    ).join("");

  // Store the mock transaction
  const txData = {
    hash: mockTxHash,
    method,
    args,
    from,
    timestamp: new Date().toISOString(),
    status: "pending",
  };

  transactions.set(mockTxHash, txData);

  // Simulate processing delay and update status
  setTimeout(() => {
    if (transactions.has(mockTxHash)) {
      transactions.get(mockTxHash).status = "confirmed";
      console.log(`✅ Transaction ${mockTxHash.slice(0, 10)}... confirmed`);
    }
  }, 3000);

  console.log(`✅ Mock TX Hash: ${mockTxHash}`);
  console.log("");

  res.json({
    success: true,
    txHash: mockTxHash,
    message: `Mock ${method} transaction submitted successfully`,
    estimatedConfirmation: "3 seconds",
  });
});

// Health check endpoint
app.get("/health", (req, res) => {
  res.json({
    status: "ok",
    message: "Mock ElizaOS running",
    uptime: process.uptime(),
    transactions: transactions.size,
  });
});

// Get transaction status endpoint
app.get("/tx/:hash", (req, res) => {
  const { hash } = req.params;
  const tx = transactions.get(hash);

  if (!tx) {
    return res.status(404).json({
      success: false,
      error: "Transaction not found",
    });
  }

  res.json({
    success: true,
    transaction: tx,
  });
});

// List all mock transactions
app.get("/transactions", (req, res) => {
  const allTx = Array.from(transactions.values());
  res.json({
    success: true,
    count: allTx.length,
    transactions: allTx,
  });
});

const PORT = process.env.PORT || 3000;

app.listen(PORT, () => {
  console.log(`
🎭 Mock ElizaOS Server Started!
   
🌐 Server: http://localhost:${PORT}
📊 Health: http://localhost:${PORT}/health
📋 Transactions: http://localhost:${PORT}/transactions

🔄 Ready to receive mock transactions from your Peridot bot!
   
Try these commands in your Telegram bot:
   /supply USDC 10
   /borrow USDT 5
   
✨ All transactions will be logged here in real-time.
`);
});

// Graceful shutdown
process.on("SIGTERM", () => {
  console.log("🛑 Mock ElizaOS server shutting down...");
  process.exit(0);
});

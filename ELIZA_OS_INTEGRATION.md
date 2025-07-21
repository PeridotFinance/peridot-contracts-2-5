# ElizaOS Integration Roadmap (Skateboard → Car)

This document outlines an incremental, value-driven path to integrate **ElizaOS** into the Peridot Telegram Bot. Each stage delivers a shippable product, gradually adding sophistication while minimising risk.

> MVP first – release early, learn fast, iterate.

---

## Legend

| Stage | Nick-name         | Goal                                                        | Ship-ready? |
| ----- | ----------------- | ----------------------------------------------------------- | ----------- |
| 1     | 🛹 **Skateboard** | Minimal write-interaction & automatic wallet creation       | ✅          |
| 2     | 🛴 **Scooter**    | Better UX & security around key handling + core write flows | ✅          |
| 3     | 🏍️ **Motorcycle** | Advanced TX preview, confirmations, gas tuning              | ✅          |
| 4     | 🚗 **Car**        | Full protocol feature parity, multi-chain, production-grade | ✅          |

---

## 1. Skateboard – _Functional but basic_

### User Experience

1. User hits `/start` →
   - Bot generates a fresh EOA via `ethers.Wallet.createRandom()`
   - Stores `address`, `encryptedPrivateKey` (AES-256 + user-specific salt) in DB
   - Replies with quick-start card:
     ```
     ✅ Wallet created!
     Address: 0x...
     • Fund with test tokens
     • Use /export_wallet to view private key (⚠️)
     ```
2. **Write actions** via ElizaOS proxy:
   - `/supply <symbol> <amount>`
   - `/borrow <symbol> <amount>`

### Engineering Tasks

- [x] Add `ElizaClient` service that wraps ElizaOS HTTP endpoint (env `ELIZA_API_URL`).
- [x] Extend `wallet.ts` with `createNewUserWallet(ctx)` helper.
- [x] Hook into `bot.start()` middleware to auto-create wallet & DB record.
- [x] Implement `/export_wallet` (private key returned _once_, then deleted from message after 20 s).
- [x] Minimal error handling + logging.

### Exit Criteria

- ✅ Wallet auto-creation proven on test chat.
- ✅ Able to call `supply` & `borrow` that hit ElizaOS sandbox.

### Implementation Notes (Current Status)

- **Storage**: Currently using in-memory storage (Map). Wallet data is lost on bot restart.
- **Security**: Using AES-256 encryption with user-specific salts. Consider upgrading to scrypt KDF in Scooter stage.
- **Environment**: Add `ELIZA_API_URL=http://localhost:3000` to your `.env` file to enable write operations.
- **Testing**: Ensure ElizaOS is running on the configured endpoint before testing write commands.

---

## 2. Scooter – _Usable & safer_

### Enhancements

1. **Inline buttons** in the wallet card: `🔑 Show Key`, `💰 Fund`, `❓ Help`.
2. Encrypt privKey at rest with user-defined passphrase (`/set_passphrase`).
3. Support additional ops: `repay`, `redeem`, `claim`, `approve`.
4. **Throttling**: rate-limit write ops per user (cool-down, anti-spam).
5. Improved error surfacing from ElizaOS (reason codes → human text).

### Engineering Tasks

- [x] Migrate DB column `encryptedPrivateKey` to include KDF (scrypt) metadata.
- [x] Add `keyboard.ts` utilities for dynamic inline keyboards.
- [x] Implement generic `executeWrite(action, params)` service.
- [x] Comprehensive unit tests for wallet lifecycle.

### Exit Criteria

- ✅ Keys remain encrypted even if DB leaked.
- ✅ UX to reveal key behind confirmation & auto-redact.
- ✅ Core 5 write operations work reliably.

### Implementation Notes (Scooter Complete)

- **Enhanced Security**: Implemented scrypt KDF with user-defined passphrases
- **Inline Keyboards**: Added interactive buttons for wallet management and operations
- **Rate Limiting**: Built-in protection against spam for all write operations
- **Additional Operations**: Added repay, redeem, claim, approve commands
- **Error Handling**: Improved error messages and user feedback

---

## 3. Motorcycle – _Advanced control & feedback_

### Features

1. **Transaction preview**: before sending, bot shows gas estimate, slippage, risk delta. User confirms ✅ / ❌.
2. **Queued actions**: batch multiple writes into single mutlisend via ElizaOS if supported.
3. **Gas management**: option to set max priority fee.
4. **Notifications**: push updates on TX mined / failed.

### Engineering Tasks

- [ ] Integrate `eth_estimateGas` + price oracle for USD cost.
- [ ] Scheduler / job-queue (BullMQ) for TX tracking.
- [ ] UX flows with `ctx.editMessageText` to update status.
- [ ] Add telemetry for all write attempts.

### Exit Criteria

- User always sees preview & must confirm.
- Bot notifies within 30 s of TX mining on test-net.

---

## 4. Car – _Full-featured & production-grade_

### Capabilities

1. **Multi-chain** (Ethereum, Base, Arbitrum) with automatic chain selection.
2. **Role-based auth** (admin, beta-tester) & feature flags.
3. **Position health monitor** with auto-liquidation alerts.
4. **Smart batching**: combine supply/borrow + collateral update.
5. **Seamless AI chat** mixing GPT-4o for explanations & ElizaOS writes in same thread.
6. **Security**: HSM or KMS for key encryption, rotation policy.

### Engineering Tasks

- [ ] Decouple chain config; inject provider per command.
- [ ] Migrate to persistent job store (Redis cluster).
- [ ] Pen-test key management flow, formal audit.
- [ ] Stress & load testing.

### Exit Criteria

- Main-net launch with 0 critical vulns.
- Handle 10k DAU with p99 < 1 s response.

---

## Cross-cutting Concerns

| Concern           | Approach                                                                        |
| ----------------- | ------------------------------------------------------------------------------- |
| **Security**      | AES-256-GCM, scrypt KDF, ENV-based salts, message auto-delete, HSM in Car stage |
| **Testing**       | Jest unit tests, integration tests with Hardhat node, staging TG bot            |
| **Observability** | Winston logs → Loki, Prom metrics, Grafana alerts                               |
| **CI/CD**         | GitHub Actions → Docker → Fly.io staging, production gates                      |

---

## Milestone Timeline (T-shirt sizing)

| Stage      | Duration  | Target Date |
| ---------- | --------- | ----------- |
| Skateboard | 3 days    | **T+3**     |
| Scooter    | 1 week    | T+10        |
| Motorcycle | 2 weeks   | T+24        |
| Car        | 3–4 weeks | T+45        |

---

## Appendix A – Example Code Snippets

```ts
// wallet.ts
export async function createUserWallet(userId: number) {
  const wallet = ethers.Wallet.createRandom();
  const encrypted = await encryptPrivateKey(wallet.privateKey, userId);
  await db.wallet.insert({ userId, address: wallet.address, encrypted });
  return wallet.address;
}
```

```ts
// elizaClient.ts
export async function executeWrite(
  method: string,
  args: Record<string, string | number>,
  user: TGUser
) {
  const res = await axios.post(`${ELIZA_API_URL}/tx`, { method, args, user });
  return res.data.txHash;
}
```

---

**✅ Stage 1 (Skateboard) Complete!**

**Next step:** Deploy bot to staging, gather user feedback, then proceed to Stage 2 (Scooter) for enhanced UX and security improvements.

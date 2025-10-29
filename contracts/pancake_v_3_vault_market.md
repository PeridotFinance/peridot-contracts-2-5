## Peridot Pancake V3 LP Vault Market Design

### Goal
Enable Peridot users to **supply PancakeSwap v3 LP liquidity** as collateral, while continuing to earn **farm APY** from Pancake, plus **borrow interest** from Peridot markets.

---

## 1. High-Level Idea

Peridot cannot list Pancake v3 LP **NFTs** directly — they are non-fungible and vary by range/liquidity. Instead, we wrap LP NFTs into a **fungible ERC-4626 vault share** token that can be used as the underlying for a **pToken market**.

Users supply or borrow against this vault share just like any other ERC-20.

**Key benefits:**
- Users earn **yield from Pancake (CAKE rewards + fees)** and **borrow interest**.
- Fungible ERC-4626 shares integrate seamlessly with Compound-style logic.
- Oracle risk and liquidation paths remain manageable.

---

## 2. Architecture Overview

```
User → Router → V3LPVault4626 → pToken Market → Comptroller
                                ↓
                          Pancake v3 MasterChef
```

**Core components:**
- `V3LPVault4626`: wraps a Pancake v3 pool and stakes NFTs into MasterChef.
- `V3LPVaultOracle`: provides USD price per vault share.
- `pERC20`: Peridot market with underlying = Vault Share.
- `Router`: UX layer to go from tokens → vault shares → supply to market.

---

## 3. Components

### A. `V3LPVault4626`
A yield-bearing ERC-4626 vault that manages a **single pool** and **tick range**.

**Features:**
- Accepts deposits of token0 + token1, mints ERC-20 shares.
- Internally holds one or more Pancake v3 NFTs for that pool/range.
- Stakes NFTs into MasterChef v3 to earn CAKE.
- Harvests CAKE, swaps to token0/token1, compounds back into liquidity.
- `totalAssets()` = value of liquidity + unclaimed fees + accrued CAKE.

**Interface:**
```solidity
interface IV3LPVault4626 is IERC4626 {
  function pool() external view returns (address);
  function tickLower() external view returns (int24);
  function tickUpper() external view returns (int24);
  function harvest() external;
  function totalAssets() external view returns (uint256);
}
```

---

### B. `V3LPVaultOracle`
Calculates fair value of 1 vault share in USD.

**Inputs:**
- Pancake v3 pool state (`slot0`, `tick`, `sqrtPriceX96`).
- Vault liquidity + uncollected fees.
- Chainlink feeds for token0/token1 and CAKE.

**Formula:**
```
value = token0_value + token1_value + uncollected_fees + (CAKE_rewards * CAKE_price)
pricePerShare = value / totalSupply
```

**Risk mitigations:**
- 30m TWAP for price.
- Conservative haircut on CAKE value.
- Ignore stale oracles.

---

### C. `pToken Market`
Standard Peridot pERC20 market where the **underlying asset** is the **Vault Share** token.

Suppliers earn:
1. Borrow interest from borrowers.
2. Vault yield via share appreciation.

No double counting—Peridot interest accrues on top of underlying share price changes.

---

### D. Liquidations

**Option 1 (Recommended):**
- Liquidator seizes vault shares (ERC-20) and later redeems for token0/token1.
- Simple, flexible, minimal protocol logic.

**Option 2 (Advanced):**
- Integrate a VaultLiquidationAdapter that auto-unwinds positions to repay debt.

Start with **Option 1** for simplicity.

---

## 4. Risk Parameters

| Parameter | Full-Range Pool | Narrow-Range Pool |
|------------|-----------------|-------------------|
| Collateral Factor (LTV) | 45% | 30-35% |
| Reserve Factor | 15% | 20% |
| Borrow Cap | Tight | Tight |
| Oracle Haircut | 2% | 5% |

**Dynamic LTV:** If vault is out-of-range, temporarily reduce LTV or freeze new borrows.

---

## 5. Implementation Plan

1. **Build & Audit** `V3LPVault4626` + `FarmAdapter` + Uniswap v3 math utils.
2. Implement **`V3LPVaultOracle`** with TWAP + Chainlink.
3. Launch **full-range** vault for stable pair (e.g. BNB/USDT 0.05%).
4. Deploy **pToken market** for vault shares.
5. Add **Router** for one-click deposit → vault → supply.
6. Monitor yield & risk; later add **managed-range** vaults.

---

## 6. Gotchas & Mitigations

| Risk | Mitigation |
|------|-------------|
| Out-of-range LP | Start with full-range, dynamic LTV |
| Oracle manipulation | TWAP + Chainlink + haircuts |
| Harvest front-run | Keeper with min-profit threshold |
| Withdrawal slippage | Maintain idle buffer |
| Reward volatility | Auto-swap CAKE to base tokens |
| Strategy trust | Tick width/cooldown/slippage limits |

---

## 7. APY Summary

Total supplier APY ≈ **Vault APY + Peridot Lending APY**

Where:
- Vault APY = LP fees + CAKE rewards + auto-compounding.
- Peridot Lending APY = Interest from borrowers.

---

### Next Steps
- Implement `totalAssets()` logic with v3 math.
- Define oracle pricing contract for Peridot Comptroller integration.
- Optionally design a liquidation adapter for one-tx unwind.

---

**Implementation status:** `contracts/pancakev3/` now ships an ERC-4626 vault that mints/increases Pancake v3 NFT liquidity via the position manager (single range), optional MasterChef hooks, and share accounting grounded in v3 math (`TickMath`, `LiquidityAmounts`, `FullMath`). Harvesting is wired through the Pancake router adapter—CAKE rewards can be swapped into pool tokens, restaked, and tracked via `lastHarvest`. The oracle prices shares using admin-set feeds once Chainlink aggregators are registered. Deterministic mocks plus tests in `test/PancakeV3Vault.t.sol` exercise mint/top-up/withdraw/harvest/price flows; production TWAP haircuts and live MasterChef wiring remain future steps.

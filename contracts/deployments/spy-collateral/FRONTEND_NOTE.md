# Frontend note: pSPY as lending collateral (forward to the frontend developer once the ceremony is signed)

Nothing here is live until the operator runs `tools/spy-collateral/ceremony.sh` (after the SPY margin ceremony).

**Market:** pSPY `0xa6660499a9cB9B6691247fE1FAbc248f502E5fB3` on controller `0x6148183676E304dbe63a85C350c208DA3cEAc39C`.
It becomes ordinary lending collateral at a **30 % collateral factor**. Borrowing SPY stays paused. Borrow USDG from pUSDG
`0x55aEd0569c8f0D166D71facE57B57C2f2624a563` as usual. Prices: the controller oracle is unchanged
(`RobinhoodLendingPriceAdapter3`, from the SPY margin ceremony).

**New reads on pSPY (implementation `RobinhoodSpyCollateralDelegate`):**
- `sessionReason() -> uint256`: 0 = SPY open. Otherwise: 1 SPY paused, 2 oracle paused, 3 feed unreadable, 4 bad answer,
  5 incomplete round, 6 stale (> 25 h), 7 weekend window (Sat 00:00 to Mon 01:00 UTC), 8 lending-oracle mismatch,
  255 source unreadable.
- `lendingSupplyCap()` and `totalUnderlyingSupply()` are both in SPY wei (18 decimals). A non-margin `mint` reverts
  `LendingSupplyCapExceeded(total, cap)` once the total would exceed the cap. Show "SPY collateral is full".
- `getAccountSnapshot(account)` now returns a **nonzero error code** (the reason above) while SPY is closed, for accounts
  that hold pSPY. Lens code must not assume error = 0.

**UI states while `sessionReason() != 0`**, for an account that holds pSPY and has entered the pSPY market:
- Only **repay** works.
- Borrow, withdraw (any market), transfer of pTokens and "disable as collateral" (`exitMarket`) all fail.
  `getAccountLiquidity` returns error 15 (SNAPSHOT_ERROR); show it as "SPY market closed: repay only".
- Liquidations are also off.
- This applies even when the account has no debt. **Do not auto-enter pSPY on supply.** Ask "use as collateral" as a
  separate step, and offer "disable as collateral" only while SPY is open.
- Accounts that hold no pSPY, and all margin positions, are unaffected.

**Unchanged:** NVDA and USDG lending and every margin flow. The SPY margin weekend rules are in `../spy-margin/FRONTEND_NOTE.md`.

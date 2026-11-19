# pSPY as plain lending collateral (feat/spy-collateral): build record

Nothing here is live. Scope and design: `../../../SCOPE.md`. To go live, the operator signs the command list
`tools/spy-collateral/ceremony.sh` after the SPY margin ceremony, in a weekday US session with a fresh RHSPY feed.

## Contracts (`contracts/margin/spy/`, profile `robinhood_spy`: 0.8.26, via-IR, runs 1, cancun)

| Contract | Role | Runtime B (EIP-170 headroom) |
| --- | --- | --- |
| `RobinhoodSpyCollateralDelegate` | New pSPY implementation. It is the plain delegate's two October corrections plus: (1) a session gate, where `getAccountSnapshot` returns the SPY source reason as its error for non-margin pSPY holders while SPY is closed or stale; (2) a lending supply cap on non-margin mints, measured in SPY against total pSPY. One appended storage slot (21, `lendingSupplyCap`). Immutable `spySource`. | 18,964 (5,612) |
| `SpyCollateralLiquidator` | Immutable, no admin. Flash USDG, `liquidateBorrow`, redeem pSPY, swap via router adapter 0xa32C, repay; proceeds to the Ledger. | 3,812 (20,764) |
| `PToken.getAccountSnapshot` | Now `virtual`. `RobinhoodPlainDelegate` compiles byte-identical with and without the change. | n/a |

Storage layout: `RobinhoodPlainDelegate` slots 0-20 (`implementation` = 20) and `RobinhoodSpyCollateralDelegate` slots 0-20 are
identical, and slot 21 is the cap. Live pSPY: slot 20 = 0x0a23…d408 and slot 21 = 0 (read 2026-11-19).

## Parameters (operator-pending)

| Parameter | Value | Where |
| --- | --- | --- |
| Collateral factor | 30 % | `SPY_CF_MANTISSA` |
| Lending supply cap | 0.23 SPY (~$165 at $716.12; SPY-backed borrow ceiling ~$49.4) | `SPY_LENDING_CAP_WEI`; later `_setLendingSupplyCap` |
| Liquidator swap floor | SPY source price − 1 % | constructor |

pUSDG `borrowCap` stays at 1,000 USDG. It is shared with margin debt, so it is not used as the SPY cap.

## Tests

| Suite | Result |
| --- | --- |
| Unit `test/spy/SpyCollateralDelegate.t.sol` (real Peridottroller + delegators, incl. 1 fuzz) | 27 / 27 |
| Existing SPY unit suites (`SpyMarginPriceSource`, `RouterAndAdapter`) | 32 / 32 |
| Hand-written mutants (`tools/spy-collateral/mutate.py`) | 24 / 24 killed |
| Fork `test/spy/SpyCollateralFork.t.sol` (SPY margin ceremony applied with the deployed contracts, then this ceremony) | 10 / 10 |
| Existing SPY margin fork suites (parity, long, weekend), same pin | 27 / 27 |
| Keeper (`.wt-margin-keeper-collateral`, `infra/app-platform`: test_lending + test_gas_cap) | 22 / 22 |

Fork pin: `SPY_FORK_BLOCK=118572697 SPY_NATIVE_BLOCK=26452141` (Thu 2026-11-19 22:32 UTC). The run used the RPC cache
captured within minutes of the pin.

Fork coverage:
- Borrow at 30 % CF (liquidity = 30 % of the SPY value) and the cap: lending mints revert past 0.23 SPY, while margin opens past the cap still succeed.
- Weekend window (reason 7) and stale feed (reason 6):
  - borrow, redeem, redeemUnderlying, transfer, exitMarket, `liquidateBorrow` and the flash liquidator all revert;
  - repay works;
  - everything resumes on a fresh print.
- Liquidation when fresh through the flash liquidator after a −20 % print: 891k gas; profit to the Ledger, nothing left in the contract.
- NVDA-only accounts are unchanged, value for value:
  - live account 0x12c1… liquidity, in session and at the weekend, plus position 6 metrics, before and after the ceremony;
  - after entering pSPY with a zero balance.
- SPY margin is unaffected:
  - position metrics bit-identical across the ceremony;
  - margin accounts exempt from the gate at the weekend;
  - repay plus `exitDebtFreeToPTokens` at the weekend.
- Donation inflation: the donor gains less borrowing power than it costs.
- Rollback ordering (cap 0, then CF 0, which makes SPY-backed debt liquidatable).

## Anvil rehearsal (`tools/spy-collateral/rehearse_ceremony.sh`, fork block 118573557, Thu 2026-11-19 22:33 UTC): passed

The SPY margin ceremony ran first (`tools/spy/ceremony.sh`, deployed SPY margin contracts):
- preflight, t0 (13 Ledger txs), 1 h warp, gate, t1 (3).

Then this ceremony:
- **Deploy:** throwaway deploy, 2 txs.
- **Collateral ceremony:** preflight, t0 (3 Ledger txs), demo-open (4), the lending keeper, demo-close (5), verify.
- **Lending keeper:**
  - 0.1 SPY borrower: healthy.
  - −20 % print: `executable_plan`.
  - `--execute`: one liquidation of 10.63 USDG (half the debt), 988,755 gas, 3.28 USDG profit to the Ledger. The profit is large only because the rehearsal moves the feed and not the pool.
- **Weekend (Sat 12:00 UTC):** `closed-check` passed (reason 7, SNAPSHOT_ERROR; borrow, redeem, transfer and liquidation refused), a repay succeeded, and the keeper reported `spy_closed`.
- **Rollback:** R1-R3 (3).

Total: 15 collateral-ceremony Ledger txs including demo and rollback.

Rehearsal-only deviations, the same as the SPY margin rehearsal:
- pUSDG/pNVDA accrual was aligned to anvil's block number;
- the RHSPY feed was etched with an always-fresh fixed-answer mock.

### Gas per Ledger step (rehearsal)

| Step | Call | Gas |
| --- | --- | --- |
| 1 | pSPY `_setImplementation(delegate, false, abi.encode(cap))` | 60,236 |
| 2 | router adapter `setOperator(liquidator, true)` | 47,780 |
| 3 | controller `_setCollateralFactor(pSPY, 0.3e18)` | 79,285 |
| D1-D4 | SPY approve / pSPY mint / enterMarkets / pUSDG borrow | 63,625 / 200,269 / 100,556 / 538,856 |
| D5-D9 | USDG approve / repayBorrow(max) / approve 0 / pSPY redeem / exitMarket | 58,324 / 252,600 / 36,040 / 345,382 / 220,570 |
| R1-R3 | cap 0 / CF 0 / setOperator false | 31,418 / 35,177 / 25,868 |

## Evidence (not committed; SHA-256 of the local files in `/Users/joshua/Peridot/.wt-spy-collateral/.scratch/`)



| SHA-256 | File (`.scratch/`) |
| --- | --- |
| 03a83599b87533e10a0f07473db23e9abe7ac47fc4fd0088d7271ebe97716e3f | rehearsal-run1.log |
| d6cfbd1c878bc47c00a200d14892a4482b006600fe1459e43f24459f4dd08eac | fork-all-run2.log |
| 2a0cef40a8d36b82a3017dc147e082323990e16834ef8ad49e0d1630e4ae86e6 | fork-collateral-run1.log (first run: 9/10, test-side exchange-rate capture fixed before run 2) |
| 2113b3ec36100ea670b785f3d4db3bd1e09a040fd6264e578a253be2f32faf29 | mutate-run2.log |
| 28fbca630c67804412274c2f9646f2cfac577e5414d631f778fc46e824f473fd | fork-pin.env |
| 054507638906195978d48360ca2a0760f1fb7eed009c3dea93bd16250676b0e4 | rehearsal/t0.log |
| 270485b38b9affa929647ce5d2efae0554d07cc958235b6c0fc6695082a268f4 | rehearsal/preflight.log |
| 5b7f162c1f8c9f9d54fa6f8477d0e3fbb567f9d62e150374740a8e5f1ad15c5b | rehearsal/keeper-3.log |
| e71ee1208a64e4d5860ce715dbef2652bcbbbaa5c82907be8d4cd37a9d62d9ce | rehearsal/closed-check.log |
| ad48d6e98b7c652df1897a223333b048faa720be2ec2dbf0b05557902665d7d0 | rehearsal/rollback.log |
| 3af50bc9ee4c05bd66df7a035510151aa78f106386c803d972b96390427920cb | rehearsal/deploy.log |

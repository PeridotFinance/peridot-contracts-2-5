# pSPY as plain lending collateral (feat/spy-collateral): build record

Nothing here is live. Scope and design: `../../../SCOPE.md`. To go live, the operator signs the command list
`tools/spy-collateral/ceremony.sh` after the SPY margin ceremony, in a weekday US session with a fresh RHSPY feed.

## Contracts (`contracts/margin/spy/`, profile `robinhood_spy`: 0.8.26, via-IR, runs 1, cancun)

| Contract | Role | Runtime B (EIP-170 headroom) |
| --- | --- | --- |
| `RobinhoodSpyCollateralDelegate` | New pSPY implementation. It is the plain delegate's two October corrections plus: (1) a session gate, where `getAccountSnapshot` returns the SPY source reason as its error for non-margin pSPY holders while SPY is closed or stale; (2) `seize` reverts while SPY is withheld (covers un-entered holders, whom the snapshot gate never reads); (3) a lending supply cap on non-margin mints, measured in SPY against total pSPY. One appended storage slot (21, `lendingSupplyCap`). Immutable `spySource`. | 18,999 (5,577) |
| `SpyCollateralLiquidator` | Immutable, no admin. Flash USDG, `liquidateBorrow`, redeem pSPY, swap via router adapter 0xa32C, repay; proceeds to the Ledger. | 3,812 (20,764) |
| `PToken.getAccountSnapshot`, `PToken.seize` | Now `virtual`. `RobinhoodPlainDelegate` executable bytecode is unchanged by both (only the CBOR metadata hash differs). | n/a |

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
| Unit `test/spy/SpyCollateralDelegate.t.sol` (real Peridottroller + delegators, incl. 1 fuzz) | 28 / 28 |
| Existing SPY unit suites (`SpyMarginPriceSource`, `RouterAndAdapter`) | 32 / 32 |
| Hand-written mutants (`tools/spy-collateral/mutate.py`) | 25 / 25 killed |
| Fork `test/spy/SpyCollateralFork.t.sol` (SPY margin ceremony applied with the deployed contracts, then this ceremony) | 11 / 11 |
| Existing SPY margin fork suites (parity, long, weekend), same pin | 27 / 27 |
| Keeper (`.wt-margin-keeper-collateral`, `infra/app-platform`: test_lending + test_gas_cap) | 23 / 23 |

Fork pin: `SPY_FORK_BLOCK=118584093 SPY_NATIVE_BLOCK=26452241` (Thu 2026-11-19 22:52 UTC; an earlier run at 118572697 passed too, before the seize gate). The run used the RPC cache
captured within minutes of the pin.

Fork coverage:
- Borrow at 30 % CF (liquidity = 30 % of the SPY value) and the cap: lending mints revert past 0.23 SPY, while margin opens past the cap still succeed.
- Weekend window (reason 7) and stale feed (reason 6):
  - borrow, redeem, redeemUnderlying, transfer, exitMarket, `liquidateBorrow` and the flash liquidator all revert;
  - repay works;
  - everything resumes on a fresh print.
- An un-entered pSPY holder with NVDA-side shortfall at the weekend: `liquidateBorrow(..., pSPY)` reverts `SpySessionClosed(7)`, while the NVDA collateral stays liquidatable.
- Liquidation when fresh through the flash liquidator after a −20 % print: 902k gas; profit to the Ledger, nothing left in the contract.
- NVDA-only accounts are unchanged, value for value:
  - live account 0x12c1… liquidity, in session and at the weekend, plus position 6 metrics, before and after the ceremony;
  - after entering pSPY with a zero balance.
- SPY margin is unaffected:
  - position metrics bit-identical across the ceremony;
  - margin accounts exempt from the gate at the weekend;
  - repay plus `exitDebtFreeToPTokens` at the weekend.
- Donation inflation: the donor gains less borrowing power than it costs.
- Rollback ordering (cap 0, then CF 0, which makes SPY-backed debt liquidatable).

## Anvil rehearsal (`tools/spy-collateral/rehearse_ceremony.sh`, fork block 118584663, Thu 2026-11-19 22:53 UTC; with the seize gate): passed

The SPY margin ceremony ran first (`tools/spy/ceremony.sh`, deployed SPY margin contracts):
- preflight, t0 (13 Ledger txs), 1 h warp, gate, t1 (3).

Then this ceremony:
- **Deploy:** throwaway deploy, 2 txs.
- **Collateral ceremony:** preflight, t0 (3 Ledger txs), demo-open (4), the lending keeper, demo-close (5), verify.
- **Lending keeper:**
  - 0.1 SPY borrower: healthy.
  - −20 % print: `executable_plan`.
  - `--execute`: one liquidation of 10.63 USDG (half the debt), 999,857 gas, 3.28 USDG profit to the Ledger. The profit is large only because the rehearsal moves the feed and not the pool.
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
| ad41911809bab6a3cab35f9ae2fdbcc6b6ffc8d609f7ce0fcf4815f2f0612863 | rehearsal-run2.log |
| 3d26e06e062f1e4472390d4927982feea8bb4888b74e26c00919a6c1b70ee896 | fork-all-run3.log |
| da6973a113add3c6686fb6ea9f2b4054d7e1fc212aa64c3bdc642f8e97ac7917 | mutate-run3.log |
| fa9a2ae8ee1435425694b40f1886ff6c010575266a6b7c52b46ee93239a00c27 | fork-pin.env |
| b83b1c07add314d26d4340dac9b482279e0767fea9d778c0ac638b3a7be658d0 | worker-smoke-false.log |
| 2c957adffb7618307e87b44d69be4d9ad0f88a12ee3677f626f5eb927fc50577 | worker-smoke-true.log |
| b73e7fab19a709d15dc4af9ff5e0a7a90a33365b317f7e5b91563df5c53ba56b | rehearsal/t0.log |
| 270485b38b9affa929647ce5d2efae0554d07cc958235b6c0fc6695082a268f4 | rehearsal/preflight.log |
| 1957ece71bf8ae551a7555bf98a3eb134f7c180a7cf5d36ec682f519734b0b68 | rehearsal/keeper-3.log |
| 6a208dcaf5ad065d2de0d55477f38a93014c84e5b8a29a84b9015a8a9e7b1189 | rehearsal/keeper-4.log |
| e71ee1208a64e4d5860ce715dbef2652bcbbbaa5c82907be8d4cd37a9d62d9ce | rehearsal/closed-check.log |
| 61b57858b654e1c7504c5a5a4830c14bbd00f2f1be4b835db1b0ce1eb927294f | rehearsal/rollback.log |
| b810f76839a45d412e8d36b2f7ccdf3b1de656b035851d6fa60b483357756fd1 | rehearsal/deploy.log |
| 03a83599b87533e10a0f07473db23e9abe7ac47fc4fd0088d7271ebe97716e3f | rehearsal-run1.log (superseded: before the seize gate) |
| d6cfbd1c878bc47c00a200d14892a4482b006600fe1459e43f24459f4dd08eac | fork-all-run2.log (superseded: before the seize gate) |
| 2113b3ec36100ea670b785f3d4db3bd1e09a040fd6264e578a253be2f32faf29 | mutate-run2.log (superseded: before the seize gate) |

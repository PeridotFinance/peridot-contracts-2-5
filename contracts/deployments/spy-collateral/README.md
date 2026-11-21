# pSPY as plain lending collateral (feat/spy-collateral): build record

Nothing here is live. Scope and design: `../../../SCOPE.md`. To go live, the operator signs the command list
`tools/spy-collateral/ceremony.sh` after the SPY margin ceremony, in a weekday US session with a fresh RHSPY feed.

## Contracts (`contracts/margin/spy/`, profile `robinhood_spy`: 0.8.26, via-IR, runs 1, cancun)

| Contract | Role | Runtime B (EIP-170 headroom) |
| --- | --- | --- |
| `RobinhoodSpyCollateralDelegate` | New pSPY implementation. It is the plain delegate's two October corrections plus: (1) a session gate for non-margin pSPY holders while SPY is closed or stale. If the holder has a borrow balance in any controller market (`getAssetsIn` + `borrowBalanceStored`, views only), `getAccountSnapshot` returns the SPY source reason as its error and the account is frozen except for repay. If the holder is debt-free, the snapshot is served with a zero exchange rate: SPY counts as zero collateral, so redeem, transfer and exitMarket work, and a new borrow can only lean on other collateral; (2) `seize` reverts while SPY is withheld (covers un-entered holders, whom the snapshot gate never reads); (3) a lending supply cap on non-margin mints, measured in SPY against total pSPY. One appended storage slot (21, `lendingSupplyCap`). Immutable `spySource`. | 19,558 (5,018) |
| `SpyCollateralLiquidator` | Immutable, no admin. For pUSDG debt (`liquidate`): flash USDG, `liquidateBorrow`, redeem pSPY, swap SPY to USDG via router adapter 0xa32C, repay. For pNVDA debt (`liquidateNvdaDebt`): flash USDG, swap it to NVDA (floor: guarded NVDA margin price 0x25E0 − 1 %), liquidate, then the same SPY to USDG repayment. Proceeds, including any leftover NVDA, go to the Ledger. It flashes USDG because the vault's NVDA balance is only 0.025 NVDA; its USDG capacity is 105.27 USDG at 5 bp. | 6,043 (18,533) |
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
| Unit `test/spy/SpyCollateralDelegate.t.sol` (real Peridottroller + delegators, incl. 1 fuzz) | 35 / 35 |
| Existing SPY unit suites (`SpyMarginPriceSource`, `RouterAndAdapter`) | 32 / 32 |
| Hand-written mutants (`tools/spy-collateral/mutate.py`, 35 incl. 9 new for the 2026-11-21 changes) | 25 / 25 killed on the pre-11-21 code (mutate-run3). After the 11-21 changes, an earlier partial run (run4) caught one surviving mutant, which led to the margin-account rate assertion (that fix is in place). Run 5 killed 6 / 6 and was then stopped by the host for low memory, so **29 mutants are not yet re-run** (`python3 tools/spy-collateral/mutate.py`, ~1 min each) |
| Fork `test/spy/SpyCollateralFork.t.sol` (SPY margin ceremony applied with the deployed contracts, then this ceremony) | 16 / 16 (weekend pin 119751055, Sat 2026-11-21 08:42 UTC, warped to Mon 02:00 UTC with both feeds re-stamped) |
| Existing SPY margin fork suites (parity, long, weekend), Thursday pin 118584093 from the RPC cache | 27 / 27 |
| Keeper (`.wt-margin-keeper-collateral`, `infra/app-platform`: test_lending + test_gas_cap) | 25 / 25 |

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
- 2026-11-21 additions:
  - a debt-free holder withdraws at the weekend (transfer, redeem, exitMarket) and cannot borrow against SPY;
  - an account that repays to 0 at the weekend can then withdraw;
  - NVDA debt is liquidated through `liquidateNvdaDebt` after a −20 % SPY print (1.24M gas) and after a +20 % NVDA print (1.26M gas);
  - an indebted NVDA borrower is frozen at the weekend.
- The +20 % NVDA case stubs the guarded NVDA source with the shocked price, because the fork moves the feed and not the pool.

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
| 7c6b8c8fdb5d6e711af97c3116150023897c27d5da23cd8ebdcc75c7e2975e44 | fork-collateral-run6.log (fork 16/16 at 119751055) |
| 892d560bf10e9499e44d06d087f4e0374ccaba0a226b4512828d13d70891866c | fork-margin-cached-run.log (existing margin fork 27/27, cached pin) |
| 34b58a36cb6f0a51a2717cd9deea1512cfcfa9d251becd80a605da57a5c322ca | fork-pin-weekend.env |
| e38b48fe922f578526bbaaa83967d4543c8127873477ba2b16a8d06ac8e665b8 | mutate-run5.log (partial, stopped by host) |
| da6973a113add3c6686fb6ea9f2b4054d7e1fc212aa64c3bdc642f8e97ac7917 | mutate-run3.log (pre-11-21 code, 25/25) |
| ad41911809bab6a3cab35f9ae2fdbcc6b6ffc8d609f7ce0fcf4815f2f0612863 | rehearsal-run2.log (pre-11-21 rehearsal) |
| b83b1c07add314d26d4340dac9b482279e0767fea9d778c0ac638b3a7be658d0 | worker-smoke-false.log |
| 2c957adffb7618307e87b44d69be4d9ad0f88a12ee3677f626f5eb927fc50577 | worker-smoke-true.log |

## Demo sizing (operator decision 5)

Inputs: RHSPY $699.40 (Fri 11-20 close) and the 30 % collateral factor. The Ledger holds 0.0001477 SPY now, and 0.0000477 after the margin seed.

| | Value |
| --- | --- |
| Demo borrow | **5 USDG** |
| Collateral at exactly 5 USDG of power | 0.02383 SPY ($16.67) |
| Recommended collateral | **0.045 SPY** ($31.47). Borrowing power is $9.44, so 5 USDG is 53 % of it, and SPY can fall about 47 % before shortfall. `ceremony.sh demo-open` refuses above 60 %. |
| SPY to buy | 0.045 − 0.0000477 = **0.04495 SPY**, about 31.5 USDG at the pool: $31.44 plus the 0.30 % fee, with a 0.5 % slippage bound giving a budget of **≤ 31.8 USDG** |
| Ledger USDG | 106.22 in the wallet today. The margin ceremony t1 supplies 80, leaving about **26.2**, so the buy is **~5.6 USDG short**. Either redeem ~6 USDG of the Ledger's pUSDG first (one extra Ledger tx; pUSDG cash is ~108 after the margin supply), or borrow 4 USDG against 0.036 SPY (≤ 25.4 USDG). |
| Repay | The 5 USDG borrowed is held and repaid (`repayBorrow(max)`), so only interest dust is extra. |
| ETH | Demo ~1.9M gas plus the SPY buy ~0.3M gas: about 0.00005 ETH at 0.02 gwei. The Ledger holds 0.00251 ETH and the margin ceremony uses ~0.0005. |
| Lending cap | 0.045 SPY plus the margin demo position (~0.143 SPY if still open) plus the 0.0001 seed = 0.188 SPY, which is ≤ 0.23 |

## Rehearsal (run by the parent; not run by this build)

```
cd /Users/joshua/Peridot/.wt-spy-collateral/contracts && tools/spy-collateral/rehearse_ceremony.sh 2>&1 | tee ../.scratch/rehearsal-gate.log
```

It needs the keeper worktree at `KEEPER_REPO` (default `/Users/joshua/Peridot/RobinhoodVaults/.wt-margin-keeper-collateral`, branch margin-keeper-spy-collateral) and anvil port 8681 free. A fork started at a weekend is warped to Monday 02:00 UTC. Expected:
- SPY margin t0: 13 Ledger txs; t1: 3; deploy: 2 txs.
- Collateral t0: steps 1-3, each `status 0x1`, all `ok:` lines; demo-open borrows 5000000.
- Keeper:
  - healthy run: both borrowers `healthy`;
  - −20 % run: B (USDG debt) and C (NVDA debt) `executable_plan`;
  - execute run: two `confirmed` journals, about 1.0M and 1.25M gas, and a positive Ledger USDG profit.
- Weekend:
  - `closed-check` all `ok:`, including the debt-free account's redeem allowed and borrow refused;
  - the debt-free account's redeem and exitMarket `status 0x1`, and the repay `status 0x1`;
  - keeper `spy_closed`.
- Rollback: R1-R3 `status 0x1`.
- The last lines are `Ledger transactions sent ...: 15` and `REHEARSAL COMPLETE`.

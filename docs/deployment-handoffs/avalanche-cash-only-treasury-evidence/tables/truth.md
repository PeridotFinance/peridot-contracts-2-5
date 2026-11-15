### Truth table

| case | verdict | debt (USDC units) | debt value (USD) | collateral value (USD) | max recovery C/LI (USD) | shortfall (USD) |
|---|---|---|---|---|---|---|
| stage1 half-power borrower | HEALTHY | 833.33 | 832.9794 | 4,164.8971 | 0.0000 | 0.0000 |
| stage1 no debt | NO_DEBT | 0.00 | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| stage1 full-power after 30d interest (shortfall from interest only) | LIQUIDATABLE_RECOVERABLE | 1,683.11 | 1,682.3902 | 4,164.8971 | 3,856.3862 | 16.4314 |
| stage2 -20% full-power | LIQUIDATABLE_RECOVERABLE | 1,683.11 | 1,682.3902 | 3,331.9177 | 3,085.1090 | 349.6231 |
| stage2 half-power still healthy at -20% | HEALTHY | 833.33 | 832.9794 | 3,331.9177 | 0.0000 | 0.0000 |
| stage3 -75% tail before liquidation (account 0) | UNRECOVERABLE_LIQUIDATE_FIRST | 1,683.11 | 1,682.3902 | 1,041.2243 | 964.0966 | 1,265.9005 |
| stage3 -75% tail before liquidation (account 1) | UNRECOVERABLE_LIQUIDATE_FIRST | 1,683.11 | 1,682.3902 | 1,041.2243 | 964.0966 | 1,265.9005 |
| stage3 -75% half-power account is liquidatable and still recoverable | LIQUIDATABLE_RECOVERABLE | 833.33 | 832.9794 | 1,041.2243 | 964.0965 | 416.4897 |
| stage4 exhausted account FIRES | DEFAULT_EXHAUSTED | 718.60 | 718.2937 | 0.0000 | 0.0000 | 718.2937 |
| stage4 partially liquidated (collateral remains) does not fire | UNRECOVERABLE_LIQUIDATE_FIRST | 841.55 | 841.1951 | 132.7336 | 122.9014 | 788.1017 |
| stage4 untouched tail account does not fire | UNRECOVERABLE_LIQUIDATE_FIRST | 1,683.11 | 1,682.3902 | 1,041.2243 | 964.0966 | 1,265.9005 |
| stage4 recoverable account does not fire | LIQUIDATABLE_RECOVERABLE | 833.33 | 832.9794 | 1,041.2243 | 964.0965 | 416.4897 |
| stale AVAX: exhausted account does NOT fire | STALE_OR_ZERO_PRICE | 718.60 | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| stale AVAX: tail account | STALE_OR_ZERO_PRICE | 1,683.11 | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| stale: an account without debt needs no price | NO_DEBT | 0.00 | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| zero AVAX answer: does NOT fire | STALE_OR_ZERO_PRICE | 718.60 | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| after repayment | NO_DEBT | 0.00 | 0.0000 | 0.0000 | 0.0000 | 0.0000 |

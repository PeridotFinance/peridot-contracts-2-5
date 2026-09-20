# Fuji margin validation — 20 September 2026

## Scope and status

All production contracts are unchanged by this package. It adds operator scripts and
tests on `boosted-findings-remediation`, preserving unrelated Robinhood work.
Mainnet RPC access was read-only; all mainnet swaps and helper deployments occurred
inside a local Foundry fork. No mainnet deployment or production risk approval is implied.

The previous user-signed Fuji mock 5x-request long/short lifecycle is complete:

- Long 5: open `0x65c1fd9b962999895b7e9bf56f66a7f75839eaada72e33eb7fbf62e5a038e42f`, close `0x7e189d43e8f831a300bbef7052cfb59c852d50f02041cdf8cc26b79536da33f2`.
- Short 6: open `0x80b9b6149a87fc33b4ca2db42f70f099058dae6d09a381c876998faff1d9a66e`, close `0xde3a3d5e7cacab6cb1219a580cccc5de9b67b0e7e15ee87272b57433cc2b54a2`.
- Direct pToken withdrawal `0xeb8ffad294699e8c2e207cfac872cfe34b0c08d599c7d2ef337d9e8d33482ce5` returned 999999980000 raw pMockUSD without redemption.
- Verified post-withdrawal snapshot: Fuji 58511100, hash `0x97b1a306712ad4e9a317d32127b312bd115f88d71ac3f3b282c655ed71437de8`. Free/locked collateral, account debt, aggregate debt and borrow shares were zero; next position ID 7.
- Requested leverage was 5x; actual entry leverage was 4.80x long and 4.84x short because sizing reserves execution-cost headroom. Entry-time estimated liquidation prices were approximately $8.80 and $11.34 at a $10 AVAX entry, not fixed future guarantees.

`SmokeFujiMockFiveX.s.sol` is the completed historical one-shot script. Its replay
guards now reject the live state. Do not run it again.

## Added coverage

| Suite | Cases | Scope |
| --- | ---: | --- |
| `FujiMockFiveXSmokeForkTest` | 11 | Historical actual-deployment lifecycle, boundary search, stale feeds, replay/budget/configuration guards |
| `FujiMarginProductionStressForkTest` | 12 | Post-withdrawal deployed code: repeated accrual, partial closes, liquidation, insurance exhaustion, two borrowers, multi-depositor fees |
| `FujiPartialLiquidationScriptForkTest` | 5 | Proposed canary lifecycle, price restoration, no insurance consumption, confirmation/chain/replay guards |
| `AvalancheRealRouteForkTest` | 3 | Real Chainlink + LFJ adapter on Avalanche fork, and unsafe Fuji quote rejection |

The stress suite uses Fuji block 58511100 with no proxy upgrade or code substitution.
It advances 640,000 blocks and 640,000 seconds in 64 accrual steps for both sides,
checks debt growth, supply exchange-rate growth and declining health, then partially
and fully closes. Time/block advances are synthetic scenarios, not a prediction of
real block frequency or future APY.

Partial liquidation improves health for long and short without drawing insurance.
Crash/squeeze full liquidations consume insurance and finish with zero debt.
With empty insurance, liquidation **reverts and leaves the debt and collateral
recorded**. This is fail-closed accounting, not proof that insolvent positions can
always be resolved. Insurance sizing, replenishment and bad-debt recovery remain
production decisions.

Fee tests enable 10-bps opening/closing fees and a 50/30/20 depositor/insurance/treasury
split through the real config timelock **only on the fork**. They check collected
pToken amounts, conservation of the split, free-plus-locked eligibility, seven-day
streaming, direct pToken settlement/withdrawal and exclusion of past fees for late
depositors. Live Fuji fees remain zero. This does not approve those production rates.

## Real oracle and route evidence

At Fuji block 58511377, actual Chainlink AVAX/USD and USDC/USD feeds were fresh under
the existing 1200/90000-second bounds. The pinned LFJ V2.1 WAVAX/USDC pair
`0x0B16Fd47Cbf5350eBDe20aA813Db8E58846cd5D2` quoted 108726 raw USDC for 0.01 WAVAX,
versus 110966 from the oracle ratio: approximately 2.02% below oracle value. The
new test proves a swap using the 1% oracle floor reverts without losing input.
**Do not widen the bound or manually falsify a quote to make this route pass.**

The Avalanche mainnet fork is pinned at 95767958. It uses:

- Router `0x18556DA13313f3532c54711497A8FedAC273220E` and its on-chain V2.2 factory.
- WAVAX/native-USDC pair `0x864d4e5Ee7318e97483DB7EB0912E09F161516EA`, bin step 10, version 3.
- WAVAX `0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7`; USDC `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E`.
- AVAX/USD `0x0A77230d17318075983913bC2145DB16C7366156`; USDC/USD `0xF096872672F44d6EBA71458D74fe67F9a77a23B9`.

The AVAX feed is listed by [Avalanche's Chainlink integration documentation](https://build.avax.network/integrations/chainlink-data-feeds);
the USDC feed is also documented in [Aave's Avalanche risk repository](https://github.com/aave/risk-v3/blob/main/asset-risk/avalanche.md).
Feed descriptions, prices, timestamps, router wrapped-native token and pool token
identities were checked against the chains themselves, not inferred from labels.

The tests swap $100 and $500 USDC to WAVAX and back, enforcing the greater of the
99% pool quote and 99% oracle quote in each direction, then verify zero adapter
residue/approval and stale-feed rejection. Funding and adapter governance are
local-only test operations; real feed rounds are neither replaced nor refreshed.
To rehearse the adapter timelock while keeping real feed timestamps valid, the
local VM queues in a simulated earlier timestamp and restores the pinned time.
`vm.getBlockTimestamp()` avoids optimizer reuse of `block.timestamp` across warps.

These are **adapter/oracle integration tests**, not a full mainnet margin lifecycle,
not an audit of LFJ/Chainlink and not proof of liquidity at production position caps.
Mainnet market inventory, token-specific routes/feeds, liquidity stress and complete
margin integration remain release gates. Fuji's real route remains economically
unsuitable under the current bound in the tested direction.

## Proposed live partial-liquidation canary — NOT broadcast

`SmokeFujiMockPartialLiquidation.s.sol` rehearses 12 transactions:

1. Refresh mock AVAX/USD to unchanged $10/$1 (two calls).
2. Approve, deposit 1e12 raw existing wallet pMockUSD (approximately $200), clear approval (three calls).
3. Accrue both markets and open one $100-margin 5x-request long (three calls).
4. Set the **mock** AVAX price to $8.70 and partially liquidate; keeper reward goes to the user's deployer wallet (two calls).
5. Restore mock AVAX to $10 and fully close the remainder (two calls).

Unsigned current-Fuji rehearsal passed: simulated ID 7; liquidation health 8965 ->
12000 bps; no insurance consumed; account/aggregate debt zero after close; price
restored; allowance/locks zero; 801541775000 raw pMockUSD free in the vault
(about $160.308355-equivalent), plus the keeper reward in the wallet. The lower
vault balance is expected from deliberately realizing liquidation losses, not a
normal profitable round trip. Estimated gas 7940776, not an inclusion guarantee.
All 12 payloads were independently decoded, with proposed nonces 203–214.

The script requires chain 43113, exact initial history/configuration, no outstanding
market debt or owner margin balance, and both `CONFIRM_FUJI_MOCK_ONLY=true` and
`CONFIRM_FUJI_PARTIAL_LIQUIDATION=true`. Merely setting flags does not grant signing
approval. It is not authorized for replay or for a full insured liquidation.

Transactions are **not atomic**. Simulation assertions cannot undo already mined
transactions. If any step fails, inspect receipts/price/debt before proposing
recovery; never blindly restart or resume. In particular, a failure after the price
shock can leave the mock feed at $8.70. Do not withdraw until receipts and debt are
verified. No new live transactions were sent during this work.

Next live gate: external review/scan, then explicit approval of these 12 exact
transactions and their intentionally realized mock loss. A later full insured
short-liquidation canary needs its own funding/insurance budget and approval.

## Reproduction and remaining gates

Verification on this package: **31 fork tests passed, zero failed/skipped**, plus
**101 existing regression tests passed, zero failed/skipped** across core margin,
Fuji deployment/policy, debt accounting, fee fuzz/invariants and LFJ adapter suites.
Fuzz cases used 1,024 runs; each fee invariant used 256 runs / 128,000 handler calls
with zero handler reverts. Scoped Solidity formatting also passed. This is targeted
coverage, not a claim that every repository test or every live scenario was run.

From `contracts`, run the new fork suites (read-only public RPC access required):

```bash
FOUNDRY_PROFILE=debt_accounting FUJI_MOCK_FORK_RPC_URL=https://api.avax-test.network/ext/bc/C/rpc AVALANCHE_FUJI_RPC_URL=https://api.avax-test.network/ext/bc/C/rpc AVALANCHE_MAINNET_RPC_URL=https://api.avax.network/ext/bc/C/rpc forge test --match-contract '^(FujiMarginProductionStressForkTest|AvalancheRealRouteForkTest|FujiPartialLiquidationScriptForkTest|FujiMockFiveXSmokeForkTest)$' --threads 1 --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol
```

Missing RPC variables explicitly skip these new tests; skipped tests are not
evidence. Run script-invoking tests serially because confirmation environment
variables are process-global. The known LayerZero exclusions remain necessary in
this checkout. Existing metadata/NatSpec/compiler warnings are not new findings.

Almanax tools were unavailable in this session, so **no new external scan exists**.
Previous clean scans do not cover this package. The next scan should cover this
package's commit against parent `d568566753e4104bd8f8d6e9cd1f80439c01ffea`, after an
approved push. Ozone coverage is not claimed. Publication, external scans, live
partial/full liquidation and live nonzero-fee validation remain separate gates.

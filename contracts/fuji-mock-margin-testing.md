# Controlled Fuji mock-margin environment

This fixture is separate from the real-token Fuji lending base and LFJ adapter. It uses the actual Peridot lending and isolated-margin contracts, but its assets, price feeds and swap venue are explicitly artificial. It never reads an existing controller or underlying-token address as a deployment target.

`mockUSD` has six decimals. `mockAVAX` has eighteen decimals and **is not wrapped AVAX**: it cannot be redeemed for native AVAX. Neither token has backing or monetary value. Only its owner can mint, with a one-billion-token total-supply cap. Names and pToken symbols include `MOCK`/`mock`. Never send real assets to this setup or offer it as a public lending market.

The two owner-controlled feeds implement the Chainlink interface for compatibility but are **not Chainlink feeds**. Prices start at $1/mockUSD and $10/mockAVAX, represented with eight decimals. Rounds expire after 1,200 seconds. Only the owner can refresh/change a price; an inactive feed deliberately causes stale-price rejection.

The funded mock adapter exchanges only these two mock tokens at the feed-implied rate, adjusted by an owner-selected execution haircut. It is **not an AMM or an LFJ pool** and does not simulate bin depth, MEV, realistic price impact or external price discovery. Only the configured margin swap module can call it, and it can spend only that caller's allowance. It cannot mint its own output liquidity.

## Deployment scope

`script/DeployFujiMockMargin.s.sol` creates new tokens, feeds, swap adapter, flash lender, lending base, pToken markets and the full margin stack. All custom fixtures and both mock scripts reject any chain except Fuji (`43113`). The only external deployment inputs are `MOCK_MARGIN_DEPLOYER` and the explicit `CONFIRM_FUJI_MOCK_ONLY` flag.

The script sets inputs to the reused margin deployment script in memory, pointing exclusively to the newly created mock contracts. It does not edit the existing `.env`, broadcast to an existing controller, consume the deployer's real ERC-20 balances, or change the real-route configuration. Native AVAX is spent only on transaction gas. The ordinary test PERIDOT governance token is also fresh and does not participate in margin fee rewards.

Initial allocations, all in **mock underlying units**:

| Destination | mockAVAX | mockUSD |
| --- | ---: | ---: |
| Swap venue | 100,000 | 1,000,000 |
| Flash lender | 10,000 | 100,000 |
| Lending markets | 10,000 | 100,000 |
| Operator wallet | 1,000 | 10,000 |

The operator receives the lending seed pTokens; 1% of each market's initial pToken supply is transferred to mock insurance. Borrow caps are 50,000 mockAVAX and 500,000 mockUSD, not guaranteed available liquidity. Spot collateral factors remain zero. Rate-model assumptions match the existing Fuji defaults (31,536,000 blocks/year, 2% base, 10% multiplier, 100% jump multiplier, 80% kink, 10% reserves).

The fresh controller is connected to the fresh margin risk hook/registrar, and the fresh adapter recognizes the fresh margin swap module. **Borrowing, pToken flash loans, the mock adapter, flash lender and margin opens remain paused.** No pair risk is configured by deployment. Opening/closing fees initially remain zero; the fee split defaults to 50% depositors / 50% insurance, with depositor rewards streamed over seven days, not paid immediately.

Simulate without a keystore from `contracts/`:

```sh
MOCK_MARGIN_DEPLOYER=0x94696d767e65a75581145646960fa0ec886ce5d2 \
CONFIRM_FUJI_MOCK_ONLY=true \
forge script script/DeployFujiMockMargin.s.sol:DeployFujiMockMargin \
  --rpc-url https://api.avax-test.network/ext/bc/C/rpc \
  --sender 0x94696d767e65a75581145646960fa0ec886ce5d2 \
  --skip P_OFTAdapter.sol \
  --skip P_OFTAdapterUpgradeable.sol \
  --skip P_OFTAdapterUpgradeable.t.sol -vv
```

Only after reviewing the exact transactions and obtaining deployment approval, add `--account robinhood-deployer --broadcast`. Enter the password in the local terminal, never in chat or an environment file. This is a separate payload from the previously approved real-token margin deployment. Do not rerun after a partial broadcast; inspect actual receipts and state first. Simulation output addresses are not evidence of deployment.

## Configure and exercise

After verifying the broadcast, retain mock addresses separately using `fuji-mock-margin.env.example`. `ConfigureFujiMockMargin` consumes only the `MOCK_*` settings plus the explicit mock-only confirmation, validates mock-asset/controller/owner relationships and refreshes mock feed rounds without changing their selected prices.

Run `script/ConfigureFujiMockMargin.s.sol:ConfigureFujiMockMargin` with the same Fuji RPC/sender/skips as above, initially unsigned. Set the verified `MOCK_RISK_ENGINE`, `MOCK_PAVAX`, `MOCK_PUSD`, `MOCK_MARGIN_DEPLOYER` and `CONFIRM_FUJI_MOCK_ONLY=true` in that process. Do not source an unreviewed environment file. The configuration script provides two stages:

1. `MOCK_EXECUTE=false`: queue 2x long and short pairs, both collateralized by pMockUSD. Defaults are 50% initial margin, 35% maintenance margin, 1% swap/oracle bounds, $10,000 position cap and $5,000 debt cap. `MOCK_ENABLE_TRADING=false` leaves the unpause action unqueued.
2. After the real 24-hour timelock, `MOCK_EXECUTE=true`: execute the pair settings. With `MOCK_ENABLE_TRADING=false`, all trading gates remain paused. If a separately reviewed controlled lifecycle run is ready, setting `MOCK_ENABLE_TRADING=true` in **both stages** also queues/executes opening activation. Activation checks mock ownership, wiring, prices, finite caps, insurance, venue liquidity and flash liquidity. It enables mock borrowing/adapter/flash-lender/opens only; pToken flash loans stay paused. A later activation requires freshly queued matching actions, not a blind rerun of already-consumed ones.

Once authorized for controlled testing:

- Supply mock tokens to their matching pToken market, then approve/deposit those **pTokens** into the margin vault. Do not deposit the underlying directly into the margin vault.
- Open a small long (pMockUSD collateral, pMockAVAX position, pMockUSD debt) or short (pMockUSD collateral/position, pMockAVAX debt). Supply a nonzero, current minimum position output. `swapData` is empty for this adapter.
- Update a **verified mock feed** through its owner-only `setAnswer(int256)` to model a crash or short squeeze. Values use eight decimals. The mock venue follows the same feed immediately; this is intentional controlled testing, not independent pricing evidence.
- Owner-only `setExecutionBps(uint16)` on the mock adapter changes execution quality: 10000 is parity, 9800 models a 2% haircut. The margin 1% safeguards are unchanged and should reject the latter. Restore parity before normal runs. Pause the adapter or withdraw mock flash liquidity through its owner to test unavailable-liquidity behavior.
- Let feeds expire to test failure handling, then refresh both answers. Repay debt and test the oracle-independent in-kind pToken exit. Record raw debt balances, returned pTokens and fee-stream accounting, not only transaction success.

The operator controls prices and minting and can therefore force insolvency. This is acceptable only for deliberately valueless mock assets. Real-asset integration must retain independent price sources and realistic DEX/fork tests. Passing this fixture does not resolve the real Fuji LFJ/Chainlink mismatch or authorize mainnet deployment.

## Tests

```sh
forge test --threads 1 --match-path test/FujiMockMargin.t.sol --fuzz-runs 1024 \
  --skip P_OFTAdapter.sol \
  --skip P_OFTAdapterUpgradeable.sol \
  --skip P_OFTAdapterUpgradeable.t.sol -vv
```

The suite deploys the package itself and exercises decimal-correct 2x and 5x long/short round trips, zero spot collateral factors, borrow interest and supply exchange-rate growth, fee streaming (including bounded raw-unit rounding dust), partial and insured full liquidation, stale-price pToken exits, strict slippage, mock authorization, funding and timelocks. Run script-invoking suites serially (`--threads 1`): Foundry environment variables modified through `vm.setEnv` are process-global. Only the local tests configure 5x; the operator configuration script starts at 2x. Complete controlled Fuji lifecycle runs and real-route validation separately before discussing a production launch.

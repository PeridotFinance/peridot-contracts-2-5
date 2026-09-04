# Avalanche Fuji Lending and Isolated-Margin Deployment

This package creates a new Peridot lending base on Avalanche Fuji and connects it to the isolated-margin stack. Every deployment and activation script rejects Avalanche mainnet. No command below should be run with `--broadcast` until its simulation output has been reviewed.

## Safety state

The base deployment creates and atomically seeds pWAVAX and pUSDC. Both markets begin with:

- a zero spot collateral factor;
- borrowing paused;
- native pToken flash loans paused;
- a finite borrow cap;
- a non-zero initial supply;
- controller and pToken administration returned to `MARGIN_DEPLOYER`.

The later activation script enables controller borrowing only after the isolated-margin risk hook and registrar are wired and verified. Margin position opening remains independently paused.

## Inputs

Copy `avalanche-fuji-margin.env.example` to the ignored `.env`, then replace every value required by the current stage. Keep the keystore password out of both files.

For the initial Fuji rollout, `MARGIN_OWNER` must equal `MARGIN_DEPLOYER`. Set seed amounts in raw token units. Each borrow cap must be finite and greater than its market's seed amount.

The supplied Fuji addresses are:

- WAVAX: `0xd00ae08403B9bbb9124bB305C09058E32C39A48c`
- LFJ USDC: `0xB6076C93701D6a07266c31066B298AeC6dd65c2d`
- LFJ WAVAX/USDC pair: `0x0B16Fd47Cbf5350eBDe20aA813Db8E58846cd5D2`
- Chainlink AVAX/USD: `0x5498BB86BC934c8D34FDA08E81D444153d0D06aD`
- Chainlink USDC/USD: `0x97FE42a7E96640D932bbc0e1580c73E705A8EB73`
- LFJ router: `0x18556DA13313f3532c54711497A8FedAC273220E`

Load the public deployment values into the shell so it can expand the command arguments. Inspect `.env` before sourcing it and keep all secrets out of it:

```bash
set -a
source .env
set +a
```

All commands are run from the `contracts` directory.

Verify the local package and the complete live-Fuji fork path before any simulation:

```bash
forge test --match-path test/AvalancheFujiLendingDeployment.t.sol \
  --skip P_OFTAdapter.sol \
  --skip P_OFTAdapterUpgradeable.sol \
  --skip P_OFTAdapterUpgradeable.t.sol

AVALANCHE_FUJI_RPC_URL="$AVALANCHE_FUJI_RPC_URL" \
forge test --match-contract AvalancheFujiLendingDeploymentForkTest \
  --skip P_OFTAdapter.sol \
  --skip P_OFTAdapterUpgradeable.sol \
  --skip P_OFTAdapterUpgradeable.t.sol
```

## 0. Prepare the seed assets when the deployer holds only AVAX

`PrepareAvalancheFujiLendingSeed` wraps the configured AVAX amount and swaps part of the resulting WAVAX through the official LFJ V2.1 bin-step-20 pool. It applies `PREPARE_MAX_SLIPPAGE_BPS` to both the live LFJ pair quote and the Chainlink AVAX/USD-to-USDC/USD value, then enforces the higher minimum with a 60-second deadline. It also reserves the configured native AVAX balance for deployment gas.

Simulate and review the quoted minimum and final balances before adding `--broadcast`:

```bash
forge script script/PrepareAvalancheFujiLendingSeed.s.sol:PrepareAvalancheFujiLendingSeed \
  --rpc-url "$AVALANCHE_FUJI_RPC_URL" \
  --account "$FOUNDRY_ACCOUNT" \
  --sender "$MARGIN_DEPLOYER" \
  --skip P_OFTAdapter.sol \
  --skip P_OFTAdapterUpgradeable.sol \
  --skip P_OFTAdapterUpgradeable.t.sol \
  -vvvv
```

## 1. Deploy the lending base

Simulate first:

```bash
forge script script/DeployAvalancheFujiLendingMarkets.s.sol:DeployAvalancheFujiLendingMarkets \
  --rpc-url "$AVALANCHE_FUJI_RPC_URL" \
  --account "$FOUNDRY_ACCOUNT" \
  --sender "$MARGIN_DEPLOYER" \
  --skip P_OFTAdapter.sol \
  --skip P_OFTAdapterUpgradeable.sol \
  --skip P_OFTAdapterUpgradeable.t.sol \
  -vvvv
```

After reviewing the simulation, rerun the same command with `--broadcast`. Copy the logged Unitroller/Peridottroller, pWAVAX, and pUSDC addresses into `PERIDOTTROLLER`, `PWAVAX`, `PUSDC`, and `MARGIN_PTOKENS`.

## 2. Deploy supporting contracts

Deploy the LFJ adapter and the paused flash vault. Simulate each command before adding `--broadcast`.

```bash
forge script script/DeployLFJLBRouterAdapterAvalanche.s.sol:DeployLFJLBRouterAdapterAvalanche \
  --rpc-url "$AVALANCHE_FUJI_RPC_URL" \
  --account "$FOUNDRY_ACCOUNT" \
  --sender "$MARGIN_DEPLOYER" \
  --skip P_OFTAdapter.sol \
  --skip P_OFTAdapterUpgradeable.sol \
  --skip P_OFTAdapterUpgradeable.t.sol \
  -vvvv

forge script script/DeploySimpleFlashLoanVaultAvalanche.s.sol:DeploySimpleFlashLoanVaultAvalanche \
  --rpc-url "$AVALANCHE_FUJI_RPC_URL" \
  --account "$FOUNDRY_ACCOUNT" \
  --sender "$MARGIN_DEPLOYER" \
  --skip P_OFTAdapter.sol \
  --skip P_OFTAdapterUpgradeable.sol \
  --skip P_OFTAdapterUpgradeable.t.sol \
  -vvvv
```

Record their addresses in `LFJ_MARGIN_ADAPTER`, `MARGIN_ROUTER_ADAPTER`, and `MARGIN_FLASH_LENDER`. Fund the flash vault with `FundSimpleFlashLoanVaultAvalanche`; keep `UNPAUSE_FLASH_VAULT=false` until lifecycle testing needs live flash liquidity.

## 3. Deploy and wire isolated margin

Set `WIRE_CONTROLLER=true`, then simulate and review:

```bash
forge script script/DeployIsolatedMarginAvalanche.s.sol:DeployIsolatedMarginAvalanche \
  --rpc-url "$AVALANCHE_FUJI_RPC_URL" \
  --account "$FOUNDRY_ACCOUNT" \
  --sender "$MARGIN_DEPLOYER" \
  --skip P_OFTAdapter.sol \
  --skip P_OFTAdapterUpgradeable.sol \
  --skip P_OFTAdapterUpgradeable.t.sol \
  -vvvv
```

After the reviewed broadcast, record all logged addresses. In particular, set `ISOLATED_MARGIN_CONFIG`, `ISOLATED_MARGIN_RISK_ENGINE`, and `ISOLATED_MARGIN_SWAP_MODULE`.

## 4. Enable borrowing behind the margin gate

Leave margin opens paused. Set `ACTIVATE_FUJI_MARGIN_BORROWS=true`, simulate, verify the controller and market addresses, and only then broadcast:

```bash
forge script script/ActivateAvalancheFujiMarginMarkets.s.sol:ActivateAvalancheFujiMarginMarkets \
  --rpc-url "$AVALANCHE_FUJI_RPC_URL" \
  --account "$FOUNDRY_ACCOUNT" \
  --sender "$MARGIN_DEPLOYER" \
  --skip P_OFTAdapter.sol \
  --skip P_OFTAdapterUpgradeable.sol \
  --skip P_OFTAdapterUpgradeable.t.sol \
  -vvvv
```

The script refuses to continue unless both markets are listed, seeded, priced, capped, borrow-paused, flash-paused, and at zero spot collateral factor, and unless the controller's isolated-margin hook and registrar point to the paused risk engine.

## 5. Configure routes and pairs

Use `ConfigureLFJLBRouterAdapterAvalanche` once with `EXECUTE=false`, wait the configured action delay, and run it again with `EXECUTE=true`. Do the same for each isolated-margin pair with `ConfigureIsolatedMarginPairAvalanche`.

Do not set `UNPAUSE_OPENS=true` until the live Fuji route, complete open/close lifecycle, interest accrual, stale-oracle handling, partial close, and liquidation tests have passed and the insurance and flash-liquidity minimums are verified.

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IsolatedMarginTypes} from "../../contracts/margin/IsolatedMarginTypes.sol";

/// @notice Live Robinhood Chain (4663) addresses and the operator-pending defaults for SPY 2x margin.
/// Every default is overridable by environment variable in `DeploySpyMargin` and the rehearsal; nothing here is final
/// until the operator signs the command list. Addresses were read on chain at L2 115913834 (2026-11-16).
library SpyMarginParams {
    uint256 internal constant CHAIN_ID = 4663;

    // ---- the live system (read, never redeployed)
    address internal constant LEDGER = 0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD;
    address internal constant CONTROLLER = 0x6148183676E304dbe63a85C350c208DA3cEAc39C; // admin = Ledger
    address internal constant LIVE_LENDING_ADAPTER = 0xe4e03C2FdaeF915ACe705D106b2660B1E342A2E4; // controller oracle (2 markets)
    address internal constant LENDING_ORACLE = 0x266F014d1325774F1190f963Df4369E07dDA1d33; // StockSimplePriceOracle
    address internal constant MARGIN_ORACLE = 0x63150Eb3DDf71420dA0b09b66838aab398f7dEdD; // owner = Ledger
    address internal constant NVDA_GUARDED_SOURCE = 0x25E02b142E0785a59D85a6CA820c400e601a9E8E; // current assetSource
    address internal constant CONFIG = 0x09F94fe0B79E000c8a26617c63E3427fdECB528b; // owner = Ledger, delay 3600
    address internal constant ROUTER_ADAPTER = 0xa32C34F100B4F1f36ECA09c427a098f99F4423F0; // owner = Ledger
    address internal constant EXECUTOR = 0x6A45Ae86bD992d250580d08D340A06A04D478977;
    address internal constant RISK_ENGINE = 0xC8b178C3c74570472FF1eeE0DD559e61AF9f9678;
    address internal constant LIQUIDATOR = 0x1434CDa56d0Aeac4d5abC16F91ca76a8A989083c;
    address internal constant QUOTER = 0xeD3c353Ab237329BD53CC7eB24E66B370155FE6e;
    address internal constant MARGIN_VAULT = 0x04D4A5555b7a37017A67B4D21A1Da5838de28B9e;
    address internal constant FLASH_VAULT = 0x79d33c9BbC1D0711e88C5602f86135Ab4C088b06;
    address internal constant REGISTRY = 0xeb7DD1635b5c22672bE469ce112f78DE2Dc62f96; // order registry V2
    address internal constant CLOSE_ADAPTER = 0x99dD14EAE0C27C47e9F39f5961DBae8A1a2A4956;
    address internal constant PNVDA = 0xa155ccCB986774AE818b3F10F07d01D1b7A47b26;
    address internal constant PUSDG = 0x55aEd0569c8f0D166D71facE57B57C2f2624a563;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address internal constant SPY_FEED = 0x319724394D3A0e3669269846abE664Cd621f9f6A; // RHSPY / USD, 8 dp, 24/5
    address internal constant IRM = 0x0987154fB5676a8Ea545AAf41F8ef2492F785d22; // pNVDA/pUSDG model
    uint24 internal constant SPY_POOL_FEE = 3000; // Uniswap v4 SPY/USDG, hooks 0
    int24 internal constant SPY_POOL_TICK_SPACING = 60;

    // ---- pSPY market (proposed)
    uint256 internal constant PSPY_INITIAL_EXCHANGE_RATE = 2e26; // as pNVDA (18-dp underlying, 8-dp pToken)
    uint8 internal constant PSPY_DECIMALS = 8;
    address internal constant SEED_SINK = 0x000000000000000000000000000000000000dEaD;

    // ---- operator-pending defaults (parameters, not constants of the contracts)
    uint256 internal constant DEFAULT_MAX_STALENESS = 90000; // 25 h
    uint256 internal constant DEFAULT_CLOSED_FROM = 5 days; // Saturday 00:00 UTC (seconds since Monday 00:00 UTC)
    uint256 internal constant DEFAULT_CLOSED_UNTIL = 1 hours; // Monday 01:00 UTC
    uint128 internal constant DEFAULT_MAX_POSITION_USD = 250e18;
    uint128 internal constant DEFAULT_MAX_DEBT_USD = 125e18;

    function longRisk(uint128 maxPositionUsd, uint128 maxDebtUsd)
        internal
        pure
        returns (IsolatedMarginTypes.PairRiskConfig memory r)
    {
        r = IsolatedMarginTypes.PairRiskConfig({
            enabled: true,
            maxLeverageX100: 200,
            initialMarginBps: 5000,
            maintenanceMarginBps: 2500,
            liquidationTargetBps: 12500,
            fullLiquidationHealthBps: 5000,
            maxLiquidationBps: 5000,
            liquidationBonusBps: 500,
            maxSlippageBps: 100,
            oracleDeviationBps: 100,
            maxPositionValueUsd: maxPositionUsd,
            maxDebtValueUsd: maxDebtUsd
        });
    }
}

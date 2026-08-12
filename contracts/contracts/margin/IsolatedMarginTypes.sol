// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library IsolatedMarginTypes {
    enum Side {
        LONG,
        SHORT
    }

    enum Status {
        NONE,
        OPENING,
        ACTIVE,
        CLOSING,
        LIQUIDATING,
        CLOSED,
        LIQUIDATED
    }

    struct PairRiskConfig {
        bool enabled;
        uint16 maxLeverageX100;
        uint16 initialMarginBps;
        uint16 maintenanceMarginBps;
        uint16 liquidationTargetBps;
        uint16 fullLiquidationHealthBps;
        uint16 maxLiquidationBps;
        uint16 liquidationBonusBps;
        uint16 maxSlippageBps;
        uint16 oracleDeviationBps;
        uint128 maxPositionValueUsd;
        uint128 maxDebtValueUsd;
    }

    struct Position {
        uint256 id;
        address owner;
        address account;
        address marginPToken;
        address positionPToken;
        address debtPToken;
        uint256 lockedMarginPTokens;
        uint256 initialNotionalUsd;
        uint256 borrowedPrincipal;
        uint16 requestedLeverageX100;
        Side side;
        Status status;
    }

    struct AccountMetrics {
        uint256 grossAssetValueUsd;
        uint256 debtValueUsd;
        int256 equityUsd;
        uint256 initialRequirementUsd;
        uint256 maintenanceRequirementUsd;
        uint256 healthFactorBps;
        uint256 leverageX100;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {IsolatedMarginConfigUpgradeable} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginTypes} from "../contracts/margin/IsolatedMarginTypes.sol";

/**
 * @notice Queues or executes one Avalanche isolated-margin pair configuration.
 * @dev Run once with EXECUTE=false, wait config.actionDelay(), then rerun with EXECUTE=true.
 *      Set UNPAUSE_OPENS=true only after controller and adapter wiring have been verified.
 */
contract ConfigureIsolatedMarginPairAvalanche is Script {
    function run() external returns (bytes32 actionId) {
        require(block.chainid == 43_114 || block.chainid == 43_113, "ConfigureMargin: Avalanche only");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        IsolatedMarginConfigUpgradeable config =
            IsolatedMarginConfigUpgradeable(vm.envAddress("ISOLATED_MARGIN_CONFIG"));
        address marginPToken = vm.envAddress("MARGIN_PTOKEN");
        address positionPToken = vm.envAddress("POSITION_PTOKEN");
        address debtPToken = vm.envAddress("DEBT_PTOKEN");

        IsolatedMarginTypes.PairRiskConfig memory risk = IsolatedMarginTypes.PairRiskConfig({
            enabled: true,
            maxLeverageX100: uint16(vm.envOr("MAX_LEVERAGE_X100", uint256(500))),
            initialMarginBps: uint16(vm.envOr("INITIAL_MARGIN_BPS", uint256(2_000))),
            maintenanceMarginBps: uint16(vm.envOr("MAINTENANCE_MARGIN_BPS", uint256(1_000))),
            liquidationTargetBps: uint16(vm.envOr("LIQUIDATION_TARGET_BPS", uint256(12_500))),
            fullLiquidationHealthBps: uint16(vm.envOr("FULL_LIQUIDATION_HEALTH_BPS", uint256(5_000))),
            maxLiquidationBps: uint16(vm.envOr("MAX_LIQUIDATION_BPS", uint256(5_000))),
            liquidationBonusBps: uint16(vm.envOr("LIQUIDATION_BONUS_BPS", uint256(500))),
            maxSlippageBps: uint16(vm.envOr("MAX_SLIPPAGE_BPS", uint256(100))),
            oracleDeviationBps: uint16(vm.envOr("ORACLE_DEVIATION_BPS", uint256(100))),
            maxPositionValueUsd: uint128(vm.envOr("MAX_POSITION_VALUE_USD", uint256(0))),
            maxDebtValueUsd: uint128(vm.envOr("MAX_DEBT_VALUE_USD", uint256(0)))
        });

        vm.startBroadcast(deployerKey);
        bool unpauseOpens = vm.envOr("UNPAUSE_OPENS", false);
        if (vm.envOr("EXECUTE", false)) {
            config.setPairRisk(marginPToken, positionPToken, debtPToken, risk);
            if (unpauseOpens) config.unpauseOpens();
            actionId = keccak256(abi.encode("pairRisk", config.pairKey(marginPToken, positionPToken, debtPToken), risk));
            console2.log("Executed pair risk action");
        } else {
            actionId = config.queuePairRisk(marginPToken, positionPToken, debtPToken, risk);
            if (unpauseOpens) {
                bytes32 unpauseActionId = config.queueUnpauseOpens();
                console2.log("Queued unpause action");
                console2.logBytes32(unpauseActionId);
            }
            console2.log("Queued pair risk action");
            console2.log("Execute after", config.queuedActions(actionId));
        }
        vm.stopBroadcast();
        console2.logBytes32(actionId);
    }
}

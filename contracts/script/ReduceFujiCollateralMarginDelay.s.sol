// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ConfigureFujiCollateralMargin as Configure} from "./ConfigureFujiCollateralMargin.s.sol";
import {CollateralPreservingExecutor as Executor} from "../contracts/margin/CollateralPreservingExecutor.sol";
import {IsolatedMarginConfigUpgradeable as Config} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";

/// @notice Fuji mock-only transition from the existing 24h delay to 1h; no upgrades or activation.
/// @dev run() queues ONE action at the old delay. execute() consumes it only after its stored ETA.
/// Execute before activating the paused stack. Existing queues are neither canceled nor re-timed.
contract ReduceFujiCollateralMarginDelay is Script {
    function run() external {
        _change(false);
    }

    function execute() external {
        _change(true);
    }

    function actionId() public pure returns (bytes32) {
        return keccak256(abi.encode("actionDelay", uint256(1 hours)));
    }

    function _change(bool execute_) private {
        require(block.chainid == 43_113, "CollateralFuji: Fuji only");
        require(vm.envOr("CONFIRM_FUJI_COLLATERAL_MOCK_ONLY", false), "CollateralFuji: confirmation required");
        address owner = vm.envAddress("CP_FUJI_DEPLOYER");
        address executor = vm.envAddress("CP_FUJI_EXECUTOR");
        Configure verifier = new Configure();
        verifier.verifyDelayTransition(executor, owner);
        Config c = Config(address(Executor(executor).config()));
        require(c.actionDelay() == 1 days, "CollateralFuji: expected legacy delay");
        uint256 eta = c.queuedActions(actionId());
        require(execute_ ? eta != 0 && block.timestamp >= eta : eta == 0, "CollateralFuji: queue state/time");
        bytes32 unpauseId = keccak256("unpauseOpens");
        uint256 unpauseEta = c.queuedActions(unpauseId);
        vm.startBroadcast(owner);
        if (execute_) c.setActionDelay(1 hours);
        else c.queueActionDelay(1 hours);
        vm.stopBroadcast();
        require(c.actionDelay() == (execute_ ? 1 hours : 1 days), "CollateralFuji: delay postcondition");
        require(
            c.queuedActions(actionId()) == (execute_ ? 0 : block.timestamp + 1 days),
            "CollateralFuji: queue postcondition"
        );
        require(c.queuedActions(unpauseId) == unpauseEta, "CollateralFuji: unpause deadline changed");
        verifier.verifyDelayTransition(executor, owner);
        console2.log("FUJI MOCK ONLY: one-hour delay applied", execute_);
        console2.log("Existing queue deadlines unchanged. All trading and borrowing gates remain paused.");
    }
}

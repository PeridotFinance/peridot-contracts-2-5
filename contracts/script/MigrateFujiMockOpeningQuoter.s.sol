// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {
    IsolatedMarginExecutorFujiQuoterMigration
} from "../contracts/margin/IsolatedMarginExecutorFujiQuoterMigration.sol";
import {IsolatedMarginExecutorUpgradeable} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginQuoter} from "../contracts/margin/IsolatedMarginQuoter.sol";

/// @notice MOCK FUJI ONLY: pause, deploy quoter, deploy implementation, atomic upgrade+migration.
/// @dev Four transactions, NOT an atomic batch. Never blindly rerun after partial execution.
///      Leaves opens paused. No feed updates, risk changes, unpause queues, transfers or approvals.
contract MigrateFujiMockOpeningQuoter is Script {
    address constant OWNER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    address constant OLD_IMPLEMENTATION = 0xdD9F436C6F11cC1cA7E4c5A738256444b660a5bc;
    address constant OLD_QUOTER = 0x6c68ef73728337e5D8212a11CFeDDdF1B4Ff23eD;
    address constant ADMIN = 0x23359eB6f9437caDfbF766C11EeC2D0090a67155;
    IsolatedMarginExecutorUpgradeable constant EX =
        IsolatedMarginExecutorUpgradeable(0xa155ccCB986774AE818b3F10F07d01D1b7A47b26);
    bytes32 constant IMPL_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    bytes32 constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);

    function run()
        external
        returns (IsolatedMarginQuoter replacement, IsolatedMarginExecutorFujiQuoterMigration implementation)
    {
        require(block.chainid == 43_113, "Migrate: Fuji only");
        require(vm.envOr("CONFIRM_FUJI_MOCK_ONLY", false), "Migrate: mock confirmation required");
        require(vm.envOr("CONFIRM_FUJI_QUOTER_MIGRATION", false), "Migrate: migration confirmation required");
        require(_slotAddress(IMPL_SLOT) == OLD_IMPLEMENTATION, "Migrate: implementation changed");
        require(_slotAddress(ADMIN_SLOT) == ADMIN && ProxyAdmin(ADMIN).owner() == OWNER, "Migrate: admin changed");
        require(address(EX.quoter()) == OLD_QUOTER, "Migrate: quoter changed");
        require(address(EX.config()) == 0x6148183676E304dbe63a85C350c208DA3cEAc39C, "Migrate: config changed");
        require(
            address(EX.riskEngine().oracle()) == 0x8099F959f9E78972b8534a696F7360cD01E00E28, "Migrate: oracle changed"
        );
        require(EX.config().owner() == OWNER, "Migrate: config owner changed");
        require(EX.config().queuedActions(keccak256("unpauseOpens")) == 0, "Migrate: pending unpause");
        require(EX.config().actionDelay() == 1 days, "Migrate: delay changed");
        require(address(EX.swapModule().quoter()) == OLD_QUOTER, "Migrate: swap quoter changed");
        uint256 nextId = EX.nextPositionId();

        vm.startBroadcast(OWNER);
        EX.config().pauseOpens();
        replacement = new IsolatedMarginQuoter(address(EX.config()), address(EX.riskEngine().oracle()));
        implementation = new IsolatedMarginExecutorFujiQuoterMigration(address(replacement));
        ProxyAdmin(ADMIN)
            .upgradeAndCall(
                ITransparentUpgradeableProxy(address(EX)),
                address(implementation),
                abi.encodeCall(IsolatedMarginExecutorFujiQuoterMigration.migrateOpeningQuoter, ())
            );
        vm.stopBroadcast();

        require(_slotAddress(IMPL_SLOT) == address(implementation), "Migrate: implementation mismatch");
        require(address(EX.quoter()) == address(replacement), "Migrate: quoter mismatch");
        require(IsolatedMarginExecutorFujiQuoterMigration(address(EX)).initializedVersion() == 2, "Migrate: version");
        require(EX.config().opensPaused() && EX.nextPositionId() == nextId, "Migrate: state mismatch");
        require(address(EX.swapModule().quoter()) == OLD_QUOTER, "Migrate: retained dependency changed");
        console2.log("MOCK ONLY new opening quoter", address(replacement));
        console2.log("MOCK ONLY executor migration implementation", address(implementation));
        console2.log(
            "Existing executor/vault/accounts retained. Opens remain paused; verify receipts before queueing reopen."
        );
    }

    function _slotAddress(bytes32 slot) private view returns (address) {
        return address(uint160(uint256(vm.load(address(EX), slot))));
    }
}

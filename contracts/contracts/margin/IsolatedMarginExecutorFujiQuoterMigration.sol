// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IsolatedMarginExecutorUpgradeable} from "./IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginQuoter} from "./IsolatedMarginQuoter.sol";

/// @notice One-use opening-quoter migration for the existing MOCK Fuji executor only.
/// @dev Install with ProxyAdmin.upgradeAndCall and nonempty migrateOpeningQuoter calldata.
///      Does not move custody, change risk, unpause opens, or add ordinary storage fields.
///      The old quoter remains in the swap module/liquidator for their unchanged helpers.
contract IsolatedMarginExecutorFujiQuoterMigration is IsolatedMarginExecutorUpgradeable {
    address public constant EXPECTED_PROXY = 0xa155ccCB986774AE818b3F10F07d01D1b7A47b26;
    address public constant EXPECTED_ADMIN = 0x23359eB6f9437caDfbF766C11EeC2D0090a67155;
    address public constant EXPECTED_CONFIG = 0x6148183676E304dbe63a85C350c208DA3cEAc39C;
    address public constant EXPECTED_ORACLE = 0x8099F959f9E78972b8534a696F7360cD01E00E28;
    address public constant OLD_QUOTER = 0x6c68ef73728337e5D8212a11CFeDDdF1B4Ff23eD;

    address public immutable replacementQuoter;
    bytes32 public immutable replacementCodeHash;

    error MigrationError(uint8 code);
    event OpeningQuoterMigrated(address indexed oldQuoter, address indexed newQuoter);

    /// @dev Matching getters alone do not authenticate arbitrary bytecode. Deploy the replacement
    ///      from the reviewed IsolatedMarginQuoter artifact; verify its runtime before signing.
    constructor(address replacement_) {
        if (block.chainid != 43_113) revert MigrationError(1);
        if (replacement_ == OLD_QUOTER || replacement_.code.length == 0) revert MigrationError(2);
        _checkBindings(replacement_);
        replacementQuoter = replacement_;
        replacementCodeHash = replacement_.codehash;
    }

    function migrateOpeningQuoter() external reinitializer(2) nonReentrant {
        if (block.chainid != 43_113) revert MigrationError(1);
        if (address(this) != EXPECTED_PROXY) revert MigrationError(3);
        if (msg.sender != EXPECTED_ADMIN || ERC1967Utils.getAdmin() != EXPECTED_ADMIN) revert MigrationError(4);
        if (address(config) != EXPECTED_CONFIG || address(riskEngine.oracle()) != EXPECTED_ORACLE) {
            revert MigrationError(5);
        }
        if (!config.opensPaused()) revert MigrationError(6);
        if (address(quoter) != OLD_QUOTER) revert MigrationError(7);
        if (replacementQuoter.codehash != replacementCodeHash) revert MigrationError(8);
        _checkBindings(replacementQuoter);
        quoter = IsolatedMarginQuoter(replacementQuoter);
        emit OpeningQuoterMigrated(OLD_QUOTER, replacementQuoter);
    }

    function initializedVersion() external view returns (uint64) {
        return _getInitializedVersion();
    }

    function _checkBindings(address candidate) private view {
        if (
            address(IsolatedMarginQuoter(candidate).config()) != EXPECTED_CONFIG
                || address(IsolatedMarginQuoter(candidate).oracle()) != EXPECTED_ORACLE
        ) revert MigrationError(5);
    }
}

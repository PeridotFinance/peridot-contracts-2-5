// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployRamRewardsDistributor} from "../script/DeployRamRewardsDistributor.s.sol";
import {RewardMock} from "./RewardsBase.sol";

contract VaultViewMock {
    mapping(address => bool) public config;

    function setConfig(address a, bool b) external {
        config[a] = b;
    }

    function externalRewards(bytes32, address) external pure returns (uint256) {
        return 96799596213810175;
    }

    function hasRole(bytes32, address a) external view returns (bool) {
        return config[a];
    }
}

/// @notice The deploy script's refusals (offline: the RAM token and the vault are etched mocks at the real addresses).
contract DeployScriptTest is Test {
    address internal constant LEDGER = 0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD;
    address internal constant OLD_SIGNER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    address internal constant TIMELOCK = 0x6797FB8Ce049B42C5BC2b42Bf76c6d15C7B12498;
    address internal constant VAULT = 0x67e7742922f4CC88C545e5aB5Df402b22DB4830b;
    address internal constant RAM = 0x5173D45A1191eE33cBB7D8c7e65f21B04eD54802;
    DeployRamRewardsDistributor internal s;
    address internal throwaway = makeAddr("throwaway");

    function setUp() public {
        vm.chainId(4663);
        vm.etch(RAM, address(new RewardMock()).code);
        vm.etch(VAULT, address(new VaultViewMock()).code);
        VaultViewMock(VAULT).setConfig(TIMELOCK, true);
        s = new DeployRamRewardsDistributor();
    }

    function test_preflightPassesForAThrowawayDeployer() public view {
        s.preflight(throwaway);
    }

    function test_refusesTheOldSignerTheLedgerAndContractsAsDeployer() public {
        vm.expectRevert(bytes("OLD_SIGNER_REFUSED"));
        s.preflight(OLD_SIGNER);
        vm.expectRevert(bytes("LEDGER_IS_NOT_THE_DEPLOYER"));
        s.preflight(LEDGER);
        vm.expectRevert(bytes("DEPLOYER_HAS_CODE"));
        s.preflight(VAULT);
        vm.expectRevert(bytes("NO_DEPLOYER"));
        s.preflight(address(0));
    }

    function test_refusesAnotherChainAndAWrongVaultConfig() public {
        vm.chainId(43114);
        vm.expectRevert(bytes("WRONG_CHAIN"));
        s.preflight(throwaway);
        vm.chainId(4663);
        VaultViewMock(VAULT).setConfig(OLD_SIGNER, true);
        vm.expectRevert(bytes("OLD_SIGNER_HAS_CONFIG"));
        s.preflight(throwaway);
        VaultViewMock(VAULT).setConfig(OLD_SIGNER, false);
        VaultViewMock(VAULT).setConfig(TIMELOCK, false);
        vm.expectRevert(bytes("TIMELOCK_NOT_CONFIG"));
        s.preflight(throwaway);
    }

    function test_runDeploysWithTheLedgerAsOwnerAndWritesAJournal() public {
        vm.setEnv("RAM_DEPLOYER", vm.toString(throwaway));
        vm.setEnv("RAM_DISTRIBUTOR_JOURNAL", "deployments/unit-test.dryrun.json");
        vm.deal(throwaway, 1 ether);
        address d = address(s.run());
        string memory j = vm.readFile("deployments/unit-test.dryrun.json");
        assertEq(vm.parseJsonAddress(j, ".distributor"), d);
        assertEq(vm.parseJsonAddress(j, ".owner"), LEDGER);
        assertEq(vm.parseJsonAddress(j, ".deployer"), throwaway);
        s.verify("deployments/unit-test.dryrun.json");
    }
}

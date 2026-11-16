// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MerkleRewardsDistributor} from "../src/MerkleRewardsDistributor.sol";

interface IRamsesVaultView {
    function externalRewards(bytes32 pairId, address token) external view returns (uint256);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @notice Robinhood Chain (4663) deployment of the RAM distributor of the Ramses SPY/USDG vault. ONE creation from a
///         throwaway deployer (gas only); owner = the Ledger. No key is ever read: run with --sender <deployer> and a
///         keystore/hardware signer of the THROWAWAY account. Writes a journal (public values only).
///
///   pre-flight : RAM_DEPLOYER=<throwaway> forge script script/DeployRamRewardsDistributor.s.sol:DeployRamRewardsDistributor \
///                  --rpc-url <endpoint> --sender <throwaway>                (simulation)
///   deploy     : ... --broadcast --slow  (+ the throwaway's --account)
///   verify     : forge script ... --sig 'verify(string)' deployments/ram-distributor-mainnet.json --rpc-url <endpoint>
contract DeployRamRewardsDistributor is Script {
    uint256 internal constant CHAIN_ID = 4663;
    address internal constant LEDGER = 0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD;
    address internal constant OLD_SIGNER = 0x94696d767e65a75581145646960FA0eC886cE5d2; // compromised 2026-11-05
    address internal constant TIMELOCK = 0x6797FB8Ce049B42C5BC2b42Bf76c6d15C7B12498;
    address internal constant VAULT = 0x67e7742922f4CC88C545e5aB5Df402b22DB4830b;
    bytes32 internal constant PAIR = 0x8f81f5d84aa85b29b5114b8ca1a75266c4dc18785b703e8257ca66ecb4ba5435;
    address internal constant RAM = 0x5173D45A1191eE33cBB7D8c7e65f21B04eD54802;
    uint256 internal constant CLAIM_DELAY = 1 days;
    uint256 internal constant CLAIM_DEADLINE = 180 days;
    bytes32 internal constant CONFIG_ROLE = keccak256("CONFIG_ROLE");

    function run() external returns (MerkleRewardsDistributor d) {
        address deployer = vm.envAddress("RAM_DEPLOYER");
        string memory journal = vm.envOr("RAM_DISTRIBUTOR_JOURNAL", string("deployments/ram-distributor-mainnet.json"));
        preflight(deployer);

        vm.startBroadcast(deployer);
        d = new MerkleRewardsDistributor(IERC20(RAM), LEDGER, CLAIM_DELAY, CLAIM_DEADLINE);
        vm.stopBroadcast();

        _check(d);
        string memory k = "journal";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "distributor", address(d));
        vm.serializeAddress(k, "deployer", deployer);
        vm.serializeAddress(k, "owner", LEDGER);
        vm.serializeAddress(k, "rewardToken", RAM);
        vm.serializeAddress(k, "vault", VAULT);
        vm.serializeBytes32(k, "pair", PAIR);
        vm.serializeAddress(k, "timelock", TIMELOCK);
        vm.serializeUint(k, "claimDelay", CLAIM_DELAY);
        vm.serializeUint(k, "claimDeadline", CLAIM_DEADLINE);
        vm.serializeUint(k, "externalRewardsAtDeploy", IRamsesVaultView(VAULT).externalRewards(PAIR, RAM));
        string memory out = vm.serializeBytes32(k, "runtimeCodehash", address(d).codehash);
        vm.writeJson(out, journal);
        console2.log("DISTRIBUTOR", address(d));
        console2.log("journal", journal);
    }

    /// @notice Every refusal before anything is sent.
    function preflight(address deployer) public view {
        require(block.chainid == CHAIN_ID, "WRONG_CHAIN");
        require(deployer != address(0), "NO_DEPLOYER");
        require(deployer != OLD_SIGNER, "OLD_SIGNER_REFUSED");
        require(deployer != LEDGER, "LEDGER_IS_NOT_THE_DEPLOYER");
        require(deployer.code.length == 0, "DEPLOYER_HAS_CODE");
        require(LEDGER.code.length == 0, "LEDGER_HAS_CODE");
        require(RAM.code.length != 0 && IDecimals(RAM).decimals() == 18, "RAM_TOKEN");
        require(VAULT.code.length != 0, "VAULT_CODE");
        require(IRamsesVaultView(VAULT).hasRole(CONFIG_ROLE, TIMELOCK), "TIMELOCK_NOT_CONFIG");
        require(!IRamsesVaultView(VAULT).hasRole(CONFIG_ROLE, OLD_SIGNER), "OLD_SIGNER_HAS_CONFIG");
        IRamsesVaultView(VAULT).externalRewards(PAIR, RAM); // the pair exists and the getter answers
    }

    function _check(MerkleRewardsDistributor d) internal view {
        require(address(d).code.length != 0, "NO_CODE");
        require(d.owner() == LEDGER, "OWNER");
        require(d.owner() != OLD_SIGNER && d.pendingOwner() != OLD_SIGNER, "OLD_SIGNER");
        require(d.pendingOwner() == address(0), "PENDING_OWNER");
        require(address(d.REWARD_TOKEN()) == RAM, "TOKEN");
        require(d.CLAIM_DELAY() == CLAIM_DELAY && d.CLAIM_DEADLINE() == CLAIM_DEADLINE, "WINDOWS");
        require(d.epochCount() == 0 && d.reserved() == 0, "NOT_FRESH");
    }

    /// @notice Read-back of a deployment journal (no transaction). Valid also after epochs were published.
    function verify(string calldata journal) external view {
        string memory j = vm.readFile(journal);
        MerkleRewardsDistributor d = MerkleRewardsDistributor(vm.parseJsonAddress(j, ".distributor"));
        require(block.chainid == CHAIN_ID, "WRONG_CHAIN");
        require(address(d).codehash == vm.parseJsonBytes32(j, ".runtimeCodehash"), "CODEHASH");
        require(d.owner() == LEDGER, "OWNER");
        require(d.pendingOwner() != OLD_SIGNER, "OLD_SIGNER");
        require(address(d.REWARD_TOKEN()) == RAM, "TOKEN");
        require(d.CLAIM_DELAY() == CLAIM_DELAY && d.CLAIM_DEADLINE() == CLAIM_DEADLINE, "WINDOWS");
        require(IERC20(RAM).balanceOf(address(d)) >= d.reserved(), "UNDERFUNDED");
        console2.log("verified", address(d));
        console2.log("  epochCount", d.epochCount());
        console2.log("  reserved", d.reserved());
        console2.log("  unallocated", d.unallocated());
    }
}

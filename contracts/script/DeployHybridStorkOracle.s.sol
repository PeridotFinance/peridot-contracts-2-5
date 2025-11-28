// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../contracts/HybridStorkPriceOracle.sol";

/**
 * @title DeployHybridStorkOracle
 * @notice Deploys the HybridStorkPriceOracle and optionally assigns an additional admin.
 *
 * Environment variables:
 *  - STORK_CONTRACT_ADDRESS (required): address of the on-chain Stork oracle
 *  - CHAINLINK_STALE_THRESHOLD (optional): uint, defaults to 3600 seconds
 *  - STORK_STALE_THRESHOLD (optional): uint, defaults to 3600 seconds
 *  - HYBRID_ORACLE_ADMIN (optional): address given admin role post-deploy
 */
contract DeployHybridStorkOracle is Script {
    function run() external {
        uint256 chainlinkStale = uint256(36000);
        uint256 storkStale = uint256(3600);
        address storkContractAddress = 0xacC0a0cF13571d30B4b8637996F5D6D774d4fd62;
        address extraAdmin = address(0);

        vm.startBroadcast();

        HybridStorkPriceOracle oracle = new HybridStorkPriceOracle(
            chainlinkStale,
            storkContractAddress,
            storkStale
        );
        console2.log("HybridStorkPriceOracle deployed to:", address(oracle));

        if (extraAdmin != address(0)) {
            oracle.setAdmin(extraAdmin, true);
            console2.log("Granted admin to:", extraAdmin);
        }

        vm.stopBroadcast();
    }
}

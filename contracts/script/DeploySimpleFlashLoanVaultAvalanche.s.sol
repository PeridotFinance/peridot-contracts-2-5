// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {SimpleFlashLoanVault} from "../contracts/margin/SimpleFlashLoanVault.sol";

/**
 * @notice Deploys a paused ERC-3156 liquidity vault for isolated margin on Avalanche Fuji.
 * @dev Configure every debt underlying during deployment. Fund and unpause it separately with
 *      FundSimpleFlashLoanVaultAvalanche after verifying the balances.
 *      Use MARGIN_DEPLOYER with Forge's --account and --sender options; never export a raw private key.
 */
contract DeploySimpleFlashLoanVaultAvalanche is Script {
    uint256 private constant AVALANCHE_FUJI_CHAIN_ID = 43_113;

    function run() external returns (SimpleFlashLoanVault vault) {
        require(block.chainid == AVALANCHE_FUJI_CHAIN_ID, "DeployFlashVault: Fuji only");
        address deployer = vm.envAddress("MARGIN_DEPLOYER");
        address finalOwner = vm.envAddress("MARGIN_OWNER");
        uint256 feeBps = vm.envOr("FLASH_VAULT_FEE_BPS", uint256(0));
        uint256 tokenCount = vm.envUint("FLASH_VAULT_TOKEN_COUNT");

        require(deployer != address(0), "DeployFlashVault: zero deployer");
        require(finalOwner != address(0), "DeployFlashVault: zero owner");
        require(feeBps <= 100, "DeployFlashVault: fee too high");
        require(tokenCount > 0, "DeployFlashVault: no tokens");

        address[] memory tokens = new address[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            tokens[i] = vm.envAddress(string.concat("FLASH_VAULT_TOKEN_", vm.toString(i)));
            require(tokens[i].code.length > 0, "DeployFlashVault: token not contract");
            for (uint256 j = 0; j < i; j++) {
                require(tokens[j] != tokens[i], "DeployFlashVault: duplicate token");
            }
        }

        vm.startBroadcast(deployer);
        vault = new SimpleFlashLoanVault(deployer);
        vault.setFeeBps(feeBps);
        vault.setPaused(true);
        for (uint256 i = 0; i < tokenCount; i++) {
            vault.setTokenAllowed(tokens[i], true);
        }
        if (finalOwner != deployer) vault.transferOwnership(finalOwner);
        vm.stopBroadcast();

        console2.log("Avalanche Fuji flash vault", address(vault));
        console2.log("Flash vault owner", finalOwner);
        console2.log("Flash vault fee bps", feeBps);
        console2.log("Flash vault remains paused until separately funded and verified");
    }
}

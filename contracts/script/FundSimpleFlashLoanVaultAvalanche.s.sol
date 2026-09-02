// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SimpleFlashLoanVault} from "../contracts/margin/SimpleFlashLoanVault.sol";

/**
 * @notice Funds and optionally unpauses the Avalanche Fuji isolated-margin flash vault.
 * @dev Each minimum is checked against the vault's final balance, not merely this transaction's deposit.
 *      Unpausing requires the broadcaster to own the vault. Funding can be performed by any account.
 *      Use MARGIN_DEPLOYER with Forge's --account and --sender options; never export a raw private key.
 */
contract FundSimpleFlashLoanVaultAvalanche is Script {
    using SafeERC20 for IERC20;

    uint256 private constant AVALANCHE_FUJI_CHAIN_ID = 43_113;

    function run() external {
        require(block.chainid == AVALANCHE_FUJI_CHAIN_ID, "FundFlashVault: Fuji only");
        address deployer = vm.envAddress("MARGIN_DEPLOYER");
        SimpleFlashLoanVault vault = SimpleFlashLoanVault(vm.envAddress("MARGIN_FLASH_LENDER"));
        uint256 tokenCount = vm.envUint("FLASH_VAULT_TOKEN_COUNT");
        bool unpause = vm.envOr("UNPAUSE_FLASH_VAULT", false);

        require(deployer != address(0), "FundFlashVault: zero deployer");
        require(address(vault).code.length > 0, "FundFlashVault: vault not contract");
        require(tokenCount > 0, "FundFlashVault: no tokens");
        if (unpause) {
            require(vault.owner() == deployer, "FundFlashVault: broadcaster not owner");
            require(vault.paused(), "FundFlashVault: already active");
        }

        address[] memory tokens = new address[](tokenCount);
        uint256[] memory amounts = new uint256[](tokenCount);
        uint256[] memory minimums = new uint256[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            string memory suffix = vm.toString(i);
            tokens[i] = vm.envAddress(string.concat("FLASH_VAULT_TOKEN_", suffix));
            amounts[i] = vm.envUint(string.concat("FLASH_VAULT_SEED_AMOUNT_", suffix));
            minimums[i] = vm.envUint(string.concat("FLASH_VAULT_MIN_LIQUIDITY_", suffix));
            require(tokens[i].code.length > 0, "FundFlashVault: token not contract");
            require(vault.tokenAllowed(tokens[i]), "FundFlashVault: token not allowed");
            require(minimums[i] > 0, "FundFlashVault: zero minimum");
            require(IERC20(tokens[i]).balanceOf(deployer) >= amounts[i], "FundFlashVault: insufficient funder balance");
            for (uint256 j = 0; j < i; j++) {
                require(tokens[j] != tokens[i], "FundFlashVault: duplicate token");
            }
        }

        vm.startBroadcast(deployer);
        for (uint256 i = 0; i < tokenCount; i++) {
            if (amounts[i] > 0) {
                IERC20(tokens[i]).forceApprove(address(vault), amounts[i]);
                vault.depositLiquidity(tokens[i], amounts[i]);
                IERC20(tokens[i]).forceApprove(address(vault), 0);
            }
            require(
                IERC20(tokens[i]).balanceOf(address(vault)) >= minimums[i], "FundFlashVault: minimum liquidity not met"
            );
            console2.log("Verified flash liquidity token", tokens[i]);
            console2.log("Verified flash liquidity amount", IERC20(tokens[i]).balanceOf(address(vault)));
        }
        if (unpause) vault.setPaused(false);
        vm.stopBroadcast();

        console2.log("Flash vault", address(vault));
        console2.log("Flash vault paused", vault.paused());
    }
}

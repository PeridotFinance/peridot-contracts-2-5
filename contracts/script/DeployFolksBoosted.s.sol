// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/boosted/FolksBoostedPErc20.sol";
import "../contracts/PeridottrollerInterface.sol";
import "../contracts/InterestRateModel.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @dev Deployment script for a Folks-boosted pToken market.
contract DeployFolksBoosted is Script {
    function run() external {
        address underlying = vm.envAddress("UNDERLYING"); // e.g., AUSD
        address comptroller = vm.envAddress("PERIDOTTROLLER"); // Comptroller proxy
        address irm = vm.envAddress("INTEREST_RATE_MODEL"); // e.g., JumpRateModelBoosted
        address vault = vm.envAddress("FOLKS_VAULT"); // Folks ERC4626 vault
        address admin = vm.envAddress("ADMIN"); // protocol admin / multisig

        // Defaults; override via env if desired
        // Defaults for 6-decimal underlying (e.g., AUSD/USDC share tokens); adjust if your share token decimals differ
        uint256 initialExchangeRate = 2e14; // 6d constant; use 2e26 for 18d
        uint256 bufferMantissa = 0; // 0% buffer; set >0 to keep idle shares
        string memory name = vm.envOr("PTOKEN_NAME", string("Peridot Folks Boosted"));
        string memory symbol = vm.envOr("PTOKEN_SYMBOL", string("pfBoost"));

        uint8 decimals = IERC20Metadata(underlying).decimals();

        vm.startBroadcast();
        FolksBoostedPErc20 pToken = new FolksBoostedPErc20(
            underlying,
            PeridottrollerInterface(comptroller),
            InterestRateModel(irm),
            initialExchangeRate,
            name,
            symbol,
            decimals,
            payable(admin),
            IERC4626(vault),
            bufferMantissa
        );
        console2.log("FolksBoostedPErc20 deployed at:", address(pToken));
        vm.stopBroadcast();
    }
}

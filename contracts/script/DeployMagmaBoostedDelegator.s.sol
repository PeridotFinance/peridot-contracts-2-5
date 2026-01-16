// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/boosted/MagmaBoostedDelegate.sol";
import "../contracts/PErc20Delegator.sol";
import "../contracts/PeridottrollerInterface.sol";
import "../contracts/InterestRateModel.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @dev Deploys MagmaBoosted delegate + delegator (Compound-style) for WMON staking.
contract DeployMagmaBoostedDelegator is Script {
    function run() external {
        // === Hard-coded deployment params (replace as needed) ===
        address underlying = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A; // WMON on Monad Mainnet
        address comptroller = 0x6D208789f0a978aF789A3C8Ba515749598940716; // Peridottroller Proxy
        address irm = 0x5710017eCdF44f39b5Ae885965140726B7d81099; // JumpRateModelBoosted
        address magmaVault = 0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081; // Magma (gMON) on Monad Mainnet
        address admin = 0xCED23360932B80d18fdEAEAa573202E80A584804;

        uint256 initialExchangeRate = 2e26; // 18d underlying (WMON)
        uint256 bufferMantissa = 3e17; // 30% buffer (higher due to async redemptions)

        string memory name = "Peridot Magma Staked WMON";
        string memory symbol = "pMagmaWMON";

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        // Deploy delegate implementation
        MagmaBoostedDelegate implementation = new MagmaBoostedDelegate();

        // Encode becomeImplementation data: (magmaVault, bufferMantissa)
        bytes memory becomeImplData = abi.encode(magmaVault, bufferMantissa);

        // Deploy delegator pointing to delegate
        PErc20Delegator delegator = new PErc20Delegator(
            underlying,
            PeridottrollerInterface(comptroller),
            InterestRateModel(irm),
            initialExchangeRate,
            name,
            symbol,
            IERC20Metadata(underlying).decimals(),
            payable(admin),
            address(implementation),
            becomeImplData
        );

        console2.log("MagmaBoosted delegator deployed at:", address(delegator));
        console2.log(
            "MagmaBoosted delegate implementation at:",
            address(implementation)
        );

        console2.log("\n=== Next Steps ===");
        console2.log(
            "1. Call Peridottroller._supportMarket(",
            address(delegator),
            ")"
        );
        console2.log("2. Set collateral factor via _setCollateralFactor");
        console2.log("3. Configure oracle price for", address(delegator));
        console2.log("4. Monitor buffer levels and manage async redemptions");

        vm.stopBroadcast();
    }
}

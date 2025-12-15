// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/boosted/MorphoBoostedDelegate.sol";
import "../contracts/PErc20Delegator.sol";
import "../contracts/PeridottrollerInterface.sol";
import "../contracts/InterestRateModel.sol";
import {IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @dev Deploys MorphoBoosted delegate + delegator (Compound-style) with hard-coded params.
contract DeployMorphoBoostedDelegator is Script {
    function run() external {
        // === Hard-coded deployment params (replace as needed) ===
        address underlying = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603; // AUSD
        address comptroller = 0x6D208789f0a978aF789A3C8Ba515749598940716;
        address irm = 0x5710017eCdF44f39b5Ae885965140726B7d81099; // JumpRateModelBoosted or other
        address morphoVault = 0xbeEFf443C3CbA3E369DA795002243BeaC311aB83; // Morpho ERC4626 vault
        address admin = 0xCED23360932B80d18fdEAEAa573202E80A584804;

        uint256 initialExchangeRate = 2e14; // 6d underlying
        uint256 bufferMantissa = 0; // 0% buffer

        string memory name = "Peridot Morpho Steakhouse USDC";
        string memory symbol = "pMorphoUSDC";

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        // Deploy delegate implementation
        MorphoBoostedDelegate implementation = new MorphoBoostedDelegate();

        // Encode becomeImplementation data: (morphoVault, bufferMantissa)
        // Note: PErc20Delegator already calls initialize() separately,
        // then passes this data to _becomeImplementation()
        bytes memory becomeImplData = abi.encode(morphoVault, bufferMantissa);

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

        console2.log(
            "MorphoBoosted delegator deployed at:",
            address(delegator)
        );
        console2.log(
            "MorphoBoosted delegate implementation at:",
            address(implementation)
        );
        vm.stopBroadcast();
    }
}

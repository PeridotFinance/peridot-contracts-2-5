// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";
import {InterestRateModel} from "../contracts/InterestRateModel.sol";
import {PErc20Delegate} from "../contracts/PErc20Delegate.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";

/**
 * @title DeployPErc20Generic
 * @notice Deploys a PErc20 market (delegate + delegator) with admin set to deployer.
 * @dev All inputs are read from environment variables for flexibility.
 *
 * Required env vars:
 *  - PRIVATEMAIN:            admin private key
 *  - UNDERLYING:             underlying ERC20 address
 *  - COMPTROLLER:            comptroller (Unitroller) address
 *  - INTEREST_RATE_MODEL:    interest rate model address
 *  - INITIAL_EXCHANGE_RATE:  initial exchange rate mantissa
 *  - PTOKEN_NAME:            name string
 *  - PTOKEN_SYMBOL:          symbol string
 * Optional env vars:
 *  - PTOKEN_DECIMALS:        defaults to 8
 */
contract DeployPErc20Generic is Script {
    function run() public {
        uint256 pk = vm.envUint("PRIVATEMAIN");
        address deployer = vm.addr(pk);

        address underlying = 0xB911C192ed1d6428A12F2Cf8F636B00c34e68a2a;
        address comptroller = 0xC4FE7BD6b9EdD67bF2ba5daa317D7cd80E1913bb;
        address irm = 0x60a8BD81f90526560344C63279210BC067a489a5;

        uint256 initialExchangeRate = 2e26;
        string memory name = "Peridot P";
        string memory symbol = "pP";

        uint8 decimals = 8; // sensible default

        console.log("=== Deploy PErc20 (Generic) ===");
        console.log("Deployer:", deployer);
        console.log("Underlying:", underlying);
        console.log("Comptroller:", comptroller);
        console.log("IRM:", irm);
        console.log("InitExRate:", initialExchangeRate);
        console.log("Name:", name);
        console.log("Symbol:", symbol);
        console.log("Decimals:", decimals);

        vm.startBroadcast(pk);

        PErc20Delegate delegate = new PErc20Delegate();
        console.log("PErc20Delegate:", address(delegate));

        PErc20Delegator delegator = new PErc20Delegator(
            underlying,
            PeridottrollerInterface(comptroller),
            InterestRateModel(irm),
            initialExchangeRate,
            name,
            symbol,
            decimals,
            payable(deployer),
            address(delegate),
            ""
        );
        console.log("PErc20Delegator:", address(delegator));

        // Verify admin
        address adminNow = delegator.admin();
        console.log("Admin:", adminNow);

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("Proxy:", address(delegator));
        console.log("Impl:", address(delegate));
        console.log("Admin:", adminNow);
    }
}

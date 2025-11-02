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

        address underlying = 0x6Bfe75D1ad432050eA973C3A3DcD88F02e2444C3;
        address comptroller = 0x6fC0c15531CB5901ac72aB3CFCd9dF6E99552e14;
        address irm = 0x22B129f93dfe3A63cBB644a86dBD695be5deE511;

        uint256 initialExchangeRate = 2e26;
        string memory name = "Peridot Microsoft (Ondo Tokenized)";
        string memory symbol = "pMSOFTon";

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

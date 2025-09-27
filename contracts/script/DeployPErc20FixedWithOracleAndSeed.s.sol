// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {PErc20Delegate} from "../contracts/PErc20Delegate.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {Peridottroller} from "../contracts/Peridottroller.sol";
import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";
import {InterestRateModel} from "../contracts/InterestRateModel.sol";
import {SimplePriceOracle} from "../contracts/SimplePriceOracle.sol";
import {EIP20Interface} from "../contracts/EIP20Interface.sol";

/**
 * @title DeployPErc20FixedWithOracleAndSeed
 * @dev Deployment script that:
 *  - Deploys PErc20 delegate/delegator
 *  - Sets oracle (SimplePriceOracle) and price
 *  - Safely seeds the market with admin-led mint
 *  - Marks market seeded, leaving CF=0 and borrows paused until manual enable
 *
 * Notes: mirrors the style of DeployPErc20Fixed with extra safety steps and verbose logs.
 */
contract DeployPErc20FixedWithOracleAndSeed is Script {
    // --- CONFIGURATION (adjust per chain) ---
    address constant UNDERLYING_ERC20_ADDRESS =
        0xbA2aE424d960c26247Dd6c32edC70B295c744C43; // example DOGE on BSC
    address constant COMPTROLLER_ADDRESS =
        0x6fC0c15531CB5901ac72aB3CFCd9dF6E99552e14;
    address constant INTEREST_RATE_MODEL_ADDRESS =
        0x8334A3ec5c9Cf105E57B8b4B68386B8A8043DD36;

    // Deploy a fresh SimplePriceOracle (or replace with existing)
    bool constant DEPLOY_ORACLE = true;
    uint256 constant ORACLE_STALE_THRESHOLD_SEC = 3600; // 1h
    // Direct price to set for underlying (scaled 1e18)
    uint256 constant DIRECT_PRICE_1e18 = 10e18; // example $10

    // pToken params
    uint256 constant INITIAL_EXCHANGE_RATE_MANTISSA = 2e16; // 0.02
    string constant PTOKEN_NAME = "Peridot Dogecoin";
    string constant PTOKEN_SYMBOL = "pDOGE";
    uint8 constant PTOKEN_DECIMALS = 8;
    uint256 constant RESERVE_FACTOR = 0.05 * 1e18;

    // Safety floors (optional): set via setSafetyParams
    uint256 constant MIN_CTOKENS = 1e8; // tiny floor
    uint256 constant MIN_CASH = 1e18; // 1 unit
    uint256 constant MAX_RATE_BPS = 5000; // 50%

    // Seed amount of underlying (admin supplies)
    uint256 constant SEED_AMOUNT = 100e18; // adjust to underlying decimals

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATEMAIN");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploy PErc20 + Oracle + Safe Seed ===");
        console.log("Deployer:", deployer);
        console.log("Underlying:", UNDERLYING_ERC20_ADDRESS);
        console.log("Comptroller:", COMPTROLLER_ADDRESS);
        console.log("Interest Model:", INTEREST_RATE_MODEL_ADDRESS);
        console.log("Reserve Factor:", RESERVE_FACTOR);

        vm.startBroadcast(deployerPrivateKey);

        // 1) Deploy delegate & delegator
        PErc20Delegate delegate = new PErc20Delegate();
        console.log("Delegate:", address(delegate));

        PErc20Delegator delegator = new PErc20Delegator(
            UNDERLYING_ERC20_ADDRESS,
            PeridottrollerInterface(COMPTROLLER_ADDRESS),
            InterestRateModel(INTEREST_RATE_MODEL_ADDRESS),
            INITIAL_EXCHANGE_RATE_MANTISSA,
            PTOKEN_NAME,
            PTOKEN_SYMBOL,
            PTOKEN_DECIMALS,
            payable(deployer),
            address(delegate),
            ""
        );
        console.log("Delegator:", address(delegator));

        // 2) Verify admin
        address currentAdmin = delegator.admin();
        console.log("Admin:", currentAdmin);
        require(currentAdmin == deployer, "Admin mismatch");

        // 3) Set reserve factor
        uint256 reserveResult = delegator._setReserveFactor(RESERVE_FACTOR);
        require(reserveResult == 0, "Set reserve factor failed");
        console.log(
            "Reserve factor set to:",
            delegator.reserveFactorMantissa()
        );

        // 4) Oracle setup
        Peridottroller comptroller = Peridottroller(COMPTROLLER_ADDRESS);
        SimplePriceOracle oracle = DEPLOY_ORACLE
            ? new SimplePriceOracle(ORACLE_STALE_THRESHOLD_SEC)
            : SimplePriceOracle(address(0));
        if (DEPLOY_ORACLE) {
            console.log("Oracle deployed:", address(oracle));
            // Make deployer admin on oracle and set price
            oracle.setAdmin(deployer);
            oracle.setDirectPrice(UNDERLYING_ERC20_ADDRESS, DIRECT_PRICE_1e18);
            uint256 resPO = comptroller._setPriceOracle(oracle);
            require(resPO == 0, "Set oracle failed");
            console.log("Oracle wired to comptroller");
        } else {
            console.log("Oracle deployment skipped - using existing");
        }

        // 5) Support market (and keep CF=0 by default)
        uint256 supportRes = comptroller._supportMarket(
            PErc20Delegator(address(delegator))
        );
        require(supportRes == 0, "Support market failed");
        console.log("Market supported in comptroller");

        // 6) Pre-seed safety: force CF=0 and pause borrows
        comptroller._setCollateralFactor(
            PErc20Delegator(address(delegator)),
            0
        );
        comptroller._setBorrowPaused(PErc20Delegator(address(delegator)), true);
        console.log("CF=0 & borrows paused");

        // 7) Optional: set safety params to floors and breaker cap
        comptroller.setSafetyParams(MIN_CTOKENS, MIN_CASH, MAX_RATE_BPS);
        console.log("Safety params set");

        // 8) Seed liquidity as admin
        EIP20Interface(UNDERLYING_ERC20_ADDRESS).approve(
            address(delegator),
            SEED_AMOUNT
        );
        uint256 mintRet = delegator.mint(SEED_AMOUNT);
        require(mintRet == 0, "Seed mint failed");
        console.log("Seeded:", SEED_AMOUNT);

        // 9) Mark seeded on controller
        uint256 ms = comptroller.markSeeded(
            PErc20Delegator(address(delegator))
        );
        require(ms == 0, "markSeeded failed");
        console.log("Market marked seeded");

        // NOTE: Do not set CF>0 or unpause borrows here. Do it after audits/tests.

        vm.stopBroadcast();

        console.log("\n=== Deployment + Seeding Summary ===");
        console.log("Delegator:", address(delegator));
        if (DEPLOY_ORACLE) {
            console.log("Oracle:", address(oracle));
        }
        console.log("Reserve Factor:", delegator.reserveFactorMantissa());
        console.log("Seed Amount:", SEED_AMOUNT);
        console.log("Status: CF=0, borrows paused, seeded=true");
        console.log(
            "Next: verify exchangeRate/totalSupply/getCash; then consider CF>0 and unpause"
        );
    }
}

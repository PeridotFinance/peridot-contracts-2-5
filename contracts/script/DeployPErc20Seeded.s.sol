// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";
import {InterestRateModel} from "../contracts/InterestRateModel.sol";
import {PErc20Delegate} from "../contracts/PErc20Delegate.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {EIP20Interface} from "../contracts/EIP20Interface.sol";

/**
 * @title DeployPErc20Seeded
 * @dev Deployment script that deploys a PErc20 market, supports it, sets reserve factor,
 *      and seeds initial liquidity and supply to avoid empty-market exchange rate edge cases.
 *      Mirrors DeployPErc20Fixed.s.sol with an additional seeding step.
 */
contract DeployPErc20Seeded is Script {
    // --- CONFIGURATION ---
    // Required: set to underlying token, comptroller, and rate model
    address constant UNDERLYING_ERC20_ADDRESS =
        0xA9eE28C80f960B889dFbd1902055218cBa016F75;
    address constant COMPTROLLER_ADDRESS =
        0x6fC0c15531CB5901ac72aB3CFCd9dF6E99552e14;
    address constant INTEREST_RATE_MODEL_ADDRESS =
        0x22B129f93dfe3A63cBB644a86dBD695be5deE511;

    // Initial exchange rate and metadata
    uint256 constant INITIAL_EXCHANGE_RATE_MANTISSA = 2e26; // 0.02
    string constant PTOKEN_NAME = "Peridot Alphabet Class A (Ondo Tokenized)";
    string constant PTOKEN_SYMBOL = "pGOOGLon";
    uint8 constant PTOKEN_DECIMALS = 8;

    // Parameters
    uint256 constant RESERVE_FACTOR = 0.05 * 1e18; // 5%

    // Seed configuration
    // The seeding amount is transferred to the pToken and minted to the deployer to
    // establish a non-zero totalSupply and solid exchange rate baseline.
    // Adjust based on underlying token decimals.
    uint256 constant SEED_UNDERLYING_AMOUNT = 480000000000000000; // example for 8 decimals: 10 DOGE = 1_000_000_000

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATEMAIN");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploying Seeded PErc20 Market ===");
        console.log("Deployer:", deployer);
        console.log("Underlying:", UNDERLYING_ERC20_ADDRESS);
        console.log("Comptroller:", COMPTROLLER_ADDRESS);
        console.log("IRM:", INTEREST_RATE_MODEL_ADDRESS);
        console.log("ReserveFactor:", RESERVE_FACTOR);
        console.log("Seed Underlying Amount:", SEED_UNDERLYING_AMOUNT);

        vm.startBroadcast(deployerPrivateKey);

        // 1) Deploy implementation
        PErc20Delegate delegate = new PErc20Delegate();
        console.log("PErc20Delegate:", address(delegate));

        // 2) Deploy delegator with deployer as admin
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
        console.log("PErc20Delegator:", address(delegator));

        // 3) Verify / accept admin if needed
        address adminNow = delegator.admin();
        if (adminNow != deployer) {
            if (delegator.pendingAdmin() == deployer) {
                uint256 ar = delegator._acceptAdmin();
                require(ar == 0, "accept admin failed");
            } else {
                revert("delegator admin mismatch");
            }
        }

        // 4) Set reserve factor
        uint256 rf = delegator._setReserveFactor(RESERVE_FACTOR);
        require(rf == 0, "reserve factor set failed");

        // 5) Optional: support market now so mintAllowed passes
        // If using Unitroller proxy, ensure this address is the admin there.
        // We avoid importing the concrete comptroller here; use interface to call.
        (bool ok, bytes memory ret) = COMPTROLLER_ADDRESS.call(
            abi.encodeWithSignature(
                "_supportMarket(address)",
                address(delegator)
            )
        );
        require(
            ok && (ret.length == 32 && abi.decode(ret, (uint256)) == 0),
            "support market failed"
        );

        // 6) Seed the market: transfer underlying to deployer first if needed, then approve and mint
        EIP20Interface underlying = EIP20Interface(UNDERLYING_ERC20_ADDRESS);
        // Approve delegator to pull underlying
        require(
            underlying.approve(address(delegator), SEED_UNDERLYING_AMOUNT),
            "approve failed"
        );

        // Mint will transferFrom deployer -> pToken and mint pTokens to deployer at initial exchange rate
        uint256 mintResult = delegator.mint(SEED_UNDERLYING_AMOUNT);
        require(mintResult == 0, "seed mint failed");

        // 7) Post checks
        uint256 exchangeRate = delegator.exchangeRateStored();
        console.log("ExchangeRateStored:", exchangeRate);
        console.log("TotalSupply:", delegator.totalSupply());
        console.log("Cash:", delegator.getCash());

        vm.stopBroadcast();

        console.log("\n=== Seeded Deployment Summary ===");
        console.log("Proxy:", address(delegator));
        console.log("Impl:", address(delegate));
        console.log("Admin:", delegator.admin());
        console.log("ReserveFactor:", delegator.reserveFactorMantissa());
    }
}

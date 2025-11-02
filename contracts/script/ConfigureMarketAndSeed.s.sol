// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {PTokenInterface} from "../contracts/PTokenInterfaces.sol";
import {PErc20Interface} from "../contracts/PTokenInterfaces.sol";
import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";
import {EIP20Interface} from "../contracts/EIP20Interface.sol";

/**
 * @title ConfigureMarketAndSeed
 * @notice Configures an existing pToken market: set oracle price, support market, CF, RF, optional cap, approve+mint seed.
 *
 * Required env vars:
 *  - PRIVATEMAIN:                admin private key (must be pToken admin and Comptroller admin to perform admin ops)
 *  - PTOKEN:                     pToken (delegator) address
 *  - COMPTROLLER:                comptroller (Unitroller) address
 * Optional env vars:
 *  - ORACLE:                     SimplePriceOracle address (to set direct price)
 *  - DIRECT_PRICE:               price mantissa (18 decimals) to set on oracle
 *  - COLLATERAL_FACTOR:          CF mantissa (e.g. 600000000000000000 for 60%)
 *  - RESERVE_FACTOR:             RF mantissa (<= 1e18)
 *  - BORROW_CAP:                 cap in underlying (0 = unlimited)
 *  - SEED_AMOUNT:                underlying amount to mint as seed (requires deployer has balance)
 */
contract ConfigureMarketAndSeed is Script {
    function run() public {
        uint256 pk = vm.envUint("PRIVATEMAIN");
        address deployer = vm.addr(pk);

        // --- Hardcoded params (edit before running) ---
        address comptroller = 0x6fC0c15531CB5901ac72aB3CFCd9dF6E99552e14;
        address pTokenAddr = 0xC59022e41D377554191351Deaaf5546012Ed906b; // example: GOOG pToken

        // Risk params (set flags true to apply)
        uint256 collateralFactor = 600000000000000000; // 60%
        bool hasCF = true;

        uint256 reserveFactor = 50000000000000000; // 5%
        bool hasRF = true;

        uint256 borrowCap = 0; // 0 = unlimited
        bool hasCap = false; // set true to apply

        // Seed (optional)
        uint256 seedAmount = 191717735179935734; // underlying amount
        bool hasSeed = true; // set true to mint seed

        console.log("=== Configure Market & Seed ===");
        console.log("Deployer:", deployer);
        console.log("Comptroller:", comptroller);
        console.log("pToken:", pTokenAddr);

        vm.startBroadcast(pk);

        // 1) Support market in Comptroller
        (bool ok, bytes memory ret) = comptroller.call(
            abi.encodeWithSignature("_supportMarket(address)", pTokenAddr)
        );
        require(
            ok && (ret.length == 32 && abi.decode(ret, (uint256)) == 0),
            "support market failed"
        );
        console.log("Market supported in Comptroller");

        // 2) Set collateral factor (if provided)
        if (hasCF) {
            (ok, ret) = comptroller.call(
                abi.encodeWithSignature(
                    "_setCollateralFactor(address,uint256)",
                    pTokenAddr,
                    collateralFactor
                )
            );
            require(
                ok && (ret.length == 32 && abi.decode(ret, (uint256)) == 0),
                "set CF failed"
            );
            console.log("Set CF:", collateralFactor);
        }

        // 3) Set reserve factor on pToken (admin-only)
        if (hasRF) {
            uint256 rfRes = PTokenInterface(pTokenAddr)._setReserveFactor(
                reserveFactor
            );
            require(rfRes == 0, "set RF failed");
            console.log("Set RF:", reserveFactor);
        }

        // 4) Optional: set borrow cap
        if (hasCap) {
            address[] memory markets = new address[](1);
            markets[0] = pTokenAddr;
            uint256[] memory caps = new uint256[](1);
            caps[0] = borrowCap;
            (ok, ) = comptroller.call(
                abi.encodeWithSignature(
                    "_setMarketBorrowCaps(address[],uint256[])",
                    markets,
                    caps
                )
            );
            require(ok, "set cap failed");
            console.log("Set borrow cap:", borrowCap);
        }

        // 5) Seed mint (if provided)
        if (hasSeed) {
            address underlying = PErc20Interface(pTokenAddr).underlying();
            EIP20Interface u = EIP20Interface(underlying);
            require(u.approve(pTokenAddr, seedAmount), "approve failed");
            uint256 mintRes = PErc20Interface(pTokenAddr).mint(seedAmount);
            require(mintRes == 0, "seed mint failed");
            console.log("Seeded:", seedAmount);
        }

        vm.stopBroadcast();

        console.log("\n=== Config Summary ===");
        console.log("pToken:", pTokenAddr);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IManagerCommon {
    function enterPosition(
        address cTokenIn,
        address cTokenOut,
        uint256 amount,
        uint8 direction,
        uint256 strike,
        uint256 expiry,
        bool useCollateral,
        bool enableAutoCompound
    ) external returns (uint256 tokenId);

    function enterPositionWithOffset(
        address cTokenIn,
        address cTokenOut,
        uint256 amount,
        uint8 direction,
        uint256 strike,
        uint256 offsetSeconds,
        bool useCollateral,
        bool enableAutoCompound
    ) external returns (uint256 tokenId);

    function vaultExecutor() external view returns (address);

    function canEnterPosition(
        address user,
        address cTokenIn,
        uint256 amount,
        bool useCollateral
    ) external returns (bool, string memory);

    function minExpiry() external view returns (uint256);
}

interface IPTokenView {
    function exchangeRateStored() external view returns (uint256);

    function getCash() external view returns (uint256);
}

contract EnterPositionCollateral is Script {
    // Defaults for BSC Testnet (can be overridden by env vars)
    address public constant DEFAULT_PWBTC =
        0xfB68C6469A67873f7FA2Df6CeAcC5da12abF6c8c; //LINK
    address public constant DEFAULT_PUSDC =
        0xF0a6303cA0A99d9235979b317E3a78083162a88B;

    function run() external {
        // Required env
        address managerAddr = 0xB5f80Fb15CeBaB3E4c217e03350E431fC218c94E;
        uint256 userPk = vm.envUint("PRIVATE_KEY");

        // Optional env overrides
        address cTokenIn = DEFAULT_PWBTC;
        address cTokenOut = DEFAULT_PUSDC;

        // Amount in cToken units (NOT underlying). Example for 1e8 if pWBTC has 8 decimals
        uint256 amount = 100e8;

        // Direction: 0 = CALL, 1 = PUT
        uint8 direction = uint8(1);

        // Strike in 18 decimals. Provide via env STRIKE_1e18, otherwise use 0 (will revert if 0)
        uint256 strike = 20000000000000000000;
        require(strike > 0, "STRIKE_1e18 env required");

        // Expiry offset in minutes (default 4)
        uint256 expiryMinutes = 4;

        address user = vm.addr(userPk);
        console.log("Manager:", managerAddr);
        console.log("User:", user);
        console.log("cTokenIn (collateral):", cTokenIn);
        console.log("cTokenOut (settlement):", cTokenOut);
        console.log("Amount (cToken units):", amount);
        console.log("Direction:", direction);
        console.log("Strike (1e18):", strike);
        console.log("Expiry minutes:", expiryMinutes);

        IManagerCommon manager = IManagerCommon(managerAddr);
        address vault = manager.vaultExecutor();
        console.log("VaultExecutor:", vault);

        // Capacity check to avoid redeem failures due to insufficient pool cash
        {
            uint256 exchangeRate = IPTokenView(cTokenIn).exchangeRateStored();
            uint256 poolCashUnderlying = IPTokenView(cTokenIn).getCash();
            uint256 maxRedeemCTokens = (poolCashUnderlying * 1e18) /
                exchangeRate;
            console.log("Pool cash (underlying):", poolCashUnderlying);
            console.log("Max redeemable cTokens:", maxRedeemCTokens);
            if (amount > maxRedeemCTokens && maxRedeemCTokens > 0) {
                console.log("Trimming amount to pool capacity");
                amount = maxRedeemCTokens - 1; // leave a tiny buffer
                console.log("New amount:", amount);
            }
        }

        // Preflight check to avoid revert and provide reason
        (bool ok, string memory reason) = manager.canEnterPosition(
            user,
            cTokenIn,
            amount,
            true
        );
        console.log("canEnterPosition:", ok);
        if (!ok) {
            console.log("Reason:", reason);
            return;
        }

        vm.startBroadcast(userPk);

        // Approve VaultExecutor to pull user's cTokens (collateral path)
        IERC20(cTokenIn).approve(vault, amount);

        // Use on-chain offset to avoid clock skew and minExpiry races
        uint256 offsetSeconds = expiryMinutes * 60;
        uint256 minOff = manager.minExpiry();
        if (offsetSeconds < minOff) {
            offsetSeconds = minOff;
        }
        uint256 tokenId = manager.enterPositionWithOffset(
            cTokenIn,
            cTokenOut,
            amount,
            direction,
            strike,
            offsetSeconds,
            true, // useCollateral
            false // enableAutoCompound (deprecated)
        );

        console.log("enterPosition - > tokenId:", tokenId);

        vm.stopBroadcast();
    }

    function _tryEnvAddress(
        string memory key,
        address fallbackAddr
    ) internal view returns (address) {
        try vm.envAddress(key) returns (address v) {
            return v;
        } catch {
            return fallbackAddr;
        }
    }

    function _tryEnvUint(
        string memory key,
        uint256 fallbackVal
    ) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 v) {
            return v;
        } catch {
            return fallbackVal;
        }
    }
}

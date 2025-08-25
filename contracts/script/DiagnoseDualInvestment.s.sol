// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IManagerDiag {
    function riskGuard() external view returns (address);

    function vaultExecutor() external view returns (address);

    function settlementEngine() external view returns (address);

    function supportedCTokens(address) external view returns (bool);
}

interface IRiskGuardOwnable {
    function owner() external view returns (address);
}

interface IVaultExecutorAuth {
    function authorizedManagers(address) external view returns (bool);
}

interface IPositionTokenAuth {
    function authorizedMinters(address) external view returns (bool);
}

interface ISettlementEngineView {
    function priceOracle() external view returns (address);
}

interface ISimplePriceOracleView {
    function assetPrices(address asset) external view returns (uint256);

    function getAggregator(address asset) external view returns (address);
}

interface IPTokenMeta {
    function symbol() external view returns (string memory);

    function underlying() external view returns (address);

    function exchangeRateStored() external view returns (uint256);

    function getCash() external view returns (uint256);
}

contract DiagnoseDualInvestment is Script {
    function run() external {
        address manager = 0x6A2eBbDB8C82C11aCC382c3f025d40a4ed7E02b2;
        address cTokenIn = 0xfB68C6469A67873f7FA2Df6CeAcC5da12abF6c8c;
        address cTokenOut = 0xF0a6303cA0A99d9235979b317E3a78083162a88B;

        console.log("Manager:", manager);
        console.log("cTokenIn:", cTokenIn);
        console.log("cTokenOut:", cTokenOut);

        IManagerDiag m = IManagerDiag(manager);
        address rg = m.riskGuard();
        address ve = m.vaultExecutor();
        address se = m.settlementEngine();
        console.log("RiskGuard:", rg);
        console.log("VaultExecutor:", ve);
        console.log("SettlementEngine:", se);

        // Supported tokens check
        if (cTokenIn != address(0)) {
            console.log(
                "supportedCTokens(cTokenIn):",
                IManagerDiag(manager).supportedCTokens(cTokenIn)
            );
        }
        if (cTokenOut != address(0)) {
            console.log(
                "supportedCTokens(cTokenOut):",
                IManagerDiag(manager).supportedCTokens(cTokenOut)
            );
        }

        // Ownership/authorization
        address rgOwner = IRiskGuardOwnable(rg).owner();
        bool veAuth = IVaultExecutorAuth(ve).authorizedManagers(manager);
        console.log("RiskGuard.owner:", rgOwner);
        console.log("VaultExecutor.authorizedManagers(manager):", veAuth);

        // Position token minter auth (optional; pass POSITION_TOKEN env to check)
        address pos = _tryEnvAddress("POSITION_TOKEN", address(0));
        if (pos != address(0)) {
            bool minterAuth = IPositionTokenAuth(pos).authorizedMinters(
                manager
            );
            console.log(
                "PositionToken.authorizedMinters(manager):",
                minterAuth
            );
        }

        // Oracle wiring and price
        address oracle = ISettlementEngineView(se).priceOracle();
        console.log("SettlementEngine.priceOracle:", oracle);

        address underlying = IPTokenMeta(cTokenIn).underlying();
        string memory sym = IPTokenMeta(cTokenIn).symbol();
        uint256 rate = IPTokenMeta(cTokenIn).exchangeRateStored();
        uint256 cash = IPTokenMeta(cTokenIn).getCash();
        console.log("cToken symbol:", sym);
        console.log("underlying:", underlying);
        console.log("exchangeRateStored:", rate);
        console.log("getCash (underlying):", cash);

        // Oracle details
        address agg = ISimplePriceOracleView(oracle).getAggregator(underlying);
        uint256 price = ISimplePriceOracleView(oracle).assetPrices(underlying);
        console.log("Oracle aggregator:", agg);
        console.log("Oracle assetPrices (1e18):", price);
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
}

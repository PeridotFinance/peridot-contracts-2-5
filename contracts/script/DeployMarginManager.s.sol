// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {MarginManager} from "../contracts/margin/MarginManager.sol";

contract DeployMarginManager is Script {
    struct MarketInput {
        address cToken;
        address underlying;
        bool active;
        bool depositsEnabled;
        bool borrowsEnabled;
        bool withdrawalsEnabled;
        bool tradesEnabled;
        uint16 maxLeverageX100;
        uint16 tradeSlippageBps;
        uint16 oracleDeviationBps;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address peridottroller = vm.envAddress("PERIDOTTROLLER");
        address priceOracle = vm.envAddress("PRICE_ORACLE");

        address routerAdapter = _tryEnvAddress("ROUTER_ADAPTER");
        address flashloanProvider = _tryEnvAddress("FLASHLOAN_PROVIDER");
        address feeRecipient = _tryEnvAddress("FEE_RECIPIENT");

        uint256 hfMinWithdrawBps = _tryEnvUint("HF_MIN_WITHDRAW_BPS");
        uint256 hfLockBps = _tryEnvUint("HF_LOCK_BPS");
        uint256 hfUnlockBps = _tryEnvUint("HF_UNLOCK_BPS");

        uint256 openFeeBps = _tryEnvUint("OPEN_FEE_BPS");
        uint256 closeFeeBps = _tryEnvUint("CLOSE_FEE_BPS");
        uint256 defaultMaxLev = _tryEnvUint("DEFAULT_MAX_LEVERAGE_X100");

        MarketInput[] memory markets = _loadMarketInputs();

        console.log("Deploying MarginManager with:");
        console.log("  Comptroller:", peridottroller);
        console.log("  PriceOracle:", priceOracle);

        vm.startBroadcast(deployerKey);

        MarginManager manager = new MarginManager(peridottroller, priceOracle);
        console.log("MarginManager deployed:", address(manager));

        if (routerAdapter != address(0)) {
            manager.setRouterAdapter(routerAdapter);
            console.log("  Router adapter set:", routerAdapter);
        }

        if (flashloanProvider != address(0)) {
            manager.setFlashloanProvider(flashloanProvider);
            console.log("  Flashloan provider set:", flashloanProvider);
        }

        if (hfMinWithdrawBps != 0 || hfLockBps != 0 || hfUnlockBps != 0) {
            require(hfMinWithdrawBps != 0 && hfLockBps != 0 && hfUnlockBps != 0, "Threshold env vars must all be set");
            manager.setThresholds(uint16(hfMinWithdrawBps), uint16(hfLockBps), uint16(hfUnlockBps));
            console.log("  Threshold minWithdraw:", hfMinWithdrawBps);
            console.log("  Threshold lock:", hfLockBps);
            console.log("  Threshold unlock:", hfUnlockBps);
        }

        if (openFeeBps != 0 || closeFeeBps != 0) {
            manager.setFees(uint16(openFeeBps), uint16(closeFeeBps));
            console.log("  Open fee bps:", openFeeBps);
            console.log("  Close fee bps:", closeFeeBps);
        }

        if (feeRecipient != address(0)) {
            manager.setFeeRecipient(feeRecipient);
            console.log("  Fee recipient set:", feeRecipient);
        }

        if (defaultMaxLev != 0) {
            manager.setDefaultMaxLeverage(uint16(defaultMaxLev));
            console.log("  Default leverage set:", defaultMaxLev);
        }

        for (uint256 i = 0; i < markets.length; i++) {
            MarketInput memory m = markets[i];
            manager.configureMarket(
                m.cToken,
                m.underlying,
                m.active,
                m.depositsEnabled,
                m.borrowsEnabled,
                m.withdrawalsEnabled,
                m.tradesEnabled,
                m.maxLeverageX100,
                m.tradeSlippageBps,
                m.oracleDeviationBps
            );
            console.log("  Configured market cToken:", m.cToken);
            console.log("    underlying:", m.underlying);
        }

        vm.stopBroadcast();
    }

    function _loadMarketInputs() internal view returns (MarketInput[] memory) {
        uint256 count = _tryEnvUint("MARGIN_MARKET_COUNT");
        if (count == 0) {
            return new MarketInput[](0);
        }
        MarketInput[] memory markets = new MarketInput[](count);
        for (uint256 i = 0; i < count; i++) {
            string memory index = vm.toString(i);
            string memory prefix = string.concat("MARGIN_MARKET_", index, "_");

            markets[i] = MarketInput({
                cToken: vm.envAddress(string.concat(prefix, "CTOKEN")),
                underlying: vm.envAddress(string.concat(prefix, "UNDERLYING")),
                active: _tryEnvBool(string.concat(prefix, "ACTIVE"), true),
                depositsEnabled: _tryEnvBool(string.concat(prefix, "DEPOSITS_ENABLED"), true),
                borrowsEnabled: _tryEnvBool(string.concat(prefix, "BORROWS_ENABLED"), true),
                withdrawalsEnabled: _tryEnvBool(string.concat(prefix, "WITHDRAWALS_ENABLED"), true),
                tradesEnabled: _tryEnvBool(string.concat(prefix, "TRADES_ENABLED"), true),
                maxLeverageX100: uint16(_tryEnvUint(string.concat(prefix, "MAX_LEVERAGE_X100"))),
                tradeSlippageBps: uint16(_tryEnvUint(string.concat(prefix, "TRADE_SLIPPAGE_BPS"))),
                oracleDeviationBps: uint16(_tryEnvUint(string.concat(prefix, "ORACLE_DEVIATION_BPS")))
            });
        }
        return markets;
    }

    function _tryEnvAddress(string memory key) internal view returns (address) {
        try vm.envAddress(key) returns (address value) {
            return value;
        } catch {
            return address(0);
        }
    }

    function _tryEnvUint(string memory key) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 value) {
            return value;
        } catch {
            return 0;
        }
    }

    function _tryEnvBool(string memory key, bool fallbackValue) internal view returns (bool) {
        try vm.envBool(key) returns (bool value) {
            return value;
        } catch {
            return fallbackValue;
        }
    }
}

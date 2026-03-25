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

        // Optional wiring (set via env vars; leave unset/zero to skip)
        address routerAdapter = _tryEnvAddress("ROUTER_ADAPTER");
        address flashloanProvider = _tryEnvAddress("FLASHLOAN_PROVIDER");
        address feeRecipient = _tryEnvAddress("FEE_RECIPIENT");

        // Health-factor thresholds (optional; must set all three or none)
        uint256 hfMinWithdrawBps = _tryEnvUint("HF_MIN_WITHDRAW_BPS");
        uint256 hfLockBps = _tryEnvUint("HF_LOCK_BPS");
        uint256 hfUnlockBps = _tryEnvUint("HF_UNLOCK_BPS");

        // Open/close fee configuration (optional)
        uint256 openFeeBps = _tryEnvUint("OPEN_FEE_BPS");
        uint256 closeFeeBps = _tryEnvUint("CLOSE_FEE_BPS");
        // Default leverage (fallback when market-specific cap is zero)
        uint256 defaultMaxLev = _tryEnvUint("DEFAULT_MAX_LEVERAGE_X100");
        if (defaultMaxLev == 0) defaultMaxLev = 300;

        MarketInput[] memory markets = _loadMarketInputs();

        console.log("Deploying MarginManager with:");
        console.log("  Comptroller:", peridottroller);
        console.log("  PriceOracle:", priceOracle);

        vm.startBroadcast(deployerKey);

        MarginManager manager = new MarginManager(peridottroller, priceOracle);
        console.log("MarginManager deployed:", address(manager));

        // Optional wiring: router adapter
        if (routerAdapter != address(0)) {
            bytes32 actionId = manager.queueSetRouterAdapter(routerAdapter);
            console.log("  Queued router adapter actionId:");
            console.logBytes32(actionId);
        }

        // Optional wiring: flashloan provider
        if (flashloanProvider != address(0)) {
            bytes32 actionId = manager.queueSetFlashloanProvider(flashloanProvider);
            console.log("  Queued flashloan provider actionId:");
            console.logBytes32(actionId);
        }

        // Optional: override thresholds if all three values provided
        if (hfMinWithdrawBps != 0 || hfLockBps != 0 || hfUnlockBps != 0) {
            require(
                hfMinWithdrawBps != 0 && hfLockBps != 0 && hfUnlockBps != 0,
                "Threshold env vars must all be set"
            );
            bytes32 actionId = manager.queueSetThresholds(
                uint16(hfMinWithdrawBps),
                uint16(hfLockBps),
                uint16(hfUnlockBps)
            );
            console.log("  Queued thresholds actionId:");
            console.logBytes32(actionId);
            console.log("  Threshold minWithdraw:", hfMinWithdrawBps);
            console.log("  Threshold lock:", hfLockBps);
            console.log("  Threshold unlock:", hfUnlockBps);
        }

        // Optional: set open/close fees
        if (openFeeBps != 0 || closeFeeBps != 0) {
            bytes32 actionId = manager.queueSetFees(uint16(openFeeBps), uint16(closeFeeBps));
            console.log("  Queued fees actionId:");
            console.logBytes32(actionId);
            console.log("  Open fee bps:", openFeeBps);
            console.log("  Close fee bps:", closeFeeBps);
        }

        // Optional: set protocol fee recipient
        if (feeRecipient != address(0)) {
            bytes32 actionId = manager.queueSetFeeRecipient(feeRecipient);
            console.log("  Queued fee recipient actionId:");
            console.logBytes32(actionId);
        }

        // Optional: configure default leverage cap
        if (defaultMaxLev != 0) {
            bytes32 actionId = manager.queueSetDefaultMaxLeverage(uint16(defaultMaxLev));
            console.log("  Queued default leverage actionId:");
            console.logBytes32(actionId);
        }

        // Configure each market using the inputs supplied via env vars. Example env setup:
        // export MARGIN_MARKET_COUNT=3
        // export MARGIN_MARKET_0_CTOKEN=0x28E4F2Bb64ac79500ec3CAa074A3C30721B6bC84
        // export MARGIN_MARKET_0_UNDERLYING=0x2170Ed0880ac9A755fd29B2688956BD959F933F8
        // export MARGIN_MARKET_0_MAX_LEVERAGE_X100=300
        // export MARGIN_MARKET_0_TRADE_SLIPPAGE_BPS=50
        // export MARGIN_MARKET_0_ORACLE_DEVIATION_BPS=100
        // (repeat for _1_, _2_, etc.)
        for (uint256 i = 0; i < markets.length; i++) {
            MarketInput memory m = markets[i];
            bytes32 actionId = manager.queueConfigureMarket(
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
            console.log("  Queued market config actionId:");
            console.logBytes32(actionId);
            console.log("  Market cToken:", m.cToken);
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
                depositsEnabled: _tryEnvBool(
                    string.concat(prefix, "DEPOSITS_ENABLED"),
                    true
                ),
                borrowsEnabled: _tryEnvBool(
                    string.concat(prefix, "BORROWS_ENABLED"),
                    true
                ),
                withdrawalsEnabled: _tryEnvBool(
                    string.concat(prefix, "WITHDRAWALS_ENABLED"),
                    true
                ),
                tradesEnabled: _tryEnvBool(
                    string.concat(prefix, "TRADES_ENABLED"),
                    true
                ),
                maxLeverageX100: uint16(
                    _tryEnvUint(string.concat(prefix, "MAX_LEVERAGE_X100"))
                ),
                tradeSlippageBps: uint16(
                    _tryEnvUint(string.concat(prefix, "TRADE_SLIPPAGE_BPS"))
                ),
                oracleDeviationBps: uint16(
                    _tryEnvUint(string.concat(prefix, "ORACLE_DEVIATION_BPS"))
                )
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

    function _tryEnvBool(
        string memory key,
        bool fallbackValue
    ) internal view returns (bool) {
        try vm.envBool(key) returns (bool value) {
            return value;
        } catch {
            return fallbackValue;
        }
    }
}

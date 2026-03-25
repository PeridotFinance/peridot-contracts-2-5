// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PeridotTransparentProxy} from "../contracts/proxy/PeridotTransparentProxy.sol";
import {AtomicMarginExecutorUpgradeable} from "../contracts/margin/AtomicMarginExecutorUpgradeable.sol";
import {MarginCollateralVaultUpgradeable} from "../contracts/margin/MarginCollateralVaultUpgradeable.sol";
import {MarginEntryRouterUpgradeable} from "../contracts/margin/MarginEntryRouterUpgradeable.sol";
import {AtomicMarginLiquidationUpgradeable} from "../contracts/margin/AtomicMarginLiquidationUpgradeable.sol";
import {SimpleFlashLoanVaultUpgradeable} from "../contracts/margin/SimpleFlashLoanVaultUpgradeable.sol";

contract DeployMarginStackWithProxies is Script {
    struct Deployment {
        address flashLoanVaultImpl;
        address flashLoanVault;
        address flashLoanVaultProxyAdmin;
        address executorImpl;
        address executor;
        address executorProxyAdmin;
        address collateralVaultImpl;
        address collateralVault;
        address collateralVaultProxyAdmin;
        address entryRouterImpl;
        address entryRouter;
        address entryRouterProxyAdmin;
        address liquidationImpl;
        address liquidation;
        address liquidationProxyAdmin;
    }

    struct ProxyDeployment {
        address proxy;
        address proxyAdmin;
    }

    function run() external returns (Deployment memory d) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("MARGIN_OWNER");
        address configSource = vm.envAddress("MARGIN_CONFIG_SOURCE");

        vm.startBroadcast(pk);

        d.flashLoanVaultImpl = address(new SimpleFlashLoanVaultUpgradeable());
        {
            ProxyDeployment memory deployed = _deployProxy(
                d.flashLoanVaultImpl,
                owner,
                abi.encodeWithSelector(SimpleFlashLoanVaultUpgradeable.initialize.selector, owner)
            );
            d.flashLoanVault = deployed.proxy;
            d.flashLoanVaultProxyAdmin = deployed.proxyAdmin;
        }

        d.executorImpl = address(new AtomicMarginExecutorUpgradeable());
        {
            ProxyDeployment memory deployed = _deployProxy(
                d.executorImpl,
                owner,
                abi.encodeWithSelector(
                    AtomicMarginExecutorUpgradeable.initialize.selector,
                    owner,
                    configSource
                )
            );
            d.executor = deployed.proxy;
            d.executorProxyAdmin = deployed.proxyAdmin;
        }

        d.collateralVaultImpl = address(new MarginCollateralVaultUpgradeable());
        {
            ProxyDeployment memory deployed = _deployProxy(
                d.collateralVaultImpl,
                owner,
                abi.encodeWithSelector(
                    MarginCollateralVaultUpgradeable.initialize.selector,
                    d.executor,
                    owner
                )
            );
            d.collateralVault = deployed.proxy;
            d.collateralVaultProxyAdmin = deployed.proxyAdmin;
        }

        d.entryRouterImpl = address(new MarginEntryRouterUpgradeable());
        {
            ProxyDeployment memory deployed = _deployProxy(
                d.entryRouterImpl,
                owner,
                abi.encodeWithSelector(
                    MarginEntryRouterUpgradeable.initialize.selector,
                    d.executor,
                    d.collateralVault,
                    owner
                )
            );
            d.entryRouter = deployed.proxy;
            d.entryRouterProxyAdmin = deployed.proxyAdmin;
        }

        d.liquidationImpl = address(new AtomicMarginLiquidationUpgradeable());
        {
            ProxyDeployment memory deployed = _deployProxy(
                d.liquidationImpl,
                owner,
                abi.encodeWithSelector(
                    AtomicMarginLiquidationUpgradeable.initialize.selector,
                    d.executor,
                    configSource,
                    owner
                )
            );
            d.liquidation = deployed.proxy;
            d.liquidationProxyAdmin = deployed.proxyAdmin;
        }

        AtomicMarginExecutorUpgradeable(d.executor).setMarginCollateralVault(d.collateralVault);
        AtomicMarginExecutorUpgradeable(d.executor).setEntryRouter(d.entryRouter, true);

        uint256 pTokenCount = _envOrZero("MARGIN_ALLOWED_PTOKEN_COUNT");
        for (uint256 i = 0; i < pTokenCount; i++) {
            address pToken = vm.envAddress(string.concat("MARGIN_ALLOWED_PTOKEN_", vm.toString(i)));
            MarginCollateralVaultUpgradeable(d.collateralVault).setPTokenAllowed(pToken, true);
        }

        uint256 flashTokenCount = _envOrZero("FLASH_VAULT_ALLOWED_TOKEN_COUNT");
        uint256 flashFeeBps = _envOrDefault("FLASH_VAULT_FEE_BPS", 5);
        SimpleFlashLoanVaultUpgradeable(d.flashLoanVault).setFeeBps(flashFeeBps);
        for (uint256 i = 0; i < flashTokenCount; i++) {
            address token = vm.envAddress(string.concat("FLASH_VAULT_ALLOWED_TOKEN_", vm.toString(i)));
            SimpleFlashLoanVaultUpgradeable(d.flashLoanVault).setTokenAllowed(token, true);
        }

        MarginCollateralVaultUpgradeable(d.collateralVault).setRouterAllowed(d.entryRouter, true);

        vm.stopBroadcast();

        console.log("FlashLoanVault impl:", d.flashLoanVaultImpl);
        console.log("FlashLoanVault proxy:", d.flashLoanVault);
        console.log("FlashLoanVault proxy admin:", d.flashLoanVaultProxyAdmin);
        console.log("AtomicMarginExecutor impl:", d.executorImpl);
        console.log("AtomicMarginExecutor proxy:", d.executor);
        console.log("AtomicMarginExecutor proxy admin:", d.executorProxyAdmin);
        console.log("MarginCollateralVault impl:", d.collateralVaultImpl);
        console.log("MarginCollateralVault proxy:", d.collateralVault);
        console.log("MarginCollateralVault proxy admin:", d.collateralVaultProxyAdmin);
        console.log("MarginEntryRouter impl:", d.entryRouterImpl);
        console.log("MarginEntryRouter proxy:", d.entryRouter);
        console.log("MarginEntryRouter proxy admin:", d.entryRouterProxyAdmin);
        console.log("AtomicMarginLiquidation impl:", d.liquidationImpl);
        console.log("AtomicMarginLiquidation proxy:", d.liquidation);
        console.log("AtomicMarginLiquidation proxy admin:", d.liquidationProxyAdmin);
    }

    function _envOrZero(string memory key) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 value) {
            return value;
        } catch {
            return 0;
        }
    }

    function _envOrDefault(string memory key, uint256 defaultValue) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 value) {
            return value;
        } catch {
            return defaultValue;
        }
    }

    function _deployProxy(address implementation, address owner, bytes memory initData)
        internal
        returns (ProxyDeployment memory deployed)
    {
        deployed.proxy = address(new PeridotTransparentProxy(implementation, owner, initData));
        deployed.proxyAdmin = address(uint160(uint256(vm.load(
            deployed.proxy,
            0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103
        ))));
        require(deployed.proxyAdmin != address(0), "proxy admin not found");
    }
}

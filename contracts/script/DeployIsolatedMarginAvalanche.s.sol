// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {Peridottroller} from "../contracts/Peridottroller.sol";
import {PToken} from "../contracts/PToken.sol";
import {PeridotTransparentProxy} from "../contracts/proxy/PeridotTransparentProxy.sol";
import {AvalanchePriceOracle} from "../contracts/margin/AvalanchePriceOracle.sol";
import {IsolatedMarginAccountFactory} from "../contracts/margin/IsolatedMarginAccountFactory.sol";
import {IsolatedMarginConfigUpgradeable} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginExecutorUpgradeable} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginLiquidatorUpgradeable} from "../contracts/margin/IsolatedMarginLiquidatorUpgradeable.sol";
import {IsolatedMarginQuoter} from "../contracts/margin/IsolatedMarginQuoter.sol";
import {IsolatedMarginRiskEngineUpgradeable} from "../contracts/margin/IsolatedMarginRiskEngineUpgradeable.sol";
import {IsolatedMarginSwapModule} from "../contracts/margin/IsolatedMarginSwapModule.sol";
import {IsolatedMarginVaultUpgradeable} from "../contracts/margin/IsolatedMarginVaultUpgradeable.sol";
import {MarginFeeDistributorUpgradeable} from "../contracts/margin/MarginFeeDistributorUpgradeable.sol";
import {MarginInsuranceFundUpgradeable} from "../contracts/margin/MarginInsuranceFundUpgradeable.sol";

/**
 * @notice Deploys and wires the isolated-margin stack for Avalanche C-Chain.
 * @dev All addresses are environment-driven; this script deliberately contains no Somnia constants.
 *      Pair risk is queued separately with ConfigureIsolatedMarginPairAvalanche because it is timelocked.
 */
contract DeployIsolatedMarginAvalanche is Script {
    struct Deployment {
        AvalanchePriceOracle oracle;
        MarginInsuranceFundUpgradeable insuranceFund;
        IsolatedMarginConfigUpgradeable config;
        MarginFeeDistributorUpgradeable feeDistributor;
        IsolatedMarginVaultUpgradeable vault;
        IsolatedMarginRiskEngineUpgradeable riskEngine;
        IsolatedMarginQuoter quoter;
        IsolatedMarginSwapModule swapModule;
        IsolatedMarginAccountFactory accountFactory;
        IsolatedMarginExecutorUpgradeable executor;
        IsolatedMarginLiquidatorUpgradeable liquidator;
    }

    function run() external returns (Deployment memory deployed) {
        _requireAvalanche();
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address finalOwner = vm.envAddress("MARGIN_OWNER");
        address treasury = vm.envAddress("MARGIN_TREASURY");
        address controllerAddress = vm.envAddress("PERIDOTTROLLER");
        address routerAdapter = vm.envAddress("MARGIN_ROUTER_ADAPTER");
        address flashLoanProvider = vm.envAddress("MARGIN_FLASH_LENDER");
        uint256 actionDelay = vm.envOr("MARGIN_ACTION_DELAY", uint256(24 hours));

        require(finalOwner != address(0) && treasury != address(0), "DeployMargin: zero governance address");
        require(controllerAddress.code.length > 0, "DeployMargin: controller not contract");
        require(routerAdapter.code.length > 0, "DeployMargin: router adapter not contract");
        require(flashLoanProvider.code.length > 0, "DeployMargin: flash lender not contract");

        vm.startBroadcast(deployerKey);
        deployed.oracle = new AvalanchePriceOracle(deployer);
        deployed.insuranceFund = MarginInsuranceFundUpgradeable(
            _proxy(
                address(new MarginInsuranceFundUpgradeable()),
                finalOwner,
                abi.encodeWithSelector(MarginInsuranceFundUpgradeable.initialize.selector, deployer)
            )
        );
        deployed.config = IsolatedMarginConfigUpgradeable(
            _proxy(
                address(new IsolatedMarginConfigUpgradeable()),
                finalOwner,
                abi.encodeWithSelector(
                    IsolatedMarginConfigUpgradeable.initialize.selector,
                    deployer,
                    actionDelay,
                    routerAdapter,
                    flashLoanProvider,
                    address(deployed.insuranceFund),
                    treasury
                )
            )
        );
        deployed.feeDistributor = MarginFeeDistributorUpgradeable(
            _proxy(
                address(new MarginFeeDistributorUpgradeable()),
                finalOwner,
                abi.encodeWithSelector(
                    MarginFeeDistributorUpgradeable.initialize.selector, deployer, address(deployed.config)
                )
            )
        );
        deployed.vault = IsolatedMarginVaultUpgradeable(
            _proxy(
                address(new IsolatedMarginVaultUpgradeable()),
                finalOwner,
                abi.encodeWithSelector(
                    IsolatedMarginVaultUpgradeable.initialize.selector, deployer, address(deployed.feeDistributor)
                )
            )
        );
        deployed.riskEngine = IsolatedMarginRiskEngineUpgradeable(
            _proxy(
                address(new IsolatedMarginRiskEngineUpgradeable()),
                finalOwner,
                abi.encodeWithSelector(
                    IsolatedMarginRiskEngineUpgradeable.initialize.selector,
                    deployer,
                    address(deployed.config),
                    address(deployed.oracle),
                    controllerAddress
                )
            )
        );
        deployed.quoter = new IsolatedMarginQuoter(address(deployed.config), address(deployed.oracle));
        deployed.swapModule = new IsolatedMarginSwapModule(address(deployed.config), address(deployed.quoter));
        deployed.accountFactory = new IsolatedMarginAccountFactory(deployer);
        deployed.executor = IsolatedMarginExecutorUpgradeable(
            _proxy(
                address(new IsolatedMarginExecutorUpgradeable()),
                finalOwner,
                abi.encodeWithSelector(
                    IsolatedMarginExecutorUpgradeable.initialize.selector,
                    address(deployed.config),
                    address(deployed.riskEngine),
                    address(deployed.vault),
                    address(deployed.feeDistributor),
                    address(deployed.quoter),
                    address(deployed.swapModule),
                    address(deployed.accountFactory)
                )
            )
        );
        deployed.liquidator = IsolatedMarginLiquidatorUpgradeable(
            _proxy(
                address(new IsolatedMarginLiquidatorUpgradeable()),
                finalOwner,
                abi.encodeWithSelector(
                    IsolatedMarginLiquidatorUpgradeable.initialize.selector,
                    address(deployed.executor),
                    address(deployed.config),
                    address(deployed.riskEngine),
                    address(deployed.vault),
                    address(deployed.insuranceFund),
                    address(deployed.quoter),
                    address(deployed.swapModule)
                )
            )
        );

        deployed.accountFactory.setExecutor(address(deployed.executor));
        deployed.riskEngine.setOperators(address(deployed.executor), address(deployed.liquidator));
        deployed.vault.setExecutor(address(deployed.executor));
        deployed.vault.setLiquidator(address(deployed.liquidator));
        deployed.feeDistributor.setVault(address(deployed.vault));
        deployed.feeDistributor.setFeeCollector(address(deployed.vault), true);
        deployed.feeDistributor.setFeeCollector(address(deployed.executor), true);
        deployed.insuranceFund.setLiquidator(address(deployed.liquidator));

        address[] memory pTokens = _configureMarketsAndFeeds(deployed.oracle, deployed.vault);

        bool wireController = vm.envOr("WIRE_CONTROLLER", false);
        if (wireController) {
            require(
                Peridottroller(controllerAddress).admin() == deployer, "DeployMargin: deployer not controller admin"
            );
        }
        if (wireController) {
            require(
                Peridottroller(controllerAddress)._setIsolatedMarginRiskHook(address(deployed.riskEngine)) == 0,
                "DeployMargin: hook wiring failed"
            );
            require(
                Peridottroller(controllerAddress)._setIsolatedMarginRegistrar(address(deployed.riskEngine)) == 0,
                "DeployMargin: registrar wiring failed"
            );
        }
        _validateControllerPrices(controllerAddress, pTokens);

        deployed.oracle.transferOwnership(finalOwner);
        deployed.insuranceFund.transferOwnership(finalOwner);
        deployed.config.transferOwnership(finalOwner);
        deployed.feeDistributor.transferOwnership(finalOwner);
        deployed.vault.transferOwnership(finalOwner);
        deployed.riskEngine.transferOwnership(finalOwner);
        vm.stopBroadcast();

        _log(deployed);
    }

    function _configureMarketsAndFeeds(AvalanchePriceOracle oracle, IsolatedMarginVaultUpgradeable vault)
        internal
        returns (address[] memory pTokens)
    {
        pTokens = vm.envAddress("MARGIN_PTOKENS", ",");
        address[] memory assets = vm.envAddress("MARGIN_ASSETS", ",");
        address[] memory feeds = vm.envAddress("MARGIN_CHAINLINK_FEEDS", ",");
        uint256[] memory maxAges = vm.envUint("MARGIN_FEED_MAX_AGES", ",");
        require(
            pTokens.length > 0 && pTokens.length == assets.length && assets.length == feeds.length
                && feeds.length == maxAges.length,
            "DeployMargin: market array length"
        );
        for (uint256 i = 0; i < pTokens.length; i++) {
            require(maxAges[i] <= type(uint32).max, "DeployMargin: max age overflow");
            oracle.configureFeed(assets[i], feeds[i], uint32(maxAges[i]));
            oracle.registerMarket(pTokens[i], assets[i]);
            vault.setPTokenAllowed(pTokens[i], true);
        }
    }

    function _validateControllerPrices(address controllerAddress, address[] memory pTokens) internal view {
        for (uint256 i = 0; i < pTokens.length; i++) {
            require(
                Peridottroller(controllerAddress).oracle().getUnderlyingPrice(PToken(pTokens[i])) > 0,
                "DeployMargin: controller price unavailable"
            );
        }
    }

    function _proxy(address implementation, address proxyAdminOwner, bytes memory data) internal returns (address) {
        return address(new PeridotTransparentProxy(implementation, proxyAdminOwner, data));
    }

    function _requireAvalanche() internal view {
        require(block.chainid == 43_114 || block.chainid == 43_113, "DeployMargin: Avalanche only");
    }

    function _log(Deployment memory d) internal pure {
        console2.log("AvalanchePriceOracle", address(d.oracle));
        console2.log("MarginInsuranceFund", address(d.insuranceFund));
        console2.log("IsolatedMarginConfig", address(d.config));
        console2.log("MarginFeeDistributor", address(d.feeDistributor));
        console2.log("IsolatedMarginVault", address(d.vault));
        console2.log("IsolatedMarginRiskEngine", address(d.riskEngine));
        console2.log("IsolatedMarginQuoter", address(d.quoter));
        console2.log("IsolatedMarginSwapModule", address(d.swapModule));
        console2.log("IsolatedMarginAccountFactory", address(d.accountFactory));
        console2.log("IsolatedMarginExecutor", address(d.executor));
        console2.log("IsolatedMarginLiquidator", address(d.liquidator));
        console2.log("Margin opens start paused; wire controller and adapter, then timelock-unpause");
    }
}

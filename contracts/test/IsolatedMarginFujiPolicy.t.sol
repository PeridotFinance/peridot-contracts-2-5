// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IsolatedMarginConfigUpgradeable} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginMath} from "../contracts/margin/IsolatedMarginMath.sol";
import {IsolatedMarginTypes} from "../contracts/margin/IsolatedMarginTypes.sol";
import {ConfigureIsolatedMarginPairAvalanche} from "../script/ConfigureIsolatedMarginPairAvalanche.s.sol";
import {ConfigureLFJLBRouterAdapterAvalanche} from "../script/ConfigureLFJLBRouterAdapterAvalanche.s.sol";
import {DeployIsolatedMarginAvalanche} from "../script/DeployIsolatedMarginAvalanche.s.sol";
import {DeployLFJLBRouterAdapterAvalanche} from "../script/DeployLFJLBRouterAdapterAvalanche.s.sol";
import {DeploySimpleFlashLoanVaultAvalanche} from "../script/DeploySimpleFlashLoanVaultAvalanche.s.sol";
import {FundSimpleFlashLoanVaultAvalanche} from "../script/FundSimpleFlashLoanVaultAvalanche.s.sol";

contract FujiPolicyCode {}

contract FujiPolicyMarket {
    address public immutable underlying;
    address public immutable peridottroller;
    mapping(address account => uint256) public balanceOf;

    constructor(address underlying_, address peridottroller_) {
        underlying = underlying_;
        peridottroller = peridottroller_;
    }

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }
}

contract FujiPolicyOracle {
    mapping(address pToken => address asset) public marketAsset;
    mapping(address asset => uint256 price) public prices;

    function setMarket(address pToken, address asset, uint256 price) external {
        marketAsset[pToken] = asset;
        prices[asset] = price;
    }

    function getPrice(address asset) external view returns (uint256) {
        return prices[asset];
    }
}

contract FujiPolicyLender {
    uint256 public liquidity;

    function setLiquidity(uint256 liquidity_) external {
        liquidity = liquidity_;
    }

    function maxFlashLoan(address) external view returns (uint256) {
        return liquidity;
    }
}

contract FujiPolicyConfig {
    address public owner;
    bool public opensPaused = true;
    address public routerAdapter;
    address public flashLoanProvider;
    address public insuranceFund;
    uint16 public feeImmediateShareBps;
    uint32 public feeStreamDuration = 7 days;

    constructor(address owner_, address routerAdapter_, address flashLoanProvider_, address insuranceFund_) {
        owner = owner_;
        routerAdapter = routerAdapter_;
        flashLoanProvider = flashLoanProvider_;
        insuranceFund = insuranceFund_;
    }
}

contract FujiPolicyRiskEngine {
    address public config;
    address public controller;
    address public oracle;

    constructor(address config_, address controller_, address oracle_) {
        config = config_;
        controller = controller_;
        oracle = oracle_;
    }
}

contract ConfigureIsolatedMarginPairAvalancheHarness is ConfigureIsolatedMarginPairAvalanche {
    function validatePairMarkets(address marginPToken, address positionPToken, address debtPToken)
        external
        view
        returns (address)
    {
        return _validatePairMarkets(marginPToken, positionPToken, debtPToken);
    }

    function requireFujiUnpauseGates(
        address config,
        address marginPToken,
        address positionPToken,
        address debtPToken,
        address pairController
    ) external view {
        _requireFujiUnpauseGates(
            IsolatedMarginConfigUpgradeable(config), marginPToken, positionPToken, debtPToken, pairController
        );
    }
}

contract IsolatedMarginFujiPolicyTest is Test {
    ConfigureIsolatedMarginPairAvalancheHarness internal configureScript;
    DeployIsolatedMarginAvalanche internal deployScript;
    ConfigureLFJLBRouterAdapterAvalanche internal configureAdapterScript;
    DeployLFJLBRouterAdapterAvalanche internal deployAdapterScript;
    DeploySimpleFlashLoanVaultAvalanche internal deployFlashVaultScript;
    FundSimpleFlashLoanVaultAvalanche internal fundFlashVaultScript;

    FujiPolicyCode internal controller;
    FujiPolicyCode internal otherController;
    FujiPolicyCode internal usd;
    FujiPolicyCode internal avax;
    FujiPolicyCode internal otherAsset;
    FujiPolicyMarket internal pUsd;
    FujiPolicyMarket internal pAvax;
    FujiPolicyMarket internal pOther;

    function setUp() public {
        configureScript = new ConfigureIsolatedMarginPairAvalancheHarness();
        deployScript = new DeployIsolatedMarginAvalanche();
        configureAdapterScript = new ConfigureLFJLBRouterAdapterAvalanche();
        deployAdapterScript = new DeployLFJLBRouterAdapterAvalanche();
        deployFlashVaultScript = new DeploySimpleFlashLoanVaultAvalanche();
        fundFlashVaultScript = new FundSimpleFlashLoanVaultAvalanche();

        controller = new FujiPolicyCode();
        otherController = new FujiPolicyCode();
        usd = new FujiPolicyCode();
        avax = new FujiPolicyCode();
        otherAsset = new FujiPolicyCode();
        pUsd = new FujiPolicyMarket(address(usd), address(controller));
        pAvax = new FujiPolicyMarket(address(avax), address(controller));
        pOther = new FujiPolicyMarket(address(otherAsset), address(controller));
    }

    function testFujiDefaultsAreConservativeFiniteAndInternallyValid() public view {
        IsolatedMarginTypes.PairRiskConfig memory risk = configureScript.fujiRiskDefaults();
        IsolatedMarginMath.validateRiskConfig(risk);

        assertEq(risk.maxLeverageX100, 200);
        assertEq(risk.initialMarginBps, 5_000);
        assertEq(risk.maintenanceMarginBps, 3_500);
        assertEq(risk.maxPositionValueUsd, 10_000e18);
        assertEq(risk.maxDebtValueUsd, 5_000e18);
        assertLt(risk.maxDebtValueUsd, risk.maxPositionValueUsd);
    }

    function testFujiMaximumLeverageStartsAboveLiquidationThreshold() public view {
        IsolatedMarginTypes.PairRiskConfig memory risk = configureScript.fujiRiskDefaults();
        IsolatedMarginTypes.AccountMetrics memory metrics = IsolatedMarginMath.calculateMetrics(
            risk.maxPositionValueUsd, risk.maxDebtValueUsd, risk.initialMarginBps, risk.maintenanceMarginBps
        );

        assertEq(metrics.leverageX100, risk.maxLeverageX100);
        assertEq(metrics.equityUsd, int256(uint256(metrics.initialRequirementUsd)));
        assertGt(metrics.healthFactorBps, 10_000);
        assertFalse(IsolatedMarginMath.isLiquidatable(metrics));
    }

    function testFujiRiskRequiresFiniteCaps() public {
        IsolatedMarginTypes.PairRiskConfig memory risk = configureScript.fujiRiskDefaults();
        risk.maxDebtValueUsd = 0;

        vm.expectRevert(bytes("ConfigureMargin: finite caps required"));
        configureScript.validateFujiRiskConfig(risk);
    }

    function testRiskEnvironmentRejectsUint16Truncation() public {
        uint256 overflowingLeverage = uint256(type(uint16).max) + 1;
        vm.setEnv("MAX_LEVERAGE_X100", vm.toString(overflowingLeverage));

        vm.expectRevert(
            abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 16, overflowingLeverage)
        );
        configureScript.riskFromEnvironment();

        vm.setEnv("MAX_LEVERAGE_X100", "200");
    }

    function testPairValidationAcceptsLongAndShortMarketShapes() public view {
        assertEq(configureScript.validatePairMarkets(address(pUsd), address(pAvax), address(pUsd)), address(controller));
        assertEq(
            configureScript.validatePairMarkets(address(pAvax), address(pAvax), address(pUsd)), address(controller)
        );
    }

    function testPairValidationRejectsUnrelatedMarginAsset() public {
        vm.expectRevert(bytes("ConfigureMargin: margin asset must match one side"));
        configureScript.validatePairMarkets(address(pOther), address(pAvax), address(pUsd));
    }

    function testPairValidationRejectsMixedControllers() public {
        FujiPolicyMarket wrongControllerMarket = new FujiPolicyMarket(address(avax), address(otherController));

        vm.expectRevert(bytes("ConfigureMargin: wrong pToken controller"));
        configureScript.validatePairMarkets(address(pUsd), address(wrongControllerMarket), address(pUsd));
    }

    function testFujiUnpauseGateAcceptsFullyFundedLiveConfiguration() public {
        (FujiPolicyConfig config, FujiPolicyRiskEngine riskEngine,,,) = _unpauseFixture();
        _setUnpauseEnvironment(address(riskEngine));

        configureScript.requireFujiUnpauseGates(
            address(config), address(pUsd), address(pAvax), address(pUsd), address(controller)
        );
    }

    function testDeploymentScriptRejectsAvalancheMainnet() public {
        vm.chainId(43_114);
        vm.expectRevert(bytes("DeployMargin: Fuji only"));
        deployScript.run();
    }

    function testConfigurationScriptRejectsAvalancheMainnet() public {
        vm.chainId(43_114);
        vm.expectRevert(bytes("ConfigureMargin: Fuji only"));
        configureScript.run();
    }

    function testAdapterDeploymentScriptRejectsAvalancheMainnet() public {
        vm.chainId(43_114);
        vm.expectRevert(bytes("DeployLFJAdapter: Fuji only"));
        deployAdapterScript.run();
    }

    function testAdapterConfigurationScriptRejectsAvalancheMainnet() public {
        vm.chainId(43_114);
        vm.expectRevert(bytes("ConfigureLFJAdapter: Fuji only"));
        configureAdapterScript.run();
    }

    function testFlashVaultDeploymentScriptRejectsAvalancheMainnet() public {
        vm.chainId(43_114);
        vm.expectRevert(bytes("DeployFlashVault: Fuji only"));
        deployFlashVaultScript.run();
    }

    function testFlashVaultFundingScriptRejectsAvalancheMainnet() public {
        vm.chainId(43_114);
        vm.expectRevert(bytes("FundFlashVault: Fuji only"));
        fundFlashVaultScript.run();
    }

    function _unpauseFixture()
        private
        returns (
            FujiPolicyConfig config,
            FujiPolicyRiskEngine riskEngine,
            FujiPolicyOracle oracle,
            FujiPolicyLender lender,
            FujiPolicyCode insurance
        )
    {
        FujiPolicyCode router = new FujiPolicyCode();
        insurance = new FujiPolicyCode();
        lender = new FujiPolicyLender();
        lender.setLiquidity(1_000e18);
        oracle = new FujiPolicyOracle();
        oracle.setMarket(address(pUsd), address(usd), 1e18);
        oracle.setMarket(address(pAvax), address(avax), 20e18);
        config = new FujiPolicyConfig(address(this), address(router), address(lender), address(insurance));
        riskEngine = new FujiPolicyRiskEngine(address(config), address(controller), address(oracle));
        pUsd.setBalance(address(insurance), 100e18);
    }

    function _setUnpauseEnvironment(address riskEngine) private {
        vm.setEnv("CONFIRM_ALL_FUJI_PAIRS_CONFIGURED", "true");
        vm.setEnv("CONFIRM_FUJI_ROUTE_TESTED", "true");
        vm.setEnv("CONFIRM_FUJI_ORACLES", "true");
        vm.setEnv("CONFIRM_FUJI_LIFECYCLE_TESTS", "true");
        vm.setEnv("CONFIRM_FUJI_LIQUIDATION_TESTED", "true");
        vm.setEnv("ISOLATED_MARGIN_RISK_ENGINE", vm.toString(riskEngine));
        vm.setEnv("MIN_INSURANCE_PTOKEN_BALANCE", "100000000000000000000");
        vm.setEnv("MIN_FLASH_LIQUIDITY_UNDERLYING", "1000000000000000000000");
    }
}

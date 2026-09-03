// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ConfigurableJumpRateModelV2} from "../contracts/ConfigurableJumpRateModelV2.sol";
import {InterestRateModel} from "../contracts/InterestRateModel.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {PErc20Delegate} from "../contracts/PErc20Delegate.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {Peridottroller} from "../contracts/Peridottroller.sol";
import {PeridottrollerAvalancheFuji} from "../contracts/PeridottrollerAvalancheFuji.sol";
import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";
import {Unitroller} from "../contracts/Unitroller.sol";
import {Peridot} from "../contracts/Governance/Peridot.sol";
import {AvalancheFujiMarketBootstrapper} from "../contracts/deployment/AvalancheFujiMarketBootstrapper.sol";
import {IsolatedMarginRiskEngineUpgradeable} from "../contracts/margin/IsolatedMarginRiskEngineUpgradeable.sol";
import {LFJLBRouterAdapter} from "../contracts/margin/LFJLBRouterAdapter.sol";
import {SimpleFlashLoanVault} from "../contracts/margin/SimpleFlashLoanVault.sol";
import {DeployAvalancheFujiLendingMarkets} from "../script/DeployAvalancheFujiLendingMarkets.s.sol";
import {DeployIsolatedMarginAvalanche} from "../script/DeployIsolatedMarginAvalanche.s.sol";
import {ActivateAvalancheFujiMarginMarkets} from "../script/ActivateAvalancheFujiMarginMarkets.s.sol";
import {MockErc20} from "./MockErc20.sol";

contract ConfigurableJumpRateModelV2Test is Test {
    uint256 private constant BLOCKS_PER_YEAR = 31_536_000;

    ConfigurableJumpRateModelV2 private model;

    function setUp() public {
        model = new ConfigurableJumpRateModelV2(BLOCKS_PER_YEAR, 0.02e18, 0.1e18, 1e18, 0.8e18, address(this));
    }

    function testAnnualizedBorrowCurveMatchesConfiguredRates() public view {
        uint256 zeroUtilizationRate = model.getBorrowRate(100e18, 0, 0) * BLOCKS_PER_YEAR;
        uint256 kinkRate = model.getBorrowRate(20e18, 80e18, 0) * BLOCKS_PER_YEAR;
        uint256 fullUtilizationRate = model.getBorrowRate(0, 100e18, 0) * BLOCKS_PER_YEAR;

        assertApproxEqAbs(zeroUtilizationRate, 0.02e18, BLOCKS_PER_YEAR);
        assertApproxEqAbs(kinkRate, 0.12e18, BLOCKS_PER_YEAR * 3);
        assertApproxEqAbs(fullUtilizationRate, 0.32e18, BLOCKS_PER_YEAR * 3);
    }

    function testAnnualizedSupplyRateIncludesUtilizationAndReserves() public view {
        uint256 annualSupplyRate = model.getSupplyRate(20e18, 80e18, 0, 0.1e18) * BLOCKS_PER_YEAR;
        assertApproxEqAbs(annualSupplyRate, 0.0864e18, BLOCKS_PER_YEAR * 3);
    }

    function testRejectsUnsafeConfiguration() public {
        vm.expectRevert("RateModel: blocks per year");
        new ConfigurableJumpRateModelV2(999_999, 0.02e18, 0.1e18, 1e18, 0.8e18, address(this));

        vm.expectRevert("RateModel: invalid kink");
        new ConfigurableJumpRateModelV2(BLOCKS_PER_YEAR, 0.02e18, 0.1e18, 1e18, 0, address(this));

        vm.expectRevert("RateModel: annual rate too high");
        model.updateJumpRateModel(11e18, 0.1e18, 1e18, 0.8e18);
    }

    function testOnlyOwnerCanUpdateCurve() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        model.updateJumpRateModel(0.01e18, 0.08e18, 0.8e18, 0.75e18);
    }
}

contract AvalancheFujiMarketBootstrapperTest is Test {
    uint256 private constant FUJI_CHAIN_ID = 43_113;
    uint256 private constant WAVAX_SEED = 10e18;
    uint256 private constant USDC_SEED = 10_000e6;
    uint256 private constant WAVAX_BORROW_CAP = 100e18;
    uint256 private constant USDC_BORROW_CAP = 100_000e6;

    MockErc20 private wavax;
    MockErc20 private usdc;
    Peridot private peridot;
    Unitroller private unitroller;
    Peridottroller private controller;
    ConfigurableJumpRateModelV2 private rateModel;
    AvalancheFujiMarketBootstrapper private bootstrapper;
    PErc20Delegate private delegate;
    PErc20Delegator private pWavax;
    PErc20Delegator private pUsdc;

    function setUp() public {
        vm.chainId(FUJI_CHAIN_ID);
        wavax = new MockErc20("Wrapped AVAX", "WAVAX", 18);
        usdc = new MockErc20("USD Coin", "USDC", 6);
        peridot = new Peridot(address(this));
        unitroller = new Unitroller();
        PeridottrollerAvalancheFuji implementation = new PeridottrollerAvalancheFuji(address(peridot));
        assertEq(unitroller._setPendingImplementation(address(implementation)), 0);
        implementation._become(unitroller);
        controller = Peridottroller(address(unitroller));

        rateModel = new ConfigurableJumpRateModelV2(31_536_000, 0.02e18, 0.1e18, 1e18, 0.8e18, address(this));
        delegate = new PErc20Delegate();
        bootstrapper = new AvalancheFujiMarketBootstrapper(
            address(this), address(controller), address(rateModel), address(delegate), address(wavax), address(usdc)
        );
        pWavax = new PErc20Delegator(
            address(wavax),
            PeridottrollerInterface(address(controller)),
            InterestRateModel(address(rateModel)),
            2e26,
            "Peridot Wrapped AVAX",
            "pWAVAX",
            8,
            payable(address(bootstrapper)),
            address(delegate),
            ""
        );
        pUsdc = new PErc20Delegator(
            address(usdc),
            PeridottrollerInterface(address(controller)),
            InterestRateModel(address(rateModel)),
            2e14,
            "Peridot LFJ USD Coin",
            "pUSDC",
            8,
            payable(address(bootstrapper)),
            address(delegate),
            ""
        );
        assertEq(unitroller._setPendingAdmin(address(bootstrapper)), 0);

        wavax.mint(address(this), WAVAX_SEED);
        usdc.mint(address(this), USDC_SEED);
        wavax.approve(address(bootstrapper), WAVAX_SEED);
        usdc.approve(address(bootstrapper), USDC_SEED);
    }

    function testAtomicallyListsSeedsAndPausesMarkets() public {
        _bootstrap();

        assertTrue(bootstrapper.used());
        assertEq(unitroller.pendingAdmin(), address(this));
        assertEq(pWavax.pendingAdmin(), address(this));
        assertEq(pUsdc.pendingAdmin(), address(this));
        assertEq(unitroller._acceptAdmin(), 0);
        assertEq(pWavax._acceptAdmin(), 0);
        assertEq(pUsdc._acceptAdmin(), 0);

        assertEq(unitroller.admin(), address(this));
        assertEq(pWavax.admin(), address(this));
        assertEq(pUsdc.admin(), address(this));
        assertEq(controller.getPeridotAddress(), address(peridot));
        assertEq(PErc20(address(pWavax)).underlying(), address(wavax));
        assertEq(PErc20(address(pUsdc)).underlying(), address(usdc));
        assertEq(PErc20(address(pWavax)).getCash(), WAVAX_SEED);
        assertEq(PErc20(address(pUsdc)).getCash(), USDC_SEED);
        assertGt(pWavax.balanceOf(address(this)), 0);
        assertGt(pUsdc.balanceOf(address(this)), 0);

        (bool wavaxListed, uint256 wavaxCollateralFactor,) = controller.markets(address(pWavax));
        (bool usdcListed, uint256 usdcCollateralFactor,) = controller.markets(address(pUsdc));
        assertTrue(wavaxListed && usdcListed);
        assertEq(wavaxCollateralFactor, 0);
        assertEq(usdcCollateralFactor, 0);
        assertTrue(controller.borrowGuardianPaused(address(pWavax)));
        assertTrue(controller.borrowGuardianPaused(address(pUsdc)));
        assertEq(controller.borrowCaps(address(pWavax)), WAVAX_BORROW_CAP);
        assertEq(controller.borrowCaps(address(pUsdc)), USDC_BORROW_CAP);
        assertEq(pWavax.reserveFactorMantissa(), 0.1e18);
        assertEq(pUsdc.reserveFactorMantissa(), 0.1e18);
        assertTrue(pWavax.flashLoansPaused());
        assertTrue(pUsdc.flashLoansPaused());
    }

    function testBootstrapIsSingleUse() public {
        _bootstrap();

        vm.expectRevert("FujiBootstrap: already used");
        _bootstrap();
    }

    function testRejectsBorrowCapAtOrBelowSeed() public {
        vm.expectRevert("FujiBootstrap: cap not above seed");
        bootstrapper.bootstrap(
            address(pWavax), address(pUsdc), WAVAX_SEED, USDC_SEED, WAVAX_SEED, USDC_BORROW_CAP, 0.1e18
        );
    }

    function testDonationMakesBootstrapRevertWithoutListingMarket() public {
        assertTrue(wavax.transfer(address(pWavax), 1));

        vm.expectRevert("FujiBootstrap: market touched");
        _bootstrap();

        (bool listed,,) = controller.markets(address(pWavax));
        assertFalse(listed);
        assertEq(unitroller.admin(), address(this));
    }

    function _bootstrap() private {
        bootstrapper.bootstrap(
            address(pWavax), address(pUsdc), WAVAX_SEED, USDC_SEED, WAVAX_BORROW_CAP, USDC_BORROW_CAP, 0.1e18
        );
    }
}

contract AvalancheFujiDeploymentChainGateTest is Test {
    function testFujiControllerRejectsAvalancheMainnet() public {
        Peridot peridot = new Peridot(address(this));
        vm.chainId(43_114);
        vm.expectRevert("FujiController: Fuji only");
        new PeridottrollerAvalancheFuji(address(peridot));
    }

    function testLendingDeploymentScriptRejectsAvalancheMainnet() public {
        vm.chainId(43_114);
        DeployAvalancheFujiLendingMarkets script = new DeployAvalancheFujiLendingMarkets();
        vm.expectRevert("DeployFujiLending: Fuji only");
        script.run();
    }

    function testActivationScriptRejectsAvalancheMainnet() public {
        vm.chainId(43_114);
        ActivateAvalancheFujiMarginMarkets script = new ActivateAvalancheFujiMarginMarkets();
        vm.expectRevert("ActivateFujiMarkets: Fuji only");
        script.run();
    }
}

contract AvalancheFujiLendingDeploymentForkTest is Test {
    address private constant FUJI_LFJ_ROUTER = 0x18556DA13313f3532c54711497A8FedAC273220E;
    address private constant FUJI_WAVAX = 0xd00ae08403B9bbb9124bB305C09058E32C39A48c;
    address private constant FUJI_LFJ_USDC = 0xB6076C93701D6a07266c31066B298AeC6dd65c2d;
    address private constant FUJI_AVAX_USD_FEED = 0x5498BB86BC934c8D34FDA08E81D444153d0D06aD;
    address private constant FUJI_USDC_USD_FEED = 0x97FE42a7E96640D932bbc0e1580c73E705A8EB73;

    function testDeploysFreshPausedLendingBaseAgainstLiveFujiContracts() public {
        string memory rpcUrl = vm.envOr("AVALANCHE_FUJI_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;
        vm.createSelectFork(rpcUrl);

        uint256 wavaxSeed = 10e18;
        uint256 usdcSeed = 10_000e6;
        uint256 wavaxBorrowCap = 100e18;
        uint256 usdcBorrowCap = 100_000e6;
        deal(FUJI_WAVAX, address(this), wavaxSeed);
        deal(FUJI_LFJ_USDC, address(this), usdcSeed);

        string memory deployer = vm.toString(address(this));
        vm.setEnv("MARGIN_DEPLOYER", deployer);
        vm.setEnv("MARGIN_OWNER", deployer);
        vm.setEnv("LENDING_WAVAX_SEED_AMOUNT", vm.toString(wavaxSeed));
        vm.setEnv("LENDING_USDC_SEED_AMOUNT", vm.toString(usdcSeed));
        vm.setEnv("LENDING_WAVAX_BORROW_CAP", vm.toString(wavaxBorrowCap));
        vm.setEnv("LENDING_USDC_BORROW_CAP", vm.toString(usdcBorrowCap));

        DeployAvalancheFujiLendingMarkets.Deployment memory deployed = new DeployAvalancheFujiLendingMarkets().run();

        assertEq(address(deployed.controller.oracle()), address(deployed.oracle));
        assertEq(deployed.unitroller.admin(), address(this));
        assertEq(deployed.pWavax.admin(), address(this));
        assertEq(deployed.pUsdc.admin(), address(this));
        assertEq(PErc20(address(deployed.pWavax)).getCash(), wavaxSeed);
        assertEq(PErc20(address(deployed.pUsdc)).getCash(), usdcSeed);
        assertTrue(deployed.controller.borrowGuardianPaused(address(deployed.pWavax)));
        assertTrue(deployed.controller.borrowGuardianPaused(address(deployed.pUsdc)));
        assertTrue(deployed.pWavax.flashLoansPaused());
        assertTrue(deployed.pUsdc.flashLoansPaused());

        LFJLBRouterAdapter adapter = new LFJLBRouterAdapter(address(this), FUJI_LFJ_ROUTER, 1 hours);
        SimpleFlashLoanVault flashVault = new SimpleFlashLoanVault(address(this));
        _setMarginDeploymentEnvironment(deployed, address(adapter), address(flashVault));
        DeployIsolatedMarginAvalanche.Deployment memory margin = new DeployIsolatedMarginAvalanche().run();

        vm.setEnv("ISOLATED_MARGIN_RISK_ENGINE", vm.toString(address(margin.riskEngine)));
        vm.setEnv("ACTIVATE_FUJI_MARGIN_BORROWS", "true");
        new ActivateAvalancheFujiMarginMarkets().run();

        assertEq(deployed.controller.isolatedMarginRiskHook(), address(margin.riskEngine));
        assertEq(deployed.controller.isolatedMarginRegistrar(), address(margin.riskEngine));
        assertFalse(deployed.controller.borrowGuardianPaused(address(deployed.pWavax)));
        assertFalse(deployed.controller.borrowGuardianPaused(address(deployed.pUsdc)));
        (, uint256 wavaxCollateralFactor,) = deployed.controller.markets(address(deployed.pWavax));
        (, uint256 usdcCollateralFactor,) = deployed.controller.markets(address(deployed.pUsdc));
        assertEq(wavaxCollateralFactor, 0);
        assertEq(usdcCollateralFactor, 0);
        assertTrue(IsolatedMarginRiskEngineUpgradeable(address(margin.riskEngine)).config().opensPaused());
    }

    function _setMarginDeploymentEnvironment(
        DeployAvalancheFujiLendingMarkets.Deployment memory deployed,
        address adapter,
        address flashVault
    ) private {
        vm.setEnv("MARGIN_TREASURY", vm.toString(address(this)));
        vm.setEnv("PERIDOTTROLLER", vm.toString(address(deployed.controller)));
        vm.setEnv("PWAVAX", vm.toString(address(deployed.pWavax)));
        vm.setEnv("PUSDC", vm.toString(address(deployed.pUsdc)));
        vm.setEnv("MARGIN_ROUTER_ADAPTER", vm.toString(adapter));
        vm.setEnv("MARGIN_FLASH_LENDER", vm.toString(flashVault));
        vm.setEnv(
            "MARGIN_PTOKENS",
            string.concat(vm.toString(address(deployed.pWavax)), ",", vm.toString(address(deployed.pUsdc)))
        );
        vm.setEnv("MARGIN_ASSETS", string.concat(vm.toString(FUJI_WAVAX), ",", vm.toString(FUJI_LFJ_USDC)));
        vm.setEnv(
            "MARGIN_CHAINLINK_FEEDS",
            string.concat(vm.toString(FUJI_AVAX_USD_FEED), ",", vm.toString(FUJI_USDC_USD_FEED))
        );
        vm.setEnv("MARGIN_FEED_MAX_AGES", "1200,90000");
        vm.setEnv("WIRE_CONTROLLER", "true");
    }
}

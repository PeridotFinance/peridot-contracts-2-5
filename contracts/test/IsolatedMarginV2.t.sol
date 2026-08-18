// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {Peridottroller} from "../contracts/Peridottroller.sol";
import {Unitroller} from "../contracts/Unitroller.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {PToken} from "../contracts/PToken.sol";
import {InterestRateModel} from "../contracts/InterestRateModel.sol";
import {MockErc20} from "./MockErc20.sol";
import {PeridotTransparentProxy} from "../contracts/proxy/PeridotTransparentProxy.sol";
import {IMarginRouterAdapter} from "../contracts/margin/IMarginRouterAdapter.sol";
import {SimpleFlashLoanVault} from "../contracts/margin/SimpleFlashLoanVault.sol";
import {AvalanchePriceOracle} from "../contracts/margin/AvalanchePriceOracle.sol";
import {IsolatedMarginAccountFactory} from "../contracts/margin/IsolatedMarginAccountFactory.sol";
import {IsolatedMarginConfigUpgradeable} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginExecutorUpgradeable} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginLiquidatorUpgradeable} from "../contracts/margin/IsolatedMarginLiquidatorUpgradeable.sol";
import {IsolatedMarginMath} from "../contracts/margin/IsolatedMarginMath.sol";
import {IsolatedMarginQuoter} from "../contracts/margin/IsolatedMarginQuoter.sol";
import {IsolatedMarginRiskEngineUpgradeable} from "../contracts/margin/IsolatedMarginRiskEngineUpgradeable.sol";
import {IsolatedMarginSwapModule} from "../contracts/margin/IsolatedMarginSwapModule.sol";
import {IsolatedMarginTypes} from "../contracts/margin/IsolatedMarginTypes.sol";
import {IsolatedMarginVaultUpgradeable} from "../contracts/margin/IsolatedMarginVaultUpgradeable.sol";
import {MarginFeeDistributorUpgradeable} from "../contracts/margin/MarginFeeDistributorUpgradeable.sol";
import {MarginInsuranceFundUpgradeable} from "../contracts/margin/MarginInsuranceFundUpgradeable.sol";

contract MarginTestAggregator is AggregatorV3Interface {
    uint8 public immutable override decimals;
    uint80 public roundId = 1;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public answeredInRound = 1;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function description() external pure override returns (string memory) {
        return "margin test feed";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }

    function setAnswer(int256 answer_) external {
        roundId++;
        answer = answer_;
        updatedAt = block.timestamp;
        answeredInRound = roundId;
    }

    function setRound(int256 answer_, uint256 updatedAt_, uint80 answeredInRound_) external {
        roundId++;
        answer = answer_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }
}

    contract OracleTestMarket {
        address public immutable underlying;

        constructor(address underlying_) {
            underlying = underlying_;
        }
    }

    contract IsolatedTestPErc20 is PErc20 {
        constructor() {
            admin = payable(msg.sender);
        }
    }

    contract MutableMarginInterestRateModel is InterestRateModel {
        uint256 public borrowRate;

        function setBorrowRate(uint256 borrowRate_) external {
            borrowRate = borrowRate_;
        }

        function getBorrowRate(uint256, uint256, uint256) external view override returns (uint256) {
            return borrowRate;
        }

        function getSupplyRate(uint256, uint256, uint256, uint256) external pure override returns (uint256) {
            return 0;
        }
    }

    contract MarginRateRouterAdapter is IMarginRouterAdapter {
        using SafeERC20 for IERC20;

        mapping(address tokenIn => mapping(address tokenOut => uint256 rateWad)) public rates;

        function setRate(address tokenIn, address tokenOut, uint256 rateWad) external {
            rates[tokenIn][tokenOut] = rateWad;
        }

        function swap(
            address fromAccount,
            address tokenIn,
            address tokenOut,
            uint256 amountIn,
            uint256 minAmountOut,
            bytes calldata
        ) external returns (uint256 amountOut) {
            uint256 rate = rates[tokenIn][tokenOut];
            require(rate > 0, "RateRouter: missing rate");
            amountOut = amountIn * rate / 1e18;
            require(amountOut >= minAmountOut, "RateRouter: min output");
            IERC20(tokenIn).safeTransferFrom(fromAccount, address(this), amountIn);
            IERC20(tokenOut).safeTransfer(fromAccount, amountOut);
        }
    }

    contract AvalanchePriceOracleTest is Test {
        AvalanchePriceOracle internal oracle;

        function setUp() public {
            vm.warp(1_000_000);
            oracle = new AvalanchePriceOracle(address(this));
        }

        function testScalesSixEightAndEighteenDecimalAssetsForController() public {
            _assertScale(6, 8, 1e8, 1e18, 1e30);
            _assertScale(8, 18, 25e17, 25e17, 25e27);
            _assertScale(18, 8, 2_000e8, 2_000e18, 2_000e18);
        }

        function testOracleFailsClosedOnStaleOrIncompleteRoundsAndAllowsShortEmergencyPrice() public {
            MockErc20 asset = new MockErc20("USD", "USD", 6);
            OracleTestMarket market = new OracleTestMarket(address(asset));
            MarginTestAggregator feed = new MarginTestAggregator(8, 1e8);
            oracle.configureFeed(address(asset), address(feed), 1 hours);
            oracle.registerMarket(address(market), address(asset));

            feed.setRound(1e8, block.timestamp - 1 hours - 1, feed.roundId() + 1);
            assertEq(oracle.getPrice(address(asset)), 0, "stale feed must fail closed");

            oracle.setEmergencyPrice(address(asset), 11e17, uint64(block.timestamp + 30 minutes));
            assertEq(oracle.getPrice(address(asset)), 11e17, "emergency price not used");

            vm.warp(block.timestamp + 31 minutes);
            assertEq(oracle.getPrice(address(asset)), 0, "expired emergency price still active");

            feed.setRound(1e8, block.timestamp, feed.roundId() - 1);
            assertEq(oracle.getPrice(address(asset)), 0, "incomplete round must fail closed");
        }

        function testFiveXMarginMathUsesEquityAndMaintenanceMargin() public pure {
            IsolatedMarginTypes.AccountMetrics memory metrics =
                IsolatedMarginMath.calculateMetrics(500e18, 400e18, 2_000, 1_000);
            assertEq(metrics.leverageX100, 500);
            assertEq(metrics.healthFactorBps, 20_000);
            assertEq(metrics.initialRequirementUsd, 100e18);
            assertEq(metrics.maintenanceRequirementUsd, 50e18);
        }

        function testRiskConfigRejectsLeverageAboveFiveX() public {
            IsolatedMarginTypes.PairRiskConfig memory risk = IsolatedMarginTypes.PairRiskConfig({
                enabled: true,
                maxLeverageX100: 501,
                initialMarginBps: 2_000,
                maintenanceMarginBps: 1_000,
                liquidationTargetBps: 12_500,
                fullLiquidationHealthBps: 5_000,
                maxLiquidationBps: 5_000,
                liquidationBonusBps: 500,
                maxSlippageBps: 100,
                oracleDeviationBps: 100,
                maxPositionValueUsd: 0,
                maxDebtValueUsd: 0
            });
            vm.expectRevert(IsolatedMarginMath.InvalidRiskParameters.selector);
            this.validateRiskConfig(risk);
        }

        function validateRiskConfig(IsolatedMarginTypes.PairRiskConfig calldata risk) external pure {
            IsolatedMarginMath.validateRiskConfig(risk);
        }

        function _assertScale(
            uint8 assetDecimals,
            uint8 feedDecimals,
            int256 feedAnswer,
            uint256 expectedMarginPrice,
            uint256 expectedControllerPrice
        ) internal {
            MockErc20 asset = new MockErc20("Asset", "AST", assetDecimals);
            OracleTestMarket market = new OracleTestMarket(address(asset));
            MarginTestAggregator feed = new MarginTestAggregator(feedDecimals, feedAnswer);
            oracle.configureFeed(address(asset), address(feed), 1 days);
            oracle.registerMarket(address(market), address(asset));
            assertEq(oracle.getPrice(address(asset)), expectedMarginPrice);
            assertEq(oracle.getUnderlyingPrice(PToken(address(market))), expectedControllerPrice);
        }
    }

    contract IsolatedMarginV2IntegrationTest is Test {
        uint256 internal constant BPS = 10_000;
        address internal constant USER = address(0xA11CE);
        address internal constant NORMAL_USER = address(0xB0B);
        address internal constant LIQUIDATION_RECIPIENT = address(0x1EE7);
        address internal constant TREASURY = address(0x7EA5);

        MockErc20 internal usd;
        MockErc20 internal avax;
        PErc20 internal pUsd;
        PErc20 internal pAvax;
        MutableMarginInterestRateModel internal interestRateModel;
        Unitroller internal unitroller;
        Peridottroller internal controller;
        AvalanchePriceOracle internal oracle;
        MarginTestAggregator internal usdFeed;
        MarginTestAggregator internal avaxFeed;
        MarginRateRouterAdapter internal router;
        SimpleFlashLoanVault internal flashVault;

        IsolatedMarginConfigUpgradeable internal config;
        MarginInsuranceFundUpgradeable internal insuranceFund;
        MarginFeeDistributorUpgradeable internal feeDistributor;
        IsolatedMarginVaultUpgradeable internal marginVault;
        IsolatedMarginRiskEngineUpgradeable internal riskEngine;
        IsolatedMarginQuoter internal quoter;
        IsolatedMarginSwapModule internal swapModule;
        IsolatedMarginExecutorUpgradeable internal executor;
        IsolatedMarginAccountFactory internal accountFactory;
        IsolatedMarginLiquidatorUpgradeable internal liquidator;

        function setUp() public {
            vm.warp(1_000_000);
            _deployLendingMarkets();
            _deployMarginStack();
            _configureMarginStack();
            _seedBalances();
        }

        function testOpensFiveXLongDespiteConventionalCollateralFactor() public {
            uint256 positionId = _openLong(500);
            IsolatedMarginTypes.Position memory position = _position(positionId);
            IsolatedMarginTypes.AccountMetrics memory metrics = riskEngine.getMetrics(position.account);

            assertTrue(controller.isolatedMarginAccounts(position.account), "account not registered in controller");
            assertLe(metrics.leverageX100, 500, "leverage cap exceeded");
            assertGe(metrics.leverageX100, 495, "position did not reach requested leverage");
            assertGe(metrics.healthFactorBps, 19_900, "five-x position starts near liquidation");
            assertGt(pAvax.balanceOf(position.account), 490e18, "position collateral not supplied as pTokens");
            assertGt(pUsd.borrowBalanceStored(position.account), 390e18, "borrow leg missing");

            (, uint256 collateralFactor,) = controller.markets(address(pAvax));
            assertEq(collateralFactor, 1e17, "test must use a low conventional collateral factor");
        }

        function testOpensFiveXShortWithUsdCollateralAndAvaxDebt() public {
            uint256 positionId = _openShort(500);
            IsolatedMarginTypes.Position memory position = _position(positionId);
            IsolatedMarginTypes.AccountMetrics memory metrics = riskEngine.getMetrics(position.account);

            assertEq(position.marginPToken, address(pUsd));
            assertEq(position.positionPToken, address(pUsd));
            assertEq(position.debtPToken, address(pAvax));
            assertLe(metrics.leverageX100, 500);
            assertGe(metrics.leverageX100, 495);
            assertGt(pUsd.balanceOf(position.account), 490e18, "short proceeds are not earning supply APY");
            assertGt(pAvax.borrowBalanceStored(position.account), 390e18, "short debt missing");
        }

        function testLockedSharesRemainVisibleAndPositionPTokensCaptureSupplyYield() public {
            uint256 positionId = _openLong(500);
            IsolatedMarginTypes.Position memory position = _position(positionId);
            uint256 grossBefore = riskEngine.getMetrics(position.account).grossAssetValueUsd;

            assertEq(marginVault.lockedBalance(USER, address(pUsd)), 100e18, "margin ledger changed denomination");
            avax.mint(address(pAvax), 50e18);

            uint256 grossAfter = riskEngine.getMetrics(position.account).grossAssetValueUsd;
            assertGt(grossAfter, grossBefore, "pToken supply yield was not reflected in margin equity");
            assertEq(marginVault.lockedBalance(USER, address(pUsd)), 100e18, "visible pToken shares changed");
        }

        function testFullCloseWorksAfterPairIsDisabledAndReturnsPTokensToVault() public {
            uint256 positionId = _openLong(500);
            IsolatedMarginTypes.Position memory position = _position(positionId);
            config.disablePair(address(pUsd), address(pAvax), address(pUsd));

            IsolatedMarginExecutorUpgradeable.CloseParams memory closeParams = IsolatedMarginExecutorUpgradeable.CloseParams({
                positionId: positionId,
                closeBps: uint16(BPS),
                maxClosingFeePToken: 0,
                minDebtUnderlying: 495e18,
                minMarginUnderlying: 0,
                positionToDebtSwapData: bytes(""),
                debtToMarginSwapData: bytes("")
            });
            vm.prank(USER);
            uint256 returned = executor.closePosition(closeParams);

            position = _position(positionId);
            assertEq(uint256(position.status), uint256(IsolatedMarginTypes.Status.CLOSED));
            assertEq(pUsd.borrowBalanceStored(position.account), 0, "debt remains after full close");
            assertEq(marginVault.lockedBalance(USER, address(pUsd)), 0, "lock not released");
            assertGt(returned, 99e18, "too little margin returned");
            assertGt(marginVault.freeBalance(USER, address(pUsd)), returned, "returned pTokens not credited");
        }

        function testUnderlyingAndPTokenRepaymentThenDebtFreeClose() public {
            uint256 positionId = _openLong(200);
            IsolatedMarginTypes.Position memory position = _position(positionId);
            uint256 debtBefore = pUsd.borrowBalanceStored(position.account);

            usd.mint(USER, 200e18);
            vm.startPrank(USER);
            usd.approve(address(executor), type(uint256).max);
            uint256 underlyingRepaid = executor.repayWithUnderlying(positionId, 20e18);
            pUsd.approve(address(executor), type(uint256).max);
            uint256 pTokenRepaid = executor.repayWithPToken(positionId, 10e18);
            vm.stopPrank();

            assertEq(underlyingRepaid, 20e18);
            assertGt(pTokenRepaid, 9e18);
            assertLt(pUsd.borrowBalanceStored(position.account), debtBefore - 29e18, "repay paths did not reduce debt");

            vm.prank(USER);
            executor.repayWithUnderlying(positionId, type(uint256).max);
            assertEq(pUsd.borrowBalanceStored(position.account), 0, "manual full repayment failed");

            IsolatedMarginExecutorUpgradeable.CloseParams memory closeParams = IsolatedMarginExecutorUpgradeable.CloseParams({
                positionId: positionId,
                closeBps: uint16(BPS),
                maxClosingFeePToken: 0,
                minDebtUnderlying: 0,
                minMarginUnderlying: 0,
                positionToDebtSwapData: bytes(""),
                debtToMarginSwapData: bytes("")
            });
            vm.prank(USER);
            uint256 returned = executor.closePosition(closeParams);
            assertGt(returned, 0, "debt-free close returned no pTokens");
            assertEq(uint256(_position(positionId).status), uint256(IsolatedMarginTypes.Status.CLOSED));
        }

        function testBorrowRateAccruesAsTheOnlyFundingCharge() public {
            uint256 positionId = _openLong(500);
            IsolatedMarginTypes.Position memory position = _position(positionId);
            uint256 debtBefore = pUsd.borrowBalanceStored(position.account);
            uint256 openingFee = config.openFeeBps();

            interestRateModel.setBorrowRate(1e12);
            vm.roll(block.number + 100);
            uint256 debtAfter = pUsd.borrowBalanceCurrent(position.account);

            assertGt(debtAfter, debtBefore, "pToken borrow rate did not accrue");
            assertEq(openingFee, 0, "test unexpectedly enabled a separate funding fee");
            assertEq(marginVault.lockedBalance(USER, address(pUsd)), 100e18, "funding changed pToken share ledger");
        }

        function testConfigurableOpeningFeeIsDistributedInSamePTokenPool() public {
            _setFees(10, 10, 6_000, 3_000, 1_000);
            uint256 insuranceBefore = pUsd.balanceOf(address(insuranceFund));
            uint256 treasuryBefore = pUsd.balanceOf(TREASURY);

            IsolatedMarginExecutorUpgradeable.OpenParams memory params = _longParams(500);
            params.maxOpeningFeePToken = 1e18;
            vm.prank(USER);
            executor.openPosition(params);

            uint256 pending = feeDistributor.pendingRewards(USER, address(pUsd));
            assertApproxEqAbs(pending, 3e17, 2, "depositor share incorrect");
            assertApproxEqAbs(pUsd.balanceOf(address(insuranceFund)) - insuranceBefore, 15e16, 2, "insurance share");
            assertApproxEqAbs(pUsd.balanceOf(TREASURY) - treasuryBefore, 5e16, 2, "treasury share");

            uint256 freeBefore = marginVault.freeBalance(USER, address(pUsd));
            vm.prank(USER);
            marginVault.settle(address(pUsd));
            assertApproxEqAbs(marginVault.freeBalance(USER, address(pUsd)) - freeBefore, pending, 1);
        }

        function testPartialLiquidationUsesMaintenanceMarginAndRestoresTargetHealth() public {
            uint256 positionId = _openLong(500);
            IsolatedMarginTypes.Position memory beforePosition = _position(positionId);
            uint256 debtBefore = pUsd.borrowBalanceStored(beforePosition.account);
            uint256 lockedBefore = beforePosition.lockedMarginPTokens;

            _setAvaxPriceAndRates(88e6);
            assertTrue(riskEngine.isLiquidatable(beforePosition.account), "position should be liquidatable");

            uint256 rewardBefore = usd.balanceOf(LIQUIDATION_RECIPIENT);
            liquidator.liquidate(_liquidationParams(positionId));

            IsolatedMarginTypes.Position memory afterPosition = _position(positionId);
            IsolatedMarginTypes.AccountMetrics memory metrics = riskEngine.getMetrics(afterPosition.account);
            assertEq(uint256(afterPosition.status), uint256(IsolatedMarginTypes.Status.ACTIVE));
            assertLt(pUsd.borrowBalanceStored(afterPosition.account), debtBefore, "debt not reduced");
            assertLt(afterPosition.lockedMarginPTokens, lockedBefore, "locked accounting not written down");
            assertGe(metrics.healthFactorBps, 12_500, "liquidation target not reached");
            assertGt(usd.balanceOf(LIQUIDATION_RECIPIENT), rewardBefore, "liquidator not rewarded");
        }

        function testDeepPartialLiquidationCanProgressInMultipleSteps() public {
            uint256 positionId = _openLong(500);
            IsolatedMarginTypes.Position memory position = _position(positionId);
            _setAvaxPriceAndRates(85e6);
            IsolatedMarginTypes.AccountMetrics memory beforeMetrics = riskEngine.getMetrics(position.account);
            assertTrue(riskEngine.isLiquidatable(position.account), "position should be liquidatable");
            assertGt(beforeMetrics.healthFactorBps, 5_000, "test should use partial liquidation");

            liquidator.liquidate(_liquidationParams(positionId));

            IsolatedMarginTypes.AccountMetrics memory afterMetrics = riskEngine.getMetrics(position.account);
            assertEq(uint256(_position(positionId).status), uint256(IsolatedMarginTypes.Status.ACTIVE));
            assertGt(afterMetrics.healthFactorBps, beforeMetrics.healthFactorBps, "health did not improve");
            assertLt(afterMetrics.healthFactorBps, 12_500, "test unexpectedly reached target in one step");
        }

        function testFullInsolventLiquidationUsesInsuranceAndClearsDebt() public {
            uint256 positionId = _openLong(500);
            IsolatedMarginTypes.Position memory beforePosition = _position(positionId);
            uint256 insuranceBefore = pUsd.balanceOf(address(insuranceFund));

            _setAvaxPriceAndRates(75e6);
            assertTrue(riskEngine.isLiquidatable(beforePosition.account), "position should be liquidatable");
            liquidator.liquidate(_liquidationParams(positionId));

            IsolatedMarginTypes.Position memory afterPosition = _position(positionId);
            assertEq(uint256(afterPosition.status), uint256(IsolatedMarginTypes.Status.LIQUIDATED));
            assertEq(pUsd.borrowBalanceStored(afterPosition.account), 0, "bad debt remains");
            assertEq(afterPosition.lockedMarginPTokens, 0, "position lock remains");
            assertEq(marginVault.lockedBalance(USER, address(pUsd)), 0, "user lock remains");
            assertLt(pUsd.balanceOf(address(insuranceFund)), insuranceBefore, "insurance was not used");
        }

        function testLiquidationPromotesToFullWhenPartialWouldExhaustPositionCollateral() public {
            uint256 positionId = _openLong(500);
            IsolatedMarginTypes.Position memory position = _position(positionId);

            usd.mint(USER, 230e18);
            vm.startPrank(USER);
            pUsd.mint(230e18);
            marginVault.deposit(address(pUsd), 230e18);
            executor.addCollateral(positionId, 230e18);
            vm.stopPrank();

            _setAvaxPriceAndRates(40e6);
            IsolatedMarginTypes.AccountMetrics memory metrics = riskEngine.getMetrics(position.account);
            assertTrue(riskEngine.isLiquidatable(position.account), "position should be liquidatable");
            assertGt(metrics.healthFactorBps, 5_000, "configured full-liquidation threshold reached");

            liquidator.liquidate(_liquidationParams(positionId));

            assertEq(uint256(_position(positionId).status), uint256(IsolatedMarginTypes.Status.LIQUIDATED));
            assertEq(pUsd.borrowBalanceStored(position.account), 0, "debt remains after promoted full liquidation");
        }

        function testNormalAccountStillUsesConventionalCollateralFactor() public {
            avax.mint(NORMAL_USER, 100e18);
            vm.startPrank(NORMAL_USER);
            avax.approve(address(pAvax), type(uint256).max);
            pAvax.mint(100e18);
            address[] memory markets = new address[](1);
            markets[0] = address(pAvax);
            controller.enterMarkets(markets);
            vm.stopPrank();

            vm.prank(address(pUsd));
            uint256 allowed = controller.borrowAllowed(address(pUsd), NORMAL_USER, 20e18);
            assertTrue(allowed != 0, "normal account bypassed conventional collateral factor");
        }

        function testControllerRejectsNativeLiquidationForIsolatedAccount() public {
            uint256 positionId = _openLong(500);
            IsolatedMarginTypes.Position memory position = _position(positionId);
            _setAvaxPriceAndRates(75e6);

            uint256 allowed =
                controller.liquidateBorrowAllowed(address(pUsd), address(pAvax), address(this), position.account, 1e18);
            assertTrue(allowed != 0, "native collateral-factor liquidation was enabled");
        }

        function testControllerRejectsDirectSeizeForIsolatedAccount() public {
            uint256 positionId = _openLong(500);
            IsolatedMarginTypes.Position memory position = _position(positionId);

            uint256 allowed = controller.seizeAllowed(
                address(pAvax), address(pUsd), address(this), position.account, 1e18
            );
            assertTrue(allowed != 0, "direct pToken seizure was enabled");
        }

        function _deployLendingMarkets() internal {
            usd = new MockErc20("USD Coin", "USD", 18);
            avax = new MockErc20("Wrapped AVAX", "WAVAX", 18);
            interestRateModel = new MutableMarginInterestRateModel();

            unitroller = new Unitroller();
            Peridottroller implementation = new Peridottroller();
            assertEq(unitroller._setPendingImplementation(address(implementation)), 0);
            implementation._become(unitroller);
            controller = Peridottroller(address(unitroller));

            pUsd = new IsolatedTestPErc20();
            pUsd.initialize(address(usd), controller, interestRateModel, 1e18, "Peridot USD", "pUSD", 18);
            pAvax = new IsolatedTestPErc20();
            pAvax.initialize(address(avax), controller, interestRateModel, 1e18, "Peridot AVAX", "pAVAX", 18);

            oracle = new AvalanchePriceOracle(address(this));
            usdFeed = new MarginTestAggregator(8, 1e8);
            avaxFeed = new MarginTestAggregator(8, 1e8);
            oracle.configureFeed(address(usd), address(usdFeed), 30 days);
            oracle.configureFeed(address(avax), address(avaxFeed), 30 days);
            oracle.registerMarket(address(pUsd), address(usd));
            oracle.registerMarket(address(pAvax), address(avax));

            assertEq(controller._setPriceOracle(oracle), 0);
            assertEq(controller._supportMarket(pUsd), 0);
            assertEq(controller._supportMarket(pAvax), 0);
            assertEq(controller._setCollateralFactor(pUsd, 1e17), 0);
            assertEq(controller._setCollateralFactor(pAvax, 1e17), 0);
        }

        function _deployMarginStack() internal {
            router = new MarginRateRouterAdapter();
            router.setRate(address(usd), address(avax), 1e18);
            router.setRate(address(avax), address(usd), 1e18);

            flashVault = new SimpleFlashLoanVault(address(this));
            flashVault.setTokenAllowed(address(usd), true);
            flashVault.setTokenAllowed(address(avax), true);

            insuranceFund = MarginInsuranceFundUpgradeable(
                _proxy(
                    address(new MarginInsuranceFundUpgradeable()),
                    abi.encodeWithSelector(MarginInsuranceFundUpgradeable.initialize.selector, address(this))
                )
            );
            config = IsolatedMarginConfigUpgradeable(
                _proxy(
                    address(new IsolatedMarginConfigUpgradeable()),
                    abi.encodeWithSelector(
                        IsolatedMarginConfigUpgradeable.initialize.selector,
                        address(this),
                        1 hours,
                        address(router),
                        address(flashVault),
                        address(insuranceFund),
                        TREASURY
                    )
                )
            );
            feeDistributor = MarginFeeDistributorUpgradeable(
                _proxy(
                    address(new MarginFeeDistributorUpgradeable()),
                    abi.encodeWithSelector(
                        MarginFeeDistributorUpgradeable.initialize.selector, address(this), address(config)
                    )
                )
            );
            marginVault = IsolatedMarginVaultUpgradeable(
                _proxy(
                    address(new IsolatedMarginVaultUpgradeable()),
                    abi.encodeWithSelector(
                        IsolatedMarginVaultUpgradeable.initialize.selector, address(this), address(feeDistributor)
                    )
                )
            );
            riskEngine = IsolatedMarginRiskEngineUpgradeable(
                _proxy(
                    address(new IsolatedMarginRiskEngineUpgradeable()),
                    abi.encodeWithSelector(
                        IsolatedMarginRiskEngineUpgradeable.initialize.selector,
                        address(this),
                        address(config),
                        address(oracle),
                        address(controller)
                    )
                )
            );
            quoter = new IsolatedMarginQuoter(address(config), address(oracle));
            swapModule = new IsolatedMarginSwapModule(address(config), address(quoter));
            accountFactory = new IsolatedMarginAccountFactory(address(this));
            executor = IsolatedMarginExecutorUpgradeable(
                _proxy(
                    address(new IsolatedMarginExecutorUpgradeable()),
                    abi.encodeWithSelector(
                        IsolatedMarginExecutorUpgradeable.initialize.selector,
                        address(config),
                        address(riskEngine),
                        address(marginVault),
                        address(feeDistributor),
                        address(quoter),
                        address(swapModule),
                        address(accountFactory)
                    )
                )
            );
            accountFactory.setExecutor(address(executor));
            liquidator = IsolatedMarginLiquidatorUpgradeable(
                _proxy(
                    address(new IsolatedMarginLiquidatorUpgradeable()),
                    abi.encodeWithSelector(
                        IsolatedMarginLiquidatorUpgradeable.initialize.selector,
                        address(executor),
                        address(config),
                        address(riskEngine),
                        address(marginVault),
                        address(insuranceFund),
                        address(quoter),
                        address(swapModule)
                    )
                )
            );
        }

        function _configureMarginStack() internal {
            riskEngine.setOperators(address(executor), address(liquidator));
            assertEq(controller._setIsolatedMarginRiskHook(address(riskEngine)), 0);
            assertEq(controller._setIsolatedMarginRegistrar(address(riskEngine)), 0);
            marginVault.setExecutor(address(executor));
            marginVault.setLiquidator(address(liquidator));
            marginVault.setPTokenAllowed(address(pUsd), true);
            marginVault.setPTokenAllowed(address(pAvax), true);
            feeDistributor.setVault(address(marginVault));
            feeDistributor.setFeeCollector(address(marginVault), true);
            feeDistributor.setFeeCollector(address(executor), true);
            insuranceFund.setLiquidator(address(liquidator));

            IsolatedMarginTypes.PairRiskConfig memory pairRisk = IsolatedMarginTypes.PairRiskConfig({
                enabled: true,
                maxLeverageX100: 500,
                initialMarginBps: 2_000,
                maintenanceMarginBps: 1_000,
                liquidationTargetBps: 12_500,
                fullLiquidationHealthBps: 5_000,
                maxLiquidationBps: 5_000,
                liquidationBonusBps: 500,
                maxSlippageBps: 100,
                oracleDeviationBps: 100,
                maxPositionValueUsd: 0,
                maxDebtValueUsd: 0
            });
            config.queuePairRisk(address(pUsd), address(pAvax), address(pUsd), pairRisk);
            config.queuePairRisk(address(pUsd), address(pUsd), address(pAvax), pairRisk);
            config.queueUnpauseOpens();
            vm.warp(block.timestamp + config.actionDelay());
            config.setPairRisk(address(pUsd), address(pAvax), address(pUsd), pairRisk);
            config.setPairRisk(address(pUsd), address(pUsd), address(pAvax), pairRisk);
            config.unpauseOpens();
        }

        function _seedBalances() internal {
            usd.mint(address(this), 30_000e18);
            avax.mint(address(this), 30_000e18);

            usd.approve(address(pUsd), type(uint256).max);
            avax.approve(address(pAvax), type(uint256).max);
            pUsd.mint(8_000e18);
            pAvax.mint(8_000e18);

            usd.approve(address(flashVault), type(uint256).max);
            avax.approve(address(flashVault), type(uint256).max);
            flashVault.depositLiquidity(address(usd), 8_000e18);
            flashVault.depositLiquidity(address(avax), 8_000e18);

            usd.transfer(address(router), 8_000e18);
            avax.transfer(address(router), 8_000e18);

            pUsd.transfer(address(insuranceFund), 500e18);
            usd.mint(USER, 200e18);
            vm.startPrank(USER);
            usd.approve(address(pUsd), type(uint256).max);
            pUsd.mint(150e18);
            pUsd.approve(address(marginVault), type(uint256).max);
            marginVault.deposit(address(pUsd), 120e18);
            vm.stopPrank();
        }

        function _openLong(uint16 leverageX100) internal returns (uint256 positionId) {
            vm.prank(USER);
            return executor.openPosition(_longParams(leverageX100));
        }

        function _openShort(uint16 leverageX100) internal returns (uint256 positionId) {
            IsolatedMarginExecutorUpgradeable.OpenParams memory params = IsolatedMarginExecutorUpgradeable.OpenParams({
                marginPToken: address(pUsd),
                positionPToken: address(pUsd),
                debtPToken: address(pAvax),
                marginPTokenAmount: 100e18,
                leverageX100: leverageX100,
                maxOpeningFeePToken: 0,
                minPositionUnderlying: 496e18,
                side: IsolatedMarginTypes.Side.SHORT,
                swapData: bytes("")
            });
            vm.prank(USER);
            return executor.openPosition(params);
        }

        function _longParams(uint16 leverageX100)
            internal
            view
            returns (IsolatedMarginExecutorUpgradeable.OpenParams memory)
        {
            return IsolatedMarginExecutorUpgradeable.OpenParams({
                marginPToken: address(pUsd),
                positionPToken: address(pAvax),
                debtPToken: address(pUsd),
                marginPTokenAmount: 100e18,
                leverageX100: leverageX100,
                maxOpeningFeePToken: 0,
                minPositionUnderlying: uint256(leverageX100) * 99e16,
                side: IsolatedMarginTypes.Side.LONG,
                swapData: bytes("")
            });
        }

        function _position(uint256 positionId) internal view returns (IsolatedMarginTypes.Position memory position) {
            (
                position.id,
                position.owner,
                position.account,
                position.marginPToken,
                position.positionPToken,
                position.debtPToken,
                position.lockedMarginPTokens,
                position.initialNotionalUsd,
                position.borrowedPrincipal,
                position.requestedLeverageX100,
                position.side,
                position.status
            ) = executor.positions(positionId);
        }

        function _liquidationParams(uint256 positionId)
            internal
            pure
            returns (IsolatedMarginLiquidatorUpgradeable.LiquidationParams memory)
        {
            return IsolatedMarginLiquidatorUpgradeable.LiquidationParams({
                positionId: positionId,
                recipient: LIQUIDATION_RECIPIENT,
                minDebtUnderlying: 0,
                minMarginUnderlying: 0,
                collateralToDebtSwapData: bytes(""),
                debtToMarginSwapData: bytes("")
            });
        }

        function _setAvaxPriceAndRates(int256 priceWithEightDecimals) internal {
            avaxFeed.setAnswer(priceWithEightDecimals);
            uint256 priceWad = uint256(priceWithEightDecimals) * 1e10;
            router.setRate(address(avax), address(usd), priceWad);
            router.setRate(address(usd), address(avax), 1e36 / priceWad);
        }

        function _setFees(
            uint16 openFeeBps,
            uint16 closeFeeBps,
            uint16 depositorShareBps,
            uint16 insuranceShareBps,
            uint16 treasuryShareBps
        ) internal {
            config.queueFees(openFeeBps, closeFeeBps, depositorShareBps, insuranceShareBps, treasuryShareBps);
            vm.warp(block.timestamp + config.actionDelay());
            config.setFees(openFeeBps, closeFeeBps, depositorShareBps, insuranceShareBps, treasuryShareBps);
        }

        function _proxy(address implementation, bytes memory data) internal returns (address) {
            return address(new PeridotTransparentProxy(implementation, address(this), data));
        }
    }

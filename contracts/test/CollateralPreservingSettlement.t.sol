// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {
    CollateralPreservingSettlementModule as Settlement
} from "../contracts/margin/CollateralPreservingSettlementModule.sol";
import {PharaohMarginOracle} from "../contracts/margin/PharaohMarginOracle.sol";
import {PharaohMarginRouterAdapter} from "../contracts/margin/PharaohMarginRouterAdapter.sol";
import {IsolatedMarginQuoter} from "../contracts/margin/IsolatedMarginQuoter.sol";
import {IsolatedMarginSwapModule} from "../contracts/margin/IsolatedMarginSwapModule.sol";
import {CollateralPreservingSwapModule} from "../contracts/margin/CollateralPreservingSwapModule.sol";
import {IsolatedMarginConfigUpgradeable} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginVaultUpgradeable} from "../contracts/margin/IsolatedMarginVaultUpgradeable.sol";
import {IsolatedMarginAccountFactory} from "../contracts/margin/IsolatedMarginAccountFactory.sol";
import {IsolatedMarginAccount} from "../contracts/margin/IsolatedMarginAccount.sol";
import {IsolatedMarginTypes} from "../contracts/margin/IsolatedMarginTypes.sol";
import {MarginFeeDistributorUpgradeable} from "../contracts/margin/MarginFeeDistributorUpgradeable.sol";
import {MarginInsuranceFundUpgradeable} from "../contracts/margin/MarginInsuranceFundUpgradeable.sol";
import {SimpleFlashLoanVault} from "../contracts/margin/SimpleFlashLoanVault.sol";
import {AvalanchePriceOracle} from "../contracts/margin/AvalanchePriceOracle.sol";
import {PharaohVaultShareOracle} from "../contracts/PharaohVaultShareOracle.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {PErc20Delegate} from "../contracts/PErc20Delegate.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {PharaohBoostedDelegate} from "../contracts/boosted/PharaohBoostedDelegate.sol";
import {Peridottroller} from "../contracts/Peridottroller.sol";
import {Unitroller} from "../contracts/Unitroller.sol";
import {PToken} from "../contracts/PToken.sol";
import {PeridotTransparentProxy} from "../contracts/proxy/PeridotTransparentProxy.sol";
import {MockInterestRateModel} from "./MockInterestRateModel.sol";
import {PharaohTestAsset, PharaohTestFeed} from "./mocks/PharaohBoostedMocks.sol";
import {MarginCapacityTestVault, PharaohMarginBaseRouterMock} from "./PharaohMarginRouterAdapter.t.sol";

/// @dev Settlement integration, NOT a borrowing/opening/liquidation lifecycle test.
/// Real controller, lending delegates, share oracle, adapter, swap, config, fee and vault code;
/// local mock ERC4626 strategies, feeds, zero interest model and funded swap venue.
contract CollateralPreservingSettlementTest is Test {
    PharaohTestAsset internal usd;
    PharaohTestAsset internal avax;
    MarginCapacityTestVault internal uVault;
    MarginCapacityTestVault internal aVault;
    PharaohTestFeed internal uFeed;
    PharaohTestFeed internal aFeed;
    PErc20Delegator internal pUsd;
    PErc20Delegator internal pAvax;
    PErc20Delegator internal pUVault;
    PErc20Delegator internal pAVault;
    Peridottroller internal controller;
    MockInterestRateModel internal irm;
    PharaohMarginBaseRouterMock internal router;
    PharaohMarginRouterAdapter internal adapter;
    PharaohMarginOracle internal oracle;
    IsolatedMarginConfigUpgradeable internal config;
    MarginFeeDistributorUpgradeable internal fees;
    IsolatedMarginVaultUpgradeable internal marginVault;
    IsolatedMarginQuoter internal quoter;
    CollateralPreservingSwapModule internal swapModule;
    Settlement internal settlement;
    address internal INSURANCE;
    address internal constant TREASURY = address(0x7EA);

    function setUp() public virtual {
        vm.warp(10 days);
        usd = new PharaohTestAsset("USDC", "USDC", 6);
        avax = new PharaohTestAsset("WAVAX", "WAVAX", 18);
        uVault = new MarginCapacityTestVault(usd);
        aVault = new MarginCapacityTestVault(avax);
        usd.mint(address(this), 1_000_000e6);
        avax.mint(address(this), 1_000_000e18);
        usd.approve(address(uVault), 10_000e6);
        avax.approve(address(aVault), 10_000e18);
        uVault.deposit(10_000e6, address(this));
        aVault.deposit(10_000e18, address(this));
        Unitroller proxy = new Unitroller();
        Peridottroller implementation = new Peridottroller();
        assertEq(proxy._setPendingImplementation(address(implementation)), 0);
        implementation._become(proxy);
        controller = Peridottroller(address(proxy));
        irm = new MockInterestRateModel();
        address plain = address(new PErc20Delegate());
        address boosted = address(new PharaohBoostedDelegate());
        pUsd = _market(address(usd), plain, 2e14, "");
        pAvax = _market(address(avax), plain, 2e26, "");
        pUVault = _market(address(uVault), boosted, 2e14, abi.encode(address(uVault), uint256(1)));
        pAVault = _market(address(aVault), boosted, 2e26, abi.encode(address(aVault), uint256(1)));
        uVault.approve(address(pUVault), 1000e6);
        aVault.approve(address(pAVault), 1000e18);
        assertEq(pUVault.mint(1000e6), 0);
        assertEq(pAVault.mint(1000e18), 0);

        uFeed = new PharaohTestFeed(8, 1e8);
        aFeed = new PharaohTestFeed(8, 10e8);
        AvalanchePriceOracle base = new AvalanchePriceOracle(address(this));
        base.configureFeed(address(usd), address(uFeed), 30 days);
        base.configureFeed(address(avax), address(aFeed), 30 days);
        base.registerMarket(address(pUsd), address(usd));
        base.registerMarket(address(pAvax), address(avax));
        PharaohVaultShareOracle shares = new PharaohVaultShareOracle(address(this), base);
        shares.registerVault(uVault, uFeed, 7 days);
        shares.registerVault(aVault, aFeed, 7 days);
        assertEq(controller._setPriceOracle(shares), 0);
        oracle =
            new PharaohMarginOracle(base, shares, address(pUVault), address(uVault), address(pAVault), address(aVault));
        router = new PharaohMarginBaseRouterMock(address(usd), address(avax));
        usd.mint(address(router), 1_000_000e6);
        avax.mint(address(router), 1_000_000e18);
        adapter = new PharaohMarginRouterAdapter(
            address(uVault), address(aVault), address(usd), address(avax), address(router)
        );
        SimpleFlashLoanVault lender = new SimpleFlashLoanVault(address(this));
        INSURANCE = _proxy(
            address(new MarginInsuranceFundUpgradeable()),
            abi.encodeCall(MarginInsuranceFundUpgradeable.initialize, (address(this)))
        );
        config = IsolatedMarginConfigUpgradeable(
            _proxy(
                address(new IsolatedMarginConfigUpgradeable()),
                abi.encodeCall(
                    IsolatedMarginConfigUpgradeable.initialize,
                    (address(this), 1 hours, address(adapter), address(lender), address(this), TREASURY)
                )
            )
        );
        config.queueFeeRecipients(INSURANCE, TREASURY);
        fees = MarginFeeDistributorUpgradeable(
            _proxy(
                address(new MarginFeeDistributorUpgradeable()),
                abi.encodeCall(MarginFeeDistributorUpgradeable.initialize, (address(this), address(config)))
            )
        );
        marginVault = IsolatedMarginVaultUpgradeable(
            _proxy(
                address(new IsolatedMarginVaultUpgradeable()),
                abi.encodeCall(IsolatedMarginVaultUpgradeable.initialize, (address(this), address(fees)))
            )
        );
        fees.setVault(address(marginVault));
        fees.setFeeCollector(address(marginVault), true);
        marginVault.setExecutor(address(this));
        marginVault.setPTokenAllowed(address(pUVault), true);
        marginVault.setPTokenAllowed(address(pAVault), true);
        quoter = new IsolatedMarginQuoter(address(config), address(oracle));
        swapModule = new CollateralPreservingSwapModule(address(config), address(quoter));
        settlement = new Settlement(address(config), address(quoter), address(swapModule), address(fees), _markets());
        fees.setFeeCollector(address(settlement), true);
        _queuePairs(true);
        vm.warp(block.timestamp + 1 hours);
        config.setFeeRecipients(INSURANCE, TREASURY);
        _setPairs(true);
        _depositRewardsStake(address(pUVault));
        _depositRewardsStake(address(pAVault));
        // Both underlying strategies refuse new deposits for every test.
        uVault.setLimits(true, false);
        aVault.setLimits(true, false);
    }

    function testProfitableLongReturnsUsdCollateralAndUsdcWithoutDeposits() public {
        _profit(false, false);
    }

    function testProfitableShortReturnsUsdCollateralAndUsdcWithoutDeposits() public {
        _profit(false, true);
    }

    function testProfitableLongReturnsAvaxCollateralAndUsdcWithoutDeposits() public {
        _profit(true, false);
    }

    function testProfitableShortReturnsAvaxCollateralAndUsdcWithoutDeposits() public {
        _profit(true, true);
    }

    function _profit(bool avaxCollateral, bool short) internal {
        Settlement.CloseParams memory p = _params(avaxCollateral, short, 510);
        uint256 supply = IERC20(_vault(p)).totalSupply();
        uint256 assets = IERC4626(_vault(p)).totalAssets();
        uint256 pSupply = PErc20(p.collateralPToken).totalSupply();
        uint256 beforeShares = IERC20(p.collateralPToken).balanceOf(address(this));
        uint256 beforeUsd = usd.balanceOf(address(this));
        uint256 beforeAvax = avax.balanceOf(address(this));
        Settlement.Settlement memory s = _settle(p);
        assertEq(s.collateralSold, 0);
        assertEq(s.collateralReturned, p.collateralShares - p.feeShares);
        assertEq(s.surplusUsdc, 10e6);
        assertEq(IERC20(p.collateralPToken).balanceOf(address(this)), beforeShares - p.feeShares);
        assertEq(IERC20(_vault(p)).totalSupply(), supply, "profit exit burned/minted strategy shares");
        assertEq(IERC4626(_vault(p)).totalAssets(), assets);
        assertEq(PErc20(p.collateralPToken).totalSupply(), pSupply);
        assertEq(usd.balanceOf(address(this)), short ? beforeUsd - 500e6 : beforeUsd + 510e6);
        assertEq(avax.balanceOf(address(this)), short ? beforeAvax + 50e18 : beforeAvax - 51e18);
        _assertFees(p);
        _clean(p.collateralPToken);
    }

    function testLosingLongSellsOnlyBudgetedUsdCollateral() public {
        _loss(false, false);
    }

    function testLosingShortSellsOnlyBudgetedUsdCollateral() public {
        _loss(false, true);
    }

    function testLosingLongSellsOnlyBudgetedAvaxCollateral() public {
        _loss(true, false);
    }

    function testLosingShortSellsOnlyBudgetedAvaxCollateral() public {
        _loss(true, true);
    }

    function _loss(bool avaxCollateral, bool short) internal {
        Settlement.CloseParams memory p = _params(avaxCollateral, short, 490);
        uint256 beforeShares = IERC20(p.collateralPToken).balanceOf(address(this));
        uint256 beforeUsd = usd.balanceOf(address(this));
        uint256 beforeAvax = avax.balanceOf(address(this));
        Settlement.Settlement memory s = _settle(p);
        assertGt(s.collateralSold, 0);
        assertLe(s.collateralSold, p.maxCollateralSharesToSell);
        assertEq(s.collateralReturned + s.collateralSold + p.feeShares, p.collateralShares);
        assertEq(IERC20(p.collateralPToken).balanceOf(address(this)), beforeShares - s.collateralSold - p.feeShares);
        // Worst-case slippage reserve sold at parity returns its unspent value as USDC.
        assertGt(s.surplusUsdc, 0);
        assertLt(s.surplusUsdc, 102_000);
        assertEq(
            usd.balanceOf(address(this)), short ? beforeUsd - 490e6 + s.surplusUsdc : beforeUsd + 500e6 + s.surplusUsdc
        );
        assertEq(avax.balanceOf(address(this)), short ? beforeAvax + 50e18 : beforeAvax - 49e18);
        _assertFees(p);
        _clean(p.collateralPToken);
    }

    function testProfitDoesNotNeedCollateralRedemptionCapacity() public {
        uVault.setLimits(true, true);
        aVault.setLimits(true, true);
        _profit(false, false);
        _profit(true, true);
    }

    function testLossRevertsAtomicallyWhenCollateralRedemptionIsClosed() public {
        Settlement.CloseParams memory p = _params(false, false, 490);
        uVault.setLimits(true, true);
        _expectUnchangedRevert(p, abi.encodeWithSelector(PharaohMarginRouterAdapter.VaultCapacity.selector));
    }

    function testLossCannotExceedOwnersCollateralBudget() public {
        Settlement.CloseParams memory p = _params(true, true, 490);
        p.maxCollateralSharesToSell = 1;
        _expectUnchangedRevert(p, abi.encodeWithSelector(Settlement.CollateralBudgetExceeded.selector));
    }

    function testInsufficientCollateralCannotSpendDonations() public {
        usd.mint(address(settlement), 1000e6);
        Settlement.CloseParams memory p = _params(false, false, 300);
        _expectUnchangedRevert(p, abi.encodeWithSelector(Settlement.CollateralBudgetExceeded.selector));
        assertEq(usd.balanceOf(address(settlement)), 1000e6);
    }

    function testInsuranceCannotCoverUnderquotedSaleWithCollateralRemaining() public {
        for (uint256 i; i < 4; ++i) {
            bool short = i % 2 != 0;
            Settlement.CloseParams memory p = _params(i >= 2, short, 490);
            p.insuranceDebtAmount = short ? 10e18 : 100e6;
            address debtAsset = short ? address(avax) : address(usd);
            uint256 quoted =
                settlement.quoteCollateralForDeficit(p.collateralPToken, debtAsset, short ? 1e18 : 10e6, 100);
            assertLt(quoted, p.maxCollateralSharesToSell);
            // Fault injection: realized redemption value is lower than the sizing
            // quote assumes. Keep real redemption, swap and oracle output checks.
            vm.mockCall(address(quoter), abi.encodeWithSelector(quoter.feePToken.selector), abi.encode(quoted / 2));
            _expectUnchangedRevert(p, _collateralMinimumError(i >= 2, short));
            vm.clearMockedCalls();
            _clean(p.collateralPToken);
        }
    }

    function testInsuranceCoversDeficitOnlyAfterAllAvailableCollateralSold() public {
        for (uint256 i; i < 4; ++i) {
            bool short = i % 2 != 0;
            Settlement.CloseParams memory p = _params(i >= 2, short, 300);
            p.insuranceDebtAmount = short ? 30e18 : 300e6;
            uint256 uBefore = usd.balanceOf(address(this));
            uint256 aBefore = avax.balanceOf(address(this));
            Settlement.Settlement memory s = _settle(p);
            assertEq(s.collateralSold, p.collateralShares - p.feeShares);
            assertEq(s.collateralReturned, 0);
            assertGt(s.insuranceDebtUsed, 0);
            assertLt(s.insuranceDebtUsed, p.insuranceDebtAmount);
            assertEq(s.surplusUsdc, 0);
            assertEq(s.surplusWavaxDust, 0);
            assertEq(
                usd.balanceOf(address(this)),
                short ? uBefore - p.tradeUnderlying : uBefore + p.repaymentAmount - s.insuranceDebtUsed
            );
            assertEq(
                avax.balanceOf(address(this)),
                short ? aBefore + p.repaymentAmount - s.insuranceDebtUsed : aBefore - p.tradeUnderlying
            );
            _clean(p.collateralPToken);
        }
    }

    function testInsuranceNeverRelaxesCollateralOutputMinimum() public {
        for (uint256 i; i < 4; ++i) {
            bool short = i % 2 != 0;
            Settlement.CloseParams memory p = _params(i >= 2, short, 300);
            p.insuranceDebtAmount = short ? 30e18 : 300e6;
            p.minCollateralDebtOut = short ? 10e18 : 100e6;
            _expectUnchangedRevert(p, _collateralMinimumError(i >= 2, short));
        }
    }

    function _collateralMinimumError(bool avaxCollateral, bool short) internal pure returns (bytes memory) {
        return avaxCollateral == short
            ? abi.encodeWithSelector(PharaohMarginRouterAdapter.InsufficientOutput.selector)
            : abi.encodeWithSignature("Error(string)", "router slippage");
    }

    function testFeeBudgetCannotBeUsedToRepayDebt() public {
        Settlement.CloseParams memory p = _params(false, false, 490);
        p.feeShares = p.collateralShares;
        _expectUnchangedRevert(p, abi.encodeWithSelector(Settlement.CollateralBudgetExceeded.selector));
    }

    function testProfitableExitPreservesPreexistingDonations() public {
        usd.mint(address(settlement), 3e6);
        avax.mint(address(settlement), 2e18);
        pUVault.transfer(address(settlement), 123);
        uVault.transfer(address(settlement), 345);
        Settlement.CloseParams memory p = _params(false, true, 510);
        _settle(p);
        assertEq(usd.balanceOf(address(settlement)), 3e6);
        assertEq(avax.balanceOf(address(settlement)), 2e18);
        assertEq(pUVault.balanceOf(address(settlement)), 123);
        assertEq(uVault.balanceOf(address(settlement)), 345);
    }

    function testInsufficientProfitMinimumRollsBackFeesAndSwaps() public {
        Settlement.CloseParams memory p = _params(false, false, 510);
        p.minSurplusUsdc = 11e6;
        _expectUnchangedRevert(p, abi.encodeWithSelector(Settlement.InsufficientProceeds.selector));
    }

    function testSwapCannotWeakenOracleBound() public {
        router.setExecution(9800, false);
        Settlement.CloseParams memory p = _params(false, false, 510);
        p.minTradeDebtOut = 1;
        _expectUnchangedRevert(p, abi.encodeWithSignature("Error(string)", "router slippage"));
    }

    function testCannotSpendAnotherCallersApprovals() public {
        Settlement.CloseParams memory p = _params(false, false, 510);
        _approve(p);
        uint256 beforeShares = pUVault.balanceOf(address(this));
        vm.prank(address(0xBAD));
        vm.expectRevert();
        settlement.settleFullClose(p);
        assertEq(pUVault.balanceOf(address(this)), beforeShares);
    }

    function testRejectsExpiredDeadlineAndFeeAboveCollateral() public {
        Settlement.CloseParams memory p = _params(false, false, 510);
        p.deadline = block.timestamp - 1;
        _expectUnchangedRevert(p, abi.encodeWithSelector(Settlement.InvalidClose.selector));
        p.deadline = block.timestamp;
        p.feeShares = p.collateralShares + 1;
        _expectUnchangedRevert(p, abi.encodeWithSelector(Settlement.InvalidClose.selector));
    }

    function testChangedMarketBindingCannotSpendFunds() public {
        Settlement.CloseParams memory p = _params(false, false, 510);
        vm.mockCall(address(pUVault), abi.encodeWithSignature("underlying()"), abi.encode(address(usd)));
        _expectUnchangedRevert(p, abi.encodeWithSelector(Settlement.InvalidConfiguration.selector));
    }

    function testChangedControllerBindingCannotSpendFunds() public {
        Settlement.CloseParams memory p = _params(true, true, 510);
        vm.mockCall(address(pAVault), abi.encodeWithSignature("peridottroller()"), abi.encode(address(this)));
        _expectUnchangedRevert(p, abi.encodeWithSelector(Settlement.InvalidConfiguration.selector));
    }

    function testRejectsMismatchedSwapQuoterWiring() public {
        IsolatedMarginQuoter otherQuoter = new IsolatedMarginQuoter(address(config), address(oracle));
        Settlement.Markets memory m = _markets();
        vm.expectRevert(Settlement.InvalidConfiguration.selector);
        new Settlement(address(config), address(otherQuoter), address(swapModule), address(fees), m);
    }

    function testRejectsLegacySwapModuleWithoutNewVersionMarker() public {
        IsolatedMarginSwapModule legacy = new IsolatedMarginSwapModule(address(config), address(quoter));
        Settlement.Markets memory m = _markets();
        vm.expectRevert();
        new Settlement(address(config), address(quoter), address(legacy), address(fees), m);
    }

    function testFractionalCollateralSaleRegression39UsdcBaseUnits() public {
        Settlement.CloseParams memory p = _params(true, false, 500);
        p.repaymentAmount += 39;
        Settlement.Settlement memory s = _settle(p);
        assertGt(s.collateralSold, 0);
        _clean(p.collateralPToken);
    }

    function testSwapUsesStricterOracleDeviationEvenWithLowUserMinimum() public {
        router.setExecution(9950, false);
        usd.approve(address(swapModule), 100e6);
        uint256 beforeUsd = usd.balanceOf(address(this));
        vm.expectRevert(bytes("router slippage"));
        swapModule.executeSwap(address(usd), address(avax), 100e6, 1, 100, 0, "");
        assertEq(usd.balanceOf(address(this)), beforeUsd);
    }

    function testSwapHonorsStricterUserMinimum() public {
        usd.approve(address(swapModule), 100e6);
        vm.expectRevert(bytes("router slippage"));
        swapModule.executeSwap(address(usd), address(avax), 100e6, 11e18, 100, 100, "");
    }

    function testSwapRejectsInvalidBoundsAndSameToken() public {
        vm.expectRevert(CollateralPreservingSwapModule.InvalidSwap.selector);
        swapModule.executeSwap(address(usd), address(avax), 100e6, 0, 10_000, 100, "");
        vm.expectRevert(CollateralPreservingSwapModule.InvalidSwap.selector);
        swapModule.executeSwap(address(usd), address(usd), 100e6, 0, 100, 100, "");
    }

    function testFuzzSwapRoundingStaysWithinOutputBaseUnitBound(uint64 rawAmount, uint16 rawBps) public {
        uint256 amount = bound(uint256(rawAmount), 1e12, 100e18);
        uint16 bps = uint16(bound(uint256(rawBps), 0, 100));
        router.setExecution(10_000 - bps, false);
        avax.approve(address(swapModule), amount);
        uint256 expected = quoter.expectedOut(address(avax), address(usd), amount);
        uint256 out = swapModule.executeSwap(address(avax), address(usd), amount, 0, bps, bps, "");
        assertEq(out, expected * (10_000 - bps) / 10_000);
        // Rational lower bound vs whole-USDC-unit output: strictly < 2 base units.
        uint256 exactNumerator = amount * 10e6 * (10_000 - bps);
        uint256 denominator = 1e18 * 10_000;
        assertLt(exactNumerator - out * denominator, 2 * denominator);
        _clean(address(pUVault));
    }

    function testExactBreakEvenDoesNotSellOrRemintCollateral() public {
        Settlement.CloseParams memory p = _params(true, true, 500);
        p.maxCollateralSharesToSell = 0;
        Settlement.Settlement memory s = _settle(p);
        assertEq(s.collateralSold, 0);
        assertEq(s.surplusUsdc, 0);
        assertEq(s.collateralReturned, p.collateralShares - p.feeShares);
        _clean(p.collateralPToken);
    }

    function testRepaymentIncludesAccruedDebtAndFlashFee() public {
        Settlement.CloseParams memory p = _params(false, false, 500);
        p.repaymentAmount += 5e6;
        uint256 beforeUsd = usd.balanceOf(address(this));
        Settlement.Settlement memory s = _settle(p);
        assertGt(s.collateralSold, 0);
        assertEq(usd.balanceOf(address(this)), beforeUsd + 505e6 + s.surplusUsdc);
        _clean(p.collateralPToken);
    }

    function testSubUsdcUnitShortSurplusReturnsExplicitDustWithoutBlockingClose() public {
        Settlement.CloseParams memory p = _params(true, true, 500);
        p.repaymentAmount -= 1; // One WAVAX wei cannot be converted into one USDC base unit.
        uint256 beforeAvax = avax.balanceOf(address(this));
        Settlement.Settlement memory s = _settle(p);
        assertEq(s.surplusUsdc, 0);
        assertEq(s.surplusWavaxDust, 1);
        assertEq(avax.balanceOf(address(this)), beforeAvax + p.repaymentAmount + 1);
        _clean(p.collateralPToken);
    }

    function testOneUsdcUnitSurplusRemainsUsdcNotDust() public {
        Settlement.CloseParams memory p = _params(true, true, 500);
        p.repaymentAmount -= 1e11; // Exactly 0.000001 USDC at $10/WAVAX.
        Settlement.Settlement memory s = _settle(p);
        assertEq(s.surplusUsdc, 1);
        assertEq(s.surplusWavaxDust, 0);
        _clean(p.collateralPToken);
    }

    function testDustDoesNotSatisfyAnExplicitUsdcMinimum() public {
        Settlement.CloseParams memory p = _params(true, true, 500);
        p.repaymentAmount -= 1;
        p.minSurplusUsdc = 1;
        _expectUnchangedRevert(p, abi.encodeWithSelector(Settlement.InsufficientProceeds.selector));
    }

    function testDisabledPairsAndPausedOpensDoNotBlockSettlement() public {
        config.disablePair(address(pUVault), address(pAvax), address(pUsd));
        assertTrue(config.opensPaused());
        _profit(false, false);
    }

    function testUnavailableShareValuationFailsClosedOnCollateralSale() public {
        Settlement.CloseParams memory p = _params(false, false, 490);
        uVault.setConversionReverts(true);
        _expectUnchangedRevert(p, abi.encodeWithSignature("Error(string)", "MarginQuoter: price unavailable"));
    }

    function testCollateralYieldReducesSharesSoldForSameDeficit() public {
        uint256 before = settlement.quoteCollateralForDeficit(address(pUVault), address(usd), 10e6, 100);
        usd.mint(address(uVault), 1000e6);
        uint256 afterYield = settlement.quoteCollateralForDeficit(address(pUVault), address(usd), 10e6, 100);
        assertLt(afterYield, before);
        _loss(false, false);
    }

    function testCurrentPTokenExchangeRateUsedBeforeSale() public {
        Settlement.CloseParams memory p = _params(false, false, 490);
        uint256 before = settlement.quoteCollateralForDeficit(address(pUVault), address(usd), 10e6, 100);
        uVault.transfer(address(pUVault), 100e6);
        Settlement.Settlement memory s = _settle(p);
        assertLt(s.collateralSold, before);
        _clean(p.collateralPToken);
    }

    function testFeeDistributionCanChangeWithoutChangingCollateralPool() public {
        config.queueFees(0, 0, 3000, 2000, 5000);
        vm.warp(block.timestamp + 1 hours);
        config.setFees(0, 0, 3000, 2000, 5000);
        Settlement.CloseParams memory p = _params(true, true, 510);
        _settle(p);
        assertEq(pAVault.balanceOf(INSURANCE), p.feeShares * 2000 / 10_000);
        assertEq(pAVault.balanceOf(TREASURY), p.feeShares * 5000 / 10_000);
        assertEq(pUVault.balanceOf(INSURANCE), 0);
        assertEq(pUVault.balanceOf(TREASURY), 0);
        _clean(p.collateralPToken);
    }

    function testAccountVaultReturnAndWithdrawalRemainPTokenNativeAfterLoss() public {
        _accountVaultReturn(false);
        _accountVaultReturn(true);
    }

    function _accountVaultReturn(bool avaxCollateral) internal {
        Settlement.CloseParams memory p = _params(avaxCollateral, false, 490);
        IsolatedMarginAccountFactory factory = new IsolatedMarginAccountFactory(address(this));
        factory.setExecutor(address(this));
        uint256 id = avaxCollateral ? 2 : 1;
        IsolatedMarginAccount account = IsolatedMarginAccount(
            factory.createAccount(address(this), address(this), id, p.collateralPToken, address(pAvax), address(pUsd))
        );
        IERC20(p.collateralPToken).approve(address(marginVault), p.collateralShares);
        marginVault.deposit(p.collateralPToken, p.collateralShares);
        marginVault.lockForPosition(id, address(this), address(account), p.collateralPToken, p.collateralShares, 0);
        assertEq(IERC20(p.collateralPToken).balanceOf(address(account)), p.collateralShares);
        // Fresh executor integration must do this only after repaying account debt.
        // This harness tests actual custody/reward reconciliation, not authorization of live debt.
        account.transferToken(p.collateralPToken, address(this), p.collateralShares);
        Settlement.Settlement memory s = _settle(p);
        IERC20(p.collateralPToken).transfer(address(account), s.collateralReturned);
        account.approveToken(p.collateralPToken, address(marginVault), s.collateralReturned);
        marginVault.releaseFromPosition(id, p.collateralShares, s.collateralReturned);
        account.approveToken(p.collateralPToken, address(marginVault), 0);
        assertEq(marginVault.lockedBalance(address(this), p.collateralPToken), 0);
        assertEq(IERC20(p.collateralPToken).balanceOf(address(account)), 0);
        (uint256 rewardShares,,) = fees.userRewards(p.collateralPToken, address(this));
        assertEq(rewardShares, marginVault.freeBalance(address(this), p.collateralPToken));
        uint256 free = marginVault.freeBalance(address(this), p.collateralPToken);
        uint256 beforeShares = IERC20(p.collateralPToken).balanceOf(address(this));
        uint256 supplyBefore = IERC20(_vault(p)).totalSupply();
        marginVault.withdraw(p.collateralPToken, free);
        assertEq(IERC20(p.collateralPToken).balanceOf(address(this)), beforeShares + free);
        assertEq(IERC20(_vault(p)).totalSupply(), supplyBefore);
        assertEq(marginVault.freeBalance(address(this), p.collateralPToken), 0);
        _clean(p.collateralPToken);
    }

    function testFuzzConservesSharesAndReturnsExactRepayment(bool avaxCollateral, bool short, uint32 value) public {
        value = uint32(bound(value, 450, 600));
        Settlement.CloseParams memory p = _params(avaxCollateral, short, value);
        uint256 beforeShares = IERC20(p.collateralPToken).balanceOf(address(this));
        uint256 beforeUsd = usd.balanceOf(address(this));
        uint256 beforeAvax = avax.balanceOf(address(this));
        Settlement.Settlement memory s = _settle(p);
        assertEq(s.collateralSold + s.collateralReturned + p.feeShares, p.collateralShares);
        assertEq(IERC20(p.collateralPToken).balanceOf(address(this)), beforeShares - s.collateralSold - p.feeShares);
        assertEq(
            usd.balanceOf(address(this)),
            short ? beforeUsd - p.tradeUnderlying + s.surplusUsdc : beforeUsd + p.repaymentAmount + s.surplusUsdc
        );
        assertEq(avax.balanceOf(address(this)), short ? beforeAvax + p.repaymentAmount : beforeAvax - p.tradeUnderlying);
        if (value >= 500) {
            assertEq(s.collateralSold, 0);
            assertEq(s.surplusUsdc, (uint256(value) - 500) * 1e6);
        }
        _clean(p.collateralPToken);
    }

    function testFuzzFractionalDebtDeficitPreservesRepaymentAndDust(bool avaxCollateral, bool short, uint64 rawDeficit)
        public
    {
        Settlement.CloseParams memory p = _params(avaxCollateral, short, 500);
        p.repaymentAmount += bound(uint256(rawDeficit), 1, short ? 5e18 : 50e6);
        uint256 beforeUsd = usd.balanceOf(address(this));
        uint256 beforeAvax = avax.balanceOf(address(this));
        Settlement.Settlement memory s = _settle(p);
        assertGt(s.collateralSold, 0);
        assertEq(s.collateralSold + s.collateralReturned + p.feeShares, p.collateralShares);
        assertEq(
            usd.balanceOf(address(this)),
            short ? beforeUsd - p.tradeUnderlying + s.surplusUsdc : beforeUsd + p.repaymentAmount + s.surplusUsdc
        );
        assertEq(
            avax.balanceOf(address(this)),
            short ? beforeAvax + p.repaymentAmount + s.surplusWavaxDust : beforeAvax - p.tradeUnderlying
        );
        if (s.surplusWavaxDust != 0) {
            assertTrue(short);
            assertEq(quoter.expectedOut(address(avax), address(usd), s.surplusWavaxDust), 0);
        }
        _clean(p.collateralPToken);
    }

    function testLossAtWorstAllowedSwapRateStillRepaysInFull() public {
        router.setExecution(9900, false);
        Settlement.CloseParams memory p = _params(true, true, 500);
        uint256 beforeAvax = avax.balanceOf(address(this));
        Settlement.Settlement memory s = _settle(p);
        assertGt(s.collateralSold, 0);
        assertEq(avax.balanceOf(address(this)), beforeAvax + p.repaymentAmount + s.surplusWavaxDust);
        _clean(p.collateralPToken);
    }

    function _params(bool avaxCollateral, bool short, uint256 tradeValue)
        internal
        view
        returns (Settlement.CloseParams memory p)
    {
        p.collateralPToken = avaxCollateral ? address(pAVault) : address(pUVault);
        p.debtPToken = short ? address(pAvax) : address(pUsd);
        p.collateralShares = quoter.feePToken(p.collateralPToken, 100e18);
        p.tradeUnderlying = short ? tradeValue * 1e6 : tradeValue * 1e17;
        p.repaymentAmount = short ? 50e18 : 500e6;
        p.feeShares = quoter.feePToken(p.collateralPToken, 1e18);
        p.maxCollateralSharesToSell = p.collateralShares - p.feeShares;
        p.deadline = block.timestamp;
    }

    function _settle(Settlement.CloseParams memory p) internal returns (Settlement.Settlement memory) {
        _approve(p);
        return settlement.settleFullClose(p);
    }

    function _approve(Settlement.CloseParams memory p) internal {
        IERC20(p.collateralPToken).approve(address(settlement), p.collateralShares);
        IERC20(p.debtPToken == address(pUsd) ? address(avax) : address(usd))
            .approve(address(settlement), p.tradeUnderlying);
        IERC20(p.debtPToken == address(pUsd) ? address(usd) : address(avax))
            .approve(address(settlement), p.insuranceDebtAmount);
    }

    function _expectUnchangedRevert(Settlement.CloseParams memory p, bytes memory reason) internal {
        _approve(p);
        uint256 uBefore = usd.balanceOf(address(this));
        uint256 aBefore = avax.balanceOf(address(this));
        uint256 pBefore = IERC20(p.collateralPToken).balanceOf(address(this));
        uint256 feeBefore = IERC20(p.collateralPToken).balanceOf(address(fees));
        vm.expectRevert(reason);
        settlement.settleFullClose(p);
        assertEq(usd.balanceOf(address(this)), uBefore);
        assertEq(avax.balanceOf(address(this)), aBefore);
        assertEq(IERC20(p.collateralPToken).balanceOf(address(this)), pBefore);
        assertEq(IERC20(p.collateralPToken).balanceOf(address(fees)), feeBefore);
    }

    function _assertFees(Settlement.CloseParams memory p) internal view {
        (,, uint256 reserve,,,) = fees.pools(p.collateralPToken);
        assertEq(reserve, p.feeShares / 2);
        assertEq(IERC20(p.collateralPToken).balanceOf(INSURANCE), p.feeShares - p.feeShares / 2);
        address other = p.collateralPToken == address(pUVault) ? address(pAVault) : address(pUVault);
        (,, uint256 otherReserve,,,) = fees.pools(other);
        // Tests making two settlements inspect the target pool, not a shared reward bucket.
        if (IERC20(other).balanceOf(INSURANCE) == 0) assertEq(otherReserve, 0);
    }

    function _clean(address collateral) internal view {
        address[4] memory tokens = [collateral, PErc20(collateral).underlying(), address(usd), address(avax)];
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(address(settlement)), 0);
            assertEq(IERC20(tokens[i]).balanceOf(address(swapModule)), 0);
            assertEq(IERC20(tokens[i]).balanceOf(address(adapter)), 0);
            assertEq(IERC20(tokens[i]).allowance(address(settlement), address(swapModule)), 0);
            assertEq(IERC20(tokens[i]).allowance(address(settlement), address(fees)), 0);
        }
    }

    function _vault(Settlement.CloseParams memory p) internal view returns (address) {
        return PErc20(p.collateralPToken).underlying();
    }

    function _depositRewardsStake(address market) internal {
        uint256 amount = quoter.feePToken(market, 1e18);
        IERC20(market).approve(address(marginVault), amount);
        marginVault.deposit(market, amount);
    }

    function _market(address asset, address implementation, uint256 rate, bytes memory data)
        internal
        returns (PErc20Delegator m)
    {
        m = new PErc20Delegator(
            asset, controller, irm, rate, "Test Peridot", "pTEST", 8, payable(address(this)), implementation, data
        );
        assertEq(controller._supportMarket(PToken(address(m))), 0);
    }

    function _markets() internal view returns (Settlement.Markets memory) {
        return Settlement.Markets(
            address(usd), address(avax), address(pUsd), address(pAvax), address(pUVault), address(pAVault)
        );
    }

    function _risk(bool enabled) internal pure returns (IsolatedMarginTypes.PairRiskConfig memory r) {
        r = IsolatedMarginTypes.PairRiskConfig(enabled, 500, 2000, 1000, 12_500, 5000, 5000, 500, 100, 100, 0, 0);
    }

    function _queuePairs(bool enabled) internal {
        address[2] memory collaterals = [address(pUVault), address(pAVault)];
        for (uint256 i; i < 2; ++i) {
            config.queuePairRisk(collaterals[i], address(pAvax), address(pUsd), _risk(enabled));
            config.queuePairRisk(collaterals[i], address(pUsd), address(pAvax), _risk(enabled));
        }
    }

    function _setPairs(bool enabled) internal {
        address[2] memory collaterals = [address(pUVault), address(pAVault)];
        for (uint256 i; i < 2; ++i) {
            config.setPairRisk(collaterals[i], address(pAvax), address(pUsd), _risk(enabled));
            config.setPairRisk(collaterals[i], address(pUsd), address(pAvax), _risk(enabled));
        }
    }

    function _proxy(address implementation, bytes memory data) internal returns (address) {
        return address(new PeridotTransparentProxy(implementation, address(this), data));
    }
}

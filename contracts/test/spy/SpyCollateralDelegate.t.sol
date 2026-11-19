// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Peridottroller} from "../../contracts/Peridottroller.sol";
import {Unitroller} from "../../contracts/Unitroller.sol";
import {PToken} from "../../contracts/PToken.sol";
import {PErc20Delegator} from "../../contracts/PErc20Delegator.sol";
import {PErc20Delegate} from "../../contracts/PErc20Delegate.sol";
import {PriceOracle} from "../../contracts/PriceOracle.sol";
import {InterestRateModel} from "../../contracts/InterestRateModel.sol";
import {PeridottrollerInterface} from "../../contracts/PeridottrollerInterface.sol";
import {RobinhoodPlainDelegate} from "../../contracts/margin/spy/RobinhoodPlainDelegate.sol";
import {RobinhoodSpyCollateralDelegate} from "../../contracts/margin/spy/RobinhoodSpyCollateralDelegate.sol";
import {SpyCollateralLiquidator} from "../../contracts/margin/spy/SpyCollateralLiquidator.sol";
import {SimpleFlashLoanVault} from "../../contracts/margin/SimpleFlashLoanVault.sol";
import {IMarginRouterAdapter} from "../../contracts/margin/IMarginRouterAdapter.sol";
import {MockErc20} from "../MockErc20.sol";

contract ZeroRateModel is InterestRateModel {
    uint256 public borrowRate;

    function setBorrowRate(uint256 r) external {
        borrowRate = r;
    }

    function getBorrowRate(uint256, uint256, uint256) external view override returns (uint256) {
        return borrowRate;
    }

    function getSupplyRate(uint256, uint256, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }
}

contract MarketPriceOracle is PriceOracle {
    mapping(address => uint256) public prices;

    function set(address market, uint256 p) external {
        prices[market] = p;
    }

    function getUnderlyingPrice(PToken pToken) external view override returns (uint256) {
        return prices[address(pToken)];
    }
}

/// @dev Stands in for SpyMarginPriceSource.stockPrice (reason 0 = served).
contract MockSessionSource {
    uint256 public price = 716e18;
    uint8 public reason;
    bool public broken;

    function set(uint256 p, uint8 r) external {
        price = p;
        reason = r;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function stockPrice() external view returns (uint256, uint8, uint256) {
        require(!broken, "SOURCE_BROKEN");
        return (reason == 0 ? price : 0, reason, block.timestamp);
    }
}

/// @dev Fixed-rate router adapter: pulls `amountIn` from `fromAccount`, pays `amountIn * rate / 1e18` of tokenOut.
contract RateRouter is IMarginRouterAdapter {
    mapping(address => mapping(address => uint256)) public rate;
    mapping(address => bool) public operators;

    function setRate(address a, address b, uint256 r) external {
        rate[a][b] = r;
    }

    function setOperator(address o, bool ok) external {
        operators[o] = ok;
    }

    function swap(address fromAccount, address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata)
        external
        virtual
        returns (uint256 out)
    {
        require(operators[msg.sender], "NOT_OPERATOR");
        MockErc20(tokenIn).transferFrom(fromAccount, address(this), amountIn);
        out = amountIn * rate[tokenIn][tokenOut] / 1e18;
        require(out >= minOut, "MIN_OUT");
        MockErc20(tokenOut).mint(fromAccount, out);
    }
}

/// @dev A router that, mid-swap, tries to re-enter the liquidator's flash callback (it is not the flash lender).
contract ReenteringRouter is RateRouter {
    function swap(address fromAccount, address, address tokenOut, uint256, uint256, bytes calldata)
        external
        override
        returns (uint256)
    {
        (bool ok, bytes memory ret) = fromAccount.call(
            abi.encodeWithSignature("onFlashLoan(address,address,uint256,uint256,bytes)", fromAccount, tokenOut, 1, 0, "")
        );
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return 0;
    }
}

/// @dev An address with code that the controller registers as an isolated-margin account.
contract FakeMarginAccount {
    function call(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }
}

interface IMarketFull {
    function mint(uint256) external returns (uint256);
    function redeem(uint256) external returns (uint256);
    function redeemUnderlying(uint256) external returns (uint256);
    function borrow(uint256) external returns (uint256);
    function repayBorrow(uint256) external returns (uint256);
    function liquidateBorrow(address, uint256, address) external returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function getAccountSnapshot(address) external view returns (uint256, uint256, uint256, uint256);
    function borrowBalanceStored(address) external view returns (uint256);
    function lendingSupplyCap() external view returns (uint256);
    function _setLendingSupplyCap(uint256) external;
    function _setImplementation(address, bool, bytes memory) external;
    function implementation() external view returns (address);
    function sessionReason() external view returns (uint256);
    function totalUnderlyingSupply() external view returns (uint256);
}

/// @notice Unit tests: the pSPY collateral delegate and the flash liquidator against a real Peridottroller.
contract SpyCollateralDelegateTest is Test {
    Peridottroller controller;
    MarketPriceOracle oracle;
    ZeroRateModel irm;
    MockErc20 usdg;
    MockErc20 spy;
    MockErc20 nvda;
    IMarketFull pUsdg;
    IMarketFull pSpy;
    IMarketFull pNvda;
    MockSessionSource source;
    RobinhoodSpyCollateralDelegate impl;

    address alice = makeAddr("alice"); // SPY collateral borrower
    address bob = makeAddr("bob"); // NVDA-only borrower
    address lender = makeAddr("lender");
    address liq = makeAddr("liquidator");

    uint256 constant SPY_PRICE = 716e18; // controller scale for an 18-dp underlying
    uint256 constant CAP = 0.23e18;

    function setUp() public {
        vm.warp(1_795_000_000);
        usdg = new MockErc20("USDG", "USDG", 6);
        spy = new MockErc20("SPY", "SPY", 18);
        nvda = new MockErc20("NVDA", "NVDA", 18);
        irm = new ZeroRateModel();
        Unitroller u = new Unitroller();
        Peridottroller ci = new Peridottroller();
        u._setPendingImplementation(address(ci));
        ci._become(u);
        controller = Peridottroller(address(u));
        oracle = new MarketPriceOracle();
        source = new MockSessionSource();

        pUsdg = _market(address(usdg), 2e14, address(new PErc20Delegate()));
        pNvda = _market(address(nvda), 2e26, address(new PErc20Delegate()));
        pSpy = _market(address(spy), 2e26, address(new RobinhoodPlainDelegate()));

        oracle.set(address(pUsdg), 1e30);
        oracle.set(address(pNvda), 180e18);
        oracle.set(address(pSpy), SPY_PRICE);
        assertEq(controller._setPriceOracle(oracle), 0);
        assertEq(controller._supportMarket(PToken(address(pUsdg))), 0);
        assertEq(controller._supportMarket(PToken(address(pNvda))), 0);
        assertEq(controller._supportMarket(PToken(address(pSpy))), 0);
        assertEq(controller._setCollateralFactor(PToken(address(pUsdg)), 0.8e18), 0);
        assertEq(controller._setCollateralFactor(PToken(address(pNvda)), 0.8e18), 0);
        assertEq(controller._setCloseFactor(0.5e18), 0);
        assertEq(controller._setLiquidationIncentive(1.08e18), 0);
        controller._setBorrowPaused(PToken(address(pSpy)), true);
        // The margin registrar is this test contract.
        assertEq(controller._setIsolatedMarginRegistrar(address(this)), 0);

        // Margin-ceremony state: dead seed in pSPY, CF 0, then the collateral ceremony.
        _mint(pSpy, spy, address(0xdEaD), 0.0001e18);
        impl = new RobinhoodSpyCollateralDelegate(address(source));
        pSpy._setImplementation(address(impl), false, abi.encode(CAP));
        assertEq(controller._setCollateralFactor(PToken(address(pSpy)), 0.3e18), 0);

        _mint(pUsdg, usdg, lender, 100e6);
    }

    function _market(address underlying, uint256 rate, address delegate) internal returns (IMarketFull m) {
        m = IMarketFull(
            address(
                new PErc20Delegator(
                    underlying,
                    PeridottrollerInterface(address(controller)),
                    irm,
                    rate,
                    "p",
                    "p",
                    8,
                    payable(address(this)),
                    delegate,
                    ""
                )
            )
        );
    }

    function _mint(IMarketFull m, MockErc20 t, address who, uint256 amount) internal {
        t.mint(who, amount);
        vm.startPrank(who);
        t.approve(address(m), amount);
        m.mint(amount);
        vm.stopPrank();
    }

    function _enter(address who, address market) internal {
        address[] memory a = new address[](1);
        a[0] = market;
        vm.prank(who);
        controller.enterMarkets(a);
    }

    /// alice: 0.2 SPY ($143.2) entered, borrows `borrowUsdg`.
    function _aliceBorrows(uint256 borrowUsdg) internal {
        _mint(pSpy, spy, alice, 0.2e18);
        _enter(alice, address(pSpy));
        if (borrowUsdg != 0) {
            vm.prank(alice);
            assertEq(pUsdg.borrow(borrowUsdg), 0);
        }
    }

    // ------------------------------------------------------------------ upgrade, layout, cap admin

    function testUpgradeSetsCapAndKeepsState() public view {
        assertEq(pSpy.implementation(), address(impl));
        assertEq(pSpy.lendingSupplyCap(), CAP);
        assertEq(uint256(vm.load(address(pSpy), bytes32(uint256(21)))), CAP, "cap lives in appended slot 21");
        assertEq(address(uint160(uint256(vm.load(address(pSpy), bytes32(uint256(20)))))), address(impl));
        assertEq(pSpy.balanceOf(address(0xdEaD)), 0.0001e18 * 1e18 / 2e26);
        assertEq(pSpy.exchangeRateStored(), 2e26);
    }

    function testBecomeImplementationRejectsBadDataAndNonAdmin() public {
        RobinhoodSpyCollateralDelegate other = new RobinhoodSpyCollateralDelegate(address(source));
        vm.expectRevert(RobinhoodSpyCollateralDelegate.InvalidConfiguration.selector);
        pSpy._setImplementation(address(other), false, "");
        vm.expectRevert(RobinhoodSpyCollateralDelegate.InvalidConfiguration.selector);
        pSpy._setImplementation(address(other), false, abi.encode(uint256(1), uint256(2)));
        vm.prank(alice);
        vm.expectRevert();
        pSpy._setImplementation(address(other), false, abi.encode(uint256(1)));
        // Direct call on the implementation: admin there is zero.
        vm.expectRevert(RobinhoodSpyCollateralDelegate.OnlyAdmin.selector);
        other._becomeImplementation(abi.encode(uint256(1)));
    }

    function testConstructorRejectsCodelessSource() public {
        vm.expectRevert(RobinhoodSpyCollateralDelegate.InvalidConfiguration.selector);
        new RobinhoodSpyCollateralDelegate(address(0x1234));
    }

    function testSetCapAdminOnly() public {
        vm.prank(alice);
        vm.expectRevert(RobinhoodSpyCollateralDelegate.OnlyAdmin.selector);
        pSpy._setLendingSupplyCap(1);
        vm.expectEmit(address(pSpy));
        emit RobinhoodSpyCollateralDelegate.LendingSupplyCapSet(CAP, 5e18);
        pSpy._setLendingSupplyCap(5e18);
        assertEq(pSpy.lendingSupplyCap(), 5e18);
    }

    // ------------------------------------------------------------------ supply cap

    function testLendingMintUpToCapThenRevert() public {
        uint256 room = CAP - pSpy.totalUnderlyingSupply();
        _mint(pSpy, spy, alice, room);
        assertEq(pSpy.totalUnderlyingSupply(), CAP);
        spy.mint(bob, 1e12);
        vm.startPrank(bob);
        spy.approve(address(pSpy), 1e12);
        vm.expectRevert(
            abi.encodeWithSelector(RobinhoodSpyCollateralDelegate.LendingSupplyCapExceeded.selector, CAP + 1e12, CAP)
        );
        pSpy.mint(1e12);
        vm.stopPrank();
    }

    function testZeroCapClosesLendingMints() public {
        pSpy._setLendingSupplyCap(0);
        spy.mint(bob, 1e15);
        vm.startPrank(bob);
        spy.approve(address(pSpy), 1e15);
        vm.expectRevert();
        pSpy.mint(1e15);
        vm.stopPrank();
    }

    function testMarginAccountMintIsNeverCapped() public {
        pSpy._setLendingSupplyCap(0);
        FakeMarginAccount acct = new FakeMarginAccount();
        controller.registerIsolatedMarginAccount(address(acct));
        spy.mint(address(acct), 5e18);
        acct.call(address(spy), abi.encodeWithSignature("approve(address,uint256)", address(pSpy), 5e18));
        acct.call(address(pSpy), abi.encodeWithSignature("mint(uint256)", 5e18));
        assertGt(pSpy.balanceOf(address(acct)), 0);
        assertGt(pSpy.totalUnderlyingSupply(), 5e18);
        // ...and margin-held pSPY counts against the lending cap afterwards.
        pSpy._setLendingSupplyCap(5e18);
        spy.mint(bob, 1e12);
        vm.startPrank(bob);
        spy.approve(address(pSpy), 1e12);
        vm.expectRevert();
        pSpy.mint(1e12);
        vm.stopPrank();
    }

    function testZeroSharesMintedStillReverts() public {
        spy.mint(bob, 1);
        vm.startPrank(bob);
        spy.approve(address(pSpy), 1);
        vm.expectRevert(RobinhoodSpyCollateralDelegate.ZeroSharesMinted.selector);
        pSpy.mint(1);
        vm.stopPrank();
    }

    function testRedeemUnderlyingRoundsSharesUp() public {
        _mint(pSpy, spy, bob, 0.01e18);
        // Donate to make the rate non-integral.
        spy.mint(address(pSpy), 7);
        uint256 before = pSpy.balanceOf(bob);
        uint256 rate = pSpy.exchangeRateStored();
        uint256 amount = 0.003e18 + 1;
        vm.prank(bob);
        pSpy.redeemUnderlying(amount);
        uint256 burned = before - pSpy.balanceOf(bob);
        assertEq(burned, (amount * 1e18 + rate - 1) / rate);
        assertGe(burned * rate / 1e18 + 1, amount);
    }

    // ------------------------------------------------------------------ CF 30 % borrow

    function testBorrowAtThirtyPercent() public {
        _aliceBorrows(0);
        (, uint256 liquidity, uint256 shortfall) = controller.getAccountLiquidity(alice);
        // 0.2 SPY * $716 * 0.30 = $42.96 (1e18 scale), up to pToken rounding.
        assertApproxEqAbs(liquidity, 42.96e18, 1e10);
        assertEq(shortfall, 0);
        vm.prank(alice);
        assertEq(pUsdg.borrow(42.95e6), 0);
        vm.prank(alice);
        vm.expectRevert();
        pUsdg.borrow(0.02e6);
    }

    // ------------------------------------------------------------------ session gate

    function testClosedSessionFailsClosedExceptRepayAndMint() public {
        _aliceBorrows(20e6);
        for (uint8 reason = 1; reason <= 8; reason++) {
            source.set(716e18, reason);
            (uint256 err,,,) = pSpy.getAccountSnapshot(alice);
            assertEq(err, reason);
            (uint256 lerr,,) = controller.getAccountLiquidity(alice);
            assertTrue(lerr != 0, "liquidity must error");

            vm.startPrank(alice);
            vm.expectRevert();
            pUsdg.borrow(1e6);
            uint256 bal = pSpy.balanceOf(alice);
            vm.expectRevert();
            pSpy.redeem(bal / 10);
            vm.expectRevert();
            pSpy.redeemUnderlying(0.001e18);
            vm.expectRevert();
            pSpy.transfer(bob, bal / 10);
            vm.stopPrank();
        }
        // exitMarket reverts on the snapshot error code.
        vm.prank(alice);
        vm.expectRevert(bytes("exitMarket: getAccountSnapshot failed"));
        controller.exitMarket(address(pSpy));
        // repay works while closed
        vm.startPrank(alice);
        usdg.approve(address(pUsdg), 5e6);
        assertEq(pUsdg.repayBorrow(5e6), 0);
        vm.stopPrank();
        assertEq(pUsdg.borrowBalanceStored(alice), 15e6);
        // mint works while closed (adds collateral)
        _mint(pSpy, spy, alice, 0.001e18);
    }

    function testRedeemOfOtherCollateralBlockedWhileClosed() public {
        _mint(pUsdg, usdg, alice, 10e6);
        _enter(alice, address(pUsdg));
        _aliceBorrows(5e6);
        source.set(0, 7);
        uint256 shares = pUsdg.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        pUsdg.redeem(shares / 100);
    }

    function testDebtFreeEnteredHolderCannotRedeemWhileClosed() public {
        _aliceBorrows(0);
        source.set(0, 7);
        uint256 bal = pSpy.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        pSpy.redeem(bal);
        source.set(716e18, 0);
        vm.prank(alice);
        assertEq(pSpy.redeem(bal), 0);
    }

    function testNotEnteredHolderRedeemsWhileClosed() public {
        _mint(pSpy, spy, bob, 0.01e18);
        source.set(0, 7);
        uint256 bal = pSpy.balanceOf(bob);
        vm.prank(bob);
        assertEq(pSpy.redeem(bal), 0);
    }

    function testZeroBalanceEntrantNotFrozen() public {
        // bob: NVDA collateral, USDG debt, and enters pSPY with no pSPY at all.
        _mint(pNvda, nvda, bob, 1e18);
        _enter(bob, address(pNvda));
        _enter(bob, address(pSpy));
        vm.prank(bob);
        assertEq(pUsdg.borrow(50e6), 0);
        source.set(0, 7);
        (uint256 err, uint256 liquidity,) = controller.getAccountLiquidity(bob);
        assertEq(err, 0);
        assertGt(liquidity, 0);
        // still liquidatable when NVDA falls, even with SPY closed
        oracle.set(address(pNvda), 60e18);
        usdg.mint(liq, 25e6);
        vm.startPrank(liq);
        usdg.approve(address(pUsdg), 25e6);
        assertEq(pUsdg.liquidateBorrow(bob, 20e6, address(pNvda)), 0);
        vm.stopPrank();
    }

    function testDustHolderIsFrozen() public {
        // Documented residual (SCOPE R2): any pSPY balance freezes the account while closed.
        _mint(pNvda, nvda, bob, 1e18);
        _enter(bob, address(pNvda));
        _mint(pSpy, spy, bob, 1e12);
        _enter(bob, address(pSpy));
        vm.prank(bob);
        pUsdg.borrow(50e6);
        source.set(0, 7);
        oracle.set(address(pNvda), 60e18);
        usdg.mint(liq, 25e6);
        vm.startPrank(liq);
        usdg.approve(address(pUsdg), 25e6);
        vm.expectRevert();
        pUsdg.liquidateBorrow(bob, 20e6, address(pNvda));
        vm.stopPrank();
        (uint256 err,,) = controller.getAccountLiquidity(bob);
        assertEq(err, 15, "SNAPSHOT_ERROR");
    }

    function testNvdaOnlyAccountUnchangedByGate() public {
        _mint(pNvda, nvda, bob, 1e18);
        _enter(bob, address(pNvda));
        vm.prank(bob);
        pUsdg.borrow(50e6);
        (uint256 e0, uint256 l0, uint256 s0) = controller.getAccountLiquidity(bob);
        source.set(0, 7);
        (uint256 e1, uint256 l1, uint256 s1) = controller.getAccountLiquidity(bob);
        assertEq(e0, e1);
        assertEq(l0, l1);
        assertEq(s0, s1);
        vm.prank(bob);
        assertEq(pUsdg.borrow(1e6), 0);
    }

    function testMarginAccountSnapshotExempt() public {
        FakeMarginAccount acct = new FakeMarginAccount();
        controller.registerIsolatedMarginAccount(address(acct));
        spy.mint(address(acct), 0.01e18);
        acct.call(address(spy), abi.encodeWithSignature("approve(address,uint256)", address(pSpy), 0.01e18));
        acct.call(address(pSpy), abi.encodeWithSignature("mint(uint256)", 0.01e18));
        source.set(0, 7);
        (uint256 err, uint256 tokens,,) = pSpy.getAccountSnapshot(address(acct));
        assertEq(err, 0);
        assertEq(tokens, pSpy.balanceOf(address(acct)));
    }

    function testUnreadableSourceFailsClosed() public {
        _aliceBorrows(10e6);
        source.setBroken(true);
        (uint256 err,,,) = pSpy.getAccountSnapshot(alice);
        assertEq(err, 255);
        vm.prank(alice);
        vm.expectRevert();
        pUsdg.borrow(1e6);
    }

    function testFuzzOpenSnapshotEqualsBase(uint96 amount) public {
        amount = uint96(bound(amount, 1e12, 0.2e18));
        _mint(pSpy, spy, alice, amount);
        (uint256 err, uint256 tokens, uint256 borrows, uint256 rate) = pSpy.getAccountSnapshot(alice);
        assertEq(err, 0);
        assertEq(tokens, pSpy.balanceOf(alice));
        assertEq(borrows, 0);
        assertEq(rate, pSpy.exchangeRateStored());
    }

    // ------------------------------------------------------------------ ordinary liquidation

    function testLiquidationOnlyWhenFresh() public {
        _aliceBorrows(42e6);
        oracle.set(address(pSpy), 600e18); // SPY -16 %
        (,, uint256 shortfall) = controller.getAccountLiquidity(alice);
        assertGt(shortfall, 0);
        usdg.mint(liq, 21e6);
        vm.prank(liq);
        usdg.approve(address(pUsdg), 21e6);

        source.set(0, 6); // stale
        vm.prank(liq);
        vm.expectRevert();
        pUsdg.liquidateBorrow(alice, 10e6, address(pSpy));

        source.set(600e18, 0);
        vm.prank(liq);
        assertEq(pUsdg.liquidateBorrow(alice, 10e6, address(pSpy)), 0);
        assertGt(pSpy.balanceOf(liq), 0);
        assertEq(pUsdg.borrowBalanceStored(alice), 32e6);
    }

    // ------------------------------------------------------------------ flash liquidator

    function _liquidatorStack(uint256 spyToUsdgRate) internal returns (SpyCollateralLiquidator l, SimpleFlashLoanVault v) {
        v = new SimpleFlashLoanVault(address(this));
        v.setTokenAllowed(address(usdg), true);
        v.setFeeBps(5);
        usdg.mint(address(this), 100e6);
        usdg.approve(address(v), 100e6);
        v.depositLiquidity(address(usdg), 100e6);
        RateRouter r = new RateRouter();
        r.setRate(address(spy), address(usdg), spyToUsdgRate);
        l = new SpyCollateralLiquidator(
            address(pUsdg), address(pSpy), address(v), address(r), address(source), address(0xBEEF), 100, 6
        );
        r.setOperator(address(l), true);
    }

    function testFlashLiquidatorProfitGoesToBeneficiary() public {
        _aliceBorrows(42e6);
        oracle.set(address(pSpy), 600e18);
        source.set(600e18, 0);
        (SpyCollateralLiquidator l,) = _liquidatorStack(600e6 * 9990 / 10_000); // pool 10 bp under oracle
        vm.prank(liq);
        uint256 profit = l.liquidate(alice, 20e6);
        assertGt(profit, 0);
        assertEq(usdg.balanceOf(address(0xBEEF)), profit);
        assertEq(usdg.balanceOf(address(l)), 0);
        assertEq(spy.balanceOf(address(l)), 0);
        assertEq(pSpy.balanceOf(address(l)), 0);
        assertEq(pUsdg.borrowBalanceStored(alice), 22e6);
        assertEq(usdg.balanceOf(liq), 0, "caller gains nothing");
    }

    function testFlashLiquidatorRefusesStaleAndHealthy() public {
        _aliceBorrows(42e6);
        (SpyCollateralLiquidator l,) = _liquidatorStack(716e6);
        vm.expectRevert(); // healthy: controller rejects
        l.liquidate(alice, 10e6);
        oracle.set(address(pSpy), 600e18);
        source.set(0, 7);
        vm.expectRevert(abi.encodeWithSelector(SpyCollateralLiquidator.SpyPriceUnavailable.selector, uint8(7)));
        l.liquidate(alice, 10e6);
        vm.expectRevert(SpyCollateralLiquidator.ZeroRepay.selector);
        l.liquidate(alice, 0);
    }

    function testFlashLiquidatorRevertsWhenPoolFarBelowOracle() public {
        _aliceBorrows(42e6);
        oracle.set(address(pSpy), 600e18);
        source.set(600e18, 0);
        (SpyCollateralLiquidator l,) = _liquidatorStack(560e6); // pool 6.7 % under oracle: floor (1 %) trips
        vm.expectRevert(bytes("MIN_OUT"));
        l.liquidate(alice, 20e6);
        assertEq(pUsdg.borrowBalanceStored(alice), 42e6);
    }

    function testFlashCallbackRejectsStrangers() public {
        (SpyCollateralLiquidator l, SimpleFlashLoanVault v) = _liquidatorStack(716e6);
        vm.expectRevert(SpyCollateralLiquidator.UnexpectedCallback.selector);
        l.onFlashLoan(address(l), address(usdg), 1, 0, "");
        vm.prank(address(v));
        vm.expectRevert(SpyCollateralLiquidator.UnexpectedCallback.selector);
        l.onFlashLoan(address(l), address(usdg), 1, 0, ""); // not inside liquidate()
        // someone else's flash loan naming this receiver
        vm.expectRevert();
        v.flashLoan(l, address(usdg), 1e6, "");
    }

    function testFlashCallbackRejectsReentryFromNonLender() public {
        _aliceBorrows(42e6);
        oracle.set(address(pSpy), 600e18);
        source.set(600e18, 0);
        SimpleFlashLoanVault v = new SimpleFlashLoanVault(address(this));
        v.setTokenAllowed(address(usdg), true);
        usdg.mint(address(this), 100e6);
        usdg.approve(address(v), 100e6);
        v.depositLiquidity(address(usdg), 100e6);
        ReenteringRouter r = new ReenteringRouter();
        SpyCollateralLiquidator l = new SpyCollateralLiquidator(
            address(pUsdg), address(pSpy), address(v), address(r), address(source), address(0xBEEF), 100, 6
        );
        vm.expectRevert(SpyCollateralLiquidator.UnexpectedCallback.selector);
        l.liquidate(alice, 20e6);
    }

    function testLiquidatorConstructorChecks() public {
        vm.expectRevert(SpyCollateralLiquidator.InvalidConfiguration.selector);
        new SpyCollateralLiquidator(address(pUsdg), address(pUsdg), address(pUsdg), address(pUsdg), address(source), address(1), 100, 6);
        vm.expectRevert(SpyCollateralLiquidator.InvalidConfiguration.selector);
        new SpyCollateralLiquidator(address(pUsdg), address(pSpy), address(pUsdg), address(pUsdg), address(source), address(0), 100, 6);
        vm.expectRevert(SpyCollateralLiquidator.InvalidConfiguration.selector);
        new SpyCollateralLiquidator(address(pUsdg), address(pSpy), address(pUsdg), address(pUsdg), address(source), address(1), 0, 6);
        vm.expectRevert(SpyCollateralLiquidator.InvalidConfiguration.selector);
        new SpyCollateralLiquidator(address(pUsdg), address(pSpy), address(pUsdg), address(pUsdg), address(source), address(1), 501, 6);
    }
}

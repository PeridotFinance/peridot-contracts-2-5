// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MarginManager} from "../contracts/margin/MarginManager.sol";
import {SmartMarginAccount} from "../contracts/margin/SmartMarginAccount.sol";
import {MarginRiskLib} from "../contracts/margin/MarginRiskLib.sol";
import {MockPeridottroller} from "./MockPeridottroller.sol";
import {MockErc20} from "./MockErc20.sol";
import {SimplePriceOracle} from "../contracts/SimplePriceOracle.sol";
import {PancakeV3RouterAdapter, IPancakeV3Router} from "../contracts/margin/PancakeV3RouterAdapter.sol";
import {PToken} from "../contracts/PToken.sol";

contract TestCToken is MockErc20 {
    MockErc20 public immutable underlyingToken;
    mapping(address => uint256) public borrowBalance;

    constructor(address underlying_, string memory name_, string memory symbol_) MockErc20(name_, symbol_, 8) {
        underlyingToken = MockErc20(underlying_);
    }

    function underlying() external view returns (address) {
        return address(underlyingToken);
    }

    function exchangeRateStored() external pure returns (uint256) {
        return 1e18;
    }

    function mint(uint256 amount) external returns (uint256) {
        require(underlyingToken.transferFrom(msg.sender, address(this), amount), "CToken: transfer fail");
        _mint(msg.sender, amount);
        return 0;
    }

    function redeem(uint256 amount) external returns (uint256) {
        _burn(msg.sender, amount);
        require(underlyingToken.transfer(msg.sender, amount), "CToken: redeem transfer");
        return 0;
    }

    function redeemUnderlying(uint256 amount) external returns (uint256) {
        _burn(msg.sender, amount);
        require(underlyingToken.transfer(msg.sender, amount), "CToken: redeem underlying transfer");
        return 0;
    }

    function borrow(uint256 amount) external returns (uint256) {
        borrowBalance[msg.sender] += amount;
        require(underlyingToken.transfer(msg.sender, amount), "CToken: borrow transfer");
        return 0;
    }

    function repayBorrow(uint256 amount) external returns (uint256) {
        require(underlyingToken.transferFrom(msg.sender, address(this), amount), "CToken: repay transfer");
        uint256 prev = borrowBalance[msg.sender];
        borrowBalance[msg.sender] = amount > prev ? 0 : prev - amount;
        return 0;
    }

    function borrowBalanceStored(address account) external view returns (uint256) {
        return borrowBalance[account];
    }
}

contract MockPancakeV3Router is IPancakeV3Router {
    uint256 public rate; // scaled 1e18

    function setRate(uint256 newRate) external {
        rate = newRate;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external override returns (uint256 amountOut) {
        MockErc20 tokenIn = MockErc20(params.tokenIn);
        MockErc20 tokenOut = MockErc20(params.tokenOut);

        tokenIn.transferFrom(msg.sender, address(this), params.amountIn);

        amountOut = (params.amountIn * rate) / 1e18;
        require(amountOut >= params.amountOutMinimum, "Router: min out");
        require(tokenOut.balanceOf(address(this)) >= amountOut, "Router: insufficient liquidity");

        tokenOut.transfer(params.recipient, amountOut);
    }
}

contract MarginManagerTest is Test {
    MarginManager public manager;
    MockPeridottroller public comptroller;
    SimplePriceOracle public oracle;
    MockErc20 public usdc;
    MockErc20 public weth;
    TestCToken public cUsdc;
    TestCToken public cWeth;
    PancakeV3RouterAdapter public router;
    MockPancakeV3Router public mockRouter;

    address public constant USER = address(0xA11CE);
    uint24 internal constant POOL_FEE = 500;
    uint16 internal constant MANAGER_SLIPPAGE_BPS = 50;

    function _tradeCalldata() internal pure returns (bytes memory) {
        return abi.encode(uint24(POOL_FEE), uint160(0));
    }

    function _managerMinOut(uint256 amountIn) internal pure returns (uint256) {
        return (amountIn * (10_000 - MANAGER_SLIPPAGE_BPS)) / (2000 * 10_000);
    }

    function setUp() public {
        comptroller = new MockPeridottroller();
        oracle = new SimplePriceOracle(3600);

        usdc = new MockErc20("USD Coin", "USDC", 18);
        weth = new MockErc20("Wrapped Ether", "WETH", 18);

        cUsdc = new TestCToken(address(usdc), "cUSDC", "cUSDC");
        cWeth = new TestCToken(address(weth), "cWETH", "cWETH");

        comptroller.setMarket(address(cUsdc), true, 0.8e18);
        comptroller.setMarket(address(cWeth), true, 0.75e18);

        oracle.setDirectPrice(address(usdc), 1e18);
        oracle.setDirectPrice(address(weth), 2000e18);

        manager = new MarginManager(address(comptroller), address(oracle));
        manager.configureMarket(address(cUsdc), address(usdc), true, true, true, true, true, 300, 50, 100);
        manager.configureMarket(address(cWeth), address(weth), true, true, true, true, true, 300, 50, 100);

        mockRouter = new MockPancakeV3Router();
        mockRouter.setRate(5e14);
        router = new PancakeV3RouterAdapter(address(this), address(mockRouter));
        router.setManager(address(manager));
        manager.setRouterAdapter(address(router));
        router.setPoolWhitelist(address(usdc), address(weth), POOL_FEE, true);

        usdc.mint(USER, 10_000e18);
        weth.mint(USER, 100e18);
        weth.mint(address(mockRouter), 1_000e18);
        weth.mint(address(this), 500e18);
        weth.approve(address(cWeth), 500e18);
        cWeth.mint(500e18);

        vm.startPrank(USER);
        usdc.approve(address(manager), type(uint256).max);
        weth.approve(address(manager), type(uint256).max);
        vm.stopPrank();
    }

    function _enable() internal returns (address) {
        vm.prank(USER);
        return manager.enableBorrowing();
    }

    function testDepositAndWithdraw() public {
        address sma = _enable();

        vm.prank(USER);
        manager.deposit(address(usdc), 1_000e18);

        assertEq(cUsdc.balanceOf(sma), 1_000e18, "cUSDC balance");

        vm.prank(USER);
        manager.withdraw(address(usdc), 400e18, USER);

        assertEq(usdc.balanceOf(USER), 10_000e18 - 1_000e18 + 400e18, "USDC after withdraw");
        assertEq(cUsdc.balanceOf(sma), 600e18, "cUSDC after withdraw");
    }

    function testBorrowRespectHealthFactor() public {
        address sma = _enable();

        vm.prank(USER);
        manager.deposit(address(usdc), 1_000e18);

        vm.prank(USER);
        manager.borrow(address(usdc), 700e18, USER);

        assertEq(usdc.balanceOf(USER), 10_000e18 - 1_000e18 + 700e18, "borrowed funds");
        assertEq(cUsdc.borrowBalanceStored(sma), 700e18, "borrow balance");

        vm.prank(USER);
        vm.expectRevert("Manager: health factor low");
        manager.borrow(address(usdc), 950e18, USER);
    }

    function testRepayUnlocksAfterLock() public {
        address sma = _enable();

        manager.setThresholds(10_000, 10_500, 10_800);

        vm.prank(USER);
        manager.deposit(address(usdc), 1_000e18);

        vm.prank(USER);
        manager.borrow(address(usdc), 400e18, address(0));

        vm.prank(USER);
        manager.withdraw(address(usdc), 500e18, USER);

        (,,,, bool locked) = manager.getAccountState(USER);
        assertTrue(locked, "should be locked");

        usdc.mint(USER, 200e18);

        vm.prank(USER);
        manager.deposit(address(usdc), 100e18);

        vm.prank(USER);
        manager.repay(address(usdc), 100e18);

        (,,,, bool lockedAfter) = manager.getAccountState(USER);
        assertFalse(lockedAfter, "should unlock");
    }

    function testRepayFromBalance() public {
        address sma = _enable();

        vm.prank(USER);
        manager.deposit(address(usdc), 1_000e18);

        vm.prank(USER);
        manager.borrow(address(weth), 0.2e18, address(0));

        uint256 borrowBefore = cWeth.borrowBalanceStored(sma);
        assertEq(weth.balanceOf(sma), 0.2e18, "weth balance before repay");

        vm.prank(USER);
        manager.repayFromBalance(address(weth), 0.05e18);

        uint256 borrowAfter = cWeth.borrowBalanceStored(sma);
        assertEq(borrowBefore - borrowAfter, 0.05e18, "repay amount mismatch");
    }

    function testOpenLeveragedPositionSameAsset() public {
        address sma = _enable();

        vm.prank(USER);
        manager.deposit(address(usdc), 1_000e18);

        vm.prank(USER);
        uint256 collateralSupplied = manager.openLeveragedPosition(address(usdc), address(usdc), 500e18, 0, bytes(""));

        assertEq(collateralSupplied, 500e18, "collateral supplied");
        assertEq(cUsdc.balanceOf(sma), 1_500e18, "leveraged collateral");
        assertEq(cUsdc.borrowBalanceStored(sma), 500e18, "borrow balance");

        (,,, uint256 hfAfter,) = manager.getAccountState(USER);
        assertGe(hfAfter, uint256(manager.hfLockBps()), "hf after leverage");
    }

    function testCloseLeveragedPositionSameAsset() public {
        address sma = _enable();

        vm.prank(USER);
        manager.deposit(address(usdc), 1_000e18);

        vm.prank(USER);
        manager.openLeveragedPosition(address(usdc), address(usdc), 500e18, 0, bytes(""));

        uint256 borrowBefore = cUsdc.borrowBalanceStored(sma);

        vm.prank(USER);
        manager.closeLeveragedPosition(address(usdc), address(usdc), 300e18, 300e18, 0, bytes(""));

        uint256 borrowAfter = cUsdc.borrowBalanceStored(sma);
        assertEq(borrowBefore - borrowAfter, 300e18, "repay difference");
    }

    function testTradeThroughRouter() public {
        address sma = _enable();

        vm.prank(USER);
        manager.deposit(address(usdc), 1_000e18);

        vm.prank(USER);
        manager.borrow(address(usdc), 200e18, address(0));

        uint256 amountIn = 100e18;
        uint256 minOut = _managerMinOut(amountIn);

        vm.prank(USER);
        uint256 amountOut = manager.trade(address(usdc), address(weth), amountIn, minOut, _tradeCalldata());

        assertEq(amountOut, 0.05e18, "trade amount out");
        assertEq(usdc.balanceOf(sma), 100e18, "remaining usdc in sma");
        assertEq(weth.balanceOf(sma), 0.05e18, "received weth");
    }

    function testSupplyFromBalanceAllowsAdditionalBorrow() public {
        address sma = _enable();

        vm.prank(USER);
        manager.deposit(address(usdc), 1_000e18);

        vm.prank(USER);
        manager.borrow(address(usdc), 700e18, address(0));

        vm.prank(USER);
        vm.expectRevert("Manager: health factor low");
        manager.borrow(address(usdc), 150e18, address(0));

        uint256 amountIn = 700e18;
        uint256 minOut = _managerMinOut(amountIn);

        vm.prank(USER);
        uint256 amountOut = manager.trade(address(usdc), address(weth), amountIn, minOut, _tradeCalldata());

        vm.prank(USER);
        manager.supplyFromBalance(address(weth), amountOut);

        vm.prank(USER);
        manager.borrow(address(usdc), 150e18, address(0));

        assertGt(cWeth.balanceOf(sma), 0, "supplied WETH collateral");
    }

    function testRedeemToBalanceKeepsFundsInternal() public {
        address sma = _enable();

        vm.prank(USER);
        manager.deposit(address(weth), 10e18);

        uint256 cTokenBefore = cWeth.balanceOf(sma);

        vm.prank(USER);
        manager.redeemToBalance(address(weth), 4e18);

        assertEq(weth.balanceOf(sma), 4e18, "underlying on SMA");
        uint256 cTokenAfter = cWeth.balanceOf(sma);
        assertEq(cTokenAfter, cTokenBefore - 4e18, "cTokens reduced");

        (,,, uint256 hfAfter,) = manager.getAccountState(USER);
        assertGe(hfAfter, uint256(manager.hfLockBps()), "health factor intact");
    }

    function testBorrowAccruesOpenFeeAndSweep() public {
        manager.setFees(50, 0);
        _enable();

        vm.prank(USER);
        manager.deposit(address(usdc), 1_000e18);

        uint256 userBalanceBefore = usdc.balanceOf(USER);

        vm.prank(USER);
        manager.borrow(address(usdc), 200e18, USER);

        uint256 fee = (200e18 * 50) / 10_000;
        uint256 netAmount = 200e18 - fee;

        assertEq(usdc.balanceOf(USER), userBalanceBefore + netAmount, "user net borrow");
        assertEq(manager.protocolFees(address(usdc)), fee, "fee accrued");

        uint256 ownerBalanceBefore = usdc.balanceOf(address(this));
        manager.sweepFees(address(usdc), address(this), fee);
        assertEq(manager.protocolFees(address(usdc)), 0, "fees cleared");
        assertEq(usdc.balanceOf(address(this)), ownerBalanceBefore + fee, "owner received fee");
    }

    function testWithdrawAccruesCloseFee() public {
        manager.setFees(0, 50);
        _enable();

        vm.prank(USER);
        manager.deposit(address(usdc), 1_000e18);

        uint256 userBalanceBefore = usdc.balanceOf(USER);

        vm.prank(USER);
        manager.withdraw(address(usdc), 500e18, USER);

        uint256 fee = (500e18 * 50) / 10_000;
        uint256 netAmount = 500e18 - fee;

        assertEq(usdc.balanceOf(USER), userBalanceBefore + netAmount, "user net withdraw");
        assertEq(manager.protocolFees(address(usdc)), fee, "close fee accrued");
    }

    function testFeeRecipientReceivesBorrowFee() public {
        address recipient = address(0xBEEF);
        manager.setFeeRecipient(recipient);
        manager.setFees(50, 0);
        _enable();

        vm.prank(USER);
        manager.deposit(address(usdc), 1_000e18);

        uint256 recipientBefore = usdc.balanceOf(recipient);

        vm.prank(USER);
        manager.borrow(address(usdc), 200e18, USER);

        uint256 fee = (200e18 * 50) / 10_000;
        assertEq(usdc.balanceOf(recipient), recipientBefore + fee, "recipient received fee");
        assertEq(manager.protocolFees(address(usdc)), 0, "no accrual held");
    }

    function testTradeSlippageGuard() public {
        _enable();

        vm.prank(USER);
        manager.deposit(address(usdc), 1_000e18);

        vm.prank(USER);
        manager.borrow(address(usdc), 100e18, address(0));

        uint256 amountIn = 1e18;
        uint256 minOut = _managerMinOut(amountIn);

        uint256 baseRate = 5e14;
        mockRouter.setRate((baseRate * 90) / 100);

        vm.prank(USER);
        vm.expectRevert(bytes("Router: min out"));
        manager.trade(address(usdc), address(weth), amountIn, minOut, _tradeCalldata());
    }

    function testTradeOracleDeviationGuard() public {
        _enable();

        vm.prank(USER);
        manager.deposit(address(usdc), 1_000e18);

        vm.prank(USER);
        manager.borrow(address(usdc), 100e18, address(0));

        uint256 amountIn = 1e18;
        uint256 minOut = _managerMinOut(amountIn);

        uint256 baseRate = 5e14;
        mockRouter.setRate((baseRate * 102) / 100);

        vm.prank(USER);
        vm.expectRevert(bytes("Manager: oracle deviation"));
        manager.trade(address(usdc), address(weth), amountIn, minOut, _tradeCalldata());
    }

    function testSupplyFromBalanceRevertsWhenDepositsPaused() public {
        address sma = _enable();

        vm.prank(USER);
        manager.deposit(address(usdc), 1_000e18);

        vm.prank(USER);
        weth.transfer(sma, 1e18);

        manager.configureMarket(address(cWeth), address(weth), true, false, true, true, true, 300, 50, 100);

        vm.prank(USER);
        vm.expectRevert("Manager: deposits paused");
        manager.supplyFromBalance(address(weth), 1e18);
    }

    function testOpenLeveragedPositionRespectsDepositsPaused() public {
        _enable();

        vm.prank(USER);
        manager.deposit(address(usdc), 1_000e18);

        manager.configureMarket(address(cWeth), address(weth), true, false, true, true, true, 300, 50, 100);

        vm.prank(USER);
        vm.expectRevert("Manager: deposits paused");
        manager.openLeveragedPosition(address(usdc), address(weth), 200e18, 0, _tradeCalldata());
    }

    function testOpenLeveragedPositionRespectsTradePause() public {
        _enable();

        vm.prank(USER);
        manager.deposit(address(usdc), 1_000e18);

        manager.configureMarket(address(cWeth), address(weth), true, true, true, true, false, 300, 50, 100);

        vm.prank(USER);
        vm.expectRevert("Manager: trades paused");
        manager.openLeveragedPosition(address(usdc), address(weth), 200e18, 0, _tradeCalldata());
    }

    function testTradeRevertsWhenTradesPaused() public {
        _enable();

        vm.prank(USER);
        manager.deposit(address(usdc), 1_000e18);

        manager.configureMarket(address(cUsdc), address(usdc), true, true, true, true, false, 300, 50, 100);

        uint256 amountIn = 100e18;
        uint256 minOut = _managerMinOut(amountIn);

        vm.prank(USER);
        vm.expectRevert("Manager: trades paused");
        manager.trade(address(usdc), address(weth), amountIn, minOut, _tradeCalldata());
    }

    function testDepositRevertsWhenOraclePriceZero() public {
        _enable();

        oracle.setDirectPrice(address(usdc), 0);

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(MarginRiskLib.PriceUnavailable.selector, address(cUsdc)));
        manager.deposit(address(usdc), 1_000e18);
    }

    function testRiskMetricsRevertWhenCollateralPriceZero() public {
        _enable();

        vm.prank(USER);
        manager.deposit(address(usdc), 1_000e18);

        oracle.setDirectPrice(address(usdc), 0);

        vm.expectRevert(abi.encodeWithSelector(MarginRiskLib.PriceUnavailable.selector, address(cUsdc)));
        manager.getAccountState(USER);
    }

    function testRiskMetricsRevertWhenBorrowPriceZero() public {
        _enable();

        vm.prank(USER);
        manager.deposit(address(usdc), 1_000e18);

        vm.prank(USER);
        manager.borrow(address(weth), 0.2e18, address(0));

        oracle.setDirectPrice(address(weth), 0);

        vm.expectRevert(abi.encodeWithSelector(MarginRiskLib.PriceUnavailable.selector, address(cWeth)));
        manager.getAccountMetrics(USER);
    }
}

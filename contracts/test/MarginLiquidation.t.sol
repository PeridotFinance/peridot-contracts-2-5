// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MarginManager} from "../contracts/margin/MarginManager.sol";
import {MarginLiquidation} from "../contracts/margin/MarginLiquidation.sol";
import {MockPeridottroller} from "./MockPeridottroller.sol";
import {MockErc20} from "./MockErc20.sol";
import {SimplePriceOracle} from "../contracts/SimplePriceOracle.sol";
import {PancakeV3RouterAdapter, IPancakeV3Router} from "../contracts/margin/PancakeV3RouterAdapter.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

contract TestCTokenLiquidation is MockErc20 {
    MockErc20 public immutable underlyingToken;
    mapping(address => uint256) public borrowBalance;
    uint256 public flashLoanFeeBps = 5; // 0.05%

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

    function liquidateBorrow(address borrower, uint256 repayAmount, address cTokenCollateral)
        external
        returns (uint256)
    {
        require(underlyingToken.transferFrom(msg.sender, address(this), repayAmount), "CToken: repay transfer");
        borrowBalance[borrower] = repayAmount >= borrowBalance[borrower] ? 0 : borrowBalance[borrower] - repayAmount;
        TestCTokenLiquidation(cTokenCollateral).seize(msg.sender, borrower, repayAmount);
        return 0;
    }

    function seize(address liquidator, address borrower, uint256 seizeTokens) external returns (uint256) {
        _transfer(borrower, liquidator, seizeTokens);
        return 0;
    }

    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        returns (bool)
    {
        require(token == address(underlyingToken), "FlashLoan: token");
        require(underlyingToken.balanceOf(address(this)) >= amount, "FlashLoan: liquidity");

        underlyingToken.transfer(address(receiver), amount);

        uint256 fee = (amount * flashLoanFeeBps) / 10000;
        require(
            receiver.onFlashLoan(msg.sender, token, amount, fee, data) == keccak256("ERC3156FlashBorrower.onFlashLoan"),
            "FlashLoan: callback"
        );

        uint256 expected = amount + fee;
        require(underlyingToken.balanceOf(address(this)) >= expected, "FlashLoan: not repaid");
        return true;
    }

    function borrowBalanceStored(address account) external view returns (uint256) {
        return borrowBalance[account];
    }
}

contract MockPancakeV3RouterLiquidation is IPancakeV3Router {
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

contract MarginLiquidationTest is Test {
    MarginManager public manager;
    MarginLiquidation public liquidation;
    MockPeridottroller public comptroller;
    SimplePriceOracle public oracle;
    MockErc20 public usdc;
    MockErc20 public weth;
    TestCTokenLiquidation public cUsdc;
    TestCTokenLiquidation public cWeth;
    PancakeV3RouterAdapter public router;
    MockPancakeV3RouterLiquidation public mockRouter;
    uint256 public actionDelay;

    address public constant USER = address(0xA11CE);
    address public constant LIQUIDATOR = address(0xB0B);
    uint24 internal constant POOL_FEE = 500;

    function setUp() public {
        comptroller = new MockPeridottroller();
        oracle = new SimplePriceOracle(3600);

        usdc = new MockErc20("USD Coin", "USDC", 18);
        weth = new MockErc20("Wrapped Ether", "WETH", 18);

        cUsdc = new TestCTokenLiquidation(address(usdc), "cUSDC", "cUSDC");
        cWeth = new TestCTokenLiquidation(address(weth), "cWETH", "cWETH");

        comptroller.setMarket(address(cUsdc), true, 0.8e18);
        comptroller.setMarket(address(cWeth), true, 0.75e18);

        oracle.setDirectPrice(address(usdc), 1e18);
        oracle.setDirectPrice(address(weth), 2000e18);

        manager = new MarginManager(address(comptroller), address(oracle));
        manager.configureMarket(address(cUsdc), address(usdc), true, true, true, true, true, 300, 50, 100);
        manager.configureMarket(address(cWeth), address(weth), true, true, true, true, true, 300, 50, 100);

        mockRouter = new MockPancakeV3RouterLiquidation();
        actionDelay = 1 days;
        router = new PancakeV3RouterAdapter(address(this), address(mockRouter), actionDelay);
        liquidation = new MarginLiquidation(address(manager), address(this));

        router.queueSetManager(address(manager));
        router.queueSetPoolWhitelist(address(usdc), address(weth), POOL_FEE, true);
        router.queueSetOperator(address(liquidation), true);
        vm.warp(block.timestamp + actionDelay);
        router.setManager(address(manager));
        router.setPoolWhitelist(address(usdc), address(weth), POOL_FEE, true);
        router.setOperator(address(liquidation), true);
        manager.setRouterAdapter(address(router));

        liquidation.setAdapter(address(router), true);

        usdc.mint(USER, 10_000e18);
        weth.mint(USER, 50e18);
        weth.mint(address(this), 500e18);
        weth.mint(address(mockRouter), 1_000e18);

        // Seed WETH liquidity in cWETH for flashloans
        weth.approve(address(cWeth), 200e18);
        cWeth.mint(200e18);

        vm.startPrank(USER);
        usdc.approve(address(manager), type(uint256).max);
        weth.approve(address(manager), type(uint256).max);
        vm.stopPrank();
    }

    function _enable() internal returns (address) {
        vm.prank(USER);
        return manager.enableBorrowing();
    }

    function testLiquidationFlow() public {
        address sma = _enable();

        vm.prank(USER);
        manager.deposit(address(usdc), 1_000e18);

        vm.prank(USER);
        manager.borrow(address(weth), 0.2e18, address(0)); // borrow 0.2 WETH

        // push account underwater by increasing WETH price
        oracle.setDirectPrice(address(weth), 5_000e18);

        MarginLiquidation.SwapParams memory swapParams = MarginLiquidation.SwapParams({
            adapter: address(router), minAmountOut: 0, data: abi.encode(uint24(500), uint160(0))
        });

        mockRouter.setRate(2e18); // 1 USDC -> 2 WETH for testing

        vm.prank(LIQUIDATOR);
        liquidation.liquidate(USER, address(cWeth), address(cUsdc), 0.1e18, LIQUIDATOR, 0, swapParams);

        uint256 borrowAfter = cWeth.borrowBalanceStored(sma);
        assertLt(borrowAfter, 0.2e18, "borrow not reduced");

        assertGt(weth.balanceOf(LIQUIDATOR), 0, "no profit transferred");
    }

    function testLiquidationRevertsWhenHealthy() public {
        _enable();

        vm.prank(USER);
        manager.deposit(address(usdc), 2_000e18);

        vm.prank(USER);
        manager.borrow(address(weth), 0.05e18, address(0));

        MarginLiquidation.SwapParams memory swapParams = MarginLiquidation.SwapParams({
            adapter: address(router), minAmountOut: 0, data: abi.encode(uint24(500), uint160(0))
        });

        vm.prank(LIQUIDATOR);
        vm.expectRevert("Liquidation: account healthy");
        liquidation.liquidate(USER, address(cWeth), address(cUsdc), 0.1e18, LIQUIDATOR, 0, swapParams);
    }
}

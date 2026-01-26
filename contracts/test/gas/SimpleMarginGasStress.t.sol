// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MarginManager} from "../../contracts/margin/MarginManager.sol";
import {SmartMarginAccount} from "../../contracts/margin/SmartMarginAccount.sol";
import {MockPeridottroller} from "../MockPeridottroller.sol";
import {MockErc20} from "../MockErc20.sol";
import {SimplePriceOracle} from "../../contracts/SimplePriceOracle.sol";
import {PancakeV3RouterAdapter, IPancakeV3Router} from "../../contracts/margin/PancakeV3RouterAdapter.sol";

contract TestCToken is MockErc20 {
    MockErc20 public immutable underlyingToken;
    mapping(address => uint256) public borrowBalance;

    constructor(
        address underlying_,
        string memory name_,
        string memory symbol_
    ) MockErc20(name_, symbol_, 8) {
        underlyingToken = MockErc20(underlying_);
    }

    function underlying() external view returns (address) {
        return address(underlyingToken);
    }

    function exchangeRateStored() external pure returns (uint256) {
        return 1e18;
    }

    function mint(uint256 amount) external returns (uint256) {
        require(
            underlyingToken.transferFrom(msg.sender, address(this), amount),
            "CToken: transfer fail"
        );
        _mint(msg.sender, amount);
        return 0;
    }

    function redeem(uint256 amount) external returns (uint256) {
        _burn(msg.sender, amount);
        require(
            underlyingToken.transfer(msg.sender, amount),
            "CToken: redeem transfer"
        );
        return 0;
    }

    function redeemUnderlying(uint256 amount) external returns (uint256) {
        _burn(msg.sender, amount);
        require(
            underlyingToken.transfer(msg.sender, amount),
            "CToken: redeem underlying transfer"
        );
        return 0;
    }

    function borrow(uint256 amount) external returns (uint256) {
        borrowBalance[msg.sender] += amount;
        require(
            underlyingToken.transfer(msg.sender, amount),
            "CToken: borrow transfer"
        );
        return 0;
    }

    function repayBorrow(uint256 amount) external returns (uint256) {
        require(
            underlyingToken.transferFrom(msg.sender, address(this), amount),
            "CToken: repay transfer"
        );
        uint256 prev = borrowBalance[msg.sender];
        borrowBalance[msg.sender] = amount > prev ? 0 : prev - amount;
        return 0;
    }

    function borrowBalanceStored(
        address account
    ) external view returns (uint256) {
        return borrowBalance[account];
    }
}

contract MockPancakeV3Router is IPancakeV3Router {
    uint256 public rate; // scaled 1e18

    function setRate(uint256 newRate) external {
        rate = newRate;
    }

    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external override returns (uint256 amountOut) {
        MockErc20 tokenIn = MockErc20(params.tokenIn);
        MockErc20 tokenOut = MockErc20(params.tokenOut);

        tokenIn.transferFrom(msg.sender, address(this), params.amountIn);

        amountOut = (params.amountIn * rate) / 1e18;
        require(amountOut >= params.amountOutMinimum, "Router: min out");
        require(
            tokenOut.balanceOf(address(this)) >= amountOut,
            "Router: insufficient liquidity"
        );

        tokenOut.transfer(params.recipient, amountOut);
    }
}

/**
 * @title SimpleMarginGasStressTest
 * @notice Gas stress tests for margin trading system
 */
contract SimpleMarginGasStressTest is Test {
    MarginManager public manager;
    MockPeridottroller public comptroller;
    SimplePriceOracle public oracle;
    MockErc20 public usdc;
    MockErc20 public weth;
    MockErc20 public wbtc;
    TestCToken public cUsdc;
    TestCToken public cWeth;
    TestCToken public cWbtc;
    PancakeV3RouterAdapter public router;
    MockPancakeV3Router public mockRouter;
    uint256 public actionDelay;

    address[] public users;
    uint256 constant NUM_USERS = 50;
    uint24 constant POOL_FEE = 500;

    function setUp() public {
        comptroller = new MockPeridottroller();
        oracle = new SimplePriceOracle(3600);

        usdc = new MockErc20("USD Coin", "USDC", 18);
        weth = new MockErc20("Wrapped Ether", "WETH", 18);
        wbtc = new MockErc20("Wrapped Bitcoin", "WBTC", 8);

        cUsdc = new TestCToken(address(usdc), "cUSDC", "cUSDC");
        cWeth = new TestCToken(address(weth), "cWETH", "cWETH");
        cWbtc = new TestCToken(address(wbtc), "cWBTC", "cWBTC");

        comptroller.setMarket(address(cUsdc), true, 0.8e18);
        comptroller.setMarket(address(cWeth), true, 0.75e18);
        comptroller.setMarket(address(cWbtc), true, 0.7e18);

        oracle.setDirectPrice(address(usdc), 1e18);
        oracle.setDirectPrice(address(weth), 2000e18);
        oracle.setDirectPrice(address(wbtc), 40000e18);

        mockRouter = new MockPancakeV3Router();
        mockRouter.setRate(1e18); // 1:1 default

        actionDelay = 1 days;
        router = new PancakeV3RouterAdapter(address(this), address(mockRouter), actionDelay);

        manager = new MarginManager(address(comptroller), address(oracle));
        router.queueSetManager(address(manager));
        router.queueSetPoolWhitelist(address(usdc), address(weth), POOL_FEE, true);
        router.queueSetPoolWhitelist(address(weth), address(wbtc), POOL_FEE, true);
        vm.warp(block.timestamp + actionDelay);
        router.setManager(address(manager));
        router.setPoolWhitelist(address(usdc), address(weth), POOL_FEE, true);
        router.setPoolWhitelist(address(weth), address(wbtc), POOL_FEE, true);
        manager.queueSetRouterAdapter(address(router));
        vm.warp(block.timestamp + manager.actionDelay());
        manager.setRouterAdapter(address(router));

        manager.queueConfigureMarket(
            address(cUsdc),
            address(usdc),
            true,
            true,
            true,
            true,
            true,
            500,
            200,
            500
        );
        manager.queueConfigureMarket(
            address(cWeth),
            address(weth),
            true,
            true,
            true,
            true,
            true,
            500,
            200,
            500
        );
        manager.queueConfigureMarket(
            address(cWbtc),
            address(wbtc),
            true,
            true,
            true,
            true,
            true,
            500,
            200,
            500
        );
        vm.warp(block.timestamp + manager.actionDelay());
        manager.configureMarket(
            address(cUsdc),
            address(usdc),
            true,
            true,
            true,
            true,
            true,
            500,
            200,
            500
        );
        manager.configureMarket(
            address(cWeth),
            address(weth),
            true,
            true,
            true,
            true,
            true,
            500,
            200,
            500
        );
        manager.configureMarket(
            address(cWbtc),
            address(wbtc),
            true,
            true,
            true,
            true,
            true,
            500,
            200,
            500
        );

        // Create users and mint tokens
        for (uint256 i = 0; i < NUM_USERS; i++) {
            address user = address(uint160(0x20000 + i));
            users.push(user);
            usdc.mint(user, 1000000e18);
            weth.mint(user, 500e18);
            wbtc.mint(user, 25e8);
        }

        // Provide liquidity to cTokens
        usdc.mint(address(this), 10000000e18);
        weth.mint(address(this), 5000e18);
        wbtc.mint(address(this), 125e8);

        usdc.approve(address(cUsdc), type(uint256).max);
        weth.approve(address(cWeth), type(uint256).max);
        wbtc.approve(address(cWbtc), type(uint256).max);

        cUsdc.mint(1000000e18);
        cWeth.mint(500e18);
        cWbtc.mint(12.5e8);
    }

    function testGas_ManyUsersCreateAccounts() public {
        console.log("\n=== Many Users Create Accounts ===");

        uint256 firstGas = _measureCreateAccountGas(users[0]);
        console.log("1st account creation gas:", firstGas);

        for (uint256 i = 1; i < 25; i++) {
            vm.prank(users[i]);
            manager.enableBorrowing();
        }

        uint256 midGas = _measureCreateAccountGas(users[25]);
        console.log("25th account creation gas:", midGas);

        for (uint256 i = 26; i < 49; i++) {
            vm.prank(users[i]);
            manager.enableBorrowing();
        }

        uint256 lastGas = _measureCreateAccountGas(users[49]);
        console.log("49th account creation gas:", lastGas);

        assertLt(lastGas, 300000, "Account creation should stay under 300k");
    }

    function testGas_DepositAcrossMultipleMarkets() public {
        console.log("\n=== Deposit Across Multiple Markets ===");

        address user = users[0];
        vm.startPrank(user);
        manager.enableBorrowing();

        usdc.approve(address(manager), type(uint256).max);
        weth.approve(address(manager), type(uint256).max);
        wbtc.approve(address(manager), type(uint256).max);

        uint256 deposit1Gas = gasleft();
        manager.deposit(address(usdc), 10000e18);
        deposit1Gas = deposit1Gas - gasleft();
        console.log("1st market deposit gas:", deposit1Gas);

        uint256 deposit2Gas = gasleft();
        manager.deposit(address(weth), 5e18);
        deposit2Gas = deposit2Gas - gasleft();
        console.log("2nd market deposit gas:", deposit2Gas);

        uint256 deposit3Gas = gasleft();
        manager.deposit(address(wbtc), 0.1e8);
        deposit3Gas = deposit3Gas - gasleft();
        console.log("3rd market deposit gas:", deposit3Gas);

        vm.stopPrank();

        assertLt(deposit3Gas, 600000, "3rd deposit should stay under 600k");
    }

    function testGas_BorrowFromMultipleMarkets() public {
        console.log("\n=== Borrow From Multiple Markets ===");

        address user = users[0];
        vm.startPrank(user);
        manager.enableBorrowing();

        usdc.approve(address(manager), type(uint256).max);
        manager.deposit(address(usdc), 100000e18);

        uint256 borrow1Gas = gasleft();
        manager.borrow(address(weth), 10e18, user);
        borrow1Gas = borrow1Gas - gasleft();
        console.log("1st borrow gas:", borrow1Gas);

        uint256 borrow2Gas = gasleft();
        manager.borrow(address(wbtc), 0.5e8, user);
        borrow2Gas = borrow2Gas - gasleft();
        console.log("2nd borrow gas:", borrow2Gas);

        vm.stopPrank();

        assertLt(borrow2Gas, 700000, "2nd borrow should stay under 700k");
    }

    function testGas_GetAccountMetricsWithMultipleMarkets() public {
        console.log("\n=== Get Account Metrics With Multiple Markets ===");

        address user = users[0];
        vm.startPrank(user);
        manager.enableBorrowing();

        usdc.approve(address(manager), type(uint256).max);
        weth.approve(address(manager), type(uint256).max);
        wbtc.approve(address(manager), type(uint256).max);

        manager.deposit(address(usdc), 50000e18);
        manager.deposit(address(weth), 10e18);
        manager.deposit(address(wbtc), 0.5e8);

        manager.borrow(address(usdc), 5000e18, user);
        manager.borrow(address(weth), 1e18, user);

        vm.stopPrank();

        uint256 metricsGas = gasleft();
        manager.getAccountMetrics(user);
        metricsGas = metricsGas - gasleft();
        console.log("Get metrics gas with 3 markets:", metricsGas);

        assertLt(metricsGas, 500000, "Metrics should stay under 500k");
    }

    function testGas_WithdrawWithMultipleMarkets() public {
        console.log("\n=== Withdraw With Multiple Markets ===");

        address user = users[0];
        vm.startPrank(user);
        manager.enableBorrowing();

        usdc.approve(address(manager), type(uint256).max);
        weth.approve(address(manager), type(uint256).max);
        wbtc.approve(address(manager), type(uint256).max);

        manager.deposit(address(usdc), 50000e18);
        manager.deposit(address(weth), 10e18);
        manager.deposit(address(wbtc), 0.5e8);

        uint256 withdrawGas = gasleft();
        manager.withdraw(address(usdc), 5000e18, user);
        withdrawGas = withdrawGas - gasleft();
        console.log("Withdraw gas with 3 markets:", withdrawGas);

        vm.stopPrank();

        assertLt(withdrawGas, 700000, "Withdraw should stay under 700k");
    }

    function testGas_RepayWithMultipleBorrows() public {
        console.log("\n=== Repay With Multiple Borrows ===");

        address user = users[0];
        vm.startPrank(user);
        manager.enableBorrowing();

        usdc.approve(address(manager), type(uint256).max);
        weth.approve(address(manager), type(uint256).max);
        wbtc.approve(address(manager), type(uint256).max);

        manager.deposit(address(usdc), 100000e18);

        manager.borrow(address(weth), 10e18, user);
        manager.borrow(address(wbtc), 0.5e8, user);

        uint256 repayGas = gasleft();
        manager.repay(address(weth), 1e18);
        repayGas = repayGas - gasleft();
        console.log("Repay gas with 2 borrows:", repayGas);

        vm.stopPrank();

        assertLt(repayGas, 600000, "Repay should stay under 600k");
    }

    function testGas_ManyUsersWithPositions() public {
        console.log("\n=== Many Users With Positions ===");

        // 20 users create accounts and deposit
        for (uint256 i = 0; i < 20; i++) {
            vm.startPrank(users[i]);
            manager.enableBorrowing();

            usdc.approve(address(manager), type(uint256).max);
            weth.approve(address(manager), type(uint256).max);

            manager.deposit(address(usdc), 10000e18);
            manager.deposit(address(weth), 2e18);
            vm.stopPrank();
        }

        // Measure gas for 21st user
        vm.startPrank(users[20]);
        manager.enableBorrowing();
        usdc.approve(address(manager), type(uint256).max);

        uint256 depositGas = gasleft();
        manager.deposit(address(usdc), 10000e18);
        depositGas = depositGas - gasleft();
        console.log("Deposit gas with 20 existing users:", depositGas);

        vm.stopPrank();

        // Gas should not increase significantly with more users
        assertLt(depositGas, 600000, "Deposit should stay under 600k");
    }

    function _measureCreateAccountGas(address user) internal returns (uint256) {
        vm.startPrank(user);
        uint256 gasBefore = gasleft();
        manager.enableBorrowing();
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();
        return gasUsed;
    }
}

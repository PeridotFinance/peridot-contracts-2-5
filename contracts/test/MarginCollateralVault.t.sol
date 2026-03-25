// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {AtomicMarginExecutor} from "../contracts/margin/AtomicMarginExecutor.sol";
import {MarginCollateralVault} from "../contracts/margin/MarginCollateralVault.sol";
import {SimpleFlashLoanVault} from "../contracts/margin/SimpleFlashLoanVault.sol";
import {MarginManager} from "../contracts/margin/MarginManager.sol";
import {MockPeridottroller} from "./MockPeridottroller.sol";
import {MockErc20} from "./MockErc20.sol";
import {SimplePriceOracle} from "../contracts/SimplePriceOracle.sol";
import {MockRouterAdapter} from "./mocks/MockRouterAdapter.sol";

contract TestCTokenVault is MockErc20 {
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

contract MarginCollateralVaultTest is Test {
    MockPeridottroller internal comptroller;
    SimplePriceOracle internal oracle;
    MarginManager internal configManager;
    AtomicMarginExecutor internal executor;
    MarginCollateralVault internal vault;
    SimpleFlashLoanVault internal flashVault;
    MockRouterAdapter internal router;

    MockErc20 internal usdt;
    MockErc20 internal pToken;
    TestCTokenVault internal pUsdt;
    TestCTokenVault internal pP;

    address internal constant USER = address(0xA11CE);

    function setUp() public {
        comptroller = new MockPeridottroller();
        oracle = new SimplePriceOracle(3600);

        usdt = new MockErc20("Mock USDT", "USDT", 18);
        pToken = new MockErc20("Mock P", "P", 18);

        pUsdt = new TestCTokenVault(address(usdt), "pUSDT", "pUSDT");
        pP = new TestCTokenVault(address(pToken), "pP", "pP");

        comptroller.setMarket(address(pUsdt), true, 0.8e18);
        comptroller.setMarket(address(pP), true, 0.5e18);

        oracle.setDirectPrice(address(usdt), 1e18);
        oracle.setDirectPrice(address(pToken), 1e18);

        configManager = new MarginManager(address(comptroller), address(oracle));
        _queueConfigureMarket(address(pUsdt), address(usdt), true, true, true, true, true, 300, 50, 100);
        _queueConfigureMarket(address(pP), address(pToken), true, true, true, true, true, 300, 50, 100);

        router = new MockRouterAdapter();
        pToken.mint(address(router), 10_000e18);
        _queueSetRouterAdapter(address(router));

        flashVault = new SimpleFlashLoanVault(address(this));
        flashVault.setTokenAllowed(address(usdt), true);
        flashVault.setFeeBps(5);
        usdt.mint(address(this), 10_000e18);
        usdt.approve(address(flashVault), type(uint256).max);
        flashVault.depositLiquidity(address(usdt), 1_000e18);
        _queueSetFlashloanProvider(address(flashVault));

        usdt.approve(address(pUsdt), type(uint256).max);
        pToken.approve(address(pP), type(uint256).max);
        pToken.mint(address(this), 10_000e18);
        pUsdt.mint(2_000e18);
        pP.mint(2_000e18);

        executor = new AtomicMarginExecutor(address(configManager));
        vault = new MarginCollateralVault(address(executor), address(this));
        executor.setMarginCollateralVault(address(vault));
        vault.setPTokenAllowed(address(pUsdt), true);
        vault.setPTokenAllowed(address(pP), true);

        vm.prank(USER);
        executor.enableBorrowing();

        usdt.mint(USER, 100e18);
        vm.startPrank(USER);
        usdt.approve(address(pUsdt), type(uint256).max);
        pUsdt.mint(10e18);
        pUsdt.approve(address(vault), type(uint256).max);
        usdt.approve(address(executor), type(uint256).max);
        vm.stopPrank();
    }

    function testMoveToMarginTransfersPTokenIntoSma() public {
        address sma = executor.getAccount(USER).sma;

        vm.prank(USER);
        vault.moveToMargin(address(pUsdt), 5e18);

        assertEq(pUsdt.balanceOf(USER), 5e18, "user earning balance not reduced");
        assertEq(pUsdt.balanceOf(sma), 5e18, "sma did not receive pTokens");
        assertEq(vault.marginBalance(USER, address(pUsdt)), 5e18, "vault ledger not updated");

        (, uint256 collateralValue,,,) = executor.getAccountState(USER);
        assertEq(collateralValue, 4e18, "collateral value should include moved pTokens");
    }

    function testMoveToEarningWithdrawsFreeCollateral() public {
        address sma = executor.getAccount(USER).sma;

        vm.prank(USER);
        vault.moveToMargin(address(pUsdt), 5e18);

        vm.prank(USER);
        vault.moveToEarning(address(pUsdt), 2e18);

        assertEq(pUsdt.balanceOf(USER), 7e18, "user did not receive pTokens back");
        assertEq(pUsdt.balanceOf(sma), 3e18, "sma balance incorrect after withdraw");
        assertEq(vault.marginBalance(USER, address(pUsdt)), 3e18, "vault ledger incorrect after withdraw");
    }

    function testMoveToEarningBlocksUsedCollateral() public {
        vm.startPrank(USER);
        vault.moveToMargin(address(pUsdt), 5e18);
        executor.openLeveragedPositionAtomic(address(usdt), address(pToken), 1e18, 300, 2.985e18, bytes(""));
        vm.expectRevert(bytes("Executor: exceeds free collateral"));
        vault.moveToEarning(address(pUsdt), 5e18);
        vm.stopPrank();
    }

    function _queueConfigureMarket(
        address cToken,
        address underlying,
        bool active,
        bool depositsEnabled,
        bool borrowsEnabled,
        bool withdrawalsEnabled,
        bool tradesEnabled,
        uint16 maxLeverageX100,
        uint16 tradeSlippageBps,
        uint16 oracleDeviationBps
    ) internal {
        configManager.queueConfigureMarket(
            cToken,
            underlying,
            active,
            depositsEnabled,
            borrowsEnabled,
            withdrawalsEnabled,
            tradesEnabled,
            maxLeverageX100,
            tradeSlippageBps,
            oracleDeviationBps
        );
        vm.warp(block.timestamp + configManager.actionDelay());
        configManager.configureMarket(
            cToken,
            underlying,
            active,
            depositsEnabled,
            borrowsEnabled,
            withdrawalsEnabled,
            tradesEnabled,
            maxLeverageX100,
            tradeSlippageBps,
            oracleDeviationBps
        );
    }

    function _queueSetRouterAdapter(address adapter) internal {
        configManager.queueSetRouterAdapter(adapter);
        vm.warp(block.timestamp + configManager.actionDelay());
        configManager.setRouterAdapter(adapter);
    }

    function _queueSetFlashloanProvider(address lender) internal {
        configManager.queueSetFlashloanProvider(lender);
        vm.warp(block.timestamp + configManager.actionDelay());
        configManager.setFlashloanProvider(lender);
    }
}

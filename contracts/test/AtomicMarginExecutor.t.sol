// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MarginManager} from "../contracts/margin/MarginManager.sol";
import {AtomicMarginExecutor} from "../contracts/margin/AtomicMarginExecutor.sol";
import {AtomicMarginLiquidation} from "../contracts/margin/AtomicMarginLiquidation.sol";
import {SimpleFlashLoanVault} from "../contracts/margin/SimpleFlashLoanVault.sol";
import {MarginRiskLib} from "../contracts/margin/MarginRiskLib.sol";
import {MockPeridottroller} from "./MockPeridottroller.sol";
import {MockErc20} from "./MockErc20.sol";
import {SimplePriceOracle} from "../contracts/SimplePriceOracle.sol";
import {PToken} from "../contracts/PToken.sol";
import {MockRouterAdapter} from "./mocks/MockRouterAdapter.sol";
import {IERC3156FlashBorrower} from "../contracts/PTokenInterfaces.sol";

contract TestCTokenAtomic is MockErc20 {
    MockErc20 public immutable underlyingToken;
    mapping(address => uint256) public borrowBalance;
    uint256 public liquidationIncentiveBps = 11000;

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
        require(
            underlyingToken.transferFrom(msg.sender, address(this), repayAmount),
            "CToken: liquidate transfer"
        );
        uint256 prev = borrowBalance[borrower];
        borrowBalance[borrower] = repayAmount >= prev ? 0 : prev - repayAmount;
        uint256 seizeTokens = (repayAmount * liquidationIncentiveBps) / 10000;
        TestCTokenAtomic(cTokenCollateral).seize(msg.sender, borrower, seizeTokens);
        return 0;
    }

    function seize(address liquidator, address borrower, uint256 seizeTokens) external returns (uint256) {
        _transfer(borrower, liquidator, seizeTokens);
        return 0;
    }

    function borrowBalanceStored(address account) external view returns (uint256) {
        return borrowBalance[account];
    }
}

contract TestFlashLoanBorrower is IERC3156FlashBorrower {
    bytes32 private constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata)
        external
        override
        returns (bytes32)
    {
        MockErc20(token).approve(msg.sender, amount + fee);
        return CALLBACK_SUCCESS;
    }
}

contract AtomicMarginExecutorTest is Test {
    MockPeridottroller internal comptroller;
    SimplePriceOracle internal oracle;
    MarginManager internal configManager;
    AtomicMarginExecutor internal executor;
    AtomicMarginLiquidation internal liquidation;
    SimpleFlashLoanVault internal vault;
    MockRouterAdapter internal router;

    MockErc20 internal usdt;
    MockErc20 internal pToken;
    TestCTokenAtomic internal pUsdt;
    TestCTokenAtomic internal pP;

    address internal constant USER = address(0xA11CE);

    function setUp() public {
        comptroller = new MockPeridottroller();
        oracle = new SimplePriceOracle(3600);

        usdt = new MockErc20("Mock USDT", "USDT", 18);
        pToken = new MockErc20("Mock P", "P", 18);

        pUsdt = new TestCTokenAtomic(address(usdt), "pUSDT", "pUSDT");
        pP = new TestCTokenAtomic(address(pToken), "pP", "pP");

        comptroller.setMarket(address(pUsdt), true, 0.8e18);
        comptroller.setMarket(address(pP), true, 0.75e18);

        oracle.setDirectPrice(address(usdt), 1e18);
        oracle.setDirectPrice(address(pToken), 1e18);

        configManager = new MarginManager(address(comptroller), address(oracle));
        _queueConfigureMarket(address(pUsdt), address(usdt), true, true, true, true, true, 300, 50, 100);
        _queueConfigureMarket(address(pP), address(pToken), true, true, true, true, true, 300, 50, 100);

        router = new MockRouterAdapter();
        pToken.mint(address(router), 10_000e18);
        _queueSetRouterAdapter(address(router));

        vault = new SimpleFlashLoanVault(address(this));
        vault.setTokenAllowed(address(usdt), true);
        vault.setTokenAllowed(address(pToken), true);
        vault.setFeeBps(5);

        usdt.mint(address(this), 10_000e18);
        pToken.mint(address(this), 10_000e18);

        usdt.approve(address(vault), type(uint256).max);
        pToken.approve(address(vault), type(uint256).max);
        vault.depositLiquidity(address(usdt), 1_000e18);
        vault.depositLiquidity(address(pToken), 1_000e18);

        _queueSetFlashloanProvider(address(vault));

        usdt.approve(address(pUsdt), type(uint256).max);
        pToken.approve(address(pP), type(uint256).max);
        pUsdt.mint(2_000e18);
        pP.mint(2_000e18);

        executor = new AtomicMarginExecutor(address(configManager));
        liquidation = new AtomicMarginLiquidation(
            address(executor),
            address(configManager),
            address(this)
        );
        liquidation.setAdapter(address(router), true);

        usdt.mint(USER, 100e18);
        vm.prank(USER);
        usdt.approve(address(executor), type(uint256).max);
    }

    function testFlashLoanVaultExecutesAndCollectsFee() public {
        TestFlashLoanBorrower borrower = new TestFlashLoanBorrower();
        usdt.mint(address(borrower), 1e18);

        uint256 liquidityBefore = usdt.balanceOf(address(vault));
        uint256 amount = 10e18;
        uint256 fee = vault.flashFee(address(usdt), amount);

        bool ok = vault.flashLoan(borrower, address(usdt), amount, bytes(""));

        assertTrue(ok, "flashloan failed");
        assertEq(usdt.balanceOf(address(vault)), liquidityBefore + fee, "fee not accrued");
    }

    function testAtomicLongUsesExternalVaultAndOpensPosition() public {
        vm.prank(USER);
        address sma = executor.enableBorrowing();

        (uint256 totalNotional, uint256 borrowAmount, uint256 flashFee) =
            executor.previewAtomicLong(address(usdt), 1e18, 200);
        assertEq(totalNotional, 2e18, "bad total notional");
        assertEq(borrowAmount, 1e18, "bad borrow amount");
        assertEq(flashFee, 5e14, "bad flash fee");

        vm.prank(USER);
        uint256 baseAcquired =
            executor.openLeveragedPositionAtomic(address(usdt), address(pToken), 1e18, 200, 1.99e18, bytes(""));

        assertEq(baseAcquired, 2e18, "unexpected base acquired");
        assertEq(pP.balanceOf(sma), 2e18, "base collateral not minted");
        assertEq(pUsdt.borrowBalanceStored(sma), 1e18 + 5e14, "borrow not opened");
        assertEq(usdt.balanceOf(address(vault)), 1_000e18 + 5e14, "vault not repaid with fee");

        (, uint256 collateralValue, uint256 borrowValue, uint256 healthFactorBps,) =
            executor.getAccountState(USER);
        assertEq(collateralValue, 1.5e18, "bad collateral value");
        assertEq(borrowValue, 1e18 + 5e14, "bad borrow value");
        assertGe(healthFactorBps, uint256(configManager.hfLockBps()), "health factor too low");
    }

    function testCloseLeveragedPositionRepaysDebt() public {
        vm.startPrank(USER);
        address sma = executor.enableBorrowing();
        executor.openLeveragedPositionAtomic(address(usdt), address(pToken), 1e18, 200, 1.99e18, bytes(""));

        uint256 debtBefore = pUsdt.borrowBalanceStored(sma);
        assertEq(debtBefore, 1e18 + 5e14, "unexpected initial debt");

        uint256 repaid = executor.closeLeveragedPosition(
            address(pToken),
            address(usdt),
            0.5e18,
            0.5e18,
            0.5e18,
            bytes("")
        );
        vm.stopPrank();

        assertEq(repaid, 0.5e18, "wrong repaid amount");
        assertEq(pUsdt.borrowBalanceStored(sma), 0.5005e18, "debt not reduced");
        assertEq(pP.balanceOf(sma), 1.5e18, "collateral not reduced");

        (, uint256 collateralValue, uint256 borrowValue, uint256 healthFactorBps,) =
            executor.getAccountState(USER);
        assertEq(collateralValue, 1.125e18, "bad collateral value after close");
        assertEq(borrowValue, 0.5005e18, "bad borrow value after close");
        assertGe(healthFactorBps, uint256(configManager.hfLockBps()), "health factor too low after close");
    }

    function testCloseLeveragedPositionAccruesCloseFee() public {
        _queueSetFees(0, 100);

        vm.startPrank(USER);
        address sma = executor.enableBorrowing();
        executor.openLeveragedPositionAtomic(address(usdt), address(pToken), 1e18, 200, 1.99e18, bytes(""));

        uint256 repaid = executor.closeLeveragedPosition(
            address(pToken),
            address(usdt),
            0.51e18,
            0.5e18,
            0.51e18,
            bytes("")
        );
        vm.stopPrank();

        assertEq(repaid, 0.5e18, "wrong repaid amount");
        assertEq(executor.protocolFees(address(usdt)), 0.005e18, "close fee not accrued");
        assertEq(pUsdt.borrowBalanceStored(sma), 0.5005e18, "debt not reduced correctly");
    }

    function testExecutorUsesUpdatedAdminFeeConfig() public {
        _queueSetFees(0, 0);

        vm.startPrank(USER);
        executor.enableBorrowing();
        executor.openLeveragedPositionAtomic(address(usdt), address(pToken), 1e18, 200, 1.99e18, bytes(""));
        vm.stopPrank();

        _queueSetFees(0, 50);

        vm.startPrank(USER);
        executor.closeLeveragedPosition(
            address(pToken),
            address(usdt),
            0.5025e18,
            0.5e18,
            0.5025e18,
            bytes("")
        );
        vm.stopPrank();

        assertEq(executor.protocolFees(address(usdt)), 0.0025e18, "executor did not pick up updated fee");
    }

    function testLiquidationOnExecutorOwnedPosition() public {
        vm.startPrank(USER);
        address sma = executor.enableBorrowing();
        executor.openLeveragedPositionAtomic(address(usdt), address(pToken), 1e18, 200, 1.99e18, bytes(""));
        vm.stopPrank();

        oracle.setDirectPrice(address(pToken), 0.6e18);

        MarginRiskLib.AccountMetrics memory preMetrics = executor.getAccountMetrics(USER);
        assertLt(preMetrics.healthFactorBps, uint256(configManager.hfLockBps()), "position should be liquidatable");

        AtomicMarginLiquidation.SwapParams memory swapParams = AtomicMarginLiquidation.SwapParams({
            adapter: address(router),
            minAmountOut: 0.5e18,
            data: bytes("")
        });

        uint256 liquidatorUsdtBefore = usdt.balanceOf(address(this));

        liquidation.liquidate(
            USER,
            address(pUsdt),
            address(pP),
            0.5e18,
            address(this),
            0,
            swapParams
        );

        assertLt(pUsdt.borrowBalanceStored(sma), 1e18 + 5e14, "debt not reduced");
        assertGt(usdt.balanceOf(address(this)), liquidatorUsdtBefore, "no liquidation profit");
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

    function _queueSetRouterAdapter(address newAdapter) internal {
        configManager.queueSetRouterAdapter(newAdapter);
        vm.warp(block.timestamp + configManager.actionDelay());
        configManager.setRouterAdapter(newAdapter);
    }

    function _queueSetFlashloanProvider(address provider) internal {
        configManager.queueSetFlashloanProvider(provider);
        vm.warp(block.timestamp + configManager.actionDelay());
        configManager.setFlashloanProvider(provider);
    }

    function _queueSetFees(uint16 openFee, uint16 closeFee) internal {
        configManager.queueSetFees(openFee, closeFee);
        vm.warp(block.timestamp + configManager.actionDelay());
        configManager.setFees(openFee, closeFee);
    }
}

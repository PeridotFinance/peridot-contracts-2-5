// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MarginManager} from "../contracts/margin/MarginManager.sol";
import {AtomicMarginExecutorUpgradeable} from "../contracts/margin/AtomicMarginExecutorUpgradeable.sol";
import {MarginCollateralVaultUpgradeable} from "../contracts/margin/MarginCollateralVaultUpgradeable.sol";
import {MarginEntryRouterUpgradeable} from "../contracts/margin/MarginEntryRouterUpgradeable.sol";
import {AtomicMarginLiquidationUpgradeable} from "../contracts/margin/AtomicMarginLiquidationUpgradeable.sol";
import {SimpleFlashLoanVaultUpgradeable} from "../contracts/margin/SimpleFlashLoanVaultUpgradeable.sol";
import {MockPeridottroller} from "./MockPeridottroller.sol";
import {MockErc20} from "./MockErc20.sol";
import {SimplePriceOracle} from "../contracts/SimplePriceOracle.sol";
import {MockRouterAdapter} from "./mocks/MockRouterAdapter.sol";
import {PeridotTransparentProxy} from "../contracts/proxy/PeridotTransparentProxy.sol";
import {ITransparentUpgradeableProxy, ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract TestCTokenProxy is MockErc20 {
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

contract SimpleFlashLoanVaultUpgradeableV2 is SimpleFlashLoanVaultUpgradeable {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract MarginStackUpgradeableTest is Test {
    MockPeridottroller internal comptroller;
    SimplePriceOracle internal oracle;
    MarginManager internal configManager;
    MockRouterAdapter internal dexRouter;

    MockErc20 internal usdt;
    MockErc20 internal pToken;
    TestCTokenProxy internal pUsdt;
    TestCTokenProxy internal pP;

    AtomicMarginExecutorUpgradeable internal executor;
    MarginCollateralVaultUpgradeable internal vault;
    MarginEntryRouterUpgradeable internal entryRouter;
    AtomicMarginLiquidationUpgradeable internal liquidation;
    SimpleFlashLoanVaultUpgradeable internal flashVault;
    address internal flashVaultProxyAdmin;

    address internal constant USER = address(0xA11CE);

    function setUp() public {
        comptroller = new MockPeridottroller();
        oracle = new SimplePriceOracle(3600);

        usdt = new MockErc20("Mock USDT", "USDT", 18);
        pToken = new MockErc20("Mock P", "P", 18);
        pUsdt = new TestCTokenProxy(address(usdt), "pUSDT", "pUSDT");
        pP = new TestCTokenProxy(address(pToken), "pP", "pP");

        comptroller.setMarket(address(pUsdt), true, 0.8e18);
        comptroller.setMarket(address(pP), true, 0.5e18);

        oracle.setDirectPrice(address(usdt), 1e18);
        oracle.setDirectPrice(address(pToken), 1e18);

        configManager = new MarginManager(address(comptroller), address(oracle));
        _queueConfigureMarket(address(pUsdt), address(usdt), true, true, true, true, true, 300, 50, 100);
        _queueConfigureMarket(address(pP), address(pToken), true, true, true, true, true, 300, 50, 100);

        dexRouter = new MockRouterAdapter();
        pToken.mint(address(dexRouter), 10_000e18);
        _queueSetRouterAdapter(address(dexRouter));

        usdt.approve(address(pUsdt), type(uint256).max);
        pToken.approve(address(pP), type(uint256).max);
        usdt.mint(address(this), 10_000e18);
        pToken.mint(address(this), 10_000e18);
        pUsdt.mint(2_000e18);
        pP.mint(2_000e18);

        {
            ProxyDeployment memory deployed = _deployProxy(
                address(new SimpleFlashLoanVaultUpgradeable()),
                abi.encodeWithSelector(SimpleFlashLoanVaultUpgradeable.initialize.selector, address(this))
            );
            flashVault = SimpleFlashLoanVaultUpgradeable(deployed.proxy);
            flashVaultProxyAdmin = deployed.proxyAdmin;
        }
        flashVault.setTokenAllowed(address(usdt), true);
        flashVault.setFeeBps(5);
        usdt.approve(address(flashVault), type(uint256).max);
        flashVault.depositLiquidity(address(usdt), 1_000e18);
        _queueSetFlashloanProvider(address(flashVault));

        executor = AtomicMarginExecutorUpgradeable(
            _deployProxy(
                address(new AtomicMarginExecutorUpgradeable()),
                abi.encodeWithSelector(
                    AtomicMarginExecutorUpgradeable.initialize.selector,
                    address(this),
                    address(configManager)
                )
            ).proxy
        );
        vault = MarginCollateralVaultUpgradeable(
            _deployProxy(
                address(new MarginCollateralVaultUpgradeable()),
                abi.encodeWithSelector(MarginCollateralVaultUpgradeable.initialize.selector, address(executor), address(this))
            ).proxy
        );
        entryRouter = MarginEntryRouterUpgradeable(
            _deployProxy(
                address(new MarginEntryRouterUpgradeable()),
                abi.encodeWithSelector(
                    MarginEntryRouterUpgradeable.initialize.selector,
                    address(executor),
                    address(vault),
                    address(this)
                )
            ).proxy
        );
        liquidation = AtomicMarginLiquidationUpgradeable(
            _deployProxy(
                address(new AtomicMarginLiquidationUpgradeable()),
                abi.encodeWithSelector(
                    AtomicMarginLiquidationUpgradeable.initialize.selector,
                    address(executor),
                    address(configManager),
                    address(this)
                )
            ).proxy
        );

        executor.setMarginCollateralVault(address(vault));
        executor.setEntryRouter(address(entryRouter), true);
        vault.setPTokenAllowed(address(pUsdt), true);
        vault.setRouterAllowed(address(entryRouter), true);

        usdt.mint(USER, 100e18);
        vm.startPrank(USER);
        usdt.approve(address(pUsdt), type(uint256).max);
        pUsdt.mint(5e18);
        pUsdt.approve(address(vault), type(uint256).max);
        usdt.approve(address(executor), type(uint256).max);
        vm.stopPrank();
    }

    function testProxyStack_moveToMarginAndOpenLong() public {
        vm.prank(USER);
        uint256 baseAcquired = entryRouter.moveToMarginAndOpenLong(
            address(pUsdt),
            5e18,
            address(usdt),
            address(pToken),
            1e18,
            150,
            1492500000000000000,
            bytes("")
        );

        address sma = executor.getAccount(USER).sma;
        assertTrue(sma != address(0), "sma not created");
        assertEq(vault.marginBalance(USER, address(pUsdt)), 5e18, "margin ledger not updated");
        assertEq(pUsdt.balanceOf(sma), 5e18, "sma did not receive moved pUSDT");
        assertGt(pP.balanceOf(sma), 0, "no leveraged collateral minted");
        assertGt(baseAcquired, 0, "no base acquired");
    }

    function testProxyStack_closeAndMoveToEarning() public {
        vm.prank(USER);
        entryRouter.moveToMarginAndOpenLong(
            address(pUsdt),
            5e18,
            address(usdt),
            address(pToken),
            1e18,
            150,
            1492500000000000000,
            bytes("")
        );

        address sma = executor.getAccount(USER).sma;
        uint256 debtBefore = pUsdt.borrowBalanceStored(sma);
        uint256 userPUsdtBefore = pUsdt.balanceOf(USER);

        vm.prank(USER);
        uint256 repaid = entryRouter.closeLeveragedPositionAndMoveToEarning(
            address(pUsdt),
            2e18,
            address(pToken),
            address(usdt),
            0.25e18,
            0.25e18,
            248750000000000000,
            bytes("")
        );

        assertEq(repaid, 0.25e18, "wrong repaid amount");
        assertLt(pUsdt.borrowBalanceStored(sma), debtBefore, "debt not reduced");
        assertEq(vault.marginBalance(USER, address(pUsdt)), 3e18, "margin balance not reduced");
        assertEq(pUsdt.balanceOf(USER), userPUsdtBefore + 2e18, "earning balance not restored");
    }

    function testFlashVaultProxyCanUpgradeAndPreserveState() public {
        assertEq(flashVault.feeBps(), 5, "fee not initialized");
        assertTrue(flashVault.tokenAllowed(address(usdt)), "token not allowed");

        SimpleFlashLoanVaultUpgradeableV2 newImpl = new SimpleFlashLoanVaultUpgradeableV2();
        ProxyAdmin(flashVaultProxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(flashVault))),
            address(newImpl),
            bytes("")
        );

        SimpleFlashLoanVaultUpgradeableV2 upgraded = SimpleFlashLoanVaultUpgradeableV2(address(flashVault));
        assertEq(upgraded.version(), 2, "upgrade failed");
        assertEq(upgraded.feeBps(), 5, "fee state not preserved");
        assertTrue(upgraded.tokenAllowed(address(usdt)), "allowlist state not preserved");
    }

    struct ProxyDeployment {
        address proxy;
        address proxyAdmin;
    }

    function _deployProxy(address implementation, bytes memory initData) internal returns (ProxyDeployment memory deployed) {
        deployed.proxy = address(new PeridotTransparentProxy(implementation, address(this), initData));
        deployed.proxyAdmin = address(uint160(uint256(vm.load(
            deployed.proxy,
            0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103
        ))));
        require(deployed.proxyAdmin != address(0), "proxy admin not found");
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

    function _queueSetFlashloanProvider(address provider) internal {
        configManager.queueSetFlashloanProvider(provider);
        vm.warp(block.timestamp + configManager.actionDelay());
        configManager.setFlashloanProvider(provider);
    }
}

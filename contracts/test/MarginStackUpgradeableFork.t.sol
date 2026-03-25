// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MarginManager} from "../contracts/margin/MarginManager.sol";
import {AtomicMarginExecutorUpgradeable} from "../contracts/margin/AtomicMarginExecutorUpgradeable.sol";
import {MarginCollateralVaultUpgradeable} from "../contracts/margin/MarginCollateralVaultUpgradeable.sol";
import {MarginEntryRouterUpgradeable} from "../contracts/margin/MarginEntryRouterUpgradeable.sol";
import {SimpleFlashLoanVaultUpgradeable} from "../contracts/margin/SimpleFlashLoanVaultUpgradeable.sol";
import {PeridotTransparentProxy} from "../contracts/proxy/PeridotTransparentProxy.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IOperatorAuthorizerProxyFork {
    function setOperator(address operator, bool allowed) external;
}

contract MarginStackUpgradeableForkTest is Test {
    address internal constant OWNER = 0xF450B38cccFdcfAD2f98f7E4bB533151a2fB00E9;
    address internal constant CONFIG_MANAGER = 0x9aec8CCE977D3270B7760793515f7d295246D204;
    address internal constant USDT = 0xa568bD70068A940910d04117c36Ab1A0225FD140;
    address internal constant P = 0xB911C192ed1d6428A12F2Cf8F636B00c34e68a2a;
    address internal constant PUSDT = 0xFaF7b3d46Ffd22129A0792859026965826386D23;
    address internal constant USER = address(0xA11CE);

    MarginManager internal configManager;
    AtomicMarginExecutorUpgradeable internal executor;
    MarginCollateralVaultUpgradeable internal vault;
    MarginEntryRouterUpgradeable internal entryRouter;
    SimpleFlashLoanVaultUpgradeable internal flashVault;

    function setUp() public {
        _ensureForkOrSkip();

        if (CONFIG_MANAGER.code.length == 0 || USDT.code.length == 0 || P.code.length == 0 || PUSDT.code.length == 0) {
            emit log("Skipping fork test: live Somnia addresses missing code");
            vm.skip(true);
        }

        configManager = MarginManager(CONFIG_MANAGER);

        flashVault = SimpleFlashLoanVaultUpgradeable(
            _deployProxy(
                address(new SimpleFlashLoanVaultUpgradeable()),
                abi.encodeWithSelector(SimpleFlashLoanVaultUpgradeable.initialize.selector, address(this))
            )
        );
        flashVault.setTokenAllowed(USDT, true);
        flashVault.setTokenAllowed(P, true);
        flashVault.setFeeBps(5);

        deal(USDT, address(this), 1_000e18, false);
        deal(P, address(this), 1_000e18, false);
        IERC20(USDT).approve(address(flashVault), type(uint256).max);
        IERC20(P).approve(address(flashVault), type(uint256).max);
        flashVault.depositLiquidity(USDT, 1_000e18);
        flashVault.depositLiquidity(P, 1_000e18);

        vm.startPrank(OWNER);
        configManager.queueSetFlashloanProvider(address(flashVault));
        vm.warp(block.timestamp + configManager.actionDelay());
        configManager.setFlashloanProvider(address(flashVault));
        vm.stopPrank();

        executor = AtomicMarginExecutorUpgradeable(
            _deployProxy(
                address(new AtomicMarginExecutorUpgradeable()),
                abi.encodeWithSelector(
                    AtomicMarginExecutorUpgradeable.initialize.selector,
                    address(this),
                    address(configManager)
                )
            )
        );
        vault = MarginCollateralVaultUpgradeable(
            _deployProxy(
                address(new MarginCollateralVaultUpgradeable()),
                abi.encodeWithSelector(MarginCollateralVaultUpgradeable.initialize.selector, address(executor), address(this))
            )
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
            )
        );

        executor.setMarginCollateralVault(address(vault));
        executor.setEntryRouter(address(entryRouter), true);
        vault.setPTokenAllowed(PUSDT, true);
        vault.setRouterAllowed(address(entryRouter), true);

        address routerAdapter = configManager.routerAdapter();
        vm.prank(OWNER);
        IOperatorAuthorizerProxyFork(routerAdapter).setOperator(address(executor), true);

        deal(PUSDT, USER, 5e8, false);
        deal(USDT, USER, 1e18, false);
        vm.startPrank(USER);
        PErc20(PUSDT).approve(address(vault), type(uint256).max);
        IERC20(USDT).approve(address(executor), type(uint256).max);
        vm.stopPrank();
    }

    function testForkSomnia_proxyStackMoveToMarginAndOpenLong() public {
        vm.prank(USER);
        uint256 baseAcquired = entryRouter.moveToMarginAndOpenLong(
            PUSDT,
            5e8,
            USDT,
            P,
            1e18,
            150,
            1492500000000000000,
            bytes("")
        );

        address sma = executor.getAccount(USER).sma;
        assertTrue(sma != address(0), "sma not created");
        assertEq(vault.marginBalance(USER, PUSDT), 5e8, "vault ledger not updated");
        assertEq(PErc20(PUSDT).balanceOf(sma), 5e8, "sma did not receive pUSDT");
        assertGt(baseAcquired, 0, "no base acquired");
    }

    function testForkSomnia_proxyStackCloseAndMoveToEarning() public {
        vm.prank(USER);
        entryRouter.moveToMarginAndOpenLong(
            PUSDT,
            5e8,
            USDT,
            P,
            1e18,
            150,
            1492500000000000000,
            bytes("")
        );

        address sma = executor.getAccount(USER).sma;
        uint256 debtBefore = PErc20(PUSDT).borrowBalanceStored(sma);
        uint256 userPUsdtBefore = PErc20(PUSDT).balanceOf(USER);

        vm.prank(USER);
        uint256 repaid = entryRouter.closeLeveragedPositionAndMoveToEarning(
            PUSDT,
            2e8,
            P,
            USDT,
            0.25e18,
            0.25e18,
            248750000000000000,
            bytes("")
        );

        assertEq(repaid, 0.25e18, "wrong repaid amount");
        assertLt(PErc20(PUSDT).borrowBalanceStored(sma), debtBefore, "debt not reduced");
        assertEq(vault.marginBalance(USER, PUSDT), 3e8, "vault ledger not updated");
        assertEq(PErc20(PUSDT).balanceOf(USER), userPUsdtBefore + 2e8, "earning balance not restored");
    }

    function testForkSomnia_proxyStackCloseOnlyRepaysDebt() public {
        vm.prank(USER);
        entryRouter.moveToMarginAndOpenLong(
            PUSDT,
            5e8,
            USDT,
            P,
            1e18,
            150,
            1492500000000000000,
            bytes("")
        );

        address sma = executor.getAccount(USER).sma;
        uint256 debtBefore = PErc20(PUSDT).borrowBalanceStored(sma);
        uint256 marginBefore = vault.marginBalance(USER, PUSDT);

        vm.prank(USER);
        uint256 repaid = entryRouter.closeLeveragedPosition(
            P,
            USDT,
            0.25e18,
            0.25e18,
            248750000000000000,
            bytes("")
        );

        assertEq(repaid, 0.25e18, "wrong repaid amount");
        assertLt(PErc20(PUSDT).borrowBalanceStored(sma), debtBefore, "debt not reduced");
        assertEq(vault.marginBalance(USER, PUSDT), marginBefore, "margin balance should stay in margin");
    }

    function testForkSomnia_proxyStackOpenLongRevertsWhenMinOutTooLow() public {
        vm.startPrank(USER);
        vm.expectRevert(bytes("Executor: minOut too low"));
        entryRouter.moveToMarginAndOpenLong(
            PUSDT,
            5e8,
            USDT,
            P,
            1e18,
            150,
            1,
            bytes("")
        );
        vm.stopPrank();
    }

    function testForkSomnia_proxyStackOpenLongRevertsWithoutOperatorAuth() public {
        AtomicMarginExecutorUpgradeable executorNoOp = AtomicMarginExecutorUpgradeable(
            _deployProxy(
                address(new AtomicMarginExecutorUpgradeable()),
                abi.encodeWithSelector(
                    AtomicMarginExecutorUpgradeable.initialize.selector,
                    address(this),
                    address(configManager)
                )
            )
        );
        MarginCollateralVaultUpgradeable vaultNoOp = MarginCollateralVaultUpgradeable(
            _deployProxy(
                address(new MarginCollateralVaultUpgradeable()),
                abi.encodeWithSelector(MarginCollateralVaultUpgradeable.initialize.selector, address(executorNoOp), address(this))
            )
        );
        MarginEntryRouterUpgradeable entryRouterNoOp = MarginEntryRouterUpgradeable(
            _deployProxy(
                address(new MarginEntryRouterUpgradeable()),
                abi.encodeWithSelector(
                    MarginEntryRouterUpgradeable.initialize.selector,
                    address(executorNoOp),
                    address(vaultNoOp),
                    address(this)
                )
            )
        );

        executorNoOp.setMarginCollateralVault(address(vaultNoOp));
        executorNoOp.setEntryRouter(address(entryRouterNoOp), true);
        vaultNoOp.setPTokenAllowed(PUSDT, true);
        vaultNoOp.setRouterAllowed(address(entryRouterNoOp), true);

        deal(PUSDT, USER, 5e8, false);
        deal(USDT, USER, 1e18, false);
        vm.startPrank(USER);
        PErc20(PUSDT).approve(address(vaultNoOp), type(uint256).max);
        IERC20(USDT).approve(address(executorNoOp), type(uint256).max);
        vm.expectRevert();
        entryRouterNoOp.moveToMarginAndOpenLong(
            PUSDT,
            5e8,
            USDT,
            P,
            1e18,
            150,
            1492500000000000000,
            bytes("")
        );
        vm.stopPrank();
    }

    function testForkSomnia_proxyStackOpenShort() public {
        vm.prank(USER);
        uint256 quoteReceived = entryRouter.moveToMarginAndOpenShort(
            PUSDT,
            5e8,
            P,
            USDT,
            1e18,
            150,
            497500000000000000,
            bytes("")
        );

        address sma = executor.getAccount(USER).sma;
        assertTrue(sma != address(0), "sma not created");
        assertEq(vault.marginBalance(USER, PUSDT), 5e8, "vault ledger not updated");
        assertGt(quoteReceived, 0, "no quote received");
    }

    function _deployProxy(address implementation, bytes memory initData) internal returns (address) {
        return address(new PeridotTransparentProxy(implementation, address(this), initData));
    }

    function _ensureForkOrSkip() internal {
        try vm.activeFork() returns (uint256) {
            return;
        } catch {
            string memory url = _rpcUrl();
            if (bytes(url).length == 0) {
                emit log("Skipping fork test: set SOMNIARPC or SOMNIA_RPC_URL");
                vm.skip(true);
            }
            uint256 forkBlock = _forkBlock();
            if (forkBlock == 0) {
                vm.createSelectFork(url);
            } else {
                vm.createSelectFork(url, forkBlock);
            }
        }
    }

    function _rpcUrl() internal view returns (string memory) {
        try vm.envString("SOMNIARPC") returns (string memory value) {
            return value;
        } catch {
            try vm.envString("SOMNIA_RPC_URL") returns (string memory alt) {
                return alt;
            } catch {
                return "";
            }
        }
    }

    function _forkBlock() internal view returns (uint256) {
        try vm.envUint("SOMNIA_FORK_BLOCK") returns (uint256 value) {
            return value;
        } catch {
            return 0;
        }
    }
}

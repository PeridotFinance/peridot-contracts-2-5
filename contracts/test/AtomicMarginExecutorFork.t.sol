// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MarginManager} from "../contracts/margin/MarginManager.sol";
import {AtomicMarginExecutor} from "../contracts/margin/AtomicMarginExecutor.sol";
import {SimpleFlashLoanVault} from "../contracts/margin/SimpleFlashLoanVault.sol";
import {MarginRiskLib} from "../contracts/margin/MarginRiskLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PErc20} from "../contracts/PErc20.sol";

interface IOperatorAuthorizer {
    function setOperator(address operator, bool allowed) external;
}

/**
 * @notice Fork test against live Somnia testnet margin configuration.
 * @dev Run with:
 *   forge test --match-path test/AtomicMarginExecutorFork.t.sol --fork-url $SOMNIARPC -vv
 */
contract AtomicMarginExecutorForkTest is Test {
    address internal constant OWNER = 0xF450B38cccFdcfAD2f98f7E4bB533151a2fB00E9;
    address internal constant CONFIG_MANAGER = 0x9aec8CCE977D3270B7760793515f7d295246D204;
    address internal constant USDT = 0xa568bD70068A940910d04117c36Ab1A0225FD140;
    address internal constant P = 0xB911C192ed1d6428A12F2Cf8F636B00c34e68a2a;
    address internal constant PUSDT = 0xFaF7b3d46Ffd22129A0792859026965826386D23;
    address internal constant PP = 0x35280b6EA83Fd265D316037432e62870409eaC5b;

    address internal constant USER = address(0xA11CE);

    MarginManager internal configManager;
    AtomicMarginExecutor internal executor;
    SimpleFlashLoanVault internal vault;

    function setUp() public {
        _ensureForkOrSkip();

        if (
            CONFIG_MANAGER.code.length == 0 ||
            USDT.code.length == 0 ||
            P.code.length == 0 ||
            PUSDT.code.length == 0 ||
            PP.code.length == 0
        ) {
            emit log("Skipping fork test: one or more live Somnia addresses have no code");
            vm.skip(true);
        }

        configManager = MarginManager(CONFIG_MANAGER);

        vault = new SimpleFlashLoanVault(address(this));
        vault.setTokenAllowed(USDT, true);
        vault.setTokenAllowed(P, true);
        vault.setFeeBps(5);

        deal(USDT, address(this), 1_000e18, false);
        deal(P, address(this), 1_000e18, false);
        IERC20(USDT).approve(address(vault), type(uint256).max);
        IERC20(P).approve(address(vault), type(uint256).max);
        vault.depositLiquidity(USDT, 1_000e18);
        vault.depositLiquidity(P, 1_000e18);

        vm.startPrank(OWNER);
        configManager.queueSetFlashloanProvider(address(vault));
        vm.warp(block.timestamp + configManager.actionDelay());
        configManager.setFlashloanProvider(address(vault));
        vm.stopPrank();

        executor = new AtomicMarginExecutor(CONFIG_MANAGER);
        address routerAdapter = configManager.routerAdapter();
        vm.prank(OWNER);
        IOperatorAuthorizer(routerAdapter).setOperator(address(executor), true);

        deal(USDT, USER, 10e18, false);
        vm.prank(USER);
        IERC20(USDT).approve(address(executor), type(uint256).max);
    }

    function testForkSomnia_openAndCloseAtomicLong() public {
        vm.prank(USER);
        address sma = executor.enableBorrowing();

        (uint256 totalNotional, uint256 borrowAmount, uint256 flashFee) =
            executor.previewAtomicLong(USDT, 1e18, 150);
        assertEq(totalNotional, 1.5e18, "bad notional");
        assertEq(borrowAmount, 0.5e18, "bad borrow amount");
        assertEq(flashFee, 25e13, "bad flash fee");

        vm.prank(USER);
        uint256 baseAcquired =
            executor.openLeveragedPositionAtomic(USDT, P, 1e18, 150, 1492500000000000000, bytes(""));

        assertGt(baseAcquired, 0, "no base acquired");
        assertGt(PErc20(PP).balanceOf(sma), 0, "no pP collateral");
        assertGt(PErc20(PUSDT).borrowBalanceStored(sma), 0, "no pUSDT debt");

        vm.prank(USER);
        uint256 repaid = executor.closeLeveragedPosition(
            P,
            USDT,
            0.25e18,
            0.25e18,
            248750000000000000,
            bytes("")
        );

        assertEq(repaid, 0.25e18, "wrong repaid amount");

        MarginRiskLib.AccountMetrics memory metrics = executor.getAccountMetrics(USER);
        assertGt(metrics.collateralValue, 0, "missing collateral after close");
        assertGt(metrics.borrowValue, 0, "debt should remain after partial close");
    }

    function testForkSomnia_closeFeeCanBeAdminUpdated() public {
        vm.startPrank(OWNER);
        configManager.queueSetFeeRecipient(address(0));
        vm.warp(block.timestamp + configManager.actionDelay());
        configManager.setFeeRecipient(address(0));
        configManager.queueSetFees(0, 50);
        vm.warp(block.timestamp + configManager.actionDelay());
        configManager.setFees(0, 50);
        vm.stopPrank();

        vm.prank(USER);
        executor.enableBorrowing();

        vm.prank(USER);
        executor.openLeveragedPositionAtomic(USDT, P, 1e18, 150, 1492500000000000000, bytes(""));

        vm.prank(USER);
        executor.closeLeveragedPosition(
            P,
            USDT,
            251250000000000000,
            250000000000000000,
            250000000000000000,
            bytes("")
        );

        assertEq(executor.protocolFees(USDT), 1250000000000000, "close fee not accrued");
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

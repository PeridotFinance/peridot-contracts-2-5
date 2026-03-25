// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MarginManager} from "../contracts/margin/MarginManager.sol";
import {AtomicMarginExecutor} from "../contracts/margin/AtomicMarginExecutor.sol";
import {MarginCollateralVault} from "../contracts/margin/MarginCollateralVault.sol";
import {PErc20} from "../contracts/PErc20.sol";

contract MarginCollateralVaultForkTest is Test {
    address internal constant CONFIG_MANAGER = 0x9aec8CCE977D3270B7760793515f7d295246D204;
    address internal constant PUSDT = 0xFaF7b3d46Ffd22129A0792859026965826386D23;
    address internal constant USER = address(0xA11CE);

    MarginManager internal configManager;
    AtomicMarginExecutor internal executor;
    MarginCollateralVault internal vault;

    function setUp() public {
        _ensureForkOrSkip();

        if (CONFIG_MANAGER.code.length == 0 || PUSDT.code.length == 0) {
            emit log("Skipping fork test: live Somnia addresses missing code");
            vm.skip(true);
        }

        configManager = MarginManager(CONFIG_MANAGER);
        executor = new AtomicMarginExecutor(CONFIG_MANAGER);
        vault = new MarginCollateralVault(address(executor), address(this));

        executor.setMarginCollateralVault(address(vault));
        vault.setPTokenAllowed(PUSDT, true);

        vm.prank(USER);
        executor.enableBorrowing();

        deal(PUSDT, USER, 5e8, false);
        vm.prank(USER);
        PErc20(PUSDT).approve(address(vault), type(uint256).max);
    }

    function testForkSomnia_movePTokenFromEarningToMarginAndBack() public {
        address sma = executor.getAccount(USER).sma;
        uint256 userBalanceBefore = PErc20(PUSDT).balanceOf(USER);

        vm.prank(USER);
        vault.moveToMargin(PUSDT, 5e8);

        assertEq(PErc20(PUSDT).balanceOf(USER), 0, "user should no longer hold pUSDT");
        assertEq(PErc20(PUSDT).balanceOf(sma), 5e8, "sma did not receive pUSDT");
        assertEq(vault.marginBalance(USER, PUSDT), 5e8, "vault ledger not updated");

        uint256 freeAmount = vault.freeMarginBalance(USER, PUSDT);
        assertGt(freeAmount, 0, "no free margin pUSDT");

        vm.prank(USER);
        vault.moveToEarning(PUSDT, freeAmount);

        assertEq(PErc20(PUSDT).balanceOf(USER), userBalanceBefore - 5e8 + freeAmount, "user pUSDT balance mismatch");
        assertEq(PErc20(PUSDT).balanceOf(sma), 5e8 - freeAmount, "sma pUSDT balance mismatch");
        assertEq(vault.marginBalance(USER, PUSDT), 5e8 - freeAmount, "vault ledger mismatch");
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

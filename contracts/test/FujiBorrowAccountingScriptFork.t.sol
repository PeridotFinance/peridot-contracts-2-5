// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {MigrateFujiMockBorrowAccounting} from "../script/MigrateFujiMockBorrowAccounting.s.sol";
import {PErc20Delegate} from "../contracts/PErc20Delegate.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {Peridottroller} from "../contracts/Peridottroller.sol";
import {IsolatedMarginExecutorUpgradeable} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";

/// @notice Executes both actual operator-script stages in a LOCAL fork only, without wallets.
contract FujiBorrowAccountingScriptForkTest is Test {
    address constant OWNER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    PErc20 constant USD = PErc20(0x81BF2032e98C8F35F2336e1A68baA01B5B2030E4);
    PErc20 constant AVAX = PErc20(0x577AC6Ca3Df06D7702740A6A8c136F868f9f0195);
    Peridottroller constant CONTROLLER = Peridottroller(0x0020998Ef0f159cf225e183BefF212b5dBA8285a);
    IsolatedMarginExecutorUpgradeable constant EX =
        IsolatedMarginExecutorUpgradeable(0xa155ccCB986774AE818b3F10F07d01D1b7A47b26);
    MigrateFujiMockBorrowAccounting migration;

    function setUp() public {
        string memory rpc = vm.envOr("FUJI_MOCK_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 58_411_347);
        require(
            keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("")))) == keccak256("debt_accounting"), "release profile"
        );
        migration = new MigrateFujiMockBorrowAccounting();
        vm.setEnv("CONFIRM_FUJI_MOCK_ONLY", "true");
        vm.setEnv("CONFIRM_FUJI_DEBT_PAUSE", "true");
        vm.setEnv("CONFIRM_FUJI_DEBT_MIGRATION", "true");
        vm.setEnv("CONFIRM_FUJI_BORROWER_HISTORY_REVIEWED", "true");
    }

    function testBothStagesPreserveClaimsAndLeaveAllGatesPaused() public {
        uint256 usdRate = USD.exchangeRateStored();
        uint256 avaxRate = AVAX.exchangeRateStored();
        uint256 reserves = AVAX.totalReserves();
        migration.pause();
        vm.roll(vm.getBlockNumber() + 100);
        PErc20Delegate replacement = migration.run();
        assertEq(PErc20Delegator(payable(address(USD))).implementation(), address(replacement));
        assertEq(PErc20Delegator(payable(address(AVAX))).implementation(), address(replacement));
        assertEq(USD.totalBorrows(), 0);
        assertEq(AVAX.totalBorrows(), 0);
        assertEq(AVAX.totalReserves(), reserves - 8);
        assertEq(USD.exchangeRateStored(), usdRate);
        assertEq(AVAX.exchangeRateStored(), avaxRate);
        assertTrue(EX.config().opensPaused());
        assertTrue(CONTROLLER.borrowGuardianPaused(address(USD)));
        assertTrue(CONTROLLER.borrowGuardianPaused(address(AVAX)));
        assertEq(EX.config().queuedActions(keccak256("unpauseOpens")), 0);
        assertEq(EX.config().getPairRisk(address(USD), address(AVAX), address(USD)).maxLeverageX100, 200);
        assertEq(EX.config().getPairRisk(address(USD), address(USD), address(AVAX)).maxLeverageX100, 200);
        assertEq(EX.nextPositionId(), 3);
    }

    function testRejectsMainnetBeforeAnyOperation() public {
        vm.chainId(43_114);
        vm.expectRevert("DebtMigration: Fuji only");
        migration.pause();
        vm.expectRevert("DebtMigration: Fuji only");
        migration.run();
    }

    function testRejectsWrongReleaseProfile() public {
        vm.setEnv("FOUNDRY_PROFILE", "default");
        vm.expectRevert("DebtMigration: release profile required");
        migration.run();
        vm.setEnv("FOUNDRY_PROFILE", "debt_accounting");
    }

    function testRejectsMissingHistoryConfirmation() public {
        vm.setEnv("CONFIRM_FUJI_BORROWER_HISTORY_REVIEWED", "false");
        vm.expectRevert("DebtMigration: history confirmation");
        migration.run();
        vm.setEnv("CONFIRM_FUJI_BORROWER_HISTORY_REVIEWED", "true");
    }

    function testRejectsMissingPauseConfirmation() public {
        vm.setEnv("CONFIRM_FUJI_DEBT_PAUSE", "false");
        vm.expectRevert("DebtMigration: pause confirmation");
        migration.pause();
        vm.setEnv("CONFIRM_FUJI_DEBT_PAUSE", "true");
    }

    function testRejectsUpgradeBeforePause() public {
        vm.expectRevert("DebtMigration: pause first");
        migration.run();
    }

    function testRejectsMissingMockConfirmation() public {
        vm.setEnv("CONFIRM_FUJI_MOCK_ONLY", "false");
        vm.expectRevert("DebtMigration: mock confirmation");
        migration.pause();
        vm.setEnv("CONFIRM_FUJI_MOCK_ONLY", "true");
    }

    function testRejectsMissingMigrationConfirmation() public {
        vm.setEnv("CONFIRM_FUJI_DEBT_MIGRATION", "false");
        vm.expectRevert("DebtMigration: migration confirmation");
        migration.run();
        vm.setEnv("CONFIRM_FUJI_DEBT_MIGRATION", "true");
    }

    function testRejectsAggregateDrift() public {
        vm.mockCall(address(USD), abi.encodeWithSignature("totalBorrows()"), abi.encode(uint256(1)));
        vm.expectRevert("DebtMigration: debt or flash gate");
        migration.pause();
    }

    function testRejectsPendingUnpause() public {
        vm.startPrank(OWNER);
        EX.config().queueUnpauseOpens();
        vm.stopPrank();
        vm.expectRevert("DebtMigration: pending unpause");
        migration.pause();
    }

    function testRejectsBlindReplayOfPauseAndMigration() public {
        migration.pause();
        vm.expectRevert("DebtMigration: reconcile partial pause");
        migration.pause();
        migration.run();
        vm.expectRevert("DebtMigration: implementation");
        migration.run();
    }

    function testRejectsPositionHistoryDrift() public {
        vm.mockCall(address(EX), abi.encodeWithSignature("nextPositionId()"), abi.encode(uint256(4)));
        vm.expectRevert("DebtMigration: position history changed");
        migration.pause();
    }
}

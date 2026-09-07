// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {FujiMockMigrationForkFixture} from "./FujiMockMigrationPreflightFork.t.sol";
import {FujiMockSizingFixForkTest} from "./FujiMockSizingFixFork.t.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {PeridotTransparentProxy} from "../contracts/proxy/PeridotTransparentProxy.sol";
import {
    IsolatedMarginExecutorFujiQuoterMigration as Migration
} from "../contracts/margin/IsolatedMarginExecutorFujiQuoterMigration.sol";
import {IsolatedMarginExecutorUpgradeable} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginQuoter} from "../contracts/margin/IsolatedMarginQuoter.sol";
import {IsolatedMarginConfigUpgradeable} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginTypes} from "../contracts/margin/IsolatedMarginTypes.sol";
import {IsolatedMarginLiquidatorUpgradeable} from "../contracts/margin/IsolatedMarginLiquidatorUpgradeable.sol";
import {FujiMockPriceFeed, FujiMockToken} from "../contracts/margin/testing/FujiMockAssets.sol";
import {MigrateFujiMockOpeningQuoter} from "../script/MigrateFujiMockOpeningQuoter.s.sol";
import {SmokeFujiMockMargin} from "../script/SmokeFujiMockMargin.s.sol";

/// @notice Pinned live-state migration using real CREATE and ProxyAdmin calls, LOCAL VM ONLY.
contract FujiMockQuoterMigrationForkTest is FujiMockMigrationForkFixture {
    address constant OLD = 0x6c68ef73728337e5D8212a11CFeDDdF1B4Ff23eD;
    FujiMockPriceFeed constant AF = FujiMockPriceFeed(0x515a87601C4515e8B42f69645E77B56110d1a9A4);
    FujiMockPriceFeed constant UF = FujiMockPriceFeed(0x4758CB877D0B1f768EdC1F374156127A1517b2eD);
    IsolatedMarginLiquidatorUpgradeable constant LIQ =
        IsolatedMarginLiquidatorUpgradeable(0xb344A644Dcf2176f50292ABDD6acDfdfea3F525d);

    function testAtomicMigrationOnlyChangesQuoterAndInitializer() public {
        bytes32 beforeState = _state();
        _migrate();
        assertEq(_state(), beforeState);
        assertEq(address(EX.quoter()), address(fresh));
        assertEq(Migration(address(EX)).initializedVersion(), 2);
        assertTrue(EX.config().opensPaused());
        assertEq(address(EX.swapModule().quoter()), OLD);
        assertEq(address(LIQ.quoter()), OLD);
    }

    function testMigrationWritesOnlyExpectedProxySlots() public {
        _pause();
        Migration implementation = new Migration(address(fresh));
        address vault = address(EX.vault());
        address fees = address(EX.feeDistributor());
        address risk = address(EX.riskEngine());
        address config = address(EX.config());
        bytes32 initializerSlot = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
        bytes32 guardSlot = 0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;
        bytes32 guardBefore = vm.load(address(EX), guardSlot);
        assertEq(uint256(vm.load(address(EX), initializerSlot)), 1);
        vm.record();
        _upgrade(implementation);
        (, bytes32[] memory writes) = vm.accesses(address(EX));
        assertGt(writes.length, 0);
        for (uint256 i; i < writes.length; ++i) {
            assertTrue(
                writes[i] == IMPL_SLOT || writes[i] == bytes32(uint256(5)) || writes[i] == initializerSlot
                    || writes[i] == guardSlot,
                "unexpected proxy storage write"
            );
        }
        (, writes) = vm.accesses(vault);
        assertEq(writes.length, 0);
        (, writes) = vm.accesses(fees);
        assertEq(writes.length, 0);
        (, writes) = vm.accesses(risk);
        assertEq(writes.length, 0);
        (, writes) = vm.accesses(config);
        assertEq(writes.length, 0);
        assertEq(uint256(vm.load(address(EX), initializerSlot)), 2);
        assertEq(vm.load(address(EX), guardSlot), guardBefore);
    }

    function testUnpausedMigrationRollsBackBothImplementationAndVersion() public {
        Migration implementation = new Migration(address(fresh));
        _expectFailedUpgrade(implementation, 6);
        // A rejected attempt cannot consume reinitializer(2).
        _pause();
        _upgrade(implementation);
        assertEq(Migration(address(EX)).initializedVersion(), 2);
    }

    function testWrongChainMigrationRollsBack() public {
        Migration implementation = new Migration(address(fresh));
        _pause();
        vm.chainId(43_114);
        _expectFailedUpgrade(implementation, 1);
    }

    function testConstructorRejectsMainnetAndMissingOrOldQuoter() public {
        vm.chainId(43_114);
        vm.expectRevert(abi.encodeWithSelector(Migration.MigrationError.selector, uint8(1)));
        new Migration(address(fresh));
        vm.chainId(43_113);
        vm.expectRevert(abi.encodeWithSelector(Migration.MigrationError.selector, uint8(2)));
        new Migration(address(0));
        vm.expectRevert(abi.encodeWithSelector(Migration.MigrationError.selector, uint8(2)));
        new Migration(OLD);
    }

    function testConstructorRejectsWrongQuoterBindings() public {
        IsolatedMarginQuoter wrong = new IsolatedMarginQuoter(address(EX.vault()), address(EX.riskEngine().oracle()));
        vm.expectRevert(abi.encodeWithSelector(Migration.MigrationError.selector, uint8(5)));
        new Migration(address(wrong));
    }

    function testBindingDriftRollsBackUpgrade() public {
        Migration implementation = new Migration(address(fresh));
        _pause();
        vm.mockCall(address(fresh), abi.encodeWithSignature("oracle()"), abi.encode(address(EX.vault())));
        _expectFailedUpgrade(implementation, 5);
        vm.clearMockedCalls();
    }

    function testDifferentProxyCannotMigrate() public {
        Migration implementation = new Migration(address(fresh));
        PeridotTransparentProxy other = new PeridotTransparentProxy(address(implementation), OWNER, "");
        address otherAdmin = address(uint160(uint256(vm.load(address(other), ADMIN_SLOT))));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Migration.MigrationError.selector, uint8(3)));
        ProxyAdmin(otherAdmin)
            .upgradeAndCall(ITransparentUpgradeableProxy(address(other)), address(implementation), _data());
    }

    function testOwnerAndPublicCannotCallMigrationDirectly() public {
        // Deliberately install without calldata in the VM to test the unconsumed entry point.
        // The reviewed operator script NEVER does this.
        Migration implementation = new Migration(address(fresh));
        _pause();
        vm.prank(OWNER);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(EX)), address(implementation), "");
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Migration.MigrationError.selector, uint8(4)));
        Migration(address(EX)).migrateOpeningQuoter();
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(Migration.MigrationError.selector, uint8(4)));
        Migration(address(EX)).migrateOpeningQuoter();
        assertEq(Migration(address(EX)).initializedVersion(), 1);
        _upgrade(implementation);
        assertEq(Migration(address(EX)).initializedVersion(), 2);
    }

    function testImplementationCannotBeInitializedAndMigrationCannotReplay() public {
        Migration implementation = new Migration(address(fresh));
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        implementation.migrateOpeningQuoter();
        _pause();
        _upgrade(implementation);
        Migration next = new Migration(address(fresh));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(EX)), address(next), _data());
        assertEq(_slotAddress(IMPL_SLOT), address(implementation));
        assertEq(address(EX.quoter()), address(fresh));
    }

    function testPreExistingLongAndShortSurviveMigrationAndPartialThenFullClose() public {
        uint256 longId = _open(false, false);
        uint256 shortId = _open(true, false);
        bytes32 beforeState = _state();
        _migrate();
        assertEq(_state(), beforeState);
        vm.startPrank(USER);
        EX.closePosition(IsolatedMarginExecutorUpgradeable.CloseParams(longId, 5000, 0, 0, 0, "", ""));
        EX.closePosition(IsolatedMarginExecutorUpgradeable.CloseParams(shortId, 5000, 0, 0, 0, "", ""));
        vm.stopPrank();
        _close(longId);
        _close(shortId);
        assertEq(EX.vault().lockedBalance(USER, address(USD)), 0);
        _withdraw();
    }

    function testPreExistingDebtFreeExitSurvivesMigrationAndStalePrices() public {
        uint256 id = _open(false, false);
        _migrate();
        vm.startPrank(OWNER);
        FujiMockToken(USD.underlying()).transfer(USER, 200e6);
        vm.stopPrank();
        vm.startPrank(USER);
        FujiMockToken(USD.underlying()).approve(address(EX), type(uint256).max);
        EX.repayWithUnderlying(id, type(uint256).max);
        vm.stopPrank();
        vm.warp(block.timestamp + 1201);
        assertEq(EX.riskEngine().oracle().getPrice(AVAX.underlying()), 0);
        vm.prank(USER);
        EX.exitDebtFreeToPTokens(id, 0);
        assertGt(AVAX.balanceOf(USER), 0);
        assertEq(USD.borrowBalanceStored(_account(id)), 0);
        assertEq(EX.vault().lockedBalance(USER, address(USD)), 0);
    }

    function testLiquidationOfPreExistingLongImprovesHealthWhilePaused() public {
        uint256 id = _open(false, false);
        _migrate();
        vm.prank(OWNER);
        AF.setAnswer(7.5e8);
        uint256 beforeHealth = EX.riskEngine().getMetrics(_account(id)).healthFactorBps;
        assertTrue(EX.riskEngine().isLiquidatable(_account(id)));
        _liquidate(id);
        assertGt(EX.riskEngine().getMetrics(_account(id)).healthFactorBps, beforeHealth);
    }

    function testNewLongAndShortInsuranceLiquidationsClearRawDebt() public {
        _migrate();
        _unpause();
        for (uint256 side; side < 2; ++side) {
            _refresh();
            uint256 id = _open(side == 1, true);
            uint256 insuranceBefore = USD.balanceOf(EX.config().insuranceFund());
            vm.prank(OWNER);
            AF.setAnswer(side == 0 ? int256(4e8) : int256(25e8));
            _liquidate(id);
            assertEq((side == 0 ? USD : AVAX).borrowBalanceStored(_account(id)), 0);
            assertEq(EX.vault().lockedBalance(USER, address(USD)), 0);
            (,,,,,,,,,,, IsolatedMarginTypes.Status status) = EX.positions(id);
            assertEq(uint256(status), uint256(IsolatedMarginTypes.Status.LIQUIDATED));
            assertLt(USD.balanceOf(EX.config().insuranceFund()), insuranceBefore);
        }
    }

    function testActiveRewardStreamPreservedAndSettledIntoSamePTokens() public {
        vm.startPrank(OWNER);
        EX.config().queueFees(10, 10, 5000, 5000, 0);
        vm.warp(block.timestamp + EX.config().actionDelay());
        EX.config().setFees(10, 10, 5000, 5000, 0);
        vm.stopPrank();
        _refresh();
        _open(false, false);
        vm.warp(block.timestamp + 1 days);
        uint256 pendingBefore = EX.feeDistributor().pendingRewards(USER, address(USD));
        assertGt(pendingBefore, 0);
        bytes32 stateBefore = _state();
        _migrate();
        assertEq(_state(), stateBefore);
        assertEq(EX.feeDistributor().pendingRewards(USER, address(USD)), pendingBefore);
        uint256 free = EX.vault().freeBalance(USER, address(USD));
        vm.startPrank(USER);
        EX.vault().settle(address(USD));
        vm.stopPrank();
        assertEq(EX.vault().freeBalance(USER, address(USD)), free + pendingBefore);
        assertEq(EX.feeDistributor().pendingRewards(USER, address(USD)), 0);
    }

    function testActualMigrationScriptAndQuoteAwareSmokeWithSeparateWithdraw() public {
        vm.setEnv("CONFIRM_FUJI_MOCK_ONLY", "true");
        vm.setEnv("CONFIRM_FUJI_QUOTER_MIGRATION", "true");
        MigrateFujiMockOpeningQuoter script = new MigrateFujiMockOpeningQuoter();
        (IsolatedMarginQuoter replacement, Migration implementation) = script.run();
        assertEq(_slotAddress(IMPL_SLOT), address(implementation));
        assertEq(address(EX.quoter()), address(replacement));
        assertTrue(EX.config().opensPaused());
        assertEq(EX.config().queuedActions(keccak256("unpauseOpens")), 0);
        vm.expectRevert("Migrate: implementation changed");
        script.run();
        _unpause();
        uint256 before = USD.balanceOf(OWNER);
        SmokeFujiMockMargin smoke = new SmokeFujiMockMargin();
        smoke.run();
        assertEq(USD.allowance(OWNER, address(EX.vault())), 0);
        assertEq(USD.totalBorrows(), 0);
        assertEq(AVAX.totalBorrows(), 0);
        smoke.withdraw();
        assertEq(EX.vault().freeBalance(OWNER, address(USD)), 0);
        assertApproxEqAbs(USD.balanceOf(OWNER), before, 100_000);
        vm.setEnv("CONFIRM_FUJI_QUOTER_MIGRATION", "false");
        vm.setEnv("CONFIRM_FUJI_MOCK_ONLY", "false");
    }

    function testScriptRefusesMissingConfirmationsAndPendingUnpause() public {
        MigrateFujiMockOpeningQuoter script = new MigrateFujiMockOpeningQuoter();
        vm.setEnv("CONFIRM_FUJI_MOCK_ONLY", "false");
        vm.expectRevert("Migrate: mock confirmation required");
        script.run();
        vm.setEnv("CONFIRM_FUJI_MOCK_ONLY", "true");
        vm.setEnv("CONFIRM_FUJI_QUOTER_MIGRATION", "false");
        vm.expectRevert("Migrate: migration confirmation required");
        script.run();
        vm.setEnv("CONFIRM_FUJI_QUOTER_MIGRATION", "true");
        vm.startPrank(OWNER);
        EX.config().queueUnpauseOpens();
        vm.stopPrank();
        vm.expectRevert("Migrate: pending unpause");
        script.run();
        vm.setEnv("CONFIRM_FUJI_QUOTER_MIGRATION", "false");
        vm.setEnv("CONFIRM_FUJI_MOCK_ONLY", "false");
    }

    function _migrate() private {
        _pause();
        _upgrade(new Migration(address(fresh)));
    }

    function _pause() private {
        vm.startPrank(OWNER);
        EX.config().pauseOpens();
        vm.stopPrank();
    }

    function _upgrade(Migration implementation) private {
        vm.prank(OWNER);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(EX)), address(implementation), _data());
    }

    function _expectFailedUpgrade(Migration implementation, uint8 code) private {
        address previous = _slotAddress(IMPL_SLOT);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Migration.MigrationError.selector, code));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(EX)), address(implementation), _data());
        assertEq(_slotAddress(IMPL_SLOT), previous);
        assertEq(address(EX.quoter()), OLD);
    }

    function _unpause() private {
        // Resolve the getter before expectRevert so it applies to the intended governance call.
        IsolatedMarginConfigUpgradeable config = EX.config();
        vm.startPrank(OWNER);
        config.queueUnpauseOpens();
        uint256 eta = block.timestamp + config.actionDelay();
        vm.warp(eta - 1);
        vm.expectRevert("MarginConfig: not ready");
        config.unpauseOpens();
        vm.warp(eta);
        config.unpauseOpens();
        vm.stopPrank();
        _refresh();
    }

    function _refresh() private {
        vm.startPrank(OWNER);
        AF.setAnswer(10e8);
        UF.setAnswer(1e8);
        vm.stopPrank();
    }

    function _open(bool short, bool migrated) private returns (uint256) {
        uint256 minimum = short ? 199_800_000 : 19.8e18;
        if (migrated) {
            USD.exchangeRateCurrent();
            AVAX.exchangeRateCurrent();
            (, minimum) = EX.quoter()
                .quoteOpen(
                    address(USD),
                    short ? address(USD) : address(AVAX),
                    short ? address(AVAX) : address(USD),
                    MARGIN * USD.exchangeRateStored() / 1e18,
                    200
                );
        }
        vm.prank(USER);
        return EX.openPosition(
            IsolatedMarginExecutorUpgradeable.OpenParams(
                address(USD),
                short ? address(USD) : address(AVAX),
                short ? address(AVAX) : address(USD),
                MARGIN,
                200,
                MARGIN / 100,
                minimum,
                short ? IsolatedMarginTypes.Side.SHORT : IsolatedMarginTypes.Side.LONG,
                ""
            )
        );
    }

    function _account(uint256 id) private view returns (address account) {
        (,, account,,,,,,,,,) = EX.positions(id);
    }

    function _close(uint256 id) private {
        vm.prank(USER);
        EX.closePosition(IsolatedMarginExecutorUpgradeable.CloseParams(id, 10_000, 0, 0, 0, "", ""));
        assertEq(USD.borrowBalanceStored(_account(id)), 0);
        assertEq(AVAX.borrowBalanceStored(_account(id)), 0);
    }

    function _withdraw() private {
        uint256 free = EX.vault().freeBalance(USER, address(USD));
        vm.startPrank(USER);
        EX.vault().withdraw(address(USD), free);
        vm.stopPrank();
        assertEq(USD.balanceOf(USER), free);
    }

    function _liquidate(uint256 id) private {
        LIQ.liquidate(IsolatedMarginLiquidatorUpgradeable.LiquidationParams(id, address(0xBEEF), 0, 0, "", ""));
    }

    function _data() private pure returns (bytes memory) {
        return abi.encodeCall(Migration.migrateOpeningQuoter, ());
    }

    function _state() private view returns (bytes32 hash) {
        // Slot 5 is the existing quoter pointer; all other linear slots, including the gap, must be preserved.
        for (uint256 i; i < 80; ++i) {
            if (i != 5) hash = keccak256(abi.encode(hash, vm.load(address(EX), bytes32(i))));
        }
        // Include complete position getter encodings and external custody/reward state, not just mapping roots.
        for (uint256 id = 1; id < EX.nextPositionId(); ++id) {
            (bool ok, bytes memory position) = address(EX).staticcall(abi.encodeWithSignature("positions(uint256)", id));
            require(ok);
            hash = keccak256(
                abi.encode(
                    hash,
                    position,
                    USD.balanceOf(_account(id)),
                    AVAX.balanceOf(_account(id)),
                    USD.borrowBalanceStored(_account(id)),
                    AVAX.borrowBalanceStored(_account(id))
                )
            );
        }
        hash = keccak256(
            abi.encode(
                hash,
                EX.vault().freeBalance(USER, address(USD)),
                EX.vault().lockedBalance(USER, address(USD)),
                USD.balanceOf(address(EX.vault())),
                USD.balanceOf(address(EX.feeDistributor())),
                EX.feeDistributor().pendingRewards(USER, address(USD))
            )
        );
    }
}

/// @notice Reuses the exact 24 cost/boundary/lifecycle scenarios but installs via the real migration.
/// @dev The inherited code-substitution hook is fully overridden; no etch/store occurs in these tests.
contract FujiMockMigratedSizingForkTest is FujiMockSizingFixForkTest {
    function _installOpeningCode() internal override {
        IsolatedMarginQuoter replacement = new IsolatedMarginQuoter(address(CONFIG), address(RISK.oracle()));
        Migration implementation = new Migration(address(replacement));
        vm.startPrank(OWNER);
        CONFIG.pauseOpens();
        ProxyAdmin(implementation.EXPECTED_ADMIN())
            .upgradeAndCall(
                ITransparentUpgradeableProxy(address(EX)),
                address(implementation),
                abi.encodeCall(Migration.migrateOpeningQuoter, ())
            );
        assertEq(address(EX.quoter()), address(replacement));
        assertEq(Migration(address(EX)).initializedVersion(), 2);
        assertEq(address(EX.swapModule().quoter()), implementation.OLD_QUOTER());
        CONFIG.queueUnpauseOpens();
        vm.warp(block.timestamp + CONFIG.actionDelay());
        CONFIG.unpauseOpens();
        vm.stopPrank();
    }
}

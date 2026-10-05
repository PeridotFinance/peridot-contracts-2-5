// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployFujiCollateralMargin as Deploy} from "../script/DeployFujiCollateralMargin.s.sol";
import {ConfigureFujiCollateralMargin as Configure} from "../script/ConfigureFujiCollateralMargin.s.sol";
import {ReduceFujiCollateralMarginDelay as ReduceDelay} from "../script/ReduceFujiCollateralMarginDelay.s.sol";
import {CollateralPreservingExecutor as Executor} from "../contracts/margin/CollateralPreservingExecutor.sol";
import {CollateralPreservingRiskEngine as Risk} from "../contracts/margin/CollateralPreservingRiskEngine.sol";
import {IsolatedMarginTypes as Types} from "../contracts/margin/IsolatedMarginTypes.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {PToken} from "../contracts/PToken.sol";
import {
    FujiMockPharaohVault,
    FujiMockPharaohBinding,
    FujiMockPharaohRouter
} from "../contracts/margin/testing/FujiMockPharaoh.sol";

contract FujiCollateralMarginDeploymentTest is Test {
    address constant OWNER = address(0xC011A7);
    Deploy deployer;
    Configure configure;
    Deploy.Deployment d;

    function setUp() public {
        vm.chainId(43_113);
        vm.warp(1_800_000_000);
        vm.setEnv("CP_FUJI_DEPLOYER", vm.toString(OWNER));
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_MOCK_ONLY", "true");
        deployer = new Deploy();
        configure = new Configure();
    }

    function _deploy() private {
        // setEnv is process-global, unlike EVM snapshot state between tests.
        vm.setEnv("CP_FUJI_DEPLOYER", vm.toString(OWNER));
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_MOCK_ONLY", "true");
        d = deployer.run();
        vm.setEnv("CP_FUJI_EXECUTOR", vm.toString(address(d.executor)));
        configure.verify(address(d.executor), OWNER);
    }

    function _configured() private {
        _deploy();
        configure.run();
        vm.warp(block.timestamp + 1 hours);
        configure.execute();
    }

    function testDeploymentSeedsFreshPausedMarketsAndClearsApprovals() public {
        _deploy();
        assertEq(d.config.actionDelay(), 1 hours);
        assertEq(d.executor.nextPositionId(), 1);
        assertEq(d.controller.admin(), OWNER);
        assertEq(d.unitroller.pendingAdmin(), address(0));
        assertTrue(d.plainBootstrap.used() && d.boostedBootstrap.used());
        assertEq(d.usd.balanceOf(OWNER), 10_000e6);
        assertEq(d.avax.balanceOf(OWNER), 1000e18);
        assertEq(d.usd.balanceOf(address(d.insurance)), 10_000e6);
        assertEq(d.avax.balanceOf(address(d.insurance)), 1000e18);
        assertEq(d.usdVault.maxDeposit(OWNER), 0);
        assertEq(d.avaxVault.maxMint(OWNER), 0);
        assertEq(d.usd.allowance(OWNER, address(d.usdVault)), 0);
        assertEq(d.avax.allowance(OWNER, address(d.avaxVault)), 0);
        address[4] memory markets = [address(d.pUsd), address(d.pAvax), address(d.pUsdVault), address(d.pAvaxVault)];
        for (uint256 i; i < 4; ++i) {
            PErc20 p = PErc20(markets[i]);
            assertEq(p.pendingAdmin(), address(0));
            assertEq(p.balanceOf(OWNER), p.totalSupply());
            address bootstrap = i < 2 ? address(d.plainBootstrap) : address(d.boostedBootstrap);
            assertEq(IERC20(p.underlying()).allowance(OWNER, bootstrap), 0);
            assertEq(IERC20(p.underlying()).allowance(bootstrap, markets[i]), 0);
            assertEq(IERC20(p.underlying()).balanceOf(bootstrap), 0);
        }
        _assertPaused();
    }

    function testScriptsRejectMainnetOtherChainsAndMissingConfirmation() public {
        uint256 nonce = vm.getNonce(OWNER);
        vm.chainId(43_114);
        vm.expectRevert("CollateralFuji: Fuji only");
        deployer.run();
        vm.expectRevert("CollateralFuji: Fuji only");
        configure.run();
        vm.expectRevert("CollateralFuji: Fuji only");
        configure.execute();
        vm.chainId(1);
        vm.expectRevert("CollateralFuji: Fuji only");
        deployer.run();
        vm.chainId(43_113);
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_MOCK_ONLY", "false");
        vm.expectRevert("CollateralFuji: confirmation required");
        deployer.run();
        vm.expectRevert("CollateralFuji: confirmation required");
        configure.run();
        assertEq(vm.getNonce(OWNER), nonce);
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_MOCK_ONLY", "true");
    }

    function testDeploymentRejectsZeroOwner() public {
        vm.setEnv("CP_FUJI_DEPLOYER", vm.toString(address(0)));
        vm.expectRevert("CollateralFuji: zero owner");
        deployer.run();
        vm.setEnv("CP_FUJI_DEPLOYER", vm.toString(OWNER));
    }

    function testOldEnvironmentInputsAreIgnoredAndNotOverwritten() public {
        vm.setEnv("PERIDOTTROLLER", vm.toString(address(0xBAD)));
        vm.setEnv("MARGIN_ROUTER_ADAPTER", vm.toString(address(0xBAD)));
        vm.setEnv("MARGIN_ENABLE_TRADING", "true");
        vm.setEnv("MOCK_ENABLE_TRADING", "true");
        _deploy();
        assertEq(vm.envAddress("PERIDOTTROLLER"), address(0xBAD));
        assertEq(vm.envAddress("MARGIN_ROUTER_ADAPTER"), address(0xBAD));
        _assertPaused();
    }

    function testConfigurationQueuesExactlyFiveThenExecutesWithoutActivation() public {
        _deploy();
        bytes32[5] memory ids = configure.actionIds(address(d.executor));
        for (uint256 i; i < 5; ++i) {
            assertEq(d.config.queuedActions(ids[i]), 0);
        }
        configure.run();
        for (uint256 i; i < 5; ++i) {
            assertEq(d.config.queuedActions(ids[i]), block.timestamp + 1 hours);
        }
        vm.expectRevert("CollateralFuji: queue state/time");
        configure.execute();
        vm.warp(block.timestamp + 1 hours - 1);
        vm.expectRevert("CollateralFuji: queue state/time");
        configure.execute();
        vm.warp(block.timestamp + 1);
        configure.execute();
        for (uint256 i; i < 5; ++i) {
            assertEq(d.config.queuedActions(ids[i]), 0);
        }
        assertEq(d.config.openFeeBps(), 10);
        assertEq(d.config.closeFeeBps(), 10);
        assertEq(d.config.depositorShareBps(), 5000);
        assertEq(d.config.insuranceShareBps(), 5000);
        assertEq(d.config.treasuryShareBps(), 0);
        address[2] memory collaterals = [address(d.pUsdVault), address(d.pAvaxVault)];
        for (uint256 i; i < 2; ++i) {
            assertEq(
                abi.encode(d.config.getPairRisk(collaterals[i], address(d.pAvax), address(d.pUsd))),
                abi.encode(configure.pair())
            );
            assertEq(
                abi.encode(d.config.getPairRisk(collaterals[i], address(d.pUsd), address(d.pAvax))),
                abi.encode(configure.pair())
            );
        }
        _assertPaused();
        vm.expectRevert("CollateralFuji: already configured");
        configure.run();
        vm.expectRevert("CollateralFuji: queue state/time");
        configure.execute();
    }

    function testPartialQueueRerunAndCancelledActionFailBeforeBroadcast() public {
        _deploy();
        vm.prank(OWNER);
        d.config.queueFees(10, 10, 5000, 5000, 0);
        vm.expectRevert("CollateralFuji: queue state/time");
        configure.run();
        bytes32[5] memory ids = configure.actionIds(address(d.executor));
        assertEq(d.config.queuedActions(ids[1]), 0);
        vm.prank(OWNER);
        d.config.cancelAction(ids[0]);
        configure.run();
        vm.prank(OWNER);
        d.config.cancelAction(ids[4]);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert("CollateralFuji: queue state/time");
        configure.execute();
        assertEq(d.config.openFeeBps(), 0);
        assertGt(d.config.queuedActions(ids[0]), 0);
    }

    function testConfigurationRejectsUnpauseQueueWrongOwnerAndBorrowGate() public {
        _deploy();
        vm.expectRevert();
        configure.verify(address(d.executor), address(0xBAD));
        vm.prank(OWNER);
        d.config.queueUnpauseOpens();
        vm.expectRevert("CollateralFuji: pause policy");
        configure.run();
        vm.prank(OWNER);
        d.config.cancelAction(keccak256("unpauseOpens"));
        vm.prank(OWNER);
        d.controller._setBorrowPaused(PToken(address(d.pUsd)), false);
        vm.expectRevert("CollateralFuji: market state");
        configure.run();
    }

    function testConfigurationRejectsMissingInsuranceAndForeignExecutor() public {
        _deploy();
        vm.expectRevert();
        configure.verify(address(d.controller), OWNER);
        deal(address(d.usd), address(d.insurance), 0);
        vm.expectRevert("CollateralFuji: cash insurance");
        configure.run();
    }

    function _legacyDelay() private returns (ReduceDelay migration) {
        _deploy();
        // Reproduce the already-deployed 24h policy through its normal governance path.
        vm.prank(OWNER);
        d.config.queueActionDelay(1 days);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(OWNER);
        d.config.setActionDelay(1 days);
        configure.verify(address(d.executor), OWNER);
        migration = new ReduceDelay();
    }

    function testDelayReductionHonorsOldDeadlineAndPreservesExistingQueues() public {
        ReduceDelay migration = _legacyDelay();
        // Read through Vm so the optimizer cannot treat time as constant across warps.
        uint256 start = vm.getBlockTimestamp();
        migration.run();
        assertEq(d.config.actionDelay(), 1 days);
        assertEq(d.config.queuedActions(migration.actionId()), start + 1 days);

        vm.warp(start + 30 minutes);
        configure.run();
        bytes32[5] memory ids = configure.actionIds(address(d.executor));
        vm.prank(OWNER);
        d.config.queueUnpauseOpens();
        uint256 originalEta = start + 30 minutes + 1 days;
        vm.expectRevert("CollateralFuji: pause policy");
        configure.verify(address(d.executor), OWNER); // Ordinary configuration still rejects unpause queues.
        configure.verifyDelayTransition(address(d.executor), OWNER);

        vm.warp(start + 1 days - 1);
        vm.expectRevert("CollateralFuji: queue state/time");
        migration.execute();
        vm.warp(start + 1 days);
        migration.execute();
        assertEq(d.config.actionDelay(), 1 hours);
        assertEq(d.config.queuedActions(migration.actionId()), 0);
        assertEq(d.config.queuedActions(keccak256("unpauseOpens")), originalEta);
        for (uint256 i; i < ids.length; ++i) {
            assertEq(d.config.queuedActions(ids[i]), originalEta);
        }
        vm.prank(OWNER);
        vm.expectRevert("MarginConfig: not ready");
        d.config.unpauseOpens();
        vm.prank(OWNER);
        bytes32 next = d.config.queueFeeDistribution(0, 7 days);
        assertEq(d.config.queuedActions(next), block.timestamp + 1 hours);
        vm.warp(block.timestamp + 1 hours - 1);
        vm.prank(OWNER);
        vm.expectRevert("MarginConfig: not ready");
        d.config.setFeeDistribution(0, 7 days);
        vm.warp(block.timestamp + 1);
        vm.prank(OWNER);
        d.config.setFeeDistribution(0, 7 days);
        _assertPausedGates();
        assertEq(d.config.queuedActions(keccak256("unpauseOpens")), originalEta);
        vm.expectRevert("CollateralFuji: expected legacy delay");
        migration.execute();
    }

    function testLegacyConfigurationStillUsesStored24HourDeadline() public {
        _legacyDelay();
        configure.run();
        uint256 queuedAt = vm.getBlockTimestamp();
        vm.warp(queuedAt + 1 hours);
        vm.expectRevert("CollateralFuji: queue state/time");
        configure.execute();
        vm.warp(queuedAt + 1 days);
        configure.execute();
        assertEq(d.config.openFeeBps(), 10);
        _assertPaused();
    }

    function testDelayReductionRejectsDuplicateMissingAndCanceledQueue() public {
        ReduceDelay migration = _legacyDelay();
        vm.expectRevert("CollateralFuji: queue state/time");
        migration.execute();
        migration.run();
        vm.expectRevert("CollateralFuji: queue state/time");
        migration.run();
        bytes32 id = migration.actionId();
        vm.prank(OWNER);
        d.config.cancelAction(id);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert("CollateralFuji: queue state/time");
        migration.execute();
        assertEq(d.config.actionDelay(), 1 days);
        _assertPaused();
    }

    function testDelayReductionRejectsMainnetOtherChainsAndMissingConfirmation() public {
        ReduceDelay migration = new ReduceDelay();
        vm.chainId(43_114);
        vm.expectRevert("CollateralFuji: Fuji only");
        migration.run();
        vm.expectRevert("CollateralFuji: Fuji only");
        migration.execute();
        vm.chainId(1);
        vm.expectRevert("CollateralFuji: Fuji only");
        migration.run();
        vm.chainId(43_113);
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_MOCK_ONLY", "false");
        vm.expectRevert("CollateralFuji: confirmation required");
        migration.run();
        vm.expectRevert("CollateralFuji: confirmation required");
        migration.execute();
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_MOCK_ONLY", "true");
    }

    function testDelayReductionRejectsWrongOwnerAndUnpausedMarket() public {
        ReduceDelay migration = _legacyDelay();
        vm.setEnv("CP_FUJI_DEPLOYER", vm.toString(address(0xBAD)));
        vm.expectRevert();
        migration.run();
        vm.setEnv("CP_FUJI_DEPLOYER", vm.toString(OWNER));
        vm.prank(OWNER);
        d.controller._setBorrowPaused(PToken(address(d.pUsd)), false);
        vm.expectRevert("CollateralFuji: market state");
        migration.run();
        assertEq(d.config.queuedActions(migration.actionId()), 0);
    }

    function testDelayReductionRequiresPausedStateAgainAtExecution() public {
        ReduceDelay migration = _legacyDelay();
        migration.run();
        vm.warp(block.timestamp + 1 days);
        vm.prank(OWNER);
        d.venue.setPaused(false);
        vm.expectRevert("CollateralFuji: venue gates");
        migration.execute();
        assertEq(d.config.actionDelay(), 1 days);
        assertGt(d.config.queuedActions(migration.actionId()), 0);
    }

    function testDelayVerifierRejectsUnsupportedDelayAndMigrationRejectsNewDefault() public {
        _deploy();
        ReduceDelay migration = new ReduceDelay();
        vm.expectRevert("CollateralFuji: expected legacy delay");
        migration.run();
        vm.prank(OWNER);
        vm.expectRevert("MarginConfig: delay too short");
        d.config.queueActionDelay(1 hours - 1);
        vm.prank(OWNER);
        d.config.queueActionDelay(2 hours);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(OWNER);
        d.config.setActionDelay(2 hours);
        vm.expectRevert("CollateralFuji: pause policy");
        configure.verify(address(d.executor), OWNER);
        vm.expectRevert("CollateralFuji: pause policy");
        migration.run();
    }

    function testConfigurationRejectsChangedOracleAndEmergencyPrices() public {
        _deploy();
        vm.prank(OWNER);
        d.baseOracle.disableFeed(address(d.usd));
        vm.expectRevert("CollateralFuji: base feed");
        configure.run();
        vm.startPrank(OWNER);
        d.baseOracle.configureFeed(address(d.usd), address(d.usdFeed), 1200);
        d.baseOracle.setEmergencyPrice(address(d.usd), 1e18, uint64(block.timestamp + 1 hours));
        vm.stopPrank();
        vm.expectRevert("CollateralFuji: emergency price");
        configure.run();
    }

    function testMockComponentsRejectMainnetAndForeignOperators() public {
        _deploy();
        vm.expectRevert();
        d.router.setOperator(address(this));
        vm.prank(OWNER);
        vm.expectRevert("FujiPharaoh: operator");
        d.router.setOperator(address(this));
        vm.chainId(43_114);
        vm.expectRevert("FujiPharaoh: mock Fuji only");
        new FujiMockPharaohVault(OWNER, d.usd);
        vm.expectRevert("FujiPharaoh: mock Fuji only");
        new FujiMockPharaohBinding(address(d.avax), address(d.usd));
        vm.expectRevert("FujiPharaoh: mock Fuji only");
        new FujiMockPharaohRouter(OWNER, address(d.binding), d.venue);
    }

    function testMockVaultClosureEnforcesAllEntryAndExitMethods() public {
        _deploy();
        vm.startPrank(OWNER);
        d.usd.approve(address(d.usdVault), 1e6);
        vm.expectRevert();
        d.usdVault.deposit(1e6, OWNER);
        vm.expectRevert();
        d.usdVault.mint(1e6, OWNER);
        d.usdVault.setLimits(false, false);
        d.usdVault.deposit(1e6, OWNER);
        d.usdVault.setLimits(true, true);
        vm.expectRevert();
        d.usdVault.withdraw(1, OWNER, OWNER);
        vm.expectRevert();
        d.usdVault.redeem(1, OWNER, OWNER);
        vm.stopPrank();
        vm.expectRevert();
        d.usdVault.setLimits(false, false);
    }

    function testKeyDeployedRuntimesFitEip170() public {
        _deploy();
        address[16] memory deployed = [
            address(d.executor),
            address(d.risk),
            address(d.settlement),
            address(d.swapModule),
            d.plainDelegate,
            d.boostedDelegate,
            address(d.implementation),
            address(d.usdVault),
            address(d.router),
            address(d.binding),
            address(d.plainBootstrap),
            address(d.boostedBootstrap),
            address(d.cl),
            address(d.adapter),
            address(d.pUsd),
            address(d.pUsdVault)
        ];
        for (uint256 i; i < deployed.length; ++i) {
            assertLe(deployed[i].code.length, 24_576);
        }
    }

    // Only TEST code activates the freshly simulated stack. No script exposes this.
    function _activateLocally() private {
        vm.prank(OWNER);
        d.config.queueUnpauseOpens();
        vm.warp(block.timestamp + 1 hours);
        vm.startPrank(OWNER);
        d.usdFeed.setAnswer(1e8);
        d.avaxFeed.setAnswer(10e8);
        d.venue.setPaused(false);
        d.lender.setPaused(false);
        d.controller._setBorrowPaused(PToken(address(d.pUsd)), false);
        d.controller._setBorrowPaused(PToken(address(d.pAvax)), false);
        d.config.unpauseOpens();
        vm.stopPrank();
    }

    function testScriptDeployedStackTwoThroughFiveXBothCollateralsAndSides() public {
        _configured();
        _activateLocally();
        for (uint256 c; c < 2; ++c) {
            address collateral = c == 0 ? address(d.pUsdVault) : address(d.pAvaxVault);
            vm.startPrank(OWNER);
            IERC20(collateral).approve(address(d.vault), 200e10);
            d.vault.deposit(collateral, 200e10);
            IERC20(collateral).approve(address(d.vault), 0);
            vm.stopPrank();
            for (uint256 side; side < 2; ++side) {
                for (uint16 leverage = 200; leverage <= 500; leverage += 100) {
                    _roundTrip(collateral, side == 1, leverage);
                }
            }
            uint256 free = d.vault.freeBalance(OWNER, collateral);
            uint256 wallet = IERC20(collateral).balanceOf(OWNER);
            vm.prank(OWNER);
            d.vault.withdraw(collateral, free);
            assertEq(IERC20(collateral).balanceOf(OWNER), wallet + free);
        }
    }

    function _open(address collateral, bool short, uint16 leverage) private returns (uint256 id) {
        Executor.OpenParams memory p;
        p.collateral = collateral;
        p.short = short;
        p.leverageX100 = leverage;
        p.collateralShares = d.quoter.feePToken(collateral, 100e18);
        p.maxFeeShares = type(uint256).max;
        p.deadline = block.timestamp;
        vm.prank(OWNER);
        id = d.executor.openPosition(p);
        (, address account,,,,) = d.executor.positions(id);
        assertEq(IERC20(collateral).balanceOf(account), p.collateralShares);
        Risk.Snapshot memory s = d.risk.snapshot(account, 0);
        assertFalse(s.metrics.liquidatable);
        assertLe(s.metrics.tradingLeverageX100, leverage);
        assertGt(s.metrics.tradingLeverageX100, leverage * 90 / 100);
    }

    function _roundTrip(address collateral, bool short, uint16 leverage) private {
        uint256 id = _open(collateral, short, leverage);
        (, address account,,, address debt,) = d.executor.positions(id);
        vm.roll(block.number + 100);
        Executor.CloseParams memory p;
        p.id = id;
        p.fractionBps = 10_000;
        p.maxFeeShares = type(uint256).max;
        p.maxCollateralSharesToSell = type(uint256).max;
        p.deadline = block.timestamp;
        vm.prank(OWNER);
        d.executor.closePosition(p);
        assertEq(PErc20(debt).borrowBalanceStored(account), 0);
        assertEq(d.vault.lockedBalance(OWNER, collateral), 0);
        assertEq(d.usd.allowance(address(d.router), address(d.venue)), 0);
        assertEq(d.avax.allowance(address(d.router), address(d.venue)), 0);
        assertEq(d.usd.balanceOf(address(d.router)), 0);
        assertEq(d.avax.balanceOf(address(d.router)), 0);
    }

    function testScriptDeployedStackSupportsPausedOracleFreeRecovery() public {
        _configured();
        _activateLocally();
        address collateral = address(d.pUsdVault);
        vm.startPrank(OWNER);
        IERC20(collateral).approve(address(d.vault), 100e10);
        d.vault.deposit(collateral, 100e10);
        vm.stopPrank();
        uint256 id = _open(collateral, false, 500);
        (, address account,, address position, address debt,) = d.executor.positions(id);
        uint256 trade = IERC20(position).balanceOf(account);
        uint256 wallet = IERC20(position).balanceOf(OWNER);
        vm.startPrank(OWNER);
        d.config.pauseOpens();
        d.venue.setPaused(true);
        d.lender.setPaused(true);
        d.usdVault.setLimits(true, true);
        d.usd.approve(address(d.executor), type(uint256).max);
        vm.warp(block.timestamp + 31 days);
        d.executor.emergencyExitToPTokens(id, type(uint256).max);
        vm.stopPrank();
        assertEq(PErc20(debt).borrowBalanceStored(account), 0);
        assertEq(d.vault.lockedBalance(OWNER, collateral), 0);
        assertEq(IERC20(position).balanceOf(OWNER), wallet + trade);
        (,,, Types.Status status,) = d.risk.accounts(account);
        assertEq(uint256(status), uint256(Types.Status.CLOSED));
    }

    function testScriptDeployedStackPartialAndInsuredLiquidationBothCollateralsAndSides() public {
        _configured();
        _activateLocally();
        for (uint256 c; c < 2; ++c) {
            for (uint256 side; side < 2; ++side) {
                uint256 checkpoint = vm.snapshotState();
                address collateral = c == 0 ? address(d.pUsdVault) : address(d.pAvaxVault);
                vm.startPrank(OWNER);
                IERC20(collateral).approve(address(d.vault), 200e10);
                d.vault.deposit(collateral, 200e10);
                vm.stopPrank();
                uint256 id = _open(collateral, side == 1, 500);
                (, address account,,, address debt,) = d.executor.positions(id);
                // Same synthetic stress levels as the production-venue fork fixture.
                uint256 bps = c == 0 ? (side == 0 ? 8700 : 11_300) : (side == 0 ? 8800 : 11_600);
                vm.prank(OWNER);
                d.avaxFeed.setAnswer(int256(10e8 * bps / 10_000));
                Risk.Snapshot memory beforeState = d.risk.snapshot(account, 0);
                assertTrue(beforeState.metrics.liquidatable);
                Executor.CloseParams memory p;
                p.id = id;
                p.fractionBps = 5000;
                p.deadline = block.timestamp;
                d.executor.liquidate(p, 0);
                assertGt(d.risk.snapshot(account, 0).metrics.healthFactorBps, beforeState.metrics.healthFactorBps);
                vm.prank(OWNER);
                d.avaxFeed.setAnswer(side == 0 ? int256(5e8) : int256(20e8));
                assertLt(d.risk.snapshot(account, 0).metrics.equityUsd, 0);
                p.fractionBps = 10_000;
                address asset = PErc20(debt).underlying();
                uint256 insuranceBefore = IERC20(asset).balanceOf(address(d.insurance));
                d.executor.liquidate(p, side == 0 ? 1000e6 : 100e18);
                assertLt(IERC20(asset).balanceOf(address(d.insurance)), insuranceBefore);
                assertEq(PErc20(debt).borrowBalanceStored(account), 0);
                assertEq(d.vault.lockedBalance(OWNER, collateral), 0);
                (,,, Types.Status status,) = d.risk.accounts(account);
                assertEq(uint256(status), uint256(Types.Status.LIQUIDATED));
                assertTrue(vm.revertToStateAndDelete(checkpoint));
            }
        }
    }

    function _assertPaused() private view {
        _assertPausedGates();
        assertEq(d.config.queuedActions(keccak256("unpauseOpens")), 0);
    }

    function _assertPausedGates() private view {
        assertTrue(d.config.opensPaused() && d.venue.paused() && d.lender.paused());
        assertTrue(d.controller.borrowGuardianPaused(address(d.pUsd)));
        assertTrue(d.controller.borrowGuardianPaused(address(d.pAvax)));
        assertTrue(d.controller.borrowGuardianPaused(address(d.pUsdVault)));
        assertTrue(d.controller.borrowGuardianPaused(address(d.pAvaxVault)));
    }
}

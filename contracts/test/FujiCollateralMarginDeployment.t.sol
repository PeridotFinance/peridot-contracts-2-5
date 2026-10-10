// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployFujiCollateralMargin as Deploy} from "../script/DeployFujiCollateralMargin.s.sol";
import {ConfigureFujiCollateralMargin as Configure} from "../script/ConfigureFujiCollateralMargin.s.sol";
import {ReduceFujiCollateralMarginDelay as ReduceDelay} from "../script/ReduceFujiCollateralMarginDelay.s.sol";
import {ActivateFujiCollateralMargin as Activate} from "../script/ActivateFujiCollateralMargin.s.sol";
import {SmokeFujiCollateralMargin as Smoke} from "../script/SmokeFujiCollateralMargin.s.sol";
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
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_ACTIVATION", "false");
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_SMOKE", "false");
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_WITHDRAW", "false");
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

    // Exercise the real seven-call operator locally; this test never broadcasts to a network.
    function _activateLocally() private {
        vm.prank(OWNER);
        d.config.queueUnpauseOpens();
        vm.warp(block.timestamp + 1 hours);
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_ACTIVATION", "true");
        new Activate().run();
    }

    function _readyActivation() private returns (Activate activation) {
        _configured();
        vm.prank(OWNER);
        d.config.queueUnpauseOpens();
        vm.warp(block.timestamp + 1 hours);
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_ACTIVATION", "true");
        activation = new Activate();
    }

    function testActivationRefreshesStaleFeedsAndEnablesOnlyPlainBorrowing() public {
        Activate activation = _readyActivation();
        uint80 usdRound = d.usdFeed.roundId();
        uint80 avaxRound = d.avaxFeed.roundId();
        uint256 unpauseEta = d.config.queuedActions(keccak256("unpauseOpens"));
        vm.warp(block.timestamp + 3 days);
        assertEq(d.oracle.getPrice(address(d.usd)), 0);
        activation.run();
        activation.verify(address(d.executor), OWNER);
        assertEq(d.usdFeed.roundId(), usdRound + 1);
        assertEq(d.avaxFeed.roundId(), avaxRound + 1);
        assertEq(d.usdFeed.answer(), 1e8);
        assertEq(d.avaxFeed.answer(), 10e8);
        assertEq(d.config.queuedActions(keccak256("unpauseOpens")), 0);
        assertLt(unpauseEta, block.timestamp);
        assertFalse(d.config.opensPaused() || d.venue.paused() || d.lender.paused());
        assertFalse(d.controller.borrowGuardianPaused(address(d.pUsd)));
        assertFalse(d.controller.borrowGuardianPaused(address(d.pAvax)));
        assertTrue(d.controller.borrowGuardianPaused(address(d.pUsdVault)));
        assertTrue(d.controller.borrowGuardianPaused(address(d.pAvaxVault)));
        assertTrue(d.pUsd.flashLoansPaused() && d.pAvax.flashLoansPaused());
        assertTrue(d.pUsdVault.flashLoansPaused() && d.pAvaxVault.flashLoansPaused());
        assertEq(d.executor.nextPositionId(), 1);
        assertEq(d.vault.totalFreeBalance(address(d.pUsdVault)), 0);
        assertEq(d.vault.totalFreeBalance(address(d.pAvaxVault)), 0);
        vm.expectRevert("CollateralFuji: pause policy");
        activation.run();
        vm.warp(block.timestamp + 1201);
        vm.expectRevert("CollateralFuji: fresh mock feeds required");
        activation.verify(address(d.executor), OWNER);
    }

    function testActivationRejectsMainnetOtherChainsAndBothMissingConfirmations() public {
        Activate activation = new Activate();
        vm.chainId(43_114);
        vm.expectRevert("CollateralFuji: Fuji only");
        activation.run();
        vm.chainId(1);
        vm.expectRevert("CollateralFuji: Fuji only");
        activation.run();
        vm.chainId(43_113);
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_MOCK_ONLY", "false");
        vm.expectRevert("CollateralFuji: confirmation required");
        activation.run();
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_MOCK_ONLY", "true");
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_ACTIVATION", "false");
        vm.expectRevert("CollateralFuji: activation confirmation");
        activation.run();
    }

    function testActivationRejectsMissingImmatureAndCanceledUnpauseBeforeFeedWrites() public {
        _configured();
        Activate activation = new Activate();
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_ACTIVATION", "true");
        uint80 round = d.usdFeed.roundId();
        vm.expectRevert("CollateralFuji: unpause not ready");
        activation.run();
        vm.prank(OWNER);
        d.config.queueUnpauseOpens();
        vm.warp(block.timestamp + 1 hours - 1);
        vm.expectRevert("CollateralFuji: unpause not ready");
        activation.run();
        vm.prank(OWNER);
        d.config.cancelAction(keccak256("unpauseOpens"));
        vm.warp(block.timestamp + 1);
        vm.expectRevert("CollateralFuji: unpause not ready");
        activation.run();
        assertEq(d.usdFeed.roundId(), round);
        _assertPaused();
    }

    function testActivationRejectsPartialActivationBeforeMoreTransactions() public {
        Activate activation = _readyActivation();
        uint80 round = d.usdFeed.roundId();
        vm.prank(OWNER);
        d.venue.setPaused(false);
        vm.expectRevert("CollateralFuji: venue gates");
        activation.run();
        vm.prank(OWNER);
        d.venue.setPaused(true);
        vm.prank(OWNER);
        d.controller._setBorrowPaused(PToken(address(d.pUsd)), false);
        vm.expectRevert("CollateralFuji: market state");
        activation.run();
        assertEq(d.usdFeed.roundId(), round);
        assertTrue(d.config.opensPaused());
    }

    function testActivationRejectsAlteredFeesAndPendingConfiguration() public {
        Activate activation = _readyActivation();
        vm.prank(OWNER);
        d.config.queueFees(10, 10, 5000, 5000, 0);
        vm.expectRevert("CollateralFuji: pending configuration");
        activation.run();
        vm.startPrank(OWNER);
        d.config.queueFees(0, 0, 5000, 5000, 0);
        vm.warp(block.timestamp + 1 hours);
        d.config.setFees(0, 0, 5000, 5000, 0);
        vm.stopPrank();
        vm.expectRevert("CollateralFuji: activation fees");
        activation.run();
        _assertPausedGates();
    }

    function testActivationRejectsChangedPairPreset() public {
        Activate activation = _readyActivation();
        Types.PairRiskConfig memory risk = configure.pair();
        risk.maxDebtValueUsd = 4000e18;
        vm.startPrank(OWNER);
        d.config.queuePairRisk(address(d.pUsdVault), address(d.pAvax), address(d.pUsd), risk);
        vm.warp(block.timestamp + 1 hours);
        d.config.setPairRisk(address(d.pUsdVault), address(d.pAvax), address(d.pUsd), risk);
        vm.stopPrank();
        vm.expectRevert("CollateralFuji: activation pairs");
        activation.run();
        _assertPausedGates();
    }

    function testActivationRejectsAlteredCapsAndReducedLendingCash() public {
        Activate activation = _readyActivation();
        PToken[] memory markets = new PToken[](1);
        markets[0] = PToken(address(d.pUsd));
        uint256[] memory caps = new uint256[](1);
        caps[0] = 1;
        vm.prank(OWNER);
        d.controller._setMarketBorrowCaps(markets, caps);
        vm.expectRevert("CollateralFuji: activation liquidity policy");
        activation.run();
        caps[0] = 500_000e6;
        vm.prank(OWNER);
        d.controller._setMarketBorrowCaps(markets, caps);
        deal(address(d.usd), address(d.pUsd), 99_999e6);
        vm.expectRevert("CollateralFuji: activation liquidity policy");
        activation.run();
        _assertPausedGates();
    }

    function testActivationRejectsForeignExecutorOwnerAndMissingInsurance() public {
        Activate activation = _readyActivation();
        vm.setEnv("CP_FUJI_EXECUTOR", vm.toString(address(d.controller)));
        vm.expectRevert();
        activation.run();
        vm.setEnv("CP_FUJI_EXECUTOR", vm.toString(address(d.executor)));
        vm.setEnv("CP_FUJI_DEPLOYER", vm.toString(address(0xBAD)));
        vm.expectRevert();
        activation.run();
        vm.setEnv("CP_FUJI_DEPLOYER", vm.toString(OWNER));
        deal(address(d.usd), address(d.insurance), 0);
        vm.expectRevert("CollateralFuji: cash insurance");
        activation.run();
    }

    function testActivationRejectsLegacyDelayUntilTransitionCompletes() public {
        Activate activation = _readyActivation();
        vm.startPrank(OWNER);
        d.config.queueActionDelay(1 days);
        vm.warp(block.timestamp + 1 hours);
        d.config.setActionDelay(1 days);
        vm.stopPrank();
        vm.expectRevert("CollateralFuji: one-hour policy required");
        activation.run();
        _assertPausedGates();
    }

    function testActivationRejectsAlteredMockPriceWithoutSilentlyResettingIt() public {
        Activate activation = _readyActivation();
        vm.prank(OWNER);
        d.avaxFeed.setAnswer(9e8);
        vm.expectRevert("CollateralFuji: mock prices");
        activation.run();
        assertEq(d.avaxFeed.answer(), 9e8);
        _assertPausedGates();
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

    function _readySmoke() private returns (Smoke smoke) {
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_WITHDRAW", "false");
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_CONTINUATION", "false");
        _configured();
        _activateLocally();
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_SMOKE", "true");
        return new Smoke();
    }

    function testSmokeFourRoundTripsPreserveOriginalCollateralAndDistributeFees() public {
        Smoke smoke = _readySmoke();
        uint256 usdWallet = d.pUsdVault.balanceOf(OWNER);
        uint256 avaxWallet = d.pAvaxVault.balanceOf(OWNER);
        vm.recordLogs();
        smoke.run();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 feeEvents;
        uint256 retainedEvents;
        uint256[2] memory treasuryDust;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(d.fees)
                    && logs[i].topics[0] == keccak256("FeeCollected(address,uint256,uint256,uint256,uint256)")
            ) {
                address collateral = address(uint160(uint256(logs[i].topics[1])));
                (uint256 amount, uint256 depositor, uint256 insurance, uint256 treasury) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                assertTrue(collateral == address(d.pUsdVault) || collateral == address(d.pAvaxVault));
                assertGt(amount, 0);
                assertEq(depositor, amount / 2);
                assertEq(insurance, amount / 2);
                assertLe(treasury, 1); // Integer split dust only, not an extra fee.
                treasuryDust[collateral == address(d.pUsdVault) ? 0 : 1] += treasury;
                ++feeEvents;
            }
            if (
                logs[i].emitter == address(d.executor)
                    && logs[i].topics[0] == keccak256("Opened(uint256,address,address,uint256,uint256)")
            ) {
                (, uint256 collateralShares) = abi.decode(logs[i].data, (uint256, uint256));
                uint256 id = uint256(logs[i].topics[1]);
                assertEq(
                    collateralShares, (id <= 2 ? smoke.USD_DEPOSIT_SHARES() : smoke.AVAX_DEPOSIT_SHARES()) * 5 / 12
                );
                ++retainedEvents;
            }
        }
        assertEq(feeEvents, 8);
        assertEq(retainedEvents, 4);
        assertEq(d.pUsdVault.balanceOf(OWNER), usdWallet - smoke.USD_DEPOSIT_SHARES() + treasuryDust[0]);
        assertEq(d.pAvaxVault.balanceOf(OWNER), avaxWallet - smoke.AVAX_DEPOSIT_SHARES() + treasuryDust[1]);
        smoke.verify(address(d.executor), OWNER);
        assertFalse(d.config.opensPaused());
        assertTrue(d.controller.borrowGuardianPaused(address(d.pUsdVault)));
        assertTrue(d.controller.borrowGuardianPaused(address(d.pAvaxVault)));
        assertTrue(d.pUsd.flashLoansPaused() && d.pAvax.flashLoansPaused());
    }

    function testSmokeWithdrawReturnsPTokensWithoutFreshPricesOrRedemption() public {
        Smoke smoke = _readySmoke();
        smoke.run();
        vm.warp(block.timestamp + 8 days);
        vm.startPrank(OWNER);
        d.usdVault.setLimits(true, true);
        d.avaxVault.setLimits(true, true);
        vm.stopPrank();
        uint256 usdFree = d.vault.freeBalance(OWNER, address(d.pUsdVault));
        uint256 avaxFree = d.vault.freeBalance(OWNER, address(d.pAvaxVault));
        uint256 usdWallet = d.pUsdVault.balanceOf(OWNER);
        uint256 avaxWallet = d.pAvaxVault.balanceOf(OWNER);
        uint256 usdSupply = d.pUsdVault.totalSupply();
        uint256 avaxSupply = d.pAvaxVault.totalSupply();
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_WITHDRAW", "true");
        smoke.withdraw();
        assertEq(d.pUsdVault.balanceOf(OWNER), usdWallet + usdFree);
        assertEq(d.pAvaxVault.balanceOf(OWNER), avaxWallet + avaxFree);
        assertEq(d.pUsdVault.totalSupply(), usdSupply);
        assertEq(d.pAvaxVault.totalSupply(), avaxSupply);
        assertGt(d.vault.freeBalance(OWNER, address(d.pUsdVault)), 0); // Settled streaming rewards are retained, not redeemed.
        vm.expectRevert("CollateralSmoke: withdrawal budget");
        smoke.withdraw();
    }

    function testSmokeRefreshesStaleFeedsButDoesNotChangePrices() public {
        Smoke smoke = _readySmoke();
        vm.warp(block.timestamp + 2 days);
        assertEq(d.oracle.getPrice(address(d.usd)), 0);
        smoke.run();
        assertEq(d.usdFeed.answer(), 1e8);
        assertEq(d.avaxFeed.answer(), 10e8);
        assertEq(d.usdFeed.updatedAt(), block.timestamp);
        assertEq(d.avaxFeed.updatedAt(), block.timestamp);
    }

    function testSmokeRejectsMainnetOtherChainsAndMissingConfirmations() public {
        Smoke smoke = _readySmoke();
        vm.chainId(43_114);
        vm.expectRevert("CollateralSmoke: Fuji only");
        smoke.run();
        vm.expectRevert("CollateralSmoke: Fuji only");
        smoke.withdraw();
        vm.chainId(1);
        vm.expectRevert("CollateralSmoke: Fuji only");
        smoke.run();
        vm.chainId(43_113);
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_MOCK_ONLY", "false");
        vm.expectRevert("CollateralSmoke: mock confirmation");
        smoke.run();
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_MOCK_ONLY", "true");
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_SMOKE", "false");
        vm.expectRevert("CollateralSmoke: confirmation");
        smoke.run();
        vm.expectRevert("CollateralSmoke: withdrawal confirmation");
        smoke.withdraw();
    }

    function testSmokeRejectsWalletApprovalAndInsufficientBudgetBeforeFeedWrite() public {
        Smoke smoke = _readySmoke();
        uint80 round = d.usdFeed.roundId();
        vm.prank(OWNER);
        d.pUsdVault.approve(address(d.vault), 1);
        vm.expectRevert("CollateralSmoke: wallet budget/approval");
        smoke.run();
        vm.prank(OWNER);
        d.pUsdVault.approve(address(d.vault), 0);
        uint256 moved = d.pAvaxVault.balanceOf(OWNER) - 1;
        vm.prank(OWNER);
        d.pAvaxVault.transfer(address(0xBAD), moved);
        vm.expectRevert("CollateralSmoke: wallet budget/approval");
        smoke.run();
        assertEq(d.usdFeed.roundId(), round);
    }

    function testSmokeRejectsExistingDepositAndChangedPrice() public {
        Smoke smoke = _readySmoke();
        uint256 checkpoint = vm.snapshotState();
        vm.startPrank(OWNER);
        d.pUsdVault.approve(address(d.vault), 1);
        d.vault.deposit(address(d.pUsdVault), 1);
        d.pUsdVault.approve(address(d.vault), 0);
        vm.stopPrank();
        vm.expectRevert("CollateralFuji: nonempty vault");
        smoke.run();
        assertTrue(vm.revertToStateAndDelete(checkpoint));
        vm.prank(OWNER);
        d.avaxFeed.setAnswer(9e8);
        vm.expectRevert("CollateralFuji: mock prices");
        smoke.run();
        assertEq(d.avaxFeed.answer(), 9e8);
    }

    function testSmokeRejectsForeignOwnerReplayAndPrematureWithdrawal() public {
        Smoke smoke = _readySmoke();
        vm.setEnv("CP_FUJI_DEPLOYER", vm.toString(address(0xBAD)));
        vm.expectRevert("CollateralSmoke: identity");
        smoke.run();
        vm.setEnv("CP_FUJI_DEPLOYER", vm.toString(OWNER));
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_WITHDRAW", "true");
        vm.expectRevert("CollateralSmoke: unexpected history");
        smoke.withdraw();
        smoke.run();
        vm.expectRevert("CollateralFuji: accounts/wiring");
        smoke.run();
    }

    function testSmokeRejectsChangedFeePolicyBeforeFeedRefresh() public {
        Smoke smoke = _readySmoke();
        uint80 round = d.usdFeed.roundId();
        vm.startPrank(OWNER);
        d.config.queueFees(0, 0, 5000, 5000, 0);
        vm.warp(block.timestamp + 1 hours);
        d.config.setFees(0, 0, 5000, 5000, 0);
        vm.stopPrank();
        vm.expectRevert("CollateralFuji: activation fees");
        smoke.run();
        assertEq(d.usdFeed.roundId(), round);
    }

    function _readyContinuation() private returns (Smoke smoke) {
        smoke = _readySmoke();
        vm.startPrank(OWNER);
        d.pUsdVault.approve(address(d.vault), 3000e8);
        d.vault.deposit(address(d.pUsdVault), 3000e8);
        d.pUsdVault.approve(address(d.vault), 0);
        vm.stopPrank();
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_CONTINUATION", "true");
    }

    function testContinuationReusesUsdDepositWithoutWalletBudgetOrSecondDeposit() public {
        Smoke smoke = _readyContinuation();
        uint256 spareUsd = d.pUsdVault.balanceOf(OWNER);
        vm.prank(OWNER);
        d.pUsdVault.transfer(address(0xBAD), spareUsd);
        uint256 avaxBefore = d.pAvaxVault.balanceOf(OWNER);
        vm.recordLogs();
        smoke.continueFromUsdDeposit();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 deposits;
        uint256 fees;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(d.vault)
                    && logs[i].topics[0] == keccak256("Deposited(address,address,uint256)")
            ) {
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(d.pAvaxVault));
                assertEq(abi.decode(logs[i].data, (uint256)), 300e8);
                ++deposits;
            }
            if (
                logs[i].emitter == address(d.fees)
                    && logs[i].topics[0] == keccak256("FeeCollected(address,uint256,uint256,uint256,uint256)")
            ) ++fees;
        }
        assertEq(deposits, 1);
        assertEq(fees, 8);
        assertLe(d.pUsdVault.balanceOf(OWNER), 4); // Only possible treasury rounding dust, no deposit/withdrawal.
        assertGe(d.pAvaxVault.balanceOf(OWNER), avaxBefore - 300e8);
        assertLe(d.pAvaxVault.balanceOf(OWNER), avaxBefore - 300e8 + 4);
        smoke.verify(address(d.executor), OWNER);
        vm.expectRevert("CollateralFuji: accounts/wiring");
        smoke.continueFromUsdDeposit();
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_WITHDRAW", "true");
        smoke.withdraw();
    }

    function testContinuationAfterExpiredFirstOpenRefreshesDeadlineWithoutChangingLimits() public {
        Smoke smoke = _readyContinuation();
        Executor.OpenParams memory p;
        p.collateral = address(d.pUsdVault);
        p.collateralShares = 1250e8;
        p.leverageX100 = 200;
        p.maxFeeShares = 5e8;
        (, p.minPositionOut) = d.risk.quoteOpen(p.collateral, false, p.collateralShares, 200);
        p.deadline = vm.getBlockTimestamp() + 15 minutes;
        vm.warp(p.deadline + 1);
        vm.roll(block.number + 20);
        vm.expectRevert(Executor.InvalidOperation.selector);
        vm.prank(OWNER);
        d.executor.openPosition(p);
        assertEq(d.executor.nextPositionId(), 1);
        assertEq(d.vault.freeBalance(OWNER, p.collateral), 3000e8);
        assertEq(d.vault.lockedBalance(OWNER, p.collateral), 0);
        assertEq(d.pUsd.totalBorrows(), 0);
        // Even the original script must keep rejecting the existing deposit.
        vm.expectRevert("CollateralFuji: nonempty vault");
        smoke.run();
        vm.warp(block.timestamp + 2 days);
        smoke.continueFromUsdDeposit();
        smoke.verify(address(d.executor), OWNER);
    }

    function testContinuationRequiresExactOwnerBalanceAndCustody() public {
        Smoke smoke = _readyContinuation();
        uint80 round = d.usdFeed.roundId();
        uint256 checkpoint = vm.snapshotState();
        vm.prank(OWNER);
        d.vault.withdraw(address(d.pUsdVault), 1);
        vm.expectRevert("CollateralFuji: continuation checkpoint");
        smoke.continueFromUsdDeposit();
        assertTrue(vm.revertToStateAndDelete(checkpoint));
        checkpoint = vm.snapshotState();
        vm.prank(OWNER);
        d.pUsdVault.transfer(address(d.vault), 1); // Unaccounted custody donation is also unexpected.
        vm.expectRevert("CollateralFuji: continuation checkpoint");
        smoke.continueFromUsdDeposit();
        assertTrue(vm.revertToStateAndDelete(checkpoint));
        vm.startPrank(OWNER);
        d.vault.withdraw(address(d.pUsdVault), 3000e8);
        d.pUsdVault.transfer(address(0xBAD), 3000e8);
        vm.stopPrank();
        vm.startPrank(address(0xBAD));
        d.pUsdVault.approve(address(d.vault), 3000e8);
        d.vault.deposit(address(d.pUsdVault), 3000e8);
        vm.stopPrank();
        vm.expectRevert("CollateralFuji: continuation checkpoint");
        smoke.continueFromUsdDeposit();
        assertEq(d.usdFeed.roundId(), round);
    }

    function testContinuationRejectsWrongStageAndOutstandingApprovals() public {
        Smoke smoke = _readySmoke();
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_CONTINUATION", "true");
        vm.expectRevert("CollateralFuji: continuation checkpoint");
        smoke.continueFromUsdDeposit();
        vm.startPrank(OWNER);
        d.pUsdVault.approve(address(d.vault), 3000e8 + 1);
        d.vault.deposit(address(d.pUsdVault), 3000e8);
        vm.stopPrank();
        vm.expectRevert("CollateralFuji: continuation checkpoint");
        smoke.continueFromUsdDeposit();
        vm.startPrank(OWNER);
        d.pUsdVault.approve(address(d.vault), 0);
        d.pAvaxVault.approve(address(d.vault), 1);
        d.vault.deposit(address(d.pAvaxVault), 1);
        vm.stopPrank();
        vm.expectRevert("CollateralFuji: continuation checkpoint");
        smoke.continueFromUsdDeposit();
    }

    function testContinuationRejectsActivePositionBeforeRefresh() public {
        Smoke smoke = _readyContinuation();
        Executor.OpenParams memory p;
        p.collateral = address(d.pUsdVault);
        p.collateralShares = 1250e8;
        p.leverageX100 = 200;
        p.maxFeeShares = 5e8;
        p.deadline = block.timestamp;
        vm.prank(OWNER);
        d.executor.openPosition(p);
        uint80 round = d.usdFeed.roundId();
        vm.expectRevert("CollateralFuji: accounts/wiring");
        smoke.continueFromUsdDeposit();
        assertEq(d.usdFeed.roundId(), round);
    }

    function testContinuationRequiresAllConfirmationsAndFujiOwner() public {
        Smoke smoke = _readyContinuation();
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_CONTINUATION", "false");
        vm.expectRevert("CollateralSmoke: continuation confirmation");
        smoke.continueFromUsdDeposit();
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_CONTINUATION", "true");
        vm.chainId(43_114);
        vm.expectRevert("CollateralSmoke: Fuji only");
        smoke.continueFromUsdDeposit();
        vm.chainId(1);
        vm.expectRevert("CollateralSmoke: Fuji only");
        smoke.continueFromUsdDeposit();
        vm.chainId(43_113);
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_MOCK_ONLY", "false");
        vm.expectRevert("CollateralSmoke: mock confirmation");
        smoke.continueFromUsdDeposit();
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_MOCK_ONLY", "true");
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_SMOKE", "false");
        vm.expectRevert("CollateralSmoke: confirmation");
        smoke.continueFromUsdDeposit();
        vm.setEnv("CONFIRM_FUJI_COLLATERAL_SMOKE", "true");
        vm.setEnv("CP_FUJI_DEPLOYER", vm.toString(address(0xBAD)));
        vm.expectRevert("CollateralSmoke: identity");
        smoke.continueFromUsdDeposit();
    }

    function testContinuationRetainsPolicyChecksAndOptionalFreshness() public {
        Smoke smoke = _readyContinuation();
        Activate verifier = new Activate();
        vm.warp(block.timestamp + 2 days);
        verifier.verifySmokeContinuation(address(d.executor), OWNER, false);
        vm.expectRevert("CollateralFuji: fresh mock feeds required");
        verifier.verifySmokeContinuation(address(d.executor), OWNER, true);
        vm.startPrank(OWNER);
        d.config.queueFees(0, 0, 5000, 5000, 0);
        vm.warp(block.timestamp + 1 hours);
        d.config.setFees(0, 0, 5000, 5000, 0);
        vm.stopPrank();
        uint80 round = d.usdFeed.roundId();
        vm.expectRevert("CollateralFuji: activation fees");
        smoke.continueFromUsdDeposit();
        assertEq(d.usdFeed.roundId(), round);
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MockErc20} from "./MockErc20.sol";
import {PeridotTransparentProxy} from "../contracts/proxy/PeridotTransparentProxy.sol";
import {IsolatedMarginVaultUpgradeable} from "../contracts/margin/IsolatedMarginVaultUpgradeable.sol";
import {MarginFeeDistributorUpgradeable} from "../contracts/margin/MarginFeeDistributorUpgradeable.sol";

contract MarginFeeFuzzConfig {
    uint16 public constant depositorShareBps = 10_000;
    uint16 public constant insuranceShareBps = 0;
    uint16 public constant treasuryShareBps = 0;
    uint16 public feeImmediateShareBps = 2_000;
    uint32 public feeStreamDuration = 7 days;

    address public immutable insuranceFund;
    address public immutable treasury;

    constructor(address insuranceFund_, address treasury_) {
        insuranceFund = insuranceFund_;
        treasury = treasury_;
    }

    function setFeeDistribution(uint16 immediateShareBps_, uint32 streamDuration_) external {
        require(immediateShareBps_ >= 1_000 && immediateShareBps_ <= 2_000, "fuzz config: immediate share");
        require(streamDuration_ >= 1 days && streamDuration_ <= 30 days, "fuzz config: stream duration");
        feeImmediateShareBps = immediateShareBps_;
        feeStreamDuration = streamDuration_;
    }
}

contract MarginFeeLegacyConfig {
    uint16 public constant depositorShareBps = 10_000;
    uint16 public constant insuranceShareBps = 0;
    uint16 public constant treasuryShareBps = 0;

    address public immutable insuranceFund;
    address public immutable treasury;

    constructor(address insuranceFund_, address treasury_) {
        insuranceFund = insuranceFund_;
        treasury = treasury_;
    }
}

contract MarginFeeDistributorLegacyConfigTest is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant INSURANCE = address(0x1A5);
    address internal constant TREASURY = address(0x7EA5);

    function testDistributorUpgradeBeforeConfigUsesSafeFeeStreamDefaults() public {
        vm.warp(1_000_000);
        MockErc20 pToken = new MockErc20("Peridot Test Share", "pTEST", 18);
        MarginFeeLegacyConfig legacyConfig = new MarginFeeLegacyConfig(INSURANCE, TREASURY);
        MarginFeeDistributorUpgradeable distributor = MarginFeeDistributorUpgradeable(
            address(
                new PeridotTransparentProxy(
                    address(new MarginFeeDistributorUpgradeable()),
                    address(this),
                    abi.encodeCall(MarginFeeDistributorUpgradeable.initialize, (address(this), address(legacyConfig)))
                )
            )
        );
        distributor.setVault(address(this));
        distributor.setFeeCollector(address(this), true);
        distributor.updateShares(ALICE, address(pToken), 100e18);

        uint256 fee = 756e18;
        pToken.mint(address(this), fee);
        pToken.approve(address(distributor), fee);
        distributor.collectFee(address(pToken), address(this), fee);

        assertEq(distributor.pendingRewards(ALICE, address(pToken)), 151.2e18, "legacy immediate reward");
        vm.warp(block.timestamp + 7 days);
        assertEq(distributor.pendingRewards(ALICE, address(pToken)), fee, "legacy seven-day stream");
    }
}

abstract contract MarginFeeFuzzFixture is Test {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant IMMEDIATE_SHARE_BPS = 2_000;
    uint256 internal constant STREAM_DURATION = 7 days;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant INSURANCE = address(0x1A5);
    address internal constant TREASURY = address(0x7EA5);

    MockErc20 internal pToken;
    MarginFeeFuzzConfig internal config;
    MarginFeeDistributorUpgradeable internal distributor;
    IsolatedMarginVaultUpgradeable internal vault;

    function _setUpFeeSystem() internal {
        vm.warp(1_000_000);
        pToken = new MockErc20("Peridot Test Share", "pTEST", 18);
        config = new MarginFeeFuzzConfig(INSURANCE, TREASURY);

        distributor = MarginFeeDistributorUpgradeable(
            address(
                new PeridotTransparentProxy(
                    address(new MarginFeeDistributorUpgradeable()),
                    address(this),
                    abi.encodeCall(MarginFeeDistributorUpgradeable.initialize, (address(this), address(config)))
                )
            )
        );
        vault = IsolatedMarginVaultUpgradeable(
            address(
                new PeridotTransparentProxy(
                    address(new IsolatedMarginVaultUpgradeable()),
                    address(this),
                    abi.encodeCall(IsolatedMarginVaultUpgradeable.initialize, (address(this), address(distributor)))
                )
            )
        );

        distributor.setVault(address(vault));
        distributor.setFeeCollector(address(this), true);
        vault.setPTokenAllowed(address(pToken), true);
        pToken.approve(address(distributor), type(uint256).max);
    }

    function _deposit(address user, uint256 amount) internal {
        pToken.mint(user, amount);
        vm.startPrank(user);
        pToken.approve(address(vault), amount);
        vault.deposit(address(pToken), amount);
        vm.stopPrank();
    }

    function _collectFee(uint256 amount) internal {
        pToken.mint(address(this), amount);
        distributor.collectFee(address(pToken), address(this), amount);
    }

    function _rewardSchedule(uint256 fee, uint256 immediateShareBps, uint256 streamDuration)
        internal
        pure
        returns (uint256 immediateReward, uint256 rewardRate)
    {
        immediateReward = Math.mulDiv(fee, immediateShareBps, BPS);
        uint256 streamBudget = fee - immediateReward;
        rewardRate = streamBudget / streamDuration;
        immediateReward += streamBudget - rewardRate * streamDuration;
    }

    function _reserve() internal view returns (uint256 rewardReserve) {
        (,, rewardReserve,,,) = distributor.pools(address(pToken));
    }
}

contract MarginFeeDistributorFuzzTest is MarginFeeFuzzFixture {
    function setUp() public {
        _setUpFeeSystem();
    }

    function testFuzzLinearAccrualMatchesTheConfiguredStream(uint256 feeSeed, uint256 sharesSeed, uint256 elapsedSeed)
        public
    {
        uint256 fee = bound(feeSeed, 1, 1e30);
        uint256 shares = bound(sharesSeed, 1, 1e30);
        uint256 elapsed = bound(elapsedSeed, 0, STREAM_DURATION);
        _deposit(ALICE, shares);
        _collectFee(fee);
        uint256 streamStart = block.timestamp;

        (uint256 immediateReward, uint256 rewardRate) = _rewardSchedule(fee, IMMEDIATE_SHARE_BPS, STREAM_DURATION);
        vm.warp(streamStart + elapsed);
        uint256 expectedReward = immediateReward + rewardRate * elapsed;
        uint256 pending = distributor.pendingRewards(ALICE, address(pToken));

        assertApproxEqAbs(pending, expectedReward, 2, "linear stream deviated from schedule");
        assertLe(pending, fee, "pending reward exceeded collected fee");
        assertLe(pending, _reserve(), "pending reward exceeded reserve");
    }

    function testFuzzLateDepositCannotCapturePastRewards(
        uint256 feeSeed,
        uint256 aliceSharesSeed,
        uint256 bobSharesSeed,
        uint256 delaySeed
    ) public {
        uint256 fee = bound(feeSeed, 1, 1e30);
        uint256 aliceShares = bound(aliceSharesSeed, 1, 1e30);
        uint256 bobShares = bound(bobSharesSeed, 1, 1e30);
        uint256 joinDelay = bound(delaySeed, 1, STREAM_DURATION - 1);
        _deposit(ALICE, aliceShares);
        _collectFee(fee);
        uint256 streamStart = block.timestamp;

        vm.warp(streamStart + joinDelay);
        uint256 aliceBeforeJoin = distributor.pendingRewards(ALICE, address(pToken));
        _deposit(BOB, bobShares);

        assertEq(distributor.pendingRewards(BOB, address(pToken)), 0, "late depositor received past rewards");
        assertEq(
            distributor.pendingRewards(ALICE, address(pToken)), aliceBeforeJoin, "late deposit changed accrued rewards"
        );

        (, uint256 rewardRate) = _rewardSchedule(fee, IMMEDIATE_SHARE_BPS, STREAM_DURATION);
        uint256 remainingStream = rewardRate * (STREAM_DURATION - joinDelay);
        vm.warp(streamStart + STREAM_DURATION);
        uint256 alicePending = distributor.pendingRewards(ALICE, address(pToken));
        uint256 bobPending = distributor.pendingRewards(BOB, address(pToken));

        assertLe(bobPending, remainingStream, "late depositor captured pre-deposit rewards");
        assertLe(alicePending + bobPending, fee, "aggregate pending rewards exceeded fee");
    }

    function testFuzzOverlappingStreamsPreserveAllRewards(
        uint256 firstFeeSeed,
        uint256 secondFeeSeed,
        uint256 sharesSeed,
        uint256 delaySeed
    ) public {
        uint256 firstFee = bound(firstFeeSeed, 1, 1e30);
        uint256 secondFee = bound(secondFeeSeed, 1, 1e30);
        uint256 shares = bound(sharesSeed, 1, 1e30);
        uint256 delay = bound(delaySeed, 0, STREAM_DURATION);
        _deposit(ALICE, shares);
        _collectFee(firstFee);
        uint256 firstStreamStart = block.timestamp;

        vm.warp(firstStreamStart + delay);
        _collectFee(secondFee);
        uint256 secondStreamStart = block.timestamp;
        vm.warp(secondStreamStart + STREAM_DURATION);

        uint256 pending = distributor.pendingRewards(ALICE, address(pToken));
        assertApproxEqAbs(pending, firstFee + secondFee, 8, "stream rollover lost or created rewards");
        assertLe(pending, _reserve(), "rolled rewards exceeded reserve");
    }

    function testFuzzClaimsRemainSolventForChangingShareWeights(
        uint256 feeSeed,
        uint256 aliceSharesSeed,
        uint256 bobSharesSeed,
        uint256 elapsedSeed
    ) public {
        uint256 fee = bound(feeSeed, 1, 1e30);
        uint256 aliceShares = bound(aliceSharesSeed, 1, 1e30);
        uint256 bobShares = bound(bobSharesSeed, 1, 1e30);
        uint256 elapsed = bound(elapsedSeed, 0, STREAM_DURATION);
        _deposit(ALICE, aliceShares);
        _deposit(BOB, bobShares);
        _collectFee(fee);
        uint256 streamStart = block.timestamp;
        vm.warp(streamStart + elapsed);

        uint256 pendingBefore =
            distributor.pendingRewards(ALICE, address(pToken)) + distributor.pendingRewards(BOB, address(pToken));
        vm.prank(ALICE);
        uint256 aliceClaim = vault.settle(address(pToken));
        vm.prank(BOB);
        uint256 bobClaim = vault.settle(address(pToken));

        assertEq(aliceClaim + bobClaim, pendingBefore, "claim changed already-accrued rewards");
        assertEq(_reserve() + aliceClaim + bobClaim, fee, "claim reserve accounting is insolvent");
        assertEq(pToken.balanceOf(address(distributor)), _reserve(), "reserve is not token-backed");
    }

    function testFuzzAllowedFeeConfigurationsPreserveLinearAccrual(
        uint256 feeSeed,
        uint256 sharesSeed,
        uint256 immediateShareSeed,
        uint256 durationSeed,
        uint256 elapsedSeed
    ) public {
        uint256 fee = bound(feeSeed, 1, 1e30);
        uint256 shares = bound(sharesSeed, 1, 1e30);
        uint16 immediateShareBps = uint16(bound(immediateShareSeed, 1_000, 2_000));
        uint32 streamDuration = uint32(bound(durationSeed, 1 days, 30 days));
        uint256 elapsed = bound(elapsedSeed, 0, streamDuration);
        config.setFeeDistribution(immediateShareBps, streamDuration);
        _deposit(ALICE, shares);
        _collectFee(fee);
        uint256 streamStart = block.timestamp;

        (uint256 immediateReward, uint256 rewardRate) = _rewardSchedule(fee, immediateShareBps, streamDuration);
        vm.warp(streamStart + elapsed);
        uint256 pending = distributor.pendingRewards(ALICE, address(pToken));

        assertApproxEqAbs(
            pending, immediateReward + rewardRate * elapsed, 2, "configured stream deviated from schedule"
        );
        assertLe(pending, _reserve(), "configured stream is insolvent");
    }

    function testFuzzFeeWithoutEligibleSharesFallsBackToInsurance(uint256 feeSeed) public {
        uint256 fee = bound(feeSeed, 1, 1e30);
        _collectFee(fee);

        assertEq(pToken.balanceOf(INSURANCE), fee, "empty-pool fee did not reach insurance");
        assertEq(_reserve(), 0, "empty pool retained a depositor reserve");
        assertEq(pToken.balanceOf(address(distributor)), 0, "empty pool stranded fee tokens");
    }
}

contract MarginFeeStatefulHandler is Test {
    uint256 internal constant MAX_ACTION_AMOUNT = 1e24;
    uint256 internal constant MAX_WARP = 30 days;

    MockErc20 public immutable pToken;
    MarginFeeFuzzConfig public immutable config;
    MarginFeeDistributorUpgradeable public immutable distributor;
    IsolatedMarginVaultUpgradeable public immutable vault;

    uint256 public totalFeeMinted;
    uint256 public totalDepositMinted;
    uint256 public totalClaimed;

    constructor(
        MockErc20 pToken_,
        MarginFeeFuzzConfig config_,
        MarginFeeDistributorUpgradeable distributor_,
        IsolatedMarginVaultUpgradeable vault_
    ) {
        pToken = pToken_;
        config = config_;
        distributor = distributor_;
        vault = vault_;
        pToken.approve(address(distributor), type(uint256).max);
    }

    function deposit(uint256 userSeed, uint256 amountSeed) external {
        address user = userAt(userSeed);
        uint256 amount = bound(amountSeed, 1, MAX_ACTION_AMOUNT);
        pToken.mint(user, amount);
        totalDepositMinted += amount;
        uint256 reserveBefore = reserve();

        vm.startPrank(user);
        pToken.approve(address(vault), amount);
        vault.deposit(address(pToken), amount);
        vm.stopPrank();
        _recordClaim(reserveBefore);
    }

    function withdraw(uint256 userSeed, uint256 amountSeed) external {
        address user = userAt(userSeed);
        uint256 free = vault.freeBalance(user, address(pToken));
        if (free == 0) return;
        uint256 amount = bound(amountSeed, 1, free);
        uint256 reserveBefore = reserve();

        vm.prank(user);
        vault.withdraw(address(pToken), amount);
        _recordClaim(reserveBefore);
    }

    function collectFee(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, MAX_ACTION_AMOUNT);
        pToken.mint(address(this), amount);
        totalFeeMinted += amount;
        distributor.collectFee(address(pToken), address(this), amount);
    }

    function settle(uint256 userSeed) external {
        uint256 reserveBefore = reserve();
        vm.prank(userAt(userSeed));
        vault.settle(address(pToken));
        _recordClaim(reserveBefore);
    }

    function warpTime(uint256 elapsedSeed) external {
        vm.warp(block.timestamp + bound(elapsedSeed, 0, MAX_WARP));
    }

    function configureFeeDistribution(uint256 immediateShareSeed, uint256 durationSeed) external {
        uint16 immediateShareBps = uint16(bound(immediateShareSeed, 1_000, 2_000));
        uint32 streamDuration = uint32(bound(durationSeed, 1 days, 30 days));
        config.setFeeDistribution(immediateShareBps, streamDuration);
    }

    function userAt(uint256 seed) public pure returns (address) {
        uint256 index = seed % 4;
        if (index == 0) return address(0xA11CE);
        if (index == 1) return address(0xB0B);
        if (index == 2) return address(0xCA201);
        return address(0xDAD);
    }

    function reserve() public view returns (uint256 rewardReserve) {
        (,, rewardReserve,,,) = distributor.pools(address(pToken));
    }

    function _recordClaim(uint256 reserveBefore) internal {
        uint256 reserveAfter = reserve();
        if (reserveAfter < reserveBefore) totalClaimed += reserveBefore - reserveAfter;
    }
}

contract MarginFeeDistributorInvariantTest is MarginFeeFuzzFixture {
    MarginFeeStatefulHandler internal handler;

    function setUp() public {
        _setUpFeeSystem();
        handler = new MarginFeeStatefulHandler(pToken, config, distributor, vault);
        distributor.setFeeCollector(address(handler), true);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.collectFee.selector;
        selectors[3] = handler.settle.selector;
        selectors[4] = handler.warpTime.selector;
        selectors[5] = handler.configureFeeDistribution.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariantFeeRewardsAreSolventAndConserved() public view {
        uint256 reserve = handler.reserve();
        assertEq(pToken.balanceOf(address(distributor)), reserve, "distributor reserve is not token-backed");
        assertEq(
            reserve + pToken.balanceOf(INSURANCE) + handler.totalClaimed(),
            handler.totalFeeMinted(),
            "fee rewards were created or lost"
        );
    }

    function invariantAllMintedTokensRemainAccountedFor() public view {
        uint256 accounted = pToken.balanceOf(address(handler)) + pToken.balanceOf(address(distributor))
            + pToken.balanceOf(address(vault)) + pToken.balanceOf(INSURANCE) + pToken.balanceOf(TREASURY);
        for (uint256 i; i < 4; ++i) {
            accounted += pToken.balanceOf(handler.userAt(i));
        }

        assertEq(accounted, pToken.totalSupply(), "pToken balance conservation failed");
        assertEq(
            pToken.totalSupply(),
            handler.totalFeeMinted() + handler.totalDepositMinted(),
            "unexpected pToken mint or burn"
        );
    }

    function invariantVaultSharesAndDistributorSharesStaySynchronized() public view {
        (, uint256 poolShares,,,,) = distributor.pools(address(pToken));
        uint256 summedShares;
        for (uint256 i; i < 4; ++i) {
            address user = handler.userAt(i);
            uint256 eligible = vault.freeBalance(user, address(pToken)) + vault.lockedBalance(user, address(pToken));
            (uint256 recordedShares,,) = distributor.userRewards(address(pToken), user);
            assertEq(recordedShares, eligible, "user share checkpoint diverged from vault");
            summedShares += eligible;
        }

        assertEq(poolShares, summedShares, "pool shares diverged from users");
        assertEq(vault.totalFreeBalance(address(pToken)), pToken.balanceOf(address(vault)), "vault lost coverage");
    }

    function invariantAggregatePendingRewardsNeverExceedReserve() public view {
        uint256 pending;
        for (uint256 i; i < 4; ++i) {
            pending += distributor.pendingRewards(handler.userAt(i), address(pToken));
        }
        assertLe(pending, handler.reserve(), "pending rewards exceed reserve");
    }

    function invariantRemainingStreamIsFullyReserved() public view {
        (, uint256 totalShares, uint256 reserve, uint256 rewardRate, uint256 lastUpdate, uint256 periodFinish) =
            distributor.pools(address(pToken));
        uint256 remainingStream;
        if (totalShares == 0 && lastUpdate < periodFinish) {
            remainingStream = (periodFinish - lastUpdate) * rewardRate;
        } else if (totalShares > 0 && block.timestamp < periodFinish) {
            remainingStream = (periodFinish - block.timestamp) * rewardRate;
        }

        assertLe(remainingStream, reserve, "unvested stream exceeds reserve");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SmokeFujiMockFiveX} from "../script/SmokeFujiMockFiveX.s.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {FujiMockPriceFeed} from "../contracts/margin/testing/FujiMockAssets.sol";
import {FujiMockSwapAdapter} from "../contracts/margin/testing/FujiMockSwapAdapter.sol";
import {IsolatedMarginConfigUpgradeable} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginTypes} from "../contracts/margin/IsolatedMarginTypes.sol";
import {IsolatedMarginExecutorUpgradeable} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";

/// @dev TEST ONLY: changes mock prices in the local VM, never part of the operator script.
contract FiveXBoundaryHarness is SmokeFujiMockFiveX {
    function _checkEntry(address account, bool short) internal override {
        super._checkEntry(account, short);
        vm.stopBroadcast();
        uint256 lo = short ? 10e8 : 1e8;
        uint256 hi = short ? 30e8 : 10e8;
        vm.startPrank(OWNER);
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            AF.setAnswer(int256(mid));
            if (RISK.isLiquidatable(account) == short) hi = mid;
            else lo = mid;
        }
        AF.setAnswer(int256(short ? lo : hi));
        require(!RISK.isLiquidatable(account), "boundary safe side");
        AF.setAnswer(int256(short ? hi : lo));
        require(RISK.isLiquidatable(account), "boundary liquidation side");
        uint256 boundary = short ? hi : lo;
        uint256 distance = short ? (boundary - 10e8) * 10_000 / 10e8 : (10e8 - boundary) * 10_000 / 10e8;
        require(distance >= 1100, "actual boundary too close");
        AF.setAnswer(10e8);
        vm.stopPrank();
        vm.startBroadcast(OWNER);
    }
}

/// @notice Pinned LOCAL fork of the actual deployed 5x stack, no code substitution or upgrades.
contract FujiMockFiveXSmokeForkTest is Test {
    address constant OWNER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    PErc20 constant USD = PErc20(0x81BF2032e98C8F35F2336e1A68baA01B5B2030E4);
    PErc20 constant AVAX = PErc20(0x577AC6Ca3Df06D7702740A6A8c136F868f9f0195);
    FujiMockPriceFeed constant AF = FujiMockPriceFeed(0x515a87601C4515e8B42f69645E77B56110d1a9A4);
    IsolatedMarginConfigUpgradeable constant CONFIG =
        IsolatedMarginConfigUpgradeable(0x6148183676E304dbe63a85C350c208DA3cEAc39C);
    IsolatedMarginExecutorUpgradeable constant EX =
        IsolatedMarginExecutorUpgradeable(0xa155ccCB986774AE818b3F10F07d01D1b7A47b26);
    SmokeFujiMockFiveX smoke;

    function setUp() public {
        string memory rpc = vm.envOr("FUJI_MOCK_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 58_509_947);
        smoke = new SmokeFujiMockFiveX();
        vm.setEnv("CONFIRM_FUJI_MOCK_ONLY", "true");
        vm.setEnv("CONFIRM_FUJI_FIVE_X_SMOKE", "true");
    }

    function testActualScriptClosesBothSidesWithoutWalletTransfersOrDebt() public {
        uint256 before = USD.balanceOf(OWNER);
        smoke.run();
        _closed();
        assertEq(USD.balanceOf(OWNER), before);
        assertEq(USD.allowance(OWNER, address(EX.vault())), 0);
        vm.expectRevert("FiveX: inspect history before replay");
        smoke.run();
    }

    function testActualEngineLiquidationBoundariesBothSides() public {
        new FiveXBoundaryHarness().run();
        _closed();
    }

    function testHalfPercentEntryAndExitLossExceedsSmokeBudget() public {
        vm.prank(OWNER);
        FujiMockSwapAdapter(0xEF3F12c9D60bc86484dac6250BCC25d784Ba200B).setExecutionBps(9950);
        FiveXBoundaryHarness harness = new FiveXBoundaryHarness();
        // The two leveraged round trips exceed 1% of the $200 free-collateral budget.
        // Simulation must reject that plan; this is NOT an atomicity guarantee for live broadcasts.
        vm.expectRevert("FiveX: excessive loss");
        harness.run();
        assertEq(EX.nextPositionId(), 5);
        assertEq(USD.totalBorrows(), 0);
        assertEq(AVAX.totalBorrows(), 0);
    }

    function testStaleFeedsRefreshedByScript() public {
        vm.warp(block.timestamp + 2 days);
        smoke.run();
        _closed();
        assertEq(AF.updatedAt(), block.timestamp);
    }

    function testRejectsMainnet() public {
        vm.chainId(43_114);
        vm.expectRevert("FiveX: Fuji only");
        smoke.run();
    }

    function testRejectsMissingMockConfirmation() public {
        vm.setEnv("CONFIRM_FUJI_MOCK_ONLY", "false");
        vm.expectRevert("FiveX: mock confirmation");
        smoke.run();
        vm.setEnv("CONFIRM_FUJI_MOCK_ONLY", "true");
    }

    function testRejectsMissingTradeConfirmation() public {
        vm.setEnv("CONFIRM_FUJI_FIVE_X_SMOKE", "false");
        vm.expectRevert("FiveX: trade confirmation");
        smoke.run();
        vm.setEnv("CONFIRM_FUJI_FIVE_X_SMOKE", "true");
    }

    function testRejectsChangedPricesBeforeRefreshing() public {
        vm.prank(OWNER);
        AF.setAnswer(11e8);
        vm.expectRevert("FiveX: prices changed");
        smoke.run();
        assertEq(AF.answer(), 11e8);
    }

    function testRejectsPausedOpens() public {
        vm.prank(OWNER);
        CONFIG.pauseOpens();
        vm.expectRevert("FiveX: opens paused");
        smoke.run();
    }

    function testRejectsChangedCollateral() public {
        vm.startPrank(OWNER);
        EX.vault().withdraw(address(USD), 1);
        vm.stopPrank();
        vm.expectRevert("FiveX: collateral changed");
        smoke.run();
    }

    function testRejectsChangedRisk() public {
        IsolatedMarginTypes.PairRiskConfig memory r = CONFIG.getPairRisk(address(USD), address(AVAX), address(USD));
        r.maintenanceMarginBps = 1900;
        vm.startPrank(OWNER);
        CONFIG.queuePairRisk(address(USD), address(AVAX), address(USD), r);
        vm.warp(block.timestamp + CONFIG.actionDelay());
        CONFIG.setPairRisk(address(USD), address(AVAX), address(USD), r);
        vm.stopPrank();
        vm.expectRevert("FiveX: risk changed");
        smoke.run();
    }

    function _closed() private view {
        assertEq(EX.nextPositionId(), 7);
        assertEq(USD.totalBorrows(), 0);
        assertEq(AVAX.totalBorrows(), 0);
        assertEq(USD.totalBorrowShares(), 0);
        assertEq(AVAX.totalBorrowShares(), 0);
        assertEq(EX.vault().lockedBalance(OWNER, address(USD)), 0);
        for (uint256 id = 5; id <= 6; ++id) {
            (,, address account,,,,,,,,, IsolatedMarginTypes.Status status) = EX.positions(id);
            assertEq(uint256(status), uint256(IsolatedMarginTypes.Status.CLOSED));
            assertEq(USD.borrowBalanceStored(account), 0);
            assertEq(AVAX.borrowBalanceStored(account), 0);
        }
    }
}

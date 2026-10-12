// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ExerciseFujiMarginRunner as Exercise} from "../script/ExerciseFujiMarginRunner.s.sol";
import {PrepareFujiMarginRunner as Prepare} from "../script/PrepareFujiMarginRunner.s.sol";

/// @notice Isolated LOCAL fork only. Never uses a signing key or public broadcasts.
contract FujiMarginRunnerForkTest is Test {
    Exercise exercise;
    Prepare prepare;

    function setUp() public {
        string memory rpc = vm.envOr("CP_FUJI_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        bool selected;
        try vm.activeFork() returns (uint256) {
            selected = true;
        } catch {}
        if (!selected) vm.createSelectFork(rpc, 59_336_291);
        assertEq(block.chainid, 43_113);
        assertEq(block.number, 59_336_291);
        exercise = new Exercise();
        prepare = new Prepare();
        vm.setEnv("CONFIRM_FUJI_RUNNER_PREPARATION", "true");
        vm.setEnv("CONFIRM_FUJI_RUNNER_ROUNDTRIPS", "true");
    }

    function testPreparationAndAllTwelveSequentialRoundTrips() public {
        address owner = exercise.OWNER();
        address runner = exercise.RUNNER();
        address usd = exercise.USD_COLLATERAL();
        address avax = exercise.AVAX_COLLATERAL();
        uint256 usdBefore = IERC20(usd).balanceOf(owner);
        uint256 avaxBefore = IERC20(avax).balanceOf(owner);
        prepare.run();
        assertEq(IERC20(usd).balanceOf(owner), usdBefore - 3000e8);
        assertEq(IERC20(avax).balanceOf(owner), avaxBefore - 300e8);
        assertEq(IERC20(usd).balanceOf(runner), 3000e8);
        assertEq(IERC20(avax).balanceOf(runner), 300e8);
        uint256 timestamp = exercise.USD_FEED().updatedAt();
        exercise.run();
        exercise.verify();
        assertEq(exercise.USD_FEED().updatedAt(), timestamp);
        assertEq(exercise.USD_FEED().owner(), owner);
        assertEq(exercise.AVAX_FEED().owner(), owner);
        assertEq(exercise.E().nextPositionId(), 17);
        vm.expectRevert("FujiRunner: history");
        exercise.run();
    }

    function testRejectsWrongChain() public {
        vm.chainId(43_114);
        vm.expectRevert("FujiRunner: Fuji only");
        exercise.run();
        vm.expectRevert("FujiPrepare: Fuji only");
        prepare.run();
    }

    function testRejectsMissingConfirmation() public {
        vm.setEnv("CONFIRM_FUJI_RUNNER_PREPARATION", "false");
        vm.expectRevert("FujiPrepare: confirmation");
        prepare.run();
        vm.setEnv("CONFIRM_FUJI_RUNNER_ROUNDTRIPS", "false");
        vm.expectRevert("FujiRunner: confirmation");
        exercise.run();
        vm.setEnv("CONFIRM_FUJI_RUNNER_PREPARATION", "true");
        vm.setEnv("CONFIRM_FUJI_RUNNER_ROUNDTRIPS", "true");
    }

    function testRejectsDuplicatePreparation() public {
        prepare.run();
        vm.expectRevert("FujiPrepare: already funded");
        prepare.run();
    }

    function testRejectsOldPricesAndUnfundedRunner() public {
        vm.startPrank(exercise.OWNER());
        exercise.USD_FEED().setAnswer(1e8);
        exercise.AVAX_FEED().setAnswer(10e8);
        vm.stopPrank();
        vm.expectRevert("FujiRunner: exact funding/checkpoint");
        exercise.check();
        prepare.run();
        vm.warp(block.timestamp + 301);
        vm.expectRevert("FujiRunner: refresh owner feeds");
        exercise.check();
    }
}

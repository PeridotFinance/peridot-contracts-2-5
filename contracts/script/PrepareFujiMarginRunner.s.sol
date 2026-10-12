// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ExerciseFujiMarginRunner as Exercise} from "./ExerciseFujiMarginRunner.s.sol";

/// @notice Four separately approved OWNER calls. No admin delegation or new minting.
contract PrepareFujiMarginRunner is Script {
    function run() external {
        require(block.chainid == 43_113, "FujiPrepare: Fuji only");
        require(vm.envOr("CONFIRM_FUJI_RUNNER_PREPARATION", false), "FujiPrepare: confirmation");
        Exercise exercise = new Exercise(); // before startBroadcast: never deployed on chain
        address runner = exercise.RUNNER();
        address owner = exercise.OWNER();
        address usd = exercise.USD_COLLATERAL();
        address avax = exercise.AVAX_COLLATERAL();
        require(exercise.E().nextPositionId() == 5, "FujiPrepare: history");
        require(
            IERC20(usd).balanceOf(runner) == 0 && IERC20(avax).balanceOf(runner) == 0, "FujiPrepare: already funded"
        );
        require(exercise.USD_FEED().answer() == 1e8 && exercise.AVAX_FEED().answer() == 10e8, "FujiPrepare: prices");
        vm.startBroadcast(owner);
        require(IERC20(usd).transfer(runner, 3000e8), "FujiPrepare: USD transfer");
        require(IERC20(avax).transfer(runner, 300e8), "FujiPrepare: AVAX transfer");
        exercise.USD_FEED().setAnswer(1e8);
        exercise.AVAX_FEED().setAnswer(10e8);
        vm.stopBroadcast();
        exercise.check();
    }
}

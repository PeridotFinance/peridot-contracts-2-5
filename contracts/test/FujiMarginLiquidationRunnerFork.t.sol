// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LiquidateFujiMarginRunner as Operator} from "../script/LiquidateFujiMarginRunner.s.sol";

/// @notice LOCAL VM only, starting after all twelve actual runner round trips.
contract FujiMarginLiquidationRunnerForkTest is Test {
    Operator op;

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
        if (!selected) vm.createSelectFork(rpc, 59_499_119);
        assertEq(block.chainid, 43_113);
        assertEq(block.number, 59_499_119);
        op = new Operator();
        assertEq(op.E().nextPositionId(), 17);
        vm.setEnv("CONFIRM_FUJI_RUNNER_LIQUIDATION", "true");
    }

    function testEightSequentialLiquidationsUseExistingMarginAndRestorePrices() public {
        address usd = op.USD_COLLATERAL();
        address avax = op.AVAX_COLLATERAL();
        address runner = op.RUNNER();
        uint256 usdBefore = op.E().vault().freeBalance(runner, usd);
        uint256 avaxBefore = op.E().vault().freeBalance(runner, avax);
        for (uint8 scenario; scenario < 8; ++scenario) {
            op.runScenario(scenario);
            assertEq(op.USD_FEED().answer(), 1e8);
            assertEq(op.AVAX_FEED().answer(), 10e8);
            assertEq(op.USD_FEED().owner(), op.OWNER());
            assertEq(op.AVAX_FEED().owner(), op.OWNER());
            assertEq(op.E().nextPositionId(), 18 + scenario);
        }
        // No deposits/withdrawals; original gas-only wallet's pToken balance stays zero.
        assertEq(IERC20(usd).balanceOf(runner), 0);
        assertEq(IERC20(avax).balanceOf(runner), 0);
        uint256 usdAfter = op.E().vault().freeBalance(runner, usd);
        uint256 avaxAfter = op.E().vault().freeBalance(runner, avax);
        assertGt(usdAfter, 0);
        assertGt(avaxAfter, 0);
        assertLt(usdAfter, usdBefore);
        assertLt(avaxAfter, avaxBefore);
        console2.log("Remaining free USD / AVAX raw shares", usdAfter, avaxAfter);
        vm.expectRevert("FujiLiq: history/replay");
        op.runScenario(0);
    }

    function testRejectsWrongChainConfirmationAndScenario() public {
        vm.chainId(43_114);
        vm.expectRevert("FujiLiq: Fuji only");
        op.runScenario(0);
        vm.chainId(43_113);
        vm.setEnv("CONFIRM_FUJI_RUNNER_LIQUIDATION", "false");
        vm.expectRevert("FujiLiq: confirmation");
        op.runScenario(0);
        vm.setEnv("CONFIRM_FUJI_RUNNER_LIQUIDATION", "true");
        vm.expectRevert("FujiLiq: scenario");
        op.runScenario(8);
        vm.expectRevert("FujiLiq: history/replay");
        op.runScenario(1);
    }

    function testRejectsChangedPricesWithoutSilentlyResettingThem() public {
        vm.startPrank(op.OWNER());
        op.AVAX_FEED().setAnswer(9e8);
        vm.stopPrank();
        vm.expectRevert("FujiLiq: baseline prices");
        op.runScenario(0);
        assertEq(op.AVAX_FEED().answer(), 9e8);
    }

    function testRejectsChangedFeedOwner() public {
        vm.startPrank(op.OWNER());
        op.USD_FEED().transferOwnership(address(0xBAD));
        vm.stopPrank();
        vm.expectRevert("FujiLiq: feed owners");
        op.runScenario(0);
    }

    function testRejectsExistingDepositApproval() public {
        vm.startPrank(op.RUNNER());
        IERC20(op.USD_COLLATERAL()).approve(address(op.E().vault()), 1);
        vm.stopPrank();
        vm.expectRevert("FujiLiq: approval");
        op.runScenario(0);
    }

    function testRejectsInsufficientExistingMarginWithoutDepositing() public {
        address token = op.USD_COLLATERAL();
        uint256 free = op.E().vault().freeBalance(op.RUNNER(), token);
        vm.startPrank(op.RUNNER());
        op.E().vault().withdraw(token, free);
        vm.stopPrank();
        vm.expectRevert("FujiLiq: insufficient existing margin");
        op.runScenario(0);
    }

    function testPartialCaseImprovesHealthWithoutInsuranceAndCannotBeReplayed() public {
        op.runScenario(0); // operator asserts exact healthy rejection, partial debt/HF and zero insurance
        vm.expectRevert("FujiLiq: history/replay");
        op.runScenario(0);
        op.runScenario(1);
    }

    function testRejectsInsufficientInsuranceBeforeFullScenario() public {
        op.runScenario(0);
        op.runScenario(1);
        address insurance = op.E().config().insuranceFund();
        address asset = op.E().settlement().usd();
        vm.mockCall(asset, abi.encodeCall(IERC20.balanceOf, (insurance)), abi.encode(uint256(0)));
        vm.expectRevert("FujiLiq: insurance cash");
        op.runScenario(2);
        assertEq(op.E().nextPositionId(), 19);
        assertEq(op.AVAX_FEED().answer(), 10e8);
    }

    function testRejectsChangedFeePolicyBeforeAnyFeedUpdate() public {
        address config = address(op.E().config());
        vm.mockCall(config, abi.encodeWithSignature("openFeeBps()"), abi.encode(uint16(20)));
        uint256 previous = op.USD_FEED().updatedAt();
        vm.expectRevert("FujiLiq: policy");
        op.runScenario(0);
        assertEq(op.USD_FEED().updatedAt(), previous);
    }
}

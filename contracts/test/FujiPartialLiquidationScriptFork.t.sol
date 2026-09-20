// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SmokeFujiMockPartialLiquidation} from "../script/SmokeFujiMockPartialLiquidation.s.sol";
import {FujiMockPriceFeed} from "../contracts/margin/testing/FujiMockAssets.sol";
import {IsolatedMarginExecutorUpgradeable as Executor} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";

contract FujiPartialLiquidationScriptForkTest is Test {
    address constant OWNER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    SmokeFujiMockPartialLiquidation script;

    function setUp() public {
        string memory rpc = vm.envOr("FUJI_MOCK_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 58_511_100);
        vm.setEnv("CONFIRM_FUJI_MOCK_ONLY", "true");
        vm.setEnv("CONFIRM_FUJI_PARTIAL_LIQUIDATION", "true");
        script = new SmokeFujiMockPartialLiquidation();
    }

    function testLifecycleRestoresPriceClosesAndRejectsReplay() public {
        script.run();
        assertEq(Executor(0xa155ccCB986774AE818b3F10F07d01D1b7A47b26).nextPositionId(), 8);
        assertEq(FujiMockPriceFeed(0x515a87601C4515e8B42f69645E77B56110d1a9A4).answer(), 10e8);
        vm.expectRevert("PartialSmoke: inspect history");
        script.run();
    }

    function testRejectsWrongChain() public {
        vm.chainId(43_114);
        vm.expectRevert("PartialSmoke: Fuji only");
        script.run();
    }

    function testRejectsMissingConfirmation() public {
        vm.setEnv("CONFIRM_FUJI_PARTIAL_LIQUIDATION", "false");
        vm.expectRevert("PartialSmoke: liquidation confirmation");
        script.run();
        vm.setEnv("CONFIRM_FUJI_PARTIAL_LIQUIDATION", "true");
    }

    function testRejectsMissingMockConfirmation() public {
        vm.setEnv("CONFIRM_FUJI_MOCK_ONLY", "false");
        vm.expectRevert("PartialSmoke: mock confirmation");
        script.run();
        vm.setEnv("CONFIRM_FUJI_MOCK_ONLY", "true");
    }

    function testRejectsUnexpectedPrice() public {
        vm.prank(OWNER);
        FujiMockPriceFeed(0x515a87601C4515e8B42f69645E77B56110d1a9A4).setAnswer(11e8);
        vm.expectRevert("PartialSmoke: scenario");
        script.run();
    }
}

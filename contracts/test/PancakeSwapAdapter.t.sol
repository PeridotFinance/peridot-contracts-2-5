// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PancakeSwapAdapter} from "../contracts/DualInvestment/PancakeSwapAdapter.sol";

contract DummyRouter {}
contract DummyQuoter {}

contract PancakeSwapAdapterTest is Test {
    PancakeSwapAdapter internal adapter;
    DummyRouter internal v2;
    DummyRouter internal v3;
    DummyQuoter internal quoter;

    function setUp() public {
        v2 = new DummyRouter();
        v3 = new DummyRouter();
        quoter = new DummyQuoter();
        adapter = new PancakeSwapAdapter(address(v2), address(v3), address(quoter));
    }

    function testConstructorRejectsZeroAddress() public {
        vm.expectRevert("router zero");
        new PancakeSwapAdapter(address(0), address(v3), address(quoter));
    }

    function testConstructorRejectsEOA() public {
        vm.expectRevert("router not contract");
        new PancakeSwapAdapter(address(0x1234), address(v3), address(quoter));
    }

    function testSetRoutersRequiresQueue() public {
        DummyRouter nextV2 = new DummyRouter();
        DummyRouter nextV3 = new DummyRouter();
        DummyQuoter nextQuoter = new DummyQuoter();

        vm.expectRevert("action not queued");
        adapter.setRouters(address(nextV2), address(nextV3), address(nextQuoter));
    }

    function testQueuedRoutersUpdate() public {
        DummyRouter nextV2 = new DummyRouter();
        DummyRouter nextV3 = new DummyRouter();
        DummyQuoter nextQuoter = new DummyQuoter();

        adapter.queueSetRouters(address(nextV2), address(nextV3), address(nextQuoter));
        vm.warp(block.timestamp + adapter.actionDelay());

        adapter.setRouters(address(nextV2), address(nextV3), address(nextQuoter));
        assertEq(adapter.v2Router(), address(nextV2));
        assertEq(adapter.v3Router(), address(nextV3));
        assertEq(adapter.v3Quoter(), address(nextQuoter));
    }

    function testSetRoutersRejectsEOA() public {
        adapter.queueSetRouters(address(0x1234), address(v3), address(quoter));
        vm.warp(block.timestamp + adapter.actionDelay());

        vm.expectRevert("router not contract");
        adapter.setRouters(address(0x1234), address(v3), address(quoter));
    }
}

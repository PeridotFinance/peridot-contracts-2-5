// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {WhitelistRouterAdapter} from "../contracts/margin/WhitelistRouterAdapter.sol";
import {MockErc20} from "./MockErc20.sol";

contract ResidualSwapTarget {
    function consumeWithResidual(
        address tokenIn,
        address tokenOut,
        uint256 spendAmount,
        uint256 outputAmount,
        address recipient
    ) external {
        MockErc20(tokenIn).transferFrom(msg.sender, address(this), spendAmount);
        MockErc20(tokenOut).transfer(recipient, outputAmount);
    }
}

contract WhitelistRouterAdapterTest is Test {
    WhitelistRouterAdapter public adapter;
    MockErc20 public tokenIn;
    MockErc20 public tokenOut;
    ResidualSwapTarget public target;
    uint256 public actionDelay;

    function setUp() public {
        target = new ResidualSwapTarget();
        actionDelay = 1 days;
        adapter = new WhitelistRouterAdapter(address(this), actionDelay);

        adapter.queueSetManager(address(this));
        adapter.queueSetTargetWhitelist(address(target), true, false);
        vm.warp(block.timestamp + actionDelay);
        adapter.setManager(address(this));
        adapter.setTargetWhitelist(address(target), true, false);

        tokenIn = new MockErc20("TokenIn", "TIN", 18);
        tokenOut = new MockErc20("TokenOut", "TOUT", 18);

        tokenOut.mint(address(target), 1_000e18);
        tokenIn.mint(address(this), 100e18);
    }

    function testSwapReturnsResidualTokenIn() public {
        uint256 amountIn = 60e18;
        uint256 spendAmount = 40e18;
        uint256 outputAmount = 20e18;

        tokenIn.approve(address(adapter), amountIn);

        bytes memory callData = abi.encodeWithSignature(
            "consumeWithResidual(address,address,uint256,uint256,address)",
            address(tokenIn),
            address(tokenOut),
            spendAmount,
            outputAmount,
            address(this)
        );

        bytes memory data = abi.encode(address(target), callData);

        uint256 balanceInBefore = tokenIn.balanceOf(address(this));
        uint256 balanceOutBefore = tokenOut.balanceOf(address(this));

        uint256 amountOut =
            adapter.swap(address(this), address(tokenIn), address(tokenOut), amountIn, outputAmount, data);

        assertEq(amountOut, outputAmount, "amount out");
        assertEq(tokenOut.balanceOf(address(this)), balanceOutBefore + outputAmount, "received output tokens");
        assertEq(tokenIn.balanceOf(address(this)), balanceInBefore - spendAmount, "only spent intended amount");
        assertEq(tokenIn.balanceOf(address(adapter)), 0, "adapter returned residual");
    }
}

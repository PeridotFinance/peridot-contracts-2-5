// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PeridotSpoke} from "../contracts/PeridotSpoke.sol";
import {PeridotHubHandler} from "../contracts/PeridotHubHandler.sol";
import {MockAxelarGateway} from "./MockAxelarGateway.sol";
import {MockErc20} from "../contracts/MockErc20.sol";
import {PErc20CrossChain} from "../contracts/PErc20CrossChain.sol";
import {MockPeridottroller} from "./MockPeridottroller.sol";
import {MockInterestRateModel} from "./MockInterestRateModel.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract CrossChainLendingTest is Test {
    // Mock contracts
    MockAxelarGateway mockGateway;
    MockErc20 token;
    MockPeridottroller peridottroller;
    MockInterestRateModel interestRateModel;

    // Contracts to test
    PeridotSpoke spoke;
    PeridotHubHandler hubHandler;
    PErc20CrossChain pToken;

    // Users
    address alice;
    uint256 constant alicePrivateKey = 0x12345;

    function setUp() public {
        alice = vm.addr(alicePrivateKey);

        // Deploy mocks
        mockGateway = new MockAxelarGateway();
        token = new MockErc20("Mock Token", "MTK", 18);
        peridottroller = new MockPeridottroller();
        interestRateModel = new MockInterestRateModel();

        // Deploy contracts (PeridotHubHandler constructor takes gateway and gasService)
        hubHandler = new PeridotHubHandler(
            address(mockGateway),
            address(mockGateway) // Using mockGateway for gasService too
        );
        pToken = new PErc20CrossChain(address(hubHandler)); // Pass hub handler address

        string memory hubHandlerStr = Strings.toHexString(uint256(uint160(address(hubHandler))), 20);

        spoke = new PeridotSpoke();
        spoke.initialize(address(mockGateway), address(mockGateway), "Ethereum", hubHandlerStr, address(this));

        // Initialize pToken
        pToken.initialize(address(token), peridottroller, interestRateModel, 1e18, "Peridot Mock Token", "pMTK", 18);

        // Link contracts
        mockGateway.setHubHandler(payable(address(hubHandler)));
        hubHandler.setPToken(address(token), address(pToken));
        // New safeguards: allowlist pToken and set Axelar symbol mapping for underlying
        hubHandler.setAllowedPToken(address(pToken), true);
        hubHandler.setUnderlyingAxelarSymbol(address(token), "MTK");

        // Authorize the spoke contract on the hub
        hubHandler.setSpokeContract("Ethereum", Strings.toHexString(uint256(uint160(address(spoke))), 20));

        // Register token with mock Axelar gateway
        mockGateway.setTokenAddress("MTK", address(token));

        // Mint tokens and provide ether to alice
        vm.deal(alice, 100 ether);
        token.mint(alice, 1_000_000e18);
    }

    function testSupply() public {
        uint256 amount = 100e18;

        // 1. User approves the spoke contract to spend their tokens
        vm.startPrank(alice);
        token.approve(address(spoke), amount);

        // 2. User initiates the supply operation on the spoke contract
        // No signature or complex UserAction is needed anymore.
        spoke.supplyToPeridot{value: 1 ether}("MTK", amount);

        vm.stopPrank();

        // Assert that the user's pToken balance on the hub has increased.
        // The mock gateway simulates the cross-chain call and minting.
        assertEq(pToken.balanceOf(alice), amount);
    }

    function testBorrow() public {
        // First, supply collateral to be able to borrow
        testSupply();

        uint256 borrowAmount = 50e18;
        uint256 balanceAfterSupply = token.balanceOf(alice);

        // In the new architecture, the user doesn't need to sign a message for borrowing.
        // They just call the spoke contract directly.
        vm.startPrank(alice);
        spoke.borrowFromPeridot{value: 1 ether}(address(pToken), borrowAmount);
        vm.stopPrank();

        // Assert that the user's token balance on the spoke chain has increased by the borrow amount.
        // The mock gateway simulates the borrow on the hub and the token transfer back to the spoke.
        uint256 finalBalance = token.balanceOf(alice);
        assertEq(finalBalance, balanceAfterSupply + borrowAmount);
    }
}

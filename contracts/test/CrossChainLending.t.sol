// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PeridotSpoke} from "../contracts/PeridotSpoke.sol";
import {PeridotHubHandler} from "../contracts/PeridotHubHandler.sol";
import {PeridotForwarder} from "../contracts/PeridotForwarder.sol";
import {PeridotSpokeReceiver} from "../contracts/PeridotSpokeReceiver.sol";
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
    PeridotForwarder forwarder;
    PeridotSpokeReceiver spokeReceiver;
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

        // Deploy contracts
        forwarder = new PeridotForwarder();
        hubHandler = new PeridotHubHandler(address(mockGateway), address(mockGateway), address(forwarder));
        string memory hubHandlerStr = Strings.toHexString(uint256(uint160(address(hubHandler))), 20);
        spoke = new PeridotSpoke(address(mockGateway), "Ethereum", hubHandlerStr);
        spokeReceiver = new PeridotSpokeReceiver(address(mockGateway));
        pToken = new PErc20CrossChain();
        pToken.initialize(address(token), peridottroller, interestRateModel, 1e18, "Peridot Mock Token", "pMTK", 18);

        // Link contracts
        mockGateway.setHubHandler(payable(address(hubHandler)));
        hubHandler.setPToken(address(token), address(pToken));
        pToken._setForwarder(address(forwarder));
        spoke.setPToken(address(pToken));


        // Mint tokens and provide ether to alice
        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        token.mint(alice, 1_000_000e18);
        vm.stopPrank();
    }

    function testSupply() public {
        uint256 amount = 100e18;

        // 1. User approves the gateway to spend their tokens
        vm.prank(alice);
        token.approve(address(mockGateway), amount);

        // 2. User initiates the supply operation on the spoke contract
        PeridotForwarder.UserAction memory userAction = PeridotForwarder.UserAction({
            user: alice,
            asset: address(token), // The asset being supplied on the spoke chain is the underlying
            amount: amount,
            nonce: 0,
            deadline: 0
        });

        bytes32 digest = forwarder.getTypedDataHash(userAction);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // The spoke contract is the one sending the cross-chain message, with a gas fee
        vm.prank(alice);
        spoke.supplyToPeridot{value: 1 ether}(userAction.user, userAction.asset, userAction.amount, userAction.nonce, userAction.deadline, signature);

        // Assert that the user's pToken balance on the hub has increased
        assertEq(pToken.balanceOf(alice), amount);
    }

    function testBorrow() public {
        // First, supply collateral to be able to borrow
        testSupply();

        // No approval is needed for borrow on the spoke chain

        uint256 borrowAmount = 50e18; // Borrow 50 tokens
        uint256 balanceAfterSupply = token.balanceOf(alice);
        
        // Debug: Check balance after supply
        // Should be 999,900 tokens (1,000,000 - 100)
        assertEq(balanceAfterSupply, 999900e18);

        // In testBorrow, we must use a new nonce (1) because testSupply used nonce 0.
        uint256 borrowNonce = 1;

        PeridotForwarder.UserAction memory userAction = PeridotForwarder.UserAction({
            user: alice,
            asset: address(pToken), // Borrow is against the pToken asset
            amount: borrowAmount,
            nonce: borrowNonce,
            deadline: block.timestamp
        });

        bytes32 digest = forwarder.getTypedDataHash(userAction);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // The user calls the spoke contract to initiate the borrow
        vm.prank(alice);
        spoke.borrowFromPeridot{value: 1 ether}(userAction.user, userAction.asset, userAction.amount, userAction.nonce, userAction.deadline, signature);

        // Assert that the user's token balance on the spoke chain has increased by the borrow amount
        uint256 finalBalance = token.balanceOf(alice);
        assertEq(finalBalance, balanceAfterSupply + borrowAmount);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import {PToken} from "../contracts/PToken.sol";
import {PTokenInterface, IERC3156FlashBorrower, IERC3156FlashLender} from "../contracts/PTokenInterfaces.sol";
import {MockErc20} from "../contracts/MockErc20.sol";
import {MockPeridottroller} from "./MockPeridottroller.sol";
import {MockInterestRateModel} from "./MockInterestRateModel.sol";

// Minimal concrete PToken for testing
contract TestPToken is PToken {
    address internal _underlying;

    constructor(address underlying_) {
        _underlying = underlying_;
        admin = payable(msg.sender);
    }

    function getUnderlyingAddress() internal view override returns (address) {
        return _underlying;
    }

    function getCashPrior() internal view override returns (uint256) {
        return MockErc20(_underlying).balanceOf(address(this));
    }

    function doTransferIn(
        address from,
        uint256 amount
    ) internal override returns (uint256) {
        uint256 balBefore = MockErc20(_underlying).balanceOf(address(this));
        bool ok = MockErc20(_underlying).transferFrom(
            from,
            address(this),
            amount
        );
        require(ok, "transferFrom failed");
        uint256 balAfter = MockErc20(_underlying).balanceOf(address(this));
        return balAfter - balBefore;
    }

    function doTransferOut(
        address payable to,
        uint256 amount
    ) internal override {
        bool ok = MockErc20(_underlying).transfer(to, amount);
        require(ok, "transfer failed");
    }
}

// Simple borrower that repays principal + fee in callback
contract TestFlashBorrower is IERC3156FlashBorrower {
    bytes32 private constant CALLBACK_SUCCESS =
        keccak256("ERC3156FlashBorrower.onFlashLoan");

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        // Use funds according to test case, then repay lender (msg.sender)
        // For tests we just send the funds back immediately
        // Ensure we have enough to cover fee
        require(
            MockErc20(token).balanceOf(address(this)) >= amount + fee,
            "insufficient for fee"
        );
        MockErc20(token).transfer(msg.sender, amount + fee);
        return CALLBACK_SUCCESS;
    }
}

contract FlashLoanTest is Test {
    MockErc20 internal underlying;
    MockPeridottroller internal controller;
    MockInterestRateModel internal irm;
    TestPToken internal pToken;
    TestFlashBorrower internal borrower;

    function setUp() public {
        underlying = new MockErc20("Mock", "MOCK", 18);
        controller = new MockPeridottroller();
        irm = new MockInterestRateModel();

        pToken = new TestPToken(address(underlying));
        // Initialize market
        pToken.initialize(controller, irm, 1e18, "pMOCK", "pMOCK", 18);

        // Provide liquidity to pToken
        deal(address(underlying), address(pToken), 1_000_000 ether);

        // Deploy borrower and pre-fund with some tokens to pay fees
        borrower = new TestFlashBorrower();
        deal(address(underlying), address(borrower), 10 ether);
    }

    function test_flashLoan_success() public {
        // Borrow a fixed modest amount so the fee is comfortably covered by the borrower's prefunding
        uint256 amount = 1_000 ether;

        // Execute flash loan
        bool ok = IERC3156FlashLender(address(pToken)).flashLoan(
            IERC3156FlashBorrower(address(borrower)),
            address(underlying),
            amount,
            bytes("")
        );
        assertTrue(ok);
        // Fee added to reserves
        uint256 fee = (amount * pToken.flashLoanFeeBps()) / 10000;
        assertEq(pToken.totalReserves(), fee);
    }

    function test_flashLoan_paused_reverts() public {
        // Pause loans as admin (the test contract is the admin set in constructor)
        pToken._setFlashLoansPaused(true);
        uint256 amount = 1 ether;
        vm.expectRevert(bytes("FlashLoan: flash loans are paused"));
        IERC3156FlashLender(address(pToken)).flashLoan(
            IERC3156FlashBorrower(address(borrower)),
            address(underlying),
            amount,
            bytes("")
        );
    }

    function test_flashLoan_exceeds_max_reverts() public {
        uint256 cash = underlying.balanceOf(address(pToken));
        uint256 maxLoan = (cash * pToken.maxFlashLoanRatio()) / 10000;
        uint256 amount = maxLoan + 1;
        vm.expectRevert(bytes("FlashLoan: amount exceeds maximum"));
        IERC3156FlashLender(address(pToken)).flashLoan(
            IERC3156FlashBorrower(address(borrower)),
            address(underlying),
            amount,
            bytes("")
        );
    }

    function test_flashLoan_wrong_token_reverts() public {
        MockErc20 other = new MockErc20("Other", "OTH", 18);
        vm.expectRevert(bytes("FlashLoan: token not supported"));
        IERC3156FlashLender(address(pToken)).flashLoan(
            IERC3156FlashBorrower(address(borrower)),
            address(other),
            1 ether,
            bytes("")
        );
    }
}

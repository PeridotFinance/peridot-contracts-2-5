// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {SmartMarginAccount} from "../contracts/margin/SmartMarginAccount.sol";
import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";
import {MockErc20} from "./MockErc20.sol";

contract MockCToken {
    address public underlying;

    constructor(address underlying_) {
        underlying = underlying_;
    }

    function mint(uint256) external pure returns (uint256) {
        return 0;
    }

    function repayBorrow(uint256) external pure returns (uint256) {
        return 0;
    }
}

contract SmartMarginAccountTest is Test {
    function testEnterMarketRevertsOnNonZeroErrorCode() public {
        SmartMarginAccount sma = new SmartMarginAccount();

        address comptroller = address(0xBEEF);
        address cToken = address(0xCAFE);
        sma.initialize(address(this), address(this), comptroller);

        address[] memory markets = new address[](1);
        markets[0] = cToken;

        uint256[] memory codes = new uint256[](1);
        codes[0] = 1;

        vm.mockCall(
            comptroller,
            abi.encodeWithSelector(PeridottrollerInterface.enterMarkets.selector, markets),
            abi.encode(codes)
        );

        vm.expectRevert("SMA: enter market failed");
        sma.enterMarket(cToken);
    }

    function testInitializeRequiresFactory() public {
        SmartMarginAccount sma = new SmartMarginAccount();
        address comptroller = address(0xBEEF);

        vm.prank(address(0x1234));
        vm.expectRevert("SMA: caller must be factory");
        sma.initialize(address(0x1234), address(0x9999), comptroller);
    }

    function testEmergencyWithdrawChecksEnteredMarkets() public {
        SmartMarginAccount sma = new SmartMarginAccount();
        address comptroller = address(0xBEEF);
        address cToken = address(0xCAFE);
        sma.initialize(address(this), address(this), comptroller);

        address[] memory markets = new address[](1);
        markets[0] = cToken;
        uint256[] memory codes = new uint256[](1);
        codes[0] = 0;
        vm.mockCall(
            comptroller,
            abi.encodeWithSelector(PeridottrollerInterface.enterMarkets.selector, markets),
            abi.encode(codes)
        );

        sma.enterMarket(cToken);

        vm.mockCall(
            cToken,
            abi.encodeWithSignature("borrowBalanceStored(address)", address(sma)),
            abi.encode(uint256(1))
        );

        vm.expectRevert("SMA: must repay borrows first");
        sma.ownerEmergencyWithdraw(address(0xDEAD), 1);
    }

    function testEmergencyWithdrawSkipsExitedMarkets() public {
        SmartMarginAccount sma = new SmartMarginAccount();
        address comptroller = address(0xBEEF);
        address cToken = address(0xCAFE);
        sma.initialize(address(this), address(this), comptroller);

        address[] memory markets = new address[](1);
        markets[0] = cToken;
        uint256[] memory codes = new uint256[](1);
        codes[0] = 0;
        vm.mockCall(
            comptroller,
            abi.encodeWithSelector(PeridottrollerInterface.enterMarkets.selector, markets),
            abi.encode(codes)
        );
        vm.mockCall(
            comptroller,
            abi.encodeWithSelector(PeridottrollerInterface.exitMarket.selector, cToken),
            abi.encode(uint256(0))
        );

        sma.enterMarket(cToken);
        sma.exitMarket(cToken);

        vm.mockCallRevert(
            cToken,
            abi.encodeWithSignature("borrowBalanceStored(address)", address(sma)),
            "unexpected"
        );

        MockErc20 token = new MockErc20("Mock", "MOCK", 18);
        token.mint(address(sma), 10e18);

        sma.ownerEmergencyWithdraw(address(token), 5e18);
        assertEq(token.balanceOf(address(this)), 5e18);
    }

    function testMintAndRepayResetAllowance() public {
        MockErc20 underlying = new MockErc20("Mock", "MOCK", 18);
        MockCToken cToken = new MockCToken(address(underlying));

        SmartMarginAccount sma = new SmartMarginAccount();
        sma.initialize(address(this), address(this), address(0xBEEF));

        underlying.mint(address(sma), 100e18);

        sma.mint(address(cToken), 10e18);
        assertEq(underlying.allowance(address(sma), address(cToken)), 0);

        sma.repayBorrow(address(cToken), 5e18);
        assertEq(underlying.allowance(address(sma), address(cToken)), 0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {SmartMarginAccount} from "../contracts/margin/SmartMarginAccount.sol";
import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";

contract SmartMarginAccountTest is Test {
    function testEnterMarketRevertsOnNonZeroErrorCode() public {
        SmartMarginAccount sma = new SmartMarginAccount();
        sma.initialize(address(this), address(this));

        address comptroller = address(0xBEEF);
        address cToken = address(0xCAFE);

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
        sma.enterMarket(comptroller, cToken);
    }
}

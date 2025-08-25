// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../contracts/PriceOracle.sol";
import "../contracts/PToken.sol";

contract MockOracle is PriceOracle {
    function getUnderlyingPrice(PToken pToken) public view override returns (uint256) {
        // Return a fixed price for all tokens for simplicity
        return 1e18;
    }
}

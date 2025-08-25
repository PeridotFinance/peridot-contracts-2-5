// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {InterestRateModel} from "../contracts/InterestRateModel.sol";

contract MockInterestRateModel is InterestRateModel {
    function getBorrowRate(uint256 cash, uint256 borrows, uint256 reserves) external view override returns (uint256) {
        return 0;
    }

    function getSupplyRate(uint256 cash, uint256 borrows, uint256 reserves, uint256 reserveFactorMantissa)
        external
        view
        override
        returns (uint256)
    {
        return 0;
    }
}

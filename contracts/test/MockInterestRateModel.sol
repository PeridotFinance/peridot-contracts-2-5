// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {InterestRateModel} from "../contracts/InterestRateModel.sol";

contract MockInterestRateModel is InterestRateModel {
    function getBorrowRate(uint cash, uint borrows, uint reserves) external view override returns (uint) {
        return 0;
    }

    function getSupplyRate(uint cash, uint borrows, uint reserves, uint reserveFactorMantissa) external view override returns (uint) {
        return 0;
    }
}

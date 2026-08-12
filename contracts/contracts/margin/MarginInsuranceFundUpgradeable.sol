// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MarginInsuranceFundUpgradeable is Initializable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    address public liquidator;

    event LiquidatorConfigured(address indexed liquidator);
    event CoverageProvided(address indexed pToken, address indexed recipient, uint256 amount);
    event TokenRecovered(address indexed token, address indexed recipient, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        require(owner_ != address(0), "InsuranceFund: zero owner");
        __Ownable_init(owner_);
    }

    function setLiquidator(address liquidator_) external onlyOwner {
        require(liquidator_.code.length > 0, "InsuranceFund: invalid liquidator");
        liquidator = liquidator_;
        emit LiquidatorConfigured(liquidator_);
    }

    function provideCoverage(address pToken, address recipient, uint256 amount) external returns (uint256 provided) {
        require(msg.sender == liquidator, "InsuranceFund: not liquidator");
        require(recipient != address(0), "InsuranceFund: zero recipient");
        uint256 balance = IERC20(pToken).balanceOf(address(this));
        provided = amount < balance ? amount : balance;
        if (provided > 0) IERC20(pToken).safeTransfer(recipient, provided);
        emit CoverageProvided(pToken, recipient, provided);
    }

    function recoverUnsupportedToken(address token, address recipient, uint256 amount) external onlyOwner {
        require(recipient != address(0), "InsuranceFund: zero recipient");
        IERC20(token).safeTransfer(recipient, amount);
        emit TokenRecovered(token, recipient, amount);
    }

    uint256[40] private __gap;
}

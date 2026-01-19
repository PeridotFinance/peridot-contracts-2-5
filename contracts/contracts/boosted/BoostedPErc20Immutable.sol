// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import "../PeridottrollerInterface.sol";
import "../InterestRateModel.sol";
import "../interfaces/IBoostedYieldAdapter.sol";
import "./BoostedPErc20.sol";

/**
 * @title Peridot's Boosted PErc20 Immutable
 * @notice Convenience wrapper that wires a boosted market during construction.
 * @dev SECURITY: Admin address is immutable after construction. Ensure it's correct!
 */
contract BoostedPErc20Immutable is BoostedPErc20 {
    constructor(
        address underlying_,
        PeridottrollerInterface peridottroller_,
        InterestRateModel interestRateModel_,
        uint256 initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address payable admin_,
        IBoostedYieldAdapter adapter_,
        uint256 liquidityBufferMantissa_
    ) {
        // Validate admin address to prevent permanent lock-out
        require(admin_ != address(0), "BoostedPErc20Immutable: zero admin");
        
        // The deployer is the temporary admin for initialization
        admin = payable(msg.sender);

        initialize(
            underlying_, peridottroller_, interestRateModel_, initialExchangeRateMantissa_, name_, symbol_, decimals_
        );

        if (address(adapter_) != address(0)) {
            setBoostAdapter(adapter_);
        }

        if (liquidityBufferMantissa_ != liquidityBufferMantissa) {
            setLiquidityBufferMantissa(liquidityBufferMantissa_);
        }

        // Hand over admin privileges to the designated admin address
        // This is final and cannot be changed (immutable contract)
        admin = admin_;
    }
}

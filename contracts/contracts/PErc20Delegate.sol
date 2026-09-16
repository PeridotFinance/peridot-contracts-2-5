// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./PErc20.sol";

/**
 * @title Peridot's PErc20Delegate Contract
 * @notice PTokens which wrap an EIP-20 underlying and are delegated to
 * @author Peridot
 */
contract PErc20Delegate is PErc20, CDelegateInterface {
    /**
     * @notice Construct an empty delegate
     */
    constructor() {}

    /**
     * @notice Called by the delegator on a delegate to initialize it for duty
     * @param data The encoded bytes data for any initialization
     */
    function _becomeImplementation(bytes memory data) public virtual override {
        // Shh -- we don't ever want this hook to be marked pure
        if (false) {
            implementation = address(0);
        }

        require(msg.sender == admin, "only the admin may call _becomeImplementation");
        // Plain lending markets can upgrade and migrate atomically. Empty data preserves the
        // historical upgrade hook; boosted delegates retain their own separately reviewed hooks.
        if (data.length != 0) {
            (address[] memory borrowers, uint256 expectedTotal, uint256 maxAdjustment) =
                abi.decode(data, (address[], uint256, uint256));
            activateBorrowAccounting(borrowers, expectedTotal, maxAdjustment);
        }
    }

    /**
     * @notice Called by the delegator on a delegate to forfeit its responsibility
     */
    function _resignImplementation() public virtual override {
        // Shh -- we don't ever want this hook to be marked pure
        if (false) {
            implementation = address(0);
        }

        require(msg.sender == admin, "only the admin may call _resignImplementation");
    }
}

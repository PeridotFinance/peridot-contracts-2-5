// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal hand-made interface of the Pharaoh `DLMMFactory` 0xEb480050b016f6c6d45203D2346B68bDDDa23D4D (Routescan verified).
interface IDLMMFactory {
    struct LBPairInformation {
        uint16 binStep;
        address LBPair;
        bool createdByOwner;
        bool ignoredForRouting;
    }

    /// token order does not matter (the factory sorts); returns LBPair == address(0) when no such pair exists
    function getLBPairInformation(address tokenA, address tokenB, uint256 binStep)
        external
        view
        returns (LBPairInformation memory);
}

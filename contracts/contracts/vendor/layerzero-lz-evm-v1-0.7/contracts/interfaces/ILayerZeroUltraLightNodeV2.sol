// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @notice Minimal interface required by LayerZero's Foundry test harness mocks.
 * @dev This is included only to satisfy compilation of `@layerzerolabs/test-devtools-evm-foundry`.
 */
interface ILayerZeroUltraLightNodeV2 {
    function withdrawNative(address payable _to, uint256 _amount) external;

    function updateHash(bytes32 _hash) external;
}


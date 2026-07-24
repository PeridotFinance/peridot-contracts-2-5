// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

/**
 * @notice Minimal interface used by the Robinhood-backed USDG pToken.
 */
interface IRobinhoodBoostedVault {
    function depositForPair(bytes32 pairId, address token, uint256 amount) external returns (uint256 received);

    function withdrawForSide(bytes32 pairId, address token, uint256 requested, address receiver, uint256 deadline)
        external
        returns (uint256 returned, uint256 realizedLoss);

    function accountedAssets(bytes32 pairId, address token) external view returns (uint256);

    function liquidAssets(bytes32 pairId, address token) external view returns (uint256);

    function sideAccount(bytes32 pairId, address token) external view returns (address);
}

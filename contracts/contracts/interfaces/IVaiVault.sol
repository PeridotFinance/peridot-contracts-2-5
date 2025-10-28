// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

/**
 * @notice Minimal interface for the Venus VAI Vault used by the boosted adapter.
 * @dev The vault accepts VAI deposits, tracks balances in `userInfo`, and allows instant withdrawals.
 */
interface IVaiVault {
    function deposit(uint256 amount) external;

    function withdraw(uint256 amount) external;

    function userInfo(address account) external view returns (uint256 amount, uint256 rewardDebt);

    function vaultPaused() external view returns (bool);
}

// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

/**
 * @notice Interface for a yield adapter that can deploy and withdraw an underlying asset instantly.
 */
interface IBoostedYieldAdapter {
    /// @notice Returns the ERC20 underlying asset managed by the adapter.
    function underlying() external view returns (address);

    /**
     * @notice Returns the total amount of underlying that can be withdrawn immediately for the owner.
     * @dev Must be net of instant-redemption fees and slippage. Implementations may include
     *      deployed and idle assets only when both are immediately available to `withdraw`.
     */
    function totalUnderlying() external view returns (uint256);

    /**
     * @notice Deploys `amount` of underlying owned by the caller into the yield strategy.
     * @return deposited The amount of underlying actually deployed.
     */
    function deposit(uint256 amount) external returns (uint256 deposited);

    /**
     * @notice Withdraws `amount` of underlying to `recipient`.
     * @return withdrawn The amount of underlying sent to the recipient.
     */
    function withdraw(address recipient, uint256 amount) external returns (uint256 withdrawn);

    /**
     * @notice Withdraws all available underlying to `recipient`.
     * @return withdrawn The amount of underlying sent to the recipient.
     */
    function withdrawAll(address recipient) external returns (uint256 withdrawn);
}

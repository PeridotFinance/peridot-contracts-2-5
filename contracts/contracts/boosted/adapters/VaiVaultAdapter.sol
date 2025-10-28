// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {IBoostedYieldAdapter} from "../../interfaces/IBoostedYieldAdapter.sol";
import {IVaiVault} from "../../interfaces/IVaiVault.sol";
import {IERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title VaiVaultAdapter
 * @notice Adapter that stakes idle VAI into the Venus VAI vault and supports instant withdrawals.
 */
contract VaiVaultAdapter is IBoostedYieldAdapter {
    using SafeERC20 for IERC20;

    /// @notice Boosted pToken allowed to interact with this adapter.
    address public immutable owner;

    /// @notice VAI ERC20 token managed by the adapter.
    address public immutable override underlying;

    /// @notice Venus VAI vault contract.
    IVaiVault public immutable vault;

    error NotOwner();
    error VaultPaused();
    error NothingStaked();
    error WithdrawalTooLarge();
    error DepositSlippage(uint256 expected, uint256 actual);
    error WithdrawalSlippage(uint256 expected, uint256 actual);

    event Deposited(uint256 amount);
    event Withdrawn(address indexed recipient, uint256 amount);
    event WithdrawnAll(address indexed recipient, uint256 amount);

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        _;
    }

    constructor(address owner_, address underlying_, address vault_) {
        require(owner_ != address(0), "VaiVaultAdapter: owner zero");
        require(underlying_ != address(0), "VaiVaultAdapter: underlying zero");
        require(vault_ != address(0), "VaiVaultAdapter: vault zero");

        owner = owner_;
        underlying = underlying_;
        vault = IVaiVault(vault_);

        // Pre-approve the vault for maximal allowance to avoid repeated approvals.
        IERC20 token = IERC20(underlying_);
        token.forceApprove(vault_, type(uint256).max);
    }

    /**
     * @notice Returns the total VAI managed by this adapter (staked balance in the vault).
     */
    function totalUnderlying() external view override returns (uint256) {
        (uint256 amount,) = vault.userInfo(address(this));
        return amount;
    }

    /**
     * @notice Stakes VAI from the owner into the vault.
     * @dev Assumes the owner granted sufficient allowance to this adapter.
     */
    function deposit(uint256 amount) external override onlyOwner returns (uint256 deposited) {
        if (amount == 0) {
            return 0;
        }
        if (vault.vaultPaused()) {
            revert VaultPaused();
        }

        IERC20 token = IERC20(underlying);

        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(owner, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - balanceBefore;

        uint256 stakedBefore = _stakedBalance();
        vault.deposit(received);
        uint256 stakedAfter = _stakedBalance();

        if (stakedAfter < stakedBefore + received) {
            revert DepositSlippage(stakedBefore + received, stakedAfter);
        }

        emit Deposited(received);
        return received;
    }

    /**
     * @notice Withdraws VAI from the vault and transfers it to `recipient`.
     */
    function withdraw(address recipient, uint256 amount) external override onlyOwner returns (uint256 withdrawn) {
        if (amount == 0) {
            return 0;
        }

        uint256 staked = _stakedBalance();
        if (staked == 0) {
            revert NothingStaked();
        }
        if (amount > staked) {
            revert WithdrawalTooLarge();
        }

        IERC20 token = IERC20(underlying);
        uint256 balanceBefore = token.balanceOf(address(this));

        vault.withdraw(amount);

        uint256 received = token.balanceOf(address(this)) - balanceBefore;
        if (received < amount) {
            revert WithdrawalSlippage(amount, received);
        }

        token.safeTransfer(recipient, received);
        emit Withdrawn(recipient, received);
        return received;
    }

    /**
     * @notice Withdraws the full staked balance to `recipient`.
     */
    function withdrawAll(address recipient) external override onlyOwner returns (uint256 withdrawn) {
        uint256 staked = _stakedBalance();
        if (staked == 0) {
            return 0;
        }

        IERC20 token = IERC20(underlying);
        uint256 balanceBefore = token.balanceOf(address(this));

        vault.withdraw(staked);
        uint256 received = token.balanceOf(address(this)) - balanceBefore;

        token.safeTransfer(recipient, received);
        emit WithdrawnAll(recipient, received);
        return received;
    }

    function _stakedBalance() internal view returns (uint256 amount) {
        (amount,) = vault.userInfo(address(this));
    }
}

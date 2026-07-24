// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {IBoostedYieldAdapter} from "../../interfaces/IBoostedYieldAdapter.sol";
import {IUpshift} from "../../interfaces/IUpshift.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title UpshiftAdapter
 * @notice Adapter that deposits idle liquidity into an Upshift Vault and supports instant withdrawals.
 */
contract UpshiftAdapter is IBoostedYieldAdapter {
    using SafeERC20 for IERC20;

    /// @notice Boosted pToken allowed to interact with this adapter.
    address public immutable override owner;

    /// @notice Underlying ERC20 token managed by the adapter.
    address public immutable override underlying;

    /// @notice Upshift Vault contract.
    IUpshift public immutable vault;

    uint256 private constant FEE_DENOMINATOR = 1e18;

    error NotOwner();
    error NotEnoughFunds();
    error InvalidRecipient();
    error BalanceMismatch();

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        _;
    }

    constructor(address owner_, address underlying_, address vault_) {
        require(owner_ != address(0), "UpshiftAdapter: owner zero");
        require(underlying_ != address(0), "UpshiftAdapter: underlying zero");
        require(vault_ != address(0), "UpshiftAdapter: vault zero");

        owner = owner_;
        underlying = underlying_;
        vault = IUpshift(vault_);
    }

    /**
     * @notice Returns the underlying amount immediately withdrawable after the instant fee.
     */
    function totalUnderlying() external view override returns (uint256) {
        uint256 idleAssets = IERC20(underlying).balanceOf(address(this));
        uint256 shares = vault.balanceOf(address(this));
        uint256 grossAssets = vault.convertToAssets(shares);
        uint256 fee = vault.instantRedemptionFee();
        if (fee >= FEE_DENOMINATOR) {
            return idleAssets;
        }
        return idleAssets + Math.mulDiv(grossAssets, FEE_DENOMINATOR - fee, FEE_DENOMINATOR);
    }

    /**
     * @notice Deposits underlying from the owner into the vault.
     */
    function deposit(uint256 amount) external override onlyOwner returns (uint256) {
        if (amount == 0) {
            return 0;
        }

        IERC20 token = IERC20(underlying);

        // Pull tokens from owner
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(owner, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - balanceBefore;

        // Deposit into Upshift
        token.forceApprove(address(vault), received);
        vault.deposit(received, address(this));
        token.forceApprove(address(vault), 0);

        return received;
    }

    /**
     * @notice Withdraws underlying from the vault via instant redemption.
     * @dev Accounts for instant redemption fee to ensure `amount` is received.
     */
    function withdraw(address recipient, uint256 amount) external override onlyOwner returns (uint256) {
        if (amount == 0) {
            return 0;
        }
        if (recipient == address(0)) {
            revert InvalidRecipient();
        }

        IERC20 token = IERC20(underlying);
        uint256 idleAssets = token.balanceOf(address(this));
        if (idleAssets < amount) {
            uint256 amountFromVault = amount - idleAssets;
            uint256 fee = vault.instantRedemptionFee();
            if (fee >= FEE_DENOMINATOR) {
                revert NotEnoughFunds();
            }

            uint256 grossAssets =
                Math.mulDiv(amountFromVault, FEE_DENOMINATOR, FEE_DENOMINATOR - fee, Math.Rounding.Ceil);
            uint256 shares = vault.convertToShares(grossAssets);
            if (vault.convertToAssets(shares) < grossAssets) {
                if (shares == type(uint256).max) {
                    revert NotEnoughFunds();
                }
                shares += 1;
            }

            uint256 ownedShares = vault.balanceOf(address(this));
            if (shares == 0 || shares > ownedShares) {
                revert NotEnoughFunds();
            }

            uint256 balanceBefore = token.balanceOf(address(this));
            uint256 reportedReceived = vault.instantRedeem(shares, address(this), address(this));
            uint256 balanceAfter = token.balanceOf(address(this));
            if (
                balanceAfter < balanceBefore || balanceAfter - balanceBefore != reportedReceived
                    || balanceAfter < amount
            ) {
                revert NotEnoughFunds();
            }
        }

        uint256 recipientBefore = token.balanceOf(recipient);
        token.safeTransfer(recipient, amount);
        uint256 recipientAfter = token.balanceOf(recipient);
        if (recipientAfter < recipientBefore || recipientAfter - recipientBefore != amount) {
            revert BalanceMismatch();
        }
        return amount;
    }

    /**
     * @notice Withdraws all assets via instant redemption.
     */
    function withdrawAll(address recipient) external override onlyOwner returns (uint256) {
        if (recipient == address(0)) {
            revert InvalidRecipient();
        }

        IERC20 token = IERC20(underlying);
        uint256 shares = vault.balanceOf(address(this));
        if (shares != 0) {
            uint256 balanceBefore = token.balanceOf(address(this));
            uint256 reportedReceived = vault.instantRedeem(shares, address(this), address(this));
            uint256 balanceAfter = token.balanceOf(address(this));
            if (balanceAfter < balanceBefore || balanceAfter - balanceBefore != reportedReceived) {
                revert BalanceMismatch();
            }
        }

        uint256 amount = token.balanceOf(address(this));
        if (amount == 0) {
            return 0;
        }
        uint256 recipientBefore = token.balanceOf(recipient);
        token.safeTransfer(recipient, amount);
        uint256 recipientAfter = token.balanceOf(recipient);
        if (recipientAfter < recipientBefore || recipientAfter - recipientBefore != amount) {
            revert BalanceMismatch();
        }
        return amount;
    }
}

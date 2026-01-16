// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {IBoostedYieldAdapter} from "../../interfaces/IBoostedYieldAdapter.sol";
import {IUpshift} from "../../interfaces/IUpshift.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title UpshiftAdapter
 * @notice Adapter that deposits idle liquidity into an Upshift Vault and supports instant withdrawals.
 */
contract UpshiftAdapter is IBoostedYieldAdapter {
    using SafeERC20 for IERC20;

    /// @notice Boosted pToken allowed to interact with this adapter.
    address public immutable owner;

    /// @notice Underlying ERC20 token managed by the adapter.
    address public immutable override underlying;

    /// @notice Upshift Vault contract.
    IUpshift public immutable vault;

    uint256 private constant FEE_DENOMINATOR = 1e18;

    error NotOwner();
    error NotEnoughFunds();

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

        // Pre-approve the vault for maximal allowance.
        IERC20(underlying_).forceApprove(vault_, type(uint256).max);
    }

    /**
     * @notice Returns the total assets managed by this adapter.
     * @dev Uses convertToAssets which returns the value of shares held.
     */
    function totalUnderlying() external view override returns (uint256) {
        uint256 shares = vault.balanceOf(address(this));
        return vault.convertToAssets(shares);
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
        vault.deposit(received, address(this));

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

        // Calculate needed shares accounting for fee
        uint256 fee = vault.instantRedemptionFee();

        // Gross = Net / (1 - fee)
        // We calculate shares for the Gross amount
        uint256 shares = vault.convertToShares(amount);

        if (fee < FEE_DENOMINATOR) {
            shares = (shares * FEE_DENOMINATOR) / (FEE_DENOMINATOR - fee);
            // Add slight buffer for rounding
            shares = shares + 1;
        }

        uint256 ownedShares = vault.balanceOf(address(this));
        if (shares > ownedShares) {
            shares = ownedShares;
        }

        // instantRedeem(shares, receiver, owner)
        uint256 assetsReceived = vault.instantRedeem(shares, recipient, address(this));

        return assetsReceived;
    }

    /**
     * @notice Withdraws all assets via instant redemption.
     */
    function withdrawAll(address recipient) external override onlyOwner returns (uint256) {
        uint256 shares = vault.balanceOf(address(this));
        if (shares == 0) {
            return 0;
        }
        return vault.instantRedeem(shares, recipient, address(this));
    }
}

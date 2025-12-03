// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import "../PErc20Delegator.sol";
import "../PErc20Delegate.sol";
import "../PeridottrollerInterface.sol";
import "../InterestRateModel.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./RewardDistributorMulti.sol";

interface IMerklDistributor {
    function claim(address account, address token, uint256 amount, bytes32[] calldata proof)
        external
        returns (uint256);
}

/**
 * @title MorphoBoostedDelegate
 * @notice Compound-style delegate for a Morpho-boosted market with optional multi-reward harvesting.
 * @dev Underlying is the vault asset. Funds are deployed into a Morpho ERC4626 vault. Rewards can be claimed
 *      and optionally swapped via a DEX and deposited back into the vault or sent to reserves.
 */
contract MorphoBoostedDelegate is PErc20Delegate {
    using SafeERC20 for IERC20;

    uint256 internal constant MANTISSA_ONE = 1e18;

    /// @notice Morpho vault (ERC4626-compatible).
    IERC4626 public morphoVault;

    /// @notice Fraction of total managed assets to keep idle on the pToken (scaled by 1e18).
    uint256 public vaultBufferMantissa;

    /// @notice When true, deposits are paused and funds are pulled back on toggle.
    bool public vaultPaused;

    /// @notice Reward configuration.
    address public rewardDistributor; // contract to claim rewards from (Merkl/URD)
    address[] public rewardTokens; // reward tokens that will be claimed and forwarded to distributor
    mapping(address => address) public rewardDistributors; // rewardToken => distributor contract
    mapping(address => bool) public isRewardToken;

    event VaultBufferUpdated(uint256 previousMantissa, uint256 newMantissa);
    event VaultPausedUpdated(bool paused);
    event VaultDeposited(uint256 assets, uint256 shares);
    event VaultWithdrawn(uint256 assets, uint256 shares);
    event RewardsHarvested(address[] rewardTokens);
    event RewardsConfigUpdated(address distributor);
    event RewardTokenAdded(address rewardToken);
    event RewardClaimed(
        address indexed user,
        address indexed reward,
        uint256 amount
    );

    /**
     * @notice Called when becoming the implementation for a delegator.
     * @dev Decodes morphoVault and vaultBufferMantissa from becomeImplementationData.
     */
    function _becomeImplementation(bytes memory data) public override {
        require(msg.sender == admin, "only admin");
        if (data.length > 0) {
            (address vault_, uint256 buffer_) = abi.decode(
                data,
                (address, uint256)
            );
            if (vault_ != address(0)) {
                morphoVault = IERC4626(vault_);
                vaultBufferMantissa = buffer_;
            }
        }
    }

    /**
     * @notice Admin function to set the Morpho vault (for post-deployment setup).
     */
    function _setMorphoVault(address vault_, uint256 buffer_) external {
        require(msg.sender == admin, "only admin");
        require(vault_ != address(0), "zero vault");
        morphoVault = IERC4626(vault_);
        vaultBufferMantissa = buffer_;
        emit VaultBufferUpdated(0, buffer_);
    }

    /**
     * @notice Initialize delegate storage (called via delegator's _setImplementation).
     */
    function initialize(
        address underlying_,
        PeridottrollerInterface peridottroller_,
        InterestRateModel interestRateModel_,
        uint256 initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        IERC4626 morphoVault_,
        uint256 vaultBufferMantissa_
    ) public {
        require(accrualBlockNumber == 0 && borrowIndex == 0, "already init");

        admin = payable(msg.sender);
        morphoVault = morphoVault_;
        vaultBufferMantissa = vaultBufferMantissa_;

        super.initialize(
            underlying_,
            peridottroller_,
            interestRateModel_,
            initialExchangeRateMantissa_,
            name_,
            symbol_,
            decimals_
        );
    }

    // Admin setters
    function _setVaultBuffer(uint256 newMantissa) external {
        require(msg.sender == admin, "only admin");
        require(newMantissa <= MANTISSA_ONE, "invalid buffer");
        uint256 prev = vaultBufferMantissa;
        vaultBufferMantissa = newMantissa;
        emit VaultBufferUpdated(prev, newMantissa);
        _rebalanceVault();
    }

    function _setVaultPaused(bool pause) external {
        require(msg.sender == admin, "only admin");
        if (pause == vaultPaused) return;
        vaultPaused = pause;
        if (pause) {
            _withdrawFromVault(_vaultAssets());
        } else {
            _rebalanceVault();
        }
        emit VaultPausedUpdated(pause);
    }

    function _setRewardsConfig(address distributor) external {
        require(msg.sender == admin, "only admin");
        rewardDistributor = distributor;
        emit RewardsConfigUpdated(distributor);
    }

    function _addRewardToken(address rewardToken) external {
        require(msg.sender == admin, "only admin");
        _pushRewardToken(rewardToken);
        emit RewardTokenAdded(rewardToken);
    }

    function _setRewardDistributor(
        address rewardToken,
        address distributor
    ) external {
        require(msg.sender == admin, "only admin");
        rewardDistributors[rewardToken] = distributor;
    }

    /// @notice Admin-only: set the global Merkl/URD distributor address used for harvestRewards.
    function _setMerklDistributor(address distributor) external {
        require(msg.sender == admin, "only admin");
        rewardDistributor = distributor;
    }

    function _pushRewardToken(address rewardToken) internal {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (rewardTokens[i] == rewardToken) return;
        }
        rewardTokens.push(rewardToken);
        isRewardToken[rewardToken] = true;
    }

    // Rewards: claim + swap + deposit
    function harvestRewards() external nonReentrant {
        accrueInterest();
        if (rewardDistributor != address(0) && rewardTokens.length > 0) {
            try
                IRewardsDistributor(rewardDistributor).claim(
                    address(this),
                    rewardTokens
                )
            {} catch {}
        }
        _forwardRewardsToDistributors();
        emit RewardsHarvested(rewardTokens);
    }

    /// @notice Claim Merkl/URD rewards using provided proofs; forwards claimed balances to distributors.
    function claimMerklRewards(
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external nonReentrant {
        require(tokens.length == amounts.length && amounts.length == proofs.length, "length mismatch");
        require(rewardDistributor != address(0), "distributor not set");
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            if (!isRewardToken[token]) continue;
            try IMerklDistributor(rewardDistributor).claim(address(this), token, amounts[i], proofs[i]) returns (
                uint256 claimed
            ) {
                emit RewardClaimed(address(this), token, claimed);
            } catch {}
        }
        _forwardRewardsToDistributors();
    }

    function _forwardRewardsToDistributors() internal {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address rToken = rewardTokens[i];
            address dist = rewardDistributors[rToken];
            if (dist == address(0)) {
                continue;
            }
            uint256 bal = IERC20(rToken).balanceOf(address(this));
            if (bal == 0) continue;
            IERC20(rToken).forceApprove(dist, bal);
            try
                RewardDistributorMulti(dist).addReward(
                    address(this),
                    rToken,
                    bal
                )
            {} catch {}
        }
    }

    // Overridden cash/view hooks
    function getCashPrior() internal view override returns (uint256) {
        return super.getCashPrior() + _vaultWithdrawable();
    }

    function doTransferIn(
        address from,
        uint256 amount
    ) internal override returns (uint256) {
        uint256 actual = super.doTransferIn(from, amount);
        _rebalanceVault();
        return actual;
    }

    function doTransferOut(
        address payable to,
        uint256 amount
    ) internal override {
        _ensureLocalLiquidity(amount);
        super.doTransferOut(to, amount);
        _rebalanceVault();
    }

    // Vault helpers
    function _rebalanceVault() internal {
        if (vaultPaused) return;
        uint256 localCash = super.getCashPrior();
        uint256 vaultAssets = _vaultAssets();
        uint256 total = localCash + vaultAssets;
        if (total == 0) return;
        uint256 target = (total * vaultBufferMantissa) / MANTISSA_ONE;
        if (localCash > target) {
            uint256 toDeposit = localCash - target;
            _depositToVault(toDeposit);
        } else if (target > localCash) {
            uint256 deficit = target - localCash;
            if (deficit > vaultAssets) deficit = vaultAssets;
            _withdrawFromVault(deficit);
        }
    }

    function _ensureLocalLiquidity(uint256 amount) internal {
        uint256 localCash = super.getCashPrior();
        if (localCash >= amount) return;
        uint256 deficit = amount - localCash;
        _withdrawFromVault(deficit);
        uint256 newCash = super.getCashPrior();
        require(newCash >= amount, "liquidity shortfall");
    }

    function _depositToVault(uint256 amount) internal {
        if (amount == 0 || vaultPaused) return;
        IERC20(underlying).forceApprove(address(morphoVault), amount);
        uint256 shares = morphoVault.deposit(amount, address(this));
        emit VaultDeposited(amount, shares);
    }

    function _withdrawFromVault(
        uint256 amount
    ) internal returns (uint256 withdrawn) {
        if (amount == 0) return 0;
        uint256 maxAvail = _vaultWithdrawable();
        require(maxAvail >= amount, "vault shortfall");
        withdrawn = morphoVault.withdraw(amount, address(this), address(this));
        emit VaultWithdrawn(amount, withdrawn);
    }

    function _vaultAssets() internal view returns (uint256) {
        uint256 shares = morphoVault.balanceOf(address(this));
        if (shares == 0) return 0;
        return morphoVault.convertToAssets(shares);
    }

    function _vaultWithdrawable() internal view returns (uint256) {
        try morphoVault.maxWithdraw(address(this)) returns (uint256 amt) {
            if (amt > 0) return amt;
            return _vaultAssets();
        } catch {
            return _vaultAssets();
        }
    }
}

interface IRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IRewardsDistributor {
    function claim(address holder, address[] calldata tokens) external;
}

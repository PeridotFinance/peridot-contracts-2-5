// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import "../PErc20Delegator.sol";
import "../PErc20Delegate.sol";
import "../PeridottrollerInterface.sol";
import "../InterestRateModel.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IMerklDistributor {
    function claim(
        address account,
        address token,
        uint256 amount,
        bytes32[] calldata proof
    ) external returns (uint256);
}

/**
 * @title MorphoBoostedDelegate
 * @notice Compound-style delegate for a Morpho-boosted market.
 * @dev Underlying is the vault asset. Funds are deployed into a Morpho ERC4626 vault.
 *
 *      Yield Distribution:
 *      - Native yield: Automatically accrues via ERC4626 share price increase. All pToken holders
 *        benefit proportionally without any action needed.
 *      - URD/Merkl rewards: Users claim their own rewards directly from Merkl's dapp. If any
 *        rewards are in the underlying token, they are reinvested into the vault to benefit all holders.
 *
 *      GOVERNANCE:
 *      - Admin controls vault, buffer, and reward configuration
 *      - In production, admin MUST be a multisig or timelock contract
 *      - Vault changes should have on-chain delay to prevent fund redirection attacks
 */
contract MorphoBoostedDelegate is PErc20Delegate {
    using SafeERC20 for IERC20;

    uint256 internal constant MANTISSA_ONE = 1e18;
    uint256 public constant MIN_ACTION_DELAY = 1 hours;

    /// @notice Morpho vault (ERC4626-compatible).
    IERC4626 public morphoVault;

    /// @notice Fraction of total managed assets to keep idle on the pToken (scaled by 1e18).
    uint256 public vaultBufferMantissa;

    /// @notice When true, deposits are paused and funds are pulled back on toggle.
    bool public vaultPaused;

    /// @notice Reward configuration (Merkl/URD claims).
    address public rewardDistributor; // contract to claim rewards from (Merkl/URD)
    address[] public rewardTokens; // reward tokens that will be claimed
    mapping(address => bool) public isRewardToken;

    uint256 public actionDelay;
    mapping(bytes32 => uint256) public queuedActions;

    event VaultBufferUpdated(uint256 previousMantissa, uint256 newMantissa);
    event VaultPausedUpdated(bool paused);
    event VaultDeposited(uint256 assets, uint256 shares);
    event VaultWithdrawn(uint256 assets, uint256 shares);
    event MorphoVaultUpdated(address indexed oldVault, address indexed newVault);
    event RewardsHarvested(address[] rewardTokens);
    event RewardsConfigUpdated(address distributor);
    event RewardTokenAdded(address rewardToken);
    event RewardClaimed(
        address indexed user,
        address indexed reward,
        uint256 amount
    );
    event UnderlyingRewardsReinvested(uint256 amount);
    event ActionDelayUpdated(uint256 newDelay);
    event ActionQueued(bytes32 indexed actionId, uint256 executeAfter);
    event ActionCanceled(bytes32 indexed actionId);
    event ActionExecuted(bytes32 indexed actionId);

    /**
     * @notice Called when becoming the implementation for a delegator.
     * @dev Decodes morphoVault and vaultBufferMantissa from becomeImplementationData.
     *      Validates vault address and asset match.
     */
    function _becomeImplementation(bytes memory data) public override {
        require(msg.sender == admin, "only admin");
        if (data.length > 0) {
            (address vault_, uint256 buffer_) = abi.decode(
                data,
                (address, uint256)
            );
            if (vault_ != address(0)) {
                _validateVault(vault_);
                require(buffer_ <= MANTISSA_ONE, "buffer too high");
                morphoVault = IERC4626(vault_);
                vaultBufferMantissa = buffer_;
            }
        }
        if (actionDelay == 0) {
            actionDelay = MIN_ACTION_DELAY;
            emit ActionDelayUpdated(actionDelay);
        }
    }

    /**
     * @notice Admin function to set the Morpho vault (for post-deployment setup).
     * @dev CRITICAL: Validates vault asset matches underlying to prevent fund misdirection.
     *      In production, this should be behind a timelock.
     */
    function _setMorphoVault(address vault_, uint256 buffer_) external {
        require(msg.sender == admin, "only admin");
        bytes32 actionId = keccak256(abi.encode("setMorphoVault", vault_, buffer_));
        _consumeAction(actionId);
        require(vault_ != address(0), "zero vault");
        _validateVault(vault_);
        require(buffer_ <= MANTISSA_ONE, "buffer too high");
        address oldVault = address(morphoVault);
        morphoVault = IERC4626(vault_);
        vaultBufferMantissa = buffer_;
        emit MorphoVaultUpdated(oldVault, vault_);
        emit VaultBufferUpdated(0, buffer_);
        emit ActionExecuted(actionId);
    }

    /**
     * @notice Validates that a vault is compatible with this delegate.
     * @dev Checks: (1) non-zero address, (2) is contract, (3) asset matches underlying.
     */
    function _validateVault(address vault_) internal view {
        require(vault_ != address(0), "zero vault");
        require(vault_.code.length > 0, "vault not contract");

        // Verify vault's asset matches our underlying
        try IERC4626(vault_).asset() returns (address vaultAsset) {
            require(vaultAsset == underlying, "vault asset mismatch");
        } catch {
            revert("vault asset() failed");
        }

        // Sanity check: try calling totalAssets to ensure vault is functional
        try IERC4626(vault_).totalAssets() returns (uint256) {
            // Success - vault appears functional
        } catch {
            revert("vault totalAssets() failed");
        }
    }

    /**
     * @notice Initialize delegate storage (called via delegator's _setImplementation).
     * @dev Validates vault compatibility before initialization.
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
        require(vaultBufferMantissa_ <= MANTISSA_ONE, "buffer too high");

        admin = payable(msg.sender);
        if (actionDelay == 0) {
            actionDelay = MIN_ACTION_DELAY;
            emit ActionDelayUpdated(actionDelay);
        }

        // Initialize parent first to set underlying
        super.initialize(
            underlying_,
            peridottroller_,
            interestRateModel_,
            initialExchangeRateMantissa_,
            name_,
            symbol_,
            decimals_
        );

        // Now validate and set vault (after underlying is set)
        if (address(morphoVault_) != address(0)) {
            _validateVault(address(morphoVault_));
        }
        morphoVault = morphoVault_;
        vaultBufferMantissa = vaultBufferMantissa_;
    }

    // Admin setters
    function _setVaultBuffer(uint256 newMantissa) external {
        require(msg.sender == admin, "only admin");
        bytes32 actionId = keccak256(abi.encode("setVaultBuffer", newMantissa));
        _consumeAction(actionId);
        require(newMantissa <= MANTISSA_ONE, "invalid buffer");
        uint256 prev = vaultBufferMantissa;
        vaultBufferMantissa = newMantissa;
        emit VaultBufferUpdated(prev, newMantissa);
        _rebalanceVault();
        emit ActionExecuted(actionId);
    }

    function _setVaultPaused(bool pause) external {
        require(msg.sender == admin, "only admin");
        bytes32 actionId = keccak256(abi.encode("setVaultPaused", pause));
        _consumeAction(actionId);
        if (pause == vaultPaused) return;
        vaultPaused = pause;
        if (pause) {
            _withdrawFromVault(_vaultWithdrawable());
        } else {
            _rebalanceVault();
        }
        emit VaultPausedUpdated(pause);
        emit ActionExecuted(actionId);
    }

    function _setRewardsConfig(address distributor) external {
        require(msg.sender == admin, "only admin");
        bytes32 actionId = keccak256(abi.encode("setRewardsConfig", distributor));
        _consumeAction(actionId);
        rewardDistributor = distributor;
        emit RewardsConfigUpdated(distributor);
        emit ActionExecuted(actionId);
    }

    function _addRewardToken(address rewardToken) external {
        require(msg.sender == admin, "only admin");
        bytes32 actionId = keccak256(abi.encode("addRewardToken", rewardToken));
        _consumeAction(actionId);
        _pushRewardToken(rewardToken);
        emit RewardTokenAdded(rewardToken);
        emit ActionExecuted(actionId);
    }

    /// @notice Admin-only: set the global Merkl/URD distributor address used for harvestRewards.
    function _setMerklDistributor(address distributor) external {
        require(msg.sender == admin, "only admin");
        bytes32 actionId = keccak256(abi.encode("setMerklDistributor", distributor));
        _consumeAction(actionId);
        rewardDistributor = distributor;
        emit ActionExecuted(actionId);
    }

    function _pushRewardToken(address rewardToken) internal {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (rewardTokens[i] == rewardToken) return;
        }
        rewardTokens.push(rewardToken);
        isRewardToken[rewardToken] = true;
    }

    /**
     * @notice Harvest rewards from the configured distributor.
     * @dev Rewards in the underlying token are automatically reinvested into the vault,
     *      benefiting all pToken holders. Other reward tokens (e.g. governance tokens)
     *      are typically claimed by users directly from Merkl's dapp.
     */
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
        // Reinvest any underlying rewards back into the vault
        _reinvestUnderlyingRewards();
        emit RewardsHarvested(rewardTokens);
    }

    /**
     * @notice Claim Merkl/URD rewards using provided proofs.
     * @dev Rewards in the underlying token are automatically reinvested into the vault.
     *      Other reward tokens are typically claimed by users directly from Merkl's dapp.
     */
    function claimMerklRewards(
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external nonReentrant {
        require(
            tokens.length == amounts.length && amounts.length == proofs.length,
            "length mismatch"
        );
        require(rewardDistributor != address(0), "distributor not set");
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            if (!isRewardToken[token]) continue;
            try
                IMerklDistributor(rewardDistributor).claim(
                    address(this),
                    token,
                    amounts[i],
                    proofs[i]
                )
            returns (uint256 claimed) {
                emit RewardClaimed(address(this), token, claimed);
            } catch {}
        }
        // Reinvest any underlying rewards back into the vault
        _reinvestUnderlyingRewards();
    }

    /**
     * @dev Reinvests any underlying token balance (from rewards) back into the vault.
     *      This benefits all pToken holders by increasing the exchange rate.
     */
    function _reinvestUnderlyingRewards() internal {
        uint256 localCash = super.getCashPrior();
        if (localCash == 0) return;

        // Rebalance will deposit excess cash into the vault
        // Any rewards in underlying will be treated as excess and deposited
        _rebalanceVault();

        // Emit event if we had underlying rewards to reinvest
        uint256 newLocalCash = super.getCashPrior();
        if (localCash > newLocalCash) {
            emit UnderlyingRewardsReinvested(localCash - newLocalCash);
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
        if (vaultPaused || !_vaultConfigured()) return;
        uint256 localCash = super.getCashPrior();
        uint256 vaultWithdrawable = _vaultWithdrawable();
        uint256 total = localCash + vaultWithdrawable;
        if (total == 0) return;
        uint256 target = (total * vaultBufferMantissa) / MANTISSA_ONE;
        if (localCash > target) {
            uint256 toDeposit = localCash - target;
            _depositToVault(toDeposit);
        } else if (target > localCash) {
            uint256 deficit = target - localCash;
            if (deficit > vaultWithdrawable) deficit = vaultWithdrawable;
            if (deficit > 0) {
                _withdrawFromVault(deficit);
            }
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
        if (amount == 0 || vaultPaused || !_vaultConfigured()) return;
        IERC20(underlying).forceApprove(address(morphoVault), amount);
        uint256 shares = morphoVault.deposit(amount, address(this));
        emit VaultDeposited(amount, shares);
    }

    function _withdrawFromVault(
        uint256 amount
    ) internal returns (uint256 withdrawn) {
        if (amount == 0 || !_vaultConfigured()) return 0;
        uint256 maxAvail = _vaultWithdrawable();
        if (maxAvail == 0) return 0;
        if (amount > maxAvail) {
            amount = maxAvail;
        }
        withdrawn = morphoVault.withdraw(amount, address(this), address(this));
        emit VaultWithdrawn(amount, withdrawn);
    }

    function _vaultAssets() internal view returns (uint256) {
        if (!_vaultConfigured()) return 0;
        uint256 shares = morphoVault.balanceOf(address(this));
        if (shares == 0) return 0;
        return morphoVault.convertToAssets(shares);
    }

    /**
     * @notice Returns the amount actually withdrawable from the vault.
     * @dev CRITICAL: Respects ERC4626 maxWithdraw limit. If maxWithdraw returns 0,
     *      it means withdrawals are blocked/disabled, so we return 0 (not all assets).
     *      This prevents getCashPrior() from over-reporting available liquidity.
     */
    function _vaultWithdrawable() internal view returns (uint256) {
        if (!_vaultConfigured()) return 0;

        try morphoVault.maxWithdraw(address(this)) returns (
            uint256 maxWithdrawable
        ) {
            // Respect ERC4626 limit: if maxWithdraw is 0, withdrawals are blocked
            if (maxWithdrawable == 0) return 0;

            // Return the minimum of maxWithdraw and our share value
            // (in case maxWithdraw somehow exceeds our assets)
            uint256 ourAssets = _vaultAssets();
            return maxWithdrawable < ourAssets ? maxWithdrawable : ourAssets;
        } catch {
            // If maxWithdraw fails, be conservative and return 0
            // (don't assume full withdrawability)
            return 0;
        }
    }

    function queueSetMorphoVault(address vault_, uint256 buffer_)
        external
        returns (bytes32 actionId)
    {
        require(msg.sender == admin, "only admin");
        actionId = _queueAction(keccak256(abi.encode("setMorphoVault", vault_, buffer_)));
    }

    function queueSetVaultBuffer(uint256 newMantissa) external returns (bytes32 actionId) {
        require(msg.sender == admin, "only admin");
        actionId = _queueAction(keccak256(abi.encode("setVaultBuffer", newMantissa)));
    }

    function queueSetVaultPaused(bool pause) external returns (bytes32 actionId) {
        require(msg.sender == admin, "only admin");
        actionId = _queueAction(keccak256(abi.encode("setVaultPaused", pause)));
    }

    function queueSetRewardsConfig(address distributor) external returns (bytes32 actionId) {
        require(msg.sender == admin, "only admin");
        actionId = _queueAction(keccak256(abi.encode("setRewardsConfig", distributor)));
    }

    function queueAddRewardToken(address rewardToken) external returns (bytes32 actionId) {
        require(msg.sender == admin, "only admin");
        actionId = _queueAction(keccak256(abi.encode("addRewardToken", rewardToken)));
    }

    function queueSetMerklDistributor(address distributor) external returns (bytes32 actionId) {
        require(msg.sender == admin, "only admin");
        actionId = _queueAction(keccak256(abi.encode("setMerklDistributor", distributor)));
    }

    function setActionDelay(uint256 newDelay) external {
        require(msg.sender == admin, "only admin");
        bytes32 actionId = keccak256(abi.encode("setActionDelay", newDelay));
        _consumeAction(actionId);
        require(newDelay >= actionDelay, "delay cannot decrease");
        require(newDelay >= MIN_ACTION_DELAY, "delay too short");
        actionDelay = newDelay;
        emit ActionDelayUpdated(newDelay);
        emit ActionExecuted(actionId);
    }

    function queueSetActionDelay(uint256 newDelay) external returns (bytes32 actionId) {
        require(msg.sender == admin, "only admin");
        actionId = _queueAction(keccak256(abi.encode("setActionDelay", newDelay)));
    }

    function cancelAction(bytes32 actionId) external {
        require(msg.sender == admin, "only admin");
        require(queuedActions[actionId] != 0, "action not queued");
        delete queuedActions[actionId];
        emit ActionCanceled(actionId);
    }

    function _queueAction(bytes32 actionId) internal returns (bytes32) {
        require(queuedActions[actionId] == 0, "action queued");
        uint256 executeAfter = block.timestamp + actionDelay;
        queuedActions[actionId] = executeAfter;
        emit ActionQueued(actionId, executeAfter);
        return actionId;
    }

    function _consumeAction(bytes32 actionId) internal {
        uint256 executeAfter = queuedActions[actionId];
        require(executeAfter != 0, "action not queued");
        require(block.timestamp >= executeAfter, "action not ready");
        delete queuedActions[actionId];
    }

    function _vaultConfigured() internal view returns (bool) {
        return address(morphoVault) != address(0);
    }
}

interface IRewardsDistributor {
    function claim(address holder, address[] calldata tokens) external;
}

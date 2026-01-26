// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import "../PErc20.sol";
import "../PeridottrollerInterface.sol";
import "../InterestRateModel.sol";
import {IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Morpho-boosted pToken
 * @notice PTokens that route idle liquidity into a Morpho ERC4626 vault on Monad.
 * @dev Exchange rate rises from both borrower interest and vault share appreciation.
 */
contract MorphoBoostedPErc20 is PErc20 {
    using SafeERC20 for IERC20;

    uint256 internal constant MANTISSA_ONE = 1e18;
    address internal constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant MIN_ACTION_DELAY = 1 hours;

    /// @notice ERC4626 vault that receives underlying deposits.
    IERC4626 public immutable morphoVault;

    /// @notice Portion of total assets to keep locally as idle cash (scaled by 1e18).
    uint256 public vaultBufferMantissa;

    /// @notice When true, new deposits are not sent to the vault and existing shares can be withdrawn.
    bool public vaultPaused;

    uint256 public actionDelay;
    mapping(bytes32 => uint256) public queuedActions;

    event VaultBufferUpdated(uint256 previousMantissa, uint256 newMantissa);
    event VaultPausedUpdated(bool paused);
    event VaultDeposited(uint256 assets, uint256 shares);
    event VaultWithdrawn(uint256 assets, uint256 shares);
    event ActionDelayUpdated(uint256 newDelay);
    event ActionQueued(bytes32 indexed actionId, uint256 executeAfter);
    event ActionCanceled(bytes32 indexed actionId);
    event ActionExecuted(bytes32 indexed actionId);

    constructor(
        address underlying_,
        PeridottrollerInterface peridottroller_,
        InterestRateModel interestRateModel_,
        uint256 initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address payable admin_,
        IERC4626 vault_,
        uint256 vaultBufferMantissa_,
        uint256 minVaultSeedShares
    ) {
        require(address(vault_) != address(0), "MorphoBoosted: vault zero");
        _validateVault(underlying_, vault_, minVaultSeedShares);

        // Temporary admin for initialization
        admin = payable(msg.sender);
        morphoVault = vault_;

        initialize(
            underlying_, peridottroller_, interestRateModel_, initialExchangeRateMantissa_, name_, symbol_, decimals_
        );

        _setVaultBufferInternal(vaultBufferMantissa_);
        actionDelay = MIN_ACTION_DELAY;
        emit ActionDelayUpdated(actionDelay);

        // Transfer admin rights to the designated address
        admin = admin_;
    }

    /**
     * @notice Update the vault buffer ratio.
     */
    function setVaultBufferMantissa(uint256 newMantissa) external {
        require(msg.sender == admin, "MorphoBoosted: only admin");
        bytes32 actionId = keccak256(abi.encode("setVaultBufferMantissa", newMantissa));
        _consumeAction(actionId);
        _setVaultBufferInternal(newMantissa);
        _rebalanceVault();
        emit ActionExecuted(actionId);
    }

    /**
     * @notice Pause/unpause vault usage. Pausing pulls all assets back to the pToken.
     */
    function setVaultPaused(bool pause) external {
        require(msg.sender == admin, "MorphoBoosted: only admin");
        bytes32 actionId = keccak256(abi.encode("setVaultPaused", pause));
        _consumeAction(actionId);
        if (pause == vaultPaused) {
            return;
        }
        vaultPaused = pause;
        if (pause) {
            _withdrawFromVault(_vaultWithdrawable());
        } else {
            _rebalanceVault();
        }
        emit VaultPausedUpdated(pause);
        emit ActionExecuted(actionId);
    }

    /**
     * @notice Returns total underlying managed inside the vault.
     */
    function totalVaultAssets() external view returns (uint256) {
        return _vaultAssets();
    }

    /**
     * @notice Returns total underlying across local cash and the vault.
     */
    function totalManagedAssets() external view returns (uint256) {
        return super.getCashPrior() + _vaultAssets();
    }

    /**
     * @dev Include vault liquidity when the core protocol queries available cash.
     */
    function getCashPrior() internal view override returns (uint256) {
        return super.getCashPrior() + _vaultWithdrawable();
    }

    /**
     * @dev After pulling tokens in, push excess above the buffer into the vault.
     */
    function doTransferIn(address from, uint256 amount) internal override returns (uint256) {
        uint256 actual = super.doTransferIn(from, amount);
        _rebalanceVault();
        return actual;
    }

    /**
     * @dev Before sending tokens out, ensure sufficient local liquidity by withdrawing from the vault if needed.
     */
    function doTransferOut(address payable to, uint256 amount) internal override {
        _ensureLocalLiquidity(amount);
        super.doTransferOut(to, amount);
        _rebalanceVault();
    }

    function _setVaultBufferInternal(uint256 newMantissa) internal {
        require(newMantissa <= MANTISSA_ONE, "MorphoBoosted: invalid buffer");
        uint256 previous = vaultBufferMantissa;
        vaultBufferMantissa = newMantissa;
        emit VaultBufferUpdated(previous, newMantissa);
    }

    function _validateVault(address underlying_, IERC4626 vault_, uint256 minSeed) internal view {
        require(vault_.asset() == underlying_, "MorphoBoosted: vault asset mismatch");
        if (minSeed > 0) {
            require(IERC20(address(vault_)).balanceOf(DEAD_ADDRESS) >= minSeed, "MorphoBoosted: vault seed missing");
        }
    }

    function _rebalanceVault() internal {
        if (vaultPaused) {
            return;
        }

        uint256 localCash = super.getCashPrior();
        uint256 vaultWithdrawable = _vaultWithdrawable();
        uint256 total = localCash + vaultWithdrawable;
        if (total == 0) {
            return;
        }

        uint256 targetBuffer = (total * vaultBufferMantissa) / MANTISSA_ONE;

        if (localCash > targetBuffer) {
            uint256 toDeposit = localCash - targetBuffer;
            _depositToVault(toDeposit);
        } else if (targetBuffer > localCash) {
            uint256 deficit = targetBuffer - localCash;
            if (deficit > vaultWithdrawable) {
                deficit = vaultWithdrawable;
            }
            if (deficit > 0) {
                _withdrawFromVault(deficit);
            }
        }
    }

    function _ensureLocalLiquidity(uint256 amount) internal {
        uint256 localCash = super.getCashPrior();
        if (localCash >= amount) {
            return;
        }

        uint256 deficit = amount - localCash;
        _withdrawFromVault(deficit);

        uint256 newCash = super.getCashPrior();
        require(newCash >= amount, "MorphoBoosted: insufficient liquidity");
    }

    function _depositToVault(uint256 amount) internal {
        if (amount == 0) {
            return;
        }
        IERC20(underlying).forceApprove(address(morphoVault), amount);
        try morphoVault.deposit(amount, address(this)) returns (uint256 shares) {
            emit VaultDeposited(amount, shares);
        } catch {}
    }

    function _withdrawFromVault(uint256 amount) internal returns (uint256 withdrawn) {
        if (amount == 0) {
            return 0;
        }
        uint256 maxAvailable = _vaultWithdrawable();
        if (maxAvailable == 0) {
            return 0;
        }
        if (amount > maxAvailable) {
            amount = maxAvailable;
        }
        try morphoVault.withdraw(amount, address(this), address(this)) returns (uint256 shares) {
            withdrawn = shares;
            emit VaultWithdrawn(amount, shares);
        } catch {
            return 0;
        }
    }

    function _vaultAssets() internal view returns (uint256) {
        uint256 shares = morphoVault.balanceOf(address(this));
        if (shares == 0) {
            return 0;
        }
        return morphoVault.convertToAssets(shares);
    }

    function _vaultWithdrawable() internal view returns (uint256) {
        try morphoVault.maxWithdraw(address(this)) returns (uint256 amount) {
            if (amount > 0) return amount;
            return _vaultAssets();
        } catch {
            return _vaultAssets();
        }
    }

    function queueSetVaultBufferMantissa(uint256 newMantissa) external returns (bytes32 actionId) {
        require(msg.sender == admin, "MorphoBoosted: only admin");
        actionId = _queueAction(keccak256(abi.encode("setVaultBufferMantissa", newMantissa)));
    }

    function queueSetVaultPaused(bool pause) external returns (bytes32 actionId) {
        require(msg.sender == admin, "MorphoBoosted: only admin");
        actionId = _queueAction(keccak256(abi.encode("setVaultPaused", pause)));
    }

    function setActionDelay(uint256 newDelay) external {
        require(msg.sender == admin, "MorphoBoosted: only admin");
        bytes32 actionId = keccak256(abi.encode("setActionDelay", newDelay));
        _consumeAction(actionId);
        require(newDelay >= actionDelay, "MorphoBoosted: delay cannot decrease");
        require(newDelay >= MIN_ACTION_DELAY, "MorphoBoosted: delay too short");
        actionDelay = newDelay;
        emit ActionDelayUpdated(newDelay);
        emit ActionExecuted(actionId);
    }

    function queueSetActionDelay(uint256 newDelay) external returns (bytes32 actionId) {
        require(msg.sender == admin, "MorphoBoosted: only admin");
        actionId = _queueAction(keccak256(abi.encode("setActionDelay", newDelay)));
    }

    function cancelAction(bytes32 actionId) external {
        require(msg.sender == admin, "MorphoBoosted: only admin");
        require(queuedActions[actionId] != 0, "MorphoBoosted: action not queued");
        delete queuedActions[actionId];
        emit ActionCanceled(actionId);
    }

    function _queueAction(bytes32 actionId) internal returns (bytes32) {
        require(queuedActions[actionId] == 0, "MorphoBoosted: action queued");
        uint256 executeAfter = block.timestamp + actionDelay;
        queuedActions[actionId] = executeAfter;
        emit ActionQueued(actionId, executeAfter);
        return actionId;
    }

    function _consumeAction(bytes32 actionId) internal {
        uint256 executeAfter = queuedActions[actionId];
        require(executeAfter != 0, "MorphoBoosted: action not queued");
        require(block.timestamp >= executeAfter, "MorphoBoosted: action not ready");
        delete queuedActions[actionId];
    }
}

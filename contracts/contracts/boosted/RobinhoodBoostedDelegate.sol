// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import "../PErc20Delegate.sol";
import "../interfaces/IRobinhoodBoostedVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title RobinhoodBoostedDelegate
 * @notice USDG pToken implementation that directly owns one side of a Robinhood paired vault.
 * @dev Calls the vault from the delegator address, so the pToken itself remains the configured
 *      USDG side account. The generic IBoostedYieldAdapter must not sit between this contract
 *      and the vault because it cannot propagate realized strategy losses.
 */
contract RobinhoodBoostedDelegate is PErc20Delegate {
    using SafeERC20 for IERC20;

    error ActionAlreadyQueued();
    error ActionDelayCannotDecrease();
    error ActionDelayTooShort();
    error ActionNotQueued();
    error ActionNotReady();
    error DepositBalanceMismatch();
    error InvalidBuffer();
    error InvalidOperator();
    error InvalidPair();
    error InvalidVault();
    error MarketNotFresh();
    error OnlyAdmin();
    error OnlyVaultOperator();
    error OldVaultNotEmpty();
    error PTokenNotSideAccount();
    error StrategyLiquidityShortfall();
    error WithdrawalBalanceMismatch();

    uint256 internal constant MANTISSA_ONE = 1e18;
    uint256 internal constant MAX_SETTLEMENT_STEPS = 3;
    uint256 public constant MIN_ACTION_DELAY = 1 hours;

    IRobinhoodBoostedVault public robinhoodVault;
    bytes32 public robinhoodPairId;

    /// @notice Fraction of managed USDG retained locally, scaled by 1e18.
    uint256 public vaultBufferMantissa;

    /// @notice Blocks new vault deposits. Existing vault claims remain part of exchange-rate accounting.
    bool public vaultPaused;

    /// @notice Address allowed to rebalance or deliberately realize a vault checkpoint/loss.
    address public vaultOperator;

    uint256 public cumulativeVaultLoss;
    uint256 public actionDelay;
    mapping(bytes32 => uint256) public queuedActions;

    /// @dev Requires a live accounted-assets report while a mint prices new pTokens.
    bool internal mintVaultAssetsValidated;

    event RobinhoodVaultConfigured(
        address indexed vault, bytes32 indexed pairId, uint256 bufferMantissa, address indexed operator
    );
    event VaultBufferUpdated(uint256 previousMantissa, uint256 newMantissa);
    event VaultPausedUpdated(bool paused);
    event VaultOperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event VaultDeposit(uint256 requested, uint256 deposited);
    event VaultWithdrawal(uint256 requested, uint256 returned, uint256 realizedLoss);
    event VaultDepositFailed(uint256 requested);
    event VaultWithdrawalFailed(uint256 requested);
    event ActionDelayUpdated(uint256 newDelay);
    event ActionQueued(bytes32 indexed actionId, uint256 executeAfter);
    event ActionCanceled(bytes32 indexed actionId);
    event ActionExecuted(bytes32 indexed actionId);

    modifier onlyVaultOperator() {
        if (msg.sender != admin && msg.sender != vaultOperator) revert OnlyVaultOperator();
        _;
    }

    /**
     * @notice Initializes delegate-specific storage when installed behind PErc20Delegator.
     * @dev Empty data is the normal deployment path. Governance registers the production
     *      pair with the delegator as USDG side account, then configures this delegate.
     */
    function _becomeImplementation(bytes memory data) public override {
        if (msg.sender != admin) revert OnlyAdmin();
        if (actionDelay == 0) {
            actionDelay = MIN_ACTION_DELAY;
            emit ActionDelayUpdated(actionDelay);
        }
        if (address(robinhoodVault) == address(0)) {
            vaultPaused = true;
        }
        if (data.length != 0) {
            (address vault_, bytes32 pairId_, uint256 buffer_, address operator_) =
                abi.decode(data, (address, bytes32, uint256, address));
            _configureVault(vault_, pairId_, buffer_, operator_);
        }
    }

    /**
     * @notice Returns all locally held and vault-accounted USDG.
     */
    function totalManagedAssets() external view returns (uint256) {
        return super.getCashPrior() + _vaultAccountedAssets();
    }

    function vaultAccountedAssets() external view returns (uint256) {
        return _vaultAccountedAssets();
    }

    function vaultLiquidAssets() external view returns (uint256) {
        return _vaultLiquidAssets();
    }

    /**
     * @notice Supplies USDG only when the vault claim used for mint pricing is live.
     * @dev Other operations use conservative zero-value fallbacks so vault read failures
     *      cannot freeze local cash while new suppliers cannot dilute existing holders.
     */
    function mint(uint256 mintAmount) external override returns (uint256) {
        mintVaultAssetsValidated = true;
        mintInternal(mintAmount);
        mintVaultAssetsValidated = false;
        return NO_ERROR;
    }

    /**
     * @dev Cash checks use only local USDG plus the vault's idle USDG. LP-backed claims
     *      are included in exchange-rate accounting but are not reported as immediately liquid.
     */
    function getCashPrior() internal view override returns (uint256) {
        return super.getCashPrior() + _vaultLiquidAssets();
    }

    /**
     * @dev Exchange-rate accounting includes the full side-specific vault claim.
     */
    function exchangeRateStoredInternal() internal view override returns (uint256) {
        if (totalSupply == 0) {
            return initialExchangeRateMantissa;
        }
        uint256 managedCash = super.getCashPrior() + _vaultAccountedAssets();
        uint256 netAssets = managedCash + totalBorrows - totalReserves;
        return (netAssets * expScale) / totalSupply;
    }

    function doTransferIn(address from, uint256 amount) internal override returns (uint256) {
        uint256 actual = super.doTransferIn(from, amount);
        _rebalanceVault(false);
        return actual;
    }

    function doTransferOut(address payable to, uint256 amount) internal override {
        _prepareFixedLiquidity(amount);
        if (super.getCashPrior() < amount) revert StrategyLiquidityShortfall();
        super.doTransferOut(to, amount);
        _rebalanceVault(false);
    }

    /**
     * @notice Redeems pTokens using the post-vault-operation exchange rate.
     * @dev If a vault withdrawal recognizes a loss, the output is recalculated before
     *      token burning and transfer so the loss is shared by all suppliers atomically.
     */
    function redeem(uint256 redeemTokens) external override nonReentrant returns (uint256) {
        accrueInterest();
        _redeemTokensLossAware(payable(msg.sender), redeemTokens);
        return NO_ERROR;
    }

    /**
     * @notice Redeems an exact USDG amount using the post-vault-operation exchange rate.
     * @dev A newly recognized loss increases the number of pTokens burned for the exact output.
     */
    function redeemUnderlying(uint256 redeemAmount) external override nonReentrant returns (uint256) {
        accrueInterest();
        _redeemUnderlyingLossAware(payable(msg.sender), redeemAmount);
        return NO_ERROR;
    }

    function rebalanceVault() external onlyVaultOperator nonReentrant {
        _rebalanceVault(true);
    }

    /**
     * @notice Pulls vault assets into local pToken cash and records any realized loss.
     * @param amount Amount requested. type(uint256).max requests the full accounted claim.
     */
    function syncVault(uint256 amount)
        external
        onlyVaultOperator
        nonReentrant
        returns (uint256 returned, uint256 realizedLoss)
    {
        uint256 accounted = _vaultAccountedAssets();
        uint256 requested = amount == type(uint256).max ? accounted : amount;
        (returned, realizedLoss,) = _withdrawFromVault(requested);
    }

    function queueSetVaultConfig(address vault_, bytes32 pairId_, uint256 buffer_, address operator_)
        external
        returns (bytes32 actionId)
    {
        if (msg.sender != admin) revert OnlyAdmin();
        actionId = _queueAction(keccak256(abi.encode("setVaultConfig", vault_, pairId_, buffer_, operator_)));
    }

    function _setVaultConfig(address vault_, bytes32 pairId_, uint256 buffer_, address operator_) external {
        if (msg.sender != admin) revert OnlyAdmin();
        bytes32 actionId = keccak256(abi.encode("setVaultConfig", vault_, pairId_, buffer_, operator_));
        _consumeAction(actionId);
        _configureVault(vault_, pairId_, buffer_, operator_);
        emit ActionExecuted(actionId);
    }

    function queueSetVaultBuffer(uint256 newMantissa) external returns (bytes32 actionId) {
        if (msg.sender != admin) revert OnlyAdmin();
        actionId = _queueAction(keccak256(abi.encode("setVaultBuffer", newMantissa)));
    }

    function _setVaultBuffer(uint256 newMantissa) external {
        if (msg.sender != admin) revert OnlyAdmin();
        bytes32 actionId = keccak256(abi.encode("setVaultBuffer", newMantissa));
        _consumeAction(actionId);
        if (newMantissa > MANTISSA_ONE) revert InvalidBuffer();
        uint256 previous = vaultBufferMantissa;
        vaultBufferMantissa = newMantissa;
        emit VaultBufferUpdated(previous, newMantissa);
        _rebalanceVault(true);
        emit ActionExecuted(actionId);
    }

    function queueSetVaultPaused(bool pause) external returns (bytes32 actionId) {
        if (msg.sender != admin) revert OnlyAdmin();
        actionId = _queueAction(keccak256(abi.encode("setVaultPaused", pause)));
    }

    function _setVaultPaused(bool pause) external {
        if (msg.sender != admin) revert OnlyAdmin();
        bytes32 actionId = keccak256(abi.encode("setVaultPaused", pause));
        _consumeAction(actionId);
        if (!pause) {
            _validateVault(address(robinhoodVault), robinhoodPairId);
        }
        vaultPaused = pause;
        if (pause) {
            _withdrawFromVault(_vaultAccountedAssets());
        } else {
            _rebalanceVault(true);
        }
        emit VaultPausedUpdated(pause);
        emit ActionExecuted(actionId);
    }

    function queueSetVaultOperator(address newOperator) external returns (bytes32 actionId) {
        if (msg.sender != admin) revert OnlyAdmin();
        actionId = _queueAction(keccak256(abi.encode("setVaultOperator", newOperator)));
    }

    function _setVaultOperator(address newOperator) external {
        if (msg.sender != admin) revert OnlyAdmin();
        bytes32 actionId = keccak256(abi.encode("setVaultOperator", newOperator));
        _consumeAction(actionId);
        if (newOperator == address(0)) revert InvalidOperator();
        address previous = vaultOperator;
        vaultOperator = newOperator;
        emit VaultOperatorUpdated(previous, newOperator);
        emit ActionExecuted(actionId);
    }

    function queueSetActionDelay(uint256 newDelay) external returns (bytes32 actionId) {
        if (msg.sender != admin) revert OnlyAdmin();
        actionId = _queueAction(keccak256(abi.encode("setActionDelay", newDelay)));
    }

    function _setActionDelay(uint256 newDelay) external {
        if (msg.sender != admin) revert OnlyAdmin();
        bytes32 actionId = keccak256(abi.encode("setActionDelay", newDelay));
        _consumeAction(actionId);
        if (newDelay < actionDelay) revert ActionDelayCannotDecrease();
        if (newDelay < MIN_ACTION_DELAY) revert ActionDelayTooShort();
        actionDelay = newDelay;
        emit ActionDelayUpdated(newDelay);
        emit ActionExecuted(actionId);
    }

    function cancelAction(bytes32 actionId) external {
        if (msg.sender != admin) revert OnlyAdmin();
        if (queuedActions[actionId] == 0) revert ActionNotQueued();
        delete queuedActions[actionId];
        emit ActionCanceled(actionId);
    }

    function _redeemTokensLossAware(address payable redeemer, uint256 redeemTokens) internal {
        if (accrualBlockNumber != getBlockNumber()) revert MarketNotFresh();

        uint256 redeemAmount;
        for (uint256 i = 0; i < MAX_SETTLEMENT_STEPS; i++) {
            Exp memory exchangeRate = Exp({mantissa: exchangeRateStoredInternal()});
            redeemAmount = mul_ScalarTruncate(exchangeRate, redeemTokens);
            uint256 localCash = super.getCashPrior();
            if (localCash >= redeemAmount) break;
            (uint256 returned, uint256 loss, bool success) = _withdrawFromVault(redeemAmount - localCash);
            if (!success || (returned == 0 && loss == 0)) break;
        }

        Exp memory settledRate = Exp({mantissa: exchangeRateStoredInternal()});
        redeemAmount = mul_ScalarTruncate(settledRate, redeemTokens);
        if (super.getCashPrior() < redeemAmount) revert RedeemTransferOutNotPossible();

        uint256 allowed = peridottroller.redeemAllowed(address(this), redeemer, redeemTokens);
        if (allowed != 0) revert RedeemPeridottrollerRejection(allowed);

        totalSupply -= redeemTokens;
        accountTokens[redeemer] -= redeemTokens;
        super.doTransferOut(redeemer, redeemAmount);
        _rebalanceVault(false);

        emit Transfer(redeemer, address(this), redeemTokens);
        emit Redeem(redeemer, redeemAmount, redeemTokens);
        peridottroller.redeemVerify(address(this), redeemer, redeemAmount, redeemTokens);
    }

    function _redeemUnderlyingLossAware(address payable redeemer, uint256 redeemAmount) internal {
        if (accrualBlockNumber != getBlockNumber()) revert MarketNotFresh();
        _prepareFixedLiquidity(redeemAmount);
        if (super.getCashPrior() < redeemAmount) revert RedeemTransferOutNotPossible();

        Exp memory settledRate = Exp({mantissa: exchangeRateStoredInternal()});
        uint256 redeemTokens = div_(redeemAmount, settledRate);
        uint256 allowed = peridottroller.redeemAllowed(address(this), redeemer, redeemTokens);
        if (allowed != 0) revert RedeemPeridottrollerRejection(allowed);

        totalSupply -= redeemTokens;
        accountTokens[redeemer] -= redeemTokens;
        super.doTransferOut(redeemer, redeemAmount);
        _rebalanceVault(false);

        emit Transfer(redeemer, address(this), redeemTokens);
        emit Redeem(redeemer, redeemAmount, redeemTokens);
        peridottroller.redeemVerify(address(this), redeemer, redeemAmount, redeemTokens);
    }

    function _prepareFixedLiquidity(uint256 target) internal {
        for (uint256 i = 0; i < MAX_SETTLEMENT_STEPS; i++) {
            uint256 localCash = super.getCashPrior();
            if (localCash >= target) return;
            (uint256 returned, uint256 loss, bool success) = _withdrawFromVault(target - localCash);
            if (!success || (returned == 0 && loss == 0)) return;
        }
    }

    function _rebalanceVault(bool allowWithdrawal) internal {
        if (vaultPaused || !_vaultConfigured()) return;
        uint256 localCash = super.getCashPrior();
        (bool accountedValid, uint256 accounted) = _tryVaultAccountedAssets();
        (bool liquidValid,) = _tryVaultLiquidAssets();
        if (!accountedValid || !liquidValid) return;
        uint256 totalAssets = localCash + accounted;
        if (totalAssets == 0) return;

        uint256 targetBuffer = (totalAssets * vaultBufferMantissa) / MANTISSA_ONE;
        if (localCash > targetBuffer) {
            _depositToVault(localCash - targetBuffer);
        } else if (allowWithdrawal && targetBuffer > localCash) {
            _withdrawFromVault(targetBuffer - localCash);
        }
    }

    function _depositToVault(uint256 amount) internal {
        if (amount == 0 || vaultPaused || !_vaultConfigured()) return;
        IERC20 token = IERC20(underlying);
        address vaultAddress = address(robinhoodVault);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.forceApprove(vaultAddress, amount);
        try robinhoodVault.depositForPair(robinhoodPairId, underlying, amount) returns (uint256 deposited) {
            token.forceApprove(vaultAddress, 0);
            uint256 balanceAfter = token.balanceOf(address(this));
            if (balanceAfter > balanceBefore || balanceBefore - balanceAfter != amount || deposited != amount) {
                revert DepositBalanceMismatch();
            }
            emit VaultDeposit(amount, deposited);
        } catch {
            token.forceApprove(vaultAddress, 0);
            emit VaultDepositFailed(amount);
        }
    }

    function _withdrawFromVault(uint256 requested)
        internal
        returns (uint256 returned, uint256 realizedLoss, bool success)
    {
        if (requested == 0 || !_vaultConfigured()) return (0, 0, false);
        (bool accountedValid, uint256 accounted) = _tryVaultAccountedAssets();
        if (!accountedValid) return (0, 0, false);
        if (requested > accounted) requested = accounted;
        if (requested == 0) return (0, 0, false);

        IERC20 token = IERC20(underlying);
        uint256 balanceBefore = token.balanceOf(address(this));
        try robinhoodVault.withdrawForSide(
            robinhoodPairId, underlying, requested, address(this), block.timestamp
        ) returns (
            uint256 actualReturned, uint256 actualLoss
        ) {
            uint256 balanceAfter = token.balanceOf(address(this));
            if (balanceAfter < balanceBefore || balanceAfter - balanceBefore != actualReturned) {
                revert WithdrawalBalanceMismatch();
            }
            returned = actualReturned;
            realizedLoss = actualLoss;
            cumulativeVaultLoss += actualLoss;
            success = true;
            emit VaultWithdrawal(requested, actualReturned, actualLoss);
        } catch {
            emit VaultWithdrawalFailed(requested);
        }
    }

    function _configureVault(address vault_, bytes32 pairId_, uint256 buffer_, address operator_) internal {
        if (buffer_ > MANTISSA_ONE) revert InvalidBuffer();
        if (operator_ == address(0)) revert InvalidOperator();
        if (_vaultConfigured() && (vault_ != address(robinhoodVault) || pairId_ != robinhoodPairId)) {
            if (robinhoodVault.accountedAssets(robinhoodPairId, underlying) != 0) revert OldVaultNotEmpty();
        }
        _validateVault(vault_, pairId_);
        robinhoodVault = IRobinhoodBoostedVault(vault_);
        robinhoodPairId = pairId_;
        vaultBufferMantissa = buffer_;
        vaultOperator = operator_;
        vaultPaused = true;
        emit RobinhoodVaultConfigured(vault_, pairId_, buffer_, operator_);
        emit VaultPausedUpdated(true);
    }

    function _validateVault(address vault_, bytes32 pairId_) internal view {
        if (vault_ == address(0) || vault_.code.length == 0) revert InvalidVault();
        if (pairId_ == bytes32(0)) revert InvalidPair();
        IRobinhoodBoostedVault candidate = IRobinhoodBoostedVault(vault_);
        if (candidate.sideAccount(pairId_, underlying) != address(this)) revert PTokenNotSideAccount();
        candidate.accountedAssets(pairId_, underlying);
        candidate.liquidAssets(pairId_, underlying);
    }

    function _vaultAccountedAssets() internal view returns (uint256) {
        if (!_vaultConfigured()) return 0;
        if (mintVaultAssetsValidated) {
            return robinhoodVault.accountedAssets(robinhoodPairId, underlying);
        }
        (bool valid, uint256 assets) = _tryVaultAccountedAssets();
        return valid ? assets : 0;
    }

    function _vaultLiquidAssets() internal view returns (uint256) {
        if (!_vaultConfigured()) return 0;
        (bool valid, uint256 assets) = _tryVaultLiquidAssets();
        return valid ? assets : 0;
    }

    function _tryVaultAccountedAssets() internal view returns (bool valid, uint256 assets) {
        try robinhoodVault.accountedAssets(robinhoodPairId, underlying) returns (uint256 value) {
            return (true, value);
        } catch {
            return (false, 0);
        }
    }

    function _tryVaultLiquidAssets() internal view returns (bool valid, uint256 assets) {
        try robinhoodVault.liquidAssets(robinhoodPairId, underlying) returns (uint256 value) {
            return (true, value);
        } catch {
            return (false, 0);
        }
    }

    function _vaultConfigured() internal view returns (bool) {
        return address(robinhoodVault) != address(0) && robinhoodPairId != bytes32(0);
    }

    function _queueAction(bytes32 actionId) internal returns (bytes32) {
        if (queuedActions[actionId] != 0) revert ActionAlreadyQueued();
        uint256 executeAfter = block.timestamp + actionDelay;
        queuedActions[actionId] = executeAfter;
        emit ActionQueued(actionId, executeAfter);
        return actionId;
    }

    function _consumeAction(bytes32 actionId) internal {
        uint256 executeAfter = queuedActions[actionId];
        if (executeAfter == 0) revert ActionNotQueued();
        if (block.timestamp < executeAfter) revert ActionNotReady();
        delete queuedActions[actionId];
    }
}

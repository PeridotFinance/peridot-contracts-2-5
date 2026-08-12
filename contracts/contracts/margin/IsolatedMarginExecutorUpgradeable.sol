// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC3156FlashBorrower, IERC3156FlashLender} from "../PTokenInterfaces.sol";
import {PErc20} from "../PErc20.sol";
import {IsolatedMarginAccount} from "./IsolatedMarginAccount.sol";
import {IsolatedMarginAccountFactory} from "./IsolatedMarginAccountFactory.sol";
import {IsolatedMarginTypes} from "./IsolatedMarginTypes.sol";
import {IsolatedMarginConfigUpgradeable} from "./IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginQuoter} from "./IsolatedMarginQuoter.sol";
import {IsolatedMarginRiskEngineUpgradeable} from "./IsolatedMarginRiskEngineUpgradeable.sol";
import {IsolatedMarginSwapModule} from "./IsolatedMarginSwapModule.sol";
import {IsolatedMarginVaultUpgradeable} from "./IsolatedMarginVaultUpgradeable.sol";
import {MarginFeeDistributorUpgradeable} from "./MarginFeeDistributorUpgradeable.sol";

contract IsolatedMarginExecutorUpgradeable is Initializable, ReentrancyGuardUpgradeable, IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    error ExecutorError(uint8 code);

    uint256 private constant BPS = 10_000;
    uint256 private constant LEVERAGE_SCALE = 100;
    bytes32 private constant FLASH_CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    enum Operation {
        NONE,
        OPEN_LONG,
        OPEN_SHORT,
        CLOSE
    }

    struct OpenParams {
        address marginPToken;
        address positionPToken;
        address debtPToken;
        uint256 marginPTokenAmount;
        uint16 leverageX100;
        uint256 maxOpeningFeePToken;
        uint256 minPositionUnderlying;
        IsolatedMarginTypes.Side side;
        bytes swapData;
    }

    struct CloseParams {
        uint256 positionId;
        uint16 closeBps;
        uint256 maxClosingFeePToken;
        uint256 minDebtUnderlying;
        uint256 minMarginUnderlying;
        bytes positionToDebtSwapData;
        bytes debtToMarginSwapData;
    }

    struct PendingFlash {
        Operation operation;
        uint256 positionId;
        address account;
        address marginPToken;
        address positionPToken;
        address debtPToken;
        uint256 marginUnderlying;
        uint256 positionPTokensToRedeem;
        uint256 flashAmount;
        uint256 minOutputAmount;
        uint256 closingFeePToken;
        uint256 resultPTokenAmount;
        uint256 borrowedAmount;
        bytes32 dataHash;
        bool fullClose;
        bool active;
    }

    IsolatedMarginAccountFactory public accountFactory;
    IsolatedMarginConfigUpgradeable public config;
    IsolatedMarginRiskEngineUpgradeable public riskEngine;
    IsolatedMarginVaultUpgradeable public vault;
    MarginFeeDistributorUpgradeable public feeDistributor;
    IsolatedMarginQuoter public quoter;
    IsolatedMarginSwapModule public swapModule;

    uint256 public nextPositionId;
    mapping(uint256 positionId => IsolatedMarginTypes.Position) public positions;

    PendingFlash private _pending;

    event PositionOpened(
        uint256 indexed positionId,
        address indexed user,
        address indexed account,
        IsolatedMarginTypes.Side side,
        address marginPToken,
        address positionPToken,
        address debtPToken,
        uint256 marginPTokenAmount,
        uint256 borrowedAmount,
        uint256 grossAssetValueUsd,
        uint256 leverageX100,
        uint256 healthFactorBps
    );
    event CollateralAdded(uint256 indexed positionId, uint256 pTokenAmount, uint256 healthFactorBps);
    event DebtRepaid(uint256 indexed positionId, uint256 underlyingAmount, uint256 remainingDebt);
    event PositionClosed(
        uint256 indexed positionId,
        uint16 closeBps,
        uint256 debtRepaid,
        uint256 returnedMarginPTokens,
        uint256 closingFeePTokens,
        uint256 healthFactorBps,
        bool fullyClosed
    );

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address config_,
        address riskEngine_,
        address vault_,
        address feeDistributor_,
        address quoter_,
        address swapModule_,
        address accountFactory_
    ) external initializer {
        if (config_.code.length == 0) revert ExecutorError(2);
        if (riskEngine_.code.length == 0) revert ExecutorError(3);
        if (vault_.code.length == 0) revert ExecutorError(4);
        if (feeDistributor_.code.length == 0) revert ExecutorError(5);
        if (quoter_.code.length == 0) revert ExecutorError(7);
        if (swapModule_.code.length == 0) revert ExecutorError(51);
        if (accountFactory_.code.length == 0) revert ExecutorError(53);
        __ReentrancyGuard_init();

        config = IsolatedMarginConfigUpgradeable(config_);
        riskEngine = IsolatedMarginRiskEngineUpgradeable(riskEngine_);
        vault = IsolatedMarginVaultUpgradeable(vault_);
        feeDistributor = MarginFeeDistributorUpgradeable(feeDistributor_);
        quoter = IsolatedMarginQuoter(quoter_);
        swapModule = IsolatedMarginSwapModule(swapModule_);
        accountFactory = IsolatedMarginAccountFactory(accountFactory_);
        nextPositionId = 1;
    }

    function openPosition(OpenParams calldata params) external nonReentrant returns (uint256 positionId) {
        if (config.opensPaused()) revert ExecutorError(8);
        if (params.marginPTokenAmount == 0) revert ExecutorError(9);
        if (params.leverageX100 <= LEVERAGE_SCALE) revert ExecutorError(10);
        if (params.minPositionUnderlying == 0) revert ExecutorError(11);

        IsolatedMarginTypes.PairRiskConfig memory pairRisk =
            config.getPairRisk(params.marginPToken, params.positionPToken, params.debtPToken);
        if (!pairRisk.enabled) revert ExecutorError(12);
        if (params.leverageX100 > pairRisk.maxLeverageX100) revert ExecutorError(13);

        address marginAsset = _asset(params.marginPToken);
        address positionAsset = _asset(params.positionPToken);
        address debtAsset = _asset(params.debtPToken);
        if (positionAsset == debtAsset) revert ExecutorError(14);
        if (params.side == IsolatedMarginTypes.Side.LONG) {
            if (marginAsset != debtAsset) revert ExecutorError(15);
        } else {
            if (marginAsset != positionAsset) revert ExecutorError(16);
        }

        PErc20(params.marginPToken).exchangeRateCurrent();
        uint256 marginValueUsd = riskEngine.pTokenValueUsd(params.marginPToken, params.marginPTokenAmount);
        uint256 requestedNotionalUsd = Math.mulDiv(marginValueUsd, params.leverageX100, LEVERAGE_SCALE);
        uint256 openingFeePToken = quoter.feePToken(
            params.marginPToken, Math.mulDiv(requestedNotionalUsd, config.openFeeBps(), BPS, Math.Rounding.Ceil)
        );
        if (openingFeePToken > params.maxOpeningFeePToken) revert ExecutorError(17);

        positionId = nextPositionId++;
        address account = accountFactory.createAccount(
            address(riskEngine), msg.sender, positionId, params.marginPToken, params.positionPToken, params.debtPToken
        );
        riskEngine.registerAccount(
            positionId, account, msg.sender, params.marginPToken, params.positionPToken, params.debtPToken, params.side
        );

        vault.lockForPosition(
            positionId, msg.sender, account, params.marginPToken, params.marginPTokenAmount, openingFeePToken
        );

        uint256 marginUnderlying = IsolatedMarginAccount(account).redeem(params.marginPToken, params.marginPTokenAmount);
        IsolatedMarginAccount(account).transferToken(marginAsset, address(this), marginUnderlying);

        uint256 flashAmount = quoter.flashAmountForLeverage(
            debtAsset, riskEngine.underlyingValueUsd(params.marginPToken, marginUnderlying), params.leverageX100
        );
        if (flashAmount == 0) revert ExecutorError(18);

        Operation operation = params.side == IsolatedMarginTypes.Side.LONG ? Operation.OPEN_LONG : Operation.OPEN_SHORT;
        uint256 minSwapOutput = params.minPositionUnderlying;
        if (operation == Operation.OPEN_SHORT) {
            minSwapOutput =
                params.minPositionUnderlying > marginUnderlying ? params.minPositionUnderlying - marginUnderlying : 0;
        }
        _pending = PendingFlash({
            operation: operation,
            positionId: positionId,
            account: account,
            marginPToken: params.marginPToken,
            positionPToken: params.positionPToken,
            debtPToken: params.debtPToken,
            marginUnderlying: marginUnderlying,
            positionPTokensToRedeem: 0,
            flashAmount: flashAmount,
            minOutputAmount: minSwapOutput,
            closingFeePToken: 0,
            resultPTokenAmount: 0,
            borrowedAmount: 0,
            dataHash: keccak256(params.swapData),
            fullClose: false,
            active: true
        });

        IERC3156FlashLender lender = _lender();
        if (!lender.flashLoan(IERC3156FlashBorrower(address(this)), debtAsset, flashAmount, params.swapData)) {
            revert ExecutorError(19);
        }
        if (_pending.active) revert ExecutorError(52);
        IERC20(debtAsset).forceApprove(address(lender), 0);

        uint256 borrowedAmount = _pending.borrowedAmount;
        delete _pending;
        riskEngine.activateAccount(account);
        IsolatedMarginTypes.AccountMetrics memory metrics = riskEngine.getMetrics(account);

        positions[positionId] = IsolatedMarginTypes.Position({
            id: positionId,
            owner: msg.sender,
            account: account,
            marginPToken: params.marginPToken,
            positionPToken: params.positionPToken,
            debtPToken: params.debtPToken,
            lockedMarginPTokens: params.marginPTokenAmount,
            initialNotionalUsd: metrics.grossAssetValueUsd,
            borrowedPrincipal: borrowedAmount,
            requestedLeverageX100: params.leverageX100,
            side: params.side,
            status: IsolatedMarginTypes.Status.ACTIVE
        });
        emit PositionOpened(
            positionId,
            msg.sender,
            account,
            params.side,
            params.marginPToken,
            params.positionPToken,
            params.debtPToken,
            params.marginPTokenAmount,
            borrowedAmount,
            metrics.grossAssetValueUsd,
            metrics.leverageX100,
            metrics.healthFactorBps
        );
    }

    function addCollateral(uint256 positionId, uint256 marginPTokenAmount) external nonReentrant {
        IsolatedMarginTypes.Position storage position = _activeOwnedPosition(positionId);
        if (marginPTokenAmount == 0) revert ExecutorError(20);
        vault.addToPosition(positionId, marginPTokenAmount);
        position.lockedMarginPTokens += marginPTokenAmount;
        IsolatedMarginTypes.AccountMetrics memory metrics = riskEngine.getMetrics(position.account);
        emit CollateralAdded(positionId, marginPTokenAmount, metrics.healthFactorBps);
    }

    function repayWithUnderlying(uint256 positionId, uint256 maxUnderlyingAmount)
        external
        nonReentrant
        returns (uint256 repaidAmount)
    {
        IsolatedMarginTypes.Position storage position = _activeOwnedPosition(positionId);
        if (maxUnderlyingAmount == 0) revert ExecutorError(21);
        uint256 debt = PErc20(position.debtPToken).borrowBalanceCurrent(position.account);
        repaidAmount = maxUnderlyingAmount < debt ? maxUnderlyingAmount : debt;
        if (repaidAmount == 0) revert ExecutorError(22);

        address debtAsset = _asset(position.debtPToken);
        IERC20(debtAsset).safeTransferFrom(msg.sender, position.account, repaidAmount);
        IsolatedMarginAccount(position.account).repayBorrow(repaidAmount);
        uint256 remainingDebt = PErc20(position.debtPToken).borrowBalanceStored(position.account);
        position.borrowedPrincipal = remainingDebt;
        emit DebtRepaid(positionId, repaidAmount, remainingDebt);
    }

    function repayWithPToken(uint256 positionId, uint256 debtPTokenAmount)
        external
        nonReentrant
        returns (uint256 repaidAmount)
    {
        IsolatedMarginTypes.Position storage position = _activeOwnedPosition(positionId);
        if (debtPTokenAmount == 0) revert ExecutorError(23);

        IERC20(position.debtPToken).safeTransferFrom(msg.sender, position.account, debtPTokenAmount);
        riskEngine.authorizeMovement(position.account, position.debtPToken, debtPTokenAmount);
        uint256 underlyingReceived =
            IsolatedMarginAccount(position.account).redeem(position.debtPToken, debtPTokenAmount);

        uint256 debt = PErc20(position.debtPToken).borrowBalanceCurrent(position.account);
        repaidAmount = underlyingReceived < debt ? underlyingReceived : debt;
        if (repaidAmount > 0) IsolatedMarginAccount(position.account).repayBorrow(repaidAmount);

        uint256 remainder = underlyingReceived - repaidAmount;
        if (remainder > 0) {
            uint256 reminted = IsolatedMarginAccount(position.account).mint(position.debtPToken, remainder);
            riskEngine.authorizeMovement(position.account, position.debtPToken, reminted);
            IsolatedMarginAccount(position.account).transferToken(position.debtPToken, msg.sender, reminted);
        }

        uint256 remainingDebt = PErc20(position.debtPToken).borrowBalanceStored(position.account);
        position.borrowedPrincipal = remainingDebt;
        emit DebtRepaid(positionId, repaidAmount, remainingDebt);
    }

    function closePosition(CloseParams calldata params) external nonReentrant returns (uint256 returnedMarginPTokens) {
        IsolatedMarginTypes.Position storage position = _activeOwnedPosition(params.positionId);
        if (params.closeBps == 0 || params.closeBps > BPS) revert ExecutorError(24);

        PErc20(position.positionPToken).exchangeRateCurrent();
        if (position.marginPToken != position.positionPToken) {
            PErc20(position.marginPToken).exchangeRateCurrent();
        }
        uint256 previousHealthFactorBps = riskEngine.beginClose(position.account);
        IsolatedMarginTypes.AccountMetrics memory preMetrics = riskEngine.getMetrics(position.account);
        uint256 closedNotionalUsd = Math.mulDiv(preMetrics.grossAssetValueUsd, params.closeBps, BPS);
        uint256 closingFeePToken = quoter.feePToken(
            position.marginPToken, Math.mulDiv(closedNotionalUsd, config.closeFeeBps(), BPS, Math.Rounding.Ceil)
        );
        if (closingFeePToken > params.maxClosingFeePToken) revert ExecutorError(25);

        uint256 currentDebt = PErc20(position.debtPToken).borrowBalanceCurrent(position.account);
        uint256 debtToRepay =
            params.closeBps == BPS ? currentDebt : Math.mulDiv(currentDebt, params.closeBps, BPS, Math.Rounding.Ceil);
        uint256 positionPTokenBalance = PErc20(position.positionPToken).balanceOf(position.account);
        uint256 positionPTokensToRedeem =
            params.closeBps == BPS ? positionPTokenBalance : Math.mulDiv(positionPTokenBalance, params.closeBps, BPS);
        if (positionPTokensToRedeem == 0) revert ExecutorError(26);

        uint256 lockedReduction = params.closeBps == BPS
            ? position.lockedMarginPTokens
            : Math.mulDiv(position.lockedMarginPTokens, params.closeBps, BPS);
        if (lockedReduction == 0) revert ExecutorError(27);

        if (debtToRepay == 0) {
            (returnedMarginPTokens, closingFeePToken) =
                _closeWithoutDebt(position, params, positionPTokensToRedeem, closingFeePToken);
        } else {
            bytes memory callbackData = abi.encode(
                params.minDebtUnderlying,
                params.minMarginUnderlying,
                params.positionToDebtSwapData,
                params.debtToMarginSwapData
            );
            _pending = PendingFlash({
                operation: Operation.CLOSE,
                positionId: params.positionId,
                account: position.account,
                marginPToken: position.marginPToken,
                positionPToken: position.positionPToken,
                debtPToken: position.debtPToken,
                marginUnderlying: 0,
                positionPTokensToRedeem: positionPTokensToRedeem,
                flashAmount: debtToRepay,
                minOutputAmount: 0,
                closingFeePToken: closingFeePToken,
                resultPTokenAmount: 0,
                borrowedAmount: 0,
                dataHash: keccak256(callbackData),
                fullClose: params.closeBps == BPS,
                active: true
            });

            address debtAsset = _asset(position.debtPToken);
            IERC3156FlashLender lender = _lender();
            if (!lender.flashLoan(IERC3156FlashBorrower(address(this)), debtAsset, debtToRepay, callbackData)) {
                revert ExecutorError(28);
            }
            if (_pending.active) revert ExecutorError(52);
            IERC20(debtAsset).forceApprove(address(lender), 0);
            returnedMarginPTokens = _pending.resultPTokenAmount;
            closingFeePToken = _pending.closingFeePToken;
            delete _pending;
        }

        if (returnedMarginPTokens > 0) {
            riskEngine.authorizeMovement(position.account, position.marginPToken, returnedMarginPTokens);
            IsolatedMarginAccount(position.account)
                .approveToken(position.marginPToken, address(vault), returnedMarginPTokens);
        }
        vault.releaseFromPosition(params.positionId, lockedReduction, returnedMarginPTokens);
        if (returnedMarginPTokens > 0) {
            IsolatedMarginAccount(position.account).approveToken(position.marginPToken, address(vault), 0);
        }

        bool fullyClosed = params.closeBps == BPS;
        IsolatedMarginTypes.AccountMetrics memory postMetrics =
            riskEngine.finishClose(position.account, previousHealthFactorBps, fullyClosed);
        position.lockedMarginPTokens -= lockedReduction;
        position.borrowedPrincipal = PErc20(position.debtPToken).borrowBalanceStored(position.account);
        if (fullyClosed) position.status = IsolatedMarginTypes.Status.CLOSED;

        emit PositionClosed(
            params.positionId,
            params.closeBps,
            debtToRepay,
            returnedMarginPTokens,
            closingFeePToken,
            postMetrics.healthFactorBps,
            fullyClosed
        );
    }

    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        override
        returns (bytes32)
    {
        PendingFlash memory pending = _pending;
        if (!pending.active) revert ExecutorError(29);
        if (initiator != address(this)) revert ExecutorError(30);
        if (msg.sender != address(_lender())) revert ExecutorError(31);
        if (token != _asset(pending.debtPToken)) revert ExecutorError(32);
        if (amount != pending.flashAmount) revert ExecutorError(33);
        if (keccak256(data) != pending.dataHash) revert ExecutorError(34);
        _pending.active = false;

        if (pending.operation == Operation.OPEN_LONG || pending.operation == Operation.OPEN_SHORT) {
            _executeOpenFlash(pending, amount, fee, data);
        } else if (pending.operation == Operation.CLOSE) {
            _executeCloseFlash(pending, amount, fee, data);
        } else {
            revert ExecutorError(35);
        }
        return FLASH_CALLBACK_SUCCESS;
    }

    function recordLiquidation(uint256 positionId, uint256 lockedReduction, bool fullyLiquidated) external {
        if (msg.sender != riskEngine.liquidator()) revert ExecutorError(48);
        IsolatedMarginTypes.Position storage position = positions[positionId];
        if (position.status != IsolatedMarginTypes.Status.ACTIVE) revert ExecutorError(47);
        if (lockedReduction == 0 || lockedReduction > position.lockedMarginPTokens) revert ExecutorError(49);
        if (fullyLiquidated && lockedReduction != position.lockedMarginPTokens) revert ExecutorError(50);

        position.lockedMarginPTokens -= lockedReduction;
        position.borrowedPrincipal = PErc20(position.debtPToken).borrowBalanceStored(position.account);
        if (fullyLiquidated) position.status = IsolatedMarginTypes.Status.LIQUIDATED;
    }

    function _executeOpenFlash(PendingFlash memory pending, uint256 amount, uint256 fee, bytes calldata data) internal {
        address marginAsset = _asset(pending.marginPToken);
        address positionAsset = _asset(pending.positionPToken);
        address debtAsset = _asset(pending.debtPToken);
        IsolatedMarginTypes.PairRiskConfig memory pairRisk = _pairRisk(pending);

        uint256 positionUnderlying;
        if (pending.operation == Operation.OPEN_LONG) {
            positionUnderlying = _swap(
                debtAsset, positionAsset, pending.marginUnderlying + amount, pending.minOutputAmount, data, pairRisk
            );
        } else {
            uint256 quoteFromShort = _swap(debtAsset, marginAsset, amount, pending.minOutputAmount, data, pairRisk);
            positionUnderlying = pending.marginUnderlying + quoteFromShort;
        }

        // The caller's minimum is checked by the adapter and protocol bound. The explicit
        // minimum is embedded in adapter data, while final margin validation remains authoritative.
        IERC20(positionAsset).safeTransfer(pending.account, positionUnderlying);
        uint256 minted = IsolatedMarginAccount(pending.account).mint(pending.positionPToken, positionUnderlying);
        if (minted == 0) revert ExecutorError(36);

        uint256 totalDebt = amount + fee;
        IsolatedMarginAccount(pending.account).borrow(totalDebt);
        IsolatedMarginAccount(pending.account).transferToken(debtAsset, address(this), totalDebt);
        IERC20(debtAsset).forceApprove(msg.sender, totalDebt);

        _pending.resultPTokenAmount = minted;
        _pending.borrowedAmount = totalDebt;
    }

    function _executeCloseFlash(PendingFlash memory pending, uint256 amount, uint256 fee, bytes calldata data)
        internal
    {
        (
            uint256 minDebtUnderlying,
            uint256 minMarginUnderlying,
            bytes memory positionToDebtSwapData,
            bytes memory debtToMarginSwapData
        ) = abi.decode(data, (uint256, uint256, bytes, bytes));

        address marginAsset = _asset(pending.marginPToken);
        address positionAsset = _asset(pending.positionPToken);
        address debtAsset = _asset(pending.debtPToken);
        IsolatedMarginTypes.PairRiskConfig memory pairRisk = _pairRisk(pending);

        IERC20(debtAsset).safeTransfer(pending.account, amount);
        IsolatedMarginAccount(pending.account).repayBorrow(amount);

        riskEngine.authorizeMovement(pending.account, pending.positionPToken, pending.positionPTokensToRedeem);
        uint256 positionUnderlying =
            IsolatedMarginAccount(pending.account).redeem(pending.positionPToken, pending.positionPTokensToRedeem);
        IsolatedMarginAccount(pending.account).transferToken(positionAsset, address(this), positionUnderlying);

        uint256 debtUnderlying = positionAsset == debtAsset
            ? positionUnderlying
            : _swap(positionAsset, debtAsset, positionUnderlying, minDebtUnderlying, positionToDebtSwapData, pairRisk);
        uint256 totalFlashRepayment = amount + fee;
        if (debtUnderlying < totalFlashRepayment) revert ExecutorError(37);

        uint256 residualDebtUnderlying = debtUnderlying - totalFlashRepayment;
        uint256 marginUnderlying;
        if (residualDebtUnderlying > 0) {
            marginUnderlying = debtAsset == marginAsset
                ? residualDebtUnderlying
                : _swap(
                    debtAsset, marginAsset, residualDebtUnderlying, minMarginUnderlying, debtToMarginSwapData, pairRisk
                );
        }

        uint256 mintedMarginPTokens;
        if (marginUnderlying > 0) {
            IERC20(marginAsset).safeTransfer(pending.account, marginUnderlying);
            mintedMarginPTokens = IsolatedMarginAccount(pending.account).mint(pending.marginPToken, marginUnderlying);
        }

        uint256 availableForReturn =
            pending.fullClose ? PErc20(pending.marginPToken).balanceOf(pending.account) : mintedMarginPTokens;
        uint256 actualClosingFee =
            pending.closingFeePToken < availableForReturn ? pending.closingFeePToken : availableForReturn;
        if (actualClosingFee > 0) _collectPositionFee(pending.account, pending.marginPToken, actualClosingFee);

        _pending.closingFeePToken = actualClosingFee;
        _pending.resultPTokenAmount = availableForReturn - actualClosingFee;
        IERC20(debtAsset).forceApprove(msg.sender, totalFlashRepayment);
    }

    function _closeWithoutDebt(
        IsolatedMarginTypes.Position storage position,
        CloseParams calldata params,
        uint256 positionPTokensToRedeem,
        uint256 closingFeePToken
    ) internal returns (uint256 returnedMarginPTokens, uint256 actualClosingFee) {
        IsolatedMarginTypes.PairRiskConfig memory pairRisk = config.getPairRisk(
            position.marginPToken, position.positionPToken, position.debtPToken
        );
        address positionAsset = _asset(position.positionPToken);
        address marginAsset = _asset(position.marginPToken);

        riskEngine.authorizeMovement(position.account, position.positionPToken, positionPTokensToRedeem);
        uint256 positionUnderlying =
            IsolatedMarginAccount(position.account).redeem(position.positionPToken, positionPTokensToRedeem);
        IsolatedMarginAccount(position.account).transferToken(positionAsset, address(this), positionUnderlying);
        uint256 marginUnderlying = positionAsset == marginAsset
            ? positionUnderlying
            : _swap(
                positionAsset,
                marginAsset,
                positionUnderlying,
                params.minMarginUnderlying,
                params.positionToDebtSwapData,
                pairRisk
            );
        IERC20(marginAsset).safeTransfer(position.account, marginUnderlying);
        uint256 mintedMarginPTokens =
            IsolatedMarginAccount(position.account).mint(position.marginPToken, marginUnderlying);

        uint256 availableForReturn =
            params.closeBps == BPS ? PErc20(position.marginPToken).balanceOf(position.account) : mintedMarginPTokens;
        actualClosingFee = closingFeePToken < availableForReturn ? closingFeePToken : availableForReturn;
        if (actualClosingFee > 0) _collectPositionFee(position.account, position.marginPToken, actualClosingFee);
        returnedMarginPTokens = availableForReturn - actualClosingFee;
    }

    function _collectPositionFee(address account, address pToken, uint256 feeAmount) internal {
        riskEngine.authorizeMovement(account, pToken, feeAmount);
        IsolatedMarginAccount(account).approveToken(pToken, address(feeDistributor), feeAmount);
        feeDistributor.collectFee(pToken, account, feeAmount);
        IsolatedMarginAccount(account).approveToken(pToken, address(feeDistributor), 0);
    }

    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes memory swapData,
        IsolatedMarginTypes.PairRiskConfig memory pairRisk
    ) internal returns (uint256 amountOut) {
        IERC20(tokenIn).forceApprove(address(swapModule), amountIn);
        amountOut = swapModule.executeSwap(
            tokenIn, tokenOut, amountIn, minAmountOut, pairRisk.maxSlippageBps, pairRisk.oracleDeviationBps, swapData
        );
        IERC20(tokenIn).forceApprove(address(swapModule), 0);
    }

    function _asset(address pToken) internal view returns (address asset) {
        return quoter.assetForMarket(pToken);
    }

    function _pairRisk(PendingFlash memory pending) internal view returns (IsolatedMarginTypes.PairRiskConfig memory) {
        return config.getPairRisk(pending.marginPToken, pending.positionPToken, pending.debtPToken);
    }

    function _lender() internal view returns (IERC3156FlashLender) {
        address lender = config.flashLoanProvider();
        if (lender.code.length == 0) revert ExecutorError(45);
        return IERC3156FlashLender(lender);
    }

    function _activeOwnedPosition(uint256 positionId)
        internal
        view
        returns (IsolatedMarginTypes.Position storage position)
    {
        position = positions[positionId];
        if (position.owner != msg.sender) revert ExecutorError(46);
        if (position.status != IsolatedMarginTypes.Status.ACTIVE) revert ExecutorError(47);
    }

    uint256[40] private __gap;
}

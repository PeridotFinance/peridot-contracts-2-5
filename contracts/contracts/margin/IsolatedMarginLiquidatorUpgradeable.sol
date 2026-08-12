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
import {IsolatedMarginQuoter} from "./IsolatedMarginQuoter.sol";
import {IsolatedMarginRiskEngineUpgradeable} from "./IsolatedMarginRiskEngineUpgradeable.sol";
import {IsolatedMarginSwapModule} from "./IsolatedMarginSwapModule.sol";
import {IsolatedMarginTypes} from "./IsolatedMarginTypes.sol";
import {IsolatedMarginVaultUpgradeable} from "./IsolatedMarginVaultUpgradeable.sol";
import {MarginInsuranceFundUpgradeable} from "./MarginInsuranceFundUpgradeable.sol";
import {IIsolatedMarginConfig} from "./interfaces/IIsolatedMarginConfig.sol";

interface IIsolatedMarginPositionRegistry {
    function positions(uint256 positionId)
        external
        view
        returns (
            uint256 id,
            address owner,
            address account,
            address marginPToken,
            address positionPToken,
            address debtPToken,
            uint256 lockedMarginPTokens,
            uint256 initialNotionalUsd,
            uint256 borrowedPrincipal,
            uint16 requestedLeverageX100,
            IsolatedMarginTypes.Side side,
            IsolatedMarginTypes.Status status
        );

    function recordLiquidation(uint256 positionId, uint256 lockedReduction, bool fullyLiquidated) external;
}

/**
 * @notice Dedicated flash-liquidation path for isolated margin positions.
 * @dev It never uses the lending controller's collateral-factor liquidation math.
 */
contract IsolatedMarginLiquidatorUpgradeable is Initializable, ReentrancyGuardUpgradeable, IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    bytes32 private constant FLASH_CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    error LiquidationError(uint8 code);

    struct LiquidationParams {
        uint256 positionId;
        address recipient;
        uint256 minDebtUnderlying;
        uint256 minMarginUnderlying;
        bytes collateralToDebtSwapData;
        bytes debtToMarginSwapData;
    }

    struct PendingLiquidation {
        uint256 positionId;
        address caller;
        address recipient;
        address account;
        address marginPToken;
        address positionPToken;
        address debtPToken;
        uint256 repayAmount;
        uint256 collateralPTokens;
        uint256 lockedReduction;
        uint256 baseDebtBalance;
        uint256 returnedMarginPTokens;
        uint256 rewardUnderlying;
        bytes32 dataHash;
        bool fullyLiquidated;
        bool active;
    }

    IIsolatedMarginPositionRegistry public executor;
    IIsolatedMarginConfig public config;
    IsolatedMarginRiskEngineUpgradeable public riskEngine;
    IsolatedMarginVaultUpgradeable public vault;
    MarginInsuranceFundUpgradeable public insuranceFund;
    IsolatedMarginQuoter public quoter;
    IsolatedMarginSwapModule public swapModule;

    PendingLiquidation private _pending;

    event PositionLiquidated(
        uint256 indexed positionId,
        address indexed caller,
        address indexed recipient,
        uint256 debtRepaid,
        uint256 collateralPTokensRedeemed,
        uint256 lockedMarginReduction,
        uint256 returnedMarginPTokens,
        uint256 liquidatorReward,
        bool fullyLiquidated
    );

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address executor_,
        address config_,
        address riskEngine_,
        address vault_,
        address insuranceFund_,
        address quoter_,
        address swapModule_
    ) external initializer {
        if (executor_.code.length == 0) revert LiquidationError(1);
        if (config_.code.length == 0) revert LiquidationError(2);
        if (riskEngine_.code.length == 0) revert LiquidationError(3);
        if (vault_.code.length == 0) revert LiquidationError(4);
        if (insuranceFund_.code.length == 0) revert LiquidationError(5);
        if (quoter_.code.length == 0) revert LiquidationError(6);
        if (swapModule_.code.length == 0) revert LiquidationError(7);
        __ReentrancyGuard_init();
        executor = IIsolatedMarginPositionRegistry(executor_);
        config = IIsolatedMarginConfig(config_);
        riskEngine = IsolatedMarginRiskEngineUpgradeable(riskEngine_);
        vault = IsolatedMarginVaultUpgradeable(vault_);
        insuranceFund = MarginInsuranceFundUpgradeable(insuranceFund_);
        quoter = IsolatedMarginQuoter(quoter_);
        swapModule = IsolatedMarginSwapModule(swapModule_);
    }

    function liquidate(LiquidationParams calldata params) external nonReentrant {
        IsolatedMarginTypes.Position memory position = _getPosition(params.positionId);
        if (position.status != IsolatedMarginTypes.Status.ACTIVE) revert LiquidationError(8);
        if (params.recipient == address(0)) revert LiquidationError(9);

        PErc20(position.positionPToken).exchangeRateCurrent();
        if (position.marginPToken != position.positionPToken) {
            PErc20(position.marginPToken).exchangeRateCurrent();
        }
        uint256 currentDebt = PErc20(position.debtPToken).borrowBalanceCurrent(position.account);
        if (currentDebt == 0) revert LiquidationError(10);
        (uint256 maxRepayAmount, uint256 previousHealthFactorBps) = riskEngine.beginLiquidation(position.account);
        if (maxRepayAmount == 0 || maxRepayAmount > currentDebt) revert LiquidationError(11);

        bool fullyLiquidated = maxRepayAmount == currentDebt;
        uint256 positionBalance = PErc20(position.positionPToken).balanceOf(position.account);
        if (positionBalance == 0) revert LiquidationError(12);

        IsolatedMarginTypes.PairRiskConfig memory pairRisk =
            config.getPairRisk(position.marginPToken, position.positionPToken, position.debtPToken);
        uint256 collateralPTokens = positionBalance;
        uint256 lockedReduction = position.lockedMarginPTokens;
        if (!fullyLiquidated) {
            uint256 repayValueUsd = riskEngine.underlyingValueUsd(position.debtPToken, maxRepayAmount);
            uint256 seizeValueUsd = Math.mulDiv(repayValueUsd, BPS + pairRisk.liquidationBonusBps, BPS);
            collateralPTokens = quoter.feePToken(position.positionPToken, seizeValueUsd);
            if (collateralPTokens > positionBalance) collateralPTokens = positionBalance;
            lockedReduction =
                Math.mulDiv(position.lockedMarginPTokens, collateralPTokens, positionBalance, Math.Rounding.Ceil);
            if (lockedReduction == 0 || lockedReduction >= position.lockedMarginPTokens) {
                revert LiquidationError(13);
            }
        }

        bytes memory callbackData = abi.encode(
            params.minDebtUnderlying,
            params.minMarginUnderlying,
            params.collateralToDebtSwapData,
            params.debtToMarginSwapData
        );
        address debtAsset = quoter.assetForMarket(position.debtPToken);
        _pending = PendingLiquidation({
            positionId: params.positionId,
            caller: msg.sender,
            recipient: params.recipient,
            account: position.account,
            marginPToken: position.marginPToken,
            positionPToken: position.positionPToken,
            debtPToken: position.debtPToken,
            repayAmount: maxRepayAmount,
            collateralPTokens: collateralPTokens,
            lockedReduction: lockedReduction,
            baseDebtBalance: IERC20(debtAsset).balanceOf(address(this)),
            returnedMarginPTokens: 0,
            rewardUnderlying: 0,
            dataHash: keccak256(callbackData),
            fullyLiquidated: fullyLiquidated,
            active: true
        });

        IERC3156FlashLender lender = quoter.flashLender();
        if (!lender.flashLoan(IERC3156FlashBorrower(address(this)), debtAsset, maxRepayAmount, callbackData)) {
            revert LiquidationError(14);
        }
        if (_pending.active) revert LiquidationError(25);
        IERC20(debtAsset).forceApprove(address(lender), 0);

        PendingLiquidation memory completed = _pending;
        riskEngine.finishLiquidation(position.account, fullyLiquidated, previousHealthFactorBps);

        if (completed.returnedMarginPTokens > 0) {
            IERC20(position.marginPToken).forceApprove(address(vault), completed.returnedMarginPTokens);
        }
        vault.releaseFromLiquidation(params.positionId, completed.lockedReduction, completed.returnedMarginPTokens);
        if (completed.returnedMarginPTokens > 0) IERC20(position.marginPToken).forceApprove(address(vault), 0);
        executor.recordLiquidation(params.positionId, completed.lockedReduction, fullyLiquidated);

        if (completed.rewardUnderlying > 0) {
            IERC20(debtAsset).safeTransfer(completed.recipient, completed.rewardUnderlying);
        }
        delete _pending;

        emit PositionLiquidated(
            params.positionId,
            completed.caller,
            completed.recipient,
            maxRepayAmount,
            completed.collateralPTokens,
            completed.lockedReduction,
            completed.returnedMarginPTokens,
            completed.rewardUnderlying,
            fullyLiquidated
        );
    }

    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        override
        returns (bytes32)
    {
        PendingLiquidation memory pending = _pending;
        if (!pending.active) revert LiquidationError(15);
        if (initiator != address(this)) revert LiquidationError(16);
        if (msg.sender != address(quoter.flashLender())) revert LiquidationError(17);
        if (token != quoter.assetForMarket(pending.debtPToken)) revert LiquidationError(18);
        if (amount != pending.repayAmount) revert LiquidationError(19);
        if (keccak256(data) != pending.dataHash) revert LiquidationError(20);
        _pending.active = false;

        (
            uint256 minDebtUnderlying,
            uint256 minMarginUnderlying,
            bytes memory collateralToDebtSwapData,
            bytes memory debtToMarginSwapData
        ) = abi.decode(data, (uint256, uint256, bytes, bytes));

        IERC20(token).forceApprove(pending.debtPToken, amount);
        if (PErc20(pending.debtPToken).repayBorrowBehalf(pending.account, amount) != 0) {
            revert LiquidationError(21);
        }
        IERC20(token).forceApprove(pending.debtPToken, 0);

        uint256 positionUnderlying =
            _redeemAccountCollateral(pending.account, pending.positionPToken, pending.collateralPTokens);
        IsolatedMarginTypes.PairRiskConfig memory pairRisk =
            config.getPairRisk(pending.marginPToken, pending.positionPToken, pending.debtPToken);
        address positionAsset = quoter.assetForMarket(pending.positionPToken);
        uint256 debtProceeds = positionAsset == token
            ? positionUnderlying
            : _swap(positionAsset, token, positionUnderlying, minDebtUnderlying, pairRisk, collateralToDebtSwapData);

        if (pending.fullyLiquidated && pending.marginPToken != pending.positionPToken) {
            uint256 marginBalance = PErc20(pending.marginPToken).balanceOf(pending.account);
            if (marginBalance > 0) {
                uint256 marginUnderlying =
                    _redeemAccountCollateral(pending.account, pending.marginPToken, marginBalance);
                address marginAsset = quoter.assetForMarket(pending.marginPToken);
                debtProceeds += marginAsset == token
                    ? marginUnderlying
                    : _swap(marginAsset, token, marginUnderlying, 0, pairRisk, collateralToDebtSwapData);
            }
        }

        uint256 totalFlashRepayment = amount + fee;
        uint256 available = IERC20(token).balanceOf(address(this)) - pending.baseDebtBalance;
        if (available < totalFlashRepayment) {
            _coverShortfall(
                pending.marginPToken, token, totalFlashRepayment - available, pairRisk, collateralToDebtSwapData
            );
            available = IERC20(token).balanceOf(address(this)) - pending.baseDebtBalance;
        }
        if (available < totalFlashRepayment) revert LiquidationError(22);

        uint256 surplus = available - totalFlashRepayment;
        uint256 rewardUnderlying = surplus;
        uint256 returnedMarginPTokens;
        if (pending.fullyLiquidated && surplus > 0) {
            uint256 repayValueUsd = quoter.underlyingValueUsd(token, amount);
            uint256 bonusValueUsd = Math.mulDiv(repayValueUsd, pairRisk.liquidationBonusBps, BPS);
            uint256 rewardCap = quoter.underlyingForUsd(token, bonusValueUsd, Math.Rounding.Floor);
            rewardUnderlying = surplus < rewardCap ? surplus : rewardCap;
            uint256 userResidual = surplus - rewardUnderlying;
            if (userResidual > 0) {
                address marginAsset = quoter.assetForMarket(pending.marginPToken);
                uint256 marginUnderlying = marginAsset == token
                    ? userResidual
                    : _swap(token, marginAsset, userResidual, minMarginUnderlying, pairRisk, debtToMarginSwapData);
                returnedMarginPTokens = _mintPToken(pending.marginPToken, marginUnderlying);
            }
        }

        _pending.rewardUnderlying = rewardUnderlying;
        _pending.returnedMarginPTokens = returnedMarginPTokens;
        IERC20(token).forceApprove(msg.sender, totalFlashRepayment);
        return FLASH_CALLBACK_SUCCESS;
    }

    function _redeemAccountCollateral(address account, address pToken, uint256 amount)
        internal
        returns (uint256 underlyingReceived)
    {
        riskEngine.authorizeMovement(account, pToken, amount);
        return IsolatedMarginAccount(account).liquidationRedeem(pToken, amount, address(this));
    }

    function _coverShortfall(
        address marginPToken,
        address debtAsset,
        uint256 shortfall,
        IsolatedMarginTypes.PairRiskConfig memory pairRisk,
        bytes memory marginToDebtSwapData
    ) internal {
        uint256 coverageValueUsd = quoter.underlyingValueUsd(debtAsset, shortfall);
        uint256 requestedPTokens = quoter.feePToken(marginPToken, coverageValueUsd);
        uint256 providedPTokens = insuranceFund.provideCoverage(marginPToken, address(this), requestedPTokens);
        if (providedPTokens == 0) return;

        address marginAsset = quoter.assetForMarket(marginPToken);
        uint256 marginUnderlying = _redeemOwnPToken(marginPToken, providedPTokens);
        if (marginAsset != debtAsset) {
            _swap(marginAsset, debtAsset, marginUnderlying, 0, pairRisk, marginToDebtSwapData);
        }
    }

    function _redeemOwnPToken(address pToken, uint256 amount) internal returns (uint256 underlyingReceived) {
        address asset = quoter.assetForMarket(pToken);
        uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
        if (PErc20(pToken).redeem(amount) != 0) revert LiquidationError(23);
        underlyingReceived = IERC20(asset).balanceOf(address(this)) - beforeBalance;
    }

    function _mintPToken(address pToken, uint256 underlyingAmount) internal returns (uint256 mintedPTokens) {
        address asset = quoter.assetForMarket(pToken);
        uint256 beforeBalance = PErc20(pToken).balanceOf(address(this));
        IERC20(asset).forceApprove(pToken, underlyingAmount);
        if (PErc20(pToken).mint(underlyingAmount) != 0) revert LiquidationError(24);
        IERC20(asset).forceApprove(pToken, 0);
        mintedPTokens = PErc20(pToken).balanceOf(address(this)) - beforeBalance;
    }

    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        IsolatedMarginTypes.PairRiskConfig memory pairRisk,
        bytes memory swapData
    ) internal returns (uint256 amountOut) {
        IERC20(tokenIn).forceApprove(address(swapModule), amountIn);
        amountOut = swapModule.executeSwap(
            tokenIn, tokenOut, amountIn, minAmountOut, pairRisk.maxSlippageBps, pairRisk.oracleDeviationBps, swapData
        );
        IERC20(tokenIn).forceApprove(address(swapModule), 0);
    }

    function _getPosition(uint256 positionId) internal view returns (IsolatedMarginTypes.Position memory position) {
        (
            position.id,
            position.owner,
            position.account,
            position.marginPToken,
            position.positionPToken,
            position.debtPToken,
            position.lockedMarginPTokens,
            position.initialNotionalUsd,
            position.borrowedPrincipal,
            position.requestedLeverageX100,
            position.side,
            position.status
        ) = executor.positions(positionId);
    }

    uint256[40] private __gap;
}

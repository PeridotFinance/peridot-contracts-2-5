// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC3156FlashBorrower, IERC3156FlashLender} from "../PTokenInterfaces.sol";
import {PErc20} from "../PErc20.sol";
import {IsolatedMarginAccount} from "./IsolatedMarginAccount.sol";
import {IsolatedMarginMath} from "./IsolatedMarginMath.sol";
import {IsolatedMarginQuoter} from "./IsolatedMarginQuoter.sol";
import {IsolatedMarginRiskEngineUpgradeable} from "./IsolatedMarginRiskEngineUpgradeable.sol";
import {IsolatedMarginSwapModule} from "./IsolatedMarginSwapModule.sol";
import {IsolatedMarginTypes} from "./IsolatedMarginTypes.sol";
import {IsolatedMarginVaultUpgradeable} from "./IsolatedMarginVaultUpgradeable.sol";
import {MarginInsuranceFundUpgradeable} from "./MarginInsuranceFundUpgradeable.sol";
import {IIsolatedMarginConfig} from "./interfaces/IIsolatedMarginConfig.sol";
import {IMarginPriceOracle} from "./interfaces/IMarginPriceOracle.sol";

/// @dev Allowlist of funded in-kind liquidators, kept in the (owner + timelock) config contract.
interface IFundedLiquidatorRegistry {
    function fundedLiquidators(address liquidator) external view returns (bool);
}

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

    /// @dev Funded in-kind fallback (handoff 00 s10). The caller pays the ACTUAL debt asset and receives position
    ///      pTokens in kind; it names no price and no seize amount. The max/min fields are only the caller's protection.
    struct FundedLiquidationParams {
        uint256 positionId;
        address recipient; // receives the seized pTokens
        uint256 maxRepayUnderlying; // spend cap on the debt asset (risk engine decides the real repay amount)
        uint256 minPositionPTokens; // minimum seized position pTokens
        uint256 minMarginPTokens; // minimum seized margin pTokens (only nonzero when margin != position pToken)
        uint256 minSeizeValueBps; // minimum seized value / repaid value in bps (10_000 = break-even; 0 = no floor)
    }

    struct FundedPlan {
        uint256 repay;
        uint256 previousHealthFactorBps;
        uint256 repayUsd; // value of the repaid debt (floored)
        uint256 capUsd; // repaid value x (1 + bonus), rounded against the liquidator
        uint256 positionSeized;
        uint256 marginSeized;
        uint256 positionLeft; // full liquidation: position pTokens (non-margin asset) returned to the owner
        uint256 marginLeft; // full liquidation: margin pTokens returned through the vault release accounting
        uint256 lockedReduction;
        bool full;
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
    event FundedPositionLiquidated(
        uint256 indexed positionId,
        address indexed funder,
        address indexed recipient,
        uint256 debtRepaid,
        uint256 positionPTokensSeized,
        uint256 marginPTokensSeized,
        uint256 positionPTokensReturnedToOwner,
        uint256 marginPTokensReturnedToVault,
        uint256 lockedMarginReduction,
        bool fullyLiquidated
    );
    event InsuranceExcessReturned(address indexed pToken, uint256 underlyingAmount, uint256 pTokenAmount);
    event UnderlyingDustReturned(address indexed pToken, address indexed recipient, uint256 underlyingAmount);

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
            (uint256 seizeValueUsd,) = riskEngine.getLiquidationQuote(position.account, maxRepayAmount);
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

    /**
     * @notice Funded in-kind forced liquidation. The allowlisted caller supplies the ACTUAL debt asset; the margin
     *         account's debt is repaid and the permitted position pTokens are moved to `recipient` in ONE call.
     * @dev No flash loan, no swap, no redemption: works with zero collateral-market cash and a dead swap route.
     *      The repay amount is exactly what `riskEngine.beginFundedLiquidation` allows (partial or full; sized without the flash lender or swap slippage), prices come
     *      only from the risk engine's oracle (a zero sentinel reverts `PriceUnavailable`), seized value is
     *      capped at repaid value x (1 + pair liquidationBonusBps) with every rounding against the liquidator,
     *      and the state machine ends in `finishLiquidation` (health must improve, or debt must be zero).
     *      Anything above the bonus stays with the borrower. No insurance-fund draw: if collateral value is
     *      below the debt the funder simply absorbs the shortfall (or does not call; use the min* bounds).
     */
    function liquidateFunded(FundedLiquidationParams calldata params) external nonReentrant {
        if (!IFundedLiquidatorRegistry(address(config)).fundedLiquidators(msg.sender)) revert LiquidationError(27);
        IsolatedMarginTypes.Position memory position = _getPosition(params.positionId);
        if (position.status != IsolatedMarginTypes.Status.ACTIVE) revert LiquidationError(8);
        // The seized pTokens must not land in an isolated margin account (outside its locked-margin tracking).
        if (params.recipient == address(0) || riskEngine.isIsolatedMarginAccount(params.recipient)) {
            revert LiquidationError(9);
        }

        PErc20(position.positionPToken).exchangeRateCurrent();
        if (position.marginPToken != position.positionPToken) PErc20(position.marginPToken).exchangeRateCurrent();
        uint256 currentDebt = PErc20(position.debtPToken).borrowBalanceCurrent(position.account);
        if (currentDebt == 0) revert LiquidationError(10);

        FundedPlan memory plan;
        // First price-touching call: an unavailable price reverts here with PriceUnavailable.
        (plan.repay, plan.previousHealthFactorBps) = riskEngine.beginFundedLiquidation(position.account);
        if (plan.repay == 0 || plan.repay > currentDebt) revert LiquidationError(11);
        if (plan.repay > params.maxRepayUnderlying) revert LiquidationError(28);
        plan.full = plan.repay == currentDebt;
        _planFundedSeizure(position, plan);
        if (plan.positionSeized < params.minPositionPTokens || plan.marginSeized < params.minMarginPTokens) {
            revert LiquidationError(30);
        }
        // Funder's loss protection (for insolvent or fast-moving positions): value received vs value paid.
        if (_seizedValueUsd(position, plan) * BPS < plan.repayUsd * params.minSeizeValueBps) {
            revert LiquidationError(32);
        }

        // 1. Funds in and debt repaid (atomic with everything below; any revert unwinds the whole call).
        _pullAndRepay(position, plan.repay);

        // 2. Seizure in kind, and on full liquidation the borrower's surplus.
        address account = position.account;
        _moveFromAccount(account, position.positionPToken, plan.positionSeized, params.recipient);
        _moveFromAccount(account, position.marginPToken, plan.marginSeized, params.recipient);
        if (plan.full) {
            _moveFromAccount(account, position.positionPToken, plan.positionLeft, position.owner);
            _moveFromAccount(account, position.marginPToken, plan.marginLeft, address(this));
        }

        // 3. Same state machine as the flash path.
        riskEngine.finishLiquidation(account, plan.full, plan.previousHealthFactorBps);
        if (plan.marginLeft > 0) IERC20(position.marginPToken).forceApprove(address(vault), plan.marginLeft);
        vault.releaseFromLiquidation(params.positionId, plan.lockedReduction, plan.marginLeft);
        if (plan.marginLeft > 0) IERC20(position.marginPToken).forceApprove(address(vault), 0);
        executor.recordLiquidation(params.positionId, plan.lockedReduction, plan.full);

        emit FundedPositionLiquidated(
            params.positionId,
            msg.sender,
            params.recipient,
            plan.repay,
            plan.positionSeized,
            plan.marginSeized,
            plan.positionLeft,
            plan.marginLeft,
            plan.lockedReduction,
            plan.full
        );
    }

    /// @dev Decides how many pTokens the funder gets. Pure accounting, no state change.
    function _planFundedSeizure(IsolatedMarginTypes.Position memory position, FundedPlan memory plan) internal view {
        IsolatedMarginTypes.PairRiskConfig memory pairRisk =
            config.getPairRisk(position.marginPToken, position.positionPToken, position.debtPToken);
        // Rounding against the liquidator: repaid value floors, bonus floors.
        plan.repayUsd = riskEngine.underlyingValueUsd(position.debtPToken, plan.repay);
        plan.capUsd = plan.repayUsd + Math.mulDiv(plan.repayUsd, pairRisk.liquidationBonusBps, BPS);

        uint256 positionBalance = PErc20(position.positionPToken).balanceOf(position.account);
        if (positionBalance == 0) revert LiquidationError(12);
        uint256 capPTokens = _pTokensForUsdFloor(position.positionPToken, plan.capUsd);
        plan.positionSeized = capPTokens < positionBalance ? capPTokens : positionBalance;
        bool sameToken = position.marginPToken == position.positionPToken;

        if (!plan.full) {
            // Same proportional locked-margin release and sanity bounds as the flash path.
            plan.lockedReduction = Math.mulDiv(
                position.lockedMarginPTokens, plan.positionSeized, positionBalance, Math.Rounding.Ceil
            );
            if (plan.lockedReduction == 0 || plan.lockedReduction >= position.lockedMarginPTokens) {
                revert LiquidationError(13);
            }
        } else {
            plan.lockedReduction = position.lockedMarginPTokens;
            if (sameToken) {
                plan.marginLeft = positionBalance - plan.positionSeized;
            } else {
                uint256 marginBalance = PErc20(position.marginPToken).balanceOf(position.account);
                // Only if the whole position cannot satisfy the cap does the funder also take margin pTokens.
                if (plan.positionSeized == positionBalance) {
                    uint256 usedUsd = _valueUsdCeil(position.positionPToken, positionBalance);
                    uint256 remainingUsd = plan.capUsd > usedUsd ? plan.capUsd - usedUsd : 0;
                    uint256 marginCap = _pTokensForUsdFloor(position.marginPToken, remainingUsd);
                    plan.marginSeized = marginCap < marginBalance ? marginCap : marginBalance;
                }
                plan.positionLeft = positionBalance - plan.positionSeized;
                plan.marginLeft = marginBalance - plan.marginSeized;
            }
        }

        // Independent bound using the risk engine's own valuation helpers: seized value <= repaid x (1 + bonus).
        if (_seizedValueUsd(position, plan) > plan.capUsd) revert LiquidationError(31);
    }

    function _seizedValueUsd(IsolatedMarginTypes.Position memory position, FundedPlan memory plan)
        internal
        view
        returns (uint256 seizedUsd)
    {
        seizedUsd = riskEngine.pTokenValueUsd(position.positionPToken, plan.positionSeized);
        if (plan.marginSeized > 0) seizedUsd += riskEngine.pTokenValueUsd(position.marginPToken, plan.marginSeized);
    }

    function _pullAndRepay(IsolatedMarginTypes.Position memory position, uint256 repay) internal {
        address debtAsset = quoter.assetForMarket(position.debtPToken);
        uint256 balanceBefore = IERC20(debtAsset).balanceOf(address(this));
        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), repay);
        if (IERC20(debtAsset).balanceOf(address(this)) - balanceBefore != repay) revert LiquidationError(29);
        IERC20(debtAsset).forceApprove(position.debtPToken, repay);
        if (PErc20(position.debtPToken).repayBorrowBehalf(position.account, repay) != 0) revert LiquidationError(21);
        IERC20(debtAsset).forceApprove(position.debtPToken, 0);
    }

    function _moveFromAccount(address account, address pToken, uint256 amount, address to) internal {
        if (amount == 0) return;
        riskEngine.authorizeMovement(account, pToken, amount);
        IsolatedMarginAccount(account).liquidationTransfer(pToken, amount, to);
    }

    /// @dev Price straight from the risk engine's oracle; the zero sentinel reverts like every other margin path.
    function _priceOf(address pToken) internal view returns (address asset, uint256 priceUsd) {
        IMarginPriceOracle oracle = riskEngine.oracle();
        asset = oracle.marketAsset(pToken);
        if (asset == address(0)) revert IsolatedMarginRiskEngineUpgradeable.PriceUnavailable(asset);
        priceUsd = oracle.getPrice(asset);
        if (priceUsd == 0) revert IsolatedMarginRiskEngineUpgradeable.PriceUnavailable(asset);
    }

    function _pTokensForUsdFloor(address pToken, uint256 valueUsd) internal view returns (uint256) {
        (address asset, uint256 priceUsd) = _priceOf(pToken);
        return IsolatedMarginMath.pTokenForUsd(
            valueUsd, IERC20Metadata(asset).decimals(), priceUsd, PErc20(pToken).exchangeRateStored(), Math.Rounding.Floor
        );
    }

    function _valueUsdCeil(address pToken, uint256 amount) internal view returns (uint256) {
        (address asset, uint256 priceUsd) = _priceOf(pToken);
        uint256 underlying = Math.mulDiv(amount, PErc20(pToken).exchangeRateStored(), 1e18, Math.Rounding.Ceil);
        return Math.mulDiv(underlying, priceUsd, 10 ** uint256(IERC20Metadata(asset).decimals()), Math.Rounding.Ceil);
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
            uint256 shortfall = totalFlashRepayment - available;
            uint256 insuranceProceeds = _coverShortfall(
                pending.marginPToken, token, totalFlashRepayment - available, pairRisk, collateralToDebtSwapData
            );
            available = IERC20(token).balanceOf(address(this)) - pending.baseDebtBalance;
            if (insuranceProceeds > shortfall) {
                uint256 excessUnderlying = insuranceProceeds - shortfall;
                _returnInsuranceExcess(pending.debtPToken, excessUnderlying);
                available -= excessUnderlying;
            }
        }
        if (available < totalFlashRepayment) revert LiquidationError(22);

        uint256 surplus = available - totalFlashRepayment;
        uint256 rewardUnderlying;
        uint256 returnedMarginPTokens;
        if (surplus > 0) {
            uint256 repayValueUsd = quoter.underlyingValueUsd(token, amount);
            uint256 bonusValueUsd = Math.mulDiv(repayValueUsd, pairRisk.liquidationBonusBps, BPS, Math.Rounding.Ceil);
            uint256 rewardCap = quoter.underlyingForUsd(token, bonusValueUsd, Math.Rounding.Floor);
            rewardUnderlying = surplus < rewardCap ? surplus : rewardCap;
            uint256 userResidual = surplus - rewardUnderlying;
            if (userResidual > 0) {
                address marginAsset = quoter.assetForMarket(pending.marginPToken);
                uint256 marginUnderlying = marginAsset == token
                    ? userResidual
                    : _swap(token, marginAsset, userResidual, minMarginUnderlying, pairRisk, debtToMarginSwapData);
                returnedMarginPTokens = _mintPTokenOrReturnUnderlying(
                    pending.marginPToken, marginUnderlying, _getPosition(pending.positionId).owner
                );
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
    ) internal returns (uint256 debtAssetReceived) {
        uint256 coverageValueUsd = quoter.underlyingValueUsd(debtAsset, shortfall);
        address marginAsset = quoter.assetForMarket(marginPToken);
        if (marginAsset != debtAsset) {
            coverageValueUsd = Math.mulDiv(coverageValueUsd, BPS, BPS - pairRisk.maxSlippageBps, Math.Rounding.Ceil);
        }
        uint256 requestedPTokens = quoter.feePToken(marginPToken, coverageValueUsd);
        if (marginAsset != debtAsset) requestedPTokens += 1;
        uint256 providedPTokens = insuranceFund.provideCoverage(marginPToken, address(this), requestedPTokens);
        if (providedPTokens == 0) return 0;

        uint256 debtBalanceBefore = IERC20(debtAsset).balanceOf(address(this));
        uint256 marginUnderlying = _redeemOwnPToken(marginPToken, providedPTokens);
        if (marginAsset != debtAsset) {
            uint256 expectedOut = quoter.expectedOut(marginAsset, debtAsset, marginUnderlying);
            uint256 protocolMinOut = Math.mulDiv(expectedOut, BPS - pairRisk.maxSlippageBps, BPS);
            _swap(marginAsset, debtAsset, marginUnderlying, protocolMinOut, pairRisk, marginToDebtSwapData);
        }
        debtAssetReceived = IERC20(debtAsset).balanceOf(address(this)) - debtBalanceBefore;
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

    function _returnInsuranceExcess(address pToken, uint256 underlyingAmount)
        internal
        returns (uint256 returnedPTokens)
    {
        returnedPTokens = _mintPTokenOrReturnUnderlying(pToken, underlyingAmount, address(insuranceFund));
        if (returnedPTokens > 0) {
            IERC20(pToken).safeTransfer(address(insuranceFund), returnedPTokens);
        }
        emit InsuranceExcessReturned(pToken, underlyingAmount, returnedPTokens);
    }

    function _mintPTokenOrReturnUnderlying(address pToken, uint256 underlyingAmount, address dustRecipient)
        internal
        returns (uint256 mintedPTokens)
    {
        address asset = quoter.assetForMarket(pToken);

        // pToken minting rounds down. If the amount cannot represent even one
        // pToken unit, return the underlying instead of donating it to market cash.
        if (Math.mulDiv(underlyingAmount, 1e18, PErc20(pToken).exchangeRateStored()) == 0) {
            IERC20(asset).safeTransfer(dustRecipient, underlyingAmount);
            emit UnderlyingDustReturned(pToken, dustRecipient, underlyingAmount);
            return 0;
        }

        mintedPTokens = _mintPToken(pToken, underlyingAmount);
        if (mintedPTokens == 0) revert LiquidationError(26);
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

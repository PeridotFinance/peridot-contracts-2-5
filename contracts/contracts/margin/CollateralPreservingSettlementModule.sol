// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PErc20} from "../PErc20.sol";
import {IsolatedMarginQuoter} from "./IsolatedMarginQuoter.sol";
import {CollateralPreservingSwapModule} from "./CollateralPreservingSwapModule.sol";
import {IsolatedMarginTypes} from "./IsolatedMarginTypes.sol";
import {MarginFeeDistributorUpgradeable} from "./MarginFeeDistributorUpgradeable.sol";
import {IIsolatedMarginConfig} from "./interfaces/IIsolatedMarginConfig.sol";

/// @notice Full-close cash settlement for the collateral-preserving execution path.
/// @dev NOT an executor, debt repayment, risk hook or liquidation implementation.
/// The future executor must first repay account debt using a flash loan, redeem the
/// trading pTokens, and supply only that position's collateral/proceeds to this module.
/// It must calculate/authorize the fee, enforce the owner's limits, repay the lender,
/// return remaining collateral via the margin vault and pay USDC surplus to the owner.
/// This module spends ONLY caller-approved funds and returns ALL outputs to the caller.
/// It never mints pTokens or deposits into Pharaoh, even when deposit capacity exists.
contract CollateralPreservingSettlementModule is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;

    struct Markets {
        address usd;
        address wavax;
        address pUsd;
        address pWavax;
        address pUsdVault;
        address pAvaxVault;
    }

    struct CloseParams {
        address collateralPToken;
        address debtPToken;
        uint256 collateralShares;
        uint256 tradeUnderlying;
        uint256 repaymentAmount; // Exact flash principal + fee, in the debt asset.
        uint256 insuranceDebtAmount; // Explicit caller funds, used only AFTER collateral loss budget.
        uint256 feeShares; // Executor-computed closing fee, in ORIGINAL collateral pTokens.
        uint256 maxCollateralSharesToSell; // Owner-approved loss budget, excludes feeShares.
        uint256 minTradeDebtOut;
        uint256 minCollateralDebtOut;
        uint256 minSurplusUsdc;
        uint256 deadline;
        bytes tradeData;
        bytes collateralData;
        bytes surplusData;
    }

    struct Settlement {
        uint256 collateralSold;
        uint256 collateralReturned;
        uint256 surplusUsdc;
        // A WAVAX remainder worth less than one USDC base unit cannot be swapped.
        // The executor must refund this dust to the owner, NOT treat it as repayment.
        uint256 surplusWavaxDust;
        uint256 insuranceDebtUsed;
    }

    struct CloseContext {
        address tradeAsset;
        address debtAsset;
        address shareAsset;
        IsolatedMarginTypes.PairRiskConfig risk;
    }

    IIsolatedMarginConfig public immutable config;
    IsolatedMarginQuoter public immutable quoter;
    CollateralPreservingSwapModule public immutable swapModule;
    MarginFeeDistributorUpgradeable public immutable feeDistributor;
    address public immutable usd;
    address public immutable wavax;
    address public immutable pUsd;
    address public immutable pWavax;
    address public immutable pUsdVault;
    address public immutable pAvaxVault;
    address public immutable usdVault;
    address public immutable avaxVault;
    address public immutable controller;

    error InvalidConfiguration();
    error InvalidClose();
    error CollateralBudgetExceeded();
    error InsufficientProceeds();
    error RedemptionFailed();
    error UnexpectedBalance();
    event InsuranceApplied(address indexed caller, address indexed debtAsset, uint256 used, uint256 returned);

    event Settled(
        address indexed caller,
        address indexed collateralPToken,
        address indexed debtPToken,
        uint256 repaymentAmount,
        uint256 collateralSold,
        uint256 feeShares,
        uint256 collateralReturned,
        uint256 surplusUsdc,
        uint256 surplusWavaxDust
    );

    constructor(address config_, address quoter_, address swapModule_, address feeDistributor_, Markets memory m) {
        if (
            config_.code.length == 0 || quoter_.code.length == 0 || swapModule_.code.length == 0
                || feeDistributor_.code.length == 0
        ) revert InvalidConfiguration();
        config = IIsolatedMarginConfig(config_);
        quoter = IsolatedMarginQuoter(quoter_);
        swapModule = CollateralPreservingSwapModule(swapModule_);
        feeDistributor = MarginFeeDistributorUpgradeable(feeDistributor_);
        if (
            address(quoter.config()) != config_ || address(swapModule.config()) != config_
                || address(swapModule.quoter()) != quoter_ || address(feeDistributor.config()) != config_
                || swapModule.executionVersion() != keccak256("collateral-preserving-swap-v1")
        ) revert InvalidConfiguration();
        usd = m.usd;
        wavax = m.wavax;
        pUsd = m.pUsd;
        pWavax = m.pWavax;
        pUsdVault = m.pUsdVault;
        pAvaxVault = m.pAvaxVault;
        usdVault = PErc20(m.pUsdVault).underlying();
        avaxVault = PErc20(m.pAvaxVault).underlying();
        controller = address(PErc20(m.pUsd).peridottroller());
        if (controller.code.length == 0) revert InvalidConfiguration();
        address[8] memory tokens = [usd, wavax, pUsd, pWavax, pUsdVault, pAvaxVault, usdVault, avaxVault];
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i].code.length == 0) revert InvalidConfiguration();
            for (uint256 j; j < i; ++j) {
                if (tokens[i] == tokens[j]) revert InvalidConfiguration();
            }
        }
        _checkBindings();
    }

    /// @dev A disabled pair may still close. Unconfigured pairs cannot supply risk bounds.
    /// Outputs include a separately accounted debt-asset repayment and USDC surplus.
    /// Surplus can include harmless rounding/slippage over-redemption, not just trading PnL.
    function settleFullClose(CloseParams calldata p) external nonReentrant returns (Settlement memory s) {
        if (
            block.timestamp > p.deadline || (p.collateralPToken != pUsdVault && p.collateralPToken != pAvaxVault)
                || (p.debtPToken != pUsd && p.debtPToken != pWavax) || p.feeShares > p.collateralShares
        ) revert InvalidClose();
        _checkBindings();
        CloseContext memory c;
        c.tradeAsset = p.debtPToken == pUsd ? wavax : usd;
        c.debtAsset = p.debtPToken == pUsd ? usd : wavax;
        address positionPToken = p.debtPToken == pUsd ? pWavax : pUsd;
        c.shareAsset = p.collateralPToken == pUsdVault ? usdVault : avaxVault;
        c.risk = config.getPairRisk(p.collateralPToken, positionPToken, p.debtPToken);
        if (c.risk.maxLeverageX100 == 0 || c.risk.maxSlippageBps >= BPS || c.risk.oracleDeviationBps >= BPS) {
            revert InvalidClose();
        }

        // Preserve all pre-existing donations: they cannot pay another caller's deficit.
        address[4] memory tokens = [p.collateralPToken, c.shareAsset, usd, wavax];
        uint256[4] memory beforeBalances;
        for (uint256 i; i < tokens.length; ++i) {
            beforeBalances[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
        _pull(p.collateralPToken, p.collateralShares);
        _pull(c.tradeAsset, p.tradeUnderlying);
        _pull(c.debtAsset, p.insuranceDebtAmount);

        uint256 proceeds = p.tradeUnderlying == 0
            ? 0
            : _swap(c.tradeAsset, c.debtAsset, p.tradeUnderlying, p.minTradeDebtOut, c.risk, p.tradeData);
        if (proceeds < p.repaymentAmount) {
            uint256 collateralProceeds;
            (s.collateralSold, collateralProceeds) = _sellCollateral(p, c, p.repaymentAmount - proceeds);
            proceeds += collateralProceeds;
        }
        if (proceeds < p.repaymentAmount) {
            s.insuranceDebtUsed = p.repaymentAmount - proceeds;
            if (s.insuranceDebtUsed > p.insuranceDebtAmount) revert InsufficientProceeds();
            proceeds += s.insuranceDebtUsed;
        }
        uint256 surplusDebt = proceeds - p.repaymentAmount;
        if (c.debtAsset == usd || surplusDebt == 0) {
            s.surplusUsdc = surplusDebt;
        } else if (quoter.expectedOut(wavax, usd, surplusDebt) == 0) {
            s.surplusWavaxDust = surplusDebt;
        } else {
            s.surplusUsdc = _swap(c.debtAsset, usd, surplusDebt, p.minSurplusUsdc, c.risk, p.surplusData);
        }
        if (s.surplusUsdc < p.minSurplusUsdc) revert InsufficientProceeds();
        s.collateralReturned = p.collateralShares - p.feeShares - s.collateralSold;

        if (p.feeShares != 0) {
            IERC20(p.collateralPToken).forceApprove(address(feeDistributor), p.feeShares);
            feeDistributor.collectFee(p.collateralPToken, address(this), p.feeShares);
            IERC20(p.collateralPToken).forceApprove(address(feeDistributor), 0);
        }
        _return(p.collateralPToken, s.collateralReturned);
        _return(c.debtAsset, p.repaymentAmount);
        _return(usd, s.surplusUsdc);
        _return(wavax, s.surplusWavaxDust);
        _return(c.debtAsset, p.insuranceDebtAmount - s.insuranceDebtUsed);
        if (p.insuranceDebtAmount != 0) {
            emit InsuranceApplied(
                msg.sender, c.debtAsset, s.insuranceDebtUsed, p.insuranceDebtAmount - s.insuranceDebtUsed
            );
        }
        for (uint256 i; i < tokens.length; ++i) {
            if (IERC20(tokens[i]).balanceOf(address(this)) != beforeBalances[i]) revert UnexpectedBalance();
        }
        emit Settled(
            msg.sender,
            p.collateralPToken,
            p.debtPToken,
            p.repaymentAmount,
            s.collateralSold,
            p.feeShares,
            s.collateralReturned,
            s.surplusUsdc,
            s.surplusWavaxDust
        );
    }

    function _sellCollateral(CloseParams calldata p, CloseContext memory c, uint256 deficit)
        private
        returns (uint256 sold, uint256 proceeds)
    {
        // Only loss settlement depends on collateral accrual and redemption.
        PErc20(p.collateralPToken).exchangeRateCurrent();
        sold = quoteCollateralForDeficit(p.collateralPToken, c.debtAsset, deficit, c.risk.maxSlippageBps);
        uint256 available = Math.min(p.maxCollateralSharesToSell, p.collateralShares - p.feeShares);
        if (p.insuranceDebtAmount != 0) sold = Math.min(sold, available);
        if (sold > available || (sold == 0 && p.insuranceDebtAmount == 0)) {
            revert CollateralBudgetExceeded();
        }
        if (sold == 0) return (0, 0);
        uint256 sharesBefore = IERC20(c.shareAsset).balanceOf(address(this));
        uint256 collateralBefore = IERC20(p.collateralPToken).balanceOf(address(this));
        if (PErc20(p.collateralPToken).redeem(sold) != 0) revert RedemptionFailed();
        if (IERC20(p.collateralPToken).balanceOf(address(this)) != collateralBefore - sold) revert UnexpectedBalance();
        uint256 redeemed = IERC20(c.shareAsset).balanceOf(address(this)) - sharesBefore;
        if (redeemed == 0) revert InsufficientProceeds();
        proceeds = _swap(
            c.shareAsset,
            c.debtAsset,
            redeemed,
            p.insuranceDebtAmount == 0 ? Math.max(deficit, p.minCollateralDebtOut) : p.minCollateralDebtOut,
            c.risk,
            p.collateralData
        );
    }

    /// @notice Conservative oracle sizing; caller must accrue the pToken before using the quote.
    /// @dev This is NOT a liquidity guarantee. Redemption fees/illiquidity still fail atomically.
    /// Rounds the debt USD value up and reserves one debt base unit before slippage gross-up.
    function quoteCollateralForDeficit(address collateral, address debtAsset, uint256 deficit, uint16 slippageBps)
        public
        view
        returns (uint256)
    {
        if (
            (collateral != pUsdVault && collateral != pAvaxVault) || (debtAsset != usd && debtAsset != wavax)
                || slippageBps >= BPS
        ) revert InvalidClose();
        if (deficit == 0) return 0;
        uint256 value = quoter.underlyingValueUsd(debtAsset, deficit + 1) + 1;
        value = Math.mulDiv(value, BPS, BPS - slippageBps, Math.Rounding.Ceil);
        return quoter.feePToken(collateral, value);
    }

    function _checkBindings() private view {
        address[4] memory markets = [pUsd, pWavax, pUsdVault, pAvaxVault];
        address[4] memory assets = [usd, wavax, usdVault, avaxVault];
        for (uint256 i; i < markets.length; ++i) {
            if (
                PErc20(markets[i]).underlying() != assets[i] || quoter.assetForMarket(markets[i]) != assets[i]
                    || address(PErc20(markets[i]).peridottroller()) != controller
            ) {
                revert InvalidConfiguration();
            }
        }
        if (IERC4626(usdVault).asset() != usd || IERC4626(avaxVault).asset() != wavax) revert InvalidConfiguration();
    }

    function _swap(
        address input,
        address output,
        uint256 amount,
        uint256 minimum,
        IsolatedMarginTypes.PairRiskConfig memory risk,
        bytes calldata data
    ) private returns (uint256 out) {
        // Raise, never weaken, a requested bound when the known deficit is smaller.
        uint256 oracleMinimum = Math.mulDiv(quoter.expectedOut(input, output, amount), BPS - risk.maxSlippageBps, BPS);
        minimum = Math.max(1, Math.max(minimum, oracleMinimum));
        uint256 inBefore = IERC20(input).balanceOf(address(this));
        uint256 outBefore = IERC20(output).balanceOf(address(this));
        IERC20(input).forceApprove(address(swapModule), amount);
        out = swapModule.executeSwap(input, output, amount, minimum, risk.maxSlippageBps, risk.oracleDeviationBps, data);
        IERC20(input).forceApprove(address(swapModule), 0);
        if (
            IERC20(input).balanceOf(address(this)) != inBefore - amount
                || IERC20(output).balanceOf(address(this)) != outBefore + out
        ) revert UnexpectedBalance();
    }

    function _pull(address token, uint256 amount) private {
        if (amount == 0) return;
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(token).balanceOf(address(this)) != beforeBalance + amount) revert UnexpectedBalance();
    }

    function _return(address token, uint256 amount) private {
        if (amount == 0) return;
        uint256 beforeBalance = IERC20(token).balanceOf(msg.sender);
        IERC20(token).safeTransfer(msg.sender, amount);
        if (IERC20(token).balanceOf(msg.sender) != beforeBalance + amount) revert UnexpectedBalance();
    }
}

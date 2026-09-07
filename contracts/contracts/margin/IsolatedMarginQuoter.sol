// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC3156FlashLender} from "../PTokenInterfaces.sol";
import {PErc20} from "../PErc20.sol";
import {IsolatedMarginMath} from "./IsolatedMarginMath.sol";
import {IsolatedMarginTypes} from "./IsolatedMarginTypes.sol";
import {IIsolatedMarginConfig} from "./interfaces/IIsolatedMarginConfig.sol";
import {IMarginPriceOracle} from "./interfaces/IMarginPriceOracle.sol";

/**
 * @notice Shared read-only quote logic for isolated margin execution.
 * @dev Keeping quote math out of the executor leaves enough EVM bytecode headroom
 *      for execution and liquidation controls.
 */
contract IsolatedMarginQuoter {
    uint256 public constant LEVERAGE_SCALE = 100;

    IIsolatedMarginConfig public immutable config;
    IMarginPriceOracle public immutable oracle;

    struct OpenSizing {
        address debtAsset;
        uint256 debtPrice;
        uint256 debtScale;
        uint256 positionPrice;
        uint256 positionScale;
        uint256 exchangeRate;
        uint256 marginUnderlying;
        uint16 leverageX100;
        uint16 initialMarginBps;
        uint16 slippageBps;
        uint16 oracleDeviationBps;
        bool short;
    }

    constructor(address config_, address oracle_) {
        require(config_.code.length > 0, "MarginQuoter: invalid config");
        require(oracle_.code.length > 0, "MarginQuoter: invalid oracle");
        config = IIsolatedMarginConfig(config_);
        oracle = IMarginPriceOracle(oracle_);
    }

    function feePToken(address pToken, uint256 feeValueUsd) external view returns (uint256) {
        if (feeValueUsd == 0) return 0;
        address asset = assetForMarket(pToken);
        return IsolatedMarginMath.pTokenForUsd(
            feeValueUsd,
            IERC20Metadata(asset).decimals(),
            price(asset),
            PErc20(pToken).exchangeRateStored(),
            Math.Rounding.Ceil
        );
    }

    function expectedOut(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256) {
        return underlyingForUsd(tokenOut, underlyingValueUsd(tokenIn, amountIn), Math.Rounding.Floor);
    }

    function underlyingValueUsd(address asset, uint256 amount) public view returns (uint256) {
        return IsolatedMarginMath.valueUsd(amount, IERC20Metadata(asset).decimals(), price(asset));
    }

    function underlyingForUsd(address asset, uint256 valueUsd, Math.Rounding rounding) public view returns (uint256) {
        return Math.mulDiv(valueUsd, 10 ** uint256(IERC20Metadata(asset).decimals()), price(asset), rounding);
    }

    /// @notice Legacy oracle-parity estimate, retained for ABI compatibility.
    /// @dev NOT an executable opening quote: ignores swap loss and mint rounding. Use quoteOpen.
    function flashAmountForLeverage(address debtAsset, uint256 marginValueUsd, uint16 leverageX100)
        external
        view
        returns (uint256 flashAmount)
    {
        uint256 candidateDebtUsd = Math.mulDiv(marginValueUsd, leverageX100 - LEVERAGE_SCALE, LEVERAGE_SCALE);
        flashAmount = underlyingForUsd(debtAsset, candidateDebtUsd, Math.Rounding.Floor);
        IERC3156FlashLender lender = flashLender();

        // The flash fee itself becomes debt. Converge down so gross assets divided by
        // post-fee equity never exceeds the user's requested leverage.
        for (uint256 i = 0; i < 8; i++) {
            uint256 flashFeeUsd = underlyingValueUsd(debtAsset, lender.flashFee(debtAsset, flashAmount));
            require(flashFeeUsd < marginValueUsd, "MarginQuoter: flash fee exceeds equity");
            uint256 allowedGrossUsd = Math.mulDiv(marginValueUsd - flashFeeUsd, leverageX100, LEVERAGE_SCALE);
            require(allowedGrossUsd > marginValueUsd, "MarginQuoter: no borrowing capacity");
            uint256 adjusted = underlyingForUsd(debtAsset, allowedGrossUsd - marginValueUsd, Math.Rounding.Floor);
            if (adjusted >= flashAmount) break;
            flashAmount = adjusted;
        }

        uint256 finalFeeUsd = underlyingValueUsd(debtAsset, lender.flashFee(debtAsset, flashAmount));
        uint256 finalDebtUsd = underlyingValueUsd(debtAsset, flashAmount);
        require(
            Math.mulDiv(marginValueUsd + finalDebtUsd, LEVERAGE_SCALE, marginValueUsd - finalFeeUsd) <= leverageX100,
            "MarginQuoter: leverage convergence"
        );
        require(flashAmount <= lender.maxFlashLoan(debtAsset), "MarginQuoter: flash capacity");
    }

    function assetForMarket(address pToken) public view returns (address asset) {
        asset = oracle.marketAsset(pToken);
        require(asset != address(0), "MarginQuoter: market unavailable");
    }

    /// @notice Conservative opening quote including allowed swap loss, flash fee and pToken rounding.
    /// @dev marginUnderlying is the redeemed collateral amount, not a pToken share count. Callers
    ///      must accrue markets before quoting. minPositionUnderlying is TOTAL position output;
    ///      on shorts the executor subtracts the unswapped margin before enforcing the swap minimum.
    ///      Requested leverage is an upper bound, not a promise of an exact notional fill.
    function quoteOpen(
        address marginPToken,
        address positionPToken,
        address debtPToken,
        uint256 marginUnderlying,
        uint16 leverageX100
    ) external view returns (uint256 flashAmount, uint256 minPositionUnderlying) {
        IsolatedMarginTypes.PairRiskConfig memory risk = config.getPairRisk(marginPToken, positionPToken, debtPToken);
        require(
            risk.enabled && leverageX100 > 100 && leverageX100 <= risk.maxLeverageX100,
            "MarginQuoter: invalid opening leverage"
        );
        address debtAsset = assetForMarket(debtPToken);
        address positionAsset = assetForMarket(positionPToken);
        address marginAsset = assetForMarket(marginPToken);
        require(
            debtAsset != positionAsset && (marginAsset == debtAsset || marginAsset == positionAsset),
            "MarginQuoter: invalid opening pair"
        );
        OpenSizing memory s = OpenSizing({
            debtAsset: debtAsset,
            debtPrice: price(debtAsset),
            debtScale: 10 ** uint256(IERC20Metadata(debtAsset).decimals()),
            positionPrice: price(positionAsset),
            positionScale: 10 ** uint256(IERC20Metadata(positionAsset).decimals()),
            exchangeRate: PErc20(positionPToken).exchangeRateStored(),
            marginUnderlying: marginUnderlying,
            leverageX100: leverageX100,
            initialMarginBps: risk.initialMarginBps,
            slippageBps: risk.maxSlippageBps,
            oracleDeviationBps: risk.oracleDeviationBps,
            short: marginAsset == positionAsset
        });
        require(
            s.exchangeRate != 0 && s.slippageBps < 10_000 && s.oracleDeviationBps < 10_000
                && s.initialMarginBps < 10_000,
            "MarginQuoter: invalid opening risk"
        );
        uint256 marginUsd = s.short
            ? Math.mulDiv(marginUnderlying, s.positionPrice, s.positionScale)
            : Math.mulDiv(marginUnderlying, s.debtPrice, s.debtScale);
        uint256 upper = Math.mulDiv(Math.mulDiv(marginUsd, leverageX100 - 100, 100), s.debtScale, s.debtPrice);
        IERC3156FlashLender lender = flashLender();
        upper = Math.min(upper, lender.maxFlashLoan(debtAsset));
        // Bounded by uint256 width (at most 256 iterations). Every selected amount is explicitly
        // checked, including the lender's actual fee. No monotonic-fee assumption is needed for
        // safety; an unusual fee curve can make the result smaller than the maximum feasible size.
        uint256 high = upper;
        while (flashAmount < high) {
            uint256 delta = high - flashAmount;
            uint256 candidate = flashAmount + delta / 2 + delta % 2;
            if (_openingFits(s, lender, candidate)) flashAmount = candidate;
            else high = candidate - 1;
        }
        require(flashAmount > 0 && _openingFits(s, lender, flashAmount), "MarginQuoter: no opening capacity");
        minPositionUnderlying = _minimumPosition(s, flashAmount);
    }

    function _minimumPosition(OpenSizing memory s, uint256 amount) private pure returns (uint256) {
        uint256 swapInput = s.short ? amount : s.marginUnderlying + amount;
        uint256 inputUsd = Math.mulDiv(swapInput, s.debtPrice, s.debtScale);
        uint256 expected = Math.mulDiv(inputUsd, s.positionScale, s.positionPrice);
        uint256 minSwap = Math.mulDiv(expected, 10_000 - s.slippageBps, 10_000);
        // The independent USD-value bound can be one output base unit stricter than the
        // token-denominated bound, especially on six-decimal assets. Never quote below it.
        uint256 oracleMinimumUsd = Math.mulDiv(inputUsd, 10_000 - s.oracleDeviationBps, 10_000);
        minSwap = Math.max(minSwap, Math.mulDiv(oracleMinimumUsd, s.positionScale, s.positionPrice, Math.Rounding.Ceil));
        return s.short ? s.marginUnderlying + minSwap : minSwap;
    }

    function _openingFits(OpenSizing memory s, IERC3156FlashLender lender, uint256 amount) private view returns (bool) {
        uint256 output = _minimumPosition(s, amount);
        uint256 minted = Math.mulDiv(output, 1e18, s.exchangeRate);
        uint256 credited = Math.mulDiv(minted, s.exchangeRate, 1e18);
        uint256 gross = Math.mulDiv(credited, s.positionPrice, s.positionScale);
        uint256 debt = amount + lender.flashFee(s.debtAsset, amount);
        uint256 debtUsd = Math.mulDiv(debt, s.debtPrice, s.debtScale);
        // Compare exact debt bounds instead of a rounded-down leverage metric. Rounding protects
        // equity, including at the exact maximum and with coarse underlying/pToken decimals.
        return gross > debtUsd && debtUsd <= Math.mulDiv(gross, s.leverageX100 - 100, s.leverageX100)
            && debtUsd <= Math.mulDiv(gross, 10_000 - s.initialMarginBps, 10_000);
    }

    function price(address asset) public view returns (uint256 priceUsd) {
        priceUsd = oracle.getPrice(asset);
        require(priceUsd > 0, "MarginQuoter: price unavailable");
    }

    function flashLender() public view returns (IERC3156FlashLender lender) {
        address lenderAddress = config.flashLoanProvider();
        require(lenderAddress.code.length > 0, "MarginQuoter: lender unavailable");
        lender = IERC3156FlashLender(lenderAddress);
    }
}

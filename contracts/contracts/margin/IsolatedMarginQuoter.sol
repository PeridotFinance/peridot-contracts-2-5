// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC3156FlashLender} from "../PTokenInterfaces.sol";
import {PErc20} from "../PErc20.sol";
import {IsolatedMarginMath} from "./IsolatedMarginMath.sol";
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

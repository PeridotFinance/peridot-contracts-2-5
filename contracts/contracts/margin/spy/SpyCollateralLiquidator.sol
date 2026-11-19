// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC3156FlashBorrower, IERC3156FlashLender} from "../../PTokenInterfaces.sol";
import {IMarginRouterAdapter} from "../IMarginRouterAdapter.sol";

interface ISpyPriceSession {
    function stockPrice() external view returns (uint256 priceE18, uint8 reason, uint256 updatedAt);
}

interface ILiquidatablePToken {
    function liquidateBorrow(address borrower, uint256 repayAmount, address pTokenCollateral) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function underlying() external view returns (address);
}

/**
 * @title SpyCollateralLiquidator
 * @notice Inventory-free liquidation of ordinary lending accounts with pUSDG debt and pSPY collateral.
 * @dev One call: flash-borrow USDG from the margin flash vault, `pUSDG.liquidateBorrow(borrower, repay, pSPY)`, redeem
 *      the seized pSPY, swap the SPY to USDG through the Robinhood v4 router adapter (this contract must be one of its
 *      operators), repay the flash loan, and send every remaining USDG to the immutable `beneficiary`.
 *
 *      - Permissionless: the caller pays gas and gains nothing; all proceeds go to `beneficiary`.
 *      - Fails closed unless the SPY session source serves a price (reason 0). The controller enforces the same rule
 *        through the pSPY snapshot gate; this check only makes the refusal explicit and cheap.
 *      - The swap floor is the SPY source price less `maxSlippageBps`. Any shortfall against the flash repayment
 *        reverts the whole liquidation: no partial state, no loss for anyone but the caller's gas.
 *      - The adapter is only ever asked to pull from `address(this)`.
 *      Immutable, no admin, no stored balances between calls.
 */
contract SpyCollateralLiquidator is IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    bytes32 internal constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    uint256 internal constant BPS = 10_000;

    ILiquidatablePToken public immutable debtMarket; // pUSDG
    ILiquidatablePToken public immutable collateralMarket; // pSPY
    IERC20 public immutable usdg;
    IERC20 public immutable spy;
    IERC3156FlashLender public immutable flashLender;
    IMarginRouterAdapter public immutable router;
    ISpyPriceSession public immutable spySource;
    address public immutable beneficiary;
    uint256 public immutable maxSlippageBps;
    uint256 internal immutable usdgScale; // 10 ** (18 - USDG decimals)

    address private _borrower; // nonzero only inside liquidate()

    error InvalidConfiguration();
    error SpyPriceUnavailable(uint8 reason);
    error UnexpectedCallback();
    error LiquidationRejected(uint256 code);
    error RedeemRejected(uint256 code);
    error NothingSeized();
    error InsufficientProceeds(uint256 have, uint256 owed);
    error ZeroRepay();

    event Liquidated(
        address indexed borrower, uint256 repaid, uint256 seizedPTokens, uint256 spySold, uint256 usdgOut, uint256 profit
    );

    constructor(
        address debtMarket_,
        address collateralMarket_,
        address flashLender_,
        address router_,
        address spySource_,
        address beneficiary_,
        uint256 maxSlippageBps_,
        uint8 usdgDecimals_
    ) {
        if (
            debtMarket_.code.length == 0 || collateralMarket_.code.length == 0 || flashLender_.code.length == 0
                || router_.code.length == 0 || spySource_.code.length == 0 || beneficiary_ == address(0)
                || debtMarket_ == collateralMarket_ || maxSlippageBps_ == 0 || maxSlippageBps_ > 500
                || usdgDecimals_ > 18
        ) revert InvalidConfiguration();
        debtMarket = ILiquidatablePToken(debtMarket_);
        collateralMarket = ILiquidatablePToken(collateralMarket_);
        usdg = IERC20(ILiquidatablePToken(debtMarket_).underlying());
        spy = IERC20(ILiquidatablePToken(collateralMarket_).underlying());
        flashLender = IERC3156FlashLender(flashLender_);
        router = IMarginRouterAdapter(router_);
        spySource = ISpyPriceSession(spySource_);
        beneficiary = beneficiary_;
        maxSlippageBps = maxSlippageBps_;
        usdgScale = 10 ** (18 - usdgDecimals_);
    }

    /// @notice Liquidates `repayAmount` USDG of `borrower`'s pUSDG debt against their pSPY. Returns USDG sent to
    ///         `beneficiary`. The controller enforces shortfall, close factor and seize limits.
    function liquidate(address borrower, uint256 repayAmount) external returns (uint256 profit) {
        if (repayAmount == 0) revert ZeroRepay();
        if (_borrower != address(0)) revert UnexpectedCallback();
        (, uint8 reason,) = spySource.stockPrice();
        if (reason != 0) revert SpyPriceUnavailable(reason);
        _borrower = borrower;
        flashLender.flashLoan(this, address(usdg), repayAmount, "");
        _borrower = address(0);
        profit = usdg.balanceOf(address(this));
        if (profit != 0) usdg.safeTransfer(beneficiary, profit);
    }

    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata)
        external
        override
        returns (bytes32)
    {
        address borrower = _borrower;
        if (
            msg.sender != address(flashLender) || initiator != address(this) || token != address(usdg)
                || borrower == address(0)
        ) revert UnexpectedCallback();

        usdg.forceApprove(address(debtMarket), amount);
        uint256 code = debtMarket.liquidateBorrow(borrower, amount, address(collateralMarket));
        if (code != 0) revert LiquidationRejected(code);
        usdg.forceApprove(address(debtMarket), 0);

        uint256 seized = collateralMarket.balanceOf(address(this));
        if (seized == 0) revert NothingSeized();
        code = collateralMarket.redeem(seized);
        if (code != 0) revert RedeemRejected(code);

        uint256 spyAmount = spy.balanceOf(address(this));
        (uint256 priceE18, uint8 reason,) = spySource.stockPrice();
        if (reason != 0) revert SpyPriceUnavailable(reason);
        uint256 minOut = spyAmount * priceE18 / 1e18 / usdgScale * (BPS - maxSlippageBps) / BPS;
        spy.forceApprove(address(router), spyAmount);
        uint256 out = router.swap(address(this), address(spy), address(usdg), spyAmount, minOut, "");
        spy.forceApprove(address(router), 0);

        uint256 owed = amount + fee;
        uint256 have = usdg.balanceOf(address(this));
        if (have < owed) revert InsufficientProceeds(have, owed);
        usdg.forceApprove(address(flashLender), owed);
        emit Liquidated(borrower, amount, seized, spyAmount, out, have - owed);
        return CALLBACK_SUCCESS;
    }
}

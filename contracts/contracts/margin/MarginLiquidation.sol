// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC3156FlashBorrower} from "../PTokenInterfaces.sol";

import {MarginManager} from "./MarginManager.sol";
import {IMarginRouterAdapter} from "./IMarginRouterAdapter.sol";
import {MarginRiskLib, IPeridottrollerView} from "./MarginRiskLib.sol";
import {PErc20} from "../PErc20.sol";
import {PToken} from "../PToken.sol";
import {PTokenInterface} from "../PTokenInterfaces.sol";
import {SimplePriceOracle} from "../SimplePriceOracle.sol";

/**
 * @title MarginLiquidation
 * @notice Facilitates flashloan-backed liquidations of SmartMarginAccount positions.
 */
contract MarginLiquidation is IERC3156FlashBorrower, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    struct SwapParams {
        address adapter;
        uint256 minAmountOut;
        bytes data;
    }

    struct FlashCallbackData {
        address user;
        address sma;
        address debtCToken;
        address collateralCToken;
        address borrowUnderlying;
        address collateralUnderlying;
        address recipient;
        uint256 minProfit;
        SwapParams swap;
        address caller;
    }

    MarginManager public immutable manager;
    IPeridottrollerView public immutable peridottroller;
    SimplePriceOracle public immutable priceOracle;

    mapping(address => bool) public allowedAdapters;

    event AdapterUpdated(address indexed adapter, bool allowed);
    event Liquidated(
        address indexed caller,
        address indexed user,
        address indexed debtCToken,
        address collateralCToken,
        uint256 repayAmount,
        uint256 feePaid,
        uint256 profit
    );

    constructor(address manager_, address owner_) Ownable(owner_) {
        require(manager_ != address(0), "Liquidation: invalid manager");
        manager = MarginManager(manager_);
        peridottroller = manager.peridottroller();
        priceOracle = manager.priceOracle();
    }

    function setAdapter(address adapter, bool allowed) external onlyOwner {
        allowedAdapters[adapter] = allowed;
        emit AdapterUpdated(adapter, allowed);
    }

    function liquidate(
        address user,
        address debtCToken,
        address collateralCToken,
        uint256 repayAmount,
        address recipient,
        uint256 minProfit,
        SwapParams calldata swap
    ) external nonReentrant {
        require(user != address(0), "Liquidation: invalid user");
        require(recipient != address(0), "Liquidation: invalid recipient");
        require(repayAmount > 0, "Liquidation: zero amount");

        MarginManager.Account memory account = manager.getAccount(user);
        require(account.sma != address(0), "Liquidation: no account");

        MarginRiskLib.AccountMetrics memory metrics = manager.getAccountMetrics(user);
        require(metrics.borrowValue > 0, "Liquidation: nothing to repay");
        require(metrics.healthFactorBps < manager.hfLockBps(), "Liquidation: account healthy");

        address borrowUnderlying = PErc20(debtCToken).underlying();
        address collateralUnderlying = PErc20(collateralCToken).underlying();

        FlashCallbackData memory data = FlashCallbackData({
            user: user,
            sma: account.sma,
            debtCToken: debtCToken,
            collateralCToken: collateralCToken,
            borrowUnderlying: borrowUnderlying,
            collateralUnderlying: collateralUnderlying,
            recipient: recipient,
            minProfit: minProfit,
            swap: swap,
            caller: msg.sender
        });

        bytes memory encoded = abi.encode(data);

        require(
            PErc20(debtCToken).flashLoan(IERC3156FlashBorrower(address(this)), borrowUnderlying, repayAmount, encoded),
            "Liquidation: flashloan failed"
        );
    }

    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        override
        returns (bytes32)
    {
        require(initiator == address(this), "Liquidation: bad initiator");

        FlashCallbackData memory params = abi.decode(data, (FlashCallbackData));
        require(msg.sender == params.debtCToken, "Liquidation: unexpected lender");
        require(token == params.borrowUnderlying, "Liquidation: unexpected token");

        IERC20 borrowToken = IERC20(token);
        IERC20 collateralToken = IERC20(params.collateralUnderlying);

        // Approve cToken to pull repay amount
        borrowToken.forceApprove(params.debtCToken, amount);

        uint256 cTokenBalanceBefore = IERC20(params.collateralCToken).balanceOf(address(this));

        uint256 liquidateResult =
            PErc20(params.debtCToken).liquidateBorrow(params.sma, amount, PTokenInterface(params.collateralCToken));
        require(liquidateResult == 0, "Liquidation: liquidate failed");
        borrowToken.forceApprove(params.debtCToken, 0);

        uint256 seizedCTokens = IERC20(params.collateralCToken).balanceOf(address(this)) - cTokenBalanceBefore;
        require(seizedCTokens > 0, "Liquidation: nothing seized");

        // Redeem seized collateral to underlying
        uint256 redeemResult = PErc20(params.collateralCToken).redeem(seizedCTokens);
        require(redeemResult == 0, "Liquidation: redeem failed");

        uint256 collateralBalance = collateralToken.balanceOf(address(this));
        require(collateralBalance > 0, "Liquidation: no collateral underlying");

        if (params.swap.adapter != address(0)) {
            require(allowedAdapters[params.swap.adapter], "Liquidation: adapter not allowed");
            collateralToken.forceApprove(params.swap.adapter, collateralBalance);
            uint256 amountOut = IMarginRouterAdapter(params.swap.adapter)
                .swap(
                    address(this),
                    params.collateralUnderlying,
                    params.borrowUnderlying,
                    collateralBalance,
                    params.swap.minAmountOut,
                    params.swap.data
                );
            collateralToken.forceApprove(params.swap.adapter, 0);
            require(amountOut >= params.swap.minAmountOut, "Liquidation: swap min out");
        } else {
            require(params.collateralUnderlying == params.borrowUnderlying, "Liquidation: swap required");
        }

        uint256 totalRepay = amount + fee;
        uint256 repayBalance = borrowToken.balanceOf(address(this));
        require(repayBalance >= totalRepay, "Liquidation: insufficient repay");

        uint256 profit = repayBalance - totalRepay;
        require(profit >= params.minProfit, "Liquidation: insufficient profit");

        // Repay flashloan
        borrowToken.safeTransfer(msg.sender, totalRepay);

        // Send profit to recipient
        if (profit > 0) {
            borrowToken.safeTransfer(params.recipient, profit);
        }

        // Forward any residual collateral underlying (should be zero if swapped)
        uint256 residualCollateral = collateralToken.balanceOf(address(this));
        if (residualCollateral > 0) {
            collateralToken.safeTransfer(params.recipient, residualCollateral);
        }

        emit Liquidated(params.caller, params.user, params.debtCToken, params.collateralCToken, amount, fee, profit);

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

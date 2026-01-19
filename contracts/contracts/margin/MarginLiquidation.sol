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
 * @dev Security notes:
 *      - cToken addresses are validated against manager's market configs
 *      - Flash loan authentication uses storage-bound expected values
 *      - Balance deltas are tracked to prevent sweeping stray tokens
 *      - Adapters must be allowlisted (recommend multisig/timelock for owner)
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

    /// @notice Expected flash loan parameters (set before flash loan, cleared after)
    struct PendingFlashLoan {
        address expectedLender;
        address expectedToken;
        uint256 expectedAmount;
        bool active;
    }

    MarginManager public immutable manager;
    IPeridottrollerView public immutable peridottroller;
    SimplePriceOracle public immutable priceOracle;

    mapping(address => bool) public allowedAdapters;

    /// @notice Storage-bound flash loan authentication
    PendingFlashLoan private pendingFlashLoan;

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
        // Require adapter to be a contract if enabling
        require(!allowed || adapter.code.length > 0, "Liquidation: adapter not contract");
        allowedAdapters[adapter] = allowed;
        emit AdapterUpdated(adapter, allowed);
    }

    /**
     * @dev Validates that a cToken is a legitimate market in the manager
     * @param cToken The cToken address to validate
     * @return underlying The validated underlying address
     */
    function _validateMarket(address cToken) internal view returns (address underlying) {
        require(cToken != address(0), "Liquidation: zero cToken");
        require(cToken.code.length > 0, "Liquidation: cToken not contract");

        // Get market config from manager
        (
            bool active,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            address configUnderlying
        ) = manager.marketConfigs(cToken);

        require(active, "Liquidation: market not active");
        require(configUnderlying != address(0), "Liquidation: market not configured");

        // Verify the cToken's underlying matches manager config
        underlying = PErc20(cToken).underlying();
        require(underlying == configUnderlying, "Liquidation: underlying mismatch");

        // Also verify with comptroller
        (bool isListed, , ) = peridottroller.markets(cToken);
        require(isListed, "Liquidation: market not listed");
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

        // Validate cToken addresses against manager's market configs
        address borrowUnderlying = _validateMarket(debtCToken);
        address collateralUnderlying = _validateMarket(collateralCToken);

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

        // Store expected flash loan parameters in storage for authentication
        pendingFlashLoan = PendingFlashLoan({
            expectedLender: debtCToken,
            expectedToken: borrowUnderlying,
            expectedAmount: repayAmount,
            active: true
        });

        require(
            PErc20(debtCToken).flashLoan(IERC3156FlashBorrower(address(this)), borrowUnderlying, repayAmount, encoded),
            "Liquidation: flashloan failed"
        );

        // Clear pending flash loan
        delete pendingFlashLoan;
    }

    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        override
        returns (bytes32)
    {
        require(initiator == address(this), "Liquidation: bad initiator");

        // Authenticate using storage-bound expected values (not calldata)
        PendingFlashLoan memory expected = pendingFlashLoan;
        require(expected.active, "Liquidation: no pending flash loan");
        require(msg.sender == expected.expectedLender, "Liquidation: unexpected lender");
        require(token == expected.expectedToken, "Liquidation: unexpected token");
        require(amount == expected.expectedAmount, "Liquidation: unexpected amount");

        FlashCallbackData memory params = abi.decode(data, (FlashCallbackData));
        // Double-check calldata matches storage expectations
        require(params.debtCToken == expected.expectedLender, "Liquidation: params mismatch");
        require(params.borrowUnderlying == expected.expectedToken, "Liquidation: token mismatch");

        IERC20 borrowToken = IERC20(token);
        IERC20 collateralToken = IERC20(params.collateralUnderlying);

        // Track balance deltas to avoid sweeping stray tokens
        // Note: At this point, the flash loan amount has already been transferred to us
        // So borrowBalanceBefore includes the flash loan amount
        uint256 borrowBalanceStart = borrowToken.balanceOf(address(this));
        uint256 collateralBalanceBefore = collateralToken.balanceOf(address(this));

        // The flash loan amount should be present
        require(borrowBalanceStart >= amount, "Liquidation: flash loan not received");

        // Calculate pre-existing balance (before flash loan)
        uint256 preExistingBorrowBalance = borrowBalanceStart - amount;

        // Approve cToken to pull repay amount (exact amount only)
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

        // Calculate collateral delta (only use what was gained from liquidation)
        uint256 collateralBalanceAfterRedeem = collateralToken.balanceOf(address(this));
        uint256 collateralGained = collateralBalanceAfterRedeem - collateralBalanceBefore;
        require(collateralGained > 0, "Liquidation: no collateral underlying");

        if (params.swap.adapter != address(0)) {
            require(allowedAdapters[params.swap.adapter], "Liquidation: adapter not allowed");
            require(params.swap.adapter.code.length > 0, "Liquidation: adapter not contract");

            // Approve exact amount only
            collateralToken.forceApprove(params.swap.adapter, collateralGained);

            // Track borrow token balance before swap
            uint256 borrowBalanceBeforeSwap = borrowToken.balanceOf(address(this));

            IMarginRouterAdapter(params.swap.adapter).swap(
                address(this),
                params.collateralUnderlying,
                params.borrowUnderlying,
                collateralGained,
                params.swap.minAmountOut,
                params.swap.data
            );
            collateralToken.forceApprove(params.swap.adapter, 0);

            // Verify swap output using balance delta
            uint256 borrowBalanceAfterSwap = borrowToken.balanceOf(address(this));
            uint256 swapOutput = borrowBalanceAfterSwap - borrowBalanceBeforeSwap;
            require(swapOutput >= params.swap.minAmountOut, "Liquidation: swap min out");
        } else {
            require(params.collateralUnderlying == params.borrowUnderlying, "Liquidation: swap required");
        }

        uint256 totalRepay = amount + fee;

        // Calculate profit using balance delta
        uint256 borrowBalanceNow = borrowToken.balanceOf(address(this));

        // We need: borrowBalanceNow >= totalRepay + preExistingBorrowBalance
        // (enough to repay flash loan and leave pre-existing balance intact)
        require(borrowBalanceNow >= totalRepay + preExistingBorrowBalance, "Liquidation: insufficient repay");

        // Profit = current balance - totalRepay - preExisting
        // This ensures we only count gains from this liquidation
        uint256 profit = borrowBalanceNow - totalRepay - preExistingBorrowBalance;
        require(profit >= params.minProfit, "Liquidation: insufficient profit");

        // Repay flashloan
        borrowToken.safeTransfer(msg.sender, totalRepay);

        // Send profit to recipient (only the profit from this liquidation)
        if (profit > 0) {
            borrowToken.safeTransfer(params.recipient, profit);
        }

        // Forward residual collateral (only from this liquidation)
        uint256 collateralBalanceNow = collateralToken.balanceOf(address(this));
        uint256 residualCollateral = collateralBalanceNow > collateralBalanceBefore
            ? collateralBalanceNow - collateralBalanceBefore
            : 0;
        if (residualCollateral > 0) {
            collateralToken.safeTransfer(params.recipient, residualCollateral);
        }

        emit Liquidated(params.caller, params.user, params.debtCToken, params.collateralCToken, amount, fee, profit);

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    /**
     * @notice Rescue tokens accidentally sent to this contract
     * @dev Only owner can call. Cannot rescue during active flash loan.
     * @param token The token to rescue
     * @param to The recipient
     * @param amount The amount to rescue
     */
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        require(!pendingFlashLoan.active, "Liquidation: flash loan active");
        require(to != address(0), "Liquidation: invalid recipient");
        IERC20(token).safeTransfer(to, amount);
    }
}

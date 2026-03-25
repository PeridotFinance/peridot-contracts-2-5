// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC3156FlashBorrower, IERC3156FlashLender} from "../PTokenInterfaces.sol";

import {IMarginRouterAdapter} from "./IMarginRouterAdapter.sol";
import {MarginRiskLib, IPeridottrollerView} from "./MarginRiskLib.sol";
import {PErc20} from "../PErc20.sol";
import {PToken} from "../PToken.sol";
import {PTokenInterface} from "../PTokenInterfaces.sol";
import {SimplePriceOracle} from "../SimplePriceOracle.sol";

interface IAtomicMarginConfigSource {
    function marketConfigs(address cToken)
        external
        view
        returns (
            bool active,
            bool depositsEnabled,
            bool borrowsEnabled,
            bool withdrawalsEnabled,
            bool tradesEnabled,
            uint16 maxLeverageX100,
            uint16 tradeSlippageBps,
            uint16 oracleDeviationBps,
            address underlying
        );
    function peridottroller() external view returns (IPeridottrollerView);
    function priceOracle() external view returns (SimplePriceOracle);
    function hfLockBps() external view returns (uint16);
    function flashloanProvider() external view returns (address);
}

interface IAtomicMarginAccounts {
    struct Account {
        address sma;
        bool withdrawalsLocked;
        uint64 lastHealthRecalc;
    }

    function getAccount(address user) external view returns (Account memory);
    function getAccountMetrics(address user)
        external
        view
        returns (MarginRiskLib.AccountMetrics memory metrics);
}

contract AtomicMarginLiquidationUpgradeable is
    Initializable,
    IERC3156FlashBorrower,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable
{
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

    struct PendingFlashLoan {
        address expectedLender;
        address expectedToken;
        uint256 expectedAmount;
        bool active;
    }

    IAtomicMarginAccounts public executor;
    IAtomicMarginConfigSource public configSource;
    IPeridottrollerView public peridottroller;
    SimplePriceOracle public priceOracle;

    mapping(address => bool) public allowedAdapters;

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

    constructor() {
        _disableInitializers();
    }

    function initialize(address executor_, address configSource_, address owner_) external initializer {
        require(executor_ != address(0), "AtomicLiquidation: invalid executor");
        require(configSource_ != address(0), "AtomicLiquidation: invalid config");
        require(owner_ != address(0), "AtomicLiquidation: invalid owner");
        __Ownable_init(owner_);
        __ReentrancyGuard_init();
        executor = IAtomicMarginAccounts(executor_);
        configSource = IAtomicMarginConfigSource(configSource_);
        peridottroller = IAtomicMarginConfigSource(configSource_).peridottroller();
        priceOracle = IAtomicMarginConfigSource(configSource_).priceOracle();
    }

    function setAdapter(address adapter, bool allowed) external onlyOwner {
        require(!allowed || adapter.code.length > 0, "AtomicLiquidation: adapter not contract");
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
        require(user != address(0), "AtomicLiquidation: invalid user");
        require(recipient != address(0), "AtomicLiquidation: invalid recipient");
        require(repayAmount > 0, "AtomicLiquidation: zero amount");

        IAtomicMarginAccounts.Account memory account = executor.getAccount(user);
        require(account.sma != address(0), "AtomicLiquidation: no account");

        MarginRiskLib.AccountMetrics memory metrics = executor.getAccountMetrics(user);
        require(metrics.borrowValue > 0, "AtomicLiquidation: nothing to repay");
        require(metrics.healthFactorBps < configSource.hfLockBps(), "AtomicLiquidation: account healthy");

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

        address lender = configSource.flashloanProvider();
        require(lender != address(0), "AtomicLiquidation: no flashloan provider");

        pendingFlashLoan = PendingFlashLoan({
            expectedLender: lender,
            expectedToken: borrowUnderlying,
            expectedAmount: repayAmount,
            active: true
        });

        require(
            IERC3156FlashLender(lender).flashLoan(
                IERC3156FlashBorrower(address(this)),
                borrowUnderlying,
                repayAmount,
                abi.encode(data)
            ),
            "AtomicLiquidation: flashloan failed"
        );

        delete pendingFlashLoan;
    }

    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        override
        returns (bytes32)
    {
        require(initiator == address(this), "AtomicLiquidation: bad initiator");

        PendingFlashLoan memory expected = pendingFlashLoan;
        require(expected.active, "AtomicLiquidation: no pending flash loan");
        require(msg.sender == expected.expectedLender, "AtomicLiquidation: unexpected lender");
        require(token == expected.expectedToken, "AtomicLiquidation: unexpected token");
        require(amount == expected.expectedAmount, "AtomicLiquidation: unexpected amount");

        FlashCallbackData memory params = abi.decode(data, (FlashCallbackData));

        IERC20 borrowToken = IERC20(token);
        IERC20 collateralToken = IERC20(params.collateralUnderlying);

        uint256 borrowBalanceStart = borrowToken.balanceOf(address(this));
        require(borrowBalanceStart >= amount, "AtomicLiquidation: flash loan not received");
        uint256 preExistingBorrowBalance = borrowBalanceStart - amount;
        uint256 collateralBalanceBefore = collateralToken.balanceOf(address(this));

        borrowToken.forceApprove(params.debtCToken, amount);
        uint256 cTokenBalanceBefore = IERC20(params.collateralCToken).balanceOf(address(this));

        uint256 liquidateResult =
            PErc20(params.debtCToken).liquidateBorrow(params.sma, amount, PTokenInterface(params.collateralCToken));
        require(liquidateResult == 0, "AtomicLiquidation: liquidate failed");
        borrowToken.forceApprove(params.debtCToken, 0);

        uint256 seizedCTokens = IERC20(params.collateralCToken).balanceOf(address(this)) - cTokenBalanceBefore;
        require(seizedCTokens > 0, "AtomicLiquidation: nothing seized");

        uint256 redeemResult = PErc20(params.collateralCToken).redeem(seizedCTokens);
        require(redeemResult == 0, "AtomicLiquidation: redeem failed");

        uint256 collateralBalanceAfterRedeem = collateralToken.balanceOf(address(this));
        uint256 collateralGained = collateralBalanceAfterRedeem - collateralBalanceBefore;
        require(collateralGained > 0, "AtomicLiquidation: no collateral underlying");

        if (params.swap.adapter != address(0)) {
            require(allowedAdapters[params.swap.adapter], "AtomicLiquidation: adapter not allowed");
            collateralToken.forceApprove(params.swap.adapter, collateralGained);

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

            uint256 swapOutput = borrowToken.balanceOf(address(this)) - borrowBalanceBeforeSwap;
            require(swapOutput >= params.swap.minAmountOut, "AtomicLiquidation: swap min out");
        } else {
            require(params.collateralUnderlying == params.borrowUnderlying, "AtomicLiquidation: swap required");
        }

        uint256 totalRepay = amount + fee;
        uint256 borrowBalanceNow = borrowToken.balanceOf(address(this));
        require(
            borrowBalanceNow >= totalRepay + preExistingBorrowBalance,
            "AtomicLiquidation: insufficient repay"
        );

        uint256 profit = borrowBalanceNow - totalRepay - preExistingBorrowBalance;
        require(profit >= params.minProfit, "AtomicLiquidation: insufficient profit");

        borrowToken.forceApprove(msg.sender, totalRepay);

        if (profit > 0) {
            borrowToken.safeTransfer(params.recipient, profit);
        }

        uint256 collateralBalanceNow = collateralToken.balanceOf(address(this));
        uint256 residualCollateral =
            collateralBalanceNow > collateralBalanceBefore ? collateralBalanceNow - collateralBalanceBefore : 0;
        if (residualCollateral > 0) {
            collateralToken.safeTransfer(params.recipient, residualCollateral);
        }

        emit Liquidated(params.caller, params.user, params.debtCToken, params.collateralCToken, amount, fee, profit);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        require(!pendingFlashLoan.active, "AtomicLiquidation: flash loan active");
        require(to != address(0), "AtomicLiquidation: invalid recipient");
        IERC20(token).safeTransfer(to, amount);
    }

    function _validateMarket(address cToken) internal view returns (address underlying) {
        require(cToken != address(0), "AtomicLiquidation: zero cToken");
        require(cToken.code.length > 0, "AtomicLiquidation: cToken not contract");

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
        ) = configSource.marketConfigs(cToken);

        require(active, "AtomicLiquidation: market not active");
        require(configUnderlying != address(0), "AtomicLiquidation: market not configured");

        underlying = PErc20(cToken).underlying();
        require(underlying == configUnderlying, "AtomicLiquidation: underlying mismatch");

        (bool isListed, , ) = peridottroller.markets(cToken);
        require(isListed, "AtomicLiquidation: market not listed");
    }
}

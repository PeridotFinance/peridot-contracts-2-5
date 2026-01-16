// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SmartMarginAccount} from "./SmartMarginAccount.sol";
import {MarginRiskLib, IPeridottrollerView} from "./MarginRiskLib.sol";
import {IMarginRouterAdapter} from "./IMarginRouterAdapter.sol";
import {SimplePriceOracle} from "../SimplePriceOracle.sol";
import {PErc20} from "../PErc20.sol";
import {PToken} from "../PToken.sol";

/**
 * @title MarginManager
 * @notice Entrypoint for Peridot cross-margin accounts.
 * @dev Deploys EIP-1167 SmartMarginAccount clones and orchestrates deposits, withdrawals, and risk gating.
 */
contract MarginManager is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MarginRiskLib for IPeridottrollerView;

    uint256 private constant EXP_SCALE = 1e18;
    uint256 private constant BPS_SCALE = 1e4;

    struct Account {
        address sma;
        bool withdrawalsLocked;
        uint64 lastHealthRecalc;
    }

    struct MarketConfig {
        bool active;
        bool depositsEnabled;
        bool borrowsEnabled;
        bool withdrawalsEnabled;
        bool tradesEnabled;
        uint16 maxLeverageX100;
        uint16 tradeSlippageBps;
        uint16 oracleDeviationBps;
        address underlying;
    }

    uint16 public hfMinWithdrawBps = 10500; // 1.05x
    uint16 public hfLockBps = 10000; // 1.00x
    uint16 public hfUnlockBps = 10800; // 1.08x
    uint16 public openFeeBps = 0;
    uint16 public closeFeeBps = 0;
    address public feeRecipient;
    uint16 public defaultMaxLeverageX100 = 300; // 3x

    address public routerAdapter;
    address public flashloanProvider;

    SmartMarginAccount public immutable implementation;
    IPeridottrollerView public immutable peridottroller;
    SimplePriceOracle public immutable priceOracle;

    mapping(address => Account) public accounts;
    mapping(address => MarketConfig) public marketConfigs; // cToken => config
    mapping(address => address) public underlyingToMarket; // underlying => cToken
    mapping(address => uint256) public protocolFees; // token => accrued amount
    mapping(address => address[]) private accountMarkets;
    mapping(address => mapping(address => bool)) private accountMarketsSet;

    event BorrowingEnabled(address indexed user, address sma);
    event Deposit(address indexed user, address indexed asset, uint256 amount);
    event Withdraw(address indexed user, address indexed asset, uint256 amount, uint256 hfAfterBps);
    event SupplyFromBalance(address indexed user, address indexed asset, uint256 amount, uint256 hfAfterBps);
    event RedeemToBalance(address indexed user, address indexed asset, uint256 amount, uint256 hfAfterBps);
    event Borrow(address indexed user, address indexed asset, uint256 amount, uint256 hfAfterBps);
    event Repay(address indexed user, address indexed asset, uint256 amount, uint256 hfAfterBps);
    event Trade(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 hfAfterBps
    );
    event LeveragedPositionOpened(
        address indexed user,
        address indexed borrowAsset,
        address indexed collateralAsset,
        uint256 borrowAmount,
        uint256 collateralSupplied,
        uint256 hfAfterBps
    );
    event LeveragedPositionClosed(
        address indexed user,
        address indexed collateralAsset,
        address indexed repayAsset,
        uint256 collateralRedeemed,
        uint256 repayAmount,
        uint256 hfAfterBps
    );
    event Locked(address indexed user);
    event Unlocked(address indexed user);
    event MarketUpdated(
        address indexed cToken,
        address indexed underlying,
        bool active,
        bool depositsEnabled,
        bool borrowsEnabled,
        bool withdrawalsEnabled,
        bool tradesEnabled,
        uint16 maxLeverageX100,
        uint16 tradeSlippageBps,
        uint16 oracleDeviationBps
    );
    event RouterAdapterUpdated(address indexed newAdapter);
    event FlashloanProviderUpdated(address indexed newProvider);
    event ThresholdsUpdated(uint16 hfMinWithdrawBps, uint16 hfLockBps, uint16 hfUnlockBps);
    event FeesUpdated(uint16 openFeeBps, uint16 closeFeeBps);
    event FeesAccrued(address indexed asset, uint256 amount);
    event FeesSwept(address indexed asset, address indexed to, uint256 amount);
    event DefaultLeverageUpdated(uint16 maxLeverageX100);
    event FeeRecipientUpdated(address indexed newRecipient);

    constructor(address _peridottroller, address _priceOracle) Ownable(msg.sender) {
        require(_peridottroller != address(0), "Manager: invalid comptroller");
        require(_priceOracle != address(0), "Manager: invalid oracle");

        implementation = new SmartMarginAccount();
        peridottroller = IPeridottrollerView(_peridottroller);
        priceOracle = SimplePriceOracle(_priceOracle);
    }

    function enableBorrowing() external returns (address sma) {
        Account storage account = accounts[msg.sender];
        if (account.sma == address(0)) {
            sma = Clones.clone(address(implementation));
            SmartMarginAccount(sma).initialize(address(this), msg.sender);
            account.sma = sma;
            emit BorrowingEnabled(msg.sender, sma);
        } else {
            sma = account.sma;
        }
    }

    function deposit(address asset, uint256 amount) external nonReentrant {
        require(amount > 0, "Manager: zero amount");
        Account storage account = accounts[msg.sender];
        require(account.sma != address(0), "Manager: no account");

        (address cToken, MarketConfig memory config, bool isUnderlying) = _getMarketForAsset(asset);
        require(config.active, "Manager: market inactive");
        require(config.depositsEnabled, "Manager: deposits paused");

        if (isUnderlying) {
            IERC20(asset).safeTransferFrom(msg.sender, account.sma, amount);
            uint256 mintResult = SmartMarginAccount(account.sma).mint(cToken, amount);
            require(mintResult == 0, "Manager: mint failed");
        } else {
            IERC20(cToken).safeTransferFrom(msg.sender, account.sma, amount);
        }

        SmartMarginAccount(account.sma).enterMarket(address(peridottroller), cToken);
        _ensureUserMarket(msg.sender, cToken);
        address[] memory markets = _getUserMarkets(msg.sender);
        MarginRiskLib.AccountMetrics memory metrics = MarginRiskLib.computeAccountMetricsForMarkets(
            peridottroller, priceOracle, account.sma, hfMinWithdrawBps, markets
        );
        _syncLockState(msg.sender, account, metrics.healthFactorBps);
        emit Deposit(msg.sender, asset, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external nonReentrant {
        require(amount > 0, "Manager: zero amount");
        require(to != address(0), "Manager: invalid recipient");

        Account storage account = accounts[msg.sender];
        require(account.sma != address(0), "Manager: no account");
        require(!account.withdrawalsLocked, "Manager: withdrawals locked");

        (address cToken, MarketConfig memory config, bool isUnderlying) = _getMarketForAsset(asset);
        require(config.active, "Manager: market inactive");
        require(config.withdrawalsEnabled, "Manager: withdrawals paused");
        require(isUnderlying, "Manager: only underlying withdraw");

        address[] memory markets = _getUserMarkets(msg.sender);
        uint256 maxUnderlying = MarginRiskLib.maxWithdrawableUnderlyingFromMarkets(
            peridottroller, priceOracle, account.sma, cToken, hfMinWithdrawBps, markets
        );

        require(maxUnderlying > 0, "Manager: nothing withdrawable");
        require(amount <= maxUnderlying, "Manager: exceeds max withdraw");

        uint256 redeemResult = SmartMarginAccount(account.sma).redeemUnderlying(cToken, amount);
        require(redeemResult == 0, "Manager: redeem failed");

        uint256 payoutAmount = amount;
        if (closeFeeBps > 0) {
            uint256 fee = (amount * closeFeeBps) / BPS_SCALE;
            if (fee > 0) {
                payoutAmount = amount - fee;
                address recipient = feeRecipient;
                if (recipient == address(0)) {
                    SmartMarginAccount(account.sma).transferOut(asset, address(this), fee);
                    protocolFees[asset] += fee;
                } else {
                    SmartMarginAccount(account.sma).transferOut(asset, recipient, fee);
                }
                emit FeesAccrued(asset, fee);
            }
        }

        if (payoutAmount > 0) {
            SmartMarginAccount(account.sma).transferOut(asset, to, payoutAmount);
        }

        _pruneUserMarkets(msg.sender, account.sma);

        MarginRiskLib.AccountMetrics memory metrics = MarginRiskLib.computeAccountMetricsForMarkets(
            peridottroller, priceOracle, account.sma, hfMinWithdrawBps, _getUserMarkets(msg.sender)
        );
        _syncLockState(msg.sender, account, metrics.healthFactorBps);
        emit Withdraw(msg.sender, asset, amount, metrics.healthFactorBps);
    }

    function supplyFromBalance(address asset, uint256 amount) external nonReentrant {
        require(amount > 0, "Manager: zero amount");
        Account storage account = accounts[msg.sender];
        require(account.sma != address(0), "Manager: no account");

        (address cToken, MarketConfig memory config, bool isUnderlying) = _getMarketForAsset(asset);
        require(config.active, "Manager: market inactive");
        require(config.depositsEnabled, "Manager: deposits paused");
        require(isUnderlying, "Manager: only underlying");

        uint256 balance = IERC20(asset).balanceOf(account.sma);
        require(balance >= amount, "Manager: insufficient balance");

        uint256 mintResult = SmartMarginAccount(account.sma).mint(cToken, amount);
        require(mintResult == 0, "Manager: mint failed");
        SmartMarginAccount(account.sma).enterMarket(address(peridottroller), cToken);

        _ensureUserMarket(msg.sender, cToken);

        MarginRiskLib.AccountMetrics memory metrics = MarginRiskLib.computeAccountMetricsForMarkets(
            peridottroller, priceOracle, account.sma, hfMinWithdrawBps, _getUserMarkets(msg.sender)
        );
        _syncLockState(msg.sender, account, metrics.healthFactorBps);

        emit SupplyFromBalance(msg.sender, asset, amount, metrics.healthFactorBps);
    }

    function redeemToBalance(address asset, uint256 amount) external nonReentrant {
        require(amount > 0, "Manager: zero amount");
        Account storage account = accounts[msg.sender];
        require(account.sma != address(0), "Manager: no account");
        require(!account.withdrawalsLocked, "Manager: withdrawals locked");

        (address cToken, MarketConfig memory config, bool isUnderlying) = _getMarketForAsset(asset);
        require(config.active, "Manager: market inactive");
        require(config.withdrawalsEnabled, "Manager: withdrawals paused");
        require(isUnderlying, "Manager: only underlying");

        address[] memory markets = _getUserMarkets(msg.sender);
        uint256 maxUnderlying = MarginRiskLib.maxWithdrawableUnderlyingFromMarkets(
            peridottroller, priceOracle, account.sma, cToken, hfMinWithdrawBps, markets
        );
        require(maxUnderlying > 0, "Manager: nothing withdrawable");
        require(amount <= maxUnderlying, "Manager: exceeds max withdraw");

        uint256 redeemResult = SmartMarginAccount(account.sma).redeemUnderlying(cToken, amount);
        require(redeemResult == 0, "Manager: redeem failed");

        _pruneUserMarkets(msg.sender, account.sma);

        MarginRiskLib.AccountMetrics memory metrics = MarginRiskLib.computeAccountMetricsForMarkets(
            peridottroller, priceOracle, account.sma, hfMinWithdrawBps, _getUserMarkets(msg.sender)
        );
        _syncLockState(msg.sender, account, metrics.healthFactorBps);

        emit RedeemToBalance(msg.sender, asset, amount, metrics.healthFactorBps);
    }

    function borrow(address asset, uint256 amount, address to) external nonReentrant {
        Account storage account = accounts[msg.sender];
        require(account.sma != address(0), "Manager: no account");
        (MarginRiskLib.AccountMetrics memory postMetrics,,) = _borrowFor(msg.sender, account, asset, amount, to);
        emit Borrow(msg.sender, asset, amount, postMetrics.healthFactorBps);
    }

    function repay(address asset, uint256 amount) external nonReentrant {
        require(amount > 0, "Manager: zero amount");
        Account storage account = accounts[msg.sender];
        require(account.sma != address(0), "Manager: no account");

        (address cToken,, bool isUnderlying) = _getMarketForAsset(asset);
        require(isUnderlying, "Manager: repay requires underlying");

        IERC20(asset).safeTransferFrom(msg.sender, account.sma, amount);
        uint256 repayResult = SmartMarginAccount(account.sma).repayBorrow(cToken, amount);
        require(repayResult == 0, "Manager: repay failed");

        _pruneUserMarkets(msg.sender, account.sma);

        MarginRiskLib.AccountMetrics memory metrics = MarginRiskLib.computeAccountMetricsForMarkets(
            peridottroller, priceOracle, account.sma, hfMinWithdrawBps, _getUserMarkets(msg.sender)
        );
        _syncLockState(msg.sender, account, metrics.healthFactorBps);
        emit Repay(msg.sender, asset, amount, metrics.healthFactorBps);
    }

    function repayFromBalance(address asset, uint256 amount) external nonReentrant {
        require(amount > 0, "Manager: zero amount");
        Account storage account = accounts[msg.sender];
        require(account.sma != address(0), "Manager: no account");

        (address cToken,, bool isUnderlying) = _getMarketForAsset(asset);
        require(isUnderlying, "Manager: repay requires underlying");

        uint256 balance = IERC20(asset).balanceOf(account.sma);
        require(balance >= amount, "Manager: insufficient balance");

        uint256 repayResult = SmartMarginAccount(account.sma).repayBorrow(cToken, amount);
        require(repayResult == 0, "Manager: repay failed");

        _pruneUserMarkets(msg.sender, account.sma);

        MarginRiskLib.AccountMetrics memory metrics = MarginRiskLib.computeAccountMetricsForMarkets(
            peridottroller, priceOracle, account.sma, hfMinWithdrawBps, _getUserMarkets(msg.sender)
        );
        _syncLockState(msg.sender, account, metrics.healthFactorBps);
        emit Repay(msg.sender, asset, amount, metrics.healthFactorBps);
    }

    function trade(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata routerData
    ) external nonReentrant returns (uint256 amountOut) {
        Account storage account = accounts[msg.sender];
        require(account.sma != address(0), "Manager: no account");
        require(amountIn > 0, "Manager: zero amount");
        require(routerAdapter != address(0), "Manager: router not set");

        (address cTokenIn, MarketConfig memory configIn, bool inIsUnderlying) = _getMarketForAsset(tokenIn);
        (address cTokenOut, MarketConfig memory configOut, bool outIsUnderlying) = _getMarketForAsset(tokenOut);
        require(configIn.active && configOut.active, "Manager: market inactive");
        require(configIn.tradesEnabled && configOut.tradesEnabled, "Manager: trades paused");
        require(inIsUnderlying && outIsUnderlying, "Manager: underlying only");

        uint256 priceIn = priceOracle.getUnderlyingPrice(PToken(cTokenIn));
        uint256 priceOut = priceOracle.getUnderlyingPrice(PToken(cTokenOut));
        require(priceIn > 0 && priceOut > 0, "Manager: price zero");

        uint256 expectedOut = (amountIn * priceIn) / priceOut;
        require(expectedOut > 0, "Manager: expectedOut zero");

        uint16 slippageLimit = _minPositive(configIn.tradeSlippageBps, configOut.tradeSlippageBps);
        if (slippageLimit > 0) {
            uint256 managerMinOut = (expectedOut * (BPS_SCALE - slippageLimit)) / BPS_SCALE;
            require(minAmountOut >= managerMinOut, "Manager: minOut too low");
        }
        uint16 deviationLimit = _minPositive(configIn.oracleDeviationBps, configOut.oracleDeviationBps);

        address[] memory marketsBefore = _getUserMarkets(msg.sender);
        MarginRiskLib.AccountMetrics memory preMetrics = MarginRiskLib.computeAccountMetricsForMarkets(
            peridottroller, priceOracle, account.sma, hfMinWithdrawBps, marketsBefore
        );

        SmartMarginAccount(account.sma).approve(tokenIn, routerAdapter, amountIn);
        amountOut = IMarginRouterAdapter(routerAdapter)
            .swap(account.sma, tokenIn, tokenOut, amountIn, minAmountOut, routerData);
        SmartMarginAccount(account.sma).approve(tokenIn, routerAdapter, 0);
        require(amountOut > 0, "Manager: zero output");

        _enforceTradeBounds(amountIn, amountOut, expectedOut, priceIn, priceOut, slippageLimit, deviationLimit);

        MarginRiskLib.AccountMetrics memory postMetrics = MarginRiskLib.computeAccountMetricsForMarkets(
            peridottroller, priceOracle, account.sma, hfMinWithdrawBps, _getUserMarkets(msg.sender)
        );

        if (account.withdrawalsLocked) {
            require(postMetrics.healthFactorBps >= preMetrics.healthFactorBps, "Manager: locked worsen");
        }

        require(postMetrics.healthFactorBps >= hfLockBps, "Manager: health factor low");
        uint16 leverageCap = _effectiveLeverageCap(
            _resolveLeverageCap(configIn.maxLeverageX100), _resolveLeverageCap(configOut.maxLeverageX100)
        );
        _enforceLeverage(postMetrics, leverageCap);
        _syncLockState(msg.sender, account, postMetrics.healthFactorBps);

        emit Trade(msg.sender, tokenIn, tokenOut, amountIn, amountOut, postMetrics.healthFactorBps);
        return amountOut;
    }

    function openLeveragedPosition(
        address borrowAsset,
        address collateralAsset,
        uint256 borrowAmount,
        uint256 minCollateralAmount,
        bytes calldata routerData
    ) external nonReentrant returns (uint256 collateralSupplied) {
        Account storage account = accounts[msg.sender];
        require(account.sma != address(0), "Manager: no account");

        (, address borrowCToken, uint256 netAmount) =
            _borrowFor(msg.sender, account, borrowAsset, borrowAmount, address(0));

        address collateralCToken;
        bool collateralIsUnderlying;
        (collateralCToken,, collateralIsUnderlying) = _getMarketForAsset(collateralAsset);
        {
            MarketConfig storage collateralConfig = marketConfigs[collateralCToken];
            require(collateralConfig.active, "Manager: market inactive");
            require(collateralConfig.depositsEnabled, "Manager: deposits paused");
        }
        require(collateralIsUnderlying, "Manager: collateral must be underlying");

        if (borrowAsset == collateralAsset) {
            collateralSupplied = netAmount;
        } else {
            collateralSupplied = _swapInternal(
                account.sma,
                borrowAsset,
                collateralAsset,
                borrowCToken,
                collateralCToken,
                netAmount,
                minCollateralAmount,
                routerData
            );
        }

        uint256 mintResult = SmartMarginAccount(account.sma).mint(collateralCToken, collateralSupplied);
        require(mintResult == 0, "Manager: mint failed");
        SmartMarginAccount(account.sma).enterMarket(address(peridottroller), collateralCToken);
        _ensureUserMarket(msg.sender, collateralCToken);

        MarginRiskLib.AccountMetrics memory postMetrics = MarginRiskLib.computeAccountMetricsForMarkets(
            peridottroller, priceOracle, account.sma, hfMinWithdrawBps, _getUserMarkets(msg.sender)
        );
        _syncLockState(msg.sender, account, postMetrics.healthFactorBps);

        emit LeveragedPositionOpened(
            msg.sender, borrowAsset, collateralAsset, borrowAmount, collateralSupplied, postMetrics.healthFactorBps
        );

        return collateralSupplied;
    }

    function closeLeveragedPosition(
        address collateralAsset,
        address repayAsset,
        uint256 collateralToRedeem,
        uint256 repayAmount,
        uint256 minRepayAmount,
        bytes calldata routerData
    ) external nonReentrant returns (uint256) {
        require(collateralToRedeem > 0, "Manager: zero collateral");
        require(repayAmount > 0, "Manager: zero repay");

        Account storage account = accounts[msg.sender];
        require(account.sma != address(0), "Manager: no account");

        (address collateralCToken, MarketConfig memory collateralConfig, bool collateralIsUnderlying) =
            _getMarketForAsset(collateralAsset);
        require(collateralIsUnderlying, "Manager: collateral must be underlying");

        address[] memory marketsBefore = _getUserMarkets(msg.sender);
        uint256 maxUnderlying = MarginRiskLib.maxWithdrawableUnderlyingFromMarkets(
            peridottroller, priceOracle, account.sma, collateralCToken, hfMinWithdrawBps, marketsBefore
        );
        require(collateralToRedeem <= maxUnderlying, "Manager: exceeds max withdraw");

        uint256 redeemResult = SmartMarginAccount(account.sma).redeemUnderlying(collateralCToken, collateralToRedeem);
        require(redeemResult == 0, "Manager: redeem failed");

        address repayCToken;
        uint256 repayBalance;
        {
            bool repayIsUnderlying;
            (repayCToken,, repayIsUnderlying) = _getMarketForAsset(repayAsset);
            require(repayIsUnderlying, "Manager: repay must be underlying");

            if (collateralAsset == repayAsset) {
                repayBalance = IERC20(repayAsset).balanceOf(account.sma);
            } else {
                _swapInternal(
                    account.sma,
                    collateralAsset,
                    repayAsset,
                    collateralCToken,
                    repayCToken,
                    collateralToRedeem,
                    minRepayAmount,
                    routerData
                );
                repayBalance = IERC20(repayAsset).balanceOf(account.sma);
            }
        }

        require(repayBalance >= repayAmount, "Manager: insufficient repay balance");

        uint256 repayResult = SmartMarginAccount(account.sma).repayBorrow(repayCToken, repayAmount);
        require(repayResult == 0, "Manager: repay failed");

        _pruneUserMarkets(msg.sender, account.sma);

        MarginRiskLib.AccountMetrics memory postMetrics = MarginRiskLib.computeAccountMetricsForMarkets(
            peridottroller, priceOracle, account.sma, hfMinWithdrawBps, _getUserMarkets(msg.sender)
        );
        _syncLockState(msg.sender, account, postMetrics.healthFactorBps);

        emit LeveragedPositionClosed(
            msg.sender, collateralAsset, repayAsset, collateralToRedeem, repayAmount, postMetrics.healthFactorBps
        );

        return repayAmount;
    }

    function getAccountState(address user)
        external
        view
        returns (
            int256 equity,
            uint256 collateralValue,
            uint256 borrowValue,
            uint256 healthFactorBps,
            bool withdrawalsLocked
        )
    {
        Account memory account = accounts[user];
        if (account.sma == address(0)) {
            return (0, 0, 0, type(uint256).max, false);
        }
        MarginRiskLib.AccountMetrics memory metrics = MarginRiskLib.computeAccountMetricsForMarkets(
            peridottroller, priceOracle, account.sma, hfMinWithdrawBps, _getUserMarkets(user)
        );
        return (
            metrics.equity,
            metrics.collateralValue,
            metrics.borrowValue,
            metrics.healthFactorBps,
            account.withdrawalsLocked
        );
    }

    function getAccount(address user) external view returns (Account memory) {
        return accounts[user];
    }

    function getAccountMetrics(address user) external view returns (MarginRiskLib.AccountMetrics memory metrics) {
        Account memory account = accounts[user];
        if (account.sma == address(0)) {
            return metrics;
        }
        metrics = MarginRiskLib.computeAccountMetricsForMarkets(
            peridottroller, priceOracle, account.sma, hfMinWithdrawBps, _getUserMarkets(user)
        );
    }

    function maxWithdrawable(address user, address asset) external view returns (uint256) {
        Account memory account = accounts[user];
        require(account.sma != address(0), "Manager: no account");
        (address cToken,, bool isUnderlying) = _getMarketForAsset(asset);
        address[] memory markets = _getUserMarkets(user);
        uint256 withdrawable = MarginRiskLib.maxWithdrawableUnderlyingFromMarkets(
            peridottroller, priceOracle, account.sma, cToken, hfMinWithdrawBps, markets
        );
        if (!isUnderlying) {
            uint256 exchangeRate = PErc20(cToken).exchangeRateStored();
            return (withdrawable * EXP_SCALE) / exchangeRate;
        }
        return withdrawable;
    }

    function setRouterAdapter(address newAdapter) external onlyOwner {
        routerAdapter = newAdapter;
        emit RouterAdapterUpdated(newAdapter);
    }

    function setFlashloanProvider(address newProvider) external onlyOwner {
        flashloanProvider = newProvider;
        emit FlashloanProviderUpdated(newProvider);
    }

    function setThresholds(uint16 _hfMinWithdrawBps, uint16 _hfLockBps, uint16 _hfUnlockBps) external onlyOwner {
        require(_hfMinWithdrawBps >= 10000, "Manager: hfMin too low");
        require(_hfUnlockBps > _hfLockBps, "Manager: unlock must exceed lock");
        hfMinWithdrawBps = _hfMinWithdrawBps;
        hfLockBps = _hfLockBps;
        hfUnlockBps = _hfUnlockBps;
        emit ThresholdsUpdated(_hfMinWithdrawBps, _hfLockBps, _hfUnlockBps);
    }

    function setFees(uint16 _openFeeBps, uint16 _closeFeeBps) external onlyOwner {
        require(_openFeeBps <= 100, "Manager: open fee too high");
        require(_closeFeeBps <= 100, "Manager: close fee too high");
        openFeeBps = _openFeeBps;
        closeFeeBps = _closeFeeBps;
        emit FeesUpdated(_openFeeBps, _closeFeeBps);
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    function setDefaultMaxLeverage(uint16 maxLeverageX100_) external onlyOwner {
        require(maxLeverageX100_ == 0 || maxLeverageX100_ >= 100, "Manager: leverage too low");
        defaultMaxLeverageX100 = maxLeverageX100_;
        emit DefaultLeverageUpdated(maxLeverageX100_);
    }

    function sweepFees(address asset, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Manager: invalid recipient");
        uint256 accrued = protocolFees[asset];
        require(amount <= accrued, "Manager: insufficient fees");
        protocolFees[asset] = accrued - amount;
        IERC20(asset).safeTransfer(to, amount);
        emit FeesSwept(asset, to, amount);
    }

    function _enforceLeverage(MarginRiskLib.AccountMetrics memory metrics, uint16 leverageX100) internal pure {
        if (leverageX100 == 0 || metrics.borrowValue == 0) {
            return;
        }
        require(metrics.equity > 0, "Manager: leverage invalid");
        uint256 equity = uint256(metrics.equity);
        uint256 borrowValue = metrics.borrowValue;
        require(borrowValue * 100 <= equity * leverageX100, "Manager: leverage exceeded");
    }

    function _effectiveLeverageCap(uint16 capA, uint16 capB) internal pure returns (uint16) {
        if (capA == 0) {
            return capB;
        }
        if (capB == 0) {
            return capA;
        }
        return capA < capB ? capA : capB;
    }

    function _resolveLeverageCap(uint16 marketCap) internal view returns (uint16) {
        return marketCap != 0 ? marketCap : defaultMaxLeverageX100;
    }

    function _minPositive(uint16 a, uint16 b) internal pure returns (uint16) {
        if (a == 0) {
            return b;
        }
        if (b == 0) {
            return a;
        }
        return a < b ? a : b;
    }

    function _enforceTradeBounds(
        uint256 amountIn,
        uint256 amountOut,
        uint256 expectedOut,
        uint256 priceIn,
        uint256 priceOut,
        uint16 slippageLimit,
        uint16 deviationLimit
    ) internal pure {
        if (slippageLimit > 0) {
            uint256 managerMinOut = (expectedOut * (BPS_SCALE - slippageLimit)) / BPS_SCALE;
            require(amountOut >= managerMinOut, "Manager: slippage");
        }

        if (deviationLimit > 0) {
            uint256 usdIn = (amountIn * priceIn) / EXP_SCALE;
            uint256 usdOut = (amountOut * priceOut) / EXP_SCALE;
            uint256 lower = (usdIn * (BPS_SCALE - deviationLimit)) / BPS_SCALE;
            uint256 upper = (usdIn * (BPS_SCALE + deviationLimit)) / BPS_SCALE;
            require(usdOut >= lower && usdOut <= upper, "Manager: oracle deviation");
        }
    }

    function _ensureUserMarket(address user, address cToken) internal {
        if (!accountMarketsSet[user][cToken]) {
            accountMarketsSet[user][cToken] = true;
            accountMarkets[user].push(cToken);
        }
    }

    function _getUserMarkets(address user) internal view returns (address[] memory markets) {
        address[] storage stored = accountMarkets[user];
        markets = new address[](stored.length);
        for (uint256 i = 0; i < stored.length; i++) {
            markets[i] = stored[i];
        }
    }

    function _pruneUserMarkets(address user, address sma) internal {
        address[] storage markets = accountMarkets[user];
        uint256 i = 0;
        while (i < markets.length) {
            address market = markets[i];
            uint256 supplyBal = PErc20(market).balanceOf(sma);
            uint256 borrowBal = PErc20(market).borrowBalanceStored(sma);
            if (supplyBal == 0 && borrowBal == 0) {
                accountMarketsSet[user][market] = false;
                markets[i] = markets[markets.length - 1];
                markets.pop();
                continue;
            }
            i++;
        }
    }

    function _borrowFor(address user, Account storage account, address asset, uint256 amount, address to)
        internal
        returns (MarginRiskLib.AccountMetrics memory postMetrics, address cToken, uint256 netAmount)
    {
        require(amount > 0, "Manager: zero amount");
        require(!account.withdrawalsLocked, "Manager: locked");

        (address marketToken, MarketConfig memory config, bool isUnderlying) = _getMarketForAsset(asset);
        require(config.active, "Manager: market inactive");
        require(config.borrowsEnabled, "Manager: borrows paused");
        require(isUnderlying, "Manager: must borrow underlying");

        _ensureUserMarket(user, marketToken);

        address[] memory marketsBefore = _getUserMarkets(user);
        MarginRiskLib.AccountMetrics memory preMetrics = MarginRiskLib.computeAccountMetricsForMarkets(
            peridottroller, priceOracle, account.sma, hfMinWithdrawBps, marketsBefore
        );

        require(preMetrics.collateralValue > 0, "Manager: no collateral");

        uint256 price = priceOracle.getUnderlyingPrice(PToken(marketToken));
        require(price > 0, "Manager: price zero");
        uint256 borrowValue = (amount * price) / EXP_SCALE;
        uint256 newBorrowValue = preMetrics.borrowValue + borrowValue;
        require(newBorrowValue > 0, "Manager: invalid borrow");
        uint256 projectedHF = (preMetrics.collateralValue * BPS_SCALE) / newBorrowValue;
        require(projectedHF >= hfLockBps, "Manager: health factor low");

        uint256 borrowResult = SmartMarginAccount(account.sma).borrow(marketToken, amount);
        require(borrowResult == 0, "Manager: borrow failed");

        netAmount = amount;
        if (openFeeBps > 0) {
            uint256 fee = (amount * openFeeBps) / BPS_SCALE;
            if (fee > 0) {
                netAmount = amount - fee;
                address recipient = feeRecipient;
                if (recipient == address(0)) {
                    SmartMarginAccount(account.sma).transferOut(asset, address(this), fee);
                    protocolFees[asset] += fee;
                } else {
                    SmartMarginAccount(account.sma).transferOut(asset, recipient, fee);
                }
                emit FeesAccrued(asset, fee);
            }
        }

        if (to != address(0) && to != account.sma && netAmount > 0) {
            SmartMarginAccount(account.sma).transferOut(asset, to, netAmount);
        }

        postMetrics = MarginRiskLib.computeAccountMetricsForMarkets(
            peridottroller, priceOracle, account.sma, hfMinWithdrawBps, _getUserMarkets(user)
        );
        _enforceLeverage(postMetrics, _resolveLeverageCap(config.maxLeverageX100));
        _syncLockState(user, account, postMetrics.healthFactorBps);
        cToken = marketToken;
    }

    function _swapInternal(
        address sma,
        address tokenIn,
        address tokenOut,
        address cTokenIn,
        address cTokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata routerData
    ) internal returns (uint256 amountOut) {
        require(routerAdapter != address(0), "Manager: router not set");

        uint256 priceIn = priceOracle.getUnderlyingPrice(PToken(cTokenIn));
        uint256 priceOut = priceOracle.getUnderlyingPrice(PToken(cTokenOut));
        require(priceIn > 0 && priceOut > 0, "Manager: price zero");

        MarketConfig storage configIn = marketConfigs[cTokenIn];
        MarketConfig storage configOut = marketConfigs[cTokenOut];
        require(configIn.active && configOut.active, "Manager: market inactive");
        require(configIn.tradesEnabled && configOut.tradesEnabled, "Manager: trades paused");

        uint256 expectedOut = (amountIn * priceIn) / priceOut;
        require(expectedOut > 0, "Manager: expectedOut zero");

        uint16 slippageLimit = _minPositive(configIn.tradeSlippageBps, configOut.tradeSlippageBps);
        if (slippageLimit > 0) {
            uint256 managerMinOut = (expectedOut * (BPS_SCALE - slippageLimit)) / BPS_SCALE;
            require(minAmountOut >= managerMinOut, "Manager: minOut too low");
        }
        uint16 deviationLimit = _minPositive(configIn.oracleDeviationBps, configOut.oracleDeviationBps);

        SmartMarginAccount(sma).approve(tokenIn, routerAdapter, amountIn);
        amountOut = IMarginRouterAdapter(routerAdapter).swap(sma, tokenIn, tokenOut, amountIn, minAmountOut, routerData);
        SmartMarginAccount(sma).approve(tokenIn, routerAdapter, 0);
        require(amountOut > 0, "Manager: zero output");

        _enforceTradeBounds(amountIn, amountOut, expectedOut, priceIn, priceOut, slippageLimit, deviationLimit);
    }

    function configureMarket(
        address cToken,
        address underlying,
        bool active,
        bool depositsEnabled,
        bool borrowsEnabled,
        bool withdrawalsEnabled,
        bool tradesEnabled,
        uint16 maxLeverageX100,
        uint16 tradeSlippageBps,
        uint16 oracleDeviationBps
    ) external onlyOwner {
        require(cToken != address(0) && underlying != address(0), "Manager: invalid market");
        require(tradeSlippageBps <= BPS_SCALE, "Manager: slippage too high");
        require(oracleDeviationBps <= BPS_SCALE, "Manager: deviation too high");
        require(maxLeverageX100 == 0 || maxLeverageX100 >= 100, "Manager: leverage too low");
        marketConfigs[cToken] = MarketConfig({
            active: active,
            depositsEnabled: depositsEnabled,
            borrowsEnabled: borrowsEnabled,
            withdrawalsEnabled: withdrawalsEnabled,
            tradesEnabled: tradesEnabled,
            maxLeverageX100: maxLeverageX100,
            tradeSlippageBps: tradeSlippageBps,
            oracleDeviationBps: oracleDeviationBps,
            underlying: underlying
        });
        underlyingToMarket[underlying] = cToken;

        emit MarketUpdated(
            cToken,
            underlying,
            active,
            depositsEnabled,
            borrowsEnabled,
            withdrawalsEnabled,
            tradesEnabled,
            maxLeverageX100,
            tradeSlippageBps,
            oracleDeviationBps
        );
    }

    function _getMarketForAsset(address asset)
        internal
        view
        returns (address cToken, MarketConfig memory config, bool isUnderlying)
    {
        config = marketConfigs[asset];
        if (config.underlying != address(0) || config.active) {
            cToken = asset;
            isUnderlying = false;
            return (cToken, config, isUnderlying);
        }

        cToken = underlyingToMarket[asset];
        require(cToken != address(0), "Manager: asset unsupported");
        config = marketConfigs[cToken];
        isUnderlying = true;
        return (cToken, config, isUnderlying);
    }

    function _syncLockState(address user, Account storage account, uint256 healthFactorBps) internal {
        if (!account.withdrawalsLocked && healthFactorBps < hfLockBps) {
            account.withdrawalsLocked = true;
            emit Locked(user);
        } else if (account.withdrawalsLocked && healthFactorBps >= hfUnlockBps) {
            account.withdrawalsLocked = false;
            emit Unlocked(user);
        }
    }
}

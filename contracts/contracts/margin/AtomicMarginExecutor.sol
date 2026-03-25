// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC3156FlashBorrower, IERC3156FlashLender} from "../PTokenInterfaces.sol";

import {SmartMarginAccount} from "./SmartMarginAccount.sol";
import {MarginRiskLib, IPeridottrollerView} from "./MarginRiskLib.sol";
import {IMarginRouterAdapter} from "./IMarginRouterAdapter.sol";
import {SimplePriceOracle} from "../SimplePriceOracle.sol";
import {PErc20} from "../PErc20.sol";
import {PToken} from "../PToken.sol";

interface IMarginConfigSource {
    function underlyingToMarket(address underlying) external view returns (address);
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
    function routerAdapter() external view returns (address);
    function flashloanProvider() external view returns (address);
    function peridottroller() external view returns (IPeridottrollerView);
    function priceOracle() external view returns (SimplePriceOracle);
    function hfMinWithdrawBps() external view returns (uint16);
    function hfLockBps() external view returns (uint16);
    function defaultMaxLeverageX100() external view returns (uint16);
    function openFeeBps() external view returns (uint16);
    function closeFeeBps() external view returns (uint16);
    function feeRecipient() external view returns (address);
}

contract AtomicMarginExecutor is Ownable, ReentrancyGuard, IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    uint256 private constant EXP_SCALE = 1e18;
    uint256 private constant BPS_SCALE = 1e4;
    uint256 private constant MAX_MARKETS_PER_ACCOUNT = 20;
    bytes32 private constant FLASH_CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

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

    struct PendingAtomicPosition {
        address user;
        address sma;
        address inputAsset;
        address outputAsset;
        address inputPToken;
        address outputPToken;
        uint256 userContribution;
        uint256 flashAmount;
        uint256 minOutputAmount;
        uint16 leverageX100;
        bool isLong;
        bool active;
    }

    SmartMarginAccount public immutable implementation;
    IMarginConfigSource public immutable configSource;
    address public marginCollateralVault;
    mapping(address => bool) public allowedEntryRouters;

    mapping(address => Account) public accounts;
    mapping(address => uint256) public protocolFees;
    mapping(address => address[]) private accountMarkets;
    mapping(address => mapping(address => bool)) private accountMarketsSet;

    PendingAtomicPosition private _atomicPending;

    event BorrowingEnabled(address indexed user, address sma);
    event AtomicLongOpened(
        address indexed user,
        address indexed quoteAsset,
        address indexed baseAsset,
        uint256 userCollateral,
        uint256 borrowedAmount,
        uint256 baseAcquired,
        uint256 healthFactorBps
    );
    event AtomicShortOpened(
        address indexed user,
        address indexed baseAsset,
        address indexed quoteAsset,
        uint256 userCollateral,
        uint256 borrowedAmount,
        uint256 quoteAcquired,
        uint256 healthFactorBps
    );
    event LeveragedPositionClosed(
        address indexed user,
        address indexed collateralAsset,
        address indexed repayAsset,
        uint256 collateralRedeemed,
        uint256 repayAmount,
        uint256 healthFactorBps
    );
    event FeesAccrued(address indexed asset, uint256 amount);
    event FeesSwept(address indexed asset, address indexed to, uint256 amount);
    event MarginCollateralVaultUpdated(address indexed vault);
    event EntryRouterUpdated(address indexed router, bool allowed);
    event MarginPTokenDeposited(address indexed user, address indexed pToken, uint256 amount);
    event MarginPTokenWithdrawn(address indexed user, address indexed pToken, address indexed to, uint256 amount);

    constructor(address configSource_) Ownable(msg.sender) {
        require(configSource_ != address(0), "Executor: invalid config source");
        configSource = IMarginConfigSource(configSource_);
        implementation = new SmartMarginAccount();
    }

    modifier onlyMarginCollateralVault() {
        require(msg.sender == marginCollateralVault, "Executor: not vault");
        _;
    }

    modifier onlyEntryRouter() {
        require(allowedEntryRouters[msg.sender], "Executor: not entry router");
        _;
    }

    function setMarginCollateralVault(address vault) external onlyOwner {
        require(vault != address(0), "Executor: invalid vault");
        marginCollateralVault = vault;
        emit MarginCollateralVaultUpdated(vault);
    }

    function setEntryRouter(address router, bool allowed) external onlyOwner {
        require(!allowed || router.code.length > 0, "Executor: router not contract");
        allowedEntryRouters[router] = allowed;
        emit EntryRouterUpdated(router, allowed);
    }

    function enableBorrowing() external returns (address sma) {
        return _enableBorrowing(msg.sender);
    }

    function enableBorrowingFor(address user) external onlyEntryRouter returns (address sma) {
        return _enableBorrowing(user);
    }

    function _enableBorrowing(address user) internal returns (address sma) {
        Account storage account = accounts[user];
        if (account.sma == address(0)) {
            sma = Clones.clone(address(implementation));
            SmartMarginAccount(sma).initialize(
                address(this),
                user,
                address(configSource.peridottroller())
            );
            account.sma = sma;
            emit BorrowingEnabled(user, sma);
        } else {
            sma = account.sma;
        }
    }

    function openLeveragedPositionAtomic(
        address quoteAsset,
        address baseAsset,
        uint256 userCollateral,
        uint16 leverageX100,
        uint256 minBaseReceived,
        bytes calldata routerData
    ) external nonReentrant returns (uint256 baseAcquired) {
        return
            _openLeveragedPositionAtomic(
                msg.sender,
                quoteAsset,
                baseAsset,
                userCollateral,
                leverageX100,
                minBaseReceived,
                routerData
            );
    }

    function openLeveragedPositionAtomicFor(
        address user,
        address quoteAsset,
        address baseAsset,
        uint256 userCollateral,
        uint16 leverageX100,
        uint256 minBaseReceived,
        bytes calldata routerData
    ) external nonReentrant onlyEntryRouter returns (uint256 baseAcquired) {
        return
            _openLeveragedPositionAtomic(
                user,
                quoteAsset,
                baseAsset,
                userCollateral,
                leverageX100,
                minBaseReceived,
                routerData
            );
    }

    function _openLeveragedPositionAtomic(
        address user,
        address quoteAsset,
        address baseAsset,
        uint256 userCollateral,
        uint16 leverageX100,
        uint256 minBaseReceived,
        bytes calldata routerData
    ) internal returns (uint256 baseAcquired) {
        require(userCollateral > 0, "Executor: zero collateral");
        require(leverageX100 >= 100, "Executor: leverage < 1x");
        require(minBaseReceived > 0, "Executor: zero min output");
        require(user != address(0), "Executor: invalid user");

        Account storage account = accounts[user];
        require(account.sma != address(0), "Executor: no account");
        require(!account.withdrawalsLocked, "Executor: account locked");

        (address quotePToken, MarketConfig memory quoteConfig, ) = _getMarketForAsset(quoteAsset);
        (address basePToken, MarketConfig memory baseConfig, ) = _getMarketForAsset(baseAsset);

        require(quoteConfig.active && quoteConfig.borrowsEnabled, "Executor: quote market unavailable");
        require(baseConfig.active && baseConfig.depositsEnabled, "Executor: base market unavailable");

        uint16 maxLev = _effectiveLeverageCap(
            _resolveLeverageCap(quoteConfig.maxLeverageX100),
            _resolveLeverageCap(baseConfig.maxLeverageX100)
        );
        require(leverageX100 <= maxLev, "Executor: leverage exceeds cap");

        uint256 totalNotional = (userCollateral * leverageX100) / 100;
        uint256 flashAmount = totalNotional - userCollateral;
        require(flashAmount > 0, "Executor: zero borrow");

        IERC20(quoteAsset).safeTransferFrom(user, address(this), userCollateral);

        _atomicPending = PendingAtomicPosition({
            user: user,
            sma: account.sma,
            inputAsset: quoteAsset,
            outputAsset: baseAsset,
            inputPToken: quotePToken,
            outputPToken: basePToken,
            userContribution: userCollateral,
            flashAmount: flashAmount,
            minOutputAmount: minBaseReceived,
            leverageX100: leverageX100,
            isLong: true,
            active: true
        });

        IERC3156FlashLender lender = _flashloanLender();
        bool success = lender.flashLoan(
            IERC3156FlashBorrower(address(this)),
            quoteAsset,
            flashAmount,
            routerData
        );
        require(success, "Executor: flashloan failed");

        baseAcquired = _atomicPending.minOutputAmount;
        delete _atomicPending;
    }

    function openShortPositionAtomic(
        address baseAsset,
        address quoteAsset,
        uint256 userCollateral,
        uint16 leverageX100,
        uint256 minQuoteReceived,
        bytes calldata routerData
    ) external nonReentrant returns (uint256 quoteReceived) {
        return
            _openShortPositionAtomic(
                msg.sender,
                baseAsset,
                quoteAsset,
                userCollateral,
                leverageX100,
                minQuoteReceived,
                routerData
            );
    }

    function openShortPositionAtomicFor(
        address user,
        address baseAsset,
        address quoteAsset,
        uint256 userCollateral,
        uint16 leverageX100,
        uint256 minQuoteReceived,
        bytes calldata routerData
    ) external nonReentrant onlyEntryRouter returns (uint256 quoteReceived) {
        return
            _openShortPositionAtomic(
                user,
                baseAsset,
                quoteAsset,
                userCollateral,
                leverageX100,
                minQuoteReceived,
                routerData
            );
    }

    function closeLeveragedPositionFor(
        address user,
        address collateralAsset,
        address repayAsset,
        uint256 collateralToRedeem,
        uint256 repayAmount,
        uint256 minRepayAmount,
        bytes calldata routerData
    ) external nonReentrant onlyEntryRouter returns (uint256) {
        return
            _closeLeveragedPosition(
                user,
                collateralAsset,
                repayAsset,
                collateralToRedeem,
                repayAmount,
                minRepayAmount,
                routerData
            );
    }

    function _openShortPositionAtomic(
        address user,
        address baseAsset,
        address quoteAsset,
        uint256 userCollateral,
        uint16 leverageX100,
        uint256 minQuoteReceived,
        bytes calldata routerData
    ) internal returns (uint256 quoteReceived) {
        require(userCollateral > 0, "Executor: zero collateral");
        require(leverageX100 >= 100, "Executor: leverage < 1x");
        require(minQuoteReceived > 0, "Executor: zero min output");
        require(user != address(0), "Executor: invalid user");

        Account storage account = accounts[user];
        require(account.sma != address(0), "Executor: no account");
        require(!account.withdrawalsLocked, "Executor: account locked");

        (address basePToken, MarketConfig memory baseConfig, ) = _getMarketForAsset(baseAsset);
        (address quotePToken, MarketConfig memory quoteConfig, ) = _getMarketForAsset(quoteAsset);

        require(baseConfig.active && baseConfig.borrowsEnabled, "Executor: base market unavailable");
        require(quoteConfig.active && quoteConfig.depositsEnabled, "Executor: quote market unavailable");

        uint16 maxLev = _effectiveLeverageCap(
            _resolveLeverageCap(baseConfig.maxLeverageX100),
            _resolveLeverageCap(quoteConfig.maxLeverageX100)
        );
        require(leverageX100 <= maxLev, "Executor: leverage exceeds cap");

        uint256 quotePrice = _priceOracle().getUnderlyingPrice(PToken(quotePToken));
        uint256 basePrice = _priceOracle().getUnderlyingPrice(PToken(basePToken));
        require(quotePrice > 0 && basePrice > 0, "Executor: invalid prices");

        uint256 collateralValue = (userCollateral * quotePrice) / EXP_SCALE;
        uint256 totalExposureValue = (collateralValue * leverageX100) / 100;
        uint256 borrowValue = totalExposureValue - collateralValue;
        uint256 flashAmount = (borrowValue * EXP_SCALE) / basePrice;
        require(flashAmount > 0, "Executor: zero borrow");

        IERC20(quoteAsset).safeTransferFrom(user, address(this), userCollateral);

        _atomicPending = PendingAtomicPosition({
            user: user,
            sma: account.sma,
            inputAsset: baseAsset,
            outputAsset: quoteAsset,
            inputPToken: basePToken,
            outputPToken: quotePToken,
            userContribution: userCollateral,
            flashAmount: flashAmount,
            minOutputAmount: minQuoteReceived,
            leverageX100: leverageX100,
            isLong: false,
            active: true
        });

        IERC3156FlashLender lender = _flashloanLender();
        bool success = lender.flashLoan(
            IERC3156FlashBorrower(address(this)),
            baseAsset,
            flashAmount,
            routerData
        );
        require(success, "Executor: flashloan failed");

        quoteReceived = _atomicPending.minOutputAmount;
        delete _atomicPending;
    }

    function closeLeveragedPosition(
        address collateralAsset,
        address repayAsset,
        uint256 collateralToRedeem,
        uint256 repayAmount,
        uint256 minRepayAmount,
        bytes calldata routerData
    ) external nonReentrant returns (uint256) {
        return
            _closeLeveragedPosition(
                msg.sender,
                collateralAsset,
                repayAsset,
                collateralToRedeem,
                repayAmount,
                minRepayAmount,
                routerData
            );
    }

    function _closeLeveragedPosition(
        address user,
        address collateralAsset,
        address repayAsset,
        uint256 collateralToRedeem,
        uint256 repayAmount,
        uint256 minRepayAmount,
        bytes calldata routerData
    ) internal returns (uint256) {
        require(collateralToRedeem > 0, "Executor: zero collateral");
        require(repayAmount > 0, "Executor: zero repay");

        Account storage account = accounts[user];
        require(account.sma != address(0), "Executor: no account");

        (
            address collateralCToken,
            MarketConfig memory collateralConfig,
            bool collateralIsUnderlying
        ) = _getMarketForAsset(collateralAsset);
        require(collateralIsUnderlying, "Executor: collateral must be underlying");
        require(collateralConfig.active, "Executor: collateral inactive");

        address[] memory marketsBefore = _getUserMarkets(user);
        uint256 maxUnderlying = MarginRiskLib.maxWithdrawableUnderlyingFromMarkets(
            _peridottroller(),
            _priceOracle(),
            account.sma,
            collateralCToken,
            configSource.hfMinWithdrawBps(),
            marketsBefore
        );
        require(collateralToRedeem <= maxUnderlying, "Executor: exceeds max withdraw");

        SmartMarginAccount(account.sma).redeemUnderlying(
            collateralCToken,
            collateralToRedeem
        );

        (address repayCToken, uint256 repayBalance) = _prepareRepayBalance(
            account.sma,
            collateralAsset,
            repayAsset,
            collateralCToken,
            collateralToRedeem,
            minRepayAmount,
            routerData
        );

        uint256 closeFee = _collectCloseFeeFromSma(account.sma, repayAsset, repayAmount, repayBalance);
        require(repayBalance >= repayAmount + closeFee, "Executor: insufficient repay balance");

        SmartMarginAccount(account.sma).repayBorrow(repayCToken, repayAmount);

        _pruneUserMarkets(user, account.sma);

        MarginRiskLib.AccountMetrics memory postMetrics = MarginRiskLib.computeAccountMetricsForMarkets(
            _peridottroller(),
            _priceOracle(),
            account.sma,
            configSource.hfMinWithdrawBps(),
            _getUserMarkets(user)
        );
        _syncLockState(user, account, postMetrics.healthFactorBps);

        emit LeveragedPositionClosed(
            user,
            collateralAsset,
            repayAsset,
            collateralToRedeem,
            repayAmount,
            postMetrics.healthFactorBps
        );

        return repayAmount;
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        require(initiator == address(this), "Executor: invalid initiator");
        require(_atomicPending.active, "Executor: no pending operation");
        require(msg.sender == address(_flashloanLender()), "Executor: unexpected lender");

        PendingAtomicPosition memory p = _atomicPending;
        require(token == p.inputAsset, "Executor: unexpected token");
        require(amount == p.flashAmount, "Executor: unexpected amount");

        if (p.isLong) {
            _executeAtomicLong(p, amount, fee, data);
        } else {
            _executeAtomicShort(p, amount, fee, data);
        }

        return FLASH_CALLBACK_SUCCESS;
    }

    function previewAtomicLong(
        address quoteAsset,
        uint256 userCollateral,
        uint16 leverageX100
    ) external view returns (uint256 totalNotional, uint256 borrowAmount, uint256 flashFee) {
        totalNotional = (userCollateral * leverageX100) / 100;
        borrowAmount = totalNotional - userCollateral;
        flashFee = _flashloanLender().flashFee(quoteAsset, borrowAmount);
    }

    function previewAtomicShort(
        address baseAsset,
        address quoteAsset,
        uint256 userCollateral,
        uint16 leverageX100
    ) external view returns (uint256 baseToBorrow, uint256 flashFee) {
        address quotePToken = configSource.underlyingToMarket(quoteAsset);
        address basePToken = configSource.underlyingToMarket(baseAsset);

        uint256 quotePrice = _priceOracle().getUnderlyingPrice(PToken(quotePToken));
        uint256 basePrice = _priceOracle().getUnderlyingPrice(PToken(basePToken));
        uint256 collateralValue = (userCollateral * quotePrice) / EXP_SCALE;
        uint256 totalExposure = (collateralValue * leverageX100) / 100;
        uint256 borrowValue = totalExposure - collateralValue;

        baseToBorrow = (borrowValue * EXP_SCALE) / basePrice;
        flashFee = _flashloanLender().flashFee(baseAsset, baseToBorrow);
    }

    function getAccount(address user) external view returns (Account memory) {
        return accounts[user];
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
            _peridottroller(),
            _priceOracle(),
            account.sma,
            configSource.hfMinWithdrawBps(),
            _getUserMarkets(user)
        );
        return (
            metrics.equity,
            metrics.collateralValue,
            metrics.borrowValue,
            metrics.healthFactorBps,
            account.withdrawalsLocked
        );
    }

    function getAccountMetrics(address user) external view returns (MarginRiskLib.AccountMetrics memory metrics) {
        Account memory account = accounts[user];
        if (account.sma == address(0)) {
            return metrics;
        }
        return MarginRiskLib.computeAccountMetricsForMarkets(
            _peridottroller(),
            _priceOracle(),
            account.sma,
            configSource.hfMinWithdrawBps(),
            _getUserMarkets(user)
        );
    }

    function sweepFees(address asset, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Executor: invalid recipient");
        uint256 accrued = protocolFees[asset];
        require(amount <= accrued, "Executor: amount exceeds fees");
        protocolFees[asset] = accrued - amount;
        IERC20(asset).safeTransfer(to, amount);
        emit FeesSwept(asset, to, amount);
    }

    function depositMarginPTokenFor(address user, address pToken, uint256 amount) external onlyMarginCollateralVault {
        require(user != address(0), "Executor: invalid user");
        require(amount > 0, "Executor: zero amount");

        Account storage account = accounts[user];
        require(account.sma != address(0), "Executor: no account");

        MarketConfig memory config = _marketConfig(pToken);
        require(config.underlying != address(0), "Executor: unsupported pToken");
        require(config.active && config.depositsEnabled, "Executor: market unavailable");

        IERC20(pToken).safeTransferFrom(msg.sender, account.sma, amount);
        SmartMarginAccount(account.sma).enterMarket(pToken);
        _ensureUserMarket(user, pToken);

        MarginRiskLib.AccountMetrics memory postMetrics = MarginRiskLib.computeAccountMetricsForMarkets(
            _peridottroller(),
            _priceOracle(),
            account.sma,
            configSource.hfMinWithdrawBps(),
            _getUserMarkets(user)
        );
        _syncLockState(user, account, postMetrics.healthFactorBps);

        emit MarginPTokenDeposited(user, pToken, amount);
    }

    function withdrawMarginPTokenTo(address user, address pToken, uint256 amount, address to)
        external
        onlyMarginCollateralVault
    {
        require(user != address(0), "Executor: invalid user");
        require(to != address(0), "Executor: invalid recipient");
        require(amount > 0, "Executor: zero amount");

        Account storage account = accounts[user];
        require(account.sma != address(0), "Executor: no account");

        MarketConfig memory config = _marketConfig(pToken);
        require(config.underlying != address(0), "Executor: unsupported pToken");
        require(config.active && config.withdrawalsEnabled, "Executor: withdrawals disabled");

        uint256 maxWithdrawable = _maxWithdrawablePToken(user, pToken, account.sma);
        require(amount <= maxWithdrawable, "Executor: exceeds free collateral");

        SmartMarginAccount(account.sma).transferOut(pToken, to, amount);

        if (PErc20(pToken).balanceOf(account.sma) == 0 && PErc20(pToken).borrowBalanceStored(account.sma) == 0) {
            SmartMarginAccount(account.sma).exitMarket(pToken);
        }
        _pruneUserMarkets(user, account.sma);

        MarginRiskLib.AccountMetrics memory postMetrics = MarginRiskLib.computeAccountMetricsForMarketsGraceful(
            _peridottroller(),
            _priceOracle(),
            account.sma,
            configSource.hfMinWithdrawBps(),
            _getUserMarkets(user)
        );
        _syncLockState(user, account, postMetrics.healthFactorBps);

        emit MarginPTokenWithdrawn(user, pToken, to, amount);
    }

    function maxWithdrawableMarginPToken(address user, address pToken) external view returns (uint256) {
        Account memory account = accounts[user];
        if (account.sma == address(0)) {
            return 0;
        }
        return _maxWithdrawablePToken(user, pToken, account.sma);
    }

    function _executeAtomicLong(
        PendingAtomicPosition memory p,
        uint256 flashAmount,
        uint256 flashFee,
        bytes calldata routerData
    ) internal {
        uint256 totalSwapInput = p.userContribution + flashAmount;
        uint256 adjustedInput = _collectOpenFee(p.inputAsset, totalSwapInput);

        uint256 baseAcquired = _atomicSwap(
            p.inputAsset,
            p.outputAsset,
            adjustedInput,
            p.minOutputAmount,
            routerData
        );
        require(baseAcquired >= p.minOutputAmount, "Executor: insufficient output");

        IERC20(p.outputAsset).safeTransfer(p.sma, baseAcquired);
        SmartMarginAccount(p.sma).mint(p.outputPToken, baseAcquired);
        SmartMarginAccount(p.sma).enterMarket(p.outputPToken);
        _ensureUserMarket(p.user, p.outputPToken);

        uint256 totalRepay = flashAmount + flashFee;
        SmartMarginAccount(p.sma).borrow(p.inputPToken, totalRepay);
        _ensureUserMarket(p.user, p.inputPToken);
        SmartMarginAccount(p.sma).transferOut(p.inputAsset, address(this), totalRepay);

        IERC20(p.inputAsset).forceApprove(msg.sender, totalRepay);

        MarginRiskLib.AccountMetrics memory postMetrics = MarginRiskLib.computeAccountMetricsForMarkets(
            _peridottroller(),
            _priceOracle(),
            p.sma,
            configSource.hfMinWithdrawBps(),
            _getUserMarkets(p.user)
        );
        require(postMetrics.healthFactorBps >= configSource.hfLockBps(), "Executor: health factor too low");

        uint16 leverageCap = _effectiveLeverageCap(
            _resolveLeverageCap(_marketConfig(p.inputPToken).maxLeverageX100),
            _resolveLeverageCap(_marketConfig(p.outputPToken).maxLeverageX100)
        );
        _enforceLeverage(postMetrics, leverageCap);
        _syncLockState(p.user, accounts[p.user], postMetrics.healthFactorBps);

        _atomicPending.minOutputAmount = baseAcquired;
        emit AtomicLongOpened(
            p.user,
            p.inputAsset,
            p.outputAsset,
            p.userContribution,
            totalRepay,
            baseAcquired,
            postMetrics.healthFactorBps
        );
    }

    function _executeAtomicShort(
        PendingAtomicPosition memory p,
        uint256 flashAmount,
        uint256 flashFee,
        bytes calldata routerData
    ) internal {
        uint256 quoteReceived = _atomicSwap(
            p.inputAsset,
            p.outputAsset,
            flashAmount,
            p.minOutputAmount,
            routerData
        );
        require(quoteReceived >= p.minOutputAmount, "Executor: insufficient output");

        uint256 totalCollateral = quoteReceived + p.userContribution;
        totalCollateral = _collectOpenFee(p.outputAsset, totalCollateral);

        IERC20(p.outputAsset).safeTransfer(p.sma, totalCollateral);
        SmartMarginAccount(p.sma).mint(p.outputPToken, totalCollateral);
        SmartMarginAccount(p.sma).enterMarket(p.outputPToken);
        _ensureUserMarket(p.user, p.outputPToken);

        uint256 totalRepay = flashAmount + flashFee;
        SmartMarginAccount(p.sma).borrow(p.inputPToken, totalRepay);
        _ensureUserMarket(p.user, p.inputPToken);
        SmartMarginAccount(p.sma).transferOut(p.inputAsset, address(this), totalRepay);

        IERC20(p.inputAsset).forceApprove(msg.sender, totalRepay);

        MarginRiskLib.AccountMetrics memory postMetrics = MarginRiskLib.computeAccountMetricsForMarkets(
            _peridottroller(),
            _priceOracle(),
            p.sma,
            configSource.hfMinWithdrawBps(),
            _getUserMarkets(p.user)
        );
        require(postMetrics.healthFactorBps >= configSource.hfLockBps(), "Executor: health factor too low");

        uint16 leverageCap = _effectiveLeverageCap(
            _resolveLeverageCap(_marketConfig(p.inputPToken).maxLeverageX100),
            _resolveLeverageCap(_marketConfig(p.outputPToken).maxLeverageX100)
        );
        _enforceLeverage(postMetrics, leverageCap);
        _syncLockState(p.user, accounts[p.user], postMetrics.healthFactorBps);

        _atomicPending.minOutputAmount = quoteReceived;
        emit AtomicShortOpened(
            p.user,
            p.inputAsset,
            p.outputAsset,
            p.userContribution,
            totalRepay,
            quoteReceived,
            postMetrics.healthFactorBps
        );
    }

    function _collectOpenFee(address asset, uint256 amount) internal returns (uint256 netAmount) {
        netAmount = amount;
        uint16 feeBps = configSource.openFeeBps();
        if (feeBps == 0) return netAmount;

        uint256 fee = (amount * feeBps) / BPS_SCALE;
        if (fee == 0) return netAmount;

        address recipient = configSource.feeRecipient();
        if (recipient == address(0)) {
            protocolFees[asset] += fee;
        } else {
            IERC20(asset).safeTransfer(recipient, fee);
        }
        emit FeesAccrued(asset, fee);
        netAmount = amount - fee;
    }

    function _collectCloseFeeFromSma(
        address sma,
        address asset,
        uint256 repayAmount,
        uint256 availableBalance
    ) internal returns (uint256 fee) {
        uint16 feeBps = configSource.closeFeeBps();
        if (feeBps == 0) return 0;

        fee = (repayAmount * feeBps) / BPS_SCALE;
        if (fee == 0) return 0;

        require(availableBalance >= repayAmount + fee, "Executor: insufficient repay balance");

        address recipient = configSource.feeRecipient();
        if (recipient == address(0)) {
            SmartMarginAccount(sma).transferOut(asset, address(this), fee);
            protocolFees[asset] += fee;
        } else {
            SmartMarginAccount(sma).transferOut(asset, recipient, fee);
        }
        emit FeesAccrued(asset, fee);
    }

    function _atomicSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        bytes calldata routerData
    ) internal returns (uint256 amountOut) {
        address router = configSource.routerAdapter();
        require(router != address(0), "Executor: no router");

        (address cTokenIn, MarketConfig memory configIn, bool isUnderlyingIn) = _getMarketForAsset(tokenIn);
        (address cTokenOut, MarketConfig memory configOut, bool isUnderlyingOut) = _getMarketForAsset(tokenOut);

        require(isUnderlyingIn && isUnderlyingOut, "Executor: only underlying");
        require(configIn.active && configOut.active, "Executor: market inactive");
        require(configIn.tradesEnabled && configOut.tradesEnabled, "Executor: trades paused");

        uint256 priceIn = _priceOracle().getUnderlyingPrice(PToken(cTokenIn));
        uint256 priceOut = _priceOracle().getUnderlyingPrice(PToken(cTokenOut));
        require(priceIn > 0 && priceOut > 0, "Executor: price zero");

        uint256 expectedOut = (amountIn * priceIn) / priceOut;
        require(expectedOut > 0, "Executor: expectedOut zero");

        uint16 slippageLimit = _minPositive(configIn.tradeSlippageBps, configOut.tradeSlippageBps);
        if (slippageLimit > 0) {
            uint256 managerMinOut = (expectedOut * (BPS_SCALE - slippageLimit)) / BPS_SCALE;
            require(amountOutMin >= managerMinOut, "Executor: minOut too low");
        }
        uint16 deviationLimit = _minPositive(configIn.oracleDeviationBps, configOut.oracleDeviationBps);

        uint256 tokenInBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 tokenOutBefore = IERC20(tokenOut).balanceOf(address(this));

        IERC20(tokenIn).forceApprove(router, amountIn);
        IMarginRouterAdapter(router).swap(address(this), tokenIn, tokenOut, amountIn, amountOutMin, routerData);

        uint256 tokenInAfter = IERC20(tokenIn).balanceOf(address(this));
        uint256 tokenOutAfter = IERC20(tokenOut).balanceOf(address(this));

        uint256 actualAmountIn = tokenInBefore - tokenInAfter;
        require(actualAmountIn <= amountIn, "Executor: excess tokenIn taken");

        amountOut = tokenOutAfter - tokenOutBefore;
        require(amountOut >= amountOutMin, "Executor: insufficient output");

        _enforceTradeBounds(actualAmountIn, amountOut, expectedOut, priceIn, priceOut, slippageLimit, deviationLimit);
        IERC20(tokenIn).forceApprove(router, 0);
    }

    function _swapFromSma(
        address sma,
        address tokenIn,
        address tokenOut,
        address cTokenIn,
        address cTokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata routerData
    ) internal returns (uint256 amountOut) {
        address router = configSource.routerAdapter();
        require(router != address(0), "Executor: no router");

        uint256 priceIn = _priceOracle().getUnderlyingPrice(PToken(cTokenIn));
        uint256 priceOut = _priceOracle().getUnderlyingPrice(PToken(cTokenOut));
        require(priceIn > 0 && priceOut > 0, "Executor: price zero");

        MarketConfig memory configIn = _marketConfig(cTokenIn);
        MarketConfig memory configOut = _marketConfig(cTokenOut);
        require(configIn.active && configOut.active, "Executor: market inactive");
        require(configIn.tradesEnabled && configOut.tradesEnabled, "Executor: trades paused");

        uint256 expectedOut = (amountIn * priceIn) / priceOut;
        require(expectedOut > 0, "Executor: expectedOut zero");

        uint16 slippageLimit = _minPositive(configIn.tradeSlippageBps, configOut.tradeSlippageBps);
        if (slippageLimit > 0) {
            uint256 managerMinOut = (expectedOut * (BPS_SCALE - slippageLimit)) / BPS_SCALE;
            require(minAmountOut >= managerMinOut, "Executor: minOut too low");
        }
        uint16 deviationLimit = _minPositive(configIn.oracleDeviationBps, configOut.oracleDeviationBps);

        uint256 tokenInBefore = IERC20(tokenIn).balanceOf(sma);
        uint256 tokenOutBefore = IERC20(tokenOut).balanceOf(sma);

        SmartMarginAccount(sma).approve(tokenIn, router, amountIn);
        IMarginRouterAdapter(router).swap(sma, tokenIn, tokenOut, amountIn, minAmountOut, routerData);
        SmartMarginAccount(sma).approve(tokenIn, router, 0);

        uint256 tokenInAfter = IERC20(tokenIn).balanceOf(sma);
        uint256 tokenOutAfter = IERC20(tokenOut).balanceOf(sma);

        uint256 actualAmountIn = tokenInBefore - tokenInAfter;
        require(actualAmountIn <= amountIn, "Executor: excess tokenIn taken");

        amountOut = tokenOutAfter - tokenOutBefore;
        require(amountOut >= minAmountOut, "Executor: insufficient output");
        require(amountOut > 0, "Executor: zero output");

        _enforceTradeBounds(actualAmountIn, amountOut, expectedOut, priceIn, priceOut, slippageLimit, deviationLimit);
    }

    function _prepareRepayBalance(
        address sma,
        address collateralAsset,
        address repayAsset,
        address collateralCToken,
        uint256 collateralToRedeem,
        uint256 minRepayAmount,
        bytes calldata routerData
    ) internal returns (address repayCToken, uint256 repayBalance) {
        bool repayIsUnderlying;
        (repayCToken, , repayIsUnderlying) = _getMarketForAsset(repayAsset);
        require(repayIsUnderlying, "Executor: repay must be underlying");

        if (collateralAsset == repayAsset) {
            repayBalance = IERC20(repayAsset).balanceOf(sma);
            return (repayCToken, repayBalance);
        }

        _swapFromSma(
            sma,
            collateralAsset,
            repayAsset,
            collateralCToken,
            repayCToken,
            collateralToRedeem,
            minRepayAmount,
            routerData
        );
        repayBalance = IERC20(repayAsset).balanceOf(sma);
    }

    function _getMarketForAsset(address asset) internal view returns (address cToken, MarketConfig memory config, bool isUnderlying) {
        cToken = configSource.underlyingToMarket(asset);
        if (cToken != address(0)) {
            return (cToken, _marketConfig(cToken), true);
        }
        config = _marketConfig(asset);
        require(config.underlying != address(0), "Executor: unsupported asset");
        return (asset, config, false);
    }

    function _marketConfig(address cToken) internal view returns (MarketConfig memory config) {
        (
            bool active,
            bool depositsEnabled,
            bool borrowsEnabled,
            bool withdrawalsEnabled,
            bool tradesEnabled,
            uint16 maxLeverageX100,
            uint16 tradeSlippageBps,
            uint16 oracleDeviationBps,
            address underlying
        ) = configSource.marketConfigs(cToken);

        config = MarketConfig({
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
    }

    function _peridottroller() internal view returns (IPeridottrollerView) {
        return configSource.peridottroller();
    }

    function _priceOracle() internal view returns (SimplePriceOracle) {
        return configSource.priceOracle();
    }

    function _flashloanLender() internal view returns (IERC3156FlashLender) {
        address lender = configSource.flashloanProvider();
        require(lender != address(0), "Executor: flashloan provider unset");
        return IERC3156FlashLender(lender);
    }

    function _resolveLeverageCap(uint16 marketCap) internal view returns (uint16) {
        return marketCap != 0 ? marketCap : configSource.defaultMaxLeverageX100();
    }

    function _effectiveLeverageCap(uint16 capA, uint16 capB) internal pure returns (uint16) {
        if (capA == 0) return capB;
        if (capB == 0) return capA;
        return capA < capB ? capA : capB;
    }

    function _minPositive(uint16 a, uint16 b) internal pure returns (uint16) {
        if (a == 0) return b;
        if (b == 0) return a;
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
            require(amountOut >= managerMinOut, "Executor: slippage");
        }

        if (deviationLimit > 0) {
            uint256 usdIn = (amountIn * priceIn) / EXP_SCALE;
            uint256 usdOut = (amountOut * priceOut) / EXP_SCALE;
            uint256 lower = (usdIn * (BPS_SCALE - deviationLimit)) / BPS_SCALE;
            uint256 upper = (usdIn * (BPS_SCALE + deviationLimit)) / BPS_SCALE;
            require(usdOut >= lower && usdOut <= upper, "Executor: oracle deviation");
        }
    }

    function _enforceLeverage(MarginRiskLib.AccountMetrics memory metrics, uint16 leverageX100) internal pure {
        if (leverageX100 == 0 || metrics.borrowValue == 0) return;
        require(metrics.equity > 0, "Executor: leverage invalid");
        uint256 equity = uint256(metrics.equity);
        require(metrics.borrowValue * 100 <= equity * leverageX100, "Executor: leverage exceeded");
    }

    function _syncLockState(address, Account storage account, uint256 healthFactorBps) internal {
        if (!account.withdrawalsLocked && healthFactorBps < configSource.hfLockBps()) {
            account.withdrawalsLocked = true;
        } else if (account.withdrawalsLocked && healthFactorBps >= configSource.hfLockBps()) {
            account.withdrawalsLocked = false;
        }
        account.lastHealthRecalc = uint64(block.timestamp);
    }

    function _ensureUserMarket(address user, address cToken) internal {
        if (!accountMarketsSet[user][cToken]) {
            require(accountMarkets[user].length < MAX_MARKETS_PER_ACCOUNT, "Executor: max markets reached");
            accountMarketsSet[user][cToken] = true;
            accountMarkets[user].push(cToken);
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

    function _getUserMarkets(address user) internal view returns (address[] memory markets) {
        address[] storage stored = accountMarkets[user];
        markets = new address[](stored.length);
        for (uint256 i = 0; i < stored.length; i++) {
            markets[i] = stored[i];
        }
    }

    function _maxWithdrawablePToken(address user, address pToken, address sma) internal view returns (uint256) {
        uint256 maxUnderlying = MarginRiskLib.maxWithdrawableUnderlyingFromMarkets(
            _peridottroller(),
            _priceOracle(),
            sma,
            pToken,
            configSource.hfMinWithdrawBps(),
            _getUserMarkets(user)
        );

        if (maxUnderlying == 0) {
            return 0;
        }

        uint256 exchangeRate = PErc20(pToken).exchangeRateStored();
        if (exchangeRate == 0) {
            return 0;
        }

        uint256 maxPToken = (maxUnderlying * EXP_SCALE) / exchangeRate;
        uint256 pTokenBalance = PErc20(pToken).balanceOf(sma);
        return maxPToken < pTokenBalance ? maxPToken : pTokenBalance;
    }
}

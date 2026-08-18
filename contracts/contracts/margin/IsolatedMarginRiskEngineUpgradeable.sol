// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC3156FlashLender} from "../PTokenInterfaces.sol";
import {PErc20} from "../PErc20.sol";
import {IsolatedMarginMath} from "./IsolatedMarginMath.sol";
import {IsolatedMarginTypes} from "./IsolatedMarginTypes.sol";
import {IIsolatedMarginConfig} from "./interfaces/IIsolatedMarginConfig.sol";
import {IIsolatedMarginRiskHook} from "./interfaces/IIsolatedMarginRiskHook.sol";
import {IMarginPriceOracle} from "./interfaces/IMarginPriceOracle.sol";

interface IIsolatedMarginControllerRegistry {
    function registerIsolatedMarginAccount(address account) external;
}

contract IsolatedMarginRiskEngineUpgradeable is Initializable, OwnableUpgradeable, IIsolatedMarginRiskHook {
    uint256 public constant BPS = 10_000;
    uint256 public constant DUST_DEBT_VALUE_USD = 10e18;

    struct AccountConfig {
        uint256 positionId;
        address owner;
        address marginPToken;
        address positionPToken;
        address debtPToken;
        IsolatedMarginTypes.Side side;
        IsolatedMarginTypes.Status status;
    }

    struct MovementAuthorization {
        uint256 remainingAmount;
        uint64 blockNumber;
    }

    IIsolatedMarginConfig public config;
    IMarginPriceOracle public oracle;
    address public controller;
    address public executor;
    address public liquidator;

    mapping(address account => AccountConfig) public accounts;
    mapping(address account => bool) public override isIsolatedMarginAccount;
    mapping(address account => mapping(address pToken => MovementAuthorization)) public movementAuthorizations;

    event OperatorsConfigured(address indexed executor, address indexed liquidator);
    event AccountRegistered(
        uint256 indexed positionId,
        address indexed account,
        address indexed owner,
        address marginPToken,
        address positionPToken,
        address debtPToken,
        IsolatedMarginTypes.Side side
    );
    event AccountStatusUpdated(address indexed account, IsolatedMarginTypes.Status status);
    event MovementAuthorized(address indexed account, address indexed pToken, uint256 amount);

    error PriceUnavailable(address asset);

    constructor() {
        _disableInitializers();
    }

    modifier onlyController() {
        require(msg.sender == controller, "RiskEngine: not controller");
        _;
    }

    modifier onlyExecutor() {
        require(msg.sender == executor, "RiskEngine: not executor");
        _;
    }

    modifier onlyLiquidator() {
        require(msg.sender == liquidator, "RiskEngine: not liquidator");
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == executor || msg.sender == liquidator, "RiskEngine: not operator");
        _;
    }

    function initialize(address owner_, address config_, address oracle_, address controller_) external initializer {
        require(owner_ != address(0), "RiskEngine: zero owner");
        require(config_.code.length > 0, "RiskEngine: invalid config");
        require(oracle_.code.length > 0, "RiskEngine: invalid oracle");
        require(controller_.code.length > 0, "RiskEngine: invalid controller");
        __Ownable_init(owner_);
        config = IIsolatedMarginConfig(config_);
        oracle = IMarginPriceOracle(oracle_);
        controller = controller_;
    }

    function setOperators(address executor_, address liquidator_) external onlyOwner {
        require(executor_.code.length > 0, "RiskEngine: invalid executor");
        require(liquidator_ == address(0) || liquidator_.code.length > 0, "RiskEngine: invalid liquidator");
        executor = executor_;
        liquidator = liquidator_;
        emit OperatorsConfigured(executor_, liquidator_);
    }

    function registerAccount(
        uint256 positionId,
        address account,
        address owner_,
        address marginPToken,
        address positionPToken,
        address debtPToken,
        IsolatedMarginTypes.Side side
    ) external onlyExecutor {
        require(positionId != 0, "RiskEngine: zero position");
        require(account.code.length > 0 && owner_ != address(0), "RiskEngine: invalid account");
        require(!isIsolatedMarginAccount[account], "RiskEngine: already registered");
        require(oracle.marketAsset(marginPToken) != address(0), "RiskEngine: margin market missing");
        require(oracle.marketAsset(positionPToken) != address(0), "RiskEngine: position market missing");
        require(oracle.marketAsset(debtPToken) != address(0), "RiskEngine: debt market missing");

        IsolatedMarginTypes.PairRiskConfig memory pairRisk =
            config.getPairRisk(marginPToken, positionPToken, debtPToken);
        require(pairRisk.enabled, "RiskEngine: pair disabled");

        accounts[account] = AccountConfig({
            positionId: positionId,
            owner: owner_,
            marginPToken: marginPToken,
            positionPToken: positionPToken,
            debtPToken: debtPToken,
            side: side,
            status: IsolatedMarginTypes.Status.OPENING
        });
        isIsolatedMarginAccount[account] = true;
        IIsolatedMarginControllerRegistry(controller).registerIsolatedMarginAccount(account);

        emit AccountRegistered(positionId, account, owner_, marginPToken, positionPToken, debtPToken, side);
        emit AccountStatusUpdated(account, IsolatedMarginTypes.Status.OPENING);
    }

    function activateAccount(address account) external onlyExecutor {
        AccountConfig storage accountConfig = accounts[account];
        require(
            accountConfig.status == IsolatedMarginTypes.Status.OPENING
                || accountConfig.status == IsolatedMarginTypes.Status.CLOSING,
            "RiskEngine: invalid activation"
        );
        if (accountConfig.status == IsolatedMarginTypes.Status.OPENING) {
            IsolatedMarginTypes.AccountMetrics memory currentMetrics = _metrics(account, 0);
            IsolatedMarginTypes.PairRiskConfig memory pairRisk = _pairRisk(accountConfig);
            IsolatedMarginMath.validateOpen(currentMetrics, pairRisk);
        }
        accountConfig.status = IsolatedMarginTypes.Status.ACTIVE;
        emit AccountStatusUpdated(account, IsolatedMarginTypes.Status.ACTIVE);
    }

    function beginClose(address account) external onlyExecutor returns (uint256 healthFactorBps) {
        AccountConfig storage accountConfig = accounts[account];
        require(accountConfig.status == IsolatedMarginTypes.Status.ACTIVE, "RiskEngine: not active");
        healthFactorBps = _metrics(account, 0).healthFactorBps;
        accountConfig.status = IsolatedMarginTypes.Status.CLOSING;
        emit AccountStatusUpdated(account, IsolatedMarginTypes.Status.CLOSING);
    }

    /// @notice Starts an in-kind recovery exit without consulting price feeds.
    /// @dev The executor must accrue the debt market first. Only raw-zero-debt accounts qualify.
    function beginDebtFreeClose(address account) external onlyExecutor {
        AccountConfig storage accountConfig = accounts[account];
        require(accountConfig.status == IsolatedMarginTypes.Status.ACTIVE, "RiskEngine: not active");
        require(PErc20(accountConfig.debtPToken).borrowBalanceStored(account) == 0, "RiskEngine: debt remains");
        accountConfig.status = IsolatedMarginTypes.Status.CLOSING;
        emit AccountStatusUpdated(account, IsolatedMarginTypes.Status.CLOSING);
    }

    function finishClose(address account, uint256 previousHealthFactorBps, bool fullyClosed)
        external
        onlyExecutor
        returns (IsolatedMarginTypes.AccountMetrics memory currentMetrics)
    {
        AccountConfig storage accountConfig = accounts[account];
        require(accountConfig.status == IsolatedMarginTypes.Status.CLOSING, "RiskEngine: not closing");
        if (fullyClosed) {
            require(PErc20(accountConfig.debtPToken).borrowBalanceStored(account) == 0, "RiskEngine: debt remains");
            accountConfig.status = IsolatedMarginTypes.Status.CLOSED;
        } else {
            currentMetrics = _metrics(account, 0);
            require(currentMetrics.equityUsd > 0, "RiskEngine: negative equity");
            require(currentMetrics.healthFactorBps >= previousHealthFactorBps, "RiskEngine: close worsened health");
            accountConfig.status = IsolatedMarginTypes.Status.ACTIVE;
        }
        emit AccountStatusUpdated(account, accountConfig.status);
    }

    function beginLiquidation(address account)
        external
        onlyLiquidator
        returns (uint256 maxRepayUnderlying, uint256 previousHealthFactorBps)
    {
        AccountConfig storage accountConfig = accounts[account];
        require(accountConfig.status == IsolatedMarginTypes.Status.ACTIVE, "RiskEngine: not active");
        IsolatedMarginTypes.AccountMetrics memory currentMetrics = _metrics(account, 0);
        require(IsolatedMarginMath.isLiquidatable(currentMetrics), "RiskEngine: healthy");

        IsolatedMarginTypes.PairRiskConfig memory pairRisk = _pairRisk(accountConfig);
        uint256 debt = PErc20(accountConfig.debtPToken).borrowBalanceStored(account);
        if (
            currentMetrics.healthFactorBps <= pairRisk.fullLiquidationHealthBps
                || currentMetrics.debtValueUsd <= DUST_DEBT_VALUE_USD
        ) {
            maxRepayUnderlying = debt;
        } else {
            maxRepayUnderlying = Math.mulDiv(debt, pairRisk.maxLiquidationBps, BPS);
            (uint256 requiredSeizeValueUsd,) = _liquidationQuote(accountConfig, maxRepayUnderlying);
            uint256 requiredPositionPTokens =
                _pTokenForUsd(accountConfig.positionPToken, requiredSeizeValueUsd, Math.Rounding.Ceil);
            uint256 repayValueUsd = underlyingValueUsd(accountConfig.debtPToken, maxRepayUnderlying);
            uint256 projectedGrossAssetValueUsd = currentMetrics.grossAssetValueUsd > requiredSeizeValueUsd
                ? currentMetrics.grossAssetValueUsd - requiredSeizeValueUsd
                : 0;
            uint256 projectedDebtValueUsd =
                currentMetrics.debtValueUsd > repayValueUsd ? currentMetrics.debtValueUsd - repayValueUsd : 0;
            IsolatedMarginTypes.AccountMetrics memory projectedMetrics = IsolatedMarginMath.calculateMetrics(
                projectedGrossAssetValueUsd,
                projectedDebtValueUsd,
                pairRisk.initialMarginBps,
                pairRisk.maintenanceMarginBps
            );
            bool partialWouldNotImprove = projectedMetrics.healthFactorBps < pairRisk.liquidationTargetBps
                && projectedMetrics.healthFactorBps <= currentMetrics.healthFactorBps;
            if (
                requiredSeizeValueUsd >= currentMetrics.grossAssetValueUsd || partialWouldNotImprove
                    || requiredPositionPTokens >= PErc20(accountConfig.positionPToken).balanceOf(account)
            ) {
                maxRepayUnderlying = debt;
            }
        }
        previousHealthFactorBps = currentMetrics.healthFactorBps;
        accountConfig.status = IsolatedMarginTypes.Status.LIQUIDATING;
        emit AccountStatusUpdated(account, IsolatedMarginTypes.Status.LIQUIDATING);
    }

    function finishLiquidation(address account, bool fullyLiquidated, uint256 previousHealthFactorBps)
        external
        onlyLiquidator
        returns (IsolatedMarginTypes.AccountMetrics memory currentMetrics)
    {
        AccountConfig storage accountConfig = accounts[account];
        require(accountConfig.status == IsolatedMarginTypes.Status.LIQUIDATING, "RiskEngine: not liquidating");
        if (fullyLiquidated) {
            require(PErc20(accountConfig.debtPToken).borrowBalanceStored(account) == 0, "RiskEngine: debt remains");
            accountConfig.status = IsolatedMarginTypes.Status.LIQUIDATED;
        } else {
            currentMetrics = _metrics(account, 0);
            IsolatedMarginTypes.PairRiskConfig memory pairRisk = _pairRisk(accountConfig);
            require(
                currentMetrics.healthFactorBps >= pairRisk.liquidationTargetBps
                    || currentMetrics.healthFactorBps > previousHealthFactorBps,
                "RiskEngine: health not improved"
            );
            accountConfig.status = IsolatedMarginTypes.Status.ACTIVE;
        }
        emit AccountStatusUpdated(account, accountConfig.status);
    }

    function authorizeMovement(address account, address pToken, uint256 amount) external onlyOperator {
        AccountConfig memory accountConfig = accounts[account];
        bool debtRepayMovement = msg.sender == executor && pToken == accountConfig.debtPToken
            && accountConfig.status == IsolatedMarginTypes.Status.ACTIVE;
        require(
            accountConfig.status == IsolatedMarginTypes.Status.CLOSING
                || accountConfig.status == IsolatedMarginTypes.Status.LIQUIDATING || debtRepayMovement,
            "RiskEngine: movement not allowed"
        );
        require(
            pToken == accountConfig.positionPToken || pToken == accountConfig.marginPToken
                || (msg.sender == executor && pToken == accountConfig.debtPToken),
            "RiskEngine: wrong collateral"
        );
        require(amount > 0, "RiskEngine: zero movement");
        movementAuthorizations[account][pToken] =
            MovementAuthorization({remainingAmount: amount, blockNumber: uint64(block.number)});
        emit MovementAuthorized(account, pToken, amount);
    }

    function borrowAllowed(address account, address debtPToken, uint256 borrowAmount)
        external
        override
        onlyController
        returns (bool)
    {
        AccountConfig memory accountConfig = accounts[account];
        if (
            accountConfig.status != IsolatedMarginTypes.Status.OPENING || debtPToken != accountConfig.debtPToken
                || borrowAmount == 0
        ) return false;

        IsolatedMarginTypes.PairRiskConfig memory pairRisk = _pairRisk(accountConfig);
        if (!pairRisk.enabled) return false;

        IsolatedMarginTypes.AccountMetrics memory projected = _metrics(account, borrowAmount);
        if (projected.equityUsd <= 0 || uint256(projected.equityUsd) < projected.initialRequirementUsd) {
            return false;
        }
        if (projected.leverageX100 > pairRisk.maxLeverageX100) return false;
        if (pairRisk.maxPositionValueUsd != 0 && projected.grossAssetValueUsd > pairRisk.maxPositionValueUsd) {
            return false;
        }
        if (pairRisk.maxDebtValueUsd != 0 && projected.debtValueUsd > pairRisk.maxDebtValueUsd) return false;
        return true;
    }

    function redeemAllowed(address account, address collateralPToken, uint256 redeemTokens)
        external
        override
        onlyController
        returns (bool)
    {
        return _consumeMovement(account, collateralPToken, redeemTokens);
    }

    function transferAllowed(address account, address collateralPToken, uint256 transferTokens)
        external
        override
        onlyController
        returns (bool)
    {
        return _consumeMovement(account, collateralPToken, transferTokens);
    }

    function getMetrics(address account) external view returns (IsolatedMarginTypes.AccountMetrics memory) {
        require(isIsolatedMarginAccount[account], "RiskEngine: unknown account");
        return _metrics(account, 0);
    }

    function isLiquidatable(address account) external view returns (bool) {
        if (!isIsolatedMarginAccount[account]) return false;
        return IsolatedMarginMath.isLiquidatable(_metrics(account, 0));
    }

    function pTokenValueUsd(address pToken, uint256 pTokenAmount) public view returns (uint256) {
        if (pTokenAmount == 0) return 0;
        address asset = oracle.marketAsset(pToken);
        if (asset == address(0)) revert PriceUnavailable(asset);
        uint256 priceUsd = oracle.getPrice(asset);
        if (priceUsd == 0) revert PriceUnavailable(asset);
        uint256 underlyingAmount =
            IsolatedMarginMath.underlyingFromPToken(pTokenAmount, PErc20(pToken).exchangeRateStored());
        return IsolatedMarginMath.valueUsd(underlyingAmount, IERC20Metadata(asset).decimals(), priceUsd);
    }

    function underlyingValueUsd(address pToken, uint256 underlyingAmount) public view returns (uint256) {
        address asset = oracle.marketAsset(pToken);
        if (asset == address(0)) revert PriceUnavailable(asset);
        uint256 priceUsd = oracle.getPrice(asset);
        if (priceUsd == 0) revert PriceUnavailable(asset);
        return IsolatedMarginMath.valueUsd(underlyingAmount, IERC20Metadata(asset).decimals(), priceUsd);
    }

    function getLiquidationQuote(address account, uint256 repayUnderlying)
        external
        view
        returns (uint256 seizeValueUsd, uint256 flashFeeUnderlying)
    {
        require(isIsolatedMarginAccount[account] && repayUnderlying > 0, "RiskEngine: invalid quote");
        return _liquidationQuote(accounts[account], repayUnderlying);
    }

    function _liquidationQuote(AccountConfig memory accountConfig, uint256 repayUnderlying)
        internal
        view
        returns (uint256 seizeValueUsd, uint256 flashFeeUnderlying)
    {
        IsolatedMarginTypes.PairRiskConfig memory pairRisk = _pairRisk(accountConfig);
        address debtAsset = oracle.marketAsset(accountConfig.debtPToken);
        address positionAsset = oracle.marketAsset(accountConfig.positionPToken);
        address lender = config.flashLoanProvider();
        require(debtAsset != address(0) && positionAsset != address(0), "RiskEngine: market missing");
        require(lender.code.length > 0, "RiskEngine: lender unavailable");

        flashFeeUnderlying = IERC3156FlashLender(lender).flashFee(debtAsset, repayUnderlying);
        uint256 repayValueUsd = underlyingValueUsd(accountConfig.debtPToken, repayUnderlying);
        uint256 flashFeeValueUsd = underlyingValueUsd(accountConfig.debtPToken, flashFeeUnderlying);
        uint256 bonusValueUsd = Math.mulDiv(repayValueUsd, pairRisk.liquidationBonusBps, BPS, Math.Rounding.Ceil);
        seizeValueUsd = repayValueUsd + flashFeeValueUsd + bonusValueUsd;

        // The seized collateral is sold into the debt asset. Reserve enough input
        // to repay at the worst output permitted by the pair's swap bound.
        if (positionAsset != debtAsset) {
            seizeValueUsd = Math.mulDiv(seizeValueUsd, BPS, BPS - pairRisk.maxSlippageBps, Math.Rounding.Ceil);
        }
    }

    function _pTokenForUsd(address pToken, uint256 valueUsd, Math.Rounding rounding) internal view returns (uint256) {
        address asset = oracle.marketAsset(pToken);
        if (asset == address(0)) revert PriceUnavailable(asset);
        uint256 priceUsd = oracle.getPrice(asset);
        if (priceUsd == 0) revert PriceUnavailable(asset);
        return IsolatedMarginMath.pTokenForUsd(
            valueUsd, IERC20Metadata(asset).decimals(), priceUsd, PErc20(pToken).exchangeRateStored(), rounding
        );
    }

    function _metrics(address account, uint256 additionalBorrow)
        internal
        view
        returns (IsolatedMarginTypes.AccountMetrics memory)
    {
        AccountConfig memory accountConfig = accounts[account];
        uint256 grossAssetValueUsd =
            pTokenValueUsd(accountConfig.positionPToken, PErc20(accountConfig.positionPToken).balanceOf(account));
        if (accountConfig.marginPToken != accountConfig.positionPToken) {
            grossAssetValueUsd += pTokenValueUsd(
                accountConfig.marginPToken, PErc20(accountConfig.marginPToken).balanceOf(account)
            );
        }

        uint256 debt = PErc20(accountConfig.debtPToken).borrowBalanceStored(account) + additionalBorrow;
        uint256 debtValueUsd = underlyingValueUsd(accountConfig.debtPToken, debt);
        IsolatedMarginTypes.PairRiskConfig memory pairRisk = _pairRisk(accountConfig);
        return IsolatedMarginMath.calculateMetrics(
            grossAssetValueUsd, debtValueUsd, pairRisk.initialMarginBps, pairRisk.maintenanceMarginBps
        );
    }

    function _pairRisk(AccountConfig memory accountConfig)
        internal
        view
        returns (IsolatedMarginTypes.PairRiskConfig memory)
    {
        return config.getPairRisk(accountConfig.marginPToken, accountConfig.positionPToken, accountConfig.debtPToken);
    }

    function _consumeMovement(address account, address pToken, uint256 amount) internal returns (bool) {
        if (!isIsolatedMarginAccount[account]) return false;

        if (PErc20(accounts[account].debtPToken).borrowBalanceStored(account) == 0) return true;

        MovementAuthorization storage authorization = movementAuthorizations[account][pToken];
        if (authorization.blockNumber != block.number || amount == 0 || amount > authorization.remainingAmount) {
            return false;
        }
        authorization.remainingAmount -= amount;
        if (authorization.remainingAmount == 0) delete movementAuthorizations[account][pToken];
        return true;
    }

    uint256[40] private __gap;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PErc20} from "../PErc20.sol";
import {IERC3156FlashLender} from "../PTokenInterfaces.sol";
import {IsolatedMarginAccount} from "./IsolatedMarginAccount.sol";
import {IsolatedMarginTypes as Types} from "./IsolatedMarginTypes.sol";
import {CollateralPreservingMarginMath as MarginMath} from "./CollateralPreservingMarginMath.sol";
import {CollateralPreservingSettlementModule} from "./CollateralPreservingSettlementModule.sol";
import {IsolatedMarginQuoter} from "./IsolatedMarginQuoter.sol";
import {IIsolatedMarginConfig} from "./interfaces/IIsolatedMarginConfig.sol";
import {IIsolatedMarginRiskHook} from "./interfaces/IIsolatedMarginRiskHook.sol";

interface ICollateralPreservingRegistry {
    function registerIsolatedMarginAccount(address account) external;
}

/// @notice Fresh-stack risk hook. NOT storage/semantic-compatible with the legacy hook.
/// @dev Marked trade/equity leverage; collateral is separate, haircutted vault-share NAV.
/// Exit reserves include quoted flash fees, closing fee and configured swap slippage.
/// Prices/metrics are stored-market views: executor MUST accrue all three markets first.
contract CollateralPreservingRiskEngine is Ownable, IIsolatedMarginRiskHook {
    bytes32 public constant executionVersion = keccak256("collateral-preserving-risk-v1");
    CollateralPreservingSettlementModule public immutable settlement;
    IsolatedMarginQuoter public immutable quoter;
    IIsolatedMarginConfig public immutable config;
    address public immutable controller;
    uint16 public immutable usdCollateralWeightBps;
    uint16 public immutable avaxCollateralWeightBps;
    address public executor;

    struct Account {
        address collateral;
        address position;
        address debt;
        Types.Status status;
        uint16 requestedLeverageX100;
    }

    struct Snapshot {
        MarginMath.Metrics metrics;
        uint256 collateralUsd;
        uint256 tradingUsd;
        uint256 debtUsd;
        uint256 exposureUsd;
        uint256 exitCostsUsd;
    }

    struct Authorization {
        uint256 amount;
        uint256 blockNumber;
    }
    mapping(address => Account) public accounts;
    mapping(address => bool) public override isIsolatedMarginAccount;
    mapping(address => mapping(address => Authorization)) public movements;

    error InvalidConfiguration();
    error Unauthorized();
    error InvalidState();
    error UnsafePosition();
    event ExecutorBound(address indexed executor);
    event StatusChanged(address indexed account, Types.Status status);

    constructor(address owner_, address settlement_, uint16 usdWeight, uint16 avaxWeight) Ownable(owner_) {
        if (
            settlement_.code.length == 0 || usdWeight == 0 || usdWeight > 10_000 || avaxWeight == 0
                || avaxWeight > 10_000
        ) {
            revert InvalidConfiguration();
        }
        settlement = CollateralPreservingSettlementModule(settlement_);
        quoter = settlement.quoter();
        config = settlement.config();
        controller = settlement.controller();
        usdCollateralWeightBps = usdWeight;
        avaxCollateralWeightBps = avaxWeight;
    }

    modifier onlyExecutor() {
        if (msg.sender != executor) revert Unauthorized();
        _;
    }
    modifier onlyController() {
        if (msg.sender != controller) revert Unauthorized();
        _;
    }

    function setExecutor(address value) external onlyOwner {
        if (executor != address(0) || value.code.length == 0) revert InvalidConfiguration();
        executor = value;
        emit ExecutorBound(value);
    }

    // The fresh executor also owns the public, risk-gated liquidation entry point.
    function liquidator() external view returns (address) {
        return executor;
    }

    function register(address account, uint16 requestedLeverage) external onlyExecutor {
        IsolatedMarginAccount a = IsolatedMarginAccount(account);
        if (isIsolatedMarginAccount[account] || a.manager() != executor || a.riskEngine() != address(this)) {
            revert InvalidConfiguration();
        }
        Account memory entry =
            Account(a.marginPToken(), a.positionPToken(), a.debtPToken(), Types.Status.OPENING, requestedLeverage);
        _validateMarkets(entry);
        Types.PairRiskConfig memory r = pair(entry);
        if (!r.enabled || config.opensPaused() || requestedLeverage <= 100 || requestedLeverage > r.maxLeverageX100) {
            revert UnsafePosition();
        }
        accounts[account] = entry;
        isIsolatedMarginAccount[account] = true;
        ICollateralPreservingRegistry(controller).registerIsolatedMarginAccount(account);
        emit StatusChanged(account, Types.Status.OPENING);
    }

    function activate(address account) external onlyExecutor {
        Account memory a = accounts[account];
        if (a.status != Types.Status.OPENING || !_fits(snapshot(account, 0), pair(a), a.requestedLeverageX100)) {
            revert UnsafePosition();
        }
        accounts[account].status = Types.Status.ACTIVE;
        emit StatusChanged(account, Types.Status.ACTIVE);
    }

    function begin(address account, bool liquidation) external onlyExecutor returns (Snapshot memory s) {
        if (accounts[account].status != Types.Status.ACTIVE) revert InvalidState();
        s = snapshot(account, 0);
        if (liquidation && !s.metrics.liquidatable) revert UnsafePosition();
        accounts[account].status = liquidation ? Types.Status.LIQUIDATING : Types.Status.CLOSING;
        emit StatusChanged(account, accounts[account].status);
    }

    /// @notice Oracle-independent preparation for an owner-funded emergency exit.
    /// @dev Accrue only debt. Executor MUST call finish(full=true) after repayment,
    /// before releasing shares; that independently requires raw zero debt.
    function beginEmergencyClose(address account) external onlyExecutor returns (uint256 debt) {
        Account memory a = accounts[account];
        if (!config.opensPaused() || a.status != Types.Status.ACTIVE) revert InvalidState();
        if (PErc20(a.debt).accrueInterest() != 0 || !PErc20(a.debt).borrowAccountingEnabled()) {
            revert InvalidConfiguration();
        }
        debt = PErc20(a.debt).borrowBalanceStored(account);
        accounts[account].status = Types.Status.CLOSING;
        emit StatusChanged(account, Types.Status.CLOSING);
    }

    function finish(address account, bool full, uint256 previousHealth) external onlyExecutor {
        Account memory a = accounts[account];
        bool liquidation = a.status == Types.Status.LIQUIDATING;
        if (!liquidation && a.status != Types.Status.CLOSING) revert InvalidState();
        if (full) {
            if (PErc20(a.debt).borrowBalanceStored(account) != 0) revert UnsafePosition();
            accounts[account].status = liquidation ? Types.Status.LIQUIDATED : Types.Status.CLOSED;
        } else {
            Snapshot memory s = snapshot(account, 0);
            if (
                s.metrics.equityUsd <= 0 || s.metrics.healthFactorBps < previousHealth
                    || (liquidation && s.metrics.healthFactorBps <= previousHealth)
            ) revert UnsafePosition();
            accounts[account].status = Types.Status.ACTIVE;
        }
        delete movements[account][a.collateral];
        delete movements[account][a.position];
        emit StatusChanged(account, accounts[account].status);
    }

    function authorize(address account, address market, uint256 amount) external onlyExecutor {
        Account memory a = accounts[account];
        if (
            (a.status != Types.Status.CLOSING && a.status != Types.Status.LIQUIDATING)
                || (market != a.collateral && market != a.position)
        ) revert InvalidState();
        movements[account][market] = Authorization(amount, block.number);
    }

    function borrowAllowed(address account, address market, uint256 amount)
        external
        view
        override
        onlyController
        returns (bool)
    {
        Account memory a = accounts[account];
        if (a.status != Types.Status.OPENING || a.debt != market || amount == 0 || config.opensPaused()) return false;
        Types.PairRiskConfig memory r = pair(a);
        return r.enabled && _fits(snapshot(account, amount), r, a.requestedLeverageX100);
    }

    function redeemAllowed(address account, address market, uint256 amount)
        external
        override
        onlyController
        returns (bool)
    {
        return _consume(account, market, amount);
    }

    function transferAllowed(address account, address market, uint256 amount)
        external
        override
        onlyController
        returns (bool)
    {
        return _consume(account, market, amount);
    }

    function _consume(address account, address market, uint256 amount) private returns (bool) {
        Account memory a = accounts[account];
        if (!isIsolatedMarginAccount[account]) return false;
        if (PErc20(a.debt).borrowBalanceStored(account) == 0) return true;
        Authorization storage permission = movements[account][market];
        if (permission.blockNumber != block.number || amount == 0 || amount > permission.amount) return false;
        permission.amount -= amount;
        return true;
    }

    function snapshot(address account, uint256 additionalDebt) public view returns (Snapshot memory) {
        Account memory a = accounts[account];
        if (!isIsolatedMarginAccount[account]) revert InvalidState();
        _validateMarkets(a);
        return evaluate(
            a,
            PErc20(a.collateral).balanceOf(account),
            PErc20(a.position).balanceOf(account),
            PErc20(a.debt).borrowBalanceStored(account) + additionalDebt
        );
    }

    function evaluate(Account memory a, uint256 collateralShares, uint256 positionShares, uint256 debtAmount)
        public
        view
        returns (Snapshot memory s)
    {
        _validateMarkets(a);
        Types.PairRiskConfig memory r = pair(a);
        s.collateralUsd = Math.mulDiv(
            pTokenValue(a.collateral, collateralShares),
            a.collateral == settlement.pUsdVault() ? usdCollateralWeightBps : avaxCollateralWeightBps,
            10_000
        );
        s.tradingUsd = pTokenValue(a.position, positionShares);
        s.debtUsd = debtValue(a.debt, debtAmount);
        s.exposureUsd = a.debt == settlement.pUsd() ? s.tradingUsd : s.debtUsd;
        uint256 flashFee =
            IERC3156FlashLender(config.flashLoanProvider()).flashFee(quoter.assetForMarket(a.debt), debtAmount);
        s.exitCostsUsd = debtValue(a.debt, flashFee)
            + Math.mulDiv(s.exposureUsd, config.closeFeeBps(), 10_000, Math.Rounding.Ceil)
            + Math.mulDiv(
                s.tradingUsd + s.collateralUsd,
                Math.min(r.maxSlippageBps, r.oracleDeviationBps),
                10_000,
                Math.Rounding.Ceil
            );
        s.metrics = MarginMath.calculate(
            MarginMath.Inputs(
                s.collateralUsd,
                s.tradingUsd,
                s.debtUsd,
                s.exitCostsUsd,
                s.exposureUsd,
                r.initialMarginBps,
                r.maintenanceMarginBps
            )
        );
    }

    function quoteOpen(address collateral, bool short, uint256 collateralShares, uint16 leverage)
        external
        view
        returns (uint256 flashAmount, uint256 minPositionOut)
    {
        Account memory a = Account(
            collateral,
            short ? settlement.pUsd() : settlement.pWavax(),
            short ? settlement.pWavax() : settlement.pUsd(),
            Types.Status.OPENING,
            leverage
        );
        _validateMarkets(a);
        Types.PairRiskConfig memory r = pair(a);
        if (!r.enabled || leverage <= 100 || leverage > r.maxLeverageX100) revert UnsafePosition();
        address debtAsset = quoter.assetForMarket(a.debt);
        IERC3156FlashLender lender = IERC3156FlashLender(config.flashLoanProvider());
        uint256 upperUsd = Math.mulDiv(pTokenValue(collateral, collateralShares), leverage, 100);
        uint256 high =
            Math.min(quoter.underlyingForUsd(debtAsset, upperUsd, Math.Rounding.Floor), lender.maxFlashLoan(debtAsset));
        high = Math.min(high, PErc20(a.debt).getCash());
        while (flashAmount < high) {
            uint256 distance = high - flashAmount;
            uint256 candidate = flashAmount + distance / 2 + distance % 2;
            (bool fits,) = _quoteFits(a, r, collateralShares, candidate);
            if (fits) flashAmount = candidate;
            else high = candidate - 1;
        }
        (bool fits, uint256 minimum) = _quoteFits(a, r, collateralShares, flashAmount);
        if (flashAmount == 0 || !fits) revert UnsafePosition();
        minPositionOut = minimum;
    }

    function _quoteFits(Account memory a, Types.PairRiskConfig memory r, uint256 collateralShares, uint256 amount)
        private
        view
        returns (bool fits, uint256 minimum)
    {
        address debtAsset = quoter.assetForMarket(a.debt);
        uint256 expected = quoter.expectedOut(debtAsset, quoter.assetForMarket(a.position), amount);
        minimum = Math.mulDiv(expected, 10_000 - Math.min(r.maxSlippageBps, r.oracleDeviationBps), 10_000);
        uint256 shares = Math.mulDiv(minimum, 1e18, PErc20(a.position).exchangeRateStored());
        // Unified borrow-share accounting may round an individual borrow up by one
        // underlying unit. Reserve two units before testing the opening boundary.
        uint256 debt = amount + IERC3156FlashLender(config.flashLoanProvider()).flashFee(debtAsset, amount) + 2;
        if (shares == 0 || debt > PErc20(a.debt).getCash()) return (false, minimum);
        fits = _fits(evaluate(a, collateralShares, shares, debt), r, a.requestedLeverageX100);
    }

    function _fits(Snapshot memory s, Types.PairRiskConfig memory r, uint16 leverage) private pure returns (bool) {
        return s.metrics.meetsInitialMargin && s.metrics.tradingLeverageX100 <= leverage
            && s.metrics.tradingLeverageX100 <= r.maxLeverageX100
            && (r.maxPositionValueUsd == 0 || s.exposureUsd <= r.maxPositionValueUsd)
            && (r.maxDebtValueUsd == 0 || s.debtUsd <= r.maxDebtValueUsd);
    }

    function pTokenValue(address market, uint256 shares) public view returns (uint256) {
        return quoter.underlyingValueUsd(
            quoter.assetForMarket(market), Math.mulDiv(shares, PErc20(market).exchangeRateStored(), 1e18)
        );
    }

    function debtValue(address market, uint256 amount) public view returns (uint256) {
        address asset = quoter.assetForMarket(market);
        return Math.mulDiv(amount, quoter.price(asset), 10 ** IERC20Metadata(asset).decimals(), Math.Rounding.Ceil);
    }

    function pair(Account memory a) public view returns (Types.PairRiskConfig memory) {
        return config.getPairRisk(a.collateral, a.position, a.debt);
    }

    function _validateMarkets(Account memory a) private view {
        if (
            (a.collateral != settlement.pUsdVault() && a.collateral != settlement.pAvaxVault())
                || !((a.position == settlement.pUsd() && a.debt == settlement.pWavax())
                    || (a.position == settlement.pWavax() && a.debt == settlement.pUsd()))
        ) revert InvalidConfiguration();
        address vaultShare = a.collateral == settlement.pUsdVault() ? settlement.usdVault() : settlement.avaxVault();
        address baseAsset = a.collateral == settlement.pUsdVault() ? settlement.usd() : settlement.wavax();
        if (PErc20(a.collateral).underlying() != vaultShare || IERC4626(vaultShare).asset() != baseAsset) {
            revert InvalidConfiguration();
        }
        address[3] memory markets = [a.collateral, a.position, a.debt];
        for (uint256 i; i < 3; ++i) {
            if (
                address(PErc20(markets[i]).peridottroller()) != controller
                    || PErc20(markets[i]).underlying() != quoter.assetForMarket(markets[i])
            ) revert InvalidConfiguration();
        }
    }
}

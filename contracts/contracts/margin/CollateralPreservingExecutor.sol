// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PErc20} from "../PErc20.sol";
import {IERC3156FlashBorrower, IERC3156FlashLender} from "../PTokenInterfaces.sol";
import {IsolatedMarginAccount} from "./IsolatedMarginAccount.sol";
import {IsolatedMarginAccountFactory} from "./IsolatedMarginAccountFactory.sol";
import {IsolatedMarginVaultUpgradeable} from "./IsolatedMarginVaultUpgradeable.sol";
import {IsolatedMarginTypes as Types} from "./IsolatedMarginTypes.sol";
import {CollateralPreservingRiskEngine as Risk} from "./CollateralPreservingRiskEngine.sol";
import {CollateralPreservingSettlementModule as Settlement} from "./CollateralPreservingSettlementModule.sol";
import {CollateralPreservingSwapModule} from "./CollateralPreservingSwapModule.sol";
import {IsolatedMarginQuoter} from "./IsolatedMarginQuoter.sol";
import {IIsolatedMarginConfig} from "./interfaces/IIsolatedMarginConfig.sol";
import {MarginInsuranceFundUpgradeable} from "./MarginInsuranceFundUpgradeable.sol";

/// @notice Fresh isolated executor. Never install as a legacy proxy implementation.
/// @dev Original boosted pTokens remain in the account at open; only debt funds trade.
/// Partial exits retain unused collateral in the account and release consumed reward
/// weight. No function grants users generic account calls or arbitrary approvals.
contract CollateralPreservingExecutor is ReentrancyGuard, IERC3156FlashBorrower {
    using SafeERC20 for IERC20;
    bytes32 public constant executionVersion = keccak256("collateral-preserving-executor-v1");
    bytes32 private constant CALLBACK = keccak256("ERC3156FlashBorrower.onFlashLoan");
    Risk public immutable risk;
    Settlement public immutable settlement;
    CollateralPreservingSwapModule public immutable swapModule;
    IsolatedMarginQuoter public immutable quoter;
    IIsolatedMarginConfig public immutable config;
    IsolatedMarginVaultUpgradeable public immutable vault;
    IsolatedMarginAccountFactory public immutable factory;
    uint256 public nextPositionId = 1;

    struct Position {
        address owner;
        address account;
        address collateral;
        address position;
        address debt;
        uint256 locked;
    }

    struct OpenParams {
        address collateral;
        bool short;
        uint256 collateralShares;
        uint16 leverageX100;
        uint256 maxFeeShares;
        uint256 minPositionOut;
        uint256 deadline;
        bytes swapData;
    }

    struct CloseParams {
        uint256 id;
        uint16 fractionBps;
        uint256 maxFeeShares;
        uint256 maxCollateralSharesToSell;
        uint256 minTradeDebtOut;
        uint256 minCollateralDebtOut;
        uint256 minSurplusUsdc;
        uint256 deadline;
        bytes tradeData;
        bytes collateralData;
        bytes surplusData;
    }

    struct CloseWork {
        uint256 repay;
        uint256 redeemShares;
        uint256 feeShares;
        uint256 previousHealth;
        bool liquidation;
        address keeper;
        uint256 bonusShares;
        address insurance;
        uint256 insuranceProvided;
    }

    struct Flash {
        address lender;
        address token;
        uint256 amount;
        uint256 fee;
        bytes32 dataHash;
        bool armed;
    }
    mapping(uint256 => Position) public positions;
    Flash private flash;

    error InvalidConfiguration();
    error Unauthorized();
    error InvalidOperation();
    error InvalidCallback();
    error UnexpectedBalance();
    error FeeLimit();

    event Opened(
        uint256 indexed id, address indexed owner, address indexed account, uint256 debt, uint256 collateralShares
    );
    event Closed(uint256 indexed id, bool full, uint256 repaid, uint256 collateralConsumed, uint256 surplusUsdc);
    event EmergencyExited(uint256 indexed id, uint256 repaid, uint256 collateralShares);
    event Liquidated(
        uint256 indexed id,
        address indexed keeper,
        bool full,
        uint256 repaid,
        uint256 bonusShares,
        uint256 insuranceDebtUsed
    );

    constructor(address risk_, address vault_, address factory_) {
        if (risk_.code.length == 0 || vault_.code.length == 0 || factory_.code.length == 0) {
            revert InvalidConfiguration();
        }
        risk = Risk(risk_);
        if (risk.executionVersion() != keccak256("collateral-preserving-risk-v1")) revert InvalidConfiguration();
        settlement = risk.settlement();
        quoter = settlement.quoter();
        config = settlement.config();
        swapModule = settlement.swapModule();
        vault = IsolatedMarginVaultUpgradeable(vault_);
        factory = IsolatedMarginAccountFactory(factory_);
        if (address(vault.feeDistributor()) != address(settlement.feeDistributor()) || factory.executor() != address(0))
        {
            revert InvalidConfiguration();
        }
    }

    function openPosition(OpenParams calldata p) external nonReentrant returns (uint256 id) {
        if (block.timestamp > p.deadline || config.opensPaused() || p.collateralShares == 0) revert InvalidOperation();
        _checkWiring();
        address positionMarket = p.short ? settlement.pUsd() : settlement.pWavax();
        address debtMarket = p.short ? settlement.pWavax() : settlement.pUsd();
        _accrue(p.collateral, positionMarket, debtMarket);
        (uint256 amount, uint256 minimum) = risk.quoteOpen(p.collateral, p.short, p.collateralShares, p.leverageX100);
        uint256 fee = quoter.feePToken(
            p.collateral,
            Math.mulDiv(risk.debtValue(debtMarket, amount), config.openFeeBps(), 10_000, Math.Rounding.Ceil)
        );
        if (fee > p.maxFeeShares) revert FeeLimit();
        id = nextPositionId++;
        address account = factory.createAccount(address(risk), msg.sender, id, p.collateral, positionMarket, debtMarket);
        positions[id] = Position(msg.sender, account, p.collateral, positionMarket, debtMarket, p.collateralShares);
        risk.register(account, p.leverageX100);
        vault.lockForPosition(id, msg.sender, account, p.collateral, p.collateralShares, fee);
        uint256 original = IERC20(p.collateral).balanceOf(account);
        _flash(
            quoter.assetForMarket(debtMarket),
            amount,
            abi.encode(true, id, abi.encode(Math.max(minimum, p.minPositionOut), p.swapData))
        );
        if (IERC20(p.collateral).balanceOf(account) != original) revert UnexpectedBalance();
        risk.activate(account);
        emit Opened(id, msg.sender, account, PErc20(debtMarket).borrowBalanceStored(account), original);
    }

    function closePosition(CloseParams calldata p) external nonReentrant {
        Position memory pos = positions[p.id];
        if (pos.owner != msg.sender) revert Unauthorized();
        if (p.fractionBps == 0 || p.fractionBps > 10_000 || block.timestamp > p.deadline) revert InvalidOperation();
        _accrue(pos.collateral, pos.position, pos.debt);
        Risk.Snapshot memory beforeState = risk.begin(pos.account, false);
        uint256 debt = PErc20(pos.debt).borrowBalanceStored(pos.account);
        CloseWork memory work;
        work.repay = p.fractionBps == 10_000 ? debt : Math.mulDiv(debt, p.fractionBps, 10_000);
        work.redeemShares = Math.mulDiv(IERC20(pos.position).balanceOf(pos.account), p.fractionBps, 10_000);
        work.previousHealth = beforeState.metrics.healthFactorBps;
        uint256 closedExposure = Math.mulDiv(beforeState.exposureUsd, p.fractionBps, 10_000, Math.Rounding.Ceil);
        work.feeShares = quoter.feePToken(
            pos.collateral, Math.mulDiv(closedExposure, config.closeFeeBps(), 10_000, Math.Rounding.Ceil)
        );
        if (work.feeShares > p.maxFeeShares) revert FeeLimit();
        bytes memory data = abi.encode(false, p.id, abi.encode(p, work));
        if (work.repay == 0) {
            if (p.fractionBps != 10_000) revert InvalidOperation();
            _close(pos, p, work, 0);
        } else {
            _flash(quoter.assetForMarket(pos.debt), work.repay, data);
        }
        risk.finish(pos.account, p.fractionBps == 10_000, work.previousHealth);
    }

    /// @notice Paused-only, fee-free recovery funded entirely by the position owner.
    /// @dev Accrues only debt: no prices, strategy redemption, swaps or flash liquidity.
    /// Collateral returns to the margin vault; trading/debt pTokens go to the wallet.
    /// maxDebtRepayment bounds the wallet debit, including all accrued interest.
    function emergencyExitToPTokens(uint256 id, uint256 maxDebtRepayment) external nonReentrant {
        Position memory p = positions[id];
        if (msg.sender != p.owner) revert Unauthorized();
        uint256 debt = risk.beginEmergencyClose(p.account);
        if (debt > maxDebtRepayment) revert InvalidOperation();
        IsolatedMarginAccount account = IsolatedMarginAccount(p.account);
        if (debt != 0) {
            IERC20(PErc20(p.debt).underlying()).safeTransferFrom(msg.sender, p.account, debt);
            if (account.repayBorrow(debt) != debt) revert UnexpectedBalance();
        }
        // Raw-zero-debt check BEFORE any pTokens move; no oracle on a full finish.
        risk.finish(p.account, true, 0);
        uint256 collateral = IERC20(p.collateral).balanceOf(p.account);
        _releaseCollateral(id, p, collateral);
        account.transferToken(p.position, p.owner, IERC20(p.position).balanceOf(p.account));
        account.transferToken(p.debt, p.owner, IERC20(p.debt).balanceOf(p.account));
        emit EmergencyExited(id, debt, collateral);
    }

    function addCollateral(uint256 id, uint256 shares) external nonReentrant {
        Position storage p = positions[id];
        if (msg.sender != p.owner) revert Unauthorized();
        (,,, Types.Status status,) = risk.accounts(p.account);
        if (status != Types.Status.ACTIVE) revert InvalidOperation();
        vault.addToPosition(id, shares);
        p.locked += shares;
    }

    /// @notice Permissionless keeper execution, authorized by current maintenance risk.
    /// @dev Insurance is debt-asset cash for this fresh stack, not a promise to redeem
    /// inaccessible strategy shares. Fund exhaustion atomically reverts; no bad-debt writeoff.
    function liquidate(CloseParams calldata p, uint256 maxInsuranceDebt) external nonReentrant {
        Position memory pos = positions[p.id];
        if (pos.owner == address(0) || block.timestamp > p.deadline || p.fractionBps == 0 || p.fractionBps > 10_000) {
            revert InvalidOperation();
        }
        _accrue(pos.collateral, pos.position, pos.debt);
        Risk.Snapshot memory s = risk.begin(pos.account, true);
        Types.PairRiskConfig memory r = config.getPairRisk(pos.collateral, pos.position, pos.debt);
        bool full = p.fractionBps == 10_000;
        uint256 fullBonusUsd = Math.mulDiv(s.debtUsd, r.liquidationBonusBps, 10_000, Math.Rounding.Ceil);
        // Promote to full when the configured partial cannot retain positive equity
        // after its proportional keeper cost. Exit reserves are already in equity.
        bool fullAllowed = s.metrics.healthFactorBps <= r.fullLiquidationHealthBps || s.debtUsd <= 10e18
            || s.metrics.equityUsd <= 0 || uint256(s.metrics.equityUsd) <= fullBonusUsd;
        if (
            (full && !fullAllowed) || (!full && p.fractionBps > r.maxLiquidationBps) || (!full && maxInsuranceDebt != 0)
        ) revert InvalidOperation();
        CloseWork memory work;
        work.liquidation = true;
        work.keeper = msg.sender;
        work.previousHealth = s.metrics.healthFactorBps;
        uint256 debt = PErc20(pos.debt).borrowBalanceStored(pos.account);
        work.repay = full ? debt : Math.mulDiv(debt, p.fractionBps, 10_000);
        if (work.repay == 0) revert InvalidOperation();
        work.redeemShares = Math.mulDiv(IERC20(pos.position).balanceOf(pos.account), p.fractionBps, 10_000);
        work.bonusShares = Math.min(
            IERC20(pos.collateral).balanceOf(pos.account),
            quoter.feePToken(
                pos.collateral,
                Math.mulDiv(risk.debtValue(pos.debt, work.repay), r.liquidationBonusBps, 10_000, Math.Rounding.Ceil)
            )
        );
        address debtAsset = quoter.assetForMarket(pos.debt);
        if (maxInsuranceDebt != 0) {
            work.insurance = config.insuranceFund();
            uint256 beforeBalance = IERC20(debtAsset).balanceOf(address(this));
            work.insuranceProvided = MarginInsuranceFundUpgradeable(work.insurance)
                .provideCoverage(debtAsset, address(this), maxInsuranceDebt);
            if (IERC20(debtAsset).balanceOf(address(this)) != beforeBalance + work.insuranceProvided) {
                revert UnexpectedBalance();
            }
        }
        // Liquidation may consume remaining collateral regardless of an untrusted keeper's
        // requested loss budget. It may NOT use insurance while leaving sellable collateral.
        CloseParams memory actual = p;
        actual.maxCollateralSharesToSell = type(uint256).max;
        _flash(debtAsset, work.repay, abi.encode(false, p.id, abi.encode(actual, work)));
        risk.finish(pos.account, full, work.previousHealth);
    }

    function _flash(address token, uint256 amount, bytes memory data) private {
        address lender = config.flashLoanProvider();
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        (,, bytes memory payload) = abi.decode(data, (bool, uint256, bytes));
        (bool opening,,) = abi.decode(data, (bool, uint256, bytes));
        if (!opening) {
            (, CloseWork memory w) = abi.decode(payload, (CloseParams, CloseWork));
            beforeBalance -= w.insuranceProvided;
        }
        flash = Flash(lender, token, amount, IERC3156FlashLender(lender).flashFee(token, amount), keccak256(data), true);
        if (!IERC3156FlashLender(lender).flashLoan(this, token, amount, data) || flash.armed) revert InvalidCallback();
        IERC20(token).forceApprove(lender, 0);
        if (IERC20(token).balanceOf(address(this)) != beforeBalance) revert UnexpectedBalance();
        delete flash;
    }

    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        override
        returns (bytes32)
    {
        Flash memory f = flash;
        if (
            !f.armed || msg.sender != f.lender || initiator != address(this) || token != f.token || amount != f.amount
                || fee != f.fee || keccak256(data) != f.dataHash
        ) revert InvalidCallback();
        flash.armed = false;
        (bool opening, uint256 id, bytes memory payload) = abi.decode(data, (bool, uint256, bytes));
        Position memory pos = positions[id];
        if (opening) {
            (uint256 minimum, bytes memory route) = abi.decode(payload, (uint256, bytes));
            _open(pos, amount, fee, minimum, route);
        } else {
            (CloseParams memory p, CloseWork memory work) = abi.decode(payload, (CloseParams, CloseWork));
            _close(pos, p, work, fee);
        }
        IERC20(token).forceApprove(msg.sender, amount + fee);
        return CALLBACK;
    }

    function _open(Position memory p, uint256 amount, uint256 fee, uint256 minimum, bytes memory route) private {
        address debtAsset = quoter.assetForMarket(p.debt);
        address positionAsset = quoter.assetForMarket(p.position);
        Types.PairRiskConfig memory r = config.getPairRisk(p.collateral, p.position, p.debt);
        IERC20(debtAsset).forceApprove(address(swapModule), amount);
        uint256 received = swapModule.executeSwap(
            debtAsset, positionAsset, amount, minimum, r.maxSlippageBps, r.oracleDeviationBps, route
        );
        IERC20(debtAsset).forceApprove(address(swapModule), 0);
        IERC20(positionAsset).safeTransfer(p.account, received);
        IsolatedMarginAccount a = IsolatedMarginAccount(p.account);
        if (a.mint(p.position, received) == 0) revert InvalidOperation();
        a.borrow(amount + fee);
        a.transferToken(debtAsset, address(this), amount + fee);
    }

    function _close(Position memory pos, CloseParams memory p, CloseWork memory work, uint256 flashFee) private {
        IsolatedMarginAccount account = IsolatedMarginAccount(pos.account);
        address debtAsset = quoter.assetForMarket(pos.debt);
        if (work.repay != 0) {
            IERC20(debtAsset).safeTransfer(pos.account, work.repay);
            if (account.repayBorrow(work.repay) != work.repay) revert InvalidOperation();
        }
        risk.authorize(pos.account, pos.position, work.redeemShares);
        uint256 trade = work.redeemShares == 0 ? 0 : account.redeem(pos.position, work.redeemShares);
        address tradeAsset = quoter.assetForMarket(pos.position);
        if (trade != 0) account.transferToken(tradeAsset, address(this), trade);
        uint256 collateral = IERC20(pos.collateral).balanceOf(pos.account);
        risk.authorize(pos.account, pos.collateral, collateral);
        account.transferToken(pos.collateral, address(this), collateral);
        if (work.bonusShares != 0) IERC20(pos.collateral).safeTransfer(work.keeper, work.bonusShares);
        collateral -= work.bonusShares;
        Settlement.CloseParams memory close;
        close.collateralPToken = pos.collateral;
        close.debtPToken = pos.debt;
        close.collateralShares = collateral;
        close.tradeUnderlying = trade;
        close.repaymentAmount = work.repay + flashFee;
        close.insuranceDebtAmount = work.insuranceProvided;
        close.feeShares = work.feeShares;
        close.maxCollateralSharesToSell = p.maxCollateralSharesToSell;
        close.minTradeDebtOut = p.minTradeDebtOut;
        close.minCollateralDebtOut = p.minCollateralDebtOut;
        close.minSurplusUsdc = p.minSurplusUsdc;
        close.deadline = p.deadline;
        close.tradeData = p.tradeData;
        close.collateralData = p.collateralData;
        close.surplusData = p.surplusData;
        IERC20(pos.collateral).forceApprove(address(settlement), collateral);
        IERC20(tradeAsset).forceApprove(address(settlement), trade);
        if (work.insuranceProvided != 0) IERC20(debtAsset).forceApprove(address(settlement), work.insuranceProvided);
        Settlement.Settlement memory result = settlement.settleFullClose(close);
        IERC20(pos.collateral).forceApprove(address(settlement), 0);
        IERC20(tradeAsset).forceApprove(address(settlement), 0);
        if (work.insuranceProvided != 0) {
            IERC20(debtAsset).forceApprove(address(settlement), 0);
            uint256 unused = work.insuranceProvided - result.insuranceDebtUsed;
            if (unused != 0) IERC20(debtAsset).safeTransfer(work.insurance, unused);
        }
        if (result.collateralReturned != 0) {
            IERC20(pos.collateral).safeTransfer(pos.account, result.collateralReturned);
        }
        uint256 consumed = result.collateralSold + work.feeShares + work.bonusShares;
        if (p.fractionBps == 10_000) {
            _releaseCollateral(p.id, pos, result.collateralReturned);
        } else {
            if (consumed >= pos.locked) revert InvalidOperation();
            if (consumed != 0) vault.releaseFromPosition(p.id, consumed, 0);
            positions[p.id].locked = pos.locked - consumed;
        }
        if (result.surplusUsdc != 0) IERC20(settlement.usd()).safeTransfer(pos.owner, result.surplusUsdc);
        if (result.surplusWavaxDust != 0) IERC20(settlement.wavax()).safeTransfer(pos.owner, result.surplusWavaxDust);
        emit Closed(p.id, p.fractionBps == 10_000, work.repay, consumed, result.surplusUsdc);
        if (work.liquidation) {
            emit Liquidated(
                p.id, work.keeper, p.fractionBps == 10_000, work.repay, work.bonusShares, result.insuranceDebtUsed
            );
        }
    }

    function _releaseCollateral(uint256 id, Position memory p, uint256 returned) private {
        IsolatedMarginAccount account = IsolatedMarginAccount(p.account);
        account.approveToken(p.collateral, address(vault), returned);
        vault.releaseFromPosition(id, p.locked, returned);
        account.approveToken(p.collateral, address(vault), 0);
        positions[id].locked = 0;
    }

    function _checkWiring() private view {
        if (
            risk.executor() != address(this) || factory.executor() != address(this) || vault.executor() != address(this)
        ) revert InvalidConfiguration();
    }

    function _accrue(address collateral, address position, address debt) private {
        PErc20(collateral).exchangeRateCurrent();
        PErc20(position).exchangeRateCurrent();
        if (PErc20(debt).accrueInterest() != 0 || !PErc20(debt).borrowAccountingEnabled()) {
            revert InvalidConfiguration();
        }
    }
}

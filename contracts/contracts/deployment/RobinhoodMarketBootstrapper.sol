// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {InterestRateModel} from "../InterestRateModel.sol";
import {PErc20} from "../PErc20.sol";
import {PErc20Delegator} from "../PErc20Delegator.sol";
import {PToken} from "../PToken.sol";
import {Peridottroller} from "../Peridottroller.sol";
import {Unitroller} from "../Unitroller.sol";

/**
 * @notice Atomically lists, seeds and pauses borrowing for the two Robinhood boosted markets.
 * @dev The controller temporarily appoints this single-use contract as admin. Candidate markets
 *      must be untouched and administered by this contract, so a donation before bootstrap makes
 *      the whole listing transaction revert. Pending controller and market administration is
 *      returned to the operator before the transaction finishes.
 *
 *      Both markets run `RobinhoodBoostedDelegate`, which is side-neutral: the stock market and
 *      the USDG market are two deployments of one implementation. At bootstrap neither is wired
 *      to the vault yet — the delegate sets `vaultPaused` while no vault is configured — so the
 *      seed lands as local pToken cash and no vault call happens here.
 *
 *      Seeding exists to make `totalSupply` large enough that mint rounding cannot be exploited.
 *      With 8-decimal pTokens at the standard 0.02 initial exchange rate, even a small seed
 *      leaves a supply of billions of units. The operator must therefore never redeem the whole
 *      seed afterwards: returning `totalSupply` to zero re-opens the first-depositor exposure
 *      this contract exists to close.
 */
contract RobinhoodMarketBootstrapper {
    using SafeERC20 for IERC20;

    uint256 private constant ROBINHOOD_CHAIN_ID = 4663;

    address public immutable operator;
    Peridottroller public immutable controller;
    InterestRateModel public immutable interestRateModel;
    address public immutable pTokenDelegate;
    address public immutable stockToken;
    address public immutable usdg;
    bool public used;

    constructor(
        address operator_,
        address controller_,
        address interestRateModel_,
        address pTokenDelegate_,
        address stockToken_,
        address usdg_
    ) {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RobinhoodBootstrap: Robinhood only");
        require(operator_ != address(0), "RobinhoodBootstrap: zero operator");
        require(
            controller_.code.length > 0 && interestRateModel_.code.length > 0 && pTokenDelegate_.code.length > 0,
            "RobinhoodBootstrap: protocol contract"
        );
        require(stockToken_.code.length > 0 && usdg_.code.length > 0, "RobinhoodBootstrap: token not contract");
        require(stockToken_ != usdg_, "RobinhoodBootstrap: duplicate token");

        operator = operator_;
        controller = Peridottroller(controller_);
        interestRateModel = InterestRateModel(interestRateModel_);
        pTokenDelegate = pTokenDelegate_;
        stockToken = stockToken_;
        usdg = usdg_;
    }

    function bootstrap(
        address pStockAddress,
        address pUsdgAddress,
        uint256 stockSeedAmount,
        uint256 usdgSeedAmount,
        uint256 stockBorrowCap,
        uint256 usdgBorrowCap,
        uint256 reserveFactorMantissa
    ) external {
        require(msg.sender == operator, "RobinhoodBootstrap: not operator");
        require(!used, "RobinhoodBootstrap: already used");
        require(pStockAddress != pUsdgAddress, "RobinhoodBootstrap: duplicate market");
        require(stockSeedAmount > 0 && usdgSeedAmount > 0, "RobinhoodBootstrap: zero seed");
        require(
            stockBorrowCap > stockSeedAmount && usdgBorrowCap > usdgSeedAmount,
            "RobinhoodBootstrap: cap not above seed"
        );
        require(reserveFactorMantissa <= 1e18, "RobinhoodBootstrap: reserve factor");

        PErc20Delegator pStock = PErc20Delegator(payable(pStockAddress));
        PErc20Delegator pUsdg = PErc20Delegator(payable(pUsdgAddress));
        _validateEmptyMarket(pStock, stockToken);
        _validateEmptyMarket(pUsdg, usdg);
        require(
            Unitroller(payable(address(controller))).pendingAdmin() == address(this),
            "RobinhoodBootstrap: not pending admin"
        );
        used = true;

        require(
            Unitroller(payable(address(controller)))._acceptAdmin() == 0, "RobinhoodBootstrap: accept controller admin"
        );
        require(controller._supportMarket(PErc20(address(pStock))) == 0, "RobinhoodBootstrap: support pStock");
        require(controller._supportMarket(PErc20(address(pUsdg))) == 0, "RobinhoodBootstrap: support pUsdg");

        // Borrowing stays paused until the vault pair is registered, the delegates are
        // configured, and the pair has been through a canary. Collateral factors are set
        // separately by governance for the same reason.
        require(controller._setBorrowPaused(PErc20(address(pStock)), true), "RobinhoodBootstrap: pause pStock");
        require(controller._setBorrowPaused(PErc20(address(pUsdg)), true), "RobinhoodBootstrap: pause pUsdg");

        require(
            PErc20(address(pStock))._setReserveFactor(reserveFactorMantissa) == 0,
            "RobinhoodBootstrap: pStock reserve factor"
        );
        require(
            PErc20(address(pUsdg))._setReserveFactor(reserveFactorMantissa) == 0,
            "RobinhoodBootstrap: pUsdg reserve factor"
        );
        require(PErc20(address(pStock))._setFlashLoansPaused(true), "RobinhoodBootstrap: flash pause pStock");
        require(PErc20(address(pUsdg))._setFlashLoansPaused(true), "RobinhoodBootstrap: flash pause pUsdg");

        PToken[] memory pTokens = new PToken[](2);
        pTokens[0] = PToken(address(pStock));
        pTokens[1] = PToken(address(pUsdg));
        uint256[] memory borrowCaps = new uint256[](2);
        borrowCaps[0] = stockBorrowCap;
        borrowCaps[1] = usdgBorrowCap;
        controller._setMarketBorrowCaps(pTokens, borrowCaps);

        _seed(stockToken, pStock, stockSeedAmount);
        _seed(usdg, pUsdg, usdgSeedAmount);

        require(pStock._setPendingAdmin(payable(operator)) == 0, "RobinhoodBootstrap: pStock pending admin");
        require(pUsdg._setPendingAdmin(payable(operator)) == 0, "RobinhoodBootstrap: pUsdg pending admin");
        require(
            Unitroller(payable(address(controller)))._setPendingAdmin(operator) == 0,
            "RobinhoodBootstrap: controller pending admin"
        );
    }

    /// @dev Any prior interaction, including a bare token transfer, fails this and reverts the
    ///      whole listing rather than letting a market be listed with a manipulated rate.
    function _validateEmptyMarket(PErc20Delegator pToken, address expectedUnderlying) private view {
        require(address(pToken).code.length > 0, "RobinhoodBootstrap: market not contract");
        require(pToken.admin() == address(this), "RobinhoodBootstrap: not market admin");
        require(pToken.implementation() == pTokenDelegate, "RobinhoodBootstrap: wrong delegate");
        require(address(pToken.peridottroller()) == address(controller), "RobinhoodBootstrap: wrong controller");
        require(
            address(pToken.interestRateModel()) == address(interestRateModel), "RobinhoodBootstrap: wrong rate model"
        );
        require(PErc20(address(pToken)).underlying() == expectedUnderlying, "RobinhoodBootstrap: wrong underlying");

        uint8 underlyingDecimals = IERC20Metadata(expectedUnderlying).decimals();
        require(underlyingDecimals <= 18, "RobinhoodBootstrap: token decimals");
        require(pToken.decimals() == 8, "RobinhoodBootstrap: pToken decimals");
        require(
            pToken.exchangeRateStored() == 2 * (10 ** uint256(underlyingDecimals + 8)),
            "RobinhoodBootstrap: exchange rate"
        );
        require(
            pToken.totalSupply() == 0 && pToken.totalBorrows() == 0 && pToken.totalReserves() == 0
                && PErc20(address(pToken)).getCash() == 0,
            "RobinhoodBootstrap: market touched"
        );
    }

    function _seed(address underlying, PErc20Delegator pToken, uint256 amount) private {
        IERC20 token = IERC20(underlying);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(operator, address(this), amount);
        require(token.balanceOf(address(this)) - balanceBefore == amount, "RobinhoodBootstrap: unsupported token");
        token.forceApprove(address(pToken), amount);
        require(pToken.mint(amount) == 0, "RobinhoodBootstrap: seed mint");
        token.forceApprove(address(pToken), 0);
        require(PErc20(address(pToken)).getCash() == amount, "RobinhoodBootstrap: unexpected cash");

        uint256 minted = pToken.balanceOf(address(this));
        require(minted > 0, "RobinhoodBootstrap: zero pToken seed");
        require(pToken.transfer(operator, minted), "RobinhoodBootstrap: seed transfer");
    }
}

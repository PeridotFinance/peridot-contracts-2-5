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
 * @notice Atomically lists, seeds, and pauses borrowing for fresh Avalanche mainnet pWAVAX and pUSDC markets.
 * @dev The controller temporarily appoints this single-use contract as admin. Candidate markets
 *      must be untouched and administered by this contract; a donation before bootstrap therefore
 *      makes the whole listing transaction revert. Pending controller and market administration is
 *      returned to the operator before the bootstrap transaction finishes.
 */
contract AvalancheMarketBootstrapper {
    using SafeERC20 for IERC20;

    uint256 private constant AVALANCHE_CHAIN_ID = 43_114;

    address public immutable operator;
    Peridottroller public immutable controller;
    InterestRateModel public immutable interestRateModel;
    address public immutable pTokenDelegate;
    address public immutable wavax;
    address public immutable usdc;
    bool public used;

    constructor(
        address operator_,
        address controller_,
        address interestRateModel_,
        address pTokenDelegate_,
        address wavax_,
        address usdc_
    ) {
        require(block.chainid == AVALANCHE_CHAIN_ID, "AvaBootstrap: Avalanche C-Chain only");
        require(operator_ != address(0), "AvaBootstrap: zero operator");
        require(
            controller_.code.length > 0 && interestRateModel_.code.length > 0 && pTokenDelegate_.code.length > 0,
            "AvaBootstrap: protocol contract"
        );
        require(wavax_.code.length > 0 && usdc_.code.length > 0, "AvaBootstrap: token not contract");
        require(wavax_ != usdc_, "AvaBootstrap: duplicate token");

        operator = operator_;
        controller = Peridottroller(controller_);
        interestRateModel = InterestRateModel(interestRateModel_);
        pTokenDelegate = pTokenDelegate_;
        wavax = wavax_;
        usdc = usdc_;
    }

    function bootstrap(
        address pWavaxAddress,
        address pUsdcAddress,
        uint256 wavaxSeedAmount,
        uint256 usdcSeedAmount,
        uint256 wavaxBorrowCap,
        uint256 usdcBorrowCap,
        uint256 reserveFactorMantissa
    ) external {
        require(msg.sender == operator, "AvaBootstrap: not operator");
        require(!used, "AvaBootstrap: already used");
        require(pWavaxAddress != pUsdcAddress, "AvaBootstrap: duplicate market");
        require(wavaxSeedAmount > 0 && usdcSeedAmount > 0, "AvaBootstrap: zero seed");
        require(wavaxBorrowCap > wavaxSeedAmount && usdcBorrowCap > usdcSeedAmount, "AvaBootstrap: cap not above seed");
        require(reserveFactorMantissa <= 1e18, "AvaBootstrap: reserve factor");

        PErc20Delegator pWavax = PErc20Delegator(payable(pWavaxAddress));
        PErc20Delegator pUsdc = PErc20Delegator(payable(pUsdcAddress));
        _validateEmptyMarket(pWavax, wavax, 18);
        _validateEmptyMarket(pUsdc, usdc, 6);
        require(
            Unitroller(payable(address(controller))).pendingAdmin() == address(this), "AvaBootstrap: not pending admin"
        );
        used = true;

        require(Unitroller(payable(address(controller)))._acceptAdmin() == 0, "AvaBootstrap: accept controller admin");
        require(controller._supportMarket(PErc20(address(pWavax))) == 0, "AvaBootstrap: support pWAVAX");
        require(controller._supportMarket(PErc20(address(pUsdc))) == 0, "AvaBootstrap: support pUSDC");
        require(controller._setBorrowPaused(PErc20(address(pWavax)), true), "AvaBootstrap: pause pWAVAX");
        require(controller._setBorrowPaused(PErc20(address(pUsdc)), true), "AvaBootstrap: pause pUSDC");

        require(
            PErc20(address(pWavax))._setReserveFactor(reserveFactorMantissa) == 0,
            "AvaBootstrap: pWAVAX reserve factor"
        );
        require(
            PErc20(address(pUsdc))._setReserveFactor(reserveFactorMantissa) == 0, "AvaBootstrap: pUSDC reserve factor"
        );
        require(PErc20(address(pWavax))._setFlashLoansPaused(true), "AvaBootstrap: flash pause pWAVAX");
        require(PErc20(address(pUsdc))._setFlashLoansPaused(true), "AvaBootstrap: flash pause pUSDC");

        PToken[] memory pTokens = new PToken[](2);
        pTokens[0] = PToken(address(pWavax));
        pTokens[1] = PToken(address(pUsdc));
        uint256[] memory borrowCaps = new uint256[](2);
        borrowCaps[0] = wavaxBorrowCap;
        borrowCaps[1] = usdcBorrowCap;
        controller._setMarketBorrowCaps(pTokens, borrowCaps);

        _seed(wavax, pWavax, wavaxSeedAmount);
        _seed(usdc, pUsdc, usdcSeedAmount);

        require(pWavax._setPendingAdmin(payable(operator)) == 0, "AvaBootstrap: pWAVAX pending admin");
        require(pUsdc._setPendingAdmin(payable(operator)) == 0, "AvaBootstrap: pUSDC pending admin");
        require(
            Unitroller(payable(address(controller)))._setPendingAdmin(operator) == 0,
            "AvaBootstrap: controller pending admin"
        );
    }

    function _validateEmptyMarket(PErc20Delegator pToken, address expectedUnderlying, uint8 underlyingDecimals)
        private
        view
    {
        require(address(pToken).code.length > 0, "AvaBootstrap: market not contract");
        require(pToken.admin() == address(this), "AvaBootstrap: not market admin");
        require(pToken.implementation() == pTokenDelegate, "AvaBootstrap: wrong delegate");
        require(address(pToken.peridottroller()) == address(controller), "AvaBootstrap: wrong controller");
        require(address(pToken.interestRateModel()) == address(interestRateModel), "AvaBootstrap: wrong rate model");
        require(PErc20(address(pToken)).underlying() == expectedUnderlying, "AvaBootstrap: wrong underlying");
        require(IERC20Metadata(expectedUnderlying).decimals() == underlyingDecimals, "AvaBootstrap: token decimals");
        require(pToken.decimals() == 8, "AvaBootstrap: pToken decimals");
        require(
            pToken.exchangeRateStored() == 2 * (10 ** uint256(underlyingDecimals + 8)), "AvaBootstrap: exchange rate"
        );
        require(
            pToken.totalSupply() == 0 && pToken.totalBorrows() == 0 && pToken.totalReserves() == 0
                && PErc20(address(pToken)).getCash() == 0,
            "AvaBootstrap: market touched"
        );
    }

    function _seed(address underlying, PErc20Delegator pToken, uint256 amount) private {
        IERC20 token = IERC20(underlying);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(operator, address(this), amount);
        require(token.balanceOf(address(this)) - balanceBefore == amount, "AvaBootstrap: unsupported token");
        token.forceApprove(address(pToken), amount);
        require(pToken.mint(amount) == 0, "AvaBootstrap: seed mint");
        token.forceApprove(address(pToken), 0);
        require(PErc20(address(pToken)).getCash() == amount, "AvaBootstrap: unexpected cash");

        uint256 minted = pToken.balanceOf(address(this));
        require(minted > 0, "AvaBootstrap: zero pToken seed");
        require(pToken.transfer(operator, minted), "AvaBootstrap: seed transfer");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PErc20} from "../PErc20.sol";

interface IIsolatedMarginLiquidatorRegistry {
    function liquidator() external view returns (address);
}

interface IIsolatedMarginAccountFactoryRegistry {
    function executor() external view returns (address);
}

/**
 * @notice Minimal custody account used by exactly one isolated margin position.
 * @dev The account intentionally has no generic call or user withdrawal entry point.
 */
contract IsolatedMarginAccount {
    using SafeERC20 for IERC20;

    address public immutable factory;
    address public manager;
    address public riskEngine;
    address public owner;
    uint256 public positionId;
    address public marginPToken;
    address public positionPToken;
    address public debtPToken;

    event Initialized(
        uint256 indexed positionId,
        address indexed owner,
        address indexed manager,
        address marginPToken,
        address positionPToken,
        address debtPToken
    );

    constructor() {
        factory = msg.sender;
    }

    modifier onlyManager() {
        require(msg.sender == manager, "IsolatedAccount: not manager");
        _;
    }

    modifier onlyLiquidator() {
        require(
            msg.sender == IIsolatedMarginLiquidatorRegistry(riskEngine).liquidator(), "IsolatedAccount: not liquidator"
        );
        _;
    }

    function initialize(
        address manager_,
        address riskEngine_,
        address owner_,
        uint256 positionId_,
        address marginPToken_,
        address positionPToken_,
        address debtPToken_
    ) external {
        require(manager == address(0), "IsolatedAccount: initialized");
        require(
            msg.sender == factory && manager_ == IIsolatedMarginAccountFactoryRegistry(factory).executor(),
            "IsolatedAccount: invalid factory"
        );
        require(riskEngine_.code.length > 0, "IsolatedAccount: invalid risk engine");
        require(owner_ != address(0) && positionId_ != 0, "IsolatedAccount: invalid identity");
        require(
            marginPToken_.code.length > 0 && positionPToken_.code.length > 0 && debtPToken_.code.length > 0,
            "IsolatedAccount: invalid market"
        );
        manager = manager_;
        riskEngine = riskEngine_;
        owner = owner_;
        positionId = positionId_;
        marginPToken = marginPToken_;
        positionPToken = positionPToken_;
        debtPToken = debtPToken_;
        emit Initialized(positionId_, owner_, manager_, marginPToken_, positionPToken_, debtPToken_);
    }

    function mint(address pToken, uint256 underlyingAmount) external onlyManager returns (uint256 mintedTokens) {
        require(
            pToken == marginPToken || pToken == positionPToken || pToken == debtPToken,
            "IsolatedAccount: unsupported mint"
        );
        IERC20 underlying = IERC20(PErc20(pToken).underlying());
        uint256 beforeBalance = PErc20(pToken).balanceOf(address(this));
        underlying.forceApprove(pToken, underlyingAmount);
        require(PErc20(pToken).mint(underlyingAmount) == 0, "IsolatedAccount: mint failed");
        underlying.forceApprove(pToken, 0);
        mintedTokens = PErc20(pToken).balanceOf(address(this)) - beforeBalance;
    }

    function redeem(address pToken, uint256 pTokenAmount) external onlyManager returns (uint256 underlyingReceived) {
        require(
            pToken == marginPToken || pToken == positionPToken || pToken == debtPToken,
            "IsolatedAccount: unsupported redeem"
        );
        address underlying = PErc20(pToken).underlying();
        uint256 beforeBalance = IERC20(underlying).balanceOf(address(this));
        require(PErc20(pToken).redeem(pTokenAmount) == 0, "IsolatedAccount: redeem failed");
        underlyingReceived = IERC20(underlying).balanceOf(address(this)) - beforeBalance;
    }

    function borrow(uint256 amount) external onlyManager returns (uint256) {
        require(PErc20(debtPToken).borrow(amount) == 0, "IsolatedAccount: borrow failed");
        return amount;
    }

    function repayBorrow(uint256 amount) external onlyManager returns (uint256 repaidAmount) {
        address underlying = PErc20(debtPToken).underlying();
        uint256 debtBefore = PErc20(debtPToken).borrowBalanceStored(address(this));
        repaidAmount = amount < debtBefore ? amount : debtBefore;
        IERC20(underlying).forceApprove(debtPToken, repaidAmount);
        require(PErc20(debtPToken).repayBorrow(repaidAmount) == 0, "IsolatedAccount: repay failed");
        IERC20(underlying).forceApprove(debtPToken, 0);
    }

    function approveToken(address token, address spender, uint256 amount) external onlyManager {
        IERC20(token).forceApprove(spender, amount);
    }

    function transferToken(address token, address to, uint256 amount) external onlyManager {
        require(to != address(0), "IsolatedAccount: zero recipient");
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Redeems isolated collateral to the configured liquidation contract.
     * @dev The controller independently consumes a same-block authorization from the risk engine.
     */
    function liquidationRedeem(address pToken, uint256 pTokenAmount, address recipient)
        external
        onlyLiquidator
        returns (uint256 underlyingReceived)
    {
        require(pToken == marginPToken || pToken == positionPToken, "IsolatedAccount: unsupported collateral");
        require(recipient != address(0), "IsolatedAccount: zero recipient");
        address underlying = PErc20(pToken).underlying();
        uint256 beforeBalance = IERC20(underlying).balanceOf(address(this));
        require(PErc20(pToken).redeem(pTokenAmount) == 0, "IsolatedAccount: redeem failed");
        underlyingReceived = IERC20(underlying).balanceOf(address(this)) - beforeBalance;
        IERC20(underlying).safeTransfer(recipient, underlyingReceived);
    }
}

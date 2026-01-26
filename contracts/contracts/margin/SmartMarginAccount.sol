// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PeridottrollerInterface} from "../PeridottrollerInterface.sol";
import {PErc20} from "../PErc20.sol";
import {PToken} from "../PToken.sol";

/**
 * @title SmartMarginAccount
 * @notice Minimal proxy-owned account that custodies collateral and executes trades for a user.
 * @dev Instances are deployed as EIP-1167 clones and must be initialized exactly once.
 *
 *      Security Model:
 *      - Manager (MarginManager contract) controls all protocol operations and risk checks
 *      - Owner (user) has emergency escape hatch to withdraw tokens when no borrows exist
 *      - Initialize can only be called by msg.sender who becomes the manager (factory pattern)
 */
contract SmartMarginAccount {
    using SafeERC20 for IERC20;

    address public immutable factory;
    address public manager;
    address public owner;
    address public comptroller;

    address[] public enteredMarkets;
    mapping(address => uint256) private enteredMarketIndex;

    event ManagerUpdated(address indexed newManager);
    event OwnerUpdated(address indexed newOwner);
    event RouterCallExecuted(address indexed target, bytes data);
    event EmergencyWithdraw(
        address indexed owner,
        address indexed token,
        uint256 amount
    );

    modifier onlyManager() {
        require(msg.sender == manager, "SMA: not manager");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "SMA: not owner");
        _;
    }

    constructor() {
        factory = msg.sender;
    }

    /**
     * @notice Initialize the account. Can only be called once.
     * @dev The caller (msg.sender) becomes the manager. This ensures atomic initialization
     *      in the same transaction as clone deployment, preventing front-running attacks.
     * @param _manager Must equal msg.sender (the deploying factory/manager contract)
     * @param _owner The user who owns this margin account
     * @param _comptroller The canonical Peridottroller for borrow checks
     */
    function initialize(address _manager, address _owner, address _comptroller) external {
        require(manager == address(0), "SMA: initialized");
        require(_manager != address(0), "SMA: invalid manager");
        require(_owner != address(0), "SMA: invalid owner");
        require(_comptroller != address(0), "SMA: invalid comptroller");
        // Ensure caller is the manager - prevents front-running of uninitialized clones
        require(_manager == msg.sender, "SMA: caller must be manager");
        require(msg.sender == factory, "SMA: caller must be factory");

        manager = _manager;
        owner = _owner;
        comptroller = _comptroller;

        emit ManagerUpdated(_manager);
        emit OwnerUpdated(_owner);
    }

    function setOwner(address newOwner) external onlyManager {
        require(newOwner != address(0), "SMA: invalid owner");
        owner = newOwner;
        emit OwnerUpdated(newOwner);
    }

    function setManager(address newManager) external onlyManager {
        require(newManager != address(0), "SMA: invalid manager");
        manager = newManager;
        emit ManagerUpdated(newManager);
    }

    function enterMarket(address cToken) external onlyManager returns (uint256) {
        address[] memory markets = new address[](1);
        markets[0] = cToken;
        uint256[] memory results = PeridottrollerInterface(comptroller)
            .enterMarkets(markets);
        require(results[0] == 0, "SMA: enter market failed");
        _trackMarket(cToken);
        return results[0];
    }

    function exitMarket(address cToken) external onlyManager returns (uint256) {
        uint256 result = PeridottrollerInterface(comptroller).exitMarket(
            cToken
        );
        require(result == 0, "SMA: exit market failed");
        _untrackMarket(cToken);
        return result;
    }

    function borrow(
        address cToken,
        uint256 amount
    ) external onlyManager returns (uint256) {
        uint256 result = PErc20(cToken).borrow(amount);
        require(result == 0, "SMA: borrow failed");
        return result;
    }

    function repayBorrow(
        address cToken,
        uint256 amount
    ) external onlyManager returns (uint256) {
        IERC20 underlying = IERC20(PErc20(cToken).underlying());
        underlying.forceApprove(cToken, amount);
        uint256 result = PErc20(cToken).repayBorrow(amount);
        require(result == 0, "SMA: repay failed");
        underlying.forceApprove(cToken, 0);
        return result;
    }

    function mint(
        address cToken,
        uint256 underlyingAmount
    ) external onlyManager returns (uint256) {
        IERC20 underlying = IERC20(PErc20(cToken).underlying());
        underlying.forceApprove(cToken, underlyingAmount);
        uint256 result = PErc20(cToken).mint(underlyingAmount);
        require(result == 0, "SMA: mint failed");
        underlying.forceApprove(cToken, 0);
        return result;
    }

    function redeem(
        address cToken,
        uint256 amount
    ) external onlyManager returns (uint256) {
        uint256 result = PErc20(cToken).redeem(amount);
        require(result == 0, "SMA: redeem failed");
        return result;
    }

    function redeemUnderlying(
        address cToken,
        uint256 underlyingAmount
    ) external onlyManager returns (uint256) {
        uint256 result = PErc20(cToken).redeemUnderlying(underlyingAmount);
        require(result == 0, "SMA: redeem underlying failed");
        return result;
    }

    function transferOut(
        address token,
        address to,
        uint256 amount
    ) external onlyManager {
        require(to != address(0), "SMA: invalid recipient");
        IERC20(token).safeTransfer(to, amount);
    }

    function approve(
        address token,
        address spender,
        uint256 amount
    ) external onlyManager {
        IERC20(token).forceApprove(spender, amount);
    }

    function callRouter(
        address target,
        bytes calldata data
    ) external onlyManager returns (bytes memory) {
        require(target.code.length > 0, "SMA: target not contract");

        (bool success, bytes memory response) = target.call(data);
        if (!success) {
            if (response.length > 0) {
                assembly {
                    let returndata_size := mload(response)
                    revert(add(32, response), returndata_size)
                }
            }
            revert("SMA: router call failed");
        }

        emit RouterCallExecuted(target, data);
        return response;
    }

    function rescueToken(
        address token,
        address to,
        uint256 amount
    ) external onlyManager {
        require(to != address(0), "SMA: invalid rescue to");
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Emergency escape hatch allowing owner to withdraw tokens directly.
     * @dev This provides owner control over funds if the manager becomes unavailable or
     *      compromised. Can only be used when the account has no outstanding borrows
     *      in any market (checked via comptroller's getAllMarkets).
     * @param token The token to withdraw
     * @param amount The amount to withdraw
     */
    function ownerEmergencyWithdraw(address token, uint256 amount)
        external
        onlyOwner
    {
        require(amount > 0, "SMA: zero amount");

        // Verify no outstanding borrows in any market
        uint256 marketsLength = enteredMarkets.length;
        for (uint256 i = 0; i < marketsLength; i++) {
            uint256 borrowBalance = PErc20(enteredMarkets[i])
                .borrowBalanceStored(address(this));
            require(borrowBalance == 0, "SMA: must repay borrows first");
        }

        IERC20(token).safeTransfer(owner, amount);
        emit EmergencyWithdraw(owner, token, amount);
    }

    function _trackMarket(address cToken) internal {
        if (enteredMarketIndex[cToken] != 0) {
            return;
        }
        enteredMarkets.push(cToken);
        enteredMarketIndex[cToken] = enteredMarkets.length;
    }

    function _untrackMarket(address cToken) internal {
        uint256 index = enteredMarketIndex[cToken];
        if (index == 0) {
            return;
        }
        uint256 lastIndex = enteredMarkets.length;
        if (index != lastIndex) {
            address last = enteredMarkets[lastIndex - 1];
            enteredMarkets[index - 1] = last;
            enteredMarketIndex[last] = index;
        }
        enteredMarkets.pop();
        delete enteredMarketIndex[cToken];
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MarginFeeDistributorUpgradeable} from "./MarginFeeDistributorUpgradeable.sol";

contract IsolatedMarginVaultUpgradeable is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    struct PositionLock {
        address user;
        address account;
        address pToken;
        uint256 amount;
    }

    MarginFeeDistributorUpgradeable public feeDistributor;
    address public executor;
    address public liquidator;

    mapping(address pToken => bool) public allowedPTokens;
    mapping(address user => mapping(address pToken => uint256)) public freeBalance;
    mapping(address user => mapping(address pToken => uint256)) public lockedBalance;
    mapping(address pToken => uint256) public totalFreeBalance;
    mapping(address pToken => uint256) public totalLockedBalance;
    mapping(uint256 positionId => PositionLock) public positionLocks;

    event ExecutorConfigured(address indexed executor);
    event LiquidatorConfigured(address indexed liquidator);
    event PTokenConfigured(address indexed pToken, bool allowed);
    event Deposited(address indexed user, address indexed pToken, uint256 amount);
    event Withdrawn(address indexed user, address indexed pToken, uint256 amount);
    event PositionLocked(
        uint256 indexed positionId,
        address indexed user,
        address indexed pToken,
        uint256 marginAmount,
        uint256 openingFee
    );
    event PositionLockIncreased(uint256 indexed positionId, uint256 amount);
    event PositionReleased(uint256 indexed positionId, uint256 lockedReduction, uint256 returnedAmount);
    event RewardsSettled(address indexed user, address indexed pToken, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    modifier onlyExecutor() {
        require(msg.sender == executor, "MarginVault: not executor");
        _;
    }

    modifier onlyLiquidator() {
        require(msg.sender == liquidator, "MarginVault: not liquidator");
        _;
    }

    function initialize(address owner_, address feeDistributor_) external initializer {
        require(owner_ != address(0), "MarginVault: zero owner");
        require(feeDistributor_.code.length > 0, "MarginVault: invalid distributor");
        __Ownable_init(owner_);
        __ReentrancyGuard_init();
        feeDistributor = MarginFeeDistributorUpgradeable(feeDistributor_);
    }

    function setExecutor(address executor_) external onlyOwner {
        require(executor_.code.length > 0, "MarginVault: invalid executor");
        executor = executor_;
        emit ExecutorConfigured(executor_);
    }

    function setLiquidator(address liquidator_) external onlyOwner {
        require(liquidator_.code.length > 0, "MarginVault: invalid liquidator");
        liquidator = liquidator_;
        emit LiquidatorConfigured(liquidator_);
    }

    function setPTokenAllowed(address pToken, bool allowed) external onlyOwner {
        require(!allowed || pToken.code.length > 0, "MarginVault: invalid pToken");
        allowedPTokens[pToken] = allowed;
        emit PTokenConfigured(pToken, allowed);
    }

    function deposit(address pToken, uint256 amount) external nonReentrant {
        require(allowedPTokens[pToken], "MarginVault: pToken disabled");
        require(amount > 0, "MarginVault: zero amount");
        _settle(msg.sender, pToken);

        uint256 balanceBefore = IERC20(pToken).balanceOf(address(this));
        IERC20(pToken).safeTransferFrom(msg.sender, address(this), amount);
        require(IERC20(pToken).balanceOf(address(this)) - balanceBefore == amount, "MarginVault: unsupported token");

        freeBalance[msg.sender][pToken] += amount;
        totalFreeBalance[pToken] += amount;
        _updateShares(msg.sender, pToken);
        _assertCovered(pToken);
        emit Deposited(msg.sender, pToken, amount);
    }

    function withdraw(address pToken, uint256 amount) external nonReentrant {
        require(amount > 0, "MarginVault: zero amount");
        _settle(msg.sender, pToken);
        uint256 free = freeBalance[msg.sender][pToken];
        require(amount <= free, "MarginVault: exceeds free balance");

        freeBalance[msg.sender][pToken] = free - amount;
        totalFreeBalance[pToken] -= amount;
        _updateShares(msg.sender, pToken);
        IERC20(pToken).safeTransfer(msg.sender, amount);
        _assertCovered(pToken);
        emit Withdrawn(msg.sender, pToken, amount);
    }

    function settle(address pToken) external nonReentrant returns (uint256) {
        uint256 amount = _settle(msg.sender, pToken);
        _assertCovered(pToken);
        return amount;
    }

    function lockForPosition(
        uint256 positionId,
        address user,
        address account,
        address pToken,
        uint256 marginAmount,
        uint256 openingFee
    ) external onlyExecutor nonReentrant {
        require(positionLocks[positionId].user == address(0), "MarginVault: position exists");
        require(allowedPTokens[pToken], "MarginVault: pToken disabled");
        require(user != address(0) && account.code.length > 0, "MarginVault: invalid position");
        require(marginAmount > 0, "MarginVault: zero margin");
        _settle(user, pToken);

        uint256 totalDebit = marginAmount + openingFee;
        require(totalDebit <= freeBalance[user][pToken], "MarginVault: insufficient free balance");
        freeBalance[user][pToken] -= totalDebit;
        lockedBalance[user][pToken] += marginAmount;
        totalFreeBalance[pToken] -= totalDebit;
        totalLockedBalance[pToken] += marginAmount;
        positionLocks[positionId] = PositionLock({user: user, account: account, pToken: pToken, amount: marginAmount});
        _updateShares(user, pToken);

        IERC20(pToken).safeTransfer(account, marginAmount);
        if (openingFee > 0) {
            IERC20(pToken).forceApprove(address(feeDistributor), openingFee);
            feeDistributor.collectFee(pToken, address(this), openingFee);
            IERC20(pToken).forceApprove(address(feeDistributor), 0);
        }
        _assertCovered(pToken);
        emit PositionLocked(positionId, user, pToken, marginAmount, openingFee);
    }

    function addToPosition(uint256 positionId, uint256 amount) external onlyExecutor nonReentrant {
        require(amount > 0, "MarginVault: zero amount");
        PositionLock storage positionLock = positionLocks[positionId];
        require(positionLock.user != address(0), "MarginVault: unknown position");
        _settle(positionLock.user, positionLock.pToken);
        require(amount <= freeBalance[positionLock.user][positionLock.pToken], "MarginVault: insufficient free balance");

        freeBalance[positionLock.user][positionLock.pToken] -= amount;
        lockedBalance[positionLock.user][positionLock.pToken] += amount;
        totalFreeBalance[positionLock.pToken] -= amount;
        totalLockedBalance[positionLock.pToken] += amount;
        positionLock.amount += amount;
        _updateShares(positionLock.user, positionLock.pToken);
        IERC20(positionLock.pToken).safeTransfer(positionLock.account, amount);
        _assertCovered(positionLock.pToken);
        emit PositionLockIncreased(positionId, amount);
    }

    function releaseFromPosition(uint256 positionId, uint256 lockedReduction, uint256 returnedAmount)
        external
        onlyExecutor
        nonReentrant
    {
        _releaseFromPosition(positionId, lockedReduction, returnedAmount, positionLocks[positionId].account);
    }

    function releaseFromLiquidation(uint256 positionId, uint256 lockedReduction, uint256 returnedAmount)
        external
        onlyLiquidator
        nonReentrant
    {
        _releaseFromPosition(positionId, lockedReduction, returnedAmount, msg.sender);
    }

    function _releaseFromPosition(uint256 positionId, uint256 lockedReduction, uint256 returnedAmount, address from)
        internal
    {
        PositionLock storage positionLock = positionLocks[positionId];
        require(positionLock.user != address(0), "MarginVault: unknown position");
        require(lockedReduction > 0 && lockedReduction <= positionLock.amount, "MarginVault: invalid reduction");
        _settle(positionLock.user, positionLock.pToken);

        if (returnedAmount > 0) {
            uint256 balanceBefore = IERC20(positionLock.pToken).balanceOf(address(this));
            IERC20(positionLock.pToken).safeTransferFrom(from, address(this), returnedAmount);
            require(
                IERC20(positionLock.pToken).balanceOf(address(this)) - balanceBefore == returnedAmount,
                "MarginVault: unsupported token"
            );
        }

        positionLock.amount -= lockedReduction;
        lockedBalance[positionLock.user][positionLock.pToken] -= lockedReduction;
        totalLockedBalance[positionLock.pToken] -= lockedReduction;
        freeBalance[positionLock.user][positionLock.pToken] += returnedAmount;
        totalFreeBalance[positionLock.pToken] += returnedAmount;
        _updateShares(positionLock.user, positionLock.pToken);

        address pToken = positionLock.pToken;
        if (positionLock.amount == 0) delete positionLocks[positionId];
        _assertCovered(pToken);
        emit PositionReleased(positionId, lockedReduction, returnedAmount);
    }

    function eligibleShares(address user, address pToken) external view returns (uint256) {
        return freeBalance[user][pToken] + lockedBalance[user][pToken];
    }

    function _settle(address user, address pToken) internal returns (uint256 reward) {
        reward = feeDistributor.claimFor(user, pToken);
        if (reward == 0) return 0;
        freeBalance[user][pToken] += reward;
        totalFreeBalance[pToken] += reward;
        _updateShares(user, pToken);
        emit RewardsSettled(user, pToken, reward);
    }

    function _updateShares(address user, address pToken) internal {
        feeDistributor.updateShares(user, pToken, freeBalance[user][pToken] + lockedBalance[user][pToken]);
    }

    function _assertCovered(address pToken) internal view {
        require(IERC20(pToken).balanceOf(address(this)) >= totalFreeBalance[pToken], "MarginVault: undercollateralized");
    }

    uint256[40] private __gap;
}

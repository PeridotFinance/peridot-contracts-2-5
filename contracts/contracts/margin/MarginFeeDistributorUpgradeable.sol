// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IIsolatedMarginConfig} from "./interfaces/IIsolatedMarginConfig.sol";

contract MarginFeeDistributorUpgradeable is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    uint256 public constant INDEX_SCALE = 1e36;
    uint256 public constant BPS = 10_000;

    struct Pool {
        uint256 rewardIndex;
        uint256 totalShares;
        uint256 rewardReserve;
    }

    struct UserReward {
        uint256 shares;
        uint256 index;
        uint256 accrued;
    }

    IIsolatedMarginConfig public config;
    address public vault;

    mapping(address collector => bool) public feeCollectors;
    mapping(address pToken => Pool) public pools;
    mapping(address pToken => mapping(address user => UserReward)) public userRewards;

    event VaultConfigured(address indexed vault);
    event FeeCollectorConfigured(address indexed collector, bool allowed);
    event SharesUpdated(address indexed pToken, address indexed user, uint256 oldShares, uint256 newShares);
    event FeeCollected(
        address indexed pToken, uint256 amount, uint256 depositorAmount, uint256 insuranceAmount, uint256 treasuryAmount
    );
    event RewardsClaimed(address indexed pToken, address indexed user, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    modifier onlyVault() {
        require(msg.sender == vault, "FeeDistributor: not vault");
        _;
    }

    function initialize(address owner_, address config_) external initializer {
        require(owner_ != address(0), "FeeDistributor: zero owner");
        require(config_.code.length > 0, "FeeDistributor: invalid config");
        __Ownable_init(owner_);
        __ReentrancyGuard_init();
        config = IIsolatedMarginConfig(config_);
    }

    function setVault(address vault_) external onlyOwner {
        require(vault_.code.length > 0, "FeeDistributor: invalid vault");
        vault = vault_;
        emit VaultConfigured(vault_);
    }

    function setFeeCollector(address collector, bool allowed) external onlyOwner {
        require(!allowed || collector.code.length > 0, "FeeDistributor: invalid collector");
        feeCollectors[collector] = allowed;
        emit FeeCollectorConfigured(collector, allowed);
    }

    function updateShares(address user, address pToken, uint256 newShares) external onlyVault {
        UserReward storage userReward = userRewards[pToken][user];
        Pool storage pool = pools[pToken];
        _checkpoint(pool, userReward);

        uint256 oldShares = userReward.shares;
        pool.totalShares = pool.totalShares - oldShares + newShares;
        userReward.shares = newShares;
        emit SharesUpdated(pToken, user, oldShares, newShares);
    }

    function collectFee(address pToken, address from, uint256 amount) external nonReentrant {
        require(feeCollectors[msg.sender], "FeeDistributor: not collector");
        require(amount > 0, "FeeDistributor: zero fee");

        uint256 balanceBefore = IERC20(pToken).balanceOf(address(this));
        IERC20(pToken).safeTransferFrom(from, address(this), amount);
        require(IERC20(pToken).balanceOf(address(this)) - balanceBefore == amount, "FeeDistributor: fee token");

        uint256 depositorAmount = Math.mulDiv(amount, config.depositorShareBps(), BPS);
        uint256 insuranceAmount = Math.mulDiv(amount, config.insuranceShareBps(), BPS);
        uint256 treasuryAmount = amount - depositorAmount - insuranceAmount;

        Pool storage pool = pools[pToken];
        if (pool.totalShares == 0) {
            insuranceAmount += depositorAmount;
            depositorAmount = 0;
        } else if (depositorAmount > 0) {
            pool.rewardReserve += depositorAmount;
            pool.rewardIndex += Math.mulDiv(depositorAmount, INDEX_SCALE, pool.totalShares);
        }

        if (insuranceAmount > 0) IERC20(pToken).safeTransfer(config.insuranceFund(), insuranceAmount);
        if (treasuryAmount > 0) IERC20(pToken).safeTransfer(config.treasury(), treasuryAmount);

        emit FeeCollected(pToken, amount, depositorAmount, insuranceAmount, treasuryAmount);
    }

    function claimFor(address user, address pToken) external onlyVault nonReentrant returns (uint256 amount) {
        UserReward storage userReward = userRewards[pToken][user];
        Pool storage pool = pools[pToken];
        _checkpoint(pool, userReward);
        amount = userReward.accrued;
        if (amount == 0) return 0;

        userReward.accrued = 0;
        pool.rewardReserve -= amount;
        IERC20(pToken).safeTransfer(vault, amount);
        emit RewardsClaimed(pToken, user, amount);
    }

    function pendingRewards(address user, address pToken) external view returns (uint256) {
        UserReward memory userReward = userRewards[pToken][user];
        Pool memory pool = pools[pToken];
        if (userReward.shares == 0 || pool.rewardIndex <= userReward.index) return userReward.accrued;
        return userReward.accrued + Math.mulDiv(userReward.shares, pool.rewardIndex - userReward.index, INDEX_SCALE);
    }

    function _checkpoint(Pool storage pool, UserReward storage userReward) internal {
        if (userReward.shares > 0 && pool.rewardIndex > userReward.index) {
            userReward.accrued += Math.mulDiv(userReward.shares, pool.rewardIndex - userReward.index, INDEX_SCALE);
        }
        userReward.index = pool.rewardIndex;
    }

    uint256[40] private __gap;
}

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
    // Keep this legacy-config fallback aligned with IsolatedMarginConfigUpgradeable's anti-sniping default.
    uint256 public constant DEFAULT_FEE_IMMEDIATE_SHARE_BPS = 0;
    uint256 public constant MIN_FEE_IMMEDIATE_SHARE_BPS = 0;
    uint256 public constant MAX_FEE_IMMEDIATE_SHARE_BPS = 2_000;
    uint256 public constant DEFAULT_FEE_STREAM_DURATION = 7 days;
    uint256 public constant MIN_FEE_STREAM_DURATION = 1 days;
    uint256 public constant MAX_FEE_STREAM_DURATION = 30 days;

    struct Pool {
        uint256 rewardIndex;
        uint256 totalShares;
        uint256 rewardReserve;
        uint256 rewardRate;
        uint256 lastUpdate;
        uint256 periodFinish;
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
    event RewardStreamUpdated(
        address indexed pToken,
        uint256 immediateReward,
        uint256 scheduledReward,
        uint256 rewardRate,
        uint256 periodFinish
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
        _updatePool(pool);
        if (pool.totalShares == 0) {
            insuranceAmount += depositorAmount;
            depositorAmount = 0;
        } else if (depositorAmount > 0) {
            pool.rewardReserve += depositorAmount;
            _scheduleDepositorRewards(pToken, pool, depositorAmount);
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
        uint256 currentIndex = _currentRewardIndex(pool);
        if (userReward.shares == 0 || currentIndex <= userReward.index) return userReward.accrued;
        return userReward.accrued + Math.mulDiv(userReward.shares, currentIndex - userReward.index, INDEX_SCALE);
    }

    function _checkpoint(Pool storage pool, UserReward storage userReward) internal {
        _updatePool(pool);
        if (userReward.shares > 0 && pool.rewardIndex > userReward.index) {
            userReward.accrued += Math.mulDiv(userReward.shares, pool.rewardIndex - userReward.index, INDEX_SCALE);
        }
        userReward.index = pool.rewardIndex;
    }

    function _scheduleDepositorRewards(address pToken, Pool storage pool, uint256 depositorAmount) internal {
        uint256 immediateReward = Math.mulDiv(depositorAmount, _feeImmediateShareBps(), BPS);
        uint256 newStreamReward = depositorAmount - immediateReward;
        uint256 remainingStream =
            block.timestamp < pool.periodFinish ? (pool.periodFinish - block.timestamp) * pool.rewardRate : 0;
        uint256 streamDuration = _feeStreamDuration();
        uint256 streamBudget = remainingStream + newStreamReward;
        uint256 rewardRate = streamBudget / streamDuration;
        uint256 scheduledReward = rewardRate * streamDuration;

        // Make sub-duration rounding immediately claimable instead of leaving pToken dust stranded.
        immediateReward += streamBudget - scheduledReward;
        if (immediateReward > 0) {
            pool.rewardIndex += Math.mulDiv(immediateReward, INDEX_SCALE, pool.totalShares);
        }

        pool.rewardRate = rewardRate;
        pool.lastUpdate = block.timestamp;
        pool.periodFinish = block.timestamp + streamDuration;
        emit RewardStreamUpdated(pToken, immediateReward, scheduledReward, pool.rewardRate, pool.periodFinish);
    }

    function _feeImmediateShareBps() internal view returns (uint256 immediateShareBps) {
        (bool success, bytes memory returnData) =
            address(config).staticcall(abi.encodeWithSelector(IIsolatedMarginConfig.feeImmediateShareBps.selector));
        // Preserve fee collection if this implementation is upgraded before a legacy config proxy.
        if (!success || returnData.length < 32) return DEFAULT_FEE_IMMEDIATE_SHARE_BPS;

        immediateShareBps = abi.decode(returnData, (uint256));
        require(
            immediateShareBps >= MIN_FEE_IMMEDIATE_SHARE_BPS && immediateShareBps <= MAX_FEE_IMMEDIATE_SHARE_BPS,
            "FeeDistributor: invalid immediate share"
        );
    }

    function _feeStreamDuration() internal view returns (uint256 streamDuration) {
        (bool success, bytes memory returnData) =
            address(config).staticcall(abi.encodeWithSelector(IIsolatedMarginConfig.feeStreamDuration.selector));
        // Match the config's pre-upgrade default until the new selector becomes available.
        if (!success || returnData.length < 32) return DEFAULT_FEE_STREAM_DURATION;

        streamDuration = abi.decode(returnData, (uint256));
        require(
            streamDuration >= MIN_FEE_STREAM_DURATION && streamDuration <= MAX_FEE_STREAM_DURATION,
            "FeeDistributor: invalid stream duration"
        );
    }

    function _updatePool(Pool storage pool) internal {
        if (pool.totalShares == 0) {
            // Pause an existing stream while nobody is eligible rather than burning or stranding it.
            if (pool.rewardRate > 0 && pool.lastUpdate < pool.periodFinish) {
                pool.periodFinish = block.timestamp + (pool.periodFinish - pool.lastUpdate);
            }
            pool.lastUpdate = block.timestamp;
            return;
        }

        uint256 applicableTime = block.timestamp < pool.periodFinish ? block.timestamp : pool.periodFinish;
        if (applicableTime <= pool.lastUpdate) return;
        uint256 streamedReward = (applicableTime - pool.lastUpdate) * pool.rewardRate;
        if (streamedReward > 0) {
            pool.rewardIndex += Math.mulDiv(streamedReward, INDEX_SCALE, pool.totalShares);
        }
        pool.lastUpdate = applicableTime;
    }

    function _currentRewardIndex(Pool memory pool) internal view returns (uint256) {
        if (pool.totalShares == 0) return pool.rewardIndex;
        uint256 applicableTime = block.timestamp < pool.periodFinish ? block.timestamp : pool.periodFinish;
        if (applicableTime <= pool.lastUpdate) return pool.rewardIndex;
        uint256 streamedReward = (applicableTime - pool.lastUpdate) * pool.rewardRate;
        return pool.rewardIndex + Math.mulDiv(streamedReward, INDEX_SCALE, pool.totalShares);
    }

    uint256[40] private __gap;
}

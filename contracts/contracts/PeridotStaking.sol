// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PeridotStaking
 * @notice Staking contract for $P that distributes revenue in a switchable reward token.
 * @dev Index-based rewards; anyone can deposit rewards, users can stake/unstake freely.
 */
contract PeridotStaking {
    using SafeERC20 for IERC20;

    uint256 public constant INDEX_SCALE = 1e36;

    struct RewardState {
        uint256 rewardRate;
        uint256 rewardPerTokenStored;
        uint256 lastUpdateTime;
        uint256 periodFinish;
        uint256 duration;
        bool initialized;
    }

    IERC20 public stakeToken;
    address public owner;

    address public currentRewardToken;
    address[] public rewardTokens;
    mapping(address => bool) public isRewardToken;

    uint256 public totalStaked;
    mapping(address => uint256) public balances;

    // rewardToken => state
    mapping(address => RewardState) public rewardState;
    // rewardToken => user => index
    mapping(address => mapping(address => uint256)) public userRewardIndex;
    // rewardToken => user => accrued
    mapping(address => mapping(address => uint256)) public accrued;

    bool private _notEntered;

    event OwnerUpdated(address indexed previousOwner, address indexed newOwner);
    event RewardTokenUpdated(address indexed previousToken, address indexed newToken, uint256 duration);
    event RewardTokenEnabled(address indexed rewardToken);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardAdded(
        address indexed rewardToken, uint256 amount, uint256 duration, uint256 newRate, uint256 periodFinish
    );
    event RewardClaimed(address indexed user, address indexed rewardToken, uint256 amount);
    event EmergencyRewardWithdraw(address indexed rewardToken, address indexed to, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "PeridotStaking: not owner");
        _;
    }

    modifier nonReentrant() {
        require(_notEntered, "PeridotStaking: reentrant");
        _notEntered = false;
        _;
        _notEntered = true;
    }

    function initialize(address stakeToken_, address rewardToken_, address owner_, uint256 rewardDuration_) external {
        require(address(stakeToken) == address(0), "PeridotStaking: initialized");
        require(stakeToken_ != address(0), "PeridotStaking: stake token zero");
        require(owner_ != address(0), "PeridotStaking: owner zero");
        require(rewardDuration_ > 0, "PeridotStaking: duration zero");

        stakeToken = IERC20(stakeToken_);
        owner = owner_;
        _notEntered = true;

        _enableRewardToken(rewardToken_);
        rewardState[rewardToken_].duration = rewardDuration_;
        currentRewardToken = rewardToken_;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "PeridotStaking: owner zero");
        emit OwnerUpdated(owner, newOwner);
        owner = newOwner;
    }

    function setRewardToken(address newToken, uint256 duration) external onlyOwner {
        require(newToken != address(0), "PeridotStaking: reward token zero");
        require(duration > 0, "PeridotStaking: duration zero");
        address previous = currentRewardToken;
        _updateReward(previous, address(0));
        _enableRewardToken(newToken);
        _updateReward(newToken, address(0));
        rewardState[newToken].duration = duration;
        currentRewardToken = newToken;
        emit RewardTokenUpdated(previous, newToken, duration);
    }

    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "PeridotStaking: amount zero");
        _accrueAll(msg.sender);

        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
        totalStaked += amount;

        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        require(amount > 0, "PeridotStaking: amount zero");
        uint256 balance = balances[msg.sender];
        require(balance >= amount, "PeridotStaking: insufficient balance");

        _accrueAll(msg.sender);

        balances[msg.sender] = balance - amount;
        totalStaked -= amount;
        stakeToken.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    function addReward(address rewardToken, uint256 amount) external nonReentrant {
        require(amount > 0, "PeridotStaking: amount zero");
        require(isRewardToken[rewardToken], "PeridotStaking: reward token disabled");
        require(rewardToken == currentRewardToken, "PeridotStaking: not current reward");

        _updateReward(rewardToken, address(0));
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);

        RewardState storage st = rewardState[rewardToken];
        uint256 duration = st.duration;
        require(duration > 0, "PeridotStaking: duration not set");

        uint256 newRate;
        uint256 periodFinish;
        if (block.timestamp >= st.periodFinish) {
            newRate = amount / duration;
        } else {
            uint256 remaining = st.periodFinish - block.timestamp;
            uint256 leftover = remaining * st.rewardRate;
            newRate = (amount + leftover) / duration;
        }

        st.rewardRate = newRate;
        st.lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + duration;
        st.periodFinish = periodFinish;

        emit RewardAdded(rewardToken, amount, duration, newRate, periodFinish);
    }

    function claim(address[] calldata rewardTokens_) external nonReentrant {
        for (uint256 i = 0; i < rewardTokens_.length; i++) {
            _claimToken(msg.sender, rewardTokens_[i]);
        }
    }

    function claimAll() external nonReentrant {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            _claimToken(msg.sender, rewardTokens[i]);
        }
    }

    function emergencyWithdrawReward(address rewardToken, address to, uint256 amount) external onlyOwner {
        require(rewardToken != address(stakeToken), "PeridotStaking: cannot withdraw stake");
        require(to != address(0), "PeridotStaking: recipient zero");
        IERC20(rewardToken).safeTransfer(to, amount);
        emit EmergencyRewardWithdraw(rewardToken, to, amount);
    }

    function earned(address user, address rewardToken) external view returns (uint256) {
        if (!rewardState[rewardToken].initialized) {
            return 0;
        }

        uint256 rpt = _rewardPerTokenView(rewardToken);
        uint256 userIdx = userRewardIndex[rewardToken][user];
        if (userIdx == 0) {
            userIdx = INDEX_SCALE;
        }
        uint256 delta = rpt - userIdx;
        uint256 pendingAccrual = (balances[user] * delta) / INDEX_SCALE;
        return accrued[rewardToken][user] + pendingAccrual;
    }

    function rewardTokensLength() external view returns (uint256) {
        return rewardTokens.length;
    }

    function _claimToken(address user, address rewardToken) internal {
        _updateReward(rewardToken, user);
        uint256 amount = accrued[rewardToken][user];
        if (amount == 0) {
            return;
        }
        accrued[rewardToken][user] = 0;
        IERC20(rewardToken).safeTransfer(user, amount);
        emit RewardClaimed(user, rewardToken, amount);
    }

    function _enableRewardToken(address rewardToken) internal {
        require(rewardToken != address(0), "PeridotStaking: reward token zero");
        if (isRewardToken[rewardToken]) {
            return;
        }
        isRewardToken[rewardToken] = true;
        rewardTokens.push(rewardToken);
        RewardState storage st = rewardState[rewardToken];
        if (!st.initialized) {
            st.initialized = true;
            st.rewardPerTokenStored = INDEX_SCALE;
        }
        emit RewardTokenEnabled(rewardToken);
    }

    function _accrueAll(address user) internal {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            _updateReward(rewardTokens[i], user);
        }
    }

    function _updateReward(address rewardToken, address user) internal {
        RewardState storage st = rewardState[rewardToken];
        if (!st.initialized) {
            return;
        }

        st.rewardPerTokenStored = _rewardPerTokenView(rewardToken);
        st.lastUpdateTime = _lastTimeRewardApplicable(st.periodFinish);

        if (user != address(0)) {
            uint256 userIdx = userRewardIndex[rewardToken][user];
            if (userIdx == 0) {
                userIdx = INDEX_SCALE;
            }
            uint256 delta = st.rewardPerTokenStored - userIdx;
            if (delta > 0) {
                uint256 amount = (balances[user] * delta) / INDEX_SCALE;
                accrued[rewardToken][user] += amount;
            }
            userRewardIndex[rewardToken][user] = st.rewardPerTokenStored;
        }
    }

    function _rewardPerTokenView(address rewardToken) internal view returns (uint256) {
        RewardState storage st = rewardState[rewardToken];
        if (!st.initialized) {
            return 0;
        }
        if (totalStaked == 0) {
            return st.rewardPerTokenStored;
        }
        uint256 lastTime = _lastTimeRewardApplicable(st.periodFinish);
        uint256 timeDelta = lastTime - st.lastUpdateTime;
        if (timeDelta == 0) {
            return st.rewardPerTokenStored;
        }
        uint256 accruedPerToken = (timeDelta * st.rewardRate * INDEX_SCALE) / totalStaked;
        return st.rewardPerTokenStored + accruedPerToken;
    }

    function _lastTimeRewardApplicable(uint256 periodFinish) internal view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }
}

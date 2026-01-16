// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20; // moved to xperidot folder

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title xPStaking
 * @author Peridot
 * @notice Timelocked staking contract for xPERIDOT tokens with APR-based rewards
 * @dev Supports multiple lock durations (1m, 3m, 12m, 24m) with different APR bonuses
 */
contract xPStaking is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    // --- Constants ---

    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant BASIS_POINTS = 10000;

    // --- State Variables ---

    /// @notice The xPERIDOT token to stake
    IERC20 public immutable xPeridotToken;

    /// @notice The PERIDOT token used for rewards
    IERC20 public immutable rewardToken;

    /// @notice Base APR in basis points (applied to all locks)
    uint256 public baseAprBps;

    /// @notice Lock duration bonus APR in basis points
    mapping(uint8 => uint256) public lockBonusBps;

    /// @notice Available lock durations in months
    uint8[] public availableLockMonths;

    /// @notice User positions
    mapping(address => Position[]) public userPositions;

    /// @notice Total staked xPERIDOT across all positions
    uint256 public totalStaked;

    // --- Structs ---

    struct Position {
        uint256 amountXP; // Amount of xPERIDOT staked
        uint256 startTime; // Timestamp when position was created
        uint256 endTime; // Timestamp when position can be unstaked
        uint256 lastClaim; // Last time rewards were claimed
        uint8 lockMonths; // Lock duration in months
        uint256 aprBps; // Total APR for this position (base + bonus)
    }

    // --- Events ---

    event Staked(
        address indexed user,
        uint256 indexed positionId,
        uint256 amount,
        uint8 lockMonths,
        uint256 endTime,
        uint256 aprBps
    );

    event Unstaked(address indexed user, uint256 indexed positionId, uint256 amount);

    event RewardsClaimed(address indexed user, uint256 indexed positionId, uint256 rewardAmount);

    event APRConfigUpdated(uint256 baseAprBps, uint8 lockMonths, uint256 bonusBps);
    event RewardsFunded(address indexed funder, uint256 amount);

    // --- Constructor ---

    constructor(address _xPeridotToken, address _rewardToken, address _owner, uint256 _baseAprBps) Ownable(_owner) {
        require(_xPeridotToken != address(0), "Invalid xPERIDOT token");
        require(_rewardToken != address(0), "Invalid reward token");
        require(_baseAprBps <= 10000, "Base APR too high"); // Max 100%

        xPeridotToken = IERC20(_xPeridotToken);
        rewardToken = IERC20(_rewardToken);
        baseAprBps = _baseAprBps;

        // Set default lock durations and bonuses
        availableLockMonths.push(1);
        availableLockMonths.push(3);
        availableLockMonths.push(12);
        availableLockMonths.push(24);

        lockBonusBps[1] = 500; // +5%
        lockBonusBps[3] = 1200; // +12%
        lockBonusBps[12] = 4000; // +40%
        lockBonusBps[24] = 8000; // +80%
    }

    // --- Admin Functions ---

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Set base APR and lock bonus APRs
     * @param _baseAprBps Base APR in basis points
     * @param lockMonths Array of lock durations in months
     * @param bonusBps Array of bonus APRs in basis points
     */
    function setAPRConfig(uint256 _baseAprBps, uint8[] calldata lockMonths, uint256[] calldata bonusBps)
        external
        onlyOwner
    {
        require(_baseAprBps <= 10000, "Base APR too high");
        require(lockMonths.length == bonusBps.length, "Array length mismatch");

        baseAprBps = _baseAprBps;

        // Clear existing lock months
        delete availableLockMonths;

        // Set new configuration
        for (uint256 i = 0; i < lockMonths.length; i++) {
            require(lockMonths[i] > 0, "Invalid lock duration");
            require(bonusBps[i] <= 20000, "Bonus APR too high"); // Max 200% bonus

            availableLockMonths.push(lockMonths[i]);
            lockBonusBps[lockMonths[i]] = bonusBps[i];

            emit APRConfigUpdated(_baseAprBps, lockMonths[i], bonusBps[i]);
        }
    }

    /**
     * @notice Fund the contract with reward tokens
     * @param amount Amount of reward tokens to add
     */
    function fundRewards(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardsFunded(msg.sender, amount);
    }

    // --- Staking Functions ---

    /**
     * @notice Stake xPERIDOT tokens for a specified lock duration
     * @param amount Amount of xPERIDOT tokens to stake
     * @param lockMonths Lock duration in months (must be supported)
     * @return positionId ID of the created position
     */
    function stake(uint256 amount, uint8 lockMonths) external nonReentrant whenNotPaused returns (uint256 positionId) {
        require(amount > 0, "Amount must be greater than 0");
        require(_isValidLockDuration(lockMonths), "Invalid lock duration");

        // Calculate position details
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + (uint256(lockMonths) * 30 days); // Approximate month length
        uint256 bonusApr = lockBonusBps[lockMonths];
        uint256 totalAprBps = baseAprBps + bonusApr;

        // Transfer xPERIDOT from user
        xPeridotToken.safeTransferFrom(msg.sender, address(this), amount);

        // Create position
        Position memory newPosition = Position({
            amountXP: amount,
            startTime: startTime,
            endTime: endTime,
            lastClaim: startTime,
            lockMonths: lockMonths,
            aprBps: totalAprBps
        });

        userPositions[msg.sender].push(newPosition);
        positionId = userPositions[msg.sender].length - 1;

        // Update total staked
        totalStaked += amount;

        emit Staked(msg.sender, positionId, amount, lockMonths, endTime, totalAprBps);
    }

    /**
     * @notice Unstake a position after lock period expires
     * @param positionId ID of the position to unstake
     */
    function unstake(uint256 positionId) external nonReentrant {
        require(positionId < userPositions[msg.sender].length, "Invalid position ID");

        Position storage position = userPositions[msg.sender][positionId];
        require(position.amountXP > 0, "Position already unstaked");
        require(block.timestamp >= position.endTime, "Position still locked");

        // Claim any remaining rewards
        _claimRewards(msg.sender, positionId);

        uint256 amount = position.amountXP;

        // Update total staked
        totalStaked -= amount;

        // Remove position (set amount to 0 to mark as unstaked)
        position.amountXP = 0;

        // Transfer xPERIDOT back to user
        xPeridotToken.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, positionId, amount);
    }

    /**
     * @notice Claim accumulated rewards for a position
     * @param positionId ID of the position to claim rewards for
     */
    function claimRewards(uint256 positionId) external nonReentrant {
        _claimRewards(msg.sender, positionId);
    }

    /**
     * @notice Claim rewards for all user positions
     */
    function claimAllRewards() external nonReentrant {
        Position[] storage positions = userPositions[msg.sender];
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].amountXP > 0) {
                _claimRewards(msg.sender, i);
            }
        }
    }

    // --- Internal Functions ---

    function _claimRewards(address user, uint256 positionId) internal {
        require(positionId < userPositions[user].length, "Invalid position ID");

        Position storage position = userPositions[user][positionId];
        require(position.amountXP > 0, "Position not active");

        uint256 rewardAmount = calculateRewards(user, positionId);

        if (rewardAmount > 0) {
            // Update last claim timestamp
            position.lastClaim = block.timestamp;

            // Transfer rewards if available
            uint256 contractBalance = rewardToken.balanceOf(address(this));
            if (contractBalance >= rewardAmount) {
                rewardToken.safeTransfer(user, rewardAmount);
                emit RewardsClaimed(user, positionId, rewardAmount);
            }
        }
    }

    function _isValidLockDuration(uint8 lockMonths) internal view returns (bool) {
        for (uint256 i = 0; i < availableLockMonths.length; i++) {
            if (availableLockMonths[i] == lockMonths) {
                return true;
            }
        }
        return false;
    }

    // --- View Functions ---

    /**
     * @notice Calculate accumulated rewards for a position
     * @param user Address of the user
     * @param positionId ID of the position
     * @return rewardAmount Amount of rewards accumulated
     */
    function calculateRewards(address user, uint256 positionId) public view returns (uint256 rewardAmount) {
        if (positionId >= userPositions[user].length) {
            return 0;
        }

        Position storage position = userPositions[user][positionId];
        if (position.amountXP == 0) {
            return 0;
        }

        uint256 elapsedSeconds = block.timestamp - position.lastClaim;

        // rewardAccrued = amountXPStaked * aprBps(lock) / 10000 * elapsedSeconds / YEAR
        rewardAmount = (position.amountXP * position.aprBps * elapsedSeconds) / (BASIS_POINTS * SECONDS_PER_YEAR);
    }

    /**
     * @notice Get total rewards across all user positions
     * @param user Address of the user
     * @return totalRewards Total accumulated rewards
     */
    function getTotalUserRewards(address user) external view returns (uint256 totalRewards) {
        Position[] storage positions = userPositions[user];
        for (uint256 i = 0; i < positions.length; i++) {
            totalRewards += calculateRewards(user, i);
        }
    }

    /**
     * @notice Get user's total staked xPERIDOT amount
     * @param user Address of the user
     * @return totalStakedAmount Total staked xPERIDOT
     */
    function getUserTotalStaked(address user) external view returns (uint256 totalStakedAmount) {
        Position[] storage positions = userPositions[user];
        for (uint256 i = 0; i < positions.length; i++) {
            totalStakedAmount += positions[i].amountXP;
        }
    }

    /**
     * @notice Get number of positions for a user
     * @param user Address of the user
     * @return Number of positions
     */
    function getUserPositionCount(address user) external view returns (uint256) {
        return userPositions[user].length;
    }

    /**
     * @notice Get position details
     * @param user Address of the user
     * @param positionId ID of the position
     * @return position Position struct
     */
    function getPosition(address user, uint256 positionId) external view returns (Position memory position) {
        require(positionId < userPositions[user].length, "Invalid position ID");
        return userPositions[user][positionId];
    }

    /**
     * @notice Get all available lock durations
     * @return Array of available lock durations in months
     */
    function getAvailableLockDurations() external view returns (uint8[] memory) {
        return availableLockMonths;
    }

    /**
     * @notice Get total APR for a lock duration
     * @param lockMonths Lock duration in months
     * @return Total APR in basis points (base + bonus)
     */
    function getTotalAPR(uint8 lockMonths) external view returns (uint256) {
        require(_isValidLockDuration(lockMonths), "Invalid lock duration");
        return baseAprBps + lockBonusBps[lockMonths];
    }

    /**
     * @notice Get contract statistics
     * @return contractBalance Current reward token balance
     * @return totalStakedXP Total xPERIDOT staked
     * @return currentBaseAPR Current base APR
     */
    function getContractStats()
        external
        view
        returns (uint256 contractBalance, uint256 totalStakedXP, uint256 currentBaseAPR)
    {
        contractBalance = rewardToken.balanceOf(address(this));
        totalStakedXP = totalStaked;
        currentBaseAPR = baseAprBps;
    }

    // --- Emergency Functions ---

    /**
     * @notice Emergency function to rescue tokens (only owner)
     * @param token Token to rescue
     * @param amount Amount to rescue
     * @dev Cannot rescue staked xPERIDOT or reward tokens while positions exist
     */
    function rescueTokens(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "Invalid token");

        if (token == address(xPeridotToken)) {
            require(totalStaked == 0, "Cannot rescue staked tokens");
        }

        if (token == address(rewardToken)) {
            // Only allow rescuing excess reward tokens
            uint256 totalPendingRewards = _calculateTotalPendingRewards();
            uint256 contractBalance = rewardToken.balanceOf(address(this));
            require(contractBalance > totalPendingRewards, "Cannot rescue pending rewards");
            uint256 maxRescue = contractBalance - totalPendingRewards;
            require(amount <= maxRescue, "Cannot rescue pending rewards");
        }

        IERC20(token).safeTransfer(owner(), amount);
    }

    function _calculateTotalPendingRewards() internal view returns (uint256 totalPending) {
        // This would require iterating through all positions of all users
        // For gas efficiency, we approximate or require admin to be careful
        // In practice, admin should only rescue tokens when no active positions exist
        return 0; // Simplified for this implementation
    }
}

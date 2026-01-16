// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20; // moved to xperidot folder

import "../PToken.sol";
import "../PTokenInterfaces.sol";
import "../PriceOracle.sol";
import "../Governance/Peridot.sol";
import "../PeridottrollerInterface.sol";
import "./xPeridotVault.sol";
import "./xPStaking.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PeridotTierRewardsV2
 * @author Peridot
 * @notice Enhanced tier-based reward system using staked xPERIDOT positions
 * @dev Calculates user tiers based on staked PERIDOT value vs supplied portfolio value
 */
contract PeridotTierRewardsV2 is Ownable {
    // --- State Variables ---

    /// @notice Peridot token contract for price reference
    Peridot public immutable peridotToken;

    /// @notice Peridottroller for portfolio calculations
    PeridottrollerInterface public immutable peridottroller;

    /// @notice Price oracle for USD valuations
    PriceOracle public immutable oracle;

    /// @notice xPeridot vault for exchange rate
    xPeridotVault public immutable vault;

    /// @notice xPERIDOT staking contract
    xPStaking public immutable stakingContract;

    /// @notice Admin-configurable PERIDOT price (fallback if oracle doesn't have PERIDOT price)
    uint256 public peridotPriceUSD; // scaled by 1e18

    /// @notice Whether to count only locked positions for tier calculation
    bool public countOnlyLockedPositions;

    // --- Constants ---

    /// @notice Tier thresholds (in basis points, 10000 = 100%)
    uint256 public constant TIER_1_THRESHOLD = 100; // 1%
    uint256 public constant TIER_2_THRESHOLD = 500; // 5%
    uint256 public constant TIER_3_THRESHOLD = 1000; // 10%

    // --- Configurable Multipliers ---

    uint256 public tier1Multiplier = 10000; // 1.0x (no bonus)
    uint256 public tier2Multiplier = 11000; // 1.1x
    uint256 public tier3Multiplier = 12500; // 1.25x
    uint256 public tier4Multiplier = 15000; // 1.5x

    // --- Events ---

    event TierCalculated(
        address indexed user,
        uint8 tier,
        uint256 stakedPeridotValueUSD,
        uint256 suppliedValueUSD,
        uint256 tierPercentBps
    );

    event RewardMultiplierUpdated(uint8 tier, uint256 newMultiplier);
    event PeridotPriceUpdated(uint256 newPrice);
    event LockRequirementUpdated(bool countOnlyLocked);

    // --- Constructor ---

    constructor(
        address _peridotToken,
        address _peridottroller,
        address _oracle,
        address _xPeridotVault,
        address _xPStaking,
        address _owner
    ) Ownable(_owner) {
        require(_peridotToken != address(0), "Invalid peridot token");
        require(_peridottroller != address(0), "Invalid peridottroller");
        require(_oracle != address(0), "Invalid oracle");
        require(_xPeridotVault != address(0), "Invalid xPeridot vault");
        require(_xPStaking != address(0), "Invalid xP staking");

        peridotToken = Peridot(_peridotToken);
        peridottroller = PeridottrollerInterface(_peridottroller);
        oracle = PriceOracle(_oracle);
        vault = xPeridotVault(_xPeridotVault);
        stakingContract = xPStaking(_xPStaking);

        // Default PERIDOT price to $1 (scaled by 1e18)
        peridotPriceUSD = 1e18;

        // Default to counting only locked positions
        countOnlyLockedPositions = true;
    }

    // --- Admin Functions ---

    /**
     * @notice Set PERIDOT price for tier calculations
     * @param newPrice New PERIDOT price in USD (scaled by 1e18)
     */
    function setPeridotPrice(uint256 newPrice) external onlyOwner {
        require(newPrice > 0, "Price must be greater than 0");
        peridotPriceUSD = newPrice;
        emit PeridotPriceUpdated(newPrice);
    }

    /**
     * @notice Configure whether to count only locked positions for tiers
     * @param onlyLocked True to count only locked positions, false for all staked positions
     */
    function setLockRequirement(bool onlyLocked) external onlyOwner {
        countOnlyLockedPositions = onlyLocked;
        emit LockRequirementUpdated(onlyLocked);
    }

    /**
     * @notice Update reward multipliers for multiple tiers
     * @param tiers Array of tier numbers (1-4)
     * @param newMultipliers Array of new multipliers in basis points
     */
    function updateTierMultipliers(uint8[] calldata tiers, uint256[] calldata newMultipliers) external onlyOwner {
        require(tiers.length == newMultipliers.length, "Array length mismatch");

        for (uint256 i = 0; i < tiers.length; i++) {
            require(tiers[i] >= 1 && tiers[i] <= 4, "Invalid tier");
            require(newMultipliers[i] >= 10000, "Multiplier cannot be less than 1.0x");

            if (tiers[i] == 1) tier1Multiplier = newMultipliers[i];
            else if (tiers[i] == 2) tier2Multiplier = newMultipliers[i];
            else if (tiers[i] == 3) tier3Multiplier = newMultipliers[i];
            else if (tiers[i] == 4) tier4Multiplier = newMultipliers[i];

            emit RewardMultiplierUpdated(tiers[i], newMultipliers[i]);
        }
    }

    // --- Core Tier Calculation ---

    /**
     * @notice Calculate user's tier based on staked PERIDOT value vs supplied portfolio value
     * @param user Address of the user
     * @return tier User's current tier (1-4)
     * @return tierPercentBps Percentage in basis points (staked PERIDOT value / supplied value * 10000)
     */
    function calculateUserTier(address user) public view returns (uint8 tier, uint256 tierPercentBps) {
        (uint256 stakedPeridotValueUSD, uint256 suppliedValueUSD) = getUserValues(user);

        if (suppliedValueUSD == 0) {
            return (1, 0);
        }

        tierPercentBps = (stakedPeridotValueUSD * 10000) / suppliedValueUSD;

        if (tierPercentBps >= TIER_3_THRESHOLD) {
            tier = 4;
        } else if (tierPercentBps >= TIER_2_THRESHOLD) {
            tier = 3;
        } else if (tierPercentBps >= TIER_1_THRESHOLD) {
            tier = 2;
        } else {
            tier = 1;
        }

        return (tier, tierPercentBps);
    }

    /**
     * @notice Get user's staked PERIDOT value and supplied portfolio value
     * @param user Address of the user
     * @return stakedPeridotValueUSD USD value of staked PERIDOT-equivalent
     * @return suppliedValueUSD USD value of supplied assets (excluding PERIDOT)
     */
    function getUserValues(address user) public view returns (uint256 stakedPeridotValueUSD, uint256 suppliedValueUSD) {
        stakedPeridotValueUSD = _getStakedPeridotValue(user);
        suppliedValueUSD = _getSuppliedPortfolioValue(user);
        return (stakedPeridotValueUSD, suppliedValueUSD);
    }

    /**
     * @notice Get reward multiplier for user's current tier
     * @param user Address of the user
     * @return multiplier Reward multiplier in basis points
     */
    function getUserRewardMultiplier(address user) external view returns (uint256 multiplier) {
        (uint8 tier,) = calculateUserTier(user);

        if (tier == 1) return tier1Multiplier;
        if (tier == 2) return tier2Multiplier;
        if (tier == 3) return tier3Multiplier;
        if (tier == 4) return tier4Multiplier;

        return tier1Multiplier;
    }

    /**
     * @notice Calculate bonus rewards for a user based on their tier
     * @param user Address of the user
     * @param baseReward Base reward amount
     * @return bonusReward Total reward including tier bonus
     */
    function calculateBonusReward(address user, uint256 baseReward) external view returns (uint256 bonusReward) {
        (uint8 tier,) = calculateUserTier(user);
        uint256 multiplier;

        if (tier == 1) multiplier = tier1Multiplier;
        else if (tier == 2) multiplier = tier2Multiplier;
        else if (tier == 3) multiplier = tier3Multiplier;
        else if (tier == 4) multiplier = tier4Multiplier;
        else multiplier = tier1Multiplier;

        return (baseReward * multiplier) / 10000;
    }

    // --- Internal Functions ---

    /**
     * @notice Calculate USD value of user's staked PERIDOT positions
     * @param user Address of the user
     * @return stakedValueUSD USD value of staked PERIDOT
     */
    function _getStakedPeridotValue(address user) internal view returns (uint256 stakedValueUSD) {
        uint256 totalStakedXP = 0;

        if (countOnlyLockedPositions) {
            // Count only locked positions
            uint256 positionCount = stakingContract.getUserPositionCount(user);
            for (uint256 i = 0; i < positionCount; i++) {
                xPStaking.Position memory position = stakingContract.getPosition(user, i);
                if (position.amountXP > 0 && block.timestamp < position.endTime) {
                    totalStakedXP += position.amountXP;
                }
            }
        } else {
            // Count all staked positions (locked and unlocked)
            totalStakedXP = stakingContract.getUserTotalStaked(user);
        }

        if (totalStakedXP == 0) {
            return 0;
        }

        // Convert staked xP to PERIDOT: stakedP = xPStaked * exchangeRatePPerX
        uint256 exchangeRatePPerX = vault.exchangeRate();
        uint256 stakedPeridotAmount = (totalStakedXP * exchangeRatePPerX) / 1e18;

        // Convert to USD: stakedP * peridotPriceUSD
        stakedValueUSD = (stakedPeridotAmount * peridotPriceUSD) / 1e18;

        return stakedValueUSD;
    }

    /**
     * @notice Calculate USD value of user's supplied assets (excluding PERIDOT)
     * @param user Address of the user
     * @return suppliedValueUSD USD value of supplied assets
     */
    function _getSuppliedPortfolioValue(address user) internal view returns (uint256 suppliedValueUSD) {
        PToken[] memory markets = peridottroller.getAllMarkets();

        for (uint256 i = 0; i < markets.length; i++) {
            PToken market = markets[i];

            // Skip PERIDOT token market (if it exists)
            // Check if this is a PErc20 token with underlying
            try PErc20Interface(address(market)).underlying() returns (address underlying) {
                if (underlying == address(peridotToken)) {
                    continue; // Skip PERIDOT market
                }
            } catch {
                // If call fails, continue (might be native token market like pETH)
            }

            (uint256 err, uint256 pTokenBalance,,) = market.getAccountSnapshot(user);

            if (err == 0 && pTokenBalance > 0) {
                uint256 underlyingPrice = oracle.getUnderlyingPrice(market);
                uint256 exchangeRate = market.exchangeRateStored();

                if (underlyingPrice > 0 && exchangeRate > 0) {
                    // Calculate USD value: pTokenBalance * exchangeRate * underlyingPrice / 1e36
                    uint256 assetValue = (pTokenBalance * exchangeRate * underlyingPrice) / 1e36;
                    suppliedValueUSD += assetValue;
                }
            }
        }

        return suppliedValueUSD;
    }

    // --- View Functions ---

    /**
     * @notice Get detailed user information for tier calculation
     * @param user Address of the user
     * @return tier Current tier (1-4)
     * @return tierPercentBps Tier percentage in basis points
     * @return stakedPeridotValueUSD USD value of staked PERIDOT
     * @return suppliedValueUSD USD value of supplied assets
     * @return totalStakedXP Total staked xPERIDOT amount
     * @return exchangeRate Current vault exchange rate
     */
    function getUserTierInfo(address user)
        external
        view
        returns (
            uint8 tier,
            uint256 tierPercentBps,
            uint256 stakedPeridotValueUSD,
            uint256 suppliedValueUSD,
            uint256 totalStakedXP,
            uint256 exchangeRate
        )
    {
        (tier, tierPercentBps) = calculateUserTier(user);
        (stakedPeridotValueUSD, suppliedValueUSD) = getUserValues(user);

        if (countOnlyLockedPositions) {
            // Calculate only locked positions
            uint256 positionCount = stakingContract.getUserPositionCount(user);
            for (uint256 i = 0; i < positionCount; i++) {
                xPStaking.Position memory position = stakingContract.getPosition(user, i);
                if (position.amountXP > 0 && block.timestamp < position.endTime) {
                    totalStakedXP += position.amountXP;
                }
            }
        } else {
            totalStakedXP = stakingContract.getUserTotalStaked(user);
        }

        exchangeRate = vault.exchangeRate();
    }

    /**
     * @notice Get tier thresholds and multipliers
     * @return thresholds Array of tier thresholds in basis points
     * @return multipliers Array of tier multipliers in basis points
     */
    function getTierConfig() external view returns (uint256[] memory thresholds, uint256[] memory multipliers) {
        thresholds = new uint256[](3);
        thresholds[0] = TIER_1_THRESHOLD;
        thresholds[1] = TIER_2_THRESHOLD;
        thresholds[2] = TIER_3_THRESHOLD;

        multipliers = new uint256[](4);
        multipliers[0] = tier1Multiplier;
        multipliers[1] = tier2Multiplier;
        multipliers[2] = tier3Multiplier;
        multipliers[3] = tier4Multiplier;
    }
}

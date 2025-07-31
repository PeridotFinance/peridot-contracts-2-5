// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "./PToken.sol";
import "./PriceOracle.sol";
import "./Governance/Peridot.sol";
import "./PeridottrollerInterface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title PeridotTierRewards
 * @dev Tier-based reward system for Peridot Protocol users
 * Calculates user tiers based on Peridot token percentage in their portfolio
 * and provides bonus rewards accordingly
 */
contract PeridotTierRewards {
    
    /// @notice Peridot token contract
    Peridot public immutable peridotToken;
    
    /// @notice Peridottroller contract
    PeridottrollerInterface public immutable peridottroller;
    
    /// @notice Price oracle for USD valuations
    PriceOracle public immutable oracle;
    
    /// @notice Admin address for configuration
    address public admin;
    
    /// @notice Tier thresholds (in basis points, 10000 = 100%)
    uint256 public constant TIER_1_THRESHOLD = 100;     // 1%
    uint256 public constant TIER_2_THRESHOLD = 500;     // 5%
    uint256 public constant TIER_3_THRESHOLD = 1000;    // 10%
    
    /// @notice Reward multipliers for each tier (in basis points)
    uint256 public tier1Multiplier = 10000;  // 1.0x (no bonus)
    uint256 public tier2Multiplier = 11000;  // 1.1x
    uint256 public tier3Multiplier = 12500;  // 1.25x
    uint256 public tier4Multiplier = 15000;  // 1.5x
    
    /// @notice Additional protocol rewards mapping
    mapping(address => uint256) public protocolRewardMultipliers;
    mapping(address => mapping(address => uint256)) public userProtocolRewards;
    
    /// @notice Events
    event TierCalculated(address indexed user, uint8 tier, uint256 peridotPercentage);
    event RewardMultiplierUpdated(uint8 tier, uint256 newMultiplier);
    event ProtocolRewardAdded(address indexed protocol, uint256 multiplier);
    event RewardsClaimed(address indexed user, address indexed protocol, uint256 amount);
    
    /// @notice Custom errors
    error InvalidTier();
    error InvalidMultiplier();
    error Unauthorized();
    
    /**
     * @notice Constructor
     * @param _peridotToken Address of Peridot governance token
     * @param _peridottroller Address of Peridottroller contract
     * @param _oracle Address of price oracle
     */
    constructor(
        address _peridotToken,
        address _peridottroller,
        address _oracle
    ) {
        peridotToken = Peridot(_peridotToken);
        peridottroller = PeridottrollerInterface(_peridottroller);
        oracle = PriceOracle(_oracle);
        admin = msg.sender;
    }
    
    /**
     * @notice Calculate user's tier based on Peridot percentage in portfolio
     * @param user Address of the user
     * @return tier User's current tier (1-4)
     * @return peridotPercentage Percentage of Peridot in portfolio (basis points)
     */
    function calculateUserTier(address user) public view returns (uint8 tier, uint256 peridotPercentage) {
        (uint256 peridotValue, uint256 totalPortfolioValue) = getUserPortfolioValue(user);
        
        if (totalPortfolioValue == 0) {
            return (1, 0);
        }
        
        peridotPercentage = (peridotValue * 10000) / totalPortfolioValue;
        
        if (peridotPercentage >= TIER_3_THRESHOLD) {
            tier = 4;
        } else if (peridotPercentage >= TIER_2_THRESHOLD) {
            tier = 3;
        } else if (peridotPercentage >= TIER_1_THRESHOLD) {
            tier = 2;
        } else {
            tier = 1;
        }
        
        return (tier, peridotPercentage);
    }
    
    /**
     * @notice Get user's portfolio value including Peridot tokens
     * @param user Address of the user
     * @return peridotValue USD value of Peridot tokens
     * @return totalPortfolioValue Total USD value of all supplied assets
     */
    function getUserPortfolioValue(address user) public view returns (uint256 peridotValue, uint256 totalPortfolioValue) {
        // Get all markets from Peridottroller
        PToken[] memory markets = peridottroller.getAllMarkets();
        
        // Calculate Peridot token value
        uint256 peridotBalance = peridotToken.balanceOf(user);
        if (peridotBalance > 0) {
            // For Peridot token, we'll use a fixed price or oracle price
            // Since Peridot is the governance token, we'll use 1e18 as base
            peridotValue = peridotBalance; // Simplified for now
        }
        
        // Calculate total portfolio value from supplied pTokens
        for (uint256 i = 0; i < markets.length; i++) {
            PToken market = markets[i];
            (uint256 err, uint256 pTokenBalance, , ) = market.getAccountSnapshot(user);
            
            if (err == 0 && pTokenBalance > 0) {
                uint256 underlyingPrice = oracle.getUnderlyingPrice(market);
                uint256 exchangeRate = market.exchangeRateStored();
                
                // Calculate USD value: pTokenBalance * exchangeRate * underlyingPrice / 1e36
                uint256 assetValue = (pTokenBalance * exchangeRate * underlyingPrice) / 1e36;
                totalPortfolioValue += assetValue;
            }
        }
        
        return (peridotValue, totalPortfolioValue);
    }
    
    /**
     * @notice Get reward multiplier for user's tier
     * @param user Address of the user
     * @return multiplier Reward multiplier for the user's tier
     */
    function getUserRewardMultiplier(address user) public view returns (uint256 multiplier) {
        (uint8 tier, ) = calculateUserTier(user);
        
        if (tier == 1) return tier1Multiplier;
        if (tier == 2) return tier2Multiplier;
        if (tier == 3) return tier3Multiplier;
        if (tier == 4) return tier4Multiplier;
        
        return tier1Multiplier; // Default to tier 1
    }
    
    /**
     * @notice Calculate bonus rewards for a user
     * @param user Address of the user
     * @param baseReward Base reward amount
     * @return bonusReward Total reward including tier bonus
     */
    function calculateBonusReward(address user, uint256 baseReward) public view returns (uint256 bonusReward) {
        uint256 multiplier = getUserRewardMultiplier(user);
        return (baseReward * multiplier) / 10000;
    }
    
    /**
     * @notice Get additional protocol rewards for user
     * @param user Address of the user
     * @param protocol Address of the protocol
     * @return additionalRewards Additional rewards from the protocol
     */
    function getProtocolRewards(address user, address protocol) public view returns (uint256 additionalRewards) {
        uint256 multiplier = protocolRewardMultipliers[protocol];
        uint256 userBaseRewards = userProtocolRewards[protocol][user];
        
        if (multiplier > 0 && userBaseRewards > 0) {
            return (userBaseRewards * multiplier) / 10000;
        }
        
        return 0;
    }
    
    /**
     * @notice Update reward multipliers for tiers
     * @param tier Tier number (1-4)
     * @param newMultiplier New multiplier in basis points
     */
    function updateTierMultiplier(uint8 tier, uint256 newMultiplier) external onlyAdmin {
        if (tier < 1 || tier > 4) revert InvalidTier();
        if (newMultiplier < 10000) revert InvalidMultiplier(); // Minimum 1.0x
        
        if (tier == 1) tier1Multiplier = newMultiplier;
        else if (tier == 2) tier2Multiplier = newMultiplier;
        else if (tier == 3) tier3Multiplier = newMultiplier;
        else if (tier == 4) tier4Multiplier = newMultiplier;
        
        emit RewardMultiplierUpdated(tier, newMultiplier);
    }
    
    /**
     * @notice Add protocol reward multiplier
     * @param protocol Address of the protocol
     * @param multiplier Reward multiplier in basis points
     */
    function addProtocolReward(address protocol, uint256 multiplier) external onlyAdmin {
        protocolRewardMultipliers[protocol] = multiplier;
        emit ProtocolRewardAdded(protocol, multiplier);
    }
    
    /**
     * @notice Set user base rewards for protocol
     * @param user Address of the user
     * @param protocol Address of the protocol
     * @param amount Base reward amount
     */
    function setUserProtocolRewards(address user, address protocol, uint256 amount) external {
        // This could be called by authorized reward distributors
        userProtocolRewards[protocol][user] = amount;
    }
    
    /**
     * @notice Batch update user protocol rewards
     * @param users Array of user addresses
     * @param protocol Address of the protocol
     * @param amounts Array of reward amounts
     */
    function batchSetUserProtocolRewards(
        address[] calldata users,
        address protocol,
        uint256[] calldata amounts
    ) external {
        require(users.length == amounts.length, "Length mismatch");
        
        for (uint256 i = 0; i < users.length; i++) {
            userProtocolRewards[protocol][users[i]] = amounts[i];
        }
    }
    
    /**
     * @notice Transfer admin rights
     * @param newAdmin Address of new admin
     */
    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Invalid address");
        admin = newAdmin;
    }
    
    /**
     * @notice Emergency function to rescue stuck tokens
     * @param token Address of the token to rescue
     * @param to Address to send tokens to
     * @param amount Amount of tokens to rescue
     */
    function rescueTokens(address token, address to, uint256 amount) external onlyAdmin {
        require(to != address(0), "Invalid address");
        IERC20(token).transfer(to, amount);
    }
    
    /**
     * @notice Modifier for admin-only functions
     */
    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }
}

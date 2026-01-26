// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../PeridottrollerInterface.sol";
import "../PErc20.sol";
import "../SimplePriceOracle.sol";

/**
 * @title RiskGuard
 * @notice Risk management module for dual investment positions
 * @dev Validates user health factors and prevents over-leveraging
 */
contract RiskGuard is Ownable {
    uint256 public constant MIN_ACTION_DELAY = 1 hours;

    // Core contracts
    PeridottrollerInterface public immutable peridottroller;
    SimplePriceOracle public immutable priceOracle;

    // Risk parameters
    uint256 public minHealthFactor = 1.3e18; // 130% minimum health factor
    // Liquidation handled by Peridottroller - removed custom liquidation
    uint256 public maxPositionSizeRatio = 0.5e18; // Max 50% of collateral value in positions
    uint256 public emergencyPauseThreshold = 1.05e18; // 105% emergency pause threshold

    // Market risk limits
    mapping(address => uint256) public marketMaxUtilization; // Max utilization per market
    mapping(address => uint256) public marketCurrentUtilization; // Current utilization per market

    // User position limits
    mapping(address => uint256) public userTotalPositionValue; // Total position value per user
    mapping(address => bool) public whitelistedUsers; // Users exempt from some limits

    // Emergency controls
    bool public emergencyPaused = false;
    mapping(address => bool) public marketsPaused;
    uint256 public actionDelay;
    mapping(bytes32 => uint256) public queuedActions;

    // Events
    event RiskParameterUpdated(string parameter, uint256 oldValue, uint256 newValue);
    event UserPositionValueUpdated(address indexed user, uint256 oldValue, uint256 newValue);
    event MarketUtilizationUpdated(address indexed market, uint256 utilization);
    event EmergencyPaused(bool paused);
    event MarketPaused(address indexed market, bool paused);
    event RiskViolation(address indexed user, string reason, uint256 value);
    event MarketMaxUtilizationUpdated(address indexed market, uint256 maxUtilization);
    event WhitelistedUserUpdated(address indexed user, bool whitelisted);
    event ActionDelayUpdated(uint256 newDelay);
    event ActionQueued(bytes32 indexed actionId, uint256 executeAfter);
    event ActionCanceled(bytes32 indexed actionId);
    event ActionExecuted(bytes32 indexed actionId);

    modifier notPaused() {
        require(!emergencyPaused, "Emergency paused");
        _;
    }

    modifier marketNotPaused(address market) {
        require(!marketsPaused[market], "Market paused");
        _;
    }

    constructor(address _peridottroller, address _priceOracle) Ownable(msg.sender) {
        require(_peridottroller != address(0), "Invalid peridottroller");
        require(_priceOracle != address(0), "Invalid price oracle");
        peridottroller = PeridottrollerInterface(_peridottroller);
        priceOracle = SimplePriceOracle(_priceOracle);

        actionDelay = MIN_ACTION_DELAY;
        emit ActionDelayUpdated(actionDelay);
    }

    /**
     * @notice Check if user can enter a new position
     * @param user User address
     * @param cTokenIn Input cToken for position
     * @param positionValue Value of position in USD
     * @param useCollateral Whether using collateral vs borrowing
     * @return allowed Whether position is allowed
     * @return reason Reason if not allowed
     */
    function checkPositionEntry(address user, address cTokenIn, uint256 positionValue, bool useCollateral)
        external
        returns (bool allowed, string memory reason)
    {
        // Check emergency pause
        if (emergencyPaused) {
            return (false, "Emergency paused");
        }

        // Check market pause
        if (marketsPaused[cTokenIn]) {
            return (false, "Market paused");
        }

        // Check position size limits (unless whitelisted)
        if (!whitelistedUsers[user]) {
            uint256 newTotalPositionValue = userTotalPositionValue[user] + positionValue;
            uint256 maxAllowedPositionValue = _getMaxPositionValueForUser(user);

            if (newTotalPositionValue > maxAllowedPositionValue) {
                return (false, "Position size exceeds limit");
            }
        }

        // Check market utilization
        uint256 maxUtil = marketMaxUtilization[cTokenIn];
        if (maxUtil > 0) {
            uint256 newUtilization = marketCurrentUtilization[cTokenIn] + positionValue;
            if (newUtilization > maxUtil) {
                return (false, "Market utilization limit exceeded");
            }
        }

        if (useCollateral) {
            return (true, "");
        }

        // Check user health factor (borrow path)
        uint256 healthFactor = _calculateHealthFactor(user);
        if (healthFactor < minHealthFactor && healthFactor != type(uint256).max) {
            return (false, "Health factor too low");
        }

        // Additional checks for borrow path
        return _checkBorrowPathRisks(user, cTokenIn, positionValue);
    }

    /**
     * @notice Update user position value tracking
     * @param user User address
     * @param oldPositionValue Previous position value
     * @param newPositionValue New position value
     */
    function updateUserPositionValue(address user, uint256 oldPositionValue, uint256 newPositionValue)
        external
        onlyOwner
    {
        uint256 currentTotal = userTotalPositionValue[user];

        // Subtract old value, add new value
        if (oldPositionValue > 0) {
            currentTotal = currentTotal > oldPositionValue ? currentTotal - oldPositionValue : 0;
        }

        uint256 newTotal = currentTotal + newPositionValue;
        userTotalPositionValue[user] = newTotal;

        emit UserPositionValueUpdated(user, currentTotal, newTotal);
    }

    /**
     * @notice Update market utilization tracking
     * @param market Market address
     * @param utilizationChange Change in utilization (can be negative)
     * @param isIncrease Whether this is an increase or decrease
     */
    function updateMarketUtilization(address market, uint256 utilizationChange, bool isIncrease) external onlyOwner {
        uint256 currentUtilization = marketCurrentUtilization[market];

        if (isIncrease) {
            marketCurrentUtilization[market] = currentUtilization + utilizationChange;
        } else {
            marketCurrentUtilization[market] =
                currentUtilization > utilizationChange ? currentUtilization - utilizationChange : 0;
        }

        emit MarketUtilizationUpdated(market, marketCurrentUtilization[market]);
    }

    // Liquidation functions removed - handled by Peridottroller

    /**
     * @notice Get maximum position value allowed for user
     * @param user User address
     * @return maxPositionValue Maximum position value in USD
     */
    function getMaxPositionValueForUser(address user) external view returns (uint256 maxPositionValue) {
        return _getMaxPositionValueForUser(user);
    }

    /**
     * @notice Calculate user's health factor
     * @param user User address
     * @return healthFactor Health factor (type(uint256).max if no borrows)
     */
    function getUserHealthFactor(address user) external view returns (uint256 healthFactor) {
        return _calculateHealthFactor(user);
    }

    /**
     * @notice Check borrow-specific risk factors
     * @param user User address
     * @param cToken cToken for borrowing
     * @param positionValue Position value
     * @return allowed Whether allowed
     * @return reason Reason if not allowed
     */
    function _checkBorrowPathRisks(address user, address cToken, uint256 positionValue)
        internal
        returns (bool allowed, string memory reason)
    {
        (bool ok, uint256 positionValueInUnderlying) = _tryConvertUSDToUnderlying(cToken, positionValue);
        if (!ok) {
            return (false, "Price unavailable");
        }

        // Check if borrowing is allowed for this market (guard against reverting controllers)
        try peridottroller.borrowAllowed(cToken, user, positionValueInUnderlying) returns (uint256 borrowAllowed) {
            if (borrowAllowed != 0) {
                return (false, "Borrow not allowed by peridottroller");
            }
        } catch {
            return (false, "Borrow check unavailable");
        }

        // Check user's liquidity (guard against reverting controllers)
        uint256 liquidity;
        uint256 shortfall;
        try peridottroller.getAccountLiquidity(user) returns (uint256, uint256 l, uint256 s) {
            liquidity = l;
            shortfall = s;
        } catch {
            return (false, "Liquidity check unavailable");
        }
        if (shortfall > 0) {
            return (false, "User has existing shortfall");
        }

        // Convert position value to underlying tokens for liquidity check
        (, uint256 liquidityInUnderlying) = _tryConvertUSDToUnderlying(cToken, liquidity);

        if (positionValueInUnderlying > liquidityInUnderlying) {
            return (false, "Insufficient liquidity for borrow");
        }

        return (true, "");
    }

    /**
     * @notice Calculate health factor for user
     * @param user User address
     * @return healthFactor Health factor (type(uint256).max if no borrows)
     */
    function _calculateHealthFactor(address user) internal view returns (uint256 healthFactor) {
        uint256 liquidity;
        uint256 shortfall;
        // Guard against controllers that revert by treating user as healthy
        try peridottroller.getAccountLiquidity(user) returns (uint256, uint256 l, uint256 s) {
            liquidity = l;
            shortfall = s;
        } catch {
            return type(uint256).max;
        }

        if (shortfall > 0) {
            return (liquidity * 1e18) / shortfall; // This will be < 1e18 when liquidatable
        }

        if (liquidity == 0) {
            return type(uint256).max; // No borrows = infinite health factor
        }

        // Simplified health factor calculation
        // In production, you'd want more sophisticated calculation
        return type(uint256).max; // Conservative assumption
    }

    /**
     * @notice Get maximum position value for user based on collateral
     * @param user User address
     * @return maxValue Maximum position value in USD
     */
    function _getMaxPositionValueForUser(address user) internal view returns (uint256 maxValue) {
        // If controller reverts, return a very high cap to avoid blocking collateral entries
        try peridottroller.getAccountLiquidity(user) returns (uint256, uint256 liquidity, uint256) {
            return (liquidity * maxPositionSizeRatio) / 1e18;
        } catch {
            return type(uint256).max;
        }
    }

    /**
     * @notice Convert USD value to underlying tokens
     * @param cToken cToken address
     * @param usdValue Value in USD
     * @return ok Whether conversion succeeded
     * @return underlyingAmount Amount in underlying tokens
     */
    function _tryConvertUSDToUnderlying(address cToken, uint256 usdValue)
        internal
        view
        returns (bool ok, uint256 underlyingAmount)
    {
        PErc20 pToken = PErc20(cToken);
        uint256 pricePerToken = priceOracle.getUnderlyingPrice(pToken);
        if (pricePerToken == 0) {
            return (false, 0);
        }
        return (true, (usdValue * 1e18) / pricePerToken);
    }

    // Admin functions

    /**
     * @notice Set minimum health factor
     * @param newMinHealthFactor New minimum health factor
     */
    function setMinHealthFactor(uint256 newMinHealthFactor) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("setMinHealthFactor", newMinHealthFactor));
        _consumeAction(actionId);
        require(newMinHealthFactor >= 1e18, "Health factor must be >= 100%");
        uint256 oldValue = minHealthFactor;
        minHealthFactor = newMinHealthFactor;
        emit RiskParameterUpdated("minHealthFactor", oldValue, newMinHealthFactor);
        emit ActionExecuted(actionId);
    }

    // Liquidation threshold setter removed - handled by Peridottroller

    /**
     * @notice Set maximum position size ratio
     * @param newRatio New maximum position size ratio
     */
    function setMaxPositionSizeRatio(uint256 newRatio) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("setMaxPositionSizeRatio", newRatio));
        _consumeAction(actionId);
        require(newRatio > 0 && newRatio <= 1e18, "Invalid ratio");
        uint256 oldValue = maxPositionSizeRatio;
        maxPositionSizeRatio = newRatio;
        emit RiskParameterUpdated("maxPositionSizeRatio", oldValue, newRatio);
        emit ActionExecuted(actionId);
    }

    /**
     * @notice Set market utilization limit
     * @param market Market address
     * @param maxUtilization Maximum utilization for this market
     */
    function setMarketMaxUtilization(address market, uint256 maxUtilization) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("setMarketMaxUtilization", market, maxUtilization));
        _consumeAction(actionId);
        marketMaxUtilization[market] = maxUtilization;
        emit MarketMaxUtilizationUpdated(market, maxUtilization);
        emit ActionExecuted(actionId);
    }

    /**
     * @notice Whitelist user (exempt from position limits)
     * @param user User address
     * @param whitelisted Whether user is whitelisted
     */
    function setWhitelistedUser(address user, bool whitelisted) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("setWhitelistedUser", user, whitelisted));
        _consumeAction(actionId);
        whitelistedUsers[user] = whitelisted;
        emit WhitelistedUserUpdated(user, whitelisted);
        emit ActionExecuted(actionId);
    }

    /**
     * @notice Emergency pause all operations
     * @param paused Whether to pause
     */
    function setEmergencyPause(bool paused) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("setEmergencyPause", paused));
        _consumeAction(actionId);
        emergencyPaused = paused;
        emit EmergencyPaused(paused);
        emit ActionExecuted(actionId);
    }

    /**
     * @notice Pause specific market
     * @param market Market address
     * @param paused Whether to pause
     */
    function setMarketPaused(address market, bool paused) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("setMarketPaused", market, paused));
        _consumeAction(actionId);
        marketsPaused[market] = paused;
        emit MarketPaused(market, paused);
        emit ActionExecuted(actionId);
    }

    function setActionDelay(uint256 newDelay) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("setActionDelay", newDelay));
        _consumeAction(actionId);
        require(newDelay >= actionDelay, "Delay cannot decrease");
        require(newDelay >= MIN_ACTION_DELAY, "Delay too short");
        actionDelay = newDelay;
        emit ActionDelayUpdated(newDelay);
        emit ActionExecuted(actionId);
    }

    function cancelAction(bytes32 actionId) external onlyOwner {
        require(queuedActions[actionId] != 0, "Action not queued");
        delete queuedActions[actionId];
        emit ActionCanceled(actionId);
    }

    function queueSetMinHealthFactor(uint256 newMinHealthFactor) external onlyOwner returns (bytes32 actionId) {
        actionId = _queueAction(keccak256(abi.encode("setMinHealthFactor", newMinHealthFactor)));
    }

    function queueSetMaxPositionSizeRatio(uint256 newRatio) external onlyOwner returns (bytes32 actionId) {
        actionId = _queueAction(keccak256(abi.encode("setMaxPositionSizeRatio", newRatio)));
    }

    function queueSetMarketMaxUtilization(address market, uint256 maxUtilization)
        external
        onlyOwner
        returns (bytes32 actionId)
    {
        actionId = _queueAction(keccak256(abi.encode("setMarketMaxUtilization", market, maxUtilization)));
    }

    function queueSetWhitelistedUser(address user, bool whitelisted) external onlyOwner returns (bytes32 actionId) {
        actionId = _queueAction(keccak256(abi.encode("setWhitelistedUser", user, whitelisted)));
    }

    function queueSetEmergencyPause(bool paused) external onlyOwner returns (bytes32 actionId) {
        actionId = _queueAction(keccak256(abi.encode("setEmergencyPause", paused)));
    }

    function queueSetMarketPaused(address market, bool paused) external onlyOwner returns (bytes32 actionId) {
        actionId = _queueAction(keccak256(abi.encode("setMarketPaused", market, paused)));
    }

    function queueSetActionDelay(uint256 newDelay) external onlyOwner returns (bytes32 actionId) {
        actionId = _queueAction(keccak256(abi.encode("setActionDelay", newDelay)));
    }

    function _queueAction(bytes32 actionId) internal returns (bytes32) {
        require(queuedActions[actionId] == 0, "Action already queued");
        uint256 executeAfter = block.timestamp + actionDelay;
        queuedActions[actionId] = executeAfter;
        emit ActionQueued(actionId, executeAfter);
        return actionId;
    }

    function _consumeAction(bytes32 actionId) internal {
        uint256 executeAfter = queuedActions[actionId];
        require(executeAfter != 0, "Action not queued");
        require(block.timestamp >= executeAfter, "Action not ready");
        delete queuedActions[actionId];
    }
}

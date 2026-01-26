// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./ERC1155DualPosition.sol";
import "./VaultExecutor.sol";
import "../SimplePriceOracle.sol";
import "../PErc20.sol";

/**
 * @title SettlementEngine
 * @notice Handles settlement of dual investment positions using oracle prices
 * @dev Pulls price at/near expiry and settles positions accordingly
 */
contract SettlementEngine is Ownable, ReentrancyGuard {
    uint256 public constant MIN_ACTION_DELAY = 1 hours;

    // Core contracts
    ERC1155DualPosition public immutable positionToken;
    VaultExecutor public immutable vaultExecutor;
    SimplePriceOracle public immutable priceOracle;

    // Settlement configuration
    uint256 public settlementWindow = 1 hours; // Grace period after expiry for settlement
    uint256 public maxSettlementSlippageBps = 200; // 2% max slippage on swaps
    uint256 public actionDelay;
    mapping(bytes32 => uint256) public queuedActions;
    mapping(uint256 => bool) public isSettled; // Track settled positions
    mapping(uint256 => uint256) public settlementPrices; // Store settlement prices

    // Events
    event PositionSettled(
        uint256 indexed tokenId,
        address indexed user,
        uint256 settlementPrice,
        uint256 strikePrice,
        bool aboveStrike,
        address winningAsset,
        uint256 payout
    );

    event SettlementWindowUpdated(uint256 oldWindow, uint256 newWindow);
    event MaxSettlementSlippageUpdated(uint256 oldBps, uint256 newBps);
    event ActionDelayUpdated(uint256 newDelay);
    event ActionQueued(bytes32 indexed actionId, uint256 executeAfter);
    event ActionCanceled(bytes32 indexed actionId);
    event ActionExecuted(bytes32 indexed actionId);

    event SettlementPriceSet(uint256 indexed tokenId, uint256 price);

    constructor(address _positionToken, address _vaultExecutor, address _priceOracle) Ownable(msg.sender) {
        require(_positionToken != address(0), "Invalid position token");
        require(_vaultExecutor != address(0), "Invalid vault executor");
        require(_priceOracle != address(0), "Invalid price oracle");

        positionToken = ERC1155DualPosition(_positionToken);
        vaultExecutor = VaultExecutor(_vaultExecutor);
        priceOracle = SimplePriceOracle(_priceOracle);

        actionDelay = MIN_ACTION_DELAY;
        emit ActionDelayUpdated(actionDelay);
    }

    /**
     * @notice Settle a dual investment position
     * @param tokenId Token ID to settle
     * @param user User address holding the position
     */
    function settlePosition(uint256 tokenId, address user) external nonReentrant {
        _settlePositionInternal(tokenId, user);
    }

    // Internal settle logic used by both single and batch settlement
    function _settlePositionInternal(uint256 tokenId, address user) internal {
        require(!isSettled[tokenId], "Position already settled");

        ERC1155DualPosition.Position memory position = positionToken.getPosition(tokenId);
        require(position.user != address(0), "Position does not exist");
        require(block.timestamp >= position.expiry, "Position not yet expired");
        require(block.timestamp <= position.expiry + settlementWindow, "Settlement window closed");

        uint256 userBalance = positionToken.balanceOf(user, tokenId);
        require(userBalance > 0, "User has no position balance");

        uint256 settlementPrice = _getSettlementPrice(position.cTokenIn, tokenId);

        (address winningCToken, uint256 payoutAmount) = _calculatePayout(position, settlementPrice, userBalance);

        if (payoutAmount > 0) {
            _executePayout(position, winningCToken, user, payoutAmount);
        }

        isSettled[tokenId] = true;
        settlementPrices[tokenId] = settlementPrice;
        positionToken.burnPosition(user, tokenId, userBalance);

        emit PositionSettled(
            tokenId,
            user,
            settlementPrice,
            position.strike,
            settlementPrice >= position.strike,
            winningCToken,
            payoutAmount
        );
    }

    // Helper callable only by this contract to enable try/catch in batch without reentrancy conflicts
    function __settleInternalExternal(uint256 tokenId, address user) external {
        require(msg.sender == address(this), "only self");
        _settlePositionInternal(tokenId, user);
    }

    /**
     * @notice Batch settle multiple positions for gas efficiency
     * @param tokenIds Array of token IDs to settle
     * @param users Array of user addresses (must match tokenIds length)
     */
    function batchSettlePositions(uint256[] calldata tokenIds, address[] calldata users) external nonReentrant {
        require(tokenIds.length == users.length, "Array length mismatch");
        require(tokenIds.length > 0, "Empty arrays");

        for (uint256 i = 0; i < tokenIds.length; i++) {
            // Use try-catch via self-call to non-guarded helper to continue on failures
            try this.__settleInternalExternal(tokenIds[i], users[i]) {
            // Settlement succeeded
            }
            catch {
                // Settlement failed, continue with next position
                continue;
            }
        }
    }

    /**
     * @notice Get settlement price for a position's underlying asset
     * @param cToken cToken address to get underlying price for
     * @param tokenId Token ID (for potential future price caching)
     * @return price Settlement price in 18 decimals
     */
    function _getSettlementPrice(address cToken, uint256 tokenId) internal returns (uint256 price) {
        // Check if we already cached the settlement price
        if (settlementPrices[tokenId] != 0) {
            return settlementPrices[tokenId];
        }

        // Get price from oracle
        price = priceOracle.getUnderlyingPrice(PToken(cToken));
        require(price > 0, "Invalid settlement price");

        // Cache the price
        settlementPrices[tokenId] = price;
        emit SettlementPriceSet(tokenId, price);

        return price;
    }

    /**
     * @notice Calculate payout for a position based on settlement price
     * @param position Position struct
     * @param settlementPrice Current settlement price
     * @param balance User's position balance
     * @return winningCToken Address of the winning cToken
     * @return payoutAmount Amount to pay out
     */
    function _calculatePayout(ERC1155DualPosition.Position memory position, uint256 settlementPrice, uint256 balance)
        internal
        pure
        returns (address winningCToken, uint256 payoutAmount)
    {
        bool aboveStrike = settlementPrice >= position.strike;

        if (position.direction == 0) {
            // DIRECTION_CALL
            // CALL position: wins if price >= strike
            if (aboveStrike) {
                winningCToken = position.cTokenOut; // Receive quote asset
                payoutAmount = balance; // 1:1 notional payout
            } else {
                winningCToken = position.cTokenIn; // Receive base asset back
                payoutAmount = balance;
            }
        } else {
            // PUT position: wins if price < strike
            if (!aboveStrike) {
                winningCToken = position.cTokenOut; // Receive quote asset
                payoutAmount = balance; // 1:1 notional payout
            } else {
                winningCToken = position.cTokenIn; // Receive base asset back
                payoutAmount = balance;
            }
        }
    }

    /**
     * @notice Execute payout to user
     * @param position Original position struct (to access cTokenIn)
     * @param payoutCToken Winning cToken to pay out in
     * @param user Recipient of payout
     * @param cTokenAmount Amount of payout denominated in payout cToken units
     */
    function _executePayout(
        ERC1155DualPosition.Position memory position,
        address payoutCToken,
        address user,
        uint256 cTokenAmount
    ) internal {
        uint256 minPayoutCTokens = (cTokenAmount * (10000 - maxSettlementSlippageBps)) / 10000;

        // Compute underlying needed for payout in payoutCToken units
        uint256 exchangeRateOut;
        try PErc20(payoutCToken).exchangeRateCurrent() returns (uint256 rate) {
            exchangeRateOut = rate;
        } catch {
            exchangeRateOut = PErc20(payoutCToken).exchangeRateStored();
        }
        uint256 underlyingOutRequested = (cTokenAmount * exchangeRateOut) / 1e18;

        // First attempt: withdraw directly from payout market if the vault holds it
        uint256 withdrawnOut = vaultExecutor.withdrawUnderlyingFromProtocol(payoutCToken, underlyingOutRequested);
        if (withdrawnOut > 0) {
            uint256 mintedOut = vaultExecutor.mintCTokensTo(payoutCToken, user, withdrawnOut);
            require(mintedOut >= minPayoutCTokens, "Insufficient payout");
            return;
        }

        // Fallback: withdraw from the position's input market and swap to payout underlying, then mint payoutCToken
        address sourceCToken = position.cTokenIn;

        // Determine how much payout underlying is needed for the target cTokenAmount
        // U_out_needed = cTokenAmount * exchangeRateOut / 1e18
        uint256 underlyingOutNeeded = (cTokenAmount * exchangeRateOut) / 1e18;

        // Convert desired payout underlying into required source underlying using oracle prices
        uint256 priceIn = priceOracle.getUnderlyingPrice(PToken(sourceCToken));
        uint256 priceOut = priceOracle.getUnderlyingPrice(PToken(payoutCToken));
        require(priceIn > 0 && priceOut > 0, "Invalid oracle price");

        // requiredIn = ceil(underlyingOutNeeded * priceOut / priceIn)
        uint256 requiredIn = (underlyingOutNeeded * priceOut + priceIn - 1) / priceIn;
        // Add small buffer (1%) to account for swap slippage without overcomplicating
        requiredIn = (requiredIn * 1001) / 1000;

        // Withdraw as much as required (vault clamps to available)
        uint256 withdrawnIn = vaultExecutor.withdrawUnderlyingFromProtocol(sourceCToken, requiredIn);

        if (withdrawnIn > 0) {
            uint256 minUnderlyingOut =
                _computeMinUnderlyingOut(sourceCToken, payoutCToken, withdrawnIn, maxSettlementSlippageBps);
            uint256 mintedOut =
                vaultExecutor.swapAndMintTo(sourceCToken, payoutCToken, user, withdrawnIn, minUnderlyingOut);
            require(mintedOut >= minPayoutCTokens, "Insufficient payout");
            return;
        }

        revert("Payout unavailable");
    }

    function _computeMinUnderlyingOut(
        address cTokenIn,
        address cTokenOut,
        uint256 underlyingInAmount,
        uint256 slippageBps
    ) internal returns (uint256 minUnderlyingOut) {
        uint256 priceIn = priceOracle.getUnderlyingPrice(PToken(cTokenIn));
        uint256 priceOut = priceOracle.getUnderlyingPrice(PToken(cTokenOut));
        require(priceIn > 0 && priceOut > 0, "Invalid price");

        uint256 valueUsd = (underlyingInAmount * priceIn) / 1e18;
        uint256 expectedOut = (valueUsd * 1e18) / priceOut;
        minUnderlyingOut = (expectedOut * (10000 - slippageBps)) / 10000;
    }

    /**
     * @notice Check if a position can be settled
     * @param tokenId Token ID to check
     * @return canSettle True if position can be settled
     * @return reason Reason if cannot settle
     */
    function canSettlePosition(uint256 tokenId) external view returns (bool canSettle, string memory reason) {
        if (isSettled[tokenId]) {
            return (false, "Already settled");
        }

        ERC1155DualPosition.Position memory position = positionToken.getPosition(tokenId);
        if (position.user == address(0)) {
            return (false, "Position does not exist");
        }

        if (block.timestamp < position.expiry) {
            return (false, "Not yet expired");
        }

        if (block.timestamp > position.expiry + settlementWindow) {
            return (false, "Settlement window closed");
        }

        return (true, "");
    }

    /**
     * @notice Get settlement information for a position
     * @param tokenId Token ID to query
     * @return settled Whether position is settled
     * @return settlementPrice Price used for settlement (0 if not settled)
     * @return canSettle Whether position can currently be settled
     */
    function getSettlementInfo(uint256 tokenId)
        external
        view
        returns (bool settled, uint256 settlementPrice, bool canSettle)
    {
        settled = isSettled[tokenId];
        settlementPrice = settlementPrices[tokenId];
        (canSettle,) = this.canSettlePosition(tokenId);
    }

    /**
     * @notice Set settlement window
     * @param newWindow New settlement window in seconds
     */
    function setSettlementWindow(uint256 newWindow) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("setSettlementWindow", newWindow));
        _consumeAction(actionId);
        require(newWindow > 0, "Invalid settlement window");
        uint256 oldWindow = settlementWindow;
        settlementWindow = newWindow;
        emit SettlementWindowUpdated(oldWindow, newWindow);
        emit ActionExecuted(actionId);
    }

    /**
     * @notice Manual price override for emergency situations
     * @param tokenId Token ID to set price for
     * @param price Price to set
     */
    function emergencySetSettlementPrice(uint256 tokenId, uint256 price) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("emergencySetSettlementPrice", tokenId, price));
        _consumeAction(actionId);
        require(price > 0, "Invalid price");
        require(!isSettled[tokenId], "Position already settled");

        settlementPrices[tokenId] = price;
        emit SettlementPriceSet(tokenId, price);
        emit ActionExecuted(actionId);
    }

    function setMaxSettlementSlippageBps(uint256 newBps) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("setMaxSettlementSlippageBps", newBps));
        _consumeAction(actionId);
        require(newBps <= 2000, "Slippage too high"); // Max 20%
        uint256 oldBps = maxSettlementSlippageBps;
        maxSettlementSlippageBps = newBps;
        emit MaxSettlementSlippageUpdated(oldBps, newBps);
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

    function queueSetSettlementWindow(uint256 newWindow) external onlyOwner returns (bytes32 actionId) {
        actionId = _queueAction(keccak256(abi.encode("setSettlementWindow", newWindow)));
    }

    function queueEmergencySetSettlementPrice(uint256 tokenId, uint256 price)
        external
        onlyOwner
        returns (bytes32 actionId)
    {
        actionId = _queueAction(keccak256(abi.encode("emergencySetSettlementPrice", tokenId, price)));
    }

    function queueSetMaxSettlementSlippageBps(uint256 newBps) external onlyOwner returns (bytes32 actionId) {
        actionId = _queueAction(keccak256(abi.encode("setMaxSettlementSlippageBps", newBps)));
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

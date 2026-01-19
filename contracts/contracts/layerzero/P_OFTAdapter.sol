// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OFTAdapter} from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";

/*
 * @title P_OFTAdapter
 * @notice OFT Adapter for pre-minted $P token using lock/unlock pattern
 * @dev This contract extends LayerZero V2 OFTAdapter with custom rate limiting
 *
 * IMPORTANT: This includes OPTIONAL rate limiting features not in the base OFTAdapter.
 * Rate limiting is an extension pattern for additional security.
 *
 * IMPLEMENTATION NOTES:
 * 1. Install LayerZero packages first:
 *    npm install @layerzerolabs/lz-evm-oapp-v2
 *
 * 2. Import the base OFTAdapter:
 *    import {OFTAdapter} from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
 *
 * 3. Inherit from OFTAdapter instead of this placeholder
 *
 * 4. Key functions to implement/override:
 *    - constructor(address _token, address _lzEndpoint, address _owner)
 *    - _debit() - called when sending tokens cross-chain (add rate limits)
 *    - _credit() - called when receiving tokens (add rate limits)
 *    - setPeer() - configure trusted remote adapters
 *
 * ARCHITECTURE:
 * - Lock/unlock model: tokens are escrowed in this contract
 * - No mint/burn: preserves existing $P token contract
 * - Inventory-based: requires seeding with $P tokens
 * - Rate limiting: prevents rapid drainage
 * - Pausable: emergency stop mechanism
 *
 * SECURITY:
 * - Only accepts messages from configured peers (via LayerZero)
 * - Rate limits per destination chain
 * - Emergency pause functionality
 * - Owner-controlled configuration
 */
contract P_OFTAdapter is OFTAdapter {
    using SafeERC20 for IERC20;

    // Rate limiting per destination chain (EID)
    struct RateLimit {
        uint256 capacity; // Maximum tokens per window
        uint256 refillRate; // Tokens refilled per second
        uint256 tokens; // Current available tokens
        uint256 lastRefill; // Last refill timestamp
    }

    mapping(uint32 => RateLimit) public outboundLimits;
    mapping(uint32 => RateLimit) public inboundLimits;

    // Emergency controls
    bool public paused;

    // Maximum refill rate to prevent overflow in rate limit calculations
    uint256 public constant MAX_REFILL_RATE = 1e50;

    // Events (PeerSet is inherited from OFTAdapter)
    event RateLimitSet(
        uint32 indexed eid,
        bool isOutbound,
        uint256 capacity,
        uint256 refillRate
    );
    event Paused(bool paused);
    event TokensLocked(
        address indexed from,
        uint32 indexed dstEid,
        uint256 amount
    );
    event TokensUnlocked(
        address indexed to,
        uint32 indexed srcEid,
        uint256 amount
    );
    event EmergencyWithdraw(address indexed to, uint256 amount);

    // Errors
    error AdapterPaused();
    error RateLimitExceeded();
    error InsufficientInventory(uint256 available, uint256 required);
    error InvalidPeer();
    error ZeroAddress();
    error EmergencyWithdrawRequiresPause();
    error RefillRateTooHigh();

    /**
     * @notice Constructor
     * @param _token Address of the $P token to bridge
     * @param _lzEndpoint LayerZero Endpoint V2 address for this chain
     * @param _owner Admin address
     */
    constructor(
        address _token,
        address _lzEndpoint,
        address _owner
    ) OFTAdapter(_token, _lzEndpoint, _owner) Ownable(_owner) {
        // OFTAdapter handles token and endpoint storage
        // Additional initialization if needed
    }

    // setPeer() is inherited from OFTAdapter - no need to override

    /**
     * @notice Set rate limit for a destination chain
     * @param _eid Chain endpoint ID
     * @param _isOutbound True for outbound, false for inbound
     * @param _capacity Maximum tokens per window
     * @param _refillRate Tokens refilled per second (bounded by MAX_REFILL_RATE)
     */
    function setRateLimit(
        uint32 _eid,
        bool _isOutbound,
        uint256 _capacity,
        uint256 _refillRate
    ) external onlyOwner {
        // Prevent overflow in elapsed * refillRate calculation
        if (_refillRate > MAX_REFILL_RATE) revert RefillRateTooHigh();

        RateLimit storage limit = _isOutbound
            ? outboundLimits[_eid]
            : inboundLimits[_eid];

        limit.capacity = _capacity;
        limit.refillRate = _refillRate;
        limit.tokens = _capacity;
        limit.lastRefill = block.timestamp;

        emit RateLimitSet(_eid, _isOutbound, _capacity, _refillRate);
    }

    /**
     * @notice Pause/unpause adapter
     * @param _paused True to pause, false to unpause
     */
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    /**
     * @notice Get current escrow balance
     * @return Balance of $P tokens held by this adapter
     */
    function escrowBalance() external view returns (uint256) {
        return IERC20(innerToken).balanceOf(address(this));
    }

    /**
     * @notice Get available outbound capacity for a destination
     * @param _eid Destination chain endpoint ID
     * @return Available tokens that can be sent
     */
    function getAvailableOutbound(uint32 _eid) external view returns (uint256) {
        RateLimit memory limit = outboundLimits[_eid];
        if (limit.capacity == 0) return type(uint256).max;

        uint256 elapsed = block.timestamp - limit.lastRefill;
        uint256 refill = elapsed * limit.refillRate;
        uint256 available = limit.tokens + refill;

        return available > limit.capacity ? limit.capacity : available;
    }

    /**
     * @notice Get available inbound capacity for a source
     * @param _eid Source chain endpoint ID
     * @return Available tokens that can be received
     */
    function getAvailableInbound(uint32 _eid) external view returns (uint256) {
        RateLimit memory limit = inboundLimits[_eid];
        if (limit.capacity == 0) return type(uint256).max;

        uint256 elapsed = block.timestamp - limit.lastRefill;
        uint256 refill = elapsed * limit.refillRate;
        uint256 available = limit.tokens + refill;

        return available > limit.capacity ? limit.capacity : available;
    }

    /**
     * @notice Internal function to consume outbound rate limit
     * @param _eid Destination chain endpoint ID
     * @param _amount Amount to consume
     */
    function _consumeOutboundLimit(uint32 _eid, uint256 _amount) internal {
        RateLimit storage limit = outboundLimits[_eid];
        if (limit.capacity == 0) return; // No limit set

        _refillLimit(limit);

        if (limit.tokens < _amount) revert RateLimitExceeded();
        limit.tokens -= _amount;
    }

    /**
     * @notice Internal function to consume inbound rate limit
     * @param _eid Source chain endpoint ID
     * @param _amount Amount to consume
     */
    function _consumeInboundLimit(uint32 _eid, uint256 _amount) internal {
        RateLimit storage limit = inboundLimits[_eid];
        if (limit.capacity == 0) return; // No limit set

        _refillLimit(limit);

        if (limit.tokens < _amount) revert RateLimitExceeded();
        limit.tokens -= _amount;
    }

    /**
     * @notice Internal function to refill rate limit based on elapsed time
     * @param limit Storage pointer to the rate limit
     */
    function _refillLimit(RateLimit storage limit) internal {
        uint256 elapsed = block.timestamp - limit.lastRefill;
        if (elapsed == 0) return;

        uint256 refill = elapsed * limit.refillRate;
        limit.tokens = limit.tokens + refill > limit.capacity
            ? limit.capacity
            : limit.tokens + refill;
        limit.lastRefill = block.timestamp;
    }

    /**
     * @notice Emergency withdraw (use with extreme caution)
     * @dev This withdraws the underlying token escrow, which can break bridging if misused.
     *      Only callable when paused.
     * @param _to Recipient address
     * @param _amount Amount to withdraw
     */
    function emergencyWithdraw(
        address _to,
        uint256 _amount
    ) external onlyOwner {
        if (_to == address(0)) revert ZeroAddress();
        if (!paused) revert EmergencyWithdrawRequiresPause();
        IERC20(innerToken).safeTransfer(_to, _amount);
        emit EmergencyWithdraw(_to, _amount);
    }

    // -------------------------
    // LayerZero internal hooks
    // -------------------------

    /**
     * @notice Override _debit to enforce pause and rate limits on outbound transfers
     * @dev Called by LayerZero when sending tokens cross-chain
     */
    function _debit(
        address _from,
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 _dstEid
    )
        internal
        virtual
        override
        returns (uint256 amountSentLD, uint256 amountReceivedLD)
    {
        if (paused) revert AdapterPaused();
        _consumeOutboundLimit(_dstEid, _amountLD);
        return super._debit(_from, _amountLD, _minAmountLD, _dstEid);
    }

    /**
     * @notice Override _credit to enforce pause and rate limits on inbound transfers
     * @dev Called by LayerZero when receiving tokens cross-chain
     */
    function _credit(
        address _to,
        uint256 _amountLD,
        uint32 _srcEid
    ) internal virtual override returns (uint256 amountReceivedLD) {
        if (paused) revert AdapterPaused();
        _consumeInboundLimit(_srcEid, _amountLD);

        // Check that we have sufficient inventory to unlock
        uint256 available = IERC20(innerToken).balanceOf(address(this));
        if (available < _amountLD)
            revert InsufficientInventory(available, _amountLD);

        return super._credit(_to, _amountLD, _srcEid);
    }
}

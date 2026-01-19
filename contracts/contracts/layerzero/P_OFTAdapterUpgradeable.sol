// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {OFTAdapterUpgradeable} from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTAdapterUpgradeable.sol";

/**
 * @title P_OFTAdapterUpgradeable
 * @notice LayerZero V2 OFT Adapter for a pre-minted ERC20 token using lock/unlock pattern, deployed behind a proxy.
 * @dev Extends LayerZero's OFTAdapterUpgradeable. Rate limits + pause are enforced inside `_debit` and `_credit`.
 *
 *      UPGRADE SAFETY:
 *      - The proxy's token and endpoint are locked at initialization time.
 *      - Upgrading to an implementation with different token/endpoint will cause ConfigMismatch reverts.
 *      - This is intentional to prevent malicious upgrades that could steal escrowed funds.
 *      - If token/endpoint migration is needed, deploy a new proxy and migrate liquidity.
 *
 *      DEPLOYMENT:
 *      - The implementation contract disables initializers in the constructor.
 *      - Proxy deployment MUST call initialize() atomically (e.g., via proxy constructor data).
 */
contract P_OFTAdapterUpgradeable is OFTAdapterUpgradeable {
    using SafeERC20 for IERC20;

    // --- Upgrade safety ---
    // Bind the proxy's storage to the token + endpoint that were used when the proxy was initialized.
    // This prevents an admin from upgrading the proxy to an implementation wired to a different token/endpoint.
    address public configuredToken;
    address public configuredEndpoint;

    // Rate limiting per peer EID
    struct RateLimit {
        uint256 capacity; // max tokens per window
        uint256 refillRate; // tokens refilled per second
        uint256 tokens; // current available
        uint256 lastRefill; // last refill timestamp
    }

    mapping(uint32 => RateLimit) public outboundLimits; // keyed by dstEid
    mapping(uint32 => RateLimit) public inboundLimits; // keyed by srcEid

    bool public paused;

    // Maximum refill rate to prevent overflow in rate limit calculations
    // Assuming max elapsed time of ~100 years (3.15e9 seconds), this ensures no overflow
    // type(uint256).max / 3.15e9 ~= 3.67e67, so we use a conservative limit of 1e50
    uint256 public constant MAX_REFILL_RATE = 1e50;

    event RateLimitSet(
        uint32 indexed eid,
        bool isOutbound,
        uint256 capacity,
        uint256 refillRate
    );
    event Paused(bool paused);
    event EmergencyWithdraw(address indexed to, uint256 amount);

    error AdapterPaused();
    error RateLimitExceeded();
    error InsufficientInventory(uint256 available, uint256 required);
    error ConfigMismatch(
        address configuredToken,
        address token,
        address configuredEndpoint,
        address endpoint
    );
    error EmergencyWithdrawRequiresPause();
    error ZeroAddress();
    error RefillRateTooHigh();

    /**
     * @notice Constructor for the implementation contract.
     * @dev Disables initializers to prevent the implementation from being initialized directly.
     *      The proxy will call initialize() which is protected by the initializer modifier.
     */
    constructor(
        address _token,
        address _lzEndpoint
    ) OFTAdapterUpgradeable(_token, _lzEndpoint) {
        // Disable initializers on the implementation contract itself
        // This prevents anyone from calling initialize() on the implementation
        _disableInitializers();
    }

    function initialize(address _owner) external initializer {
        if (_owner == address(0)) revert ZeroAddress();

        __OFTAdapter_init(_owner);
        __Ownable_init(_owner);

        // Persist the expected configuration into proxy storage.
        configuredToken = token();
        configuredEndpoint = address(endpoint);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    /**
     * @notice Set rate limit for a specific endpoint ID.
     * @dev Refill rate is bounded to prevent overflow in rate limit calculations.
     * @param _eid The endpoint ID (destination for outbound, source for inbound)
     * @param _isOutbound True for outbound limit, false for inbound
     * @param _capacity Maximum tokens allowed in the bucket
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

    function escrowBalance() external view returns (uint256) {
        return IERC20(token()).balanceOf(address(this));
    }

    function getAvailableOutbound(uint32 _eid) external view returns (uint256) {
        return _getAvailable(outboundLimits[_eid]);
    }

    function getAvailableInbound(uint32 _eid) external view returns (uint256) {
        return _getAvailable(inboundLimits[_eid]);
    }

    /**
     * @notice Emergency withdraw (use with extreme caution).
     * @dev This withdraws the underlying token escrow, which can break bridging if misused.
     */
    function emergencyWithdraw(
        address _to,
        uint256 _amount
    ) external onlyOwner {
        if (_to == address(0)) revert ZeroAddress();
        if (!paused) revert EmergencyWithdrawRequiresPause();
        IERC20(token()).safeTransfer(_to, _amount);
        emit EmergencyWithdraw(_to, _amount);
    }

    // -------------------------
    // LayerZero internal hooks
    // -------------------------

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
        _assertConfig();
        if (paused) revert AdapterPaused();
        _consumeOutboundLimit(_dstEid, _amountLD);
        return super._debit(_from, _amountLD, _minAmountLD, _dstEid);
    }

    function _credit(
        address _to,
        uint256 _amountLD,
        uint32 _srcEid
    ) internal virtual override returns (uint256 amountReceivedLD) {
        _assertConfig();
        if (paused) revert AdapterPaused();
        _consumeInboundLimit(_srcEid, _amountLD);

        uint256 available = IERC20(token()).balanceOf(address(this));
        if (available < _amountLD)
            revert InsufficientInventory(available, _amountLD);

        return super._credit(_to, _amountLD, _srcEid);
    }

    function _assertConfig() internal view {
        address _token = token();
        address _endpoint = address(endpoint);
        if (_token != configuredToken || _endpoint != configuredEndpoint) {
            revert ConfigMismatch(
                configuredToken,
                _token,
                configuredEndpoint,
                _endpoint
            );
        }
    }

    // -------------------------
    // Rate limit internals
    // -------------------------

    function _getAvailable(
        RateLimit memory limit
    ) internal view returns (uint256) {
        if (limit.capacity == 0) return type(uint256).max;
        uint256 elapsed = block.timestamp - limit.lastRefill;
        uint256 refill = elapsed * limit.refillRate;
        uint256 available = limit.tokens + refill;
        return available > limit.capacity ? limit.capacity : available;
    }

    function _consumeOutboundLimit(uint32 _eid, uint256 _amount) internal {
        RateLimit storage limit = outboundLimits[_eid];
        if (limit.capacity == 0) return;
        _refillLimit(limit);
        if (limit.tokens < _amount) revert RateLimitExceeded();
        limit.tokens -= _amount;
    }

    function _consumeInboundLimit(uint32 _eid, uint256 _amount) internal {
        RateLimit storage limit = inboundLimits[_eid];
        if (limit.capacity == 0) return;
        _refillLimit(limit);
        if (limit.tokens < _amount) revert RateLimitExceeded();
        limit.tokens -= _amount;
    }

    function _refillLimit(RateLimit storage limit) internal {
        uint256 elapsed = block.timestamp - limit.lastRefill;
        if (elapsed == 0) return;
        uint256 refill = elapsed * limit.refillRate;
        uint256 newTokens = limit.tokens + refill;
        limit.tokens = newTokens > limit.capacity ? limit.capacity : newTokens;
        limit.lastRefill = block.timestamp;
    }
}

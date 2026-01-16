// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IWormhole {
    struct VM {
        uint8 version;
        uint32 timestamp;
        uint32 nonce;
        uint16 emitterChainId;
        bytes32 emitterAddress;
        uint64 sequence;
        uint8 consistencyLevel;
        bytes payload;
        uint32 guardianSetIndex;
        bytes signatures;
        bytes32 hash;
    }

    function publishMessage(uint32 nonce, bytes memory payload, uint8 consistencyLevel)
        external
        payable
        returns (uint64 sequence);

    function parseAndVerifyVM(bytes calldata encodedVM)
        external
        view
        returns (VM memory vm, bool valid, string memory reason);

    function messageFee() external view returns (uint256);
}

interface IExecutor {
    function requestExecution(
        uint16 dstChain,
        bytes32 dstAddr,
        address refundAddr,
        bytes calldata signedQuoteBytes,
        bytes calldata requestBytes,
        bytes calldata relayInstructions
    ) external payable;
}

/**
 * @title PeridotBridgeEvm
 * @notice Lock/unlock bridge for $P token using Wormhole Core messaging.
 * @dev Implements inventory-based bridging without mint/burn. Uses VAA verification
 *      and replay protection as per Wormhole best practices.
 */
contract PeridotBridgeEvm is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========== CONSTANTS ==========

    uint8 public constant VERSION = 1;
    uint8 public constant ACTION_UNLOCK = 1;
    uint8 public constant CONSISTENCY_LEVEL = 15; // Finalized on most chains
    bytes32 public constant TOKEN_ID = keccak256("PERIDOT_P");

    // ========== STATE ==========

    IERC20 public immutable tokenP;
    IWormhole public immutable wormhole;
    uint16 public immutable thisChainId; // Wormhole chain ID of this chain
    IExecutor public immutable executor;

    /// @notice Maps Wormhole chain ID -> trusted emitter address (32 bytes)
    mapping(uint16 => bytes32) public trustedEmitter;

    /// @notice Tracks consumed VAAs to prevent replay attacks
    mapping(bytes32 => bool) public consumed;

    /// @notice Refund credits if ETH refund fails (e.g. smart contract recipient)
    mapping(address => uint256) public refundCredit;

    /// @notice Rate limit structure per route
    struct RateLimit {
        uint256 capacity; // Maximum tokens per window
        uint256 refillRate; // Tokens refilled per second
        uint256 tokens; // Current available tokens
        uint256 lastRefill; // Last refill timestamp
    }

    mapping(uint16 => RateLimit) public outboundLimit;
    mapping(uint16 => RateLimit) public inboundLimit;

    /// @notice Protocol fee in basis points (e.g., 10 = 0.1%)
    uint256 public protocolFeeBps;

    /// @notice Fee recipient
    address public feeRecipient;

    // ========== EVENTS ==========

    event Locked(
        bytes32 indexed depositId,
        address indexed from,
        uint16 indexed dstChain,
        bytes32 dstRecipient,
        uint256 amount,
        uint64 sequence
    );

    event UnlockExecuted(
        bytes32 indexed vaaHash, uint16 indexed srcChain, bytes32 srcEmitter, address indexed to, uint256 amount
    );

    event TrustedEmitterSet(uint16 indexed chainId, bytes32 emitter);
    event RateLimitSet(uint16 indexed chainId, bool isOutbound, uint256 capacity, uint256 refillRate);
    event ProtocolFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event VAARejected(
        uint16 indexed emitterChainId, bytes32 indexed emitterAddress, bytes32 indexed vmHash, string reason
    );
    event RefundCreditAdded(address indexed to, uint256 amount);
    event ExecutionRequested(
        uint16 indexed dstChain, bytes32 indexed dstBridge, uint64 sequence, uint256 executorPayment
    );

    // ========== ERRORS ==========

    error InvalidVAA();
    error UntrustedEmitter();
    error ReplayDetected();
    error DeadlineExpired();
    error InsufficientEscrow();
    error RateLimitExceeded();
    error InvalidPayload();
    error FeeTooHigh();
    error RefundFailed();
    error InsufficientValue();

    // ========== CONSTRUCTOR ==========

    constructor(address tokenP_, address wormhole_, address executor_, uint16 thisChainId_, address owner_)
        Ownable(owner_)
    {
        require(tokenP_ != address(0), "token zero");
        require(wormhole_ != address(0), "wormhole zero");
        require(executor_ != address(0), "executor zero");

        tokenP = IERC20(tokenP_);
        wormhole = IWormhole(wormhole_);
        executor = IExecutor(executor_);
        thisChainId = thisChainId_;
        feeRecipient = owner_;
    }

    // ========== USER FUNCTIONS ==========

    /**
     * @notice Lock $P and send it to another chain via Wormhole.
     * @param dstChain Wormhole chain ID of destination
     * @param dstRecipient Recipient address (32 bytes, EVM address in low 20 bytes)
     * @param amount Amount of $P to bridge (in local decimals)
     * @param nonce User nonce for uniqueness
     * @param deadline Unix timestamp deadline
     * @param maxFeeBps Maximum acceptable fee in basis points
     * @param refundAddress Address to refund if unlock fails (32 bytes)
     */
    function lockAndSend(
        uint16 dstChain,
        bytes32 dstRecipient,
        uint256 amount,
        uint32 nonce,
        uint64 deadline,
        uint256 maxFeeBps,
        bytes32 refundAddress
    ) external payable whenNotPaused nonReentrant returns (uint64 sequence) {
        require(amount > 0, "amount zero");
        require(trustedEmitter[dstChain] != bytes32(0), "dst chain not supported");
        require(block.timestamp <= deadline, "deadline passed");
        require(maxFeeBps >= protocolFeeBps, "fee too high");
        require(maxFeeBps <= type(uint16).max, "maxFeeBps too large");

        // Check rate limit
        _consumeOutboundRateLimit(dstChain, amount);

        // Take protocol fee
        uint256 fee = (amount * protocolFeeBps) / 10000;
        uint256 netAmount = amount - fee;

        // Transfer tokens from user to this contract (escrow)
        tokenP.safeTransferFrom(msg.sender, address(this), amount);

        if (fee > 0) {
            tokenP.safeTransfer(feeRecipient, fee);
        }

        // Build payload
        bytes memory payload = abi.encode(
            VERSION,
            ACTION_UNLOCK,
            thisChainId,
            dstChain,
            TOKEN_ID,
            dstRecipient,
            netAmount,
            nonce,
            deadline,
            uint16(maxFeeBps),
            refundAddress
        );

        // Publish Wormhole message
        uint256 wormholeFee = wormhole.messageFee();
        require(msg.value >= wormholeFee, "insufficient wormhole fee");

        sequence = wormhole.publishMessage{value: wormholeFee}(nonce, payload, CONSISTENCY_LEVEL);

        // Refund excess ETH
        if (msg.value > wormholeFee) {
            uint256 refundAmount = msg.value - wormholeFee;
            (bool ok,) = payable(msg.sender).call{value: refundAmount}("");
            if (!ok) {
                refundCredit[msg.sender] += refundAmount;
                emit RefundCreditAdded(msg.sender, refundAmount);
            }
        }

        bytes32 depositId = keccak256(abi.encodePacked(thisChainId, msg.sender, dstChain, dstRecipient, amount, nonce));

        emit Locked(depositId, msg.sender, dstChain, dstRecipient, netAmount, sequence);
    }

    /**
     * @notice Lock $P and request automatic execution on the destination chain via Wormhole Executor.
     * @dev User pays both Wormhole Core message fee and Executor provider payment in the same tx.
     *
     * @param dstChain Wormhole chain ID of destination
     * @param dstBridge Wormhole-formatted address (bytes32) of the destination PeridotBridgeEvm
     * @param dstRecipient Recipient address (bytes32, EVM address in low 20 bytes)
     * @param amount Amount of $P to bridge (in local decimals)
     * @param nonce User nonce for uniqueness
     * @param deadline Unix timestamp deadline
     * @param maxFeeBps Maximum acceptable fee in basis points
     * @param refundAddress Address to refund if unlock fails (32 bytes)
     * @param executorRefundAddr EVM address to receive execution-layer refunds (provider policy)
     * @param signedQuoteBytes Provider-signed execution quote (off-chain)
     * @param relayInstructions Provider-specific relay instructions (off-chain)
     * @param executorPayment Native token payment forwarded to Executor.requestExecution
     */
    function lockAndSendAndRequestExecution(
        uint16 dstChain,
        bytes32 dstBridge,
        bytes32 dstRecipient,
        uint256 amount,
        uint32 nonce,
        uint64 deadline,
        uint256 maxFeeBps,
        bytes32 refundAddress,
        address executorRefundAddr,
        bytes calldata signedQuoteBytes,
        bytes calldata relayInstructions,
        uint256 executorPayment
    ) external payable whenNotPaused nonReentrant returns (uint64 sequence) {
        require(amount > 0, "amount zero");
        require(trustedEmitter[dstChain] != bytes32(0), "dst chain not supported");
        require(block.timestamp <= deadline, "deadline passed");
        require(maxFeeBps >= protocolFeeBps, "fee too high");
        require(maxFeeBps <= type(uint16).max, "maxFeeBps too large");

        // Check rate limit
        _consumeOutboundRateLimit(dstChain, amount);

        // Take protocol fee
        uint256 fee = (amount * protocolFeeBps) / 10000;
        uint256 netAmount = amount - fee;

        // Transfer tokens from user to this contract (escrow)
        tokenP.safeTransferFrom(msg.sender, address(this), amount);

        if (fee > 0) {
            tokenP.safeTransfer(feeRecipient, fee);
        }

        // Build payload
        bytes memory payload = abi.encode(
            VERSION,
            ACTION_UNLOCK,
            thisChainId,
            dstChain,
            TOKEN_ID,
            dstRecipient,
            netAmount,
            nonce,
            deadline,
            uint16(maxFeeBps),
            refundAddress
        );

        // Publish Wormhole message
        uint256 wormholeFee = wormhole.messageFee();
        uint256 required = wormholeFee + executorPayment;
        if (msg.value < required) revert InsufficientValue();

        sequence = wormhole.publishMessage{value: wormholeFee}(nonce, payload, CONSISTENCY_LEVEL);

        // Request execution via Executor using a standard v1 VAA request identifier:
        // (emitterChain, emitterAddress, sequence). EVM emitterAddress is the bridge contract in low 20 bytes.
        bytes memory requestBytes = abi.encode(thisChainId, bytes32(uint256(uint160(address(this)))), sequence);

        executor.requestExecution{
            value: executorPayment
        }(dstChain, dstBridge, executorRefundAddr, signedQuoteBytes, requestBytes, relayInstructions);

        emit ExecutionRequested(dstChain, dstBridge, sequence, executorPayment);

        // Refund any extra ETH (beyond wormholeFee+executorPayment)
        if (msg.value > required) {
            uint256 refundAmount = msg.value - required;
            (bool ok,) = payable(msg.sender).call{value: refundAmount}("");
            if (!ok) {
                refundCredit[msg.sender] += refundAmount;
                emit RefundCreditAdded(msg.sender, refundAmount);
            }
        }
    }

    /**
     * @notice Receive and verify VAA, then unlock $P to recipient.
     * @param encodedVAA Wormhole VAA bytes (signed by guardians)
     */
    function receiveAndUnlock(bytes calldata encodedVAA) external whenNotPaused nonReentrant {
        // Parse and verify VAA
        (IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVAA);

        if (!valid) {
            emit VAARejected(vm.emitterChainId, vm.emitterAddress, vm.hash, reason);
            revert InvalidVAA();
        }

        // Check trusted emitter
        bytes32 expectedEmitter = trustedEmitter[vm.emitterChainId];
        if (expectedEmitter == bytes32(0) || vm.emitterAddress != expectedEmitter) {
            revert UntrustedEmitter();
        }

        // Replay protection
        bytes32 vmHash = vm.hash;
        if (consumed[vmHash]) {
            revert ReplayDetected();
        }
        consumed[vmHash] = true;

        // Decode payload
        (
            uint8 version,
            uint8 action,
            uint16 srcChain,
            uint16 dstChain,
            bytes32 tokenId,
            bytes32 recipientBytes,
            uint256 amount,
            uint32 nonce,
            uint64 deadline,
            uint16 maxFeeBps,
            bytes32 refundAddress
        ) = abi.decode(
            vm.payload, (uint8, uint8, uint16, uint16, bytes32, bytes32, uint256, uint32, uint64, uint16, bytes32)
        );

        // Validate payload
        if (version != VERSION || action != ACTION_UNLOCK) {
            revert InvalidPayload();
        }
        if (tokenId != TOKEN_ID) {
            revert InvalidPayload();
        }
        if (dstChain != thisChainId) {
            revert InvalidPayload();
        }
        if (srcChain != vm.emitterChainId) {
            revert InvalidPayload();
        }
        if (block.timestamp > deadline) {
            revert DeadlineExpired();
        }

        // Check rate limit
        _consumeInboundRateLimit(srcChain, amount);

        // Extract recipient address (last 20 bytes)
        address recipient = address(uint160(uint256(recipientBytes)));

        // Check escrow balance
        uint256 escrowBal = tokenP.balanceOf(address(this));
        if (escrowBal < amount) {
            revert InsufficientEscrow();
        }

        // Transfer tokens to recipient
        tokenP.safeTransfer(recipient, amount);

        emit UnlockExecuted(vmHash, srcChain, vm.emitterAddress, recipient, amount);
    }

    /**
     * @notice Withdraw ETH refund credits accumulated when direct refunds fail.
     */
    function withdrawRefundCredit() external nonReentrant {
        uint256 amount = refundCredit[msg.sender];
        refundCredit[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert RefundFailed();
    }

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Set trusted emitter for a remote chain.
     * @param chainId Wormhole chain ID
     * @param emitter 32-byte emitter address
     */
    function setTrustedEmitter(uint16 chainId, bytes32 emitter) external onlyOwner {
        trustedEmitter[chainId] = emitter;
        emit TrustedEmitterSet(chainId, emitter);
    }

    /**
     * @notice Set rate limit for a route.
     * @param chainId Wormhole chain ID
     * @param isOutbound True for outbound, false for inbound
     * @param capacity Maximum tokens per window
     * @param refillRate Tokens refilled per second
     */
    function setRateLimit(uint16 chainId, bool isOutbound, uint256 capacity, uint256 refillRate) external onlyOwner {
        RateLimit storage limit = isOutbound ? outboundLimit[chainId] : inboundLimit[chainId];

        limit.capacity = capacity;
        limit.refillRate = refillRate;
        limit.tokens = capacity; // Start full
        limit.lastRefill = block.timestamp;

        emit RateLimitSet(chainId, isOutbound, capacity, refillRate);
    }

    /**
     * @notice Set protocol fee.
     * @param newFeeBps Fee in basis points (max 100 = 1%)
     */
    function setProtocolFee(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > 100) {
            revert FeeTooHigh();
        }
        uint256 oldFee = protocolFeeBps;
        protocolFeeBps = newFeeBps;
        emit ProtocolFeeUpdated(oldFee, newFeeBps);
    }

    /**
     * @notice Set fee recipient.
     */
    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "zero address");
        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }

    /**
     * @notice Pause bridge operations.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause bridge operations.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Emergency withdraw escrowed tokens (only owner, use with extreme caution).
     */
    function emergencyWithdraw(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "zero address");
        tokenP.safeTransfer(to, amount);
    }

    // ========== INTERNAL FUNCTIONS ==========

    /**
     * @notice Consume outbound rate limit tokens.
     */
    function _consumeOutboundRateLimit(uint16 chainId, uint256 amount) internal {
        RateLimit storage limit = outboundLimit[chainId];
        if (limit.capacity == 0) return; // No limit set

        _refillRateLimit(limit);

        if (limit.tokens < amount) {
            revert RateLimitExceeded();
        }

        limit.tokens -= amount;
    }

    /**
     * @notice Consume inbound rate limit tokens.
     */
    function _consumeInboundRateLimit(uint16 chainId, uint256 amount) internal {
        RateLimit storage limit = inboundLimit[chainId];
        if (limit.capacity == 0) return; // No limit set

        _refillRateLimit(limit);

        if (limit.tokens < amount) {
            revert RateLimitExceeded();
        }

        limit.tokens -= amount;
    }

    /**
     * @notice Refill rate limit based on time elapsed.
     */
    function _refillRateLimit(RateLimit storage limit) internal {
        uint256 elapsed = block.timestamp - limit.lastRefill;
        if (elapsed == 0) return;

        uint256 refill = elapsed * limit.refillRate;
        limit.tokens = limit.tokens + refill > limit.capacity ? limit.capacity : limit.tokens + refill;

        limit.lastRefill = block.timestamp;
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Get escrow balance.
     */
    function escrowBalance() external view returns (uint256) {
        return tokenP.balanceOf(address(this));
    }

    /**
     * @notice Get current available rate limit for outbound transfers.
     */
    function getOutboundRateLimit(uint16 chainId) external view returns (uint256) {
        RateLimit memory limit = outboundLimit[chainId];
        if (limit.capacity == 0) return type(uint256).max;

        uint256 elapsed = block.timestamp - limit.lastRefill;
        uint256 refill = elapsed * limit.refillRate;
        uint256 available = limit.tokens + refill;

        return available > limit.capacity ? limit.capacity : available;
    }

    /**
     * @notice Get current available rate limit for inbound transfers.
     */
    function getInboundRateLimit(uint16 chainId) external view returns (uint256) {
        RateLimit memory limit = inboundLimit[chainId];
        if (limit.capacity == 0) return type(uint256).max;

        uint256 elapsed = block.timestamp - limit.lastRefill;
        uint256 refill = elapsed * limit.refillRate;
        uint256 available = limit.tokens + refill;

        return available > limit.capacity ? limit.capacity : available;
    }

    /**
     * @notice Check if a VAA has been consumed.
     */
    function isConsumed(bytes32 vaaHash) external view returns (bool) {
        return consumed[vaaHash];
    }

    /**
     * @notice Helper to convert EVM address to bytes32 (for dstRecipient on Solana).
     */
    function addressToBytes32(address addr) public pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    /**
     * @notice Helper to extract address from bytes32.
     */
    function bytes32ToAddress(bytes32 b) public pure returns (address) {
        return address(uint160(uint256(b)));
    }

    // ========== RECEIVE FUNCTION ==========

    /**
     * @notice Accept ETH for Wormhole message fees.
     */
    receive() external payable {}
}

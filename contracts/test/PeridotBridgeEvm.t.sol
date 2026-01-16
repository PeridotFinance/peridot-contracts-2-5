// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/bridge/PeridotBridgeEvm.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockTokenP is ERC20 {
    constructor() ERC20("Peridot", "P") {
        _mint(msg.sender, 1000000000e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockWormhole is IWormhole {
    uint64 public nextSequence = 1;
    mapping(bytes32 => VM) public vms;

    function publishMessage(uint32 nonce, bytes memory payload, uint8)
        external
        payable
        override
        returns (uint64 sequence)
    {
        sequence = nextSequence++;

        // Store for testing
        bytes32 hash = keccak256(abi.encodePacked(msg.sender, nonce, payload));
        vms[hash] = VM({
            version: 1,
            timestamp: uint32(block.timestamp),
            nonce: nonce,
            emitterChainId: 1, // Mock source chain
            emitterAddress: bytes32(uint256(uint160(msg.sender))),
            sequence: sequence,
            consistencyLevel: 15,
            payload: payload,
            guardianSetIndex: 0,
            signatures: "",
            hash: hash
        });
    }

    function parseAndVerifyVM(bytes calldata encodedVM)
        external
        view
        override
        returns (VM memory vm, bool valid, string memory reason)
    {
        bytes32 hash = keccak256(encodedVM);
        vm = vms[hash];

        if (vm.hash == bytes32(0)) {
            // Decode from encodedVM for testing
            (uint8 version, uint16 emitterChainId, bytes32 emitterAddress, bytes memory payload) =
                abi.decode(encodedVM, (uint8, uint16, bytes32, bytes));

            vm = VM({
                version: version,
                timestamp: uint32(block.timestamp),
                nonce: 0,
                emitterChainId: emitterChainId,
                emitterAddress: emitterAddress,
                sequence: 1,
                consistencyLevel: 15,
                payload: payload,
                guardianSetIndex: 0,
                signatures: "",
                hash: hash
            });
        }

        valid = true;
        reason = "";
    }

    function messageFee() external pure override returns (uint256) {
        return 0.001 ether;
    }
}

contract MockExecutor is IExecutor {
    uint16 public lastDstChain;
    bytes32 public lastDstAddr;
    address public lastRefundAddr;
    bytes public lastSignedQuoteBytes;
    bytes public lastRequestBytes;
    bytes public lastRelayInstructions;
    uint256 public lastValue;

    function requestExecution(
        uint16 dstChain,
        bytes32 dstAddr,
        address refundAddr,
        bytes calldata signedQuoteBytes,
        bytes calldata requestBytes,
        bytes calldata relayInstructions
    ) external payable override {
        lastDstChain = dstChain;
        lastDstAddr = dstAddr;
        lastRefundAddr = refundAddr;
        lastSignedQuoteBytes = signedQuoteBytes;
        lastRequestBytes = requestBytes;
        lastRelayInstructions = relayInstructions;
        lastValue = msg.value;
    }
}

contract RefundRejector {
    PeridotBridgeEvm public bridge;
    IERC20 public tokenP;

    constructor(PeridotBridgeEvm bridge_, IERC20 tokenP_) {
        bridge = bridge_;
        tokenP = tokenP_;
    }

    receive() external payable {
        revert("no refund");
    }

    function doLockAndSend(
        uint16 dstChain,
        bytes32 dstRecipient,
        uint256 amount,
        uint32 nonce,
        uint64 deadline,
        uint256 maxFeeBps,
        bytes32 refundAddress
    ) external payable returns (uint64) {
        tokenP.approve(address(bridge), amount);
        return
            bridge.lockAndSend{
                value: msg.value
            }(dstChain, dstRecipient, amount, nonce, deadline, maxFeeBps, refundAddress);
    }
}

contract PeridotBridgeEvmTest is Test {
    PeridotBridgeEvm bridge;
    MockTokenP tokenP;
    MockWormhole wormhole;
    MockExecutor executor;

    address admin = address(this);
    address user1 = address(0x1);
    address user2 = address(0x2);
    address feeRecipient = address(0x3);

    uint16 constant THIS_CHAIN = 2; // Monad
    uint16 constant REMOTE_CHAIN = 1; // Solana
    bytes32 constant REMOTE_EMITTER = bytes32(uint256(0x123456));

    function setUp() public {
        tokenP = new MockTokenP();
        wormhole = new MockWormhole();
        executor = new MockExecutor();

        bridge = new PeridotBridgeEvm(address(tokenP), address(wormhole), address(executor), THIS_CHAIN, admin);

        // Fund users
        tokenP.mint(user1, 10000e18);
        tokenP.mint(user2, 10000e18);

        // Fund bridge escrow
        tokenP.mint(address(bridge), 100000e18);

        // Set trusted emitter
        bridge.setTrustedEmitter(REMOTE_CHAIN, REMOTE_EMITTER);

        // Fund users with ETH for Wormhole fees
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
    }

    function testDeployment() public view {
        assertEq(address(bridge.tokenP()), address(tokenP));
        assertEq(address(bridge.wormhole()), address(wormhole));
        assertEq(address(bridge.executor()), address(executor));
        assertEq(bridge.thisChainId(), THIS_CHAIN);
        assertEq(bridge.trustedEmitter(REMOTE_CHAIN), REMOTE_EMITTER);
    }

    function testLockAndSend() public {
        uint256 amount = 100e18;
        bytes32 recipient = bytes32(uint256(0x9999)); // Solana pubkey

        vm.startPrank(user1);
        tokenP.approve(address(bridge), amount);

        uint256 bridgeBalanceBefore = tokenP.balanceOf(address(bridge));
        uint256 userBalanceBefore = tokenP.balanceOf(user1);

        uint64 sequence = bridge.lockAndSend{
            value: 0.001 ether
        }(
            REMOTE_CHAIN,
            recipient,
            amount,
            12345, // nonce
            uint64(block.timestamp + 1 hours),
            0, // maxFeeBps
            bytes32(uint256(uint160(user1))) // refund address
        );

        vm.stopPrank();

        uint256 bridgeBalanceAfter = tokenP.balanceOf(address(bridge));
        uint256 userBalanceAfter = tokenP.balanceOf(user1);

        assertEq(userBalanceBefore - userBalanceAfter, amount, "User balance decreased");
        assertEq(bridgeBalanceAfter - bridgeBalanceBefore, amount, "Bridge escrow increased");
        assertEq(sequence, 1, "First sequence");

        console.log("Locked", amount, "tokens, sequence:", sequence);
    }

    function testReceiveAndUnlock() public {
        uint256 amount = 50e18;
        address recipient = user2;

        // Build payload
        bytes memory payload = abi.encode(
            uint8(1), // version
            uint8(1), // ACTION_UNLOCK
            REMOTE_CHAIN, // srcChain
            THIS_CHAIN, // dstChain
            bridge.TOKEN_ID(),
            bytes32(uint256(uint160(recipient))),
            amount,
            uint32(11111), // nonce
            uint64(block.timestamp + 1 hours), // deadline
            uint16(0), // maxFeeBps
            bytes32(0) // refundAddress
        );

        // Encode VAA
        bytes memory encodedVAA = abi.encode(
            uint8(1), // version
            REMOTE_CHAIN, // emitterChainId
            REMOTE_EMITTER, // emitterAddress
            payload
        );

        uint256 recipientBalanceBefore = tokenP.balanceOf(recipient);
        uint256 bridgeBalanceBefore = tokenP.balanceOf(address(bridge));

        bridge.receiveAndUnlock(encodedVAA);

        uint256 recipientBalanceAfter = tokenP.balanceOf(recipient);
        uint256 bridgeBalanceAfter = tokenP.balanceOf(address(bridge));

        assertEq(recipientBalanceAfter - recipientBalanceBefore, amount, "Recipient received tokens");
        assertEq(bridgeBalanceBefore - bridgeBalanceAfter, amount, "Bridge escrow decreased");

        console.log("Unlocked", amount, "tokens to", recipient);
    }

    function testReplayProtection() public {
        uint256 amount = 50e18;
        address recipient = user2;

        bytes memory payload = abi.encode(
            uint8(1),
            uint8(1),
            REMOTE_CHAIN,
            THIS_CHAIN,
            bridge.TOKEN_ID(),
            bytes32(uint256(uint160(recipient))),
            amount,
            uint32(22222),
            uint64(block.timestamp + 1 hours),
            uint16(0),
            bytes32(0)
        );

        bytes memory encodedVAA = abi.encode(uint8(1), REMOTE_CHAIN, REMOTE_EMITTER, payload);

        // First unlock succeeds
        bridge.receiveAndUnlock(encodedVAA);

        // Second unlock with same VAA should fail
        vm.expectRevert(PeridotBridgeEvm.ReplayDetected.selector);
        bridge.receiveAndUnlock(encodedVAA);

        console.log("Replay protection working correctly");
    }

    function testPayloadSrcChainMustMatchVmEmitterChainId() public {
        uint256 amount = 50e18;
        address recipient = user2;

        // Make the mismatched emitterChainId pass the trusted-emitter check so we can
        // specifically test the payload-vs-VM binding.
        bridge.setTrustedEmitter(uint16(REMOTE_CHAIN + 1), REMOTE_EMITTER);

        // Payload says srcChain=REMOTE_CHAIN, but encodedVAA says emitterChainId=REMOTE_CHAIN+1
        bytes memory payload = abi.encode(
            uint8(1),
            uint8(1),
            REMOTE_CHAIN, // srcChain in payload
            THIS_CHAIN,
            bridge.TOKEN_ID(),
            bytes32(uint256(uint160(recipient))),
            amount,
            uint32(123),
            uint64(block.timestamp + 1 hours),
            uint16(0),
            bytes32(0)
        );

        bytes memory encodedVAA = abi.encode(
            uint8(1),
            uint16(REMOTE_CHAIN + 1), // emitterChainId in VM
            REMOTE_EMITTER,
            payload
        );

        vm.expectRevert(PeridotBridgeEvm.InvalidPayload.selector);
        bridge.receiveAndUnlock(encodedVAA);
    }

    function testLockAndSendMaxFeeBpsTooLargeReverts() public {
        uint256 amount = 1e18;
        bytes32 recipient = bytes32(uint256(uint160(user2)));

        vm.startPrank(user1);
        tokenP.approve(address(bridge), amount);

        vm.expectRevert(bytes("maxFeeBps too large"));
        bridge.lockAndSend{
            value: 0.001 ether
        }(
            REMOTE_CHAIN,
            recipient,
            amount,
            1,
            uint64(block.timestamp + 1 hours),
            uint256(type(uint16).max) + 1,
            bytes32(0)
        );

        vm.stopPrank();
    }

    function testRefundCreditWhenRefundFails() public {
        uint256 amount = 10e18;
        RefundRejector rr = new RefundRejector(bridge, IERC20(address(tokenP)));

        // Fund rr with tokens and ETH
        tokenP.mint(address(rr), amount);
        vm.deal(address(rr), 10 ether);

        uint256 wormholeFee = wormhole.messageFee();
        uint256 extra = 0.123 ether;

        // Call lockAndSend from rr so refund target is rr (which rejects ETH)
        vm.prank(address(rr));
        rr.doLockAndSend{
            value: wormholeFee + extra
        }(REMOTE_CHAIN, bytes32(uint256(uint160(user2))), amount, 77, uint64(block.timestamp + 1 hours), 0, bytes32(0));

        assertEq(bridge.refundCredit(address(rr)), extra, "refund credit recorded");
    }

    function testUntrustedEmitterFails() public {
        bytes32 untrustedEmitter = bytes32(uint256(0x999999));

        bytes memory payload = abi.encode(
            uint8(1),
            uint8(1),
            REMOTE_CHAIN,
            THIS_CHAIN,
            bridge.TOKEN_ID(),
            bytes32(uint256(uint160(user2))),
            100e18,
            uint32(33333),
            uint64(block.timestamp + 1 hours),
            uint16(0),
            bytes32(0)
        );

        bytes memory encodedVAA = abi.encode(uint8(1), REMOTE_CHAIN, untrustedEmitter, payload);

        vm.expectRevert(PeridotBridgeEvm.UntrustedEmitter.selector);
        bridge.receiveAndUnlock(encodedVAA);

        console.log("Correctly rejected untrusted emitter");
    }

    function testRateLimits() public {
        // Set outbound rate limit: 100 tokens capacity, 1 token/second refill
        bridge.setRateLimit(REMOTE_CHAIN, true, 100e18, 1e18);

        vm.startPrank(user1);
        tokenP.approve(address(bridge), 200e18);

        // First transfer within limit should succeed
        bridge.lockAndSend{
            value: 0.001 ether
        }(REMOTE_CHAIN, bytes32(uint256(0x1111)), 50e18, 1, uint64(block.timestamp + 1 hours), 0, bytes32(0));

        // Second transfer exceeding limit should fail
        vm.expectRevert(PeridotBridgeEvm.RateLimitExceeded.selector);
        bridge.lockAndSend{
            value: 0.001 ether
        }(REMOTE_CHAIN, bytes32(uint256(0x2222)), 60e18, 2, uint64(block.timestamp + 1 hours), 0, bytes32(0));

        vm.stopPrank();

        console.log("Rate limit enforced correctly");
    }

    function testRateLimitRefill() public {
        bridge.setRateLimit(REMOTE_CHAIN, true, 100e18, 10e18); // 10 tokens/second

        vm.startPrank(user1);
        tokenP.approve(address(bridge), 200e18);

        // Use 80 tokens
        bridge.lockAndSend{
            value: 0.001 ether
        }(REMOTE_CHAIN, bytes32(uint256(0x1)), 80e18, 1, uint64(block.timestamp + 1 hours), 0, bytes32(0));

        // Wait 5 seconds (should refill 50 tokens)
        vm.warp(block.timestamp + 5);

        // Now we should have 20 + 50 = 70 tokens available
        bridge.lockAndSend{
            value: 0.001 ether
        }(REMOTE_CHAIN, bytes32(uint256(0x2)), 70e18, 2, uint64(block.timestamp + 1 hours), 0, bytes32(0));

        vm.stopPrank();

        console.log("Rate limit refill working correctly");
    }

    function testPause() public {
        bridge.pause();

        vm.startPrank(user1);
        tokenP.approve(address(bridge), 100e18);

        vm.expectRevert();
        bridge.lockAndSend{
            value: 0.001 ether
        }(REMOTE_CHAIN, bytes32(uint256(0x1)), 10e18, 1, uint64(block.timestamp + 1 hours), 0, bytes32(0));

        vm.stopPrank();

        console.log("Pause working correctly");
    }

    function testProtocolFee() public {
        bridge.setProtocolFee(50); // 0.5% fee
        bridge.setFeeRecipient(feeRecipient);

        uint256 amount = 100e18;
        uint256 expectedFee = (amount * 50) / 10000; // 0.5 tokens

        vm.startPrank(user1);
        tokenP.approve(address(bridge), amount);

        uint256 feeRecipientBefore = tokenP.balanceOf(feeRecipient);

        bridge.lockAndSend{
            value: 0.001 ether
        }(REMOTE_CHAIN, bytes32(uint256(0x1)), amount, 1, uint64(block.timestamp + 1 hours), 50, bytes32(0));

        vm.stopPrank();

        uint256 feeRecipientAfter = tokenP.balanceOf(feeRecipient);
        assertEq(feeRecipientAfter - feeRecipientBefore, expectedFee, "Fee collected");

        console.log("Protocol fee collected:", expectedFee);
    }

    function testInsufficientEscrow() public {
        // Deploy new bridge with no inventory
        PeridotBridgeEvm emptyBridge =
            new PeridotBridgeEvm(address(tokenP), address(wormhole), address(executor), THIS_CHAIN, admin);

        emptyBridge.setTrustedEmitter(REMOTE_CHAIN, REMOTE_EMITTER);

        bytes memory payload = abi.encode(
            uint8(1),
            uint8(1),
            REMOTE_CHAIN,
            THIS_CHAIN,
            bridge.TOKEN_ID(),
            bytes32(uint256(uint160(user2))),
            100e18,
            uint32(44444),
            uint64(block.timestamp + 1 hours),
            uint16(0),
            bytes32(0)
        );

        bytes memory encodedVAA = abi.encode(uint8(1), REMOTE_CHAIN, REMOTE_EMITTER, payload);

        vm.expectRevert(PeridotBridgeEvm.InsufficientEscrow.selector);
        emptyBridge.receiveAndUnlock(encodedVAA);

        console.log("Correctly reverted when escrow insufficient");
    }

    function testLockAndSendAndRequestExecutionCallsExecutor() public {
        uint256 amount = 10e18;
        bytes32 recipient = bytes32(uint256(uint160(user2)));

        bytes memory signedQuote = hex"010203";
        bytes memory relayInstr = hex"aabbcc";
        uint256 executorPayment = 0.05 ether;

        vm.startPrank(user1);
        tokenP.approve(address(bridge), amount);

        uint256 wormholeFee = wormhole.messageFee();
        uint256 value = wormholeFee + executorPayment;

        uint64 seq = bridge.lockAndSendAndRequestExecution{
            value: value
        }(
            REMOTE_CHAIN,
            bytes32(uint256(uint160(address(0xBEEF)))), // dstBridge (wormhole-formatted)
            recipient,
            amount,
            7,
            uint64(block.timestamp + 1 hours),
            0,
            bytes32(0),
            user1, // executorRefundAddr
            signedQuote,
            relayInstr,
            executorPayment
        );
        vm.stopPrank();

        assertEq(seq, 1);
        assertEq(executor.lastDstChain(), REMOTE_CHAIN);
        assertEq(executor.lastRefundAddr(), user1);
        assertEq(executor.lastSignedQuoteBytes(), signedQuote);
        assertEq(executor.lastRelayInstructions(), relayInstr);
        assertEq(executor.lastValue(), executorPayment);

        bytes memory expectedRequest = abi.encode(THIS_CHAIN, bytes32(uint256(uint160(address(bridge)))), uint64(1));
        assertEq(executor.lastRequestBytes(), expectedRequest);
    }

    function testHelperFunctions() public view {
        address testAddr = 0x1234567890123456789012345678901234567890;
        bytes32 addrAsBytes32 = bridge.addressToBytes32(testAddr);
        address recoveredAddr = bridge.bytes32ToAddress(addrAsBytes32);

        assertEq(recoveredAddr, testAddr, "Address conversion round-trip");
        console.log("Helper functions working correctly");
    }
}

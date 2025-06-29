// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VRFCoordinatorV2Interface} from "@chainlink/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";
import {VRFConsumerBaseV2} from "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import {PeridottrollerInterface} from "../../PeridottrollerInterface.sol";

/**
 * @title PeridotVRFLiquidator
 * @dev A VRF-powered liquidation contract that provides MEV protection and fair liquidation selection.
 * This contract uses Chainlink VRF to introduce randomness in liquidation processes.
 */
contract PeridotVRFLiquidator is VRFConsumerBaseV2 {
    event LiquidationRequested(
        bytes32 indexed requestId,
        address indexed borrower,
        address indexed pTokenBorrowed,
        address pTokenCollateral,
        uint256 repayAmount
    );

    event LiquidatorSelected(
        bytes32 indexed requestId,
        address indexed borrower,
        address indexed selectedLiquidator,
        uint256 randomness
    );

    event LiquidationExecuted(
        bytes32 indexed requestId,
        address indexed borrower,
        address indexed liquidator,
        uint256 seizeTokens
    );

    event LiquidatorRegistered(address indexed liquidator);
    event LiquidatorUnregistered(address indexed liquidator);

    struct LiquidationRequest {
        address borrower;
        address pTokenBorrowed;
        address pTokenCollateral;
        uint256 repayAmount;
        address[] eligibleLiquidators;
        uint256 timestamp;
        bool fulfilled;
    }

    // VRF Configuration
    VRFCoordinatorV2Interface private immutable vrfCoordinator;
    uint64 private immutable subscriptionId;
    bytes32 private immutable keyHash;
    uint32 private constant CALLBACK_GAS_LIMIT = 500_000;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;

    // Protocol Integration
    PeridottrollerInterface public immutable peridottroller;

    // Liquidation Management
    mapping(bytes32 => LiquidationRequest) public liquidationRequests;
    mapping(address => bool) public registeredLiquidators;
    address[] public liquidatorList;

    // Access Control
    address public owner;
    mapping(address => bool) public authorizedCallers;

    // MEV Protection Settings
    uint256 public constant MIN_LIQUIDATION_DELAY = 1 minutes;
    uint256 public constant MAX_LIQUIDATION_DELAY = 10 minutes;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }

    modifier onlyAuthorized() {
        require(
            authorizedCallers[msg.sender] || msg.sender == owner,
            "Not authorized to call this function"
        );
        _;
    }

    /**
     * @dev Constructor initializes the VRF consumer and protocol integration.
     * @param _vrfCoordinator The VRF coordinator address.
     * @param _subscriptionId The VRF subscription ID.
     * @param _keyHash The VRF key hash.
     * @param _peridottroller The Peridottroller contract address.
     */
    constructor(
        address _vrfCoordinator,
        uint64 _subscriptionId,
        bytes32 _keyHash,
        address _peridottroller
    ) VRFConsumerBaseV2(_vrfCoordinator) {
        vrfCoordinator = VRFCoordinatorV2Interface(_vrfCoordinator);
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        peridottroller = PeridottrollerInterface(_peridottroller);
        owner = msg.sender;
    }

    /**
     * @dev Register a liquidator in the fair liquidation pool.
     */
    function registerLiquidator() external {
        require(!registeredLiquidators[msg.sender], "Already registered");

        registeredLiquidators[msg.sender] = true;
        liquidatorList.push(msg.sender);

        emit LiquidatorRegistered(msg.sender);
    }

    /**
     * @dev Unregister a liquidator from the fair liquidation pool.
     */
    function unregisterLiquidator() external {
        require(registeredLiquidators[msg.sender], "Not registered");

        registeredLiquidators[msg.sender] = false;

        // Remove from liquidator list
        for (uint256 i = 0; i < liquidatorList.length; i++) {
            if (liquidatorList[i] == msg.sender) {
                liquidatorList[i] = liquidatorList[liquidatorList.length - 1];
                liquidatorList.pop();
                break;
            }
        }

        emit LiquidatorUnregistered(msg.sender);
    }

    /**
     * @dev Request a fair liquidation using VRF to select a liquidator.
     * @param _borrower The borrower to liquidate.
     * @param _pTokenBorrowed The borrowed pToken to repay.
     * @param _pTokenCollateral The collateral pToken to seize.
     * @param _repayAmount The amount to repay.
     * @return requestId The VRF request ID.
     */
    function requestFairLiquidation(
        address _borrower,
        address _pTokenBorrowed,
        address _pTokenCollateral,
        uint256 _repayAmount
    ) external onlyAuthorized returns (uint256 requestId) {
        require(liquidatorList.length > 0, "No registered liquidators");

        // Check if liquidation is allowed
        uint256 allowed = peridottroller.liquidateBorrowAllowed(
            _pTokenBorrowed,
            _pTokenCollateral,
            msg.sender,
            _borrower,
            _repayAmount
        );
        require(allowed == 0, "Liquidation not allowed");

        // Request randomness from VRF
        requestId = vrfCoordinator.requestRandomWords(
            keyHash,
            subscriptionId,
            REQUEST_CONFIRMATIONS,
            CALLBACK_GAS_LIMIT,
            NUM_WORDS
        );

        // Store liquidation request
        liquidationRequests[bytes32(requestId)] = LiquidationRequest({
            borrower: _borrower,
            pTokenBorrowed: _pTokenBorrowed,
            pTokenCollateral: _pTokenCollateral,
            repayAmount: _repayAmount,
            eligibleLiquidators: liquidatorList, // Snapshot current liquidators
            timestamp: block.timestamp,
            fulfilled: false
        });

        emit LiquidationRequested(
            bytes32(requestId),
            _borrower,
            _pTokenBorrowed,
            _pTokenCollateral,
            _repayAmount
        );

        return requestId;
    }

    /**
     * @dev Fulfill the randomness request and select a liquidator.
     * @param requestId The VRF request ID.
     * @param randomWords The random words provided by VRF.
     */
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) internal override {
        bytes32 reqId = bytes32(requestId);
        LiquidationRequest storage request = liquidationRequests[reqId];

        require(!request.fulfilled, "Request already fulfilled");
        require(
            request.eligibleLiquidators.length > 0,
            "No eligible liquidators"
        );

        // Select a random liquidator
        uint256 randomIndex = randomWords[0] %
            request.eligibleLiquidators.length;
        address selectedLiquidator = request.eligibleLiquidators[randomIndex];

        request.fulfilled = true;

        emit LiquidatorSelected(
            reqId,
            request.borrower,
            selectedLiquidator,
            randomWords[0]
        );

        // Execute the liquidation (this is a simplified version)
        // In production, you might want to implement a more sophisticated execution mechanism
        _executeLiquidation(reqId, selectedLiquidator);
    }

    /**
     * @dev Execute the liquidation with the selected liquidator.
     * @param requestId The request ID.
     * @param liquidator The selected liquidator.
     */
    function _executeLiquidation(
        bytes32 requestId,
        address liquidator
    ) internal {
        LiquidationRequest storage request = liquidationRequests[requestId];

        // Check if liquidation is still valid (time-based MEV protection)
        require(
            block.timestamp >= request.timestamp + MIN_LIQUIDATION_DELAY,
            "Liquidation delay not met"
        );
        require(
            block.timestamp <= request.timestamp + MAX_LIQUIDATION_DELAY,
            "Liquidation window expired"
        );

        // Calculate seize tokens
        (uint256 error, uint256 seizeTokens) = peridottroller
            .liquidateCalculateSeizeTokens(
                request.pTokenBorrowed,
                request.pTokenCollateral,
                request.repayAmount
            );

        require(error == 0, "Seize calculation failed");

        emit LiquidationExecuted(
            requestId,
            request.borrower,
            liquidator,
            seizeTokens
        );

        // Note: In a production implementation, you would need to:
        // 1. Transfer tokens from the liquidator to repay the debt
        // 2. Transfer collateral tokens to the liquidator
        // 3. Handle the actual liquidation through the protocol
        // This is simplified for demonstration purposes
    }

    /**
     * @dev Get liquidation request details.
     * @param requestId The request ID.
     * @return The liquidation request details.
     */
    function getLiquidationRequest(
        bytes32 requestId
    ) external view returns (LiquidationRequest memory) {
        return liquidationRequests[requestId];
    }

    /**
     * @dev Get the number of registered liquidators.
     * @return The number of registered liquidators.
     */
    function getLiquidatorCount() external view returns (uint256) {
        return liquidatorList.length;
    }

    /**
     * @dev Authorize a caller to request liquidations.
     * @param caller The caller to authorize.
     * @param authorized Whether the caller is authorized.
     */
    function setAuthorizedCaller(
        address caller,
        bool authorized
    ) external onlyOwner {
        authorizedCallers[caller] = authorized;
    }

    /**
     * @dev Transfer ownership to a new address.
     * @param newOwner The new owner address.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner address");
        owner = newOwner;
    }

    /**
     * @dev Emergency function to cancel a liquidation request.
     * @param requestId The request ID to cancel.
     */
    function emergencyCancel(bytes32 requestId) external onlyOwner {
        delete liquidationRequests[requestId];
    }
}

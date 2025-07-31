// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IPaymaster} from "../lib/account-abstraction/contracts/interfaces/IPaymaster.sol";
import {UserOperationLib} from "../lib/account-abstraction/contracts/core/UserOperationLib.sol";
import {PackedUserOperation} from "../lib/account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {EntryPoint} from "../lib/account-abstraction/contracts/core/EntryPoint.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SimplePriceOracle} from "./SimplePriceOracle.sol";

interface ICompoundFork {
    function getUserTotalSuppliedValue(address user) external view returns (uint256);
    function getUserTokenSuppliedValue(address user) external view returns (uint256);
}

/**
 * @title TieredPaymaster
 * @dev An ERC-4337 Paymaster that sponsors transactions based on a user's supplied value in a protocol.
 * It uses a tiered quota system, charges a configurable premium, and is fully configurable by the owner.
 * This contract is designed to be upgradeable.
 */
contract TieredPaymaster is Initializable, IPaymaster, OwnableUpgradeable {
    // === Events ===
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event UserOpValidated(address indexed sender, uint256 quotaUsed, uint256 quotaAllowed);
    event TreasuryPaid(address indexed treasury, uint256 amount);
    event ConfigUpdated(string parameter, uint256 newValue);
    event TiersUpdated(uint256[] newThresholds, uint256[] newQuotas);

    // === Errors ===
    error NotFromEntryPoint();
    error NoContractDeploymentAllowed();
    error FreeTxQuotaExceeded();
    error MustPayPremiumGas();
    error InvalidPrice();
    error TreasuryTransferFailed();
    error InvalidArrayLength();

    // === State ===
    EntryPoint public entryPoint;
    ICompoundFork public compoundFork;
    SimplePriceOracle public priceOracle;
    address public nativeAssetWrapper; // e.g., WETH address for ETH price
    address public treasury;

    // User-specific data
    mapping(address => uint256) public userOpsUsed;
    mapping(address => uint256) public lastReset;

    // Configurable parameters
    uint256 public gasPremiumMultiplier; // e.g., 10 for a 10x premium
    uint256 public requiredFeeUSD; // e.g., 1e17 for $0.10
    uint256[] public percentageThresholds; // In bps, e.g., [1000, 500, 100] for 10%, 5%, 1%
    uint256[] public quotaTiers; // e.g., [100, 25, 10, 3]

    // Constants
    uint256 public constant MONTH = 30 days;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _entryPoint,
        address _compoundFork,
        address _priceOracle,
        address _treasury,
        address _nativeAssetWrapper,
        address _initialOwner
    ) public initializer {
        require(_entryPoint != address(0), "Invalid EntryPoint");
        require(_compoundFork != address(0), "Invalid CompoundFork");
        require(_priceOracle != address(0), "Invalid PriceOracle");
        require(_treasury != address(0), "Invalid Treasury");
        require(_nativeAssetWrapper != address(0), "Invalid NativeAssetWrapper");

        __Ownable_init(_initialOwner);

        entryPoint = EntryPoint(payable(_entryPoint));
        compoundFork = ICompoundFork(_compoundFork);
        priceOracle = SimplePriceOracle(_priceOracle);
        treasury = _treasury;
        nativeAssetWrapper = _nativeAssetWrapper;

        // Set default values
        gasPremiumMultiplier = 10;
        requiredFeeUSD = 1e17; // $0.10
        percentageThresholds = [1000, 500, 100]; // 10%, 5%, 1%
        quotaTiers = [100, 25, 10, 3]; // 100, 25, 10, 3 tx/month
    }

    /// @inheritdoc IPaymaster
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32,
        uint256 maxCost
    ) external override returns (bytes memory context, uint256 validationData) {
        if (msg.sender != address(entryPoint)) revert NotFromEntryPoint();
        if (userOp.initCode.length != 0) revert NoContractDeploymentAllowed();

        address sender = userOp.sender;

        // Check monthly quota without modifying state
        uint256 used = userOpsUsed[sender];
        if (block.timestamp - lastReset[sender] > MONTH) {
            used = 0;
        }

        uint256 allowed = getFreeQuota(sender);
        if (used >= allowed) revert FreeTxQuotaExceeded();

        // Get native asset price from the SimplePriceOracle
        uint256 nativePrice = priceOracle.assetPrices(nativeAssetWrapper);
        if (nativePrice == 0) revert InvalidPrice();

        // Calculate required minimum fee in wei
        uint256 requiredFeeWei = (requiredFeeUSD * 1e18) / nativePrice;
        if (maxCost < requiredFeeWei * gasPremiumMultiplier) revert MustPayPremiumGas();

        return (abi.encode(sender, requiredFeeWei, used, allowed), 0);
    }

    /// @inheritdoc IPaymaster
    function postOp(PostOpMode, bytes calldata context, uint256, uint256) external override {
        if (msg.sender != address(entryPoint)) revert NotFromEntryPoint();

        (address sender, uint256 baseCost, uint256 used, uint256 allowed) = abi.decode(context, (address, uint256, uint256, uint256));

        // Reset quota if a month has passed, otherwise increment
        if (block.timestamp - lastReset[sender] > MONTH) {
            userOpsUsed[sender] = 1;
            lastReset[sender] = block.timestamp;
        } else {
            userOpsUsed[sender] += 1;
        }
        emit UserOpValidated(sender, used + 1, allowed);

        // Distribute premium
        uint256 premiumCost = baseCost * gasPremiumMultiplier;
        uint256 treasuryCut = premiumCost / 2;

        if (treasuryCut > 0) {
            (bool sent, ) = payable(treasury).call{value: treasuryCut}("");
            if (!sent) revert TreasuryTransferFailed();
            emit TreasuryPaid(treasury, treasuryCut);
        }
    }

    /**
     * @notice Determines the user's monthly transaction quota based on their supplied assets.
     * @param user The address of the user.
     * @return The number of free transactions the user is allowed per month.
     */
    function getFreeQuota(address user) public view returns (uint256) {
        uint256 userTokenVal = compoundFork.getUserTokenSuppliedValue(user);
        uint256 userTotalVal = compoundFork.getUserTotalSuppliedValue(user);

        if (userTotalVal == 0) return quotaTiers[quotaTiers.length - 1];

        uint256 percentBps = userTokenVal * 10000 / userTotalVal;

        for (uint i = 0; i < percentageThresholds.length; i++) {
            if (percentBps >= percentageThresholds[i]) {
                return quotaTiers[i];
            }
        }
        return quotaTiers[quotaTiers.length - 1];
    }

    // === Admin Functions ===

    function setTreasury(address _newTreasury) external onlyOwner {
        require(_newTreasury != address(0), "Invalid Treasury");
        emit TreasuryUpdated(treasury, _newTreasury);
        treasury = _newTreasury;
    }

    function setPriceOracle(address _newOracle) external onlyOwner {
        require(_newOracle != address(0), "Invalid PriceOracle");
        emit OracleUpdated(address(priceOracle), _newOracle);
        priceOracle = SimplePriceOracle(_newOracle);
    }

    function setGasPremiumMultiplier(uint256 _newMultiplier) external onlyOwner {
        gasPremiumMultiplier = _newMultiplier;
        emit ConfigUpdated("GasPremiumMultiplier", _newMultiplier);
    }

    function setRequiredFeeUSD(uint256 _newFee) external onlyOwner {
        requiredFeeUSD = _newFee;
        emit ConfigUpdated("RequiredFeeUSD", _newFee);
    }

    function setTierConfig(uint256[] calldata _thresholds, uint256[] calldata _quotas) external onlyOwner {
        if (_thresholds.length != _quotas.length - 1) revert InvalidArrayLength();
        percentageThresholds = _thresholds;
        quotaTiers = _quotas;
        emit TiersUpdated(_thresholds, _quotas);
    }

    function withdraw(address to, uint256 amount) external onlyOwner {
        payable(to).transfer(amount);
    }

    receive() external payable {}
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {IsolatedMarginMath} from "./IsolatedMarginMath.sol";
import {IsolatedMarginTypes} from "./IsolatedMarginTypes.sol";
import {IIsolatedMarginConfig} from "./interfaces/IIsolatedMarginConfig.sol";

contract IsolatedMarginConfigUpgradeable is Initializable, OwnableUpgradeable, IIsolatedMarginConfig {
    uint256 public constant override BPS = 10_000;
    uint16 public constant MAX_OPEN_FEE_BPS = 100;
    uint16 public constant MAX_CLOSE_FEE_BPS = 100;
    uint16 public constant DEFAULT_FEE_IMMEDIATE_SHARE_BPS = 2_000;
    uint16 public constant MIN_FEE_IMMEDIATE_SHARE_BPS = 1_000;
    uint16 public constant MAX_FEE_IMMEDIATE_SHARE_BPS = 2_000;
    uint32 public constant DEFAULT_FEE_STREAM_DURATION = 7 days;
    uint32 public constant MIN_FEE_STREAM_DURATION = 1 days;
    uint32 public constant MAX_FEE_STREAM_DURATION = 30 days;
    uint256 public constant MIN_ACTION_DELAY = 1 hours;

    uint256 public actionDelay;
    bool public override opensPaused;

    uint16 public override openFeeBps;
    uint16 public override closeFeeBps;
    uint16 public override depositorShareBps;
    uint16 public override insuranceShareBps;
    uint16 public override treasuryShareBps;

    address public override insuranceFund;
    address public override treasury;
    address public override routerAdapter;
    address public override flashLoanProvider;

    mapping(bytes32 pair => IsolatedMarginTypes.PairRiskConfig) private _pairRisk;
    mapping(bytes32 actionId => uint256 executeAfter) public queuedActions;

    // Appended after the original mappings to preserve proxy storage layout. The boolean lets an
    // upgraded pre-streaming proxy use safe defaults until governance explicitly configures it.
    uint16 private _feeImmediateShareBps;
    uint32 private _feeStreamDuration;
    bool private _feeDistributionConfigured;

    event ActionQueued(bytes32 indexed actionId, uint256 executeAfter);
    event ActionCanceled(bytes32 indexed actionId);
    event ActionExecuted(bytes32 indexed actionId);
    event OpensPaused(bool paused);
    event FeesConfigured(
        uint16 openFeeBps,
        uint16 closeFeeBps,
        uint16 depositorShareBps,
        uint16 insuranceShareBps,
        uint16 treasuryShareBps
    );
    event FeeDistributionConfigured(uint16 immediateShareBps, uint32 streamDuration);
    event FeeRecipientsConfigured(address indexed insuranceFund, address indexed treasury);
    event ExecutionEndpointsConfigured(address indexed routerAdapter, address indexed flashLoanProvider);
    event PairRiskConfigured(bytes32 indexed pair, IsolatedMarginTypes.PairRiskConfig config);
    event ActionDelayConfigured(uint256 actionDelay);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        uint256 actionDelay_,
        address routerAdapter_,
        address flashLoanProvider_,
        address insuranceFund_,
        address treasury_
    ) external initializer {
        require(owner_ != address(0), "MarginConfig: zero owner");
        require(actionDelay_ >= MIN_ACTION_DELAY, "MarginConfig: delay too short");
        require(routerAdapter_.code.length > 0, "MarginConfig: router not contract");
        require(flashLoanProvider_.code.length > 0, "MarginConfig: lender not contract");
        require(insuranceFund_.code.length > 0, "MarginConfig: insurance not contract");
        __Ownable_init(owner_);

        actionDelay = actionDelay_;
        opensPaused = true;
        routerAdapter = routerAdapter_;
        flashLoanProvider = flashLoanProvider_;
        insuranceFund = insuranceFund_;
        treasury = treasury_;

        depositorShareBps = 5_000;
        insuranceShareBps = 5_000;
        _feeImmediateShareBps = DEFAULT_FEE_IMMEDIATE_SHARE_BPS;
        _feeStreamDuration = DEFAULT_FEE_STREAM_DURATION;
        _feeDistributionConfigured = true;

        emit ActionDelayConfigured(actionDelay_);
        emit OpensPaused(true);
        emit ExecutionEndpointsConfigured(routerAdapter_, flashLoanProvider_);
        emit FeeRecipientsConfigured(insuranceFund_, treasury_);
        emit FeesConfigured(0, 0, 5_000, 5_000, 0);
        emit FeeDistributionConfigured(DEFAULT_FEE_IMMEDIATE_SHARE_BPS, DEFAULT_FEE_STREAM_DURATION);
    }

    function feeImmediateShareBps() external view override returns (uint16) {
        return _feeDistributionConfigured ? _feeImmediateShareBps : DEFAULT_FEE_IMMEDIATE_SHARE_BPS;
    }

    function feeStreamDuration() external view override returns (uint32) {
        return _feeDistributionConfigured ? _feeStreamDuration : DEFAULT_FEE_STREAM_DURATION;
    }

    function pairKey(address marginPToken, address positionPToken, address debtPToken)
        public
        pure
        override
        returns (bytes32)
    {
        return keccak256(abi.encode(marginPToken, positionPToken, debtPToken));
    }

    function getPairRisk(address marginPToken, address positionPToken, address debtPToken)
        external
        view
        override
        returns (IsolatedMarginTypes.PairRiskConfig memory)
    {
        return _pairRisk[pairKey(marginPToken, positionPToken, debtPToken)];
    }

    function queueFees(
        uint16 openFeeBps_,
        uint16 closeFeeBps_,
        uint16 depositorShareBps_,
        uint16 insuranceShareBps_,
        uint16 treasuryShareBps_
    ) external onlyOwner returns (bytes32) {
        _validateFees(openFeeBps_, closeFeeBps_, depositorShareBps_, insuranceShareBps_, treasuryShareBps_);
        return _queue(
            keccak256(
                abi.encode("fees", openFeeBps_, closeFeeBps_, depositorShareBps_, insuranceShareBps_, treasuryShareBps_)
            )
        );
    }

    function setFees(
        uint16 openFeeBps_,
        uint16 closeFeeBps_,
        uint16 depositorShareBps_,
        uint16 insuranceShareBps_,
        uint16 treasuryShareBps_
    ) external onlyOwner {
        bytes32 actionId = keccak256(
            abi.encode("fees", openFeeBps_, closeFeeBps_, depositorShareBps_, insuranceShareBps_, treasuryShareBps_)
        );
        _consume(actionId);
        _validateFees(openFeeBps_, closeFeeBps_, depositorShareBps_, insuranceShareBps_, treasuryShareBps_);
        openFeeBps = openFeeBps_;
        closeFeeBps = closeFeeBps_;
        depositorShareBps = depositorShareBps_;
        insuranceShareBps = insuranceShareBps_;
        treasuryShareBps = treasuryShareBps_;
        emit FeesConfigured(openFeeBps_, closeFeeBps_, depositorShareBps_, insuranceShareBps_, treasuryShareBps_);
    }

    /// @notice Queues how the depositor portion of margin fees is split between immediate and streamed rewards.
    function queueFeeDistribution(uint16 immediateShareBps_, uint32 streamDuration_)
        external
        onlyOwner
        returns (bytes32)
    {
        _validateFeeDistribution(immediateShareBps_, streamDuration_);
        return _queue(keccak256(abi.encode("feeDistribution", immediateShareBps_, streamDuration_)));
    }

    function setFeeDistribution(uint16 immediateShareBps_, uint32 streamDuration_) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("feeDistribution", immediateShareBps_, streamDuration_));
        _consume(actionId);
        _validateFeeDistribution(immediateShareBps_, streamDuration_);
        _feeImmediateShareBps = immediateShareBps_;
        _feeStreamDuration = streamDuration_;
        _feeDistributionConfigured = true;
        emit FeeDistributionConfigured(immediateShareBps_, streamDuration_);
    }

    function queueFeeRecipients(address insuranceFund_, address treasury_) external onlyOwner returns (bytes32) {
        return _queue(keccak256(abi.encode("feeRecipients", insuranceFund_, treasury_)));
    }

    function setFeeRecipients(address insuranceFund_, address treasury_) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("feeRecipients", insuranceFund_, treasury_));
        _consume(actionId);
        _validateRecipients(insuranceFund_, treasury_);
        insuranceFund = insuranceFund_;
        treasury = treasury_;
        emit FeeRecipientsConfigured(insuranceFund_, treasury_);
    }

    function queueExecutionEndpoints(address routerAdapter_, address flashLoanProvider_)
        external
        onlyOwner
        returns (bytes32)
    {
        require(routerAdapter_.code.length > 0, "MarginConfig: router not contract");
        require(flashLoanProvider_.code.length > 0, "MarginConfig: lender not contract");
        return _queue(keccak256(abi.encode("endpoints", routerAdapter_, flashLoanProvider_)));
    }

    function setExecutionEndpoints(address routerAdapter_, address flashLoanProvider_) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("endpoints", routerAdapter_, flashLoanProvider_));
        _consume(actionId);
        require(routerAdapter_.code.length > 0, "MarginConfig: router not contract");
        require(flashLoanProvider_.code.length > 0, "MarginConfig: lender not contract");
        routerAdapter = routerAdapter_;
        flashLoanProvider = flashLoanProvider_;
        emit ExecutionEndpointsConfigured(routerAdapter_, flashLoanProvider_);
    }

    function disableExecutionEndpoints() external onlyOwner {
        opensPaused = true;
        routerAdapter = address(0);
        flashLoanProvider = address(0);
        emit OpensPaused(true);
        emit ExecutionEndpointsConfigured(address(0), address(0));
    }

    function queuePairRisk(
        address marginPToken,
        address positionPToken,
        address debtPToken,
        IsolatedMarginTypes.PairRiskConfig calldata config
    ) external onlyOwner returns (bytes32) {
        require(config.enabled, "MarginConfig: use disable");
        IsolatedMarginMath.validateRiskConfig(config);
        bytes32 pair = pairKey(marginPToken, positionPToken, debtPToken);
        return _queue(keccak256(abi.encode("pairRisk", pair, config)));
    }

    function setPairRisk(
        address marginPToken,
        address positionPToken,
        address debtPToken,
        IsolatedMarginTypes.PairRiskConfig calldata config
    ) external onlyOwner {
        require(config.enabled, "MarginConfig: use disable");
        bytes32 pair = pairKey(marginPToken, positionPToken, debtPToken);
        bytes32 actionId = keccak256(abi.encode("pairRisk", pair, config));
        _consume(actionId);
        IsolatedMarginMath.validateRiskConfig(config);
        _pairRisk[pair] = config;
        emit PairRiskConfigured(pair, config);
    }

    /// @notice Risk-increasing operations stop immediately; close/repay paths are unaffected.
    function disablePair(address marginPToken, address positionPToken, address debtPToken) external onlyOwner {
        bytes32 pair = pairKey(marginPToken, positionPToken, debtPToken);
        _pairRisk[pair].enabled = false;
        emit PairRiskConfigured(pair, _pairRisk[pair]);
    }

    function pauseOpens() external onlyOwner {
        opensPaused = true;
        emit OpensPaused(true);
    }

    function queueUnpauseOpens() external onlyOwner returns (bytes32) {
        return _queue(keccak256("unpauseOpens"));
    }

    function unpauseOpens() external onlyOwner {
        bytes32 actionId = keccak256("unpauseOpens");
        _consume(actionId);
        require(routerAdapter.code.length > 0, "MarginConfig: router unavailable");
        require(flashLoanProvider.code.length > 0, "MarginConfig: lender unavailable");
        opensPaused = false;
        emit OpensPaused(false);
    }

    function queueActionDelay(uint256 actionDelay_) external onlyOwner returns (bytes32) {
        require(actionDelay_ >= MIN_ACTION_DELAY, "MarginConfig: delay too short");
        return _queue(keccak256(abi.encode("actionDelay", actionDelay_)));
    }

    function setActionDelay(uint256 actionDelay_) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("actionDelay", actionDelay_));
        _consume(actionId);
        require(actionDelay_ >= MIN_ACTION_DELAY, "MarginConfig: delay too short");
        actionDelay = actionDelay_;
        emit ActionDelayConfigured(actionDelay_);
    }

    function cancelAction(bytes32 actionId) external onlyOwner {
        require(queuedActions[actionId] != 0, "MarginConfig: not queued");
        delete queuedActions[actionId];
        emit ActionCanceled(actionId);
    }

    function _validateFees(
        uint16 openFeeBps_,
        uint16 closeFeeBps_,
        uint16 depositorShareBps_,
        uint16 insuranceShareBps_,
        uint16 treasuryShareBps_
    ) internal view {
        require(openFeeBps_ <= MAX_OPEN_FEE_BPS, "MarginConfig: open fee too high");
        require(closeFeeBps_ <= MAX_CLOSE_FEE_BPS, "MarginConfig: close fee too high");
        require(
            uint256(depositorShareBps_) + insuranceShareBps_ + treasuryShareBps_ == BPS, "MarginConfig: invalid split"
        );
        _validateRecipientsForShares(insuranceFund, treasury, insuranceShareBps_, treasuryShareBps_);
    }

    function _validateFeeDistribution(uint16 immediateShareBps_, uint32 streamDuration_) internal pure {
        require(
            immediateShareBps_ >= MIN_FEE_IMMEDIATE_SHARE_BPS && immediateShareBps_ <= MAX_FEE_IMMEDIATE_SHARE_BPS,
            "MarginConfig: invalid immediate share"
        );
        require(
            streamDuration_ >= MIN_FEE_STREAM_DURATION && streamDuration_ <= MAX_FEE_STREAM_DURATION,
            "MarginConfig: invalid stream duration"
        );
    }

    function _validateRecipients(address insuranceFund_, address treasury_) internal view {
        _validateRecipientsForShares(insuranceFund_, treasury_, insuranceShareBps, treasuryShareBps);
    }

    function _validateRecipientsForShares(address insuranceFund_, address treasury_, uint16, uint16 treasuryShareBps_)
        internal
        view
    {
        // Depositor fees fall back to insurance while a pToken pool has no shares,
        // so insurance must remain a live recipient even when its explicit split is zero.
        require(insuranceFund_.code.length > 0, "MarginConfig: invalid insurance");
        require(treasuryShareBps_ == 0 || treasury_ != address(0), "MarginConfig: zero treasury");
    }

    function _queue(bytes32 actionId) internal returns (bytes32) {
        require(queuedActions[actionId] == 0, "MarginConfig: already queued");
        uint256 executeAfter = block.timestamp + actionDelay;
        queuedActions[actionId] = executeAfter;
        emit ActionQueued(actionId, executeAfter);
        return actionId;
    }

    function _consume(bytes32 actionId) internal {
        uint256 executeAfter = queuedActions[actionId];
        require(executeAfter != 0, "MarginConfig: not queued");
        require(block.timestamp >= executeAfter, "MarginConfig: not ready");
        delete queuedActions[actionId];
        emit ActionExecuted(actionId);
    }

    uint256[39] private __gap;
}

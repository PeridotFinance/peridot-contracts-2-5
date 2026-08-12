// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {IsolatedMarginAccount} from "./IsolatedMarginAccount.sol";

/**
 * @notice Deploys one minimal custody account for each isolated margin position.
 * @dev The executor can be configured only once, permanently binding every clone
 *      produced by this factory to one executor proxy.
 */
contract IsolatedMarginAccountFactory {
    address public immutable configurator;
    IsolatedMarginAccount public immutable implementation;
    address public executor;

    event ExecutorConfigured(address indexed executor);
    event AccountCreated(uint256 indexed positionId, address indexed account, address indexed owner);

    constructor(address configurator_) {
        require(configurator_ != address(0), "AccountFactory: zero configurator");
        configurator = configurator_;
        implementation = new IsolatedMarginAccount();
    }

    function setExecutor(address executor_) external {
        require(msg.sender == configurator, "AccountFactory: not configurator");
        require(executor == address(0), "AccountFactory: executor configured");
        require(executor_.code.length > 0, "AccountFactory: invalid executor");
        executor = executor_;
        emit ExecutorConfigured(executor_);
    }

    function createAccount(
        address riskEngine,
        address owner,
        uint256 positionId,
        address marginPToken,
        address positionPToken,
        address debtPToken
    ) external returns (address account) {
        address executor_ = executor;
        require(msg.sender == executor_ && executor_ != address(0), "AccountFactory: not executor");
        account = Clones.clone(address(implementation));
        IsolatedMarginAccount(account)
            .initialize(executor_, riskEngine, owner, positionId, marginPToken, positionPToken, debtPToken);
        emit AccountCreated(positionId, account, owner);
    }
}

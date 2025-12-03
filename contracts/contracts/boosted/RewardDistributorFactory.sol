// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import "./RewardDistributor.sol";

/**
 * @title RewardDistributorFactory
 * @notice Simple factory to deploy RewardDistributor instances.
 */
contract RewardDistributorFactory {
    event DistributorCreated(address indexed distributor, address rewardToken, address market);

    function create(address rewardToken, address market) external returns (address) {
        RewardDistributor dist = new RewardDistributor(IERC20(rewardToken), market, msg.sender);
        emit DistributorCreated(address(dist), rewardToken, market);
        return address(dist);
    }
}

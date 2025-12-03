// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title RewardDistributorMulti
 * @notice Multi-token, multi-market reward distributor. Each (market, rewardToken) pair maintains its own index.
 *         Operators push rewards in via addReward(market, rewardToken, amount), indexes update, and users claim
 *         their accrued amounts based on their balance in that market.
 */
contract RewardDistributorMulti is Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant INDEX_SCALE = 1e36;

    struct MarketRewardState {
        uint256 index; // global index
        bool initialized;
    }

    // market => rewardToken => state
    mapping(address => mapping(address => MarketRewardState)) public marketRewardState;
    // market => rewardToken => user => index
    mapping(address => mapping(address => mapping(address => uint256))) public userRewardIndex;
    // market => rewardToken => user => accrued
    mapping(address => mapping(address => mapping(address => uint256))) public accrued;

    // ERC20 selectors for totalSupply / balanceOf
    bytes4 private constant TOTAL_SUPPLY_SELECTOR = bytes4(keccak256("totalSupply()"));
    bytes4 private constant BALANCE_OF_SELECTOR = bytes4(keccak256("balanceOf(address)"));

    event RewardAdded(address indexed market, address indexed rewardToken, uint256 amount, uint256 newIndex);
    event RewardClaimed(address indexed user, address indexed market, address indexed rewardToken, uint256 amount);

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Push rewards for a given market/rewardToken and update the index.
    function addReward(address market, address rewardToken, uint256 amount) external onlyOwner {
        require(market != address(0) && rewardToken != address(0), "invalid");
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);

        MarketRewardState storage st = marketRewardState[market][rewardToken];
        if (!st.initialized) {
            st.initialized = true;
            st.index = INDEX_SCALE;
        }

        uint256 supply = _totalSupply(market);
        if (supply == 0 || amount == 0) {
            emit RewardAdded(market, rewardToken, amount, st.index);
            return;
        }
        uint256 deltaIndex = (amount * INDEX_SCALE) / supply;
        st.index += deltaIndex;
        emit RewardAdded(market, rewardToken, amount, st.index);
    }

    /// @notice Accrue rewards for a user for a list of reward tokens on a given market.
    function accrue(address market, address user, address[] calldata rewardTokens) public {
        uint256 userBal = _balanceOf(market, user);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address rToken = rewardTokens[i];
            MarketRewardState storage st = marketRewardState[market][rToken];
            if (!st.initialized) continue;
            uint256 globalIdx = st.index;
            uint256 userIdx = userRewardIndex[market][rToken][user];
            if (userIdx == 0) {
                userIdx = INDEX_SCALE;
            }
            uint256 delta = globalIdx - userIdx;
            if (delta > 0 && userBal > 0) {
                uint256 amt = (userBal * delta) / INDEX_SCALE;
                accrued[market][rToken][user] += amt;
            }
            userRewardIndex[market][rToken][user] = globalIdx;
        }
    }

    /// @notice Claim accrued rewards for the caller for a given market and set of reward tokens.
    function claim(address market, address[] calldata rewardTokens) external {
        accrue(market, msg.sender, rewardTokens);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address rToken = rewardTokens[i];
            uint256 amt = accrued[market][rToken][msg.sender];
            if (amt == 0) continue;
            accrued[market][rToken][msg.sender] = 0;
            IERC20(rToken).safeTransfer(msg.sender, amt);
            emit RewardClaimed(msg.sender, market, rToken, amt);
        }
    }

    function _totalSupply(address market) internal view returns (uint256) {
        (bool ok, bytes memory data) = market.staticcall(abi.encodeWithSelector(TOTAL_SUPPLY_SELECTOR));
        require(ok && data.length >= 32, "supply call failed");
        return abi.decode(data, (uint256));
    }

    function _balanceOf(address market, address user) internal view returns (uint256) {
        (bool ok, bytes memory data) = market.staticcall(abi.encodeWithSelector(BALANCE_OF_SELECTOR, user));
        require(ok && data.length >= 32, "balance call failed");
        return abi.decode(data, (uint256));
    }
}

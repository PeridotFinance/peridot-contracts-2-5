// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title RewardDistributor
 * @notice Simple index-based reward distributor for a single market. Rewards are pushed in by an operator
 *         (e.g., pToken harvest), indexed over totalSupply, and users can claim their accrued balance.
 */
contract RewardDistributor is Ownable {
    using SafeERC20 for IERC20;

    /// @notice Token being distributed as rewards.
    IERC20 public immutable rewardToken;

    /// @notice Market whose totalSupply/balances are used for indexing.
    address public immutable market;

    /// @notice Total supply function signature hash for the market.
    bytes4 private constant TOTAL_SUPPLY_SELECTOR = bytes4(keccak256("totalSupply()"));
    /// @notice BalanceOf function signature hash for the market.
    bytes4 private constant BALANCE_OF_SELECTOR = bytes4(keccak256("balanceOf(address)"));

    uint256 public constant INDEX_SCALE = 1e36;
    uint256 public rewardIndex; // global index
    mapping(address => uint256) public userRewardIndex;
    mapping(address => uint256) public accrued;

    event RewardsAdded(uint256 amount, uint256 newIndex);
    event Claimed(address indexed user, uint256 amount);

    constructor(IERC20 rewardToken_, address market_, address initialOwner) Ownable(initialOwner) {
        rewardToken = rewardToken_;
        market = market_;
        rewardIndex = INDEX_SCALE;
    }

    /// @notice Push rewards into the distributor and update the global index.
    function addReward(uint256 amount) external onlyOwner {
        uint256 supply = _totalSupply();
        if (supply == 0 || amount == 0) {
            // If no supply, just hold rewards; they'll be indexed when supply > 0.
            rewardToken.safeTransferFrom(msg.sender, address(this), amount);
            emit RewardsAdded(0, rewardIndex);
            return;
        }
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 deltaIndex = (amount * INDEX_SCALE) / supply;
        rewardIndex += deltaIndex;
        emit RewardsAdded(amount, rewardIndex);
    }

    /// @notice Accrue rewards to a user (should be called before balance changes in the market).
    function accrue(address user) public {
        uint256 userIdx = userRewardIndex[user];
        uint256 globalIdx = rewardIndex;
        if (userIdx == 0) {
            userIdx = INDEX_SCALE;
        }
        uint256 delta = globalIdx - userIdx;
        if (delta > 0) {
            uint256 bal = _balanceOf(user);
            uint256 amt = (bal * delta) / INDEX_SCALE;
            accrued[user] += amt;
            userRewardIndex[user] = globalIdx;
        }
    }

    /// @notice Claim accrued rewards.
    function claim() external {
        accrue(msg.sender);
        uint256 amt = accrued[msg.sender];
        if (amt == 0) return;
        accrued[msg.sender] = 0;
        rewardToken.safeTransfer(msg.sender, amt);
        emit Claimed(msg.sender, amt);
    }

    function _totalSupply() internal view returns (uint256) {
        (bool ok, bytes memory data) = market.staticcall(abi.encodeWithSelector(TOTAL_SUPPLY_SELECTOR));
        require(ok && data.length >= 32, "supply call failed");
        return abi.decode(data, (uint256));
    }

    function _balanceOf(address user) internal view returns (uint256) {
        (bool ok, bytes memory data) = market.staticcall(abi.encodeWithSelector(BALANCE_OF_SELECTOR, user));
        require(ok && data.length >= 32, "balance call failed");
        return abi.decode(data, (uint256));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/boosted/RewardDistributorMulti.sol";

contract RewardDistributorMultiTest is Test {
    RewardDistributorMulti internal dist;
    MockToken internal reward;
    MockToken internal marketToken;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        reward = new MockToken("Reward", "R", 18);
        marketToken = new MockToken("mToken", "mT", 18);
        dist = new RewardDistributorMulti(address(this));

        // Setup balances to simulate supply
        marketToken.mint(alice, 100e18);
        marketToken.mint(bob, 100e18);
        vm.label(address(dist), "RewardDistributorMulti");
    }

    function testAddRewardAndClaim() public {
        // totalSupply = 200e18 (alice + bob)
        // alice stake: 100e18
        // reward: 200 tokens -> index increment = 200 * 1e36 / 200e18 = 1e18
        reward.mint(address(this), 200e18);
        reward.approve(address(dist), 200e18);
        dist.addReward(address(marketToken), address(reward), 200e18);

        address[] memory rts = new address[](1);
        rts[0] = address(reward);

        vm.prank(alice);
        dist.claim(address(marketToken), rts);

        // Alice should get ~100e18 reward
        assertEq(reward.balanceOf(alice), 100e18);
    }
}

contract MockToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _transfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amt, "allow");
        allowance[from][msg.sender] = allowed - amt;
        _transfer(from, to, amt);
        return true;
    }

    function totalSupply() external view returns (uint256) {
        // For simplicity in test: sum balances of alice and bob only
        return balanceOf[address(0xA11CE)] + balanceOf[address(0xB0B)];
    }

    function _transfer(address from, address to, uint256 amt) internal {
        uint256 bal = balanceOf[from];
        require(bal >= amt, "bal");
        balanceOf[from] = bal - amt;
        balanceOf[to] += amt;
    }
}

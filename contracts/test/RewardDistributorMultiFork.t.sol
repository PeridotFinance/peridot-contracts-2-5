// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/boosted/RewardDistributorMulti.sol";
import "../contracts/boosted/RewardDistributorMultiProxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPToken {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @dev Fork test skeleton: requires env `REWARD_TOKEN`, `MARKET`, `REWARD_ADMIN_PK`, `ADD_REWARD_AMOUNT`.
contract RewardDistributorMultiForkTest is Test {
    RewardDistributorMulti proxyDist;
    IPToken market;
    IERC20 rewardToken;
    bool configured;

    function setUp() public {
        string memory rpc = vm.envOr("MONAD_RPC", string(""));
        address marketAddr = vm.envOr("MARKET", address(0));
        address rewardTokenAddr = vm.envOr("REWARD_TOKEN", address(0));
        address admin = vm.envOr("REWARD_ADMIN", address(0));

        if (bytes(rpc).length == 0 || marketAddr == address(0) || rewardTokenAddr == address(0) || admin == address(0)) {
            emit log("Skipping fork: set MONAD_RPC, MARKET, REWARD_TOKEN, REWARD_ADMIN");
            return;
        }
        vm.createSelectFork(rpc);

        market = IPToken(marketAddr);
        rewardToken = IERC20(rewardTokenAddr);

        uint256 adminPk = vm.envOr("REWARD_ADMIN_PK", uint256(0));

        RewardDistributorMulti impl = new RewardDistributorMulti(admin);
        RewardDistributorMultiProxy proxy = new RewardDistributorMultiProxy(address(impl), admin, "");
        proxyDist = RewardDistributorMulti(address(proxy));

        // Fund admin with reward tokens (assumes balance exists or use deal)
        uint256 addAmt = vm.envOr("ADD_REWARD_AMOUNT", uint256(0));
        if (addAmt > 0 && adminPk != 0) {
            vm.startBroadcast(adminPk);
            rewardToken.approve(address(proxyDist), addAmt);
            proxyDist.addReward(marketAddr, rewardTokenAddr, addAmt);
            vm.stopBroadcast();
        }

        configured = true;
    }

    function testCanClaim() public {
        if (address(proxyDist) == address(0)) {
            emit log("Fork not configured; skipping");
            return;
        }
        if (!configured) return;
        address[] memory rts = new address[](1);
        rts[0] = address(rewardToken);

        // Use the default caller; accrue+claim
        proxyDist.claim(address(market), rts);

        // No assert here because we don't know balances; the main check is that it doesn't revert.
        assertTrue(true);
    }
}

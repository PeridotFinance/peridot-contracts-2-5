// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {Peridottroller} from "../../contracts/Peridottroller.sol";

/**
 * @notice TEST-ONLY PROTOTYPE (no production src/ change). Shows the constructor change that would let the Avalanche controller wrapper run
 *         WITHOUT a reward token, as an explicit OPT-IN: the default behaviour of `PeridottrollerAvalanche` (the token must be an existing
 *         contract, `address(0)` is refused) is preserved unless the deployer passes `allowNoRewardToken_ = true` TOGETHER WITH
 *         `peridotToken_ = address(0)`. There is no silent fallback: `address(0)` without the flag reverts, a non-zero address without
 *         code reverts regardless of the flag, and a real token behaves exactly as before.
 *
 * With no token, `getPeridotAddress()` is address(0): the only token-touching entry points (`claimPeridot`, admin `_grantPeridot`) revert,
 * which is harmless when all reward speeds are zero; no lending path reads the token (shown in AvalancheCashOnlyRewardTokenIndependenceFork).
 * This prototype omits the borrow cash floor of the production wrapper: it prototypes the constructor/token logic only.
 */
contract PeridottrollerAvalancheOptionalRewardTokenPrototype is Peridottroller {
    uint256 private constant AVALANCHE_CHAIN_ID = 43_114;

    address public immutable peridotToken;
    bool public immutable noRewardToken;

    constructor(address peridotToken_, bool allowNoRewardToken_) {
        require(block.chainid == AVALANCHE_CHAIN_ID, "AvalancheController: Avalanche only");
        if (peridotToken_ == address(0)) {
            require(allowNoRewardToken_, "AvalancheController: token not contract (explicit opt-in required for no reward token)");
        } else {
            require(peridotToken_.code.length > 0, "AvalancheController: token not contract");
        }
        peridotToken = peridotToken_;
        noRewardToken = peridotToken_ == address(0);
    }

    function getPeridotAddress() public view override returns (address) {
        return peridotToken;
    }
}

// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {Peridottroller} from "./Peridottroller.sol";

/**
 * @notice Robinhood Chain Peridottroller implementation with an explicit PERIDOT token.
 * @dev The token address is immutable in implementation bytecode and is therefore available
 *      when this contract is used behind Unitroller through delegatecall.
 *
 *      The chain guard is deliberate. This implementation backs markets whose underlying is a
 *      tokenized equity priced by a feed that only updates while its market is open, so the
 *      risk parameters and oracle staleness policy chosen for Robinhood Chain must not be
 *      reachable from a deployment on any other chain.
 */
contract PeridottrollerRobinhood is Peridottroller {
    uint256 private constant ROBINHOOD_CHAIN_ID = 4663;

    address public immutable peridotToken;

    constructor(address peridotToken_) {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RobinhoodController: Robinhood only");
        require(peridotToken_.code.length > 0, "RobinhoodController: token not contract");
        peridotToken = peridotToken_;
    }

    function getPeridotAddress() public view override returns (address) {
        return peridotToken;
    }
}

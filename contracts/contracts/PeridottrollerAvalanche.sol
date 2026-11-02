// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {Peridottroller} from "./Peridottroller.sol";

/**
 * @notice Avalanche C-Chain mainnet Peridottroller implementation with an explicit PERIDOT token.
 * @dev Mirror of `PeridottrollerAvalancheFuji` with the mainnet chain id. The token address is
 *      immutable bytecode so it is available behind Unitroller through delegatecall. Added for the
 *      handoff-09 fork checkpoint; it is NOT a deployment authorization.
 */
contract PeridottrollerAvalanche is Peridottroller {
    uint256 private constant AVALANCHE_CHAIN_ID = 43_114;

    address public immutable peridotToken;

    constructor(address peridotToken_) {
        require(block.chainid == AVALANCHE_CHAIN_ID, "AvalancheController: Avalanche only");
        require(peridotToken_.code.length > 0, "AvalancheController: token not contract");
        peridotToken = peridotToken_;
    }

    function getPeridotAddress() public view override returns (address) {
        return peridotToken;
    }
}

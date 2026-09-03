// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {Peridottroller} from "./Peridottroller.sol";

/**
 * @notice Fuji-only Peridottroller implementation with an explicit testnet PERIDOT token.
 * @dev The token address is immutable in implementation bytecode and is therefore available
 *      when this contract is used behind Unitroller through delegatecall.
 */
contract PeridottrollerAvalancheFuji is Peridottroller {
    uint256 private constant AVALANCHE_FUJI_CHAIN_ID = 43_113;

    address public immutable peridotToken;

    constructor(address peridotToken_) {
        require(block.chainid == AVALANCHE_FUJI_CHAIN_ID, "FujiController: Fuji only");
        require(peridotToken_.code.length > 0, "FujiController: token not contract");
        peridotToken = peridotToken_;
    }

    function getPeridotAddress() public view override returns (address) {
        return peridotToken;
    }
}

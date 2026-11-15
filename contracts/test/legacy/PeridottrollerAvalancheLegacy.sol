// FROZEN COPY of contracts/PeridottrollerAvalanche.sol as of commit 3764e3ff (before the borrow cash floor). TEST ONLY: differential / upgrade tests. Never deploy.
// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {Peridottroller} from "../../contracts/Peridottroller.sol";

/**
 * @notice Avalanche C-Chain mainnet Peridottroller implementation with an explicit PERIDOT token.
 * @dev Mirror of `PeridottrollerAvalancheFuji` with the mainnet chain id. The token address is
 *      immutable bytecode so it is available behind Unitroller through delegatecall. Added for the
 *      handoff-09 fork checkpoint; it is NOT a deployment authorization.
 */
contract PeridottrollerAvalancheLegacy is Peridottroller {
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

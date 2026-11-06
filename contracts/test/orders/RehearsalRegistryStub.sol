// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IMarginCloseAdapter} from "../../contracts/margin/orders/IMarginOrderRegistry.sol";

/// @notice REHEARSAL ONLY, not a registry. It follows the SPEC's deployment convention (no-arg constructor, initialize
/// (adapter, admin), OZ 5 transparent proxy) so the Robinhood deploy script and timelock pair can be rehearsed before
/// the real registry implementation arrives. It has no orders, triggers or checks.
contract RehearsalRegistryStub is Initializable {
    IMarginCloseAdapter public adapter;
    address public admin;

    constructor() {
        _disableInitializers();
    }

    function initialize(IMarginCloseAdapter adapter_, address admin_) external initializer {
        adapter = adapter_;
        admin = admin_;
    }

    /// @dev Stands in for executeOrder step 6: a full close at the oracle price.
    function closeAtOracle(uint256 positionId, uint16 maxSlippageBps) external returns (uint256) {
        (uint256 price, bool ok) = adapter.oraclePriceE18(positionId);
        require(ok, "ORACLE");
        return adapter.closeFor(positionId, adapter.positionOwner(positionId), 10_000, price, maxSlippageBps, "");
    }
}

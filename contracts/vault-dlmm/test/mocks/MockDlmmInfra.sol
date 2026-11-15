// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice DLMMFactory stand-in: `getLBPairInformation(tokenA, tokenB, binStep)` (order-insensitive, like the verified factory).
contract MockDlmmFactory {
    struct LBPairInformation {
        uint16 binStep;
        address LBPair;
        bool createdByOwner;
        bool ignoredForRouting;
    }

    mapping(bytes32 => LBPairInformation) private _info;

    function setPair(address tokenA, address tokenB, uint16 binStep, address pair) external {
        _info[_key(tokenA, tokenB, binStep)] = LBPairInformation(binStep, pair, false, false);
    }

    function getLBPairInformation(address tokenA, address tokenB, uint256 binStep) external view returns (LBPairInformation memory) {
        return _info[_key(tokenA, tokenB, uint16(binStep))];
    }

    function _key(address a, address b, uint16 step) private pure returns (bytes32) {
        (address x, address y) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encode(x, y, step));
    }
}

/// @notice Pharaoh voter stand-in (the rewarder's owner): router authorisation, anti-sybil switch and threshold, the rewarder beacon.
contract MockDlmmVoter {
    mapping(address => bool) public isAuthorizedDLMMManager;
    address public dlmmRewarderFactory;
    bool public isAntiSybilEnabled = true;
    uint256 public thresholdForGauge = 111;

    function setManager(address m, bool ok) external {
        isAuthorizedDLMMManager[m] = ok;
    }

    function setBeacon(address b) external {
        dlmmRewarderFactory = b;
    }

    function timeThresholdForGauge(address) external view returns (uint256) {
        return thresholdForGauge;
    }
}

/// @notice Two implementations with DIFFERENT runtime code (hence different codehash), standing for the beacon implementation before and after an accessHub upgrade.
contract MockRewarderImplA {
    function version() external pure returns (uint256) {
        return 1;
    }
}

contract MockRewarderImplB {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @notice `DLMMRewarderFactory` (the beacon): `implementation()` is what the rewarder proxies delegate to; `getRewarder(pool)` the registry. `setImplementation` = the accessHub upgrade.
contract MockRewarderBeacon {
    address public implementation;
    mapping(address => address) public getRewarder;

    constructor(address impl) {
        implementation = impl;
    }

    function setImplementation(address impl) external {
        implementation = impl;
    }

    function setRewarder(address pool, address r) external {
        getRewarder[pool] = r;
    }
}

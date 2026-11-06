// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @notice TEST-ONLY mocks used by the operator monitor's fork tests (operator/test/fork). They are etched over the real Chainlink feeds and
 *         the real Uniswap V3 WAVAX/USDC 0.05% pool of a LOCAL anvil fork, so that the monitor can be driven through the treasury truth table
 *         with the same price moves the Foundry test makes (`vm.mockCall` there, `anvil_setCode` here). Not deployed anywhere.
 */
contract MonitorMockFeed {
    int256 public answer;
    uint256 public updatedAt;

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "MOCK / USD";
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1000, answer, updatedAt, updatedAt, 1000);
    }
}

/// @dev Reports a constant mean tick over any `observe([1800, 0])` window and a settable liquidity. token0 = WAVAX, token1 = USDC, fee 500.
contract MonitorMockPool {
    int56 public meanTick;
    uint128 public liquidityValue;
    bool public observeReverts;

    function set(int56 meanTick_, uint128 liquidity_, bool observeReverts_) external {
        meanTick = meanTick_;
        liquidityValue = liquidity_;
        observeReverts = observeReverts_;
    }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory ticks, uint160[] memory spl) {
        require(!observeReverts, "OLD");
        ticks = new int56[](secondsAgos.length);
        spl = new uint160[](secondsAgos.length);
        // cumulative(t) = meanTick * (T0 - secondsAgo): the difference over a window is meanTick * window
        for (uint256 i; i < secondsAgos.length; ++i) {
            ticks[i] = meanTick * (int56(int256(uint256(1_000_000))) - int56(uint56(secondsAgos[i])));
        }
    }

    function liquidity() external view returns (uint128) {
        return liquidityValue;
    }

    function token0() external pure returns (address) {
        return 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7; // WAVAX
    }

    function token1() external pure returns (address) {
        return 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E; // USDC
    }

    function fee() external pure returns (uint24) {
        return 500;
    }
}

// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import "../contracts/SimplePriceOracle.sol";
import "../contracts/Peridottroller.sol";
import "../contracts/PToken.sol";
import "../contracts/PErc20.sol";

contract CheckOraclePrices is Script {
    // Update these with your deployed addresses
    address constant ORACLE_ADDRESS =
        0xeAEdaF63CbC1d00cB6C14B5c4DE161d68b7C63A0;
    address constant COMPTROLLER_ADDRESS =
        0xa41D586530BC7BC872095950aE03a780d5114445;

    // Add your deployed pToken addresses here
    address constant PUSDC_ADDRESS = 0xf817257fed379853cDe0fa4F97AB987181B1E5Ea; // Update with actual
    address constant PUSDT_ADDRESS = 0x88b8E2161DEDC77EF4ab7585569D2415a1C1055D; // Update when deployed

    SimplePriceOracle oracle;
    Peridottroller comptroller;

    function run() external {
        oracle = SimplePriceOracle(ORACLE_ADDRESS);
        comptroller = Peridottroller(COMPTROLLER_ADDRESS);

        console.log("=== ORACLE PRICE CHECK REPORT ===");
        console.log("Oracle Address:", ORACLE_ADDRESS);
        console.log("Comptroller Address:", COMPTROLLER_ADDRESS);
        console.log("Block Number:", block.number);
        console.log("Block Timestamp:", block.timestamp);
        console.log("");

        // Test 1: Check oracle configuration
        _checkOracleConfig();

        // Test 2: Check pToken prices (if deployed)
        _checkPTokenPrices();

        // Test 3: Check direct asset prices
        _checkDirectAssetPrices();

        // Test 4: Check Chainlink integration
        _checkChainlinkIntegration();

        // Test 5: Test price staleness detection
        _checkPriceStaleness();

        // Test 6: Verify comptroller integration
        _checkComptrollerIntegration();

        console.log("=== PRICE CHECK COMPLETE ===");
    }

    function _checkOracleConfig() internal view {
        console.log("--- ORACLE CONFIGURATION ---");

        try oracle.chainlinkPriceStaleThreshold() returns (uint threshold) {
            console.log("Stale Threshold:", threshold, "seconds");
            console.log("Stale Threshold (hours):", threshold / 3600);
        } catch {
            console.log("ERROR: Could not get stale threshold");
        }

        console.log("");
    }

    function _checkPTokenPrices() internal view {
        console.log("--- PTOKEN PRICES ---");

        if (PUSDC_ADDRESS != address(0)) {
            _checkSinglePTokenPrice("pUSDC", PUSDC_ADDRESS);
        }

        if (PUSDT_ADDRESS != address(0)) {
            _checkSinglePTokenPrice("pUSDT", PUSDT_ADDRESS);
        }

        console.log("");
    }

    function _checkSinglePTokenPrice(
        string memory name,
        address pTokenAddress
    ) internal view {
        console.log("Checking", name, "at", pTokenAddress);

        try oracle.getUnderlyingPrice(PToken(pTokenAddress)) returns (
            uint price
        ) {
            console.log("  Price (raw mantissa):", price);
            console.log("  Price (USD, 6 decimals):", price / 1e12);
            console.log("  Price (formatted):", _formatPrice(price));

            // Get underlying token info
            try PErc20(pTokenAddress).underlying() returns (
                address underlying
            ) {
                console.log("  Underlying token:", underlying);

                // Check if this token has a Chainlink feed
                try oracle.getAggregator(underlying) returns (
                    address aggregator
                ) {
                    if (aggregator != address(0)) {
                        console.log("  Chainlink aggregator:", aggregator);
                        _checkChainlinkFeedData(underlying, aggregator);
                    } else {
                        console.log("  No Chainlink feed - using manual price");
                    }
                } catch {
                    console.log("  Could not check aggregator");
                }
            } catch {
                console.log("  Could not get underlying token");
            }
        } catch {
            console.log("  ERROR: Could not get price for", name);
        }

        console.log("");
    }

    function _checkDirectAssetPrices() internal view {
        console.log("--- DIRECT ASSET PRICES ---");

        // Test your actual token addresses
        address[] memory testAssets = new address[](3);
        string[] memory testNames = new string[](3);

        testAssets[0] = 0x88b8E2161DEDC77EF4ab7585569D2415a1C1055D; // Your Mock USDT
        testNames[0] = "Mock USDT";

        testAssets[1] = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE; // ETH sentinel
        testNames[1] = "ETH";

        testAssets[2] = address(0x1234567890123456789012345678901234567890); // Random address
        testNames[2] = "Unknown Token";

        for (uint i = 0; i < testAssets.length; i++) {
            _checkDirectAssetPrice(testNames[i], testAssets[i]);
        }

        console.log("");
    }

    function _checkDirectAssetPrice(
        string memory name,
        address asset
    ) internal view {
        console.log("Checking direct price for", name, "at", asset);

        try oracle.assetPrices(asset) returns (uint price) {
            if (price > 0) {
                console.log("  Direct price:", price);
                console.log("  Formatted price:", _formatPrice(price));
            } else {
                console.log("  No price set");
            }
        } catch {
            console.log("  ERROR: Could not get direct price");
        }

        // Check if it has a Chainlink feed
        try oracle.getAggregator(asset) returns (address aggregator) {
            if (aggregator != address(0)) {
                console.log("  Has Chainlink feed at:", aggregator);
            }
        } catch {
            console.log("  Could not check for Chainlink feed");
        }

        console.log("");
    }

    function _checkChainlinkIntegration() internal view {
        console.log("--- CHAINLINK INTEGRATION TEST ---");

        // Test assets that might have Chainlink feeds
        address[] memory chainlinkAssets = new address[](1);
        chainlinkAssets[0] = 0x88b8E2161DEDC77EF4ab7585569D2415a1C1055D; // Mock USDT

        for (uint i = 0; i < chainlinkAssets.length; i++) {
            address asset = chainlinkAssets[i];
            console.log("Checking Chainlink for asset:", asset);

            try oracle.getAggregator(asset) returns (address aggregator) {
                if (aggregator != address(0)) {
                    _checkChainlinkFeedData(asset, aggregator);
                } else {
                    console.log("  No Chainlink aggregator registered");
                }
            } catch {
                console.log("  ERROR: Could not check aggregator");
            }

            console.log("");
        }
    }

    function _checkChainlinkFeedData(
        address asset,
        address aggregator
    ) internal view {
        console.log("  Chainlink aggregator:", aggregator);

        try oracle.getLatestRoundData(asset) returns (
            uint80 roundId,
            int256 price,
            uint256 /* startedAt */,
            uint256 updatedAt,
            uint80 /* answeredInRound */
        ) {
            console.log("  Latest round ID:", roundId);
            console.log("  Raw price:", uint256(price));
            console.log("  Updated at:", updatedAt);
            console.log("  Age (seconds):", block.timestamp - updatedAt);

            // Check if price is stale
            try oracle.isPriceStale(asset) returns (bool isStale) {
                if (isStale) {
                    console.log("  WARNING: Price is STALE");
                } else {
                    console.log("  Price is fresh");
                }
            } catch {
                console.log("  Could not check staleness");
            }
        } catch {
            console.log("  ERROR: Could not get Chainlink round data");
        }
    }

    function _checkPriceStaleness() internal view {
        console.log("--- PRICE STALENESS CHECK ---");

        address[] memory testAssets = new address[](1);
        testAssets[0] = 0x88b8E2161DEDC77EF4ab7585569D2415a1C1055D;

        for (uint i = 0; i < testAssets.length; i++) {
            address asset = testAssets[i];
            console.log("Checking staleness for:", asset);

            try oracle.isPriceStale(asset) returns (bool isStale) {
                if (isStale) {
                    console.log("  Status: STALE");
                } else {
                    console.log("  Status: FRESH");
                }
            } catch {
                console.log("  ERROR: Could not check staleness");
            }
        }

        console.log("");
    }

    function _checkComptrollerIntegration() internal view {
        console.log("--- COMPTROLLER INTEGRATION ---");

        try comptroller.oracle() returns (PriceOracle comptrollerOracle) {
            address comptrollerOracleAddress = address(comptrollerOracle);
            console.log(
                "Comptroller oracle address:",
                comptrollerOracleAddress
            );

            if (comptrollerOracleAddress == ORACLE_ADDRESS) {
                console.log("Comptroller is using the correct oracle");

                // Test comptroller's ability to get prices
                if (PUSDC_ADDRESS != address(0)) {
                    console.log(
                        "Testing comptroller price lookup for pUSDC..."
                    );
                    try
                        comptrollerOracle.getUnderlyingPrice(
                            PToken(PUSDC_ADDRESS)
                        )
                    returns (uint price) {
                        console.log("  Comptroller got price:", price);
                        console.log("  Formatted price:", _formatPrice(price));
                    } catch {
                        console.log("  ERROR: Comptroller could not get price");
                    }
                }
            } else {
                console.log(
                    "WARNING: Comptroller is using a different oracle!"
                );
                console.log("Expected:", ORACLE_ADDRESS);
                console.log("Actual  :", comptrollerOracleAddress);
            }
        } catch {
            console.log("ERROR: Could not get comptroller oracle");
        }

        console.log("");
    }

    function _formatPrice(uint256 price) internal pure returns (string memory) {
        if (price == 0) return "$0.00";

        // Convert from 18 decimals to human readable (simplified)
        uint256 dollars = price / 1e18;
        uint256 cents = (price % 1e18) / 1e16; // Get 2 decimal places

        // Simple formatting - you can enhance this
        if (dollars > 0) {
            return
                string(
                    abi.encodePacked(
                        "$",
                        _toString(dollars),
                        ".",
                        _toString(cents)
                    )
                );
        } else {
            return string(abi.encodePacked("$0.", _toString(cents)));
        }
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";

        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }

        return string(buffer);
    }
}

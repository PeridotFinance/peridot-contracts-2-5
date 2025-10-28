// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import "../contracts/DiaPriceOracle.sol";

/// @title DeployDiaOracle
/// @notice Foundry script to deploy DiaPriceOracle and optionally register DIA adapters
/// @dev Usage examples:
///  - forge script script/DeployDiaOracle.s.sol --rpc-url $SOMNIA_TESTNET_RPC --broadcast --private-key $PRIVATE_KEY
///  - Configure with env: DIA_STALE_THRESHOLD, DIA_ASSETS, DIA_ADAPTERS
contract DeployDiaOracle is Script {
    DiaPriceOracle public oracle;

    // Default configuration
    uint256 public constant DEFAULT_STALE_THRESHOLD = 3600; // 1 hour

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("Deploying DiaPriceOracle...");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(pk);

        uint256 stale = vm.envOr(
            "DIA_STALE_THRESHOLD",
            DEFAULT_STALE_THRESHOLD
        );
        oracle = new DiaPriceOracle(stale);

        console.log("DiaPriceOracle deployed to:", address(oracle));
        console.log("Stale threshold:", stale, "seconds");

        _optionalAdapterRegistration();

        vm.stopBroadcast();

        _logDeploymentInfo();
    }

    /// @notice Optionally register DIA adapters if provided via env
    /// @dev Expects comma-separated lists for DIA_ASSETS and DIA_ADAPTERS of equal length
    function _optionalAdapterRegistration() internal {
        string memory assetsCsv = vm.envOr("DIA_ASSETS", string(""));
        string memory adaptersCsv = vm.envOr("DIA_ADAPTERS", string(""));

        if (bytes(assetsCsv).length == 0 || bytes(adaptersCsv).length == 0) {
            console.log(
                "No DIA adapters provided via env; skipping registration"
            );
            return;
        }

        address[] memory assets = _parseAddressCsv(assetsCsv);
        address[] memory adapters = _parseAddressCsv(adaptersCsv);

        require(assets.length == adapters.length, "DIA env length mismatch");

        console.log("Registering", assets.length, "DIA adapters...");
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] != address(0) && adapters[i] != address(0)) {
                oracle.registerDIAAdapter(assets[i], adapters[i]);
                console.log(
                    "Registered adapter",
                    adapters[i],
                    "for asset",
                    assets[i]
                );
            }
        }
    }

    /// @notice Helper to parse a comma-separated list of addresses
    function _parseAddressCsv(
        string memory csv
    ) internal pure returns (address[] memory) {
        // Count commas to size the array
        uint256 parts = 1;
        bytes memory b = bytes(csv);
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ",") parts++;
        }

        address[] memory result = new address[](parts);
        uint256 idx = 0;
        uint256 start = 0;
        for (uint256 i = 0; i <= b.length; i++) {
            if (i == b.length || b[i] == ",") {
                bytes memory slice = new bytes(i - start);
                for (uint256 j = start; j < i; j++) {
                    slice[j - start] = b[j];
                }
                result[idx] = _toAddress(string(slice));
                idx++;
                start = i + 1;
            }
        }
        return result;
    }

    /// @notice Convert hex string to address (accepts with/without 0x)
    function _toAddress(string memory s) internal pure returns (address) {
        bytes memory strBytes = bytes(s);
        uint256 start = 0;
        if (
            strBytes.length >= 2 &&
            strBytes[0] == "0" &&
            (strBytes[1] == "x" || strBytes[1] == "X")
        ) {
            start = 2;
        }
        require(strBytes.length - start == 40, "bad address length");

        uint160 a = 0;
        for (uint256 i = start; i < start + 40; i++) {
            uint8 c = uint8(strBytes[i]);
            uint8 val;
            if (c >= 48 && c <= 57) {
                val = c - 48;
            } else if (c >= 65 && c <= 70) {
                val = c - 55; // 'A'..'F' => 10..15
            } else if (c >= 97 && c <= 102) {
                val = c - 87; // 'a'..'f' => 10..15
            } else {
                revert("bad hex char");
            }
            a = (a << 4) | uint160(val);
        }
        return address(a);
    }

    function _logDeploymentInfo() internal view {
        console.log("=== DiaPriceOracle Deployment Complete ===");
        console.log("Contract Address:", address(oracle));
        console.log("Chain ID:", block.chainid);
        console.log("Block Number:", block.number);
        console.log("=========================================");
    }
}

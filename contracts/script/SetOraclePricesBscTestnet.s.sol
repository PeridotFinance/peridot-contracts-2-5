// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface ISimplePriceOracle {
    function setDirectPrice(address asset, uint256 price) external;
}

/// @notice Set LINK and USDC prices on BSC testnet SimplePriceOracle
/// @dev Requires the oracle admin key. Override defaults via envs if needed.
contract SetOraclePricesBscTestnet is Script {
    // BSC testnet underlying addresses from addresses.MD
    address public constant UNDERLYING_LINK =
        0x84b9B910527Ad5C03A9Ca831909E21e236EA7b06;
    address public constant UNDERLYING_USDC =
        0x64544969ed7EBf5f083679233325356EbE738930;

    // Default oracle from current deploy logs
    address public constant DEFAULT_ORACLE =
        0xa0Cb889707d426A7A386870A03bc70d1b0697598;

    function run() external {
        uint256 adminPk = vm.envUint("PRIVATE_KEY");
        address oracleAddr = 0xa0Cb889707d426A7A386870A03bc70d1b0697598;

        // Prices in 1e18
        uint256 linkPrice = 24e18; // $25 default
        uint256 usdcPrice = 1e18; // $1 default

        console.log("Oracle:", oracleAddr);
        console.log("LINK price:", linkPrice);
        console.log("USDC price:", usdcPrice);

        vm.startBroadcast(adminPk);
        ISimplePriceOracle(oracleAddr).setDirectPrice(
            UNDERLYING_LINK,
            linkPrice
        );
        ISimplePriceOracle(oracleAddr).setDirectPrice(
            UNDERLYING_USDC,
            usdcPrice
        );
        vm.stopBroadcast();

        console.log("Oracle prices set.");
    }

    function _tryEnvAddress(
        string memory key,
        address fallbackAddr
    ) internal view returns (address) {
        try vm.envAddress(key) returns (address v) {
            return v;
        } catch {
            return fallbackAddr;
        }
    }

    function _tryEnvUint(
        string memory key,
        uint256 fallbackVal
    ) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 v) {
            return v;
        } catch {
            return fallbackVal;
        }
    }
}

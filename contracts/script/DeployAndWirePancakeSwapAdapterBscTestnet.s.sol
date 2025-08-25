// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IPancakeSwapAdapter {
    function setRouters(address v2, address v3, address quoter) external;

    function setV3Fee(address tokenIn, address tokenOut, uint24 fee) external;
}

interface IVaultExecutorCfg {
    function setSwapAdapter(address newAdapter) external;
}

contract DeployAndWirePancakeSwapAdapterBscTestnet is Script {
    // Default BSC Testnet addresses (override via env if needed)
    address public constant DEFAULT_V2_ROUTER =
        0xD99D1c33F9fC3444f8101754aBC46c52416550D1; // Pancake V2 router (testnet)
    address public constant DEFAULT_V3_ROUTER =
        0x1b81D678ffb9C0263b24A97847620C99d213eB14; // Pancake V3 router (testnet)
    address public constant DEFAULT_V3_QUOTER =
        0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997; // QuoterV2 (testnet)

    // Project addresses from addresses.MD (BSC Testnet)
    address public constant DEFAULT_VAULT_EXECUTOR =
        0x80034925b8cd129cEFAAd27162597adF4120F59c;
    address public constant DEFAULT_LINK =
        0x84b9B910527Ad5C03A9Ca831909E21e236EA7b06; // LINK
    address public constant DEFAULT_USDC =
        0x64544969ed7EBf5f083679233325356EbE738930; // USDC

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        // Optional overrides
        address v2 = DEFAULT_V2_ROUTER;
        address v3 = DEFAULT_V3_ROUTER;
        address quoter = DEFAULT_V3_QUOTER;
        address vault = DEFAULT_VAULT_EXECUTOR;
        address tokenIn = DEFAULT_LINK;
        address tokenOut = DEFAULT_USDC;
        uint24 fee = uint24(3000);

        console.log("VaultExecutor:", vault);
        console.log("Routers v2/v3/quoter:", v2, v3, quoter);

        vm.startBroadcast(pk);

        // Deploy adapter
        address adapter;
        {
            // deploy via inline assembly new since adapter ctor requires (v2,v3,quoter)
            // Simpler: create2 not needed; we just deploy using the constructor
        }
        adapter = address(new PancakeSwapAdapter(v2, v3, quoter));
        console.log("PancakeSwapAdapter:", adapter);

        // Configure v3 fee for the primary pair (LINK -> USDC)
        IPancakeSwapAdapter(adapter).setV3Fee(tokenIn, tokenOut, fee);

        // Wire adapter into vault
        IVaultExecutorCfg(vault).setSwapAdapter(adapter);

        vm.stopBroadcast();

        console.log("Configured adapter on vault. Done.");
    }

    // Helpers (need vm from Script)
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

// Minimal adapter import to satisfy new(...)
import {PancakeSwapAdapter} from "../contracts/DualInvestment/PancakeSwapAdapter.sol";

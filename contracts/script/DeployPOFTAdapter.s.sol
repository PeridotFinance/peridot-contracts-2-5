// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "../contracts/layerzero/P_OFTAdapterUpgradeable.sol";

import {PeridotProxyAdmin} from "../contracts/proxy/PeridotProxyAdmin.sol";
import {PeridotTransparentProxy} from "../contracts/proxy/PeridotTransparentProxy.sol";

import {LayerZeroV2BscTestnet, LayerZeroV2BasesepTestnet, LayerZeroV2MonadTestnet} from "lz-address-book/generated/LZAddresses.sol";

/**
 * @title DeployPOFTAdapter
 * @notice Deploy P_OFTAdapterUpgradeable behind a TransparentUpgradeableProxy on testnets
 *
 * USAGE:
 *
 * 1. Deploy on BNB Testnet:
 *    forge script script/DeployPOFTAdapter.s.sol \
 *      --rpc-url $BNB_TESTNET_RPC_URL \
 *      --private-key $PRIVATE_KEY \
 *      --broadcast \
 *      --verify --etherscan-api-key $BSCSCAN_KEY
 *
 * 2. Deploy on Arbitrum Sepolia:
 *    forge script script/DeployPOFTAdapter.s.sol \
 *      --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
 *      --private-key $PRIVATE_KEY \
 *      --broadcast \
 *      --verify --etherscan-api-key $ARBISCAN_KEY
 *
 * PREREQUISITES:
 * - $P token must be deployed on the target chain
 * - LayerZero Endpoint V2 must exist on the chain
 * - Deployer must have gas tokens for deployment
 */
contract DeployPOFTAdapter is Script {
    // $P token addresses (from addresses.MD)
    address constant BSC_TESTNET_P_TOKEN =
        0x5A5063a749fCF050CE58Cae6bB76A29bb37BA4Ed;
    address constant MONAD_TESTNET_P_TOKEN =
        0xeAEdaF63CbC1d00cB6C14B5c4DE161d68b7C63A0;
    address constant BASE_SEPOLIA_P_TOKEN =
        0x7E9aa6aa7fa64c41ba6fbC15A08efa84685F5c54;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploying P_OFTAdapter ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("Deployer balance:", deployer.balance);

        // Get configuration based on chain
        (
            address pToken,
            address lzEndpoint,
            string memory chainName
        ) = getChainConfig();

        console.log("\nConfiguration:");
        console.log("Chain:", chainName);
        console.log("P Token:", pToken);
        console.log("LZ Endpoint:", lzEndpoint);

        // Validate
        require(pToken != address(0), "P token not configured for this chain");
        require(
            lzEndpoint != address(0),
            "LZ endpoint not configured for this chain"
        );

        vm.startBroadcast(deployerPrivateKey);

        // Proxy admin (reuse via env if provided)
        address proxyAdminAddr = vm.envOr("PROXY_ADMIN", address(0));
        if (proxyAdminAddr == address(0)) {
            proxyAdminAddr = address(new PeridotProxyAdmin(deployer));
        }

        // Deploy implementation
        P_OFTAdapterUpgradeable impl = new P_OFTAdapterUpgradeable(
            pToken,
            lzEndpoint
        );

        // Deploy proxy + initialize
        bytes memory initData = abi.encodeWithSelector(
            P_OFTAdapterUpgradeable.initialize.selector,
            deployer
        );
        PeridotTransparentProxy proxy = new PeridotTransparentProxy(
            address(impl),
            proxyAdminAddr,
            initData
        );
        address adapterProxy = address(proxy);

        console.log("\n=== Deployment Successful ===");
        console.log("ProxyAdmin:", proxyAdminAddr);
        console.log("P_OFTAdapterUpgradeable (impl):", address(impl));
        console.log("P_OFTAdapter (proxy):", adapterProxy);

        // Display next steps
        console.log("\n=== Next Steps ===");
        console.log("1. Save this address to your .env file:");
        console.log(
            "   - For BSC Testnet: BSC_TESTNET_ADAPTER=%s",
            adapterProxy
        );
        console.log(
            "   - For Monad Testnet: MONAD_TESTNET_ADAPTER=%s",
            adapterProxy
        );
        console.log(
            "   - For Base Sepolia: BASE_SEPOLIA_ADAPTER=%s",
            adapterProxy
        );
        console.log("\n2. Deploy on the other chain");
        console.log(
            "\n3. Run ConfigurePOFTPeers.s.sol to set up peer connections"
        );
        console.log(
            "\n4. Run SeedPOFTInventory.s.sol to add $P token inventory"
        );
        console.log("\n5. Run TestCrossChainTransfer.s.sol to test bridging");

        vm.stopBroadcast();
    }

    function getChainConfig()
        internal
        view
        returns (address pToken, address lzEndpoint, string memory chainName)
    {
        if (block.chainid == 97) {
            // BSC Testnet
            return (
                BSC_TESTNET_P_TOKEN,
                address(LayerZeroV2BscTestnet.ENDPOINT_V2),
                "BSC Testnet"
            );
        } else if (block.chainid == 84532) {
            // Base Sepolia
            return (
                BASE_SEPOLIA_P_TOKEN,
                address(LayerZeroV2BasesepTestnet.ENDPOINT_V2),
                "Base Sepolia"
            );
        } else if (block.chainid == 10143) {
            // Monad Testnet
            return (
                MONAD_TESTNET_P_TOKEN,
                address(LayerZeroV2MonadTestnet.ENDPOINT_V2),
                "Monad Testnet"
            );
        } else {
            revert("Unsupported chain - add configuration for this chain");
        }
    }
}

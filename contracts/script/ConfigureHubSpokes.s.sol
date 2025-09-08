// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {PeridotHubHandler} from "../contracts/v1PeridotHub.sol";

contract ConfigureHubSpokes is Script {
    struct SpokeConfig {
        // Axelar chain name for the spoke (e.g., "base-sepolia", "ethereum-sepolia", "avalanche")
        string chainName;
        // Spoke contract address deployed on that chain (EVM address)
        address spokeAddress;
    }

    function run() external {
        // --- HUB CONNECTION ---
        // Fill with your hub chain RPC URL and the PeridotHubHandler proxy address on the hub chain
        string
            memory hubRpcUrl = "https://bnb-testnet.g.alchemy.com/v2/0koluEm5CjcmS90ULIC51ig2vp0AOXeh"; // e.g., BSC testnet RPC
        address payable hubHandlerProxy = payable(
            0x458A4f56317d663BA5F31da21BC5BD61Fc3dcB68
        ); // e.g., 0x91b2cb19... (proxy)

        require(bytes(hubRpcUrl).length > 0, "Missing hub RPC");
        require(
            address(hubHandlerProxy) != address(0),
            "Invalid hub handler proxy"
        );

        // --- SPOKE ENTRIES ---
        // Add/replace entries as needed. No envs used; everything is manual.
        SpokeConfig[] memory spokes = new SpokeConfig[](3);
        spokes[0] = SpokeConfig({
            chainName: "base-sepolia", // Chain ID: 84532
            spokeAddress: 0x5Ace095d973677e4e167B26832648cEd5d115B4b // fill with Base Sepolia spoke
        });
        spokes[1] = SpokeConfig({
            chainName: "ethereum-sepolia", // Chain ID: 11155111
            spokeAddress: 0xB4fc887D43B7acdff1139FeCb27c97b000945b64 // fill with Ethereum Sepolia spoke
        });
        spokes[2] = SpokeConfig({
            chainName: "avalanche", // Chain ID: 43113 (Fuji)
            spokeAddress: 0xC49677D218C2a53869430dCF70247732a520b772 // fill with Avalanche Fuji spoke
        });

        // --- EXECUTION ---
        uint256 forkId = vm.createFork(hubRpcUrl);
        vm.selectFork(forkId);

        console.log("Configuring PeridotHubHandler on hub RPC:", hubRpcUrl);
        console.log("HubHandler (proxy):", address(hubHandlerProxy));

        PeridotHubHandler hub = PeridotHubHandler(hubHandlerProxy);
        address currentOwner = hub.owner();
        console.log("Hub owner:", currentOwner);

        vm.startBroadcast();
        for (uint256 i = 0; i < spokes.length; i++) {
            SpokeConfig memory cfg = spokes[i];
            require(bytes(cfg.chainName).length > 0, "Invalid chainName");
            require(cfg.spokeAddress != address(0), "Invalid spokeAddress");

            string memory addrStr = Strings.toHexString(
                uint256(uint160(cfg.spokeAddress)),
                20
            );

            string memory oldSpoke = hub.spokeContracts(cfg.chainName);
            console.log("Setting spoke for:", cfg.chainName);
            console.log("  Old:", oldSpoke);
            console.log("  New:", addrStr);

            hub.setSpokeContract(cfg.chainName, addrStr);

            // Verify
            string memory stored = hub.spokeContracts(cfg.chainName);
            require(
                keccak256(bytes(stored)) == keccak256(bytes(addrStr)),
                "Spoke set failed"
            );
        }
        vm.stopBroadcast();

        console.log("\nSpoke mappings updated successfully.");
    }
}

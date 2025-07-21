// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import "../contracts/MockErc20.sol";

contract DeployMockUSDC is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying Mock USDC...");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Mock USDC with 6 decimals (like real USDC)
        MockErc20 mockUSDC = new MockErc20(
            "USD Coin", // name
            "USDC", // symbol
            6 // decimals
        );

        // Mint initial supply to deployer
        uint256 initialSupply = 1000000 * 1e6; // 1M USDC
        mockUSDC.mint(deployer, initialSupply);

        console.log("Mock USDC deployed at:", address(mockUSDC));
        console.log("Initial supply:", mockUSDC.totalSupply());
        console.log("Deployer balance:", mockUSDC.balanceOf(deployer));

        vm.stopBroadcast();

        console.log("=== UPDATE YOUR DEPLOYMENT SCRIPT ===");
        console.log("Replace the ERC20 address with:", address(mockUSDC));
    }
}

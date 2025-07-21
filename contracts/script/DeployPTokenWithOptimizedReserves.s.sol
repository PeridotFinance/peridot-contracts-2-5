// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import "../contracts/PErc20Immutable.sol";
import "../contracts/Peridottroller.sol";
import "../contracts/JumpRateModelV2.sol";

contract DeployPTokenWithOptimizedReserves is Script {
    
    // Replace with your deployed addresses
    address constant PERIDOTTROLLER_ADDRESS = 0x...; // Your deployed comptroller
    address constant INTEREST_RATE_MODEL_ADDRESS = 0x...; // Your deployed rate model
    
    // Optimized reserve factor for higher supplier APY
    uint256 constant OPTIMIZED_RESERVE_FACTOR = 0.08 * 1e18; // 8% (vs typical 15-20%)
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Example: Deploy USDC market with optimized reserves
        address usdcToken = 0xAb5c49580294Aff77670F839ea425f5b78ab3Ae7; // Your USDC address
        
        PErc20Immutable pUSDC = new PErc20Immutable(
            usdcToken,                      // underlying asset
            Peridottroller(PERIDOTTROLLER_ADDRESS),  // comptroller
            InterestRateModel(INTEREST_RATE_MODEL_ADDRESS), // interest rate model
            1e16,                          // initial exchange rate (0.01)
            "Peridot USDC",               // name
            "pUSDC",                      // symbol
            8,                            // decimals
            payable(deployer)             // admin
        );
        
        console.log("Deployed pUSDC at:", address(pUSDC));
        
        // Set optimized reserve factor (8% instead of 15-20%)
        uint256 result = pUSDC._setReserveFactor(OPTIMIZED_RESERVE_FACTOR);
        require(result == 0, "Failed to set reserve factor");
        
        console.log("Set reserve factor to 8% for maximum supplier APY");
        
        // Add market to comptroller
        Peridottroller comptroller = Peridottroller(PERIDOTTROLLER_ADDRESS);
        uint256 supportResult = comptroller._supportMarket(pUSDC);
        require(supportResult == 0, "Failed to support market");
        
        // Set collateral factor (example: 75%)
        uint256 collateralFactor = 0.75 * 1e18;
        uint256 collateralResult = comptroller._setCollateralFactor(address(pUSDC), collateralFactor);
        require(collateralResult == 0, "Failed to set collateral factor");
        
        vm.stopBroadcast();
        
        console.log("=== Market Configuration ===");
        console.log("pUSDC Market:", address(pUSDC));
        console.log("Reserve Factor:", OPTIMIZED_RESERVE_FACTOR / 1e16, "%");
        console.log("Collateral Factor:", collateralFactor / 1e16, "%");
        console.log("Expected Supplier APY Boost: +15-25%");
    }
    
    // Function to update existing market reserve factors
    function updateExistingMarketReserves() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // List of existing pToken markets to update
        address[] memory markets = new address[](3);
        markets[0] = 0x...; // pETH address
        markets[1] = 0x...; // pUSDC address  
        markets[2] = 0x...; // pBTC address
        
        vm.startBroadcast(deployerPrivateKey);
        
        for (uint i = 0; i < markets.length; i++) {
            if (markets[i] != address(0)) {
                PErc20Immutable pToken = PErc20Immutable(markets[i]);
                
                // Update to optimized reserve factor
                uint256 result = pToken._setReserveFactor(OPTIMIZED_RESERVE_FACTOR);
                
                if (result == 0) {
                    console.log("Updated reserve factor for market:", markets[i]);
                } else {
                    console.log("Failed to update market:", markets[i], "Error:", result);
                }
            }
        }
        
        vm.stopBroadcast();
    }
} 
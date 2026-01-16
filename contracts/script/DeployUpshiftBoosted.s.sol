// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/boosted/BoostedPErc20Immutable.sol";
import "../contracts/boosted/adapters/UpshiftAdapter.sol";
import "../contracts/PeridottrollerInterface.sol";
import "../contracts/InterestRateModel.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract DeployUpshiftBoosted is Script {
    function run() external {
        address underlying = vm.envAddress("UNDERLYING"); 
        address comptroller = vm.envAddress("PERIDOTTROLLER"); 
        address irm = vm.envAddress("INTEREST_RATE_MODEL"); 
        address vault = vm.envAddress("UPSHIFT_VAULT"); 
        address admin = vm.envAddress("ADMIN"); 

        uint256 initialExchangeRate = vm.envOr("INITIAL_EXCHANGE_RATE", uint256(2e26)); 
        uint256 bufferMantissa = vm.envOr("BUFFER_MANTISSA", uint256(1e17)); // 10%
        string memory name = vm.envOr("PTOKEN_NAME", string("Peridot Upshift Boosted"));
        string memory symbol = vm.envOr("PTOKEN_SYMBOL", string("pUpshiftBoost"));

        uint8 decimals = IERC20Metadata(underlying).decimals();

        vm.startBroadcast();
        address deployer = msg.sender;
        uint256 nonce = vm.getNonce(deployer);
        
        // Predict pToken address (it will be the 2nd contract deployed: 1. Adapter, 2. pToken)
        address predictedPToken = vm.computeCreateAddress(deployer, nonce + 1);

        UpshiftAdapter adapter = new UpshiftAdapter(
            predictedPToken,
            underlying,
            vault
        );
        
        BoostedPErc20Immutable pToken = new BoostedPErc20Immutable(
            underlying,
            PeridottrollerInterface(comptroller),
            InterestRateModel(irm),
            initialExchangeRate,
            name,
            symbol,
            decimals,
            payable(admin),
            IBoostedYieldAdapter(address(adapter)),
            bufferMantissa
        );
        
        require(address(pToken) == predictedPToken, "Address mismatch - pToken address prediction failed");

        console2.log("UpshiftAdapter deployed at:", address(adapter));
        console2.log("BoostedPErc20Immutable deployed at:", address(pToken));
        
        vm.stopBroadcast();
    }
}

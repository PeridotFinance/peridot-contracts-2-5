// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import "../contracts/Peridottroller.sol";
import "../contracts/PToken.sol";

contract SupportMarket is Script {
    // Update these with your deployed addresses
    address constant PERIDOTTROLLER_ADDRESS =
        0xe8F09917d56Cc5B634f4DE091A2c82189dc41b54;
    address constant PTOKEN_ADDRESS =
        0xC4FE7BD6b9EdD67bF2ba5daa317D7cd80E1913bb; // PErc20Delegator (Proxy) address

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        Peridottroller comptroller = Peridottroller(PERIDOTTROLLER_ADDRESS);

        // Support the market
        uint256 result = comptroller._supportMarket(PToken(PTOKEN_ADDRESS));
        require(result == 0, "Failed to support market");

        // Set collateral factor (75% for USDC)
        uint256 collateralFactor = 0.20 * 1e18;
        uint256 collateralResult = comptroller._setCollateralFactor(
            PToken(PTOKEN_ADDRESS),
            collateralFactor
        );
        require(collateralResult == 0, "Failed to set collateral factor");

        // Set reserve factor (8% for higher supplier APY)
        PToken pToken = PToken(PTOKEN_ADDRESS);
        uint256 reserveResult = pToken._setReserveFactor(0.10 * 1e18);
        require(reserveResult == 0, "Failed to set reserve factor");

        vm.stopBroadcast();

        console.log("Market configuration completed:");
        console.log("- Market supported in comptroller");
        console.log("- Collateral factor set to 75%");
        console.log("- Reserve factor set to 10% (optimized for suppliers)");
    }
}

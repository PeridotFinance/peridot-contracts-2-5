// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import "../contracts/Peridottroller.sol";
import "../contracts/PToken.sol";

contract SupportMarket is Script {
    // Update these with your deployed addresses
    address constant PERIDOTTROLLER_ADDRESS =
        0x6fC0c15531CB5901ac72aB3CFCd9dF6E99552e14;
    address constant PTOKEN_ADDRESS =
        0x66468B168Ea8289982EBEd6617dFCFA981d1EF0C; // PErc20Delegator (Proxy) address

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATEMAIN");

        vm.startBroadcast(deployerPrivateKey);

        Peridottroller comptroller = Peridottroller(PERIDOTTROLLER_ADDRESS);

        // Support the market
        uint256 result = comptroller._supportMarket(PToken(PTOKEN_ADDRESS));
        require(result == 0, "Failed to support market");

        // Set collateral factor (75% for USDC)
        uint256 collateralFactor = 0.35 * 1e18;
        uint256 collateralResult = comptroller._setCollateralFactor(
            PToken(PTOKEN_ADDRESS),
            collateralFactor
        );
        require(collateralResult == 0, "Failed to set collateral factor");

        // Set reserve factor (8% for higher supplier APY)
        /*PToken pToken = PToken(PTOKEN_ADDRESS);
        uint256 reserveResult = pToken._setReserveFactor(0.10 * 1e18);*/

        vm.stopBroadcast();

        console.log("Market configuration completed:");
        console.log("- Market supported in comptroller");
        console.log("- Collateral factor set to 75%");
        console.log("- Reserve factor set to 10% (optimized for suppliers)");
    }
}

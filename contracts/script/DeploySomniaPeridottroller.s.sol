// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/PeridottrollerG7.sol";
import "../contracts/Unitroller.sol";
import "../contracts/JumpRateModelV2.sol";
import "../contracts/PriceOracle.sol";
import "../contracts/DiaPriceOracle.sol";

contract DeploySomniaPeridottroller is Script {
    // Update as needed (or pass via env and read with vm.envAddress if preferred)
    address constant PERIDOT_ADDRESS =
        0x96650BebC549456F253974c11Fc6cBE28172A2d2;

    // Interest Rate Model params
    uint256 baseRatePerYear = 0.01 * 1e18;
    uint256 multiplierPerYear = 0.12 * 1e18;
    uint256 jumpMultiplierPerYear = 0.36 * 1e18;
    uint256 kink_ = 0.5 * 1e18;

    // Comptroller params
    uint256 closeFactorMantissa = 0.5e18;
    uint256 liquidationIncentiveMantissa = 1.08e18;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        console.log(
            "Deploying Somnia Comptroller stack (Unitroller + Impl + DIA Oracle + IRM)..."
        );
        console.log("Deployer:", deployer);

        vm.startBroadcast(pk);

        // 1) Deploy Unitroller (proxy)
        Unitroller unitroller = new Unitroller();
        console.log("Unitroller (Proxy) deployed:", address(unitroller));

        // 2) Deploy PeridottrollerG7 (implementation)
        PeridottrollerG7 impl = new PeridottrollerG7();
        console.log(
            "PeridottrollerG7 (Implementation) deployed:",
            address(impl)
        );

        // 3) Use pre-deployed JumpRateModelV2 and DiaPriceOracle (from env or known Somnia addresses)
        address irmAddr = vm.envOr(
            "SOMNIA_IRM",
            address(0x60a8BD81f90526560344C63279210BC067a489a5)
        );
        address diaAddr = vm.envOr(
            "SOMNIA_DIA_ORACLE",
            address(0xa41D586530BC7BC872095950aE03a780d5114445)
        );

        require(irmAddr != address(0), "IRM address is zero");
        require(diaAddr != address(0), "DIA oracle address is zero");
        require(irmAddr.code.length > 0, "IRM not deployed");
        require(diaAddr.code.length > 0, "DIA oracle not deployed");

        JumpRateModelV2 irm = JumpRateModelV2(irmAddr);
        DiaPriceOracle dia = DiaPriceOracle(diaAddr);
        console.log("JumpRateModelV2 (pre-deployed):", irmAddr);
        console.log("DiaPriceOracle (pre-deployed):", diaAddr);

        // 5) Wire Unitroller -> Implementation (two-step)
        uint256 r1 = unitroller._setPendingImplementation(address(impl));
        require(r1 == 0, "set pending impl failed");
        impl._become(unitroller);

        // Sanity: implementation must not be zero
        address activeImpl = unitroller.peridottrollerImplementation();
        require(
            activeImpl != address(0),
            "implementation is zero after accept"
        );
        console.log("Active implementation set:", activeImpl);

        // 6) Use proxy interface at Unitroller address
        PeridottrollerG7 ctrl = PeridottrollerG7(address(unitroller));

        // 7) Set the DIA oracle on controller
        uint256 so = ctrl._setPriceOracle(PriceOracle(address(dia)));
        require(so == 0, "set oracle failed");
        console.log("Oracle set to:", address(dia));

        // 8) Set core risk params
        require(
            ctrl._setCloseFactor(closeFactorMantissa) == 0,
            "set close factor failed"
        );
        console.log("Close factor set:", closeFactorMantissa);

        require(
            ctrl._setLiquidationIncentive(liquidationIncentiveMantissa) == 0,
            "set liq incentive failed"
        );
        console.log("Liquidation incentive set:", liquidationIncentiveMantissa);

        vm.stopBroadcast();

        console.log("==== Deployment Summary ====");
        console.log("Unitroller (Proxy):", address(unitroller));
        console.log("PeridottrollerG7 (Implementation):", address(impl));
        console.log("Peridottroller Proxy (Use this):", address(ctrl));
        console.log("JumpRateModelV2:", address(irm));
        console.log("DIA Oracle:", address(dia));
    }
}

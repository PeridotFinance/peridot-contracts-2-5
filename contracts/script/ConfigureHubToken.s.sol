// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PeridotHubHandler} from "../contracts/PeridotHubHandler.sol";

contract ConfigureHubToken is Script {
    // Hardcode values here, or use the parameterized run(...) below
    address constant HUB_HANDLER = 0x91b2cb19Ce8072296732349ca26F78ad60c4FF40; // update me
    address constant UNDERLYING = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd; // update me (token on hub)
    address constant PTOKEN = 0x39e955B2Dc405062b4212026EEC24CCBB81b9065; // update me (PErc20CrossChain)
    string constant AXELAR_SYMBOL = "WBNB"; // update me (Axelar symbol)

    function _configure(
        address hub,
        address underlying,
        address ptoken,
        string memory symbol
    ) internal {
        require(hub != address(0), "invalid hub");
        require(underlying != address(0), "invalid underlying");
        require(ptoken != address(0), "invalid pToken");
        require(bytes(symbol).length > 0, "invalid symbol");

        PeridotHubHandler h = PeridotHubHandler(payable(hub));

        console.log("Setting mapping underlying -> pToken ...");
        h.setPToken(underlying, ptoken);

        console.log("Allowlisting pToken ...");
        h.setAllowedPToken(ptoken, true);

        console.log("Setting Axelar symbol for underlying ...");
        h.setUnderlyingAxelarSymbol(underlying, symbol);

        console.log("Configured:");
        console.log("  hub:", hub);
        console.log("  underlying:", underlying);
        console.log("  pToken:", ptoken);
        console.log("  axelarSymbol:", symbol);
    }

    // Default usage with hardcoded constants above
    function run() external {
        vm.startBroadcast();
        _configure(HUB_HANDLER, UNDERLYING, PTOKEN, AXELAR_SYMBOL);
        vm.stopBroadcast();
    }

    // Parameterized usage:
    // forge script script/ConfigureHubToken.s.sol:ConfigureHubToken \
    //   --rpc-url <RPC> --private-key <PK> --broadcast \
    //   --sig "run(address,address,address,string)" <HUB> <UNDERLYING> <PTOKEN> <SYMBOL>
    function run(
        address hub,
        address underlying,
        address ptoken,
        string memory symbol
    ) external {
        vm.startBroadcast();
        _configure(hub, underlying, ptoken, symbol);
        vm.stopBroadcast();
    }
}

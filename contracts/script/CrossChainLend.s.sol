// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PeridotSpoke} from "../contracts/PeridotSpoke.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// Define a local interface to avoid conflicts with the contract's interface
interface ILocalAxelarGateway {
    function tokenAddresses(
        string calldata symbol
    ) external view returns (address);
}

/**
 * @title CrossChainLend
 * @author Peridot
 * @notice Script to perform cross-chain lending from a spoke chain to the hub chain.
 * @dev Usage: forge script script/CrossChainLend.s.sol:CrossChainLend --rpc-url <SPOKE_RPC> --private-key <PK> --broadcast --sig "run(string,uint256)" <TOKEN_SYMBOL> <AMOUNT>
 */
contract CrossChainLend is Script {
    // --- DEPLOYED CONTRACT ADDRESS ---
    // This should be the PeridotSpoke contract on your source chain (e.g., Arbitrum)
    address constant PERIDOT_SPOKE_ADDRESS =
        0xe08DAd870A8ABecba3E94Fd82A064d88C73c8703;

    // --- CHAIN CONFIGURATION ---
    uint256 constant DEFAULT_GAS_PAYMENT = 0.01 ether; // Default gas payment for cross-chain tx

    // Contract instance
    PeridotSpoke spoke;

    function setUp() public {
        spoke = PeridotSpoke(payable(PERIDOT_SPOKE_ADDRESS));
        require(PERIDOT_SPOKE_ADDRESS != address(0), "Invalid spoke address");
    }

    function run(string memory tokenSymbol, uint256 supplyAmount) public {
        uint256 gasPayment = 0.01 ether; // 0.01 ETH for gas

        vm.startBroadcast();

        // Get token address
        ILocalAxelarGateway gateway = ILocalAxelarGateway(
            address(spoke.getGateway())
        );
        address tokenAddress = gateway.tokenAddresses(tokenSymbol);
        require(tokenAddress != address(0), "Token not supported");

        // Approve tokens
        IERC20(tokenAddress).approve(address(spoke), supplyAmount);

        // Call supply function with gas
        spoke.supplyToPeridot{value: gasPayment}(tokenSymbol, supplyAmount);

        vm.stopBroadcast();

        console.log("SUCCESS: Cross-chain supply transaction submitted!");
    }
}

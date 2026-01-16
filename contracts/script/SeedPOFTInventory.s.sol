// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {LayerZeroV2BscTestnet, LayerZeroV2BasesepTestnet, LayerZeroV2MonadTestnet} from "lz-address-book/generated/LZAddresses.sol";

/**
 * @title SeedPOFTInventory
 * @notice Seeds the lockbox inventory by transferring $P into the adapter escrow.
 * @dev Lock/unlock bridging requires inventory on the destination chain adapter.
 *
 * Env vars:
 * - PRIVATE_KEY
 * - BSC_TESTNET_ADAPTER
 * - BASE_SEPOLIA_ADAPTER
 * - SEED_AMOUNT (uint, in token wei)
 */
contract SeedPOFTInventory is Script {
    using SafeERC20 for IERC20;

    // $P token addresses (from addresses.MD)
    address constant BSC_TESTNET_P_TOKEN =
        0x5A5063a749fCF050CE58Cae6bB76A29bb37BA4Ed;
    address constant MONAD_TESTNET_P_TOKEN =
        0xeAEdaF63CbC1d00cB6C14B5c4DE161d68b7C63A0;
    address constant BASE_SEPOLIA_P_TOKEN =
        0x7E9aa6aa7fa64c41ba6fbC15A08efa84685F5c54;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        address bscAdapter = vm.envAddress("BSC_TESTNET_ADAPTER");
        address baseAdapter = vm.envAddress("BASE_SEPOLIA_ADAPTER");
        uint256 amount = vm.envUint("SEED_AMOUNT");

        vm.startBroadcast(pk);

        if (block.chainid == LayerZeroV2BscTestnet.CHAIN_ID) {
            IERC20(BSC_TESTNET_P_TOKEN).safeTransfer(bscAdapter, amount);
        } else if (block.chainid == LayerZeroV2BasesepTestnet.CHAIN_ID) {
            IERC20(BASE_SEPOLIA_P_TOKEN).safeTransfer(baseAdapter, amount);
        } else {
            revert("Unsupported chain: use BSC testnet or Base Sepolia");
        }

        vm.stopBroadcast();
    }
}

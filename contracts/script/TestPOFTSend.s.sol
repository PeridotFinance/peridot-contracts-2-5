// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";

import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {IOFT, SendParam, MessagingFee} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TestPOFTSend
 * @notice Quotes fee, approves underlying token, and calls OFTAdapter `send()` with safe default options.
 *
 * Env vars:
 * - PRIVATE_KEY
 * - OFT_ADAPTER      (address)  // the proxy address on the SOURCE chain
 * - DST_EID          (uint)     // destination LayerZero EID (e.g. Base Sepolia = 40245, BSC testnet = 40102)
 * - TO               (address)  // recipient on destination chain
 * - AMOUNT_LD        (uint)     // amount in local decimals (token wei)
 * Optional:
 * - LZ_RECEIVE_GAS   (uint)     // default 200000
 */
contract TestPOFTSend is Script {
    using OptionsBuilder for bytes;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(pk);

        address adapter = vm.envAddress("OFT_ADAPTER");
        uint32 dstEid = uint32(vm.envUint("DST_EID"));
        address to = vm.envAddress("TO");
        uint256 amountLD = vm.envUint("AMOUNT_LD");

        uint256 lzReceiveGasRaw = vm.envOr("LZ_RECEIVE_GAS", uint256(200000));
        require(
            lzReceiveGasRaw <= type(uint128).max,
            "LZ_RECEIVE_GAS too large"
        );
        uint128 lzReceiveGas = uint128(lzReceiveGasRaw);

        bytes memory options = OptionsBuilder
            .newOptions()
            .addExecutorLzReceiveOption(lzReceiveGas, 0);
        SendParam memory sendParam = SendParam(
            dstEid,
            _addressToBytes32(to),
            amountLD,
            amountLD,
            options,
            "",
            ""
        );

        MessagingFee memory fee = IOFT(adapter).quoteSend(sendParam, false);

        console.log("=== TestPOFTSend ===");
        console.log("chainid:", block.chainid);
        console.log("sender:", sender);
        console.log("adapter:", adapter);
        console.log("dstEid:", dstEid);
        console.log("to:", to);
        console.log("amountLD:", amountLD);
        console.log("lzReceiveGas:", uint256(lzReceiveGas));
        console.log("fee.nativeFee:", fee.nativeFee);
        console.log("fee.lzTokenFee:", fee.lzTokenFee);

        vm.startBroadcast(pk);

        // approve underlying token for the adapter (OFTAdapter requires approval)
        address underlying = IOFT(adapter).token();
        IERC20(underlying).approve(adapter, amountLD);

        IOFT(adapter).send{value: fee.nativeFee}(sendParam, fee, sender);

        vm.stopBroadcast();
    }

    function _addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }
}

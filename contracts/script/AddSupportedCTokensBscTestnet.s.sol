// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

/// @notice Minimal interface to support both manager variants
interface IDualInvestmentManager {
    function setSupportedCToken(address cToken, bool supported) external;
}

/// @title AddSupportedCTokensBscTestnet
/// @notice Adds supported cTokens on BSC Testnet to a deployed DualInvestment manager
/// @dev Set MANAGER and PRIVATE_KEY env vars before running. Example:
///      forge script script/AddSupportedCTokensBscTestnet.s.sol:AddSupportedCTokensBscTestnet \
///        --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY
contract AddSupportedCTokensBscTestnet is Script {
    // ===== BSC Testnet cToken proxies (from addresses.MD) =====
    address public constant CTOKEN_PLINK =
        0xfB68C6469A67873f7FA2Df6CeAcC5da12abF6c8c; // PErc20Delegator LINK
    address public constant CTOKEN_PBNB =
        0xa568bD70068A940910d04117c36Ab1A0225FD140; // PEther (pBNB)

    function run() external {
        address managerAddr = 0xcf0fE6c3ECd1f6d4c0BF8B361e6D262a8902Bd34;
        require(managerAddr != address(0), "MANAGER env not set");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(pk);
        console.log("Adding supported cTokens on BSC Testnet");
        console.log("Manager:", managerAddr);
        console.log("Sender:", sender);

        vm.startBroadcast(pk);

        IDualInvestmentManager manager = IDualInvestmentManager(managerAddr);

        _add(manager, CTOKEN_PLINK, "pLINK");
        _add(manager, CTOKEN_PBNB, "pBNB");

        vm.stopBroadcast();
        console.log("Done.");
    }

    function _add(
        IDualInvestmentManager manager,
        address cToken,
        string memory name
    ) internal {
        if (cToken == address(0)) {
            console.log(name, "skipped: zero address");
            return;
        }
        manager.setSupportedCToken(cToken, true);
        console.log("Added", name, cToken);
    }
}

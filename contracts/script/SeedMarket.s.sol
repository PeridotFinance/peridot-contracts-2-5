// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import "../contracts/Peridottroller.sol";
import "../contracts/PTokenInterfaces.sol";
import "../contracts/PToken.sol";
import "../contracts/EIP20Interface.sol";

/// @notice Admin-led safe market seeding script
/// Env vars:
///  - SEED_PERIDOTTROLLER: comptroller address
///  - SEED_PTOKEN: pToken (PErc20Delegator) address
///  - SEED_AMOUNT: amount of underlying to seed (in underlying decimals)
///  - PRIVKEY: admin private key
contract SeedMarket is Script {
    function run() external {
        address comptrollerAddr = vm.envAddress("SEED_PERIDOTTROLLER");
        address pTokenAddr = vm.envAddress("SEED_PTOKEN");
        uint256 amount = vm.envUint("SEED_AMOUNT");
        uint256 pk = vm.envUint("PRIVKEY");

        vm.startBroadcast(pk);

        Peridottroller comptroller = Peridottroller(comptrollerAddr);
        PToken pToken = PToken(pTokenAddr);

        // 1) Freeze risk params: CF=0, pause borrows
        uint256 res = comptroller._setCollateralFactor(PToken(pTokenAddr), 0);
        require(res == 0, "set CF 0 failed");
        comptroller._setBorrowPaused(PToken(pTokenAddr), true);

        // 2) Resolve underlying and approve
        address underlying = PErc20Interface(pTokenAddr).underlying();
        EIP20Interface(underlying).approve(pTokenAddr, amount);

        // 3) Mint seed
        uint256 mintRet = PErc20Interface(pTokenAddr).mint(amount);
        require(mintRet == 0, "mint failed");

        // 4) Mark seeded on controller
        uint256 ms = comptroller.markSeeded(PToken(pTokenAddr));
        require(ms == 0, "markSeeded failed");

        // Note: Do not re-enable borrows here; do that after verification/hotfix rollout

        vm.stopBroadcast();
    }
}

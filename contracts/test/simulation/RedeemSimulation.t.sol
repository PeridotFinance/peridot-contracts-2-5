// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/boosted/MorphoBoostedDelegate.sol";
import "../../contracts/PErc20Delegator.sol";

contract RedeemSimulation is Test {
    // Addresses from MonadScan
    address constant SENDER = 0xCED23360932B80d18fdEAEAa573202E80A584804;
    address constant DELEGATOR_PROXY = 0x085FbF880F88f861B8A09e6aaB1E4618d79Ba1D4; // pToken (USDC Boosted)
    address constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603; // USDC on Monad Mainnet

    // Morpho Vault address (found in logs or known)
    // From logs: 0xbeEFf443...aC311aB83 is where funds came from during withdrawal
    address constant MORPHO_VAULT = address(0xbeEFf443C3CbA3E369DA795002243BeaC311aB83);

    // Target Transaction Details
    // Note: Use a recent block number. The tx was ~41 mins ago from block 45624626
    uint256 constant TARGET_BLOCK = 45622000; // Approximate block ~2600 blocks ago
    uint256 constant REDEEM_AMOUNT = 5009675; // 5.009675 USDC (6 decimals)

    MorphoBoostedDelegate pToken;
    IERC20 usdc;
    IERC4626 vault;

    function setUp() public {
        // Fork Monad Mainnet at the specific block
        // vm.createSelectFork("https://rpc.monad.xyz", TARGET_BLOCK);
        // Note: User must provide RPC URL via environment variable or command line
        // We will assume `forge test --fork-url $MONAD_RPC_URL --fork-block-number 456140`

        pToken = MorphoBoostedDelegate(DELEGATOR_PROXY);
        usdc = IERC20(USDC);
        vault = IERC4626(MORPHO_VAULT);
    }

    function testSimulateRedeem() public {
        console.log("=== Setup ===");
        console.log("Sender:", SENDER);
        console.log("pToken:", address(pToken));
        console.log("USDC:", address(usdc));
        console.log("Vault:", address(vault));

        // 1. Initial State
        uint256 initialUserUSDC = usdc.balanceOf(SENDER);
        uint256 initialUserPToken = pToken.balanceOf(SENDER);
        uint256 initialPTokenCash = usdc.balanceOf(address(pToken));
        uint256 initialVaultAssets = vault.maxWithdraw(address(pToken));

        console.log("=== Initial State ===");
        console.log("User USDC:", initialUserUSDC);
        console.log("User pToken:", initialUserPToken);
        console.log("pToken Idle Cash:", initialPTokenCash);
        console.log("pToken Vault Assets:", initialVaultAssets);

        // Check if idle cash is enough
        if (initialPTokenCash < REDEEM_AMOUNT) {
            console.log("NOTE: Idle cash is LESS than redeem amount. Expecting withdrawal from Morpho.");
        } else {
            console.log("NOTE: Idle cash is SUFFICIENT. Funds should come from local buffer.");
        }

        // 2. Execute Transaction
        vm.prank(SENDER);
        pToken.redeemUnderlying(REDEEM_AMOUNT);

        // 3. Post State
        uint256 finalUserUSDC = usdc.balanceOf(SENDER);
        uint256 finalPTokenCash = usdc.balanceOf(address(pToken));
        uint256 finalVaultAssets = vault.maxWithdraw(address(pToken));

        console.log("\n=== Final State ===");
        console.log("User USDC:", finalUserUSDC);
        console.log("Delta USDC:", finalUserUSDC - initialUserUSDC);
        console.log("Expected Delta:", REDEEM_AMOUNT);

        console.log("pToken Idle Cash:", finalPTokenCash);
        console.log("pToken Vault Assets:", finalVaultAssets);

        // 4. Verification
        assertEq(finalUserUSDC - initialUserUSDC, REDEEM_AMOUNT, "User received incorrect amount");

        uint256 withdrawnFromVault = initialVaultAssets > finalVaultAssets ? initialVaultAssets - finalVaultAssets : 0;

        console.log("\n=== Analysis ===");
        console.log("Withdrawn from Vault:", withdrawnFromVault);

        if (initialPTokenCash < REDEEM_AMOUNT) {
            console.log("INFO: Idle cash was insufficient, but vault withdrawal was:", withdrawnFromVault);
            console.log("This means the contract had enough after rebalancing or the vault was not tapped.");
        } else {
            console.log("INFO: Idle cash was sufficient. No vault withdrawal expected.");
        }

        // Success - log the outcome
        console.log("\n=== SUCCESS ===");
        console.log("User successfully redeemed", REDEEM_AMOUNT, "USDC");
    }
}

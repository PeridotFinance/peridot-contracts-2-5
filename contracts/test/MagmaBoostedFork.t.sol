// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/boosted/MagmaBoostedDelegate.sol";
import "../contracts/PErc20Delegator.sol";
import "../contracts/PeridottrollerInterface.sol";
import "../contracts/InterestRateModel.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MagmaBoostedForkTest
 * @notice Fork test against real Magma deployment on Monad Mainnet
 * @dev Run with: forge test --match-path test/MagmaBoostedFork.t.sol --fork-url $MONAD_RPC_URL -vv
 */
contract MagmaBoostedForkTest is Test {
    // Monad Mainnet addresses
    address constant WMON = 0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701;
    address constant MAGMA = 0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081;
    address constant PERIDOTTROLLER = 0x6D208789f0a978aF789A3C8Ba515749598940716;
    address constant JUMP_RATE_MODEL = 0x5710017eCdF44f39b5Ae885965140726B7d81099;

    MagmaBoostedDelegate implementation;
    PErc20Delegator delegator;

    address admin = address(0xCED23360932B80d18fdEAEAa573202E80A584804);
    address testUser;

    function setUp() public {
        // Create test user with WMON
        testUser = address(0x9999);

        // Get some WMON by dealing
        deal(WMON, testUser, 100e18);

        // Deploy implementation
        implementation = new MagmaBoostedDelegate();

        // Deploy delegator
        bytes memory becomeImplData = abi.encode(MAGMA, 3e17); // 30% buffer

        delegator = new PErc20Delegator(
            WMON,
            PeridottrollerInterface(PERIDOTTROLLER),
            InterestRateModel(JUMP_RATE_MODEL),
            2e26, // initial exchange rate
            "Peridot Magma Staked MON",
            "pMagmaWMON",
            18,
            payable(admin),
            address(implementation),
            becomeImplData
        );

        console.log("Deployed MagmaBoosted at:", address(delegator));
    }

    function testForkDeployment() public view {
        MagmaBoostedDelegate delegate = MagmaBoostedDelegate(address(delegator));

        assertEq(address(delegate.magmaVault()), MAGMA);
        assertEq(delegate.underlying(), WMON);
        assertEq(delegate.vaultBufferMantissa(), 3e17);

        console.log("Deployment successful on fork");
    }

    function testForkMintAndDeposit() public {
        uint256 mintAmount = 10e18;

        vm.startPrank(testUser);
        IERC20(WMON).approve(address(delegator), mintAmount);

        uint256 gmonBefore = IERC20(MAGMA).balanceOf(address(delegator));
        console.log("gMON balance before mint:", gmonBefore);

        uint256 result = PErc20(address(delegator)).mint(mintAmount);
        require(result == 0, "mint failed");

        uint256 gmonAfter = IERC20(MAGMA).balanceOf(address(delegator));
        console.log("gMON balance after mint:", gmonAfter);

        uint256 pTokenBalance = delegator.balanceOf(testUser);
        console.log("User pToken balance:", pTokenBalance);

        vm.stopPrank();

        assertTrue(gmonAfter > gmonBefore, "Should deposit to Magma");
        assertTrue(pTokenBalance > 0, "Should receive pTokens");
    }

    function testForkExchangeRate() public {
        MagmaBoostedDelegate delegate = MagmaBoostedDelegate(address(delegator));

        uint256 exchangeRate = PToken(address(delegator)).exchangeRateStored();
        console.log("Current Exchange Rate:", exchangeRate);

        // Get Magma's exchange rate
        IMagma magmaVault = IMagma(MAGMA);
        uint256 magmaRate = magmaVault.convertToAssets(1e18);
        console.log("Magma Exchange Rate (1 gMON -> WMON):", magmaRate);

        assertTrue(exchangeRate > 0, "Exchange rate should be positive");
    }

    function testForkVaultViews() public {
        MagmaBoostedDelegate delegate = MagmaBoostedDelegate(address(delegator));

        // Deposit first
        uint256 mintAmount = 10e18;
        vm.startPrank(testUser);
        IERC20(WMON).approve(address(delegator), mintAmount);
        PErc20(address(delegator)).mint(mintAmount);
        vm.stopPrank();

        // Check view functions
        uint256 gmonShares = IERC20(MAGMA).balanceOf(address(delegator));
        console.log("gMON shares held:", gmonShares);

        IMagma magmaVault = IMagma(MAGMA);
        uint256 vaultAssets = magmaVault.convertToAssets(gmonShares);
        console.log("Vault assets (WMON value):", vaultAssets);

        assertTrue(vaultAssets > 0, "Should have assets in vault");
    }
}

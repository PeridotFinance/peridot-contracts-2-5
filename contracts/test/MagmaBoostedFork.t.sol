// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/boosted/MagmaBoostedDelegate.sol";
import "../contracts/PErc20Delegator.sol";
import "../contracts/PeridottrollerInterface.sol";
import "../contracts/InterestRateModel.sol";
import "./MockPeridottroller.sol";
import "./MockInterestRateModel.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IWrappedMON {
    function deposit() external payable;
}

/**
 * @title MagmaBoostedForkTest
 * @notice Fork test against real Magma deployment on Monad Mainnet
 * @dev Run with: forge test --match-path test/MagmaBoostedFork.t.sol --fork-url $MONAD_RPC_URL -vv
 */
contract MagmaBoostedForkTest is Test {
    // Monad Mainnet addresses (override via env if needed)
    address constant DEFAULT_WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant DEFAULT_MAGMA = 0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081;

    MagmaBoostedDelegate implementation;
    PErc20Delegator delegator;
    address wmon;
    address magma;
    MockPeridottroller comptroller;
    MockInterestRateModel irm;

    address admin = address(0xCED23360932B80d18fdEAEAa573202E80A584804);
    address testUser;

    function setUp() public {
        _ensureForkOrSkip();
        wmon = vm.envOr("WMON_ADDRESS", DEFAULT_WMON);
        magma = vm.envOr("MAGMA_ADDRESS", DEFAULT_MAGMA);
        if (wmon.code.length == 0) {
            emit log("Skipping fork test: WMON address has no code (override WMON_ADDRESS)");
            vm.skip(true);
        }
        if (magma.code.length == 0) {
            emit log("Skipping fork test: MAGMA address has no code (override MAGMA_ADDRESS)");
            vm.skip(true);
        }
        if (address(0x1000).code.length == 0) {
            emit log("Skipping fork test: system contract 0x1000 missing on RPC");
            vm.skip(true);
        }

        comptroller = new MockPeridottroller();
        irm = new MockInterestRateModel();
        // Create test user with WMON
        testUser = address(0x9999);

        // Fund native MON and wrap into WMON
        vm.deal(testUser, 100e18);
        vm.startPrank(testUser);
        IWrappedMON(wmon).deposit{value: 100e18}();
        vm.stopPrank();

        // Deploy implementation
        implementation = new MagmaBoostedDelegate();

        // Deploy delegator
        bytes memory becomeImplData = abi.encode(magma, 3e17); // 30% buffer

        delegator = new PErc20Delegator(
            wmon,
            PeridottrollerInterface(address(comptroller)),
            InterestRateModel(address(irm)),
            2e26, // initial exchange rate
            "Peridot Magma Staked MON",
            "pMagmaWMON",
            18,
            payable(admin),
            address(implementation),
            becomeImplData
        );

        console.log("Deployed MagmaBoosted at:", address(delegator));
        comptroller.setMarket(address(delegator), true, 0.75e18);
    }

    function testForkDeployment() public view {
        MagmaBoostedDelegate delegate = MagmaBoostedDelegate(address(delegator));

        assertEq(address(delegate.magmaVault()), magma);
        assertEq(delegate.underlying(), wmon);
        assertEq(delegate.vaultBufferMantissa(), 3e17);

        console.log("Deployment successful on fork");
    }

    function testForkMintAndDeposit() public {
        uint256 mintAmount = 10e18;

        vm.startPrank(testUser);
        IERC20(wmon).approve(address(delegator), mintAmount);

        uint256 gmonBefore = IERC20(magma).balanceOf(address(delegator));
        console.log("gMON balance before mint:", gmonBefore);

        uint256 result = PErc20(address(delegator)).mint(mintAmount);
        require(result == 0, "mint failed");

        uint256 gmonAfter = IERC20(magma).balanceOf(address(delegator));
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
        IMagma magmaVault = IMagma(magma);
        uint256 magmaRate = magmaVault.convertToAssets(1e18);
        console.log("Magma Exchange Rate (1 gMON -> WMON):", magmaRate);

        assertTrue(exchangeRate > 0, "Exchange rate should be positive");
    }

    function testForkVaultViews() public {
        MagmaBoostedDelegate delegate = MagmaBoostedDelegate(address(delegator));

        // Deposit first
        uint256 mintAmount = 10e18;
        vm.startPrank(testUser);
        IERC20(wmon).approve(address(delegator), mintAmount);
        PErc20(address(delegator)).mint(mintAmount);
        vm.stopPrank();

        // Check view functions
        uint256 gmonShares = IERC20(magma).balanceOf(address(delegator));
        console.log("gMON shares held:", gmonShares);

        IMagma magmaVault = IMagma(magma);
        uint256 vaultAssets = magmaVault.convertToAssets(gmonShares);
        console.log("Vault assets (WMON value):", vaultAssets);

        assertTrue(vaultAssets > 0, "Should have assets in vault");
    }

    function testForkYieldDiagnosticsAfter2Hours() public {
        IMagma magmaVault = IMagma(magma);

        uint256 mintAmount = 10e18;
        vm.startPrank(testUser);
        IERC20(wmon).approve(address(delegator), mintAmount);
        require(PErc20(address(delegator)).mint(mintAmount) == 0, "mint failed");
        vm.stopPrank();

        uint256 shares0 = IERC20(magma).balanceOf(address(delegator));
        uint256 assets0 = magmaVault.convertToAssets(shares0);
        uint256 rate0 = magmaVault.convertToAssets(1e18);
        uint256 exchangeRateStored0 = PToken(address(delegator)).exchangeRateStored();
        uint256 exchangeRateCurrent0 = PToken(address(delegator)).exchangeRateCurrent();

        console.log("=== BEFORE (fork) ===");
        console.log("block.number:", block.number);
        console.log("block.timestamp:", block.timestamp);
        console.log("shares0:", shares0);
        console.log("assets0:", assets0);
        console.log("rate0 (assets per 1e18 shares):", rate0);
        console.log("exchangeRateStored0:", exchangeRateStored0);
        console.log("exchangeRateCurrent0:", exchangeRateCurrent0);

        vm.warp(block.timestamp + 2 hours);
        vm.rollFork(block.number + 1000);

        uint256 shares1 = IERC20(magma).balanceOf(address(delegator));
        uint256 assets1 = magmaVault.convertToAssets(shares1);
        uint256 rate1 = magmaVault.convertToAssets(1e18);
        uint256 exchangeRateStored1 = PToken(address(delegator)).exchangeRateStored();
        uint256 exchangeRateCurrent1 = PToken(address(delegator)).exchangeRateCurrent();

        console.log("=== AFTER (fork, warp + rollFork) ===");
        console.log("block.number:", block.number);
        console.log("block.timestamp:", block.timestamp);
        console.log("shares1:", shares1);
        console.log("assets1:", assets1);
        console.log("rate1 (assets per 1e18 shares):", rate1);
        console.log("exchangeRateStored1:", exchangeRateStored1);
        console.log("exchangeRateCurrent1:", exchangeRateCurrent1);

        assertEq(shares1, shares0, "shares should stay unchanged");
        assertGe(rate1, rate0, "magma rate should not decrease");
    }

    function _ensureForkOrSkip() internal {
        try vm.activeFork() returns (uint256) {
            return;
        } catch {
            string memory url = _tryEnvString("MONAD_RPC_URL");
            if (bytes(url).length == 0) {
                vm.skip(true);
            }
            vm.createSelectFork(url);
        }
    }

    function _tryEnvString(string memory key) internal view returns (string memory) {
        try vm.envString(key) returns (string memory value) {
            return value;
        } catch {
            return "";
        }
    }
}

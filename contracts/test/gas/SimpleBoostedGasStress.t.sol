// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../../contracts/boosted/MorphoBoostedPErc20.sol";
import "../MockErc20.sol";
import "../MockInterestRateModel.sol";
import "../MockPeridottroller.sol";
import "../mocks/MockERC4626Vault.sol";

/**
 * @title SimpleBoostedGasStress
 * @notice Simplified gas stress test for boosted markets using existing test infrastructure
 */
contract SimpleBoostedGasStressTest is Test {
    MockErc20 public underlying;
    MockERC4626Vault public vault;
    MockPeridottroller public comptroller;
    MockInterestRateModel public irm;
    MorphoBoostedPErc20 public pToken;

    address[] public users;
    uint256 constant NUM_USERS = 100;
    uint256 constant INITIAL_BALANCE = 1000000e18;
    uint256 constant DEPOSIT_AMOUNT = 10000e18;

    function setUp() public {
        // Deploy mocks
        underlying = new MockErc20("Mock USD", "mUSD", 18);
        vault = new MockERC4626Vault(IERC20Metadata(address(underlying)));
        comptroller = new MockPeridottroller();
        irm = new MockInterestRateModel();

        // Deploy boosted pToken
        pToken = new MorphoBoostedPErc20(
            address(underlying),
            comptroller,
            irm,
            1e18, // initialExchangeRate
            "Peridot Morpho mUSD",
            "pmUSD",
            18,
            payable(address(this)),
            IERC4626(address(vault)),
            1e17, // 10% buffer
            0
        );

        // List market
        comptroller.setMarket(address(pToken), true, 0.75e18);

        // Create users and mint tokens
        for (uint256 i = 0; i < NUM_USERS; i++) {
            address user = address(uint160(0x10000 + i));
            users.push(user);
            underlying.mint(user, INITIAL_BALANCE);
        }
    }

    function testGas_ManyUsersMint() public {
        console.log("\n=== Many Users Mint ===");

        // First user
        uint256 firstGas = _measureMintGas(users[0], DEPOSIT_AMOUNT);
        console.log("First user mint gas:", firstGas);

        // 50th user
        for (uint256 i = 1; i < 50; i++) {
            vm.startPrank(users[i]);
            underlying.approve(address(pToken), DEPOSIT_AMOUNT);
            pToken.mint(DEPOSIT_AMOUNT);
            vm.stopPrank();
        }
        uint256 midGas = _measureMintGas(users[50], DEPOSIT_AMOUNT);
        console.log("50th user mint gas:", midGas);

        // 99th user
        for (uint256 i = 51; i < 99; i++) {
            vm.startPrank(users[i]);
            underlying.approve(address(pToken), DEPOSIT_AMOUNT);
            pToken.mint(DEPOSIT_AMOUNT);
            vm.stopPrank();
        }
        uint256 lastGas = _measureMintGas(users[99], DEPOSIT_AMOUNT);
        console.log("99th user mint gas:", lastGas);

        assertLt(lastGas, 500000, "Mint gas should stay under 500k");
        // Gas may actually decrease due to storage warm-up, so check absolute difference
        uint256 gasDiff = lastGas > firstGas
            ? lastGas - firstGas
            : firstGas - lastGas;
        assertLt(gasDiff, 200000, "Gas difference should be within 200k");
    }

    function testGas_ManyUsersRedeem() public {
        console.log("\n=== Many Users Redeem ===");

        // Setup: all users mint
        for (uint256 i = 0; i < NUM_USERS; i++) {
            vm.startPrank(users[i]);
            underlying.approve(address(pToken), DEPOSIT_AMOUNT);
            pToken.mint(DEPOSIT_AMOUNT);
            vm.stopPrank();
        }

        // Measure redeem gas
        uint256 firstRedeem = _measureRedeemGas(users[0], 5000e18);
        console.log("First redeem gas:", firstRedeem);

        for (uint256 i = 1; i < 50; i++) {
            vm.prank(users[i]);
            pToken.redeem(5000e18);
        }

        uint256 midRedeem = _measureRedeemGas(users[50], 5000e18);
        console.log("50th redeem gas:", midRedeem);

        assertLt(midRedeem, 600000, "Redeem gas should stay under 600k");
    }

    function testGas_SequentialMintsByOneUser() public {
        console.log("\n=== Sequential Mints By One User ===");

        address user = users[0];
        vm.startPrank(user);
        underlying.approve(address(pToken), type(uint256).max);

        uint256 firstMint = gasleft();
        pToken.mint(1000e18);
        firstMint = firstMint - gasleft();
        console.log("1st mint gas:", firstMint);

        for (uint256 i = 1; i < 10; i++) {
            pToken.mint(1000e18);
        }
        uint256 tenthMint = gasleft();
        pToken.mint(1000e18);
        tenthMint = tenthMint - gasleft();
        console.log("10th mint gas:", tenthMint);

        for (uint256 i = 11; i < 50; i++) {
            pToken.mint(1000e18);
        }
        uint256 fiftiethMint = gasleft();
        pToken.mint(1000e18);
        fiftiethMint = fiftiethMint - gasleft();
        console.log("50th mint gas:", fiftiethMint);

        vm.stopPrank();

        assertLt(
            fiftiethMint,
            400000,
            "Sequential mints should stay under 400k"
        );
    }

    function testGas_ExchangeRateCalculation() public {
        console.log("\n=== Exchange Rate Calculation ===");

        // Setup: many users deposit
        for (uint256 i = 0; i < 50; i++) {
            vm.startPrank(users[i]);
            underlying.approve(address(pToken), DEPOSIT_AMOUNT);
            pToken.mint(DEPOSIT_AMOUNT);
            vm.stopPrank();
        }

        // Advance time
        vm.warp(block.timestamp + 30 days);

        // Measure exchange rate calculation gas
        uint256 gasBefore = gasleft();
        uint256 rate = pToken.exchangeRateCurrent();
        uint256 exchangeGas = gasBefore - gasleft();
        console.log(
            "Exchange rate calculation gas with 50 users:",
            exchangeGas
        );
        console.log("Exchange rate:", rate);

        assertLt(exchangeGas, 200000, "Exchange rate should stay under 200k");
    }

    function testGas_AccrueInterest() public {
        console.log("\n=== Accrue Interest After Time ===");

        // Setup: many users deposit
        for (uint256 i = 0; i < NUM_USERS; i++) {
            vm.startPrank(users[i]);
            underlying.approve(address(pToken), DEPOSIT_AMOUNT);
            pToken.mint(DEPOSIT_AMOUNT);
            vm.stopPrank();
        }

        // Advance time
        vm.warp(block.timestamp + 365 days);

        // Measure accrue interest gas
        uint256 accrueGas = gasleft();
        pToken.accrueInterest();
        accrueGas = accrueGas - gasleft();
        console.log("Accrue interest gas with 100 users:", accrueGas);

        assertLt(accrueGas, 200000, "Accrue interest should stay under 200k");
    }

    function _measureMintGas(
        address user,
        uint256 amount
    ) internal returns (uint256) {
        vm.startPrank(user);
        underlying.approve(address(pToken), amount);
        uint256 gasBefore = gasleft();
        pToken.mint(amount);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();
        return gasUsed;
    }

    function _measureRedeemGas(
        address user,
        uint256 amount
    ) internal returns (uint256) {
        vm.startPrank(user);
        uint256 gasBefore = gasleft();
        pToken.redeem(amount);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();
        return gasUsed;
    }
}

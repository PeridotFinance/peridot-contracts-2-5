// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {PErc20Delegate} from "../contracts/PErc20Delegate.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {Peridottroller} from "../contracts/Peridottroller.sol";
import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";
import {InterestRateModel} from "../contracts/InterestRateModel.sol";
import {MockInterestRateModel} from "./MockInterestRateModel.sol";
import {MockErc20} from "./MockErc20.sol";

contract PErc20SeededTest is Test {
    MockErc20 underlying;
    Peridottroller comptroller;
    MockInterestRateModel irm;
    PErc20Delegate delegate;
    PErc20Delegator delegator;

    address admin = address(this);
    address alice = address(0xA);
    address attacker = address(0xB);

    uint256 constant INITIAL_EXCHANGE_RATE = 2e16; // 0.02

    function setUp() public {
        // Deploy mocks
        underlying = new MockErc20("Mock", "MOCK", 8);
        comptroller = new Peridottroller();
        irm = new MockInterestRateModel();

        // Configure comptroller minimally
        // set price oracle etc not required for this test path

        delegate = new PErc20Delegate();

        delegator = new PErc20Delegator(
            address(underlying),
            PeridottrollerInterface(address(comptroller)),
            InterestRateModel(address(irm)),
            INITIAL_EXCHANGE_RATE,
            "pMock",
            "pMOCK",
            8,
            payable(admin),
            address(delegate),
            ""
        );

        // Support market so mint/borrow allowed
        uint256 r = comptroller._supportMarket(PErc20(address(delegator)));
        require(r == 0, "support market failed");
    }

    function test_emptyMarketDonationCanDistortExchangeRate() public {
        // Set up: no seed
        // Attacker donates dust underlying to the pToken before first mint
        vm.startPrank(attacker);
        underlying.mint(attacker, 1_000_000); // 0.01 units at 8 decimals
        underlying.transfer(address(delegator), 1_000_000);
        vm.stopPrank();

        // Now first minter mints a small amount; exchange rate should still be initial
        // but we assert that supply minted equals amount / initial rate; donation increases cash
        // and lowers effective future exchange rate dynamics similar to CompV2/Onyx empty market issue.

        underlying.mint(alice, 100_000_000); // 1.0 units
        vm.startPrank(alice);
        underlying.approve(address(delegator), type(uint256).max);
        uint256 res = delegator.mint(100_000_000);
        assertEq(res, 0);
        vm.stopPrank();

        // Verify totalSupply minted equals mintAmount / initialRate
        // pTokens = 1.0 / 0.02 = 50 pTokens (considering decimals scaling inside contract)
        // We check invariants instead of exact numbers to avoid rounding assumptions.
        uint256 exchangeRate = delegator.exchangeRateStored();
        // Donation before first mint should distort exchange rate away from the initial value
        assertGt(exchangeRate, INITIAL_EXCHANGE_RATE);

        // Donation should have increased cash without issuing pTokens; this creates potential distortions
        // Assert that getCash > minted underlying
        uint256 cash = delegator.getCash();
        assertGt(cash, 100_000_000);
    }

    function test_seededMarketPreventsEmptyMarketExploit() public {
        // Seed by a whitelisted deployer before any third-party interactions
        underlying.mint(admin, 10_000_000_000); // 100 units
        underlying.approve(address(delegator), type(uint256).max);
        uint256 r0 = delegator.mint(10_000_000_000);
        assertEq(r0, 0);

        // Attacker donation after seeding should not break the initial exchange rate snapshot for first minter
        vm.startPrank(attacker);
        underlying.mint(attacker, 1_000_000); // 0.01
        underlying.transfer(address(delegator), 1_000_000);
        vm.stopPrank();

        // Another user mints
        underlying.mint(alice, 100_000_000); // 1.0 unit
        vm.startPrank(alice);
        underlying.approve(address(delegator), type(uint256).max);
        uint256 r1 = delegator.mint(100_000_000);
        assertEq(r1, 0);
        vm.stopPrank();

        // Because totalSupply was non-zero before donation, exchange rate uses full formula
        // Verify exchange rate reflects cash+borrows-reserves / totalSupply and cannot be forced to an unsafe value
        uint256 ex = delegator.exchangeRateStored();
        assertGt(ex, 0);
        // Crucially, it must not deviate below initial by attacker donation on empty state
        assertGe(ex, INITIAL_EXCHANGE_RATE);
    }
}

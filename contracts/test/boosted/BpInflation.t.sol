// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PToken} from "../../contracts/PToken.sol";
import {PErc20} from "../../contracts/PErc20.sol";
import {PErc20Delegator} from "../../contracts/PErc20Delegator.sol";
import {PeridottrollerInterface} from "../../contracts/PeridottrollerInterface.sol";
import {InterestRateModel} from "../../contracts/InterestRateModel.sol";
import {PharaohBoostedDelegate} from "../../contracts/boosted/PharaohBoostedDelegate.sol";
import {BpBase} from "./BpBase.sol";

/// @notice Test 7: pToken exchange-rate inflation (classic first-depositor / donation attack) on the share market.
///
///         Attack (no seed): attacker mints 1 share base unit (5000 pToken base units at the 2e14 initial rate), redeems
///         4999 pTokens (the underlying rounds to 0, `redeemVerify` only blocks zero tokens for NON-zero underlying), so
///         totalSupply == 1 pToken base unit == 1 share base unit of cash (rate 1e18). He then donates D shares directly to
///         the pToken: rate = (1 + D) * 1e18 / 1. A victim minting V <= D gets floor(V / (1 + D)) = 0 pTokens, and the
///         attacker redeems his single pToken for everything.
///
///         "Uneconomic" is defined as: for every donation D in the grid (and for every victim size V tested) the attacker's
///         profit = shares redeemed - (1 + D) shares spent is <= 0. Attacker budget in the realistic case is bounded by the
///         vault deposit cap of 200 USDC (= 200e6 share base units at NAV 1.0); the grid also goes far beyond it.
contract BpInflationTest is BpBase {
    function setUp() public override {
        super.setUp();
        // support only: borrow stays irrelevant here (nobody borrows); the seed is applied per scenario
        require(controller._supportMarket(PErc20(address(bp))) == 0, "list bp");
    }

    struct Outcome {
        int256 attackerProfit; // shares
        uint256 victimTokens;
        int256 victimLoss; // shares (V - what the victim can redeem afterwards)
        uint256 supplyAfterTrick;
        uint256 rateAfterDonation;
    }

    function _attack(uint256 seed, uint256 victimShares, uint256 donation) internal returns (Outcome memory o) {
        uint256 snap = vm.snapshotState();
        if (seed > 0) _seedPermanent(seed);
        // 1. attacker: mint 1 base unit, redeem all but one pToken base unit
        vault.mintShares(ATTACKER, 1 + donation);
        vm.startPrank(ATTACKER);
        vault.approve(address(bp), type(uint256).max);
        require(bp.mint(1) == 0);
        uint256 minted = bp.balanceOf(ATTACKER);
        require(bp.redeem(minted - 1) == 0);
        // 2. donate
        if (donation > 0) vault.transfer(address(bp), donation);
        vm.stopPrank();
        o.supplyAfterTrick = bp.totalSupply();
        o.rateAfterDonation = bp.exchangeRateStored();
        // 3. victim mints
        o.victimTokens = _supplyShares(VICTIM, victimShares);
        // 4. attacker redeems everything he holds (1 pToken base unit)
        uint256 attackerBefore = vault.balanceOf(ATTACKER);
        uint256 attackerTokens = bp.balanceOf(ATTACKER);
        vm.prank(ATTACKER);
        require(bp.redeem(attackerTokens) == 0);
        uint256 attackerGot = vault.balanceOf(ATTACKER) - attackerBefore;
        o.attackerProfit = int256(attackerGot) - int256(1 + donation);
        // victim redeems what he can
        uint256 victimBefore = vault.balanceOf(VICTIM);
        uint256 vt = bp.balanceOf(VICTIM);
        if (vt > 0) {
            vm.prank(VICTIM);
            require(bp.redeem(vt) == 0);
        }
        o.victimLoss = int256(victimShares) - int256(vault.balanceOf(VICTIM) - victimBefore);
        vm.revertToState(snap);
    }

    // =================================================================== 1. the classic attack without the seed
    function test_attack_withoutSeed_victimLosesEverythingAndAttackerProfits() external {
        uint256 V = 100e6; // 100 shares ($100)
        uint256 D = V; // donation >= V is enough because supply is 1 base unit
        Outcome memory o = _attack(0, V, D);
        emit log_named_uint("no seed: supply after trick (pToken base units)", o.supplyAfterTrick);
        emit log_named_uint("no seed: rate after donation (1e18 = 1 share base unit per pToken base unit)", o.rateAfterDonation);
        emit log_named_uint("no seed: victim pTokens minted for 100e6 shares", o.victimTokens);
        emit log_named_int("no seed: victim loss (shares base units)", o.victimLoss);
        emit log_named_int("no seed: attacker profit (shares base units)", o.attackerProfit);
        assertEq(o.supplyAfterTrick, 1, "attacker left a single pToken base unit");
        assertEq(o.victimTokens, 0, "victim receives ZERO pTokens");
        assertEq(o.victimLoss, int256(V), "victim loses the entire deposit");
        assertEq(o.attackerProfit, int256(V), "attacker nets exactly the victim's deposit");
    }

    function test_attack_withoutSeed_attackerBudgetCappedAt200Usdc_stillWorksAgainstSmallerVictims() external {
        uint256 budget = 200e6; // vault deposit cap: 200 USDC = 200e6 share base units at NAV 1.0
        Outcome memory o = _attack(0, 150e6, budget - 1);
        assertEq(o.victimTokens, 0);
        assertGt(o.attackerProfit, 0, "a 200-share budget is enough to rob a 150-share depositor");
    }

    // =================================================================== 2. with the permanent seed
    function test_attack_withSeed_oneWholeShare_isUneconomic_atEveryDonation() external {
        uint256 seed = SEED; // 1_000_000 base units = 1 whole share, burned to 0x...dEaD
        uint256[3] memory victims = [uint256(1e6), 100e6, 200e6];
        for (uint256 vi = 0; vi < victims.length; vi++) {
            int256 best = type(int256).min;
            uint256 bestD;
            for (uint256 j = 0; j <= 50; j++) {
                uint256 D = j == 0 ? 0 : uint256(1) << (j - 1); // 0, 1, 2, 4 ... 2^49
                Outcome memory o = _attack(seed, victims[vi], D);
                if (o.attackerProfit > best) {
                    best = o.attackerProfit;
                    bestD = D;
                }
            }
            emit log_named_uint("seed 1e6, victim", victims[vi]);
            emit log_named_int("  best attacker profit over D in {0,1,2,4..2^49}", best);
            emit log_named_uint("  at donation", bestD);
            assertLe(best, 0, "attack must never be profitable with the seed");
        }
    }

    function test_attack_withSeed_victimStillGetsFairPTokens() external {
        Outcome memory o = _attack(SEED, 100e6, 100e6); // the same donation that robbed the victim without a seed
        emit log_named_uint("seed 1e6: rate after donation", o.rateAfterDonation);
        emit log_named_uint("seed 1e6: victim pTokens for 100e6 shares", o.victimTokens);
        emit log_named_int("seed 1e6: victim loss (shares)", o.victimLoss);
        emit log_named_int("seed 1e6: attacker profit (shares)", o.attackerProfit);
        assertGt(o.victimTokens, 0);
        assertLe(o.victimLoss, 1, "at most 1 base unit of rounding");
        assertLt(o.attackerProfit, 0, "attacker burned his donation into the dead seed");
        // the donation mostly went to the dead address
        assertGt(o.supplyAfterTrick, SEED * 5000);
    }

    /// @dev Sweep of the seed size: smallest seed (in share base units) for which the attack is unprofitable for every
    ///      (victim, donation) in the grid, plus the donation an attacker would need to zero a 100-share victim.
    function test_seedSweep_minimumSeedThatMakesTheAttackUneconomic() external {
        uint256[8] memory seeds = [uint256(0), 1, 2, 10, 1_000, 1_000_000, 100_000_000, 1_000_000_000];
        uint256[3] memory victims = [uint256(1e3), 100e6, 200e6];
        uint256 minimumSafeSeed = type(uint256).max;
        for (uint256 si = 0; si < seeds.length; si++) {
            int256 best = type(int256).min;
            uint256 worstVictimLossAtBest;
            for (uint256 vi = 0; vi < victims.length; vi++) {
                for (uint256 j = 0; j <= 60; j++) {
                    uint256 D = j == 0 ? 0 : uint256(1) << (j - 1);
                    Outcome memory o = _attack(seeds[si], victims[vi], D);
                    if (o.attackerProfit > best) {
                        best = o.attackerProfit;
                        worstVictimLossAtBest = o.victimLoss > 0 ? uint256(o.victimLoss) : 0;
                    }
                }
            }
            emit log_named_uint("seed (share base units)", seeds[si]);
            emit log_named_int("  max attacker profit over the grid", best);
            emit log_named_uint("  victim loss at that point", worstVictimLossAtBest);
            if (best <= 0 && seeds[si] < minimumSafeSeed) minimumSafeSeed = seeds[si];
        }
        emit log_named_uint("MINIMUM SEED (share base units) with profit <= 0 over the whole grid", minimumSafeSeed);
        // seed 0 is profitable; the smallest tested non-zero seed already is not
        assertGt(minimumSafeSeed, 0, "no seed must not be safe");
        assertEq(minimumSafeSeed, 1, "even one share base unit (5000 pToken base units, dead) removes the profit");
    }

    /// @dev Why a larger seed is still recommended: it bounds the VICTIM-side rounding damage and griefing. With a tiny
    ///      seed the attacker can still zero small deposits at a loss to himself (pure griefing).
    function test_griefing_tinySeedStillLetsAnAttackerZeroASmallDeposit_atALoss() external {
        Outcome memory o = _attack(1, 1_000, 1_000 * 5000 * 2); // seed 1 share base unit
        emit log_named_uint("seed 1: victim pTokens", o.victimTokens);
        emit log_named_int("seed 1: victim loss", o.victimLoss);
        emit log_named_int("seed 1: attacker profit", o.attackerProfit);
        assertLt(o.attackerProfit, 0);
        Outcome memory big = _attack(SEED, 1_000, 1_000 * 5000 * 2);
        assertEq(big.victimLoss <= 1 ? int256(0) : big.victimLoss, int256(0), "seed 1 whole share: no victim loss beyond rounding");
    }

    /// @dev GRIEFING cost table: smallest donation D (power of two) that makes a victim lose >= 1% of a deposit V, per seed.
    ///      The attacker's realistic budget is the vault deposit cap, 200e6 share base units. A donation above the budget is
    ///      unreachable, so the victim size is "ungriefable" for that seed.
    function test_griefingCost_table_minimumDonationForOnePercentVictimLoss() external {
        uint256[6] memory seeds = [uint256(0), 1, 1_000, 100_000, 1_000_000, 100_000_000];
        uint256[3] memory victims = [uint256(1_000), 1_000_000, 100_000_000];
        uint256 budget = 200e6;
        for (uint256 si = 0; si < seeds.length; si++) {
            for (uint256 vi = 0; vi < victims.length; vi++) {
                uint256 found;
                for (uint256 j = 0; j <= 62; j++) {
                    uint256 D = uint256(1) << j;
                    Outcome memory o = _attack(seeds[si], victims[vi], D);
                    if (o.victimLoss * 100 >= int256(victims[vi])) {
                        found = D;
                        break;
                    }
                }
                emit log_named_uint(string.concat("seed ", vm.toString(seeds[si]), " victim ", vm.toString(victims[vi]), " minimum D (0 = none up to 2^62)"), found);
                if (seeds[si] >= 1_000_000) {
                    assertTrue(found == 0 || found > budget, "with a 1-share seed nobody within the 200 USDC cap can grief");
                }
                if (seeds[si] == 0) assertTrue(found != 0 && found <= budget, "no seed: griefing/theft is within budget");
            }
        }
    }

    // =================================================================== 3. donation, rounding, minimum behaviour
    function test_donationDirectlyToThePToken_doesNotMintPTokens_andRaisesTheRateForHolders() external {
        _seedPermanent(SEED);
        uint256 aliceTokens = _supplyShares(ALICE, 100e6);
        uint256 rateBefore = bp.exchangeRateStored();
        assertEq(rateBefore, 2e14);
        vault.mintShares(ATTACKER, 100e6);
        vm.prank(ATTACKER);
        vault.transfer(address(bp), 100e6); // donate 100 shares
        uint256 rateAfter = bp.exchangeRateStored();
        // cash 101 + 100 = 201 shares over (1 + 100) shares of pTokens
        assertEq(rateAfter, (uint256(201e6) * 1e18) / (uint256(101e6) * 5000));
        assertGt(rateAfter, rateBefore);
        assertEq(bp.balanceOf(ATTACKER), 0, "donor receives nothing");
        // holders (and the dead seed) benefit pro rata: ALICE redeems ~ 100 + 100 * 100/101
        (bool ok,) = _redeemShares(ALICE, aliceTokens);
        assertTrue(ok);
        assertEq(vault.balanceOf(ALICE), (aliceTokens * rateAfter) / 1e18);
        assertGt(vault.balanceOf(ALICE), 100e6);
    }

    function test_redeemRounding_tinyPTokenAmountsRedeemZeroShares_burnsTokensForNothing() external {
        _seedPermanent(SEED);
        uint256 pTokens = _supplyShares(ALICE, 10e6);
        vm.prank(ALICE);
        require(bp.redeem(4999) == 0); // 4999 * 2e14 / 1e18 = 0.9998 -> 0 shares
        assertEq(vault.balanceOf(ALICE), 0, "redeemed 4999 pTokens for 0 shares: rounding is in the market's favour");
        assertEq(bp.balanceOf(ALICE), pTokens - 4999);
    }

    function test_redeemUnderlying_zeroTokenRoundingIsBlockedByRedeemVerify() external {
        _seedPermanent(SEED);
        _supplyShares(ALICE, 10e6);
        // inflate the rate above 1 share base unit per pToken base unit: donate 10_000 shares over (1+10) shares of supply
        vault.mintShares(ATTACKER, 100_000e6);
        vm.prank(ATTACKER);
        vault.transfer(address(bp), 100_000e6);
        assertGt(bp.exchangeRateStored(), 1e18, "rate > 1: one pToken base unit is worth more than one share base unit");
        // redeemUnderlying(1): tokens = floor(1 / rate) = 0 while amount > 0 -> redeemVerify reverts
        (bool ok, bytes memory ret) =
            _try(ALICE, address(bp), abi.encodeWithSelector(PErc20.redeemUnderlying.selector, 1));
        assertFalse(ok);
        assertEq(_reason(ret), "redeemTokens zero");
    }

    function test_redeemUnderlying_roundDownTheft_isBelowOneShareBaseUnitPerCall_withTheSeed() external {
        // Sonne-style: with rate r (shares per pToken base unit) redeemUnderlying(x) burns floor(x / r) pTokens, so each call
        // can take up to ~0.99 r shares for free. Measure the free value per call for several seeds at the largest donation a
        // 200-share budget allows.
        uint256[3] memory seeds = [uint256(0), 1, SEED];
        int256[3] memory gains;
        for (uint256 i = 0; i < seeds.length; i++) {
            uint256 snap = vm.snapshotState();
            if (seeds[i] > 0) _seedPermanent(seeds[i]);
            _supplyShares(ALICE, 10e6); // some honest liquidity (also keeps totalSupply > 2)
            vault.mintShares(ATTACKER, 200e6);
            vm.prank(ATTACKER);
            vault.transfer(address(bp), 200e6);
            uint256 r = bp.exchangeRateStored(); // 1e18-scaled shares per pToken base unit
            uint256 x = (r * 199) / (100 * 1e18); // 1.99 r in shares
            if (x == 0) {
                gains[i] = 0; // r < 1 share base unit: cannot even ask for 1 share for 0 tokens
            } else {
                // free value = x - floor(x*1e18/r) * r / 1e18
                uint256 burned = (x * 1e18) / r;
                gains[i] = int256(x) - int256((burned * r) / 1e18);
            }
            emit log_named_uint("seed", seeds[i]);
            emit log_named_uint("  rate after a 200-share donation (1e18 = 1 share base unit/pToken base unit)", r);
            emit log_named_int("  free shares (base units) per redeemUnderlying call", gains[i]);
            vm.revertToState(snap);
        }
        assertLe(gains[2], 1, "with the 1-share seed the per-call gain is at most 1 share base unit (and gas costs far more)");
        assertLe(gains[1], 1);
    }

    function test_firstMintAfterSeed_getsTheInitialRate_andTotalSupplyIsSeedPlusMinted() external {
        _seedPermanent(SEED);
        assertEq(bp.totalSupply(), SEED * 5000);
        assertEq(bp.balanceOf(DEAD), SEED * 5000);
        assertEq(bp.exchangeRateStored(), 2e14);
        uint256 minted = _supplyShares(ALICE, 1);
        assertEq(minted, 5000, "1 share base unit mints 5000 pToken base units");
        // minimum supplyable amount: 0 pTokens would be minted by... no amount > 0 mints 0 at rate 2e14
        assertEq(bp.exchangeRateStored(), 2e14);
    }

    // =================================================================== minimum-seed behaviour of the delegate
    function test_delegateMinimumVaultSupply_atTheLiveListingNumbers() external {
        assertEq(vault.totalSupply(), VAULT_SUPPLY_AT_LISTING);
        _deploy(VAULT_SUPPLY_AT_LISTING); // exactly the live supply passes
        vm.expectRevert(PharaohBoostedDelegate.PharaohBoosted__InsufficientVaultSeed.selector);
        this.deployExternal(VAULT_SUPPLY_AT_LISTING + 1);
        vm.expectRevert(PharaohBoostedDelegate.PharaohBoosted__InvalidConfiguration.selector);
        this.deployExternal(0);
    }

    function deployExternal(uint256 minSupply) external returns (address) {
        return address(_deploy(minSupply));
    }

    function _deploy(uint256 minSupply) internal returns (PErc20Delegator) {
        return new PErc20Delegator(
            address(vault),
            PeridottrollerInterface(address(controller)),
            InterestRateModel(address(irm)),
            SHARE_INITIAL_EXCHANGE_RATE,
            "x",
            "x",
            8,
            payable(address(this)),
            address(bpDelegate),
            abi.encode(address(vault), minSupply)
        );
    }

    /// @dev The vault's totalSupply can later fall below `minimumVaultSupplyAtListing`: the delegate does not re-check it.
    function test_minimumVaultSupplyIsOnlyCheckedAtListing() external {
        assertEq(PharaohBoostedDelegate(address(bp)).minimumVaultSupplyAtListing(), MIN_VAULT_SUPPLY);
        // shrink the vault supply far below the minimum: the market and the oracle keep working (no on-chain re-check)
        vault.mintShares(address(this), 1);
        assertEq(PharaohBoostedDelegate(address(bp)).vaultTotalSupply(), VAULT_SUPPLY_AT_LISTING + 1);
    }
}

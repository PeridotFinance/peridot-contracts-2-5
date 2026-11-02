// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    TrackAVaultsBase,
    ITAVault,
    ITAGauge,
    ITAPositionManager,
    ITAOwnable,
    ITASafe,
    ITAOracle
} from "./helpers/AvalancheTrackAVaultsBase.sol";

/**
 * Handoff 09 TRACK A launch-gate evidence for the two EXISTING Pharaoh ERC-4626 vaults on Avalanche mainnet.
 *
 * Fork tests only. Every owner/rebalancer action is a forge `vm.prank` in the LOCAL VM; nothing is signed or
 * broadcast. No cap change is proposed: `_openCap` only opens a test cap inside the forked state so deposits can run.
 *
 * Tests named `testFinding_*` assert the CURRENT (unfavourable) behaviour so the suite stays green while the finding is
 * documented; each is paired with a control/mutation that proves the assertion can distinguish fair from unfair.
 * Numbers are printed with console2 (run with -vv) and are copied into docs/deployment-handoffs/avalanche-track-a-launch-gate.md.
 *
 * Run (one pinned block per suite; the public node only serves recent state, so the pin must be re-chosen when the
 * foundry rpc cache for it is missing; see the doc):
 *   AVALANCHE_MAINNET_RPC_URL=https://avalanche-c-chain-rpc.publicnode.com FOUNDRY_OUT=out_tracka \
 *   FOUNDRY_CACHE_PATH=cache_tracka FOUNDRY_PROFILE=debt_accounting forge test --threads 1 -vv \
 *   --match-path test/AvalancheTrackAVaultsFork.t.sol \
 *   --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol
 */
abstract contract TrackACore is TrackAVaultsBase {
    function _expectedAsset() internal pure virtual returns (address);
    function _expectedPaired() internal pure virtual returns (address);
    function _stressTicks() internal pure virtual returns (int24[] memory);
    function _feeAliceUsd() internal pure virtual returns (uint256);
    function _feeLegUsd() internal pure virtual returns (uint256);
    function _feeRounds() internal pure virtual returns (uint256);

    uint256[5] internal LADDER = [uint256(1_000), 10_000, 50_000, 100_000, 250_000];

    // ================================================================= 00 address map and behaviour discovery
    function test_00_addressMapAndConfig() public view {
        address implSlot = address(uint160(uint256(vm.load(address(v), IMPL_SLOT))));
        address adminSlot = address(uint160(uint256(vm.load(address(v), ADMIN_SLOT))));
        console2.log(_label());
        console2.log(string.concat(" vault        ", " ", _ta(address(v))));
        console2.log(string.concat(" impl (ERC1967)", " ", _ta(implSlot)));
        console2.log(string.concat(" proxyAdmin    ", " ", _ta(adminSlot)));
        console2.log(string.concat(" proxyAdmin.owner", " ", _ta(ITAOwnable(adminSlot).owner())));
        console2.log(string.concat(" vault.owner   ", " ", _ta(v.owner())));
        console2.log(string.concat(" rebalancer    ", " ", _ta(v.rebalancer())));
        console2.log(string.concat(" asset         ", " ", _ta(address(asset))));
        console2.log(string.concat(" paired        ", " ", _ta(address(paired))));
        console2.log(string.concat(" pool          ", " ", _ta(address(pool))));
        console2.log(string.concat(" gauge         ", " ", _ta(gauge)));
        console2.log(string.concat(" oracle        ", " ", _ta(oracleAddr)));
        console2.log(string.concat(" positionMgr   ", " ", _ta(v.positionManager())));
        console2.log(string.concat(" tokenId       ", " ", _t(v.tokenId())));
        console2.log(string.concat(" ticks lower/upper", " ", _ti(int256(v.positionTickLower())), " ", _ti(int256(v.positionTickUpper()))));
        console2.log(string.concat(" spot tick     ", " ", _ti(int256(_spotTick()))));
        console2.log(string.concat(" pool fee(ppm) ", " ", _t(pool.fee())));
        console2.log(string.concat(" pool liquidity", " ", _t(uint256(pool.liquidity()))));
        console2.log(string.concat(" paused        ", " ", _tb(v.paused())));
        console2.log(string.concat(" depositCap    ", " ", _t(v.depositCap())));
        console2.log(string.concat(" totalAssets   ", " ", _t(v.totalAssets())));
        console2.log(string.concat(" totalSupply   ", " ", _t(v.totalSupply())));
        console2.log(string.concat(" maxDeposit(alice)", " ", _t(v.maxDeposit(ALICE))));
        console2.log(string.concat(" twap/maxTwapTicks/maxOracleBps", " ", _t(uint256(v.twapPeriod())), " ", _t(uint256(v.maxTwapDeviationTicks())), " ", _t(uint256(v.maxOracleDeviationBps()))));
        console2.log(string.concat(" slippage/haircut bps", " ", _t(uint256(v.slippageBps())), " ", _t(uint256(v.valuationHaircutBps()))));
        console2.log(string.concat(" PHAR earned (gauge, tokenId)", " ", _t(ITAGauge(gauge).earned(PHAR, v.tokenId()))));
        console2.log(string.concat(" PHAR held by vault", " ", _t(IERC20(PHAR).balanceOf(address(v)))));

        assertEq(address(v), _vaultAddress());
        assertEq(address(asset), _expectedAsset(), "asset label");
        assertEq(address(paired), _expectedPaired(), "paired label");
        assertEq(implSlot, EXT_IMPL, "proxy implementation is the reward extension");
        assertEq(BASE_IMPL.codehash, BASE_CODEHASH, "extension's pinned base implementation");
        assertEq(ITAOwnable(adminSlot).owner(), SAFE, "proxy admin owner (upgrade authority)");
        assertEq(v.owner(), SAFE, "vault owner");
        assertEq(v.rebalancer(), REBALANCER, "rebalancer");
        assertEq(v.positionManager(), POSITION_MANAGER);
        assertEq(ITAPositionManager(POSITION_MANAGER).ownerOf(v.tokenId()), address(v), "NFT held by vault");
        assertEq(pool.token0(), address(v.assetIsToken0() ? asset : paired));
        assertTrue(gauge != address(0), "pool has a gauge");
        assertFalse(v.paused(), "vault unpaused at pin");
        assertEq(v.maxDeposit(ALICE), 0, "deposits gated at 0 at the pin");
        assertEq(v.maxMint(ALICE), 0, "mint disabled");
        assertEq(v.balanceOf(SAFE), v.totalSupply(), "Safe holds 100% of the seed shares");
        // Safe is 1-of-1 and its only signer is the rebalancer address
        address[] memory owners = ITASafe(SAFE).getOwners();
        assertEq(owners.length, 1);
        assertEq(owners[0], REBALANCER, "Safe's single signer is the rebalancer address");
        assertEq(ITASafe(SAFE).getThreshold(), 1);
        assertEq(REBALANCER.code.length, 0, "rebalancer is an EOA");
    }

    // ================================================================= 01 who may call what
    function test_01_accessMatrix() public {
        // strangers
        _expectRevertSel(ALICE, abi.encodeCall(ITAVault.deployIdle, ()), "Vault__NotRebalancer");
        _expectRevertSel(ALICE, abi.encodeCall(ITAVault.rebalance, ()), "Vault__NotRebalancer");
        _expectRevertSel(ALICE, abi.encodeCall(ITAVault.emergencyExit, ()), "OwnableUnauthorizedAccount");
        _expectRevertSel(ALICE, abi.encodeCall(ITAVault.setDepositCap, (type(uint256).max)), "OwnableUnauthorizedAccount");
        _expectRevertSel(ALICE, abi.encodeCall(ITAVault.pause, ()), "OwnableUnauthorizedAccount");
        _expectRevertSel(ALICE, abi.encodeCall(ITAVault.setRebalancer, (ALICE)), "OwnableUnauthorizedAccount");
        _expectRevertSel(ALICE, abi.encodeCall(ITAVault.harvestRewards, (true, 0)), "OwnableUnauthorizedAccount");
        // the rebalancer address (NOT the Safe contract) at vault level: keeper functions only
        _expectRevertSel(REBALANCER, abi.encodeCall(ITAVault.setDepositCap, (type(uint256).max)), "OwnableUnauthorizedAccount");
        _expectRevertSel(REBALANCER, abi.encodeCall(ITAVault.harvestRewards, (true, 0)), "OwnableUnauthorizedAccount");
        _expectRevertSel(REBALANCER, abi.encodeCall(ITAVault.emergencyExit, ()), "OwnableUnauthorizedAccount");
        _expectRevertSel(REBALANCER, abi.encodeCall(ITAVault.pause, ()), "OwnableUnauthorizedAccount");
        // the rebalancer is accepted by the keeper modifier (it reaches the body: success OR a body revert that is not NotRebalancer)
        (bool ok, bytes memory ret) = _try(REBALANCER, address(v), abi.encodeCall(ITAVault.deployIdle, ()));
        console2.log(string.concat(" rebalancer.deployIdle:", " ", _short(ok, ret)));
        assertTrue(ok || keccak256(bytes(_err(ret))) != keccak256("Vault__NotRebalancer"));
        // the owner is also accepted by onlyRebalancer
        (ok, ret) = _try(SAFE, address(v), abi.encodeCall(ITAVault.deployIdle, ()));
        console2.log(string.concat(" owner.deployIdle:", " ", _short(ok, ret)));
        assertTrue(ok || keccak256(bytes(_err(ret))) != keccak256("Vault__NotRebalancer"));
        // public (permissionless) entries: deposit / redeem / redeemInKind (not harvest: there is no public harvest)
        assertEq(v.maxDeposit(ALICE), 0);
    }

    function _expectRevertSel(address who, bytes memory data, string memory name) internal {
        (bool ok, bytes memory ret) = _try(who, address(v), data);
        assertFalse(ok, string.concat("should revert: ", name));
        assertEq(_err(ret), name);
    }

    // ================================================================= 02 swap fees: no capture by a late depositor (PASS expected)
    function test_02_feeFairness_lateDepositorDoesNotCaptureAccruedFees() public {
        _openCap(5_000_000);
        uint256 X = _usdToAsset(_feeAliceUsd());
        (bool ok, uint256 aShares, bytes memory eDep) = _depositAs(ALICE, X);
        require(ok, string.concat("alice deposit: ", _err(eDep)));

        int24 tickBefore = _spotTick();
        uint256 vol = _generateFees(_feeRounds(), _usdToAsset(_feeLegUsd()));
        console2.log(string.concat(" fee volume (asset units)", " ", _t(vol)));
        console2.log(string.concat(" tick drift after ping-pong", " ", _ti(int256(_spotTick()) - int256(tickBefore))));

        uint256 snap = vm.snapshotState();
        uint256 supply0 = v.totalSupply();
        uint256 vPre = v.totalAssets(); // uncollected fees are NOT in totalAssets
        // CONTROL: no Bob. A keeper deployIdle collects fees and redeploys them.
        vm.prank(REBALANCER);
        v.deployIdle();
        uint256 vPost = v.totalAssets();
        uint256 ppsCtl = _pps();
        uint256 aliceCtl = v.convertToAssets(aShares);
        console2.log(string.concat(" NAV before fee collect", " ", _t(vPre)));
        console2.log(string.concat(" NAV after  fee collect", " ", _t(vPost)));
        uint256 feesAccrued = vPost > vPre ? vPost - vPre : 0;
        console2.log(string.concat(" accrued fees visible only after collect", " ", _t(feesAccrued)));
        assertGt(vPost, vPre, "fees were accrued off-NAV before the collect (measurable)");
        vm.revertToState(snap);

        // TEST: Bob deposits the same amount Alice did, right before the collect would have happened, then exits at once
        uint256 Y = X;
        (bool okB, uint256 bShares, bytes memory eDepB) = _depositAs(BOB, Y);
        require(okB, string.concat("bob deposit: ", _err(eDepB)));
        uint256 bobValueAtEntry = v.convertToAssets(bShares);
        (bool okR, uint256 bOut, bytes memory e) = _redeemAs(BOB, bShares);
        require(okR, _err(e));
        uint256 ppsT = _pps();
        uint256 aliceT = v.convertToAssets(aShares);
        console2.log(string.concat(" Bob deposit", " ", _t(Y)));
        console2.log(string.concat(" Bob NAV value right after deposit", " ", _t(bobValueAtEntry)));
        console2.log(string.concat(" Bob redeemed", " ", _t(bOut)));
        console2.log(string.concat(" Bob round-trip loss bps", " ", _ti(_lossBps(Y, bOut))));
        console2.log(string.concat(" Alice value  control / with-Bob", " ", _t(aliceCtl), " ", _t(aliceT)));
        console2.log(string.concat(" PPS control / with-Bob (1e18)", " ", _t(ppsCtl), " ", _t(ppsT)));

        // PASS 1: Alice is not diluted by Bob's visit (within 0.1 bp of the no-Bob control)
        assertGe(aliceT * 1_000_000, aliceCtl * (1_000_000 - 10), "Alice diluted by Bob");
        // PASS 2: Bob cannot profit from fees accrued before he joined
        assertLe(bOut, Y, "Bob profited at entry/exit");

        // MUTATION: price Bob on the PRE-collect NAV (a vault that did not collect fees before minting). The same
        // measure must then flag a violation, proving the PASS above is not vacuous.
        uint256 netY = bobValueAtEntry; // Bob's measured net contribution
        uint256 naiveShares = Math.mulDiv(netY, supply0 + 1, vPre + 1);
        uint256 naiveValue = Math.mulDiv(naiveShares, vPost + netY, supply0 + naiveShares);
        int256 naiveGain = int256(naiveValue) - int256(netY);
        console2.log(string.concat(" MUTATION naive-pricing Bob gain (asset units)", " ", _ti(naiveGain)));
        assertGt(naiveGain, 0, "mutation not detected: fee-capture measure is vacuous");
        // and the shipped behaviour is strictly better than the mutation
        assertLt(int256(bOut) - int256(Y), naiveGain, "shipped vault no better than naive");
    }


    // ================================================================= 02b swap fees: an exiting depositor keeps the fees accrued while he held (PASS expected)
    function test_02b_feeFairness_exitKeepsAccruedFees() public {
        _openCap(5_000_000);
        uint256 X = _usdToAsset(_feeAliceUsd());
        (bool ok, uint256 aShares, bytes memory e0) = _depositAs(ALICE, X);
        require(ok, string.concat("alice: ", _err(e0)));
        (bool okB, uint256 bShares, bytes memory e1) = _depositAs(BOB, X);
        require(okB, string.concat("bob: ", _err(e1)));
        uint256 bobNavEntry = v.convertToAssets(bShares);
        uint256 supply = v.totalSupply();
        _generateFees(_feeRounds(), _usdToAsset(_feeLegUsd())); // fees accrue while Bob is a holder
        uint256 snap = vm.snapshotState();
        uint256 navPre = v.totalAssets(); // uncollected fees excluded
        vm.prank(SAFE);
        v.redeem(1, SAFE, SAFE); // control: any redeem collects fees WITHOUT deploying idle assets (1 seed share, ~1e-8 of supply)
        uint256 F = v.totalAssets() - navPre;
        vm.revertToState(snap);
        (bool okR, uint256 out, bytes memory eR) = _redeemAs(BOB, bShares);
        require(okR, _err(eR));
        uint256 expectedFee = Math.mulDiv(F, bShares, supply);
        uint256 gain = out > bobNavEntry ? out - bobNavEntry : 0;
        console2.log(string.concat(" total fees F (NAV units) ", _t(F), "; Bob's pro-rata share of supply (bps) ", _t(_bps(bShares, supply))));
        console2.log(string.concat(" Bob's expected fee share ", _t(expectedFee), "; Bob's actual gain at exit ", _t(gain), " (entry NAV ", _t(bobNavEntry), " exit ", _t(out), ")"));
        aShares;
        assertGt(expectedFee, 0, "no fees accrued: test would be vacuous");
        assertGe(gain * 100, expectedFee * 95, "exiting holder lost part of his accrued fees");
        // MUTATION: a vault that did not collect fees before burning would pay the entry NAV (gain 0): the same check must flag it
        assertLt(uint256(0) * 100, expectedFee * 95, "mutation not detected");
    }

    // ================================================================= 03 PHAR rewards, entry: late depositor captures earlier rewards (FINDING)
    function testFinding_03_rewardSnipingAtEntry() public {
        _openCap(5_000_000);
        uint256 tid = v.tokenId();
        uint256 earnedAtPin = ITAGauge(gauge).earned(PHAR, tid);
        uint256 vaultPharPin = IERC20(PHAR).balanceOf(address(v));
        uint256 D = _usdToAsset(100); // stand-in for the sale proceeds of the accrued PHAR (price not on-chain here)

        uint256 snap = vm.snapshotState();
        // ---- ORDER A (the exploitable one): Bob joins while PHAR is accrued but unharvested, Safe harvests+donates later
        uint256 Y = _usdToAsset(_bobUsd());
        (bool ok, uint256 bShares, bytes memory eDep) = _depositAs(BOB, Y);
        require(ok, string.concat("bob deposit: ", _err(eDep)));
        uint256 pharInVault = IERC20(PHAR).balanceOf(address(v));
        console2.log(string.concat(" PHAR earned by position at pin", " ", _t(earnedAtPin)));
        console2.log(string.concat(" PHAR in vault after Bob's deposit (auto-claimed by increaseLiquidity)", " ", _t(pharInVault)));
        assertGe(pharInVault, vaultPharPin + earnedAtPin, "increaseLiquidity pulled the accrued PHAR into the vault, outside NAV");
        uint256 bobBefore = v.convertToAssets(bShares);
        vm.prank(SAFE); // LOCAL VM ONLY
        (uint256 forwarded,) = v.harvestRewards(false, 0);
        assertEq(forwarded, pharInVault, "harvest forwards all PHAR to the Safe (off-chain swap-and-donation policy)");
        deal(address(asset), SAFE, D);
        vm.prank(SAFE);
        asset.transfer(address(v), D); // the donation leg of the documented Safe batch
        uint256 bobAfter = v.convertToAssets(bShares);
        uint256 captured = bobAfter - bobBefore;
        uint256 captureBps = _bps(captured, D);
        console2.log(string.concat(" Bob's shares of supply (bps)", " ", _t(_bps(bShares, v.totalSupply()))));
        console2.log(string.concat(" donation D", " ", _t(D)));
        console2.log(string.concat(" Bob captured from D, bps (fair = 0)", " ", _t(captureBps)));
        assertGt(captureBps, 9_000, "FINDING: a depositor joining before the donation captures the earlier rewards");
        vm.revertToState(snap);

        // ---- ORDER B (control): harvest + donate first, Bob joins after => Bob captures ~0. The assertion is order-sensitive.
        vm.prank(SAFE);
        v.harvestRewards(true, 0);
        deal(address(asset), SAFE, D);
        vm.prank(SAFE);
        asset.transfer(address(v), D);
        (ok, bShares,) = _depositAs(BOB, Y);
        require(ok, "bob deposit B");
        uint256 bobValueB = v.convertToAssets(bShares);
        console2.log(string.concat(" CONTROL (harvest+donate before Bob): Bob value / deposit", " ", _t(bobValueB), " ", _t(Y)));
        assertLe(bobValueB, Y, "control: Bob must not gain when the donation precedes his entry");
        // nothing in the contract enforces order B: harvestRewards is onlyOwner but deposit() is permissionless and
        // increaseLiquidity re-pulls PHAR into the vault on EVERY deposit/withdraw.
    }

    // ================================================================= 04 PHAR rewards, exit: leaver forfeits accrued rewards (FINDING)
    function testFinding_04_rewardForfeitAtExit() public {
        _openCap(5_000_000);
        _etchFreshOracle(); // keep the oracle fresh across warp
        uint256 tid = v.tokenId();
        uint256 Y = _usdToAsset(_bobUsd());
        (bool ok, uint256 bShares, bytes memory eDep) = _depositAs(BOB, Y);
        require(ok, string.concat("bob deposit: ", _err(eDep)));
        uint256 earnedJoin = ITAGauge(gauge).earned(PHAR, tid);
        uint256 pharAtJoin = IERC20(PHAR).balanceOf(address(v)); // includes PHAR accrued before Bob, claimed by his deposit
        uint256 supplyShareBps = _bps(bShares, v.totalSupply());
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 43_200);
        uint256 earnedHeld = ITAGauge(gauge).earned(PHAR, tid);
        console2.log(string.concat(" Bob's share of supply, bps", " ", _t(supplyShareBps)));
        console2.log(string.concat(" PHAR earned by position at Bob's join / after 1 day", " ", _t(earnedJoin), " ", _t(earnedHeld)));
        (bool okR, uint256 out, bytes memory e) = _redeemAs(BOB, bShares);
        require(okR, _err(e));
        uint256 bobPhar = IERC20(PHAR).balanceOf(BOB);
        uint256 pharStuck = IERC20(PHAR).balanceOf(address(v));
        console2.log(string.concat(" Bob redeemed asset", " ", _t(out)));
        console2.log(string.concat(" Bob PHAR received", " ", _t(bobPhar)));
        console2.log(string.concat(" PHAR left in vault for the Safe/remaining holders", " ", _t(pharStuck)));
        assertEq(bobPhar, 0, "exit pays no PHAR");
        assertGt(pharStuck, pharAtJoin, "FINDING: reward accrued while Bob held ~all liquidity is claimed into the vault on his exit and not paid to him");
        // control for the measure: a holder entitled pro rata would be owed ~supplyShareBps of (pharStuck - earnedJoin)
        uint256 owedApprox = Math.mulDiv(pharStuck - pharAtJoin, supplyShareBps, 10_000);
        console2.log(string.concat(" Bob's approximate pro-rata entitlement forfeited (PHAR wei)", " ", _t(owedApprox)));
        assertGt(owedApprox, 0);
    }

    // ================================================================= 05 donation / inflation / rounding
    function test_05_donationInflationAndRounding() public {
        _openCap(5_000_000);
        uint256 C = _usdToAsset(_bobUsd());
        uint256 Y = _usdToAsset(_bobUsd());
        uint256 snap = vm.snapshotState();

        // baseline WITHOUT donation: Carol (future attacker) deposits, Bob (victim) deposits
        (bool ok, uint256 cs0, bytes memory eC) = _depositAs(CAROL, C);
        require(ok, string.concat("carol: ", _err(eC)));
        (bool okB0, uint256 bs0, bytes memory eB0) = _depositAs(BOB, Y);
        require(okB0, string.concat("bob: ", _err(eB0)));
        uint256 baseValue = v.convertToAssets(bs0);
        console2.log(string.concat(" baseline (no donation) Bob NAV value / deposit ", _t(baseValue), " ", _t(Y)));
        cs0;
        vm.revertToState(snap);
        snap = vm.snapshotState();

        uint256[4] memory donations = [uint256(1), _usdToAsset(100), _usdToAsset(10_000), _usdToAsset(1_000_000)];
        for (uint256 i; i < donations.length; ++i) {
            uint256 D = donations[i];
            (bool okC, uint256 cShares,) = _depositAs(CAROL, C); // attacker holds shares
            require(okC, "carol deposit");
            uint256 ppsBefore = _pps();
            deal(address(asset), CAROL, D);
            vm.prank(CAROL);
            asset.transfer(address(v), D); // donation straight to the vault
            uint256 ppsAfter = _pps();
            console2.log(string.concat(" donation D ", _t(D), ": PPS before/after (1e18) ", _t(ppsBefore), " ", _t(ppsAfter)));
            (bool okV, uint256 bShares, bytes memory eV) = _depositAs(BOB, Y);
            if (!okV) {
                console2.log(string.concat("   victim deposit REVERTS after donation: ", _err(eV)));
                // the keeper can clear it: deployIdle() deploys the donated idle asset at the keeper's call, not a depositor's
                vm.prank(REBALANCER);
                (bool okK,) = address(v).call(abi.encodeCall(ITAVault.deployIdle, ()));
                (okV, bShares, eV) = _depositAs(BOB, Y);
                console2.log(string.concat("   after keeper deployIdle(): keeper ok=", _tb(okK), "; victim deposit ", _short(okV, eV)));
                vm.prank(REBALANCER);
                (bool okRb, bytes memory eRb) = address(v).call(abi.encodeCall(ITAVault.rebalance, ()));
                console2.log(string.concat("   keeper rebalance() with the donated idle asset: ", _short(okRb, eRb)));
                (bool okW, uint256 gW,) = _redeemAs(CAROL, cShares);
                console2.log(string.concat("   existing holder can still redeem (idle asset covers it): ", _tb(okW), " got ", _t(gW)));
            }
            if (okV) {
                uint256 bobValue = v.convertToAssets(bShares);
                (bool okR, uint256 cOut,) = _redeemAs(CAROL, cShares);
                require(okR, "carol redeem");
                int256 attackerPnL = int256(cOut) - int256(C) - int256(D);
                int256 victimExtraLossBps = _lossBps(baseValue, bobValue);
                console2.log(string.concat("   victim extra loss vs no-donation baseline, bps ", _ti(victimExtraLossBps)));
                console2.log(string.concat("   attacker PnL (asset units, negative = loses) ", _ti(attackerPnL)));
                assertLt(attackerPnL, 0, "donation attack profitable");
                // small donations: no measurable effect on the victim. A donation that is large relative to the victim's
                // deposit is taxed onto him (he pays to deploy the donated idle asset): logged, asserted only for small D.
                assertLe(victimExtraLossBps, 500, "donation cost the victim more than 5%");
            }
            vm.revertToState(snap);
            snap = vm.snapshotState();
        }

        // rounding / dust deposits
        uint256[5] memory dust = [uint256(1), 2, 10, 100, 1_000];
        for (uint256 i; i < dust.length; ++i) {
            uint256 a = dust[i];
            uint256 prev;
            try v.previewDeposit(a) returns (uint256 pv) {
                prev = pv;
            } catch {}
            (bool okD, uint256 sh, bytes memory e) = _depositAs(BOB, a);
            console2.log(string.concat(" dust deposit units ", _t(a), " previewShares ", _t(prev), " result ", _short(okD, e), okD ? string.concat(" shares ", _t(sh)) : ""));
            if (okD) {
                uint256 worth = v.convertToAssets(sh);
                console2.log(string.concat("   shares worth (asset units) ", _t(worth), worth > a ? string.concat(" => depositor gains ", _t(worth - a), " (deploy-time NAV step of pre-existing idle assets)") : ""));
                assertLe(worth, a + aUnit / 100, "dust deposit gained more than 1% of a token unit");
            }
            vm.revertToState(snap);
            snap = vm.snapshotState();
        }
        // the share price cannot be reduced by dust redemptions: redeem 1 share
        (bool okD2,,) = _depositAs(BOB, Y);
        require(okD2);
        uint256 ppsPre = _pps();
        (bool okR2, uint256 got1,) = _redeemAs(BOB, 1);
        console2.log(string.concat(" redeem 1 share: ok=", _tb(okR2), " assets ", _t(got1)));
        assertGe(_pps() + 1, ppsPre, "dust redeem lowered PPS");
    }

    function _bobUsd() internal pure virtual returns (uint256);

    // ================================================================= position builder (a whale enters in chunks)
    /// @dev Builds a position of `S` asset units for `who` with several deposits, restoring the pool price between
    ///      chunks (an arbitrageur would). The chunk is halved when a deposit fails (swap slippage bound). Returns the
    ///      shares minted, the number of chunks and the final chunk size.
    function _buildPosition(address who, uint256 S, uint256 chunk0)
        internal
        returns (uint256 shares, uint256 nChunks, uint256 chunkUsed, string memory firstFail)
    {
        uint256 remaining = S;
        uint256 chunk = chunk0 < S ? chunk0 : S;
        int24 t0 = _spotTick();
        uint256 minChunk = _usdToAsset(100);
        while (remaining > 0) {
            uint256 amt = remaining < chunk ? remaining : chunk;
            (bool ok, uint256 sh, bytes memory e) = _depositAs(who, amt);
            if (!ok) {
                if (bytes(firstFail).length == 0) firstFail = _err(e);
                chunk = amt / 2;
                require(chunk >= minChunk, string.concat("cannot build position: ", _err(e)));
                continue;
            }
            shares += sh;
            remaining -= amt;
            ++nChunks;
            if (chunkUsed == 0 || amt > chunkUsed) chunkUsed = amt;
            if (_spotTick() != t0) _moveToTick(t0); // arbitrage restores the pool price between chunks
        }
    }

    /// @dev Largest single redeem that succeeds, trying 8/8, 7/8, 6/8, 5/8, 4/8, then 1/4, 1/8 ... 1/64 of `shares`.
    function _exitProbe(address who, uint256 shares, uint256 S) internal {
        uint256[10] memory num = [uint256(8), 7, 6, 5, 4, 2, 1, 1, 1, 1];
        uint256[10] memory den = [uint256(8), 8, 8, 8, 8, 8, 8, 16, 32, 64];
        string memory firstFailure = "";
        for (uint256 i; i < 10; ++i) {
            uint256 sh = shares * num[i] / den[i];
            uint256 snap = vm.snapshotState();
            uint256 navPart = v.convertToAssets(sh);
            (bool ok, uint256 got, bytes memory e) = _redeemAs(who, sh);
            if (ok) {
                uint256 depPart = S * num[i] / den[i];
                console2.log(string.concat("   largest single redeem that succeeds: ", _t(num[i]), "/", _t(den[i]), " of the position = USD x100 ", _t(_assetToUsdE2(depPart)), "; vs NAV-part loss bps ", _ti(_lossBps(navPart, got)), "; vs deposit-part loss bps ", _ti(_lossBps(depPart, got))));
                if (bytes(firstFailure).length != 0) console2.log(string.concat("   first failure (larger redeem): ", firstFailure));
                vm.revertToState(snap);
                return;
            }
            if (bytes(firstFailure).length == 0) firstFailure = string.concat(_t(num[i]), "/", _t(den[i]), " -> ", _err(e));
            vm.revertToState(snap);
        }
        console2.log(string.concat("   NO redeem down to 1/64 of the position succeeds; first failure ", firstFailure));
    }

    function _chunkUsd() internal pure virtual returns (uint256);
    function _midUsd() internal pure virtual returns (uint256);
    function _stressSmallUsd() internal pure virtual returns (uint256);
    function _stressLargeUsd() internal pure virtual returns (uint256);
    function _maxChunkedUsd() internal pure virtual returns (uint256);

    // ================================================================= 06 exit capacity, baseline pool
    function test_06_ladder_1k() public { _ladder(1_000); }
    function test_06_ladder_10k() public { _ladder(10_000); }
    function test_06_ladder_50k() public { _ladder(50_000); }
    function test_06_ladder_100k() public { _ladder(100_000); }
    function test_06_ladder_250k() public { _ladder(250_000); }

    function _ladder(uint256 usd) internal {
        _openCap(5_000_000);
        console2.log(string.concat("LADDER ", _label(), " USD ", _t(usd)));
        {
            (,,,,, uint128 liq,,,,) = ITAPositionManager(POSITION_MANAGER).positions(v.tokenId());
            console2.log(string.concat(" pool active liquidity / vault seed liquidity ", _t(uint256(pool.liquidity())), " ", _t(uint256(liq))));
        }
        uint256 S = _usdToAsset(usd);
        uint256 snap = vm.snapshotState();
        int24 t0 = _spotTick();
        // (a) one-shot deposit
        (bool ok, uint256 shares, bytes memory e) = _depositAs(ALICE, S);
        if (ok) {
            console2.log(string.concat(" single-tx deposit of USD ", _t(usd), " OK; tick move ", _ti(int256(_spotTick()) - int256(t0))));
        } else {
            console2.log(string.concat(" single-tx deposit of USD ", _t(usd), " FAILS: ", _err(e)));
        }
        vm.revertToState(snap);
        if (usd > _maxChunkedUsd()) {
            console2.log(string.concat("   position NOT built by chunks above USD ", _t(_maxChunkedUsd()), " (impractical on this pool at the pin; exit side UNMEASURED for this size)"));
            return;
        }
        // (b) position built in chunks (whale over several blocks), then exits
        snap = vm.snapshotState();
        uint256 pps0 = _pps();
        uint256 nChunks;
        uint256 chunkUsed;
        string memory firstFail;
        (shares, nChunks, chunkUsed, firstFail) = _buildPosition(ALICE, S, _usdToAsset(_chunkUsd()));
        uint256 nav = v.convertToAssets(shares);
        console2.log(string.concat("   built in ", _t(nChunks), " chunk(s), last chunk USD x100 ", _t(_assetToUsdE2(chunkUsed)), "; first deposit failure: ", bytes(firstFail).length == 0 ? "none" : firstFail));
        console2.log(string.concat("   entry: NAV value of shares / deposit, loss bps ", _t(nav), " ", _ti(_lossBps(S, nav))));
        console2.log(string.concat("   maxWithdraw / deposit ", _t(v.maxWithdraw(ALICE)), " ", _t(S)));
        console2.log(string.concat("   position range ", _ti(v.positionTickLower()), " ", _ti(v.positionTickUpper()), " tick ", _ti(_spotTick()), "; pool liquidity now ", _t(uint256(pool.liquidity()))));
        // full redeem
        uint256 snapR = vm.snapshotState();
        (bool okR, uint256 got, bytes memory eR) = _redeemAs(ALICE, shares);
        if (okR) {
            console2.log(string.concat("   FULL REDEEM ok, got / deposited, round-trip loss bps ", _t(got), " ", _ti(_lossBps(S, got))));
            console2.log(string.concat("   exit-only loss vs NAV bps ", _ti(_lossBps(nav, got))));
            console2.log(string.concat("   PPS change for remaining holders (1e18 units) ", _ti(int256(_pps()) - int256(pps0))));
        } else {
            console2.log(string.concat("   FULL REDEEM FAILS: ", _err(eR)));
        }
        vm.revertToState(snapR);
        _exitProbe(ALICE, shares, S);
        // in-kind route, valued at the oracle
        (bool okK, uint256 ga, uint256 gp, bytes memory eK) = _redeemKindAs(ALICE, shares);
        if (okK) {
            uint256 value = ga + _pairedInAsset(gp);
            console2.log(string.concat("   IN-KIND full: asset + paired(oracle-valued) / deposited, loss bps ", _t(value), " ", _ti(_lossBps(S, value))));
            console2.log(string.concat("   IN-KIND legs: asset, paired ", _t(ga), " ", _t(gp)));
        } else {
            console2.log(string.concat("   IN-KIND FAILS: ", _err(eK)));
        }
    }

    // ================================================================= 07 exits through a stressed pool (real swaps through the real router)
    function test_07_stress_small_k0() public { _stress(_stressSmallUsd(), 0); }
    function test_07_stress_small_k1() public { _stress(_stressSmallUsd(), 1); }
    function test_07_stress_small_k2() public { _stress(_stressSmallUsd(), 2); }
    function test_07_stress_small_k3() public { _stress(_stressSmallUsd(), 3); }
    function test_07_stress_small_k4() public { _stress(_stressSmallUsd(), 4); }
    function test_07_stress_small_k5() public { _stress(_stressSmallUsd(), 5); }
    function test_07_stress_small_k6() public { _stress(_stressSmallUsd(), 6); }
    function test_07_stress_small_k7() public { _stress(_stressSmallUsd(), 7); }
    function test_07_stress_large_k0() public { _stress(_stressLargeUsd(), 0); }
    function test_07_stress_large_k1() public { _stress(_stressLargeUsd(), 1); }
    function test_07_stress_large_k2() public { _stress(_stressLargeUsd(), 2); }
    function test_07_stress_large_k3() public { _stress(_stressLargeUsd(), 3); }
    function test_07_stress_large_k4() public { _stress(_stressLargeUsd(), 4); }
    function test_07_stress_large_k5() public { _stress(_stressLargeUsd(), 5); }
    function test_07_stress_large_k6() public { _stress(_stressLargeUsd(), 6); }
    function test_07_stress_large_k7() public { _stress(_stressLargeUsd(), 7); }

    function _stress(uint256 usd, uint256 k) internal {
        _openCap(5_000_000);
        int24[] memory ticks = _stressTicks();
        uint256 S = _usdToAsset(usd);
        (uint256 shares,,,) = _buildPosition(ALICE, S, _usdToAsset(_chunkUsd()));
        uint256 snap = vm.snapshotState();
        int24 base = _spotTick();
        uint256 usedIn = _moveToTick(base + ticks[k]);
        int24 now_ = _spotTick();
        console2.log(string.concat("STRESS ", _label(), " USD ", _t(usd), " requested tick shift ", _ti(ticks[k]), " achieved ", _ti(int256(now_) - int256(base)), " (TWAP gate ", _t(v.maxTwapDeviationTicks()), " ticks)"));
        console2.log(string.concat("   pool trade used (tokenIn raw units) ", _t(usedIn)));
        (bool okR, uint256 got, bytes memory eR) = _redeemAs(ALICE, shares);
        if (okR) console2.log(string.concat("   FULL REDEEM ok, loss bps vs deposit ", _ti(_lossBps(S, got))));
        else console2.log(string.concat("   FULL REDEEM FAILS: ", _err(eR)));
        (bool okB,, bytes memory eB) = _depositAs(BOB, _usdToAsset(100));
        console2.log(string.concat("   new deposit (USD 100): ", _short(okB, eB)));
        vm.revertToState(snap);
        _moveToTick(base + ticks[k]);
        uint256 snap2 = vm.snapshotState();
        (bool ok1, uint256 g1, bytes memory e1) = _redeemAs(ALICE, shares / 10);
        console2.log(string.concat("   10% REDEEM: ", ok1 ? string.concat("ok, loss bps vs NAV-part ", _ti(_lossBps(S / 10, g1))) : _err(e1)));
        vm.revertToState(snap2);
        (bool okK, uint256 ga, uint256 gp, bytes memory eK) = _redeemKindAs(ALICE, shares);
        if (okK) {
            uint256 val = ga + _pairedInAsset(gp);
            console2.log(string.concat("   IN-KIND ok, oracle-valued loss bps vs deposit ", _ti(_lossBps(S, val))));
        } else {
            console2.log(string.concat("   IN-KIND FAILS: ", _err(eK)));
        }
    }

    // ================================================================= 08 out of range, oracle FOLLOWS the pool (a real depeg): keeper outage then keeper rebalance
    function test_08_outOfRange_oracleFollows_keeperOutageAndRebalance() public {
        _openCap(5_000_000);
        console2.log(string.concat("OUT-OF-RANGE (oracle follows pool)", " ", _label()));
        uint256 S = _usdToAsset(_midUsd());
        (uint256 shares,,,) = _buildPosition(ALICE, S, _usdToAsset(_chunkUsd()));
        uint256 tid = v.tokenId();

        // in-range control: PHAR accrual over 1h
        _etchFreshOracle();
        uint256 snap = vm.snapshotState();
        uint256 e0 = ITAGauge(gauge).earned(PHAR, tid);
        vm.warp(block.timestamp + 1 hours);
        uint256 inRangeAccrual = ITAGauge(gauge).earned(PHAR, tid) - e0;
        console2.log(string.concat(" in-range PHAR accrual over 1h (wei)", " ", _t(inRangeAccrual)));
        vm.revertToState(snap);

        int24 lower = v.positionTickLower();
        int24 upper = v.positionTickUpper();
        int24 target = lower - 5;
        _moveToTick(target);
        _etchOracleWithRatio(_ratioAtTick(_spotTick())); // the market (oracle) agrees with the new pool price
        vm.warp(block.timestamp + 2_400); // > twapPeriod so the TWAP has caught up
        vm.roll(block.number + 2_400);
        int24 spot = _spotTick();
        console2.log(string.concat(" range lower/upper, spot after move", " ", _ti(int256(lower)), " ", _ti(int256(upper)), " ", _ti(int256(spot))));
        assertLe(spot, lower, "position is out of range");

        // what a depositor sees
        (bool taOk, uint256 ta) = _viewTotalAssets();
        console2.log(string.concat(" totalAssets view ok / value", " ", _tb(taOk), " ", _t(ta)));
        console2.log(string.concat(" maxWithdraw(alice) / alice NAV / deposited", " ", _t(v.maxWithdraw(ALICE)), " ", _t(v.convertToAssets(shares)), " ", _t(S)));
        console2.log(string.concat(" maxDeposit(bob)", " ", _t(v.maxDeposit(BOB))));
        (bool okD,, bytes memory eD) = _depositAs(BOB, _usdToAsset(1_000));
        console2.log(string.concat(" new deposit while out of range:", " ", _short(okD, eD)));
        assertFalse(okD, "deposits must be blocked while out of range");
        (bool okI, bytes memory eI) = _try(REBALANCER, address(v), abi.encodeCall(ITAVault.deployIdle, ()));
        console2.log(string.concat(" deployIdle while out of range:", " ", _short(okI, eI)));
        assertFalse(okI);

        // idle liquidity earns nothing
        uint256 o0 = ITAGauge(gauge).earned(PHAR, tid);
        vm.warp(block.timestamp + 1 hours);
        uint256 outAccrual = ITAGauge(gauge).earned(PHAR, tid) - o0;
        console2.log(string.concat(" out-of-range PHAR accrual over 1h (wei)", " ", _t(outAccrual)));
        assertEq(outAccrual, 0, "out-of-range position must accrue nothing");
        assertGt(inRangeAccrual, 0, "control: in-range position accrues");

        // user exit while out of range (whole position is in the paired token; swap back through the pool)
        uint256 snap2 = vm.snapshotState();
        (bool okR, uint256 got, bytes memory eR) = _redeemAs(ALICE, shares);
        console2.log(string.concat(" Alice redeem while out of range:", " ", _short(okR, eR)));
        if (okR) console2.log(string.concat("   got / deposited, loss bps", " ", _t(got), " ", _ti(_lossBps(S, got))));
        vm.revertToState(snap2);
        _exitProbe(ALICE, shares, S);

        // keeper rebalance (rebalancer address, local prank)
        uint256 navBefore = v.totalAssets();
        (bool okB, bytes memory eB) = _try(REBALANCER, address(v), abi.encodeCall(ITAVault.rebalance, ()));
        console2.log(string.concat(" rebalance while out of range:", " ", _short(okB, eB)));
        if (okB) {
            console2.log(string.concat("   NAV before / after", " ", _t(navBefore), " ", _t(v.totalAssets())));
            console2.log(string.concat("   new range lower/upper", " ", _ti(int256(v.positionTickLower())), " ", _ti(int256(v.positionTickUpper()))));
            console2.log(string.concat("   NAV change bps", " ", _ti(_lossBps(navBefore, v.totalAssets()))));
            assertGt(_spotTick(), v.positionTickLower());
            assertLt(_spotTick(), v.positionTickUpper());
            (bool okD2,, bytes memory eD2) = _depositAs(BOB, _usdToAsset(1_000));
            console2.log(string.concat("   deposit after rebalance:", " ", _short(okD2, eD2)));
            assertTrue(okD2, "deposits resume after the keeper rebalances");
        }
    }

    // ================================================================= 09 out of range / dislocation, oracle does NOT follow
    function test_09_dislocation_oracleDoesNotFollow_gatesAndOwnerPath() public {
        _openCap(5_000_000);
        console2.log(string.concat("DISLOCATION (oracle does not follow)", " ", _label()));
        uint256 S = _usdToAsset(_midUsd());
        (uint256 shares,,,) = _buildPosition(ALICE, S, _usdToAsset(_chunkUsd()));
        uint256 ratio0 = _etchFreshOracle();
        console2.log(string.concat(" oracle ratio (1e18)", " ", _t(ratio0)));

        int24 upper = v.positionTickUpper();
        int24 lower = v.positionTickLower();
        int24 start = _spotTick();
        int24 target = lower - 5; // just below the range
        _moveToTick(target);
        console2.log(string.concat(" spot moved (ticks)", " ", _ti(int256(_spotTick()) - int256(start))));

        (bool okR, uint256 gotNow, bytes memory eR) = _redeemAs(ALICE, shares / 2);
        console2.log(string.concat(" immediately: redeem", " ", _short(okR, eR)));
        (bool okD,, bytes memory eD) = _depositAs(BOB, _usdToAsset(100));
        console2.log(string.concat(" immediately: deposit", " ", _short(okD, eD)));
        (bool okK, bytes memory eK) = _try(REBALANCER, address(v), abi.encodeCall(ITAVault.rebalance, ()));
        console2.log(string.concat(" immediately: rebalance", " ", _short(okK, eK)));
        (bool taOk,) = _viewTotalAssets();
        console2.log(string.concat(" immediately: totalAssets()/maxWithdraw view ok?", " ", _tb(taOk)));
        gotNow;

        vm.warp(block.timestamp + 2_400);
        vm.roll(block.number + 2_400);
        (okR, gotNow, eR) = _redeemAs(ALICE, shares / 2);
        console2.log(string.concat(" after TWAP caught up: redeem", " ", _short(okR, eR)));
        (okK, eK) = _try(REBALANCER, address(v), abi.encodeCall(ITAVault.rebalance, ()));
        console2.log(string.concat(" after TWAP caught up: rebalance", " ", _short(okK, eK)));
        assertFalse(okR, "ERC-4626 redeem is frozen by the oracle-deviation gate");
        assertFalse(okK, "rebalance is frozen too");
        (taOk,) = _viewTotalAssets();
        console2.log(string.concat(" after TWAP caught up: totalAssets view ok?", " ", _tb(taOk)));
        assertFalse(taOk, "totalAssets() (hence maxDeposit/maxWithdraw/convertToAssets) reverts");

        // the permissionless escape hatch still works
        uint256 snap = vm.snapshotState();
        (bool okIK, uint256 ga, uint256 gp, bytes memory eIK) = _redeemKindAs(ALICE, shares);
        console2.log(string.concat(" redeemInKind (permissionless):", " ", _short(okIK, eIK)));
        if (okIK) {
            console2.log(string.concat("   legs asset / paired", " ", _t(ga), " ", _t(gp)));
            uint256 val = ga + _pairedInAsset(gp);
            console2.log(string.concat("   oracle-valued (at pre-move ratio) loss bps vs deposit", " ", _ti(_lossBps(S, val))));
        }
        assertTrue(okIK, "redeemInKind must keep working");
        vm.revertToState(snap);

        // owner emergency exit works while the price gate blocks everything else, but ERC-4626 redeem stays gated
        vm.prank(SAFE);
        v.emergencyExit();
        assertTrue(v.paused());
        (okR,, eR) = _redeemAs(ALICE, shares);
        console2.log(string.concat(" after emergencyExit, redeem still gated:", " ", _short(okR, eR)));
        assertFalse(okR);
        upper;
    }

    // ================================================================= 10 keeper rebalance in range
    function test_10_keeperRebalance_small() public { _rebalanceCase(_stressSmallUsd()); }
    function test_10_keeperRebalance_mid() public { _rebalanceCase(_midUsd()); }

    function _rebalanceCase(uint256 usd) internal {
        _openCap(5_000_000);
        console2.log(string.concat("REBALANCE ", _label(), " USD ", _t(usd)));
        uint256 S = _usdToAsset(usd);
        (uint256 shares,,,) = _buildPosition(ALICE, S, _usdToAsset(_chunkUsd()));
        uint256 aliceNav0 = v.convertToAssets(shares);
        uint256 tid0 = v.tokenId();
        uint256 pharBefore = IERC20(PHAR).balanceOf(address(v));
        _expectRevertSel(ALICE, abi.encodeCall(ITAVault.rebalance, ()), "Vault__NotRebalancer");
        for (uint256 i; i < 3; ++i) {
            uint256 navB = v.totalAssets();
            (bool okB, bytes memory eB) = _try(REBALANCER, address(v), abi.encodeCall(ITAVault.rebalance, ()));
            console2.log(string.concat(" rebalance #, result", " ", _t(i + 1), " ", _short(okB, eB)));
            if (!okB) {
                console2.log("   keeper rebalance() DOES NOT EXECUTE at this size/pool depth");
                return;
            }
            console2.log(string.concat("   tokenId old/new", " ", _t(tid0), " ", _t(v.tokenId())));
            console2.log(string.concat("   NAV before/after, change bps", " ", _t(navB), " ", _t(v.totalAssets())));
            console2.log(string.concat("   change bps", " ", _ti(_lossBps(navB, v.totalAssets()))));
        }
        console2.log(string.concat(" cumulative NAV change after 3 back-to-back rebalances, bps (no cooldown exists)", " ", _ti(_lossBps(aliceNav0, v.convertToAssets(shares)))));
        console2.log(string.concat(" PHAR in vault before/after (claimed on exit of the old NFT)", " ", _t(pharBefore), " ", _t(IERC20(PHAR).balanceOf(address(v)))));
        console2.log(string.concat(" max loss one rebalance may legally book (entry-loss bps = 2*slippage+haircut)", " ", _t(2 * uint256(v.slippageBps()) + v.valuationHaircutBps())));
        // old NFT is burned: a stale tokenId cannot be re-used
        assertTrue(v.tokenId() != 0);
    }

    // ================================================================= 11 incident path: owner emergencyExit, then users
    function test_11_emergencyExit_small() public { _emergencyCase(_stressSmallUsd()); }
    function test_11_emergencyExit_mid() public { _emergencyCase(_midUsd()); }

    function _emergencyCase(uint256 usd) internal {
        _openCap(5_000_000);
        uint256 S = _usdToAsset(usd);
        (uint256 shares,,,) = _buildPosition(ALICE, S, _usdToAsset(_chunkUsd()));
        vm.prank(SAFE);
        v.emergencyExit();
        assertTrue(v.paused());
        console2.log(string.concat("EMERGENCY EXIT", " ", _label()));
        (bool okD,, bytes memory eD) = _depositAs(BOB, _usdToAsset(100));
        console2.log(string.concat(" deposit:", " ", _short(okD, eD)));
        assertFalse(okD);
        console2.log(string.concat(" maxDeposit / maxWithdraw(alice)", " ", _t(v.maxDeposit(ALICE)), " ", _t(v.maxWithdraw(ALICE))));
        uint256 snapE = vm.snapshotState();
        (bool okR, uint256 got, bytes memory eR) = _redeemAs(ALICE, shares);
        console2.log(string.concat(" redeem:", " ", _short(okR, eR)));
        if (okR) console2.log(string.concat("   got / deposited, loss bps", " ", _t(got), " ", _ti(_lossBps(S, got))));
        vm.revertToState(snapE);
        // not asserted: whether the ERC-4626 redeem can still swap the whole idle paired balance depends on pool depth
        // (fails for the USDC/USDt vault at USD 10k). The incident path that is always available is redeemInKind.
        (bool okK2, uint256 ga2, uint256 gp2,) = _redeemKindAs(ALICE, shares);
        console2.log(string.concat(" redeemInKind after emergencyExit: ok=", _tb(okK2), " asset ", _t(ga2), " paired ", _t(gp2)));
    }

    // ================================================================= 12 cap semantics (what a cap means to a depositor)
    function test_12_capSemantics() public {
        uint256 capUsd = 20_000;
        _openCap(capUsd);
        uint256 cap = v.depositCap();
        uint256 managed = v.totalAssets();
        console2.log(string.concat(" cap / managed / maxDeposit", " ", _t(cap), " ", _t(managed), " ", _t(v.maxDeposit(ALICE))));
        assertEq(v.maxDeposit(ALICE), cap - managed);
        (bool ok,, bytes memory e) = _depositAs(ALICE, cap - managed + _usdToAsset(100));
        console2.log(string.concat(" deposit above cap:", " ", _short(ok, e)));
        assertFalse(ok);
        assertEq(_err(e), "Vault__DepositCapExceeded");
        // the cap is checked against NAV (haircut-valued, excludes uncollected fees and PHAR): fills slowly as fees compound
        (ok,,) = _depositAs(ALICE, cap - managed);
        console2.log(string.concat(" deposit exactly maxDeposit ok?", " ", _tb(ok)));
    }
}

contract AvalancheTrackAUsdcVaultForkTest is TrackACore {
    function _vaultAddress() internal pure override returns (address) {
        return USDC_VAULT;
    }

    function _label() internal pure override returns (string memory) {
        return "USDC/USDt vault (asset USDC)";
    }

    function _isUsd() internal pure override returns (bool) {
        return true;
    }

    function _expectedAsset() internal pure override returns (address) {
        return USDC;
    }

    function _expectedPaired() internal pure override returns (address) {
        return USDT;
    }

    function _chunkUsd() internal pure override returns (uint256) { return 2_000; }
    function _midUsd() internal pure override returns (uint256) { return 10_000; }
    function _maxChunkedUsd() internal pure override returns (uint256) { return 10_000; }
    function _stressSmallUsd() internal pure override returns (uint256) { return 2_000; }
    function _stressLargeUsd() internal pure override returns (uint256) { return 10_000; }
    function _feeAliceUsd() internal pure override returns (uint256) { return 1_500; }
    function _feeLegUsd() internal pure override returns (uint256) { return 3_000; }
    function _bobUsd() internal pure override returns (uint256) { return 1_000; }
    function _feeRounds() internal pure override returns (uint256) { return 4; }

    function _stressTicks() internal pure override returns (int24[] memory a) {
        a = new int24[](8);
        a[0] = -40;
        a[1] = -25;
        a[2] = -10;
        a[3] = -3;
        a[4] = 3;
        a[5] = 10;
        a[6] = 25;
        a[7] = 40;
    }
}

contract AvalancheTrackAWavaxVaultForkTest is TrackACore {
    function _vaultAddress() internal pure override returns (address) {
        return WAVAX_VAULT;
    }

    function _label() internal pure override returns (string memory) {
        return "sAVAX/WAVAX vault (asset WAVAX)";
    }

    function _isUsd() internal pure override returns (bool) {
        return false;
    }

    function _expectedAsset() internal pure override returns (address) {
        return WAVAX;
    }

    function _expectedPaired() internal pure override returns (address) {
        return SAVAX;
    }

    function _chunkUsd() internal pure override returns (uint256) { return 25_000; }
    function _midUsd() internal pure override returns (uint256) { return 50_000; }
    function _maxChunkedUsd() internal pure override returns (uint256) { return 250_000; }
    function _stressSmallUsd() internal pure override returns (uint256) { return 10_000; }
    function _stressLargeUsd() internal pure override returns (uint256) { return 100_000; }
    function _feeAliceUsd() internal pure override returns (uint256) { return 20_000; }
    function _feeLegUsd() internal pure override returns (uint256) { return 30_000; }
    function _bobUsd() internal pure override returns (uint256) { return 10_000; }
    function _feeRounds() internal pure override returns (uint256) { return 4; }

    function _stressTicks() internal pure override returns (int24[] memory a) {
        a = new int24[](8);
        a[0] = -150;
        a[1] = -90;
        a[2] = -30;
        a[3] = -10;
        a[4] = 10;
        a[5] = 30;
        a[6] = 90;
        a[7] = 150;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PToken} from "../../contracts/PToken.sol";
import {PriceOracle} from "../../contracts/PriceOracle.sol";
import {PharaohTestMarket} from "../mocks/PharaohBoostedMocks.sol";
import {BpBase, BpNotAMarket} from "./BpBase.sol";

/// @notice Test 1: for every EXISTING pToken the wrapper must return exactly what the old (guarded) oracle returns, in
///         every feed state, including reverts. Compared byte-for-byte via staticcall (success flag + returndata), so a
///         revert in one and a zero in the other is a failure.
///
///         Wrapper under test: `PharaohDlmmShareOracle(baseOracle = the guarded oracle, market = bpPHAR)`. The `test_marginSurface_*`
///         tests cover the other functions of `IMarginPriceOracle` that a consumer reaching the oracle through
///         `controller.oracle()` could call (`marketAsset`, `getPrice`), plus arbitrary / non-contract pToken arguments.
///
///         Which functions are actually consumed through `controller.oracle()` (on-chain): Peridottroller
///         (`getUnderlyingPrice` only: borrowAllowed, getHypotheticalAccountLiquidity, liquidateCalculateSeizeTokens,
///         _setCollateralFactor) and PeridotLens (`getUnderlyingPrice`). The live margin stack (risk engine, quoter,
///         liquidator, order close adapter) holds its OWN immutable/storage oracle pointer and is not affected by
///         `_setPriceOracle`; off-chain, operator/src/chain.ts compares `controller.oracle()` to its configured oracle.
abstract contract BpIdentityBase is BpBase {
    uint256 internal constant STATES = 14;

    PharaohTestMarket internal unknownWavaxMarket; // PErc20-like, underlying WAVAX, NOT registered in the source oracle
    PharaohTestMarket internal unknownUsdcMarket;
    BpNotAMarket internal notAMarket;

    function setUp() public override {
        super.setUp();
        unknownWavaxMarket = new PharaohTestMarket(address(wavax));
        unknownUsdcMarket = new PharaohTestMarket(address(usdc));
        notAMarket = new BpNotAMarket();
    }

    // ---------------------------------------------------------------- feed state machine
    function _applyFeedState(bool isAvax, uint256 state) internal {
        // state: 0 fresh, 1 stale by 1s over maxAge, 2 exactly at maxAge (still fresh), 3 zero, 4 negative, 5 future,
        // 6 reverting, 7 roundId 0, 8 answeredInRound < roundId, 9 updatedAt 0, 10 huge answer (overflow in scaling),
        // 11 disabled in the source oracle, 12 answer 1 (tiny), 13 max int256
        uint256 maxAge = isAvax ? AVAX_MAX_AGE : USDC_MAX_AGE;
        int256 fresh = isAvax ? int256(20e8) : int256(1e8);
        // PharaohTestFeed is shared by the avax and usdc variable names
        if (isAvax) {
            avaxFeed.setReadReverts(false);
        } else {
            usdcFeed.setReadReverts(false);
        }
        int256 answer = fresh;
        uint256 updatedAt = block.timestamp;
        uint80 roundId = 5;
        uint80 answeredInRound = 5;
        if (state == 1) updatedAt = block.timestamp - maxAge - 1;
        else if (state == 2) updatedAt = block.timestamp - maxAge;
        else if (state == 3) answer = 0;
        else if (state == 4) answer = -1;
        else if (state == 5) updatedAt = block.timestamp + 1;
        else if (state == 7) roundId = 0;
        else if (state == 8) answeredInRound = 4;
        else if (state == 9) updatedAt = 0;
        else if (state == 10) answer = int256(type(int256).max / 1e10 + 1);
        else if (state == 12) answer = 1;
        else if (state == 13) answer = type(int256).max;
        if (isAvax) {
            avaxFeed.setRound(answer, updatedAt, roundId, answeredInRound);
            if (state == 6) avaxFeed.setReadReverts(true);
            if (state == 11) inner.disableFeed(address(wavax));
            else if (!_enabled(address(wavax))) inner.configureFeed(address(wavax), address(avaxFeed), AVAX_MAX_AGE);
        } else {
            usdcFeed.setRound(answer, updatedAt, roundId, answeredInRound);
            if (state == 6) usdcFeed.setReadReverts(true);
            if (state == 11) inner.disableFeed(address(usdc));
            else if (!_enabled(address(usdc))) inner.configureFeed(address(usdc), address(usdcFeed), USDC_MAX_AGE);
        }
    }

    function _enabled(address asset) internal view returns (bool enabled) {
        (,,, enabled) = inner.feeds(asset);
    }

    // ---------------------------------------------------------------- comparison
    function _assertSame(bytes memory data, string memory tag) internal view {
        (bool okOld, bytes memory retOld) = address(old).staticcall(data);
        (bool okNew, bytes memory retNew) = address(wrapper).staticcall(data);
        assertEq(okNew, okOld, string.concat("success flag differs: ", tag));
        assertEq(keccak256(retNew), keccak256(retOld), string.concat("returndata differs: ", tag));
    }

    function _assertAllMarketsSame(string memory tag) internal view {
        address[5] memory targets =
            [address(pWavax), address(pUsdc), address(unknownWavaxMarket), address(unknownUsdcMarket), address(notAMarket)];
        for (uint256 i = 0; i < targets.length; i++) {
            _assertSame(abi.encodeCall(PriceOracle.getUnderlyingPrice, (PToken(targets[i]))), tag);
        }
    }
}

/// @notice GREEN against the current wrapper: getUnderlyingPrice identity for contract pTokens.
contract BpPriceIdentityTest is BpIdentityBase {
    // ================================================================ getUnderlyingPrice
    function test_underlyingPriceIdentity_freshBaseline() external view {
        assertGt(old.getUnderlyingPrice(PToken(address(pWavax))), 0);
        assertEq(wrapper.getUnderlyingPrice(PToken(address(pWavax))), 20e18 * 1, "WAVAX $20, 18 dec: 20e18");
        assertEq(wrapper.getUnderlyingPrice(PToken(address(pUsdc))), 1e30, "USDC $1, 6 dec: 1e30");
        assertEq(wrapper.getUnderlyingPrice(PToken(address(pWavax))), old.getUnderlyingPrice(PToken(address(pWavax))));
        assertEq(wrapper.getUnderlyingPrice(PToken(address(pUsdc))), old.getUnderlyingPrice(PToken(address(pUsdc))));
        _assertAllMarketsSame("fresh");
    }

    function test_underlyingPriceIdentity_fullFeedStateMatrix() external {
        for (uint256 a = 0; a < STATES; a++) {
            for (uint256 u = 0; u < STATES; u++) {
                _applyFeedState(true, a);
                _applyFeedState(false, u);
                _assertAllMarketsSame(string.concat("avax state ", vm.toString(a), " usdc state ", vm.toString(u)));
            }
        }
    }

    function test_underlyingPriceIdentity_namedStates() external {
        // stale by exactly one second over maxAge: both return 0, exactly one second earlier both return the price
        _applyFeedState(true, 2);
        assertGt(wrapper.getUnderlyingPrice(PToken(address(pWavax))), 0, "at maxAge: fresh");
        _applyFeedState(true, 1);
        assertEq(wrapper.getUnderlyingPrice(PToken(address(pWavax))), 0, "maxAge+1s: 0");
        assertEq(old.getUnderlyingPrice(PToken(address(pWavax))), 0);
        _assertAllMarketsSame("avax stale+1");
        // USDC stale by one second: pUSDC 0 in both, pWAVAX unaffected in both
        _applyFeedState(true, 0);
        _applyFeedState(false, 1);
        assertEq(wrapper.getUnderlyingPrice(PToken(address(pUsdc))), 0);
        assertGt(wrapper.getUnderlyingPrice(PToken(address(pWavax))), 0);
        _assertAllMarketsSame("usdc stale+1");
        // overflow in the old oracle's scaling reverts in the old oracle; the wrapper must revert identically
        _applyFeedState(false, 0);
        _applyFeedState(true, 13);
        (bool okOld,) = address(old).staticcall(abi.encodeCall(PriceOracle.getUnderlyingPrice, (PToken(address(pWavax)))));
        assertFalse(okOld, "documented: the old oracle REVERTS on an overflowing answer");
        _assertAllMarketsSame("avax max int256");
    }

    function test_underlyingPriceIdentity_acrossVaultStates() external {
        for (uint256 v = 0; v < 5; v++) {
            vault.setConvertReverts(v == 1);
            vault.setAssetReverts(v == 2);
            vault.setAssetOverride(v == 3 ? address(wavax) : address(0));
            vault.setAssetsPerWholeShare(v == 4 ? 0 : 1e6);
            _assertAllMarketsSame(string.concat("vault state ", vm.toString(v)));
        }
    }

    function test_underlyingPriceIdentity_afterTheShareMarketIsListed() external {
        _listShareMarket();
        _assertAllMarketsSame("after listing");
        // the ONLY intended difference: the new market
        assertEq(old.getUnderlyingPrice(PToken(address(bp))), 0, "old oracle does not know bpPHAR");
        assertEq(wrapper.getUnderlyingPrice(PToken(address(bp))), 1e30, "wrapper prices it: $1.00/share, 6 dec -> 1e30");
    }

    /// @dev Fuzz: random raw feed rounds for both feeds, random disabled flags, random vault state, every probe target.
    function testFuzz_underlyingPriceIdentity(
        int256 avaxAnswer,
        uint256 avaxUpdatedAt,
        uint80 avaxRound,
        uint80 avaxAnswered,
        int256 usdcAnswer,
        uint256 usdcUpdatedAt,
        uint80 usdcRound,
        uint80 usdcAnswered,
        uint8 flags
    ) external {
        avaxFeed.setRound(avaxAnswer, avaxUpdatedAt, avaxRound, avaxAnswered);
        usdcFeed.setRound(usdcAnswer, usdcUpdatedAt, usdcRound, usdcAnswered);
        avaxFeed.setReadReverts(flags & 1 != 0);
        usdcFeed.setReadReverts(flags & 2 != 0);
        if (flags & 4 != 0) inner.disableFeed(address(wavax));
        if (flags & 8 != 0) inner.disableFeed(address(usdc));
        vault.setConvertReverts(flags & 16 != 0);
        vault.setAssetReverts(flags & 32 != 0);
        _assertAllMarketsSame("fuzz");
    }

    /// @dev Fuzz around the freshness boundary with a realistic answer range: age and answer vary, prices must match.
    function testFuzz_underlyingPriceIdentity_ageBoundary(uint32 ageAvax, uint32 ageUsdc, uint64 avax8, uint64 usdc8)
        external
    {
        avaxFeed.setRound(int256(uint256(avax8)), block.timestamp - (uint256(ageAvax) % (AVAX_MAX_AGE * 2)), 9, 9);
        usdcFeed.setRound(int256(uint256(usdc8)), block.timestamp - (uint256(ageUsdc) % (USDC_MAX_AGE * 2)), 9, 9);
        _assertAllMarketsSame("fuzz age boundary");
    }

    // ================================================================ controller-level views through the swap
    function test_controllerViewsIdenticalBeforeAndAfterTheSwap_allFeedStates() external {
        // a pWAVAX-collateral account with a USDC borrow, plus a lender
        _mintUnderlyingP(pWavax, ALICE, 50e18); // $1000, CF 30% -> $300 power
        _enter(ALICE, address(pWavax));
        (bool ok,) = _borrowUsdc(ALICE, 100e6);
        assertTrue(ok);
        for (uint256 a = 0; a < STATES; a++) {
            for (uint256 u = 0; u < STATES; u += 3) {
                _applyFeedState(true, a);
                _applyFeedState(false, u);
                _snapshotControllerViews(); // under the OLD oracle (controller still points at `old`)
            }
        }
        // second pass under the wrapper: recompute and compare against the stored hashes
        bytes32[] memory before = _hashes;
        delete _hashes;
        require(controller._setPriceOracle(PriceOracle(address(wrapper))) == 0);
        for (uint256 a = 0; a < STATES; a++) {
            for (uint256 u = 0; u < STATES; u += 3) {
                _applyFeedState(true, a);
                _applyFeedState(false, u);
                _snapshotControllerViews();
            }
        }
        assertEq(_hashes.length, before.length);
        for (uint256 i = 0; i < before.length; i++) {
            assertEq(_hashes[i], before[i], string.concat("controller view differs at case ", vm.toString(i)));
        }
    }

    bytes32[] internal _hashes;

    function _snapshotControllerViews() internal {
        (bool ok1, bytes memory r1) =
            address(controller).staticcall(abi.encodeCall(controller.getAccountLiquidity, (ALICE)));
        (bool ok2, bytes memory r2) = address(controller)
            .staticcall(abi.encodeCall(controller.liquidateCalculateSeizeTokens, (address(pUsdc), address(pWavax), 10e6)));
        (bool ok3, bytes memory r3) = address(controller)
            .staticcall(abi.encodeCall(controller.getHypotheticalAccountLiquidity, (ALICE, address(pWavax), 1e8, 1e6)));
        (bool ok4, bytes memory r4) = address(controller)
            .staticcall(abi.encodeCall(controller.liquidateCalculateSeizeTokens, (address(pWavax), address(pUsdc), 1e18)));
        _hashes.push(keccak256(abi.encode(ok1, r1, ok2, r2, ok3, r3, ok4, r4)));
    }
}

/// @notice Margin surface and arbitrary-argument identity. These were RED against the first wrapper (PharaohVaultShareOracle:
///         reverted for non-contract pTokens, no marketAsset/getPrice); GREEN against PharaohDlmmShareOracle.
contract BpPriceIdentityMarginSurfaceTest is BpIdentityBase {
    /// @dev Arbitrary target address (EOA, zero, precompile-like, random): old returns 0 for an unknown market.
    ///      If the wrapper reverts here while the old oracle returns 0 it is a REAL identity gap for any consumer that
    ///      passes a non-contract pToken (Peridottroller never does: it only calls with listed pTokens).
    function testFuzz_underlyingPriceIdentity_arbitraryTarget(address target) external view {
        _assertSame(abi.encodeCall(PriceOracle.getUnderlyingPrice, (PToken(target))), "arbitrary target");
    }

    function test_underlyingPriceIdentity_eoaAndZeroTargets() external view {
        _assertSame(abi.encodeCall(PriceOracle.getUnderlyingPrice, (PToken(address(0)))), "zero address");
        _assertSame(abi.encodeCall(PriceOracle.getUnderlyingPrice, (PToken(address(0xBEEF)))), "EOA");
        _assertSame(abi.encodeCall(PriceOracle.getUnderlyingPrice, (PToken(address(1)))), "precompile ecrecover");
    }

    // ================================================================ margin surface (RED until the wrapper forwards it)
    function test_marginSurface_marketAssetIdentity() external view {
        address[6] memory targets = [
            address(pWavax), address(pUsdc), address(unknownWavaxMarket), address(notAMarket), address(0), address(0xBEEF)
        ];
        for (uint256 i = 0; i < targets.length; i++) {
            _assertSame(abi.encodeWithSignature("marketAsset(address)", targets[i]), "marketAsset");
        }
    }

    function test_marginSurface_getPriceIdentity_allFeedStates() external {
        for (uint256 a = 0; a < STATES; a++) {
            for (uint256 u = 0; u < STATES; u++) {
                _applyFeedState(true, a);
                _applyFeedState(false, u);
                _assertSame(abi.encodeWithSignature("getPrice(address)", address(wavax)), "getPrice WAVAX");
                _assertSame(abi.encodeWithSignature("getPrice(address)", address(usdc)), "getPrice USDC");
                _assertSame(abi.encodeWithSignature("getPrice(address)", address(0xBEEF)), "getPrice unknown");
            }
        }
    }

    function testFuzz_marginSurface_getPriceIdentity(int256 answer, uint256 updatedAt, uint80 round, uint80 answered, bool revertsFeed)
        external
    {
        avaxFeed.setRound(answer, updatedAt, round, answered);
        avaxFeed.setReadReverts(revertsFeed);
        _assertSame(abi.encodeWithSignature("getPrice(address)", address(wavax)), "getPrice WAVAX fuzz");
        _assertSame(abi.encodeWithSignature("marketAsset(address)", address(pWavax)), "marketAsset fuzz");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/StockSimplePriceOracle.sol";
import "../contracts/PToken.sol";

contract SSPOMockFeed {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    bool public feedReverts;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        set(answer_);
    }

    function set(int256 answer_) public {
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function setRound(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setReverts(bool v) external {
        feedReverts = v;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!feedReverts, "FEED_DOWN");
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @dev Feed whose decimals() call reverts; the oracle reads decimals() only after a fresh round.
contract SSPODecimalsRevertFeed {
    int256 public answer = 1e8;
    uint256 public updatedAt = block.timestamp;

    function decimals() external pure returns (uint8) {
        revert("NO_DECIMALS");
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract SSPOMockPErc20 {
    address public underlying;
    string public symbol;

    constructor(address underlying_, string memory symbol_) {
        underlying = underlying_;
        symbol = symbol_;
    }
}

/// @dev Stands in for a native-asset market: it has a symbol but no underlying().
contract SSPOMockPEther {
    string public symbol = "pETH";
}

/// @notice Unit tests for the lending price source that backs the live Robinhood markets.
/// @dev Several tests PIN current behaviour that is surprising (documented inline) so a
///      later change is a conscious decision. They are characterisation tests, not endorsements.
contract StockSimplePriceOracleTest is Test {
    event PricePosted(
        address asset, uint256 previousPriceMantissa, uint256 requestedPriceMantissa, uint256 newPriceMantissa
    );
    event ChainlinkFeedRegistered(address asset, address aggregator);
    event LastChainlinkPriceUpdated(address indexed asset, uint256 priceMantissa);
    event StockAssetSet(address indexed asset, bool isStock);

    uint256 constant DEFAULT_STALE = 1 hours;
    uint256 constant STOCK_STALE = 12 hours;
    address constant STOCK = address(0x57C0);
    address constant USD = address(0x05D6);
    address constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    StockSimplePriceOracle oracle;
    address admin = address(0xAD);
    address outsider = address(0xBAD);

    function setUp() public {
        vm.warp(1_800_000_000);
        oracle = new StockSimplePriceOracle(DEFAULT_STALE, STOCK_STALE);
        oracle.setAdmin(admin);
    }

    function _market(address underlying, string memory sym) internal returns (PToken) {
        return PToken(address(new SSPOMockPErc20(underlying, sym)));
    }

    function _feed(address asset, uint8 dec, int256 answer) internal returns (SSPOMockFeed f) {
        f = new SSPOMockFeed(dec, answer);
        oracle.registerChainlinkFeed(asset, address(f));
    }

    // ---------------------------------------------------------------- construction / roles

    function testConstructorSetsThresholdsAndDeployerIsAdminAndOwner() public view {
        assertEq(oracle.chainlinkPriceStaleThreshold(), DEFAULT_STALE);
        assertEq(oracle.stockChainlinkPriceStaleThreshold(), STOCK_STALE);
        assertTrue(oracle.admin(address(this)));
        assertTrue(oracle.isPriceOracle());
    }

    function testAdminGatedSettersRejectOutsiders() public {
        PToken market = _market(STOCK, "pNVDA"); // create before expectRevert: CREATE counts as a call
        vm.startPrank(outsider);
        vm.expectRevert("Only admin");
        oracle.setDirectPrice(STOCK, 1);
        vm.expectRevert("Only admin");
        oracle.registerChainlinkFeed(STOCK, address(1));
        vm.expectRevert("Only admin");
        oracle.removeChainlinkFeed(STOCK);
        vm.expectRevert("Only admin");
        oracle.setStockAsset(STOCK, true);
        vm.expectRevert("Only admin");
        oracle.setUnderlyingPrice(market, 1);
        vm.stopPrank();
    }

    function testOwnerGatedSettersRejectAdminsAndOutsiders() public {
        address[2] memory callers = [admin, outsider];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert("Only owner");
            oracle.setChainlinkStaleThreshold(1);
            vm.expectRevert("Only owner");
            oracle.setStockChainlinkStaleThreshold(1);
            vm.expectRevert("Only owner");
            oracle.setAdmin(outsider);
            vm.expectRevert("Only owner");
            oracle.removeAdmin(admin);
            vm.expectRevert("Only owner");
            oracle.setOwner(outsider);
            vm.stopPrank();
        }
    }

    function testOwnerCanRevokeAdmin() public {
        oracle.removeAdmin(admin);
        vm.prank(admin);
        vm.expectRevert("Only admin");
        oracle.setDirectPrice(STOCK, 1);
    }

    /// PIN: setOwner does not touch the admin mapping. After a hand-over the previous owner
    /// keeps admin rights until explicitly removed, and the new owner has none until granted.
    function testSetOwnerDoesNotMoveAdminRights() public {
        address newOwner = address(0x0AAE);
        oracle.setOwner(newOwner);
        assertTrue(oracle.admin(address(this)), "old owner keeps admin");
        assertFalse(oracle.admin(newOwner), "new owner has no admin");
        vm.expectRevert("Only owner");
        oracle.setAdmin(address(5));
        vm.prank(newOwner);
        oracle.setAdmin(newOwner);
        assertTrue(oracle.admin(newOwner));
    }

    /// PIN: handing ownership to address(0) permanently disables owner-only configuration.
    function testOwnerRenounceIsPermanent() public {
        oracle.setOwner(address(0));
        vm.expectRevert("Only owner");
        oracle.setChainlinkStaleThreshold(5);
        vm.expectRevert("Only owner");
        oracle.setOwner(address(this));
    }

    // ---------------------------------------------------------------- manual price path

    function testManualPriceViaPTokenAndDirectAgreeAndEmit() public {
        PToken p = _market(STOCK, "pNVDA");
        vm.expectEmit(false, false, false, true);
        emit PricePosted(STOCK, 0, 183e18, 183e18);
        vm.prank(admin);
        oracle.setUnderlyingPrice(p, 183e18);
        assertEq(oracle.getUnderlyingPrice(p), 183e18);
        assertEq(oracle.assetPrices(STOCK), 183e18);

        vm.expectEmit(false, false, false, true);
        emit PricePosted(STOCK, 183e18, 190e18, 190e18);
        oracle.setDirectPrice(STOCK, 190e18);
        assertEq(oracle.assetPrices(STOCK), 190e18);
    }

    function testUnknownAssetPricesToZero() public {
        assertEq(oracle.assetPrices(STOCK), 0);
        assertEq(oracle.getUnderlyingPrice(_market(STOCK, "pNVDA")), 0);
    }

    // ---------------------------------------------------------------- pETH routing

    function testPEthSymbolRoutesToNativeSentinelWithoutCallingUnderlying() public {
        PToken eth = PToken(address(new SSPOMockPEther()));
        oracle.setUnderlyingPrice(eth, 3000e18);
        assertEq(oracle.assetPrices(NATIVE), 3000e18);
        assertEq(oracle.getUnderlyingPrice(eth), 3000e18);
    }

    /// PIN: routing keys off the symbol string only, so an ERC20 market that happens to be
    /// called "pETH" is priced as the native asset, not as its underlying.
    function testErc20MarketNamedPEthIsMisroutedToNative() public {
        PToken impostor = _market(STOCK, "pETH");
        oracle.setDirectPrice(NATIVE, 2000e18);
        oracle.setDirectPrice(STOCK, 5e18);
        assertEq(oracle.getUnderlyingPrice(impostor), 2000e18);
    }

    function testMarketThatIsNotAContractReverts() public {
        vm.expectRevert();
        oracle.getUnderlyingPrice(PToken(address(0x1234)));
    }

    // ---------------------------------------------------------------- chainlink path

    function testFreshFeedWinsOverCacheAndManualPrice() public {
        _feed(STOCK, 8, 200e8);
        oracle.setDirectPrice(STOCK, 1e18);
        address[] memory a = new address[](1);
        a[0] = STOCK;
        oracle.updateChainlinkPrices(a);
        SSPOMockFeed(address(oracle.assetToAggregator(STOCK))).set(210e8);
        assertEq(oracle.assetPrices(STOCK), 210e18);
        assertEq(oracle.getUnderlyingPrice(_market(STOCK, "pNVDA")), 210e18);
    }

    function testFeedRegistrationRejectsZeroAddressAndEmits() public {
        vm.expectRevert("Invalid aggregator");
        oracle.registerChainlinkFeed(STOCK, address(0));
        SSPOMockFeed f = new SSPOMockFeed(8, 1e8);
        vm.expectEmit(false, false, false, true);
        emit ChainlinkFeedRegistered(STOCK, address(f));
        oracle.registerChainlinkFeed(STOCK, address(f));
    }

    function testRemoveFeedRequiresFeedAndClearsFeedAndCacheButKeepsManualAndClass() public {
        vm.expectRevert("No feed");
        oracle.removeChainlinkFeed(STOCK);

        _feed(STOCK, 8, 200e8);
        oracle.setStockAsset(STOCK, true);
        oracle.setDirectPrice(STOCK, 7e18);
        address[] memory a = new address[](1);
        a[0] = STOCK;
        oracle.updateChainlinkPrices(a);
        assertEq(oracle.lastValidChainlinkPrice(STOCK), 200e18);

        oracle.removeChainlinkFeed(STOCK);
        assertEq(address(oracle.assetToAggregator(STOCK)), address(0));
        assertEq(oracle.lastValidChainlinkPrice(STOCK), 0);
        assertTrue(oracle.isStockAsset(STOCK));
        assertEq(oracle.assetPrices(STOCK), 7e18, "manual price survives");
        assertTrue(oracle.isPriceStale(STOCK), "no feed counts as stale");
    }

    // ---------------------------------------------------------------- staleness boundaries

    function testDefaultThresholdBoundary() public {
        SSPOMockFeed f = _feed(USD, 8, 1e8);
        oracle.setDirectPrice(USD, 9e18);
        vm.warp(block.timestamp + DEFAULT_STALE); // age == threshold: still fresh
        assertEq(oracle.assetPrices(USD), 1e18);
        assertFalse(oracle.isPriceStale(USD));
        vm.warp(block.timestamp + 1); // age == threshold + 1: stale -> manual fallback
        assertEq(oracle.assetPrices(USD), 9e18);
        assertTrue(oracle.isPriceStale(USD));
        f.set(1e8);
        assertFalse(oracle.isPriceStale(USD), "fresh again after a new round");
    }

    function testStockUsesItsOwnLongerThreshold() public {
        _feed(STOCK, 8, 200e8);
        oracle.setDirectPrice(STOCK, 9e18);
        vm.warp(block.timestamp + DEFAULT_STALE + 1);
        // Not marked as stock yet: default threshold applies and the round is stale.
        assertTrue(oracle.isPriceStale(STOCK));
        assertEq(oracle.assetPrices(STOCK), 9e18);

        vm.expectEmit(true, false, false, true);
        emit StockAssetSet(STOCK, true);
        oracle.setStockAsset(STOCK, true);
        assertFalse(oracle.isPriceStale(STOCK));
        assertEq(oracle.assetPrices(STOCK), 200e18);
        PToken market = _market(STOCK, "pNVDA");
        assertEq(oracle.getUnderlyingPrice(market), 200e18);
        address[] memory a = new address[](1);
        a[0] = STOCK;
        oracle.updateChainlinkPrices(a);
        assertEq(oracle.lastValidChainlinkPrice(STOCK), 200e18, "cache honours the stock threshold");

        vm.warp(block.timestamp + STOCK_STALE - DEFAULT_STALE - 1); // age == stock threshold
        assertFalse(oracle.isPriceStale(STOCK));
        assertEq(oracle.getUnderlyingPrice(market), 200e18);
        vm.warp(block.timestamp + 1);
        assertTrue(oracle.isPriceStale(STOCK));
        // Past the stock threshold the cached 200e18 is what remains, not the stale-but-unflagged feed.
        assertEq(oracle.getUnderlyingPrice(market), 200e18);
    }

    function testClassificationChangeDoesNotAffectOtherAssets() public {
        _feed(STOCK, 8, 200e8);
        _feed(USD, 8, 1e8);
        oracle.setStockAsset(STOCK, true);
        vm.warp(block.timestamp + 2 hours);
        assertFalse(oracle.isPriceStale(STOCK));
        assertTrue(oracle.isPriceStale(USD));
    }

    function testThresholdSettersTakeEffect() public {
        _feed(USD, 8, 1e8);
        vm.warp(block.timestamp + 2 hours);
        assertTrue(oracle.isPriceStale(USD));
        oracle.setChainlinkStaleThreshold(3 hours);
        assertFalse(oracle.isPriceStale(USD));
        oracle.setStockAsset(USD, true);
        oracle.setStockChainlinkStaleThreshold(0);
        assertTrue(oracle.isPriceStale(USD), "zero stock threshold stales anything older than 0s");
    }

    function testNonPositiveAnswersAreStale() public {
        SSPOMockFeed f = _feed(USD, 8, 1e8);
        oracle.setDirectPrice(USD, 4e18);
        f.set(0);
        assertTrue(oracle.isPriceStale(USD));
        assertEq(oracle.assetPrices(USD), 4e18);
        f.set(-5);
        assertTrue(oracle.isPriceStale(USD));
        assertEq(oracle.assetPrices(USD), 4e18);
    }

    // ---------------------------------------------------------------- cache / fallback chain

    function testFallbackOrderCacheThenManualThenZero() public {
        SSPOMockFeed f = _feed(STOCK, 8, 200e8);
        // 1) stale feed, nothing else -> zero
        f.setRound(200e8, block.timestamp - 100 days);
        assertEq(oracle.assetPrices(STOCK), 0);
        // 2) manual price present -> manual
        oracle.setDirectPrice(STOCK, 150e18);
        assertEq(oracle.assetPrices(STOCK), 150e18);
        // 3) cache present -> cache outranks manual
        f.set(200e8);
        address[] memory a = new address[](1);
        a[0] = STOCK;
        oracle.updateChainlinkPrices(a);
        f.setRound(200e8, block.timestamp - 100 days);
        assertEq(oracle.assetPrices(STOCK), 200e18);
        assertEq(oracle.getUnderlyingPrice(_market(STOCK, "pNVDA")), 200e18);
    }

    /// PIN (policy risk): the cached price never expires and masks later manual prices for as
    /// long as the feed is unavailable. Manual prices are NOT an emergency override.
    function testCachedPriceNeverExpiresAndMasksManualPrice() public {
        SSPOMockFeed f = _feed(STOCK, 8, 200e8);
        address[] memory a = new address[](1);
        a[0] = STOCK;
        oracle.updateChainlinkPrices(a);
        f.setRound(200e8, block.timestamp - 100 days);
        vm.warp(block.timestamp + 3650 days);
        oracle.setDirectPrice(STOCK, 1e18);
        assertEq(oracle.assetPrices(STOCK), 200e18);
    }

    function testRevertingFeedFallsBackToCacheThenManual() public {
        SSPOMockFeed f = _feed(STOCK, 8, 200e8);
        oracle.setDirectPrice(STOCK, 150e18);
        f.setReverts(true);
        assertEq(oracle.assetPrices(STOCK), 150e18);
        assertTrue(oracle.isPriceStale(STOCK));
        f.setReverts(false);
        address[] memory a = new address[](1);
        a[0] = STOCK;
        oracle.updateChainlinkPrices(a);
        f.setReverts(true);
        assertEq(oracle.assetPrices(STOCK), 200e18);
        assertEq(oracle.getUnderlyingPrice(_market(STOCK, "pNVDA")), 200e18);
    }

    function testGettersNeverPopulateTheCache() public {
        _feed(STOCK, 8, 200e8);
        oracle.assetPrices(STOCK);
        oracle.getUnderlyingPrice(_market(STOCK, "pNVDA"));
        assertEq(oracle.lastValidChainlinkPrice(STOCK), 0);
    }

    function testUpdateCacheIsPermissionlessAndEmits() public {
        _feed(STOCK, 8, 200e8);
        address[] memory a = new address[](1);
        a[0] = STOCK;
        vm.expectEmit(true, false, false, true);
        emit LastChainlinkPriceUpdated(STOCK, 200e18);
        vm.prank(outsider);
        oracle.updateChainlinkPrices(a);
        assertEq(oracle.lastValidChainlinkPrice(STOCK), 200e18);
    }

    function testUpdateCacheLeavesExistingCachesUntouchedForStaleBadAndUnregisteredAssets() public {
        SSPOMockFeed good = _feed(STOCK, 8, 200e8);
        SSPOMockFeed stale = _feed(USD, 8, 1e8);
        address bad = address(0xBEEF);
        SSPOMockFeed down = _feed(bad, 8, 5e8);
        address[] memory a = new address[](4);
        a[0] = address(0xDEAD); // no feed registered
        a[1] = USD;
        a[2] = bad;
        a[3] = STOCK;
        oracle.updateChainlinkPrices(a); // seed real, non-zero caches
        assertEq(oracle.lastValidChainlinkPrice(USD), 1e18);
        assertEq(oracle.lastValidChainlinkPrice(bad), 5e18);
        assertEq(oracle.lastValidChainlinkPrice(STOCK), 200e18);
        assertEq(oracle.lastValidChainlinkPrice(address(0xDEAD)), 0);

        // Now one asset goes stale, one reverts, one gets a bad round, and the good one moves.
        stale.setRound(1e8, block.timestamp - 10 days);
        down.setReverts(true);
        good.set(201e8);
        oracle.updateChainlinkPrices(a);
        assertEq(oracle.lastValidChainlinkPrice(USD), 1e18, "stale round must not touch the cache");
        assertEq(oracle.lastValidChainlinkPrice(bad), 5e18, "reverting feed must not touch the cache");
        assertEq(oracle.lastValidChainlinkPrice(address(0xDEAD)), 0);
        assertEq(oracle.lastValidChainlinkPrice(STOCK), 201e18, "good asset still updates in the same batch");

        stale.setRound(-1, block.timestamp); // fresh but non-positive
        oracle.updateChainlinkPrices(a);
        assertEq(oracle.lastValidChainlinkPrice(USD), 1e18, "non-positive answer must not touch the cache");

        address[] memory dup = new address[](2);
        dup[0] = STOCK;
        dup[1] = STOCK;
        oracle.updateChainlinkPrices(dup); // duplicates in one batch are harmless
        assertEq(oracle.lastValidChainlinkPrice(STOCK), 201e18);
        oracle.updateChainlinkPrices(new address[](0));
    }

    /// PIN (cache provenance): replacing a feed keeps the previous feed's cached price, so a
    /// stale replacement serves the OLD feed's price. Removal is the only thing that clears it.
    function testReplacingFeedKeepsPredecessorsCache() public {
        _feed(STOCK, 8, 200e8);
        address[] memory a = new address[](1);
        a[0] = STOCK;
        oracle.updateChainlinkPrices(a);
        SSPOMockFeed replacement = new SSPOMockFeed(8, 999e8);
        replacement.setRound(999e8, block.timestamp - 100 days);
        oracle.registerChainlinkFeed(STOCK, address(replacement));
        assertEq(oracle.assetPrices(STOCK), 200e18);
    }

    // ---------------------------------------------------------------- decimals scaling

    function testDecimalsBoundaries() public {
        _feed(USD, 17, 5e17); // below 18: scaled up
        assertEq(oracle.assetPrices(USD), 5e18);
        SSPOMockFeed f = _feed(USD, 18, 5e18); // exactly 18
        assertEq(oracle.assetPrices(USD), 5e18);
        f = _feed(USD, 19, 5e19); // above 18: scaled down
        assertEq(oracle.assetPrices(USD), 5e18);
        f.set(5e19 + 9); // above-18 feeds truncate toward zero
        assertEq(oracle.assetPrices(USD), 5e18);
        _feed(USD, 0, 7);
        assertEq(oracle.assetPrices(USD), 7e18);
    }

    function testFuzzDecimalsScalingMatchesReference(uint8 dec, uint128 raw) public {
        dec = uint8(bound(dec, 0, 30));
        raw = uint128(bound(raw, 1, type(uint96).max));
        _feed(STOCK, dec, int256(uint256(raw)));
        uint256 expected = dec <= 18 ? uint256(raw) * 10 ** (18 - dec) : uint256(raw) / 10 ** (dec - 18);
        assertEq(oracle.assetPrices(STOCK), expected);
        assertEq(oracle.getUnderlyingPrice(_market(STOCK, "pNVDA")), expected);
    }

    /// PIN: a positive answer that truncates to zero (decimals > 18) is returned as 0 and also
    /// overwrites a good cache with 0. A feed this coarse should never be registered.
    function testPositiveAnswerThatTruncatesToZeroIsReturnedAndOverwritesCache() public {
        SSPOMockFeed f = _feed(STOCK, 20, 1e20);
        address[] memory a = new address[](1);
        a[0] = STOCK;
        oracle.updateChainlinkPrices(a);
        assertEq(oracle.lastValidChainlinkPrice(STOCK), 1e18);
        f.set(99); // 99 / 100 == 0
        oracle.setDirectPrice(STOCK, 5e18);
        assertEq(oracle.assetPrices(STOCK), 0, "fresh round wins even though it normalizes to 0");
        oracle.updateChainlinkPrices(a);
        assertEq(oracle.lastValidChainlinkPrice(STOCK), 0, "good cache clobbered");
    }

    function testExtremeDecimalsBehaviour() public {
        _feed(STOCK, 18 + 78, 1); // 10 ** 78 overflows uint256 -> arithmetic panic, no fallback
        vm.expectRevert(stdError.arithmeticError);
        oracle.assetPrices(STOCK);
    }

    // ---------------------------------------------------------------- panics that escape the try/catch

    /// PIN: arithmetic that fails inside the successful-return branch is NOT caught by the
    /// try/catch, so these panic instead of falling back to cache/manual prices.
    function testFutureTimestampPanicsEverywhere() public {
        SSPOMockFeed f = _feed(STOCK, 8, 200e8);
        oracle.setDirectPrice(STOCK, 150e18);
        PToken market = _market(STOCK, "pNVDA");
        f.setRound(200e8, block.timestamp + 1);
        vm.expectRevert(stdError.arithmeticError);
        oracle.assetPrices(STOCK);
        vm.expectRevert(stdError.arithmeticError);
        oracle.getUnderlyingPrice(market);
        vm.expectRevert(stdError.arithmeticError);
        oracle.isPriceStale(STOCK);
        address[] memory a = new address[](1);
        a[0] = STOCK;
        vm.expectRevert(stdError.arithmeticError);
        oracle.updateChainlinkPrices(a);
    }

    function testRevertingDecimalsOnFreshRoundIsNotCaught() public {
        SSPODecimalsRevertFeed f = new SSPODecimalsRevertFeed();
        oracle.registerChainlinkFeed(STOCK, address(f));
        oracle.setDirectPrice(STOCK, 150e18);
        vm.expectRevert("NO_DECIMALS");
        oracle.assetPrices(STOCK);
    }

    /// PIN: only updatedAt, price sign and decimals are checked. A zero updatedAt passes while
    /// the configured threshold covers the current timestamp.
    function testZeroUpdatedAtAcceptedWhenThresholdIsHuge() public {
        SSPOMockFeed f = _feed(STOCK, 8, 200e8);
        f.setRound(200e8, 0);
        assertEq(oracle.assetPrices(STOCK), 0, "stale at the default threshold, nothing to fall back to");
        oracle.setChainlinkStaleThreshold(type(uint256).max);
        assertEq(oracle.assetPrices(STOCK), 200e18);
    }

    // ---------------------------------------------------------------- unit semantics

    /// PIN (known, handled by RobinhoodLendingPriceAdapter): getUnderlyingPrice returns plain USD
    /// 1e18 regardless of the underlying's decimals, so a 6-decimal USDG market is priced as if
    /// it had 18 decimals. This source alone is not Compound-scaled for non-18-decimal tokens.
    function testGetUnderlyingPriceIsNotScaledForUnderlyingDecimals() public {
        _feed(USD, 8, 1e8);
        assertEq(oracle.getUnderlyingPrice(_market(USD, "pUSDG")), 1e18);
        assertEq(oracle.assetPrices(USD), 1e18);
    }
}

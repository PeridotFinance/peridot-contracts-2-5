// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PriceOracle} from "./PriceOracle.sol";
import {PToken} from "./PToken.sol";
import {IMarginPriceOracle} from "./margin/interfaces/IMarginPriceOracle.sol";

interface IShareMarket {
    function underlying() external view returns (address);
    function isPToken() external view returns (bool);
}

/**
 * @title PharaohDlmmShareOracle
 * @notice Controller price oracle for the Avalanche pilot: the EXISTING guarded oracle for every market it already
 *         knows, plus ONE extra market, `bpPHAR-USDC`, whose underlying is the share token of the Peridot Pharaoh
 *         DLMM USDC/USDt ERC-4626 vault.
 *
 * @dev TRUST MODEL. Ownerless: the base oracle, the one market, its vault and the vault asset are immutables fixed at
 *      construction. There is no function that adds, replaces or removes a vault, changes the base oracle, or sets a
 *      price. The only mutable state is ONE stored "last good vault leg" (assets per whole share) that the permissionless
 *      `poke()` may move under the bounds below; nobody can write an arbitrary value. The controller admin (the Ledger)
 *      can already point the controller at any oracle with one transaction, so an owner here would add power without adding
 *      capability; rolling back is `controller._setPriceOracle(baseOracle)`.
 *
 *      IDENTITY. For every pToken other than `market`, `getUnderlyingPrice` is `baseOracle.getUnderlyingPrice(pToken)`
 *      through a plain external call: same value, and a revert in the base oracle is the wrapper's revert too. The
 *      margin surface (`getPrice(asset)`, `marketAsset(pToken)`) is forwarded verbatim for EVERY argument (the share
 *      market is NOT registered as a margin market: `marketAsset(market)` is whatever the base oracle says, i.e. 0).
 *      Nothing on the identity path reads the vault, the market or any storage.
 *
 *      SHARE PRICE. USD per share = (assets per whole share) x the BASE oracle's USD price of the vault asset (USDC).
 *      Reusing the base oracle's USDC price (the one the pUSDC market is priced with, same feed and maxAge) means the
 *      USDC price cancels out of a bpPHAR / pUSDC health comparison and no second feed configuration exists. The USDC
 *      price is ALWAYS the live base-oracle read; only the vault leg can ever come from storage. Prices use the Peridot
 *      scaling 10^(36 - underlyingDecimals).
 *
 *      FALLBACK (the only logic added in v2/v3). The vault's `totalAssets()` (hence `convertToAssets`) reverts with its own
 *      `FeedInvalid(uint8)` when one of its two Chainlink feeds (USDC/USD, USDT/USD) is stale or bad; an out-of-band price or a
 *      pool/oracle deviation does NOT revert it and the live value is returned unchanged. ONLY that selector is an outage: the share
 *      price is then the LAST GOOD vault leg minus FALLBACK_HAIRCUT_BPS (3%) times the live USDC price, for at most FALLBACK_WINDOW
 *      (24 h) after the last successful `poke()`; after that it is 0 ("price unavailable", the controller answers PRICE_ERROR).
 *      Any OTHER failure is a broken vault and prices 0 at once, with no fallback: another revert (a failed pair read is
 *      `ExitFailed`), an empty revert (out of gas), a zero or oversized answer, an `asset()` that cannot answer or answers a different
 *      asset, and a base oracle with no USDC price (the USDC feed itself is stale: pUSDC is then unpriced by the base oracle as well).
 *      Without a recurring `poke()` the fallback simply expires 24 h after the last poke (the behaviour of v1: price 0 during a vault outage).
 *
 *      WRITE PATH. The stored leg is seeded in the constructor and moved only by `poke()`: it stores the LIVE vault leg when
 *      the live read succeeds. Downward moves are stored at once. Upward moves are stored at most once per POKE_UP_INTERVAL
 *      (1 h) and by at most POKE_MAX_UP_BPS (2%) per store, so a feed glitch that briefly inflates the NAV can raise the
 *      stored value by at most 2% per hour (a per-store cap alone would compound inside one transaction). When the stored
 *      value is older than FALLBACK_WINDOW the next poke replaces it with the live value, whatever it is.
 *
 *      EXTENSION POINT. `getUnderlyingPrice` for the share market is `_guardPrice(_sharePriceUnderlying())`.
 *      `_guardPrice` returns its input unchanged.
 */
contract PharaohDlmmShareOracle is PriceOracle, IMarginPriceOracle {
    /// @notice The oracle every other market is priced by (the controller's oracle at deployment).
    PriceOracle public immutable baseOracle;
    /// @notice The one extra market (pToken) priced here.
    address public immutable market;
    /// @notice The vault whose shares are `market`'s underlying.
    address public immutable vault;
    /// @notice The vault's asset (USDC); its USD price is read from `baseOracle.getPrice`.
    address public immutable vaultAsset;
    uint8 public immutable shareDecimals;
    uint8 public immutable assetDecimals;

    uint256 private immutable SHARE_UNIT; // 10 ** shareDecimals
    uint256 private immutable ASSET_UNIT; // 10 ** assetDecimals
    uint256 private immutable PRICE_SCALE; // 10 ** (18 - shareDecimals)

    uint256 private constant MAX_OPERAND = type(uint128).max;
    uint256 private constant BPS = 10_000;

    /// @notice Haircut applied to the stored vault leg while the fallback is in use (3%).
    uint256 public constant FALLBACK_HAIRCUT_BPS = 300;
    /// @notice How long after the last successful poke the stored vault leg may still be used (24 h).
    uint256 public constant FALLBACK_WINDOW = 24 hours;
    /// @notice Largest upward step of the stored vault leg per accepted poke (2%).
    uint256 public constant POKE_MAX_UP_BPS = 200;
    /// @notice Minimum time between two accepted UPWARD pokes (1 h).
    uint256 public constant POKE_UP_INTERVAL = 1 hours;

    /// @notice Last good vault leg: asset base units per ONE WHOLE share (10^shareDecimals base units), and when it was stored.
    uint128 public lastGoodAssetsPerShare;
    uint64 public lastGoodTime;

    /// @dev vault leg status: OK = live value, UNAVAILABLE = the vault answered asset() but convertToAssets reverted with ITS OWN
    ///      FeedInvalid(uint8) (a Chainlink feed stale or bad: the only outage the fallback covers), BROKEN = anything else (asset()
    ///      unreadable or different, another revert such as a failed pair read, out of gas, a zero or oversized answer): never falls back.
    bytes4 private constant FEED_INVALID = bytes4(keccak256("FeedInvalid(uint8)"));
    uint8 private constant LEG_OK = 0;
    uint8 private constant LEG_UNAVAILABLE = 1;
    uint8 private constant LEG_BROKEN = 2;

    event FallbackPriceStored(uint256 assetsPerShare, uint256 at);

    error PharaohDlmmOracle__InvalidConfiguration();

    constructor(PriceOracle baseOracle_, address market_) {
        if (address(baseOracle_).code.length == 0 || market_.code.length == 0) {
            revert PharaohDlmmOracle__InvalidConfiguration();
        }
        IShareMarket pToken = IShareMarket(market_);
        if (!pToken.isPToken() || !baseOracle_.isPriceOracle()) revert PharaohDlmmOracle__InvalidConfiguration();

        address vault_ = pToken.underlying();
        if (vault_.code.length == 0) revert PharaohDlmmOracle__InvalidConfiguration();
        // NO check against the controller's current oracle: after the swap the controller points at THIS wrapper, and a fixed or rate-limited
        // replacement must be deployable without first rolling back (the deploy script's check() pins controller.oracle() == the base oracle
        // before the first wrapper is created)

        address asset_ = _readAddress(vault_, abi.encodeWithSignature("asset()"));
        uint8 shareDecimals_ = _readDecimals(vault_);
        uint8 assetDecimals_ = _readDecimals(asset_);
        if (asset_.code.length == 0 || shareDecimals_ > 18 || assetDecimals_ > 18) {
            revert PharaohDlmmOracle__InvalidConfiguration();
        }

        uint256 shareUnit = 10 ** shareDecimals_;
        uint256 assetUnit = 10 ** assetDecimals_;
        uint256 priceScale = 10 ** (18 - shareDecimals_);

        baseOracle = baseOracle_;
        market = market_;
        vault = vault_;
        vaultAsset = asset_;
        shareDecimals = shareDecimals_;
        assetDecimals = assetDecimals_;
        SHARE_UNIT = shareUnit;
        ASSET_UNIT = assetUnit;
        PRICE_SCALE = priceScale;

        // the share price and the asset price must both be available when the wrapper is created; the live vault leg seeds the fallback
        (uint8 status, uint256 leg) = _vaultLeg(vault_, asset_, shareUnit);
        if (status != LEG_OK || _assetUsd(address(baseOracle_), asset_) == 0) revert PharaohDlmmOracle__InvalidConfiguration();
        // forge-lint: disable-next-line(unsafe-typecast)
        lastGoodAssetsPerShare = uint128(leg); // leg <= MAX_OPERAND = uint128.max (checked in _vaultLeg)
        // forge-lint: disable-next-line(unsafe-typecast)
        lastGoodTime = uint64(block.timestamp);
        emit FallbackPriceStored(leg, block.timestamp);
    }

    // ------------------------------------------------------------------------------------------------ PriceOracle

    function getUnderlyingPrice(PToken pToken) external view override returns (uint256) {
        if (address(pToken) != market) return baseOracle.getUnderlyingPrice(pToken);
        return _guardPrice(_sharePriceUnderlying());
    }

    // ------------------------------------------------------------------------------- IMarginPriceOracle (verbatim)

    function getPrice(address asset) external view override returns (uint256) {
        return IMarginPriceOracle(address(baseOracle)).getPrice(asset);
    }

    function marketAsset(address pToken) external view override returns (address) {
        return IMarginPriceOracle(address(baseOracle)).marketAsset(pToken);
    }

    // ------------------------------------------------------------------------------------------------------ views

    /// @notice USD price (1e18) of ONE WHOLE share, 0 when unavailable (includes the fallback). For monitoring; the controller uses getUnderlyingPrice.
    function getShareUsdPrice() external view returns (uint256) {
        return _guardPrice(_sharePriceUnderlying()) / PRICE_SCALE;
    }

    /// @notice Monitoring: the live vault leg (0 when the vault cannot answer), the stored leg, when it was stored, whether the controller is
    ///         being served from the fallback right now, and how many seconds of fallback window are left (0 when expired).
    function shareState()
        external
        view
        returns (uint256 liveAssetsPerShare, uint256 storedAssetsPerShare, uint64 storedAt, bool usingFallback, uint256 fallbackSecondsLeft)
    {
        (uint8 status, uint256 leg) = _vaultLeg(vault, vaultAsset, SHARE_UNIT);
        liveAssetsPerShare = status == LEG_OK ? leg : 0;
        storedAssetsPerShare = lastGoodAssetsPerShare;
        storedAt = lastGoodTime;
        uint256 age = block.timestamp - storedAt;
        fallbackSecondsLeft = age > FALLBACK_WINDOW ? 0 : FALLBACK_WINDOW - age; // the same boundary as the price: valid at age == 24 h
        usingFallback = status == LEG_UNAVAILABLE && age <= FALLBACK_WINDOW && _assetUsd(address(baseOracle), vaultAsset) != 0;
    }

    // ----------------------------------------------------------------------------------------------------- poke

    /// @notice Store the live vault leg as the new "last good" value, within the bounds in the contract header. Permissionless; the stored
    ///         value can only be set from the vault's own live answer. Returns whether a value was stored (false: the vault cannot answer,
    ///         or an upward move came inside POKE_UP_INTERVAL of the last store).
    function poke() external returns (bool stored) {
        (uint8 status, uint256 leg) = _vaultLeg(vault, vaultAsset, SHARE_UNIT);
        if (status != LEG_OK) return false;

        uint256 prev = lastGoodAssetsPerShare;
        uint256 prevAt = lastGoodTime;
        if (block.timestamp - prevAt <= FALLBACK_WINDOW && leg > prev) {
            if (block.timestamp - prevAt < POKE_UP_INTERVAL) return false;
            uint256 cap = (prev * (BPS + POKE_MAX_UP_BPS)) / BPS;
            if (leg > cap) leg = cap;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        lastGoodAssetsPerShare = uint128(leg); // leg <= MAX_OPERAND (checked in _vaultLeg) and the cap keeps it <= prev * 1.02
        // forge-lint: disable-next-line(unsafe-typecast)
        lastGoodTime = uint64(block.timestamp);
        emit FallbackPriceStored(leg, block.timestamp);
        return true;
    }

    // ------------------------------------------------------------------------------------------------ share price

    /// @dev Peridot-scaled price of the share token (10^(36-shareDecimals) per USD), or 0. Never reverts.
    function _sharePriceUnderlying() internal view returns (uint256) {
        (uint8 status, uint256 leg) = _vaultLeg(vault, vaultAsset, SHARE_UNIT);
        if (status == LEG_BROKEN) return 0;
        if (status == LEG_UNAVAILABLE) {
            if (block.timestamp - lastGoodTime > FALLBACK_WINDOW) return 0;
            leg = (uint256(lastGoodAssetsPerShare) * (BPS - FALLBACK_HAIRCUT_BPS)) / BPS;
            if (leg == 0) return 0;
        }
        uint256 assetUsd18 = _assetUsd(address(baseOracle), vaultAsset);
        if (assetUsd18 == 0) return 0;
        // (assets per whole share / 10^assetDecimals) x USD per asset (1e18) x 10^(18-shareDecimals); multiply first, divide once
        return (leg * assetUsd18 * PRICE_SCALE) / ASSET_UNIT;
    }

    /// @dev The vault leg: assets per whole share, read live. Never reverts.
    function _vaultLeg(address vault_, address asset_, uint256 shareUnit) private view returns (uint8 status, uint256 assetsPerShare) {
        (bool okAsset, address currentAsset) = _tryAddress(vault_, abi.encodeWithSignature("asset()"));
        if (!okAsset || currentAsset != asset_) return (LEG_BROKEN, 0);

        (bool okVault, bytes memory ret) = vault_.staticcall(abi.encodeWithSignature("convertToAssets(uint256)", shareUnit));
        if (!okVault) {
            // ONLY the vault's own FeedInvalid(uint8) (a Chainlink feed stale or bad) is an outage; any other revert (a failed pair read = ExitFailed, out of gas = empty data, a panic) is a BROKEN vault: price 0, no fallback
            if (ret.length >= 4 && bytes4(ret) == FEED_INVALID) return (LEG_UNAVAILABLE, 0);
            return (LEG_BROKEN, 0);
        }
        if (ret.length < 32) return (LEG_BROKEN, 0);
        uint256 value = abi.decode(ret, (uint256));
        // an answer of 0 (NAV rounds to nothing) is a broken vault, not an outage
        if (value == 0 || value > MAX_OPERAND) return (LEG_BROKEN, 0);
        return (LEG_OK, value);
    }

    /// @dev The base oracle's USD price (1e18) of the vault asset, 0 when unavailable or oversized.
    function _assetUsd(address base_, address asset_) private view returns (uint256) {
        (bool ok, uint256 price) = _tryUint(base_, abi.encodeCall(IMarginPriceOracle.getPrice, (asset_)));
        if (!ok || price == 0 || price > MAX_OPERAND) return 0;
        return price;
    }

    /// @dev Hook for a share-price rate limiter. Identity today. Applies ONLY to the share market.
    function _guardPrice(uint256 price) internal view virtual returns (uint256) {
        return price;
    }

    // -------------------------------------------------------------------------------------------- low-level reads

    function _tryUint(address target, bytes memory data) private view returns (bool ok, uint256 value) {
        (bool success, bytes memory ret) = target.staticcall(data);
        if (!success || ret.length < 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }

    function _tryAddress(address target, bytes memory data) private view returns (bool ok, address value) {
        (bool success, bytes memory ret) = target.staticcall(data);
        if (!success || ret.length < 32) return (false, address(0));
        uint256 word = abi.decode(ret, (uint256));
        if (word > type(uint160).max) return (false, address(0));
        // forge-lint: disable-next-line(unsafe-typecast)
        return (true, address(uint160(word)));
    }

    function _readAddress(address target, bytes memory data) private view returns (address) {
        (bool ok, address value) = _tryAddress(target, data);
        if (!ok || value == address(0)) revert PharaohDlmmOracle__InvalidConfiguration();
        return value;
    }

    function _readDecimals(address token) private view returns (uint8) {
        (bool ok, uint256 value) = _tryUint(token, abi.encodeWithSignature("decimals()"));
        if (!ok || value > 255) revert PharaohDlmmOracle__InvalidConfiguration();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(value);
    }
}

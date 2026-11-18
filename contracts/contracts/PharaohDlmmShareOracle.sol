// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PriceOracle} from "./PriceOracle.sol";
import {PToken} from "./PToken.sol";
import {IMarginPriceOracle} from "./margin/interfaces/IMarginPriceOracle.sol";

interface IShareMarket {
    function underlying() external view returns (address);
    function peridottroller() external view returns (address);
    function isPToken() external view returns (bool);
}

interface IControllerOracle {
    function oracle() external view returns (address);
}

/**
 * @title PharaohDlmmShareOracle
 * @notice Controller price oracle for the Avalanche pilot: the EXISTING guarded oracle for every market it already
 *         knows, plus ONE extra market, `bpPHAR-USDC`, whose underlying is the share token of the Peridot Pharaoh
 *         DLMM USDC/USDt ERC-4626 vault.
 *
 * @dev TRUST MODEL. Stateless and ownerless: the base oracle, the one market, its vault and the vault asset are
 *      immutables fixed at construction. There is no function that adds, replaces or removes a vault, changes the
 *      base oracle, or sets a price. The controller admin (the Ledger) can already point the controller at any oracle
 *      with one transaction, so an owner here would add power without adding capability; rolling back is
 *      `controller._setPriceOracle(baseOracle)`.
 *
 *      IDENTITY. For every pToken other than `market`, `getUnderlyingPrice` is `baseOracle.getUnderlyingPrice(pToken)`
 *      through a plain external call: same value, and a revert in the base oracle is the wrapper's revert too. The
 *      margin surface (`getPrice(asset)`, `marketAsset(pToken)`) is forwarded verbatim for EVERY argument (the share
 *      market is NOT registered as a margin market: `marketAsset(market)` is whatever the base oracle says, i.e. 0).
 *      Nothing on the identity path reads the vault, the market or any storage.
 *
 *      SHARE PRICE (the only new logic). USD per share = vault.convertToAssets(1 whole share) x the BASE oracle's
 *      USD price of the vault asset (USDC). Reusing the base oracle's USDC price (the one the pUSDC market is priced
 *      with, same feed and maxAge) means the USDC price cancels out of a bpPHAR / pUSDC health comparison and no
 *      second feed configuration exists. Prices use the Peridot scaling 10^(36 - underlyingDecimals).
 *      FAIL CLOSED: a reverting or short-returning vault or base oracle, a changed vault asset, an out-of-range value
 *      or a zero price returns 0 ("price unavailable", the controller answers PRICE_ERROR). The share path never
 *      reverts, so a broken vault can never make an UNRELATED market's price revert. The DLMM vault's `totalAssets`
 *      reverts when its own Chainlink feeds are stale, which is exactly this case.
 *
 *      EXTENSION POINT. `getUnderlyingPrice` for the share market is `_guardPrice(_sharePriceUnderlying())`.
 *      `_guardPrice` returns its input unchanged; a share-price rate limiter would be added by overriding it in a
 *      subclass (or here) without touching the identity path.
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

    error PharaohDlmmOracle__InvalidConfiguration();

    constructor(PriceOracle baseOracle_, address market_) {
        if (address(baseOracle_).code.length == 0 || market_.code.length == 0) {
            revert PharaohDlmmOracle__InvalidConfiguration();
        }
        IShareMarket pToken = IShareMarket(market_);
        if (!pToken.isPToken() || !baseOracle_.isPriceOracle()) revert PharaohDlmmOracle__InvalidConfiguration();

        address vault_ = pToken.underlying();
        if (vault_.code.length == 0) revert PharaohDlmmOracle__InvalidConfiguration();
        // the base oracle must be the one the market's controller uses right now (deploy-time pin against a wrong address)
        if (IControllerOracle(pToken.peridottroller()).oracle() != address(baseOracle_)) {
            revert PharaohDlmmOracle__InvalidConfiguration();
        }

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

        // the share price and the asset price must both be available when the wrapper is created
        if (_computeSharePrice(vault_, asset_, address(baseOracle_), shareUnit, assetUnit, priceScale) == 0) {
            revert PharaohDlmmOracle__InvalidConfiguration();
        }
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

    /// @notice USD price (1e18) of ONE WHOLE share, 0 when unavailable. For monitoring; the controller uses getUnderlyingPrice.
    function getShareUsdPrice() external view returns (uint256) {
        return _guardPrice(_sharePriceUnderlying()) / PRICE_SCALE;
    }

    // ------------------------------------------------------------------------------------------------ share price

    /// @dev Peridot-scaled price of the share token (10^(36-shareDecimals) per USD), or 0. Never reverts.
    function _sharePriceUnderlying() internal view returns (uint256) {
        return _computeSharePrice(vault, vaultAsset, address(baseOracle), SHARE_UNIT, ASSET_UNIT, PRICE_SCALE);
    }

    function _computeSharePrice(
        address vault_,
        address asset_,
        address base_,
        uint256 shareUnit,
        uint256 assetUnit,
        uint256 priceScale
    ) private view returns (uint256) {
        (bool okAsset, address currentAsset) = _tryAddress(vault_, abi.encodeWithSignature("asset()"));
        if (!okAsset || currentAsset != asset_) return 0;

        (bool okVault, uint256 assetsPerShare) =
            _tryUint(vault_, abi.encodeWithSignature("convertToAssets(uint256)", shareUnit));
        if (!okVault || assetsPerShare == 0 || assetsPerShare > MAX_OPERAND) return 0;

        (bool okPrice, uint256 assetUsd18) = _tryUint(base_, abi.encodeCall(IMarginPriceOracle.getPrice, (asset_)));
        if (!okPrice || assetUsd18 == 0 || assetUsd18 > MAX_OPERAND) return 0;

        // (assets per whole share / 10^assetDecimals) x USD per asset (1e18) x 10^(18-shareDecimals); multiply first, divide once
        return (assetsPerShare * assetUsd18 * priceScale) / assetUnit;
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

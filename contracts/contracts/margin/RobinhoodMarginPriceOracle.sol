// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IMarginPriceOracle} from "./interfaces/IMarginPriceOracle.sol";

interface IAssetPriceSource {
    /// @notice Asset price in USD scaled to 1e18, or zero when unavailable or stale.
    function assetPrices(address asset) external view returns (uint256);
}

interface IRobinhoodVaultClaim {
    function accountedAssets(bytes32 pairId, address token) external view returns (uint256);
}

interface IRobinhoodBoostedMarket {
    function underlying() external view returns (address);
    function robinhoodVault() external view returns (address);
    function robinhoodPairId() external view returns (bytes32);
}

/**
 * @title RobinhoodMarginPriceOracle
 * @notice Margin price source for Robinhood Chain, wrapping the same asset oracle the lending
 *         markets use so margin and lending cannot drift onto different prices.
 * @dev Registered Robinhood boosted markets get one extra check. Their pToken exchange rate is
 *      `localCash + vaultClaim`, and the delegate treats an unreadable vault claim as zero so a
 *      redeemer can never be over-credited. That fallback is correct for redemption and wrong
 *      for collateral: the margin risk engine values a position as
 *      `underlyingFromPToken(amount, exchangeRateStored()) * price`, so a claim that reads as
 *      zero would price the collateral at nearly nothing and make the account liquidatable at a
 *      valuation that is not real.
 *
 *      `marketAsset` therefore returns the zero address when the vault claim cannot be read, and
 *      `IsolatedMarginRiskEngineUpgradeable.pTokenValueUsd` already reverts `PriceUnavailable` on
 *      a zero asset. The valuation fails closed instead of returning a collapsed number, and no
 *      change is needed in the margin core shared with other chains.
 *
 *      This is defense in depth, not a routine path. `accountedAssets` is a pure ledger read on
 *      the vault: it consults no oracle and reverts only on an unregistered pair or a token that
 *      is not one of the pair's two. A stale price feed does not trigger it. Collateral
 *      valuation on these markets is oracle-independent; only a genuine vault fault reaches
 *      this branch.
 */
contract RobinhoodMarginPriceOracle is IMarginPriceOracle, Ownable {
    IAssetPriceSource public assetSource;

    mapping(address => address) private _assetOf;
    mapping(address => bool) public isBoostedMarket;

    error InvalidConfiguration();

    event AssetSourceUpdated(address indexed source);
    event MarketRegistered(address indexed pToken, address indexed asset, bool boosted);
    event MarketDeregistered(address indexed pToken);

    constructor(address owner_, address assetSource_) Ownable(owner_) {
        if (owner_ == address(0) || assetSource_.code.length == 0) revert InvalidConfiguration();
        assetSource = IAssetPriceSource(assetSource_);
        emit AssetSourceUpdated(assetSource_);
    }

    function setAssetSource(address assetSource_) external onlyOwner {
        if (assetSource_.code.length == 0) revert InvalidConfiguration();
        assetSource = IAssetPriceSource(assetSource_);
        emit AssetSourceUpdated(assetSource_);
    }

    /**
     * @notice Registers a market so margin can price it.
     * @param boosted True for a Robinhood boosted market, whose vault claim is checked on read.
     * @dev For a boosted market the asset must equal the pToken's own `underlying`, so a
     *      misregistration cannot quietly price one market off another asset's feed.
     */
    function registerMarket(address pToken, address asset, bool boosted) external onlyOwner {
        if (pToken.code.length == 0 || asset == address(0)) revert InvalidConfiguration();
        if (boosted) {
            if (IRobinhoodBoostedMarket(pToken).underlying() != asset) revert InvalidConfiguration();
            // Must be readable at registration, or the market is misconfigured from the start.
            if (!_vaultClaimReadable(pToken)) revert InvalidConfiguration();
        }
        _assetOf[pToken] = asset;
        isBoostedMarket[pToken] = boosted;
        emit MarketRegistered(pToken, asset, boosted);
    }

    function deregisterMarket(address pToken) external onlyOwner {
        delete _assetOf[pToken];
        delete isBoostedMarket[pToken];
        emit MarketDeregistered(pToken);
    }

    /// @inheritdoc IMarginPriceOracle
    function getPrice(address asset) external view returns (uint256) {
        if (asset == address(0)) return 0;
        try assetSource.assetPrices(asset) returns (uint256 price) {
            return price;
        } catch {
            return 0;
        }
    }

    /**
     * @inheritdoc IMarginPriceOracle
     * @dev Returns the zero address for a boosted market whose vault claim cannot be read, which
     *      makes the risk engine revert rather than value the position off a collapsed exchange
     *      rate.
     */
    function marketAsset(address pToken) external view returns (address) {
        address asset = _assetOf[pToken];
        if (asset == address(0)) return address(0);
        if (isBoostedMarket[pToken] && !_vaultClaimReadable(pToken)) return address(0);
        return asset;
    }

    /// @notice Whether margin will currently price this market. Useful for monitoring.
    function marketPriceable(address pToken) external view returns (bool) {
        address asset = _assetOf[pToken];
        if (asset == address(0)) return false;
        if (isBoostedMarket[pToken] && !_vaultClaimReadable(pToken)) return false;
        try assetSource.assetPrices(asset) returns (uint256 price) {
            return price != 0;
        } catch {
            return false;
        }
    }

    /**
     * @dev Mirrors the exact call the delegate makes when computing its exchange rate, so this
     *      cannot disagree with what the pToken itself would observe.
     */
    function _vaultClaimReadable(address pToken) internal view returns (bool) {
        IRobinhoodBoostedMarket market = IRobinhoodBoostedMarket(pToken);

        address vault;
        bytes32 pairId;
        address token;
        try market.robinhoodVault() returns (address vault_) {
            vault = vault_;
        } catch {
            return false;
        }
        if (vault == address(0) || vault.code.length == 0) return false;

        try market.robinhoodPairId() returns (bytes32 pairId_) {
            pairId = pairId_;
        } catch {
            return false;
        }
        if (pairId == bytes32(0)) return false;

        try market.underlying() returns (address token_) {
            token = token_;
        } catch {
            return false;
        }

        try IRobinhoodVaultClaim(vault).accountedAssets(pairId, token) returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }
}

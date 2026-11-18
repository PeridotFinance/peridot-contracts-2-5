// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {PErc20} from "../../../../contracts/PErc20.sol";
import {PToken} from "../../../../contracts/PToken.sol";
import {PriceOracle} from "../../../../contracts/PriceOracle.sol";

/**
 * @title PharaohVaultShareOracle
 * @notice Adds fail-closed Pharaoh ERC-4626 share prices to an existing Peridot oracle.
 * @dev Unregistered markets delegate to `baseOracle`. Registered vault-share markets use the
 *      vault's conservative `convertToAssets` accounting and the vault asset's Chainlink USD feed.
 *      Prices use Compound/Peridot's 10^(36-underlyingDecimals) scaling.
 */
contract PharaohVaultShareOracle is PriceOracle, Ownable {
    uint256 public constant MAX_STALENESS = 7 days;

    /// @notice OPTIONAL RATE LIMIT (see docs-manip/bp-dlmm-share-price-manipulation.md, section 7). The share price the controller reads may rise
    ///         by at most this many bp per hour above the last checkpoint (linear, never compounded); a fall is passed through at once.
    ///         Stateless callers get `min(spot, checkpoint x (1 + rate x elapsed))`, so a stale checkpoint only LOOSENS the cap (fails open to the old behaviour).
    uint256 public constant MAX_RISE_BPS_PER_HOUR = 100;

    /// @dev one storage slot per vault: USD per whole share (1e18) and the time it was stored
    struct Checkpoint {
        uint128 price18;
        uint64 updatedAt;
    }

    struct VaultConfig {
        AggregatorV3Interface assetUsdFeed;
        address asset;
        uint64 maxStaleness;
        uint8 assetDecimals;
        uint8 shareDecimals;
        uint64 feedScale;
    }

    error PharaohOracle__ZeroAddress();
    error PharaohOracle__InvalidConfiguration();
    error PharaohOracle__InvalidFeed();
    error PharaohOracle__InvalidVault();

    PriceOracle public immutable baseOracle;
    mapping(address vaultShare => VaultConfig config) public vaultConfigs;
    mapping(address vaultShare => Checkpoint checkpoint) public checkpoints;

    event VaultRegistered(address indexed vaultShare, address indexed asset, address indexed assetUsdFeed);
    event VaultRemoved(address indexed vaultShare);
    event CheckpointPoked(address indexed vaultShare, uint256 spotPrice18, uint256 storedPrice18);

    constructor(address owner_, PriceOracle baseOracle_) Ownable(owner_) {
        if (owner_ == address(0) || address(baseOracle_) == address(0) || address(baseOracle_).code.length == 0) {
            revert PharaohOracle__ZeroAddress();
        }
        baseOracle = baseOracle_;
    }

    function registerVault(IERC4626 vault, AggregatorV3Interface assetUsdFeed, uint64 maxStaleness) external onlyOwner {
        address vaultShare = address(vault);
        if (vaultShare == address(0) || address(assetUsdFeed) == address(0)) {
            revert PharaohOracle__ZeroAddress();
        }
        if (vaultShare.code.length == 0 || address(assetUsdFeed).code.length == 0) {
            revert PharaohOracle__InvalidConfiguration();
        }
        if (maxStaleness == 0 || maxStaleness > MAX_STALENESS) {
            revert PharaohOracle__InvalidConfiguration();
        }

        address asset;
        uint8 assetDecimals;
        uint8 shareDecimals;
        uint8 feedDecimals;
        try vault.asset() returns (address returnedAsset) {
            asset = returnedAsset;
        } catch {
            revert PharaohOracle__InvalidVault();
        }
        if (asset == address(0) || asset.code.length == 0) revert PharaohOracle__InvalidVault();

        try IERC20Metadata(asset).decimals() returns (uint8 returnedDecimals) {
            assetDecimals = returnedDecimals;
        } catch {
            revert PharaohOracle__InvalidVault();
        }
        try IERC20Metadata(vaultShare).decimals() returns (uint8 returnedDecimals) {
            shareDecimals = returnedDecimals;
        } catch {
            revert PharaohOracle__InvalidVault();
        }
        try assetUsdFeed.decimals() returns (uint8 returnedDecimals) {
            feedDecimals = returnedDecimals;
        } catch {
            revert PharaohOracle__InvalidFeed();
        }
        if (assetDecimals > 18 || shareDecimals > 18 || feedDecimals > 18) {
            revert PharaohOracle__InvalidConfiguration();
        }

        VaultConfig memory config = VaultConfig({
            assetUsdFeed: assetUsdFeed,
            asset: asset,
            maxStaleness: maxStaleness,
            assetDecimals: assetDecimals,
            shareDecimals: shareDecimals,
            feedScale: uint64(10 ** (18 - feedDecimals))
        });
        if (_readAssetUsdPrice(config) == 0) revert PharaohOracle__InvalidFeed();
        if (_readAssetsPerWholeShare(vault, shareDecimals) == 0) revert PharaohOracle__InvalidVault();

        vaultConfigs[vaultShare] = config;
        checkpoints[vaultShare] =
            Checkpoint({price18: uint128(_shareUsdPrice18(vault, config)), updatedAt: uint64(block.timestamp)});
        emit VaultRegistered(vaultShare, asset, address(assetUsdFeed));
    }

    function removeVault(address vaultShare) external onlyOwner {
        if (address(vaultConfigs[vaultShare].assetUsdFeed) == address(0)) revert PharaohOracle__InvalidVault();
        delete vaultConfigs[vaultShare];
        delete checkpoints[vaultShare];
        emit VaultRemoved(vaultShare);
    }

    /// @notice Permissionless: moves the checkpoint to `min(spot, allowed)`. It can never raise the checkpoint faster than the rate and never stores 0
    ///         (a failed feed read leaves the checkpoint alone). Poke it hourly from any keeper; skipping pokes only loosens the cap.
    function poke(address vaultShare) external {
        VaultConfig memory config = vaultConfigs[vaultShare];
        if (address(config.assetUsdFeed) == address(0)) revert PharaohOracle__InvalidVault();
        uint256 spot = _shareUsdPrice18(IERC4626(vaultShare), config);
        if (spot == 0) return;
        uint256 stored = _limited(vaultShare, spot);
        checkpoints[vaultShare] = Checkpoint({price18: uint128(stored), updatedAt: uint64(block.timestamp)});
        emit CheckpointPoked(vaultShare, spot, stored);
    }

    /// @notice Share price without the rate limit (diagnostics only; the controller never reads it).
    function getRawShareUsdPrice(address vaultShare) external view returns (uint256) {
        VaultConfig memory config = vaultConfigs[vaultShare];
        if (address(config.assetUsdFeed) == address(0)) return 0;
        return _shareUsdPrice18(IERC4626(vaultShare), config);
    }

    function getUnderlyingPrice(PToken pToken) public view override returns (uint256) {
        address vaultShare = _marketUnderlying(address(pToken));
        VaultConfig memory config = vaultConfigs[vaultShare];
        if (vaultShare == address(0) || address(config.assetUsdFeed) == address(0)) {
            return baseOracle.getUnderlyingPrice(pToken);
        }

        uint256 shareUsdPrice18 = _shareUsdPrice18(IERC4626(vaultShare), config);
        if (shareUsdPrice18 == 0) return 0;
        shareUsdPrice18 = _limited(vaultShare, shareUsdPrice18);

        uint256 marketScale = 10 ** (18 - config.shareDecimals);
        if (shareUsdPrice18 > type(uint256).max / marketScale) return 0;
        return shareUsdPrice18 * marketScale;
    }

    function getShareUsdPrice(address vaultShare) external view returns (uint256) {
        VaultConfig memory config = vaultConfigs[vaultShare];
        if (address(config.assetUsdFeed) == address(0)) return 0;
        uint256 spot = _shareUsdPrice18(IERC4626(vaultShare), config);
        return spot == 0 ? 0 : _limited(vaultShare, spot);
    }

    /// @dev min(spot, checkpoint x (1 + MAX_RISE_BPS_PER_HOUR x elapsed / 1h / 10_000)); spot when there is no checkpoint
    function _limited(address vaultShare, uint256 spot) private view returns (uint256) {
        Checkpoint memory c = checkpoints[vaultShare];
        if (c.updatedAt == 0 || c.price18 == 0) return spot;
        uint256 elapsed = block.timestamp > c.updatedAt ? block.timestamp - c.updatedAt : 0;
        uint256 cap = uint256(c.price18) + uint256(c.price18) * MAX_RISE_BPS_PER_HOUR * elapsed / (10_000 * 1 hours);
        return spot < cap ? spot : cap;
    }

    function _shareUsdPrice18(IERC4626 vault, VaultConfig memory config) private view returns (uint256) {
        address currentAsset;
        try vault.asset() returns (address returnedAsset) {
            currentAsset = returnedAsset;
        } catch {
            return 0;
        }
        if (currentAsset != config.asset) return 0;

        uint256 assetsPerWholeShare = _readAssetsPerWholeShare(vault, config.shareDecimals);
        if (assetsPerWholeShare == 0) return 0;

        uint256 assetUsdPrice18 = _readAssetUsdPrice(config);
        if (assetUsdPrice18 == 0) return 0;
        if (assetsPerWholeShare > type(uint256).max / assetUsdPrice18) return 0;
        return (assetsPerWholeShare * assetUsdPrice18) / (10 ** config.assetDecimals);
    }

    function _readAssetsPerWholeShare(IERC4626 vault, uint8 shareDecimals) private view returns (uint256) {
        try vault.convertToAssets(10 ** shareDecimals) returns (uint256 assetsPerWholeShare) {
            return assetsPerWholeShare;
        } catch {
            return 0;
        }
    }

    function _readAssetUsdPrice(VaultConfig memory config) private view returns (uint256) {
        try config.assetUsdFeed.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound
        ) {
            if (
                roundId == 0 || answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp
                    || answeredInRound < roundId || block.timestamp - updatedAt > config.maxStaleness
            ) return 0;
            uint256 unsignedAnswer = uint256(answer);
            if (unsignedAnswer > type(uint256).max / config.feedScale) return 0;
            return unsignedAnswer * config.feedScale;
        } catch {
            return 0;
        }
    }

    function _marketUnderlying(address pToken) private view returns (address) {
        try PErc20(pToken).underlying() returns (address underlying) {
            return underlying;
        } catch {
            return address(0);
        }
    }
}

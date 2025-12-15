// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import "../contracts/pancakev3/V3LPVault4626.sol";
import "../contracts/pancakev3/V3LPVaultOracle.sol";
import "../contracts/pancakev3/interfaces/INonfungiblePositionManager.sol";
import "../contracts/pancakev3/interfaces/IPancakeV3MasterChef.sol";
import "../contracts/pancakev3/interfaces/IV3LPVault4626.sol";
import "../contracts/margin/IMarginRouterAdapter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract DeployPancakeV3Vault is Script {
    // ===== MONAD MAINNET DEFAULTS (override via env vars) =====
    // PancakeSwap V3 on Monad
    address public constant DEFAULT_POSITION_MANAGER =
        0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address public constant DEFAULT_POOL =
        0x143333EC849D14A6dbd29e7d04DC7a9eBf302165; // AUSD/USDC 0.05%
    address public constant DEFAULT_MASTER_CHEF = address(0); // No MasterChef on Monad
    uint24 public constant DEFAULT_FEE = 500; // 0.05% for stablecoins
    // Stablecoin-optimized: ~10% range around 1:1 price (much more capital efficient than full range)
    int24 public constant DEFAULT_TICK_LOWER = -1000; // ~0.9048 price ratio
    int24 public constant DEFAULT_TICK_UPPER = 1000; // ~1.1052 price ratio
    uint256 public constant DEFAULT_MASTER_PID = 0;
    address public constant DEFAULT_ROUTER_ADAPTER = address(0); // Not needed without rewards
    address public constant DEFAULT_REWARD_TOKEN = address(0); // No CAKE on Monad
    address public constant DEFAULT_TOKEN0 =
        0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a; // AUSD (6 decimals)
    address public constant DEFAULT_TOKEN1 =
        0x754704Bc059F8C67012fEd69BC8A327a5aafb603; // USDC (6 decimals)
    address public constant DEFAULT_KEEPER = address(0);
    uint256 public constant DEFAULT_HARVEST_MIN_TOKEN0 = 0;
    uint256 public constant DEFAULT_HARVEST_MIN_TOKEN1 = 0;
    uint256 public constant DEFAULT_HARVEST_THRESHOLD = 0;
    // Note: Price feeds need to be configured for Monad (these are BSC defaults)
    address public constant DEFAULT_CAKE_USD_FEED = address(0); // Set for your chain
    address public constant DEFAULT_USDT_USD_FEED = address(0); // Set for your chain
    uint256 public constant DEFAULT_MAX_DEVIATION_BPS = 500; // 5%
    uint32 public constant DEFAULT_TWAP_WINDOW = 300; // 5 minutes
    string public constant DEFAULT_VAULT_NAME =
        "Peridot Pancake V3 Vault AUSD/USDC 005";
    string public constant DEFAULT_VAULT_SYMBOL = "pV3AUSD/USDC005";

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        address positionManagerAddr = _requireEnvAddress(
            "POSITION_MANAGER",
            DEFAULT_POSITION_MANAGER
        );
        address poolAddr = _requireEnvAddress("PANCAKE_POOL", DEFAULT_POOL);
        address masterChefAddr = _tryEnvAddress(
            "MASTER_CHEF",
            DEFAULT_MASTER_CHEF
        ); // Optional
        address routerAdapterAddr = _tryEnvAddress(
            "ROUTER_ADAPTER",
            DEFAULT_ROUTER_ADAPTER
        ); // Optional
        address rewardTokenAddr = _tryEnvAddress(
            "REWARD_TOKEN",
            DEFAULT_REWARD_TOKEN
        ); // Optional
        address token0Addr = _requireEnvAddress("TOKEN0", DEFAULT_TOKEN0);
        address token1Addr = _requireEnvAddress("TOKEN1", DEFAULT_TOKEN1);

        uint24 fee = uint24(_tryEnvUint("FEE_TIER", DEFAULT_FEE));
        int24 tickLower = int24(
            int256(
                _tryEnvUint("TICK_LOWER", uint256(int256(DEFAULT_TICK_LOWER)))
            )
        );
        int24 tickUpper = int24(
            int256(
                _tryEnvUint("TICK_UPPER", uint256(int256(DEFAULT_TICK_UPPER)))
            )
        );
        uint256 masterPid = _tryEnvUint("MASTER_PID", DEFAULT_MASTER_PID);
        bool stakeWithMasterChef = _tryEnvBool(
            "STAKE_WITH_MASTER_CHEF",
            masterChefAddr != address(0)
        );

        address keeper = _tryEnvAddress("VAULT_KEEPER", DEFAULT_KEEPER);
        uint256 harvestMinToken0 = _tryEnvUint(
            "HARVEST_MIN_TOKEN0",
            DEFAULT_HARVEST_MIN_TOKEN0
        );
        uint256 harvestMinToken1 = _tryEnvUint(
            "HARVEST_MIN_TOKEN1",
            DEFAULT_HARVEST_MIN_TOKEN1
        );
        uint256 harvestThreshold = _tryEnvUint(
            "HARVEST_THRESHOLD",
            DEFAULT_HARVEST_THRESHOLD
        );

        address cakeUsdFeed = _tryEnvAddress(
            "CAKE_USD_FEED",
            DEFAULT_CAKE_USD_FEED
        );
        address usdtUsdFeed = _tryEnvAddress(
            "USDT_USD_FEED",
            DEFAULT_USDT_USD_FEED
        );
        uint256 maxDeviationBps = _tryEnvUint(
            "MAX_DEVIATION_BPS",
            DEFAULT_MAX_DEVIATION_BPS
        );
        uint32 twapWindow = uint32(
            _tryEnvUint("TWAP_WINDOW", DEFAULT_TWAP_WINDOW)
        );
        string memory vaultName = _tryEnvString(
            "VAULT_NAME",
            DEFAULT_VAULT_NAME
        );
        string memory vaultSymbol = _tryEnvString(
            "VAULT_SYMBOL",
            DEFAULT_VAULT_SYMBOL
        );

        console.log("== Pancake V3 Vault Deployment ==");
        console.log("Position Manager:", positionManagerAddr);
        console.log("Pool:", poolAddr);
        console.log("MasterChef:", masterChefAddr);
        console.log("Router Adapter:", routerAdapterAddr);
        console.log("Reward Token:", rewardTokenAddr);
        console.log("Token0/token1:", token0Addr, token1Addr);
        console.log("Fee tier:", fee);
        console.log("Tick Lower:", int256(tickLower));
        console.log("Tick Upper:", int256(tickUpper));
        console.log("Master PID:", masterPid);
        console.log("Stake with MasterChef:", stakeWithMasterChef);
        console.log("Vault Name:", vaultName);
        console.log("Vault Symbol:", vaultSymbol);

        vm.startBroadcast(deployerKey);

        V3LPVault4626 vault = new V3LPVault4626(
            IERC20Metadata(token0Addr),
            IERC20Metadata(token1Addr),
            vaultName,
            vaultSymbol,
            vm.addr(deployerKey),
            V3LPVault4626.VaultConfig({
                positionManager: INonfungiblePositionManager(
                    positionManagerAddr
                ),
                masterChef: IPancakeV3MasterChef(masterChefAddr),
                pool: poolAddr,
                fee: fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                masterChefPid: masterPid,
                stakeWithMasterChef: stakeWithMasterChef,
                routerAdapter: routerAdapterAddr,
                rewardToken: IERC20(rewardTokenAddr)
            })
        );
        console.log("Vault deployed at:", address(vault));

        if (keeper != address(0)) {
            vault.setKeeper(keeper);
            console.log("Keeper set to:", keeper);
        }

        vault.configureHarvest(
            harvestMinToken0,
            harvestMinToken1,
            harvestThreshold
        );
        console.log("Harvest config -> minToken0:", harvestMinToken0);
        console.log("  minToken1:", harvestMinToken1);
        console.log("  threshold:", harvestThreshold);

        V3LPVaultOracle oracle = new V3LPVaultOracle(vm.addr(deployerKey));
        console.log("Oracle deployed at:", address(oracle));

        // Register vault (mode 0 = use pool TWAP for pricing)
        oracle.registerVault(
            IV3LPVault4626(address(vault)),
            token0Addr,
            token1Addr,
            0
        );
        oracle.setShareDeviationBps(address(vault), maxDeviationBps);
        oracle.setTwapWindow(address(vault), twapWindow);

        // Set price feeds if provided (optional for TWAP-based pricing)
        if (cakeUsdFeed != address(0)) {
            oracle.setAssetFeed(token0Addr, cakeUsdFeed);
            console.log("Token0 feed set:", cakeUsdFeed);
        }
        if (usdtUsdFeed != address(0)) {
            oracle.setAssetFeed(token1Addr, usdtUsdFeed);
            console.log("Token1 feed set:", usdtUsdFeed);
        }

        console.log("Oracle configured with TWAP/deviation guards");

        vm.stopBroadcast();

        console.log("== Deployment complete ==");
        console.log("Vault:", address(vault));
        console.log("Oracle:", address(oracle));
    }

    // ===== Helpers =====
    function _tryEnvAddress(
        string memory key,
        address fallbackAddr
    ) internal view returns (address) {
        try vm.envAddress(key) returns (address v) {
            return v;
        } catch {
            return fallbackAddr;
        }
    }

    function _requireEnvAddress(
        string memory key,
        address fallbackAddr
    ) internal view returns (address) {
        address addr = _tryEnvAddress(key, fallbackAddr);
        require(addr != address(0), string.concat("missing env ", key));
        return addr;
    }

    function _tryEnvUint(
        string memory key,
        uint256 fallbackVal
    ) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 v) {
            return v;
        } catch {
            return fallbackVal;
        }
    }

    function _tryEnvBool(
        string memory key,
        bool fallbackVal
    ) internal view returns (bool) {
        try vm.envBool(key) returns (bool v) {
            return v;
        } catch {
            return fallbackVal;
        }
    }

    function _tryEnvString(
        string memory key,
        string memory fallbackVal
    ) internal view returns (string memory) {
        try vm.envString(key) returns (string memory v) {
            return v;
        } catch {
            return fallbackVal;
        }
    }
}

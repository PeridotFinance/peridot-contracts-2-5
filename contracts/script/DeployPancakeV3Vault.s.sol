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
    // ===== Default configuration (override via env vars) =====
    address public constant DEFAULT_POSITION_MANAGER = address(0); // e.g., 0x878d... on BNB
    address public constant DEFAULT_POOL = address(0); // Pancake v3 pool address
    address public constant DEFAULT_MASTER_CHEF = address(0); // 0x556B... on BNB
    uint24 public constant DEFAULT_FEE = 500; // 0.05%
    int24 public constant DEFAULT_TICK_LOWER = -887220; // full range placeholder
    int24 public constant DEFAULT_TICK_UPPER = 887220;
    uint256 public constant DEFAULT_MASTER_PID = 0;
    address public constant DEFAULT_ROUTER_ADAPTER = address(0);
    address public constant DEFAULT_REWARD_TOKEN = address(0); // CAKE
    address public constant DEFAULT_TOKEN0 = address(0); // e.g., CAKE or base token
    address public constant DEFAULT_TOKEN1 = address(0); // e.g., USDT
    address public constant DEFAULT_KEEPER = address(0);
    uint256 public constant DEFAULT_HARVEST_MIN_TOKEN0 = 0;
    uint256 public constant DEFAULT_HARVEST_MIN_TOKEN1 = 0;
    uint256 public constant DEFAULT_HARVEST_THRESHOLD = 0;
    address public constant DEFAULT_CAKE_USD_FEED = 0xB6064eD41d4f67e353768aA239cA86f4F73665a1;
    address public constant DEFAULT_USDT_USD_FEED = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;
    uint256 public constant DEFAULT_MAX_DEVIATION_BPS = 500; // 5%
    uint32 public constant DEFAULT_TWAP_WINDOW = 300; // 5 minutes

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        address positionManagerAddr = _requireEnvAddress("POSITION_MANAGER", DEFAULT_POSITION_MANAGER);
        address poolAddr = _requireEnvAddress("PANCake_POOL", DEFAULT_POOL);
        address masterChefAddr = _requireEnvAddress("MASTER_CHEF", DEFAULT_MASTER_CHEF);
        address routerAdapterAddr = _requireEnvAddress("ROUTER_ADAPTER", DEFAULT_ROUTER_ADAPTER);
        address rewardTokenAddr = _requireEnvAddress("REWARD_TOKEN", DEFAULT_REWARD_TOKEN);
        address token0Addr = _requireEnvAddress("TOKEN0", DEFAULT_TOKEN0);
        address token1Addr = _requireEnvAddress("TOKEN1", DEFAULT_TOKEN1);

        uint24 fee = uint24(_tryEnvUint("FEE_TIER", DEFAULT_FEE));
        int24 tickLower = int24(int256(_tryEnvUint("TICK_LOWER", uint256(int256(DEFAULT_TICK_LOWER)))));
        int24 tickUpper = int24(int256(_tryEnvUint("TICK_UPPER", uint256(int256(DEFAULT_TICK_UPPER)))));
        uint256 masterPid = _tryEnvUint("MASTER_PID", DEFAULT_MASTER_PID);
        bool stakeWithMasterChef = _tryEnvBool("STAKE_WITH_MASTER_CHEF", masterChefAddr != address(0));

        address keeper = _tryEnvAddress("VAULT_KEEPER", DEFAULT_KEEPER);
        uint256 harvestMinToken0 = _tryEnvUint("HARVEST_MIN_TOKEN0", DEFAULT_HARVEST_MIN_TOKEN0);
        uint256 harvestMinToken1 = _tryEnvUint("HARVEST_MIN_TOKEN1", DEFAULT_HARVEST_MIN_TOKEN1);
        uint256 harvestThreshold = _tryEnvUint("HARVEST_THRESHOLD", DEFAULT_HARVEST_THRESHOLD);

        address cakeUsdFeed = _tryEnvAddress("CAKE_USD_FEED", DEFAULT_CAKE_USD_FEED);
        address usdtUsdFeed = _tryEnvAddress("USDT_USD_FEED", DEFAULT_USDT_USD_FEED);
        uint256 maxDeviationBps = _tryEnvUint("MAX_DEVIATION_BPS", DEFAULT_MAX_DEVIATION_BPS);
        uint32 twapWindow = uint32(_tryEnvUint("TWAP_WINDOW", DEFAULT_TWAP_WINDOW));

        console.log("== Pancake V3 Vault Deployment ==");
        console.log("Position Manager:", positionManagerAddr);
        console.log("Pool:", poolAddr);
        console.log("MasterChef:", masterChefAddr);
        console.log("Router Adapter:", routerAdapterAddr);
        console.log("Reward Token:", rewardTokenAddr);
        console.log("Token0/token1:", token0Addr, token1Addr);
        console.log("Fee tier:", fee);
        console.log("Ticks:", tickLower, tickUpper);
        console.log("Master PID:", masterPid);
        console.log("Stake with MasterChef:", stakeWithMasterChef);

        vm.startBroadcast(deployerKey);

        V3LPVault4626 vault = new V3LPVault4626(
            IERC20Metadata(token0Addr),
            IERC20Metadata(token1Addr),
            "Peridot Pancake V3 Vault",
            "pV3",
            vm.addr(deployerKey),
            V3LPVault4626.VaultConfig({
                positionManager: INonfungiblePositionManager(positionManagerAddr),
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

        vault.configureHarvest(harvestMinToken0, harvestMinToken1, harvestThreshold);
        console.log(
            "Harvest config -> minToken0:",
            harvestMinToken0,
            " minToken1:",
            harvestMinToken1,
            " threshold:",
            harvestThreshold
        );

        V3LPVaultOracle oracle = new V3LPVaultOracle(vm.addr(deployerKey));
        console.log("Oracle deployed at:", address(oracle));

        oracle.registerVault(IV3LPVault4626(address(vault)), token0Addr, token1Addr, 0);
        oracle.setAssetFeed(token0Addr, cakeUsdFeed);
        oracle.setAssetFeed(token1Addr, usdtUsdFeed);
        oracle.setShareDeviationBps(address(vault), maxDeviationBps);
        oracle.setTwapWindow(address(vault), twapWindow);

        console.log("Oracle configured: feeds set and TWAP/deviation guards applied");

        vm.stopBroadcast();

        console.log("== Deployment complete ==");
        console.log("Vault:", address(vault));
        console.log("Oracle:", address(oracle));
    }

    // ===== Helpers =====
    function _tryEnvAddress(string memory key, address fallbackAddr) internal view returns (address) {
        try vm.envAddress(key) returns (address v) {
            return v;
        } catch {
            return fallbackAddr;
        }
    }

    function _requireEnvAddress(string memory key, address fallbackAddr) internal view returns (address) {
        address addr = _tryEnvAddress(key, fallbackAddr);
        require(addr != address(0), string.concat("missing env ", key));
        return addr;
    }

    function _tryEnvUint(string memory key, uint256 fallbackVal) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 v) {
            return v;
        } catch {
            return fallbackVal;
        }
    }

    function _tryEnvBool(string memory key, bool fallbackVal) internal view returns (bool) {
        try vm.envBool(key) returns (bool v) {
            return v;
        } catch {
            return fallbackVal;
        }
    }
}

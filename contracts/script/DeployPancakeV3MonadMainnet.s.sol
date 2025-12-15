// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import "../contracts/pancakev3/V3LPVault4626.sol";
import "../contracts/pancakev3/V3LPVaultOracle.sol";
import "../contracts/pancakev3/interfaces/INonfungiblePositionManager.sol";
import "../contracts/pancakev3/interfaces/IPancakeV3MasterChef.sol";
import "../contracts/pancakev3/interfaces/IV3LPVault4626.sol";
import "../contracts/boosted/PancakeBoostedPErc20.sol";
import "../contracts/PeridottrollerInterface.sol";
import "../contracts/InterestRateModel.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title DeployPancakeV3MonadMainnet
 * @notice Deploys the complete PancakeBoosted system on Monad Mainnet:
 *         1. V3LPVault4626 - The LP vault for AUSD/USDC
 *         2. V3LPVaultOracle - Oracle for pricing vault shares
 *         3. Seeds the vault (sends shares to dead address)
 *         4. PancakeBoostedPErc20 - The pToken wrapping vault shares
 *
 * @dev Run with:
 *      forge script script/DeployPancakeV3MonadMainnet.s.sol \
 *        --rpc-url "https://rpc-mainnet.monadinfra.com/rpc/gj5S68FEcV5YJhoHerGE51VLJ0gh7kQA" \
 *        --broadcast
 */
contract DeployPancakeV3MonadMainnet is Script {
    // ============ MONAD MAINNET ADDRESSES ============

    // PancakeSwap V3 Infrastructure
    address constant POSITION_MANAGER =
        0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address constant SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address constant SMART_ROUTER = 0x21114915Ac6d5A2e156931e20B20b038dEd0Be7C;
    address constant QUOTER_V2 = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;

    // AUSD/USDC Pool (0.01% fee)
    address constant POOL = 0xE84765B4e2634f3bD8a91c89e432F6B81f0647Bc;
    uint24 constant FEE = 100; // 0.01%
    int24 constant TICK_SPACING = 1;

    // Tokens (ordered by address for pool)
    address constant TOKEN0_AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a; // 6 decimals
    address constant TOKEN1_USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603; // 6 decimals

    // Peridot Protocol
    address constant PERIDOTTROLLER =
        0x6D208789f0a978aF789A3C8Ba515749598940716;
    address constant JUMP_RATE_MODEL_BOOSTED =
        0x5710017eCdF44f39b5Ae885965140726B7d81099;

    // No MasterChef or CAKE rewards on Monad
    address constant MASTER_CHEF = address(0);
    address constant REWARD_TOKEN = address(0);
    address constant ROUTER_ADAPTER = address(0); // Not needed without rewards

    // Stablecoin-optimized tick range (tick spacing = 1)
    // Tick 0 = 1:1 price, range covers ~10% depeg in either direction
    // This is much more capital efficient than full range for stablecoins
    int24 constant TICK_LOWER = -1000; // ~0.9048 price ratio
    int24 constant TICK_UPPER = 1000; // ~1.1052 price ratio

    // Inflation protection
    address constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 constant SEED_AMOUNT_TOKEN0 = 1e6; // 1 AUSD (6 decimals)
    uint256 constant SEED_AMOUNT_TOKEN1 = 1e6; // 1 USDC (6 decimals)
    uint256 constant MIN_VAULT_SEED = 1000; // Minimum shares at dead address

    // ============ DEPLOYMENT ============

    function run() external {
        // Support both --private-key flag and PRIVATE_KEY env var
        uint256 deployerKey;
        try vm.envUint("PRIVATE_KEY") returns (uint256 key) {
            deployerKey = key;
        } catch {
            revert("Set PRIVATE_KEY env var or use: export PRIVATE_KEY=<key>");
        }
        address deployer = vm.addr(deployerKey);
        address admin = _tryEnvAddress("ADMIN", deployer);

        console.log("==============================================");
        console.log("  PANCAKE V3 BOOSTED DEPLOYMENT - MONAD MAINNET");
        console.log("==============================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("Admin:", admin);
        console.log("");

        vm.startBroadcast(deployerKey);

        // Step 1: Deploy V3LPVault4626
        console.log("Step 1: Deploying V3LPVault4626...");
        V3LPVault4626 vault = _deployVault(deployer);
        console.log("  Vault deployed at:", address(vault));

        // Step 2: Deploy Oracle
        console.log("");
        console.log("Step 2: Deploying V3LPVaultOracle...");
        V3LPVaultOracle oracle = _deployOracle(deployer, vault);
        console.log("  Oracle deployed at:", address(oracle));

        // Step 3: Seed the vault
        console.log("");
        console.log("Step 3: Seeding vault for inflation protection...");
        uint256 sharesMinted = _seedVault(vault, deployer);
        console.log("  Shares minted:", sharesMinted);

        // Step 4: Send seed to dead address
        console.log("");
        console.log("Step 4: Sending seed shares to dead address...");
        uint256 seedAmount = sharesMinted > MIN_VAULT_SEED
            ? MIN_VAULT_SEED
            : sharesMinted;
        IERC20(address(vault)).transfer(DEAD_ADDRESS, seedAmount);
        console.log("  Sent to dead address:", seedAmount);

        // Step 5: Deploy PancakeBoostedPErc20
        console.log("");
        console.log("Step 5: Deploying PancakeBoostedPErc20...");
        PancakeBoostedPErc20 pToken = _deployPToken(vault, admin);
        console.log("  pToken deployed at:", address(pToken));

        vm.stopBroadcast();

        // Summary
        console.log("");
        console.log("==============================================");
        console.log("  DEPLOYMENT COMPLETE");
        console.log("==============================================");
        console.log("");
        console.log("V3LPVault4626:", address(vault));
        console.log("V3LPVaultOracle:", address(oracle));
        console.log("PancakeBoostedPErc20:", address(pToken));
        console.log("");
        console.log("Next steps:");
        console.log("1. Verify contracts on explorer");
        console.log("2. Support market in Peridottroller:");
        console.log("   cast send", PERIDOTTROLLER);
        console.log("   '_supportMarket(address)'", address(pToken));
        console.log("3. Set collateral factor if needed");
        console.log("4. Set borrow cap if needed (recommended for LP tokens)");
    }

    function _deployVault(address owner) internal returns (V3LPVault4626) {
        return
            new V3LPVault4626(
                IERC20Metadata(TOKEN0_AUSD),
                IERC20Metadata(TOKEN1_USDC),
                "Peridot AUSD/USDC V3 LP Vault",
                "pV3-AUSD-USDC",
                owner,
                V3LPVault4626.VaultConfig({
                    positionManager: INonfungiblePositionManager(
                        POSITION_MANAGER
                    ),
                    masterChef: IPancakeV3MasterChef(MASTER_CHEF),
                    pool: POOL,
                    fee: FEE,
                    tickLower: TICK_LOWER,
                    tickUpper: TICK_UPPER,
                    masterChefPid: 0,
                    stakeWithMasterChef: false,
                    routerAdapter: ROUTER_ADAPTER,
                    rewardToken: IERC20(REWARD_TOKEN)
                })
            );
    }

    function _deployOracle(
        address owner,
        V3LPVault4626 vault
    ) internal returns (V3LPVaultOracle) {
        V3LPVaultOracle oracle = new V3LPVaultOracle(owner);

        // Register vault (mode 0 = use pool TWAP)
        oracle.registerVault(
            IV3LPVault4626(address(vault)),
            TOKEN0_AUSD,
            TOKEN1_USDC,
            0
        );

        // Set deviation and TWAP guards
        oracle.setShareDeviationBps(address(vault), 500); // 5%
        oracle.setTwapWindow(address(vault), 300); // 5 minutes

        return oracle;
    }

    function _seedVault(
        V3LPVault4626 vault,
        address receiver
    ) internal returns (uint256 shares) {
        // Check balances
        uint256 balance0 = IERC20(TOKEN0_AUSD).balanceOf(receiver);
        uint256 balance1 = IERC20(TOKEN1_USDC).balanceOf(receiver);

        require(balance0 >= SEED_AMOUNT_TOKEN0, "Insufficient AUSD for seed");
        require(balance1 >= SEED_AMOUNT_TOKEN1, "Insufficient USDC for seed");

        // Approve vault
        IERC20(TOKEN0_AUSD).approve(address(vault), SEED_AMOUNT_TOKEN0);
        IERC20(TOKEN1_USDC).approve(address(vault), SEED_AMOUNT_TOKEN1);

        // Deposit to get shares
        shares = vault.depositDual(
            V3LPVault4626.DepositParams({
                receiver: receiver,
                refundReceiver: receiver,
                amount0Desired: SEED_AMOUNT_TOKEN0,
                amount1Desired: SEED_AMOUNT_TOKEN1,
                amount0Min: 0,
                amount1Min: 0,
                minShares: 0,
                deadline: block.timestamp + 300
            })
        );
    }

    function _deployPToken(
        V3LPVault4626 vault,
        address admin
    ) internal returns (PancakeBoostedPErc20) {
        uint8 decimals = vault.decimals();
        uint256 initialExchangeRate = decimals == 6 ? 2e14 : 2e26;

        return
            new PancakeBoostedPErc20(
                address(vault), // underlying = vault share token
                PeridottrollerInterface(PERIDOTTROLLER),
                InterestRateModel(JUMP_RATE_MODEL_BOOSTED),
                initialExchangeRate,
                "Peridot AUSD/USDC LP",
                "pAUSD-USDC-LP",
                decimals,
                payable(admin),
                MIN_VAULT_SEED
            );
    }

    function _tryEnvAddress(
        string memory key,
        address fallback_
    ) internal view returns (address) {
        try vm.envAddress(key) returns (address value) {
            return value;
        } catch {
            return fallback_;
        }
    }
}

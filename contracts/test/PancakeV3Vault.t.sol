// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {V3LPVault4626, V3LPVault4626 as Vault} from "../contracts/pancakev3/V3LPVault4626.sol";
import {V3LPVaultOracle} from "../contracts/pancakev3/V3LPVaultOracle.sol";
import {IV3LPVault4626} from "../contracts/pancakev3/interfaces/IV3LPVault4626.sol";
import {INonfungiblePositionManager} from "../contracts/pancakev3/interfaces/INonfungiblePositionManager.sol";
import {PToken} from "../contracts/PToken.sol";

import {MockErc20} from "./MockErc20.sol";
import {MockPErc20} from "./MockPErc20.sol";
import {MockPancakeV3PositionManager} from "./mocks/MockPancakeV3PositionManager.sol";
import {MockPancakeV3MasterChef} from "./mocks/MockPancakeV3MasterChef.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockPancakeV3Pool} from "./mocks/MockPancakeV3Pool.sol";
import {MockRouterAdapter} from "./mocks/MockRouterAdapter.sol";
import {TickMath} from "../contracts/pancakev3/libraries/TickMath.sol";

contract PancakeV3VaultTest is Test {
    MockErc20 internal token0;
    MockErc20 internal token1;
    MockPancakeV3PositionManager internal positionManager;
    MockPancakeV3MasterChef internal masterChef;
    MockRouterAdapter internal routerAdapter;
    MockErc20 internal reward;
    V3LPVault4626 internal vault;
    MockPancakeV3Pool internal pool;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        token0 = new MockErc20("Token0", "TK0", 18);
        token1 = new MockErc20("Token1", "TK1", 18);
        reward = new MockErc20("CAKE", "CAKE", 18);
        positionManager = new MockPancakeV3PositionManager();
        masterChef = new MockPancakeV3MasterChef();
        routerAdapter = new MockRouterAdapter();
        pool = new MockPancakeV3Pool(TickMath.getSqrtRatioAtTick(0), 0, 50);

        masterChef.setRewardToken(address(reward));
        token0.mint(address(routerAdapter), 10_000e18);
        token1.mint(address(routerAdapter), 10_000e18);

        Vault.VaultConfig memory cfg = Vault.VaultConfig({
            positionManager: INonfungiblePositionManager(
                address(positionManager)
            ),
            masterChef: masterChef,
            pool: address(pool),
            fee: 500,
            tickLower: -600,
            tickUpper: 600,
            masterChefPid: 1,
            stakeWithMasterChef: true,
            routerAdapter: address(routerAdapter),
            rewardToken: IERC20(address(reward))
        });

        positionManager.configurePool(
            address(token0),
            address(token1),
            cfg.fee,
            address(pool)
        );

        vault = new V3LPVault4626(
            IERC20Metadata(address(token0)),
            IERC20Metadata(address(token1)),
            "Peridot Pancake Vault",
            "pVLT",
            address(this),
            cfg
        );

        token0.mint(alice, 1_000e18);
        token1.mint(alice, 1_000e18);
        token0.mint(bob, 1_000e18);
        token1.mint(bob, 1_000e18);
    }

    function _defaultDepositParams(
        address receiver,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (Vault.DepositParams memory) {
        return
            Vault.DepositParams({
                receiver: receiver,
                refundReceiver: receiver,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                minShares: 1,
                deadline: block.timestamp + 1
            });
    }

    function _defaultWithdrawParams(
        address receiver,
        address owner,
        uint256 shares
    ) internal view returns (Vault.WithdrawParams memory) {
        return
            Vault.WithdrawParams({
                receiver: receiver,
                owner: owner,
                shares: shares,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1
            });
    }

    function testInitialMintAndShareAccounting() public {
        vm.startPrank(alice);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);

        uint256 expectedShares = vault.previewDepositDual(1e18, 1e18);
        uint256 shares = vault.depositDual(
            _defaultDepositParams(alice, 1e18, 1e18)
        );
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), shares, "shares credited");
        assertApproxEqAbs(shares, expectedShares, 1, "matching preview");
        assertApproxEqAbs(
            vault.totalManagedToken0(),
            1e18,
            1,
            "managed token0"
        );
        assertApproxEqAbs(
            vault.totalManagedToken1(),
            1e18,
            1,
            "managed token1"
        );
        assertTrue(vault.positionTokenId() != 0, "position minted");
        assertApproxEqAbs(
            uint256(vault.totalLiquidity()),
            expectedShares,
            1,
            "liquidity tracked"
        );
    }

    function testSubsequentDepositMintsProportionalShares() public {
        vm.startPrank(alice);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        vault.depositDual(_defaultDepositParams(alice, 1e18, 1e18));
        vm.stopPrank();

        vm.startPrank(bob);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        uint256 expectedShares = vault.previewDepositDual(0.5e18, 0.5e18);
        uint256 bobShares = vault.depositDual(
            _defaultDepositParams(bob, 0.5e18, 0.5e18)
        );
        vm.stopPrank();

        assertApproxEqAbs(bobShares, expectedShares, 1, "proportional shares");
        assertApproxEqAbs(
            vault.totalManagedToken0(),
            1.5e18,
            2,
            "token0 updated"
        );
        assertApproxEqAbs(
            vault.totalManagedToken1(),
            1.5e18,
            2,
            "token1 updated"
        );
    }

    function testWithdrawReturnsProportionalTokens() public {
        vm.startPrank(alice);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        uint256 shares = vault.depositDual(
            _defaultDepositParams(alice, 1e18, 1e18)
        );

        Vault.WithdrawParams memory params = _defaultWithdrawParams(
            alice,
            alice,
            shares / 2
        );
        (uint256 amount0, uint256 amount1) = vault.withdrawDual(params);
        vm.stopPrank();

        assertApproxEqAbs(amount0, 0.5e18, 1e6, "half token0 returned");
        assertApproxEqAbs(amount1, 0.5e18, 1e6, "half token1 returned");
        assertApproxEqAbs(
            vault.balanceOf(alice),
            shares / 2,
            1,
            "remaining shares"
        );
    }

    function testHarvestCompoundsRewards() public {
        vm.startPrank(alice);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        vault.depositDual(_defaultDepositParams(alice, 1e18, 1e18));
        vm.stopPrank();

        uint128 liquidityBefore = vault.totalLiquidity();

        reward.mint(address(masterChef), 1e18);
        masterChef.setRewardAmount(1e18);
        vault.configureHarvest(0, 0, 0);

        V3LPVault4626.HarvestParams memory params = V3LPVault4626
            .HarvestParams({
                rewardForToken0: 5e17,
                rewardForToken1: 5e17,
                minToken0Out: 0,
                minToken1Out: 0,
                swapDataToken0: "",
                swapDataToken1: ""
            });

        vault.harvestAndCompound(params);

        assertGt(
            vault.totalLiquidity(),
            liquidityBefore,
            "liquidity increased"
        );
        assertEq(vault.lastHarvest(), block.timestamp, "lastHarvest updated");
    }

    // ========== SINGLE-ASSET ERC4626 OVERRIDE TESTS ==========

    function testSingleAssetDepositReverts() public {
        token0.mint(alice, 1e18);

        vm.startPrank(alice);
        token0.approve(address(vault), 1e18);

        vm.expectRevert(V3LPVault4626.SingleAssetNotSupported.selector);
        vault.deposit(1e18, alice);
        vm.stopPrank();
    }

    function testSingleAssetMintReverts() public {
        token0.mint(alice, 1e18);

        vm.startPrank(alice);
        token0.approve(address(vault), 1e18);

        vm.expectRevert(V3LPVault4626.SingleAssetNotSupported.selector);
        vault.mint(1e18, alice);
        vm.stopPrank();
    }

    function testSingleAssetWithdrawReverts() public {
        // First deposit via dual
        vm.startPrank(alice);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        vault.depositDual(_defaultDepositParams(alice, 1e18, 1e18));

        vm.expectRevert(V3LPVault4626.SingleAssetNotSupported.selector);
        vault.withdraw(1e18, alice, alice);
        vm.stopPrank();
    }

    function testSingleAssetRedeemReverts() public {
        // First deposit via dual
        vm.startPrank(alice);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        uint256 shares = vault.depositDual(
            _defaultDepositParams(alice, 1e18, 1e18)
        );

        vm.expectRevert(V3LPVault4626.SingleAssetNotSupported.selector);
        vault.redeem(shares, alice, alice);
        vm.stopPrank();
    }

    function testMaxDepositReturnsZero() public view {
        assertEq(vault.maxDeposit(alice), 0, "maxDeposit should be 0");
    }

    function testMaxMintReturnsZero() public view {
        assertEq(vault.maxMint(alice), 0, "maxMint should be 0");
    }

    function testMaxWithdrawReturnsToken0Value() public {
        vm.startPrank(alice);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        vault.depositDual(_defaultDepositParams(alice, 1e18, 1e18));
        vm.stopPrank();

        uint256 maxWithdraw = vault.maxWithdraw(alice);
        (uint256 amount0, ) = vault.previewWithdrawDual(vault.balanceOf(alice));
        assertEq(
            maxWithdraw,
            amount0,
            "maxWithdraw should equal token0 portion"
        );
    }

    function testMaxRedeemReturnsShareBalance() public {
        vm.startPrank(alice);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        uint256 shares = vault.depositDual(
            _defaultDepositParams(alice, 1e18, 1e18)
        );
        vm.stopPrank();

        assertEq(
            vault.maxRedeem(alice),
            shares,
            "maxRedeem should equal share balance"
        );
    }

    function testPreviewDepositReturnsZero() public view {
        assertEq(vault.previewDeposit(1e18), 0, "previewDeposit should be 0");
    }

    function testPreviewMintReturnsZero() public view {
        assertEq(vault.previewMint(1e18), 0, "previewMint should be 0");
    }
}

contract PancakeV3VaultOracleTest is Test {
    MockErc20 internal token0;
    MockErc20 internal token1;
    MockPancakeV3PositionManager internal positionManager;
    V3LPVault4626 internal vault;
    V3LPVaultOracle internal oracle;
    MockPErc20 internal pToken;
    MockAggregator internal cakeUsdFeed;
    MockAggregator internal usdtUsdFeed;
    MockPancakeV3Pool internal pool;
    MockRouterAdapter internal routerAdapter;
    MockErc20 internal reward;

    address internal admin = address(this);
    address internal user = address(0xDEAD);

    function setUp() public {
        token0 = new MockErc20("Token0", "TK0", 18);
        token1 = new MockErc20("Token1", "TK1", 18);
        reward = new MockErc20("CAKE", "CAKE", 18);
        positionManager = new MockPancakeV3PositionManager();
        pool = new MockPancakeV3Pool(TickMath.getSqrtRatioAtTick(0), 0, 50);
        routerAdapter = new MockRouterAdapter();
        token0.mint(address(routerAdapter), 10_000e18);
        token1.mint(address(routerAdapter), 10_000e18);

        Vault.VaultConfig memory cfg = Vault.VaultConfig({
            positionManager: INonfungiblePositionManager(
                address(positionManager)
            ),
            masterChef: MockPancakeV3MasterChef(address(0)),
            pool: address(pool),
            fee: 500,
            tickLower: -600,
            tickUpper: 600,
            masterChefPid: 0,
            stakeWithMasterChef: false,
            routerAdapter: address(routerAdapter),
            rewardToken: IERC20(address(reward))
        });

        positionManager.configurePool(
            address(token0),
            address(token1),
            cfg.fee,
            address(pool)
        );

        vault = new V3LPVault4626(
            IERC20Metadata(address(token0)),
            IERC20Metadata(address(token1)),
            "Peridot Pancake Vault",
            "pVLT",
            admin,
            cfg
        );

        oracle = new V3LPVaultOracle(admin);
        oracle.registerVault(
            IV3LPVault4626(address(vault)),
            address(token0),
            address(token1),
            1e18
        );
        cakeUsdFeed = new MockAggregator(18, 1e18);
        usdtUsdFeed = new MockAggregator(18, 1e18);
        oracle.setAssetFeed(address(token0), address(cakeUsdFeed));
        oracle.setAssetFeed(address(token1), address(usdtUsdFeed));
        oracle.setShareDeviationBps(address(vault), 10_000);
        oracle.setShareDeviationBps(address(vault), 10_000);

        pToken = new MockPErc20(address(vault), "pShare");

        token0.mint(user, 2e18);
        token1.mint(user, 2e18);
    }

    function testOracleReportsSharePrice() public {
        vm.startPrank(user);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        vault.depositDual(
            Vault.DepositParams({
                receiver: user,
                refundReceiver: user,
                amount0Desired: 2e18,
                amount1Desired: 2e18,
                amount0Min: 0,
                amount1Min: 0,
                minShares: 1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        uint256 price = oracle.getUnderlyingPrice(PToken(address(pToken)));
        assertGt(price, 0, "oracle price set");

        cakeUsdFeed.updateAnswer(2e18);
        uint256 increasedPrice = oracle.getUnderlyingPrice(
            PToken(address(pToken))
        );
        assertGt(increasedPrice, price, "price responds to feed updates");
    }

    function testOracleRejectsLargeDeviation() public {
        vm.startPrank(user);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        vault.depositDual(
            Vault.DepositParams({
                receiver: user,
                refundReceiver: user,
                amount0Desired: 2e18,
                amount1Desired: 2e18,
                amount0Min: 0,
                amount1Min: 0,
                minShares: 1,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        oracle.setShareDeviationBps(address(vault), 200); // 2%
        cakeUsdFeed.updateAnswer(5e18);
        vm.expectRevert("price deviation");
        oracle.getUnderlyingPrice(PToken(address(pToken)));
    }

    function testOracleFallsBackWithoutSupply() public {
        uint256 price = oracle.getUnderlyingPrice(PToken(address(pToken)));
        assertEq(price, 1e18, "fallback price");
    }
}

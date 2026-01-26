// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/boosted/MorphoBoostedPErc20.sol";
import "./MockErc20.sol";
import "./MockInterestRateModel.sol";
import "./MockPeridottroller.sol";
import "./mocks/MockERC4626Vault.sol";
import "../contracts/Peridottroller.sol";
import "../contracts/PToken.sol";

contract MorphoBoostedPErc20Test is Test {
    MockErc20 internal underlying;
    MockERC4626Vault internal vault;
    MockPeridottroller internal comptroller;
    MockInterestRateModel internal irm;
    MorphoBoostedPErc20 internal pToken;

    address internal alice = address(0xa11ce);
    address internal bob = address(0xb0b);

    uint256 internal constant INITIAL_EXCHANGE_RATE = 1e18;
    uint256 internal constant BUFFER = 1e17; // 10%

    function setUp() public {
        underlying = new MockErc20("Mock USD", "mUSD", 18);
        vault = new MockERC4626Vault(IERC20Metadata(address(underlying)));
        comptroller = new MockPeridottroller();
        irm = new MockInterestRateModel();

        pToken = new MorphoBoostedPErc20(
            address(underlying),
            comptroller,
            irm,
            INITIAL_EXCHANGE_RATE,
            "Peridot Morpho mUSD",
            "pmUSD",
            18,
            payable(address(this)),
            IERC4626(address(vault)),
            BUFFER,
            0
        );

        // List market in mock comptroller
        comptroller.setMarket(address(pToken), true, 0.75e18);

        // Seed users
        underlying.mint(alice, 1_000e18);
        underlying.mint(bob, 1_000e18);
    }

    function testMintDepositsIntoVaultRespectingBuffer() public {
        vm.startPrank(alice);
        underlying.approve(address(pToken), 100e18);
        pToken.mint(100e18);
        vm.stopPrank();

        uint256 vaultAssets = vault.totalAssets();
        uint256 localCash = underlying.balanceOf(address(pToken));

        // 10% buffer stays locally, rest deposited
        assertApproxEqAbs(vaultAssets, 90e18, 1);
        assertApproxEqAbs(localCash, 10e18, 1);

        // Alice receives pTokens 1:1 at initial rate
        assertEq(pToken.balanceOf(alice), 100e18);
    }

    function testBorrowPullsFromVaultAndKeepsBuffer() public {
        // Alice supplies
        vm.startPrank(alice);
        underlying.approve(address(pToken), 100e18);
        pToken.mint(100e18);
        vm.stopPrank();

        // Bob borrows
        vm.startPrank(bob);
        underlying.approve(address(pToken), 50e18);
        pToken.borrow(50e18);
        vm.stopPrank();

        // Vault should supply most liquidity; buffer recalculates on new total
        uint256 vaultAssets = vault.totalAssets();
        uint256 localCash = underlying.balanceOf(address(pToken));
        // Total assets after lending out 50: vault + cash should be ~50
        assertApproxEqAbs(vaultAssets + localCash, 50e18, 1);
        // Buffer is 10% of remaining assets (~5)
        assertApproxEqAbs(localCash, 5e18, 1);

        assertEq(underlying.balanceOf(bob), 1_050e18); // received borrow
    }

    function testRedeemWithdrawsFromVault() public {
        vm.startPrank(alice);
        underlying.approve(address(pToken), 80e18);
        pToken.mint(80e18);
        pToken.redeem(40e18);
        vm.stopPrank();

        uint256 vaultAssets = vault.totalAssets();
        uint256 localCash = underlying.balanceOf(address(pToken));

        // Remaining assets ~40; buffer ~4, vault holds the rest
        assertApproxEqAbs(vaultAssets + localCash, 40e18, 1);
        assertApproxEqAbs(localCash, 4e18, 1);

        assertEq(underlying.balanceOf(alice), 960e18); // 1000 start - 80 + 40 redeemed
    }

    function testDepositToVaultFailureDoesNotRevert() public {
        FailingDepositVault failingVault = new FailingDepositVault(IERC20Metadata(address(underlying)));
        MorphoBoostedPErc20 failingToken = new MorphoBoostedPErc20(
            address(underlying),
            comptroller,
            irm,
            INITIAL_EXCHANGE_RATE,
            "Peridot Morpho mUSD",
            "pmUSD",
            18,
            payable(address(this)),
            IERC4626(address(failingVault)),
            BUFFER,
            0
        );
        comptroller.setMarket(address(failingToken), true, 0.75e18);

        underlying.mint(alice, 100e18);
        vm.startPrank(alice);
        underlying.approve(address(failingToken), 100e18);
        failingToken.mint(100e18);
        vm.stopPrank();

        assertEq(failingVault.totalAssets(), 0, "vault should not receive assets");
        assertEq(underlying.balanceOf(address(failingToken)), 100e18, "funds remain local");
    }

    function testWithdrawFromVaultFailureDoesNotRevert() public {
        FailingWithdrawVault failingVault = new FailingWithdrawVault(IERC20Metadata(address(underlying)));
        MorphoBoostedPErc20 failingToken = new MorphoBoostedPErc20(
            address(underlying),
            comptroller,
            irm,
            INITIAL_EXCHANGE_RATE,
            "Peridot Morpho mUSD",
            "pmUSD",
            18,
            payable(address(this)),
            IERC4626(address(failingVault)),
            BUFFER,
            0
        );
        comptroller.setMarket(address(failingToken), true, 0.75e18);

        underlying.mint(address(this), 100e18);
        underlying.approve(address(failingToken), 100e18);
        failingToken.mint(100e18);

        failingVault.setMaxWithdrawLimit(100e18);
        bytes32 pauseAction = failingToken.queueSetVaultPaused(true);
        vm.warp(block.timestamp + failingToken.actionDelay());
        failingToken.setVaultPaused(true);

        bytes32 bufferAction = failingToken.queueSetVaultBufferMantissa(1e18);
        vm.warp(block.timestamp + failingToken.actionDelay());
        failingToken.setVaultBufferMantissa(1e18);

        // Funds should remain locally available and not revert.
        assertEq(underlying.balanceOf(address(failingToken)), 10e18);
    }
}

contract FailingDepositVault is MockERC4626Vault {
    constructor(IERC20Metadata asset_) MockERC4626Vault(asset_) {}

    function deposit(uint256, address) public pure override returns (uint256) {
        revert("deposit blocked");
    }
}

contract FailingWithdrawVault is MockERC4626Vault {
    uint256 public maxWithdrawLimit;

    constructor(IERC20Metadata asset_) MockERC4626Vault(asset_) {}

    function setMaxWithdrawLimit(uint256 newLimit) external {
        maxWithdrawLimit = newLimit;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 assets = convertToAssets(balanceOf(owner));
        if (maxWithdrawLimit == 0) {
            return 0;
        }
        return maxWithdrawLimit < assets ? maxWithdrawLimit : assets;
    }

    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert("withdraw blocked");
    }
}

contract MorphoBoostedPErc20ForkTest is Test {
    // Defaults from addresses.MD (Monad mainnet)
    address internal constant DEFAULT_COMPTROLLER = 0x6D208789f0a978aF789A3C8Ba515749598940716;
    address internal constant DEFAULT_IRM = 0x1FB287E1c4F7B4c6b511f4d190523814593Ad84e;

    function testForkDepositIntoRealMorphoVault() public {
        string memory rpc = vm.envOr("MONAD_MAINNET_RPC_URL", string(""));
        address vaultAddr = vm.envOr("MORPHO_VAULT", address(0));
        address underlyingAddr = vm.envOr("MORPHO_UNDERLYING", address(0));

        if (bytes(rpc).length == 0 || vaultAddr == address(0) || underlyingAddr == address(0)) {
            emit log("Skipping fork test: set MONAD_MAINNET_RPC_URL, MORPHO_VAULT, MORPHO_UNDERLYING");
            return;
        }

        vm.createSelectFork(rpc);

        IERC20Metadata underlying = IERC20Metadata(underlyingAddr);
        IERC4626 vault = IERC4626(vaultAddr);

        MockPeridottroller comptroller = new MockPeridottroller();
        MockInterestRateModel irm = new MockInterestRateModel();

        MorphoBoostedPErc20 pToken = new MorphoBoostedPErc20(
            underlyingAddr,
            comptroller,
            irm,
            1e18,
            "Peridot Morpho Fork",
            "pmFork",
            underlying.decimals(),
            payable(address(this)),
            vault,
            1e17, // 10% buffer
            1e9 // expected dead-address seed in Morpho vaults
        );

        comptroller.setMarket(address(pToken), true, 0.75e18);

        address user = address(this);
        uint256 mintAmount = 10_000 * (10 ** underlying.decimals());

        if (!_fundUser(address(underlying), mintAmount)) return;

        underlying.approve(address(pToken), mintAmount);
        pToken.mint(mintAmount);

        // Basic sanity: vault balance should increase and exchange rate should stay >= initial
        uint256 vaultAssets = vault.convertToAssets(vault.balanceOf(address(pToken)));
        assertGt(vaultAssets, 0);
        assertGe(pToken.exchangeRateCurrent(), 1e18);
    }

    function testForkRedeemHalf() public {
        string memory rpc = vm.envOr("MONAD_MAINNET_RPC_URL", string(""));
        address vaultAddr = vm.envOr("MORPHO_VAULT", address(0));
        address underlyingAddr = vm.envOr("MORPHO_UNDERLYING", address(0));

        if (bytes(rpc).length == 0 || vaultAddr == address(0) || underlyingAddr == address(0)) {
            emit log("Skipping fork redeem test: missing envs");
            return;
        }

        vm.createSelectFork(rpc);

        IERC20Metadata underlying = IERC20Metadata(underlyingAddr);
        IERC4626 vault = IERC4626(vaultAddr);
        MockPeridottroller comptroller = new MockPeridottroller();
        MockInterestRateModel irm = new MockInterestRateModel();

        MorphoBoostedPErc20 pToken = new MorphoBoostedPErc20(
            underlyingAddr,
            comptroller,
            irm,
            1e18,
            "Peridot Morpho Fork",
            "pmFork",
            underlying.decimals(),
            payable(address(this)),
            vault,
            1e17,
            1e9
        );
        comptroller.setMarket(address(pToken), true, 0.75e18);

        uint256 mintAmount = 5_000 * (10 ** underlying.decimals());
        if (!_fundUser(address(underlying), mintAmount)) return;

        underlying.approve(address(pToken), mintAmount);
        pToken.mint(mintAmount);

        uint256 redeemTokens = pToken.balanceOf(address(this)) / 2;
        pToken.redeem(redeemTokens);

        // After redeeming half, user recovers roughly half the underlying (buffer + vault pull)
        uint256 userBal = underlying.balanceOf(address(this));
        assertApproxEqAbs(userBal, mintAmount / 2, mintAmount / 100); // allow 1% drift from vault math
    }

    function testForkPausePullsVault() public {
        string memory rpc = vm.envOr("MONAD_MAINNET_RPC_URL", string(""));
        address vaultAddr = vm.envOr("MORPHO_VAULT", address(0));
        address underlyingAddr = vm.envOr("MORPHO_UNDERLYING", address(0));

        if (bytes(rpc).length == 0 || vaultAddr == address(0) || underlyingAddr == address(0)) {
            emit log("Skipping fork pause test: missing envs");
            return;
        }

        vm.createSelectFork(rpc);

        IERC20Metadata underlying = IERC20Metadata(underlyingAddr);
        IERC4626 vault = IERC4626(vaultAddr);
        MockPeridottroller comptroller = new MockPeridottroller();
        MockInterestRateModel irm = new MockInterestRateModel();

        MorphoBoostedPErc20 pToken = new MorphoBoostedPErc20(
            underlyingAddr,
            comptroller,
            irm,
            1e18,
            "Peridot Morpho Fork",
            "pmFork",
            underlying.decimals(),
            payable(address(this)),
            vault,
            1e17,
            1e9
        );
        comptroller.setMarket(address(pToken), true, 0.75e18);

        uint256 mintAmount = 2_000 * (10 ** underlying.decimals());
        if (!_fundUser(address(underlying), mintAmount)) return;

        underlying.approve(address(pToken), mintAmount);
        pToken.mint(mintAmount);

        // Pause should pull liquidity back on setVaultPaused(true)
        bytes32 actionId = pToken.queueSetVaultPaused(true);
        vm.warp(block.timestamp + pToken.actionDelay());
        pToken.setVaultPaused(true);

        uint256 vaultAssets = vault.convertToAssets(vault.balanceOf(address(pToken)));
        uint256 localCash = underlying.balanceOf(address(pToken));
        assertEq(vaultAssets, 0);
        assertApproxEqAbs(localCash, mintAmount, mintAmount / 100); // allow small rounding
    }

    function testForkWithProdComptroller() public {
        string memory rpc = vm.envOr("MONAD_MAINNET_RPC_URL", string(""));
        address vaultAddr = vm.envOr("MORPHO_VAULT", address(0));
        address underlyingAddr = vm.envOr("MORPHO_UNDERLYING", address(0));
        address comptrollerAddr = vm.envOr("PERIDOT_COMPTROLLER", DEFAULT_COMPTROLLER);
        address irmAddr = vm.envOr("PERIDOT_IRM", DEFAULT_IRM);

        if (bytes(rpc).length == 0 || vaultAddr == address(0) || underlyingAddr == address(0)) {
            emit log("Skipping prod comptroller test: missing envs");
            return;
        }

        vm.createSelectFork(rpc);

        IERC20Metadata underlying = IERC20Metadata(underlyingAddr);
        IERC4626 vault = IERC4626(vaultAddr);

        MorphoBoostedPErc20 pToken = new MorphoBoostedPErc20(
            underlyingAddr,
            PeridottrollerInterface(comptrollerAddr),
            InterestRateModel(irmAddr),
            1e18,
            "Peridot Morpho Prod",
            "pmProd",
            underlying.decimals(),
            payable(address(this)),
            vault,
            1e17,
            1e9
        );

        // Support market on real comptroller (impersonate admin)
        address admin = Peridottroller(payable(comptrollerAddr)).admin();
        vm.startPrank(admin);
        Peridottroller(comptrollerAddr)._supportMarket(pToken);
        Peridottroller(comptrollerAddr)._setCollateralFactor(PToken(address(pToken)), 0.75e18);
        vm.stopPrank();

        uint256 mintAmount = 1_000 * (10 ** underlying.decimals());
        if (!_fundUser(address(underlying), mintAmount)) return;

        underlying.approve(address(pToken), mintAmount);
        pToken.mint(mintAmount);

        uint256 vaultAssets = vault.convertToAssets(vault.balanceOf(address(pToken)));
        assertGt(vaultAssets, 0);
        assertEq(pToken.balanceOf(address(this)), mintAmount); // initial exchange rate 1e18
    }

    /// Attempt to fund the test address with `amount` underlying.
    /// Tries `deal`, then optional whale transfer (env AUSD_WHALE), otherwise skips.
    function _fundUser(address token, uint256 amount) internal returns (bool) {
        (bool okDeal,) = address(this).call(abi.encodeWithSelector(this._deal.selector, token, address(this), amount));
        if (okDeal) return true;
        address whale = vm.envOr("AUSD_WHALE", address(0));
        if (whale != address(0)) {
            try IERC20(token).transferFrom(whale, address(this), amount) {
                return true;
            } catch {
                emit log("Skipping fork test: whale transfer failed");
                return false;
            }
        }
        emit log("Skipping fork test: unable to fund underlying (deal failed, no whale)");
        return false;
    }

    function _deal(address token, address to, uint256 amount) external {
        deal(token, to, amount);
    }
}

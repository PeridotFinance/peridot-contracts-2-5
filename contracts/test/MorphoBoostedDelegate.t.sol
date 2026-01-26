// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../contracts/boosted/MorphoBoostedDelegate.sol";
import "../contracts/PErc20Delegator.sol";
import "./MockErc20.sol";
import "./MockPeridottroller.sol";
import "./MockInterestRateModel.sol";

contract LimitedERC4626Vault is ERC4626 {
    uint256 public maxWithdrawLimit;

    constructor(IERC20Metadata asset_) ERC20("Limited Vault Share", "lSHARE") ERC4626(asset_) {}

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

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }
}

contract MorphoBoostedDelegateTest is Test {
    MockErc20 internal underlying;
    LimitedERC4626Vault internal vault;
    MockPeridottroller internal comptroller;
    MockInterestRateModel internal irm;
    MorphoBoostedDelegate internal implementation;
    PErc20Delegator internal delegator;

    address internal admin = address(this);
    address internal user = address(0xBEEF);

    uint256 internal constant INITIAL_EXCHANGE_RATE = 2e26;

    function setUp() public {
        underlying = new MockErc20("Mock USD", "mUSD", 18);
        vault = new LimitedERC4626Vault(IERC20Metadata(address(underlying)));
        comptroller = new MockPeridottroller();
        irm = new MockInterestRateModel();
        implementation = new MorphoBoostedDelegate();

        bytes memory becomeImplData = abi.encode(address(vault), 2e17);
        delegator = new PErc20Delegator(
            address(underlying),
            comptroller,
            irm,
            INITIAL_EXCHANGE_RATE,
            "Peridot Morpho mUSD",
            "pmUSD",
            18,
            payable(admin),
            address(implementation),
            becomeImplData
        );

        comptroller.setMarket(address(delegator), true, 0.75e18);

        underlying.mint(user, 1_000e18);
        vm.prank(user);
        underlying.approve(address(delegator), type(uint256).max);
    }

    function testPauseWithdrawUsesWithdrawable() public {
        MorphoBoostedDelegate delegate = MorphoBoostedDelegate(address(delegator));

        vm.prank(user);
        PErc20(address(delegator)).mint(500e18);

        // Block withdrawals from the vault.
        vault.setMaxWithdrawLimit(0);

        bytes32 actionId = delegate.queueSetVaultPaused(true);
        vm.warp(block.timestamp + delegate.actionDelay());
        delegate._setVaultPaused(true);

        assertTrue(delegate.vaultPaused(), "vault not paused");
        uint256 vaultAssets = vault.convertToAssets(vault.balanceOf(address(delegator)));
        assertGt(vaultAssets, 0, "vault assets should remain");
    }

    function testRebalanceCapsWithdrawals() public {
        MorphoBoostedDelegate delegate = MorphoBoostedDelegate(address(delegator));

        vm.prank(user);
        PErc20(address(delegator)).mint(500e18);

        // Drain local cash to force buffer deficit.
        uint256 localCash = underlying.balanceOf(address(delegator));
        vm.prank(address(delegator));
        underlying.transfer(address(0xCAFE), localCash);

        // Limit withdrawals to 10 underlying.
        vault.setMaxWithdrawLimit(10e18);

        bytes32 actionId = delegate.queueSetVaultBuffer(1e18);
        vm.warp(block.timestamp + delegate.actionDelay());
        delegate._setVaultBuffer(1e18);

        uint256 newCash = underlying.balanceOf(address(delegator));
        assertEq(newCash, 10e18, "withdrawal should cap to maxWithdraw");
    }

    function testUnsetVaultAllowsMint() public {
        MorphoBoostedDelegate impl = new MorphoBoostedDelegate();
        bytes memory becomeImplData = "";
        PErc20Delegator localDelegator = new PErc20Delegator(
            address(underlying),
            comptroller,
            irm,
            INITIAL_EXCHANGE_RATE,
            "Peridot Morpho mUSD",
            "pmUSD",
            18,
            payable(admin),
            address(impl),
            becomeImplData
        );
        comptroller.setMarket(address(localDelegator), true, 0.75e18);

        underlying.mint(user, 100e18);
        vm.startPrank(user);
        underlying.approve(address(localDelegator), 100e18);
        PErc20(address(localDelegator)).mint(100e18);
        vm.stopPrank();
    }

    function testUnsetVaultRedeemRevertsWithoutLiquidity() public {
        MorphoBoostedDelegate impl = new MorphoBoostedDelegate();
        bytes memory becomeImplData = "";
        PErc20Delegator localDelegator = new PErc20Delegator(
            address(underlying),
            comptroller,
            irm,
            INITIAL_EXCHANGE_RATE,
            "Peridot Morpho mUSD",
            "pmUSD",
            18,
            payable(admin),
            address(impl),
            becomeImplData
        );
        comptroller.setMarket(address(localDelegator), true, 0.75e18);

        underlying.mint(user, 100e18);
        vm.startPrank(user);
        underlying.approve(address(localDelegator), 100e18);
        PErc20(address(localDelegator)).mint(100e18);
        vm.stopPrank();

        vm.startPrank(user);
        vm.expectRevert("RedeemTransferOutNotPossible()");
        PErc20(address(localDelegator)).redeem(50e18);
        vm.stopPrank();
    }

    function testAdminActionsRequireQueue() public {
        MorphoBoostedDelegate delegate = MorphoBoostedDelegate(address(delegator));

        vm.expectRevert("action not queued");
        delegate._setVaultBuffer(3e17);

        bytes32 actionId = delegate.queueSetVaultBuffer(3e17);
        vm.warp(block.timestamp + delegate.actionDelay());
        delegate._setVaultBuffer(3e17);
        assertEq(delegate.vaultBufferMantissa(), 3e17);
    }
}

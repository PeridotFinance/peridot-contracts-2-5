// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/boosted/FolksBoostedPErc20.sol";
import "../contracts/Peridottroller.sol";
import "../contracts/InterestRateModel.sol";
import "../contracts/PToken.sol";

interface IERC4626Minimal {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function balanceOf(address owner) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
}

contract FolksBoostedPErc20ForkTest is Test {
    // Defaults from addresses.MD (Monad mainnet)
    address internal constant DEFAULT_COMPTROLLER = 0x6D208789f0a978aF789A3C8Ba515749598940716;
    address internal constant DEFAULT_IRM = 0x1FB287E1c4F7B4c6b511f4d190523814593Ad84e;

    function testForkDepositAndRedeem() public {
        string memory rpc = vm.envOr("MONAD_MAINNET_RPC_URL", string(""));
        address vaultAddr = vm.envOr("FOLKS_VAULT", address(0));
        address underlyingAddr = vm.envOr("FOLKS_UNDERLYING", address(0));
        address comptrollerAddr = vm.envOr("PERIDOT_COMPTROLLER", DEFAULT_COMPTROLLER);
        address irmAddr = vm.envOr("PERIDOT_IRM", DEFAULT_IRM);
        address whale = vm.envOr("FOLKS_WHALE", address(0));

        if (bytes(rpc).length == 0 || vaultAddr == address(0) || underlyingAddr == address(0)) {
            emit log("Skipping fork test: missing envs");
            return;
        }

        vm.createSelectFork(rpc);

        IERC20 underlying = IERC20(underlyingAddr);
        IERC4626Minimal vault = IERC4626Minimal(vaultAddr);

        FolksBoostedPErc20 pToken = new FolksBoostedPErc20(
            underlyingAddr,
            PeridottrollerInterface(comptrollerAddr),
            InterestRateModel(irmAddr),
            1e18,
            "Peridot Folks Fork",
            "pFolks",
            IERC20Metadata(underlyingAddr).decimals(),
            payable(address(this)),
            IERC4626(vaultAddr),
            1e17 // 10% buffer
        );

        // Support market on real comptroller (impersonate admin)
        address admin = Peridottroller(payable(comptrollerAddr)).admin();
        vm.startPrank(admin);
        Peridottroller(comptrollerAddr)._supportMarket(pToken);
        Peridottroller(comptrollerAddr)._setCollateralFactor(PToken(address(pToken)), 0.5e18);
        vm.stopPrank();

        uint256 mintAmount = 1_000 * (10 ** IERC20Metadata(underlyingAddr).decimals());
        if (!_fundUser(underlyingAddr, whale, mintAmount)) return;

        underlying.approve(address(pToken), mintAmount);
        pToken.mint(mintAmount);

        // Redeem half
        uint256 redeemTokens = pToken.balanceOf(address(this)) / 2;
        pToken.redeem(redeemTokens);

        // Assert vault still holds some assets, and user recovered roughly half
        uint256 vaultAssets = vault.convertToAssets(vault.balanceOf(address(pToken)));
        uint256 userBal = underlying.balanceOf(address(this));
        assertGt(vaultAssets, 0);
        assertApproxEqAbs(userBal, mintAmount / 2, mintAmount / 50); // allow 2% drift
    }

    /// Try to fund test address with underlying; use deal first, then whale transfer.
    function _fundUser(address token, address whale, uint256 amount) internal returns (bool) {
        (bool okDeal,) = address(this).call(abi.encodeWithSelector(this._deal.selector, token, address(this), amount));
        if (okDeal) return true;

        if (whale != address(0)) {
            vm.startPrank(whale);
            try IERC20(token).transfer(address(this), amount) {
                vm.stopPrank();
                return true;
            } catch {
                vm.stopPrank();
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UpshiftAdapter} from "../contracts/boosted/adapters/UpshiftAdapter.sol";
import {MockErc20} from "./MockErc20.sol";

contract MockUpshiftVault {
    uint256 internal constant FEE_DENOMINATOR = 1e18;

    IERC20 public immutable asset;
    uint256 public instantRedemptionFee;
    mapping(address => uint256) public balanceOf;

    constructor(IERC20 asset_, uint256 fee_) {
        asset = asset_;
        instantRedemptionFee = fee_;
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function convertToShares(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(asset.transferFrom(msg.sender, address(this), assets), "TRANSFER_IN");
        balanceOf[receiver] += assets;
        return assets;
    }

    function instantRedeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(msg.sender == owner, "OWNER");
        balanceOf[owner] -= shares;
        assets = Math.mulDiv(shares, FEE_DENOMINATOR - instantRedemptionFee, FEE_DENOMINATOR);
        require(asset.transfer(receiver, assets), "TRANSFER_OUT");
    }
}

contract UpshiftAdapterTest is Test {
    MockErc20 internal token;
    MockUpshiftVault internal vault;
    UpshiftAdapter internal adapter;

    function setUp() external {
        token = new MockErc20("Underlying", "UND", 18);
        vault = new MockUpshiftVault(IERC20(address(token)), 1e17);
        adapter = new UpshiftAdapter(address(this), address(token), address(vault));
        token.mint(address(this), 1_000e18);
        token.approve(address(adapter), type(uint256).max);
    }

    function testReportsNetImmediatelyWithdrawableAssetsAndRevokesVaultAllowance() external {
        adapter.deposit(1_000e18);

        assertEq(adapter.totalUnderlying(), 900e18);
        assertEq(token.allowance(address(adapter), address(vault)), 0);
    }

    function testWithdrawalReducesNetWithdrawableValue() external {
        adapter.deposit(1_000e18);
        uint256 beforeAssets = adapter.totalUnderlying();

        uint256 returned = adapter.withdraw(address(this), 450e18);

        assertGe(returned, 450e18);
        assertLt(adapter.totalUnderlying(), beforeAssets);
    }
}

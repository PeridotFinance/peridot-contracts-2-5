// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IV3LPVault4626 {
    struct DepositParams {
        address receiver;
        address refundReceiver;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 minShares;
        uint256 deadline;
    }

    struct WithdrawParams {
        address receiver;
        address owner;
        uint256 shares;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function token0() external view returns (address);

    function token1() external view returns (address);

    function totalManagedToken0() external view returns (uint256);

    function totalManagedToken1() external view returns (uint256);

    function totalLiquidity() external view returns (uint128);

    function positionTokenId() external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function previewDepositDual(uint256 amount0Desired, uint256 amount1Desired) external view returns (uint256 shares);

    function previewWithdrawDual(uint256 shares) external view returns (uint256 amount0, uint256 amount1);

    function depositDual(DepositParams calldata params) external returns (uint256 shares);

    function withdrawDual(WithdrawParams calldata params) external returns (uint256 amount0, uint256 amount1);
}

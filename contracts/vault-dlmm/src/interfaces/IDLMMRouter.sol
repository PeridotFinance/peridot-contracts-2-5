// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal hand-made interface of the Pharaoh `DLMMRouter` 0xFF2BEFC4FF86CB0F3E8D3D9D6200B7A05BF5D93D (Routescan verified, solc 0.8.30).
///         Struct and enum layouts are copied from `IDLMMRouter.sol` of that bundle (the ABI is what matters).
///         `addLiquidity` requires `to == msg.sender` and pulls amountX/amountY from msg.sender into the pair; the pair's hook then requires
///         the router to be an authorised DLMM manager of the voter (it is the mint caller, `to` the vault).
interface IDLMMRouter {
    enum Version { V1, V2, V2_1 }

    struct LiquidityParameters {
        address tokenX;
        address tokenY;
        uint256 binStep;
        uint256 amountX;
        uint256 amountY;
        uint256 amountXMin;
        uint256 amountYMin;
        uint256 activeIdDesired;
        uint256 idSlippage;
        int256[] deltaIds;
        uint256[] distributionX;
        uint256[] distributionY;
        address to;
        address refundTo;
        uint256 deadline;
    }

    struct Path {
        uint256[] pairBinSteps;
        Version[] versions;
        address[] tokenPath;
    }

    function getFactory() external view returns (address);

    function addLiquidity(LiquidityParameters calldata liquidityParameters)
        external
        returns (
            uint256 amountXAdded,
            uint256 amountYAdded,
            uint256 amountXLeft,
            uint256 amountYLeft,
            uint256[] memory depositIds,
            uint256[] memory liquidityMinted
        );

    /// Pulls `amountIn` from msg.sender into the pair, swaps, reverts `LBRouter__InsufficientAmountOut` if below `amountOutMin`.
    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, Path memory path, address to, uint256 deadline)
        external
        returns (uint256 amountOut);
}

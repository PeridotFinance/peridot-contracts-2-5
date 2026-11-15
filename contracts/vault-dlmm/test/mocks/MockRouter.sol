// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMockLBPair {
    function tokenX() external view returns (address);
    function tokenY() external view returns (address);
    function getActiveId() external view returns (uint24);
    function mint(address to, bytes32[] calldata cfgs, address refundTo) external returns (bytes32, bytes32, uint256[] memory);
    function burn(address from, address to, uint256[] calldata ids, uint256[] calldata amounts) external returns (bytes32[] memory);
    function swap(bool swapForY, address to) external returns (bytes32);
}

interface IMockFactory {
    struct LBPairInformation {
        uint16 binStep;
        address LBPair;
        bool createdByOwner;
        bool ignoredForRouting;
    }

    function getLBPairInformation(address, address, uint256) external view returns (LBPairInformation memory);
}

/// @notice Pharaoh `DLMMRouter` stand-in (verified source 0xFF2BEF...5D93D): `addLiquidity` (liquidity params with deltaIds / distributions / idSlippage, `to == msg.sender`),
///         `removeLiquidity` (burns from msg.sender, which must have approved the router on the pair), `swapExactTokensForTokens` over a one-hop path. Errors use the real names.
contract MockRouter {
    error LBRouter__DeadlineExceeded(uint256 deadline, uint256 currentTimestamp);
    error LBRouter__PairNotCreated(address tokenX, address tokenY, uint256 binStep);
    error LBRouter__WrongTokenOrder();
    error LBRouter__LengthsMismatch();
    error LBRouter__IdSlippageCaught(uint256 activeIdDesired, uint256 idSlippage, uint256 activeId);
    error LBRouter__IdDesiredOverflows(uint256 idDesired, uint256 idSlippage);
    error LBRouter__IdOverflows(int256 id);
    error LBRouter__AmountSlippageCaught(uint256 amountXMin, uint256 amountX, uint256 amountYMin, uint256 amountY);
    error LBRouter__InsufficientAmountOut(uint256 amountOutMin, uint256 amountOut);
    error LBRouter__InvalidTokenPath(address wrongToken);
    error LBRouter__UnauthorizedLiquidityRecipient(address sender, address recipient);

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

    address public immutable factory;

    constructor(address factory_) {
        factory = factory_;
    }

    function getFactory() external view returns (address) {
        return factory;
    }

    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert LBRouter__DeadlineExceeded(deadline, block.timestamp);
        _;
    }

    function _pair(address a, address b, uint256 step) private view returns (address p) {
        p = IMockFactory(factory).getLBPairInformation(a, b, step).LBPair;
        if (p == address(0)) revert LBRouter__PairNotCreated(a, b, step);
    }

    function addLiquidity(LiquidityParameters calldata p)
        external
        ensure(p.deadline)
        returns (uint256 amountXAdded, uint256 amountYAdded, uint256 amountXLeft, uint256 amountYLeft, uint256[] memory depositIds, uint256[] memory liquidityMinted)
    {
        if (p.to != msg.sender) revert LBRouter__UnauthorizedLiquidityRecipient(msg.sender, p.to);
        address pair = _pair(p.tokenX, p.tokenY, p.binStep);
        if (p.tokenX != IMockLBPair(pair).tokenX()) revert LBRouter__WrongTokenOrder();

        IERC20(p.tokenX).transferFrom(msg.sender, pair, p.amountX);
        IERC20(p.tokenY).transferFrom(msg.sender, pair, p.amountY);

        if (p.deltaIds.length != p.distributionX.length || p.deltaIds.length != p.distributionY.length) revert LBRouter__LengthsMismatch();
        if (p.activeIdDesired > type(uint24).max || p.idSlippage > type(uint24).max) revert LBRouter__IdDesiredOverflows(p.activeIdDesired, p.idSlippage);
        uint256 activeId = IMockLBPair(pair).getActiveId();
        if (p.activeIdDesired + p.idSlippage < activeId || activeId + p.idSlippage < p.activeIdDesired) {
            revert LBRouter__IdSlippageCaught(p.activeIdDesired, p.idSlippage, activeId);
        }

        bytes32[] memory cfgs = new bytes32[](p.deltaIds.length);
        depositIds = new uint256[](p.deltaIds.length);
        for (uint256 i; i < cfgs.length; ++i) {
            int256 id = int256(p.activeIdDesired) + p.deltaIds[i];
            if (id < 0 || uint256(id) > type(uint24).max) revert LBRouter__IdOverflows(id);
            depositIds[i] = uint256(id);
            cfgs[i] = bytes32((uint256(uint64(p.distributionX[i])) << 88) | (uint256(uint64(p.distributionY[i])) << 24) | uint256(id));
        }
        bytes32 received;
        bytes32 left;
        (received, left, liquidityMinted) = IMockLBPair(pair).mint(p.to, cfgs, p.refundTo);
        amountXLeft = uint128(uint256(left));
        amountYLeft = uint256(left) >> 128;
        amountXAdded = p.amountX - amountXLeft;
        amountYAdded = p.amountY - amountYLeft;
        if (amountXAdded < p.amountXMin || amountYAdded < p.amountYMin) {
            revert LBRouter__AmountSlippageCaught(p.amountXMin, amountXAdded, p.amountYMin, amountYAdded);
        }
    }

    function removeLiquidity(
        address tokenX,
        address tokenY,
        uint16 binStep,
        uint256 amountXMin,
        uint256 amountYMin,
        uint256[] memory ids,
        uint256[] memory amounts,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountX, uint256 amountY) {
        address pair = _pair(tokenX, tokenY, binStep);
        if (tokenX != IMockLBPair(pair).tokenX()) revert LBRouter__WrongTokenOrder();
        bytes32[] memory out = IMockLBPair(pair).burn(msg.sender, to, ids, amounts);
        for (uint256 i; i < out.length; ++i) {
            amountX += uint128(uint256(out[i]));
            amountY += uint256(out[i]) >> 128;
        }
        if (amountX < amountXMin || amountY < amountYMin) revert LBRouter__AmountSlippageCaught(amountXMin, amountX, amountYMin, amountY);
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, Path memory path, address to, uint256 deadline)
        external
        ensure(deadline)
        returns (uint256 amountOut)
    {
        if (path.tokenPath.length != 2 || path.pairBinSteps.length != 1) revert LBRouter__LengthsMismatch();
        address tIn = path.tokenPath[0];
        address tOut = path.tokenPath[1];
        address pair = _pair(tIn, tOut, path.pairBinSteps[0]);
        bool swapForY = tIn == IMockLBPair(pair).tokenX();
        if (!swapForY && tIn != IMockLBPair(pair).tokenY()) revert LBRouter__InvalidTokenPath(tIn);
        IERC20(tIn).transferFrom(msg.sender, pair, amountIn);
        bytes32 o = IMockLBPair(pair).swap(swapForY, to);
        amountOut = swapForY ? uint256(o) >> 128 : uint128(uint256(o));
        if (amountOut < amountOutMin) revert LBRouter__InsufficientAmountOut(amountOutMin, amountOut);
    }
}

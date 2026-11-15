// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Stand-in for the Pharaoh DLMM pool (Trader Joe LB v2.1 `DLMMPool`, verified source 0xF41253...d710). Behaviour copied from that source:
///  - bins hold (X, Y); liquidity L = price*x + (y << 128), price 128.128; first mint shares = sqrt(L), later shares = L_in * supply / L_bin (round down, excess trimmed);
///  - `mint(to, configs, refundTo)` reads tokens already sent to the pair (balance - reserves); config = distX(64b)<<88 | distY(64b)<<24 | id(24b), amounts floor(received*dist/1e18);
///  - one-sided rule: below the active bin only Y, above only X (`CompositionFactorFlawed`); the active bin takes both (composition fee NOT modelled);
///  - shares are non-transferable ERC-1155-like (`batchTransferFrom` goes through the hook, which reverts "transfers disabled"); `burn(from,to,ids,amounts)` needs from == sender or approval,
///    pays floor(amount*reserve/supply), reverts `LBPair__ZeroAmount` on a zero per-bin amount and `LBPair__ZeroAmountsOut` when a bin pays nothing;
///  - `swap(swapForY, to)` takes the tokens already sent, crosses bins (Y out of the active bin and lower ids for swapForY), the fee stays in the bin (LP income, protocol share not modelled);
///  - hooks (`beforeSwap`, `beforeMint`, `beforeBurn`, `beforeBatchTransferFrom`) are called through a safe call: a reverting hook or a wrong return selector reverts the WHOLE pair call.
///  Price per bin is linear in the id (1 + (id - 2^23) * binStep / 10000 in bps-of-step), an approximation of 1.0001^n that is exact to 1e-8 over a few bins.
contract MockLBPair {
    // ---- errors (selectors-compatible names of the real pair)
    error LBPair__InsufficientAmountIn();
    error LBPair__InsufficientAmountOut();
    error LBPair__OutOfLiquidity();
    error LBPair__ZeroAmount(uint24 id);
    error LBPair__ZeroAmountsOut(uint24 id);
    error LBPair__ZeroShares(uint24 id);
    error LBPair__InvalidInput();
    error LBPair__EmptyMarketConfigs();
    error LBPair__InvalidHooks();
    error LBPair__AddressZero();
    error BinHelper__CompositionFactorFlawed(uint24 id);
    error LiquidityConfigurations__InvalidConfig();
    error LBToken__SpenderNotApproved(address from, address spender);
    error LBToken__BurnExceedsBalance(address from, uint256 id, uint256 amount);

    uint256 private constant SCALE_OFFSET = 128;
    uint256 private constant ONE = 1 << 128;
    uint24 public constant ID_ONE = 1 << 23;

    bytes32 internal constant BEFORE_SWAP_FLAG = bytes32(uint256(1 << 160));
    bytes32 internal constant BEFORE_MINT_FLAG = bytes32(uint256(1 << 164));
    bytes32 internal constant BEFORE_BURN_FLAG = bytes32(uint256(1 << 166));
    bytes32 internal constant BEFORE_TRANSFER_FLAG = bytes32(uint256(1 << 168));
    bytes32 public constant PHARAOH_HOOK_FLAGS = bytes32(uint256(0x151) << 160);

    address public immutable tokenX;
    address public immutable tokenY;
    uint16 public immutable binStep;
    address public factory;

    uint24 public activeId;
    mapping(uint24 => uint128) internal _binX;
    mapping(uint24 => uint128) internal _binY;
    uint128 public reserveX;
    uint128 public reserveY;

    mapping(uint256 => uint256) public totalSupply;
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    bytes32 internal _hooksParameters;
    /// swap fee as a 1e18 fraction of the input (default 0.0025 % = the pool's base fee at bin step 1)
    uint256 public feeWad = 2.5e13;
    uint256 public swapCount;

    constructor(address tokenX_, address tokenY_, uint16 binStep_, uint24 activeId_, address factory_) {
        require(tokenX_ < tokenY_, "order");
        tokenX = tokenX_;
        tokenY = tokenY_;
        binStep = binStep_;
        activeId = activeId_;
        factory = factory_;
    }

    // ------------------------------------------------------------------ views
    function getFactory() external view returns (address) {
        return factory;
    }

    function getTokenX() external view returns (address) {
        return tokenX;
    }

    function getTokenY() external view returns (address) {
        return tokenY;
    }

    function getBinStep() external view returns (uint16) {
        return binStep;
    }

    function getActiveId() external view returns (uint24) {
        return activeId;
    }

    function getBin(uint24 id) external view returns (uint128, uint128) {
        return (_binX[id], _binY[id]);
    }

    function getReserves() external view returns (uint128, uint128) {
        return (reserveX, reserveY);
    }

    function getLBHooksParameters() external view returns (bytes32) {
        return _hooksParameters;
    }

    function getPriceFromId(uint24 id) public view returns (uint256) {
        int256 d = int256(uint256(id)) - int256(uint256(ID_ONE));
        int256 p = int256(ONE) + (d * int256(ONE) * int256(uint256(binStep))) / 10_000;
        require(p > 0, "price");
        return uint256(p);
    }

    function name() external pure returns (string memory) {
        return "Mock LB";
    }

    function symbol() external pure returns (string memory) {
        return "MLB";
    }

    // ------------------------------------------------------------------ LB token
    function approveForAll(address spender, bool approved) external {
        require(spender != msg.sender, "self");
        isApprovedForAll[msg.sender][spender] = approved;
    }

    /// real transfers are disabled by the Pharaoh hook (the hook reverts "transfers disabled"); without a hook the transfer is allowed like a plain LB token
    function batchTransferFrom(address from, address to, uint256[] calldata ids, uint256[] calldata amounts) external {
        if (from != msg.sender && !isApprovedForAll[from][msg.sender]) revert LBToken__SpenderNotApproved(from, msg.sender);
        bytes32 hp = _hooksParameters;
        if (hp & BEFORE_TRANSFER_FLAG != 0) {
            _safeCall(hp, abi.encodeWithSignature("beforeBatchTransferFrom(address,address,address,uint256[],uint256[])", msg.sender, from, to, ids, amounts), bytes4(0));
        }
        for (uint256 i; i < ids.length; ++i) {
            if (balanceOf[from][ids[i]] < amounts[i]) revert LBToken__BurnExceedsBalance(from, ids[i], amounts[i]);
            balanceOf[from][ids[i]] -= amounts[i];
            balanceOf[to][ids[i]] += amounts[i];
        }
    }

    // ------------------------------------------------------------------ mint
    function mint(address to, bytes32[] calldata liquidityConfigs, address refundTo)
        external
        returns (bytes32 amountsReceived, bytes32 amountsLeft, uint256[] memory liquidityMinted)
    {
        if (to == address(0) || to == address(this)) revert LBPair__AddressZero();
        if (liquidityConfigs.length == 0) revert LBPair__EmptyMarketConfigs();

        uint256 recX = IERC20(tokenX).balanceOf(address(this)) - reserveX;
        uint256 recY = IERC20(tokenY).balanceOf(address(this)) - reserveY;
        amountsReceived = _pack(recX, recY);

        _hook(BEFORE_MINT_FLAG, abi.encodeWithSignature("beforeMint(address,address,bytes32[],bytes32)", msg.sender, to, liquidityConfigs, amountsReceived), bytes4(0));

        liquidityMinted = new uint256[](liquidityConfigs.length);
        uint256 leftX = recX;
        uint256 leftY = recY;
        for (uint256 i; i < liquidityConfigs.length; ++i) {
            (uint256 inX, uint256 inY, uint24 id) = _decodeConfig(liquidityConfigs[i], recX, recY);
            (uint256 shares, uint256 usedX, uint256 usedY) = _updateBin(id, inX, inY);
            leftX -= usedX;
            leftY -= usedY;
            liquidityMinted[i] = shares;
            totalSupply[id] += shares;
            balanceOf[to][id] += shares;
        }
        reserveX += uint128(recX - leftX);
        reserveY += uint128(recY - leftY);
        amountsLeft = _pack(leftX, leftY);
        if (leftX != 0) IERC20(tokenX).transfer(refundTo, leftX);
        if (leftY != 0) IERC20(tokenY).transfer(refundTo, leftY);
    }

    function _decodeConfig(bytes32 cfg, uint256 recX, uint256 recY) private pure returns (uint256 x, uint256 y, uint24 id) {
        uint256 c = uint256(cfg);
        uint64 dX = uint64(c >> 88);
        uint64 dY = uint64(c >> 24);
        id = uint24(c);
        if (c > type(uint152).max || dX > 1e18 || dY > 1e18) revert LiquidityConfigurations__InvalidConfig();
        x = (recX * dX) / 1e18;
        y = (recY * dY) / 1e18;
    }

    function _updateBin(uint24 id, uint256 x, uint256 y) private returns (uint256 shares, uint256 usedX, uint256 usedY) {
        uint256 price = getPriceFromId(id);
        uint256 supply = totalSupply[id];
        uint256 bx = _binX[id];
        uint256 by = _binY[id];

        uint256 userL = _liq(x, y, price);
        if (userL != 0) {
            uint256 binL = _liq(bx, by, price);
            if (binL == 0 || supply == 0) {
                shares = Math.sqrt(userL);
            } else {
                shares = Math.mulDiv(userL, supply, binL);
                uint256 effL = Math.mulDiv(shares, binL, supply, Math.Rounding.Ceil);
                if (userL > effL) {
                    uint256 dL = userL - effL;
                    if (dL >= ONE) {
                        uint256 dY = dL >> SCALE_OFFSET;
                        dY = dY > y ? y : dY;
                        y -= dY;
                        dL -= dY << SCALE_OFFSET;
                    }
                    if (dL >= price) {
                        uint256 dX = dL / price;
                        dX = dX > x ? x : dX;
                        x -= dX;
                    }
                }
            }
        }
        if (id < activeId && x > 0 || id > activeId && y > 0) revert BinHelper__CompositionFactorFlawed(id);
        if (shares == 0 || (x == 0 && y == 0)) revert LBPair__ZeroShares(id);
        _binX[id] = uint128(bx + x);
        _binY[id] = uint128(by + y);
        return (shares, x, y);
    }

    function _liq(uint256 x, uint256 y, uint256 price) private pure returns (uint256) {
        return price * x + (y << SCALE_OFFSET);
    }

    // ------------------------------------------------------------------ burn
    function burn(address from, address to, uint256[] calldata ids, uint256[] calldata amountsToBurn) external returns (bytes32[] memory amounts) {
        if (from != msg.sender && !isApprovedForAll[from][msg.sender]) revert LBToken__SpenderNotApproved(from, msg.sender);
        if (ids.length == 0 || ids.length != amountsToBurn.length) revert LBPair__InvalidInput();

        _hook(BEFORE_BURN_FLAG, abi.encodeWithSignature("beforeBurn(address,address,address,uint256[],uint256[])", msg.sender, from, to, ids, amountsToBurn), bytes4(0));

        amounts = new bytes32[](ids.length);
        uint256 outX;
        uint256 outY;
        for (uint256 i; i < ids.length; ++i) {
            uint24 id = uint24(ids[i]);
            uint256 a = amountsToBurn[i];
            if (a == 0) revert LBPair__ZeroAmount(id);
            uint256 supply = totalSupply[ids[i]];
            if (balanceOf[from][ids[i]] < a) revert LBToken__BurnExceedsBalance(from, ids[i], a);
            balanceOf[from][ids[i]] -= a;
            totalSupply[ids[i]] = supply - a;

            uint256 ox = (a * _binX[id]) / supply;
            uint256 oy = (a * _binY[id]) / supply;
            if (ox == 0 && oy == 0) revert LBPair__ZeroAmountsOut(id);
            _binX[id] -= uint128(ox);
            _binY[id] -= uint128(oy);
            amounts[i] = _pack(ox, oy);
            outX += ox;
            outY += oy;
        }
        reserveX -= uint128(outX);
        reserveY -= uint128(outY);
        if (outX != 0) IERC20(tokenX).transfer(to, outX);
        if (outY != 0) IERC20(tokenY).transfer(to, outY);
    }

    // ------------------------------------------------------------------ swap
    function swap(bool swapForY, address to) external returns (bytes32 amountsOut) {
        uint256 amountIn = swapForY
            ? IERC20(tokenX).balanceOf(address(this)) - reserveX
            : IERC20(tokenY).balanceOf(address(this)) - reserveY;
        if (amountIn == 0) revert LBPair__InsufficientAmountIn();

        _hook(BEFORE_SWAP_FLAG, abi.encodeWithSignature("beforeSwap(address,address,bool,bytes32)", msg.sender, to, swapForY, swapForY ? _pack(amountIn, 0) : _pack(0, amountIn)), bytes4(0));

        uint256 left = amountIn;
        uint256 out;
        uint24 id = activeId;
        uint256 keep = 1e18 - feeWad;
        while (true) {
            uint256 price = getPriceFromId(id);
            if (swapForY) {
                uint256 by = _binY[id];
                if (by != 0) {
                    uint256 netNeeded = Math.mulDiv(by, ONE, price, Math.Rounding.Ceil);
                    uint256 gross = Math.mulDiv(netNeeded, 1e18, keep, Math.Rounding.Ceil);
                    uint256 take;
                    uint256 o;
                    if (left >= gross) {
                        take = gross;
                        o = by;
                    } else {
                        take = left;
                        o = Math.mulDiv((take * keep) / 1e18, price, ONE);
                        if (o > by) o = by;
                    }
                    left -= take;
                    out += o;
                    _binX[id] += uint128(take);
                    _binY[id] -= uint128(o);
                }
            } else {
                uint256 bx = _binX[id];
                if (bx != 0) {
                    uint256 netNeeded = Math.mulDiv(bx, price, ONE, Math.Rounding.Ceil);
                    uint256 gross = Math.mulDiv(netNeeded, 1e18, keep, Math.Rounding.Ceil);
                    uint256 take;
                    uint256 o;
                    if (left >= gross) {
                        take = gross;
                        o = bx;
                    } else {
                        take = left;
                        o = Math.mulDiv((take * keep) / 1e18, ONE, price);
                        if (o > bx) o = bx;
                    }
                    left -= take;
                    out += o;
                    _binY[id] += uint128(take);
                    _binX[id] -= uint128(o);
                }
            }
            if (left == 0) break;
            id = _nextNonEmpty(swapForY, id);
        }
        if (out == 0) revert LBPair__InsufficientAmountOut();
        activeId = id;
        swapCount++;
        if (swapForY) {
            reserveX += uint128(amountIn);
            reserveY -= uint128(out);
            IERC20(tokenY).transfer(to, out);
            amountsOut = _pack(0, out);
        } else {
            reserveY += uint128(amountIn);
            reserveX -= uint128(out);
            IERC20(tokenX).transfer(to, out);
            amountsOut = _pack(out, 0);
        }
    }

    function _nextNonEmpty(bool swapForY, uint24 id) private view returns (uint24) {
        for (uint256 i; i < 2000; ++i) {
            if (swapForY) {
                if (id == 0) break;
                id -= 1;
                if (_binY[id] != 0) return id;
            } else {
                id += 1;
                if (_binX[id] != 0) return id;
            }
        }
        revert LBPair__OutOfLiquidity();
    }

    // ------------------------------------------------------------------ hooks
    function _hook(bytes32 flag, bytes memory data, bytes4) private {
        bytes32 hp = _hooksParameters;
        if (hp & flag != 0) _safeCall(hp, data, bytes4(data));
    }

    /// like `Hooks._safeCall`: a failing hook call reverts the whole pair call (revert data bubbled), a wrong return selector reverts `LBPair__InvalidHooks`
    function _safeCall(bytes32 hp, bytes memory data, bytes4) private {
        address h = address(uint160(uint256(hp)));
        (bool ok, bytes memory ret) = h.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        if (ret.length != 32 || bytes4(abi.decode(ret, (bytes32))) != bytes4(data)) revert LBPair__InvalidHooks();
    }

    function _pack(uint256 x, uint256 y) private pure returns (bytes32) {
        return bytes32((y << 128) | x);
    }

    // ------------------------------------------------------------------ test knobs (not on the real pair)
    function setHooksParameters(bytes32 hp) external {
        _hooksParameters = hp;
    }

    /// the Pharaoh configuration: flags 0x151 (BEFORE_SWAP, BEFORE_MINT, BEFORE_BURN, BEFORE_TRANSFER) plus the hook address
    function setHook(address hook) external {
        _hooksParameters = hook == address(0) ? bytes32(0) : (PHARAOH_HOOK_FLAGS | bytes32(uint256(uint160(hook))));
    }

    function setFee(uint256 feeWad_) external {
        feeWad = feeWad_;
    }

    /// moves the active id WITHOUT trading (peg-guard fixtures); the invariant "Y below, X above" can break: use only on empty neighbours
    function forceActiveId(uint24 id) external {
        activeId = id;
    }

    /// fee / donation income: sends tokens to the pair's own reserves of one bin (caller must have transferred them first via the token mock mint to this address)
    function addToBin(uint24 id, uint128 x, uint128 y) external {
        _binX[id] += x;
        _binY[id] += y;
        reserveX += x;
        reserveY += y;
    }
}

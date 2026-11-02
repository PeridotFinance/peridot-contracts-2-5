// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "../../contracts/pancakev3/libraries/TickMath.sol";

/// @dev Minimal interfaces for the two LIVE Pharaoh ERC-4626 vaults (PharaohLiquidityVault behind
///      PharaohRewardExtension behind a TransparentUpgradeableProxy). Verified source: see the Track A doc.
interface ITAVault {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function owner() external view returns (address);
    function rebalancer() external view returns (address);
    function paused() external view returns (bool);
    function depositCap() external view returns (uint256);
    function pool() external view returns (address);
    function positionManager() external view returns (address);
    function priceOracle() external view returns (address);
    function pairedToken() external view returns (address);
    function assetIsToken0() external view returns (bool);
    function tokenId() external view returns (uint256);
    function positionTickLower() external view returns (int24);
    function positionTickUpper() external view returns (int24);
    function tickRange() external view returns (int24);
    function twapPeriod() external view returns (uint32);
    function maxTwapDeviationTicks() external view returns (uint24);
    function maxOracleDeviationBps() external view returns (uint16);
    function slippageBps() external view returns (uint16);
    function valuationHaircutBps() external view returns (uint16);
    function maxDeposit(address) external view returns (uint256);
    function maxMint(address) external view returns (uint256);
    function maxWithdraw(address) external view returns (uint256);
    function maxRedeem(address) external view returns (uint256);
    function previewRedeem(uint256) external view returns (uint256);
    function previewDeposit(uint256) external view returns (uint256);
    function convertToAssets(uint256) external view returns (uint256);
    function deposit(uint256, address) external returns (uint256);
    function withdraw(uint256, address, address) external returns (uint256);
    function redeem(uint256, address, address) external returns (uint256);
    function redeemInKind(uint256, address, address) external returns (uint256, uint256);
    function deployIdle() external;
    function rebalance() external;
    function emergencyExit() external;
    function pause() external;
    function unpause() external;
    function setDepositCap(uint256) external;
    function setRebalancer(address) external;
    function harvestRewards(bool, uint256) external returns (uint256, uint256);
}

interface ITAPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool);
}

interface ITAPositionManager {
    function positions(uint256)
        external
        view
        returns (address, address, int24, int24, int24, uint128, uint256, uint256, uint128, uint128);
    function ownerOf(uint256) external view returns (address);
}

interface ITAGauge {
    function earned(address token, uint256 tokenId) external view returns (uint256);
}

interface ITAVoter {
    function gaugeForPool(address) external view returns (address);
}

interface ITARouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256);
}

interface ITAFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface ITAOwnable {
    function owner() external view returns (address);
}

interface ITASafe {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
}

interface ITAOracle {
    function asset() external view returns (address);
    function pairedToken() external view returns (address);
    function quotePairToAsset(uint256) external view returns (uint256);
    function quoteAssetToPair(uint256) external view returns (uint256);
}

/// @dev Drop-in replacement for the vault's price oracle (installed with vm.etch, LOCAL VM ONLY). Used to keep the
///      oracle fresh across vm.warp, or to make the oracle FOLLOW a real pool move (a genuine depeg / rate move).
contract TAMockOracle {
    address public immutable asset;
    address public immutable pairedToken;
    uint256 public immutable aUnit;
    uint256 public immutable pUnit;
    uint256 public ratio; // asset per ONE paired token, 1e18 scaled

    constructor(address a, address p, uint256 aU, uint256 pU) {
        asset = a;
        pairedToken = p;
        aUnit = aU;
        pUnit = pU;
    }

    function setRatio(uint256 r) external {
        ratio = r;
    }

    function quotePairToAsset(uint256 pairAmount) external view returns (uint256) {
        return Math.mulDiv(pairAmount, ratio * aUnit, 1e18 * pUnit);
    }

    function quoteAssetToPair(uint256 assetAmount) external view returns (uint256) {
        return Math.mulDiv(assetAmount, 1e18 * pUnit, ratio * aUnit);
    }
}

/// @notice Shared fixture for the Track A launch-gate fork suites. One concrete suite per vault.
abstract contract TrackAVaultsBase is Test {
    // ------------------------------------------------------------------ pin (one block per suite)
    uint256 internal constant PIN_BLOCK = 99208619;
    // block hash recorded by `cast block 99212200 -f hash` at pin time (documented; also checked by the suite)
    bytes32 internal constant PIN_HASH = 0xd42b05fafc04d45616e7c10d0b256a675f25e78e811fdaf6624dabe5e6b52549;

    // ------------------------------------------------------------------ labelled addresses (verified in test_00)
    address internal constant SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
    address internal constant REBALANCER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    address internal constant USDC_VAULT = 0x855bF832f26a294d28500db59eE941dE3d654129;
    address internal constant WAVAX_VAULT = 0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8;
    address internal constant ROUTER = 0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c;
    address internal constant FACTORY = 0xAE6E5c62328ade73ceefD42228528b70c8157D0d;
    address internal constant VOTER = 0x922b9Ca8e2207bfB850B6FF647c054d4b58a2Aa7;
    address internal constant POSITION_MANAGER = 0x0B4478e810D48B5882D4019D435A2f864Bab4F39;
    address internal constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant USDT = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7;
    address internal constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address internal constant SAVAX = 0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE;
    address internal constant PHAR = 0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7;
    address internal constant XPHAR = 0xE8164Ea89665DAb7a553e667F81F30CfDA736B9A;
    address internal constant AVAX_FEED = 0x0A77230d17318075983913bC2145DB16C7366156;
    address internal constant BASE_IMPL = 0x37E28a2C9FA3bBdab81efA69D5D480f5107a3770;
    address internal constant EXT_IMPL = 0x165E1f072e7bEeDf94f14F732838354cA20bA45d;
    bytes32 internal constant BASE_CODEHASH = 0x416f2a818693b20948fc44e9955ec7a370be051599b1eef6ca1fad932f3626ef;
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);
    address internal constant WHALE = address(0xDEAD0001);

    // ------------------------------------------------------------------ per-suite configuration
    ITAVault internal v;
    IERC20 internal asset;
    IERC20 internal paired;
    ITAPool internal pool;
    address internal gauge;
    address internal oracleAddr;
    uint256 internal aUnit;
    uint256 internal pUnit;
    int24 internal tSpacing;
    bool internal live;

    function _vaultAddress() internal pure virtual returns (address);
    function _label() internal pure virtual returns (string memory);
    function _isUsd() internal pure virtual returns (bool);

    function setUp() public {
        string memory rpc = vm.envOr("AVALANCHE_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        // The public node serves cold state only for roughly the last 128 blocks, so each run pins a block taken just
        // before it starts (env TRACKA_PIN_BLOCK); the constant is the pin of the documented reference run.
        vm.createSelectFork(rpc, vm.envOr("TRACKA_PIN_BLOCK", PIN_BLOCK));
        require(block.chainid == 43_114, "not Avalanche C-Chain");
        v = ITAVault(_vaultAddress());
        asset = IERC20(v.asset());
        paired = IERC20(v.pairedToken());
        pool = ITAPool(v.pool());
        gauge = ITAVoter(VOTER).gaugeForPool(address(pool));
        oracleAddr = v.priceOracle();
        aUnit = 10 ** _dec(address(asset));
        pUnit = 10 ** _dec(address(paired));
        tSpacing = 1;
        live = true;
    }

    function _dec(address t) internal view returns (uint256) {
        (bool ok, bytes memory r) = t.staticcall(abi.encodeWithSignature("decimals()"));
        require(ok, "decimals");
        return abi.decode(r, (uint8));
    }

    // ------------------------------------------------------------------ sizing
    function _avaxUsd8() internal view returns (uint256) {
        (, int256 a,,,) = ITAFeed(AVAX_FEED).latestRoundData();
        return uint256(a);
    }

    /// @dev USD (whole dollars) -> asset units. USDC is taken at USD 1; WAVAX at the Chainlink AVAX/USD answer at the pin.
    function _usdToAsset(uint256 usd) internal view returns (uint256) {
        if (_isUsd()) return usd * aUnit;
        return Math.mulDiv(usd * 1e8, aUnit, _avaxUsd8());
    }

    function _assetToUsdE2(uint256 amt) internal view returns (uint256) {
        if (_isUsd()) return amt * 100 / aUnit;
        return Math.mulDiv(amt, _avaxUsd8() * 100, aUnit * 1e8);
    }

    // ------------------------------------------------------------------ funding / swaps
    function _fund(address token, address to, uint256 amt) internal {
        if (token == SAVAX) {
            // sAVAX is a BENQI staking token: try storage deal first, then mint through submit() with native AVAX.
            (bool ok,) = address(vm).call(abi.encodeWithSignature("deal(address,address,uint256)", token, to, amt));
            if (ok && IERC20(token).balanceOf(to) >= amt) return;
            uint256 need = amt * 2;
            vm.deal(to, need);
            vm.prank(to);
            (bool ok2,) = token.call{value: need}(abi.encodeWithSignature("submit()"));
            require(ok2 && IERC20(token).balanceOf(to) >= amt, "fund sAVAX");
            return;
        }
        deal(token, to, amt);
    }

    function _swapAs(address who, address tin, address tout, uint256 amtIn, uint160 limit) internal returns (uint256 out) {
        if (IERC20(tin).balanceOf(who) < amtIn) _fund(tin, who, amtIn);
        vm.startPrank(who);
        IERC20(tin).approve(ROUTER, amtIn);
        out = ITARouter(ROUTER).exactInputSingle(
            ITARouter.ExactInputSingleParams(tin, tout, tSpacing, who, block.timestamp + 1, amtIn, 0, limit)
        );
        vm.stopPrank();
    }

    function _spotTick() internal view returns (int24 t) {
        (, t,,,,,) = pool.slot0();
    }

    /// @dev Move the REAL pool to `target` by one real swap through the real router, price-limited at the target.
    function _moveToTick(int24 target) internal returns (uint256 tokenInUsed) {
        int24 t = _spotTick();
        if (target == t) return 0;
        bool zeroForOne = target < t;
        address t0 = pool.token0();
        address t1 = pool.token1();
        address tin = zeroForOne ? t0 : t1;
        address tout = zeroForOne ? t1 : t0;
        uint256 big = 2_000_000_000 * (10 ** _dec(tin)); // ample, the limit stops the swap
        if (IERC20(tin).balanceOf(WHALE) < big) _fund(tin, WHALE, big);
        uint256 before = IERC20(tin).balanceOf(WHALE);
        _swapAs(WHALE, tin, tout, big, TickMath.getSqrtRatioAtTick(target));
        tokenInUsed = before - IERC20(tin).balanceOf(WHALE);
    }

    /// @dev Ping-pong swaps of `legAsset` size to generate swap fees for in-range LPs without moving the price.
    function _generateFees(uint256 rounds, uint256 legAsset) internal returns (uint256 volumeAsset) {
        for (uint256 i; i < rounds; ++i) {
            uint256 got = _swapAs(WHALE, address(asset), address(paired), legAsset, 0);
            _swapAs(WHALE, address(paired), address(asset), got, 0);
            volumeAsset += legAsset * 2;
        }
    }

    // ------------------------------------------------------------------ vault helpers
    function _openCap(uint256 usdCap) internal {
        uint256 cap = _usdToAsset(usdCap);
        vm.prank(SAFE); // LOCAL VM ONLY: forge cheatcode impersonation of the owner Safe, never a real transaction
        v.setDepositCap(cap);
    }

    function _try(address who, address target, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.prank(who);
        (ok, ret) = target.call(data);
    }

    function _depositAs(address who, uint256 amt) internal returns (bool ok, uint256 shares, bytes memory err) {
        if (asset.balanceOf(who) < amt) _fund(address(asset), who, amt);
        vm.prank(who);
        asset.approve(address(v), amt);
        bytes memory ret;
        (ok, ret) = _try(who, address(v), abi.encodeCall(ITAVault.deposit, (amt, who)));
        if (ok) shares = abi.decode(ret, (uint256));
        else err = ret;
    }

    function _redeemAs(address who, uint256 shares) internal returns (bool ok, uint256 gotAsset, bytes memory err) {
        uint256 b = asset.balanceOf(who);
        bytes memory ret;
        (ok, ret) = _try(who, address(v), abi.encodeCall(ITAVault.redeem, (shares, who, who)));
        if (ok) gotAsset = asset.balanceOf(who) - b;
        else err = ret;
    }

    function _redeemKindAs(address who, uint256 shares)
        internal
        returns (bool ok, uint256 gotAsset, uint256 gotPaired, bytes memory err)
    {
        bytes memory ret;
        (ok, ret) = _try(who, address(v), abi.encodeCall(ITAVault.redeemInKind, (shares, who, who)));
        if (ok) (gotAsset, gotPaired) = abi.decode(ret, (uint256, uint256));
        else err = ret;
    }

    function _pps() internal view returns (uint256) {
        return Math.mulDiv(v.totalAssets(), 1e18, v.totalSupply());
    }

    function _viewTotalAssets() internal view returns (bool ok, uint256 val) {
        try v.totalAssets() returns (uint256 x) {
            return (true, x);
        } catch {
            return (false, 0);
        }
    }

    function _pairedInAsset(uint256 pairedAmt) internal view returns (uint256) {
        return ITAOracle(oracleAddr).quotePairToAsset(pairedAmt);
    }

    function _bps(uint256 num, uint256 den) internal pure returns (uint256) {
        return den == 0 ? 0 : Math.mulDiv(num, 10_000, den);
    }

    function _lossBps(uint256 invested, uint256 got) internal pure returns (int256) {
        if (invested == 0) return 0;
        return (int256(invested) - int256(got)) * 10_000 / int256(invested);
    }

    /// @dev Replace the vault's oracle with a mock holding the CURRENT oracle ratio (keeps it fresh across vm.warp).
    function _etchFreshOracle() internal returns (uint256 ratio) {
        ratio = Math.mulDiv(ITAOracle(oracleAddr).quotePairToAsset(pUnit), 1e18, aUnit);
        _etchOracleWithRatio(ratio);
    }

    function _etchOracleWithRatio(uint256 ratio) internal {
        TAMockOracle m = new TAMockOracle(address(asset), address(paired), aUnit, pUnit);
        vm.etch(oracleAddr, address(m).code);
        TAMockOracle(oracleAddr).setRatio(ratio);
    }

    /// @dev asset-per-paired ratio (1e18) implied by the pool at `tick` (asset is token1, paired token0 for both vaults).
    function _ratioAtTick(int24 tick) internal view returns (uint256) {
        uint256 s = TickMath.getSqrtRatioAtTick(tick);
        uint256 p1e18 = Math.mulDiv(s * s, 1e18, 1 << 192); // token1 per token0, raw units
        // raw -> decimals adjusted: asset per ONE paired = p * 10^pDec / 10^aDec; same 1e18 scale
        return Math.mulDiv(p1e18, pUnit, aUnit);
    }


    // ------------------------------------------------------------------ log formatting (console2 lacks mixed overloads)
    function _t(uint256 x) internal pure returns (string memory) {
        return vm.toString(x);
    }

    function _ti(int256 x) internal pure returns (string memory) {
        return vm.toString(x);
    }

    function _tb(bool x) internal pure returns (string memory) {
        return x ? "true" : "false";
    }

    function _ta(address x) internal pure returns (string memory) {
        return vm.toString(x);
    }

    // ------------------------------------------------------------------ error decoding
    function _err(bytes memory r) internal pure returns (string memory) {
        if (r.length < 4) return "empty-revert";
        bytes4 sel;
        assembly { sel := mload(add(r, 32)) }
        if (sel == bytes4(keccak256("Vault__PriceDeviation(int24,int24)"))) return "Vault__PriceDeviation";
        if (sel == bytes4(keccak256("Vault__OracleDeviation(uint256,uint256)"))) return "Vault__OracleDeviation";
        if (sel == bytes4(keccak256("Vault__PositionNeedsRebalance()"))) return "Vault__PositionNeedsRebalance";
        if (sel == bytes4(keccak256("Vault__InsufficientAssets(uint256,uint256)"))) return "Vault__InsufficientAssets";
        if (sel == bytes4(keccak256("Vault__InsufficientShares(uint256,uint256)"))) return "Vault__InsufficientShares";
        if (sel == bytes4(keccak256("Vault__ExcessiveLoss(uint256,uint256)"))) return "Vault__ExcessiveLoss";
        if (sel == bytes4(keccak256("Vault__DepositCapExceeded(uint256,uint256)"))) return "Vault__DepositCapExceeded";
        if (sel == bytes4(keccak256("Vault__NotRebalancer()"))) return "Vault__NotRebalancer";
        if (sel == bytes4(keccak256("Vault__ZeroAmount()"))) return "Vault__ZeroAmount";
        if (sel == bytes4(keccak256("Vault__InvalidOracle()"))) return "Vault__InvalidOracle";
        if (sel == bytes4(keccak256("OwnableUnauthorizedAccount(address)"))) return "OwnableUnauthorizedAccount";
        if (sel == bytes4(keccak256("EnforcedPause()"))) return "EnforcedPause";
        if (sel == bytes4(keccak256("ERC4626ExceededMaxRedeem(address,uint256,uint256)"))) return "ERC4626ExceededMaxRedeem";
        if (sel == bytes4(keccak256("ERC4626ExceededMaxWithdraw(address,uint256,uint256)"))) return "ERC4626ExceededMaxWithdraw";
        if (sel == bytes4(keccak256("Oracle__StaleAnswer(address,uint256)"))) return "Oracle__StaleAnswer";
        if (sel == bytes4(keccak256("Error(string)"))) {
            bytes memory tail = new bytes(r.length - 4);
            for (uint256 i; i < tail.length; ++i) tail[i] = r[i + 4];
            return string.concat("Error: ", abi.decode(tail, (string)));
        }
        if (sel == 0x4e487b71) return "Panic";
        return string.concat("sel:", vm.toString(bytes32(sel)));
    }

    function _short(bool ok, bytes memory err) internal pure returns (string memory) {
        return ok ? "ok" : _err(err);
    }
}

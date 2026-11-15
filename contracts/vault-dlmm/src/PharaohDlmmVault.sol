// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IPharaohDlmmVault} from "./IPharaohDlmmVault.sol";
import {IDLMMPair} from "./interfaces/IDLMMPair.sol";
import {IDLMMRouter} from "./interfaces/IDLMMRouter.sol";
import {IDLMMFactory} from "./interfaces/IDLMMFactory.sol";
import {IDLMMRewarder, IDLMMVoter, IDLMMRewarderBeacon} from "./interfaces/IDLMMRewarder.sol";
import {PharaohDlmmPairValidator} from "./PharaohDlmmPairValidator.sol";
import {IChainlinkFeed} from "./interfaces/IChainlinkFeed.sol";

/// @title PharaohDlmmVault
/// @notice ERC-4626 vault (asset USDC) over a 3-bin Pharaoh DLMM position, on the R3 ownership NAV, priced ONLY by two Chainlink USD feeds.
///         Spec: docs/deployment-handoffs/avalanche-pharaoh-dlmm-vault-spec.md. Interface: IPharaohDlmmVault (frozen). Notes: DEVIATIONS.md.
/// @dev EXIT RULE: `redeemInKind` and the pro-rata burn helper make no oracle read, no swap, no router call and consult no pause, guard, latch,
///      cooldown, keeper role or codehash pin. They call only the pair (`balanceOf`, `totalSupply`, `getBin`, `burn`) and the two ERC-20s.
///      `redeem`/`withdraw` (USDC out) additionally need the feeds and a router swap of the USDt leg.
contract PharaohDlmmVault is
    IPharaohDlmmVault,
    Initializable,
    ERC4626Upgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ constants
    uint256 private constant BPS = 10_000;
    uint256 private constant WAD = 1e18;
    uint8 private constant FEED_DECIMALS = 8;
    uint256 private constant ONE_USD = 1e8;
    uint256 private constant MAX_ID_SLIPPAGE = 2;
    uint256 private constant MAX_BAND_BINS = 3;

    // guard bits of guardState().reasons (see the interface)
    uint256 internal constant FEED_ASSET_STALE_OR_BAD = 1;
    uint256 internal constant FEED_PAIR_STALE_OR_BAD = 2;
    uint256 internal constant ASSET_LEG_OUT_OF_BAND = 4;
    uint256 internal constant PAIR_LEG_OUT_OF_BAND = 8;
    uint256 internal constant POOL_ORACLE_DEVIATION = 16;
    uint256 internal constant REWARDER_UNLINKED_OR_CODEHASH_CHANGED = 32;
    uint256 internal constant LATCHABLE_MASK = 15;
    // extra bits of rebalanceAllowed().reasonBits (above the guard bits)
    uint256 internal constant RB_NO_BAND = 64;
    uint256 internal constant RB_IN_RANGE = 128;
    uint256 internal constant RB_COOLDOWN = 256;
    uint256 internal constant RB_DAILY_CAP = 512;
    uint256 internal constant RB_LATCHED = 1024;
    uint256 internal constant RB_PAUSED = 2048;

    // ------------------------------------------------------------------ extra errors (not in the frozen interface; additive)
    error ZeroAddress();
    error ZeroAmount();
    error ZeroShares();
    error NotRebalancer();
    error FeedInvalid(uint8 which); // 1 asset feed, 2 pair feed
    error DeadlineExpired(uint256 deadline);
    error BandExists();
    error NothingToDeploy();
    error ExitFailed();

    event RebalancerUpdated(address indexed oldRebalancer, address indexed newRebalancer);

    // ------------------------------------------------------------------ immutables
    /// @dev implementation immutable: raising the cap above this needs a new implementation (a Safe-signed upgrade)
    uint256 public immutable DEPOSIT_CAP_CEILING;
    /// @dev stateless initialize-time validator, deployed by this implementation's constructor (part of the implementation, not a parameter)
    address private immutable VALIDATOR;

    // ------------------------------------------------------------------ storage (wiring, set once in initialize)
    IERC20 public tokenX; // pair order, from pair.getTokenX()
    IERC20 public tokenY;
    IERC20 public pairToken; // the non-asset leg (USDt)
    bool public assetIsX;
    address public pair;
    address public router;
    address public factory;
    address public rewarder;
    address public rewarderBeacon; // DLMMRewarderFactory, derived from rewarder.owner().dlmmRewarderFactory() at initialize and then fixed
    address public rewardToken; // PHAR
    bytes32 public rewarderImplCodehash;
    address public feedAsset;
    address public feedPair;
    uint16 public binStep;
    uint256 private assetScale; // 10**assetDecimals
    uint256 private pairScale;

    // band
    bool private _hasBand;
    uint24 private _lower;
    uint24 private _upper;

    // roles, params, state
    address public rebalancer;
    uint256 public depositCap;
    GuardParams private _gp;
    bool private _latched;
    uint48 public lastRebalanceAt;
    uint32 private _day;
    uint16 private _countToday;

    constructor() {
        DEPOSIT_CAP_CEILING = 200_000_000;
        VALIDATOR = address(new PharaohDlmmPairValidator());
        _disableInitializers();
    }

    // =====================================================================================================================
    // initialize: pair validation (PairValidationFailed(check) numbering is in DEVIATIONS.md)
    // =====================================================================================================================

    function initialize(InitParams calldata p) external initializer {
        if (p.depositCap > DEPOSIT_CAP_CEILING) revert CapAboveCeiling(p.depositCap, DEPOSIT_CAP_CEILING);

        __ERC20_init(p.name, p.symbol);
        __ERC4626_init(IERC20(p.asset));
        __Ownable_init(p.owner);
        __Pausable_init();
        __ReentrancyGuard_init();

        // every pair/router/rewarder/beacon/feed check runs in the validator (check numbers: see PharaohDlmmPairValidator); it reverts
        // PairValidationFailed(check) and the revert is bubbled unchanged
        (bool ok, bytes memory r) = VALIDATOR.staticcall(abi.encodeCall(PharaohDlmmPairValidator.validate, (p)));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 32), mload(r))
            }
        }
        (address tx_, address ty_, address beacon, address rt, uint8 aDec, uint8 pDec) =
            abi.decode(r, (address, address, address, address, uint8, uint8));

        tokenX = IERC20(tx_);
        tokenY = IERC20(ty_);
        pairToken = IERC20(p.pairToken);
        assetIsX = tx_ == p.asset;
        pair = p.pair;
        router = p.router;
        factory = p.factory;
        rewarder = p.rewarder;
        rewarderBeacon = beacon;
        rewardToken = rt;
        rewarderImplCodehash = p.rewarderImplCodehash;
        feedAsset = p.feedAsset;
        feedPair = p.feedPair;
        binStep = p.binStep;
        assetScale = 10 ** aDec;
        pairScale = 10 ** pDec;
        rebalancer = p.rebalancer;
        depositCap = p.depositCap;

        _setGuardParams(
            GuardParams({
                legBandBps: 50,
                maxFeedAge: 93_600,
                maxPoolOracleDevBps: 60,
                rebalanceCooldown: 120,
                maxRebalancesPerDay: 48,
                maxSwapBps: 6000,
                maxRebalanceLossBps: 50
            })
        );
        emit DepositCapSet(0, p.depositCap);
        emit RebalancerUpdated(address(0), p.rebalancer);

        // 13b: both feeds must be healthy at deployment
        (uint256 reasons,,) = _evaluate();
        if (reasons & (FEED_ASSET_STALE_OR_BAD | FEED_PAIR_STALE_OR_BAD) != 0) revert PairValidationFailed(13);

        // the vault starts PAUSED (blocks deposit, mint, openBand, rebalance; never exits). The owner unpauses after the read-backs.
        _pause();
    }

    modifier onlyRebalancer() {
        if (msg.sender != rebalancer) revert NotRebalancer();
        _;
    }

    // =====================================================================================================================
    // NAV (ownership NAV, Chainlink only) and ERC-4626
    // =====================================================================================================================

    /// @notice Ownership NAV in asset units: idle USDC + idle USDt + bin holdings (fees are inside bin reserves), the USDt leg valued with the two
    ///         Chainlink feeds. Reverts FeedInvalid when a feed is bad or stale (an out-of-band price does NOT revert it). Pending PHAR excluded.
    function totalAssets() public view override returns (uint256) {
        (uint256 pa, uint256 pp) = _prices();
        return _nav(pa, pp);
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (paused() || _latched) return 0;
        (uint256 reasons, uint256 pa, uint256 pp) = _evaluate();
        if (reasons != 0) return 0;
        uint256 nav = _nav(pa, pp);
        return nav >= depositCap ? 0 : depositCap - nav;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (maxAssets == 0) return 0;
        return _convertToShares(maxAssets, Math.Rounding.Floor);
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant whenNotPaused returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        _requireEntryOk();
        _checkCap(assets);
        shares = _convertToShares(assets, Math.Rounding.Floor);
        if (shares == 0) revert ZeroShares();
        _deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant whenNotPaused returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        _requireEntryOk();
        assets = _convertToAssets(shares, Math.Rounding.Ceil);
        _checkCap(assets);
        _deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice USDC out. NOTE: `previewRedeem`/`convertToAssets` OVERSTATE what is paid (they are the oracle NAV; the swap fee and the pool's standing
    ///         discount on the USDt part are charged to the redeemer). `withdraw(assets)` may likewise pay slightly LESS than `assets`. The redeemer's pro-rata slice is burned from the bins, its USDt part is swapped to USDC through the router with an oracle
    ///         minimum (`maxRebalanceLossBps`); the REDEEMER bears the swap cost; the spill onto other holders is bounded and tiny (the swap runs against the active bin, which can hold part of the vault's own band at a price off the oracle; MEASURED by W4: 12 wei on 30.8M units). Pays what is realised, so it
    ///         can be slightly below `previewRedeem` (swap fee plus the pool's standing discount). Not gated by pause, guard or latch. Needs the feeds
    ///         and pool depth; if either fails use `redeemInKind`.
    function redeem(uint256 shares, address receiver, address owner_) public override nonReentrant returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        uint256 maxShares = balanceOf(owner_);
        if (shares > maxShares) revert ERC4626ExceededMaxRedeem(owner_, shares, maxShares);
        (uint256 pa, uint256 pp) = _prices();
        assets = _payOutAsset(shares, receiver, owner_, pa, pp);
    }

    /// @notice Burns ceil(convertToShares(assets)) shares and pays what the slice realises in USDC (see `redeem`): may be slightly below `assets`.
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        (uint256 pa, uint256 pp) = _prices();
        shares = _convertToShares(assets, Math.Rounding.Ceil);
        uint256 maxShares = balanceOf(owner_);
        if (shares > maxShares) revert ERC4626ExceededMaxWithdraw(owner_, assets, _convertToAssets(maxShares, Math.Rounding.Floor));
        _payOutAsset(shares, receiver, owner_, pa, pp);
    }

    /// @notice Pro-rata exit paying BOTH tokens (amounts in pair X/Y order). NO oracle read, NO swap, NO router call. Not gated by pause, guard,
    ///         latch, cooldown, keeper or the rewarder pin. The only external dependencies are the pair (balanceOf, totalSupply, getBin, burn)
    ///         and the two tokens. If the pair's hook reverts, the pair's `burn` reverts (documented in the spec, section 3).
    function redeemInKind(uint256 shares, address receiver, address owner_)
        external
        nonReentrant
        returns (uint256 amountX, uint256 amountY)
    {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        uint256 supply = totalSupply();
        uint256 ownerShares = balanceOf(owner_);
        if (shares > ownerShares) revert ERC4626ExceededMaxRedeem(owner_, shares, ownerShares);
        if (msg.sender != owner_) _spendAllowance(owner_, msg.sender, shares);
        _burn(owner_, shares);
        (amountX, amountY) = _sliceOut(shares, supply, false);
        if (amountX == 0 && amountY == 0) revert ExitFailed();
        if (amountX != 0) tokenX.safeTransfer(receiver, amountX);
        if (amountY != 0) tokenY.safeTransfer(receiver, amountY);
        emit RedeemedInKind(owner_, receiver, shares, amountX, amountY);
    }

    function _payOutAsset(uint256 shares, address receiver, address owner_, uint256 pa, uint256 pp)
        private
        returns (uint256 paid)
    {
        uint256 supply = totalSupply();
        if (msg.sender != owner_) _spendAllowance(owner_, msg.sender, shares);
        _burn(owner_, shares);
        (uint256 x, uint256 y) = _sliceOut(shares, supply, false);
        (uint256 assetAmt, uint256 pairAmt) = assetIsX ? (x, y) : (y, x);
        paid = assetAmt;
        if (pairAmt != 0) {
            uint256 expectedOut = _pairToAsset(pairAmt, pa, pp);
            paid += _swap(pairToken, IERC20(asset()), pairAmt, _md(expectedOut, BPS - _gp.maxRebalanceLossBps, BPS), block.timestamp);
        }
        if (paid == 0) revert ExitFailed();
        IERC20(asset()).safeTransfer(receiver, paid);
        emit Withdraw(msg.sender, receiver, owner_, paid, shares);
    }

    /// @dev Burns `shares/supply` of the vault's bins (all of them when `all`) and returns that slice of the vault's tokens: the pro-rata share of the
    ///      idle balances (measured before the burn) plus the burn proceeds. No oracle, no router. Bins whose burn amount or proceeds round to zero are
    ///      skipped (the pair reverts a whole burn on LBPair__ZeroAmount / ZeroAmountsOut). The tokens stay in the vault; callers transfer.
    function _sliceOut(uint256 shares, uint256 supply, bool all) private returns (uint256 outX, uint256 outY) {
        bool full = all || shares == supply;
        outX = full ? tokenX.balanceOf(address(this)) : tokenX.balanceOf(address(this)) * shares / supply;
        outY = full ? tokenY.balanceOf(address(this)) : tokenY.balanceOf(address(this)) * shares / supply;
        if (!_hasBand) return (outX, outY);

        uint256 n = uint256(_upper) - uint256(_lower) + 1;
        uint256[] memory ids = new uint256[](n);
        uint256[] memory amts = new uint256[](n);
        uint256 k;
        bool any;
        for (uint256 i; i < n; ++i) {
            uint256 id = uint256(_lower) + i;
            (uint256 bal,) = _pv(abi.encodeCall(IDLMMPair.balanceOf, (address(this), id)));
            uint256 amt = full ? bal : bal * shares / supply;
            if (bal != amt) any = true; // a part of this bin stays in the vault
            if (amt == 0) continue;
            (uint256 binSupply,) = _pv(abi.encodeCall(IDLMMPair.totalSupply, (id)));
            (uint256 bx, uint256 by) = _pv(abi.encodeCall(IDLMMPair.getBin, (uint24(id))));
            if (bx * amt < binSupply && by * amt < binSupply) {
                any = true; // both proceeds would floor to zero (the pair reverts a zero-out bin): leave the dust
                continue;
            }
            ids[k] = id;
            amts[k] = amt;
            ++k;
        }
        if (k != 0) {
            assembly ("memory-safe") {
                mstore(ids, k)
                mstore(amts, k)
            }
            (bool ok, bytes memory r) = pair.call(abi.encodeCall(IDLMMPair.burn, (address(this), address(this), ids, amts)));
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(r, 32), mload(r))
                }
            }
            bytes32[] memory outs = abi.decode(r, (bytes32[]));
            for (uint256 j; j < outs.length; ++j) {
                uint256 w = uint256(outs[j]);
                outX += uint128(w);
                outY += w >> 128;
            }
        }
        if (full || !any) _hasBand = false;
    }

    /// @dev low-level pair view returning up to two words (reverts ExitFailed when the call fails or returns < 32 bytes)
    function _pv(bytes memory data) private view returns (uint256 a, uint256 b) {
        (bool ok, bytes memory r) = pair.staticcall(data);
        if (!ok || r.length < 32) revert ExitFailed();
        a = abi.decode(r, (uint256));
        if (r.length >= 64) (, b) = abi.decode(r, (uint256, uint256));
    }

    // =====================================================================================================================
    // Band: openBand (no band yet) and exit-triggered rebalance
    // =====================================================================================================================

    /// @notice First band from the idle assets (USDC and any idle USDt). Only when no band exists; the vault swaps the over-held leg itself to an
    ///         even value split (oracle minimum, <= maxSwapBps of NAV), adds 3 bins (-1,0,+1) around the active id.
    function openBand(
        uint24 expectedActiveId,
        uint24 idSlippage,
        uint256 swapMinOut,
        uint256 amountXMin,
        uint256 amountYMin,
        uint256 deadline
    ) external onlyRebalancer nonReentrant whenNotPaused {
        _checkDeadline(deadline);
        _requireEntryOk();
        if (_hasBand) revert BandExists();
        if (idSlippage > MAX_ID_SLIPPAGE) revert ParamOutOfBounds();
        _checkActive(expectedActiveId, idSlippage);
        (uint256 pa, uint256 pp) = _prices();
        uint256 navBefore = _nav(pa, pp);

        // even the idle inventory by value
        (uint256 aAmt, uint256 pAmt) = _idle();
        uint256 pv = _pairToAsset(pAmt, pa, pp);
        if (aAmt > pv + 1) {
            _guardedSwap(IERC20(asset()), pairToken, (aAmt - pv) / 2, swapMinOut, navBefore, pa, pp, deadline);
        } else if (pv > aAmt + 1) {
            uint256 amountIn = Math.min(_assetToPair((pv - aAmt) / 2, pa, pp), pAmt);
            _guardedSwap(pairToken, IERC20(asset()), amountIn, swapMinOut, navBefore, pa, pp, deadline);
        }

        (uint24 active, uint256 addedX, uint256 addedY) = _addBand(expectedActiveId, idSlippage, amountXMin, amountYMin, deadline);
        _checkNavLoss(navBefore, pa, pp);
        // no cap post-check: openBand takes in no funds; the cap is enforced where assets enter (deposit, mint, maxDeposit, maxMint)
        emit BandOpened(_lower, _upper, active, addedX, addedY);
    }

    function rebalance(
        uint24 expectedActiveId,
        uint24 idSlippage,
        bool swapXForY,
        uint256 swapIn,
        uint256 swapMinOut,
        uint256 amountXMin,
        uint256 amountYMin,
        uint256 deadline
    ) external onlyRebalancer nonReentrant whenNotPaused {
        _checkDeadline(deadline);
        if (idSlippage > MAX_ID_SLIPPAGE) revert ParamOutOfBounds();
        if (!_hasBand) revert NoBand();
        {
            uint24 a = _activeId();
            if (a >= _lower && a <= _upper) revert NotOutOfRange(a, _lower, _upper);
        }
        _requireEntryOk(); // latched -> GuardLatched, live unsafe -> GuardUnsafe(reasons)
        uint256 readyAt = uint256(lastRebalanceAt) + _gp.rebalanceCooldown;
        if (lastRebalanceAt != 0 && block.timestamp < readyAt) revert CooldownActive(readyAt);
        uint32 today = uint32(block.timestamp / 1 days);
        if (_day != today) {
            _day = today;
            _countToday = 0;
        }
        if (_countToday >= _gp.maxRebalancesPerDay) revert DailyRebalanceCapReached();
        _checkActive(expectedActiveId, idSlippage);

        (uint256 pa, uint256 pp) = _prices();
        uint256 navBefore = _nav(pa, pp);
        uint24 oldLower = _lower;
        uint24 oldUpper = _upper;

        _sliceOut(0, 1, true); // burn the whole band (and keep every idle token in the vault)

        uint256 swapOut = _guardedSwap(
            swapXForY ? tokenX : tokenY, swapXForY ? tokenY : tokenX, swapIn, swapMinOut, navBefore, pa, pp, deadline
        );
        (uint24 active,,) = _addBand(expectedActiveId, idSlippage, amountXMin, amountYMin, deadline);
        _checkNavLoss(navBefore, pa, pp);

        lastRebalanceAt = uint48(block.timestamp);
        ++_countToday;
        emit Rebalanced(
            oldLower, oldUpper, _lower, _upper, active, swapXForY, swapIn, swapOut, navBefore, _nav(pa, pp)
        );
    }

    /// @dev swap with the vault-side limits: swapIn <= maxSwapBps of NAV, min out >= oracle-implied out minus maxRebalanceLossBps
    function _guardedSwap(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountIn,
        uint256 swapMinOut,
        uint256 nav,
        uint256 pa,
        uint256 pp,
        uint256 deadline
    ) private returns (uint256 amountOut) {
        if (amountIn == 0) return 0;
        uint256 maxIn = _md(nav, _gp.maxSwapBps, BPS);
        uint256 inValue = address(tokenIn) == asset() ? amountIn : _pairToAsset(amountIn, pa, pp);
        if (inValue > maxIn) revert SwapTooLarge(inValue, maxIn);
        uint256 oracleOut = address(tokenIn) == asset() ? _assetToPair(amountIn, pa, pp) : _pairToAsset(amountIn, pa, pp);
        uint256 floorOut = _md(oracleOut, BPS - _gp.maxRebalanceLossBps, BPS);
        amountOut = _swap(tokenIn, tokenOut, amountIn, swapMinOut > floorOut ? swapMinOut : floorOut, deadline);
    }

    function _swap(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn, uint256 minOut, uint256 deadline)
        private
        returns (uint256 amountOut)
    {
        uint256[] memory steps = new uint256[](1);
        steps[0] = binStep;
        IDLMMRouter.Version[] memory versions = new IDLMMRouter.Version[](1);
        versions[0] = IDLMMRouter.Version.V2_1;
        address[] memory path = new address[](2);
        path[0] = address(tokenIn);
        path[1] = address(tokenOut);
        tokenIn.forceApprove(router, amountIn);
        amountOut = IDLMMRouter(router).swapExactTokensForTokens(
            amountIn, minOut, IDLMMRouter.Path({pairBinSteps: steps, versions: versions, tokenPath: path}), address(this), deadline
        );
        tokenIn.forceApprove(router, 0);
    }

    /// @dev adds all token balances of the vault as 3 bins (-1,0,+1) around the CURRENT active id with an even value split: Y over (-1: 2/3, 0: 1/3),
    ///      X over (0: 1/3, +1: 2/3). Bins that would receive nothing are dropped (the pair reverts a zero-share bin); leftovers are refunded to the vault.
    function _addBand(uint24 expectedActiveId, uint24 idSlippage, uint256 amountXMin, uint256 amountYMin, uint256 deadline)
        private
        returns (uint24 active, uint256 addedX, uint256 addedY)
    {
        _checkActive(expectedActiveId, idSlippage);
        active = _activeId();
        uint256 bx = tokenX.balanceOf(address(this));
        uint256 by = tokenY.balanceOf(address(this));
        if (bx == 0 && by == 0) revert NothingToDeploy();

        uint256[3] memory dX = [uint256(0), 333333333333333334, 666666666666666666];
        uint256[3] memory dY = [uint256(666666666666666666), 333333333333333334, 0];
        int256[] memory deltas = new int256[](MAX_BAND_BINS);
        uint256[] memory distX = new uint256[](MAX_BAND_BINS);
        uint256[] memory distY = new uint256[](MAX_BAND_BINS);
        uint256 k;
        for (uint256 i; i < MAX_BAND_BINS; ++i) {
            if (_md(bx, dX[i], WAD) == 0 && _md(by, dY[i], WAD) == 0) continue;
            deltas[k] = int256(i) - 1;
            distX[k] = dX[i];
            distY[k] = dY[i];
            ++k;
        }
        assembly ("memory-safe") {
            mstore(deltas, k)
            mstore(distX, k)
            mstore(distY, k)
        }

        tokenX.forceApprove(router, bx);
        tokenY.forceApprove(router, by);
        (addedX, addedY,,,,) = IDLMMRouter(router).addLiquidity(
            IDLMMRouter.LiquidityParameters({
                tokenX: address(tokenX),
                tokenY: address(tokenY),
                binStep: binStep,
                amountX: bx,
                amountY: by,
                amountXMin: amountXMin,
                amountYMin: amountYMin,
                activeIdDesired: active, // the REAL active id read after the inventory swap: ids and distributions are built around it
                idSlippage: 0, // the caller's tolerance was applied above (ActiveIdMoved); the router must see exactly the id used here
                deltaIds: deltas,
                distributionX: distX,
                distributionY: distY,
                to: address(this),
                refundTo: address(this),
                deadline: deadline
            })
        );
        tokenX.forceApprove(router, 0);
        tokenY.forceApprove(router, 0);

        _lower = active - 1;
        _upper = active + 1;
        _hasBand = true;
    }

    function _checkNavLoss(uint256 navBefore, uint256 pa, uint256 pp) private view {
        uint256 navAfter = _nav(pa, pp);
        if (navAfter * BPS < navBefore * (BPS - _gp.maxRebalanceLossBps)) revert NavLossTooLarge(navBefore, navAfter);
    }

    function _checkActive(uint24 expected, uint24 slip) private view {
        uint24 a = _activeId();
        uint256 diff = a > expected ? a - expected : expected - a;
        if (diff > slip) revert ActiveIdMoved(expected, a, slip);
    }

    function _checkDeadline(uint256 deadline) private view {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
    }

    // =====================================================================================================================
    // Rewards
    // =====================================================================================================================

    /// @notice Claims PHAR from the rewarder for the band ids (the rewarder settled earlier bins at their burn) and forwards the vault's whole PHAR
    ///         balance to the owner, as R3 does. Rebalancer or owner. Emits PharHarvested; the share price does not include pending PHAR.
    function harvestRewards() external nonReentrant {
        if (msg.sender != rebalancer && msg.sender != owner()) revert NotRebalancer();
        uint256 n = _hasBand ? uint256(_upper) - uint256(_lower) + 1 : 0;
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) ids[i] = uint256(_lower) + i;
        IDLMMRewarder(rewarder).claim(address(this), ids);
        IERC20 phar = IERC20(rewardToken);
        uint256 amount = phar.balanceOf(address(this));
        if (amount != 0) phar.safeTransfer(owner(), amount);
        // totalAssets in the event is 0 when a feed is bad: a harvest must not depend on the feeds
        (bool ok, uint256 nav) = _tryNav();
        emit PharHarvested(address(phar), amount, totalSupply(), ok ? nav : 0);
    }

    // =====================================================================================================================
    // Guard
    // =====================================================================================================================

    function guardState() external view returns (bool unsafe, bool latched, uint256 reasons) {
        (reasons,,) = _evaluate();
        return (reasons != 0, _latched, reasons);
    }

    function tripGuard() external {
        (uint256 reasons,,) = _evaluate();
        uint256 latchable = reasons & LATCHABLE_MASK;
        if (latchable == 0) revert GuardUnsafe(0);
        _latched = true;
        emit GuardTripped(msg.sender, latchable);
    }

    function clearGuard() external onlyOwner {
        (uint256 reasons,,) = _evaluate();
        if (reasons != 0) revert GuardStillUnsafe(reasons);
        _latched = false;
        emit GuardCleared(msg.sender);
    }

    function rebalanceAllowed() external view returns (bool ok, uint256 reasonBits, uint256 readyAt) {
        (uint256 reasons,,) = _evaluate();
        reasonBits = reasons;
        if (paused()) reasonBits |= RB_PAUSED;
        if (_latched) reasonBits |= RB_LATCHED;
        if (!_hasBand) {
            reasonBits |= RB_NO_BAND;
        } else {
            uint24 a = _activeId();
            if (a >= _lower && a <= _upper) reasonBits |= RB_IN_RANGE;
        }
        readyAt = lastRebalanceAt == 0 ? 0 : uint256(lastRebalanceAt) + _gp.rebalanceCooldown;
        if (block.timestamp < readyAt) reasonBits |= RB_COOLDOWN;
        if (rebalancesToday() >= _gp.maxRebalancesPerDay) {
            reasonBits |= RB_DAILY_CAP;
            uint256 nextDay = (block.timestamp / 1 days + 1) * 1 days;
            if (nextDay > readyAt) readyAt = nextDay;
        }
        ok = reasonBits == 0;
    }

    function guardParams() external view returns (GuardParams memory) {
        return _gp;
    }

    function rebalancesToday() public view returns (uint16) {
        return _day == uint32(block.timestamp / 1 days) ? _countToday : 0;
    }

    function bandState() external view returns (uint24 lowerId, uint24 upperId, uint24 activeId, bool hasBand, bool outOfRange) {
        lowerId = _lower;
        upperId = _upper;
        hasBand = _hasBand;
        (bool ok, uint256 w) = _word(pair, abi.encodeCall(IDLMMPair.getActiveId, ()));
        activeId = ok ? uint24(w) : 0;
        outOfRange = _hasBand && (activeId < _lower || activeId > _upper);
    }

    /// @dev Live guard evaluation. Never reverts: every external read is a low-level staticcall with a length check. `pa`/`pp` (8-decimal USD) are
    ///      only meaningful when the corresponding feed bit is not set.
    function _evaluate() private view returns (uint256 reasons, uint256 pa, uint256 pp) {
        (uint256[2] memory px, uint256 okMask, uint256 hasMask) = _feeds();
        pa = px[0];
        pp = px[1];
        if (okMask & 1 == 0) reasons |= FEED_ASSET_STALE_OR_BAD;
        if (okMask & 2 == 0) reasons |= FEED_PAIR_STALE_OR_BAD;
        uint256 band = uint256(_gp.legBandBps) * ONE_USD;
        if (hasMask & 1 != 0 && _absDiff(pa, ONE_USD) * BPS > band) reasons |= ASSET_LEG_OUT_OF_BAND;
        if (hasMask & 2 != 0 && _absDiff(pp, ONE_USD) * BPS > band) reasons |= PAIR_LEG_OUT_OF_BAND;
        if (okMask == 3 && _poolDeviates(pa, pp)) reasons |= POOL_ORACLE_DEVIATION;
        if (_rewarderBroken()) reasons |= REWARDER_UNLINKED_OR_CODEHASH_CHANGED;
    }

    /// @dev both feeds in one place: price[i] = answer (0 when it is <= 0 or the read failed); okMask bit i = answer > 0, round complete and not
    ///      older than maxFeedAge; hasMask bit i = answer > 0. Never reverts (staticcall with a length check, no range-checked decode).
    function _feeds() private view returns (uint256[2] memory price, uint256 okMask, uint256 hasMask) {
        uint256 maxAge = _gp.maxFeedAge;
        for (uint256 i; i < 2; ++i) {
            (bool s, bytes memory r) = (i == 0 ? feedAsset : feedPair).staticcall(abi.encodeCall(IChainlinkFeed.latestRoundData, ()));
            if (!s || r.length < 160) continue;
            (uint256 roundId, int256 answer,, uint256 updatedAt, uint256 answeredInRound) =
                abi.decode(r, (uint256, int256, uint256, uint256, uint256));
            if (answer <= 0) continue;
            price[i] = uint256(answer);
            hasMask |= 1 << i;
            if (updatedAt == 0 || answeredInRound < roundId) continue;
            if (updatedAt <= block.timestamp && block.timestamp - updatedAt > maxAge) continue;
            okMask |= 1 << i;
        }
    }

    /// @dev pool active-bin price (Y per X, human units) vs the oracle ratio; any failure to read counts as a deviation
    function _poolDeviates(uint256 pa, uint256 pp) private view returns (bool) {
        (bool ok, uint256 w) = _word(pair, abi.encodeCall(IDLMMPair.getActiveId, ()));
        if (!ok) return true;
        int256 k = int256(uint256(uint24(w))) - int256(uint256(1) << 23);
        uint256 absK = k < 0 ? uint256(-k) : uint256(k);
        if (absK > 4096) return true; // more than ~+-40 % at 1 bp: not a peg
        uint256 pw = _pow1e18(WAD + (uint256(binStep) * WAD) / BPS, absK);
        uint256 raw = k < 0 ? _md(WAD, WAD, pw) : pw; // Y_raw per X_raw, 1e18
        // human Y per X = raw * 10^dX / 10^dY
        uint256 scaleX = assetIsX ? assetScale : pairScale;
        uint256 scaleY = assetIsX ? pairScale : assetScale;
        uint256 poolPrice = _md(raw, scaleX, scaleY);
        uint256 priceX = assetIsX ? pa : pp;
        uint256 priceY = assetIsX ? pp : pa;
        uint256 oracleRatio = _md(priceX, WAD, priceY); // Y per X
        return _absDiff(poolPrice, oracleRatio) * BPS > uint256(_gp.maxPoolOracleDevBps) * oracleRatio;
    }

    function _rewarderBroken() private view returns (bool) {
        (bool ok, uint256 hooks) = _word(pair, abi.encodeCall(IDLMMPair.getLBHooksParameters, ()));
        if (!ok || address(uint160(hooks)) != rewarder) return true;
        (ok, hooks) = _word(rewarder, abi.encodeCall(IDLMMRewarder.isLinked, ()));
        if (!ok || hooks != 1) return true;
        (ok, hooks) = _word(rewarderBeacon, abi.encodeCall(IDLMMRewarderBeacon.implementation, ()));
        if (!ok) return true;
        address impl = address(uint160(hooks));
        return impl.codehash != rewarderImplCodehash;
    }

    function _word(address target, bytes memory data) private view returns (bool ok, uint256 w) {
        (bool s, bytes memory r) = target.staticcall(data);
        if (!s || r.length < 32) return (false, 0);
        w = abi.decode(r, (uint256));
        ok = true;
    }

    function _pow1e18(uint256 base, uint256 e) private pure returns (uint256 result) {
        result = WAD;
        while (e != 0) {
            if (e & 1 == 1) result = _md(result, base, WAD);
            base = _md(base, base, WAD);
            e >>= 1;
        }
    }

    function _requireEntryOk() private view {
        if (_latched) revert GuardLatched();
        (uint256 reasons,,) = _evaluate();
        if (reasons != 0) revert GuardUnsafe(reasons);
    }

    function _checkCap(uint256 assets) private view {
        uint256 afterAssets = totalAssets() + assets;
        if (afterAssets > depositCap) revert CapExceeded(depositCap, afterAssets);
    }

    // =====================================================================================================================
    // Administration
    // =====================================================================================================================

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setRebalancer(address r) external onlyOwner {
        if (r == address(0)) revert ZeroAddress();
        emit RebalancerUpdated(rebalancer, r);
        rebalancer = r;
    }

    function setDepositCap(uint256 newCap) external onlyOwner {
        if (newCap > DEPOSIT_CAP_CEILING) revert CapAboveCeiling(newCap, DEPOSIT_CAP_CEILING);
        emit DepositCapSet(depositCap, newCap);
        depositCap = newCap;
    }

    function setGuardParams(GuardParams calldata p) external onlyOwner {
        _setGuardParams(p);
    }

    function _setGuardParams(GuardParams memory p) private {
        if (
            p.legBandBps < 10 || p.legBandBps > 200 || p.maxFeedAge < 3_600 || p.maxFeedAge > 172_800
                || p.maxPoolOracleDevBps < 20 || p.maxPoolOracleDevBps > 300 || p.rebalanceCooldown < 111
                || p.rebalanceCooldown > 3_600 || p.maxRebalancesPerDay < 4 || p.maxRebalancesPerDay > 96
                || p.maxSwapBps < 1 || p.maxSwapBps > 10_000 || p.maxRebalanceLossBps < 5 || p.maxRebalanceLossBps > 300
        ) revert ParamOutOfBounds();
        _gp = p;
        emit GuardParamsSet(p);
    }

    // =====================================================================================================================
    // Internal views and valuation helpers
    // =====================================================================================================================

    function _activeId() private view returns (uint24) {
        return IDLMMPair(pair).getActiveId();
    }

    /// @dev strict prices (8-dec USD): reverts when a feed is bad or stale. An out-of-band answer does not revert.
    function _prices() private view returns (uint256 pa, uint256 pp) {
        (uint256[2] memory px, uint256 okMask,) = _feeds();
        if (okMask & 1 == 0) revert FeedInvalid(1);
        if (okMask & 2 == 0) revert FeedInvalid(2);
        return (px[0], px[1]);
    }

    function _tryNav() private view returns (bool ok, uint256 nav) {
        (uint256[2] memory px, uint256 okMask,) = _feeds();
        if (okMask != 3) return (false, 0);
        return (true, _nav(px[0], px[1]));
    }

    function _nav(uint256 pa, uint256 pp) private view returns (uint256) {
        (uint256 aAmt, uint256 pAmt) = _holdings();
        return aAmt + _pairToAsset(pAmt, pa, pp);
    }

    function _idle() private view returns (uint256 aAmt, uint256 pAmt) {
        aAmt = IERC20(asset()).balanceOf(address(this));
        pAmt = pairToken.balanceOf(address(this));
    }

    /// @dev idle balances plus the vault's share of every band bin (floor)
    function _holdings() private view returns (uint256 aAmt, uint256 pAmt) {
        uint256 x = tokenX.balanceOf(address(this));
        uint256 y = tokenY.balanceOf(address(this));
        if (_hasBand) {
            for (uint256 id = _lower; id <= _upper; ++id) {
                (uint256 bal,) = _pv(abi.encodeCall(IDLMMPair.balanceOf, (address(this), id)));
                if (bal == 0) continue;
                (uint256 sup,) = _pv(abi.encodeCall(IDLMMPair.totalSupply, (id)));
                if (sup == 0) continue;
                (uint256 bx, uint256 by) = _pv(abi.encodeCall(IDLMMPair.getBin, (uint24(id))));
                x += bx * bal / sup;
                y += by * bal / sup;
            }
        }
        (aAmt, pAmt) = assetIsX ? (x, y) : (y, x);
    }

    function _pairToAsset(uint256 amount, uint256 pa, uint256 pp) private view returns (uint256) {
        return _md(amount, pp * assetScale, pa * pairScale);
    }

    function _assetToPair(uint256 amount, uint256 pa, uint256 pp) private view returns (uint256) {
        return _md(amount, pa * pairScale, pp * assetScale);
    }

    /// @dev plain floor(a*b/c). All operands are bounded far below 2^128 (token amounts of a vault capped at 200 USDC, LB shares of at most
    ///      2^128 * that, 1e18-scaled prices), so the product cannot overflow; this keeps the exit path free of the large `Math.mulDiv`.
    function _md(uint256 a, uint256 b, uint256 c) private pure returns (uint256) {
        return a * b / c;
    }

    function _absDiff(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    uint256[40] private __gap;
}

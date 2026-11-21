// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {ManipBase} from "./ManipBase.sol";
import {PharaohDlmmShareOracle} from "../../../contracts/PharaohDlmmShareOracle.sol";
import {GuardedAvalanchePriceOracle, IAvalanchePriceOracleSource} from "../../../contracts/margin/GuardedAvalanchePriceOracle.sol";
import {PriceOracle} from "../../../contracts/PriceOracle.sol";
import {PToken} from "../../../contracts/PToken.sol";

/// @dev stands in for the pToken of the bpPHAR-USDC market (the wrapper calls `isPToken()` and `underlying()` at construction, nothing else)
contract MockPToken2 {
    address public underlying;
    bool public constant isPToken = true;

    constructor(address u) {
        underlying = u;
    }
}

/// @dev the feed-configuration source of the REAL GuardedAvalanchePriceOracle: USDC/USD feed with the live maxAge (90,000 s), 8 feed decimals, 6 asset decimals
contract MockOracleSource is IAvalanchePriceOracleSource {
    AggregatorV3Interface public feed;
    uint32 public maxAge;
    address public usdc;
    address public pUsdc;

    constructor(AggregatorV3Interface f, uint32 maxAge_, address usdc_, address pUsdc_) {
        feed = f;
        maxAge = maxAge_;
        usdc = usdc_;
        pUsdc = pUsdc_;
    }

    function setMaxAge(uint32 m) external {
        maxAge = m;
    }

    function feeds(address asset) external view returns (AggregatorV3Interface, uint32, uint8, bool) {
        if (asset == usdc) return (feed, maxAge, 8, true);
        return (AggregatorV3Interface(address(0)), 0, 0, false);
    }

    function marketAsset(address pToken) external view returns (address) {
        return pToken == pUsdc ? usdc : address(0);
    }

    function assetDecimals(address) external pure returns (uint8) {
        return 6;
    }
}

/// @notice Fixture for the wrapper-v2 analysis: the REAL vault (ManipBase) + the REAL PharaohDlmmShareOracle in front of the REAL GuardedAvalanchePriceOracle
///         (source mocked, same feed and maxAge 90,000 as pUSDC). Time is driven by an explicit `clock` (Foundry 1.7.1 caches block.timestamp across vm.warp).
abstract contract V2Base is ManipBase {
    uint256 internal constant HAIRCUT_BPS = 300;
    uint256 internal constant WINDOW = 24 hours;
    uint256 internal constant GATE = 1 hours;
    uint256 internal constant UP_BPS = 200;
    uint256 internal constant VAULT_MAX_AGE = 93_600;
    uint256 internal constant BASE_USDC_MAX_AGE = 90_000;
    uint256 internal constant CLOSE_FACTOR_BPS = 5_000;

    PharaohDlmmShareOracle internal w2;
    GuardedAvalanchePriceOracle internal guarded;
    MockOracleSource internal src;
    MockPToken2 internal pS2;
    MockPToken2 internal pUsdcTok;
    uint256 internal clock;
    uint256 internal t0; // time at which the wrapper was constructed and both feeds were fresh

    function _setUpV2() internal {
        _setUpManip();
        pUsdcTok = new MockPToken2(address(usdc));
        src = new MockOracleSource(AggregatorV3Interface(address(feedUsdc)), uint32(BASE_USDC_MAX_AGE), address(usdc), address(pUsdcTok));
        guarded = new GuardedAvalanchePriceOracle(IAvalanchePriceOracleSource(address(src)));
        pS2 = new MockPToken2(proxyAddr);
        w2 = new PharaohDlmmShareOracle(PriceOracle(address(guarded)), address(pS2));
        clock = block.timestamp;
        t0 = clock;
    }

    // ------------------------------------------------------------------ time
    function _to(uint256 ts) internal {
        clock = ts;
        vm.warp(ts);
    }

    function _tick(uint256 dt) internal {
        uint256 ts = clock + dt;
        clock = ts;
        vm.warp(ts);
    }

    function _freshUsdc() internal {
        feedUsdc.setUpdatedAt(clock);
    }

    function _freshBoth() internal {
        feedUsdc.setUpdatedAt(clock);
        feedUsdt.setUpdatedAt(clock);
    }


    /// hourly keeper through the run-up (USDT feed dead since t0, USDC refreshed), then the first second in which the vault reverts
    function _toOutage() internal {
        for (uint256 k = 1; k <= 26; ++k) {
            _tick(3_600);
            _freshUsdc();
            _poke();
        }
        _tick(1);
        _freshUsdc();
        assertTrue(_usingFallback(), "outage started");
    }

    function _lender() internal returns (LenderV2 l) {
        l = new LenderV2(IERC20(address(usdc)), sh, w2, guarded, address(pS2), CF_BPS, BORROW_CAP, CASH_FLOOR, LIQ_INCENTIVE_BPS, CLOSE_FACTOR_BPS);
        usdc.mint(address(l), 274e6);
    }

    // ------------------------------------------------------------------ views
    function _p() internal view returns (uint256) {
        return w2.getUnderlyingPrice(PToken(address(pS2)));
    }

    function _stored() internal view returns (uint256) {
        return w2.lastGoodAssetsPerShare();
    }

    /// live vault leg (assets per whole share), 0 when the vault cannot answer
    function _live() internal view returns (uint256 l) {
        (l,,,,) = w2.shareState();
    }

    function _usingFallback() internal view returns (bool u) {
        (,,, u,) = w2.shareState();
    }

    /// the base-oracle USDC price (1e18 USD per USDC)
    function _usdcPx() internal view returns (uint256) {
        return guarded.getPrice(address(usdc));
    }

    /// USD (1e18) the controller credits for `shares` pToken-underlying units at the wrapper price
    function _valUsd18(uint256 shares) internal view returns (uint256) {
        return shares * _p() / 1e18;
    }

    /// max USDC (6 dec) borrowable against `shares` at `cfBps`: collateral USD x CF / pUSDC USD price
    function _maxBorrow(uint256 shares, uint256 cfBps) internal view returns (uint256) {
        uint256 px = _usdcPx();
        if (px == 0) return 0;
        return _valUsd18(shares) * cfBps / 10_000 * 1e6 / px;
    }

    function _ceil(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    /// mimic of what a keeper does: refresh the USDC feed (it has its own heartbeat), poke
    function _poke() internal returns (bool) {
        return w2.poke();
    }

    /// pure arithmetic of one accepted upward poke
    function _up(uint256 s) internal pure returns (uint256) {
        return s * (10_000 + UP_BPS) / 10_000;
    }

    /// sell USDt into the pool until the vault band is left (the vault then holds only USDt). External so that `block.timestamp` inside the router deadline is read fresh after warps.
    function pushUsdtIn() external {
        (uint24 lo,,,,) = v.bandState();
        uint256 guard;
        while (guard++ < 60) {
            if (pair.getActiveId() < lo) return;
            _swapAs(address(0x5AAB), false, 60_000e6);
        }
        revert("pushUsdtIn: band not left");
    }

    /// sell USDC into the pool until the vault band is left on the other side (the vault then holds only USDC)
    function pushUsdcIn() external {
        (, uint24 hi,,,) = v.bandState();
        uint256 guard;
        while (guard++ < 60) {
            if (pair.getActiveId() > hi) return;
            _swapAs(address(0x5AAB), true, 60_000e6);
        }
        revert("pushUsdcIn: band not left");
    }
}

/// @notice The lending side the analysis needs, with the controller's three checks that matter (CF x oracle value, strict borrow cap, cash floor), a close factor and an incentive.
///         Not the controller: the pToken exchange rate is abstracted to 1 (the dead seed pins it; see the doc, section 2).
contract LenderV2 {
    IERC20 public immutable usdc;
    IERC20 public immutable shares;
    PharaohDlmmShareOracle public immutable oracle;
    GuardedAvalanchePriceOracle public immutable guarded;
    address public immutable pShare;
    uint256 public immutable cfBps;
    uint256 public immutable cap;
    uint256 public immutable floor_;
    uint256 public immutable incentiveBps;
    uint256 public immutable closeBps;
    uint256 public totalBorrows;
    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;

    constructor(IERC20 usdc_, IERC20 shares_, PharaohDlmmShareOracle o, GuardedAvalanchePriceOracle g, address pShare_, uint256 cf, uint256 cap_, uint256 floor__, uint256 incentive, uint256 close) {
        usdc = usdc_;
        shares = shares_;
        oracle = o;
        guarded = g;
        pShare = pShare_;
        cfBps = cf;
        cap = cap_;
        floor_ = floor__;
        incentiveBps = incentive;
        closeBps = close;
    }

    function collValueUsd18(address u) public view returns (uint256) {
        return collateral[u] * oracle.getUnderlyingPrice(PToken(pShare)) / 1e18;
    }

    function debtValueUsd18(address u) public view returns (uint256) {
        return debt[u] * guarded.getPrice(address(usdc)) / 1e6;
    }

    /// (liquidity, shortfall) in USD 1e18, 0/0 impossible: a zero price anywhere is PRICE_ERROR in the controller (modelled as a revert)
    function liquidity(address u) public view returns (uint256 liq, uint256 shortfall) {
        require(oracle.getUnderlyingPrice(PToken(pShare)) != 0 && guarded.getPrice(address(usdc)) != 0, "PRICE_ERROR");
        uint256 power = collValueUsd18(u) * cfBps / 10_000;
        uint256 d = debtValueUsd18(u);
        if (power >= d) return (power - d, uint256(0));
        return (uint256(0), d - power);
    }

    function supply(uint256 amt) external {
        shares.transferFrom(msg.sender, address(this), amt);
        collateral[msg.sender] += amt;
    }

    function borrow(uint256 amt) external {
        debt[msg.sender] += amt;
        totalBorrows += amt;
        (, uint256 sf) = liquidity(msg.sender);
        require(sf == 0, "insufficient liquidity");
        require(totalBorrows < cap, "market borrow cap reached");
        require(usdc.balanceOf(address(this)) >= floor_ + amt, "cash floor");
        usdc.transfer(msg.sender, amt);
    }

    /// liquidator repays `repay` USDC and seizes shares worth `incentive x repay` at the ORACLE price (limited to the collateral). Returns (shares seized, repaid)
    function liquidate(address borrower, uint256 repay) external returns (uint256 seized, uint256 repaid) {
        (, uint256 sf) = liquidity(borrower);
        require(sf > 0, "not liquidatable");
        require(repay <= debt[borrower] * closeBps / 10_000, "too much");
        usdc.transferFrom(msg.sender, address(this), repay);
        debt[borrower] -= repay;
        totalBorrows -= repay;
        uint256 repayUsd18 = repay * guarded.getPrice(address(usdc)) / 1e6;
        uint256 px = oracle.getUnderlyingPrice(PToken(pShare));
        seized = repayUsd18 * incentiveBps / 10_000 * 1e18 / px;
        if (seized > collateral[borrower]) seized = collateral[borrower];
        collateral[borrower] -= seized;
        shares.transfer(msg.sender, seized);
        return (seized, repay);
    }
}

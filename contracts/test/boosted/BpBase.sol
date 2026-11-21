// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {Peridot} from "../../contracts/Governance/Peridot.sol";
import {Unitroller} from "../../contracts/Unitroller.sol";
import {Peridottroller} from "../../contracts/Peridottroller.sol";
import {PeridottrollerAvalanche} from "../../contracts/PeridottrollerAvalanche.sol";
import {PeridottrollerInterface} from "../../contracts/PeridottrollerInterface.sol";
import {InterestRateModel} from "../../contracts/InterestRateModel.sol";
import {PriceOracle} from "../../contracts/PriceOracle.sol";
import {PToken} from "../../contracts/PToken.sol";
import {PErc20} from "../../contracts/PErc20.sol";
import {PErc20Delegate} from "../../contracts/PErc20Delegate.sol";
import {PErc20Delegator} from "../../contracts/PErc20Delegator.sol";
import {ConfigurableJumpRateModelV2} from "../../contracts/ConfigurableJumpRateModelV2.sol";
import {AvalanchePriceOracle} from "../../contracts/margin/AvalanchePriceOracle.sol";
import {
    GuardedAvalanchePriceOracle,
    IAvalanchePriceOracleSource
} from "../../contracts/margin/GuardedAvalanchePriceOracle.sol";
import {PharaohDlmmShareOracle} from "../../contracts/PharaohDlmmShareOracle.sol";
import {PharaohBoostedDelegate} from "../../contracts/boosted/PharaohBoostedDelegate.sol";
import {PharaohTestAsset, PharaohTestFeed} from "../mocks/PharaohBoostedMocks.sol";

/// @notice Controllable stand-in for the Peridot Pharaoh DLMM vault (ERC-4626 share token, 6 decimals, asset = USDC).
/// @dev Only what the delegate, the oracle wrapper and the tests touch is implemented. `assetsPerWholeShare` is the
///      number of asset base units that one whole share (10^decimals share base units) converts to. The live vault
///      REVERTS `totalAssets()` (and therefore `convertToAssets`) when a Chainlink guard trips; `convertReverts`
///      models that, and `assetOverride` models a vault whose asset() changes under the wrapper.
contract BpDlmmVaultMock {
    string public name = "Peridot Pharaoh DLMM USDC/USDt Vault";
    string public symbol = "pdlmm-USDC";
    uint8 public constant decimals = 6;

    address private immutable _asset;
    address public assetOverride;
    uint256 public totalSupply;
    uint256 public assetsPerWholeShare = 1e6; // 1.000000 USDC per whole share, like the live vault at listing
    bool public convertReverts;
    bool public assetReverts;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(address asset_) {
        _asset = asset_;
    }

    function asset() external view returns (address) {
        require(!assetReverts, "vault asset unavailable");
        return assetOverride == address(0) ? _asset : assetOverride;
    }

    function setAssetsPerWholeShare(uint256 value) external {
        assetsPerWholeShare = value;
    }

    function setConvertReverts(bool state) external {
        convertReverts = state;
    }

    function setAssetReverts(bool state) external {
        assetReverts = state;
    }

    function setAssetOverride(address value) external {
        assetOverride = value;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        require(!convertReverts, "vault price unavailable");
        return (shares * assetsPerWholeShare) / 1e6;
    }

    function totalAssets() external view returns (uint256) {
        return convertToAssets(totalSupply);
    }

    /// @dev Test helper: mint share base units out of thin air (the mock holds no assets).
    function mintShares(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @dev Test helper: destroy share base units (models vault redemptions shrinking totalSupply).
    function burnShares(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @notice A non-PErc20 contract (no `underlying()`), used to probe oracle edge cases.
contract BpNotAMarket {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

/// @notice LOCAL (no fork, no RPC) replica of the live Avalanche pilot controller stack plus the planned
///         `bpPHAR-USDC` market and oracle wrapper. Every address, feed age and risk parameter below is the live value
///         from the brief (18 Nov 2026) unless marked PARAM. Nothing here signs or broadcasts.
///
///         Live pilot replicated: Unitroller + `PeridottrollerAvalanche`; pWAVAX (CF 30%, borrow paused); pUSDC (CF 0,
///         borrow cap 200 USDC, cash floor 50 USDC, borrow enabled); close factor 50%; incentive 108%; reserve factor 10%;
///         `GuardedAvalanchePriceOracle` over `AvalanchePriceOracle` with maxAge 1200 (AVAX) and 90000 (USDC).
///         Rate model parameters (PARAM): the live rate model 0xe5a8... could not be found in the repo scripts, so
///         `ConfigurableJumpRateModelV2(31_536_000, 2%, 10%, 100%, 80%)` from the Fuji/Robinhood deploy scripts is used.
///         It only affects interest accrual; the tests stay inside one block unless they say otherwise.
///
///         All wrapper / delegate construction is concentrated in `_deployWrapper`, `_deployShareMarket` and
///         `_listShareMarket`, so re-syncing with a changed wrapper or delegate is a one-place edit.
abstract contract BpBase is Test {
    // ---------------------------------------------------------------- live constants
    uint32 internal constant AVAX_MAX_AGE = 1_200;
    uint32 internal constant USDC_MAX_AGE = 90_000;
    uint256 internal constant USDC_BORROW_CAP = 200e6;
    uint256 internal constant USDC_CASH_FLOOR = 50e6;
    uint256 internal constant CF_WAVAX = 0.30e18;
    uint256 internal constant CF_SHARE = 0.50e18;
    uint256 internal constant RESERVE_FACTOR = 0.10e18;
    uint256 internal constant CLOSE_FACTOR = 0.50e18;
    uint256 internal constant INCENTIVE = 1.08e18;
    uint256 internal constant PROTOCOL_SEIZE_SHARE = 2.8e16; // PTokenInterfaces constant
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // controller / market error codes (ErrorReporter.sol)
    uint256 internal constant ERR_PRICE = 13; // Error.PRICE_ERROR
    uint256 internal constant ERR_INSUFFICIENT_LIQUIDITY = 4;
    uint256 internal constant ERR_INSUFFICIENT_SHORTFALL = 3;
    uint256 internal constant ERR_TOO_MUCH_REPAY = 17;

    // PARAM: listing parameters of the share market
    uint256 internal constant SHARE_INITIAL_EXCHANGE_RATE = 2e14; // 6-dec underlying -> 8-dec pToken, same as pUSDC
    uint256 internal constant VAULT_SUPPLY_AT_LISTING = 17_000_000; // live: 17 whole shares
    uint256 internal constant MIN_VAULT_SUPPLY = 1_000_000; // PARAM minimumVaultSupply passed to the delegate
    uint256 internal constant SEED = 1_000_000; // PARAM permanent seed, share base units (1 whole share)

    address internal constant LP = address(0x1001);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201); // liquidator
    address internal constant SEEDER = address(0x5EED);
    address internal constant ATTACKER = address(0xBADD);
    address internal constant VICTIM = address(0x71C71);

    // ---------------------------------------------------------------- stack
    PharaohTestAsset internal usdc;
    PharaohTestAsset internal wavax;
    BpDlmmVaultMock internal vault;
    PharaohTestFeed internal avaxFeed;
    PharaohTestFeed internal usdcFeed;
    Peridot internal peridot;
    AvalanchePriceOracle internal inner; // source oracle 0x74eB...
    GuardedAvalanchePriceOracle internal old; // the live controller oracle 0x7BAB...
    PharaohDlmmShareOracle internal wrapper;
    Unitroller internal unitroller;
    Peridottroller internal controller;
    ConfigurableJumpRateModelV2 internal irm;
    PErc20Delegate internal plainDelegate;
    PharaohBoostedDelegate internal bpDelegate;
    PErc20Delegator internal pWavax;
    PErc20Delegator internal pUsdc;
    PErc20Delegator internal bp; // bpPHAR-USDC

    bytes internal lastRevert;

    function setUp() public virtual {
        _deployPilot();
        _deployVault();
        _deployShareMarket();
        _deployWrapper();
    }

    // ================================================================ pilot (no share market yet)
    function _deployPilot() internal {
        vm.warp(1_800_000_000); // far from 0 so `block.timestamp - maxAge` never underflows
        vm.chainId(43_114); // PeridottrollerAvalanche only deploys on Avalanche C-Chain
        usdc = new PharaohTestAsset("USD Coin", "USDC", 6);
        wavax = new PharaohTestAsset("Wrapped AVAX", "WAVAX", 18);
        avaxFeed = new PharaohTestFeed(8, 20e8); // $20.00
        usdcFeed = new PharaohTestFeed(8, 1e8); // $1.00

        inner = new AvalanchePriceOracle(address(this));
        inner.configureFeed(address(wavax), address(avaxFeed), AVAX_MAX_AGE);
        inner.configureFeed(address(usdc), address(usdcFeed), USDC_MAX_AGE);
        old = new GuardedAvalanchePriceOracle(IAvalanchePriceOracleSource(address(inner)));

        peridot = new Peridot(address(this));
        unitroller = new Unitroller();
        PeridottrollerAvalanche impl = new PeridottrollerAvalanche(address(peridot), false);
        require(unitroller._setPendingImplementation(address(impl)) == 0, "impl");
        impl._become(unitroller);
        controller = Peridottroller(address(unitroller));

        irm = new ConfigurableJumpRateModelV2(31_536_000, 0.02e18, 0.1e18, 1e18, 0.8e18, address(this));
        plainDelegate = new PErc20Delegate();
        require(controller._setPriceOracle(PriceOracle(address(old))) == 0, "oracle");
        require(controller._setCloseFactor(CLOSE_FACTOR) == 0, "close factor");
        require(controller._setLiquidationIncentive(INCENTIVE) == 0, "incentive");
        require(controller._setPauseGuardian(address(this)) == 0, "guardian");

        pWavax = _plainMarket(address(wavax), 2e26, "Peridot Wrapped AVAX", "pWAVAX");
        pUsdc = _plainMarket(address(usdc), 2e14, "Peridot USD Coin", "pUSDC");
        require(controller._supportMarket(PErc20(address(pWavax))) == 0, "list pWAVAX");
        require(controller._supportMarket(PErc20(address(pUsdc))) == 0, "list pUSDC");
        require(PErc20(address(pWavax))._setReserveFactor(RESERVE_FACTOR) == 0, "rf w");
        require(PErc20(address(pUsdc))._setReserveFactor(RESERVE_FACTOR) == 0, "rf u");
        inner.registerMarket(address(pWavax), address(wavax));
        inner.registerMarket(address(pUsdc), address(usdc));
        require(controller._setCollateralFactor(PToken(address(pWavax)), CF_WAVAX) == 0, "cf w");
        // pUSDC CF stays 0 (live)
        controller._setBorrowPaused(PToken(address(pWavax)), true); // live: pWAVAX borrow paused
        PErc20(address(pWavax))._setFlashLoansPaused(true);
        PErc20(address(pUsdc))._setFlashLoansPaused(true);
        PToken[] memory ps = new PToken[](1);
        ps[0] = PToken(address(pUsdc));
        uint256[] memory caps = new uint256[](1);
        caps[0] = USDC_BORROW_CAP;
        controller._setMarketBorrowCaps(ps, caps);
        PeridottrollerAvalanche(address(controller))._setBorrowCashFloor(PToken(address(pUsdc)), USDC_CASH_FLOOR);

        // Liquidity the pilot's lenders provide: 300 USDC (so the 200 cap binds before the 50 floor), 100 WAVAX.
        _mintUnderlyingP(pUsdc, LP, 300e6);
        _mintUnderlyingP(pWavax, LP, 100e18);
    }

    function _plainMarket(address underlying, uint256 initialRate, string memory name_, string memory symbol_)
        internal
        returns (PErc20Delegator)
    {
        return new PErc20Delegator(
            underlying,
            PeridottrollerInterface(address(controller)),
            InterestRateModel(address(irm)),
            initialRate,
            name_,
            symbol_,
            8,
            payable(address(this)),
            address(plainDelegate),
            ""
        );
    }

    // ================================================================ wrapper + share market (edit here when A changes them)
    function _deployVault() internal {
        vault = new BpDlmmVaultMock(address(usdc));
        vault.mintShares(address(0x1ED6E2), VAULT_SUPPLY_AT_LISTING - 1_000_000); // "Ledger" 16,000,000
        vault.mintShares(DEAD, 1_000_000); // vault dead seed
    }

    /// @dev PharaohDlmmShareOracle: stateless, ownerless; constructor(baseOracle, market). It needs the market pToken to exist.
    function _deployWrapper() internal {
        wrapper = new PharaohDlmmShareOracle(PriceOracle(address(old)), address(bp));
    }

    /// @dev Deploys the share market (delegator + PharaohBoostedDelegate pinned to the mock vault). NOT listed.
    function _deployShareMarket() internal {
        bpDelegate = new PharaohBoostedDelegate();
        bp = new PErc20Delegator(
            address(vault),
            PeridottrollerInterface(address(controller)),
            InterestRateModel(address(irm)),
            SHARE_INITIAL_EXCHANGE_RATE,
            "Peridot Boosted Pharaoh DLMM USDC",
            "bpPHAR-USDC",
            8,
            payable(address(this)),
            address(bpDelegate),
            abi.encode(address(vault), MIN_VAULT_SUPPLY)
        );
    }

    /// @dev The ceremony order of tools/bp-dlmm-ceremony.sh (T1..T9), verified by BpListingOrderTest:
    ///      T1 swap controller oracle to the wrapper (bp still unlisted)  T2 borrow cap = 1 (works on an unlisted pToken)
    ///      T3 _supportMarket (CF 0, born priced)  T4 borrow pause  [flash loans are paused from birth by the delegate]
    ///      T5/T6 seed mint BY THE ADMIN (seed-first guard: outsiders cannot mint while supply is 0)
    ///      T7 mint pause  T8 transfer the whole seed to 0x...dEaD  T9 mint unpause (activation). CF stays 0.
    function _listShareMarket() internal {
        _listShareMarketNoSeed();
        _seedPermanent(SEED);
    }

    function _listShareMarketNoSeed() internal {
        require(controller._setPriceOracle(PriceOracle(address(wrapper))) == 0, "wrapper"); // T1
        PToken[] memory ps = new PToken[](1);
        ps[0] = PToken(address(bp));
        uint256[] memory caps = new uint256[](1);
        caps[0] = 1;
        controller._setMarketBorrowCaps(ps, caps); // T2
        require(controller._supportMarket(PErc20(address(bp))) == 0, "list bp"); // T3
        controller._setBorrowPaused(PToken(address(bp)), true); // T4
    }

    /// @dev Seed: the ADMIN mints `shares` (seed-first guard), mint pause, everything to the dead address, mint unpause.
    function _seedPermanent(uint256 shares) internal {
        vault.mintShares(address(this), shares);
        vault.approve(address(bp), shares);
        require(bp.mint(shares) == 0, "seed mint");
        uint256 pTokens = bp.balanceOf(address(this));
        controller._setMintPaused(PToken(address(bp)), true); // T7
        require(bp.transfer(DEAD, pTokens), "burn seed"); // T8
        controller._setMintPaused(PToken(address(bp)), false); // T9
    }

    // ================================================================ helpers
    function _mintUnderlyingP(PErc20Delegator p, address who, uint256 amount) internal returns (uint256 minted) {
        PharaohTestAsset token = PharaohTestAsset(PErc20(address(p)).underlying());
        token.mint(who, amount);
        uint256 before = p.balanceOf(who);
        vm.startPrank(who);
        token.approve(address(p), amount);
        require(p.mint(amount) == 0, "mint failed");
        vm.stopPrank();
        minted = p.balanceOf(who) - before;
    }

    /// @dev Gives `who` fresh share base units and supplies them to the share market. Returns pTokens minted.
    function _supplyShares(address who, uint256 shares) internal returns (uint256 minted) {
        vault.mintShares(who, shares);
        uint256 before = bp.balanceOf(who);
        vm.startPrank(who);
        vault.approve(address(bp), shares);
        require(bp.mint(shares) == 0, "mint shares failed");
        vm.stopPrank();
        minted = bp.balanceOf(who) - before;
    }

    function _enter(address who, address market) internal {
        address[] memory ms = new address[](1);
        ms[0] = market;
        vm.prank(who);
        uint256[] memory r = controller.enterMarkets(ms);
        require(r[0] == 0, "enter failed");
    }

    /// @dev Low-level call as `who`; `ok` = did not revert. `lastRevert` holds the revert data when it did.
    function _try(address who, address target, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.prank(who);
        (ok, ret) = target.call(data);
        lastRevert = ok ? bytes("") : ret;
    }

    function _selector(bytes memory ret) internal pure returns (bytes4 s) {
        if (ret.length >= 4) {
            assembly {
                s := mload(add(ret, 32))
            }
        }
    }

    /// @dev uint code argument of a custom error (e.g. BorrowPeridottrollerRejection(code)).
    function _errCode(bytes memory ret) internal pure returns (uint256 code) {
        if (ret.length >= 36) {
            assembly {
                code := mload(add(ret, 36))
            }
        }
    }

    function _reason(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 68 || _selector(ret) != 0x08c379a0) return "";
        bytes memory body = new bytes(ret.length - 4);
        for (uint256 i = 4; i < ret.length; i++) {
            body[i - 4] = ret[i];
        }
        return abi.decode(body, (string));
    }

    function _borrowUsdc(address who, uint256 amount) internal returns (bool ok, bytes memory ret) {
        return _try(who, address(pUsdc), abi.encodeWithSelector(PErc20.borrow.selector, amount));
    }

    function _redeemShares(address who, uint256 pTokens) internal returns (bool ok, bytes memory ret) {
        return _try(who, address(bp), abi.encodeWithSelector(PErc20.redeem.selector, pTokens));
    }

    function _repayUsdc(address who, uint256 amount) internal returns (bool ok, bytes memory ret) {
        usdc.mint(who, amount == type(uint256).max ? pUsdc.borrowBalanceCurrent(who) + 1 : amount);
        vm.prank(who);
        usdc.approve(address(pUsdc), type(uint256).max);
        return _try(who, address(pUsdc), abi.encodeWithSelector(PErc20.repayBorrow.selector, amount));
    }

    function _liquidate(address liquidator, address borrower, uint256 repay) internal returns (bool ok, bytes memory ret) {
        return _liquidateSeizing(liquidator, borrower, repay, address(bp));
    }

    function _liquidateSeizing(address liquidator, address borrower, uint256 repay, address collateral)
        internal
        returns (bool ok, bytes memory ret)
    {
        usdc.mint(liquidator, repay);
        vm.prank(liquidator);
        usdc.approve(address(pUsdc), repay);
        return _try(
            liquidator,
            address(pUsdc),
            abi.encodeWithSelector(PErc20.liquidateBorrow.selector, borrower, repay, collateral)
        );
    }

    function _price(PToken p) internal view returns (uint256) {
        return controller.oracle().getUnderlyingPrice(p);
    }

    function _staleUsdcFeed() internal {
        usdcFeed.setRound(1e8, block.timestamp - USDC_MAX_AGE - 1, 7, 7);
    }

    /// @dev Pins BOTH base feeds fresh at the EXPLICIT timestamp `ts` (use after `vm.warp(ts)`: Foundry 1.7.1 caches `block.timestamp`
    ///      inside the same function, so the caller passes its own variable). `avax8` is the AVAX/USD answer (8 decimals); USDC stays $1.
    function _pinFeeds(uint256 ts, int256 avax8) internal {
        avaxFeed.setRound(avax8, ts, 9, 9);
        usdcFeed.setRound(1e8, ts, 9, 9);
    }

    /// @dev Makes the BASE USDC feed stale relative to the explicit timestamp `ts` (not the vault: the vault mock is untouched).
    function _staleUsdcFeedAt(uint256 ts) internal {
        usdcFeed.setRound(1e8, ts - USDC_MAX_AGE - 1, 7, 7);
    }

    function _freshUsdcFeed() internal {
        usdcFeed.setRound(1e8, block.timestamp, 8, 8);
    }

    /// @dev Standard borrower: supplies `shares` of vault shares, enters bpPHAR, borrows `usdcAmount`.
    function _openBorrow(address who, uint256 shares, uint256 usdcAmount) internal {
        _supplyShares(who, shares);
        _enter(who, address(bp));
        (bool ok, bytes memory ret) = _borrowUsdc(who, usdcAmount);
        require(ok, string(abi.encodePacked("borrow failed: ", _reason(ret), " code ", vm.toString(_errCode(ret)))));
    }
}

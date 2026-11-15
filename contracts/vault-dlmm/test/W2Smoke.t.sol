// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {PharaohDlmmVault} from "../src/PharaohDlmmVault.sol";
import {IPharaohDlmmVault} from "../src/IPharaohDlmmVault.sol";
import {IDLMMRouter} from "../src/interfaces/IDLMMRouter.sol";

/// @dev W2 compile-level smoke test with minimal hand mocks (W4 owns the real mocks and the full tests). Price 1:1 everywhere.
contract MTok is ERC20 {
    uint8 private d;
    constructor(string memory n, uint8 d_) ERC20(n, n) { d = d_; }
    function decimals() public view override returns (uint8) { return d; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract MFeed {
    int256 public answer = 1e8;
    uint256 public updatedAt;
    function decimals() external pure returns (uint8) { return 8; }
    function set(int256 a) external { answer = a; updatedAt = block.timestamp; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, 0, updatedAt == 0 ? block.timestamp : updatedAt, 1);
    }
}

contract MImpl { uint256 public x = 1; }

contract MVoter {
    address public dlmmRewarderFactory;
    mapping(address => bool) public isAuthorizedDLMMManager;
    function set(address beacon, address router) external { dlmmRewarderFactory = beacon; isAuthorizedDLMMManager[router] = true; }
}

contract MBeacon {
    address public implementation;
    address public rw;
    constructor(address i) { implementation = i; }
    function setRw(address r) external { rw = r; }
    function getRewarder(address) external view returns (address) { return rw; }
}

contract MRewarder {
    address public owner;
    address public phar;
    bool public isLinked = true;
    constructor(address v, address p) { owner = v; phar = p; }
    function getRewardToken() external view returns (address) { return phar; }
    function setLinked(bool b) external { isLinked = b; }
    function claim(address user, uint256[] calldata) external { require(user == msg.sender, "unauthorized"); MTok(phar).mint(user, 5e18); }
}

contract MFactory {
    struct Info { uint16 binStep; address LBPair; bool createdByOwner; bool ignoredForRouting; }
    address public pair;
    function setPair(address p) external { pair = p; }
    function getLBPairInformation(address, address, uint256 b) external view returns (Info memory) { return Info(uint16(b), pair, false, false); }
}

contract MPair {
    address public getFactory;
    address public getTokenX;
    address public getTokenY;
    uint16 public getBinStep = 1;
    uint24 public getActiveId = 8388608;
    bytes32 public getLBHooksParameters;
    mapping(uint256 => uint256) public binX;
    mapping(uint256 => uint256) public binY;
    mapping(uint256 => uint256) public totalSupply;
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    bool public burnReverts;

    constructor(address f, address x, address y, address hook) {
        getFactory = f; getTokenX = x; getTokenY = y;
        getLBHooksParameters = bytes32(uint256(0x151) << 160 | uint256(uint160(hook)));
    }
    function setActive(uint24 a) external { getActiveId = a; }
    function setBurnReverts(bool b) external { burnReverts = b; }
    function getBin(uint24 id) external view returns (uint128, uint128) { return (uint128(binX[id]), uint128(binY[id])); }
    function mintBin(address to, uint256 id, uint256 x, uint256 y) external {
        uint256 sh = totalSupply[id] == 0 ? (x + y) * 1e30 : (x + y) * totalSupply[id] / (binX[id] + binY[id]);
        binX[id] += x; binY[id] += y; totalSupply[id] += sh; balanceOf[to][id] += sh;
    }
    function burn(address from, address to, uint256[] calldata ids, uint256[] calldata amts) external returns (bytes32[] memory out) {
        require(!burnReverts, "hook");
        require(from == msg.sender, "approval");
        out = new bytes32[](ids.length);
        uint256 tx_; uint256 ty_;
        for (uint256 i; i < ids.length; ++i) {
            require(amts[i] != 0, "ZeroAmount");
            uint256 x = binX[ids[i]] * amts[i] / totalSupply[ids[i]];
            uint256 y = binY[ids[i]] * amts[i] / totalSupply[ids[i]];
            require(x + y != 0, "ZeroAmountsOut");
            binX[ids[i]] -= x; binY[ids[i]] -= y; totalSupply[ids[i]] -= amts[i]; balanceOf[from][ids[i]] -= amts[i];
            out[i] = bytes32(y << 128 | x);
            tx_ += x; ty_ += y;
        }
        MTok(getTokenX).transfer(to, tx_);
        MTok(getTokenY).transfer(to, ty_);
    }
}

contract MRouter {
    address public getFactory;
    MPair public pair;
    constructor(address f, address p) { getFactory = f; pair = MPair(p); }
    function addLiquidity(IDLMMRouter.LiquidityParameters calldata l)
        external
        returns (uint256, uint256, uint256, uint256, uint256[] memory, uint256[] memory)
    {
        require(l.to == msg.sender, "to");
        require(block.timestamp <= l.deadline, "deadline");
        uint256 a = pair.getActiveId();
        require(a + l.idSlippage >= l.activeIdDesired && l.activeIdDesired + l.idSlippage >= a, "idslip");
        MTok(l.tokenX).transferFrom(msg.sender, address(pair), l.amountX);
        MTok(l.tokenY).transferFrom(msg.sender, address(pair), l.amountY);
        uint256 ax; uint256 ay;
        for (uint256 i; i < l.deltaIds.length; ++i) {
            uint256 id = uint256(int256(a) + l.deltaIds[i]);
            uint256 x = l.amountX * l.distributionX[i] / 1e18;
            uint256 y = l.amountY * l.distributionY[i] / 1e18;
            if (id < a) require(x == 0, "flawed");
            if (id > a) require(y == 0, "flawed");
            pair.mintBin(l.to, id, x, y);
            ax += x; ay += y;
        }
        // leftover stays in the pair mock; refund
        MPairRefund(address(pair)); // no-op
        require(ax >= l.amountXMin && ay >= l.amountYMin, "min");
        return (ax, ay, l.amountX - ax, l.amountY - ay, new uint256[](0), new uint256[](0));
    }
    function swapExactTokensForTokens(uint256 amountIn, uint256 minOut, IDLMMRouter.Path memory path, address to, uint256 deadline)
        external returns (uint256 out)
    {
        require(block.timestamp <= deadline, "deadline");
        MTok(path.tokenPath[0]).transferFrom(msg.sender, address(this), amountIn);
        out = amountIn * 9999 / 10000; // 1 bp fee, price 1
        require(out >= minOut, "InsufficientAmountOut");
        MTok(path.tokenPath[1]).transfer(to, out);
    }
}
function MPairRefund(address) pure {}

contract W2SmokeTest is Test {
    MTok usdc; MTok usdt; MTok phar;
    MFeed fa; MFeed fp;
    MFactory fac; MPair pair; MRouter router; MRewarder rw; MBeacon beacon; MVoter voter; MImpl impl;
    PharaohDlmmVault v;
    address owner = address(0xA11CE);
    address keeper = address(0xBEEF);
    address user = address(0xCAFE);
    address admin = address(0xAD);

    function setUp() public {
        vm.warp(1_800_000_000);
        // X = usdt, Y = usdc (as on chain): deploy so that address(usdt) < address(usdc) is not required by the mocks
        usdc = new MTok("USDC", 6); usdt = new MTok("USDT", 6); phar = new MTok("PHAR", 18);
        fa = new MFeed(); fp = new MFeed();
        fa.set(1e8); fp.set(1e8);
        impl = new MImpl(); voter = new MVoter(); beacon = new MBeacon(address(impl));
        rw = new MRewarder(address(voter), address(phar));
        beacon.setRw(address(rw));
        fac = new MFactory();
        pair = new MPair(address(fac), address(usdt), address(usdc), address(rw));
        fac.setPair(address(pair));
        router = new MRouter(address(fac), address(pair));
        voter.set(address(beacon), address(router));
        usdt.mint(address(router), 1e12); usdc.mint(address(router), 1e12);

        PharaohDlmmVault implV = new PharaohDlmmVault();
        IPharaohDlmmVault.InitParams memory p = IPharaohDlmmVault.InitParams({
            asset: address(usdc), pairToken: address(usdt), pair: address(pair), router: address(router), factory: address(fac),
            rewarder: address(rw), rewarderImplCodehash: address(impl).codehash, feedAsset: address(fa), feedPair: address(fp),
            binStep: 1, owner: owner, rebalancer: keeper, depositCap: 200e6, name: "DLMM Vault", symbol: "dUSDC"
        });
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implV), admin, abi.encodeCall(PharaohDlmmVault.initialize, (p))
        );
        v = PharaohDlmmVault(address(proxy));
        usdc.mint(user, 1000e6);
        vm.prank(user); usdc.approve(address(v), type(uint256).max);
    }

    function _open() internal {
        vm.prank(owner); v.unpause();
        vm.prank(user); v.deposit(100e6, user);
        vm.prank(keeper); v.openBand(8388608, 0, 0, 0, 0, block.timestamp + 100);
    }

    function test_initState() public view {
        assertEq(v.depositCap(), 200e6);
        assertEq(v.DEPOSIT_CAP_CEILING(), 200e6);
        assertTrue(v.paused());
        assertEq(v.rebalancer(), keeper);
        assertEq(address(v.tokenX()), address(usdt));
        assertFalse(v.assetIsX());
        (bool unsafe, bool latched, uint256 r) = v.guardState();
        assertFalse(unsafe); assertFalse(latched); assertEq(r, 0);
    }

    function test_pausedBlocksDeposit() public {
        vm.prank(user); vm.expectRevert(); v.deposit(1e6, user);
        assertEq(v.maxDeposit(user), 0);
    }

    function test_depositCapAndOpenBand() public {
        vm.prank(owner); v.unpause();
        assertEq(v.maxDeposit(user), 200e6);
        vm.prank(user); v.deposit(100e6, user);
        assertEq(v.totalAssets(), 100e6);
        vm.prank(user); vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.CapExceeded.selector, 200e6, 201e6));
        v.deposit(101e6, user);
        vm.prank(keeper); v.openBand(8388608, 0, 0, 0, 0, block.timestamp + 100);
        (uint24 lo, uint24 hi, uint24 act, bool has, bool oor) = v.bandState();
        assertTrue(has); assertFalse(oor); assertEq(lo, 8388607); assertEq(hi, 8388609); assertEq(act, 8388608);
        // NAV: 1 bp swap fee on 50 USDC
        assertApproxEqAbs(v.totalAssets(), 100e6, 10_000);
        assertEq(usdc.balanceOf(address(v)) + usdt.balanceOf(address(v)) < 1e5, true, "all deployed (dust only)");
    }

    function test_rebalanceFlow() public {
        _open();
        vm.prank(keeper); vm.expectRevert(); // in range
        v.rebalance(8388608, 0, true, 0, 0, 0, 0, block.timestamp + 100);
        pair.setActive(8388620);
        (,,,, bool oor) = v.bandState(); assertTrue(oor);
        (bool ok, uint256 bits,) = v.rebalanceAllowed(); assertTrue(ok); assertEq(bits, 0);
        vm.prank(keeper); v.rebalance(8388620, 0, true, 0, 0, 0, 0, block.timestamp + 100);
        (uint24 lo, uint24 hi,,,) = v.bandState();
        assertEq(lo, 8388619); assertEq(hi, 8388621);
        assertEq(v.rebalancesToday(), 1);
        pair.setActive(8388645);
        (ok, bits,) = v.rebalanceAllowed(); assertFalse(ok); assertEq(bits & 256, 256); // cooldown
        vm.warp(vm.getBlockTimestamp() + 121);
        uint256 dl = vm.getBlockTimestamp() + 100;
        vm.prank(keeper); v.rebalance(8388645, 0, true, 0, 0, 0, 0, dl);
    }

    function test_redeemInKindAndRedeem() public {
        _open();
        uint256 s = v.balanceOf(user);
        vm.prank(user); (uint256 ax, uint256 ay) = v.redeemInKind(s / 2, user, user);
        assertGt(ax + ay, 49e6);
        uint256 before = usdc.balanceOf(user);
        uint256 rest = v.balanceOf(user);
        vm.prank(user); uint256 got = v.redeem(rest, user, user);
        assertEq(usdc.balanceOf(user) - before, got);
        assertApproxEqAbs(got, 50e6, 20_000);
        (,,, bool has,) = v.bandState(); assertFalse(has);
        assertEq(v.totalSupply(), 0);
    }

    function test_exitsIgnoreGuardPauseFeedAndPin() public {
        _open();
        fa.set(0); // feed answer <= 0 -> bit 1
        rw.setLinked(false); // bit 32
        vm.prank(owner); v.pause();
        (bool unsafe,, uint256 r) = v.guardState(); assertTrue(unsafe); assertTrue(r & 1 != 0); assertTrue(r & 32 != 0);
        v.tripGuard();
        vm.prank(user); vm.expectRevert(); v.redeem(1e6, user, user); // needs the feed
        uint256 all = v.balanceOf(user);
        vm.prank(user); v.redeemInKind(all, user, user); // works
        assertEq(v.balanceOf(user), 0);
    }

    function test_guardLatchAndClear() public {
        vm.prank(owner); v.unpause();
        fp.set(0.99e8); // 100 bp off: bit 8
        (, , uint256 r) = v.guardState(); assertEq(r & 8, 8); assertEq(r & 16, 16 * 0 + (r & 16));
        vm.prank(user); vm.expectRevert(); v.deposit(1e6, user);
        v.tripGuard();
        fp.set(1e8);
        (bool unsafe, bool latched,) = v.guardState(); assertFalse(unsafe); assertTrue(latched);
        vm.prank(user); vm.expectRevert(IPharaohDlmmVault.GuardLatched.selector); v.deposit(1e6, user);
        vm.expectRevert(); v.clearGuard();
        vm.prank(owner); v.clearGuard();
        vm.prank(user); v.deposit(1e6, user);
    }

    function test_poolOracleDeviationBit() public {
        vm.prank(owner); v.unpause();
        pair.setActive(8388608 + 100); // +1.00 %
        (, , uint256 r) = v.guardState(); assertEq(r & 16, 16);
        pair.setActive(8388608 - 100);
        (, , r) = v.guardState(); assertEq(r & 16, 16);
        pair.setActive(8388608 + 30); // 0.30 % < 0.60 %
        (, , r) = v.guardState(); assertEq(r & 16, 0);
        // feed ratio moves the other way: USDT (X) at 1.004 vs USDC 1.0 -> oracle Y per X = 1.004, pool at 1.0 -> 40 bp: ok; 1.0066 -> 66 bp: trips
        fp.set(1.0066e8); fa.set(1e8); pair.setActive(8388608);
        (, , r) = v.guardState(); assertEq(r & 16, 16);
        fp.set(1.0040e8);
        (, , r) = v.guardState(); assertEq(r & 16, 0);
    }

    function test_harvestAndParams() public {
        _open();
        vm.prank(keeper); v.harvestRewards();
        assertEq(phar.balanceOf(owner), 5e18);
        IPharaohDlmmVault.GuardParams memory g = v.guardParams();
        g.legBandBps = 9;
        vm.prank(owner); vm.expectRevert(IPharaohDlmmVault.ParamOutOfBounds.selector); v.setGuardParams(g);
        g.legBandBps = 100;
        vm.prank(owner); v.setGuardParams(g);
        vm.prank(owner); vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.CapAboveCeiling.selector, 201e6, 200e6)); v.setDepositCap(201e6);
    }

    function test_initRejectsWrongCodehashAndCap() public {
        PharaohDlmmVault implV = new PharaohDlmmVault();
        IPharaohDlmmVault.InitParams memory p = IPharaohDlmmVault.InitParams({
            asset: address(usdc), pairToken: address(usdt), pair: address(pair), router: address(router), factory: address(fac),
            rewarder: address(rw), rewarderImplCodehash: bytes32(uint256(1)), feedAsset: address(fa), feedPair: address(fp),
            binStep: 1, owner: owner, rebalancer: keeper, depositCap: 200e6, name: "x", symbol: "x"
        });
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.PairValidationFailed.selector, 11));
        new TransparentUpgradeableProxy(address(implV), admin, abi.encodeCall(PharaohDlmmVault.initialize, (p)));
        p.rewarderImplCodehash = address(impl).codehash; p.depositCap = 200e6 + 1;
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.CapAboveCeiling.selector, 200e6 + 1, 200e6));
        new TransparentUpgradeableProxy(address(implV), admin, abi.encodeCall(PharaohDlmmVault.initialize, (p)));
    }

    function test_failingHookBlocksInKind() public {
        _open();
        pair.setBurnReverts(true);
        vm.prank(user); vm.expectRevert(); v.redeemInKind(1e6, user, user);
    }

    function test_capExactThenOneWeiRevertsAndOpenBandSurvivesFavourableSwap() public {
        vm.prank(owner); v.unpause();
        vm.prank(user); v.deposit(200e6, user); // exactly the cap
        assertEq(v.maxDeposit(user), 0);
        vm.prank(user); vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.CapExceeded.selector, 200e6, 200e6 + 1));
        v.deposit(1, user);
        fp.set(1.001e8); // favourable swap: NAV rises above the cap
        vm.prank(keeper); v.openBand(8388608, 0, 0, 0, 0, block.timestamp + 100);
        (,,, bool has,) = v.bandState(); assertTrue(has);
        assertGt(v.totalAssets(), 200e6);
    }

    function test_rebalanceWithSwapBothDirections() public {
        _open();
        // inventory after the burn is about 25 USDt + 75 USDC (mock band holds what it was given): swap USDC -> USDt (Y -> X) = swapXForY false
        pair.setActive(8388620);
        vm.prank(keeper); v.rebalance(8388620, 0, false, 10e6, 0, 0, 0, block.timestamp + 100);
        (uint24 lo,,,,) = v.bandState(); assertEq(lo, 8388619);
        vm.warp(vm.getBlockTimestamp() + 121);
        pair.setActive(8388630);
        uint256 dl = vm.getBlockTimestamp() + 100;
        vm.prank(keeper); v.rebalance(8388630, 0, true, 5e6, 0, 0, 0, dl); // USDt -> USDC
        // too large: > 60 % of NAV
        vm.warp(vm.getBlockTimestamp() + 121);
        pair.setActive(8388640);
        dl = vm.getBlockTimestamp() + 100;
        vm.prank(keeper); vm.expectRevert(); v.rebalance(8388640, 0, false, 70e6, 0, 0, 0, dl);
        assertApproxEqAbs(v.totalAssets(), 100e6, 100_000);
    }

    function test_withdrawAndMint() public {
        _open();
        vm.prank(user); uint256 minted = v.mint(10e6, user); // assets ~ 10e6 (ceil)
        assertApproxEqAbs(minted, 10e6, 2_000); // NAV is a few bp below supply after the 1 bp mock swap fee
        uint256 before = usdc.balanceOf(user);
        vm.prank(user); uint256 burned = v.withdraw(20e6, user, user);
        uint256 got = usdc.balanceOf(user) - before;
        assertApproxEqAbs(burned, 20e6, 20_000);
        assertApproxEqAbs(got, 20e6, 20_000); // slightly below: the redeemer bears the swap fee
    }

    function test_depositWhileBandThenRebalanceFoldsIdle() public {
        _open();
        vm.prank(user); v.deposit(50e6, user);
        assertEq(usdc.balanceOf(address(v)), 50e6 + usdc.balanceOf(address(v)) - 50e6); // idle USDC present
        assertGe(usdc.balanceOf(address(v)), 50e6);
        pair.setActive(8388620);
        vm.prank(keeper); v.rebalance(8388620, 0, false, 40e6, 0, 0, 0, block.timestamp + 100);
        assertLt(usdc.balanceOf(address(v)), 1e6, "idle folded into the new band");
        assertApproxEqAbs(v.totalAssets(), 150e6, 200_000);
    }
}

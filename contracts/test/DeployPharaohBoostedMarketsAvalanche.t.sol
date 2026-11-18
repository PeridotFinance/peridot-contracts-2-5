// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PharaohDlmmShareOracle} from "../contracts/PharaohDlmmShareOracle.sol";
import {PToken} from "../contracts/PToken.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {DeployPharaohBoostedMarketsAvalanche} from "../script/DeployPharaohBoostedMarketsAvalanche.s.sol";
import {DlmmTestGuardedBase} from "./PharaohDlmmShareOracle.t.sol";
import {MockInterestRateModel} from "./MockInterestRateModel.sol";
import {PharaohTestAsset, PharaohTestVault} from "./mocks/PharaohBoostedMocks.sol";

/// @dev Minimal controller with the real admin entry points' names and the state the script reads. Offline stand-in for the live Unitroller.
contract ScriptTestController {
    bool public constant isPeridottroller = true;
    address public admin;
    address public oracle;
    uint256 public closeFactorMantissa = 0.5e18;
    uint256 public liquidationIncentiveMantissa = 1.08e18;
    mapping(address => bool) public listed;
    mapping(address => uint256) public cf;
    address[] internal all;
    mapping(address => bool) public mintGuardianPaused;
    mapping(address => bool) public borrowGuardianPaused;
    mapping(address => uint256) public borrowCaps;
    mapping(address => uint256) public borrowCashFloor;

    constructor(address admin_, address oracle_) {
        admin = admin_;
        oracle = oracle_;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "admin only");
        _;
    }

    function markets(address p) external view returns (bool, uint256, bool) {
        return (listed[p], cf[p], false);
    }

    function getAllMarkets() external view returns (address[] memory) {
        return all;
    }

    function seedMarket(address p, uint256 cf_) external {
        listed[p] = true;
        cf[p] = cf_;
        all.push(p);
    }

    function _setPriceOracle(address o) external onlyAdmin returns (uint256) {
        oracle = o;
        return 0;
    }

    function _supportMarket(address p) external onlyAdmin returns (uint256) {
        require(!listed[p], "listed");
        listed[p] = true;
        all.push(p);
        return 0;
    }

    function _setBorrowPaused(address p, bool s) external onlyAdmin returns (bool) {
        borrowGuardianPaused[p] = s;
        return s;
    }

    function _setMintPaused(address p, bool s) external onlyAdmin returns (bool) {
        mintGuardianPaused[p] = s;
        return s;
    }

    function _setMarketBorrowCaps(address[] calldata ps, uint256[] calldata caps) external onlyAdmin {
        for (uint256 i; i < ps.length; ++i) borrowCaps[ps[i]] = caps[i];
    }

    function _setCollateralFactor(address p, uint256 v) external onlyAdmin returns (uint256) {
        cf[p] = v;
        return 0;
    }

    // hooks the pToken calls
    function mintAllowed(address p, address, uint256) external view returns (uint256) {
        require(!mintGuardianPaused[p], "mint is paused");
        return listed[p] ? 0 : 9;
    }

    function transferAllowed(address, address, address, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract ScriptTestVault is PharaohTestVault {
    address public owner;
    bool public paused;
    uint256 public depositCap = 200e6;

    constructor(IERC20 asset_, address owner_) PharaohTestVault(asset_, "Peridot Pharaoh DLMM USDC/USDt", "pdlmm") {
        owner = owner_;
    }
}

contract ScriptTestOwnable {
    address public owner;

    constructor(address o) {
        owner = o;
    }
}

/// @dev Runs the rewritten deploy script and the whole listing sequence against local mocks placed at the LIVE addresses, so every constant,
///      pin and read-back in the script is exercised offline. The real controller semantics are covered by the fork rehearsal.
contract DeployPharaohBoostedMarketsAvalancheTest is Test {
    address internal constant LEDGER = 0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD;
    address internal constant SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
    address internal constant CONTROLLER = 0xbE938cD7C25E0E4d0604Fa3F9f0a8b5b67b3D51A;
    address internal constant GUARDED = 0x7BAB5406Cb4929f9b9492e1b2a43b65BF93AaFC0;
    address internal constant PWAVAX = 0x12f1F4Fc057a76f473B781ce2Fa88E55ef8581B1;
    address internal constant PUSDC = 0x0f7849CD9E54ffb027aacaEec82007cca9470098;
    address internal constant RATE_MODEL = 0xe5a82bF40b493cf37C06851A934370F3f0896263;
    address internal constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address internal constant VAULT = 0x278B1b625C74B1926C5F989ddE601f3C5Ba27f7D;
    address internal constant VAULT_IMPL = 0x7F204f63152c577358fDaFbB7939CdC06D61a093;
    address internal constant PROXY_ADMIN = 0x7037fa4B1870dFd28FF9c057Cf49A0f83011268A;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant DEPLOYER = address(0xDE91);
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    DeployPharaohBoostedMarketsAvalanche internal script;
    ScriptTestController internal ctl = ScriptTestController(CONTROLLER);
    DlmmTestGuardedBase internal base = DlmmTestGuardedBase(GUARDED);
    ScriptTestVault internal vault = ScriptTestVault(VAULT);

    function setUp() external {
        vm.chainId(43_114);
        vm.warp(10 days);
        deployCodeTo("PharaohBoostedMocks.sol:PharaohTestAsset", abi.encode("USD Coin", "USDC", uint8(6)), USDC);
        deployCodeTo("DlmmTestGuardedBase", "", GUARDED);
        deployCodeTo("MockInterestRateModel", "", RATE_MODEL);
        deployCodeTo("ScriptTestOwnable", abi.encode(SAFE), PROXY_ADMIN);
        deployCodeTo("ScriptTestController", abi.encode(LEDGER, GUARDED), CONTROLLER);
        deployCodeTo("ScriptTestVault", abi.encode(USDC, SAFE), VAULT);
        vm.store(VAULT, ADMIN_SLOT, bytes32(uint256(uint160(PROXY_ADMIN))));
        vm.store(VAULT, IMPL_SLOT, bytes32(uint256(uint160(VAULT_IMPL))));

        // the live vault: 17 USDC, 17,000,000 shares; the Ledger holds 16,000,000
        PharaohTestAsset(USDC).mint(address(this), 17e6);
        PharaohTestAsset(USDC).approve(VAULT, type(uint256).max);
        vault.deposit(17e6, LEDGER);

        // existing markets and prices
        ctl.seedMarket(PWAVAX, 0.3e18);
        ctl.seedMarket(PUSDC, 0);
        base.setAssetPrice(USDC, 1e18);
        base.setAssetPrice(WAVAX, 21.5e18);
        base.setUnderlyingPrice(PWAVAX, 21.5e18);
        base.setUnderlyingPrice(PUSDC, 1e30);
        base.setMarketAsset(PWAVAX, WAVAX);
        base.setMarketAsset(PUSDC, USDC);

        script = new DeployPharaohBoostedMarketsAvalanche();
    }

    DeployPharaohBoostedMarketsAvalanche.New internal n;

    function _deploy() internal returns (address delegate, address market, address oracle) {
        n = script.deployAs(DEPLOYER);
        delegate = n.delegate;
        market = n.market;
        oracle = n.oracle;
    }

    function _stage(uint256 s) internal view {
        script.verifyListingFor(n, s);
    }

    function testCheckPassesOnTheLiveShapedState() external view {
        script.check();
    }

    function testDeployThenFullListingSequenceVerifiesAtEveryStage() external {
        (, address market, address oracle) = _deploy();
        script.verifyDeployedFor(n);

        // T1: swap the oracle
        vm.startPrank(LEDGER);
        assertEq(ctl._setPriceOracle(oracle), 0);
        vm.stopPrank();
        _stage(1);

        // T2-T4: list, borrow pause, borrow cap 1
        vm.startPrank(LEDGER);
        assertEq(ctl._supportMarket(market), 0);
        ctl._setBorrowPaused(market, true);
        address[] memory ps = new address[](1);
        ps[0] = market;
        uint256[] memory caps = new uint256[](1);
        caps[0] = 1;
        ctl._setMarketBorrowCaps(ps, caps);
        vm.stopPrank();
        _stage(2);

        // an outsider holding shares cannot mint before the seed
        vm.prank(LEDGER);
        vault.transfer(address(0xBAD), 1e6);
        vm.startPrank(address(0xBAD));
        vault.approve(market, type(uint256).max);
        (bool outsiderOk,) = market.call(abi.encodeWithSignature("mint(uint256)", uint256(1)));
        assertFalse(outsiderOk, "an outsider minted before the seed");
        vm.stopPrank();

        // T5-T7: seed, T8: dead, T9: mint pause
        vm.startPrank(LEDGER);
        vault.approve(market, 1_000_000);
        assertEq(PToken(market).balanceOf(LEDGER), 0);
        (bool ok,) = market.call(abi.encodeWithSignature("mint(uint256)", uint256(1_000_000)));
        assertTrue(ok);
        assertEq(PToken(market).balanceOf(LEDGER), 5_000_000_000);
        PToken(market).transfer(DEAD, PToken(market).balanceOf(LEDGER));
        ctl._setMintPaused(market, true);
        vm.stopPrank();
        _stage(3);

        // activation: mint open, CF 50%
        vm.startPrank(LEDGER);
        ctl._setMintPaused(market, false);
        assertEq(ctl._setCollateralFactor(market, 0.5e18), 0);
        vm.stopPrank();
        _stage(4);

        // rollback: one transaction, the guarded oracle again; the identity holds either way
        vm.prank(LEDGER);
        ctl._setPriceOracle(GUARDED);
        assertEq(ctl.oracle(), GUARDED);
    }

    function testVerifyListingRejectsAnUnlockedShareMarket() external {
        (, address market, address oracle) = _deploy();
        vm.startPrank(LEDGER);
        ctl._setPriceOracle(oracle);
        ctl._supportMarket(market);
        vm.stopPrank();
        // borrow neither paused nor capped
        vm.expectRevert();
        script.verifyListingFor(n, 2);
    }

    function testCheckRefusesWhenTheVaultFeedIsStaleOrTheOracleAlreadySwapped() external {
        vault.setConversionReverts(true);
        vm.expectRevert();
        script.check();
        vault.setConversionReverts(false);

        (, address market, address oracle) = _deploy();
        market;
        vm.prank(LEDGER);
        ctl._setPriceOracle(oracle);
        vm.expectRevert();
        script.check(); // controller oracle is no longer the guarded oracle
    }

    function testDeployRefusesTheLedgerAsDeployer() external {
        vm.expectRevert();
        script.deployAs(LEDGER);
    }

    function testDeployedMarketAdminIsTheLedgerAndTheDeployerHoldsNothing() external {
        (address delegate, address market, address oracle) = _deploy();
        assertEq(PToken(market).admin(), LEDGER);
        assertEq(PToken(market).pendingAdmin(), address(0));
        assertTrue(PToken(market).flashLoansPaused());
        assertEq(PToken(market).exchangeRateStored(), 2e14);
        assertEq(PErc20(market).underlying(), VAULT);
        assertEq(PharaohDlmmShareOracle(oracle).market(), market);
        assertTrue(delegate.code.length > 0);
        // the deployer cannot do anything admin-only
        vm.prank(DEPLOYER);
        vm.expectRevert();
        PToken(market)._setPendingAdmin(payable(DEPLOYER));
    }
}

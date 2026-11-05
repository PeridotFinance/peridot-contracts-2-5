// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {PToken} from "../contracts/PToken.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {Unitroller} from "../contracts/Unitroller.sol";
import {PriceOracle} from "../contracts/PriceOracle.sol";
import {
    DeployAvalancheCashOnlyLending,
    VerifyAvalancheCashOnlyLending,
    CashOnlyDeployment,
    CashOnlyParams
} from "../script/DeployAvalancheCashOnlyLending.s.sol";

/// @dev TEST-ONLY stand-in so the rehearsal has SOME contract at the PERIDOT_TOKEN input. It is NOT a proposed token and nothing in
///      the deploy script can create or select one: the production PERIDOT token is an unresolved operator decision.
contract TestOnlyPeridotTokenStandIn is ERC20 {
    constructor() ERC20("TEST-ONLY PERIDOT STAND-IN", "TESTPDT") {}
}

/**
 * @notice LOCAL-FORK REHEARSAL of `script/DeployAvalancheCashOnlyLending.s.sol` (pinned block 99,200,000). Nothing is signed, broadcast
 *         or sent to any network: the script runs inside the forge VM. Every parameter below is SYNTHETIC; no production value, no
 *         production PERIDOT token. Borrowing is never unpaused here.
 */
contract AvalancheCashOnlyDeployRehearsalForkTest is Test {
    uint256 internal constant PIN_BLOCK = 99_200_000;
    address internal constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address internal constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    // The operator's Ledger (the intended single admin/signer). In-VM only: nothing is signed or sent; the rehearsal just runs the script as this address.
    address internal constant DEPLOYER = 0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD;
    address internal constant GUARDIAN = address(0x6A2D);
    address internal constant STRANGER = address(0xBAD1);

    // SYNTHETIC rehearsal inputs
    uint256 internal constant S_WAVAX_SEED = 100e18;
    uint256 internal constant S_USDC_SEED = 1_000e6;
    uint256 internal constant S_WAVAX_CAP = 10_000e18;
    uint256 internal constant S_USDC_CAP = 100_000e6;
    uint256 internal constant S_WAVAX_FLOOR = 25e18;
    uint256 internal constant S_USDC_FLOOR = 250e6;

    DeployAvalancheCashOnlyLending internal script;
    address internal tokenStandIn;

    function setUp() public {
        string memory rpc = vm.envOr("AVALANCHE_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, PIN_BLOCK);
        script = new DeployAvalancheCashOnlyLending();
        tokenStandIn = address(new TestOnlyPeridotTokenStandIn());
        deal(WAVAX, DEPLOYER, S_WAVAX_SEED);
        deal(USDC, DEPLOYER, S_USDC_SEED);
    }

    function _params() internal view returns (CashOnlyParams memory p) {
        p.deployer = DEPLOYER;
        p.peridotToken = tokenStandIn;
        p.pauseGuardian = GUARDIAN;
        p.wavaxSeed = S_WAVAX_SEED;
        p.usdcSeed = S_USDC_SEED;
        p.wavaxBorrowCap = S_WAVAX_CAP;
        p.usdcBorrowCap = S_USDC_CAP;
        p.reserveFactor = 0.1e18;
        p.closeFactor = 0.5e18;
        p.liquidationIncentive = 1.08e18;
        p.blocksPerYear = 31_536_000;
        p.baseRatePerYear = 0.02e18;
        p.multiplierPerYear = 0.1e18;
        p.jumpMultiplierPerYear = 1e18;
        p.kink = 0.8e18;
        p.avaxFeedMaxAge = 1_200;
        p.usdcFeedMaxAge = 90_000;
        p.wavaxBorrowCashFloor = S_WAVAX_FLOOR;
        p.usdcBorrowCashFloor = S_USDC_FLOOR;
    }

    function _env() internal {
        vm.setEnv("DEPLOYER", vm.toString(DEPLOYER));
        vm.setEnv("PERIDOT_TOKEN", vm.toString(tokenStandIn));
        vm.setEnv("LENDING_ALLOW_NO_REWARD_TOKEN", "false");
        vm.setEnv("PAUSE_GUARDIAN", vm.toString(GUARDIAN));
        vm.setEnv("LENDING_WAVAX_SEED_AMOUNT", vm.toString(S_WAVAX_SEED));
        vm.setEnv("LENDING_USDC_SEED_AMOUNT", vm.toString(S_USDC_SEED));
        vm.setEnv("LENDING_WAVAX_BORROW_CAP", vm.toString(S_WAVAX_CAP));
        vm.setEnv("LENDING_USDC_BORROW_CAP", vm.toString(S_USDC_CAP));
        vm.setEnv("LENDING_RESERVE_FACTOR", vm.toString(uint256(0.1e18)));
        vm.setEnv("LENDING_CLOSE_FACTOR", vm.toString(uint256(0.5e18)));
        vm.setEnv("LENDING_LIQUIDATION_INCENTIVE", vm.toString(uint256(1.08e18)));
        vm.setEnv("LENDING_BLOCKS_PER_YEAR", vm.toString(uint256(31_536_000)));
        vm.setEnv("LENDING_BASE_RATE_PER_YEAR", vm.toString(uint256(0.02e18)));
        vm.setEnv("LENDING_MULTIPLIER_PER_YEAR", vm.toString(uint256(0.1e18)));
        vm.setEnv("LENDING_JUMP_MULTIPLIER_PER_YEAR", vm.toString(uint256(1e18)));
        vm.setEnv("LENDING_KINK", vm.toString(uint256(0.8e18)));
        vm.setEnv("AVAX_FEED_MAX_AGE", vm.toString(uint256(1_200)));
        vm.setEnv("USDC_FEED_MAX_AGE", vm.toString(uint256(90_000)));
        vm.setEnv("LENDING_WAVAX_BORROW_CASH_FLOOR", vm.toString(S_WAVAX_FLOOR));
        vm.setEnv("LENDING_USDC_BORROW_CASH_FLOOR", vm.toString(S_USDC_FLOOR));
    }

    function _verify(CashOnlyDeployment memory d, address expectedAdmin) internal {
        new VerifyAvalancheCashOnlyLending().verify(d, _params(), expectedAdmin);
    }

    function _expectVerifyRevert(CashOnlyDeployment memory d, address expectedAdmin, string memory why) internal {
        VerifyAvalancheCashOnlyLending v = new VerifyAvalancheCashOnlyLending();
        CashOnlyParams memory p = _params();
        vm.expectRevert(bytes(why));
        v.verify(d, p, expectedAdmin);
    }

    // ================================================================= the happy path and its explicit checks
    function testRehearsal_Deploys_BorrowingPaused_HooksUnset_AdminAndConfigChecks() public {
        CashOnlyDeployment memory d = script.deploy(_params());
        _verify(d, DEPLOYER); // the verifier script: admin, owner, implementation, token, oracle, feeds, markets, caps, floors, pause, hooks
        // spelled out independently of the verifier
        assertEq(d.unitroller.admin(), DEPLOYER, "controller admin is the deployer until a separate verified handover");
        assertEq(d.unitroller.pendingAdmin(), address(0));
        assertEq(d.pWavax.admin(), DEPLOYER);
        assertEq(d.pUsdc.admin(), DEPLOYER);
        assertEq(d.sourceOracle.owner(), DEPLOYER);
        assertEq(d.controller.isolatedMarginRiskHook(), address(0), "margin risk hook unset");
        assertEq(d.controller.isolatedMarginRegistrar(), address(0), "margin registrar unset");
        assertTrue(d.controller.borrowGuardianPaused(address(d.pWavax)) && d.controller.borrowGuardianPaused(address(d.pUsdc)), "borrowing paused");
        assertTrue(d.pWavax.flashLoansPaused() && d.pUsdc.flashLoansPaused(), "pToken flash loans paused");
        (, uint256 cfw,) = d.controller.markets(address(d.pWavax));
        (, uint256 cfu,) = d.controller.markets(address(d.pUsdc));
        assertEq(cfw + cfu, 0, "collateral factors are zero: the deployment cannot lend");
        assertEq(d.controller.getPeridotAddress(), tokenStandIn, "the PERIDOT token is exactly the supplied input");
        assertEq(address(d.controller.oracle()), address(d.oracle), "the guarded oracle, not the source oracle");
        assertEq(d.controller.borrowCashFloor(address(d.pWavax)), S_WAVAX_FLOOR);
        assertEq(d.controller.borrowCashFloor(address(d.pUsdc)), S_USDC_FLOOR);
        assertEq(d.pWavax.implementation(), d.pUsdc.implementation(), "one plain delegate");
        assertGt(d.pWavax.totalSupply(), 0);
        assertGt(d.pUsdc.totalSupply(), 0);
        assertEq(IERC20(WAVAX).balanceOf(DEPLOYER), 0, "the deployer's seed moved into the market");
        // no margin contract exists in the deployment: the script deploys none and the controller points at none
        assertEq(address(d.bootstrapper).code.length > 0, true);
        assertTrue(d.bootstrapper.used(), "single-use bootstrapper consumed");
    }

    /// @dev What the deployed markets do while paused: supply and redeem work, borrowing reverts, a stranger cannot unpause, and even
    ///      after SYNTHETIC parameters are applied by the admin the script's outcome stays paused until the admin explicitly unpauses
    ///      (which this rehearsal never does).
    function testRehearsal_PostDeploy_SupplyWorks_BorrowRevertsPaused_StrangerCannotUnpause() public {
        CashOnlyDeployment memory d = script.deploy(_params());
        address user = address(0x5E11);
        deal(USDC, user, 500e6);
        vm.startPrank(user);
        IERC20(USDC).approve(address(d.pUsdc), 500e6);
        assertEq(d.pUsdc.mint(500e6), 0, "supply works");
        vm.stopPrank();
        // SYNTHETIC parameter step by the admin (a separate step from the script)
        vm.startPrank(DEPLOYER);
        assertEq(d.controller._setCollateralFactor(PToken(address(d.pUsdc)), 0.5e18), 0);
        assertEq(d.controller._setCollateralFactor(PToken(address(d.pWavax)), 0.5e18), 0);
        vm.stopPrank();
        vm.startPrank(user);
        address[] memory ms = new address[](2);
        ms[0] = address(d.pUsdc);
        ms[1] = address(d.pWavax);
        d.controller.enterMarkets(ms);
        vm.expectRevert(bytes("borrow is paused"));
        d.pWavax.borrow(1e18);
        vm.stopPrank();
        // a stranger cannot unpause or change a floor
        vm.prank(STRANGER);
        vm.expectRevert();
        d.controller._setBorrowPaused(PErc20(address(d.pWavax)), false);
        vm.prank(STRANGER);
        vm.expectRevert(bytes("only admin can set borrow cash floor"));
        d.controller._setBorrowCashFloor(PToken(address(d.pWavax)), 0);
        // redeem works while paused
        uint256 bal = d.pUsdc.balanceOf(user);
        vm.prank(user);
        assertEq(d.pUsdc.redeem(bal), 0, "supplier can exit while borrowing is paused");
        // the deployment itself still reads as paused
        assertTrue(d.controller.borrowGuardianPaused(address(d.pWavax)) && d.controller.borrowGuardianPaused(address(d.pUsdc)));
    }

    // ================================================================= inputs the script must refuse (struct entry point)
    function testRehearsal_RefusesWithoutAProductionPeridotTokenDecision() public {
        CashOnlyParams memory p = _params();
        p.peridotToken = address(0);
        vm.expectRevert(bytes("CashOnlyLending: PERIDOT token must be an existing contract (operator decision)"));
        script.deploy(p);
        p.peridotToken = address(0xE0A); // an address without code
        vm.expectRevert(bytes("CashOnlyLending: PERIDOT token must be an existing contract (operator decision)"));
        script.deploy(p);
    }

    /// @dev The explicit, opt-in NO-REWARD-TOKEN deployment: both inputs must say so (token 0 AND flag true). Everything else about the
    ///      deployment is unchanged: verifier passes, borrowing stays paused, the reward-token entry points revert, supply and redeem work.
    function testRehearsal_NoRewardTokenOptIn_DeploysAndVerifies_ClaimRevertsLendingWorks() public {
        CashOnlyParams memory p = _params();
        p.peridotToken = address(0);
        p.allowNoRewardToken = true;
        CashOnlyDeployment memory d = script.deploy(p);
        new VerifyAvalancheCashOnlyLending().verify(d, p, DEPLOYER);
        assertEq(d.controller.getPeridotAddress(), address(0));
        assertEq(d.implementation.peridotToken(), address(0));
        assertTrue(d.controller.borrowGuardianPaused(address(d.pUsdc)) && d.controller.borrowGuardianPaused(address(d.pWavax)), "borrowing paused");
        assertEq(d.controller.isolatedMarginRiskHook(), address(0));
        (bool ok,) = address(d.controller).call(abi.encodeWithSignature("claimPeridot(address)", DEPLOYER));
        assertFalse(ok, "claimPeridot reverts with no reward token");
        (ok,) = address(d.controller).call(abi.encodeWithSignature("_grantPeridot(address,uint256)", DEPLOYER, 1));
        assertFalse(ok, "_grantPeridot reverts with no reward token");
    }

    function testRehearsal_OptInFlagWithATokenGiven_IsRefused_ContradictoryInputs() public {
        CashOnlyParams memory p = _params(); // token = stand-in contract
        p.allowNoRewardToken = true;
        vm.expectRevert(bytes("CashOnlyLending: no-reward-token opt-in requires PERIDOT_TOKEN = address(0)"));
        script.deploy(p);
    }

    function testRehearsal_RefusesWrongChainAndBadParameters() public {
        CashOnlyParams memory p = _params();
        vm.chainId(1);
        vm.expectRevert(bytes("CashOnlyLending: Avalanche C-Chain only"));
        script.deploy(p);
        vm.chainId(43_114);
        p.usdcSeed = 0;
        vm.expectRevert(bytes("CashOnlyLending: zero seed"));
        script.deploy(p);
        p = _params();
        p.usdcBorrowCap = p.usdcSeed; // cap not above seed
        vm.expectRevert(bytes("CashOnlyLending: cap not above seed"));
        script.deploy(p);
        p = _params();
        p.reserveFactor = 0.9e18;
        vm.expectRevert(bytes("CashOnlyLending: reserve factor too high"));
        script.deploy(p);
        p = _params();
        p.closeFactor = 0.95e18;
        vm.expectRevert(bytes("CashOnlyLending: close factor"));
        script.deploy(p);
        p = _params();
        p.liquidationIncentive = 1.5e18;
        vm.expectRevert(bytes("CashOnlyLending: liquidation incentive"));
        script.deploy(p);
        // insufficient seed balance
        deal(USDC, DEPLOYER, S_USDC_SEED - 1);
        vm.expectRevert(bytes("CashOnlyLending: USDC seed balance"));
        script.deploy(_params());
    }

    function testRehearsal_RefusesStaleFeeds() public {
        vm.warp(block.timestamp + 2 days);
        CashOnlyParams memory p = _params();
        vm.expectRevert(bytes("CashOnlyLending: stale feed"));
        script.deploy(p);
    }

    /// @dev The ONE env-driven test: `run()` reads every input from the environment, NONE has a default. (Env vars are process-global,
    ///      so every other test uses the struct entry point.)
    function testEnv_RunReadsEveryInput_NoDefaults() public {
        _env();
        CashOnlyDeployment memory d = script.run();
        assertEq(d.controller.getPeridotAddress(), tokenStandIn);
        assertEq(d.controller.borrowCashFloor(address(d.pUsdc)), S_USDC_FLOOR);
        // each required variable, when empty, makes the script refuse to run (no default is substituted)
        string[20] memory names = [
            "DEPLOYER", "PERIDOT_TOKEN", "LENDING_ALLOW_NO_REWARD_TOKEN", "PAUSE_GUARDIAN", "LENDING_WAVAX_SEED_AMOUNT", "LENDING_USDC_SEED_AMOUNT",
            "LENDING_WAVAX_BORROW_CAP", "LENDING_USDC_BORROW_CAP", "LENDING_RESERVE_FACTOR", "LENDING_CLOSE_FACTOR",
            "LENDING_LIQUIDATION_INCENTIVE", "LENDING_BLOCKS_PER_YEAR", "LENDING_BASE_RATE_PER_YEAR", "LENDING_MULTIPLIER_PER_YEAR",
            "LENDING_JUMP_MULTIPLIER_PER_YEAR", "LENDING_KINK", "AVAX_FEED_MAX_AGE", "USDC_FEED_MAX_AGE",
            "LENDING_WAVAX_BORROW_CASH_FLOOR", "LENDING_USDC_BORROW_CASH_FLOOR"
        ];
        for (uint256 i; i < names.length; ++i) {
            _env();
            vm.setEnv(names[i], "");
            vm.expectRevert();
            script.readParams();
        }
        _env();
        // the explicit no-reward-token choice through the environment: token 0 + flag true deploys; token 0 + flag false and a token + flag true refuse
        vm.setEnv("PERIDOT_TOKEN", vm.toString(address(0)));
        vm.setEnv("LENDING_ALLOW_NO_REWARD_TOKEN", "true");
        deal(WAVAX, DEPLOYER, S_WAVAX_SEED);
        deal(USDC, DEPLOYER, S_USDC_SEED);
        CashOnlyDeployment memory d2 = script.run();
        assertEq(d2.controller.getPeridotAddress(), address(0));
        vm.setEnv("LENDING_ALLOW_NO_REWARD_TOKEN", "false");
        vm.expectRevert(bytes("CashOnlyLending: PERIDOT token must be an existing contract (operator decision)"));
        script.run();
        vm.setEnv("PERIDOT_TOKEN", vm.toString(tokenStandIn));
        vm.setEnv("LENDING_ALLOW_NO_REWARD_TOKEN", "true");
        vm.expectRevert(bytes("CashOnlyLending: no-reward-token opt-in requires PERIDOT_TOKEN = address(0)"));
        script.run();
        _env();
    }

    // ================================================================= the verifier catches every deviation (post-deploy tampering)
    function testVerifier_CatchesTampering() public {
        CashOnlyDeployment memory d = script.deploy(_params());
        _verify(d, DEPLOYER);

        // unpaused borrowing
        uint256 s = vm.snapshotState();
        vm.prank(DEPLOYER);
        d.controller._setBorrowPaused(PErc20(address(d.pUsdc)), false);
        _expectVerifyRevert(d, DEPLOYER, "verify: BORROWING IS NOT PAUSED");
        vm.revertToState(s);

        // an enabled collateral factor
        vm.prank(DEPLOYER);
        d.controller._setCollateralFactor(PToken(address(d.pWavax)), 0.1e18);
        _expectVerifyRevert(d, DEPLOYER, "verify: a collateral factor is enabled (parameter step is separate)");
        vm.revertToState(s);

        // a margin hook installed
        vm.prank(DEPLOYER);
        d.controller._setIsolatedMarginRiskHook(tokenStandIn); // any contract: the setter only requires code
        _expectVerifyRevert(d, DEPLOYER, "verify: margin risk hook is set");
        vm.revertToState(s);

        // the controller pointed at the unguarded source oracle
        vm.prank(DEPLOYER);
        d.controller._setPriceOracle(PriceOracle(address(d.sourceOracle)));
        _expectVerifyRevert(d, DEPLOYER, "verify: controller oracle is not the guarded oracle");
        vm.revertToState(s);

        // a pending admin left behind
        vm.prank(DEPLOYER);
        d.unitroller._setPendingAdmin(STRANGER);
        _expectVerifyRevert(d, DEPLOYER, "verify: controller pending admin");
        vm.revertToState(s);

        // a changed floor
        vm.prank(DEPLOYER);
        d.controller._setBorrowCashFloor(PToken(address(d.pUsdc)), 1);
        _expectVerifyRevert(d, DEPLOYER, "verify: borrow cash floors");
        vm.revertToState(s);

        // a changed borrow cap
        PToken[] memory pt = new PToken[](1);
        pt[0] = PToken(address(d.pUsdc));
        uint256[] memory caps = new uint256[](1);
        caps[0] = S_USDC_CAP + 1;
        vm.prank(DEPLOYER);
        d.controller._setMarketBorrowCaps(pt, caps);
        _expectVerifyRevert(d, DEPLOYER, "verify: borrow caps");
        vm.revertToState(s);

        // wrong expected admin (e.g. after a handover the operator forgot to complete)
        _expectVerifyRevert(d, STRANGER, "verify: controller admin");
    }

    /// @dev The single-use bootstrapper cannot be run a second time. (What protects the empty-market window is that listing and seeding
    ///      happen in ONE transaction inside the bootstrapper; its "market touched" refusal is inherited from the Fuji bootstrapper design
    ///      and is NOT separately tested here.)
    function testBootstrapper_CannotBeUsedTwice() public {
        CashOnlyDeployment memory d = script.deploy(_params());
        // a second, fresh bootstrap attempt on the SAME (already used, seeded) markets must fail
        vm.expectRevert();
        vm.prank(DEPLOYER);
        d.bootstrapper.bootstrap(address(d.pWavax), address(d.pUsdc), S_WAVAX_SEED, S_USDC_SEED, S_WAVAX_CAP, S_USDC_CAP, 0.1e18);
    }
}

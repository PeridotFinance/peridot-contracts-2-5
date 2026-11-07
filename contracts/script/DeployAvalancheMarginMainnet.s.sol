// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Peridottroller} from "../contracts/Peridottroller.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {PToken} from "../contracts/PToken.sol";
import {PriceOracle} from "../contracts/PriceOracle.sol";
import {PeridotTransparentProxy} from "../contracts/proxy/PeridotTransparentProxy.sol";
import {IMarginPriceOracle} from "../contracts/margin/interfaces/IMarginPriceOracle.sol";
import {IsolatedMarginTypes} from "../contracts/margin/IsolatedMarginTypes.sol";
import {IsolatedMarginMath} from "../contracts/margin/IsolatedMarginMath.sol";
import {IsolatedMarginAccountFactory} from "../contracts/margin/IsolatedMarginAccountFactory.sol";
import {IsolatedMarginConfigUpgradeable} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginExecutorUpgradeable} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginLiquidatorUpgradeable} from "../contracts/margin/IsolatedMarginLiquidatorUpgradeable.sol";
import {IsolatedMarginQuoter} from "../contracts/margin/IsolatedMarginQuoter.sol";
import {IsolatedMarginRiskEngineUpgradeable} from "../contracts/margin/IsolatedMarginRiskEngineUpgradeable.sol";
import {IsolatedMarginSwapModule} from "../contracts/margin/IsolatedMarginSwapModule.sol";
import {IsolatedMarginVaultUpgradeable} from "../contracts/margin/IsolatedMarginVaultUpgradeable.sol";
import {MarginFeeDistributorUpgradeable} from "../contracts/margin/MarginFeeDistributorUpgradeable.sol";
import {MarginInsuranceFundUpgradeable} from "../contracts/margin/MarginInsuranceFundUpgradeable.sol";
import {PharaohCLRouterAdapter} from "../contracts/margin/PharaohCLRouterAdapter.sol";
import {SimpleFlashLoanVault} from "../contracts/margin/SimpleFlashLoanVault.sol";
import {MarginOrderRegistry} from "../contracts/margin/orders/MarginOrderRegistry.sol";
import {AvalancheMarginCloseAdapter} from "../contracts/margin/orders/AvalancheMarginCloseAdapter.sol";

interface IOwnableLike {
    function owner() external view returns (address);
}

interface IProxyAdminLike {
    function upgradeAndCall(address proxy, address implementation, bytes memory data) external payable;
}

/// @notice The long-only 2x WAVAX/USDC margin deployment on Avalanche mainnet, in four stages, on top of the PW30 lending controller.
///
///  STAGE 1  deploy      signer: a THROWAWAY DEPLOYER (an unprivileged key; it only pays gas). Deploys every contract with the Ledger as
///                       owner and as proxy-admin owner from the first instruction. The deployer holds no role anywhere and is not read again.
///  STAGE 2  wire        signer: the LEDGER. Every owner-only action: role grants, token allowlists, flash-vault allowance and fee, the two
///                       controller hooks, the one-shot order-executor wiring, the seeds, and the QUEUEING of every timelocked action.
///  STAGE 3  execute     signer: the LEDGER, after `actionDelay`. Pair risk and the funded-liquidator allowlist (opens stay PAUSED).
///  STAGE 4  enable      signer: the LEDGER, only after `verify(4-pre)` passes. Executes the queued unpause.
///
/// Nothing here signs: every function takes the signer from `forge script --sender`. The risk numbers are CONSTANTS in this file on purpose
/// (an environment variable must not be able to change them); the other inputs are public addresses and amounts.
/// Mainnet only (chain id 43114). Fuji scripts are untouched.
struct MarginParams {
    address deployer; // throwaway, unprivileged
    address ledger; // owner of everything
    address controller; // PW30 Unitroller
    address pWavax;
    address pUsdc;
    uint256 actionDelay;
    address treasury;
    uint256 flashSeedUsdc;
    uint256 insuranceSeedUsdc;
    address[] funders; // the liquidator operators
}

struct MarginDeployment {
    address oracle; // the PW30 guarded oracle (not deployed here)
    address insuranceFund;
    address config;
    address feeDistributor;
    address vault;
    address riskEngine;
    address quoter;
    address swapModule;
    address accountFactory;
    address executorImpl;
    address executor;
    address liquidator;
    address flashVault;
    address clAdapter;
    address registryImpl;
    address registry;
    address closeAdapter;
}

abstract contract MarginChecks is Script {
    uint256 internal constant AVALANCHE_CHAIN_ID = 43_114;
    address internal constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address internal constant PHARAOH_ROUTER = 0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c;
    address internal constant PHARAOH_FACTORY = 0xAE6E5c62328ade73ceefD42228528b70c8157D0d;
    address internal constant PHARAOH_POOL = 0xf01449C0bA930B6e2CaCA3DEF3CCBd7a3E589534;
    int24 internal constant TICK_SPACING = 10;
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 internal constant MIN_DELAY = 1 hours;

    /// @dev The pair as proposed in the scope document. 2x, 25% maintenance, position cap USD 5,000, debt cap USD 2,500.
    function pairRisk() public pure returns (IsolatedMarginTypes.PairRiskConfig memory) {
        return IsolatedMarginTypes.PairRiskConfig({
            enabled: true,
            maxLeverageX100: 200,
            initialMarginBps: 5_000,
            maintenanceMarginBps: 2_500,
            liquidationTargetBps: 12_500,
            fullLiquidationHealthBps: 5_000,
            maxLiquidationBps: 5_000,
            liquidationBonusBps: 500,
            maxSlippageBps: 100,
            oracleDeviationBps: 100,
            maxPositionValueUsd: uint128(5_000e18),
            maxDebtValueUsd: uint128(2_500e18)
        });
    }

    function _proxyAdmin(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ADMIN_SLOT))));
    }

    function _impl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    function _eq(address a, address b, string memory why) internal pure {
        require(a == b, why);
    }

    function _checkParams(MarginParams memory p) internal view {
        require(block.chainid == AVALANCHE_CHAIN_ID, "Margin: Avalanche mainnet only");
        require(p.ledger != address(0) && p.deployer != address(0), "Margin: zero signer");
        require(p.deployer != p.ledger, "Margin: the deployer must not be the Ledger");
        require(p.actionDelay >= MIN_DELAY, "Margin: delay below the contract minimum");
        require(p.flashSeedUsdc > 0 && p.insuranceSeedUsdc > 0, "Margin: seeds must be positive");
        require(p.funders.length >= 1, "Margin: no funded liquidators");
        for (uint256 i; i < p.funders.length; ++i) {
            require(p.funders[i] != address(0) && p.funders[i] != p.ledger && p.funders[i] != p.deployer, "Margin: bad funder");
            for (uint256 j; j < i; ++j) {
                require(p.funders[i] != p.funders[j], "Margin: duplicate funder");
            }
        }
        require(p.controller.code.length > 0 && p.pWavax.code.length > 0 && p.pUsdc.code.length > 0, "Margin: PW30 not found");
        require(PErc20(p.pWavax).underlying() == WAVAX && PErc20(p.pUsdc).underlying() == USDC, "Margin: wrong market assets");
        require(
            address(PToken(p.pWavax).peridottroller()) == p.controller && address(PToken(p.pUsdc).peridottroller()) == p.controller,
            "Margin: markets on another controller"
        );
        Peridottroller c = Peridottroller(p.controller);
        _eq(c.admin(), p.ledger, "Margin: the Ledger is not the controller admin");
        // WAVAX borrowing must stay paused: that is what makes the product long-only
        require(c.borrowGuardianPaused(p.pWavax), "Margin: WAVAX borrowing is not paused");
        address oracle = address(c.oracle());
        require(oracle.code.length > 0, "Margin: controller oracle");
        require(IMarginPriceOracle(oracle).marketAsset(p.pWavax) == WAVAX, "Margin: oracle does not know pWAVAX");
        require(IMarginPriceOracle(oracle).marketAsset(p.pUsdc) == USDC, "Margin: oracle does not know pUSDC");
        require(IMarginPriceOracle(oracle).getPrice(WAVAX) > 0 && IMarginPriceOracle(oracle).getPrice(USDC) > 0, "Margin: no fresh price");
        IsolatedMarginMath.validateRiskConfig(pairRisk());
        require(PHARAOH_POOL.code.length > 0 && PHARAOH_ROUTER.code.length > 0 && PHARAOH_FACTORY.code.length > 0, "Margin: Pharaoh");
    }

    function _owner(address a) internal view returns (address) {
        return IOwnableLike(a).owner();
    }

    /// @dev stage: 1 after deploy, 2 after wire, 3 after execute (opens still paused), 4 after enable. The deployer-holds-nothing rule
    ///      is checked at EVERY stage: no owner, no proxy-admin owner, no allowlist entry, no pToken, no allowance names the deployer.
    function _verify(MarginDeployment memory d, MarginParams memory p, uint8 stage) internal view {
        _checkWiringConstants(d, p);
        // --- ownership: the Ledger owns everything; the deployer owns nothing
        address[8] memory owned = [d.insuranceFund, d.config, d.feeDistributor, d.vault, d.riskEngine, d.accountFactory, d.flashVault, d.registry];
        for (uint256 i; i < owned.length; ++i) {
            require(owned[i].code.length > 0, "verify: contract missing");
        }
        _eq(_owner(d.insuranceFund), p.ledger, "verify: insuranceFund owner");
        _eq(_owner(d.config), p.ledger, "verify: config owner");
        _eq(_owner(d.feeDistributor), p.ledger, "verify: feeDistributor owner");
        _eq(_owner(d.vault), p.ledger, "verify: vault owner");
        _eq(_owner(d.riskEngine), p.ledger, "verify: riskEngine owner");
        _eq(IsolatedMarginAccountFactory(d.accountFactory).configurator(), p.ledger, "verify: accountFactory configurator");
        _eq(_owner(d.flashVault), p.ledger, "verify: flashVault owner");
        address[8] memory proxies = [d.insuranceFund, d.config, d.feeDistributor, d.vault, d.riskEngine, d.executor, d.liquidator, d.registry];
        for (uint256 i; i < proxies.length; ++i) {
            address admin = _proxyAdmin(proxies[i]);
            require(admin.code.length > 0, "verify: proxy admin missing");
            _eq(_owner(admin), p.ledger, "verify: proxy admin owner is not the Ledger");
            require(_owner(admin) != p.deployer, "verify: deployer owns a proxy admin");
            require(_impl(proxies[i]).code.length > 0, "verify: implementation missing");
        }
        // --- deployer holds nothing: no funded-liquidator rights, no pTokens, no margin accounts, no allowance on the flash vault
        require(!IsolatedMarginConfigUpgradeable(d.config).fundedLiquidators(p.deployer), "verify: deployer is a funded liquidator");
        require(PToken(p.pUsdc).balanceOf(p.deployer) == 0 && PToken(p.pWavax).balanceOf(p.deployer) == 0, "verify: deployer holds pTokens");
        require(IERC20(USDC).allowance(p.deployer, d.flashVault) == 0, "verify: deployer allowance");
        // --- stage-dependent wiring
        IsolatedMarginConfigUpgradeable cfg = IsolatedMarginConfigUpgradeable(d.config);
        require(cfg.actionDelay() == p.actionDelay, "verify: actionDelay");
        require(cfg.opensPaused() == (stage < 4), stage < 4 ? "verify: opens must be paused" : "verify: opens must be live");
        Peridottroller c = Peridottroller(p.controller);
        if (stage < 2) {
            require(c.isolatedMarginRiskHook() == address(0), "verify: hook set too early");
            require(IsolatedMarginExecutorUpgradeable(d.executor).orderExecutor() == address(0), "verify: order executor set too early");
        } else {
            _eq(c.isolatedMarginRiskHook(), d.riskEngine, "verify: risk hook");
            _eq(c.isolatedMarginRegistrar(), d.riskEngine, "verify: registrar");
            _eq(IsolatedMarginExecutorUpgradeable(d.executor).orderExecutor(), d.closeAdapter, "verify: order executor");
            _eq(address(IsolatedMarginAccountFactory(d.accountFactory).executor()), d.executor, "verify: factory executor");
            _eq(address(IsolatedMarginVaultUpgradeable(d.vault).executor()), d.executor, "verify: vault executor");
            _eq(address(IsolatedMarginVaultUpgradeable(d.vault).liquidator()), d.liquidator, "verify: vault liquidator");
            require(IsolatedMarginVaultUpgradeable(d.vault).allowedPTokens(p.pUsdc), "verify: pUSDC not allowed in vault");
            require(IsolatedMarginVaultUpgradeable(d.vault).allowedPTokens(p.pWavax), "verify: pWAVAX not allowed in vault");
            SimpleFlashLoanVault fv = SimpleFlashLoanVault(d.flashVault);
            require(fv.tokenAllowed(USDC) && !fv.tokenAllowed(WAVAX), "verify: flash token allowlist");
            require(fv.feeBps() == 0 && fv.flashFee(USDC, 1_000_000e6) == 0, "verify: flash fee must be 0");
            require(IERC20(USDC).balanceOf(d.flashVault) >= p.flashSeedUsdc, "verify: flash vault unfunded");
            require(PToken(p.pUsdc).balanceOf(d.insuranceFund) > 0, "verify: insurance fund unseeded");
        }
        if (stage >= 3) {
            IsolatedMarginTypes.PairRiskConfig memory want = pairRisk();
            IsolatedMarginTypes.PairRiskConfig memory got = cfg.getPairRisk(p.pUsdc, p.pWavax, p.pUsdc);
            require(keccak256(abi.encode(want)) == keccak256(abi.encode(got)), "verify: pair risk differs from the proposed constants");
            for (uint256 i; i < p.funders.length; ++i) {
                require(cfg.fundedLiquidators(p.funders[i]), "verify: funder not added");
            }
        }
    }

    function _checkWiringConstants(MarginDeployment memory d, MarginParams memory p) internal view {
        // the risk engine, quoter and the controller all use the SAME guarded oracle
        _eq(d.oracle, address(Peridottroller(p.controller).oracle()), "verify: oracle is not the controller's");
        _eq(address(IsolatedMarginRiskEngineUpgradeable(d.riskEngine).oracle()), d.oracle, "verify: risk engine oracle");
        _eq(IsolatedMarginRiskEngineUpgradeable(d.riskEngine).controller(), p.controller, "verify: risk engine controller");
        _eq(address(IsolatedMarginRiskEngineUpgradeable(d.riskEngine).config()), d.config, "verify: risk engine config");
        IsolatedMarginConfigUpgradeable cfg = IsolatedMarginConfigUpgradeable(d.config);
        _eq(cfg.routerAdapter(), d.clAdapter, "verify: router adapter");
        _eq(cfg.flashLoanProvider(), d.flashVault, "verify: flash provider");
        _eq(cfg.insuranceFund(), d.insuranceFund, "verify: insurance fund");
        require(cfg.openFeeBps() == 0 && cfg.closeFeeBps() == 0, "verify: fees must be 0");
        require(cfg.feeImmediateShareBps() == 0 && cfg.feeStreamDuration() == 7 days, "verify: fee distribution");
        _eq(address(MarginOrderRegistry(d.registry).adapter()), d.closeAdapter, "verify: registry adapter");
        _eq(AvalancheMarginCloseAdapter(d.closeAdapter).registry(), d.registry, "verify: adapter registry");
        _eq(address(AvalancheMarginCloseAdapter(d.closeAdapter).executor()), d.executor, "verify: adapter executor");
        _eq(address(AvalancheMarginCloseAdapter(d.closeAdapter).oracle()), d.oracle, "verify: adapter oracle");
    }
}

contract DeployAvalancheMarginMainnet is MarginChecks {
    function readParams() public view returns (MarginParams memory p) {
        p.deployer = vm.envAddress("MARGIN_DEPLOYER");
        p.ledger = vm.envAddress("MARGIN_OWNER");
        p.controller = vm.envAddress("CONTROLLER");
        p.pWavax = vm.envAddress("PWAVAX");
        p.pUsdc = vm.envAddress("PUSDC");
        p.actionDelay = vm.envOr("MARGIN_ACTION_DELAY", uint256(24 hours));
        p.treasury = vm.envOr("MARGIN_TREASURY", p.ledger);
        p.flashSeedUsdc = vm.envUint("MARGIN_FLASH_SEED_USDC");
        p.insuranceSeedUsdc = vm.envUint("MARGIN_INSURANCE_SEED_USDC");
        p.funders = vm.envAddress("MARGIN_FUNDERS", ",");
    }

    function run() external returns (MarginDeployment memory d) {
        return deploy(readParams());
    }

    /// STAGE 1. The broadcaster is the throwaway deployer.
    function deploy(MarginParams memory p) public returns (MarginDeployment memory d) {
        _checkParams(p);
        require(Peridottroller(p.controller).isolatedMarginRiskHook() == address(0), "Margin: hook already set");
        address L = p.ledger;
        d.oracle = address(Peridottroller(p.controller).oracle());

        vm.startBroadcast(p.deployer);
        d.flashVault = address(new SimpleFlashLoanVault(L));
        d.clAdapter = address(new PharaohCLRouterAdapter(PHARAOH_ROUTER, PHARAOH_FACTORY, PHARAOH_POOL, WAVAX, USDC, TICK_SPACING));
        d.insuranceFund = _proxy(address(new MarginInsuranceFundUpgradeable()), L, abi.encodeWithSelector(MarginInsuranceFundUpgradeable.initialize.selector, L));
        d.config = _proxy(
            address(new IsolatedMarginConfigUpgradeable()),
            L,
            abi.encodeWithSelector(
                IsolatedMarginConfigUpgradeable.initialize.selector, L, p.actionDelay, d.clAdapter, d.flashVault, d.insuranceFund, p.treasury
            )
        );
        d.feeDistributor = _proxy(
            address(new MarginFeeDistributorUpgradeable()),
            L,
            abi.encodeWithSelector(MarginFeeDistributorUpgradeable.initialize.selector, L, d.config)
        );
        d.vault = _proxy(
            address(new IsolatedMarginVaultUpgradeable()),
            L,
            abi.encodeWithSelector(IsolatedMarginVaultUpgradeable.initialize.selector, L, d.feeDistributor)
        );
        d.riskEngine = _proxy(
            address(new IsolatedMarginRiskEngineUpgradeable()),
            L,
            abi.encodeWithSelector(IsolatedMarginRiskEngineUpgradeable.initialize.selector, L, d.config, d.oracle, p.controller)
        );
        d.quoter = address(new IsolatedMarginQuoter(d.config, d.oracle));
        d.swapModule = address(new IsolatedMarginSwapModule(d.config, d.quoter));
        d.accountFactory = address(new IsolatedMarginAccountFactory(L));
        d.executorImpl = address(new IsolatedMarginExecutorUpgradeable());
        d.executor = _proxy(
            d.executorImpl,
            L,
            abi.encodeWithSelector(
                IsolatedMarginExecutorUpgradeable.initialize.selector,
                d.config,
                d.riskEngine,
                d.vault,
                d.feeDistributor,
                d.quoter,
                d.swapModule,
                d.accountFactory
            )
        );
        d.liquidator = _proxy(
            address(new IsolatedMarginLiquidatorUpgradeable()),
            L,
            abi.encodeWithSelector(
                IsolatedMarginLiquidatorUpgradeable.initialize.selector,
                d.executor,
                d.config,
                d.riskEngine,
                d.vault,
                d.insuranceFund,
                d.quoter,
                d.swapModule
            )
        );
        // registry <-> adapter address cycle: predict the adapter from the deployer nonce (SPEC "Address order"), assert it below
        d.registryImpl = address(new MarginOrderRegistry());
        address predictedAdapter = vm.computeCreateAddress(p.deployer, vm.getNonce(p.deployer) + 1);
        d.registry = _proxy(d.registryImpl, L, abi.encodeWithSelector(MarginOrderRegistry.initialize.selector, predictedAdapter, L));
        d.closeAdapter = address(new AvalancheMarginCloseAdapter(d.executor, d.registry, d.oracle, d.quoter, d.config));
        require(d.closeAdapter == predictedAdapter, "Margin: adapter address prediction failed");
        vm.stopBroadcast();

        _verify(d, p, 1);
        _log(d);
    }

    function _proxy(address implementation, address proxyAdminOwner, bytes memory data) internal returns (address) {
        return address(new PeridotTransparentProxy(implementation, proxyAdminOwner, data));
    }

    function _log(MarginDeployment memory d) internal pure {
        console2.log("oracle (PW30 guarded, reused)", d.oracle);
        console2.log("insuranceFund", d.insuranceFund);
        console2.log("config", d.config);
        console2.log("feeDistributor", d.feeDistributor);
        console2.log("vault", d.vault);
        console2.log("riskEngine", d.riskEngine);
        console2.log("quoter", d.quoter);
        console2.log("swapModule", d.swapModule);
        console2.log("accountFactory", d.accountFactory);
        console2.log("executorImpl", d.executorImpl);
        console2.log("executor", d.executor);
        console2.log("liquidator", d.liquidator);
        console2.log("flashVault", d.flashVault);
        console2.log("clAdapter", d.clAdapter);
        console2.log("registryImpl", d.registryImpl);
        console2.log("registry", d.registry);
        console2.log("closeAdapter", d.closeAdapter);
    }
}

/// STAGES 2, 3, 4 and the read-only verification. The broadcaster of 2, 3 and 4 is the LEDGER.
contract OperateAvalancheMarginMainnet is MarginChecks {
    function readDeployment() public view returns (MarginDeployment memory d) {
        d.oracle = vm.envAddress("M_ORACLE");
        d.insuranceFund = vm.envAddress("M_INSURANCE_FUND");
        d.config = vm.envAddress("M_CONFIG");
        d.feeDistributor = vm.envAddress("M_FEE_DISTRIBUTOR");
        d.vault = vm.envAddress("M_VAULT");
        d.riskEngine = vm.envAddress("M_RISK_ENGINE");
        d.quoter = vm.envAddress("M_QUOTER");
        d.swapModule = vm.envAddress("M_SWAP_MODULE");
        d.accountFactory = vm.envAddress("M_ACCOUNT_FACTORY");
        d.executorImpl = vm.envAddress("M_EXECUTOR_IMPL");
        d.executor = vm.envAddress("M_EXECUTOR");
        d.liquidator = vm.envAddress("M_LIQUIDATOR");
        d.flashVault = vm.envAddress("M_FLASH_VAULT");
        d.clAdapter = vm.envAddress("M_CL_ADAPTER");
        d.registryImpl = vm.envAddress("M_REGISTRY_IMPL");
        d.registry = vm.envAddress("M_REGISTRY");
        d.closeAdapter = vm.envAddress("M_CLOSE_ADAPTER");
    }

    function readParams() public view returns (MarginParams memory p) {
        p.deployer = vm.envAddress("MARGIN_DEPLOYER");
        p.ledger = vm.envAddress("MARGIN_OWNER");
        p.controller = vm.envAddress("CONTROLLER");
        p.pWavax = vm.envAddress("PWAVAX");
        p.pUsdc = vm.envAddress("PUSDC");
        p.actionDelay = vm.envOr("MARGIN_ACTION_DELAY", uint256(24 hours));
        p.treasury = vm.envOr("MARGIN_TREASURY", p.ledger);
        p.flashSeedUsdc = vm.envUint("MARGIN_FLASH_SEED_USDC");
        p.insuranceSeedUsdc = vm.envUint("MARGIN_INSURANCE_SEED_USDC");
        p.funders = vm.envAddress("MARGIN_FUNDERS", ",");
    }

    /// read-only: `STAGE` = 1..4 (4 = after enable). `4-pre` is `preEnable`.
    function run() external view {
        MarginParams memory p = readParams();
        MarginDeployment memory d = readDeployment();
        _checkParams(p);
        _verify(d, p, uint8(vm.envUint("STAGE")));
        console2.log("verify passed at stage", vm.envUint("STAGE"));
    }

    // ------------------------------------------------------------------------------------------------ STAGE 2
    function wire() external {
        wire(readParams(), readDeployment());
    }

    function wire(MarginParams memory p, MarginDeployment memory d) public {
        _checkParams(p);
        _verify(d, p, 1);
        vm.startBroadcast(p.ledger);
        IsolatedMarginAccountFactory(d.accountFactory).setExecutor(d.executor);
        IsolatedMarginRiskEngineUpgradeable(d.riskEngine).setOperators(d.executor, d.liquidator);
        IsolatedMarginVaultUpgradeable(d.vault).setExecutor(d.executor);
        IsolatedMarginVaultUpgradeable(d.vault).setLiquidator(d.liquidator);
        MarginFeeDistributorUpgradeable(d.feeDistributor).setVault(d.vault);
        MarginFeeDistributorUpgradeable(d.feeDistributor).setFeeCollector(d.vault, true);
        MarginFeeDistributorUpgradeable(d.feeDistributor).setFeeCollector(d.executor, true);
        MarginInsuranceFundUpgradeable(d.insuranceFund).setLiquidator(d.liquidator);
        IsolatedMarginVaultUpgradeable(d.vault).setPTokenAllowed(p.pUsdc, true);
        IsolatedMarginVaultUpgradeable(d.vault).setPTokenAllowed(p.pWavax, true);

        // the flash vault: USDC only, fee 0, funded with the seed
        SimpleFlashLoanVault fv = SimpleFlashLoanVault(d.flashVault);
        fv.setTokenAllowed(USDC, true);
        fv.setFeeBps(0);
        IERC20(USDC).approve(d.flashVault, p.flashSeedUsdc);
        fv.depositLiquidity(USDC, p.flashSeedUsdc);

        // insurance seed: mint pUSDC and move exactly the minted amount to the fund
        uint256 before_ = PToken(p.pUsdc).balanceOf(p.ledger);
        IERC20(USDC).approve(p.pUsdc, p.insuranceSeedUsdc);
        require(PErc20(p.pUsdc).mint(p.insuranceSeedUsdc) == 0, "Margin: insurance mint failed");
        uint256 minted = PToken(p.pUsdc).balanceOf(p.ledger) - before_;
        require(PToken(p.pUsdc).transfer(d.insuranceFund, minted), "Margin: insurance transfer failed");

        // the controller hooks (admin only) and the one-shot order-executor wiring through the proxy admin
        require(Peridottroller(p.controller)._setIsolatedMarginRiskHook(d.riskEngine) == 0, "Margin: hook failed");
        require(Peridottroller(p.controller)._setIsolatedMarginRegistrar(d.riskEngine) == 0, "Margin: registrar failed");
        IProxyAdminLike(_proxyAdmin(d.executor)).upgradeAndCall(
            d.executor, d.executorImpl, abi.encodeWithSelector(IsolatedMarginExecutorUpgradeable.initializeOrderExecutor.selector, d.closeAdapter)
        );

        // queue every timelocked action (24 h by default): the clock starts now
        IsolatedMarginConfigUpgradeable cfg = IsolatedMarginConfigUpgradeable(d.config);
        cfg.queuePairRisk(p.pUsdc, p.pWavax, p.pUsdc, pairRisk());
        for (uint256 i; i < p.funders.length; ++i) {
            cfg.queueFundedLiquidator(p.funders[i]);
        }
        cfg.queueUnpauseOpens();
        vm.stopBroadcast();
        _verify(d, p, 2);
        console2.log("wire done; queued actions execute after", block.timestamp + p.actionDelay);
    }

    // ------------------------------------------------------------------------------------------------ STAGE 3
    function execute() external {
        execute(readParams(), readDeployment());
    }

    function execute(MarginParams memory p, MarginDeployment memory d) public {
        _checkParams(p);
        IsolatedMarginConfigUpgradeable cfg = IsolatedMarginConfigUpgradeable(d.config);
        vm.startBroadcast(p.ledger);
        cfg.setPairRisk(p.pUsdc, p.pWavax, p.pUsdc, pairRisk());
        for (uint256 i; i < p.funders.length; ++i) {
            cfg.addFundedLiquidator(p.funders[i]);
        }
        vm.stopBroadcast();
        _verify(d, p, 3);
    }

    // ------------------------------------------------------------------------------------------------ STAGE 4
    /// the gates that replace the Fuji confirmations: they are CHECKED here, not asserted by environment flags
    function preEnable(MarginParams memory p, MarginDeployment memory d) public view {
        _verify(d, p, 3);
        IMarginPriceOracle o = IMarginPriceOracle(d.oracle);
        require(o.getPrice(WAVAX) > 0 && o.getPrice(USDC) > 0, "enable: no fresh price");
        require(SimpleFlashLoanVault(d.flashVault).maxFlashLoan(USDC) >= p.flashSeedUsdc, "enable: flash liquidity");
        require(PToken(p.pUsdc).balanceOf(d.insuranceFund) > 0, "enable: insurance");
        require(Peridottroller(p.controller).borrowGuardianPaused(p.pWavax), "enable: WAVAX borrowing must stay paused");
    }

    function enable() external {
        enable(readParams(), readDeployment());
    }

    function enable(MarginParams memory p, MarginDeployment memory d) public {
        preEnable(p, d);
        vm.startBroadcast(p.ledger);
        IsolatedMarginConfigUpgradeable(d.config).unpauseOpens();
        vm.stopBroadcast();
        _verify(d, p, 4);
    }
}

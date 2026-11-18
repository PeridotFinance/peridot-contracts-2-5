// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {InterestRateModel} from "../contracts/InterestRateModel.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";
import {PharaohDlmmShareOracle} from "../contracts/PharaohDlmmShareOracle.sol";
import {PriceOracle} from "../contracts/PriceOracle.sol";
import {PharaohBoostedDelegate} from "../contracts/boosted/PharaohBoostedDelegate.sol";

interface IBpController {
    function admin() external view returns (address);
    function oracle() external view returns (address);
    function markets(address pToken)
        external
        view
        returns (bool isListed, uint256 collateralFactorMantissa, bool isPeridoted);
    function getAllMarkets() external view returns (address[] memory);
    function mintGuardianPaused(address pToken) external view returns (bool);
    function borrowGuardianPaused(address pToken) external view returns (bool);
    function borrowCaps(address pToken) external view returns (uint256);
    function borrowCashFloor(address pToken) external view returns (uint256);
    function closeFactorMantissa() external view returns (uint256);
    function liquidationIncentiveMantissa() external view returns (uint256);
}

interface IBpVault {
    function asset() external view returns (address);
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function convertToAssets(uint256) external view returns (uint256);
    function depositCap() external view returns (uint256);
}

interface IBpProxyAdmin {
    function owner() external view returns (address);
}

interface IBpMarket {
    function admin() external view returns (address);
    function pendingAdmin() external view returns (address);
    function implementation() external view returns (address);
    function underlying() external view returns (address);
    function peridottroller() external view returns (address);
    function interestRateModel() external view returns (address);
    function decimals() external view returns (uint8);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function totalSupply() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function totalReserves() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function getCash() external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function flashLoansPaused() external view returns (bool);
    function pharaohVault() external view returns (address);
    function minimumVaultSupplyAtListing() external view returns (uint256);
}

interface IBpOracle {
    function baseOracle() external view returns (address);
    function market() external view returns (address);
    function vault() external view returns (address);
    function vaultAsset() external view returns (address);
    function getUnderlyingPrice(address pToken) external view returns (uint256);
    function getPrice(address asset) external view returns (uint256);
    function marketAsset(address pToken) external view returns (address);
}

interface IBpBaseOracle {
    function getUnderlyingPrice(address pToken) external view returns (uint256);
    function getPrice(address asset) external view returns (uint256);
    function marketAsset(address pToken) external view returns (address);
}

/**
 * @title DeployPharaohBoostedMarketsAvalanche (rewritten 18 Nov 2026 for the ONE market bpPHAR-USDC)
 * @notice The market is the share token of the Peridot Pharaoh DLMM USDC/USDt vault, listed on the LIVE Avalanche pilot controller.
 *         The script never holds a key: the signer comes from `forge script --account <keystore> --sender <deployer>` (live) or
 *         `--unlocked --sender` (rehearsal), and the deployer address is passed as BP_DEPLOYER (public).
 *
 *   check           read-only preflight of the live facts (no env except the endpoint)
 *   deploy          signer: the THROWAWAY DEPLOYER. Three contracts, no controller call, no vault call, no role kept:
 *                     1. PharaohBoostedDelegate (market implementation; no constructor arguments)
 *                     2. PErc20Delegator: underlying = the DLMM vault share, admin = THE LEDGER FROM THE CONSTRUCTOR (the delegator sets
 *                        `admin = admin_` as its last statement, so there is no _setPendingAdmin/_acceptAdmin round trip and no moment
 *                        at which the deployer is admin after the transaction), initial exchange rate 2e14 (= 0.02 x 10^(18+6-8), the
 *                        pilot pUSDC rule), become-implementation data = (vault, MINIMUM_VAULT_SUPPLY)
 *                     3. PharaohDlmmShareOracle(base = the live guarded oracle, market): stateless, ownerless
 *                   Nothing is listed, no oracle is replaced, nothing is approved or transferred.
 *   verifyDeployed  read-only (env BP_DELEGATE, BP_MARKET, BP_ORACLE): code hashes against a fresh build in this very run, every pin,
 *                   identity of the wrapper with the guarded oracle for every listed market, the share price
 *   verifyListing   read-only (env as above + BP_STAGE 1..4): the cumulative controller state after each Ledger stage
 *                     1 oracle swapped   2 listed + CF 0 + borrow paused + cap 1   3 seeded + mint paused   4 activated (CF 50%, mint open)
 */
contract DeployPharaohBoostedMarketsAvalanche is Script {
    uint256 internal constant AVALANCHE_CHAIN_ID = 43_114;

    // ---------------------------------------------------------------- LIVE FACTS (public; verified 18 Nov 2026, see the ceremony document)
    address internal constant LEDGER = 0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD;
    address internal constant SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
    address internal constant CONTROLLER = 0xbE938cD7C25E0E4d0604Fa3F9f0a8b5b67b3D51A;
    address internal constant GUARDED_ORACLE = 0x7BAB5406Cb4929f9b9492e1b2a43b65BF93AaFC0;
    address internal constant PWAVAX = 0x12f1F4Fc057a76f473B781ce2Fa88E55ef8581B1;
    address internal constant PUSDC = 0x0f7849CD9E54ffb027aacaEec82007cca9470098;
    address internal constant RATE_MODEL = 0xe5a82bF40b493cf37C06851A934370F3f0896263;
    address internal constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address internal constant VAULT = 0x278B1b625C74B1926C5F989ddE601f3C5Ba27f7D;
    address internal constant VAULT_IMPL = 0x7F204f63152c577358fDaFbB7939CdC06D61a093;
    address internal constant VAULT_PROXY_ADMIN = 0x7037fa4B1870dFd28FF9c057Cf49A0f83011268A;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 internal constant EIP1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // ---------------------------------------------------------------- PARAMETERS
    /// @dev The vault's own MIN_SUPPLY / dead seed; a CONSTANT (never read from the live vault at broadcast time, which could revert
    ///      between simulation and broadcast on an open vault).
    uint256 internal constant MINIMUM_VAULT_SUPPLY = 1_000_000;
    uint8 internal constant PTOKEN_DECIMALS = 8;
    uint8 internal constant SHARE_DECIMALS = 6;
    /// @dev 2 x 10^(shareDecimals + 16 - pTokenDecimals) = 2e14: the Compound 0.02 rule for a 6-decimal underlying and an 8-decimal pToken.
    uint256 internal constant INITIAL_EXCHANGE_RATE = 2e14;
    /// @dev The permanent seed: 1,000,000 share-wei = 1 whole share = about 1 USD = 5,000,000,000 pToken-wei at the initial rate.
    uint256 internal constant SEED_SHARES = 1_000_000;
    uint256 internal constant SEED_PTOKENS = SEED_SHARES * 5000;
    uint256 internal constant CF_ACTIVE = 0.5e18;
    string internal constant NAME = "Peridot Boosted Pharaoh DLMM USDC/USDt";
    string internal constant SYMBOL = "bpPHAR-USDC";

    struct New {
        address delegate;
        address market;
        address oracle;
    }

    error BpDlmm__WrongChain(uint256 actual);
    error BpDlmm__Check(string what);

    function run() external view {
        check();
    }

    // ================================================================================================= check
    function check() public view {
        if (block.chainid != AVALANCHE_CHAIN_ID) revert BpDlmm__WrongChain(block.chainid);
        IBpController c = IBpController(CONTROLLER);
        _req(c.admin() == LEDGER, "controller admin is not the Ledger");
        _req(c.oracle() == GUARDED_ORACLE, "controller oracle is not the guarded oracle (already swapped, or drift)");
        _req(IBpBaseOracle(GUARDED_ORACLE).getPrice(USDC) != 0, "guarded oracle has no USDC price right now");
        _req(IBpBaseOracle(GUARDED_ORACLE).getUnderlyingPrice(PUSDC) != 0, "guarded oracle has no pUSDC price right now");
        _req(InterestRateModel(RATE_MODEL).isInterestRateModel(), "rate model");
        (bool l1,,) = c.markets(PWAVAX);
        (bool l2,,) = c.markets(PUSDC);
        _req(l1 && l2, "pWAVAX / pUSDC are not listed");

        IBpVault v = IBpVault(VAULT);
        _req(v.asset() == USDC, "vault asset is not USDC");
        _req(v.decimals() == SHARE_DECIMALS, "vault share decimals != 6");
        _req(v.owner() == SAFE, "vault owner is not the Safe");
        _req(!v.paused(), "vault is paused");
        _req(address(uint160(uint256(vm.load(VAULT, EIP1967_ADMIN_SLOT)))) == VAULT_PROXY_ADMIN, "vault proxy admin slot");
        _req(address(uint160(uint256(vm.load(VAULT, EIP1967_IMPL_SLOT)))) == VAULT_IMPL, "vault implementation slot");
        _req(IBpProxyAdmin(VAULT_PROXY_ADMIN).owner() == SAFE, "vault ProxyAdmin owner is not the Safe");
        _req(v.totalSupply() >= MINIMUM_VAULT_SUPPLY, "vault supply below the minimum");
        _req(v.balanceOf(LEDGER) >= SEED_SHARES, "the Ledger holds fewer shares than the seed");
        uint256 perShare;
        try v.convertToAssets(10 ** SHARE_DECIMALS) returns (uint256 x) {
            perShare = x;
        } catch {
            revert BpDlmm__Check("vault convertToAssets reverts (a vault feed is stale): do not list now");
        }
        _req(perShare > 0, "vault share price is zero");
        console2.log("vault assets per whole share (6 dec):", perShare);
        console2.log("vault totalSupply:", v.totalSupply());
        console2.log("vault depositCap:", v.depositCap());
        console2.log("vault Ledger shares:", v.balanceOf(LEDGER));
        console2.log("check: OK");
    }

    // ================================================================================================ deploy
    function deploy() external returns (New memory n) {
        return deployAs(vm.envAddress("BP_DEPLOYER"));
    }

    function deployAs(address deployer) public returns (New memory n) {
        require(deployer != LEDGER && deployer != address(0), "BP_DEPLOYER must be a throwaway key, not the Ledger");
        check();

        vm.startBroadcast(deployer);
        PharaohBoostedDelegate delegate = new PharaohBoostedDelegate();
        PErc20Delegator market = new PErc20Delegator(
            VAULT,
            PeridottrollerInterface(CONTROLLER),
            InterestRateModel(RATE_MODEL),
            INITIAL_EXCHANGE_RATE,
            NAME,
            SYMBOL,
            PTOKEN_DECIMALS,
            payable(LEDGER),
            address(delegate),
            abi.encode(VAULT, MINIMUM_VAULT_SUPPLY)
        );
        PharaohDlmmShareOracle oracle = new PharaohDlmmShareOracle(PriceOracle(GUARDED_ORACLE), address(market));
        vm.stopBroadcast();

        n = New({delegate: address(delegate), market: address(market), oracle: address(oracle)});
        _checkNew(n, deployer);
        console2.log("delegate:", n.delegate);
        console2.log("market:", n.market);
        console2.log("oracle:", n.oracle);
    }

    // ======================================================================================== verifyDeployed
    function verifyDeployed() external {
        verifyDeployedFor(_envNew());
    }

    function verifyDeployedFor(New memory n) public {
        check();
        _checkNew(n, address(0));
        require(IBpController(CONTROLLER).oracle() == GUARDED_ORACLE, "stage 0: the controller must still use the guarded oracle");
        (bool listed,,) = IBpController(CONTROLLER).markets(n.market);
        require(!listed, "stage 0: the market must not be listed yet");
        console2.log("verifyDeployed: OK");
    }

    // ========================================================================================== verifyListing
    function verifyListing() external view {
        verifyListingFor(_envNew(), vm.envUint("BP_STAGE"));
    }

    function verifyListingFor(New memory n, uint256 stage) public view {
        require(stage >= 1 && stage <= 4, "BP_STAGE must be 1..4");
        IBpController c = IBpController(CONTROLLER);
        IBpMarket m = IBpMarket(n.market);

        _req(c.admin() == LEDGER, "controller admin");
        _req(m.admin() == LEDGER && m.pendingAdmin() == address(0), "market admin");
        _req(c.oracle() == n.oracle, "controller oracle is not the wrapper");
        _checkIdentity(n);
        {
            uint256 p = IBpOracle(n.oracle).getUnderlyingPrice(n.market);
            _req(p > 0.9e30 && p < 1.5e30, "bpPHAR price outside the sane band (0.9..1.5 USD per share)");
            console2.log("bpPHAR underlying price (1e30 = 1 USD per share):", p);
        }

        (bool listed, uint256 cf,) = c.markets(n.market);
        if (stage == 1) {
            _req(!listed, "stage 1: the market must not be listed yet");
        } else {
            _req(listed, "market not listed");
            _req(c.borrowGuardianPaused(n.market), "borrow is NOT paused on the share market");
            _req(c.borrowCaps(n.market) == 1, "borrow cap must be exactly 1 (0 means unlimited)");
            _req(m.flashLoansPaused(), "flash loans are not paused");
            _req(m.totalBorrows() == 0 && m.totalReserves() == 0, "the share market has borrows or reserves");
            console2.log("borrowCashFloor (informational):", c.borrowCashFloor(n.market));
        }
        if (stage == 2) {
            _req(cf == 0, "stage 2: CF must be 0");
            _req(!c.mintGuardianPaused(n.market), "stage 2: mint must still be open for the seed");
            _req(m.totalSupply() == 0, "stage 2: the market must be unseeded");
        }
        if (stage >= 3) {
            _req(m.totalSupply() == SEED_PTOKENS, "pToken supply != the seed (5,000,000,000)");
            _req(m.balanceOf(DEAD) == SEED_PTOKENS, "the dead address does not hold the whole seed");
            _req(m.balanceOf(LEDGER) == 0, "the Ledger still holds pTokens");
            _req(IBpVault(VAULT).balanceOf(n.market) == SEED_SHARES && m.getCash() == SEED_SHARES, "market cash != the seed shares");
            _req(m.exchangeRateStored() == INITIAL_EXCHANGE_RATE, "exchange rate moved (a donation?)");
        }
        if (stage == 3) {
            _req(cf == 0, "stage 3: CF must be 0");
            _req(c.mintGuardianPaused(n.market), "stage 3: mint must be paused");
        }
        if (stage == 4) {
            _req(cf == CF_ACTIVE, "stage 4: CF must be 0.5");
            _req(!c.mintGuardianPaused(n.market), "stage 4: mint must be open");
        }
        _logExisting();
        console2.log("verifyListing stage OK:", stage);
    }

    // ------------------------------------------------------------------------------------------- internals
    function _envNew() internal view returns (New memory n) {
        n = New({delegate: vm.envAddress("BP_DELEGATE"), market: vm.envAddress("BP_MARKET"), oracle: vm.envAddress("BP_ORACLE")});
    }

    /// @dev everything about the three new contracts, from the chain (or the simulation) alone.
    function _checkNew(New memory n, address deployer) internal {
        require(n.delegate.code.length > 0 && n.market.code.length > 0 && n.oracle.code.length > 0, "a new contract has no code");
        // code hashes against a fresh build in THIS run (same compiler settings as the deployment). The DELEGATE is not compared here:
        // PToken creates a BorrowAccountingModule in its constructor and keeps its address as an immutable, so every delegate instance has its
        // own runtime hash. tools/bp-dlmm-ceremony.sh verify-deployed compares it with the build's immutable-zeroed artifact instead.
        _req(
            n.oracle.codehash == address(new PharaohDlmmShareOracle(PriceOracle(GUARDED_ORACLE), n.market)).codehash,
            "oracle code differs from this build"
        );
        _req(
            n.market.codehash
                == address(
                    new PErc20Delegator(
                        VAULT,
                        PeridottrollerInterface(CONTROLLER),
                        InterestRateModel(RATE_MODEL),
                        INITIAL_EXCHANGE_RATE,
                        NAME,
                        SYMBOL,
                        PTOKEN_DECIMALS,
                        payable(LEDGER),
                        n.delegate,
                        abi.encode(VAULT, MINIMUM_VAULT_SUPPLY)
                    )
                ).codehash,
            "market (delegator) code differs from this build"
        );

        IBpMarket m = IBpMarket(n.market);
        _req(m.admin() == LEDGER, "market admin is not the Ledger");
        _req(m.pendingAdmin() == address(0), "market has a pending admin");
        if (deployer != address(0)) _req(m.admin() != deployer, "the deployer is admin");
        _req(m.implementation() == n.delegate, "market implementation");
        _req(m.underlying() == VAULT, "market underlying is not the DLMM vault");
        _req(m.peridottroller() == CONTROLLER, "market controller");
        _req(m.interestRateModel() == RATE_MODEL, "market rate model");
        _req(m.decimals() == PTOKEN_DECIMALS, "market decimals");
        _req(
            keccak256(bytes(m.name())) == keccak256(bytes(NAME)) && keccak256(bytes(m.symbol())) == keccak256(bytes(SYMBOL)),
            "market name/symbol"
        );
        _req(m.exchangeRateStored() == INITIAL_EXCHANGE_RATE, "market exchange rate");
        _req(m.flashLoansPaused(), "flash loans are not paused from birth");
        _req(m.pharaohVault() == VAULT && m.minimumVaultSupplyAtListing() == MINIMUM_VAULT_SUPPLY, "delegate pin");

        IBpOracle o = IBpOracle(n.oracle);
        _req(o.baseOracle() == GUARDED_ORACLE && o.market() == n.market, "oracle pins");
        _req(o.vault() == VAULT && o.vaultAsset() == USDC, "oracle vault pins");
        uint256 p = o.getUnderlyingPrice(n.market);
        _req(p > 0.9e30 && p < 1.5e30, "share price outside the sane band (0.9..1.5 USD per share)");
        _checkIdentity(n);
    }

    /// @dev wrapper == guarded oracle, value for value, for every market the controller lists (except the new one) and the margin surface.
    function _checkIdentity(New memory n) internal view {
        address[] memory all = IBpController(CONTROLLER).getAllMarkets();
        for (uint256 i; i < all.length; ++i) {
            if (all[i] == n.market) continue;
            _req(
                IBpOracle(n.oracle).getUnderlyingPrice(all[i]) == IBpBaseOracle(GUARDED_ORACLE).getUnderlyingPrice(all[i]),
                "identity: getUnderlyingPrice differs from the guarded oracle"
            );
            _req(
                IBpOracle(n.oracle).marketAsset(all[i]) == IBpBaseOracle(GUARDED_ORACLE).marketAsset(all[i]),
                "identity: marketAsset differs"
            );
        }
        address[3] memory assets = [USDC, WAVAX, VAULT];
        for (uint256 i; i < assets.length; ++i) {
            _req(
                IBpOracle(n.oracle).getPrice(assets[i]) == IBpBaseOracle(GUARDED_ORACLE).getPrice(assets[i]),
                "identity: getPrice differs"
            );
        }
        _req(IBpOracle(n.oracle).marketAsset(n.market) == address(0), "the share market must not be a margin market");
    }

    function _logExisting() internal view {
        IBpController c = IBpController(CONTROLLER);
        (, uint256 cfW,) = c.markets(PWAVAX);
        (, uint256 cfU,) = c.markets(PUSDC);
        console2.log("pWAVAX CF / borrow paused:", cfW, c.borrowGuardianPaused(PWAVAX));
        console2.log("pUSDC CF / borrow cap:", cfU, c.borrowCaps(PUSDC));
        console2.log("closeFactor / liquidationIncentive:", c.closeFactorMantissa(), c.liquidationIncentiveMantissa());
    }

    function _req(bool ok, string memory what) internal pure {
        if (!ok) revert BpDlmm__Check(what);
    }
}

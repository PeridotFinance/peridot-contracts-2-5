// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {PharaohDlmmVault} from "../src/PharaohDlmmVault.sol";
import {IPharaohDlmmVault} from "../src/IPharaohDlmmVault.sol";
import {IDLMMPair} from "../src/interfaces/IDLMMPair.sol";
import {IDLMMFactory} from "../src/interfaces/IDLMMFactory.sol";
import {IDLMMRewarder, IDLMMVoter, IDLMMRewarderBeacon} from "../src/interfaces/IDLMMRewarder.sol";
import {IChainlinkFeed} from "../src/interfaces/IChainlinkFeed.sol";

interface ISafeLike {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function VERSION() external view returns (string memory);
}

interface IErc20Dec {
    function decimals() external view returns (uint8);
}

/// @notice Mainnet (Avalanche C-chain 43114) deployment of the Pharaoh DLMM USDC/USDt 3-bin vault. Spec: docs/deployment-handoffs/avalanche-pharaoh-dlmm-vault-spec.md
///         section 8; ceremony: docs/deployment-handoffs/avalanche-dlmm-vault-ceremony.md.
///
///  What it does, in this order:
///   1. PRE-FLIGHT, read-only, BEFORE the first broadcast (any revert here sends nothing): chain id, token order of the pair, bin step, factory
///      registration, rewarder is the pair's hook and linked, the router is an authorised DLMM manager, the rewarder implementation codehash read from
///      the beacon on chain EQUALS the env-supplied expected value, both Chainlink feeds (8 decimals, fresh, inside the band), the Safe is the
///      Peridot 1-of-1 Safe owned by the Ledger, the deployer is fresh (nonce 0) and is none of the roles.
///   2. DEPLOY (two transactions from the deployer, nonces 0 and 1): the implementation (its constructor deploys the pair validator at
///      CREATE(implementation, 1)), then a TransparentUpgradeableProxy whose constructor delegatecalls `initialize(InitParams)`: cap 200_000_000, owner =
///      the Safe, rebalancer = the keeper wallet. OpenZeppelin v5's proxy creates ITS OWN ProxyAdmin owned by the `initialOwner` argument, which is the
///      Safe: there is no ownership hand-over step and the deployer is never an owner of anything. The vault is created PAUSED (initialize).
///   3. POST-CHECKS on the state the script itself produced (the on-chain read-back is ReadBackPharaohDlmmVault.s.sol, run afterwards).
///
/// Signer: the broadcaster given by `forge script --sender/--account` (the throwaway deployer). Nothing here holds or reads a key.
/// Environment (public values only): DEPLOYER (must equal the broadcaster), REBALANCER (the keeper wallet), EXPECTED_REWARDER_IMPL_CODEHASH (bytes32),
/// optional VAULT_NAME / VAULT_SYMBOL. The chain facts (pair, router, factory, rewarder, tokens, feeds, Safe, Ledger) are CONSTANTS below on purpose.
contract DeployPharaohDlmmVault is Script {
    // ---- chain facts (public). Every one is re-checked on chain in the pre-flight.
    address internal constant SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
    address internal constant LEDGER = 0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD;
    address internal constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant USDT = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7;
    address internal constant PAIR = 0x16888EE58E706C253b821EAA637ae9b2cFeA255C;
    address internal constant ROUTER = 0xff2BEFC4ff86CB0f3e8D3d9D6200B7A05BF5D93d;
    address internal constant FACTORY = 0xEb480050b016f6c6d45203D2346B68bDDDa23D4D;
    address internal constant REWARDER = 0x32E68C4b8Edc6d1F16E99EbA826B292FDC18daDC;
    address internal constant FEED_USDC = 0xF096872672F44d6EBA71458D74fe67F9a77a23B9;
    address internal constant FEED_USDT = 0xEBE676ee90Fe1112671f19b6B7459bC678B67e8a;
    uint16 internal constant BIN_STEP = 1;
    uint256 internal constant DEPOSIT_CAP = 200_000_000;
    uint256 internal constant MAX_FEED_AGE = 93_600; // the vault's default maxFeedAge
    uint256 internal constant FEED_BAND = 0.005e8; // 1.00 +- 0.50 % (the vault's default legBandBps 50)
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct Outputs {
        address implementation;
        address validator;
        address proxy;
        address proxyAdmin;
    }

    function run() external returns (Outputs memory o) {
        address deployer = vm.envAddress("DEPLOYER");
        address rebalancer = vm.envAddress("REBALANCER");
        bytes32 expectedHash = vm.envBytes32("EXPECTED_REWARDER_IMPL_CODEHASH");
        string memory name = vm.envOr("VAULT_NAME", string("Peridot Pharaoh DLMM USDC/USDt"));
        string memory symbol = vm.envOr("VAULT_SYMBOL", string("pdUSDC"));

        bytes32 liveHash = _preflight(deployer, rebalancer, expectedHash);

        IPharaohDlmmVault.InitParams memory p = IPharaohDlmmVault.InitParams({
            asset: USDC,
            pairToken: USDT,
            pair: PAIR,
            router: ROUTER,
            factory: FACTORY,
            rewarder: REWARDER,
            rewarderImplCodehash: liveHash,
            feedAsset: FEED_USDC,
            feedPair: FEED_USDT,
            binStep: BIN_STEP,
            owner: SAFE,
            rebalancer: rebalancer,
            depositCap: DEPOSIT_CAP,
            name: name,
            symbol: symbol
        });

        vm.startBroadcast();
        (VmSafe.CallerMode mode, address sender,) = vm.readCallers();
        require(mode == VmSafe.CallerMode.Broadcast && sender == deployer, "broadcaster is not DEPLOYER");
        PharaohDlmmVault impl = new PharaohDlmmVault(); // tx 1 (deployer nonce 0); its constructor deploys the validator
        // tx 2 (deployer nonce 1): initialOwner of the proxy's own ProxyAdmin = the SAFE (no hand-over step)
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(impl), SAFE, abi.encodeCall(PharaohDlmmVault.initialize, (p)));
        vm.stopBroadcast();

        o.implementation = address(impl);
        o.validator = vm.computeCreateAddress(address(impl), 1);
        o.proxy = address(proxy);
        o.proxyAdmin = address(uint160(uint256(vm.load(address(proxy), ADMIN_SLOT))));
        _postchecks(o, deployer, rebalancer, liveHash);

        console2.log("== DEPLOYED (public addresses; the wrapper writes them to the addresses file)");
        console2.log("DLMM_IMPLEMENTATION=%s", o.implementation);
        console2.log("DLMM_VALIDATOR=%s", o.validator);
        console2.log("DLMM_VAULT=%s", o.proxy);
        console2.log("DLMM_PROXY_ADMIN=%s", o.proxyAdmin);
        console2.log("DLMM_REWARDER_IMPL_CODEHASH=%s", vm.toString(liveHash));
    }

    // ------------------------------------------------------------------------------------------------------------------ pre-flight
    function _preflight(address deployer, address rebalancer, bytes32 expectedHash) internal view returns (bytes32 liveHash) {
        require(block.chainid == 43114, "preflight: not Avalanche C-chain (43114)");

        // roles: the deployer is a fresh throwaway and none of the roles; the keeper is a new EOA, not the Safe, not the Ledger
        require(deployer != address(0) && deployer != SAFE && deployer != LEDGER, "preflight: DEPLOYER is the Safe, the Ledger or zero");
        require(rebalancer != address(0) && rebalancer != SAFE && rebalancer != LEDGER, "preflight: REBALANCER is the Safe, the Ledger or zero");
        require(rebalancer != deployer, "preflight: REBALANCER == DEPLOYER");
        require(deployer.code.length == 0, "preflight: DEPLOYER has code");
        require(rebalancer.code.length == 0, "preflight: REBALANCER has code");
        require(vm.getNonce(deployer) == 0, "preflight: DEPLOYER nonce != 0 (use a fresh key: the planned addresses and the nonce read-back assume 0)");

        // the Safe is Peridot's 1-of-1 Safe 1.4.1 owned by the Ledger
        ISafeLike safe = ISafeLike(SAFE);
        address[] memory owners = safe.getOwners();
        require(owners.length == 1 && owners[0] == LEDGER, "preflight: the Safe's owner is not exactly the Ledger");
        require(safe.getThreshold() == 1, "preflight: Safe threshold != 1");
        require(keccak256(bytes(safe.VERSION())) == keccak256("1.4.1"), "preflight: Safe version != 1.4.1");

        // tokens and pair
        require(IErc20Dec(USDC).decimals() == 6 && IErc20Dec(USDT).decimals() == 6, "preflight: token decimals != 6");
        IDLMMPair pair = IDLMMPair(PAIR);
        require(pair.getTokenX() == USDT && pair.getTokenY() == USDC, "preflight: pair token order is not X = USDt, Y = USDC");
        require(pair.getBinStep() == BIN_STEP && pair.getFactory() == FACTORY, "preflight: pair bin step / factory");
        IDLMMFactory.LBPairInformation memory info = IDLMMFactory(FACTORY).getLBPairInformation(USDC, USDT, BIN_STEP);
        require(info.LBPair == PAIR && info.binStep == BIN_STEP, "preflight: the factory does not register this pair");

        // rewarder: the pair's hook, linked, router authorised, listed by the beacon, implementation codehash pinned
        require(address(uint160(uint256(pair.getLBHooksParameters()))) == REWARDER, "preflight: the pair's hook is not the rewarder");
        IDLMMRewarder rw = IDLMMRewarder(REWARDER);
        require(rw.isLinked(), "preflight: rewarder is not linked");
        address voter = rw.owner();
        require(voter != address(0) && IDLMMVoter(voter).isAuthorizedDLMMManager(ROUTER), "preflight: the router is not an authorised DLMM manager");
        address beacon = IDLMMVoter(voter).dlmmRewarderFactory();
        require(beacon != address(0) && IDLMMRewarderBeacon(beacon).getRewarder(PAIR) == REWARDER, "preflight: the beacon does not list the rewarder for the pair");
        liveHash = IDLMMRewarderBeacon(beacon).implementation().codehash;
        require(liveHash != bytes32(0), "preflight: beacon implementation has no code");
        require(liveHash == expectedHash, "preflight: beacon implementation codehash != EXPECTED_REWARDER_IMPL_CODEHASH");

        // feeds: 8 decimals, complete round, fresh, inside 1.00 +- 0.50 %
        _checkFeed(FEED_USDC, "USDC/USD");
        _checkFeed(FEED_USDT, "USDT/USD");
    }

    function _checkFeed(address feed, string memory label) internal view {
        IChainlinkFeed f = IChainlinkFeed(feed);
        require(f.decimals() == 8, string.concat("preflight: feed decimals != 8 ", label));
        (uint80 rid, int256 ans,, uint256 updatedAt, uint80 answeredIn) = f.latestRoundData();
        require(ans > 0 && answeredIn >= rid && updatedAt != 0, string.concat("preflight: feed round incomplete or answer <= 0 ", label));
        require(updatedAt <= block.timestamp && block.timestamp - updatedAt <= MAX_FEED_AGE, string.concat("preflight: feed stale ", label));
        uint256 a = uint256(ans);
        uint256 dev = a > 1e8 ? a - 1e8 : 1e8 - a;
        require(dev <= FEED_BAND, string.concat("preflight: feed outside 1.00 +- 0.50 % ", label));
    }

    // ------------------------------------------------------------------------------------------------------------------ post-checks
    function _postchecks(Outputs memory o, address deployer, address rebalancer, bytes32 liveHash) internal view {
        PharaohDlmmVault v = PharaohDlmmVault(o.proxy);
        require(o.implementation.code.length != 0 && o.validator.code.length != 0, "post: implementation or validator has no code");
        require(address(uint160(uint256(vm.load(o.proxy, IMPL_SLOT)))) == o.implementation, "post: proxy implementation slot");
        require(o.proxyAdmin != address(0) && o.proxyAdmin != deployer, "post: proxy admin");
        require(v.owner() == SAFE, "post: vault owner is not the Safe");
        require(OwnerView(o.proxyAdmin).owner() == SAFE, "post: ProxyAdmin owner is not the Safe");
        require(v.rebalancer() == rebalancer && v.rebalancer() != deployer, "post: rebalancer");
        require(v.paused(), "post: vault is not paused");
        require(v.depositCap() == DEPOSIT_CAP && v.DEPOSIT_CAP_CEILING() == DEPOSIT_CAP, "post: cap / ceiling");
        require(v.totalSupply() == 0, "post: supply != 0");
        require(v.rewarderImplCodehash() == liveHash, "post: codehash");
        require(v.owner() != deployer, "post: the deployer is the vault owner");
        require(vm.getNonce(deployer) == 2, "post: deployer nonce != 2");
        require(PharaohDlmmVault(o.implementation).owner() == address(0), "post: the implementation itself is initialised");
    }
}

interface OwnerView {
    function owner() external view returns (address);
}

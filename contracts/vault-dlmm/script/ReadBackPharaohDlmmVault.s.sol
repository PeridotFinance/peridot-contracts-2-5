// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IPharaohDlmmVault} from "../src/IPharaohDlmmVault.sol";

interface IVaultRead {
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function rebalancer() external view returns (address);
    function asset() external view returns (address);
    function pairToken() external view returns (address);
    function tokenX() external view returns (address);
    function tokenY() external view returns (address);
    function assetIsX() external view returns (bool);
    function pair() external view returns (address);
    function router() external view returns (address);
    function factory() external view returns (address);
    function rewarder() external view returns (address);
    function rewarderBeacon() external view returns (address);
    function rewardToken() external view returns (address);
    function rewarderImplCodehash() external view returns (bytes32);
    function feedAsset() external view returns (address);
    function feedPair() external view returns (address);
    function binStep() external view returns (uint16);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function maxDeposit(address) external view returns (uint256);
    function lastRebalanceAt() external view returns (uint48);
    function rebalancesToday() external view returns (uint16);
    function depositCap() external view returns (uint256);
    function DEPOSIT_CAP_CEILING() external view returns (uint256);
    function guardParams() external view returns (IPharaohDlmmVault.GuardParams memory);
    function guardState() external view returns (bool unsafe, bool latched, uint256 reasons);
    function bandState() external view returns (uint24 lowerId, uint24 upperId, uint24 activeId, bool hasBand, bool outOfRange);
}

interface IOwnerView {
    function owner() external view returns (address);
}

interface IErc20Read {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
}

interface IBeaconRead {
    function implementation() external view returns (address);
}

/// @notice READ-ONLY read-back of a deployed Pharaoh DLMM vault: prints every value and REVERTS on the first mismatch. Never broadcasts.
///   forge script script/ReadBackPharaohDlmmVault.s.sol:ReadBackPharaohDlmmVault --rpc-url <alias or local>      (no --broadcast)
/// Environment (public values only):
///   VAULT (proxy), DEPLOYER, REBALANCER                      required
///   EXPECTED_IMPLEMENTATION                                  optional (the address the deploy printed)
///   STAGE                                                    1 (default) = after the deploy: paused, supply 0.
///                                                            2 = after the Safe MultiSend: unpaused, supply == seed shares held by SEED_HOLDER.
///   SEED (default 1000000), SEED_HOLDER (default 0x...dEaD)  stage 2 only
///   EXPECTED_DEPLOYER_NONCE                                  default 2 (implementation + proxy); 3 after the leftover-AVAX sweep
/// The expected values are the ceremony's (spec sections 2 and 8): they are written here, not read from the vault.
contract ReadBackPharaohDlmmVault is Script {
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
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 internal constant CAP = 200_000_000;

    function run() external view {
        address vault = vm.envAddress("VAULT");
        address deployer = vm.envAddress("DEPLOYER");
        address keeper = vm.envAddress("REBALANCER");
        uint256 stage = vm.envOr("STAGE", uint256(1));
        require(stage == 1 || stage == 2, "STAGE must be 1 or 2");
        require(block.chainid == 43114, "not 43114");
        IVaultRead v = IVaultRead(vault);

        console2.log("== read-back, stage %s, chain %s, block %s", stage, block.chainid, block.number);
        console2.log("vault (proxy)            %s", vault);

        // ---- proxy: implementation, admin, ProxyAdmin owner
        address impl = address(uint160(uint256(vm.load(vault, IMPL_SLOT))));
        address admin = address(uint160(uint256(vm.load(vault, ADMIN_SLOT))));
        console2.log("implementation           %s", impl);
        console2.log("proxy admin (ProxyAdmin) %s", admin);
        require(impl != address(0) && impl.code.length != 0, "implementation has no code");
        address expectedImpl = vm.envOr("EXPECTED_IMPLEMENTATION", address(0));
        if (expectedImpl != address(0)) require(impl == expectedImpl, "implementation != EXPECTED_IMPLEMENTATION");
        require(admin != address(0) && admin != deployer, "proxy admin is zero or the deployer");
        address adminOwner = IOwnerView(admin).owner();
        console2.log("ProxyAdmin owner         %s   (expect the Safe)", adminOwner);
        require(adminOwner == SAFE, "ProxyAdmin owner != Safe");
        console2.log("implementation.owner()   %s   (expect 0: initializers disabled)", IOwnerView(impl).owner());
        require(IOwnerView(impl).owner() == address(0), "the implementation is initialised");
        // the ProxyAdmin is the proxy's own child: CREATE(proxy, 1)
        require(admin == vm.computeCreateAddress(vault, 1), "ProxyAdmin is not CREATE(proxy, 1)");
        // the validator is part of the implementation: CREATE(implementation, 1)
        address validator = vm.computeCreateAddress(impl, 1);
        console2.log("validator CREATE(impl,1) %s   code bytes %s", validator, validator.code.length);
        require(validator.code.length != 0, "validator has no code");
        // the proxy and the implementation are the deployer's nonce 1 and 0
        require(vault == vm.computeCreateAddress(deployer, 1) && impl == vm.computeCreateAddress(deployer, 0), "addresses are not the deployer's CREATE nonces 1 and 0");

        // ---- roles
        console2.log("vault owner              %s   (expect the Safe)", v.owner());
        require(v.owner() == SAFE, "vault owner != Safe");
        console2.log("rebalancer               %s   (expect the keeper wallet)", v.rebalancer());
        require(v.rebalancer() == keeper, "rebalancer != REBALANCER");
        require(v.rebalancer() != deployer && v.rebalancer() != LEDGER && v.rebalancer() != SAFE, "rebalancer is a privileged address");

        // ---- wiring
        console2.log("asset                    %s", v.asset());
        console2.log("pairToken                %s", v.pairToken());
        console2.log("tokenX / tokenY          %s / %s   assetIsX %s", v.tokenX(), v.tokenY(), v.assetIsX());
        console2.log("pair                     %s", v.pair());
        console2.log("router                   %s", v.router());
        console2.log("factory                  %s", v.factory());
        console2.log("rewarder                 %s", v.rewarder());
        console2.log("rewarderBeacon           %s", v.rewarderBeacon());
        console2.log("rewardToken (PHAR)       %s", v.rewardToken());
        console2.log("feedAsset (USDC/USD)     %s", v.feedAsset());
        console2.log("feedPair  (USDT/USD)     %s", v.feedPair());
        console2.log("binStep                  %s", uint256(v.binStep()));
        require(v.asset() == USDC && v.pairToken() == USDT && v.tokenX() == USDT && v.tokenY() == USDC && !v.assetIsX(), "tokens");
        require(v.pair() == PAIR && v.router() == ROUTER && v.factory() == FACTORY && v.rewarder() == REWARDER, "pair / router / factory / rewarder");
        require(v.feedAsset() == FEED_USDC && v.feedPair() == FEED_USDT && v.binStep() == 1, "feeds / bin step");
        bytes32 liveHash = IBeaconRead(v.rewarderBeacon()).implementation().codehash;
        console2.log("rewarderImplCodehash     %s", vm.toString(v.rewarderImplCodehash()));
        console2.log("live beacon impl hash    %s", vm.toString(liveHash));
        require(v.rewarderImplCodehash() == liveHash, "pinned rewarder codehash != the beacon implementation's codehash now");
        console2.log("name / symbol / decimals %s / %s / %s", v.name(), v.symbol(), uint256(v.decimals()));

        // ---- cap
        console2.log("depositCap               %s   (expect 200000000)", v.depositCap());
        console2.log("DEPOSIT_CAP_CEILING      %s   (expect 200000000)", v.DEPOSIT_CAP_CEILING());
        require(v.depositCap() == CAP && v.DEPOSIT_CAP_CEILING() == CAP, "cap / ceiling");
        console2.log("maxDeposit(Ledger)       %s", v.maxDeposit(LEDGER));

        // ---- guard
        IPharaohDlmmVault.GuardParams memory g = v.guardParams();
        console2.log("guardParams legBandBps %s maxFeedAge %s maxPoolOracleDevBps %s", uint256(g.legBandBps), uint256(g.maxFeedAge), uint256(g.maxPoolOracleDevBps));
        console2.log("guardParams cooldown %s maxRebalancesPerDay %s maxSwapBps %s", uint256(g.rebalanceCooldown), uint256(g.maxRebalancesPerDay), uint256(g.maxSwapBps));
        console2.log("guardParams maxRebalanceLossBps %s", uint256(g.maxRebalanceLossBps));
        require(
            g.legBandBps == 50 && g.maxFeedAge == 93_600 && g.maxPoolOracleDevBps == 60 && g.rebalanceCooldown == 120 && g.maxRebalancesPerDay == 48
                && g.maxSwapBps == 6000 && g.maxRebalanceLossBps == 50,
            "guardParams are not the defaults"
        );
        (bool unsafe_, bool latched, uint256 reasons) = v.guardState();
        console2.log("guardState unsafe %s latched %s reasons %s   (expect false false 0)", unsafe_, latched, reasons);
        require(!unsafe_ && !latched && reasons == 0, "guardState is not clean");

        // ---- band (none until the keeper's open-band)
        (uint24 lo, uint24 up, uint24 act, bool hasBand, bool outOfRange) = v.bandState();
        console2.log("bandState lower %s upper %s active %s", uint256(lo), uint256(up), uint256(act));
        console2.log("bandState hasBand %s outOfRange %s   (expect false false)", hasBand, outOfRange);
        require(!hasBand && !outOfRange, "a band exists");
        require(v.lastRebalanceAt() == 0 && v.rebalancesToday() == 0, "rebalance counters are not zero");

        // ---- paused / supply by stage
        bool paused_ = v.paused();
        console2.log("paused                   %s", paused_);
        if (stage == 1) {
            require(paused_, "stage 1: the vault must be PAUSED");
            require(v.totalSupply() == 0 && v.totalAssets() == 0, "stage 1: supply / assets must be 0");
            console2.log("totalSupply / totalAssets 0 / 0   (stage 1: expect paused = true and an empty vault)");
        } else {
            uint256 seed = vm.envOr("SEED", uint256(1_000_000));
            address holder = vm.envOr("SEED_HOLDER", DEAD);
            require(seed >= 1_000_000, "SEED < 1 USDC: the first-depositor window (W10 F1) is not closed");
            require(!paused_, "stage 2: the vault must be UNPAUSED");
            console2.log("seed holder %s shares %s   (expect >= %s)", holder, v.balanceOf(holder), seed);
            require(v.balanceOf(holder) >= seed, "stage 2: the seed shares are not at the seed holder");
            require(v.totalSupply() >= seed, "stage 2: supply below the seed");
            console2.log("totalSupply %s totalAssets %s", v.totalSupply(), v.totalAssets());
            require(IErc20Read(USDC).allowance(SAFE, vault) == 0, "stage 2: a USDC allowance from the Safe to the vault is left");
            require(IErc20Read(USDC).balanceOf(SAFE) == 0, "stage 2: the Safe still holds USDC");
        }

        // ---- the deployer holds nothing
        uint256 wantNonce = vm.envOr("EXPECTED_DEPLOYER_NONCE", uint256(2));
        console2.log("deployer %s nonce %s (expect %s)", deployer, vm.getNonce(deployer), wantNonce);
        console2.log("deployer balance (wei)   %s", deployer.balance);
        require(vm.getNonce(deployer) == wantNonce, "deployer nonce");
        require(deployer != SAFE && deployer != LEDGER && deployer != v.owner() && deployer != v.rebalancer() && deployer != adminOwner, "the deployer holds a role");
        console2.log("deployer USDC / vault shares %s / %s", IErc20Read(USDC).balanceOf(deployer), v.balanceOf(deployer));
        require(v.balanceOf(deployer) == 0, "the deployer holds shares");
        console2.log("READ-BACK OK");
    }
}

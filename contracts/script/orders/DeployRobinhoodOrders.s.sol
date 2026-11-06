// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
// Imported so the build emits its artifact; deployed from the artifact.
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IsolatedMarginExecutorUpgradeable} from "../../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {RobinhoodMarginCloseAdapter, IRobinhoodOrderExecutor} from "../../contracts/margin/orders/RobinhoodMarginCloseAdapter.sol";

interface IOrdersTimelock {
    function getMinDelay() external view returns (uint256);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function hashOperation(address target, uint256 value, bytes calldata data, bytes32 predecessor, bytes32 salt)
        external
        pure
        returns (bytes32);
    function isOperation(bytes32 id) external view returns (bool);
    function isOperationDone(bytes32 id) external view returns (bool);
}

interface IOrdersOwnable {
    function owner() external view returns (address);
}

interface IOrdersRegistryView {
    function adapter() external view returns (address);
}

/// @title Robinhood TP/SL deployment path: three deployments by a throwaway key, then one timelock pair for the Ledger.
/// @notice Stage 1 (`run`, gas-only throwaway deployer, 4 creations):
///   1. the new executor implementation (closePositionFor + initializeOrderExecutor);
///   2. the registry implementation (`ORDERS_REGISTRY_ARTIFACT`, built to the SPEC's deployment convention);
///   3. the registry proxy, an OZ 5 TransparentUpgradeableProxy whose own ProxyAdmin the timelock owns, initialized with
///      the adapter address predicted from the deployer nonce;
///   4. RobinhoodMarginCloseAdapter(executor, registry proxy, oracle, quoter, config), asserted to land on that address.
/// Stage 2 (Ledger): timelock.schedule, then at least 3,600 s later timelock.execute, of
///   ProxyAdmin(0x561f).upgradeAndCall(executor, newImplementation, initializeOrderExecutor(adapter)).
/// `check(journal)` gates both signatures read-only; `verify(journal)` re-reads everything after the execute.
/// The executor upgrade does nothing until the registry has orders: the adapter only acts for the registry, and only for
/// a position's real owner. Liquidation, owner closes and every position are untouched (fork-tested).
contract DeployRobinhoodOrders is Script {
    using stdJson for string;

    address constant EXECUTOR = 0x6A45Ae86bD992d250580d08D340A06A04D478977;
    address constant EXECUTOR_PROXY_ADMIN = 0x561fa1749F4B58A70d0d7d67e74e6fBeEba6F9B8;
    address constant LIVE_EXECUTOR_IMPLEMENTATION = 0xD44a1d425CfA875eFC0263C0cf717840c213Fbd8;
    address constant TIMELOCK = 0x6797FB8Ce049B42C5BC2b42Bf76c6d15C7B12498;
    address constant LEDGER = 0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD;
    address constant ORACLE = 0x63150Eb3DDf71420dA0b09b66838aab398f7dEdD;
    address constant QUOTER = 0xeD3c353Ab237329BD53CC7eB24E66B370155FE6e;
    address constant CONFIG = 0x09F94fe0B79E000c8a26617c63E3427fdECB528b;
    uint256 constant DELAY = 3600;
    bytes32 constant SALT = keccak256("peridot-margin-orders-executor-upgrade-v1");
    // ERC-1967 and OZ 5 Initializable (ERC-7201) slots.
    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    struct Deployment {
        address executorImplementation;
        address registryImplementation;
        address registry;
        address registryProxyAdmin;
        address adapter;
    }

    // ------------------------------------------------------------------ stage 1
    function run() external {
        require(block.chainid == 4663, "CHAIN");
        address sender = vm.envAddress("ORDERS_PUBLIC_SENDER");
        string memory artifact = vm.envString("ORDERS_REGISTRY_ARTIFACT");
        string memory journal = vm.envString("ORDERS_JOURNAL");
        require(!vm.exists(journal), "JOURNAL_EXISTS");
        require(sender != LEDGER && sender != TIMELOCK, "SENDER_IS_GOVERNANCE");
        _preconditions();
        vm.startBroadcast(sender);
        Deployment memory d = _deploy(sender, vm.getCode(artifact));
        vm.stopBroadcast();
        _postconditions(d, sender);
        _writeJournal(journal, d, artifact);
    }

    /// @dev Shared with the fork test. `creator` is the address whose nonce CREATE uses.
    string constant EXECUTOR_ARTIFACT = "IsolatedMarginExecutorUpgradeable.sol:IsolatedMarginExecutorUpgradeable";
    string constant ADAPTER_ARTIFACT = "RobinhoodMarginCloseAdapter.sol:RobinhoodMarginCloseAdapter";
    string constant PROXY_ARTIFACT = "TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy";

    /// @dev Shared with the fork test. `creator` is the address whose nonce CREATE uses. Creation code comes from this
    /// build's artifacts, so this contract stays small.
    function _deploy(address creator, bytes memory registryCreationCode) internal returns (Deployment memory d) {
        d.executorImplementation = _create(vm.getCode(EXECUTOR_ARTIFACT));
        d.registryImplementation = _create(registryCreationCode);
        // The proxy is the creator's next creation; the adapter is the one after it.
        address predictedAdapter = vm.computeCreateAddress(creator, vm.getNonce(creator) + 1);
        bytes memory init = abi.encodeWithSignature("initialize(address,address)", predictedAdapter, TIMELOCK);
        d.registry = _create(abi.encodePacked(vm.getCode(PROXY_ARTIFACT), abi.encode(d.registryImplementation, TIMELOCK, init)));
        d.adapter = _create(
            abi.encodePacked(vm.getCode(ADAPTER_ARTIFACT), abi.encode(EXECUTOR, d.registry, ORACLE, QUOTER, CONFIG))
        );
        require(d.adapter == predictedAdapter, "ADAPTER_ADDRESS");
        d.registryProxyAdmin = address(uint160(uint256(vm.load(d.registry, ADMIN_SLOT))));
    }

    function _create(bytes memory code) internal returns (address a) {
        assembly ("memory-safe") {
            a := create(0, add(code, 0x20), mload(code))
        }
        require(a != address(0), "CREATE");
    }

    function _preconditions() internal view {
        require(IOrdersOwnable(EXECUTOR_PROXY_ADMIN).owner() == TIMELOCK, "EXECUTOR_PROXY_ADMIN_OWNER");
        require(address(uint160(uint256(vm.load(EXECUTOR, ADMIN_SLOT)))) == EXECUTOR_PROXY_ADMIN, "EXECUTOR_ADMIN");
        require(
            address(uint160(uint256(vm.load(EXECUTOR, IMPLEMENTATION_SLOT)))) == LIVE_EXECUTOR_IMPLEMENTATION,
            "EXECUTOR_IMPLEMENTATION_CHANGED"
        );
        require(uint256(vm.load(EXECUTOR, INITIALIZABLE_SLOT)) == 1, "EXECUTOR_INITIALIZED_VERSION_NOT_1");
        IOrdersTimelock t = IOrdersTimelock(TIMELOCK);
        require(t.getMinDelay() >= DELAY, "TIMELOCK_DELAY");
        require(t.hasRole(PROPOSER_ROLE, LEDGER) && t.hasRole(EXECUTOR_ROLE, LEDGER), "LEDGER_ROLES");
    }

    function _postconditions(Deployment memory d, address deployer) internal view {
        require(
            keccak256(d.executorImplementation.code) == keccak256(vm.getDeployedCode(EXECUTOR_ARTIFACT)),
            "EXECUTOR_IMPLEMENTATION_CODE"
        );
        require(IOrdersRegistryView(d.registry).adapter() == d.adapter, "REGISTRY_ADAPTER");
        require(address(uint160(uint256(vm.load(d.registry, IMPLEMENTATION_SLOT)))) == d.registryImplementation, "REGISTRY_IMPL");
        require(IOrdersOwnable(d.registryProxyAdmin).owner() == TIMELOCK, "REGISTRY_PROXY_ADMIN_OWNER");
        RobinhoodMarginCloseAdapter a = RobinhoodMarginCloseAdapter(d.adapter);
        require(address(a.executor()) == EXECUTOR && a.registry() == d.registry, "ADAPTER_WIRING");
        require(address(a.oracle()) == ORACLE && address(a.quoter()) == QUOTER && address(a.config()) == CONFIG, "ADAPTER_SOURCES");
        // The implementation must not be usable directly (initializers disabled).
        require(uint256(vm.load(d.registryImplementation, INITIALIZABLE_SLOT)) == type(uint64).max, "REGISTRY_IMPL_INITIALIZABLE");
        _deployerHoldsNothing(d, deployer);
    }

    /// @dev Generic over the registry's admin model: owner(), an AccessControl admin role, or the proxy admin.
    function _deployerHoldsNothing(Deployment memory d, address deployer) internal view {
        require(IOrdersOwnable(d.registryProxyAdmin).owner() != deployer, "DEPLOYER_OWNS_PROXY_ADMIN");
        (bool ok, bytes memory r) = d.registry.staticcall(abi.encodeWithSignature("owner()"));
        if (ok && r.length == 32) require(abi.decode(r, (address)) != deployer, "DEPLOYER_OWNS_REGISTRY");
        (ok, r) = d.registry.staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", bytes32(0), deployer));
        if (ok && r.length == 32) require(!abi.decode(r, (bool)), "DEPLOYER_REGISTRY_ADMIN");
        (ok, r) = d.registry.staticcall(abi.encodeWithSignature("admin()"));
        if (ok && r.length == 32) require(abi.decode(r, (address)) != deployer, "DEPLOYER_REGISTRY_ADMIN");
    }

    // ------------------------------------------------------------------ the timelock pair
    function upgradeCall(Deployment memory d) public pure returns (bytes memory) {
        return abi.encodeWithSignature(
            "upgradeAndCall(address,address,bytes)",
            EXECUTOR,
            d.executorImplementation,
            abi.encodeCall(IsolatedMarginExecutorUpgradeable.initializeOrderExecutor, (d.adapter))
        );
    }

    function scheduleCalldata(Deployment memory d) public pure returns (bytes memory) {
        return abi.encodeWithSignature(
            "schedule(address,uint256,bytes,bytes32,bytes32,uint256)", EXECUTOR_PROXY_ADMIN, 0, upgradeCall(d), bytes32(0), SALT, DELAY
        );
    }

    function executeCalldata(Deployment memory d) public pure returns (bytes memory) {
        return abi.encodeWithSignature(
            "execute(address,uint256,bytes,bytes32,bytes32)", EXECUTOR_PROXY_ADMIN, 0, upgradeCall(d), bytes32(0), SALT
        );
    }

    function operationId(Deployment memory d) public view returns (bytes32) {
        return IOrdersTimelock(TIMELOCK).hashOperation(EXECUTOR_PROXY_ADMIN, 0, upgradeCall(d), bytes32(0), SALT);
    }

    // ------------------------------------------------------------------ journal
    function _writeJournal(string memory path, Deployment memory d, string memory artifact) internal {
        string memory k = "orders";
        vm.serializeAddress(k, "executor", EXECUTOR);
        vm.serializeAddress(k, "executorProxyAdmin", EXECUTOR_PROXY_ADMIN);
        vm.serializeAddress(k, "previousExecutorImplementation", LIVE_EXECUTOR_IMPLEMENTATION);
        vm.serializeAddress(k, "executorImplementation", d.executorImplementation);
        vm.serializeAddress(k, "registryImplementation", d.registryImplementation);
        vm.serializeString(k, "registryArtifact", artifact);
        vm.serializeAddress(k, "registry", d.registry);
        vm.serializeAddress(k, "registryProxyAdmin", d.registryProxyAdmin);
        vm.serializeAddress(k, "adapter", d.adapter);
        vm.serializeAddress(k, "timelock", TIMELOCK);
        vm.serializeBytes32(k, "salt", SALT);
        vm.serializeBytes32(k, "operationId", operationId(d));
        vm.serializeUint(k, "nextPositionIdAtDeploy", IsolatedMarginExecutorUpgradeable(EXECUTOR).nextPositionId());
        vm.serializeString(k, "sourceCommit", vm.envOr("ORDERS_SOURCE_COMMIT", string("unset")));
        vm.serializeBytes(k, "scheduleCalldata", scheduleCalldata(d));
        string memory out = vm.serializeBytes(k, "executeCalldata", executeCalldata(d));
        vm.writeJson(out, path);
    }

    function _readJournal(string memory path) internal view returns (Deployment memory d) {
        string memory j = vm.readFile(path);
        d.executorImplementation = j.readAddress(".executorImplementation");
        d.registryImplementation = j.readAddress(".registryImplementation");
        d.registry = j.readAddress(".registry");
        d.registryProxyAdmin = j.readAddress(".registryProxyAdmin");
        d.adapter = j.readAddress(".adapter");
    }

    // ------------------------------------------------------------------ read-only gates
    /// @notice Before the schedule and again before the execute: the deployment is what the journal says and the executor
    /// has not moved. Prints the operation state.
    function check(string memory path) external view {
        Deployment memory d = _readJournal(path);
        _preconditions();
        require(
            keccak256(d.executorImplementation.code) == keccak256(vm.getDeployedCode(EXECUTOR_ARTIFACT)),
            "EXECUTOR_IMPLEMENTATION_CODE"
        );
        require(IOrdersRegistryView(d.registry).adapter() == d.adapter, "REGISTRY_ADAPTER");
        require(RobinhoodMarginCloseAdapter(d.adapter).registry() == d.registry, "ADAPTER_REGISTRY");
        require(IOrdersOwnable(d.registryProxyAdmin).owner() == TIMELOCK, "REGISTRY_PROXY_ADMIN_OWNER");
        bytes32 id = operationId(d);
        require(id == vm.parseJsonBytes32(vm.readFile(path), ".operationId"), "OPERATION_ID");
        IOrdersTimelock t = IOrdersTimelock(TIMELOCK);
        require(!t.isOperationDone(id), "ALREADY_EXECUTED");
        console2.log(t.isOperation(id) ? "check ok: operation scheduled, execute when ready" : "check ok: ready to schedule");
    }

    /// @notice After the execute.
    function verify(string memory path) external {
        Deployment memory d = _readJournal(path);
        string memory j = vm.readFile(path);
        require(
            address(uint160(uint256(vm.load(EXECUTOR, IMPLEMENTATION_SLOT)))) == d.executorImplementation, "IMPLEMENTATION"
        );
        require(uint256(vm.load(EXECUTOR, INITIALIZABLE_SLOT)) == 2, "INITIALIZED_VERSION");
        require(IRobinhoodOrderExecutor(EXECUTOR).orderExecutor() == d.adapter, "ORDER_EXECUTOR");
        require(
            IsolatedMarginExecutorUpgradeable(EXECUTOR).nextPositionId() >= j.readUint(".nextPositionIdAtDeploy"), "POSITIONS"
        );
        require(IOrdersOwnable(EXECUTOR_PROXY_ADMIN).owner() == TIMELOCK, "EXECUTOR_PROXY_ADMIN_OWNER");
        require(IOrdersOwnable(d.registryProxyAdmin).owner() == TIMELOCK, "REGISTRY_PROXY_ADMIN_OWNER");
        require(IOrdersRegistryView(d.registry).adapter() == d.adapter, "REGISTRY_ADAPTER");
        require(IOrdersTimelock(TIMELOCK).isOperationDone(operationId(d)), "OPERATION_NOT_DONE");
        // Only the adapter may close for an owner (simulated, nothing is sent).
        IRobinhoodOrderExecutor.CloseParams memory cp = IRobinhoodOrderExecutor.CloseParams(1, 10_000, 0, 0, 0, "", "");
        vm.prank(address(0xbad));
        (bool ok, bytes memory r) =
            EXECUTOR.call(abi.encodeCall(IRobinhoodOrderExecutor.closePositionFor, (address(0xbad), cp)));
        require(!ok && keccak256(r) == keccak256(abi.encodeWithSignature("ExecutorError(uint8)", uint8(60))), "CLOSE_FOR_OPEN");
        console2.log("verified: executor implementation, orderExecutor = adapter, version 2, positions kept, closePositionFor adapter-only");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
// Imported so the build emits their artifacts; deployed from the artifacts (keeps this contract small).
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IsolatedMarginExecutorUpgradeable} from "../../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginRiskEngineUpgradeable} from "../../contracts/margin/IsolatedMarginRiskEngineUpgradeable.sol";
import {IsolatedMarginLiquidatorUpgradeable} from "../../contracts/margin/IsolatedMarginLiquidatorUpgradeable.sol";
import {MarginOrderRegistryV2} from "../../contracts/margin/orders/MarginOrderRegistryV2.sol";
import {RobinhoodMarginCloseAdapter} from "../../contracts/margin/orders/RobinhoodMarginCloseAdapter.sol";
import {RangeTakeProfit} from "../../contracts/margin/orders/range/RangeTakeProfit.sol";

interface IRtpTimelock {
    function getMinDelay() external view returns (uint256);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function hashOperationBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external pure returns (bytes32);
    function isOperation(bytes32 id) external view returns (bool);
    function isOperationDone(bytes32 id) external view returns (bool);
}

interface IRtpOwnable {
    function owner() external view returns (address);
}

interface IRtpExecutorView {
    function orderExecutor() external view returns (address);
    function rangeCustodian() external view returns (address);
    function nextPositionId() external view returns (uint256);
}

interface IRtpRegistryView {
    function adapter() external view returns (address);
    function rangeOrders() external view returns (address);
}

interface IRtpCustodianView {
    function rangeCustodian() external view returns (address);
}

/// @title Range take-profit, production path (prepared for after the interview; nothing sent).
/// @notice Runs AFTER the 15-17 Nov orders ceremony and reads its journal (`ORDERS_JOURNAL`).
/// Stage 1 (`run`, gas-only throwaway key, 7 creations): RangeTakeProfit implementation and its proxy (OZ 5, ProxyAdmin
/// owned by the timelock, admin = the timelock), the range-aware close adapter v2, and new implementations of the
/// executor (range hooks), risk engine (band valuation), liquidator (band removal before seizure) and the registry (V2).
/// Stage 2 (Ledger, 2 signatures): timelock.scheduleBatch, then at least 3,600 s later executeBatch, of one atomic batch:
///   1. executor     upgradeAndCall(v3, initializeRange(custodian, adapter v2))   order executor handed v1 -> v2
///   2. registry     upgradeAndCall(V2, initializeV2(adapter v2, custodian))      same handover, plus TP/range exclusivity
///   3. risk engine  upgradeAndCall(impl, initializeRangeCustodian(custodian))    bands counted at the oracle
///   4. liquidator   upgradeAndCall(impl, initializeRangeCustodian(custodian))    bands removed before seizure
///   5-7. custodian  setPreset(1, 2, 3): 1%, 3%, 5% above the market, each 2% wide (operator 2026-11-07)
///   8. custodian    setFeeSplit(7000, 2000, 1000, protocol, loss reserve, pair)  pilot split; reserve share credited
///                   to the NVDA/USDG pair's loss reserve via deposit (operator 2026-11-09); protocol from env
///   9. custodian    setUnwinders(liquidator, adapter v2)
/// Steps 1 and 2 must be in the same batch: closePositionFor accepts only the executor's orderExecutor, so a split would
/// leave every TP/SL reverting. The risk engine's first wiring is a proxy-admin reinitializer inside the batch, so the
/// timelock delay is the delay; later changes use its queue/apply. Until step 3 has run, the custodian refuses every
/// band (NotWired). `check(journal)` gates both signatures; `verify(journal)` re-reads everything after the execute.
contract DeployRangeTakeProfit is Script {
    using stdJson for string;

    address constant EXECUTOR = 0x6A45Ae86bD992d250580d08D340A06A04D478977;
    address constant RISK = 0xC8b178C3c74570472FF1eeE0DD559e61AF9f9678;
    address constant LIQUIDATOR = 0x1434CDa56d0Aeac4d5abC16F91ca76a8A989083c;
    address constant TIMELOCK = 0x6797FB8Ce049B42C5BC2b42Bf76c6d15C7B12498;
    address constant LEDGER = 0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD;
    address constant OLD_SIGNER = 0x94696d767e65a75581145646960FA0eC886cE5d2; // compromised 2026-11-05: never a recipient
    address constant ORACLE = 0x63150Eb3DDf71420dA0b09b66838aab398f7dEdD;
    address constant QUOTER = 0xeD3c353Ab237329BD53CC7eB24E66B370155FE6e;
    address constant CONFIG = 0x09F94fe0B79E000c8a26617c63E3427fdECB528b;
    address constant POOL = 0xdac1904D823F7d6bcAaF431ceEe40c934fEd321b; // Ramses NVDA/USDG
    address constant NFP = 0x2eBd7B85a4E08D5B508b04BA147976C94afE6590;
    address constant GAUGE = 0x93c6A733FB3165D94774B3A5Fc4319D29bd7b6ce;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint256 constant DELAY = 3600;
    address constant LOSS_RESERVE = 0x806b182B050f7EcF908758dD6bBF91DB8B2212aF; // the pair's StrategyLossReserve
    bytes32 constant NVDA_PAIR = 0xe2050352f4346597cc69d2776d99ae60c9440dfc28f9406ce66be0bbe3fb6b06;
    bytes32 constant SALT = keccak256("peridot-range-take-profit-v1");
    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    string constant PROXY_ARTIFACT = "TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy";
    string constant CUSTODIAN_ARTIFACT = "RangeTakeProfit.sol:RangeTakeProfit";
    string constant ADAPTER_ARTIFACT = "RobinhoodMarginCloseAdapter.sol:RobinhoodMarginCloseAdapter";
    string constant EXECUTOR_ARTIFACT = "IsolatedMarginExecutorUpgradeable.sol:IsolatedMarginExecutorUpgradeable";
    string constant RISK_ARTIFACT = "IsolatedMarginRiskEngineUpgradeable.sol:IsolatedMarginRiskEngineUpgradeable";
    string constant LIQUIDATOR_ARTIFACT = "IsolatedMarginLiquidatorUpgradeable.sol:IsolatedMarginLiquidatorUpgradeable";
    string constant REGISTRY_ARTIFACT = "MarginOrderRegistryV2.sol:MarginOrderRegistryV2";

    struct Ceremony {
        address registry;
        address adapterV1;
        address executorImplementation;
    }

    struct Range {
        address custodianImplementation;
        address custodian;
        address adapterV2;
        address executorImplementation;
        address riskImplementation;
        address liquidatorImplementation;
        address registryImplementation;
        address protocolRecipient;
        address reserveRecipient;
    }

    // ------------------------------------------------------------------ stage 1
    function run() external {
        require(block.chainid == 4663, "CHAIN");
        address sender = vm.envAddress("RANGE_PUBLIC_SENDER");
        string memory journal = vm.envString("RANGE_JOURNAL");
        require(!vm.exists(journal), "JOURNAL_EXISTS");
        require(sender != LEDGER && sender != TIMELOCK && sender != OLD_SIGNER, "SENDER");
        Ceremony memory c = readCeremony(vm.envString("ORDERS_JOURNAL"));
        address protocolTo = _protocolRecipient();
        _preconditions(c);
        vm.startBroadcast(sender);
        Range memory r = _deploy(sender, c, protocolTo);
        vm.stopBroadcast();
        _postconditions(c, r, sender);
        _writeJournal(journal, c, r);
    }

    function readCeremony(string memory path) public view returns (Ceremony memory c) {
        string memory j = vm.readFile(path);
        c.registry = j.readAddress(".registry");
        c.adapterV1 = j.readAddress(".adapter");
        c.executorImplementation = j.readAddress(".executorImplementation");
    }

    function _protocolRecipient() internal view returns (address protocolTo) {
        // The Robinhood Safe or the Ledger, to be confirmed by the operator: no default, never zero or the compromised key.
        protocolTo = vm.envAddress("RANGE_PROTOCOL_RECIPIENT");
        require(protocolTo != address(0), "PROTOCOL_RECIPIENT_UNSET");
        require(protocolTo != OLD_SIGNER, "RECIPIENT_IS_THE_OLD_KEY");
    }

    function _deploy(address creator, Ceremony memory c, address protocolTo)
        internal
        returns (Range memory r)
    {
        r.protocolRecipient = protocolTo;
        r.reserveRecipient = LOSS_RESERVE;
        r.custodianImplementation = _create(vm.getCode(CUSTODIAN_ARTIFACT));
        bytes memory init = abi.encodeCall(
            RangeTakeProfit.initialize,
            (RangeTakeProfit.InitParams(EXECUTOR, RISK, NFP, POOL, GAUGE, ORACLE, CONFIG, c.registry, NVDA, USDG, TIMELOCK))
        );
        r.custodian = _create(abi.encodePacked(vm.getCode(PROXY_ARTIFACT), abi.encode(r.custodianImplementation, TIMELOCK, init)));
        r.adapterV2 = _create(
            abi.encodePacked(vm.getCode(ADAPTER_ARTIFACT), abi.encode(EXECUTOR, c.registry, ORACLE, QUOTER, CONFIG, r.custodian))
        );
        r.executorImplementation = _create(vm.getCode(EXECUTOR_ARTIFACT));
        r.riskImplementation = _create(vm.getCode(RISK_ARTIFACT));
        r.liquidatorImplementation = _create(vm.getCode(LIQUIDATOR_ARTIFACT));
        r.registryImplementation = _create(vm.getCode(REGISTRY_ARTIFACT));
        creator; // CREATE uses the broadcaster's nonce; nothing here needs a predicted address
    }

    function _create(bytes memory code) internal returns (address a) {
        assembly ("memory-safe") {
            a := create(0, add(code, 0x20), mload(code))
        }
        require(a != address(0), "CREATE");
    }

    // ------------------------------------------------------------------ checks
    function _admin(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ADMIN_SLOT))));
    }

    function _version(address proxy) internal view returns (uint256) {
        return uint256(vm.load(proxy, INITIALIZABLE_SLOT));
    }

    /// @dev The ceremony has run exactly as prepared and nothing has moved since.
    function _preconditions(Ceremony memory c) internal view {
        require(address(uint160(uint256(vm.load(EXECUTOR, IMPLEMENTATION_SLOT)))) == c.executorImplementation, "EXECUTOR_IMPL");
        require(_version(EXECUTOR) == 2, "EXECUTOR_VERSION_NOT_2");
        require(IRtpExecutorView(EXECUTOR).orderExecutor() == c.adapterV1, "ORDER_EXECUTOR_NOT_V1");
        require(_version(c.registry) == 1 && IRtpRegistryView(c.registry).adapter() == c.adapterV1, "REGISTRY_NOT_V1");
        require(_version(RISK) == 1 && _version(LIQUIDATOR) == 1, "RISK_OR_LIQUIDATOR_VERSION");
        address[4] memory proxies = [EXECUTOR, c.registry, RISK, LIQUIDATOR];
        for (uint256 i; i < 4; i++) require(IRtpOwnable(_admin(proxies[i])).owner() == TIMELOCK, "PROXY_ADMIN_OWNER");
        IRtpTimelock t = IRtpTimelock(TIMELOCK);
        require(t.getMinDelay() >= DELAY, "TIMELOCK_DELAY");
        require(t.hasRole(keccak256("PROPOSER_ROLE"), LEDGER) && t.hasRole(keccak256("EXECUTOR_ROLE"), LEDGER), "LEDGER_ROLES");
    }

    function _postconditions(Ceremony memory c, Range memory r, address deployer) internal view {
        RangeTakeProfit cust = RangeTakeProfit(r.custodian);
        require(address(uint160(uint256(vm.load(r.custodian, IMPLEMENTATION_SLOT)))) == r.custodianImplementation, "CUSTODIAN_IMPL");
        require(IRtpOwnable(_admin(r.custodian)).owner() == TIMELOCK && cust.admin() == TIMELOCK, "CUSTODIAN_ADMIN");
        require(address(cust.executor()) == EXECUTOR && address(cust.riskEngine()) == RISK && address(cust.registry()) == c.registry,
            "CUSTODIAN_WIRING");
        require(address(cust.pool()) == POOL && cust.stock() == NVDA && cust.usdg() == USDG && !cust.stockIsToken0(), "CUSTODIAN_POOL");
        require(_version(r.custodianImplementation) == type(uint64).max, "CUSTODIAN_IMPL_INITIALIZABLE");
        RobinhoodMarginCloseAdapter a = RobinhoodMarginCloseAdapter(r.adapterV2);
        require(address(a.executor()) == EXECUTOR && a.registry() == c.registry && a.rangeCustodian() == r.custodian, "ADAPTER_V2");
        string[5] memory art = [EXECUTOR_ARTIFACT, RISK_ARTIFACT, LIQUIDATOR_ARTIFACT, REGISTRY_ARTIFACT, CUSTODIAN_ARTIFACT];
        address[5] memory impl = [r.executorImplementation, r.riskImplementation, r.liquidatorImplementation,
            r.registryImplementation, r.custodianImplementation];
        for (uint256 i; i < 5; i++) require(keccak256(impl[i].code) == keccak256(vm.getDeployedCode(art[i])), "IMPLEMENTATION_CODE");
        require(IRtpOwnable(_admin(r.custodian)).owner() != deployer && cust.admin() != deployer, "DEPLOYER_HOLDS_SOMETHING");
    }

    // ------------------------------------------------------------------ the Ledger batch
    function batch(Ceremony memory c, Range memory r)
        public
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](9);
        values = new uint256[](9);
        payloads = new bytes[](9);
        string memory up = "upgradeAndCall(address,address,bytes)";
        targets[0] = _admin(EXECUTOR);
        payloads[0] = abi.encodeWithSignature(up, EXECUTOR, r.executorImplementation,
            abi.encodeCall(IsolatedMarginExecutorUpgradeable.initializeRange, (r.custodian, r.adapterV2)));
        targets[1] = _admin(c.registry);
        payloads[1] = abi.encodeWithSignature(up, c.registry, r.registryImplementation,
            abi.encodeWithSignature("initializeV2(address,address)", r.adapterV2, r.custodian));
        targets[2] = _admin(RISK);
        payloads[2] = abi.encodeWithSignature(up, RISK, r.riskImplementation,
            abi.encodeCall(IsolatedMarginRiskEngineUpgradeable.initializeRangeCustodian, (r.custodian)));
        targets[3] = _admin(LIQUIDATOR);
        payloads[3] = abi.encodeWithSignature(up, LIQUIDATOR, r.liquidatorImplementation,
            abi.encodeCall(IsolatedMarginLiquidatorUpgradeable.initializeRangeCustodian, (r.custodian)));
        int24[3] memory distance = [int24(100), 300, 490]; // 1.0001^ticks: 1.0%, 3.0%, 5.0%; tick spacing 10
        for (uint256 i; i < 3; i++) {
            targets[4 + i] = r.custodian;
            payloads[4 + i] = abi.encodeCall(RangeTakeProfit.setPreset, (uint8(i + 1), true, distance[i], int24(200)));
        }
        targets[7] = r.custodian;
        payloads[7] = abi.encodeCall(
            RangeTakeProfit.setFeeSplit, (7000, 2000, 1000, r.protocolRecipient, r.reserveRecipient, NVDA_PAIR)
        );
        targets[8] = r.custodian;
        payloads[8] = abi.encodeCall(RangeTakeProfit.setUnwinders, (LIQUIDATOR, r.adapterV2));
    }

    function operationId(Ceremony memory c, Range memory r) public view returns (bytes32) {
        (address[] memory t, uint256[] memory v, bytes[] memory p) = batch(c, r);
        return IRtpTimelock(TIMELOCK).hashOperationBatch(t, v, p, bytes32(0), SALT);
    }

    function scheduleCalldata(Ceremony memory c, Range memory r) public view returns (bytes memory) {
        (address[] memory t, uint256[] memory v, bytes[] memory p) = batch(c, r);
        return abi.encodeWithSignature(
            "scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)", t, v, p, bytes32(0), SALT, DELAY
        );
    }

    function executeCalldata(Ceremony memory c, Range memory r) public view returns (bytes memory) {
        (address[] memory t, uint256[] memory v, bytes[] memory p) = batch(c, r);
        return abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", t, v, p, bytes32(0), SALT);
    }

    // ------------------------------------------------------------------ journal (also read by orders_keeper.py)
    function _writeJournal(string memory path, Ceremony memory c, Range memory r) internal {
        string memory k = "range";
        vm.serializeAddress(k, "registry", c.registry);
        vm.serializeAddress(k, "executor", EXECUTOR);
        vm.serializeAddress(k, "adapterV1", c.adapterV1);
        vm.serializeAddress(k, "previousExecutorImplementation", c.executorImplementation);
        vm.serializeAddress(k, "rangeCustodian", r.custodian);
        vm.serializeAddress(k, "custodianImplementation", r.custodianImplementation);
        vm.serializeAddress(k, "adapter", r.adapterV2);
        vm.serializeAddress(k, "executorImplementation", r.executorImplementation);
        vm.serializeAddress(k, "riskImplementation", r.riskImplementation);
        vm.serializeAddress(k, "liquidatorImplementation", r.liquidatorImplementation);
        vm.serializeAddress(k, "registryImplementation", r.registryImplementation);
        vm.serializeAddress(k, "protocolRecipient", r.protocolRecipient);
        vm.serializeAddress(k, "reserveRecipient", r.reserveRecipient);
        vm.serializeBytes32(k, "salt", SALT);
        vm.serializeBytes32(k, "operationId", operationId(c, r));
        vm.serializeUint(k, "nextPositionIdAtDeploy", IRtpExecutorView(EXECUTOR).nextPositionId());
        vm.serializeString(k, "sourceCommit", vm.envOr("RANGE_SOURCE_COMMIT", string("unset")));
        vm.serializeBytes(k, "scheduleCalldata", scheduleCalldata(c, r));
        string memory out = vm.serializeBytes(k, "executeCalldata", executeCalldata(c, r));
        vm.writeJson(out, path);
    }

    function _read(string memory path) internal view returns (Ceremony memory c, Range memory r) {
        string memory j = vm.readFile(path);
        c.registry = j.readAddress(".registry");
        c.adapterV1 = j.readAddress(".adapterV1");
        c.executorImplementation = j.readAddress(".previousExecutorImplementation");
        r.custodian = j.readAddress(".rangeCustodian");
        r.custodianImplementation = j.readAddress(".custodianImplementation");
        r.adapterV2 = j.readAddress(".adapter");
        r.executorImplementation = j.readAddress(".executorImplementation");
        r.riskImplementation = j.readAddress(".riskImplementation");
        r.liquidatorImplementation = j.readAddress(".liquidatorImplementation");
        r.registryImplementation = j.readAddress(".registryImplementation");
        r.protocolRecipient = j.readAddress(".protocolRecipient");
        r.reserveRecipient = j.readAddress(".reserveRecipient");
    }

    // ------------------------------------------------------------------ read-only gates
    function check(string memory path) external view {
        (Ceremony memory c, Range memory r) = _read(path);
        _preconditions(c);
        require(operationId(c, r) == vm.parseJsonBytes32(vm.readFile(path), ".operationId"), "OPERATION_ID");
        require(!IRtpTimelock(TIMELOCK).isOperationDone(operationId(c, r)), "ALREADY_EXECUTED");
        console2.log(IRtpTimelock(TIMELOCK).isOperation(operationId(c, r))
            ? "check ok: batch scheduled, execute when ready" : "check ok: ready to schedule");
    }

    function verify(string memory path) external {
        (Ceremony memory c, Range memory r) = _read(path);
        string memory j = vm.readFile(path);
        require(IRtpTimelock(TIMELOCK).isOperationDone(operationId(c, r)), "OPERATION_NOT_DONE");
        require(address(uint160(uint256(vm.load(EXECUTOR, IMPLEMENTATION_SLOT)))) == r.executorImplementation, "EXECUTOR_IMPL");
        require(_version(EXECUTOR) == 3 && _version(c.registry) == 2 && _version(RISK) == 2 && _version(LIQUIDATOR) == 2, "VERSIONS");
        IRtpExecutorView e = IRtpExecutorView(EXECUTOR);
        require(e.orderExecutor() == r.adapterV2 && e.rangeCustodian() == r.custodian, "EXECUTOR_WIRING");
        require(IRtpRegistryView(c.registry).adapter() == r.adapterV2 && IRtpRegistryView(c.registry).rangeOrders() == r.custodian,
            "REGISTRY_WIRING");
        require(IRtpCustodianView(RISK).rangeCustodian() == r.custodian && IRtpCustodianView(LIQUIDATOR).rangeCustodian() == r.custodian,
            "RISK_LIQUIDATOR_WIRING");
        RangeTakeProfit cust = RangeTakeProfit(r.custodian);
        int24[3] memory distance = [int24(100), 300, 490];
        for (uint256 i; i < 3; i++) {
            (bool on, int24 d, int24 w) = cust.presets(uint8(i + 1));
            require(on && d == distance[i] && w == 200, "PRESETS");
        }
        require(cust.userFeeBps() == 7000 && cust.protocolFeeBps() == 2000 && cust.reserveFeeBps() == 1000
            && cust.protocolRecipient() == r.protocolRecipient && cust.reserveRecipient() == LOSS_RESERVE
            && cust.reservePairId() == NVDA_PAIR, "FEE_SPLIT");
        require(cust.liquidator() == LIQUIDATOR && cust.orderAdapter() == r.adapterV2, "UNWINDERS");
        require(e.nextPositionId() >= j.readUint(".nextPositionIdAtDeploy"), "POSITIONS");
        // Only adapter v2 may close for an owner now; adapter v1 and strangers are refused (simulated).
        address[2] memory callers = [c.adapterV1, address(0xbad)];
        for (uint256 i; i < 2; i++) {
            vm.prank(callers[i]);
            (bool ok, bytes memory ret) = EXECUTOR.call(abi.encodeWithSignature(
                "closePositionFor(address,(uint256,uint16,uint256,uint256,uint256,bytes,bytes))",
                address(0xbad), uint256(1), uint16(10_000), uint256(0), uint256(0), uint256(0), bytes(""), bytes("")));
            require(!ok && keccak256(ret) == keccak256(abi.encodeWithSignature("ExecutorError(uint8)", uint8(60))), "CLOSE_FOR_OPEN");
        }
        console2.log("verified: executor v3 (orderExecutor = adapter v2), registry V2, risk engine and liquidator wired, presets 1/3/5%, fee split 70/20/10, unwinders");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// TEST STUBS for the keeper's local anvil harness. Not production code: nothing here is deployed anywhere but a throwaway local chain.
// They implement exactly the reads the keeper makes (the frozen IPharaohDlmmVault views, the LB pair views, Chainlink feeds, ERC-20 balanceOf/decimals, Multicall3.aggregate3)
// and a NO-OP rebalance / tripGuard that records its arguments. Signatures are compared with the keeper's ABI by the harness test.

contract StubToken {
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
}

contract StubFeed {
    uint8 public decimals = 8;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    function set(int256 a, uint256 t) external { answer = a; updatedAt = t; roundId++; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) { return (roundId, answer, updatedAt, updatedAt, roundId); }
}

contract StubPair {
    address public tokenX;
    address public tokenY;
    uint24 public activeId;
    uint256 public priceNum = 9996;   // raw Y per raw X = priceNum / priceDen
    uint256 public priceDen = 10000;
    uint256 public feeBps = 3;
    struct Bin { uint128 x; uint128 y; uint256 supply; }
    mapping(uint24 => Bin) public bins;
    mapping(address => mapping(uint256 => uint256)) public shares;
    constructor(address x, address y, uint24 id) { tokenX = x; tokenY = y; activeId = id; }
    function setActive(uint24 id) external { activeId = id; }
    function setPrice(uint256 n, uint256 d, uint256 f) external { priceNum = n; priceDen = d; feeBps = f; }
    function setBin(uint24 id, uint128 x, uint128 y, uint256 supply, address holder, uint256 held) external { bins[id] = Bin(x, y, supply); shares[holder][id] = held; }
    function getActiveId() external view returns (uint24) { return activeId; }
    function getTokenX() external view returns (address) { return tokenX; }
    function getTokenY() external view returns (address) { return tokenY; }
    function getBinStep() external pure returns (uint16) { return 1; }
    function getBin(uint24 id) external view returns (uint128, uint128) { return (bins[id].x, bins[id].y); }
    function totalSupply(uint256 id) external view returns (uint256) { return bins[uint24(id)].supply; }
    function balanceOf(address a, uint256 id) external view returns (uint256) { return shares[a][id]; }
    function getPriceFromId(uint24) external view returns (uint256) { return (uint256(1) << 128) * priceNum / priceDen; }
    bool public hookRevert;
    function setHookRevert(bool b) external { hookRevert = b; }
    /// the exit probe simulates burn(vault, vault, ...) from the vault; a failing Pharaoh hook is a revert here
    function burn(address, address, uint256[] calldata, uint256[] calldata) external view returns (bytes32[] memory out) {
        require(!hookRevert, "hook: anti-sybil");
        out = new bytes32[](1);
    }
    function getSwapOut(uint128 amountIn, bool swapForY) external view returns (uint128, uint128, uint128) {
        uint256 gross = swapForY ? uint256(amountIn) * priceNum / priceDen : uint256(amountIn) * priceDen / priceNum;
        uint256 fee = gross * feeBps / 10000;
        return (0, uint128(gross - fee), uint128(fee));
    }
}

contract StubVault {
    struct GuardParams { uint16 legBandBps; uint32 maxFeedAge; uint16 maxPoolOracleDevBps; uint32 rebalanceCooldown; uint16 maxRebalancesPerDay; uint16 maxSwapBps; uint16 maxRebalanceLossBps; }
    event Rebalanced(uint24 oldLowerId, uint24 oldUpperId, uint24 newLowerId, uint24 newUpperId, uint24 activeId, bool swapXForY, uint256 swapIn, uint256 swapOut, uint256 navBefore, uint256 navAfter);
    event GuardTripped(address indexed by, uint256 reasons);
    error GuardLatched();
    error GuardUnsafe(uint256 reasons);
    error NotOutOfRange(uint24 activeId, uint24 lowerId, uint24 upperId);
    error CooldownActive(uint256 readyAt);
    error DailyRebalanceCapReached();
    error SwapTooLarge(uint256 swapIn, uint256 maxIn);
    error NavLossTooLarge(uint256 navBefore, uint256 navAfter);
    error ActiveIdMoved(uint24 expected, uint24 actual, uint24 idSlippage);
    error GuardStillUnsafe(uint256 reasons);
    error NoBand();

    StubPair public pair;
    address public rebalancer;
    uint24 public lowerId; uint24 public upperId; bool public hasBand;
    bool public latched; uint256 public reasons;
    uint48 public lastRebalanceAt; uint16 public rebalancesToday;
    GuardParams internal gp = GuardParams(50, 93600, 60, 120, 48, 6000, 50);
    // test controls and records
    uint8 public failMode;            // 1 = NavLossTooLarge, 2 = SwapTooLarge
    uint256 public rebalanceCount; uint256 public tripCount;
    bytes public lastCall;
    uint24 public lastExpected; bool public lastXForY; uint256 public lastSwapIn; uint256 public lastSwapMinOut; uint256 public lastXMin; uint256 public lastYMin; uint256 public lastDeadline;

    constructor(address p, address r, uint24 lo, uint24 up) { pair = StubPair(p); rebalancer = r; lowerId = lo; upperId = up; hasBand = true; }
    function setReasons(uint256 r) external { reasons = r; }
    function setLatched(bool l) external { latched = l; }
    function setFailMode(uint8 m) external { failMode = m; }
    function setBand(uint24 lo, uint24 up, bool has) external { lowerId = lo; upperId = up; hasBand = has; }
    function setRebalancer(address r) external { rebalancer = r; }
    address public feedAsset; address public feedPair; address public asset; address public pairToken;
    event BandOpened(uint24 lowerId, uint24 upperId, uint24 activeId, uint256 amountX, uint256 amountY);
    error BandExists();
    function setWiring(address fa, address fp, address a, address p) external { feedAsset = fa; feedPair = fp; asset = a; pairToken = p; }
    function openBand(uint24 expectedActiveId, uint24, uint256 swapMinOut, uint256, uint256, uint256 deadline) external {
        require(msg.sender == rebalancer, "not rebalancer");
        if (hasBand) revert BandExists();
        if (latched) revert GuardLatched();
        if (reasons & 15 != 0) revert GuardUnsafe(reasons);
        require(block.timestamp <= deadline, "expired");
        uint24 a = pair.getActiveId();
        lowerId = a - 1; upperId = a + 1; hasBand = true;
        lastExpected = expectedActiveId; lastSwapMinOut = swapMinOut;
        emit BandOpened(lowerId, upperId, a, 1, 1);
    }

    function bandState() external view returns (uint24, uint24, uint24, bool, bool) {
        uint24 a = pair.getActiveId();
        return (lowerId, upperId, a, hasBand, hasBand && (a < lowerId || a > upperId));
    }
    function guardState() external view returns (bool, bool, uint256) { return (latched || reasons != 0, latched, reasons); }
    function rebalanceAllowed() external view returns (bool ok, uint256 reasonBits, uint256 readyAt) {
        uint24 a = pair.getActiveId();
        readyAt = uint256(lastRebalanceAt) + gp.rebalanceCooldown;
        ok = hasBand && (a < lowerId || a > upperId) && !latched && reasons == 0 && block.timestamp >= readyAt && rebalancesToday < gp.maxRebalancesPerDay;
        reasonBits = ok ? 0 : reasons;
    }
    function guardParams() external view returns (GuardParams memory) { return gp; }

    function rebalance(uint24 expectedActiveId, uint24 idSlippage, bool swapXForY, uint256 swapIn, uint256 swapMinOut, uint256 amountXMin, uint256 amountYMin, uint256 deadline) external {
        require(msg.sender == rebalancer, "not rebalancer");
        if (!hasBand) revert NoBand();
        if (latched) revert GuardLatched();
        if (reasons & 15 != 0) revert GuardUnsafe(reasons);
        uint24 a = pair.getActiveId();
        if (a >= lowerId && a <= upperId) revert NotOutOfRange(a, lowerId, upperId);
        uint256 ready = uint256(lastRebalanceAt) + gp.rebalanceCooldown;
        if (block.timestamp < ready) revert CooldownActive(ready);
        if (block.timestamp > deadline) revert("expired");
        uint24 diff = a > expectedActiveId ? a - expectedActiveId : expectedActiveId - a;
        if (diff > idSlippage) revert ActiveIdMoved(expectedActiveId, a, idSlippage);
        if (failMode == 1) revert NavLossTooLarge(1_000_000, 900_000);
        if (failMode == 2) revert SwapTooLarge(swapIn, swapIn / 2);
        rebalanceCount++;
        lastCall = msg.data;
        lastExpected = expectedActiveId; lastXForY = swapXForY; lastSwapIn = swapIn; lastSwapMinOut = swapMinOut; lastXMin = amountXMin; lastYMin = amountYMin; lastDeadline = deadline;
        uint24 ol = lowerId; uint24 ou = upperId;
        lowerId = a - 1; upperId = a + 1;
        lastRebalanceAt = uint48(block.timestamp); rebalancesToday++;
        emit Rebalanced(ol, ou, lowerId, upperId, a, swapXForY, swapIn, swapMinOut, 1_000_000, 999_900);
    }
    function tripGuard() external {
        if (reasons & 15 == 0) revert GuardUnsafe(0);
        latched = true; tripCount++;
        emit GuardTripped(msg.sender, reasons);
    }
}

contract StubMulticall3 {
    struct Call3 { address target; bool allowFailure; bytes callData; }
    struct Result { bool success; bytes returnData; }
    function aggregate3(Call3[] calldata calls) external payable returns (Result[] memory out) {
        out = new Result[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory data) = calls[i].target.call(calls[i].callData);
            require(ok || calls[i].allowFailure, "multicall: call failed");
            out[i] = Result(ok, data);
        }
    }
}

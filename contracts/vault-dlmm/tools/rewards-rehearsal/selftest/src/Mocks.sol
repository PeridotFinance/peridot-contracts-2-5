// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// MOCK WORLD for tools/rewards-rehearsal/selftest/selftest.mjs: a non-fork local chain (id 43114) on which these runtimes are put at the REAL addresses of the Safe, the vault, PHAR and the
// rewarder, so that the rehearsal script, the Safe tools, the deploy script and the generator can be exercised END TO END without any endpoint. Test doubles only; nothing here is deployed anywhere.
address constant SAFE_ADDR = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
address constant LEDGER_ADDR = 0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD;
address constant VAULT_ADDR = 0x278B1b625C74B1926C5F989ddE601f3C5Ba27f7D;
address constant PHAR_ADDR = 0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7;
address constant REWARDER_ADDR = 0x32E68C4b8Edc6d1F16E99EbA826B292FDC18daDC;

/// A Safe 1-of-1 owned by the Ledger that accepts execTransaction with the "approved by msg.sender" signature (r = owner, s = 0, v = 1) exactly as tools/dlmm-safe-call.sh sends it.
contract MockSafe {
    uint256 public nonce;
    function getOwners() external pure returns (address[] memory o) { o = new address[](1); o[0] = LEDGER_ADDR; }
    function getThreshold() external pure returns (uint256) { return 1; }
    function execTransaction(address to, uint256 value, bytes calldata data, uint8 operation, uint256, uint256, uint256, address, address payable, bytes calldata signatures) external payable returns (bool) {
        require(msg.sender == LEDGER_ADDR, "GS030");
        require(signatures.length == 65 && bytes32(signatures[0:32]) == bytes32(uint256(uint160(LEDGER_ADDR))) && bytes32(signatures[32:64]) == bytes32(0) && uint8(signatures[64]) == 1, "GS026");
        require(operation == 0, "op");
        nonce++;
        (bool ok,) = to.call{value: value}(data);
        require(ok, "GS013");
        return true;
    }
}

contract MockPhar {
    string public name = "Pharaoh"; string public symbol = "PHAR"; uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf; mapping(address => mapping(address => uint256)) public allowance; uint256 public totalSupply;
    event Transfer(address indexed from, address indexed to, uint256 value); event Approval(address indexed owner, address indexed spender, uint256 value);
    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; emit Transfer(address(0), to, a); }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; emit Approval(msg.sender, s, a); return true; }
    function transfer(address to, uint256 a) external returns (bool) { _t(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender]; require(al >= a, "allowance"); if (al != type(uint256).max) allowance[f][msg.sender] = al - a; _t(f, to, a); return true;
    }
    function _t(address f, address to, uint256 a) internal { require(balanceOf[f] >= a, "balance"); balanceOf[f] -= a; balanceOf[to] += a; emit Transfer(f, to, a); }
}

/// The DLMM vault as the rehearsal sees it: an ERC-20 of shares (6 decimals), owner = the Safe, harvestRewards() (rebalancer or owner) that pays the PHAR accrued since the last call
/// (`rate` wei per second) to the owner and emits PharHarvested; a band that exists.
contract MockVault {
    uint8 public constant decimals = 6;
    uint256 public rate; // PHAR wei per second, set by init() (the runtime is placed with anvil_setCode, so no constructor storage); setRate(0) = the live band earns nothing: the exit-43 control
    function setRate(uint256 r) external { rate = r; }
    mapping(address => uint256) public balanceOf; uint256 public totalSupply; uint256 public lastClaim; address public rebalancer;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event PharHarvested(address indexed token, uint256 amount, uint256 totalSupplyShares, uint256 totalAssets);
    error NotRebalancer();
    function init(address reb) external { require(lastClaim == 0, "init"); lastClaim = block.timestamp; rebalancer = reb; rate = 1_000_000_000_000; }
    function owner() external pure returns (address) { return SAFE_ADDR; }
    function rewardToken() external pure returns (address) { return PHAR_ADDR; }
    function rewarder() external pure returns (address) { return REWARDER_ADDR; }
    function bandState() external pure returns (uint24, uint24, uint24, bool, bool) { return (8_388_607, 8_388_609, 8_388_608, true, false); }
    function pending() public view returns (uint256) { return (block.timestamp - lastClaim) * rate; }
    function mintTo(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; emit Transfer(address(0), to, a); }
    function transfer(address to, uint256 a) external returns (bool) { require(balanceOf[msg.sender] >= a, "balance"); balanceOf[msg.sender] -= a; balanceOf[to] += a; emit Transfer(msg.sender, to, a); return true; }
    function harvestRewards() external {
        if (msg.sender != rebalancer && msg.sender != SAFE_ADDR) revert NotRebalancer();
        uint256 amount = pending(); lastClaim = block.timestamp;
        MockPhar(PHAR_ADDR).mint(address(this), amount);
        uint256 whole = MockPhar(PHAR_ADDR).balanceOf(address(this));
        MockPhar(PHAR_ADDR).transfer(SAFE_ADDR, whole);
        emit PharHarvested(PHAR_ADDR, amount, totalSupply, 0);
    }
}

contract MockRewarder {
    function getPendingRewards(address, uint256[] calldata) external view returns (uint256) { return MockVault(VAULT_ADDR).pending(); }
}

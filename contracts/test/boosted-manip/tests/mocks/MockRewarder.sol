// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMockPairHooks {
    function getLBHooksParameters() external view returns (bytes32);
}

interface IMockVoterRW {
    function isAuthorizedDLMMManager(address) external view returns (bool);
}

/// @notice The pair's hook, a stand-in for the Pharaoh `DLMMRewarder` (BeaconProxy). Hook signatures are the real `IDLMMHooks` ones. Switches:
///         `revertSwap`, `revertMint`, `revertBurn` (the hook REVERTS: the pair then reverts the whole call), `wrongSelector` (hook returns a bad selector),
///         `revertTransfer` is always on (the real hook reverts every real batchTransferFrom: "transfers disabled").
///         Rewards: tests set `pending[user]`; `claim` requires user == msg.sender and the rewarder to be linked, pays `rewardToken`.
///         Settlement is not modelled (no forfeiture); `lastModified` records the touches so tests can assert the vault touched the bins.
contract MockRewarder {
    address public immutable pair;
    address public immutable rewardToken;
    address public immutable owner; // the voter

    bool public revertSwap;
    bool public revertMint;
    bool public revertBurn;
    bool public wrongSelector;

    mapping(address => uint256) public pending;
    mapping(address => mapping(uint256 => uint32)) public lastModified;
    uint256 public hookCalls;

    constructor(address pair_, address rewardToken_, address voter_) {
        pair = pair_;
        rewardToken = rewardToken_;
        owner = voter_;
    }

    // ------------------------------------------------------------------ views the vault reads
    function isLinked() external view returns (bool) {
        return _isLinked();
    }

    function getLBPair() external view returns (address) {
        return pair;
    }

    function getRewardToken() external view returns (address) {
        return rewardToken;
    }

    function getPendingRewards(address user, uint256[] calldata) external view returns (uint256) {
        if (!_isLinked()) return 0;
        return pending[user];
    }

    function claim(address user, uint256[] calldata) external {
        require(user == msg.sender, "caller");
        require(_isLinked(), "unlinked");
        uint256 amt = pending[user];
        pending[user] = 0;
        if (amt != 0) IERC20(rewardToken).transfer(user, amt);
    }

    // ------------------------------------------------------------------ hooks (IDLMMHooks)
    modifier onlyPair() {
        require(msg.sender == pair, "InvalidCaller");
        _;
    }

    function beforeSwap(address, address, bool, bytes32) external onlyPair returns (bytes4) {
        hookCalls++;
        if (revertSwap) revert("rewarder: swap hook down");
        return _sel(this.beforeSwap.selector);
    }

    function beforeMint(address sender, address to, bytes32[] calldata cfgs, bytes32) external onlyPair returns (bytes4) {
        hookCalls++;
        if (revertMint) revert("rewarder: mint hook down");
        if (sender != to) require(IMockVoterRW(owner).isAuthorizedDLMMManager(sender), "unauthorized manager");
        for (uint256 i; i < cfgs.length; ++i) {
            lastModified[to][uint24(uint256(cfgs[i]))] = uint32(block.timestamp);
        }
        return _sel(this.beforeMint.selector);
    }

    function beforeBurn(address, address from, address, uint256[] calldata ids, uint256[] calldata) external onlyPair returns (bytes4) {
        hookCalls++;
        if (revertBurn) revert("rewarder: burn hook down");
        for (uint256 i; i < ids.length; ++i) {
            lastModified[from][ids[i]] = uint32(block.timestamp);
        }
        return _sel(this.beforeBurn.selector);
    }

    function beforeBatchTransferFrom(address, address, address, uint256[] calldata, uint256[] calldata) external view onlyPair returns (bytes4) {
        revert("transfers disabled");
    }

    // ------------------------------------------------------------------ test knobs
    function setRevert(bool swap_, bool mint_, bool burn_) external {
        revertSwap = swap_;
        revertMint = mint_;
        revertBurn = burn_;
    }

    function setRevertAll(bool b) external {
        revertSwap = b;
        revertMint = b;
        revertBurn = b;
    }

    function setWrongSelector(bool b) external {
        wrongSelector = b;
    }

    function setPending(address user, uint256 amt) external {
        pending[user] = amt;
    }

    // ------------------------------------------------------------------ internals
    function _isLinked() internal view returns (bool) {
        return address(uint160(uint256(IMockPairHooks(pair).getLBHooksParameters()))) == address(this);
    }

    function _sel(bytes4 s) private view returns (bytes4) {
        return wrongSelector ? bytes4(0xdeadbeef) : s;
    }
}

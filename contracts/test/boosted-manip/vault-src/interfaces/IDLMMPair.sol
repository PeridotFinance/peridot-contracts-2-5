// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal hand-made interface of the Pharaoh DLMM pool (LB pair), the clone implementation `DLMMPool` verified at
///         0xF41253C1258a7a3C291e695158267B173C26d710 (Routescan, solc 0.8.26), pair 0x16888EE58E706C253b821EAA637ae9b2cFeA255C.
///         Only what the vault calls. Amounts are packed `bytes32`: low 128 bits = X, high 128 bits = Y.
interface IDLMMPair {
    function getFactory() external view returns (address);
    function getTokenX() external view returns (address);
    function getTokenY() external view returns (address);
    function getBinStep() external view returns (uint16);
    function getActiveId() external view returns (uint24);
    function getBin(uint24 id) external view returns (uint128 binReserveX, uint128 binReserveY);
    /// hooks parameters: low 160 bits = hook address, bits 160.. = flags (BEFORE_SWAP 1<<160, BEFORE_MINT 1<<164, BEFORE_BURN 1<<166, BEFORE_TRANSFER 1<<168)
    function getLBHooksParameters() external view returns (bytes32);

    // LB token (non-transferable except by the pair's rules; hooks revert a real batchTransferFrom)
    function totalSupply(uint256 id) external view returns (uint256);
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function isApprovedForAll(address owner, address spender) external view returns (bool);
    function approveForAll(address spender, bool approved) external;

    /// `from` must be msg.sender or have approved msg.sender. Reverts on a zero amount per bin (LBPair__ZeroAmount) and when a bin pays zero out
    /// (LBPair__ZeroAmountsOut). Calls the hook (beforeBurn) first: a reverting hook reverts the whole burn.
    function burn(address from, address to, uint256[] calldata ids, uint256[] calldata amountsToBurn)
        external
        returns (bytes32[] memory amounts);
}

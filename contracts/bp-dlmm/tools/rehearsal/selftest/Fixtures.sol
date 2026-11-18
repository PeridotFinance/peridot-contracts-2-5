// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// Test-only fixtures of the harness self-test (plumbing against a local anvil WITHOUT a fork). Nothing here is part of the product.
contract Erc20Slot0 {
    mapping(address => uint256) public balanceOf; // slot 0 (OpenZeppelin-like layout is slot 0 in a plain token)
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
}

contract Erc20Slot9 {
    uint256[9] private pad; // pushes the balances mapping to slot 9, like FiatToken (USDC)
    mapping(address => uint256) public balanceOf;
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
}

contract Thrower {
    uint256 public hits;
    error Boom(uint256 code);
    function ok() external { hits += 1; }
    function boom(uint256 x) public pure { revert Boom(x); }
    function req() external pure { require(false, "nope"); }
    function panic() external pure returns (uint256) { uint256[] memory a = new uint256[](1); return a[5]; }
    /// a nested revert: the outer frame re-throws what the inner frame reverted with
    function inner() external view { try this.boom(7) {} catch (bytes memory r) { assembly { revert(add(r, 32), mload(r)) } } }
}

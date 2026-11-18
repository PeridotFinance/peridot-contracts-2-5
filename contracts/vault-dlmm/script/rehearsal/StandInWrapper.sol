// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IShareToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice STAND-IN for a Peridot pToken whose underlying is the DLMM vault share, for the LOCAL FORK REHEARSAL of the wrapper-holder split ONLY
///         (tools/rewards-rehearsal, REH_WRAPPER=1). It emits the same ERC-20 Transfer logs as PToken.sol: a supply is Transfer(pToken -> minter, pTokens),
///         a redeem is Transfer(redeemer -> pToken, pTokens), a transfer between suppliers is Transfer(from -> to, pTokens). 1 vault share = 50 pTokens (a constant
///         rate: the generator uses pToken balances, never a rate). Holds the vault shares itself, like the pToken. No access control, no checks beyond underflow:
///         it is never deployed anywhere but a throwaway local chain.
contract StandInWrapper {
    uint256 public constant PTOKENS_PER_SHARE = 50;
    address public immutable underlying; // the vault share (the generator checks underlying() == the vault)
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 amount);

    constructor(address share) {
        underlying = share;
    }

    function mint(uint256 shares) external {
        require(IShareToken(underlying).transferFrom(msg.sender, address(this), shares), "share transfer failed");
        uint256 pTokens = shares * PTOKENS_PER_SHARE;
        totalSupply += pTokens;
        balanceOf[msg.sender] += pTokens;
        emit Transfer(address(this), msg.sender, pTokens);
    }

    function redeem(uint256 pTokens) external {
        balanceOf[msg.sender] -= pTokens;
        totalSupply -= pTokens;
        emit Transfer(msg.sender, address(this), pTokens);
        require(IShareToken(underlying).transfer(msg.sender, pTokens / PTOKENS_PER_SHARE), "share transfer failed");
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
}

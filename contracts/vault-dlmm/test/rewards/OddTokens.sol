// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Takes 1 % of every transfer (fee-on-transfer): the distributor must refuse to fund an epoch with it.
contract FeeToken is ERC20 {
    constructor() ERC20("Fee", "FEE") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee); // burnt
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @dev Over-delivers: the recipient receives 1 % MORE than asked (a rebasing or bonus token): the funded total would not match the leaves.
contract BonusToken is ERC20 {
    constructor() ERC20("Bonus", "BON") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to != address(0)) _mint(to, value / 100);
    }
}

/// @dev transfer and transferFrom return false (without reverting) once `broken` is set: SafeERC20 must turn that into a revert.
contract FalseReturnToken is ERC20 {
    bool public broken;

    constructor() ERC20("False", "FALSE") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function transfer(address to, uint256 v) public override returns (bool) {
        if (broken) return false;
        return super.transfer(to, v);
    }

    function transferFrom(address f, address to, uint256 v) public override returns (bool) {
        if (broken) return false;
        return super.transferFrom(f, to, v);
    }
}

/// @dev USDT style: transfer / transferFrom / approve return NOTHING. SafeERC20 must accept it.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external {
        allowance[msg.sender][s] = a;
    }

    function transfer(address to, uint256 a) external {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
    }

    function transferFrom(address f, address to, uint256 a) external {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
    }
}

/// @dev Blacklisting token (USDC style): a transfer to or from a blocked account reverts.
contract BlacklistToken is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("Block", "BLK") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[from] && !blocked[to], "blocked");
        super._update(from, to, value);
    }
}

interface ITokenHook {
    function onTokenReceived(address from, uint256 amount) external;
}

/// @dev ERC-777 style: after every transfer it calls `onTokenReceived` on the RECIPIENT when that is a contract (a re-entrancy vector for claim / cancel / sweep).
contract HookToken is ERC20 {
    address public exempt; // the distributor itself has no hook

    constructor() ERC20("Hook", "HOOK") {}

    function setExempt(address a) external {
        exempt = a;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to != exempt && to.code.length != 0) ITokenHook(to).onTokenReceived(from, value);
    }
}

/// @dev Calls the data it was given when it receives tokens, remembering whether that inner call worked. Can also be the distributor's OWNER.
contract Reenterer is ITokenHook {
    address public target;
    bytes public data;
    bool public armed;
    bool public lastSucceeded;
    bytes public lastReturn;
    uint256 public hits;

    function arm(address t, bytes calldata d) external {
        target = t;
        data = d;
        armed = true;
    }

    function onTokenReceived(address, uint256) external {
        if (!armed) return;
        armed = false; // one shot
        ++hits;
        (lastSucceeded, lastReturn) = target.call(data);
    }

    function exec(address t, bytes calldata d) external returns (bytes memory r) {
        bool ok;
        (ok, r) = t.call(d);
        if (!ok) {
            assembly {
                revert(add(r, 32), mload(r))
            }
        }
    }

    function approveToken(address token, address spender, uint256 a) external {
        ERC20(token).approve(spender, a);
    }
}

/// @dev A token whose hook reverts when the re-entrancy attempt fails: the whole outer call must then revert.
contract BubblingReenterer is ITokenHook {
    address public target;
    bytes public data;

    function arm(address t, bytes calldata d) external {
        target = t;
        data = d;
    }

    function onTokenReceived(address, uint256) external {
        (bool ok, bytes memory r) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(r, 32), mload(r))
            }
        }
    }
}

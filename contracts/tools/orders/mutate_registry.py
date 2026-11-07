#!/usr/bin/env python3
"""Mutation check for MarginOrderRegistry: each mutant is one textual change; the unit suite must fail on every one.

Run from contracts/:  python3 tools/orders/mutate_registry.py
Restores the source after every mutant (and on interrupt). Exit 1 if any mutant survives.
"""
import os
import subprocess
import sys
from pathlib import Path

SRC = Path('contracts/margin/orders/MarginOrderRegistry.sol')
TEST = 'test/orders/MarginOrderRegistry.t.sol'

MUTANTS = [
    # authorization
    ('create: skip owner check', 'if (msg.sender != a.positionOwner(positionId)) revert NotPositionOwner();', ''),
    ('create: skip active check', 'if (!a.isActive(positionId)) revert PositionNotActive();\n        // Long', '// Long'),
    ('create: invert direction rule', '((kind == OrderKind.TAKE_PROFIT) == a.isLong(positionId))', '((kind == OrderKind.TAKE_PROFIT) != a.isLong(positionId))'),
    ('create: skip direction', 'revert InvalidOrder(1);', '{}'),
    ('create: limit 5 open', 'open.length >= MAX_ORDERS_PER_POSITION', 'open.length > MAX_ORDERS_PER_POSITION'),
    ('modify: any position owner', 'if (msg.sender != o.owner || msg.sender != a.positionOwner(o.positionId))', 'if (msg.sender != a.positionOwner(o.positionId))'),
    ('modify: order owner only', 'if (msg.sender != o.owner || msg.sender != a.positionOwner(o.positionId))', 'if (msg.sender != o.owner)'),
    ('modify: expired allowed', 'if (o.status != OrderStatus.OPEN || block.timestamp > o.expiry) revert OrderNotOpen();', 'if (o.status != OrderStatus.OPEN) revert OrderNotOpen();'),
    ('modify: skip active', 'if (!a.isActive(o.positionId)) revert PositionNotActive();\n        _checkFields', '_checkFields'),
    ('modify: skip field checks', '_checkFields(triggerPriceE18, closeBps, maxSlippageBps, expiry);\n        o.triggerPriceE18', 'o.triggerPriceE18'),
    ('modify: closeBps not stored', 'o.closeBps = closeBps;\n        o.maxSlippageBps = maxSlippageBps;\n        o.expiry = expiry;\n        o.updatedAt', 'o.maxSlippageBps = maxSlippageBps;\n        o.expiry = expiry;\n        o.updatedAt'),
    ('cancel: anyone', 'if (msg.sender != o.owner) revert NotPositionOwner();\n        if (block.timestamp > o.expiry) _expire', 'if (block.timestamp > o.expiry) _expire'),
    ('cancel: expired becomes cancelled', 'if (block.timestamp > o.expiry) _expire(orderId, o);\n        else _cancel', 'if (false) _expire(orderId, o);\n        else _cancel'),
    # field bounds
    ('closeBps 0 allowed', 'if (closeBps == 0 || closeBps > BPS) revert InvalidOrder(2);', 'if (closeBps > BPS) revert InvalidOrder(2);'),
    ('closeBps > BPS allowed', 'if (closeBps == 0 || closeBps > BPS) revert InvalidOrder(2);', 'if (closeBps == 0) revert InvalidOrder(2);'),
    ('slippage 0 allowed', 'if (maxSlippageBps == 0 || maxSlippageBps > MAX_SLIPPAGE_BPS)', 'if (maxSlippageBps > MAX_SLIPPAGE_BPS)'),
    ('slippage edge off by one', 'maxSlippageBps > MAX_SLIPPAGE_BPS', 'maxSlippageBps >= MAX_SLIPPAGE_BPS'),
    ('expiry now allowed', 'if (expiry <= block.timestamp ||', 'if (expiry < block.timestamp ||'),
    ('lifetime unbounded', '|| expiry > block.timestamp + MAX_ORDER_LIFETIME) revert InvalidOrder(4);', ') revert InvalidOrder(4);'),
    ('lifetime edge off by one', 'expiry > block.timestamp + MAX_ORDER_LIFETIME', 'expiry >= block.timestamp + MAX_ORDER_LIFETIME'),
    ('zero trigger allowed', 'if (triggerPriceE18 == 0) revert InvalidOrder(5);', ''),
    # execution order and outcomes
    ('execute: no pause', 'if (paused) revert ExecutionPaused();', ''),
    ('execute: expiry exclusive', 'if (block.timestamp > o.expiry) {\n            _expire(orderId, o);\n            return false;', 'if (block.timestamp >= o.expiry) {\n            _expire(orderId, o);\n            return false;'),
    ('execute: expiry skipped', 'if (block.timestamp > o.expiry) {\n            _expire(orderId, o);\n            return false;', 'if (false) {\n            _expire(orderId, o);\n            return false;'),
    ('execute: inactive reverts', '_cancel(orderId, o, C_INACTIVE);\n            return false;', 'revert PositionNotActive();'),
    ('execute: owner change ignored', 'if (a.positionOwner(positionId) != o.owner) {\n            _cancel(orderId, o, C_OWNER_CHANGED);', 'if (false) {\n            _cancel(orderId, o, C_OWNER_CHANGED);'),
    ('execute: wrong cancel reason', '_cancel(orderId, o, C_INACTIVE);', '_cancel(orderId, o, C_OWNER_CHANGED);'),
    ('execute: oracle ok ignored', 'if (!ok || price == 0) revert OracleUnavailable();', 'if (price == 0) revert OracleUnavailable();'),
    ('execute: zero price accepted', 'if (!ok || price == 0) revert OracleUnavailable();', 'if (!ok) revert OracleUnavailable();'),
    ('execute: trigger ignored', 'if (!_crossed(o, price)) revert TriggerNotReached(price, o.triggerPriceE18);', ''),
    ('trigger above strict', 'price >= o.triggerPriceE18 : price <= o.triggerPriceE18', 'price > o.triggerPriceE18 : price <= o.triggerPriceE18'),
    ('trigger below strict', 'price >= o.triggerPriceE18 : price <= o.triggerPriceE18', 'price >= o.triggerPriceE18 : price < o.triggerPriceE18'),
    ('trigger direction swapped', 'return o.triggerAbove ? price >= o.triggerPriceE18', 'return !o.triggerAbove ? price >= o.triggerPriceE18'),
    ('execute: proceeds to caller', 'a.closeFor(positionId, owner, closeBps', 'a.closeFor(positionId, msg.sender, closeBps'),
    ('execute: slippage not passed', 'price, o.maxSlippageBps, adapterData)', 'price, MAX_SLIPPAGE_BPS, adapterData)'),
    ('execute: no sibling cancel', 'if (!a.isActive(positionId)) _cancelAllOpen(positionId, C_SIBLING);', ''),
    ('execute: sibling cancel always', 'if (!a.isActive(positionId)) _cancelAllOpen(positionId, C_SIBLING);', '_cancelAllOpen(positionId, C_SIBLING);'),
    ('execute: not removed from open', '_removeOpen(positionId, orderId);\n        uint256 returned', 'uint256 returned'),
    ('execute: no reentrancy guard', 'function executeOrder(uint256 orderId, bytes calldata adapterData) external nonReentrant returns', 'function executeOrder(uint256 orderId, bytes calldata adapterData) external returns'),
    # canExecute
    ('canExecute: pause ignored', 'if (paused) return (false, oraclePriceE18, R_PAUSED);', ''),
    ('canExecute: owner change ignored', 'if (current != o.owner) return (false, 0, R_OWNER_CHANGED);', ''),
    ('canExecute: wrong expired code', 'return (false, 0, R_EXPIRED);', 'return (false, 0, R_INACTIVE);'),
    ('canExecute: oracle ok ignored', 'if (!ok || price == 0) return (false, 0, R_ORACLE);', 'if (price == 0) return (false, 0, R_ORACLE);'),
    ('canExecute: catch reverts', '} catch {\n            return (false, 0, R_ORACLE);\n        }', '} catch {\n            revert OracleUnavailable();\n        }'),
    # admin and bookkeeping
    ('pause: anyone', 'if (msg.sender != admin) revert NotAdmin();', ''),
    ('init: zero adapter allowed', 'require(address(adapter_) != address(0) && admin_ != address(0), "REGISTRY_CONFIG");', 'require(admin_ != address(0), "REGISTRY_CONFIG");'),
    ('init: ids from 0', 'nextOrderId = 1;', ''),
    ('constructor: initializers open', '_disableInitializers();', ''),
    ('removeOpen: index not updated', '_openIndex[last] = slot;', ''),
]

# Known-equivalent: removing `delete _openIndex[orderId]` leaves a stale index for an id that is never looked up again
# (an order leaves the open set once and never returns), so no behaviour can observe it. Kept in the source for hygiene.
EQUIVALENT = [
    ('removeOpen: stale index kept', 'delete _openIndex[orderId];', ''),
]


V2_MUTANTS = [
    ('v2: TP check dropped', "if (kind == OrderKind.TAKE_PROFIT && range != address(0) && IRangeOrdersActive(range).isActive(positionId)) {", "if (false) {"),
    ('v2: blocks stop-losses instead', "if (kind == OrderKind.TAKE_PROFIT && range != address(0)", "if (kind == OrderKind.STOP_LOSS && range != address(0)"),
    ('v2: init by anyone', 'require(msg.sender == ERC1967Utils.getAdmin(), "REGISTRY_NOT_PROXY_ADMIN");', ''),
    ('v2: init accepts non-contracts', 'require(address(adapter_).code.length != 0 && rangeOrders_.code.length != 0, "REGISTRY_CONFIG");', ''),
    ('v2: adapter not re-pointed', '        adapter = adapter_;\n        rangeOrders = rangeOrders_;', '        rangeOrders = rangeOrders_;'),
    ('v2: range not stored', '        rangeOrders = rangeOrders_;\n        emit', '        emit'),
]
if '--v2' in sys.argv:
    SRC = Path('contracts/margin/orders/MarginOrderRegistryV2.sol')
    TEST = 'test/orders/MarginOrderRegistryV2.t.sol'
    MUTANTS = V2_MUTANTS


def run_tests():
    env = dict(os.environ, FOUNDRY_PROFILE='robinhood_orders')
    r = subprocess.run(['forge', 'test', '--match-path', TEST, '--fuzz-runs', '64'], capture_output=True, text=True, env=env)
    out = r.stdout + r.stderr
    if 'Compiler run failed' in out or 'Error (' in out:
        return 'compile-error'
    return 'pass' if r.returncode == 0 else 'fail'


def main():
    original = SRC.read_text()
    if run_tests() != 'pass':
        sys.exit('baseline suite does not pass')
    survivors = []
    try:
        for name, old, new in MUTANTS:
            if original.count(old) != 1:
                sys.exit(f'mutant pattern not unique or missing: {name}')
            SRC.write_text(original.replace(old, new))
            res = run_tests()
            killed = res != 'pass'
            print(f'{"KILLED " if killed else "SURVIVED"} {res:13s} {name}', flush=True)
            if not killed:
                survivors.append(name)
    finally:
        SRC.write_text(original)
    print(f'{len(MUTANTS) - len(survivors)}/{len(MUTANTS)} killed; {len(EQUIVALENT)} known-equivalent excluded')
    sys.exit(1 if survivors else 0)


if __name__ == '__main__':
    main()

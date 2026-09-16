// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PErc20Delegate} from "../contracts/PErc20Delegate.sol";
import {MagmaBoostedDelegate} from "../contracts/boosted/MagmaBoostedDelegate.sol";
import {RobinhoodBoostedDelegate} from "../contracts/boosted/RobinhoodBoostedDelegate.sol";
import {PharaohBoostedDelegate} from "../contracts/boosted/PharaohBoostedDelegate.sol";

contract BorrowAccountingReleaseSizeTest is Test {
    function testPinnedReleaseDelegatesAndHelperFitEIP170() public {
        if (keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("")))) != keccak256("debt_accounting")) {
            vm.skip(true);
            return;
        }
        PErc20Delegate delegate = new PErc20Delegate();
        _fits(address(delegate));
        _fits(delegate.borrowAccountingModule());
        _fits(address(new MagmaBoostedDelegate()));
        _fits(address(new RobinhoodBoostedDelegate()));
        _fits(address(new PharaohBoostedDelegate()));
        // Morpho already exceeded EIP-170 on the baseline default build and is NOT a release target here.
    }

    function _fits(address deployed) private view {
        assertGt(deployed.code.length, 0);
        assertLe(deployed.code.length, 24_576);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IStableVaultOracle} from "../IStableVaultOracle.sol";

/// @notice Independent valuation oracle used by a Pharaoh liquidity vault.
interface IPharaohVaultOracle is IStableVaultOracle {}

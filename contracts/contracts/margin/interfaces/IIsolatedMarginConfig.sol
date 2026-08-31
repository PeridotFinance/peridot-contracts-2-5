// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IsolatedMarginTypes} from "../IsolatedMarginTypes.sol";

interface IIsolatedMarginConfig {
    function BPS() external view returns (uint256);
    function opensPaused() external view returns (bool);
    function openFeeBps() external view returns (uint16);
    function closeFeeBps() external view returns (uint16);
    function depositorShareBps() external view returns (uint16);
    function insuranceShareBps() external view returns (uint16);
    function treasuryShareBps() external view returns (uint16);
    function feeImmediateShareBps() external view returns (uint16);
    function feeStreamDuration() external view returns (uint32);
    function insuranceFund() external view returns (address);
    function treasury() external view returns (address);
    function routerAdapter() external view returns (address);
    function flashLoanProvider() external view returns (address);
    function pairKey(address marginPToken, address positionPToken, address debtPToken) external pure returns (bytes32);
    function getPairRisk(address marginPToken, address positionPToken, address debtPToken)
        external
        view
        returns (IsolatedMarginTypes.PairRiskConfig memory);
}

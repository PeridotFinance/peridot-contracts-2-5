// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPharaohDlmmVault} from "./IPharaohDlmmVault.sol";
import {IDLMMPair} from "./interfaces/IDLMMPair.sol";
import {IDLMMRouter} from "./interfaces/IDLMMRouter.sol";
import {IDLMMFactory} from "./interfaces/IDLMMFactory.sol";
import {IDLMMRewarder, IDLMMVoter, IDLMMRewarderBeacon} from "./interfaces/IDLMMRewarder.sol";
import {IChainlinkFeed} from "./interfaces/IChainlinkFeed.sol";

/// @title PharaohDlmmPairValidator
/// @notice The initialize-time pair validation of `PharaohDlmmVault`, kept in a separate stateless contract only so that the vault's runtime stays
///         under the 24,576-byte limit. The vault's CONSTRUCTOR deploys one instance and stores it as an immutable of the implementation, so it is
///         part of the implementation (not a parameter, not upgradable, not callable with effect). It is a pure view over the chain: it reverts
///         `PairValidationFailed(check)` and returns the derived wiring. `PairValidationFailed` is the interface's error; the vault's `initialize`
///         bubbles it unchanged.
/// Checks (the number is the `check` argument):
///  1 a zero address or empty field     2 asset == pairToken      3 factory.getLBPairInformation(asset, pairToken, binStep) is `pair` with that bin step
///  4 pair.getFactory() / getBinStep() agree      5 pair tokens are exactly {asset, pairToken} (X/Y order read from getTokenX/getTokenY)
///  6 router.getFactory() == factory     7 pair hook (low 160 bits of getLBHooksParameters) == rewarder     8 rewarder.isLinked()
///  9 rewarder.owner() (the voter) lists the router as an authorised DLMM manager
/// 10 voter.dlmmRewarderFactory() (the beacon) lists `rewarder` for `pair`     11 beacon.implementation().codehash == the pinned codehash (non-zero)
/// 12 the reward token is non-zero and neither leg     13 both feeds report 8 decimals     14 token decimals <= 18
contract PharaohDlmmPairValidator {
    function validate(IPharaohDlmmVault.InitParams calldata p)
        external
        view
        returns (address tokenX, address tokenY, address beacon, address rewardToken, uint8 assetDecimals, uint8 pairDecimals)
    {
        if (
            p.asset == address(0) || p.pairToken == address(0) || p.pair == address(0) || p.router == address(0)
                || p.factory == address(0) || p.rewarder == address(0) || p.feedAsset == address(0)
                || p.feedPair == address(0) || p.owner == address(0) || p.rebalancer == address(0)
                || p.rewarderImplCodehash == bytes32(0)
        ) revert IPharaohDlmmVault.PairValidationFailed(1);
        if (p.asset == p.pairToken) revert IPharaohDlmmVault.PairValidationFailed(2);

        IDLMMFactory.LBPairInformation memory info =
            IDLMMFactory(p.factory).getLBPairInformation(p.asset, p.pairToken, p.binStep);
        if (info.LBPair != p.pair || info.binStep != p.binStep) revert IPharaohDlmmVault.PairValidationFailed(3);

        IDLMMPair pr = IDLMMPair(p.pair);
        if (pr.getFactory() != p.factory || pr.getBinStep() != p.binStep) revert IPharaohDlmmVault.PairValidationFailed(4);
        tokenX = pr.getTokenX();
        tokenY = pr.getTokenY();
        if (!((tokenX == p.asset && tokenY == p.pairToken) || (tokenX == p.pairToken && tokenY == p.asset))) {
            revert IPharaohDlmmVault.PairValidationFailed(5);
        }
        if (IDLMMRouter(p.router).getFactory() != p.factory) revert IPharaohDlmmVault.PairValidationFailed(6);
        if (address(uint160(uint256(pr.getLBHooksParameters()))) != p.rewarder) revert IPharaohDlmmVault.PairValidationFailed(7);
        IDLMMRewarder rw = IDLMMRewarder(p.rewarder);
        if (!rw.isLinked()) revert IPharaohDlmmVault.PairValidationFailed(8);
        address voter = rw.owner();
        if (voter == address(0) || !IDLMMVoter(voter).isAuthorizedDLMMManager(p.router)) {
            revert IPharaohDlmmVault.PairValidationFailed(9);
        }
        beacon = IDLMMVoter(voter).dlmmRewarderFactory();
        if (beacon == address(0) || IDLMMRewarderBeacon(beacon).getRewarder(p.pair) != p.rewarder) {
            revert IPharaohDlmmVault.PairValidationFailed(10);
        }
        if (IDLMMRewarderBeacon(beacon).implementation().codehash != p.rewarderImplCodehash) {
            revert IPharaohDlmmVault.PairValidationFailed(11);
        }
        rewardToken = rw.getRewardToken();
        if (rewardToken == address(0) || rewardToken == p.asset || rewardToken == p.pairToken) {
            revert IPharaohDlmmVault.PairValidationFailed(12);
        }
        if (IChainlinkFeed(p.feedAsset).decimals() != 8 || IChainlinkFeed(p.feedPair).decimals() != 8) {
            revert IPharaohDlmmVault.PairValidationFailed(13);
        }
        assetDecimals = IERC20Metadata(p.asset).decimals();
        pairDecimals = IERC20Metadata(p.pairToken).decimals();
        if (assetDecimals > 18 || pairDecimals > 18) revert IPharaohDlmmVault.PairValidationFailed(14);
    }
}

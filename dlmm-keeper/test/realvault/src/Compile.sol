// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Only imports: forces forge to produce artifacts for the real vault, W4's mocks and the proxy.
import "vault/src/PharaohDlmmVault.sol";
import "vault/test/mocks/MockERC20.sol";
import "vault/test/mocks/MockChainlinkFeed.sol";
import "vault/test/mocks/MockDlmmInfra.sol";
import "vault/test/mocks/MockLBPair.sol";
import "vault/test/mocks/MockRouter.sol";
import "vault/test/mocks/MockRewarder.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// the keeper's own quote helper for the mock pair, which has no getSwapOut (the real pair does): active-bin price and the pair's fee, no bin crossing
interface IMockPairForQuote {
    function getPriceFromId(uint24 id) external view returns (uint256);
    function getActiveId() external view returns (uint24);
    function feeWad() external view returns (uint256);
}

contract MockPairQuoter {
    IMockPairForQuote public immutable pair;
    constructor(address p) { pair = IMockPairForQuote(p); }
    function getSwapOut(uint128 amountIn, bool swapForY) external view returns (uint128, uint128, uint128) {
        uint256 price = pair.getPriceFromId(pair.getActiveId());
        uint256 gross = swapForY ? uint256(amountIn) * price / (uint256(1) << 128) : uint256(amountIn) * (uint256(1) << 128) / price;
        uint256 fee = gross * pair.feeWad() / 1e18;
        return (0, uint128(gross - fee), uint128(fee));
    }
}

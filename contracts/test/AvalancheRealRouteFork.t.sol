// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LFJLBRouterAdapter, ILFJLBRouter} from "../contracts/margin/LFJLBRouterAdapter.sol";
import {AvalanchePriceOracle} from "../contracts/margin/AvalanchePriceOracle.sol";

interface IRealLBQuote {
    function getTokenX() external view returns (address);
    function getTokenY() external view returns (address);
    function getSwapOut(uint128 amount, bool swapForY) external view returns (uint128, uint128, uint128);
}

/// @notice Read RPC + LOCAL VM writes only. No production margin deployment or mainnet broadcast.
/// Proves the oracle/adapter integration at pinned liquidity, not production capacity or a full margin lifecycle.
contract AvalancheRealRouteForkTest is Test {
    address constant ROUTER = 0x18556DA13313f3532c54711497A8FedAC273220E;
    address wavax;
    address usdc;
    IRealLBQuote pair;
    LFJLBRouterAdapter adapter;
    AvalanchePriceOracle oracle;
    uint256 binStep;
    uint8 version;

    function testMainnetRealFeedsAndHundredDollarRoundTrip() public {
        _mainnet();
        _roundTrip(100e6);
    }

    function testMainnetRealFeedsAndFiveHundredDollarRoundTrip() public {
        _mainnet();
        _roundTrip(500e6);
    }

    function testFujiBadPoolPriceFailsOnePercentOracleBound() public {
        _fork("AVALANCHE_FUJI_RPC_URL", 58_511_377, 43_113);
        wavax = 0xd00ae08403B9bbb9124bB305C09058E32C39A48c;
        usdc = 0xB6076C93701D6a07266c31066B298AeC6dd65c2d;
        pair = IRealLBQuote(0x0B16Fd47Cbf5350eBDe20aA813Db8E58846cd5D2);
        binStep = 20;
        version = 2;
        _setup(0x5498BB86BC934c8D34FDA08E81D444153d0D06aD, 0x97FE42a7E96640D932bbc0e1580c73E705A8EB73);
        uint256 amount = 0.01e18;
        uint256 floor = _oracleQuote(amount, true) * 9900 / 10_000;
        (uint128 left, uint128 out,) = pair.getSwapOut(uint128(amount), true);
        assertEq(left, 0);
        assertLt(out, floor, "pinned Fuji divergence no longer reproduced");
        deal(wavax, address(this), amount);
        IERC20(wavax).approve(address(adapter), amount);
        // Assert the router's actual minimum-output failure, not an unrelated route/config revert.
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("LBRouter__InsufficientAmountOut(uint256,uint256)")), floor, uint256(out)
            )
        );
        adapter.swap(address(this), wavax, usdc, amount, floor, abi.encode(binStep, version));
        assertEq(IERC20(wavax).balanceOf(address(this)), amount);
        assertEq(IERC20(wavax).balanceOf(address(adapter)), 0);
    }

    function _mainnet() private {
        _fork("AVALANCHE_MAINNET_RPC_URL", 95_767_958, 43_114);
        wavax = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
        usdc = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
        pair = IRealLBQuote(0x864d4e5Ee7318e97483DB7EB0912E09F161516EA);
        binStep = 10; // V2.2, discovered from this router's factory on-chain.
        version = 3;
        _setup(0x0A77230d17318075983913bC2145DB16C7366156, 0xF096872672F44d6EBA71458D74fe67F9a77a23B9);
    }

    function _fork(string memory key, uint256 blockNumber, uint256 chain) private {
        string memory rpc = vm.envOr(key, string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, blockNumber);
        assertEq(block.chainid, chain);
    }

    function _setup(address avaxFeed, address usdFeed) private {
        assertEq(ILFJLBRouter(ROUTER).getWNATIVE(), wavax);
        assertEq(pair.getTokenX(), wavax);
        assertEq(pair.getTokenY(), usdc);
        oracle = new AvalanchePriceOracle(address(this));
        oracle.configureFeed(wavax, avaxFeed, 1200);
        oracle.configureFeed(usdc, usdFeed, 90_000);
        assertGt(oracle.getPrice(wavax), 0);
        assertGt(oracle.getPrice(usdc), 0);
        adapter = new LFJLBRouterAdapter(address(this), ROUTER, 1 hours);
        // Local governance rehearsal only: queue in a simulated earlier timestamp, then return
        // to the actual pinned block time so real feed timestamps/prices need no mock or refresh.
        // Use the cheatcode read: the optimizer treats block.timestamp as invariant within a call.
        uint256 pinnedTime = vm.getBlockTimestamp();
        vm.warp(pinnedTime - 1 hours);
        adapter.queueOperator(address(this), true);
        adapter.queueRoute(wavax, usdc, binStep, version, true);
        vm.warp(pinnedTime);
        adapter.setOperator(address(this), true);
        adapter.setRoute(wavax, usdc, binStep, version, true);
    }

    function _roundTrip(uint256 amount) private {
        deal(usdc, address(this), amount); // Local account funding only, no on-chain mint.
        IERC20(usdc).approve(address(adapter), amount);
        uint256 avaxOut =
            adapter.swap(address(this), usdc, wavax, amount, _minimum(amount, false), abi.encode(binStep, version));
        assertGt(avaxOut, 0);
        assertEq(IERC20(usdc).allowance(address(adapter), ROUTER), 0);
        IERC20(wavax).approve(address(adapter), avaxOut);
        uint256 usdOut =
            adapter.swap(address(this), wavax, usdc, avaxOut, _minimum(avaxOut, true), abi.encode(binStep, version));
        assertGe(usdOut, amount * 9801 / 10_000);
        assertEq(IERC20(wavax).allowance(address(adapter), ROUTER), 0);
        assertEq(IERC20(usdc).balanceOf(address(adapter)), 0);
        assertEq(IERC20(wavax).balanceOf(address(adapter)), 0);
        vm.warp(vm.getBlockTimestamp() + 1201);
        assertEq(oracle.getPrice(wavax), 0, "stale oracle must fail closed");
    }

    function _minimum(uint256 amount, bool forward) private view returns (uint256) {
        (uint128 left, uint128 out,) = pair.getSwapOut(uint128(amount), forward);
        assertEq(left, 0, "incomplete liquidity");
        return Math.max(uint256(out) * 9900 / 10_000, _oracleQuote(amount, forward) * 9900 / 10_000);
    }

    function _oracleQuote(uint256 amount, bool forward) private view returns (uint256) {
        uint256 avaxPrice = oracle.getPrice(wavax);
        uint256 usdPrice = oracle.getPrice(usdc);
        require(avaxPrice > 0 && usdPrice > 0, "unusable feed");
        return forward
            ? Math.mulDiv(amount, avaxPrice * 1e6, usdPrice * 1e18)
            : Math.mulDiv(amount, usdPrice * 1e18, avaxPrice * 1e6);
    }
}

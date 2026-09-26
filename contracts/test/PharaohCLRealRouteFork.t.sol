// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PharaohCLRouterAdapter} from "../contracts/margin/PharaohCLRouterAdapter.sol";
import {AvalanchePriceOracle} from "../contracts/margin/AvalanchePriceOracle.sol";

/// @dev Pinned LOCAL Avalanche fork, real Pharaoh pool/router/feeds. No live writes.
contract PharaohCLRealRouteForkTest is Test {
    address internal constant USD = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address internal constant ROUTER = 0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c;
    address internal constant FACTORY = 0xAE6E5c62328ade73ceefD42228528b70c8157D0d;
    address internal constant POOL = 0xf01449C0bA930B6e2CaCA3DEF3CCBd7a3E589534;
    PharaohCLRouterAdapter internal adapter;
    AvalanchePriceOracle internal oracle;

    function setUp() public {
        string memory rpc = vm.envOr("AVALANCHE_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 96_140_026);
        assertEq(block.chainid, 43_114);
        adapter = new PharaohCLRouterAdapter(ROUTER, FACTORY, POOL, WAVAX, USD, 10);
        oracle = new AvalanchePriceOracle(address(this));
        oracle.configureFeed(WAVAX, 0x0A77230d17318075983913bC2145DB16C7366156, 1200);
        oracle.configureFeed(USD, 0xF096872672F44d6EBA71458D74fe67F9a77a23B9, 90_000);
        assertGt(oracle.getPrice(WAVAX), 0);
        assertGt(oracle.getPrice(USD), 0);
    }

    function testPharaohRealHundredDollarRoundTrip() public {
        _roundTrip(100e6);
    }

    function testPharaohRealFiveHundredDollarRoundTrip() public {
        _roundTrip(500e6);
    }

    function testPharaohRealFiveThousandDollarRoundTrip() public {
        _roundTrip(5000e6);
    }

    function _roundTrip(uint256 amount) internal {
        deal(USD, address(this), amount);
        IERC20(USD).approve(address(adapter), amount);
        uint256 minimum = Math.mulDiv(amount, oracle.getPrice(USD) * 1e12, oracle.getPrice(WAVAX)) * 9900 / 10_000;
        uint256 avaxOut = adapter.swap(address(this), USD, WAVAX, amount, minimum, "");
        IERC20(WAVAX).approve(address(adapter), avaxOut);
        minimum = Math.mulDiv(avaxOut, oracle.getPrice(WAVAX), oracle.getPrice(USD) * 1e12) * 9900 / 10_000;
        uint256 usdOut = adapter.swap(address(this), WAVAX, USD, avaxOut, minimum, "");
        assertGe(usdOut, amount * 9801 / 10_000);
        assertEq(IERC20(USD).allowance(address(adapter), ROUTER), 0);
        assertEq(IERC20(WAVAX).allowance(address(adapter), ROUTER), 0);
        assertEq(IERC20(USD).balanceOf(address(adapter)), 0);
        assertEq(IERC20(WAVAX).balanceOf(address(adapter)), 0);
        emit log_named_uint("USDC input", amount);
        emit log_named_uint("USDC returned", usdOut);
    }
}

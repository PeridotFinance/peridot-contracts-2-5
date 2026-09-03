// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILFJLBRouter} from "../contracts/margin/LFJLBRouterAdapter.sol";

interface IWavax is IERC20 {
    function deposit() external payable;
}

/**
 * @notice Converts Fuji AVAX into the WAVAX and LFJ USDC required to seed the lending markets.
 * @dev This is an operator preparation script, not a protocol contract. Its minimum USDC output is
 *      derived from live Chainlink prices and a bounded testnet slippage setting.
 */
contract PrepareAvalancheFujiLendingSeed is Script {
    using SafeERC20 for IERC20;

    uint256 private constant AVALANCHE_FUJI_CHAIN_ID = 43_113;
    uint256 private constant BPS = 10_000;
    uint256 private constant SWAP_DEADLINE_BUFFER = 10 minutes;
    uint256 private constant BIN_STEP = 20;

    address private constant DEFAULT_LFJ_ROUTER = 0x18556DA13313f3532c54711497A8FedAC273220E;
    address private constant DEFAULT_WAVAX = 0xd00ae08403B9bbb9124bB305C09058E32C39A48c;
    address private constant DEFAULT_LFJ_USDC = 0xB6076C93701D6a07266c31066B298AeC6dd65c2d;
    address private constant DEFAULT_AVAX_USD_FEED = 0x5498BB86BC934c8D34FDA08E81D444153d0D06aD;
    address private constant DEFAULT_USDC_USD_FEED = 0x97FE42a7E96640D932bbc0e1580c73E705A8EB73;

    function run() external returns (uint256 usdcReceived) {
        require(block.chainid == AVALANCHE_FUJI_CHAIN_ID, "PrepareFujiSeed: Fuji only");

        address deployer = vm.envAddress("MARGIN_DEPLOYER");
        address routerAddress = vm.envOr("LFJ_LB_ROUTER", DEFAULT_LFJ_ROUTER);
        address wavax = vm.envOr("FUJI_WAVAX", DEFAULT_WAVAX);
        address usdc = vm.envOr("FUJI_LFJ_USDC", DEFAULT_LFJ_USDC);
        address avaxUsdFeed = vm.envOr("FUJI_AVAX_USD_FEED", DEFAULT_AVAX_USD_FEED);
        address usdcUsdFeed = vm.envOr("FUJI_USDC_USD_FEED", DEFAULT_USDC_USD_FEED);
        uint256 wrapAmount = vm.envUint("PREPARE_WRAP_AVAX_AMOUNT");
        uint256 swapAmount = vm.envUint("PREPARE_SWAP_WAVAX_AMOUNT");
        uint256 requiredWavax = vm.envUint("LENDING_WAVAX_SEED_AMOUNT");
        uint256 requiredUsdc = vm.envUint("LENDING_USDC_SEED_AMOUNT");
        uint256 maxSlippageBps = vm.envOr("PREPARE_MAX_SLIPPAGE_BPS", uint256(500));
        uint256 minNativeGasBalance = vm.envOr("PREPARE_MIN_NATIVE_GAS_BALANCE", uint256(0.75 ether));
        uint256 avaxFeedMaxAge = vm.envOr("FUJI_AVAX_FEED_MAX_AGE", uint256(1_200));
        uint256 usdcFeedMaxAge = vm.envOr("FUJI_USDC_FEED_MAX_AGE", uint256(90_000));

        require(deployer != address(0), "PrepareFujiSeed: zero deployer");
        require(routerAddress.code.length > 0, "PrepareFujiSeed: router not contract");
        require(wavax.code.length > 0 && usdc.code.length > 0, "PrepareFujiSeed: token not contract");
        require(IERC20Metadata(wavax).decimals() == 18, "PrepareFujiSeed: WAVAX decimals");
        require(IERC20Metadata(usdc).decimals() == 6, "PrepareFujiSeed: USDC decimals");
        require(ILFJLBRouter(routerAddress).getWNATIVE() == wavax, "PrepareFujiSeed: wrong router WAVAX");
        require(wrapAmount > 0 && swapAmount > 0, "PrepareFujiSeed: zero amount");
        require(requiredWavax > 0 && requiredUsdc > 0, "PrepareFujiSeed: zero target");
        require(maxSlippageBps <= 1_000, "PrepareFujiSeed: slippage too high");
        require(
            avaxFeedMaxAge > 0 && avaxFeedMaxAge <= type(uint32).max && usdcFeedMaxAge > 0
                && usdcFeedMaxAge <= type(uint32).max,
            "PrepareFujiSeed: feed age"
        );
        require(deployer.balance >= wrapAmount + minNativeGasBalance, "PrepareFujiSeed: native gas reserve");

        uint256 currentWavax = IERC20(wavax).balanceOf(deployer);
        uint256 currentUsdc = IERC20(usdc).balanceOf(deployer);
        require(currentWavax + wrapAmount >= swapAmount + requiredWavax, "PrepareFujiSeed: insufficient WAVAX");

        uint256 avaxPrice = _readPrice(avaxUsdFeed, "AVAX / USD", avaxFeedMaxAge);
        uint256 usdcPrice = _readPrice(usdcUsdFeed, "USDC / USD", usdcFeedMaxAge);
        uint256 expectedUsdc = Math.mulDiv(Math.mulDiv(swapAmount, avaxPrice, 1e18), 1e6, usdcPrice);
        uint256 minUsdcOut = Math.mulDiv(expectedUsdc, BPS - maxSlippageBps, BPS);
        require(minUsdcOut > 0, "PrepareFujiSeed: zero minimum output");
        require(currentUsdc + minUsdcOut >= requiredUsdc, "PrepareFujiSeed: insufficient USDC minimum");

        uint256 usdcBefore = currentUsdc;
        vm.startBroadcast(deployer);
        IWavax(wavax).deposit{value: wrapAmount}();
        IERC20(wavax).forceApprove(routerAddress, swapAmount);
        ILFJLBRouter(routerAddress)
            .swapExactTokensForTokens(
                swapAmount, minUsdcOut, _path(wavax, usdc), deployer, block.timestamp + SWAP_DEADLINE_BUFFER
            );
        IERC20(wavax).forceApprove(routerAddress, 0);
        vm.stopBroadcast();

        usdcReceived = IERC20(usdc).balanceOf(deployer) - usdcBefore;
        require(usdcReceived >= minUsdcOut, "PrepareFujiSeed: output below minimum");
        require(IERC20(wavax).balanceOf(deployer) >= requiredWavax, "PrepareFujiSeed: WAVAX target");
        require(IERC20(usdc).balanceOf(deployer) >= requiredUsdc, "PrepareFujiSeed: USDC target");

        console2.log("Fuji WAVAX balance", IERC20(wavax).balanceOf(deployer));
        console2.log("Fuji LFJ USDC balance", IERC20(usdc).balanceOf(deployer));
        console2.log("LFJ USDC received", usdcReceived);
        console2.log("Chainlink-derived minimum USDC", minUsdcOut);
    }

    function _path(address wavax, address usdc) private pure returns (ILFJLBRouter.Path memory path) {
        path.pairBinSteps = new uint256[](1);
        path.pairBinSteps[0] = BIN_STEP;
        path.versions = new ILFJLBRouter.Version[](1);
        path.versions[0] = ILFJLBRouter.Version.V2_1;
        path.tokenPath = new IERC20[](2);
        path.tokenPath[0] = IERC20(wavax);
        path.tokenPath[1] = IERC20(usdc);
    }

    function _readPrice(address feed, string memory expectedDescription, uint256 maxAge)
        private
        view
        returns (uint256)
    {
        require(feed.code.length > 0 && maxAge > 0, "PrepareFujiSeed: invalid feed");
        AggregatorV3Interface aggregator = AggregatorV3Interface(feed);
        require(aggregator.decimals() == 8, "PrepareFujiSeed: feed decimals");
        require(
            keccak256(bytes(aggregator.description())) == keccak256(bytes(expectedDescription)),
            "PrepareFujiSeed: wrong feed"
        );
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = aggregator.latestRoundData();
        require(
            roundId != 0 && answer > 0 && updatedAt != 0 && updatedAt <= block.timestamp && answeredInRound >= roundId
                && block.timestamp - updatedAt <= maxAge,
            "PrepareFujiSeed: stale feed"
        );
        return uint256(answer) * 1e10;
    }
}

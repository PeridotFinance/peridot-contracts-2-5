// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {InterestRateModel} from "../contracts/InterestRateModel.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {Peridottroller} from "../contracts/Peridottroller.sol";
import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";
import {PharaohVaultShareOracle} from "../contracts/PharaohVaultShareOracle.sol";
import {PriceOracle} from "../contracts/PriceOracle.sol";
import {PToken} from "../contracts/PToken.sol";
import {PharaohBoostedDelegate} from "../contracts/boosted/PharaohBoostedDelegate.sol";

interface ILivePharaohVault is IERC4626 {
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function depositCap() external view returns (uint256);
}

/**
 * @notice Deploys the two Avalanche Pharaoh vault-share markets and their fail-closed oracle wrapper.
 * @dev Deployment does not replace the controller oracle, list a market, change a vault cap, transfer
 *      vault shares, or unpause anything. Governance configures the deployed contracts separately.
 */
contract DeployPharaohBoostedMarketsAvalanche is Script {
    uint256 private constant AVALANCHE_CHAIN_ID = 43_114;

    address private constant PHARAOH_SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
    address private constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address private constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;

    ILivePharaohVault private constant USDC_VAULT = ILivePharaohVault(0x855bF832f26a294d28500db59eE941dE3d654129);
    ILivePharaohVault private constant WAVAX_VAULT = ILivePharaohVault(0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8);

    AggregatorV3Interface private constant USDC_USD_FEED =
        AggregatorV3Interface(0xF096872672F44d6EBA71458D74fe67F9a77a23B9);
    AggregatorV3Interface private constant AVAX_USD_FEED =
        AggregatorV3Interface(0x0A77230d17318075983913bC2145DB16C7366156);

    struct Deployment {
        PharaohVaultShareOracle oracle;
        PharaohBoostedDelegate implementation;
        PErc20Delegator usdcMarket;
        PErc20Delegator wavaxMarket;
    }

    error DeployPharaohMarkets__WrongChain(uint256 actual);
    error DeployPharaohMarkets__InvalidAddress(address target);
    error DeployPharaohMarkets__UnexpectedVault(address vault);
    error DeployPharaohMarkets__OracleUnavailable(address market);

    function run() external returns (Deployment memory deployed) {
        if (block.chainid != AVALANCHE_CHAIN_ID) revert DeployPharaohMarkets__WrongChain(block.chainid);

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address controllerAddress = vm.envAddress("PERIDOTTROLLER");
        address interestRateModel = vm.envAddress("INTEREST_RATE_MODEL");
        address marketAdmin = vm.envAddress("MARKET_ADMIN");
        address oracleOwner = vm.envOr("ORACLE_OWNER", marketAdmin);
        uint64 maxStaleness = uint64(vm.envOr("PHARAOH_FEED_MAX_AGE", uint256(26 hours)));

        _requireContract(controllerAddress);
        _requireContract(interestRateModel);
        _requireContract(marketAdmin);
        _requireContract(oracleOwner);
        if (!InterestRateModel(interestRateModel).isInterestRateModel()) {
            revert DeployPharaohMarkets__InvalidAddress(interestRateModel);
        }

        _assertClosedLiveVault(USDC_VAULT, USDC);
        _assertClosedLiveVault(WAVAX_VAULT, WAVAX);

        Peridottroller controller = Peridottroller(controllerAddress);
        PriceOracle baseOracle = controller.oracle();
        _requireContract(address(baseOracle));

        vm.startBroadcast(deployerKey);
        deployed.oracle = new PharaohVaultShareOracle(deployer, baseOracle);
        deployed.oracle.registerVault(USDC_VAULT, USDC_USD_FEED, maxStaleness);
        deployed.oracle.registerVault(WAVAX_VAULT, AVAX_USD_FEED, maxStaleness);

        deployed.implementation = new PharaohBoostedDelegate();
        deployed.usdcMarket = _deployMarket(
            address(USDC_VAULT),
            controllerAddress,
            interestRateModel,
            marketAdmin,
            address(deployed.implementation),
            vm.envOr("USDC_MINIMUM_VAULT_SUPPLY", USDC_VAULT.totalSupply()),
            vm.envOr("USDC_INITIAL_EXCHANGE_RATE", _initialExchangeRate(USDC_VAULT, 8)),
            vm.envOr("USDC_PTOKEN_NAME", string("Peridot Boosted Pharaoh USDC/USDt")),
            vm.envOr("USDC_PTOKEN_SYMBOL", string("bpPHAR-USDC"))
        );
        deployed.wavaxMarket = _deployMarket(
            address(WAVAX_VAULT),
            controllerAddress,
            interestRateModel,
            marketAdmin,
            address(deployed.implementation),
            vm.envOr("WAVAX_MINIMUM_VAULT_SUPPLY", WAVAX_VAULT.totalSupply()),
            vm.envOr("WAVAX_INITIAL_EXCHANGE_RATE", _initialExchangeRate(WAVAX_VAULT, 8)),
            vm.envOr("WAVAX_PTOKEN_NAME", string("Peridot Boosted Pharaoh sAVAX/WAVAX")),
            vm.envOr("WAVAX_PTOKEN_SYMBOL", string("bpPHAR-WAVAX"))
        );

        if (deployed.oracle.getUnderlyingPrice(PToken(address(deployed.usdcMarket))) == 0) {
            revert DeployPharaohMarkets__OracleUnavailable(address(deployed.usdcMarket));
        }
        if (deployed.oracle.getUnderlyingPrice(PToken(address(deployed.wavaxMarket))) == 0) {
            revert DeployPharaohMarkets__OracleUnavailable(address(deployed.wavaxMarket));
        }
        deployed.oracle.transferOwnership(oracleOwner);
        vm.stopBroadcast();

        _log(deployed, baseOracle, marketAdmin, oracleOwner);
    }

    function _deployMarket(
        address vault,
        address controller,
        address interestRateModel,
        address marketAdmin,
        address implementation,
        uint256 minimumVaultSupply,
        uint256 initialExchangeRate,
        string memory name,
        string memory symbol
    ) private returns (PErc20Delegator) {
        return new PErc20Delegator(
            vault,
            PeridottrollerInterface(controller),
            InterestRateModel(interestRateModel),
            initialExchangeRate,
            name,
            symbol,
            8,
            payable(marketAdmin),
            implementation,
            abi.encode(vault, minimumVaultSupply)
        );
    }

    function _initialExchangeRate(IERC4626 vault, uint8 pTokenDecimals) private view returns (uint256) {
        uint8 shareDecimals = IERC20Metadata(address(vault)).decimals();
        if (uint256(shareDecimals) + 16 < pTokenDecimals) {
            revert DeployPharaohMarkets__UnexpectedVault(address(vault));
        }
        return 2 * (10 ** (uint256(shareDecimals) + 16 - pTokenDecimals));
    }

    function _assertClosedLiveVault(ILivePharaohVault vault, address expectedAsset) private view {
        _requireContract(address(vault));
        uint256 supply = vault.totalSupply();
        if (
            vault.asset() != expectedAsset || vault.owner() != PHARAOH_SAFE || vault.paused() || vault.depositCap() != 1
                || supply == 0 || vault.balanceOf(PHARAOH_SAFE) != supply || vault.maxDeposit(address(this)) != 0
                || vault.totalAssets() == 0
        ) revert DeployPharaohMarkets__UnexpectedVault(address(vault));
    }

    function _requireContract(address target) private view {
        if (target == address(0) || target.code.length == 0) {
            revert DeployPharaohMarkets__InvalidAddress(target);
        }
    }

    function _log(Deployment memory deployed, PriceOracle baseOracle, address marketAdmin, address oracleOwner)
        private
        pure
    {
        console2.log("PharaohVaultShareOracle", address(deployed.oracle));
        console2.log("Base oracle", address(baseOracle));
        console2.log("PharaohBoostedDelegate", address(deployed.implementation));
        console2.log("USDC/USDt boosted market", address(deployed.usdcMarket));
        console2.log("sAVAX/WAVAX boosted market", address(deployed.wavaxMarket));
        console2.log("Market admin", marketAdmin);
        console2.log("Oracle owner", oracleOwner);
        console2.log("Markets remain unlisted; vault deposit caps remain closed.");
    }
}

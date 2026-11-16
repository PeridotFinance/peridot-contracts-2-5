// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {PErc20Delegator} from "../../contracts/PErc20Delegator.sol";
import {PeridottrollerInterface} from "../../contracts/PeridottrollerInterface.sol";
import {InterestRateModel} from "../../contracts/InterestRateModel.sol";
import {RobinhoodPlainDelegate} from "../../contracts/margin/spy/RobinhoodPlainDelegate.sol";
import {RobinhoodLendingPriceAdapter3} from "../../contracts/margin/spy/RobinhoodLendingPriceAdapter3.sol";
import {SpyMarginPriceSource} from "../../contracts/margin/spy/SpyMarginPriceSource.sol";
import {MarginPriceSourceRouter} from "../../contracts/margin/spy/MarginPriceSourceRouter.sol";
import {SpyMarginParams as P} from "./SpyMarginParams.sol";

/// @notice Creates the five SPY-margin contracts (no proxy except the pSPY delegator; no admin anywhere except
/// pSPY's, which is the Ledger from construction). Everything else in the rollout is a Ledger call from the command list.
///
///   simulate:  FOUNDRY_PROFILE=robinhood_spy forge script script/spy/DeploySpyMargin.s.sol --rpc-url $RPC --sender $DEPLOYER
///   broadcast: add --broadcast --account <throwaway> (never the Ledger, never the old deployer)
///   verify:    SPY_MARGIN_ACTION=verify ... (reads deployments/spy-margin/<SPY_MARGIN_JOURNAL>.json; no transactions)
///
/// Parameters (operator-pending, env overrides): SPY_MAX_STALENESS (90000), SPY_CLOSED_FROM (432000 = Sat 00:00 UTC),
/// SPY_CLOSED_UNTIL (3600 = Mon 01:00 UTC). The pair caps are not deployed here; they go into the config queue.
contract DeploySpyMargin is Script {
    struct Deployed {
        address delegate;
        address pSpy;
        address lendingAdapter;
        address spySource;
        address router;
    }

    struct Params {
        uint256 maxStaleness;
        uint256 closedFrom;
        uint256 closedUntil;
    }

    function defaults() public view returns (Params memory p) {
        p.maxStaleness = vm.envOr("SPY_MAX_STALENESS", P.DEFAULT_MAX_STALENESS);
        p.closedFrom = vm.envOr("SPY_CLOSED_FROM", P.DEFAULT_CLOSED_FROM);
        p.closedUntil = vm.envOr("SPY_CLOSED_UNTIL", P.DEFAULT_CLOSED_UNTIL);
    }

    /// @dev Deploys from msg.sender context (the broadcaster in `run`, the caller contract in tests).
    function deployAll(Params memory p) public returns (Deployed memory d) {
        d.delegate = address(new RobinhoodPlainDelegate());
        // Borrower-share accounting is enabled by `PToken.initialize` for every new market; no activation step.
        d.pSpy = address(
            new PErc20Delegator(
                P.SPY,
                PeridottrollerInterface(P.CONTROLLER),
                InterestRateModel(P.IRM),
                P.PSPY_INITIAL_EXCHANGE_RATE,
                "Peridot Robinhood SPY",
                "pSPY",
                P.PSPY_DECIMALS,
                payable(P.LEDGER),
                d.delegate,
                ""
            )
        );
        d.lendingAdapter = address(new RobinhoodLendingPriceAdapter3(P.LENDING_ORACLE, P.PNVDA, P.PUSDG, d.pSpy));
        d.spySource = address(
            new SpyMarginPriceSource(
                P.SPY_FEED, P.SPY, P.USDG, P.LENDING_ORACLE, p.maxStaleness, p.closedFrom, p.closedUntil
            )
        );
        d.router = address(new MarginPriceSourceRouter(P.NVDA_GUARDED_SOURCE, d.spySource, P.SPY, P.USDG));
    }

    function run() external {
        require(block.chainid == P.CHAIN_ID, "CHAIN");
        string memory action = vm.envOr("SPY_MARGIN_ACTION", string("deploy"));
        string memory name = vm.envOr("SPY_MARGIN_JOURNAL", string("spy-margin-mainnet"));
        string memory path = string.concat(vm.projectRoot(), "/deployments/spy-margin/", name, ".json");
        if (keccak256(bytes(action)) == keccak256("verify")) {
            string memory j = vm.readFile(path);
            Deployed memory e = Deployed({
                delegate: vm.parseJsonAddress(j, ".delegate"),
                pSpy: vm.parseJsonAddress(j, ".pSpy"),
                lendingAdapter: vm.parseJsonAddress(j, ".lendingAdapter"),
                spySource: vm.parseJsonAddress(j, ".spySource"),
                router: vm.parseJsonAddress(j, ".router")
            });
            Params memory jp = Params({
                maxStaleness: vm.parseJsonUint(j, ".maxStaleness"),
                closedFrom: vm.parseJsonUint(j, ".closedFrom"),
                closedUntil: vm.parseJsonUint(j, ".closedUntil")
            });
            verify(e, jp);
            return;
        }
        require(keccak256(bytes(action)) == keccak256("deploy"), "ACTION");
        Params memory params = defaults();
        vm.startBroadcast();
        Deployed memory d = deployAll(params);
        vm.stopBroadcast();
        verify(d, params);
        string memory k = "spy";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "deployer", msg.sender);
        vm.serializeUint(k, "maxStaleness", params.maxStaleness);
        vm.serializeUint(k, "closedFrom", params.closedFrom);
        vm.serializeUint(k, "closedUntil", params.closedUntil);
        vm.serializeAddress(k, "delegate", d.delegate);
        vm.serializeAddress(k, "pSpy", d.pSpy);
        vm.serializeAddress(k, "lendingAdapter", d.lendingAdapter);
        vm.serializeAddress(k, "spySource", d.spySource);
        string memory out = vm.serializeAddress(k, "router", d.router);
        vm.writeJson(out, path);
    }

    /// @notice Read-only identity checks of a deployment against the live system and the chosen parameters.
    function verify(Deployed memory d, Params memory p) public view {
        IPSpyView m = IPSpyView(d.pSpy);
        require(m.underlying() == P.SPY, "PSPY_UNDERLYING");
        require(m.admin() == P.LEDGER && m.pendingAdmin() == address(0), "PSPY_ADMIN");
        require(m.implementation() == d.delegate, "PSPY_IMPLEMENTATION");
        require(address(m.peridottroller()) == P.CONTROLLER, "PSPY_CONTROLLER");
        require(m.interestRateModel() == P.IRM, "PSPY_IRM");
        require(m.decimals() == P.PSPY_DECIMALS, "PSPY_DECIMALS");
        require(m.borrowAccountingEnabled(), "PSPY_BORROW_ACCOUNTING");
        require(m.totalBorrows() == 0, "PSPY_BORROWS");
        require(m.exchangeRateStored() == P.PSPY_INITIAL_EXCHANGE_RATE || m.totalSupply() != 0, "PSPY_RATE");
        RobinhoodLendingPriceAdapter3 a = RobinhoodLendingPriceAdapter3(d.lendingAdapter);
        require(
            address(a.source()) == P.LENDING_ORACLE && a.stockMarket() == P.PNVDA && a.dollarMarket() == P.PUSDG
                && a.secondStockMarket() == d.pSpy,
            "LENDING_ADAPTER"
        );
        SpyMarginPriceSource s = SpyMarginPriceSource(d.spySource);
        require(
            address(s.feed()) == P.SPY_FEED && s.stock() == P.SPY && s.usd() == P.USDG
                && address(s.lendingSource()) == P.LENDING_ORACLE && s.maxStaleness() == p.maxStaleness
                && s.closedFrom() == p.closedFrom && s.closedUntil() == p.closedUntil && s.feedDecimals() == 8,
            "SPY_SOURCE"
        );
        MarginPriceSourceRouter r = MarginPriceSourceRouter(d.router);
        require(
            address(r.primary()) == P.NVDA_GUARDED_SOURCE && address(r.secondary()) == d.spySource
                && r.secondaryAsset() == P.SPY && r.sharedAsset() == P.USDG,
            "ROUTER"
        );
    }
}

interface IPSpyView {
    function underlying() external view returns (address);
    function admin() external view returns (address);
    function pendingAdmin() external view returns (address);
    function implementation() external view returns (address);
    function peridottroller() external view returns (address);
    function interestRateModel() external view returns (address);
    function decimals() external view returns (uint8);
    function borrowAccountingEnabled() external view returns (bool);
    function totalBorrows() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
}

// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "../PErc20.sol";
import "../PToken.sol";
import "../PriceOracle.sol";
import "../EIP20Interface.sol";
import "../Governance/GovernorAlpha.sol";
import "../Governance/Peridot.sol";

interface PeridottrollerLensInterface {
    function markets(address) external view returns (bool, uint256);

    function oracle() external view returns (PriceOracle);

    function getAccountLiquidity(address) external view returns (uint256, uint256, uint256);

    function getAssetsIn(address) external view returns (PToken[] memory);

    function claimPeridot(address) external;

    function peridotAccrued(address) external view returns (uint256);

    function peridotSpeeds(address) external view returns (uint256);

    function peridotSupplySpeeds(address) external view returns (uint256);

    function peridotBorrowSpeeds(address) external view returns (uint256);

    function borrowCaps(address) external view returns (uint256);
}

interface GovernorBravoInterface {
    struct Receipt {
        bool hasVoted;
        uint8 support;
        uint96 votes;
    }

    struct Proposal {
        uint256 id;
        address proposer;
        uint256 eta;
        uint256 startBlock;
        uint256 endBlock;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool canceled;
        bool executed;
    }

    function getActions(uint256 proposalId)
        external
        view
        returns (
            address[] memory targets,
            uint256[] memory values,
            string[] memory signatures,
            bytes[] memory calldatas
        );

    function proposals(uint256 proposalId) external view returns (Proposal memory);

    function getReceipt(uint256 proposalId, address voter) external view returns (Receipt memory);
}

contract PeridotLens {
    struct PTokenMetadata {
        address pToken;
        uint256 exchangeRateCurrent;
        uint256 supplyRatePerBlock;
        uint256 borrowRatePerBlock;
        uint256 reserveFactorMantissa;
        uint256 totalBorrows;
        uint256 totalReserves;
        uint256 totalSupply;
        uint256 totalCash;
        bool isListed;
        uint256 collateralFactorMantissa;
        address underlyingAssetAddress;
        uint256 pTokenDecimals;
        uint256 underlyingDecimals;
        uint256 peridotSupplySpeed;
        uint256 peridotBorrowSpeed;
        uint256 borrowCap;
    }

    function getPeridotSpeeds(PeridottrollerLensInterface peridottroller, PToken pToken)
        internal
        returns (uint256, uint256)
    {
        // Getting peridot speeds is gnarly due to not every network having the
        // split peridot speeds from Proposal 62 and other networks don't even
        // have peridot speeds.
        uint256 peridotSupplySpeed = 0;
        (bool peridotSupplySpeedSuccess, bytes memory peridotSupplySpeedReturnData) = address(peridottroller).call(
            abi.encodePacked(peridottroller.peridotSupplySpeeds.selector, abi.encode(address(pToken)))
        );
        if (peridotSupplySpeedSuccess) {
            peridotSupplySpeed = abi.decode(peridotSupplySpeedReturnData, (uint256));
        }

        uint256 peridotBorrowSpeed = 0;
        (bool peridotBorrowSpeedSuccess, bytes memory peridotBorrowSpeedReturnData) = address(peridottroller).call(
            abi.encodePacked(peridottroller.peridotBorrowSpeeds.selector, abi.encode(address(pToken)))
        );
        if (peridotBorrowSpeedSuccess) {
            peridotBorrowSpeed = abi.decode(peridotBorrowSpeedReturnData, (uint256));
        }

        // If the split peridot speeds call doesn't work, try the  oldest non-spit version.
        if (!peridotSupplySpeedSuccess || !peridotBorrowSpeedSuccess) {
            (bool peridotSpeedSuccess, bytes memory peridotSpeedReturnData) = address(peridottroller).call(
                abi.encodePacked(peridottroller.peridotSpeeds.selector, abi.encode(address(pToken)))
            );
            if (peridotSpeedSuccess) {
                peridotSupplySpeed = peridotBorrowSpeed = abi.decode(peridotSpeedReturnData, (uint256));
            }
        }
        return (peridotSupplySpeed, peridotBorrowSpeed);
    }

    function pTokenMetadata(PToken pToken) public returns (PTokenMetadata memory) {
        uint256 exchangeRateCurrent = pToken.exchangeRateCurrent();
        PeridottrollerLensInterface peridottroller = PeridottrollerLensInterface(address(pToken.peridottroller()));
        (bool isListed, uint256 collateralFactorMantissa) = peridottroller.markets(address(pToken));
        address underlyingAssetAddress;
        uint256 underlyingDecimals;

        if (peridotareStrings(pToken.symbol(), "cETH")) {
            underlyingAssetAddress = address(0);
            underlyingDecimals = 18;
        } else {
            PErc20 cErc20 = PErc20(address(pToken));
            underlyingAssetAddress = cErc20.underlying();
            underlyingDecimals = EIP20Interface(cErc20.underlying()).decimals();
        }

        (uint256 peridotSupplySpeed, uint256 peridotBorrowSpeed) = getPeridotSpeeds(peridottroller, pToken);

        uint256 borrowCap = 0;
        (bool borrowCapSuccess, bytes memory borrowCapReturnData) = address(peridottroller).call(
            abi.encodePacked(peridottroller.borrowCaps.selector, abi.encode(address(pToken)))
        );
        if (borrowCapSuccess) {
            borrowCap = abi.decode(borrowCapReturnData, (uint256));
        }

        return PTokenMetadata({
            pToken: address(pToken),
            exchangeRateCurrent: exchangeRateCurrent,
            supplyRatePerBlock: pToken.supplyRatePerBlock(),
            borrowRatePerBlock: pToken.borrowRatePerBlock(),
            reserveFactorMantissa: pToken.reserveFactorMantissa(),
            totalBorrows: pToken.totalBorrows(),
            totalReserves: pToken.totalReserves(),
            totalSupply: pToken.totalSupply(),
            totalCash: pToken.getCash(),
            isListed: isListed,
            collateralFactorMantissa: collateralFactorMantissa,
            underlyingAssetAddress: underlyingAssetAddress,
            pTokenDecimals: pToken.decimals(),
            underlyingDecimals: underlyingDecimals,
            peridotSupplySpeed: peridotSupplySpeed,
            peridotBorrowSpeed: peridotBorrowSpeed,
            borrowCap: borrowCap
        });
    }

    function pTokenMetadataAll(PToken[] calldata pTokens) external returns (PTokenMetadata[] memory) {
        uint256 pTokenCount = pTokens.length;
        PTokenMetadata[] memory res = new PTokenMetadata[](pTokenCount);
        for (uint256 i = 0; i < pTokenCount; i++) {
            res[i] = pTokenMetadata(pTokens[i]);
        }
        return res;
    }

    struct PTokenBalances {
        address pToken;
        uint256 balanceOf;
        uint256 borrowBalanceCurrent;
        uint256 balanceOfUnderlying;
        uint256 tokenBalance;
        uint256 tokenAllowance;
    }

    function pTokenBalances(PToken pToken, address payable account) public returns (PTokenBalances memory) {
        uint256 balanceOf = pToken.balanceOf(account);
        uint256 borrowBalanceCurrent = pToken.borrowBalanceCurrent(account);
        uint256 balanceOfUnderlying = pToken.balanceOfUnderlying(account);
        uint256 tokenBalance;
        uint256 tokenAllowance;

        if (peridotareStrings(pToken.symbol(), "cETH")) {
            tokenBalance = account.balance;
            tokenAllowance = account.balance;
        } else {
            PErc20 cErc20 = PErc20(address(pToken));
            EIP20Interface underlying = EIP20Interface(cErc20.underlying());
            tokenBalance = underlying.balanceOf(account);
            tokenAllowance = underlying.allowance(account, address(pToken));
        }

        return PTokenBalances({
            pToken: address(pToken),
            balanceOf: balanceOf,
            borrowBalanceCurrent: borrowBalanceCurrent,
            balanceOfUnderlying: balanceOfUnderlying,
            tokenBalance: tokenBalance,
            tokenAllowance: tokenAllowance
        });
    }

    function pTokenBalancesAll(PToken[] calldata pTokens, address payable account)
        external
        returns (PTokenBalances[] memory)
    {
        uint256 pTokenCount = pTokens.length;
        PTokenBalances[] memory res = new PTokenBalances[](pTokenCount);
        for (uint256 i = 0; i < pTokenCount; i++) {
            res[i] = pTokenBalances(pTokens[i], account);
        }
        return res;
    }

    struct PTokenUnderlyingPrice {
        address pToken;
        uint256 underlyingPrice;
    }

    function pTokenUnderlyingPrice(PToken pToken) public returns (PTokenUnderlyingPrice memory) {
        PeridottrollerLensInterface peridottroller = PeridottrollerLensInterface(address(pToken.peridottroller()));
        PriceOracle priceOracle = peridottroller.oracle();

        return PTokenUnderlyingPrice({pToken: address(pToken), underlyingPrice: priceOracle.getUnderlyingPrice(pToken)});
    }

    function pTokenUnderlyingPriceAll(PToken[] calldata pTokens) external returns (PTokenUnderlyingPrice[] memory) {
        uint256 pTokenCount = pTokens.length;
        PTokenUnderlyingPrice[] memory res = new PTokenUnderlyingPrice[](pTokenCount);
        for (uint256 i = 0; i < pTokenCount; i++) {
            res[i] = pTokenUnderlyingPrice(pTokens[i]);
        }
        return res;
    }

    struct AccountLimits {
        PToken[] markets;
        uint256 liquidity;
        uint256 shortfall;
    }

    function getAccountLimits(PeridottrollerLensInterface peridottroller, address account)
        public
        returns (AccountLimits memory)
    {
        (uint256 errorCode, uint256 liquidity, uint256 shortfall) = peridottroller.getAccountLiquidity(account);
        require(errorCode == 0);

        return AccountLimits({markets: peridottroller.getAssetsIn(account), liquidity: liquidity, shortfall: shortfall});
    }

    struct GovReceipt {
        uint256 proposalId;
        bool hasVoted;
        bool support;
        uint96 votes;
    }

    function getGovReceipts(GovernorAlpha governor, address voter, uint256[] memory proposalIds)
        public
        view
        returns (GovReceipt[] memory)
    {
        uint256 proposalCount = proposalIds.length;
        GovReceipt[] memory res = new GovReceipt[](proposalCount);
        for (uint256 i = 0; i < proposalCount; i++) {
            GovernorAlpha.Receipt memory receipt = governor.getReceipt(proposalIds[i], voter);
            res[i] = GovReceipt({
                proposalId: proposalIds[i],
                hasVoted: receipt.hasVoted,
                support: receipt.support,
                votes: receipt.votes
            });
        }
        return res;
    }

    struct GovBravoReceipt {
        uint256 proposalId;
        bool hasVoted;
        uint8 support;
        uint96 votes;
    }

    function getGovBravoReceipts(GovernorBravoInterface governor, address voter, uint256[] memory proposalIds)
        public
        view
        returns (GovBravoReceipt[] memory)
    {
        uint256 proposalCount = proposalIds.length;
        GovBravoReceipt[] memory res = new GovBravoReceipt[](proposalCount);
        for (uint256 i = 0; i < proposalCount; i++) {
            GovernorBravoInterface.Receipt memory receipt = governor.getReceipt(proposalIds[i], voter);
            res[i] = GovBravoReceipt({
                proposalId: proposalIds[i],
                hasVoted: receipt.hasVoted,
                support: receipt.support,
                votes: receipt.votes
            });
        }
        return res;
    }

    struct GovProposal {
        uint256 proposalId;
        address proposer;
        uint256 eta;
        address[] targets;
        uint256[] values;
        string[] signatures;
        bytes[] calldatas;
        uint256 startBlock;
        uint256 endBlock;
        uint256 forVotes;
        uint256 againstVotes;
        bool canceled;
        bool executed;
    }

    function setProposal(GovProposal memory res, GovernorAlpha governor, uint256 proposalId) internal view {
        (
            ,
            address proposer,
            uint256 eta,
            uint256 startBlock,
            uint256 endBlock,
            uint256 forVotes,
            uint256 againstVotes,
            bool canceled,
            bool executed
        ) = governor.proposals(proposalId);
        res.proposalId = proposalId;
        res.proposer = proposer;
        res.eta = eta;
        res.startBlock = startBlock;
        res.endBlock = endBlock;
        res.forVotes = forVotes;
        res.againstVotes = againstVotes;
        res.canceled = canceled;
        res.executed = executed;
    }

    function getGovProposals(GovernorAlpha governor, uint256[] calldata proposalIds)
        external
        view
        returns (GovProposal[] memory)
    {
        GovProposal[] memory res = new GovProposal[](proposalIds.length);
        for (uint256 i = 0; i < proposalIds.length; i++) {
            (address[] memory targets, uint256[] memory values, string[] memory signatures, bytes[] memory calldatas) =
                governor.getActions(proposalIds[i]);
            res[i] = GovProposal({
                proposalId: 0,
                proposer: address(0),
                eta: 0,
                targets: targets,
                values: values,
                signatures: signatures,
                calldatas: calldatas,
                startBlock: 0,
                endBlock: 0,
                forVotes: 0,
                againstVotes: 0,
                canceled: false,
                executed: false
            });
            setProposal(res[i], governor, proposalIds[i]);
        }
        return res;
    }

    struct GovBravoProposal {
        uint256 proposalId;
        address proposer;
        uint256 eta;
        address[] targets;
        uint256[] values;
        string[] signatures;
        bytes[] calldatas;
        uint256 startBlock;
        uint256 endBlock;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool canceled;
        bool executed;
    }

    function setBravoProposal(GovBravoProposal memory res, GovernorBravoInterface governor, uint256 proposalId)
        internal
        view
    {
        GovernorBravoInterface.Proposal memory p = governor.proposals(proposalId);

        res.proposalId = proposalId;
        res.proposer = p.proposer;
        res.eta = p.eta;
        res.startBlock = p.startBlock;
        res.endBlock = p.endBlock;
        res.forVotes = p.forVotes;
        res.againstVotes = p.againstVotes;
        res.abstainVotes = p.abstainVotes;
        res.canceled = p.canceled;
        res.executed = p.executed;
    }

    function getGovBravoProposals(GovernorBravoInterface governor, uint256[] calldata proposalIds)
        external
        view
        returns (GovBravoProposal[] memory)
    {
        GovBravoProposal[] memory res = new GovBravoProposal[](proposalIds.length);
        for (uint256 i = 0; i < proposalIds.length; i++) {
            (address[] memory targets, uint256[] memory values, string[] memory signatures, bytes[] memory calldatas) =
                governor.getActions(proposalIds[i]);
            res[i] = GovBravoProposal({
                proposalId: 0,
                proposer: address(0),
                eta: 0,
                targets: targets,
                values: values,
                signatures: signatures,
                calldatas: calldatas,
                startBlock: 0,
                endBlock: 0,
                forVotes: 0,
                againstVotes: 0,
                abstainVotes: 0,
                canceled: false,
                executed: false
            });
            setBravoProposal(res[i], governor, proposalIds[i]);
        }
        return res;
    }

    struct PeridotBalanceMetadata {
        uint256 balance;
        uint256 votes;
        address delegate;
    }

    function getPeridotBalanceMetadata(Peridot peridot, address account)
        external
        view
        returns (PeridotBalanceMetadata memory)
    {
        return PeridotBalanceMetadata({
            balance: peridot.balanceOf(account),
            votes: uint256(peridot.getCurrentVotes(account)),
            delegate: peridot.delegates(account)
        });
    }

    struct PeridotBalanceMetadataExt {
        uint256 balance;
        uint256 votes;
        address delegate;
        uint256 allocated;
    }

    function getPeridotBalanceMetadataExt(Peridot peridot, PeridottrollerLensInterface peridottroller, address account)
        external
        returns (PeridotBalanceMetadataExt memory)
    {
        uint256 balance = peridot.balanceOf(account);
        peridottroller.claimPeridot(account);
        uint256 newBalance = peridot.balanceOf(account);
        uint256 accrued = peridottroller.peridotAccrued(account);
        uint256 total = add(accrued, newBalance, "sum peridot total");
        uint256 allocated = sub(total, balance, "sub allocated");

        return PeridotBalanceMetadataExt({
            balance: balance,
            votes: uint256(peridot.getCurrentVotes(account)),
            delegate: peridot.delegates(account),
            allocated: allocated
        });
    }

    struct PeridotVotes {
        uint256 blockNumber;
        uint256 votes;
    }

    function getPeridotVotes(Peridot peridot, address account, uint32[] calldata blockNumbers)
        external
        view
        returns (PeridotVotes[] memory)
    {
        PeridotVotes[] memory res = new PeridotVotes[](blockNumbers.length);
        for (uint256 i = 0; i < blockNumbers.length; i++) {
            res[i] = PeridotVotes({
                blockNumber: uint256(blockNumbers[i]),
                votes: uint256(peridot.getPriorVotes(account, blockNumbers[i]))
            });
        }
        return res;
    }

    function peridotareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }

    function add(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, errorMessage);
        return c;
    }

    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;
        return c;
    }
}

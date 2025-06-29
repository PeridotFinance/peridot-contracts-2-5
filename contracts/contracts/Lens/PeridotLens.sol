// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "../PErc20.sol";
import "../PToken.sol";
import "../PriceOracle.sol";
import "../EIP20Interface.sol";
import "../Governance/GovernorAlpha.sol";
import "../Governance/Peridot.sol";

interface PeridottrollerLensInterface {
    function markets(address) external view returns (bool, uint);

    function oracle() external view returns (PriceOracle);

    function getAccountLiquidity(
        address
    ) external view returns (uint, uint, uint);

    function getAssetsIn(address) external view returns (PToken[] memory);

    function claimPeridot(address) external;

    function peridotAccrued(address) external view returns (uint);

    function peridotSpeeds(address) external view returns (uint);

    function peridotSupplySpeeds(address) external view returns (uint);

    function peridotBorrowSpeeds(address) external view returns (uint);

    function borrowCaps(address) external view returns (uint);
}

interface GovernorBravoInterface {
    struct Receipt {
        bool hasVoted;
        uint8 support;
        uint96 votes;
    }
    struct Proposal {
        uint id;
        address proposer;
        uint eta;
        uint startBlock;
        uint endBlock;
        uint forVotes;
        uint againstVotes;
        uint abstainVotes;
        bool canceled;
        bool executed;
    }

    function getActions(
        uint proposalId
    )
        external
        view
        returns (
            address[] memory targets,
            uint[] memory values,
            string[] memory signatures,
            bytes[] memory calldatas
        );

    function proposals(uint proposalId) external view returns (Proposal memory);

    function getReceipt(
        uint proposalId,
        address voter
    ) external view returns (Receipt memory);
}

contract PeridotLens {
    struct PTokenMetadata {
        address pToken;
        uint exchangeRateCurrent;
        uint supplyRatePerBlock;
        uint borrowRatePerBlock;
        uint reserveFactorMantissa;
        uint totalBorrows;
        uint totalReserves;
        uint totalSupply;
        uint totalCash;
        bool isListed;
        uint collateralFactorMantissa;
        address underlyingAssetAddress;
        uint pTokenDecimals;
        uint underlyingDecimals;
        uint peridotSupplySpeed;
        uint peridotBorrowSpeed;
        uint borrowCap;
    }

    function getPeridotSpeeds(
        PeridottrollerLensInterface peridottroller,
        PToken pToken
    ) internal returns (uint, uint) {
        // Getting peridot speeds is gnarly due to not every network having the
        // split peridot speeds from Proposal 62 and other networks don't even
        // have peridot speeds.
        uint peridotSupplySpeed = 0;
        (
            bool peridotSupplySpeedSuccess,
            bytes memory peridotSupplySpeedReturnData
        ) = address(peridottroller).call(
                abi.encodePacked(
                    peridottroller.peridotSupplySpeeds.selector,
                    abi.encode(address(pToken))
                )
            );
        if (peridotSupplySpeedSuccess) {
            peridotSupplySpeed = abi.decode(
                peridotSupplySpeedReturnData,
                (uint)
            );
        }

        uint peridotBorrowSpeed = 0;
        (
            bool peridotBorrowSpeedSuccess,
            bytes memory peridotBorrowSpeedReturnData
        ) = address(peridottroller).call(
                abi.encodePacked(
                    peridottroller.peridotBorrowSpeeds.selector,
                    abi.encode(address(pToken))
                )
            );
        if (peridotBorrowSpeedSuccess) {
            peridotBorrowSpeed = abi.decode(
                peridotBorrowSpeedReturnData,
                (uint)
            );
        }

        // If the split peridot speeds call doesn't work, try the  oldest non-spit version.
        if (!peridotSupplySpeedSuccess || !peridotBorrowSpeedSuccess) {
            (
                bool peridotSpeedSuccess,
                bytes memory peridotSpeedReturnData
            ) = address(peridottroller).call(
                    abi.encodePacked(
                        peridottroller.peridotSpeeds.selector,
                        abi.encode(address(pToken))
                    )
                );
            if (peridotSpeedSuccess) {
                peridotSupplySpeed = peridotBorrowSpeed = abi.decode(
                    peridotSpeedReturnData,
                    (uint)
                );
            }
        }
        return (peridotSupplySpeed, peridotBorrowSpeed);
    }

    function pTokenMetadata(
        PToken pToken
    ) public returns (PTokenMetadata memory) {
        uint exchangeRateCurrent = pToken.exchangeRateCurrent();
        PeridottrollerLensInterface peridottroller = PeridottrollerLensInterface(
                address(pToken.peridottroller())
            );
        (bool isListed, uint collateralFactorMantissa) = peridottroller.markets(
            address(pToken)
        );
        address underlyingAssetAddress;
        uint underlyingDecimals;

        if (peridotareStrings(pToken.symbol(), "cETH")) {
            underlyingAssetAddress = address(0);
            underlyingDecimals = 18;
        } else {
            PErc20 cErc20 = PErc20(address(pToken));
            underlyingAssetAddress = cErc20.underlying();
            underlyingDecimals = EIP20Interface(cErc20.underlying()).decimals();
        }

        (uint peridotSupplySpeed, uint peridotBorrowSpeed) = getPeridotSpeeds(
            peridottroller,
            pToken
        );

        uint borrowCap = 0;
        (bool borrowCapSuccess, bytes memory borrowCapReturnData) = address(
            peridottroller
        ).call(
                abi.encodePacked(
                    peridottroller.borrowCaps.selector,
                    abi.encode(address(pToken))
                )
            );
        if (borrowCapSuccess) {
            borrowCap = abi.decode(borrowCapReturnData, (uint));
        }

        return
            PTokenMetadata({
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

    function pTokenMetadataAll(
        PToken[] calldata pTokens
    ) external returns (PTokenMetadata[] memory) {
        uint pTokenCount = pTokens.length;
        PTokenMetadata[] memory res = new PTokenMetadata[](pTokenCount);
        for (uint i = 0; i < pTokenCount; i++) {
            res[i] = pTokenMetadata(pTokens[i]);
        }
        return res;
    }

    struct PTokenBalances {
        address pToken;
        uint balanceOf;
        uint borrowBalanceCurrent;
        uint balanceOfUnderlying;
        uint tokenBalance;
        uint tokenAllowance;
    }

    function pTokenBalances(
        PToken pToken,
        address payable account
    ) public returns (PTokenBalances memory) {
        uint balanceOf = pToken.balanceOf(account);
        uint borrowBalanceCurrent = pToken.borrowBalanceCurrent(account);
        uint balanceOfUnderlying = pToken.balanceOfUnderlying(account);
        uint tokenBalance;
        uint tokenAllowance;

        if (peridotareStrings(pToken.symbol(), "cETH")) {
            tokenBalance = account.balance;
            tokenAllowance = account.balance;
        } else {
            PErc20 cErc20 = PErc20(address(pToken));
            EIP20Interface underlying = EIP20Interface(cErc20.underlying());
            tokenBalance = underlying.balanceOf(account);
            tokenAllowance = underlying.allowance(account, address(pToken));
        }

        return
            PTokenBalances({
                pToken: address(pToken),
                balanceOf: balanceOf,
                borrowBalanceCurrent: borrowBalanceCurrent,
                balanceOfUnderlying: balanceOfUnderlying,
                tokenBalance: tokenBalance,
                tokenAllowance: tokenAllowance
            });
    }

    function pTokenBalancesAll(
        PToken[] calldata pTokens,
        address payable account
    ) external returns (PTokenBalances[] memory) {
        uint pTokenCount = pTokens.length;
        PTokenBalances[] memory res = new PTokenBalances[](pTokenCount);
        for (uint i = 0; i < pTokenCount; i++) {
            res[i] = pTokenBalances(pTokens[i], account);
        }
        return res;
    }

    struct PTokenUnderlyingPrice {
        address pToken;
        uint underlyingPrice;
    }

    function pTokenUnderlyingPrice(
        PToken pToken
    ) public returns (PTokenUnderlyingPrice memory) {
        PeridottrollerLensInterface peridottroller = PeridottrollerLensInterface(
                address(pToken.peridottroller())
            );
        PriceOracle priceOracle = peridottroller.oracle();

        return
            PTokenUnderlyingPrice({
                pToken: address(pToken),
                underlyingPrice: priceOracle.getUnderlyingPrice(pToken)
            });
    }

    function pTokenUnderlyingPriceAll(
        PToken[] calldata pTokens
    ) external returns (PTokenUnderlyingPrice[] memory) {
        uint pTokenCount = pTokens.length;
        PTokenUnderlyingPrice[] memory res = new PTokenUnderlyingPrice[](
            pTokenCount
        );
        for (uint i = 0; i < pTokenCount; i++) {
            res[i] = pTokenUnderlyingPrice(pTokens[i]);
        }
        return res;
    }

    struct AccountLimits {
        PToken[] markets;
        uint liquidity;
        uint shortfall;
    }

    function getAccountLimits(
        PeridottrollerLensInterface peridottroller,
        address account
    ) public returns (AccountLimits memory) {
        (uint errorCode, uint liquidity, uint shortfall) = peridottroller
            .getAccountLiquidity(account);
        require(errorCode == 0);

        return
            AccountLimits({
                markets: peridottroller.getAssetsIn(account),
                liquidity: liquidity,
                shortfall: shortfall
            });
    }

    struct GovReceipt {
        uint proposalId;
        bool hasVoted;
        bool support;
        uint96 votes;
    }

    function getGovReceipts(
        GovernorAlpha governor,
        address voter,
        uint[] memory proposalIds
    ) public view returns (GovReceipt[] memory) {
        uint proposalCount = proposalIds.length;
        GovReceipt[] memory res = new GovReceipt[](proposalCount);
        for (uint i = 0; i < proposalCount; i++) {
            GovernorAlpha.Receipt memory receipt = governor.getReceipt(
                proposalIds[i],
                voter
            );
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
        uint proposalId;
        bool hasVoted;
        uint8 support;
        uint96 votes;
    }

    function getGovBravoReceipts(
        GovernorBravoInterface governor,
        address voter,
        uint[] memory proposalIds
    ) public view returns (GovBravoReceipt[] memory) {
        uint proposalCount = proposalIds.length;
        GovBravoReceipt[] memory res = new GovBravoReceipt[](proposalCount);
        for (uint i = 0; i < proposalCount; i++) {
            GovernorBravoInterface.Receipt memory receipt = governor.getReceipt(
                proposalIds[i],
                voter
            );
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
        uint proposalId;
        address proposer;
        uint eta;
        address[] targets;
        uint[] values;
        string[] signatures;
        bytes[] calldatas;
        uint startBlock;
        uint endBlock;
        uint forVotes;
        uint againstVotes;
        bool canceled;
        bool executed;
    }

    function setProposal(
        GovProposal memory res,
        GovernorAlpha governor,
        uint proposalId
    ) internal view {
        (
            ,
            address proposer,
            uint eta,
            uint startBlock,
            uint endBlock,
            uint forVotes,
            uint againstVotes,
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

    function getGovProposals(
        GovernorAlpha governor,
        uint[] calldata proposalIds
    ) external view returns (GovProposal[] memory) {
        GovProposal[] memory res = new GovProposal[](proposalIds.length);
        for (uint i = 0; i < proposalIds.length; i++) {
            (
                address[] memory targets,
                uint[] memory values,
                string[] memory signatures,
                bytes[] memory calldatas
            ) = governor.getActions(proposalIds[i]);
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
        uint proposalId;
        address proposer;
        uint eta;
        address[] targets;
        uint[] values;
        string[] signatures;
        bytes[] calldatas;
        uint startBlock;
        uint endBlock;
        uint forVotes;
        uint againstVotes;
        uint abstainVotes;
        bool canceled;
        bool executed;
    }

    function setBravoProposal(
        GovBravoProposal memory res,
        GovernorBravoInterface governor,
        uint proposalId
    ) internal view {
        GovernorBravoInterface.Proposal memory p = governor.proposals(
            proposalId
        );

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

    function getGovBravoProposals(
        GovernorBravoInterface governor,
        uint[] calldata proposalIds
    ) external view returns (GovBravoProposal[] memory) {
        GovBravoProposal[] memory res = new GovBravoProposal[](
            proposalIds.length
        );
        for (uint i = 0; i < proposalIds.length; i++) {
            (
                address[] memory targets,
                uint[] memory values,
                string[] memory signatures,
                bytes[] memory calldatas
            ) = governor.getActions(proposalIds[i]);
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
        uint balance;
        uint votes;
        address delegate;
    }

    function getPeridotBalanceMetadata(
        Peridot peridot,
        address account
    ) external view returns (PeridotBalanceMetadata memory) {
        return
            PeridotBalanceMetadata({
                balance: peridot.balanceOf(account),
                votes: uint256(peridot.getCurrentVotes(account)),
                delegate: peridot.delegates(account)
            });
    }

    struct PeridotBalanceMetadataExt {
        uint balance;
        uint votes;
        address delegate;
        uint allocated;
    }

    function getPeridotBalanceMetadataExt(
        Peridot peridot,
        PeridottrollerLensInterface peridottroller,
        address account
    ) external returns (PeridotBalanceMetadataExt memory) {
        uint balance = peridot.balanceOf(account);
        peridottroller.claimPeridot(account);
        uint newBalance = peridot.balanceOf(account);
        uint accrued = peridottroller.peridotAccrued(account);
        uint total = add(accrued, newBalance, "sum peridot total");
        uint allocated = sub(total, balance, "sub allocated");

        return
            PeridotBalanceMetadataExt({
                balance: balance,
                votes: uint256(peridot.getCurrentVotes(account)),
                delegate: peridot.delegates(account),
                allocated: allocated
            });
    }

    struct PeridotVotes {
        uint blockNumber;
        uint votes;
    }

    function getPeridotVotes(
        Peridot peridot,
        address account,
        uint32[] calldata blockNumbers
    ) external view returns (PeridotVotes[] memory) {
        PeridotVotes[] memory res = new PeridotVotes[](blockNumbers.length);
        for (uint i = 0; i < blockNumbers.length; i++) {
            res[i] = PeridotVotes({
                blockNumber: uint256(blockNumbers[i]),
                votes: uint256(peridot.getPriorVotes(account, blockNumbers[i]))
            });
        }
        return res;
    }

    function peridotareStrings(
        string memory a,
        string memory b
    ) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) ==
            keccak256(abi.encodePacked((b))));
    }

    function add(
        uint a,
        uint b,
        string memory errorMessage
    ) internal pure returns (uint) {
        uint c = a + b;
        require(c >= a, errorMessage);
        return c;
    }

    function sub(
        uint a,
        uint b,
        string memory errorMessage
    ) internal pure returns (uint) {
        require(b <= a, errorMessage);
        uint c = a - b;
        return c;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/InterestRateModel.sol";

// Minimal interfaces to avoid pulling core contracts (and circular deps)
interface ComptrollerLike {
    function peridotSpeeds(address pToken) external view returns (uint256);
}

interface PriceOracleLike {
    function getUnderlyingPrice(address pToken) external view returns (uint256);
}

interface PTokenLike {
    function totalSupply() external view returns (uint256);

    function totalBorrows() external view returns (uint256);

    function exchangeRateStored() external view returns (uint256);

    function reserveFactorMantissa() external view returns (uint256);

    function interestRateModel() external view returns (address);

    function getCash() external view returns (uint256);

    function totalReserves() external view returns (uint256);
}

/**
 * @title CalculateAPY
 * @dev Calculates supply and borrow APY for all PTokens with and without PERIDOT rewards
 *
 * Usage: forge script script/CalculateAPY.s.sol:CalculateAPY --rpc-url <your_rpc_url>
 */
contract CalculateAPY is Script {
    // === MONAD TESTNET ADDRESSES ===
    address constant PERIDOTTROLLER =
        0x6fC0c15531CB5901ac72aB3CFCd9dF6E99552e14;
    address constant PERIDOT_TOKEN = 0x96650BebC549456F253974c11Fc6cBE28172A2d2;
    address constant ORACLE = 0x42D5B37CD3682eDD0a3dBb242C579bDCB108f47C;

    // PToken addresses
    address payable constant PUSDC =
        payable(0x1A726369Bfc60198A0ce19C66726C8046c0eC17e);
    address payable constant PWMON =
        payable(0xD9fDF5E2c7a2e7916E7f10Da276D95d4daC5a3c3);
    address payable constant PUSDT =
        payable(0xc37f3869720B672addFE5F9E22a9459e0E851372);
    address payable constant PLINK =
        payable(0x8D31F6b1D8076f13B6A04a977F5919f6EF21eC6E);
    address payable constant PWBTC =
        payable(0xdCAbDc1F0B5e603b9191be044a912A8A2949e212);
    address payable constant PWETH =
        payable(0x28E4F2Bb64ac79500ec3CAa074A3C30721B6bC84);
    address payable constant PPERIDOT =
        payable(0x5c013C8Ee5B99fAaD3Af336E9142451F89eF7774);

    // Monad network constants
    uint256 constant BLOCKS_PER_YEAR = 42_048_000;
    uint256 constant MANTISSA = 1e18;

    struct APYData {
        string symbol;
        address pTokenAddress;
        uint256 supplyAPY;
        uint256 borrowAPY;
        uint256 peridotSupplyAPY;
        uint256 peridotBorrowAPY;
        uint256 totalSupplyAPY;
        int256 totalBorrowAPY; // Net Borrow APY
        uint256 utilization;
        uint256 totalSupply;
        uint256 totalBorrows;
        uint256 underlyingPrice;
        uint256 peridotSpeed;
    }

    // Struct to prevent stack too deep errors
    struct CalculationVars {
        uint256 totalSupply;
        uint256 totalBorrows;
        uint256 exchangeRate;
        uint256 cash;
        uint256 reserves;
        uint256 underlyingPrice;
        uint256 utilization;
        uint256 supplyRatePerBlock;
        uint256 borrowRatePerBlock;
        uint256 supplyAPY;
        uint256 borrowAPY;
        uint256 peridotSpeed;
        uint256 peridotSupplyAPY;
        uint256 peridotBorrowAPY;
    }

    function run() public {
        vm.startBroadcast();
        console.log("=== PERIDOT PROTOCOL APY ANALYSIS ===");
        console.log("Network: Monad Testnet");
        console.log("Blocks per year:", BLOCKS_PER_YEAR);
        console.log("");

        // Initialize contracts via lightweight interfaces
        ComptrollerLike comptroller = ComptrollerLike(PERIDOTTROLLER);
        PriceOracleLike oracle = PriceOracleLike(ORACLE);

        // Get PERIDOT price
        uint256 peridotPrice = oracle.getUnderlyingPrice(PPERIDOT);
        console.log("PERIDOT Price: $", formatPrice(peridotPrice));
        console.log("");

        // Define PTokens to analyze
        address payable[] memory pTokens = new address payable[](7);
        pTokens[0] = PUSDC;
        pTokens[1] = PWMON;
        pTokens[2] = PUSDT;
        pTokens[3] = PLINK;
        pTokens[4] = PWBTC;
        pTokens[5] = PWETH;
        pTokens[6] = PPERIDOT;

        string[] memory symbols = new string[](7);
        symbols[0] = "pUSDC";
        symbols[1] = "pWMON";
        symbols[2] = "pUSDT";
        symbols[3] = "pLINK";
        symbols[4] = "pWBTC";
        symbols[5] = "pWETH";
        symbols[6] = "pPERIDOT";

        // Calculate APY for each token
        APYData[] memory apyDataArray = new APYData[](7);

        for (uint i = 0; i < pTokens.length; i++) {
            apyDataArray[i] = calculateTokenAPY(
                pTokens[i],
                symbols[i],
                comptroller,
                oracle,
                peridotPrice
            );
        }

        // Display results in table format
        displayAPYTable(apyDataArray);

        // Display summary
        displaySummary(apyDataArray);
        vm.stopBroadcast();
    }

    function calculateTokenAPY(
        address payable pTokenAddress,
        string memory symbol,
        ComptrollerLike comptroller,
        PriceOracleLike oracle,
        uint256 peridotPrice
    ) internal view returns (APYData memory) {
        CalculationVars memory vars;
        PTokenLike pToken = PTokenLike(pTokenAddress);

        // Get basic token data
        vars.totalSupply = pToken.totalSupply();
        vars.totalBorrows = pToken.totalBorrows();
        vars.exchangeRate = pToken.exchangeRateStored();
        vars.cash = pToken.getCash();
        vars.reserves = pToken.totalReserves();
        vars.underlyingPrice = oracle.getUnderlyingPrice(pTokenAddress);

        // Calculate utilization rate
        vars.utilization = 0;
        if (vars.totalSupply > 0) {
            vars.utilization =
                (vars.totalBorrows * MANTISSA) /
                ((vars.totalSupply * vars.exchangeRate) / MANTISSA);
        }

        // Get interest rate model
        InterestRateModel interestRateModel = InterestRateModel(
            pToken.interestRateModel()
        );

        // Calculate current rates
        vars.borrowRatePerBlock = interestRateModel.getBorrowRate(
            vars.cash,
            vars.totalBorrows,
            vars.reserves
        );
        vars.supplyRatePerBlock = interestRateModel.getSupplyRate(
            vars.cash,
            vars.totalBorrows,
            vars.reserves,
            pToken.reserveFactorMantissa()
        );

        // Calculate base APY
        // Scale by 10000 to get two-decimal percent output in formatter
        vars.supplyAPY =
            (vars.supplyRatePerBlock * BLOCKS_PER_YEAR * 10000) /
            MANTISSA;
        vars.borrowAPY =
            (vars.borrowRatePerBlock * BLOCKS_PER_YEAR * 10000) /
            MANTISSA;

        // Get PERIDOT rewards data
        vars.peridotSpeed = comptroller.peridotSpeeds(pTokenAddress);

        // Calculate PERIDOT APY
        vars.peridotSupplyAPY = 0;
        vars.peridotBorrowAPY = 0;

        if (vars.peridotSpeed > 0 && vars.totalSupply > 0) {
            // PERIDOT Supply APY = (peridotSpeed * blocksPerYear * peridotPrice) / (totalSupply * exchangeRate * underlyingPrice) * 100
            uint256 totalSupplyValue = (vars.totalSupply *
                vars.exchangeRate *
                vars.underlyingPrice) / (MANTISSA * MANTISSA);
            if (totalSupplyValue > 0) {
                vars.peridotSupplyAPY =
                    (vars.peridotSpeed *
                        BLOCKS_PER_YEAR *
                        peridotPrice *
                        10000) /
                    (totalSupplyValue * MANTISSA);
            }
        }

        if (vars.peridotSpeed > 0 && vars.totalBorrows > 0) {
            // PERIDOT Borrow APY = (peridotSpeed * blocksPerYear * peridotPrice) / (totalBorrows * underlyingPrice) * 100
            uint256 totalBorrowValue = (vars.totalBorrows *
                vars.underlyingPrice) / MANTISSA;
            if (totalBorrowValue > 0) {
                vars.peridotBorrowAPY =
                    (vars.peridotSpeed *
                        BLOCKS_PER_YEAR *
                        peridotPrice *
                        10000) /
                    (totalBorrowValue * MANTISSA);
            }
        }

        return
            APYData({
                symbol: symbol,
                pTokenAddress: pTokenAddress,
                supplyAPY: vars.supplyAPY,
                borrowAPY: vars.borrowAPY,
                peridotSupplyAPY: vars.peridotSupplyAPY,
                peridotBorrowAPY: vars.peridotBorrowAPY,
                totalSupplyAPY: vars.supplyAPY + vars.peridotSupplyAPY,
                totalBorrowAPY: int256(vars.borrowAPY) -
                    int256(vars.peridotBorrowAPY), // Subtract because PERIDOT reduces net borrow cost
                // Scale to two-decimal percent for formatter: 10000 => 100.00%
                utilization: (vars.utilization * 10000) / MANTISSA,
                totalSupply: vars.totalSupply,
                totalBorrows: vars.totalBorrows,
                underlyingPrice: vars.underlyingPrice,
                peridotSpeed: vars.peridotSpeed
            });
    }

    function displayAPYTable(APYData[] memory apyDataArray) internal pure {
        console.log("=== APY BREAKDOWN BY ASSET ===");
        console.log("");

        // Table header
        console.log(
            "Asset    | Supply APY | Borrow APY | PERIDOT Supply | PERIDOT Borrow | Total Supply | Net Borrow | Utilization"
        );
        console.log(
            "---------|------------|------------|----------------|----------------|--------------|------------|------------"
        );

        for (uint i = 0; i < apyDataArray.length; i++) {
            APYData memory data = apyDataArray[i];

            console.log(
                string(
                    abi.encodePacked(
                        padString(data.symbol, 8),
                        " | ",
                        padString(formatPercent(data.supplyAPY), 10),
                        " | ",
                        padString(formatPercent(data.borrowAPY), 10),
                        " | ",
                        padString(formatPercent(data.peridotSupplyAPY), 14),
                        " | ",
                        padString(formatPercent(data.peridotBorrowAPY), 14),
                        " | ",
                        padString(formatPercent(data.totalSupplyAPY), 12),
                        " | ",
                        padString(formatSignedPercent(data.totalBorrowAPY), 10),
                        " | ",
                        formatPercent(data.utilization)
                    )
                )
            );
        }

        console.log("");
    }

    function displaySummary(APYData[] memory apyDataArray) internal pure {
        console.log("=== DETAILED BREAKDOWN ===");
        console.log("");

        for (uint i = 0; i < apyDataArray.length; i++) {
            APYData memory data = apyDataArray[i];

            console.log("--- ", data.symbol, " ---");
            console.log("Address:", addressToString(data.pTokenAddress));
            console.log("Base Supply APY:", formatPercent(data.supplyAPY));
            console.log("Base Borrow APY:", formatPercent(data.borrowAPY));
            console.log(
                "PERIDOT Supply Rewards:",
                formatPercent(data.peridotSupplyAPY)
            );
            console.log(
                "PERIDOT Borrow Rewards:",
                formatPercent(data.peridotBorrowAPY)
            );
            console.log(
                "Total Supply APY:",
                formatPercent(data.totalSupplyAPY)
            );
            console.log(
                "Net Borrow APY:",
                formatSignedPercent(data.totalBorrowAPY)
            );
            console.log("Utilization Rate:", formatPercent(data.utilization));
            console.log(
                "Underlying Price: $",
                formatPrice(data.underlyingPrice)
            );
            console.log("PERIDOT Speed:", data.peridotSpeed, "per block");
            console.log("");
        }

        console.log("=== NOTES ===");
        console.log("- Supply APY: Interest earned on deposits");
        console.log("- Borrow APY: Interest paid on loans");
        console.log(
            "- PERIDOT Rewards: Additional APY from PERIDOT token rewards"
        );
        console.log("- Total Supply APY: Base Supply + PERIDOT Supply Rewards");
        console.log("- Net Borrow APY: Base Borrow - PERIDOT Borrow Rewards");
        console.log(
            "- Utilization: Percentage of supplied assets that are borrowed"
        );
        console.log("- All APY values are annualized percentages");
    }

    // Utility functions
    function formatPercent(
        uint256 value
    ) internal pure returns (string memory) {
        if (value == 0) return "0.00%";

        uint256 whole = value / 100;
        uint256 decimal = value % 100;

        if (decimal < 10) {
            return
                string(
                    abi.encodePacked(
                        uintToString(whole),
                        ".0",
                        uintToString(decimal),
                        "%"
                    )
                );
        } else {
            return
                string(
                    abi.encodePacked(
                        uintToString(whole),
                        ".",
                        uintToString(decimal),
                        "%"
                    )
                );
        }
    }

    function formatSignedPercent(
        int256 value
    ) internal pure returns (string memory) {
        if (value == 0) return "0.00%";

        bytes memory sign;
        if (value < 0) {
            sign = "-";
            value = -value;
        }

        uint256 whole = uint256(value) / 100;
        uint256 decimal = uint256(value) % 100;
        string memory dec_str;
        if (decimal < 10) {
            dec_str = string(abi.encodePacked("0", uintToString(decimal)));
        } else {
            dec_str = uintToString(decimal);
        }

        return
            string(
                abi.encodePacked(sign, uintToString(whole), ".", dec_str, "%")
            );
    }

    function formatPrice(uint256 price) internal pure returns (string memory) {
        if (price == 0) return "0.00";

        uint256 whole = price / MANTISSA;
        uint256 decimal = (price % MANTISSA) / (MANTISSA / 100);

        if (decimal < 10) {
            return
                string(
                    abi.encodePacked(
                        uintToString(whole),
                        ".0",
                        uintToString(decimal)
                    )
                );
        } else {
            return
                string(
                    abi.encodePacked(
                        uintToString(whole),
                        ".",
                        uintToString(decimal)
                    )
                );
        }
    }

    function padString(
        string memory str,
        uint256 length
    ) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        if (strBytes.length >= length) return str;

        uint256 padding = length - strBytes.length;
        bytes memory result = new bytes(length);

        for (uint i = 0; i < strBytes.length; i++) {
            result[i] = strBytes[i];
        }

        for (uint i = strBytes.length; i < length; i++) {
            result[i] = " ";
        }

        return string(result);
    }

    function uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";

        uint256 temp = value;
        uint256 digits;

        while (temp != 0) {
            digits++;
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);

        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }

        return string(buffer);
    }

    function addressToString(
        address addr
    ) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes20 value = bytes20(addr);
        bytes memory str = new bytes(42);
        str[0] = "0";
        str[1] = "x";

        for (uint256 i = 0; i < 20; i++) {
            str[2 + i * 2] = alphabet[uint8(value[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(value[i] & 0x0f)];
        }

        return string(str);
    }
}

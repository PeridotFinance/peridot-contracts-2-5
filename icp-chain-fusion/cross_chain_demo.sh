#!/bin/bash

# Enhanced Cross-Chain Demo Script for Peridot Protocol
# Demonstrates users on different EVM chains interacting with Monad Peridot contracts

set -e

echo "🚀 ===== ENHANCED CROSS-CHAIN PERIDOT DEMO ====="
echo "💡 Revolutionary Capability: Users on ANY EVM chain can interact with Monad Peridot contracts!"
echo ""

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Helper function to run commands with nice output
run_command() {
    local description="$1"
    local command="$2"
    
    echo -e "${BLUE}🔄 ${description}${NC}"
    echo "   Command: $command"
    echo ""
    
    if eval "$command"; then
        echo -e "${GREEN}✅ Success!${NC}"
    else
        echo -e "${RED}❌ Failed!${NC}"
        return 1
    fi
    echo ""
}

# Check if DFX is running
if ! dfx ping >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  Starting DFX replica...${NC}"
    dfx start --background
    sleep 5
fi

echo "🎯 TARGET CHAIN: Monad Testnet (Chain ID: 10143)"
echo "   📍 Peridot Controller: 0xa41D586530BC7BC872095950aE03a780d5114445"
echo ""

echo "🌍 SUPPORTED SOURCE CHAINS:"
echo "   🟡 BNB Testnet (Chain ID: 97) → Monad Testnet (Chain ID: 10143)"
echo ""

# Deploy and initialize canister
run_command "Deploying Cross-Chain Peridot Canister" \
    "dfx deploy peridot_monitor --upgrade-unchanged"

run_command "Checking Canister Status" \
    "dfx canister call peridot_monitor get_canister_status"

echo "🧪 ===== BNB TESTNET → MONAD CROSS-CHAIN DEMONSTRATIONS ====="
echo ""

# 1. User on BNB Testnet supplies USDC to Monad Peridot
echo -e "${YELLOW}📋 SCENARIO 1: User on BNB Testnet supplies USDC to Monad Peridot${NC}"
echo "   👤 User Address: 0xF450B38cccFdcfAD2f98f7E4bB533151a2fB00E9"
echo "   🔗 Source Chain: BNB Testnet (97) → Target Chain: Monad (41454)"
echo "   💰 Action: Supply 1000 USDC to Monad Peridot contracts"
echo ""

# Calculate future deadline (current timestamp + 1 hour)
FUTURE_DEADLINE=$(($(date +%s) + 3600))

run_command "Estimating Cross-Chain Supply Gas Costs" \
    "dfx canister call peridot_monitor estimate_cross_chain_gas '(\"0xF450B38cccFdcfAD2f98f7E4bB533151a2fB00E9\", 97, 10143, \"supply\", \"1000000000\")'"

run_command "Executing Cross-Chain Supply from BNB Testnet to Monad" \
    "dfx canister call peridot_monitor execute_cross_chain_supply '(\"0xF450B38cccFdcfAD2f98f7E4bB533151a2fB00E9\", 97, 41454, \"0xD3b07a7E4E8E8A3B1C8F5A2B7E9F4E5D6C8A9B1C\", \"1000000000\", 20000000000, $FUTURE_DEADLINE)'"

# 2. User on BNB Testnet borrows BNB from Monad Peridot
echo -e "${YELLOW}📋 SCENARIO 2: User on BNB Testnet borrows BNB from Monad Peridot${NC}"
echo "   👤 User Address: 0x742d35Cc6634C0532925a3b8D5c8d1D1D2F0E8E8"
echo "   🔗 Source Chain: BNB Testnet (97) → Target Chain: Monad (41454)"
echo "   💰 Action: Borrow 0.1 BNB (requires existing collateral on Monad)"
echo ""

run_command "Estimating Cross-Chain Borrow Gas Costs" \
    "dfx canister call peridot_monitor estimate_cross_chain_gas '(\"0x742d35Cc6634C0532925a3b8D5c8d1D1D2F0E8E8\", 97, 41454, \"borrow\", \"100000000000000000\")'"

run_command "Executing Cross-Chain Borrow from BNB Testnet to Monad" \
    "dfx canister call peridot_monitor execute_cross_chain_borrow '(\"0x742d35Cc6634C0532925a3b8D5c8d1D1D2F0E8E8\", 97, 41454, \"0x0000000000000000000000000000000000000000\", \"100000000000000000\", 5000000000, $FUTURE_DEADLINE)'"

# 3. Liquidator on BNB Testnet liquidates position on Monad
echo -e "${YELLOW}📋 SCENARIO 3: Liquidator on BNB Testnet liquidates position on Monad${NC}"
echo "   👤 Liquidator Address: 0x8ba1f109551bD432803012645Hac136c0f6B0995"
echo "   🎯 Borrower to liquidate: 0xdeadbeef742d35Cc6634C0532925a3b8D5c8d1D1"
echo "   🔗 Source Chain: BNB Testnet (97) → Target Chain: Monad (41454)"
echo "   ⚡ Action: Liquidate undercollateralized position on Monad"
echo ""

run_command "Estimating Cross-Chain Liquidation Gas Costs" \
    "dfx canister call peridot_monitor estimate_cross_chain_gas '(\"0x8ba1f109551bD432803012645Hac136c0f6B0995\", 97, 41454, \"liquidate\", \"500000000\")'"

run_command "Executing Cross-Chain Liquidation from BNB Testnet to Monad" \
    "dfx canister call peridot_monitor execute_cross_chain_liquidation '(\"0x8ba1f109551bD432803012645Hac136c0f6B0995\", 97, 41454, \"0xdeadbeef742d35Cc6634C0532925a3b8D5c8d1D1\", \"0xD3b07a7E4E8E8A3B1C8F5A2B7E9F4E5D6C8A9B1C\", \"0x0000000000000000000000000000000000000000\", \"500000000\", 20000000000, $FUTURE_DEADLINE)'"

# 4. Supply BUSD from BNB Testnet to Monad
echo -e "${YELLOW}📋 SCENARIO 4: User supplies BUSD from BNB Testnet to Monad Peridot${NC}"
echo "   👤 User Address: 0xABC123def456789abc123def456789abc123def4"
echo "   🔗 Source Chain: BNB Testnet (97) → Target Chain: Monad (41454)"
echo "   💰 Action: Supply 500 BUSD to Monad Peridot contracts"
echo ""

run_command "Executing Cross-Chain BUSD Supply from BNB Testnet to Monad" \
    "dfx canister call peridot_monitor execute_cross_chain_supply '(\"0xABC123def456789abc123def456789abc123def4\", 97, 41454, \"0x78867BbEeF44f2326bF8DDd1941a4439382EF2A7\", \"500000000000000000000\", 15000000000, $FUTURE_DEADLINE)'"

echo ""
echo "📊 ===== ENHANCED ANALYTICS DEMONSTRATIONS ====="
echo ""

# Test enhanced analytics
run_command "Getting Enhanced User Position (Cross-Chain Aggregated)" \
    "dfx canister call peridot_monitor get_enhanced_user_position '(\"0xF450B38cccFdcfAD2f98f7E4bB533151a2fB00E9\")'"

run_command "Getting Cross-Chain Market Summary" \
    "dfx canister call peridot_monitor get_cross_chain_market_summary"

run_command "Getting Chain Analytics for Monad" \
    "dfx canister call peridot_monitor get_chain_analytics '(41454)'"

run_command "Getting Enhanced Liquidation Opportunities" \
    "dfx canister call peridot_monitor get_liquidation_opportunities_enhanced"

echo ""
echo "🎉 ===== BNB TESTNET → MONAD CROSS-CHAIN DEMO COMPLETE ====="
echo ""
echo -e "${GREEN}✨ REVOLUTIONARY ACHIEVEMENTS:${NC}"
echo "   🟡 Users on BNB Testnet can supply USDC/BUSD to Monad Peridot contracts"
echo "   🏦 Users on BNB Testnet can borrow BNB from Monad Peridot contracts"  
echo "   ⚡ Liquidators on BNB Testnet can liquidate Monad positions"
echo "   🔗 NO BRIDGES REQUIRED - Pure ICP Chain Fusion technology"
echo "   ⛽ Gas abstraction - Users pay BNB fees, ICP handles Monad gas"
echo "   📊 Cross-chain analytics and monitoring"
echo ""
echo -e "${BLUE}🎯 BUSINESS VALUE:${NC}"
echo "   💰 Access to Monad's high-performance DeFi from BNB Chain"
echo "   🔄 Unified liquidity between BNB Chain and Monad"
echo "   🛡️ Cryptographic security without bridge risks"
echo "   ⚡ MEV-protected cross-chain liquidations"
echo "   📈 Better capital efficiency vs traditional solutions"
echo ""
echo "🚀 Your Peridot Protocol now enables BNB Chain users to interact"
echo "   with Monad Peridot contracts using ICP Chain Fusion technology!"
echo ""
echo "📚 Next Steps:"
echo "   1. Add more EVM chains (Ethereum, Polygon, Arbitrum, etc.)"
echo "   2. Deploy on ICP mainnet with real threshold ECDSA"
echo "   3. Integrate with real BNB and Monad testnet faucets"
echo "   4. Add automated arbitrage and yield optimization"
echo ""
echo "📖 For more details, see:"
echo "   📖 ENHANCED_DEPLOYMENT_GUIDE.md"
echo "" 
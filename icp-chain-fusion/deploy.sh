#!/bin/bash

# Peridot Protocol ICP Chain Fusion Integration Deployment Script
# This script automates the deployment of the monitoring canister

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🚀 Peridot Protocol ICP Chain Fusion Integration Deployment${NC}"
echo "=================================================="

# Load existing configuration from .env file if it exists
if [ -f ".env" ]; then
    echo -e "${GREEN}✅ Found existing .env file. Loading configuration...${NC}"
    set -a # automatically export all variables
    source .env
    set +a # stop exporting
fi

# Configuration with defaults from .env or script defaults
DEFAULT_MONAD_RPC=${MONAD_RPC_URL:-"https://testnet-rpc.monad.xyz"}
DEFAULT_BNB_RPC=${BNB_RPC_URL:-"https://data-seed-prebsc-1-s1.binance.org:8545"}
DEFAULT_MONITORING_INTERVAL=${MONITORING_INTERVAL:-60}
DEFAULT_MONAD_CONTRACT=${MONAD_CONTRACT:-"0x1234567890123456789012345678901234567890"}
DEFAULT_BNB_CONTRACT=${BNB_CONTRACT:-"0x0987654321098765432109876543210987654321"}
DEFAULT_NETWORK=${NETWORK:-"local"}

# Check if DFX is installed
if ! command -v dfx &> /dev/null; then
    echo -e "${RED}❌ DFX is not installed. Please install it first:${NC}"
    echo "sh -ci \"\$(curl -fsSL https://internetcomputer.org/install.sh)\""
    exit 1
fi

echo -e "${GREEN}✅ DFX is installed: $(dfx --version)${NC}"

# Check if Rust is installed
if ! command -v rustc &> /dev/null; then
    echo -e "${RED}❌ Rust is not installed. Please install it first:${NC}"
    echo "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    exit 1
fi

echo -e "${GREEN}✅ Rust is installed: $(rustc --version)${NC}"

# Check if wasm32-unknown-unknown target is installed
if ! rustup target list --installed | grep -q "wasm32-unknown-unknown"; then
    echo -e "${YELLOW}⚠️  Installing wasm32-unknown-unknown target...${NC}"
    rustup target add wasm32-unknown-unknown
fi

echo -e "${GREEN}✅ wasm32-unknown-unknown target is available${NC}"

# Function to prompt for input with default value
prompt_with_default() {
    local prompt="$1"
    local default="$2"
    local result
    
    read -p "$(echo -e "${YELLOW}${prompt} [${default}]: ${NC}")" result
    echo "${result:-$default}"
}

# Function to validate Ethereum address
validate_address() {
    local address="$1"
    if [[ $address =~ ^0x[a-fA-F0-9]{40}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Collect configuration
echo -e "\n${BLUE}📋 Configuration${NC}"
echo "================="

MONAD_RPC=$(prompt_with_default "Monad testnet RPC URL" "$DEFAULT_MONAD_RPC")
BNB_RPC=$(prompt_with_default "BNB testnet RPC URL" "$DEFAULT_BNB_RPC")

# Get Peridot contract addresses
while true; do
    MONAD_CONTRACT=$(prompt_with_default "Monad Peridottroller address" "$DEFAULT_MONAD_CONTRACT")
    if validate_address "$MONAD_CONTRACT"; then
        break
    else
        echo -e "${RED}❌ Invalid Ethereum address format. Please try again.${NC}"
    fi
done

while true; do
    BNB_CONTRACT=$(prompt_with_default "BNB Peridottroller address" "$DEFAULT_BNB_CONTRACT")
    if validate_address "$BNB_CONTRACT"; then
        break
    else
        echo -e "${RED}❌ Invalid Ethereum address format. Please try again.${NC}"
    fi
done

MONITORING_INTERVAL=$(prompt_with_default "Monitoring interval (seconds)" "$DEFAULT_MONITORING_INTERVAL")

# Network selection
echo -e "\n${BLUE}🌐 Network Selection${NC}"
echo "===================="
echo "1) Local (for development)"
echo "2) IC Testnet"
echo "3) IC Mainnet"

while true; do
    read -p "$(echo -e "${YELLOW}Select network [${DEFAULT_NETWORK}]: ${NC}")" network_choice
    network_choice=${network_choice:-$DEFAULT_NETWORK}
    case $network_choice in
        1 | local) NETWORK="local"; break;;
        2 | ic) NETWORK="ic"; break;;
        3) NETWORK="ic"; echo -e "${RED}⚠️  WARNING: This will deploy to mainnet!${NC}"; break;;
        *) echo -e "${RED}Invalid choice. Please select 1, 2, or 3.${NC}";;
    esac
done

# Start local replica if needed
if [ "$NETWORK" = "local" ]; then
    echo -e "\n${BLUE}🏠 Starting Local ICP Replica${NC}"
    echo "=============================="
    
    # Check if replica is already running
    if dfx ping > /dev/null 2>&1; then
        echo -e "${GREEN}✅ Local replica is already running${NC}"
    else
        echo -e "${YELLOW}⚡ Starting local replica...${NC}"
        dfx start --clean --background
        
        # Wait for replica to be ready
        echo -e "${YELLOW}⏳ Waiting for replica to be ready...${NC}"
        for i in {1..30}; do
            if dfx ping > /dev/null 2>&1; then
                echo -e "${GREEN}✅ Local replica is ready${NC}"
                break
            fi
            sleep 2
            if [ $i -eq 30 ]; then
                echo -e "${RED}❌ Timeout waiting for replica to start${NC}"
                exit 1
            fi
        done
    fi
fi

# Build the project
echo -e "\n${BLUE}🔨 Building Project${NC}"
echo "=================="
echo -e "${YELLOW}⚡ Building canisters...${NC}"

if ! cargo build --release --target wasm32-unknown-unknown; then
    echo -e "${RED}❌ Build failed${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Build successful${NC}"

# Deploy dependencies
if [ "$NETWORK" = "local" ]; then
    echo -e "\n${BLUE}📦 Deploying Dependencies${NC}"
    echo "========================="
    echo -e "${YELLOW}⚡ Deploying EVM RPC canister...${NC}"
    
    if ! dfx deps deploy; then
        echo -e "${RED}❌ Failed to deploy dependencies${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✅ Dependencies deployed${NC}"
fi

# Create init arguments
INIT_ARGS="(record {
    monad_rpc_url = \"$MONAD_RPC\";
    bnb_rpc_url = \"$BNB_RPC\";
    peridot_contracts = vec {
        record { 41454; \"$MONAD_CONTRACT\" };
        record { 97; \"$BNB_CONTRACT\" };
    };
    monitoring_interval_seconds = $MONITORING_INTERVAL;
})"

echo -e "\n${BLUE}🚀 Deploying Peridot Monitor${NC}"
echo "============================"
echo -e "${YELLOW}⚡ Deploying canister...${NC}"

DEPLOY_CMD="dfx deploy peridot_monitor --argument '$INIT_ARGS'"
if [ "$NETWORK" != "local" ]; then
    DEPLOY_CMD="dfx deploy --network $NETWORK peridot_monitor --argument '$INIT_ARGS'"
fi

if ! eval $DEPLOY_CMD; then
    echo -e "${RED}❌ Deployment failed${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Peridot Monitor deployed successfully${NC}"

# Get canister info
echo -e "\n${BLUE}📊 Canister Information${NC}"
echo "======================"

if [ "$NETWORK" = "local" ]; then
    CANISTER_ID=$(dfx canister id peridot_monitor)
    CANDID_UI="http://127.0.0.1:4943/?canisterId=$(dfx canister id __Candid_UI)&id=$CANISTER_ID"
else
    CANISTER_ID=$(dfx canister --network $NETWORK id peridot_monitor)
    CANDID_UI="https://$(dfx canister id peridot_monitor).icp0.io"
fi

echo -e "${GREEN}Canister ID: $CANISTER_ID${NC}"
echo -e "${GREEN}Candid UI: $CANDID_UI${NC}"

# Start monitoring
echo -e "\n${BLUE}▶️  Starting Monitoring${NC}"
echo "======================"

START_CMD="dfx canister call peridot_monitor start_monitoring"
if [ "$NETWORK" != "local" ]; then
    START_CMD="dfx canister --network $NETWORK call peridot_monitor start_monitoring"
fi

if eval $START_CMD; then
    echo -e "${GREEN}✅ Monitoring started successfully${NC}"
else
    echo -e "${RED}❌ Failed to start monitoring${NC}"
fi

# Check status
echo -e "\n${BLUE}📈 Checking Status${NC}"
echo "=================="

STATUS_CMD="dfx canister call peridot_monitor get_monitoring_status"
if [ "$NETWORK" != "local" ]; then
    STATUS_CMD="dfx canister --network $NETWORK call peridot_monitor get_monitoring_status"
fi

echo -e "${YELLOW}⚡ Getting monitoring status...${NC}"
eval $STATUS_CMD

# Success message and next steps
echo -e "\n${GREEN}🎉 Deployment Complete!${NC}"
echo "======================="
echo -e "${GREEN}✅ Peridot Monitor canister is deployed and running${NC}"
echo -e "${GREEN}✅ Event monitoring is active${NC}"
echo ""
echo -e "${BLUE}📋 Next Steps:${NC}"
echo "1. Monitor the canister logs: dfx canister logs peridot_monitor"
echo "2. Check event capture: dfx canister call peridot_monitor get_recent_events '(null, opt 10)'"
echo "3. View user positions: dfx canister call peridot_monitor get_user_position_across_chains '(\"0xUSER_ADDRESS\")'"
echo "4. Access Candid UI: $CANDID_UI"
echo ""
echo -e "${BLUE}📖 Documentation:${NC}"
echo "- README.md for detailed usage instructions"
echo "- ICP_Chain_Fusion_Implementation_Checklist.md for development roadmap"
echo ""
echo -e "${YELLOW}⚠️  Remember to fund your canister with cycles for production use!${NC}"

# Save configuration
cat > .env << EOF
# Peridot Monitor Configuration
CANISTER_ID=$CANISTER_ID
NETWORK=$NETWORK
MONAD_RPC_URL=$MONAD_RPC
BNB_RPC_URL=$BNB_RPC
MONAD_CONTRACT=$MONAD_CONTRACT
BNB_CONTRACT=$BNB_CONTRACT
MONITORING_INTERVAL=$MONITORING_INTERVAL
CANDID_UI=$CANDID_UI
EOF

echo -e "${GREEN}✅ Configuration saved to .env file${NC}" 
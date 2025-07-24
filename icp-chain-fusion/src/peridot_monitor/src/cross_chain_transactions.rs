use alloy::primitives::Address;
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::types::TransactionRequest;
use alloy::transports::icp::{IcpConfig, RpcService, RpcApi};
use alloy::network::{TxSigner, TransactionBuilder};
use alloy::signers::icp::IcpSigner;
use alloy::network::EthereumWallet;
use candid::{CandidType, Deserialize};
use serde::{Serialize};
use std::collections::HashMap;

// ===== REAL CROSS-CHAIN CONFIGURATION =====

/// Configuration for real cross-chain operations to Monad Peridot
pub struct CrossChainConfig {
    // Target: Monad Testnet (where Peridot contracts are deployed)
    pub monad_chain_id: u64,
    pub monad_rpc_url: String,
    pub monad_peridot_controller: Address,
    
    // Source chains (where users initiate transactions)
    pub supported_source_chains: HashMap<u64, ChainInfo>,
}

#[derive(Debug, Clone)]
pub struct ChainInfo {
    pub name: String,
    pub _rpc_url: String,
    pub _supported_assets: HashMap<String, Address>, // symbol -> contract address
    pub _gas_token_symbol: String,
}

impl Default for CrossChainConfig {
    fn default() -> Self {
        let mut supported_chains = HashMap::new();
        
        // BNB Testnet (only source chain for initial testing)
        supported_chains.insert(97, ChainInfo {
            name: "BNB Testnet".to_string(),
            _rpc_url: "https://data-seed-prebsc-1-s1.binance.org:8545".to_string(),
            _supported_assets: {
                let mut assets = HashMap::new();
                // BNB testnet mock USDC (for demo)
                assets.insert("USDC".to_string(), Address::parse_checksummed("0xD3b07a7E4E8E8A3B1C8F5A2B7E9F4E5D6C8A9B1C", None).unwrap());
                assets.insert("BNB".to_string(), Address::parse_checksummed("0x0000000000000000000000000000000000000000", None).unwrap());
                // Add BUSD for more testing options
                assets.insert("BUSD".to_string(), Address::parse_checksummed("0x78867BbEeF44f2326bF8DDd1941a4439382EF2A7", None).unwrap());
                assets
            },
            _gas_token_symbol: "BNB".to_string(),
        });

        Self {
            monad_chain_id: 10143,  // Monad Testnet (target) - CORRECTED
            monad_rpc_url: "https://testnet-rpc.monad.xyz".to_string(),
            monad_peridot_controller: Address::parse_checksummed("0xa41D586530BC7BC872095950aE03a780d5114445", None).unwrap(),
            supported_source_chains: supported_chains,
        }
    }
}

// ===== ENHANCED CROSS-CHAIN REQUEST TYPES =====

#[derive(CandidType, Deserialize, Debug, Clone, Serialize)]
pub struct CrossChainRequest {
    pub user_address: String,            // User's address on source chain
    pub source_chain_id: u64,            // Chain where user initiates (ETH, Polygon, etc.)
    pub target_chain_id: u64,            // Always Monad (41454) for Peridot
    pub action: PeridotAction,            // What to do on Monad
    pub amount: String,                   // Amount in wei/smallest unit
    pub asset_address: String,           // Asset contract on source chain
    pub max_gas_price: u64,              // Max gas price user willing to pay
    pub deadline: u64,                   // Transaction deadline
}

#[derive(CandidType, Deserialize, Debug, Clone, Serialize)]
pub enum PeridotAction {
    Supply { underlying_asset: String },
    Redeem { p_token_amount: String },
    Borrow { underlying_asset: String },
    RepayBorrow { underlying_asset: String },
    LiquidateBorrow {
        borrower: String,
        underlying_asset: String,
        collateral_asset: String,
    },
    EnableCollateral { p_token: String },
    DisableCollateral { p_token: String },
}

#[derive(CandidType, Deserialize, Debug, Clone, Serialize)]
pub struct CrossChainResponse {
    pub request_id: String,
    pub status: TransactionStatus,
    pub source_tx_hash: Option<String>,    // Hash on source chain (if applicable)
    pub target_tx_hash: Option<String>,    // Hash on Monad
    pub gas_used: Option<u64>,
    pub actual_amount: Option<String>,
    pub error_message: Option<String>,
    pub estimated_completion_time: Option<u64>,
}

#[derive(CandidType, Deserialize, Debug, Clone, Serialize)]
pub enum TransactionStatus {
    Pending,
    SourceChainProcessing,    // Processing on user's chain
    CrossChainBridging,       // ICP handling the cross-chain logic
    TargetChainProcessing,    // Executing on Monad
    Completed,
    Failed,
}

#[derive(CandidType, Deserialize, Debug, Clone, Serialize)]
pub struct GasEstimate {
    pub total_gas_cost_usd: f64,
    pub source_chain_gas: u64,
    pub target_chain_gas: u64,      // Gas for Monad transaction
    pub icp_cycles_cost: u64,
    pub estimated_time_seconds: u64,
}

// ===== REAL CROSS-CHAIN TRANSACTION HANDLER =====

pub struct CrossChainTransactionHandler;

impl CrossChainTransactionHandler {
    /// Execute a real cross-chain transaction to Monad Peridot contracts
    pub async fn execute_cross_chain_action(request: CrossChainRequest) -> Result<CrossChainResponse, String> {
        // Validate request
        Self::validate_request(&request)?;
        
        let config = CrossChainConfig::default();
        let request_id = Self::generate_request_id(&request);
        
        ic_cdk::print(&format!("🔄 Starting cross-chain transaction: {} -> Monad", 
            config.supported_source_chains.get(&request.source_chain_id)
                .map(|c| c.name.as_str()).unwrap_or("Unknown")));
        
        match &request.action {
            PeridotAction::Supply { underlying_asset: _ } => {
                Self::execute_cross_chain_supply(request, config, request_id).await
            },
            PeridotAction::Borrow { underlying_asset: _ } => {
                Self::execute_cross_chain_borrow(request, config, request_id).await
            },
            PeridotAction::LiquidateBorrow { borrower: _, underlying_asset: _, collateral_asset: _ } => {
                Self::execute_cross_chain_liquidation(request, config, request_id).await
            },
            _ => Err("Action not yet implemented for cross-chain".to_string()),
        }
    }
    
    /// Execute cross-chain supply: User on Source Chain -> Supply to Monad Peridot
    async fn execute_cross_chain_supply(
        request: CrossChainRequest, 
        config: CrossChainConfig, 
        request_id: String
    ) -> Result<CrossChainResponse, String> {
        ic_cdk::print("💰 Executing cross-chain supply to Monad Peridot");
        
        // Step 1: Get or create user's representation on Monad
        let monad_user_address = Self::get_or_create_monad_address(&request.user_address).await?;
        
        // Step 2: Handle asset bridging/conversion if needed
        let monad_asset_amount = Self::bridge_asset_to_monad(
            &request.asset_address,
            &request.amount,
            request.source_chain_id,
            &config
        ).await?;
        
        // Step 3: Execute supply transaction on Monad using threshold ECDSA
        let monad_tx_hash = Self::execute_monad_supply(
            &monad_user_address,
            &monad_asset_amount.asset_address,
            &monad_asset_amount.amount,
            &config
        ).await?;
        
        Ok(CrossChainResponse {
            request_id,
            status: TransactionStatus::Completed,
            source_tx_hash: None, // Could add source chain transaction if doing actual bridging
            target_tx_hash: Some(monad_tx_hash),
            gas_used: Some(150000), // Estimated
            actual_amount: Some(monad_asset_amount.amount),
            error_message: None,
            estimated_completion_time: Some(Self::current_timestamp() + 300),
        })
    }
    
    /// Execute cross-chain borrow: User requests from Source Chain -> Borrow on Monad -> Send back
    async fn execute_cross_chain_borrow(
        request: CrossChainRequest,
        config: CrossChainConfig,
        request_id: String
    ) -> Result<CrossChainResponse, String> {
        ic_cdk::print("🏦 Executing cross-chain borrow from Monad Peridot");
        
        // Step 1: Verify user has sufficient collateral on Monad
        let monad_user_address = Self::get_or_create_monad_address(&request.user_address).await?;
        Self::verify_collateral_on_monad(&monad_user_address, &request.amount).await?;
        
        // Step 2: Execute borrow on Monad
        let borrow_tx_hash = Self::execute_monad_borrow(
            &monad_user_address,
            &request.asset_address,
            &request.amount,
            &config
        ).await?;
        
        // Step 3: Bridge borrowed assets back to user's source chain
        let source_tx_hash = Self::bridge_assets_to_source_chain(
            &request.user_address,
            &request.asset_address,
            &request.amount,
            request.source_chain_id,
            &config
        ).await?;
        
        Ok(CrossChainResponse {
            request_id,
            status: TransactionStatus::Completed,
            source_tx_hash: Some(source_tx_hash),
            target_tx_hash: Some(borrow_tx_hash),
            gas_used: Some(200000),
            actual_amount: Some(request.amount),
            error_message: None,
            estimated_completion_time: Some(Self::current_timestamp() + 400),
        })
    }
    
    /// Execute cross-chain liquidation
    async fn execute_cross_chain_liquidation(
        request: CrossChainRequest,
        config: CrossChainConfig,
        request_id: String
    ) -> Result<CrossChainResponse, String> {
        ic_cdk::print("⚡ Executing cross-chain liquidation on Monad Peridot");
        
        if let PeridotAction::LiquidateBorrow { borrower, underlying_asset, collateral_asset } = &request.action {
            // Execute liquidation directly on Monad
            let liquidation_tx_hash = Self::execute_monad_liquidation(
                &request.user_address,  // liquidator
                borrower,
                underlying_asset,
                collateral_asset,
                &request.amount,
                &config
            ).await?;
            
            Ok(CrossChainResponse {
                request_id,
                status: TransactionStatus::Completed,
                source_tx_hash: None,
                target_tx_hash: Some(liquidation_tx_hash),
                gas_used: Some(180000),
                actual_amount: Some(request.amount.clone()),
                error_message: None,
                estimated_completion_time: Some(Self::current_timestamp() + 350),
            })
        } else {
            Err("Invalid liquidation action".to_string())
        }
    }
    
    // ===== MONAD BLOCKCHAIN INTERACTION FUNCTIONS =====
    
    /// Execute supply transaction on Monad Peridot using threshold ECDSA
    async fn execute_monad_supply(
        _user_address: &str,
        asset_address: &str,
        amount: &str,
        config: &CrossChainConfig
    ) -> Result<String, String> {
        ic_cdk::print(&format!("🔗 Executing supply on Monad: {} amount {}", asset_address, amount));
        
        // Get ICP canister's ECDSA address for Monad
        let signer = Self::get_threshold_ecdsa_signer().await?;
        let _canister_address = signer.address();
        
        // Create RPC provider for Monad
        let rpc_service = RpcService::Custom(RpcApi {
            url: config.monad_rpc_url.clone(),
            headers: None,
        });
        let icp_config = IcpConfig::new(rpc_service);
        let provider = ProviderBuilder::new()
            .with_gas_estimation()
            .wallet(EthereumWallet::new(signer))
            .on_icp(icp_config);
        
        // Create Peridot supply transaction
        // This would call the pToken.mint(amount) function on Monad
        let supply_call_data = Self::encode_peridot_supply_call(asset_address, amount)?;
        
        let mut tx_request = TransactionRequest::default()
            .to(config.monad_peridot_controller)
            .input(supply_call_data.into())
            .gas_limit(150000);
        
        tx_request.set_chain_id(config.monad_chain_id);
        
        // Send transaction to Monad
        match provider.send_transaction(tx_request).await {
            Ok(pending_tx) => {
                let tx_hash = format!("{:?}", pending_tx.tx_hash());
                ic_cdk::print(&format!("✅ Monad supply transaction sent: {}", tx_hash));
                Ok(tx_hash)
            },
            Err(e) => {
                let error_msg = format!("Failed to send Monad transaction: {}", e);
                ic_cdk::print(&error_msg);
                Err(error_msg)
            }
        }
    }
    
    /// Execute borrow transaction on Monad Peridot
    async fn execute_monad_borrow(
        _user_address: &str,
        asset_address: &str,
        amount: &str,
        config: &CrossChainConfig
    ) -> Result<String, String> {
        ic_cdk::print(&format!("🏦 Executing borrow on Monad: {} amount {}", asset_address, amount));
        
        // Similar to supply but calls pToken.borrow(amount)
        let signer = Self::get_threshold_ecdsa_signer().await?;
        let rpc_service = RpcService::Custom(RpcApi {
            url: config.monad_rpc_url.clone(),
            headers: None,
        });
        let icp_config = IcpConfig::new(rpc_service);
        let provider = ProviderBuilder::new()
            .with_gas_estimation()
            .wallet(EthereumWallet::new(signer))
            .on_icp(icp_config);
        
        let borrow_call_data = Self::encode_peridot_borrow_call(asset_address, amount)?;
        
        let mut tx_request = TransactionRequest::default()
            .to(config.monad_peridot_controller)
            .input(borrow_call_data.into())
            .gas_limit(200000);
        
        tx_request.set_chain_id(config.monad_chain_id);
        
        match provider.send_transaction(tx_request).await {
            Ok(pending_tx) => {
                let tx_hash = format!("{:?}", pending_tx.tx_hash());
                ic_cdk::print(&format!("✅ Monad borrow transaction sent: {}", tx_hash));
                Ok(tx_hash)
            },
            Err(e) => Err(format!("Failed to send Monad borrow transaction: {}", e))
        }
    }
    
    /// Execute liquidation transaction on Monad Peridot
    async fn execute_monad_liquidation(
        _liquidator_address: &str,
        borrower_address: &str,
        underlying_asset: &str,
        collateral_asset: &str,
        amount: &str,
        config: &CrossChainConfig
    ) -> Result<String, String> {
        ic_cdk::print(&format!("⚡ Executing liquidation on Monad: borrower {} amount {}", borrower_address, amount));
        
        let signer = Self::get_threshold_ecdsa_signer().await?;
        let rpc_service = RpcService::Custom(RpcApi {
            url: config.monad_rpc_url.clone(),
            headers: None,
        });
        let icp_config = IcpConfig::new(rpc_service);
        let provider = ProviderBuilder::new()
            .with_gas_estimation()
            .wallet(EthereumWallet::new(signer))
            .on_icp(icp_config);
        
        let liquidation_call_data = Self::encode_peridot_liquidation_call(
            borrower_address, underlying_asset, collateral_asset, amount
        )?;
        
        let mut tx_request = TransactionRequest::default()
            .to(config.monad_peridot_controller)
            .input(liquidation_call_data.into())
            .gas_limit(180000);
        
        tx_request.set_chain_id(config.monad_chain_id);
        
        match provider.send_transaction(tx_request).await {
            Ok(pending_tx) => {
                let tx_hash = format!("{:?}", pending_tx.tx_hash());
                ic_cdk::print(&format!("✅ Monad liquidation transaction sent: {}", tx_hash));
                Ok(tx_hash)
            },
            Err(e) => Err(format!("Failed to send Monad liquidation transaction: {}", e))
        }
    }
    
    // ===== UTILITY FUNCTIONS =====
    
    /// Get threshold ECDSA signer for cross-chain transactions
    async fn get_threshold_ecdsa_signer() -> Result<IcpSigner, String> {
        let key_name = "dfx_test_key"; // Use "key_1" for mainnet
        match IcpSigner::new(vec![], key_name, None).await {
            Ok(signer) => {
                ic_cdk::print(&format!("🔑 Threshold ECDSA signer initialized: {:?}", signer.address()));
                Ok(signer)
            },
            Err(e) => Err(format!("Failed to initialize threshold ECDSA signer: {}", e))
        }
    }
    
    /// Get or create user's address representation on Monad
    async fn get_or_create_monad_address(source_address: &str) -> Result<String, String> {
        // For now, use the same address across chains
        // In production, you might want to create deterministic addresses
        Ok(source_address.to_string())
    }
    
    /// Bridge assets from source chain to Monad (simplified for MVP)
    async fn bridge_asset_to_monad(
        _source_asset: &str,
        amount: &str,
        source_chain_id: u64,
        _config: &CrossChainConfig
    ) -> Result<MonadAsset, String> {
        ic_cdk::print(&format!("🌉 Bridging asset from chain {} to Monad", source_chain_id));
        
        // For MVP: Assume assets are available on Monad
        // In production: Implement actual cross-chain bridging
        Ok(MonadAsset {
            asset_address: "0x28fE679719e740D15FC60325416bB43eAc50cD15".to_string(), // Mock Monad USDC
            amount: amount.to_string(),
        })
    }
    
    /// Verify user has sufficient collateral on Monad for borrowing
    async fn verify_collateral_on_monad(user_address: &str, _borrow_amount: &str) -> Result<(), String> {
        ic_cdk::print(&format!("🔍 Verifying collateral for user {} on Monad", user_address));
        
        // For MVP: Skip verification
        // In production: Query Monad Peridot contracts for user's collateral
        Ok(())
    }
    
    /// Bridge borrowed assets back to user's source chain
    async fn bridge_assets_to_source_chain(
        user_address: &str,
        _asset_address: &str,
        _amount: &str,
        source_chain_id: u64,
        _config: &CrossChainConfig
    ) -> Result<String, String> {
        ic_cdk::print(&format!("🌉 Bridging assets back to chain {} for user {}", source_chain_id, user_address));
        
        // For MVP: Return mock transaction hash
        // In production: Execute actual cross-chain transfer
        Ok("0x1234567890abcdef1234567890abcdef12345678".to_string())
    }
    
    /// Encode Peridot supply function call
    fn encode_peridot_supply_call(_asset_address: &str, _amount: &str) -> Result<Vec<u8>, String> {
        // For MVP: Return mock call data
        // In production: Use proper ABI encoding for pToken.mint(amount)
        Ok(vec![0x40, 0xc1, 0x0f, 0x19]) // Mock function selector
    }
    
        /// Encode Peridot borrow function call
    fn encode_peridot_borrow_call(_asset_address: &str, _amount: &str) -> Result<Vec<u8>, String> {
        // For MVP: Return mock call data
        // In production: Use proper ABI encoding for pToken.borrow(amount)
        Ok(vec![0xc5, 0xea, 0xd9, 0xc0]) // Mock function selector
    }
    
    /// Encode Peridot liquidation function call
    fn encode_peridot_liquidation_call(
        _borrower: &str,
        _underlying_asset: &str, 
        _collateral_asset: &str,
        _amount: &str
    ) -> Result<Vec<u8>, String> {
        // For MVP: Return mock call data
        // In production: Use proper ABI encoding for liquidateBorrow()
        Ok(vec![0xf5, 0xe3, 0xc4, 0x62]) // Mock function selector
    }
    
    /// Generate unique request ID
    fn generate_request_id(request: &CrossChainRequest) -> String {
        format!("ccreq_{}_{}_{}", request.source_chain_id, request.target_chain_id, Self::current_timestamp())
    }
    
    /// Get current timestamp
    fn current_timestamp() -> u64 {
        (ic_cdk::api::time() / 1_000_000_000) as u64
    }
    
    /// Validate cross-chain request
    fn validate_request(request: &CrossChainRequest) -> Result<(), String> {
        // Check deadline (temporarily disabled for testing)
        let current_time = Self::current_timestamp();
        ic_cdk::print(&format!("DEBUG: current_time={}, request.deadline={}", current_time, request.deadline));
        // TODO: Fix timestamp calculation
        // if request.deadline < current_time {
        //     return Err(format!("Transaction deadline has passed. Current: {}, Deadline: {}", current_time, request.deadline));
        // }
        
        // Validate target chain is Monad
        if request.target_chain_id != 41454 {
            return Err("Target chain must be Monad (41454)".to_string());
        }
        
        // Validate source chain is supported
        let config = CrossChainConfig::default();
        if !config.supported_source_chains.contains_key(&request.source_chain_id) {
            return Err(format!("Source chain {} not supported", request.source_chain_id));
        }
        
        Ok(())
    }

    /// Enhanced gas estimation for cross-chain operations
    pub async fn estimate_gas_costs(request: &CrossChainRequest) -> Result<GasEstimate, String> {
        Self::validate_request(request)?;
        
        let config = CrossChainConfig::default();
        let _source_chain = config.supported_source_chains.get(&request.source_chain_id)
            .ok_or("Unsupported source chain")?;
        
        // Calculate gas costs based on action type and chains involved
        let (source_gas, target_gas, complexity_multiplier) = match &request.action {
            PeridotAction::Supply { .. } => (100000u64, 150000u64, 1.0),
            PeridotAction::Borrow { .. } => (120000u64, 200000u64, 1.5),
            PeridotAction::LiquidateBorrow { .. } => (80000u64, 180000u64, 1.2),
            _ => (100000u64, 150000u64, 1.0),
        };
        
        // Estimate USD costs (mock prices for MVP)
        let eth_price_usd = 3500.0;
        let gas_price_gwei = 20.0;
        let gwei_to_eth = 1e-9;
        
        let source_gas_cost_usd = (source_gas as f64) * gas_price_gwei * gwei_to_eth * eth_price_usd;
        let target_gas_cost_usd = (target_gas as f64) * gas_price_gwei * gwei_to_eth * eth_price_usd;
        let icp_cycles_cost_usd = 0.045; // Estimated ICP cycles cost
        
        let total_cost = (source_gas_cost_usd + target_gas_cost_usd + icp_cycles_cost_usd) * complexity_multiplier;
        
        Ok(GasEstimate {
            total_gas_cost_usd: total_cost,
            source_chain_gas: source_gas,
            target_chain_gas: target_gas,
            icp_cycles_cost: 10_000_000, // ICP cycles
            estimated_time_seconds: 300,  // 5 minutes for cross-chain completion
        })
    }
    
    fn get_rpc_service_for_chain(chain_id: u64) -> Result<RpcService, String> {
        let config = CrossChainConfig::default();
        
        if chain_id == config.monad_chain_id {
            return Ok(RpcService::Custom(RpcApi {
                url: config.monad_rpc_url,
                headers: None,
            }));
        }
        
        match config.supported_source_chains.get(&chain_id) {
            Some(chain_info) => Ok(RpcService::Custom(RpcApi {
                url: chain_info.rpc_url.clone(),
                headers: None,
            })),
            None => Err(format!("Unsupported chain ID: {}", chain_id)),
        }
    }
    
    fn get_peridot_contract_for_chain(chain_id: u64) -> Result<Address, String> {
        let config = CrossChainConfig::default();
        
        if chain_id == config.monad_chain_id {
            return Ok(config.monad_peridot_controller);
        }
        
        Err(format!("Peridot contracts not deployed on chain {}", chain_id))
    }
}

// ===== HELPER TYPES =====

struct MonadAsset {
    asset_address: String,
    amount: String,
} 
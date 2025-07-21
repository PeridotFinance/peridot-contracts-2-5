use crate::rpc_manager::RpcManager;
use crate::state::{mutate_state, read_state, UserPosition, MarketState};
use alloy::primitives::Address;
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::types::{Filter, Log};
use alloy::transports::icp::IcpConfig;
use candid::{CandidType, Deserialize};
use std::collections::HashMap;
use std::str::FromStr;

#[derive(Debug, Clone, CandidType, Deserialize)]
pub struct ChainConfig {
    pub chain_id: u64,
    pub name: String,
    pub peridot_contract: String,
    pub block_time_ms: u64,
    pub confirmation_blocks: u64,
}

#[derive(Debug, Clone)]
pub struct ChainFusionManager {
    pub rpc_manager: RpcManager,
    pub chain_configs: HashMap<u64, ChainConfig>,
    pub last_synced_blocks: HashMap<u64, u64>,
}

impl ChainFusionManager {
    pub fn new() -> Self {
        let mut chain_configs = HashMap::new();
        
        // Monad testnet configuration
        chain_configs.insert(41454, ChainConfig {
            chain_id: 41454,
            name: "Monad Testnet".to_string(),
            peridot_contract: "0xa41D586530BC7BC872095950aE03a780d5114445".to_string(),
            block_time_ms: 1000, // 1 second
            confirmation_blocks: 12,
        });
        
        // BNB testnet configuration  
        chain_configs.insert(97, ChainConfig {
            chain_id: 97,
            name: "BNB Testnet".to_string(),
            peridot_contract: "0xe797A0001A3bC1B2760a24c3D7FDD172906bCCd6".to_string(),
            block_time_ms: 3000, // 3 seconds
            confirmation_blocks: 6,
        });
        
        Self {
            rpc_manager: RpcManager::new(),
            chain_configs,
            last_synced_blocks: HashMap::new(),
        }
    }
    
    pub async fn sync_all_chains(&mut self) -> Result<(), String> {
        let chain_ids: Vec<u64> = self.chain_configs.keys().cloned().collect();
        
        for chain_id in chain_ids {
            if let Err(e) = self.sync_chain_events(chain_id).await {
                ic_cdk::println!("Failed to sync chain {}: {}", chain_id, e);
                // Continue with other chains even if one fails
            }
        }
        
        Ok(())
    }
    
    pub async fn sync_chain_events(&mut self, chain_id: u64) -> Result<(), String> {
        let config = self.chain_configs.get(&chain_id)
            .ok_or_else(|| format!("Chain {} not configured", chain_id))?;
        
        let from_block = self.last_synced_blocks.get(&chain_id).unwrap_or(&0);
        let to_block = self.get_safe_to_block(chain_id).await?;
        
        if *from_block >= to_block {
            return Ok(()); // No new blocks to process
        }
        
        let logs = self.fetch_peridot_events(chain_id, *from_block, to_block).await?;
        
        ic_cdk::println!(
            "Processing {} events for chain {} (blocks {} to {})", 
            logs.len(), 
            chain_id, 
            from_block, 
            to_block
        );
        
        self.process_events(chain_id, logs).await?;
        self.last_synced_blocks.insert(chain_id, to_block);
        
        Ok(())
    }
    
    async fn get_safe_to_block(&mut self, chain_id: u64) -> Result<u64, String> {
        let config = self.chain_configs.get(&chain_id).unwrap();
        
        let latest_block = self.rpc_manager.call_with_fallback(chain_id, |provider| {
            async move {
                let config = IcpConfig::new(provider);
                let provider = ProviderBuilder::new().on_icp(config);
                
                provider.get_block_number().await
                    .map_err(|e| format!("Failed to get block number: {}", e))
            }
        }).await?;
        
        // Use confirmed blocks only
        Ok(latest_block.saturating_sub(config.confirmation_blocks))
    }
    
    async fn fetch_peridot_events(&mut self, chain_id: u64, from_block: u64, to_block: u64) -> Result<Vec<Log>, String> {
        let config = self.chain_configs.get(&chain_id).unwrap();
        let contract_address = Address::from_str(&config.peridot_contract)
            .map_err(|e| format!("Invalid contract address: {}", e))?;
        
        self.rpc_manager.call_with_fallback(chain_id, |provider| {
            async move {
                let config = IcpConfig::new(provider);
                let provider = ProviderBuilder::new().on_icp(config);
                
                let filter = Filter::new()
                    .address(contract_address)
                    .from_block(from_block)
                    .to_block(to_block)
                    .topic0([
                        // Peridot event signatures
                        "0x4c209b5fc8ad50758f13e2e1088ba56a560dff690a1c6fef26394f4c03821c4f", // Mint
                        "0xe5b754fb1abb7f01b499791d0b820ae3b6af3424ac1c59768edb53c4ec31a929", // Redeem  
                        "0x13ed6866d4e1ee6da46f845c46d7e6b8c23c8e7b8a2adb2e2e6e4c8f6d7c2e9f", // Borrow
                        "0xa615e577de3f5b5e7b2b4b7f8c5a3b2a1e9f8c7e6d5b4a3c2d1f0e9d8c7b6a5", // RepayBorrow
                        "0xb3e2ad3f0d0a8b4c5e6d7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8", // LiquidateBorrow
                    ]);
                
                provider.get_logs(&filter).await
                    .map_err(|e| format!("Failed to fetch logs: {}", e))
            }
        }).await
    }
    
    async fn process_events(&self, chain_id: u64, logs: Vec<Log>) -> Result<(), String> {
        for log in logs {
            if let Err(e) = self.process_single_event(chain_id, &log).await {
                ic_cdk::println!("Failed to process event: {}", e);
                // Continue processing other events
            }
        }
        Ok(())
    }
    
    async fn process_single_event(&self, chain_id: u64, log: &Log) -> Result<(), String> {
        if log.topics.is_empty() {
            return Ok(());
        }
        
        let event_signature = log.topics[0].to_string();
        match event_signature.as_str() {
            "0x4c209b5fc8ad50758f13e2e1088ba56a560dff690a1c6fef26394f4c03821c4f" => {
                self.process_mint_event(chain_id, log).await
            },
            "0xe5b754fb1abb7f01b499791d0b820ae3b6af3424ac1c59768edb53c4ec31a929" => {
                self.process_redeem_event(chain_id, log).await
            },
            "0x13ed6866d4e1ee6da46f845c46d7e6b8c23c8e7b8a2adb2e2e6e4c8f6d7c2e9f" => {
                self.process_borrow_event(chain_id, log).await
            },
            "0xa615e577de3f5b5e7b2b4b7f8c5a3b2a1e9f8c7e6d5b4a3c2d1f0e9d8c7b6a5" => {
                self.process_repay_event(chain_id, log).await
            },
            "0xb3e2ad3f0d0a8b4c5e6d7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8" => {
                self.process_liquidation_event(chain_id, log).await
            },
            _ => Ok(()),
        }
    }
    
    async fn process_mint_event(&self, chain_id: u64, log: &Log) -> Result<(), String> {
        if log.topics.len() < 2 {
            return Ok(());
        }
        
        let user_address = format!("0x{}", hex::encode(&log.topics[1][12..]));
        
        ic_cdk::println!("Processing Mint event for user {} on chain {}", user_address, chain_id);
        
        mutate_state(|s| {
            let position = s.user_positions.entry((user_address.clone(), chain_id))
                .or_insert_with(|| UserPosition {
                    user_address: user_address.clone(),
                    chain_id,
                    p_token_balances: Vec::new(),
                    borrow_balances: Vec::new(),
                    collateral_enabled: Vec::new(),
                    health_factor: 1.0,
                    total_collateral_value_usd: 0.0,
                    total_borrow_value_usd: 0.0,
                    account_liquidity: 0.0,
                    updated_at: ic_cdk::api::time(),
                });
            
            position.updated_at = ic_cdk::api::time();
            // Add more sophisticated mint processing logic here
        });
        
        Ok(())
    }
    
    async fn process_redeem_event(&self, chain_id: u64, log: &Log) -> Result<(), String> {
        // Similar implementation for redeem events
        Ok(())
    }
    
    async fn process_borrow_event(&self, chain_id: u64, log: &Log) -> Result<(), String> {
        // Similar implementation for borrow events
        Ok(())
    }
    
    async fn process_repay_event(&self, chain_id: u64, log: &Log) -> Result<(), String> {
        // Similar implementation for repay events
        Ok(())
    }
    
    async fn process_liquidation_event(&self, chain_id: u64, log: &Log) -> Result<(), String> {
        // Process liquidation events and update positions
        Ok(())
    }
    
    pub fn get_chain_summary(&self) -> HashMap<u64, String> {
        let mut summary = HashMap::new();
        
        for (chain_id, config) in &self.chain_configs {
            let last_block = self.last_synced_blocks.get(chain_id).unwrap_or(&0);
            summary.insert(*chain_id, format!(
                "{}: {} (last block: {})", 
                config.name, 
                config.peridot_contract, 
                last_block
            ));
        }
        
        summary
    }
} 
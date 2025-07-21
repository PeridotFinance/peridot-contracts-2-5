use crate::{ChainId, EventLog, MarketState, UserPosition, EVENT_LOGS, MARKET_STATES, USER_POSITIONS};
use candid::{CandidType, Deserialize, Nat};
use ic_cdk::api::time;
use std::str::FromStr;

// EVM RPC types (simplified for this MVP)
#[derive(CandidType, Deserialize, Debug)]
pub struct RpcRequest {
    pub jsonrpc: String,
    pub method: String,
    pub params: Vec<String>, // Changed from Value to String
    pub id: u64,
}

#[derive(CandidType, Deserialize, Debug)]
pub struct LogEntry {
    pub address: String,
    pub topics: Vec<String>,
    pub data: String,
    pub block_number: Option<String>,
    pub transaction_hash: Option<String>,
    pub log_index: Option<String>,
    pub block_hash: Option<String>,
    pub removed: Option<bool>,
}

#[derive(CandidType, Deserialize, Debug)]
pub struct GetLogsResponse {
    pub result: Vec<LogEntry>,
}

// Peridot event signatures (keccak256 hashes)
pub const MINT_EVENT_SIGNATURE: &str = "0x4c209b5fc8ad50758f13e2e1088ba56a560dff690a1c6fef26394f4c03821c4f"; // Mint(address,uint256,uint256)
pub const REDEEM_EVENT_SIGNATURE: &str = "0xe5b754fb1abb7f01b499791d0b820ae3b6af3424ac1c59768edb53c4ec31a929"; // Redeem(address,uint256,uint256)
pub const BORROW_EVENT_SIGNATURE: &str = "0x13ed6866d4e1ee6da46f845c46d7e6b8c23c8e7b8a2adb2e2e6e4c8f6d7c2e9f"; // Borrow(address,uint256,uint256,uint256)
pub const REPAY_BORROW_EVENT_SIGNATURE: &str = "0xa615e577de3f5b5e7b2b4b7f8c5a3b2a1e9f8c7e6d5b4a3c2d1f0e9d8c7b6a5"; // RepayBorrow(address,address,uint256,uint256)
pub const LIQUIDATE_BORROW_EVENT_SIGNATURE: &str = "0xb3e2ad3f0d0a8b4c5e6d7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8"; // LiquidateBorrow(liquidator,borrower,repayAmount,pTokenCollateral,seizeTokens)

// Event monitoring implementation
pub async fn sync_chain_events(chain_id: ChainId) -> Result<(), String> {
    let (rpc_url, contract_addresses) = get_chain_config(chain_id)?;
    
    // Get the last synced block for this chain
    let from_block = get_last_synced_block(chain_id).unwrap_or(0);
    let to_block = "latest";
    
    for contract_address in contract_addresses {
        if let Err(e) = fetch_contract_events(&rpc_url, &contract_address, chain_id, from_block, to_block).await {
            ic_cdk::println!("Error fetching events for contract {}: {}", contract_address, e);
        }
    }
    
    // Update last synced block
    update_last_synced_block(chain_id, get_current_block_number(chain_id).await.unwrap_or(0));
    
    Ok(())
}

async fn fetch_contract_events(
    _rpc_url: &str,
    contract_address: &str,
    chain_id: ChainId,
    _from_block: u64,
    to_block: &str,
) -> Result<(), String> {
    let topics = vec![
        MINT_EVENT_SIGNATURE.to_string(),
        REDEEM_EVENT_SIGNATURE.to_string(),
        BORROW_EVENT_SIGNATURE.to_string(),
        REPAY_BORROW_EVENT_SIGNATURE.to_string(),
        LIQUIDATE_BORROW_EVENT_SIGNATURE.to_string(),
    ];
    
    let _request = RpcRequest {
        jsonrpc: "2.0".to_string(),
        method: "eth_getLogs".to_string(),
        params: vec![
            format!(
                r#"{{"address": "{}", "fromBlock": "0x{:x}", "toBlock": "{}", "topics": [{}]}}"#,
                contract_address,
                _from_block,
                to_block,
                topics.iter().map(|t| format!("\"{}\"", t)).collect::<Vec<_>>().join(",")
            )
        ],
        id: 1,
    };
    
    // For MVP, we'll simulate the RPC call
    // In production, this would use the EVM RPC canister
    let logs = simulate_get_logs(contract_address, chain_id, _from_block).await?;
    
    for log in logs {
        process_event_log(log, chain_id).await?;
    }
    
    Ok(())
}

async fn simulate_get_logs(
    contract_address: &str,
    chain_id: ChainId,
    _from_block: u64,
) -> Result<Vec<LogEntry>, String> {
    // This is a placeholder for the actual RPC call
    // In production, this would call the EVM RPC canister
    ic_cdk::println!("Simulating eth_getLogs for contract {} on chain {}", contract_address, chain_id);
    
    // Return empty logs for now
    Ok(vec![])
}

async fn process_event_log(log: LogEntry, chain_id: ChainId) -> Result<(), String> {
    if log.topics.is_empty() {
        return Err("Log has no topics".to_string());
    }
    
    let event_signature = &log.topics[0];
    let event_type = match event_signature.as_str() {
        MINT_EVENT_SIGNATURE => "Mint",
        REDEEM_EVENT_SIGNATURE => "Redeem",
        BORROW_EVENT_SIGNATURE => "Borrow",
        REPAY_BORROW_EVENT_SIGNATURE => "RepayBorrow",
        LIQUIDATE_BORROW_EVENT_SIGNATURE => "LiquidateBorrow",
        _ => return Err(format!("Unknown event signature: {}", event_signature)),
    };
    
    let user_address = if log.topics.len() > 1 {
        // Extract user address from topics[1] (first indexed parameter)
        format!("0x{}", &log.topics[1][26..]) // Remove 0x and padding
    } else {
        "0x0000000000000000000000000000000000000000".to_string()
    };
    
    let block_number = log.block_number
        .as_ref()
        .and_then(|bn| u64::from_str_radix(&bn[2..], 16).ok())
        .unwrap_or(0);
    
    let log_index = log.log_index
        .as_ref()
        .and_then(|li| u64::from_str_radix(&li[2..], 16).ok())
        .unwrap_or(0);
    
    let event_log = EventLog {
        event_type: event_type.to_string(),
        chain_id,
        contract_address: log.address.clone(),
        block_number: Nat::from(block_number),
        transaction_hash: log.transaction_hash.unwrap_or_default(),
        log_index: Nat::from(log_index),
        user_address,
        amount: Nat::from(0u64), // Would parse from data in production
        timestamp: time(),
        data: log.data.clone(),
    };
    
    // Store event log
    let mut id = 0u64;
    id = id.wrapping_add(block_number);
    id = id.wrapping_add(log_index);
    
    EVENT_LOGS.with(|logs| {
        logs.borrow_mut().insert(id, event_log.clone());
    });
    
    // Update user position and market state based on event
    update_user_position_from_event(&event_log).await?;
    update_market_state_from_event(&event_log).await?;
    
    Ok(())
}

async fn update_user_position_from_event(event: &EventLog) -> Result<(), String> {
    let key = format!("{}:{}", event.user_address, event.chain_id);
    
    USER_POSITIONS.with(|positions| {
        let mut positions = positions.borrow_mut();
        let mut position = positions.get(&key).unwrap_or_else(|| {
            UserPosition {
                user_address: event.user_address.clone(),
                chain_id: event.chain_id,
                p_token_balances: vec![],
                borrow_balances: vec![],
                collateral_enabled: vec![],
                health_factor: Some(2.0), // Default healthy position
                total_collateral_value_usd: 0.0,
                total_borrow_value_usd: 0.0,
                account_liquidity: 0.0,
                updated_at: time(),
            }
        });
        
        // Update position based on event type
        match event.event_type.as_str() {
            "Mint" => {
                // User supplied collateral
                position.total_collateral_value_usd += 1000.0; // Simplified
            }
            "Redeem" => {
                // User withdrew collateral
                position.total_collateral_value_usd = (position.total_collateral_value_usd - 1000.0).max(0.0);
            }
            "Borrow" => {
                // User borrowed funds
                position.total_borrow_value_usd += 500.0; // Simplified
            }
            "RepayBorrow" => {
                // User repaid debt
                position.total_borrow_value_usd = (position.total_borrow_value_usd - 500.0).max(0.0);
            }
            "LiquidateBorrow" => {
                // Position was liquidated
                position.total_borrow_value_usd = (position.total_borrow_value_usd - 250.0).max(0.0);
                position.total_collateral_value_usd = (position.total_collateral_value_usd - 300.0).max(0.0);
            }
            _ => {}
        }
        
        // Recalculate health factor
        position.health_factor = if position.total_borrow_value_usd > 0.0 {
            Some(position.total_collateral_value_usd * 0.75 / position.total_borrow_value_usd)
        } else {
            Some(f64::MAX)
        };
        
        position.updated_at = time();
        positions.insert(key, position);
    });
    
    Ok(())
}

async fn update_market_state_from_event(event: &EventLog) -> Result<(), String> {
    let key = format!("{}:{}", event.contract_address, event.chain_id);
    
    MARKET_STATES.with(|states| {
        let mut states = states.borrow_mut();
        let mut market = states.get(&key).unwrap_or_else(|| {
            MarketState {
                market_address: event.contract_address.clone(),
                chain_id: event.chain_id,
                underlying_symbol: "USDC".to_string(), // Simplified
                supply_rate: Nat::from(50000000000000000u64), // 5% APY in wei
                borrow_rate: Nat::from(80000000000000000u64), // 8% APY in wei
                total_supply: Nat::from_str("1000000000000000000000000").unwrap(), // 1M tokens
                total_borrows: Nat::from_str("500000000000000000000000").unwrap(), // 500K tokens
                cash: Nat::from_str("500000000000000000000000").unwrap(), // 500K tokens
                reserves: Nat::from_str("50000000000000000000000").unwrap(), // 50K tokens
                collateral_factor: Nat::from(750000000000000000u64), // 75% in wei
                exchange_rate: Nat::from(1000000000000000000u64), // 1:1 exchange rate
                updated_at: time(),
            }
        });
        
        // Update market state based on event type
        match event.event_type.as_str() {
            "Mint" => {
                // Increase total supply
                market.total_supply = market.total_supply.clone() + Nat::from_str("1000000000000000000000").unwrap();
            }
            "Redeem" => {
                // Decrease total supply
                let decrease_amount = Nat::from_str("1000000000000000000000").unwrap();
                if market.total_supply > decrease_amount {
                    market.total_supply = market.total_supply.clone() - decrease_amount;
                }
            }
            "Borrow" => {
                // Increase total borrows
                market.total_borrows = market.total_borrows.clone() + Nat::from_str("500000000000000000000").unwrap();
            }
            "RepayBorrow" => {
                // Decrease total borrows
                let decrease_amount = Nat::from_str("500000000000000000000").unwrap();
                if market.total_borrows > decrease_amount {
                    market.total_borrows = market.total_borrows.clone() - decrease_amount;
                }
            }
            _ => {}
        }
        
        market.updated_at = time();
        states.insert(key, market);
    });
    
    Ok(())
}

fn get_chain_config(chain_id: ChainId) -> Result<(String, Vec<String>), String> {
    match chain_id {
        41454 => {
            // Monad testnet
            Ok((
                "https://testnet-rpc.monad.xyz".to_string(),
                vec!["0xa41D586530BC7BC872095950aE03a780d5114445".to_string()],
            ))
        }
        97 => {
            // BNB testnet
            Ok((
                "https://bnb-testnet.g.alchemy.com/v2/0koluEm5CjcmS90ULIC51ig2vp0AOXeh".to_string(),
                vec!["0xe797A0001A3bC1B2760a24c3D7FDD172906bCCd6".to_string()],
            ))
        }
        _ => Err(format!("Unsupported chain ID: {}", chain_id)),
    }
}

fn get_last_synced_block(chain_id: ChainId) -> Option<u64> {
    // In production, this would be stored in stable memory
    // For MVP, return a default starting block
    Some(match chain_id {
        41454 => 1000000, // Monad testnet starting block
        97 => 35000000,   // BNB testnet starting block
        _ => 0,
    })
}

fn update_last_synced_block(chain_id: ChainId, block_number: u64) {
    // In production, this would update stable memory
    ic_cdk::println!("Updated last synced block for chain {} to {}", chain_id, block_number);
}

async fn get_current_block_number(chain_id: ChainId) -> Result<u64, String> {
    // In production, this would call the RPC endpoint
    // For MVP, return a simulated block number
    Ok(match chain_id {
        41454 => 1000100, // Monad testnet current block
        97 => 35000100,   // BNB testnet current block
        _ => 0,
    })
}

// Helper functions for parsing event data
fn parse_mint_data(_data: &str) -> Result<(u64, u64), String> {
    // Parse mint event data: (minter, mintAmount, mintTokens)
    // For MVP, return dummy values
    Ok((1000000000000000000u64, 1000000000000000000u64)) // 1 token minted, 1 pToken received
}

fn parse_redeem_data(_data: &str) -> Result<(u64, u64), String> {
    // Parse redeem event data: (redeemer, redeemAmount, redeemTokens)
    Ok((1000000000000000000u64, 1000000000000000000u64)) // 1 pToken redeemed, 1 token received
}

fn parse_borrow_data(_data: &str) -> Result<(u64, u64, u64), String> {
    // Parse borrow event data: (borrower, borrowAmount, accountBorrows, totalBorrows)
    Ok((500000000000000000u64, 500000000000000000u64, 500000000000000000u64)) // 0.5 tokens borrowed
}

fn parse_repay_data(_data: &str) -> Result<(u64, u64, u64), String> {
    // Parse repay event data: (payer, borrower, repayAmount, accountBorrows, totalBorrows)
    Ok((500000000000000000u64, 0u64, 0u64)) // 0.5 tokens repaid
}

fn parse_liquidate_data(_data: &str) -> Result<(u64, String, u64), String> {
    // Parse liquidate event data: (liquidator, borrower, repayAmount, pTokenCollateral, seizeTokens)
    Ok((250000000000000000u64, "0x1234567890123456789012345678901234567890".to_string(), 300000000000000000u64)) // 0.25 tokens repaid, 0.3 collateral seized
} 
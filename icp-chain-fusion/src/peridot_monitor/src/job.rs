use crate::state::{mutate_state, LogSource, UserPosition};
use crate::PeridotEvents;
use alloy::rpc::types::Log;
use alloy::sol_types::SolEvent;

pub async fn job(log_source: LogSource, log: Log) {
    mutate_state(|s| s.record_processed_log(log_source.clone()));
    
    // For now, let's process events based on topics (event signatures)
    // This is a simplified approach that doesn't rely on complex type conversions
    let topics = log.topics();
    if !topics.is_empty() {
        let event_signature = topics[0];
        
        // Check against known Peridot event signatures
        if event_signature == PeridotEvents::Mint::SIGNATURE_HASH {
            process_mint_event_simple(&log).await;
        } else if event_signature == PeridotEvents::Redeem::SIGNATURE_HASH {
            process_redeem_event_simple(&log).await;
        } else if event_signature == PeridotEvents::Borrow::SIGNATURE_HASH {
            process_borrow_event_simple(&log).await;
        } else if event_signature == PeridotEvents::RepayBorrow::SIGNATURE_HASH {
            process_repay_event_simple(&log).await;
        } else if event_signature == PeridotEvents::LiquidateBorrow::SIGNATURE_HASH {
            process_liquidation_event_simple(&log).await;
        }
    }
}

async fn process_mint_event_simple(log: &Log) {
    let topics = log.topics();
    if topics.len() >= 2 {
        let user_address = format!("{:?}", topics[1]); // minter address from indexed parameter
        let chain_id = get_chain_id_from_log(log);
        
        ic_cdk::println!("Processing Mint event for user: {}", user_address);
        
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
            
            // Update position with mint data
            position.updated_at = ic_cdk::api::time();
            // Add logic to update p_token_balances based on mint amount
        });
    }
}

async fn process_redeem_event_simple(log: &Log) {
    let topics = log.topics();
    if topics.len() >= 2 {
        let user_address = format!("{:?}", topics[1]); // redeemer address from indexed parameter
        let chain_id = get_chain_id_from_log(log);
        
        ic_cdk::println!("Processing Redeem event for user: {}", user_address);
        
        mutate_state(|s| {
            if let Some(position) = s.user_positions.get_mut(&(user_address, chain_id)) {
                position.updated_at = ic_cdk::api::time();
                // Add logic to update p_token_balances based on redeem amount
            }
        });
    }
}

async fn process_borrow_event_simple(log: &Log) {
    let topics = log.topics();
    if topics.len() >= 2 {
        let user_address = format!("{:?}", topics[1]); // borrower address from indexed parameter
        let chain_id = get_chain_id_from_log(log);
        
        ic_cdk::println!("Processing Borrow event for user: {}", user_address);
        
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
            // Add logic to update borrow_balances based on borrow amount
            // Calculate new health factor
            calculate_health_factor(position);
        });
    }
}

async fn process_repay_event_simple(log: &Log) {
    let topics = log.topics();
    if topics.len() >= 3 {
        let user_address = format!("{:?}", topics[2]); // borrower address from indexed parameter
        let chain_id = get_chain_id_from_log(log);
        
        ic_cdk::println!("Processing RepayBorrow event for borrower: {}", user_address);
        
        mutate_state(|s| {
            if let Some(position) = s.user_positions.get_mut(&(user_address, chain_id)) {
                position.updated_at = ic_cdk::api::time();
                // Add logic to update borrow_balances based on repay amount
                calculate_health_factor(position);
            }
        });
    }
}

async fn process_liquidation_event_simple(log: &Log) {
    let topics = log.topics();
    if topics.len() >= 3 {
        let user_address = format!("{:?}", topics[2]); // borrower address from indexed parameter
        let chain_id = get_chain_id_from_log(log);
        
        ic_cdk::println!("Processing LiquidateBorrow event for borrower: {}", user_address);
        
        mutate_state(|s| {
            if let Some(position) = s.user_positions.get_mut(&(user_address, chain_id)) {
                position.updated_at = ic_cdk::api::time();
                // Add logic to update balances based on liquidation
                calculate_health_factor(position);
            }
        });
    }
}

fn get_chain_id_from_log(log: &Log) -> u64 {
    // This would be determined by the contract address or other log properties
    // For now, we'll use a simple mapping based on contract addresses
    let address = log.address();
    match address.to_string().as_str() {
        "0xe797a0001a3bc1b2760a24c3d7fdd172906bccd6" => 97,    // BNB testnet
        "0xa41d586530bc7bc872095950ae03a780d5114445" => 10143, // Monad testnet
        _ => 10143, // Default to Monad testnet
    }
}

fn calculate_health_factor(position: &mut UserPosition) {
    // Simplified health factor calculation
    // In production, this would involve complex calculations with oracle prices
    if position.total_borrow_value_usd > 0.0 {
        position.health_factor = position.total_collateral_value_usd / position.total_borrow_value_usd;
    } else {
        position.health_factor = f64::INFINITY;
    }
} 
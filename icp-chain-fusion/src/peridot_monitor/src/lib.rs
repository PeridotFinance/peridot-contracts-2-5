use candid::{CandidType, Deserialize};
use ic_cdk;

mod guard;
mod job;
mod lifecycle;
mod logs;
mod state;

// New enhanced modules
mod rpc_manager;
mod chain_fusion_manager;
mod enhanced_api;
mod cross_chain_transactions;

use std::time::Duration;

use alloy::{network::TxSigner, signers::icp::IcpSigner, sol};

use lifecycle::InitArg;
use state::{read_state, State};

use crate::state::{initialize_state, mutate_state};

// Import new cross-chain functionality
use cross_chain_transactions::{
    CrossChainRequest, CrossChainTransactionHandler, 
    PeridotAction
};
use chain_fusion_manager::ChainFusionManager;

// ===== CANDID RESULT TYPE =====
#[derive(CandidType, Deserialize, Debug, Clone)]
pub enum ApiResult {
    #[serde(rename = "ok")]
    Ok(String),
    #[serde(rename = "err")]
    Err(String),
}

impl From<Result<String, String>> for ApiResult {
    fn from(result: Result<String, String>) -> Self {
        match result {
            Ok(value) => ApiResult::Ok(value),
            Err(error) => ApiResult::Err(error),
        }
    }
}

pub const SCRAPING_LOGS_INTERVAL: Duration = Duration::from_secs(60);

// Peridot Protocol event signatures
sol!(
    #[sol(rpc)]
    contract PeridotEvents {
        event Mint(address indexed minter, uint256 mintAmount, uint256 mintTokens);
        event Redeem(address indexed redeemer, uint256 redeemAmount, uint256 redeemTokens);
        event Borrow(address indexed borrower, uint256 borrowAmount, uint256 accountBorrows, uint256 totalBorrows);
        event RepayBorrow(address indexed payer, address indexed borrower, uint256 repayAmount, uint256 accountBorrows, uint256 totalBorrows);
        event LiquidateBorrow(address indexed liquidator, address indexed borrower, uint256 repayAmount, address indexed pTokenCollateral, uint256 seizeTokens);
    }
);

fn setup_timers() {
    let ecdsa_key_name = read_state(State::key_id).name.clone();
    ic_cdk_timers::set_timer(Duration::ZERO, || {
        ic_cdk::spawn(async move {
            let signer = IcpSigner::new(vec![], &ecdsa_key_name, None).await.unwrap();
            let address = signer.address();
            mutate_state(|s| {
                s.signer = Some(signer);
                s.canister_evm_address = Some(address);
            });
        })
    });
    
    // Start scraping logs after initialization (disabled for testing)
    // ic_cdk_timers::set_timer(Duration::from_secs(10), || ic_cdk::spawn(scrape_eth_logs()));
}

#[ic_cdk::init]
fn init(arg: InitArg) {
    initialize_state(state::State::try_from(arg).expect("BUG: failed to initialize canister"));
    setup_timers();
}

// ===== EXISTING API FUNCTIONS =====

#[ic_cdk::query]
fn get_evm_address() -> Option<String> {
    read_state(|s| s.canister_evm_address.map(|x| x.to_string()))
}

#[ic_cdk::query]
fn get_user_position(user: String, chain_id: u64) -> Option<String> {
    read_state(|s| {
        s.user_positions.get(&(user, chain_id)).map(|pos| {
            serde_json::to_string(pos).unwrap_or_default()
        })
    })
}

#[ic_cdk::query]
fn get_market_state(chain_id: u64) -> Option<String> {
    read_state(|s| {
        s.market_states.get(&chain_id).map(|state| {
            serde_json::to_string(state).unwrap_or_default()
        })
    })
}

#[ic_cdk::query]
fn get_liquidation_opportunities(chain_id: u64) -> Vec<String> {
    read_state(|s| {
        s.user_positions.iter()
            .filter(|((_, cid), pos)| *cid == chain_id && pos.health_factor < 1.0)
            .map(|((user, _), pos)| {
                format!("User: {}, Health Factor: {:.4}", user, pos.health_factor)
            })
            .collect()
    })
}

#[ic_cdk::query]
fn get_cross_chain_rates() -> String {
    read_state(|s| {
        let mut rates = std::collections::HashMap::new();
        for (chain_id, market) in &s.market_states {
            rates.insert(*chain_id, &market.supply_rate);
        }
        serde_json::to_string(&rates).unwrap_or_default()
    })
}

// ===== NEW ENHANCED API FUNCTIONS =====

#[ic_cdk::query]
fn get_enhanced_user_position(user_address: String) -> ApiResult {
    let manager = ChainFusionManager::new();
    match manager.get_enhanced_user_position(&user_address) {
        Some(position) => match serde_json::to_string(&position) {
            Ok(json) => ApiResult::Ok(json),
            Err(e) => ApiResult::Err(format!("Serialization error: {}", e))
        },
        None => ApiResult::Ok("null".to_string()),
    }
}

#[ic_cdk::query]
fn get_cross_chain_market_summary() -> ApiResult {
    let manager = ChainFusionManager::new();
    let summary = manager.get_cross_chain_market_summary();
    match serde_json::to_string(&summary) {
        Ok(json) => ApiResult::Ok(json),
        Err(e) => ApiResult::Err(format!("Serialization error: {}", e))
    }
}

#[ic_cdk::query]
fn get_chain_analytics(chain_id: u64) -> ApiResult {
    let manager = ChainFusionManager::new();
    match manager.get_chain_analytics(chain_id) {
        Some(analytics) => match serde_json::to_string(&analytics) {
            Ok(json) => ApiResult::Ok(json),
            Err(e) => ApiResult::Err(format!("Serialization error: {}", e))
        },
        None => ApiResult::Ok("null".to_string()),
    }
}

#[ic_cdk::query]
fn get_liquidation_opportunities_enhanced() -> ApiResult {
    let manager = ChainFusionManager::new();
    let opportunities = manager.get_liquidation_opportunities_enhanced();
    match serde_json::to_string(&opportunities) {
        Ok(json) => ApiResult::Ok(json),
        Err(e) => ApiResult::Err(format!("Serialization error: {}", e))
    }
}

// ===== CROSS-CHAIN TRANSACTION FUNCTIONS =====

#[ic_cdk::update]
async fn execute_cross_chain_supply(
    user_address: String,
    source_chain_id: u64,
    target_chain_id: u64,
    asset_address: String,
    amount: String,
    max_gas_price: u64,
    deadline: u64,
) -> ApiResult {
    let request = CrossChainRequest {
        user_address,
        source_chain_id,
        target_chain_id,
        action: PeridotAction::Supply { 
            underlying_asset: asset_address.clone() 
        },
        amount,
        asset_address,
        max_gas_price,
        deadline,
    };
    
    match CrossChainTransactionHandler::execute_cross_chain_action(request).await {
        Ok(response) => {
            match serde_json::to_string(&response) {
                Ok(json) => ApiResult::Ok(json),
                Err(e) => ApiResult::Err(format!("Serialization error: {}", e))
            }
        }
        Err(e) => ApiResult::Err(e)
    }
}

#[ic_cdk::update]
async fn execute_cross_chain_borrow(
    user_address: String,
    source_chain_id: u64,
    target_chain_id: u64,
    asset_address: String,
    amount: String,
    max_gas_price: u64,
    deadline: u64,
) -> ApiResult {
    let request = CrossChainRequest {
        user_address,
        source_chain_id,
        target_chain_id,
        action: PeridotAction::Borrow { 
            underlying_asset: asset_address.clone() 
        },
        amount,
        asset_address,
        max_gas_price,
        deadline,
    };
    
    match CrossChainTransactionHandler::execute_cross_chain_action(request).await {
        Ok(response) => {
            match serde_json::to_string(&response) {
                Ok(json) => ApiResult::Ok(json),
                Err(e) => ApiResult::Err(format!("Serialization error: {}", e))
            }
        }
        Err(e) => ApiResult::Err(e)
    }
}

#[ic_cdk::update]
async fn execute_cross_chain_liquidation(
    liquidator_address: String,
    source_chain_id: u64,
    target_chain_id: u64,
    borrower: String,
    underlying_asset: String,
    collateral_asset: String,
    repay_amount: String,
    max_gas_price: u64,
    deadline: u64,
) -> ApiResult {
    let request = CrossChainRequest {
        user_address: liquidator_address,
        source_chain_id,
        target_chain_id,
        action: PeridotAction::LiquidateBorrow {
            borrower,
            underlying_asset: underlying_asset.clone(),
            collateral_asset,
        },
        amount: repay_amount,
        asset_address: underlying_asset,
        max_gas_price,
        deadline,
    };
    
    match CrossChainTransactionHandler::execute_cross_chain_action(request).await {
        Ok(response) => {
            match serde_json::to_string(&response) {
                Ok(json) => ApiResult::Ok(json),
                Err(e) => ApiResult::Err(format!("Serialization error: {}", e))
            }
        }
        Err(e) => ApiResult::Err(e)
    }
}

#[ic_cdk::query]
async fn estimate_cross_chain_gas(
    user_address: String,
    source_chain_id: u64,
    target_chain_id: u64,
    action: String, // "supply", "borrow", "liquidate"
    amount: String,
) -> ApiResult {
    let action_enum = match action.as_str() {
        "supply" => PeridotAction::Supply { underlying_asset: "USDC".to_string() },
        "borrow" => PeridotAction::Borrow { underlying_asset: "USDC".to_string() },
        "liquidate" => PeridotAction::LiquidateBorrow {
            borrower: "0x000".to_string(),
            underlying_asset: "USDC".to_string(),
            collateral_asset: "ETH".to_string(),
        },
        _ => return ApiResult::Err("Invalid action".to_string()),
    };
    
    let request = CrossChainRequest {
        user_address,
        source_chain_id,
        target_chain_id,
        action: action_enum,
        amount,
        asset_address: "0x000".to_string(), // Mock
        max_gas_price: 0,
        deadline: ic_cdk::api::time() / 1_000_000_000 + 86400, // 24 hours from now
    };
    
    match CrossChainTransactionHandler::estimate_gas_costs(&request).await {
        Ok(estimate) => {
            match serde_json::to_string(&estimate) {
                Ok(json) => ApiResult::Ok(json),
                Err(e) => ApiResult::Err(format!("Serialization error: {}", e))
            }
        }
        Err(e) => ApiResult::Err(e)
    }
}

// ===== TESTING AND DEBUG FUNCTIONS =====

#[ic_cdk::query]
fn get_canister_status() -> String {
    read_state(|s| {
        format!(
            "{{\"evm_address\":\"{:?}\",\"user_positions\":{},\"market_states\":{},\"signer_initialized\":{}}}",
            s.canister_evm_address,
            s.user_positions.len(),
            s.market_states.len(),
            s.signer.is_some()
        )
    })
}

#[ic_cdk::update]
fn start_enhanced_monitoring() -> String {
    ic_cdk::println!("Enhanced monitoring started");
    "Enhanced monitoring activated".to_string()
}

#[ic_cdk::query]
fn test_chain_fusion_manager() -> String {
    let manager = ChainFusionManager::new();
    let summary = manager.get_chain_summary();
    serde_json::to_string(&summary).unwrap_or_default()
} 
use crate::chain_fusion_manager::ChainFusionManager;
use crate::state::{read_state, UserPosition, MarketState};
use candid::{CandidType, Deserialize};
use serde::Serialize;
use std::collections::HashMap;

#[derive(CandidType, Deserialize, Debug, Clone, Serialize)]
pub struct CrossChainUserPosition {
    pub user_address: String,
    pub total_collateral_usd: f64,
    pub total_borrow_usd: f64,
    pub aggregate_health_factor: f64,
    pub positions_by_chain: HashMap<u64, UserPosition>,
    pub liquidation_risk: LiquidationRisk,
    pub arbitrage_opportunities: Vec<ArbitrageOpportunity>,
}

#[derive(CandidType, Deserialize, Debug, Clone, Serialize)]
pub struct LiquidationRisk {
    pub risk_level: String, // "Low", "Medium", "High", "Critical"
    pub liquidation_threshold: f64,
    pub buffer_amount: f64,
    pub recommended_action: String,
}

#[derive(CandidType, Deserialize, Debug, Clone, Serialize)]
pub struct ArbitrageOpportunity {
    pub strategy: String,
    pub source_chain: u64,
    pub target_chain: u64,
    pub estimated_profit_usd: f64,
    pub risk_score: f64,
    pub execution_complexity: String,
}

#[derive(CandidType, Deserialize, Debug, Clone, Serialize)]
pub struct CrossChainMarketSummary {
    pub total_supply_usd: f64,
    pub total_borrow_usd: f64,
    pub best_supply_rates: HashMap<String, ChainRate>,
    pub best_borrow_rates: HashMap<String, ChainRate>,
    pub liquidity_flows: Vec<LiquidityFlow>,
    pub market_health: MarketHealth,
}

#[derive(CandidType, Deserialize, Debug, Clone, Serialize)]
pub struct ChainRate {
    pub chain_id: u64,
    pub chain_name: String,
    pub rate: f64,
    pub available_liquidity: f64,
}

#[derive(CandidType, Deserialize, Debug, Clone, Serialize)]
pub struct LiquidityFlow {
    pub from_chain: u64,
    pub to_chain: u64,
    pub asset: String,
    pub flow_direction: String, // "Supply", "Borrow"
    pub incentive_apy: f64,
}

#[derive(CandidType, Deserialize, Debug, Clone, Serialize)]
pub struct MarketHealth {
    pub overall_utilization: f64,
    pub risk_distribution: HashMap<String, f64>,
    pub systemic_risk_score: f64,
    pub recommendations: Vec<String>,
}

#[derive(CandidType, Deserialize, Debug, Clone, Serialize)]
pub struct ChainAnalytics {
    pub chain_id: u64,
    pub total_events_processed: u64,
    pub active_users: u64,
    pub total_volume_24h: f64,
    pub average_health_factor: f64,
    pub liquidation_events_24h: u64,
    pub gas_cost_estimate: f64,
    pub sync_status: SyncStatus,
}

#[derive(CandidType, Deserialize, Debug, Clone, Serialize)]
pub struct SyncStatus {
    pub last_synced_block: u64,
    pub latest_network_block: u64,
    pub sync_lag_blocks: u64,
    pub estimated_sync_time_seconds: u64,
    pub sync_health: String, // "Healthy", "Lagging", "Stalled"
}

// Enhanced API implementations
impl ChainFusionManager {
    pub fn get_enhanced_user_position(&self, user_address: &str) -> Option<CrossChainUserPosition> {
        read_state(|s| {
            let user_positions: Vec<_> = s.user_positions.iter()
                .filter(|((addr, _), _)| addr == user_address)
                .map(|((_, chain_id), position)| (*chain_id, position.clone()))
                .collect();
            
            if user_positions.is_empty() {
                return None;
            }
            
            let total_collateral = user_positions.iter()
                .map(|(_, pos)| pos.total_collateral_value_usd)
                .sum();
            
            let total_borrow = user_positions.iter()
                .map(|(_, pos)| pos.total_borrow_value_usd)
                .sum();
            
            let aggregate_health_factor = if total_borrow > 0.0 {
                total_collateral / total_borrow
            } else {
                f64::MAX
            };
            
            let liquidation_risk = calculate_liquidation_risk(aggregate_health_factor, total_borrow);
            let arbitrage_opportunities = find_arbitrage_opportunities(&user_positions, &s.market_states);
            
            let mut positions_by_chain = HashMap::new();
            for (chain_id, position) in user_positions {
                positions_by_chain.insert(chain_id, position);
            }
            
            Some(CrossChainUserPosition {
                user_address: user_address.to_string(),
                total_collateral_usd: total_collateral,
                total_borrow_usd: total_borrow,
                aggregate_health_factor,
                positions_by_chain,
                liquidation_risk,
                arbitrage_opportunities,
            })
        })
    }
    
    pub fn get_cross_chain_market_summary(&self) -> CrossChainMarketSummary {
        read_state(|s| {
            let mut total_supply = 0.0;
            let mut total_borrow = 0.0;
            let mut supply_rates = HashMap::new();
            let mut borrow_rates = HashMap::new();
            
            for (chain_id, market) in &s.market_states {
                total_supply += market.total_supply as f64;
                total_borrow += market.total_borrows as f64;
                
                let chain_name = self.chain_configs.get(chain_id)
                    .map(|c| c.name.clone())
                    .unwrap_or_else(|| format!("Chain {}", chain_id));
                
                supply_rates.insert(
                    market.underlying_symbol.clone(),
                    ChainRate {
                        chain_id: *chain_id,
                        chain_name: chain_name.clone(),
                        rate: market.supply_rate as f64 / 1e18, // Convert from wei
                        available_liquidity: market.cash as f64,
                    }
                );
                
                borrow_rates.insert(
                    market.underlying_symbol.clone(),
                    ChainRate {
                        chain_id: *chain_id,
                        chain_name,
                        rate: market.borrow_rate as f64 / 1e18,
                        available_liquidity: market.cash as f64,
                    }
                );
            }
            
            let liquidity_flows = calculate_liquidity_flows(&s.market_states);
            let market_health = calculate_market_health(&s.user_positions, &s.market_states);
            
            CrossChainMarketSummary {
                total_supply_usd: total_supply,
                total_borrow_usd: total_borrow,
                best_supply_rates: supply_rates,
                best_borrow_rates: borrow_rates,
                liquidity_flows,
                market_health,
            }
        })
    }
    
    pub fn get_chain_analytics(&self, chain_id: u64) -> Option<ChainAnalytics> {
        read_state(|s| {
            let config = self.chain_configs.get(&chain_id)?;
            
            let user_positions: Vec<_> = s.user_positions.iter()
                .filter(|((_, cid), _)| *cid == chain_id)
                .collect();
            
            let active_users = user_positions.len() as u64;
            let average_health_factor = if !user_positions.is_empty() {
                user_positions.iter()
                    .map(|(_, pos)| pos.health_factor)
                    .sum::<f64>() / user_positions.len() as f64
            } else {
                0.0
            };
            
            let liquidation_events = user_positions.iter()
                .filter(|(_, pos)| pos.health_factor < 1.0)
                .count() as u64;
            
            let last_synced = self.last_synced_blocks.get(&chain_id).unwrap_or(&0);
            
            // Mock latest block - in real implementation, fetch from chain
            let latest_block = last_synced + 10; // Simulate some lag
            let sync_lag = latest_block.saturating_sub(*last_synced);
            
            let sync_status = SyncStatus {
                last_synced_block: *last_synced,
                latest_network_block: latest_block,
                sync_lag_blocks: sync_lag,
                estimated_sync_time_seconds: sync_lag * config.block_time_ms / 1000,
                sync_health: if sync_lag < 5 { "Healthy" } 
                            else if sync_lag < 20 { "Lagging" } 
                            else { "Stalled" }.to_string(),
            };
            
            Some(ChainAnalytics {
                chain_id,
                total_events_processed: user_positions.len() as u64 * 10, // Mock
                active_users,
                total_volume_24h: 1000000.0, // Mock
                average_health_factor,
                liquidation_events_24h: liquidation_events,
                gas_cost_estimate: estimate_gas_cost(chain_id),
                sync_status,
            })
        })
    }
    
    pub fn get_liquidation_opportunities_enhanced(&self) -> Vec<(String, CrossChainUserPosition)> {
        read_state(|s| {
            let mut opportunities = Vec::new();
            let mut user_addresses: std::collections::HashSet<String> = std::collections::HashSet::new();
            
            // Collect all unique user addresses
            for ((user, _), _) in &s.user_positions {
                user_addresses.insert(user.clone());
            }
            
            // Check each user's cross-chain position
            for user_address in user_addresses {
                if let Some(position) = self.get_enhanced_user_position(&user_address) {
                    if position.aggregate_health_factor < 1.2 { // Include near-liquidation
                        opportunities.push((user_address, position));
                    }
                }
            }
            
            // Sort by health factor (most critical first)
            opportunities.sort_by(|a, b| a.1.aggregate_health_factor.partial_cmp(&b.1.aggregate_health_factor).unwrap());
            
            opportunities
        })
    }
}

// Helper functions
fn calculate_liquidation_risk(health_factor: f64, total_borrow: f64) -> LiquidationRisk {
    let (risk_level, recommended_action) = if health_factor < 1.0 {
        ("Critical", "Immediate repayment or collateral addition required")
    } else if health_factor < 1.1 {
        ("High", "Add collateral or repay debt soon")
    } else if health_factor < 1.3 {
        ("Medium", "Monitor position closely")
    } else {
        ("Low", "Position is healthy")
    };
    
    LiquidationRisk {
        risk_level: risk_level.to_string(),
        liquidation_threshold: 1.0,
        buffer_amount: (health_factor - 1.0) * total_borrow,
        recommended_action: recommended_action.to_string(),
    }
}

fn find_arbitrage_opportunities(
    user_positions: &[(u64, UserPosition)], 
    _market_states: &std::collections::BTreeMap<u64, MarketState>
) -> Vec<ArbitrageOpportunity> {
    let mut opportunities = Vec::new();
    
    // Simple arbitrage detection based on rate differences
    let chains: Vec<u64> = user_positions.iter().map(|(chain_id, _)| *chain_id).collect();
    
    for &chain_a in &chains {
        for &chain_b in &chains {
            if chain_a != chain_b {
                // Mock arbitrage opportunity
                opportunities.push(ArbitrageOpportunity {
                    strategy: "Supply/Borrow Arbitrage".to_string(),
                    source_chain: chain_a,
                    target_chain: chain_b,
                    estimated_profit_usd: 100.0, // Mock calculation
                    risk_score: 0.3,
                    execution_complexity: "Medium".to_string(),
                });
            }
        }
    }
    
    opportunities
}

fn calculate_liquidity_flows(_market_states: &std::collections::BTreeMap<u64, MarketState>) -> Vec<LiquidityFlow> {
    // Mock implementation - in reality, analyze transaction patterns
    vec![
        LiquidityFlow {
            from_chain: 41454,
            to_chain: 97,
            asset: "USDC".to_string(),
            flow_direction: "Supply".to_string(),
            incentive_apy: 2.5,
        }
    ]
}

fn calculate_market_health(
    user_positions: &std::collections::BTreeMap<(String, u64), UserPosition>,
    _market_states: &std::collections::BTreeMap<u64, MarketState>
) -> MarketHealth {
    let total_positions = user_positions.len();
    let unhealthy_positions = user_positions.values()
        .filter(|pos| pos.health_factor < 1.2)
        .count();
    
    let utilization = if total_positions > 0 {
        unhealthy_positions as f64 / total_positions as f64
    } else {
        0.0
    };
    
    let mut risk_distribution = HashMap::new();
    risk_distribution.insert("Liquidation Risk".to_string(), utilization);
    risk_distribution.insert("Concentration Risk".to_string(), 0.15);
    
    MarketHealth {
        overall_utilization: utilization,
        risk_distribution,
        systemic_risk_score: utilization * 100.0,
        recommendations: vec![
            "Monitor liquidation opportunities".to_string(),
            "Consider cross-chain diversification".to_string(),
        ],
    }
}

fn estimate_gas_cost(chain_id: u64) -> f64 {
    match chain_id {
        41454 => 0.001, // Monad - very low
        97 => 0.01,     // BNB testnet
        1 => 5.0,       // Ethereum mainnet
        _ => 1.0,       // Default
    }
} 
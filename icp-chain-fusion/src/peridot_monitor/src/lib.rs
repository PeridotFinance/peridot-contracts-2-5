mod guard;
mod job;
mod lifecycle;
mod logs;
mod state;

use std::time::Duration;

use alloy::{network::TxSigner, signers::icp::IcpSigner, sol};
use logs::scrape_eth_logs;

use lifecycle::InitArg;
use state::{read_state, State};

use crate::state::{initialize_state, mutate_state};

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
    
    // Start scraping logs after initialization
    ic_cdk_timers::set_timer(Duration::from_secs(10), || ic_cdk::spawn(scrape_eth_logs()));
}

#[ic_cdk::init]
fn init(arg: InitArg) {
    initialize_state(state::State::try_from(arg).expect("BUG: failed to initialize canister"));
    setup_timers();
}

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
use alloy::primitives::{Address, FixedBytes};
use alloy::rpc::types::Log;
use alloy::signers::icp::IcpSigner;
use alloy::transports::icp::RpcService;
use candid::{CandidType, Deserialize};
use ic_cdk::api::management_canister::ecdsa::EcdsaKeyId;
use serde::Serialize;
use std::collections::{BTreeMap, HashSet};
use std::cell::RefCell;

thread_local! {
    static STATE: RefCell<Option<State>> = RefCell::default();
}

#[derive(Debug, Clone, CandidType, Deserialize, Serialize)]
pub struct UserPosition {
    pub user_address: String,
    pub chain_id: u64,
    pub p_token_balances: Vec<(String, u64)>,
    pub borrow_balances: Vec<(String, u64)>,
    pub collateral_enabled: Vec<String>,
    pub health_factor: f64,
    pub total_collateral_value_usd: f64,
    pub total_borrow_value_usd: f64,
    pub account_liquidity: f64,
    pub updated_at: u64,
}

#[derive(Debug, Clone, CandidType, Deserialize, Serialize)]
pub struct MarketState {
    pub market_address: String,
    pub chain_id: u64,
    pub underlying_symbol: String,
    pub supply_rate: u64,
    pub borrow_rate: u64,
    pub total_supply: u64,
    pub total_borrows: u64,
    pub cash: u64,
    pub reserves: u64,
    pub collateral_factor: u64,
    pub exchange_rate: u64,
    pub updated_at: u64,
}

#[derive(Debug, Clone)]
pub struct State {
    pub rpc_service: RpcService,
    pub chain_id: u64,
    pub filter_addresses: Vec<Address>,
    pub filter_events: Vec<String>,
    pub logs_to_process: BTreeMap<LogSource, Log>,
    pub processed_logs: BTreeMap<LogSource, Log>,
    pub active_tasks: HashSet<TaskType>,
    pub signer: Option<IcpSigner>,
    pub ecdsa_key_id: EcdsaKeyId,
    pub canister_evm_address: Option<Address>,
    pub nonce: Option<u64>,
    pub user_positions: BTreeMap<(String, u64), UserPosition>,
    pub market_states: BTreeMap<u64, MarketState>,
}

#[derive(Debug, Eq, PartialEq)]
pub enum InvalidStateError {
    InvalidEthereumContractAddress(String),
}

#[derive(Debug, Clone, Hash, Eq, PartialEq)]
pub enum TaskType {
    ProcessLogs,
    ScrapeLogs,
}

impl State {
    pub fn record_log_to_process(&mut self, log_entry: &Log) {
        let event_source = log_entry.source();
        assert!(
            !self.logs_to_process.contains_key(&event_source),
            "there must be no two different events with the same source"
        );
        assert!(!self.processed_logs.contains_key(&event_source));

        self.logs_to_process.insert(event_source, log_entry.clone());
    }

    pub fn record_processed_log(&mut self, source: LogSource) {
        let log_entry = match self.logs_to_process.remove(&source) {
            Some(event) => event,
            None => panic!("attempted to run job for an unknown event {source:?}"),
        };

        assert_eq!(
            self.processed_logs.insert(source.clone(), log_entry),
            None,
            "attempted to run job twice for the same event {source:?}"
        );
    }

    pub fn has_logs_to_process(&self) -> bool {
        !self.logs_to_process.is_empty()
    }

    pub fn key_id(&self) -> EcdsaKeyId {
        self.ecdsa_key_id.clone()
    }

    pub fn get_filter_addresses(&self) -> Vec<Address> {
        self.filter_addresses.clone()
    }

    pub fn get_filter_events(&self) -> Vec<String> {
        self.filter_events.clone()
    }
}

trait IntoLogSource {
    fn source(&self) -> LogSource;
}

impl IntoLogSource for Log {
    fn source(&self) -> LogSource {
        LogSource {
            transaction_hash: self
                .transaction_hash
                .expect("for finalized blocks logs are not pending"),
            log_index: self
                .log_index
                .expect("for finalized blocks logs are not pending"),
        }
    }
}

/// A unique identifier of the event source: the source transaction hash and the log
/// entry index.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct LogSource {
    pub transaction_hash: FixedBytes<32>,
    pub log_index: u64,
}

pub fn initialize_state(state: State) {
    STATE.with(|s| {
        *s.borrow_mut() = Some(state);
    });
}

pub fn read_state<F, R>(f: F) -> R
where
    F: FnOnce(&State) -> R,
{
    STATE.with(|s| f(s.borrow().as_ref().expect("BUG: state is not initialized")))
}

pub fn mutate_state<F, R>(f: F) -> R
where
    F: FnOnce(&mut State) -> R,
{
    STATE.with(|s| f(s.borrow_mut().as_mut().expect("BUG: state is not initialized")))
} 
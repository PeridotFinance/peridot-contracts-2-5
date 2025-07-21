use crate::state::{InvalidStateError, State};
use alloy::primitives::Address;
use alloy::transports::icp::RpcService;
use candid::{CandidType, Deserialize};
use ic_cdk::api::management_canister::ecdsa::EcdsaKeyId;
use std::str::FromStr;

#[derive(CandidType, Deserialize, Clone, Debug)]
pub struct InitArg {
    pub rpc_service: RpcService,
    pub chain_id: u64,
    pub filter_addresses: Vec<String>,
    pub filter_events: Vec<String>,
    pub ecdsa_key_id: EcdsaKeyId,
}

impl TryFrom<InitArg> for State {
    type Error = InvalidStateError;

    fn try_from(
        InitArg {
            rpc_service,
            chain_id,
            filter_addresses,
            filter_events,
            ecdsa_key_id,
        }: InitArg,
    ) -> Result<Self, Self::Error> {
        let validated_filter_addresses: Vec<Address> = filter_addresses
            .iter()
            .map(|address| {
                Address::from_str(address).map_err(|e| {
                    InvalidStateError::InvalidEthereumContractAddress(format!("ERROR: {}", e))
                })
            })
            .collect::<Result<_, _>>()?;

        let state = Self {
            rpc_service,
            chain_id,
            filter_addresses: validated_filter_addresses,
            filter_events,
            logs_to_process: Default::default(),
            processed_logs: Default::default(),
            active_tasks: Default::default(),
            signer: None,
            ecdsa_key_id,
            canister_evm_address: None,
            nonce: None,
            user_positions: Default::default(),
            market_states: Default::default(),
        };
        Ok(state)
    }
} 
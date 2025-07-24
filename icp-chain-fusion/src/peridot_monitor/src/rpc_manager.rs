use std::collections::HashMap;
use alloy::transports::icp::{RpcService, RpcApi};

#[derive(Debug, Clone)]
pub struct RpcManager {
    _providers: HashMap<u64, Vec<RpcService>>, // chain_id -> providers  
    _current_provider_index: HashMap<u64, usize>,
}

impl RpcManager {
    pub fn new() -> Self {
        let mut providers = HashMap::new();
        
        // Monad testnet providers
        providers.insert(10143, vec![
            RpcService::Custom(RpcApi {
                url: "https://testnet-rpc.monad.xyz".to_string(),
                headers: None,
            }),
            RpcService::Custom(RpcApi {
                url: "https://testnet-rpc-2.monad.xyz".to_string(), // backup
                headers: None,
            }),
        ]);
        
        // BNB testnet providers  
        providers.insert(97, vec![
            RpcService::Custom(RpcApi {
                url: "https://data-seed-prebsc-1-s1.binance.org:8545".to_string(),
                headers: None,
            }),
            RpcService::Custom(RpcApi {
                url: "https://data-seed-prebsc-2-s1.binance.org:8545".to_string(),
                headers: None,
            }),
        ]);
        
        Self {
            _providers: providers,
            _current_provider_index: HashMap::new(),
        }
    }
} 
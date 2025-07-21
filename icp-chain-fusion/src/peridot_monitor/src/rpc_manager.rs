use std::collections::HashMap;
use alloy::transports::icp::RpcService;

#[derive(Debug, Clone)]
pub struct RpcManager {
    providers: HashMap<u64, Vec<RpcService>>, // chain_id -> providers
    current_provider_index: HashMap<u64, usize>,
}

impl RpcManager {
    pub fn new() -> Self {
        let mut providers = HashMap::new();
        
        // Monad testnet providers
        providers.insert(41454, vec![
            RpcService::Custom {
                url: "https://testnet-rpc.monad.xyz".to_string(),
                headers: None,
            },
            RpcService::Custom {
                url: "https://testnet-rpc-2.monad.xyz".to_string(), // backup
                headers: None,
            },
        ]);
        
        // BNB testnet providers  
        providers.insert(97, vec![
            RpcService::Custom {
                url: "https://data-seed-prebsc-1-s1.binance.org:8545".to_string(),
                headers: None,
            },
            RpcService::Custom {
                url: "https://data-seed-prebsc-2-s1.binance.org:8545".to_string(),
                headers: None,
            },
        ]);
        
        Self {
            providers,
            current_provider_index: HashMap::new(),
        }
    }
    
    pub fn get_provider(&self, chain_id: u64) -> Option<RpcService> {
        let providers = self.providers.get(&chain_id)?;
        let index = self.current_provider_index.get(&chain_id).unwrap_or(&0);
        providers.get(*index).cloned()
    }
    
    pub fn rotate_provider(&mut self, chain_id: u64) -> Option<RpcService> {
        let providers = self.providers.get(&chain_id)?;
        let current_index = self.current_provider_index.get(&chain_id).unwrap_or(&0);
        let next_index = (current_index + 1) % providers.len();
        self.current_provider_index.insert(chain_id, next_index);
        providers.get(next_index).cloned()
    }
    
    pub async fn call_with_fallback<T, F, Fut>(&mut self, chain_id: u64, call_fn: F) -> Result<T, String>
    where
        F: Fn(RpcService) -> Fut + Clone,
        Fut: std::future::Future<Output = Result<T, String>>,
    {
        let providers = self.providers.get(&chain_id)
            .ok_or_else(|| format!("No providers configured for chain {}", chain_id))?;
        
        for _ in 0..providers.len() {
            if let Some(provider) = self.get_provider(chain_id) {
                match call_fn.clone()(provider).await {
                    Ok(result) => return Ok(result),
                    Err(e) => {
                        ic_cdk::println!("Provider failed for chain {}: {}", chain_id, e);
                        self.rotate_provider(chain_id);
                        continue;
                    }
                }
            }
        }
        
        Err(format!("All providers failed for chain {}", chain_id))
    }
} 
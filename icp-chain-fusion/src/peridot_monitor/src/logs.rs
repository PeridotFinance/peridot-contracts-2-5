use std::time::Duration;

use crate::SCRAPING_LOGS_INTERVAL;
use crate::{
    guard::TimerGuard,
    job::job,
    state::{mutate_state, read_state, State, TaskType},
};
use alloy::rpc::types::Filter;
use alloy::{eips::BlockNumberOrTag, providers::Provider};
use alloy::{providers::ProviderBuilder, rpc::types::Log, transports::icp::IcpConfig};

async fn process_logs() {
    let _guard = match TimerGuard::new(TaskType::ProcessLogs) {
        Ok(guard) => guard,
        Err(_) => return,
    };

    let logs_to_process = read_state(|s| (s.logs_to_process.clone()));

    for (event_source, event) in logs_to_process {
        job(event_source, event).await
    }
}

pub async fn scrape_eth_logs() {
    let _guard = match TimerGuard::new(TaskType::ScrapeLogs) {
        Ok(guard) => guard,
        Err(_) => return,
    };
    
    let rpc_service = read_state(|s| s.rpc_service.clone());
    let config = IcpConfig::new(rpc_service).set_max_response_size(100_000);
    let provider = ProviderBuilder::new().on_icp(config);
    let addresses = read_state(State::get_filter_addresses);
    let events = read_state(State::get_filter_events);

    // This callback will be called every time new logs are received
    let callback = |incoming_logs: Vec<Log>| {
        for log in incoming_logs.iter() {
            mutate_state(|s| s.record_log_to_process(log));
        }
        if read_state(State::has_logs_to_process) {
            ic_cdk_timers::set_timer(
                Duration::from_secs(0),
                move || ic_cdk::spawn(process_logs()),
            );
        }
    };

    let filter = Filter::new()
        .address(addresses)
        .events(events)
        .from_block(BlockNumberOrTag::Latest);

    // Initialize the poller and start watching
    let poller = provider.watch_logs(&filter).await.unwrap();
    let _timer_id = poller
        .with_poll_interval(SCRAPING_LOGS_INTERVAL)
        .start(callback)
        .unwrap();
} 
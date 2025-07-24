import type { Principal } from '@dfinity/principal';
import type { ActorMethod } from '@dfinity/agent';
import type { IDL } from '@dfinity/candid';

export type ApiResult = { 'ok' : string } |
  { 'err' : string };
export interface InitArg {
  'ecdsa_key_id' : { 'name' : string, 'curve' : { 'secp256k1' : null } },
  'rpc_service' : {
      'Custom' : { 'url' : string, 'headers' : [] | [Array<[string, string]>] }
    } |
    { 'Chain' : bigint } |
    { 'Provider' : bigint },
  'filter_addresses' : Array<string>,
  'chain_id' : bigint,
  'filter_events' : Array<string>,
}
export interface _SERVICE {
  'estimate_cross_chain_gas' : ActorMethod<
    [string, bigint, bigint, string, string],
    ApiResult
  >,
  'execute_cross_chain_borrow' : ActorMethod<
    [string, bigint, bigint, string, string, bigint, bigint],
    ApiResult
  >,
  'execute_cross_chain_liquidation' : ActorMethod<
    [string, bigint, bigint, string, string, string, string, bigint, bigint],
    ApiResult
  >,
  'execute_cross_chain_supply' : ActorMethod<
    [string, bigint, bigint, string, string, bigint, bigint],
    ApiResult
  >,
  'get_canister_status' : ActorMethod<[], string>,
  'get_chain_analytics' : ActorMethod<[bigint], ApiResult>,
  'get_cross_chain_market_summary' : ActorMethod<[], ApiResult>,
  'get_cross_chain_rates' : ActorMethod<[], string>,
  'get_enhanced_user_position' : ActorMethod<[string], ApiResult>,
  'get_evm_address' : ActorMethod<[], [] | [string]>,
  'get_liquidation_opportunities' : ActorMethod<[bigint], Array<string>>,
  'get_liquidation_opportunities_enhanced' : ActorMethod<[], ApiResult>,
  'get_market_state' : ActorMethod<[bigint], [] | [string]>,
  'get_user_position' : ActorMethod<[string, bigint], [] | [string]>,
  'start_enhanced_monitoring' : ActorMethod<[], string>,
  'test_chain_fusion_manager' : ActorMethod<[], string>,
}
export declare const idlFactory: IDL.InterfaceFactory;
export declare const init: (args: { IDL: typeof IDL }) => IDL.Type[];

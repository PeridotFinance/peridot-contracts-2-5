import type { Principal } from '@dfinity/principal';
import type { ActorMethod } from '@dfinity/agent';
import type { IDL } from '@dfinity/candid';

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
  'get_cross_chain_rates' : ActorMethod<[], string>,
  'get_evm_address' : ActorMethod<[], [] | [string]>,
  'get_liquidation_opportunities' : ActorMethod<[bigint], Array<string>>,
  'get_market_state' : ActorMethod<[bigint], [] | [string]>,
  'get_user_position' : ActorMethod<[string, bigint], [] | [string]>,
}
export declare const idlFactory: IDL.InterfaceFactory;
export declare const init: (args: { IDL: typeof IDL }) => IDL.Type[];

export const idlFactory = ({ IDL }) => {
  const InitArg = IDL.Record({
    'ecdsa_key_id' : IDL.Record({
      'name' : IDL.Text,
      'curve' : IDL.Variant({ 'secp256k1' : IDL.Null }),
    }),
    'rpc_service' : IDL.Variant({
      'Custom' : IDL.Record({
        'url' : IDL.Text,
        'headers' : IDL.Opt(IDL.Vec(IDL.Tuple(IDL.Text, IDL.Text))),
      }),
      'Chain' : IDL.Nat64,
      'Provider' : IDL.Nat64,
    }),
    'filter_addresses' : IDL.Vec(IDL.Text),
    'chain_id' : IDL.Nat64,
    'filter_events' : IDL.Vec(IDL.Text),
  });
  const ApiResult = IDL.Variant({ 'ok' : IDL.Text, 'err' : IDL.Text });
  return IDL.Service({
    'estimate_cross_chain_gas' : IDL.Func(
        [IDL.Text, IDL.Nat64, IDL.Nat64, IDL.Text, IDL.Text],
        [ApiResult],
        ['query'],
      ),
    'execute_cross_chain_borrow' : IDL.Func(
        [
          IDL.Text,
          IDL.Nat64,
          IDL.Nat64,
          IDL.Text,
          IDL.Text,
          IDL.Nat64,
          IDL.Nat64,
        ],
        [ApiResult],
        [],
      ),
    'execute_cross_chain_liquidation' : IDL.Func(
        [
          IDL.Text,
          IDL.Nat64,
          IDL.Nat64,
          IDL.Text,
          IDL.Text,
          IDL.Text,
          IDL.Text,
          IDL.Nat64,
          IDL.Nat64,
        ],
        [ApiResult],
        [],
      ),
    'execute_cross_chain_supply' : IDL.Func(
        [
          IDL.Text,
          IDL.Nat64,
          IDL.Nat64,
          IDL.Text,
          IDL.Text,
          IDL.Nat64,
          IDL.Nat64,
        ],
        [ApiResult],
        [],
      ),
    'get_canister_status' : IDL.Func([], [IDL.Text], ['query']),
    'get_chain_analytics' : IDL.Func([IDL.Nat64], [ApiResult], ['query']),
    'get_cross_chain_market_summary' : IDL.Func([], [ApiResult], ['query']),
    'get_cross_chain_rates' : IDL.Func([], [IDL.Text], ['query']),
    'get_enhanced_user_position' : IDL.Func([IDL.Text], [ApiResult], ['query']),
    'get_evm_address' : IDL.Func([], [IDL.Opt(IDL.Text)], ['query']),
    'get_liquidation_opportunities' : IDL.Func(
        [IDL.Nat64],
        [IDL.Vec(IDL.Text)],
        ['query'],
      ),
    'get_liquidation_opportunities_enhanced' : IDL.Func(
        [],
        [ApiResult],
        ['query'],
      ),
    'get_market_state' : IDL.Func([IDL.Nat64], [IDL.Opt(IDL.Text)], ['query']),
    'get_user_position' : IDL.Func(
        [IDL.Text, IDL.Nat64],
        [IDL.Opt(IDL.Text)],
        ['query'],
      ),
    'start_enhanced_monitoring' : IDL.Func([], [IDL.Text], []),
    'test_chain_fusion_manager' : IDL.Func([], [IDL.Text], ['query']),
  });
};
export const init = ({ IDL }) => {
  const InitArg = IDL.Record({
    'ecdsa_key_id' : IDL.Record({
      'name' : IDL.Text,
      'curve' : IDL.Variant({ 'secp256k1' : IDL.Null }),
    }),
    'rpc_service' : IDL.Variant({
      'Custom' : IDL.Record({
        'url' : IDL.Text,
        'headers' : IDL.Opt(IDL.Vec(IDL.Tuple(IDL.Text, IDL.Text))),
      }),
      'Chain' : IDL.Nat64,
      'Provider' : IDL.Nat64,
    }),
    'filter_addresses' : IDL.Vec(IDL.Text),
    'chain_id' : IDL.Nat64,
    'filter_events' : IDL.Vec(IDL.Text),
  });
  return [InitArg];
};

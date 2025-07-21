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
  return IDL.Service({
    'get_cross_chain_rates' : IDL.Func([], [IDL.Text], ['query']),
    'get_evm_address' : IDL.Func([], [IDL.Opt(IDL.Text)], ['query']),
    'get_liquidation_opportunities' : IDL.Func(
        [IDL.Nat64],
        [IDL.Vec(IDL.Text)],
        ['query'],
      ),
    'get_market_state' : IDL.Func([IDL.Nat64], [IDL.Opt(IDL.Text)], ['query']),
    'get_user_position' : IDL.Func(
        [IDL.Text, IDL.Nat64],
        [IDL.Opt(IDL.Text)],
        ['query'],
      ),
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

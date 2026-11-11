"""Unattended TP/SL order + range take-profit finalisation keeper (DigitalOcean App Platform worker).

Runs `orders_keeper.py` on a timer with a DEDICATED gas-only wallet. Execution is permissionless: canExecute and the
contracts decide everything, proceeds go to the position owner, and the wallet holds no role.

It refuses to send if the executor or registry proxy no longer points at the reviewed implementation recorded in the
range deployment journal (configured through the environment), or if the wallet unexpectedly holds code.

Environment (non-secret): KEEPER_ADDRESS, ORDERS_REGISTRY, ORDERS_RANGE_CUSTODIAN, ORDERS_EXECUTOR,
ORDERS_REGISTRY_IMPL, ORDERS_EXECUTOR_IMPL, EXECUTE (default false), INTERVAL_SECONDS (default 30), MAX_GAS_PRICE_WEI.
Secret (only with EXECUTE=true): KEYSTORE_JSON_BASE64, KEYSTORE_PASSWORD. Logs are JSON lines without secrets.
"""
import base64
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
import orders_keeper as ok  # noqa: E402

RPC = 'https://rpc.mainnet.chain.robinhood.com'
IMPLEMENTATION_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
MIN_GAS_WEI = 300_000_000_000_000  # 0.0003 ETH: one close is about 2.3M gas, one finalisation about 1.5M
KEYS = ('ORDERS_REGISTRY', 'ORDERS_RANGE_CUSTODIAN', 'ORDERS_EXECUTOR', 'ORDERS_REGISTRY_IMPL', 'ORDERS_EXECUTOR_IMPL')
STOP = False


def stop(*_):
    global STOP
    STOP = True


def emit(status, **fields):
    print(json.dumps(dict(status=status, checkedAtUnix=int(time.time()), **fields)), flush=True)


def is_address(value):
    return isinstance(value, str) and value.startswith('0x') and len(value) == 42


def local_rpc(url):
    parts = urlsplit(url)
    return parts.scheme == 'http' and parts.hostname in ('127.0.0.1', 'localhost') and '@' not in parts.netloc


def cast(rpc, *args):
    r = subprocess.run(['cast', *args, '--rpc-url', rpc], capture_output=True, text=True, timeout=60)
    if r.returncode:
        raise RuntimeError('rpc read failed')
    return r.stdout.strip()


def configured(env):
    values = {k: env.get(k, '') for k in KEYS}
    if not all(is_address(v) for v in values.values()):
        raise RuntimeError('all of ' + ', '.join(KEYS) + ' must be set to addresses')
    return values


def preflight(rpc, c, keeper):
    if int(cast(rpc, 'chain-id')) != 4663:
        raise RuntimeError('wrong chain')
    for proxy, impl in (('ORDERS_EXECUTOR', 'ORDERS_EXECUTOR_IMPL'), ('ORDERS_REGISTRY', 'ORDERS_REGISTRY_IMPL')):
        slot = cast(rpc, 'storage', c[proxy], IMPLEMENTATION_SLOT)
        if ('0x' + slot[-40:]).lower() != c[impl].lower():
            raise RuntimeError(proxy.lower() + ' implementation changed; review before sending')
    if int(cast(rpc, 'codesize', keeper)) != 0:
        raise RuntimeError('KEEPER_ADDRESS has code')


def prepare_signer(directory, keeper):
    encoded = os.environ.pop('KEYSTORE_JSON_BASE64', '')
    password = os.environ.pop('KEYSTORE_PASSWORD', '')
    if not encoded or not password:
        raise RuntimeError('signer is not provisioned')
    raw = base64.b64decode(encoded, validate=True)
    data = json.loads(raw)
    if data.get('version') != 3 or not (data.get('crypto') or data.get('Crypto')):
        raise RuntimeError('expected an encrypted V3 keystore')
    key = Path(directory) / 'keystore'
    key.write_bytes(raw)
    key.chmod(0o600)
    secret = Path(directory) / 'password'
    secret.write_text(password)
    secret.chmod(0o600)
    check = subprocess.run(['cast', 'wallet', 'address', '--keystore', str(key), '--password-file', str(secret)],
                           capture_output=True, text=True, timeout=60)
    if check.returncode or check.stdout.strip().lower() != keeper.lower():
        raise RuntimeError('keystore does not belong to KEEPER_ADDRESS')
    return ['--keystore', str(key), '--password-file', str(secret)]


def main():
    os.umask(0o077)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    keeper = os.environ.get('KEEPER_ADDRESS', '')
    if not is_address(keeper):
        raise RuntimeError('KEEPER_ADDRESS is required')
    execute = os.environ.get('EXECUTE', 'false') == 'true'
    interval = max(15, int(os.environ.get('INTERVAL_SECONDS', '30')))
    rpc = os.environ.get('RPC_URL', RPC)
    if rpc != RPC and not local_rpc(rpc):
        raise RuntimeError('RPC_URL may only override to a local rehearsal node')
    ok.MAX_GAS_PRICE_WEI = min(int(os.environ.get('MAX_GAS_PRICE_WEI', '100000000')), 2_000_000_000)
    c = configured(os.environ)
    errors = 0
    with tempfile.TemporaryDirectory(prefix='orders-keeper-') as directory:
        signer = prepare_signer(directory, keeper) if execute else []
        journal = Path(directory) / 'journal.json'
        journal.write_text(json.dumps({'registry': c['ORDERS_REGISTRY'], 'rangeCustodian': c['ORDERS_RANGE_CUSTODIAN'],
                                       'executor': c['ORDERS_EXECUTOR']}))
        k = ok.Keeper(journal, keeper, signer, Path(directory) / 'state.json', rpc=rpc)
        emit('started', executionEnabled=execute, keeper=keeper, registry=c['ORDERS_REGISTRY'])
        while not STOP:
            try:
                preflight(rpc, c, keeper)
                balance = int(cast(rpc, 'balance', keeper))
                funded = balance >= MIN_GAS_WEI
                emit('heartbeat', executionEnabled=execute, keeper=keeper, gasBalanceWei=str(balance), gasReady=funded)
                if execute and not funded:
                    emit('awaiting_gas', keeper=keeper, gasBalanceWei=str(balance))
                else:
                    lines, code = k.step(execute and funded)
                    for line in lines:
                        emit('step', **line)
                    if code:
                        emit('attention', code=code)
                errors = 0
            except Exception as error:  # no raw messages from cast: they can carry call data
                errors += 1
                emit('error', errorType=type(error).__name__,
                     reason=str(error)[:160] if type(error) is RuntimeError else '', consecutive=errors)
                if errors >= 10:
                    raise
            for _ in range(interval):
                if STOP:
                    break
                time.sleep(1)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        emit('fatal', errorType=type(error).__name__)
        sys.exit(2)

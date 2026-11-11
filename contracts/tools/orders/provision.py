"""Host the TP/SL order + range finalisation keeper on DigitalOcean App Platform (its own app, its own wallet).

    python3 provision.py create <range journal>  monitor-only app (EXECUTE=false, no secrets), addresses and reviewed
                                                 implementations from deployments/range-mainnet.json
    python3 provision.py enable                  OPERATOR ONLY: uploads the keeper keystore + password as encrypted
                                                 run-time secrets and sets EXECUTE=true. Refuses unless the wallet has
                                                 gas and no code (execution is permissionless; it needs no role).
    python3 provision.py disable             EXECUTE=false and the signer secrets removed, force-rebuild
    python3 provision.py status              deployment phase plus the last worker log lines

Never touches any other app (peridot-ramses-keeper, the range keeper 6dc249f8, the margin keeper 24b65b93, the Stellar apps). Every spec change
is followed by `create-deployment --force-rebuild` (an update alone can reuse an old build). Secrets are written only to
an owner-only temporary file for the `doctl apps update` call and deleted afterwards; they are never printed.
"""
import base64
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONTEXT = os.environ.get('DO_CONTEXT', 'peridot-keeper-database2')
APP_NAME = 'peridot-orders-keeper'
APP_RECORD = HERE / 'app.json'
WALLET = json.loads((HERE / 'wallet.json').read_text())
RPC = 'https://rpc.mainnet.chain.robinhood.com'
BRANCH = os.environ.get('ORDERS_KEEPER_BRANCH', 'proto/range-take-profit')
MIN_GAS_WEI = 300_000_000_000_000
SECRET_KEYS = ('KEYSTORE_JSON_BASE64', 'KEYSTORE_PASSWORD')


def doctl(*args, stdin=None):
    r = subprocess.run(['doctl', '--context', CONTEXT, *args], capture_output=True, text=True, input=stdin, timeout=300)
    if r.returncode:
        raise RuntimeError('doctl ' + args[0] + ' ' + args[1] + ' failed: ' + (r.stderr or r.stdout).strip()[:300])
    return r.stdout


def cast(*args):
    r = subprocess.run(['cast', *args, '--rpc-url', RPC], capture_output=True, text=True, timeout=60)
    if r.returncode:
        raise RuntimeError('cast ' + args[0] + ' failed')
    return r.stdout.strip()


def keccak(text):
    # offline: `cast keccak` takes no --rpc-url
    r = subprocess.run(['cast', 'keccak', text], capture_output=True, text=True, timeout=60)
    if r.returncode:
        raise RuntimeError('cast keccak failed')
    return r.stdout.strip()


def env(key, value, secret=False):
    item = {'key': key, 'value': value, 'scope': 'RUN_TIME'}
    if secret:
        item['type'] = 'SECRET'
    return item


def base_spec(addresses=None):
    spec = {
        'name': APP_NAME, 'region': 'fra',
        'alerts': [{'rule': 'DEPLOYMENT_FAILED'}],
        'workers': [{
            'name': 'orders-keeper',
            'git': {'repo_clone_url': 'https://github.com/PeridotFinance/peridot-contracts-2-5.git', 'branch': BRANCH},
            'source_dir': '/', 'dockerfile_path': 'contracts/tools/orders/Dockerfile',
            'instance_count': 1, 'instance_size_slug': 'apps-s-1vcpu-0.5gb',
            'envs': [env('EXECUTE', 'false'), env('INTERVAL_SECONDS', '30'), env('KEEPER_ADDRESS', WALLET['address'])],
        }],
    }
    if addresses:
        spec['workers'][0]['envs'] += [env(k, v) for k, v in addresses.items()]
    return spec


def journal_addresses(journal_path):
    j = json.loads(Path(journal_path).read_text())
    keys = {'ORDERS_REGISTRY': 'registry', 'ORDERS_RANGE_CUSTODIAN': 'rangeCustodian', 'ORDERS_EXECUTOR': 'executor',
            'ORDERS_REGISTRY_IMPL': 'registryImplementation', 'ORDERS_EXECUTOR_IMPL': 'executorImplementation'}
    out = {k: j.get(v, '') for k, v in keys.items()}
    if not all(isinstance(v, str) and v.startswith('0x') and len(v) == 42 for v in out.values()):
        raise RuntimeError('range journal is missing an address')
    return out


def app_id():
    if not APP_RECORD.exists():
        raise RuntimeError('no app recorded; run create first')
    return json.loads(APP_RECORD.read_text())['id']


def current_spec():
    spec = json.loads(doctl('apps', 'spec', 'get', app_id(), '--format', 'json'))
    if spec.get('name') != APP_NAME:
        raise RuntimeError('recorded app is not ' + APP_NAME)
    return spec


def set_envs(spec, updates, remove=()):
    worker = spec['workers'][0]
    envs = [e for e in worker.get('envs', []) if e['key'] not in updates and e['key'] not in remove]
    envs += list(updates.values())
    worker['envs'] = envs


def update(spec):
    fd, name = tempfile.mkstemp(prefix='orders-spec-', suffix='.json')
    try:
        os.chmod(name, 0o600)
        with os.fdopen(fd, 'w') as f:
            json.dump(spec, f)
        doctl('apps', 'update', app_id(), '--spec', name)
    finally:
        os.unlink(name)
    out = doctl('apps', 'create-deployment', app_id(), '--force-rebuild', '--format', 'ID,Phase', '--no-header')
    print(json.dumps({'app': app_id(), 'deployment': out.split()[0] if out.split() else None, 'forceRebuild': True}))


def cmd_create(journal_path):
    if APP_RECORD.exists():
        raise RuntimeError('app already recorded in app.json; inspect it, never create a second one')
    names = doctl('apps', 'list', '--format', 'Spec.Name', '--no-header').split()
    if APP_NAME in names:
        raise RuntimeError(APP_NAME + ' already exists on DigitalOcean; record its id in app.json instead')
    fd, name = tempfile.mkstemp(prefix='orders-spec-', suffix='.json')
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(base_spec(journal_addresses(journal_path)), f)
        out = doctl('apps', 'create', '--spec', name, '--format', 'ID', '--no-header')
    finally:
        os.unlink(name)
    APP_RECORD.write_text(json.dumps({'id': out.split()[0], 'name': APP_NAME, 'context': CONTEXT, 'branch': BRANCH},
                                     indent=2) + '\n')
    print(APP_RECORD.read_text().strip())


def cmd_enable():
    spec = current_spec()
    keeper = WALLET['address']
    if int(cast('codesize', keeper)) != 0:
        raise RuntimeError('keeper address has code; refusing')
    if int(cast('balance', keeper)) < MIN_GAS_WEI:
        raise RuntimeError('fund the keeper wallet first (at least 0.0003 ETH)')
    key, secret = Path(WALLET['keystorePath']), Path(WALLET['passwordPath'])
    check = subprocess.run(['cast', 'wallet', 'address', '--keystore', str(key), '--password-file', str(secret)],
                           capture_output=True, text=True, timeout=60)
    if check.returncode or check.stdout.strip().lower() != keeper.lower():
        raise RuntimeError('local keystore does not match wallet.json')
    set_envs(spec, {'EXECUTE': env('EXECUTE', 'true'),
                    'KEYSTORE_JSON_BASE64': env('KEYSTORE_JSON_BASE64', base64.b64encode(key.read_bytes()).decode(), True),
                    'KEYSTORE_PASSWORD': env('KEYSTORE_PASSWORD', secret.read_text().strip(), True)})
    update(spec)


def cmd_disable():
    spec = current_spec()
    set_envs(spec, {'EXECUTE': env('EXECUTE', 'false')}, remove=SECRET_KEYS)
    update(spec)


def cmd_status():
    out = doctl('apps', 'get', app_id(), '--format', 'ActiveDeployment.ID,InProgressDeployment.ID', '--no-header')
    print('deployments (active, in progress):', ' '.join(out.split()))
    logs = subprocess.run(['doctl', '--context', CONTEXT, 'apps', 'logs', app_id(), 'orders-keeper', '--type', 'run',
                           '--tail', '8'], capture_output=True, text=True, timeout=120).stdout
    print(logs.strip()[-3000:])


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    commands = {'enable': cmd_enable, 'disable': cmd_disable, 'status': cmd_status}
    if argv[0] == 'create' and len(argv) == 2:
        cmd_create(argv[1])
    elif argv[0] in commands and len(argv) == 1:
        commands[argv[0]]()
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

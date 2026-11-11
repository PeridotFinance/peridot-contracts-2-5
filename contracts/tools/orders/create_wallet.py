"""Create the dedicated TP/SL + range-finalisation keeper wallet as an encrypted Foundry keystore, locally.

Prints only the PUBLIC address. The random password and the keystore are written to an owner-only, git-ignored
directory outside every git repository (default: /Users/joshua/Peridot/.orders-keeper-signer/) and are never printed.
Execution of orders and range finalisation is permissionless: the wallet needs gas only, holds no role and receives
nothing. Never fund it with anything else and never give it a role.
"""
import json
import os
import secrets
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_DIR = Path('/Users/joshua/Peridot/.orders-keeper-signer')


def main(argv):
    os.umask(0o077)
    directory = Path(argv[0]) if argv else DEFAULT_DIR
    record = HERE / 'wallet.json'
    if directory.exists() or record.exists():
        raise RuntimeError('An orders keeper wallet already exists; inspect it, never overwrite')
    directory.mkdir(mode=0o700)
    secret = directory / 'password'
    password = secrets.token_urlsafe(48)
    secret.write_text(password)
    secret.chmod(0o600)
    made = subprocess.run(['cast', 'wallet', 'new', str(directory), 'keystore'],
                          env=dict(os.environ, CAST_PASSWORD=password), capture_output=True, text=True, timeout=60)
    del password
    if made.returncode:
        raise RuntimeError('Keystore creation failed; inspect the directory before retrying')
    key = directory / 'keystore'
    key.chmod(0o600)
    shown = subprocess.run(['cast', 'wallet', 'address', '--keystore', str(key), '--password-file', str(secret)],
                           capture_output=True, text=True, timeout=60)
    address = shown.stdout.strip()
    if shown.returncode or not (address.startswith('0x') and len(address) == 42):
        raise RuntimeError('Keystore verification failed')
    int(address[2:], 16)
    record.write_text(json.dumps({
        'address': address, 'chainId': 4663,
        'purpose': 'TP/SL order execution and range take-profit finalisation: gas only, no roles.',
        'keystorePath': str(key), 'passwordPath': str(secret),
        'fundingTargetWei': str(3 * 10**15)}, indent=2) + '\n')
    print(json.dumps({'address': address, 'chainId': 4663, 'credentialsPrinted': False}, indent=2))


if __name__ == '__main__':
    main(sys.argv[1:])

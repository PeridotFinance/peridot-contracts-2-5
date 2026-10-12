'use strict';

// Disposable local TESTNET credential only. Never fund on mainnet or grant admin roles.
// This utility deliberately has NO signing, exporting or broadcasting command.
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { Wallet } = require('ethers');

function privateDirectory(directory) {
  if (!fs.existsSync(directory)) fs.mkdirSync(directory, { mode: 0o700 });
  const info = fs.lstatSync(directory);
  if (!info.isDirectory() || info.isSymbolicLink() || (info.mode & 0o077) !== 0
      || (process.getuid && info.uid !== process.getuid())) {
    throw new Error('Unsafe wallet directory');
  }
}

function createWallet(directory) {
  privateDirectory(directory);
  const filename = path.join(directory, 'fuji-margin-runner.json');
  // Refuse overwrite, including dangling symlinks. Generate only after the check.
  try {
    fs.lstatSync(filename);
    throw new Error('Wallet already exists');
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  const wallet = Wallet.createRandom();
  const record = {
    version: 1,
    purpose: 'Disposable Fuji margin tests only; no mainnet assets or admin role',
    chainId: 43113,
    address: wallet.address,
    privateKey: wallet.privateKey,
  };
  // Exclusive create also closes the overwrite race. No secret is printed or passed as an argument.
  fs.writeFileSync(filename, JSON.stringify(record) + '\n', { flag: 'wx', mode: 0o600 });
  return { address: wallet.address, chainId: 43113, filename };
}

function publicInfo(directory) {
  privateDirectory(directory);
  const filename = path.join(directory, 'fuji-margin-runner.json');
  const info = fs.lstatSync(filename);
  if (!info.isFile() || info.isSymbolicLink() || (info.mode & 0o077) !== 0
      || info.nlink !== 1 || (process.getuid && info.uid !== process.getuid())) {
    throw new Error('Unsafe wallet file');
  }
  const record = JSON.parse(fs.readFileSync(filename, 'utf8'));
  if (record.version !== 1 || record.chainId !== 43113
      || new Wallet(record.privateKey).address !== record.address) throw new Error('Invalid wallet record');
  return { address: record.address, chainId: record.chainId, filename };
}

function main() {
  const command = process.argv[2];
  if (process.argv.length !== 3 || !['create', 'address'].includes(command)) {
    throw new Error('Use create or address');
  }
  const root = path.resolve(__dirname, '../..');
  const directory = path.join(root, 'private-keys');
  // The runtime credential is not source code and must never be tracked.
  const filename = path.join(directory, 'fuji-margin-runner.json');
  execFileSync('git', ['check-ignore', '--quiet', '--', filename], { cwd: root, stdio: 'ignore' });
  const tracked = execFileSync('git', ['ls-files', '--', filename], { cwd: root, encoding: 'utf8' });
  if (tracked.trim()) throw new Error('Wallet path is tracked');
  console.log(JSON.stringify(command === 'create' ? createWallet(directory) : publicInfo(directory)));
}

if (require.main === module) {
  try { main(); } catch {
    // Never print exception values that could include credential material.
    console.error('Wallet operation refused. Check command, existing file, Git ignore and owner-only permissions.');
    process.exitCode = 1;
  }
}

module.exports = { createWallet, publicInfo };

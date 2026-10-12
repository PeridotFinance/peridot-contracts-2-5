'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createWallet, publicInfo } = require('./fuji-test-wallet.cjs');

// Each directory contains only a generated disposable test credential.
function fixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'fuji-wallet-test-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  return directory;
}

test('creates an owner-only wallet and exposes only public metadata', t => {
  const directory = fixture(t);
  const result = createWallet(directory);
  assert.deepEqual(Object.keys(result).sort(), ['address', 'chainId', 'filename']);
  assert.match(result.address, /^0x[0-9a-fA-F]{40}$/);
  assert.equal(result.chainId, 43113);
  assert.equal(fs.statSync(result.filename).mode & 0o777, 0o600);
  assert.equal(fs.statSync(directory).mode & 0o777, 0o700);
  assert.deepEqual(publicInfo(directory), result);
  assert.throws(() => createWallet(directory), /exists/);
  assert.deepEqual(publicInfo(directory), result);
});

test('rejects unsafe directory permissions and symbolic links', t => {
  const directory = fixture(t);
  fs.chmodSync(directory, 0o755);
  assert.throws(() => createWallet(directory), /Unsafe/);
  fs.chmodSync(directory, 0o700);
  const linked = path.join(directory, 'linked');
  fs.symlinkSync(directory, linked);
  assert.throws(() => createWallet(linked), /Unsafe/);
});

test('rejects exposed, linked or corrupt wallet files', t => {
  const directory = fixture(t);
  const result = createWallet(directory);
  fs.chmodSync(result.filename, 0o644);
  assert.throws(() => publicInfo(directory), /Unsafe/);
  fs.chmodSync(result.filename, 0o600);
  const copy = path.join(directory, 'hardlink');
  fs.linkSync(result.filename, copy);
  assert.throws(() => publicInfo(directory), /Unsafe/);
  fs.unlinkSync(copy);
  fs.writeFileSync(result.filename, '{}');
  assert.throws(() => publicInfo(directory), /Invalid/);
});

test('refuses to overwrite a dangling symlink', t => {
  const directory = fixture(t);
  fs.symlinkSync(path.join(directory, 'missing'), path.join(directory, 'fuji-margin-runner.json'));
  assert.throws(() => createWallet(directory), /exists/);
  assert.equal(fs.existsSync(path.join(directory, 'missing')), false);
});

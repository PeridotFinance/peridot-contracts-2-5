// OFFLINE tests of tools/dlmm-rewards-ceremony.sh and tools/dlmm-rewards-safe-call.sh with a STUB `cast` and a STUB `forge` first on the PATH (no chain, no endpoint, nothing signed).
// The stub answers the RPC-touching subcommands from environment variables and records every call in a log; `cast calldata` and `cast abi-decode` (pure, offline) are delegated to the REAL
// cast so that the calldata the tool prints and the tuple text the tool parses (`epochInfo`) are cast's own formats, not a guess. Every tool runs under /bin/bash (macOS: 3.2).
//   run from contracts/vault-dlmm:   node --test tools/rewards-test/dlmm-rewards-tools.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const TOOLS = join(HERE, '..');
const REAL_CAST = spawnSync('bash', ['-c', 'command -v cast'], { encoding: 'utf8' }).stdout.trim();
const skip = REAL_CAST ? false : 'real cast not installed (needed offline for calldata / abi-decode)';
const SAFE = '0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12', LEDGER = '0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD', PHAR = '0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7';
const DIST = '0x7343D74BE909F24097AE39c8F8976a30eb128df5';
const ROOT = '0x' + 'ab'.repeat(32), DH = '0x' + 'cd'.repeat(32);
const SECRET_URL = 'https://rpc.example.invalid/v2/TOPSECRETKEY1234567890';

const STUB_CAST = `#!/bin/bash
# STUB cast (test double): RPC subcommands answer from STUB_* variables and are logged; pure subcommands go to the real cast.
echo "cast $*" >> "$STUB_LOG"
sub="$1"; shift
lc() { echo "$1" | tr 'A-Z' 'a-z'; }
sci() { n="$1"; if [ "\${#n}" -gt 10 ]; then echo "$n [\${n:0:1}e$((\${#n}-1))]"; else echo "$n"; fi; }
case "$sub" in
  chain-id) echo "\${STUB_CHAIN_ID:-43114}" ;;
  block-number) echo "\${STUB_HEAD:-100500000}" ;;
  block) echo "\${STUB_NOW:-1800000000}" ;;
  rpc) if [ "\${STUB_ANVIL:-0}" = 1 ]; then echo '{}'; else echo "method not found" >&2; exit 1; fi ;;
  send) echo "SEND $*" >> "$STUB_LOG"; echo "status 1 (success)"; exit "\${STUB_SEND_RC:-0}" ;;
  call)
    target=""; sig=""
    for a in "$@"; do case "$a" in --*) break ;; esac; if [ -z "$target" ]; then target="$a"; elif [ -z "$sig" ]; then sig="$a"; break; fi; done
    case "$sig" in
      'getOwners()(address[])') echo "[\${STUB_OWNERS:-0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD}]" ;;
      'owner()(address)') echo "\${STUB_DIST_OWNER:-0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12}" ;;
      'PHAR()(address)') echo "\${STUB_DIST_PHAR:-0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7}" ;;
      'epochCount()(uint256)') echo "\${STUB_EPOCH_COUNT:-0}" ;;
      'balanceOf(address)(uint256)')
        who=$(lc "$3"); if [ "$who" = "$(lc 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12)" ]; then sci "\${STUB_SAFE_PHAR:-5000000000000000000}"; else sci "\${STUB_DIST_BAL:-0}"; fi ;;
      'allowance(address,address)(uint256)') sci "\${STUB_ALLOWANCE:-0}" ;;
      'nonce()(uint256)') echo "\${STUB_NONCE:-7}" ;;
      epochInfo*) echo "\${STUB_EPOCHINFO:?}" ;;
      execTransaction*)
        case "\${STUB_SIM:-true}" in true) echo true ;; false) echo false ;; *) echo "Error: execution reverted: GS013" >&2; exit 1 ;; esac ;;
      0x*) echo "execution reverted: the inner call reverts (stub)" >&2; exit 1 ;;
      *) echo "stub cast: unexpected call $sig" >&2; exit 9 ;;
    esac ;;
  *) exec "$REAL_CAST" "$sub" "$@" ;;
esac
`;
const STUB_FORGE = `#!/bin/bash
echo "forge $*" >> "$STUB_LOG"
printf '%s\\n' "\${STUB_FORGE_OUT:-}"
exit "\${STUB_FORGE_RC:-0}"
`;

const tmp = mkdtempSync(join(tmpdir(), 'rewards-tools-'));
const bin = join(tmp, 'bin'); spawnSync('mkdir', ['-p', bin]);
writeFileSync(join(bin, 'cast'), STUB_CAST); writeFileSync(join(bin, 'forge'), STUB_FORGE); chmodSync(join(bin, 'cast'), 0o755); chmodSync(join(bin, 'forge'), 0o755);
const LOG = join(tmp, 'calls.log');
let epochTuple = '';
function tuple(over = {}) {
  const f = { root: ROOT, total: '1000000000000000000', claimed: '0', publishedAt: '1800000000', opens: '1800086400', deadline: '1815552000', from: '100488395', to: '100490000', dh: DH, status: '1', ...over };
  const enc = spawnSync(REAL_CAST, ['abi-encode', 'f((bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256,bytes32,uint8))', `(${f.root},${f.total},${f.claimed},${f.publishedAt},${f.opens},${f.deadline},${f.from},${f.to},${f.dh},${f.status})`], { encoding: 'utf8' }).stdout.trim();
  return spawnSync(REAL_CAST, ['abi-decode', 'epochInfo(uint256)((bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256,bytes32,uint8))', enc], { encoding: 'utf8' }).stdout.trim();
}
function sh(script, args, env = {}, { path = true } = {}) {
  writeFileSync(LOG, '');
  const r = spawnSync('/bin/bash', [join(TOOLS, script), ...args], {
    encoding: 'utf8', timeout: 60000,
    env: { PATH: `${path ? bin + ':' : ''}/usr/bin:/bin:/usr/sbin:/sbin`, HOME: tmp, REAL_CAST, STUB_LOG: LOG, STUB_EPOCHINFO: epochTuple || tuple(), ...env },
  });
  return { code: r.status, out: (r.stdout || '') + (r.stderr || ''), log: readFileSync(LOG, 'utf8') };
}
const calls = (r, re) => r.log.split('\n').filter((l) => re.test(l));
const SC = 'dlmm-rewards-safe-call.sh', CER = 'dlmm-rewards-ceremony.sh';
const base = { DIST, ETH_RPC_URL: 'http://127.0.0.1:1' };
const calldata = (sig, ...a) => spawnSync(REAL_CAST, ['calldata', sig, ...a], { encoding: 'utf8' }).stdout.trim();

test('the tools use no bash 4+ construct (macOS ships bash 3.2): no mapfile/readarray, associative arrays, case conversion, |&, namerefs; and they run under /bin/bash', { skip }, () => {
  for (const f of [SC, CER]) {
    const t = readFileSync(join(TOOLS, f), 'utf8').replace(/^\s*#.*$/gm, '');
    for (const [re, what] of [[/\bmapfile\b|\breadarray\b/, 'mapfile'], [/declare\s+-A|typeset\s+-A/, 'associative array'], [/\$\{[^}]*(,,|\^\^)[^}]*\}/, 'case conversion'], [/\|&/, '|&'], [/local\s+-n|declare\s+-n/, 'nameref'], [/\bcoproc\b/, 'coproc'], [/\[\[\s+-v\b/, '[[ -v'], [/\$\{!\w+\[@\]\}/, 'indirect keys']]) assert.ok(!re.test(t), `${f}: ${what}`);
  }
  const v = spawnSync('/bin/bash', ['--version'], { encoding: 'utf8' }).stdout.split('\n')[0];
  console.log('# /bin/bash:', v);
  for (const f of [SC, CER]) assert.equal(spawnSync('/bin/bash', ['-n', join(TOOLS, f)]).status, 0, `${f} passes /bin/bash -n`);
});

// ------------------------------------------------------------------------------------------------------------------------------ safe-call: refusals
test('safe-call: usage, DIST and ETH_RPC_URL are required; the mode and the action are validated', { skip }, () => {
  assert.equal(sh(SC, [], base).code, 2);
  assert.equal(sh(SC, ['frob', 'approve', '1'], base).code, 2);
  assert.match(sh(SC, ['simulate', 'approve', '1'], { ETH_RPC_URL: base.ETH_RPC_URL }).out, /set DIST/);
  assert.match(sh(SC, ['simulate', 'approve', '1'], { DIST: '0x123', ETH_RPC_URL: base.ETH_RPC_URL }).out, /DIST is not an address/);
  assert.match(sh(SC, ['simulate', 'approve', '1'], { DIST }).out, /ETH_RPC_URL/);
  const r = sh(SC, ['simulate', 'frobnicate', '1'], base);
  assert.equal(r.code, 2);
  assert.match(r.out, /unknown action/);
});
test('safe-call: wrong chain, Safe owners not exactly the Ledger, distributor not owned by the Safe, wrong PHAR are each refused (exit 1) before anything else', { skip }, () => {
  let r = sh(SC, ['simulate', 'approve', '5'], { ...base, STUB_CHAIN_ID: '1' });
  assert.equal(r.code, 1); assert.match(r.out, /chain id is not 43114/);
  r = sh(SC, ['simulate', 'approve', '5'], { ...base, STUB_OWNERS: `${LEDGER}, 0x1111111111111111111111111111111111111111` });
  assert.equal(r.code, 1); assert.match(r.out, /Safe owners are not exactly \[the Ledger\]/);
  r = sh(SC, ['simulate', 'approve', '5'], { ...base, STUB_DIST_OWNER: '0x2222222222222222222222222222222222222222' });
  assert.equal(r.code, 1); assert.match(r.out, /distributor's owner is not the Safe/);
  r = sh(SC, ['simulate', 'approve', '5'], { ...base, STUB_DIST_PHAR: '0x3333333333333333333333333333333333333333' });
  assert.equal(r.code, 1); assert.match(r.out, /PHAR is not the PHAR constant/);
  for (const x of [r]) assert.equal(calls(x, /^cast send|^SEND/).length, 0);
});
test('safe-call approve: an exact amount only (integer, not above 10^30), simulation prints the decoded call and the real calldata; `simulate` never sends', { skip }, () => {
  assert.equal(sh(SC, ['simulate', 'approve', '1.5'], base).code, 2);
  assert.equal(sh(SC, ['simulate', 'approve', 'abc'], base).code, 2);
  assert.match(sh(SC, ['simulate', 'approve', '1' + '0'.repeat(31)], base).out, /refusing an approval above 10\^30 wei/);
  assert.equal(sh(SC, ['simulate', 'approve', '1' + '0'.repeat(30)], base).code, 0, '10^30 itself is allowed');
  const r = sh(SC, ['simulate', 'approve', '123456789012345678'], base);
  assert.equal(r.code, 0, r.out);
  assert.match(r.out, new RegExp(`DECODED CALL: ${PHAR}  approve\\(address,uint256\\) ${DIST} 123456789012345678`));
  assert.ok(r.out.includes(calldata('approve(address,uint256)', DIST, '123456789012345678')), 'the printed calldata is cast\'s encoding of approve(DIST, total)');
  assert.match(r.out, /before: distributor epochCount=0  distributor PHAR=0  Safe PHAR=5000000000000000000  allowance=0  safe nonce=7/, 'the cast "[1e18]" decorations are stripped');
  assert.match(r.out, /SIMULATION \(eth_call from the Ledger, MANDATORY before signing; must be true\): true/);
  assert.equal(calls(r, /^SEND/).length, 0, 'simulate sends nothing');
  const ex = calls(r, /^cast call .*execTransaction/)[0];
  assert.ok(ex.includes(`--from ${LEDGER}`) && ex.includes(PHAR), 'the simulation is an eth_call of execTransaction from the Ledger on PHAR');
});
test('safe-call: a simulation that returns false or fails stops the tool (exit 1) with the inner revert reason, and `send` then never reaches cast send', { skip }, () => {
  for (const sim of ['false', 'fail']) {
    const r = sh(SC, ['send', 'approve', '5'], { ...base, STUB_SIM: sim, STUB_ANVIL: '1', SEND_MODE: 'unlocked' });
    assert.equal(r.code, 1, sim);
    assert.equal(calls(r, /^SEND/).length, 0, 'no signature without a passing simulation');
  }
  const r = sh(SC, ['send', 'approve', '5'], { ...base, STUB_SIM: 'fail' });
  assert.match(r.out, /simulation FAILED/);
  assert.match(r.out, /inner call as the Safe .*the inner call reverts \(stub\)/);
});
// ------------------------------------------------------------------------------------------------------------------------------ safe-call: publish
const PUB = ['publish', ROOT, '1000000000000000000', '100488395', '100490000', DH];
test('safe-call publish: EXPECT_EPOCH_ID is mandatory and must equal epochCount(); bytes32 and integer arguments are validated; the Safe needs the balance and the allowance; toBlock may not exceed the head', { skip }, () => {
  const ok = { ...base, STUB_EPOCH_COUNT: '3', EXPECT_EPOCH_ID: '3', STUB_SAFE_PHAR: '2000000000000000000', STUB_ALLOWANCE: '1000000000000000000' };
  assert.match(sh(SC, ['simulate', ...PUB], { ...base }).out, /EXPECT_EPOCH_ID/);
  assert.equal(sh(SC, ['simulate', 'publish', '0x12', '1', '1', '2', DH], ok).code, 2);
  assert.equal(sh(SC, ['simulate', 'publish', ROOT, '1', '1', '2', '0x34'], ok).code, 2);
  assert.equal(sh(SC, ['simulate', 'publish', ROOT, 'x', '1', '2', DH], ok).code, 2);
  let r = sh(SC, ['simulate', ...PUB], { ...ok, EXPECT_EPOCH_ID: '2' });
  assert.equal(r.code, 1); assert.match(r.out, /epochCount\(\) is 3 but the root was generated for id 2: regenerate/);
  r = sh(SC, ['simulate', ...PUB], { ...ok, STUB_SAFE_PHAR: '999999999999999999' });
  assert.equal(r.code, 1); assert.match(r.out, /Safe holds 999999999999999999 PHAR wei, less than the total/);
  r = sh(SC, ['simulate', ...PUB], { ...ok, STUB_ALLOWANCE: '0' });
  assert.equal(r.code, 1); assert.match(r.out, /allowance to the distributor is 0, less than the total .* run the approve step first/);
  r = sh(SC, ['simulate', ...PUB], { ...ok, STUB_HEAD: '100489999' });
  assert.equal(r.code, 1); assert.match(r.out, /toBlock is above the chain head/);
  r = sh(SC, ['simulate', ...PUB], ok);
  assert.equal(r.code, 0, r.out);
  assert.match(r.out, new RegExp(`PUBLISH epoch id 3: root ${ROOT} total 1000000000000000000 blocks \\(100488395, 100490000\\] dataHash ${DH}`));
  assert.ok(r.out.includes(calldata('publishEpoch(bytes32,uint256,uint64,uint64,bytes32)', ROOT, '1000000000000000000', '100488395', '100490000', DH)), 'calldata = publishEpoch(root,total,from,to,dataHash)');
  assert.equal(calls(r, /^SEND/).length, 0);
});
test('safe-call send: SEND_MODE=unlocked only on an anvil node (anvil_nodeInfo must answer: exit 3 otherwise); the default mode is the LEDGER and prints OPERATOR-ONLY; exactly ONE cast send, after the passing simulation, carrying execTransaction with the approved-by-msg.sender signature and the Ledger as sender', { skip }, () => {
  const ok = { ...base, STUB_EPOCH_COUNT: '0', EXPECT_EPOCH_ID: '0', STUB_ALLOWANCE: '1000000000000000000' };
  let r = sh(SC, ['send', ...PUB], { ...ok, SEND_MODE: 'unlocked', STUB_ANVIL: '0' });
  assert.equal(r.code, 3); assert.match(r.out, /SEND_MODE=unlocked is for a LOCAL anvil fork only/); assert.equal(calls(r, /^SEND/).length, 0);
  r = sh(SC, ['send', ...PUB], { ...ok, SEND_MODE: 'unlocked', STUB_ANVIL: '1' });
  assert.equal(r.code, 0, r.out);
  let s = calls(r, /^SEND/);
  assert.equal(s.length, 1);
  assert.ok(s[0].includes('--unlocked') && s[0].includes(`--from ${LEDGER}`) && s[0].includes('--gas-limit 1500000') && !s[0].includes('--ledger'));
  assert.ok(s[0].includes('execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)'));
  assert.ok(s[0].includes('0x000000000000000000000000064efe76812f5f18bd1aa9708739fb33c810b2dd000000000000000000000000000000000000000000000000000000000000000001'), 'the signature field');
  assert.match(r.out, /ABOUT TO SIGN: Safe nonce 7, publishEpoch/);
  // the simulation precedes the send in the call log
  const iSim = r.log.split('\n').findIndex((l) => /execTransaction.*\(bool\)/.test(l)); const iSend = r.log.split('\n').findIndex((l) => /^SEND/.test(l));
  assert.ok(iSim >= 0 && iSend > iSim, 'simulation first, then the send');
  r = sh(SC, ['send', ...PUB], ok); // default = ledger
  assert.equal(r.code, 0, r.out);
  assert.match(r.out, /OPERATOR-ONLY: one Ledger confirmation/);
  s = calls(r, /^SEND/); assert.equal(s.length, 1); assert.ok(s[0].includes('--ledger') && !s[0].includes('--unlocked'));
  r = sh(SC, ['send', ...PUB], { ...ok, STUB_SEND_RC: '1' });
  assert.notEqual(r.code, 0, 'a failing cast send fails the tool (set -e)');
});
// ------------------------------------------------------------------------------------------------------------------------------ safe-call: cancel and sweep (the epochInfo tuple is parsed from cast's own text)
test('safe-call cancel: only inside the challenge window (strictly before claimOpensAt), parsed from the real epochInfo tuple text; sweep: only at or after the deadline', { skip }, () => {
  epochTuple = tuple({ publishedAt: '1800000000', opens: '1800086400', deadline: '1815552000' });
  assert.match(epochTuple, /^\(0x[0-9a-f]{64}, 1000000000000000000 \[1e18\], 0, 1800000000 \[1\.8e9\],/, 'the stub serves cast\'s real tuple format');
  let r = sh(SC, ['simulate', 'cancel', '0'], { ...base, STUB_NOW: '1800086399' });
  assert.equal(r.code, 0, r.out); assert.ok(r.out.includes(calldata('cancelEpoch(uint256)', '0')));
  r = sh(SC, ['simulate', 'cancel', '0'], { ...base, STUB_NOW: '1800086400' });
  assert.equal(r.code, 1); assert.match(r.out, /challenge window of epoch 0 is over \(claimOpensAt 1800086400 <= now 1800086400\)/);
  r = sh(SC, ['simulate', 'sweep', '0'], { ...base, STUB_NOW: '1815551999' });
  assert.equal(r.code, 1); assert.match(r.out, /claim deadline of epoch 0 is 1815552000, now is 1815551999: sweep is not possible yet/);
  r = sh(SC, ['simulate', 'sweep', '0'], { ...base, STUB_NOW: '1815552000' });
  assert.equal(r.code, 0, r.out); assert.ok(r.out.includes(calldata('sweepUnclaimed(uint256)', '0')));
  assert.equal(sh(SC, ['simulate', 'cancel', 'x'], base).code, 2);
  assert.equal(sh(SC, ['simulate', 'cancel'], base).code, 1, 'a missing epoch id is refused');
  epochTuple = '';
});
test('safe-call: the endpoint value never appears in the tool\'s output, and no cast argument carries a URL (the tool reads ETH_RPC_URL from the environment only)', { skip }, () => {
  const r = sh(SC, ['simulate', 'approve', '5'], { DIST, ETH_RPC_URL: SECRET_URL });
  assert.equal(r.code, 0, r.out);
  assert.ok(!r.out.includes('TOPSECRETKEY') && !r.log.includes('TOPSECRETKEY') && !/https?:\/\//.test(r.log));
});

// ------------------------------------------------------------------------------------------------------------------------------ ceremony
test('ceremony list: prints the ordered ceremony without cast, forge or an endpoint; usage errors exit 2', { skip }, () => {
  const r = sh(CER, ['list'], {}, { path: false });
  assert.equal(r.code, 0, r.out);
  for (const k of ['A3  tools/dlmm-rewards-ceremony.sh deploy live', 'B1  daily: vault.harvestRewards()', 'B5  Safe: distributor.publishEpoch', 'B8  after publishedAt + 180 days']) assert.ok(r.out.includes(k), k);
  assert.equal(sh(CER, [], {}).code, 2);
  assert.equal(sh(CER, ['deploy'], {}).code, 2);
  assert.equal(sh(CER, ['deploy', 'nowhere'], {}).code, 2);
  assert.equal(sh(CER, ['frob', 'live'], { AVALANCHE_MAINNET_RPC_URL: SECRET_URL }).code, 2);
});
test('ceremony check-env: DEPLOYER must be set, an address, and neither the Ledger nor the Safe (any case); delay/deadline integers; live deploy needs the keystore account name; verify needs DISTRIBUTOR', { skip }, () => {
  const dep = '0x1234567890123456789012345678901234567890';
  assert.equal(sh(CER, ['check-env', 'rehearsal'], {}).code, 1);
  assert.match(sh(CER, ['check-env', 'rehearsal'], { DEPLOYER: 'nope' }).out, /DEPLOYER is not an address/);
  assert.match(sh(CER, ['check-env', 'rehearsal'], { DEPLOYER: LEDGER.toLowerCase() }).out, /must not be the Ledger or the Safe/);
  assert.match(sh(CER, ['check-env', 'rehearsal'], { DEPLOYER: SAFE.toUpperCase().replace('0X', '0x') }).out, /must not be the Ledger or the Safe/);
  assert.match(sh(CER, ['check-env', 'rehearsal'], { DEPLOYER: dep, CLAIM_DELAY: '1d' }).out, /must be integers/);
  const ok = sh(CER, ['check-env', 'rehearsal'], { DEPLOYER: dep });
  assert.equal(ok.code, 0, ok.out); assert.match(ok.out, /all inputs set; the deployer is neither the Ledger nor the Safe/);
  const live = sh(CER, ['check-env', 'live'], { DEPLOYER: dep, AVALANCHE_MAINNET_RPC_URL: SECRET_URL });
  assert.equal(live.code, 0, 'check-env is pure: no keystore name needed, no RPC');
  assert.match(sh(CER, ['deploy', 'live'], { DEPLOYER: dep, AVALANCHE_MAINNET_RPC_URL: SECRET_URL }).out, /DLMM_DEPLOYER_ACCOUNT/);
  assert.match(sh(CER, ['verify', 'rehearsal'], { DEPLOYER: dep, STUB_ANVIL: '1' }).out, /DISTRIBUTOR is not set/);
});
test('ceremony live: refuses without AVALANCHE_MAINNET_RPC_URL; deploys with the keystore account and the foundry alias `avalanche` (the endpoint is in no argument), writes the PUBLIC addresses file, redacts every URL, and propagates a failing forge', { skip }, () => {
  const dep = '0x1234567890123456789012345678901234567890';
  const file = join(tmp, 'addr.live.env');
  const out = `Script ran\n  == DEPLOYED\n  PHAR_DISTRIBUTOR=${DIST}\n  PHAR_DISTRIBUTOR_CODEHASH=0x${'ee'.repeat(32)}\n connecting to ${SECRET_URL}`;
  let r = sh(CER, ['deploy', 'live'], { DEPLOYER: dep, DLMM_DEPLOYER_ACCOUNT: 'dlmm-deployer' });
  assert.notEqual(r.code, 0); assert.match(r.out, /AVALANCHE_MAINNET_RPC_URL must be set/);
  r = sh(CER, ['deploy', 'live'], { DEPLOYER: dep, DLMM_DEPLOYER_ACCOUNT: 'dlmm-deployer', AVALANCHE_MAINNET_RPC_URL: SECRET_URL, STUB_FORGE_OUT: out, DLMM_REWARDS_ADDRESSES_FILE: file });
  assert.equal(r.code, 0, r.out);
  const f = calls(r, /^forge script/)[0];
  assert.ok(f.includes('script/DeployPharRewardsDistributor.s.sol:DeployPharRewardsDistributor') && f.includes('--rpc-url avalanche') && f.includes('--account dlmm-deployer') && f.includes(`--sender ${dep}`) && f.includes('--broadcast') && !f.includes('--unlocked'));
  assert.ok(!r.log.includes('TOPSECRETKEY') && !r.out.includes('TOPSECRETKEY') && !r.out.includes('rpc.example.invalid'), 'the endpoint is in no argument and no output line');
  assert.match(r.out, /<url-redacted>/);
  assert.equal(readFileSync(file, 'utf8'), `export PHAR_DISTRIBUTOR=${DIST}\nexport PHAR_DISTRIBUTOR_CODEHASH=0x${'ee'.repeat(32)}\n`);
  r = sh(CER, ['deploy', 'live'], { DEPLOYER: dep, DLMM_DEPLOYER_ACCOUNT: 'dlmm-deployer', AVALANCHE_MAINNET_RPC_URL: SECRET_URL, STUB_FORGE_OUT: 'preflight: DEPLOYER nonce != 0', STUB_FORGE_RC: '1', DLMM_REWARDS_ADDRESSES_FILE: file });
  assert.equal(r.code, 1, 'a failing forge script is a failing deploy');
  assert.match(readFileSync(file, 'utf8'), /MISSING/);
});
test('ceremony rehearsal: refuses unless the LOCAL endpoint answers anvil_nodeInfo (exit 3); then the deployer is an unlocked sender, no keystore', { skip }, () => {
  const dep = '0x1234567890123456789012345678901234567890';
  const file = join(tmp, 'addr.reh.env');
  let r = sh(CER, ['deploy', 'rehearsal'], { DEPLOYER: dep, STUB_ANVIL: '0', DLMM_REWARDS_ADDRESSES_FILE: file });
  assert.equal(r.code, 3); assert.match(r.out, /rehearsal mode needs a LOCAL anvil fork/);
  assert.equal(calls(r, /^forge script/).length, 0);
  r = sh(CER, ['deploy', 'rehearsal'], { DEPLOYER: dep, STUB_ANVIL: '1', RPC_LOCAL: 'http://127.0.0.1:18545', STUB_FORGE_OUT: `PHAR_DISTRIBUTOR=${DIST}\nPHAR_DISTRIBUTOR_CODEHASH=0x${'aa'.repeat(32)}`, DLMM_REWARDS_ADDRESSES_FILE: file });
  assert.equal(r.code, 0, r.out);
  const f = calls(r, /^forge script/)[0];
  assert.ok(f.includes('--rpc-url http://127.0.0.1:18545') && f.includes('--unlocked') && f.includes(`--sender ${dep}`) && !f.includes('--account'));
  r = sh(CER, ['verify', 'rehearsal'], { DEPLOYER: dep, DISTRIBUTOR: DIST, STUB_ANVIL: '1', EXPECT_OWNER_SAFE: 'true', STUB_FORGE_OUT: 'owner ok' });
  assert.equal(r.code, 0, r.out);
  const v = calls(r, /^forge script/)[0];
  assert.ok(v.includes('ReadBackPharRewardsDistributor') && !v.includes('--broadcast'), 'verify is read-only: no --broadcast');
});

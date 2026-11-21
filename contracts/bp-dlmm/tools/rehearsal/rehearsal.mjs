// FORK REHEARSAL of the bpPHAR-USDC listing (a lending market whose underlying is the share token of the Peridot Pharaoh DLMM USDC/USDt vault + an oracle wrapper in front of the controller's
// oracle) on the LIVE Avalanche pilot. Started by rehearsal.sh (shared fork lock, anvil at head-4, instant mining, proxy-fronted endpoint, removes its scratch on exit).
// THE ASSISTANT HAS NOT RUN THIS (it has no endpoint): the user runs it. NOTHING IS REAL: the throwaway deployer, the Ledger (the real admin of the controller, impersonated ONLY because this
// is a fork), the Safe and every test wallet are impersonated on the local anvil. Every transaction goes to the LOCAL endpoint REH_RPC.
// ORDER = the order of the ceremony: B0 pre-flight + deploy (the new contracts exist, nothing is seeded or listed; v2 wrapper facts and the REAL feed evidence are read here) -> B1 price identity with the REAL feeds
// (oracle swap) and margin after the swap -> B2 listing + seed -> B6a rollback before use -> B8 pToken inflation (seed-only market) -> B3 supply / CF 50 % / borrow / repay -> B4 stale feeds (v2: the 24 h fallback)
// -> B5 liquidation -> B10 stale-feed OUTAGE on the real vault (fallback, liquidation during it, expiry at exactly 24 h, poke cap, R1 rollback) -> B6b rollback after use -> B7 manipulation -> B9 final read-back
// -> B11 PHAR distribution with the deployed market as the wrapper holder (LAST group; REH_WRAPPER=0 skips it). (B6a and B8 run right after B2 because they need the pristine, seeded, unused market; every
// scenario is wrapped in an evm snapshot and reverted.)
// Output: `PASS <id> <text>`, `FAIL <id> <text> :: <detail>`, `NOTE <id> <text>`; RESULTS json (REH_RESULTS); exit 0 when nothing FAILED, 1 otherwise (42 / 3 / 2 are set by rehearsal.sh).
import fs from "node:fs";
import path from "node:path";
import {
  ethers, utils, BN, BigNumber, A, C, LIVE, HERE, OUTDIR, check, note, group, finish, results, provider, rpc, log, impersonate, setErc20Balance, tx, expectRevert, codeOrRevert, addErrorAbi, decodeErr,
  decodeData, runProc, progress, blockNumber, etchFeed, setFeed, repin, warp, warpRaw, headTs, readFeed, scenario, touched, mocks, signer, mine, setStorage, sleep,
} from "./lib.mjs";
import { snapshot, diff, PATH_CONTRACTS } from "./readback.mjs";
import { runOutage, shareExpect, fallbackLeg } from "./outage.mjs";
import { runPhar, crossCheckModel } from "./phar.mjs";

const DRY = process.argv.includes("--dry");
const BP_OUT = process.env.BP_OUT || path.join(HERE, "..", "..", "..", "out_bpdlmm"); // THIS tree's ceremony build (rehearsal.sh always passes it)
const WRAPPER_ON = process.env.REH_WRAPPER !== "0";   // the PHAR step (B11) is ON unless REH_WRAPPER=0
const E18 = BN(10).pow(18), ZERO = ethers.constants.AddressZero;
const usd6 = (x) => (Number(BN(x)) / 1e6).toFixed(6);
const sh = (x) => BN(x).toString();
const lc = (a) => String(a).toLowerCase();

// ---------------------------------------------------------------------------------------------------------------- knobs (all overridable from the environment)
const KNOB = {
  seedShares: BN(process.env.BP_SEED_SHARES || 1_000_000),            // the permanent seed, in RAW shares (1.000000 share)
  minVaultSupply: BN(process.env.BP_MIN_VAULT_SUPPLY || 1_000_000),    // delegate _becomeImplementation(abi.encode(vault, minimumVaultSupply))
  initialExchangeRate: BN(process.env.BP_INITIAL_EXCHANGE_RATE || "200000000000000"), // 0.02 * 10^(18 + 6 - 8): shares have 6 decimals, pTokens 8
  pTokenDecimals: Number(process.env.BP_PTOKEN_DECIMALS || 8),
  name: process.env.BP_PTOKEN_NAME || "Peridot bpPHAR-USDC", symbol: process.env.BP_PTOKEN_SYMBOL || "bpPHAR-USDC",
  wrapperName: process.env.BP_WRAPPER_NAME || "PharaohDlmmShareOracle", delegateName: process.env.BP_DELEGATE_NAME || "PharaohBoostedDelegate",
  cf: BN(process.env.BP_CF || "500000000000000000"),                   // 50 %
  borrowCapShare: BN(process.env.BP_SHARE_BORROW_CAP || 1),            // cap 0 means UNLIMITED in this controller: the share market gets the smallest non-zero cap
  tool: process.env.BP_TOOL || "",                                     // A's ceremony tool (contracts/tools/bp-dlmm-ceremony.sh): deploy + verify-deployed + verify-listing + print-ledger-calls are run THROUGH it
  useTool: process.env.BP_USE_TOOL || "auto",                          // auto: use the tool when it and its pin file exist; 1: require it; 0: built-in deployment and encodings only
  addressesFile: process.env.BP_ADDRESSES_FILE || "",                  // optional: export BP_PTOKEN=.. BP_WRAPPER=.. BP_DELEGATE=.. written by the real deploy script
  deployCmd: process.env.BP_DEPLOY_CMD || "",                          // optional: command (run in BP_DEPLOY_CWD) that deploys through the REAL deploy script on the fork and writes BP_ADDRESSES_FILE
};

// ---------------------------------------------------------------------------------------------------------------- ABIs
const ERC20 = ["function balanceOf(address) view returns (uint256)", "function approve(address,uint256) returns (bool)", "function transfer(address,uint256) returns (bool)", "function allowance(address,address) view returns (uint256)", "function totalSupply() view returns (uint256)", "function decimals() view returns (uint8)", "function symbol() view returns (string)"];
const CTL = [
  "function oracle() view returns (address)", "function admin() view returns (address)", "function closeFactorMantissa() view returns (uint256)", "function liquidationIncentiveMantissa() view returns (uint256)",
  "function getAllMarkets() view returns (address[])", "function markets(address) view returns (bool,uint256,bool)", "function borrowCaps(address) view returns (uint256)", "function mintGuardianPaused(address) view returns (bool)",
  "function borrowGuardianPaused(address) view returns (bool)", "function borrowCashFloor(address) view returns (uint256)", "function checkMembership(address,address) view returns (bool)", "function getAssetsIn(address) view returns (address[])",
  "function enterMarkets(address[]) returns (uint256[])", "function exitMarket(address) returns (uint256)", "function getAccountLiquidity(address) view returns (uint256,uint256,uint256)",
  "function liquidateCalculateSeizeTokens(address,address,uint256) view returns (uint256,uint256)", "function seizeGuardianPaused() view returns (bool)", "function pauseGuardian() view returns (address)",
  "function _setPriceOracle(address) returns (uint256)", "function _supportMarket(address) returns (uint256)", "function _setCollateralFactor(address,uint256) returns (uint256)", "function _setMarketBorrowCaps(address[],uint256[])",
  "function _setBorrowPaused(address,bool) returns (bool)", "function _setMintPaused(address,bool) returns (bool)", "function _setBorrowCashFloor(address,uint256) returns (uint256)", "function isolatedMarginAccounts(address) view returns (bool)",
];
const PT = [
  "function mint(uint256) returns (uint256)", "function redeem(uint256) returns (uint256)", "function redeemUnderlying(uint256) returns (uint256)", "function borrow(uint256) returns (uint256)", "function repayBorrow(uint256) returns (uint256)",
  "function liquidateBorrow(address,uint256,address) returns (uint256)", "function balanceOf(address) view returns (uint256)", "function transfer(address,uint256) returns (bool)", "function approve(address,uint256) returns (bool)",
  "function totalSupply() view returns (uint256)", "function exchangeRateStored() view returns (uint256)", "function exchangeRateCurrent() returns (uint256)", "function getCash() view returns (uint256)", "function totalBorrows() view returns (uint256)",
  "function totalReserves() view returns (uint256)", "function borrowBalanceStored(address) view returns (uint256)", "function borrowBalanceCurrent(address) returns (uint256)", "function underlying() view returns (address)", "function admin() view returns (address)",
  "function peridottroller() view returns (address)", "function decimals() view returns (uint8)", "function symbol() view returns (string)", "function flashLoansPaused() view returns (bool)", "function maxFlashLoan(address) view returns (uint256)",
  "function flashLoan(address,address,uint256,bytes) returns (bool)", "function _setFlashLoansPaused(bool) returns (bool)", "function implementation() view returns (address)", "function protocolSeizeShareMantissa() view returns (uint256)",
  "function pharaohVault() view returns (address)", "function minimumVaultSupplyAtListing() view returns (uint256)", "function interestRateModel() view returns (address)", "function reserveFactorMantissa() view returns (uint256)", "function isPToken() view returns (bool)",
  "error MintPeridottrollerRejection(uint256 errorCode)", "error RedeemPeridottrollerRejection(uint256 errorCode)", "error BorrowPeridottrollerRejection(uint256 errorCode)", "error RepayBorrowPeridottrollerRejection(uint256 errorCode)",
  "error LiquidatePeridottrollerRejection(uint256 errorCode)", "error LiquidateSeizePeridottrollerRejection(uint256 errorCode)", "error TransferPeridottrollerRejection(uint256 errorCode)", "error BorrowCashNotAvailable()", "error LiquidateCloseAmountIsZero()",
  "error PharaohBoosted__SeedPending()", "error PharaohBoosted__InvalidConfiguration()", "error PharaohBoosted__InvalidVault()", "error PharaohBoosted__InsufficientVaultSeed()",
];
const ORACLE = ["function getUnderlyingPrice(address) view returns (uint256)", "function getPrice(address) view returns (uint256)", "function marketAsset(address) view returns (address)", "function baseOracle() view returns (address)",
  "function market() view returns (address)", "function vault() view returns (address)", "function vaultAsset() view returns (address)", "function getShareUsdPrice() view returns (uint256)", "function source() view returns (address)",
  // v2 wrapper (outputs unnamed on purpose: read by index, ethers v5 struct names collide with Array methods, e.g. `at`)
  "function shareState() view returns (uint256,uint256,uint64,bool,uint256)", "function poke() returns (bool)", "function lastGoodAssetsPerShare() view returns (uint128)", "function lastGoodTime() view returns (uint64)",
  "function FALLBACK_HAIRCUT_BPS() view returns (uint256)", "function FALLBACK_WINDOW() view returns (uint256)", "function POKE_MAX_UP_BPS() view returns (uint256)", "function POKE_UP_INTERVAL() view returns (uint256)",
  "function shareDecimals() view returns (uint8)", "function assetDecimals() view returns (uint8)", "event FallbackPriceStored(uint256 assetsPerShare, uint256 at)"];
const FEEDX = ["function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)", "function decimals() view returns (uint8)", "function description() view returns (string)", "function aggregator() view returns (address)"];
const SRCX = ["function feeds(address) view returns (address,uint32,uint8,bool)", "function marketAsset(address) view returns (address)", "function assetDecimals(address) view returns (uint8)"];
/** smallest block in [lo, hi] at which `addr` has code (null when it has none at hi): where a contract was created, by bisection on eth_getCode of the local chain */
async function firstBlockWithCode(addr, lo, hi) {
  if (hi < lo || (await provider.getCode(addr, hi)) === "0x") return null;
  while (lo < hi) { const mid = Math.floor((lo + hi) / 2); if ((await provider.getCode(addr, mid)) === "0x") lo = mid + 1; else hi = mid; }
  return lo;
}
const VAULT = [
  "function owner() view returns (address)", "function paused() view returns (bool)", "function asset() view returns (address)", "function decimals() view returns (uint8)", "function totalSupply() view returns (uint256)", "function totalAssets() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)", "function convertToAssets(uint256) view returns (uint256)", "function convertToShares(uint256) view returns (uint256)", "function maxDeposit(address) view returns (uint256)", "function depositCap() view returns (uint256)",
  "function deposit(uint256,address) returns (uint256)", "function redeem(uint256,address,address) returns (uint256)", "function redeemInKind(uint256,address,address) returns (uint256,uint256)", "function approve(address,uint256) returns (bool)", "function transfer(address,uint256) returns (bool)",
  "function guardState() view returns (bool,bool,uint256)", "function guardParams() view returns (tuple(uint16 legBandBps,uint32 maxFeedAge,uint16 maxPoolOracleDevBps,uint32 rebalanceCooldown,uint16 maxRebalancesPerDay,uint16 maxSwapBps,uint16 maxRebalanceLossBps))",
  "function bandState() view returns (uint24,uint24,uint24,bool,bool)", "function feedAsset() view returns (address)", "function feedPair() view returns (address)", "function pair() view returns (address)", "function router() view returns (address)",
  "function pairToken() view returns (address)", "function tripGuard()", "function tokenX() view returns (address)", "function tokenY() view returns (address)",
  "error CapExceeded(uint256 cap,uint256 totalAssetsAfter)", "error GuardLatched()", "error GuardUnsafe(uint256 reasons)", "error FeedInvalid(uint8 which)", "error ZeroShares()", "error SupplyBelowMinimum(uint256 resultingSupply)", "error EnforcedPause()", "error ZeroAmount()",
  "error ERC4626ExceededMaxRedeem(address owner,uint256 shares,uint256 max)", "error ExitFailed()", "error GuardStillUnsafe(uint256 reasons)",
];
const PAIR = ["function getActiveId() view returns (uint24)", "function getBin(uint24) view returns (uint128,uint128)", "function balanceOf(address,uint256) view returns (uint256)", "function totalSupply(uint256) view returns (uint256)", "function burn(address,address,uint256[],uint256[]) returns (bytes32[])", "function getBinStep() view returns (uint16)"];
const DLMM_ROUTER = ["function swapExactTokensForTokens(uint256,uint256,(uint256[] pairBinSteps,uint8[] versions,address[] tokenPath),address,uint256) returns (uint256)"];
const EXEC = ["function nextPositionId() view returns (uint256)", "function positions(uint256) view returns (uint256 id,address owner,address account,address marginPToken,address positionPToken,address debtPToken,uint256 lockedMarginPTokens,uint256 initialNotionalUsd,uint256 borrowedPrincipal,uint16 requestedLeverageX100,uint8 side,uint8 status)",
  "function openPosition(tuple(address marginPToken,address positionPToken,address debtPToken,uint256 marginPTokenAmount,uint16 leverageX100,uint256 maxOpeningFeePToken,uint256 minPositionUnderlying,uint8 side,bytes swapData)) returns (uint256)", "error ExecutorError(uint8 code)"];
const REG = ["function createOrder(uint256,uint8,bool,uint256,uint16,uint16,uint64) returns (uint256)", "function executeOrder(uint256,bytes) returns (bool)", "function nextOrderId() view returns (uint256)", "function adapter() view returns (address)",
  "function getOrder(uint256) view returns (tuple(uint256 positionId,address owner,uint8 kind,bool triggerAbove,uint256 triggerPriceE18,uint16 closeBps,uint16 maxSlippageBps,uint64 expiry,uint64 createdAt,uint64 updatedAt,uint8 status))",
  "error InvalidOrder(uint8)", "error NotPositionOwner()", "error TriggerNotReached(uint256,uint256)", "error OrderNotOpen()"];
const RISK = ["function getMetrics(address) view returns (tuple(uint256 grossAssetValueUsd,uint256 debtValueUsd,int256 equityUsd,uint256 initialRequirementUsd,uint256 maintenanceRequirementUsd,uint256 healthFactorBps,uint256 leverageX100))", "function oracle() view returns (address)", "function isLiquidatable(address) view returns (bool)"];
const QUOTER = ["function quoteOpen(address,address,address,uint256,uint16) view returns (uint256 flashAmount,uint256 minPositionUnderlying)", "function oracle() view returns (address)"];
const MVAULT = ["function deposit(address,uint256)"];
const POOL = ["function slot0() view returns (uint160,int24,uint16,uint16,uint16,uint24,bool)"];
const CLROUTER = ["function exactInputSingle(tuple(address tokenIn,address tokenOut,int24 tickSpacing,address recipient,uint256 deadline,uint256 amountIn,uint256 amountOutMinimum,uint160 sqrtPriceLimitX96)) returns (uint256)"];
for (const a of [PT, VAULT, REG, EXEC]) addErrorAbi(a.filter((x) => x.startsWith("error")));

// ---------------------------------------------------------------------------------------------------------------- artifacts (forge out dir of subagent A) and the deployment of the NEW contracts
function artifact(name) {
  const f = path.join(BP_OUT, `${name}.sol`, `${name}.json`);
  if (!fs.existsSync(f)) throw new Error(`artifact ${f} missing (cd to the forge project of subagent A and run: forge build --skip test; or set BP_OUT)`);
  const j = JSON.parse(fs.readFileSync(f, "utf8"));
  return { abi: j.abi, bytecode: typeof j.bytecode === "string" ? j.bytecode : j.bytecode.object, deployed: typeof j.deployedBytecode === "string" ? j.deployedBytecode : j.deployedBytecode.object };
}
/** constructor arguments resolved BY NAME from a dictionary (so a renamed or extended constructor of A fails loudly, naming the argument, instead of silently misdeploying) */
function ctorArgs(abi, dict, label) {
  const ctor = abi.find((x) => x.type === "constructor"); if (!ctor) return [];
  const over = process.env[`BP_CTOR_${label.toUpperCase()}`]; if (over) return JSON.parse(over);
  return ctor.inputs.map((inp) => {
    const n = inp.name.replace(/_$/, "");
    if (!(n in dict)) throw new Error(`constructor of ${label}: no value for argument "${inp.name}" (${inp.type}); set BP_CTOR_${label.toUpperCase()}='[...]' (JSON array in constructor order) or extend the dictionary in rehearsal.mjs`);
    return dict[n];
  });
}
let D = {}; // deployed addresses: PBP (market), WRAPPER, DELEGATE
async function deployFromArtifact(name, dict, deployer) {
  const art = artifact(name);
  const f = new ethers.ContractFactory(art.abi, art.bytecode, signer(deployer));
  const args = ctorArgs(art.abi, dict, name);
  const c = await f.deploy(...args, {});
  const r = await c.deployTransaction.wait(); results.gas[`deploy ${name}`] = r.gasUsed.toNumber();
  return c.address;
}

// ---------------------------------------------------------------------------------------------------------------- the ceremony: the Ledger transactions of A's call list (contracts/avalanche_bp_dlmm_ceremony_calls.md)
// ONE table. Source of truth when A's tool is used: the calldata printed by `bp-dlmm-ceremony.sh print-ledger-calls rehearsal` (the very bytes the Ledger signs); the harness ALSO encodes every call itself from
// its own ABIs and asserts the two are identical (B0.t5). Without the tool the harness's own encodings are used. Compound-style admin functions RETURN an error code instead of reverting: each call is made
// statically first (code-returning calls must give 0), then sent from the impersonated Ledger, then traced for the contracts it wrote.
// The harness identifies each transaction SEMANTICALLY (oracleSwap | capSet, list, borrowPause | approveSeed, mintSeed, seedToDead, mintPause | mintOpen, setCF | rollback) and takes the ORDER within a stage and the
// T-numbers from the tool, so a reordering inside A's tool (it changed once while this was written: the borrow cap now comes BEFORE listing) cannot desynchronise the rehearsal; a transaction added, removed or
// changed in the tool fails B0.t5 by name.
const SEED_PTOKENS = () => KNOB.seedShares.mul(5000); // initial exchange rate 2e14: 1 share-wei = 5000 pToken-wei
function ownCalls() {
  const ctl = new utils.Interface(CTL), pt = new utils.Interface(PT), v = new utils.Interface(VAULT);
  const enc = (i, fn, ...args) => i.encodeFunctionData(fn, args);
  const P = D.PBP || A("BB01"), W = D.WRAPPER || A("BB02");
  return {
    oracleSwap: { label: "controller._setPriceOracle(wrapper)", to: LIVE.CONTROLLER, data: enc(ctl, "_setPriceOracle", W), stage: 1, code0: true },
    capSet: { label: "controller._setMarketBorrowCaps([market],[1])", to: LIVE.CONTROLLER, data: enc(ctl, "_setMarketBorrowCaps", [P], [KNOB.borrowCapShare]), stage: 2 },
    list: { label: "controller._supportMarket(market)", to: LIVE.CONTROLLER, data: enc(ctl, "_supportMarket", P), stage: 2, code0: true },
    borrowPause: { label: "controller._setBorrowPaused(market, true)", to: LIVE.CONTROLLER, data: enc(ctl, "_setBorrowPaused", P, true), stage: 2 },
    approveSeed: { label: "vault.approve(market, seed)", to: LIVE.VAULT, data: enc(v, "approve", P, KNOB.seedShares), stage: 3 },
    mintSeed: { label: "market.mint(seed)", to: P, data: enc(pt, "mint", KNOB.seedShares), stage: 3, code0: true },
    seedToDead: { label: "market.transfer(0xdEaD, seed pTokens)", to: P, data: enc(pt, "transfer", LIVE.DEAD, SEED_PTOKENS()), stage: 3 },
    mintPause: { label: "controller._setMintPaused(market, true)", to: LIVE.CONTROLLER, data: enc(ctl, "_setMintPaused", P, true), stage: 3 },
    mintOpen: { label: "controller._setMintPaused(market, false)", to: LIVE.CONTROLLER, data: enc(ctl, "_setMintPaused", P, false), stage: 4 },
    setCF: { label: "controller._setCollateralFactor(market, 50 %)", to: LIVE.CONTROLLER, data: enc(ctl, "_setCollateralFactor", P, KNOB.cf), stage: 4, code0: true },
    rollback: { label: "controller._setPriceOracle(guarded oracle)  [ROLLBACK]", to: LIVE.CONTROLLER, data: enc(ctl, "_setPriceOracle", LIVE.GUARDED_ORACLE), stage: "rollback", code0: true },
  };
}
let CER = {}; // semantic key -> { id (the tool's T-number when the tool is used), label, to, data, stage, code0 }
const DEFAULT_ORDER = { 1: ["oracleSwap"], 2: ["capSet", "list", "borrowPause"], 3: ["approveSeed", "mintSeed", "mintPause", "seedToDead"], 4: ["mintOpen", "setCF"] };
/** the keys of a stage in the order the Ledger will sign them (the tool's T-numbers when the tool is used, else A's documented order) */
const orderOf = (stage) => Object.entries(CER).filter(([, c]) => c.stage === stage).sort((x, y) => (x[1].tnum ?? DEFAULT_ORDER[stage].indexOf(x[0])) - (y[1].tnum ?? DEFAULT_ORDER[stage].indexOf(y[0]))).map(([k]) => k);
/** parse `print-ledger-calls rehearsal` output: blocks "# ---- <id> <label>", "# calldata (compare with the device): 0x..", "cast send --unlocked --from <ledger> <target> ..." */
function parseLedgerCalls(text) {
  const out = {}; let cur = null;
  for (const line of text.split("\n")) {
    let m = /^# ---- (T\d+|R\d+) (.*)$/.exec(line); if (m) { cur = { id: m[1], label: m[2], data: null, to: null, from: null }; out[m[1]] = cur; continue; }
    if (!cur) continue;
    m = /^# calldata \(compare with the device\): (0x[0-9a-fA-F]*)/.exec(line); if (m) { cur.data = m[1]; continue; }
    m = /^cast send --(?:unlocked|ledger) --from (0x[0-9a-fA-F]{40}) (0x[0-9a-fA-F]{40}) /.exec(line); if (m) { cur.from = utils.getAddress(m[1]); cur.to = utils.getAddress(m[2]); }
  }
  return out;
}
const ledgerSigner = () => signer(LIVE.LEDGER);
const touchedByStep = {};
async function runStep(s) {
  const data = s.data;
  let ret;
  progress(`ceremony step ${s.id} ${s.label}: static call from the Ledger`);
  try { ret = await provider.call({ from: LIVE.LEDGER, to: s.to, data }); }
  catch (e) { throw new Error(`${s.id} ${s.label}: static call reverted: ${decodeErr(e)}`); }
  if (s.code0 && ret && ret.length === 66 && !BN(ret).eq(0)) throw new Error(`${s.id} ${s.label}: returned error code ${BN(ret)} (see ErrorReporter.sol)`);
  progress(`ceremony step ${s.id} ${s.label}: static call ok (${ret && ret.length === 66 ? "code " + BN(ret) : "no code"}), sending`);
  const r = await tx(`${s.id} ${s.label}`, (o) => ledgerSigner().sendTransaction({ to: s.to, data, ...o }));
  progress(`ceremony step ${s.id} ${s.label}: mined in block ${r.blockNumber}, tracing the contracts it wrote`);
  touchedByStep[s.id] = await touched(r.transactionHash);
  progress(`ceremony step ${s.id} ${s.label}: done (trace ${touchedByStep[s.id].mode}, ${touchedByStep[s.id].addresses.length} addresses)`);
  return r;
}
const step = (key) => ({ ...CER[key], id: CER[key].id || key });
// A's ceremony tool (when present): run THROUGH it against the local fork (endpoint = the local anvil only)
let TOOL_ON = false, ADDR_FILE = "";
async function toolRun(args, extra = {}) {   // ASYNC, stdin closed, own timeout, tracked: the heartbeat / watchdog stay alive while the tool runs (run 1 went silent here)
  const r = await runProc("bash", [KNOB.tool, ...args], { timeoutMs: (Number(process.env.REH_TOOL_TIMEOUT_MS) || 25 * 60 * 1000), label: `ceremony tool ${args.join(" ")}`,
    env: { PATH: process.env.PATH, HOME: process.env.HOME, ETH_RPC_URL: process.env.REH_RPC, BP_ADDRESSES_FILE: ADDR_FILE, FOUNDRY_DISABLE_NIGHTLY_WARNING: "1", ...extra } });
  fs.writeFileSync(path.join(OUTDIR, `tool-${args.join("-")}.log`), r.out);
  return { code: r.code, out: r.out };
}
const toolCheck = async (id, label, args, okText, extra = {}) => { if (!TOOL_ON) return; const r = await toolRun(args, extra); check(id, r.code === 0 && okText.test(r.out), label, r.out.split("\n").slice(-6).join(" | ")); };

// ---------------------------------------------------------------------------------------------------------------- DRY mode: everything that can be checked without a chain
if (DRY) {
  const out = [];
  const ok = (m) => out.push(`DRY ok   ${m}`); const bad = (m) => { out.push(`DRY FAIL ${m}`); process.exitCode = 1; };
  try {
    for (const [k, v] of Object.entries(LIVE)) utils.getAddress(v); ok(`${Object.keys(LIVE).length} live addresses parse and checksum`);
    for (const [n, abi] of Object.entries({ CTL, PT, ORACLE, FEEDX, SRCX, VAULT, PAIR, DLMM_ROUTER, EXEC, REG, RISK, QUOTER, POOL, CLROUTER, ERC20 })) { const i = new utils.Interface(abi); ok(`Interface ${n}: ${Object.keys(i.functions).length} functions, ${Object.keys(i.errors).length} errors`); }
    const w = artifact(KNOB.wrapperName), d = artifact(KNOB.delegateName), g = artifact("PErc20Delegator");
    ok(`artifacts in ${BP_OUT}: ${KNOB.wrapperName} (${w.abi.filter((x) => x.type === "function").length} fns), ${KNOB.delegateName}, PErc20Delegator`);
    { // the artifact must be the v2 wrapper (run 1 used v1): ABI, runtime size, and the arithmetic helpers of the outage group
      const names = new Set(w.abi.filter((x) => x.type === "function").map((x) => x.name)), need = ["shareState", "poke", "lastGoodAssetsPerShare", "lastGoodTime", "FALLBACK_HAIRCUT_BPS", "FALLBACK_WINDOW", "POKE_MAX_UP_BPS", "POKE_UP_INTERVAL"];
      const miss = need.filter((n) => !names.has(n)); if (miss.length) bad(`the wrapper artifact is not v2: missing ${miss.join(", ")}`); else ok(`wrapper artifact is v2: ${need.join(", ")} in the ABI`);
      const size = (w.deployed.length - 2) / 2, want = Number(process.env.BP_WRAPPER_RUNTIME || 3628);
      if (size !== want) bad(`wrapper runtime size ${size} bytes in ${BP_OUT}, expected ${want} (BP_WRAPPER_RUNTIME): another build / profile`); else ok(`wrapper runtime size ${size} bytes (v2: ${want}), under 24,576`);
      const iface = new utils.Interface(ORACLE); const probe = ["shareState", "poke", "lastGoodAssetsPerShare", "lastGoodTime"].every((n) => iface.getFunction(n).format() && w.abi.some((x) => x.name === n && x.inputs.length === iface.getFunction(n).inputs.length && x.outputs.length === iface.getFunction(n).outputs.length));
      if (!probe) bad("the harness ABI of the wrapper (shareState/poke/lastGood*) does not match the artifact's input/output counts"); else ok("harness ABI of shareState/poke/lastGoodAssetsPerShare/lastGoodTime matches the artifact's arity");
      const ss = w.abi.find((x) => x.name === "shareState"); if (ss && ss.outputs.map((o) => o.type).join(",") === "uint256,uint256,uint64,bool,uint256") ok("shareState() output types uint256,uint256,uint64,bool,uint256 (read by index)"); else bad("shareState() output types differ from the harness ABI");
      if (shareExpect(1_000_000, E18).eq(BN(10).pow(30)) && fallbackLeg(1_000_000).eq(970_000) && fallbackLeg(3).eq(2)) ok("outage helpers: share price of 1 share at $1 = 1e30, fallback leg = floor(stored x 0.97)"); else bad("outage helper arithmetic");
    }
    const P = A("BB01");
    const dict = { baseOracle: LIVE.GUARDED_ORACLE, base: LIVE.GUARDED_ORACLE, market: P, pToken: P, owner: LIVE.LEDGER, vault: LIVE.VAULT, source: LIVE.SOURCE_ORACLE };
    const wa = ctorArgs(w.abi, dict, KNOB.wrapperName); ok(`wrapper constructor arguments resolved: ${w.abi.find((x) => x.type === "constructor").inputs.map((x) => x.name).join(", ")}`);
    new utils.Interface(g.abi).encodeDeploy([LIVE.VAULT, LIVE.CONTROLLER, LIVE.RATE_MODEL, KNOB.initialExchangeRate, KNOB.name, KNOB.symbol, KNOB.pTokenDecimals, LIVE.LEDGER, A("DE1E"), utils.defaultAbiCoder.encode(["address", "uint256"], [LIVE.VAULT, KNOB.minVaultSupply])]);
    ok("PErc20Delegator constructor encodes");
    D = { PBP: P, WRAPPER: A("BB02"), DELEGATE: A("DE1E") };
    CER = ownCalls(); for (const s of Object.values(CER)) utils.hexlify(s.data);
    ok(`ceremony table: ${Object.keys(CER).length} Ledger calls encode: ${Object.keys(CER).join(" ")}`);
    const pl = parseLedgerCalls("# ---- T1 x\n# calldata (compare with the device): 0xabcd\ncast send --unlocked --from 0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD 0xbE938cD7C25E0E4d0604Fa3F9f0a8b5b67b3D51A '_setPriceOracle(address)' '0x1'\n");
    if (pl.T1?.data === "0xabcd" && pl.T1.to === LIVE.CONTROLLER) ok("print-ledger-calls parser reads a sample block"); else bad("print-ledger-calls parser");
    if (KNOB.tool && fs.existsSync(KNOB.tool)) { // A's tool prints calldata without any network: compare it with the harness's own encoding, with placeholder addresses
      const af = path.join(process.env.TMPDIR || "/tmp", `bp-dry-addresses-${process.pid}.env`);
      fs.writeFileSync(af, `export BP_DELEGATE=${A("DE1E")}\nexport BP_MARKET=${D.PBP}\nexport BP_ORACLE=${D.WRAPPER}\n`); ADDR_FILE = af;
      const r = await toolRun(["print-ledger-calls", "rehearsal"]); fs.rmSync(af, { force: true });
      const pl2 = Object.values(parseLedgerCalls(r.out)), diffs = [], used = new Set();
      for (const [key, c] of Object.entries(CER)) { const t = pl2.find((x) => x.data && x.data.toLowerCase() === c.data.toLowerCase() && x.to.toLowerCase() === c.to.toLowerCase()); if (!t) diffs.push(`${key}: not printed by the tool`); else used.add(t.id); }
      for (const t of pl2) if (!used.has(t.id)) diffs.push(`${t.id} (${t.label}): printed by the tool but unknown to the harness`);
      if (diffs.length) bad(`tool print-ledger-calls differs from the harness encoding: ${diffs.join("; ")}`); else ok(`A's tool print-ledger-calls: calldata AND target of all ${Object.keys(CER).length} Ledger transactions (${pl2.map((x) => x.id).join(" ")}) match the harness's independent encoding one-to-one (offline, placeholder addresses)`);
    } else ok("A's ceremony tool not found: calldata cross-check skipped (BP_TOOL)");
    const srcFiles = ["rehearsal.mjs", "outage.mjs", "phar.mjs"], idsBy = {}, ids = [];
    for (const f of srcFiles) { const src = fs.readFileSync(path.join(HERE, f), "utf8"); idsBy[f] = [...new Set([...src.matchAll(/\b(?:check|note)\(\s*[`"'](B[0-9a-z.]+)[`"']/g)].map((m) => m[1]))].sort(); ids.push(...idsBy[f]); }
    const dup = ids.filter((x, i) => ids.indexOf(x) !== i); if (dup.length) bad(`check ids used twice: ${[...new Set(dup)].join(" ")}`);
    const readme = fs.readFileSync(path.join(HERE, "README.md"), "utf8");
    const missing = [...new Set(ids)].filter((i) => !readme.includes(`\`${i}\``));
    ok(`${new Set(ids).size} check ids (${srcFiles.map((f) => `${f}: ${idsBy[f].length}`).join(", ")})`); if (missing.length) bad(`README.md does not list: ${missing.join(" ")}`); else ok("README.md lists every check id");
    if (WRAPPER_ON) { // the PHAR step: its inputs and an offline cross-check of the expected-split model against the generator's own exported function
      const proj = process.env.REH_REWARDS_PROJ || "";
      const gfile = path.join(proj, "tools", "dlmm-rewards-root.mjs");
      if (!proj || !fs.existsSync(gfile)) bad(`REH_WRAPPER is on but the generator is not at ${gfile}`);
      else {
        process.env.ETHERS_DIR = path.join(process.env.REH_ETHERS_DIR, "node_modules", "ethers");
        const R = await import(gfile);
        const cc = crossCheckModel(R); if (cc.ok) ok(`PHAR: the harness's expected-split model equals the generator's wrapperSplit on ${cc.cases} random histories (offline)`); else bad(`PHAR: model != generator: ${cc.detail}`);
        const wf = R.parseWrappersFile({ schema: R.WRAPPERS_SCHEMA, wrappers: [{ pToken: A("BB01"), underlying: LIVE.VAULT, fromBlock: 100500000, label: "bpPHAR-USDC (deployed by this run)" }] }, { vault: LIVE.VAULT });
        if (wf.length === 1 && wf[0].fromBlock === 100500000) ok("PHAR: a wrappers.json for the deployed market parses with the generator's own parser"); else bad("PHAR: wrappers.json sample");
        for (const t of [["dlmm-rewards-ceremony.sh"], ["dlmm-rewards-safe-call.sh"]]) if (!fs.existsSync(path.join(proj, "tools", t[0]))) bad(`missing ${t[0]}`);
        if (/^\d+$/.test(process.env.REH_SCAN_FROM || "")) ok(`PHAR: REH_SCAN_FROM=${process.env.REH_SCAN_FROM}`); else out.push("DRY WARN PHAR: REH_SCAN_FROM is not set (the real run refuses to start without it)");
      }
    } else ok("PHAR step skipped (REH_WRAPPER=0): B11 is not run");
  } catch (e) { bad(String(e?.message || e)); }
  console.log(out.join("\n")); process.exit(process.exitCode || 0);
}

// ================================================================================================================ the chain starts here
if (process.env.REH_SELFTEST !== "1") await main();
async function main() {
  const ctl = C(LIVE.CONTROLLER, CTL), vault = C(LIVE.VAULT, VAULT), guarded = C(LIVE.GUARDED_ORACLE, ORACLE), usdc = C(LIVE.USDC, ERC20), usdt = C(LIVE.USDT, ERC20);
  const pU = C(LIVE.PUSDC, PT), pW = C(LIVE.PWAVAX, PT);
  const risk = C(LIVE.M_RISK_ENGINE, RISK), quoter = C(LIVE.M_QUOTER, QUOTER), exec = C(LIVE.M_EXECUTOR, EXEC), reg = C(LIVE.M_REGISTRY, REG);
  const pb = () => C(D.PBP, PT), wr = () => C(D.WRAPPER, ORACLE);
  const sharePps = async () => (await vault.convertToAssets(1_000_000)); // USDC raw per 1 whole share (1e6 raw)
  const ledger = () => signer(LIVE.LEDGER);
  const ageOf = async (f) => (await readFeed(f)).age;
  let S0, price0 = {}, deployerAddr = A("DE17");

  // ============================================================================================================ B0 pre-flight and deployment
  await group("B0 pre-flight and deployment", async () => {
    check("B0.1", (await provider.getNetwork()).chainId === 43114 && !!(await rpc("anvil_nodeInfo")), `local anvil fork, chain id 43114, pinned block ${process.env.REH_PIN} (head ${await blockNumber()})`);
    // deterministic time: every block is exactly 1 s after the previous one, so the REAL feeds (AVAX maxAge 1200 s) cannot go stale during B1 however long the run takes
    try { await rpc("anvil_setBlockTimestampInterval", [1]); note("B0.n1", "block timestamp interval set to 1 s (deterministic time for the real-feed comparison in B1)"); } catch (e) { note("B0.n1", `anvil_setBlockTimestampInterval unavailable (${String(e.message).slice(0, 60)}): B1 relies on wall-clock time`); }
    await impersonate(LIVE.LEDGER); await impersonate(LIVE.SAFE); await impersonate(deployerAddr);
    const codeless = []; for (const [k, v] of Object.entries(LIVE)) if (!["LEDGER", "SAFE", "DEAD", "KEEPER_WALLET"].includes(k) && (await provider.getCode(v)) === "0x") codeless.push(k);
    check("B0.2", codeless.length === 0, `every live contract address has code (${Object.keys(LIVE).length} addresses)`, codeless.join(","));
    check("B0.3", (await ctl.oracle()) === LIVE.GUARDED_ORACLE && (await ctl.admin()) === LIVE.LEDGER && (await guarded.source()) === LIVE.SOURCE_ORACLE, `controller.oracle() = the guarded oracle ${LIVE.GUARDED_ORACLE}, controller admin = the Ledger, guarded.source = ${LIVE.SOURCE_ORACLE}`);
    check("B0.4", (await ctl.closeFactorMantissa()).eq(E18.div(2)) && (await ctl.liquidationIncentiveMantissa()).eq(BN("1080000000000000000")), "closeFactor 50 %, liquidation incentive 108 %");
    const mU = await ctl.markets(LIVE.PUSDC), mW = await ctl.markets(LIVE.PWAVAX);
    check("B0.5", mU[0] && mW[0] && mW[1].eq(BN("300000000000000000")) && mU[1].eq(0) && (await ctl.borrowCaps(LIVE.PUSDC)).eq(200_000_000) && (await ctl.borrowGuardianPaused(LIVE.PWAVAX)) && (await ctl.borrowCashFloor(LIVE.PUSDC)).eq(50_000_000),
      `pWAVAX CF 30 % borrow paused; pUSDC CF 0, borrow cap 200 USDC, cash floor 50 USDC (pUSDC cash ${usd6(await pU.getCash())}, borrows ${usd6(await pU.totalBorrows())} USDC)`);
    const mk = await ctl.getAllMarkets(); check("B0.6", mk.length === 2, `exactly the two existing markets are listed (${mk.length})`);
    const [tS, tA] = [await vault.totalSupply(), await vault.totalAssets()];
    check("B0.7", (await vault.asset()) === LIVE.USDC && (await vault.decimals()) === 6 && (await vault.owner()) === LIVE.SAFE && (await vault.feedAsset()) === LIVE.USDC_FEED && (await vault.feedPair()) === LIVE.USDT_FEED && (await vault.pair()) === LIVE.VAULT_PAIR && (await vault.router()) === LIVE.VAULT_ROUTER,
      "DLMM vault: asset USDC, 6 decimals, owner = the Safe, feeds = the live USDC/USDT feeds, pair and router as pinned");
    check("B0.8", (await vault.balanceOf(LIVE.LEDGER)).eq(16_000_000) && (await vault.balanceOf(LIVE.DEAD)).eq(1_000_000) && tS.eq(17_000_000),
      `share holders: Ledger ${sh(await vault.balanceOf(LIVE.LEDGER))}, dead ${sh(await vault.balanceOf(LIVE.DEAD))}, total ${sh(tS)} (state moved since the brief if this fails)`);
    const gs = await vault.guardState(), gp = await vault.guardParams();
    note("B0.n2", `vault: totalAssets ${usd6(tA)} USDC, depositCap ${usd6(await vault.depositCap())}, paused ${await vault.paused()}, guard unsafe=${gs[0]} latched=${gs[1]} reasons=${gs[2]}, maxDeposit ${usd6(await vault.maxDeposit(LIVE.LEDGER))}, maxFeedAge ${gp.maxFeedAge}s, legBand ${gp.legBandBps}bp, poolDev ${gp.maxPoolOracleDevBps}bp`);
    const ages = { AVAX: await ageOf(LIVE.AVAX_FEED), USDC: await ageOf(LIVE.USDC_FEED), USDT: await ageOf(LIVE.USDT_FEED) };
    check("B0.9", ages.AVAX < 600 && ages.USDC < 90_000 - 3600 && ages.USDT < gp.maxFeedAge - 3600, `real feeds are fresh with margin at the pin (age s: AVAX ${ages.AVAX} (maxAge 1200), USDC ${ages.USDC} (maxAge 90000), USDT ${ages.USDT} (vault maxFeedAge ${gp.maxFeedAge})); a stale feed would make B1 compare 0 with 0 - re-run if this fails`);
    // ---- B0.f: the REAL feeds behind the vault and behind the base oracle, read and PRINTED (evidence; the mocks of B1.n2 do not exist yet). Decides whether re-pinning the USDC feed fresh also refreshes the vault's asset leg.
    {
      const facts = async (addr) => {
        const f = C(addr, FEEDX), r = await f.latestRoundData(), ts = await headTs();
        return { addr, roundId: r[0].toString(), answer: r[1].toString(), updatedAt: r[3].toNumber(), answeredInRound: r[4].toString(), age: ts - r[3].toNumber(), decimals: await f.decimals(), description: await f.description().catch(() => "n/a"), aggregator: await f.aggregator().catch(() => "n/a") };
      };
      const src = C(LIVE.SOURCE_ORACLE, SRCX);
      const keyU = await guarded.marketAsset(LIVE.PUSDC), keyW = await guarded.marketAsset(LIVE.PWAVAX);
      const bU = await src.feeds(keyU), bW = await src.feeds(keyW);           // (feed, maxAge, feedDecimals, enabled), read by index
      const vFA = await vault.feedAsset(), vFP = await vault.feedPair();
      const fVA = await facts(vFA), fVP = await facts(vFP), fBU = await facts(bU[0]), fBW = await facts(bW[0]);
      const line = (n, f, extra = "") => `${n}: ${f.addr} | ${f.description} | answer ${f.answer} (${f.decimals} dec) | updatedAt ${f.updatedAt} (age ${f.age} s) | round ${f.roundId}/${f.answeredInRound} | aggregator ${f.aggregator}${extra}`;
      results.data.feedEvidence = { vaultFeedAsset: fVA, vaultFeedPair: fVP, baseUsdc: { ...fBU, maxAge: bU[1], enabled: bU[3], asset: keyU }, baseAvax: { ...fBW, maxAge: bW[1], enabled: bW[3], asset: keyW }, vaultMaxFeedAge: gp.maxFeedAge, vaultGuard: { legBandBps: gp.legBandBps, maxPoolOracleDevBps: gp.maxPoolOracleDevBps } };
      check("B0.f1", lc(keyU) === lc(LIVE.USDC) && lc(keyW) === lc(LIVE.WAVAX) && bU[3] === true && bW[3] === true && [fVA, fVP, fBU, fBW].every((f) => BN(f.answer).gt(0) && f.updatedAt > 0 && f.age >= 0),
        `evidence readable: the base oracle's feeds for USDC and WAVAX are enabled, and the vault's feedAsset / feedPair and both base feeds all answer (answer > 0, updatedAt > 0)`);
      note("B0.f2", `VAULT ${line("feedAsset", fVA)}`); note("B0.f3", `VAULT ${line("feedPair", fVP)} | maxFeedAge ${gp.maxFeedAge} s (a feed older than that makes totalAssets/convertToAssets revert FeedInvalid)`);
      note("B0.f4", `BASE ORACLE USDC (key ${keyU}) ${line("feed", fBU)} | maxAge ${bU[1]} s | feed decimals ${bU[2]} | enabled ${bU[3]}`); note("B0.f5", `BASE ORACLE WAVAX (key ${keyW}) ${line("feed", fBW)} | maxAge ${bW[1]} s | feed decimals ${bW[2]} | enabled ${bW[3]}`);
      const sameFeed = lc(vFA) === lc(bU[0]), sameAgg = sameFeed || (fVA.aggregator !== "n/a" && lc(fVA.aggregator) === lc(fBU.aggregator)), sameRound = fVA.roundId === fBU.roundId && fVA.answer === fBU.answer && fVA.updatedAt === fBU.updatedAt;
      check("B0.f6", sameFeed && lc(bW[0]) === lc(LIVE.AVAX_FEED) && lc(bU[0]) === lc(LIVE.USDC_FEED) && lc(vFP) === lc(LIVE.USDT_FEED),
        `THE HARNESS'S MOCK MODEL HOLDS: the vault's USDC feed (${vFA}) is the SAME contract as the base oracle's USDC feed (${bU[0]}), so ONE re-pinned mock at that address refreshes both the vault's asset leg and pUSDC / the wrapper's USDC price; the AVAX feed and the USDT feed are the pinned ones. If this fails the outage and stale-feed groups would test the wrong thing`,
        `vault feedAsset ${vFA} vs base USDC feed ${bU[0]} (same aggregator contract: ${sameAgg}, same round: ${sameRound})`);
      note("B0.f7", `VERDICT: the vault's USDC/USD feed ${sameFeed ? "IS the same contract" : sameAgg ? "is a different proxy on the same aggregator" : "is NOT the same contract / aggregator"} as the base oracle's USDC/USD feed (latest round identical: ${sameRound}). ${sameFeed ? "Re-pinning USDC fresh therefore refreshes the vault's asset leg AND the base oracle's USDC price (pUSDC, the wrapper's USDC factor) together. The base oracle's maxAge (" + bU[1] + " s) is shorter than the vault's maxFeedAge (" + gp.maxFeedAge + " s): a stale USDC feed makes pUSDC and the wrapper price 0 first, the vault's asset leg is never the first to fail.": "Re-pinning must refresh BOTH feeds separately."} Ages now: vault asset ${fVA.age} s, vault pair ${fVP.age} s, base USDC ${fBU.age} s, base AVAX ${fBW.age} s.`);
    }
    check("B0.10", (await risk.oracle()) === LIVE.GUARDED_ORACLE && (await quoter.oracle()) === LIVE.GUARDED_ORACLE, "the margin stack holds ITS OWN oracle pointer = the guarded oracle (risk engine and quoter); it does not read controller.oracle()");
    const next = (await exec.nextPositionId()).toNumber(), nextO = (await reg.nextOrderId()).toNumber();
    check("B0.11", next >= 3 && nextO >= 5, `live margin positions opened ${next - 1}, orders ${nextO - 1}`);

    // deploy the NEW contracts (the starting state of the ceremony: deployed, NOT seeded, NOT listed)
    await impersonate(deployerAddr);
    const hBefore = await blockNumber();
    const pinFile = KNOB.tool ? path.join(path.dirname(KNOB.tool), "..", "ceremony", "bp-dlmm-pin.json") : "";
    TOOL_ON = KNOB.useTool !== "0" && !!KNOB.tool && fs.existsSync(KNOB.tool) && fs.existsSync(pinFile);
    results.data.mode = TOOL_ON ? "TOOL (A's ceremony tool: real deploy script, verify-*, printed calldata)" : "BUILT-IN (harness deployment and encodings, NOT A's deploy script)";
    if (!TOOL_ON && KNOB.useTool !== "0") check("B0.t0", false, `A's ceremony tool is not usable (tool ${KNOB.tool || "none"}, pin file ${pinFile || "none"}): the run falls back to the BUILT-IN deployment, which is NOT the real deploy script; run 'tools/bp-dlmm-ceremony.sh pin rehearsal' in A's worktree, or set BP_USE_TOOL=0 to accept the built-in mode explicitly`);
    if (KNOB.useTool === "1" && !TOOL_ON) throw new Error(`BP_USE_TOOL=1 but the tool or its pin file is missing (${KNOB.tool} / ${pinFile}): run 'tools/bp-dlmm-ceremony.sh pin rehearsal' in A's worktree`);
    ADDR_FILE = KNOB.addressesFile || path.join(OUTDIR, "bp-addresses.env");
    if (TOOL_ON) {
      note("B0.t0", `MODE TOOL: ceremony tool in use: ${KNOB.tool} (pin file ${pinFile}); deploy, verify-deployed, verify-listing and print-ledger-calls run through it`);
      await toolCheck("B0.t1", "tool: `check rehearsal` (live facts: controller admin = Ledger, oracle = the guarded oracle, vault owner/ProxyAdmin = the Safe, feeds fresh, Ledger holds the seed) passes on the fork", ["check", "rehearsal"], /check: OK/);
      fs.rmSync(ADDR_FILE, { force: true });
      const r = await toolRun(["deploy", "rehearsal"], { BP_DEPLOYER: deployerAddr });
      check("B0.12", r.code === 0 && /verify-deployed: OK/.test(r.out), `the REAL deploy script ran on the fork through the tool by the throwaway deployer (exit ${r.code}) and its verify-deployed (code == the pinned build, wrapper == guarded oracle for every market) passed; log tool-deploy-rehearsal.log`, r.out.split("\n").slice(-8).join(" | "));
      const e = Object.fromEntries(fs.readFileSync(ADDR_FILE, "utf8").split("\n").filter((l) => l.startsWith("export ")).map((l) => l.slice(7).split("=")));
      D = { PBP: utils.getAddress(e.BP_MARKET), WRAPPER: utils.getAddress(e.BP_ORACLE), DELEGATE: utils.getAddress(e.BP_DELEGATE) };
    } else if (KNOB.deployCmd) {
      const r = await runProc("bash", ["-c", KNOB.deployCmd], { cwd: process.env.BP_DEPLOY_CWD || process.cwd(), timeoutMs: 20 * 60 * 1000, label: "BP_DEPLOY_CMD",
        env: { PATH: process.env.PATH, HOME: process.env.HOME, RPC_LOCAL: process.env.REH_RPC, ETH_RPC_URL: process.env.REH_RPC, AVALANCHE_MAINNET_RPC_URL: process.env.REH_RPC, BP_DEPLOYER: deployerAddr, BP_ADDRESSES_FILE: ADDR_FILE } });
      fs.writeFileSync(path.join(OUTDIR, "deploy-cmd.log"), r.out);
      check("B0.12", r.code === 0, `the deploy command ran on the fork (exit ${r.code}); log in deploy-cmd.log`, r.out.slice(-300));
      const e = Object.fromEntries(fs.readFileSync(ADDR_FILE, "utf8").split("\n").filter((l) => l.startsWith("export ")).map((l) => l.slice(7).split("=")));
      D = { PBP: utils.getAddress(e.BP_MARKET || e.BP_PTOKEN), WRAPPER: utils.getAddress(e.BP_ORACLE || e.BP_WRAPPER), DELEGATE: e.BP_DELEGATE ? utils.getAddress(e.BP_DELEGATE) : ZERO };
    } else {
      D.DELEGATE = await deployFromArtifact(KNOB.delegateName, {}, deployerAddr);
      const g = artifact("PErc20Delegator");
      const become = utils.defaultAbiCoder.encode(["address", "uint256"], [LIVE.VAULT, KNOB.minVaultSupply]);
      const gf = new ethers.ContractFactory(g.abi, g.bytecode, signer(deployerAddr));
      const c = await gf.deploy(LIVE.VAULT, LIVE.CONTROLLER, LIVE.RATE_MODEL, KNOB.initialExchangeRate, KNOB.name, KNOB.symbol, KNOB.pTokenDecimals, LIVE.LEDGER, D.DELEGATE, become, {});
      await c.deployTransaction.wait(); D.PBP = c.address;
      D.WRAPPER = await deployFromArtifact(KNOB.wrapperName, { baseOracle: LIVE.GUARDED_ORACLE, base: LIVE.GUARDED_ORACLE, market: D.PBP, pToken: D.PBP, owner: LIVE.LEDGER, vault: LIVE.VAULT, source: LIVE.SOURCE_ORACLE }, deployerAddr);
      check("B0.12b", true, `built-in deployment by the throwaway deployer from the forge artifacts of ${BP_OUT} (NOT the real deploy script - use the ceremony tool for the real rehearsal): delegate ${D.DELEGATE}, market ${D.PBP}, wrapper ${D.WRAPPER}`);
    }
    const hAfter = await blockNumber();
    D.blocks = { market: await firstBlockWithCode(D.PBP, hBefore + 1, hAfter), wrapper: await firstBlockWithCode(D.WRAPPER, hBefore + 1, hAfter), head: hAfter };   // where the contracts were created, found by bisection on eth_getCode of the local chain
    CER = ownCalls();
    if (TOOL_ON) {
      const pl = Object.values(parseLedgerCalls((await toolRun(["print-ledger-calls", "rehearsal"])).out)), probs = [], used = new Set();
      for (const [key, c] of Object.entries(CER)) {
        const t = pl.find((x) => x.data && x.data.toLowerCase() === c.data.toLowerCase() && x.to.toLowerCase() === c.to.toLowerCase());
        if (!t) { probs.push(`${key}: the tool prints no transaction with the harness's calldata/target`); continue; }
        used.add(t.id); CER[key] = { ...c, id: t.id, tnum: Number(/\d+/.exec(t.id)[0]), toolLabel: t.label };
      }
      for (const t of pl) if (!used.has(t.id)) probs.push(`${t.id} (${t.label}): printed by the tool but unknown to the harness`);
      check("B0.t5", probs.length === 0, `every Ledger transaction printed by the tool's print-ledger-calls (${pl.map((x) => x.id).join(" ")}) has byte-identical calldata AND target to the harness's own independent encoding, and the harness knows no transaction the tool does not print (the harness sends the order the tool prints: ${["oracleSwap", ...orderOf(2), ...orderOf(3), ...orderOf(4)].map((k) => CER[k].id).join(" ")})`, probs.join("; "));
    }
    check("B0.12a", !!D.blocks.market && !!D.blocks.wrapper, `new contracts: market ${D.PBP} (created in block ${D.blocks.market}), wrapper ${D.WRAPPER} (block ${D.blocks.wrapper}), delegate ${D.DELEGATE}`, `no code found between blocks ${hBefore + 1} and ${hAfter}`);
    addErrorAbi(artifact(KNOB.wrapperName).abi);
    results.data.deployed = D;
    // the deployed, unlisted, unseeded starting state
    const p = pb();
    check("B0.13", !(await ctl.markets(D.PBP))[0] && (await p.totalSupply()).eq(0) && (await p.underlying()) === LIVE.VAULT && (await p.peridottroller()) === LIVE.CONTROLLER && (await p.admin()) === LIVE.LEDGER,
      "starting state: the market is deployed (underlying = the DLMM vault, controller = the live one, admin = the Ledger), NOT listed, pToken supply 0");
    const dv = await codeOrRevert(async () => (await p.pharaohVault()) === LIVE.VAULT ? 0 : 1);
    check("B0.14", dv.code === 0 && (await p.minimumVaultSupplyAtListing()).eq(KNOB.minVaultSupply), `the delegate pinned the vault at deployment (pharaohVault() = ${LIVE.VAULT}, minimum supply ${sh(KNOB.minVaultSupply)})`, JSON.stringify(dv));
    check("B0.15", (await p.flashLoansPaused()) === true && (await p.maxFlashLoan(LIVE.VAULT)).eq(0), "flash loans are PAUSED FROM BIRTH (delegate _becomeImplementation) and maxFlashLoan(shares) = 0");
    const w = wr();
    check("B0.16", (await w.baseOracle()) === LIVE.GUARDED_ORACLE && (await w.market()) === D.PBP && (await w.vault()) === LIVE.VAULT && (await w.vaultAsset()) === LIVE.USDC,
      `wrapper: base oracle = the live guarded oracle, market = the new pToken, vault = the DLMM vault, asset = USDC`);
    const wp = await w.getUnderlyingPrice(D.PBP);
    check("B0.17", wp.gt(0), `the wrapper already prices the (unlisted) share market: ${wp} (USD per raw share x 1e36 / 1e18... = ${Number(wp) / 1e30} USD per whole share)`);
    // ---- B0.v: the v2 wrapper's facts straight after the deployment (nothing else has touched the vault: the stored leg must be the live one)
    {
      const wv = await codeOrRevert(async () => { await w.shareState(); return 0; });
      check("B0.v0", wv.code === 0, "the deployed wrapper answers shareState(): it is the v2 wrapper (run 1 used v1, which has no such function): if this fails re-pin and rebuild in THIS tree", JSON.stringify(wv));
      if (wv.code === 0) {
        const stored = await w.lastGoodAssetsPerShare(), storedAt = (await w.lastGoodTime()).toNumber(), headNow = await headTs();
        const logs = await provider.getLogs({ address: D.WRAPPER, topics: [w.interface.getEventTopic("FallbackPriceStored")], fromBlock: D.blocks.wrapper, toBlock: D.blocks.head });
        const ev = logs.length === 1 ? w.interface.parseLog(logs[0]).args : null;                     // by index: `at` collides with Array.prototype.at in ethers v5
        const legAtDeploy = await vault.convertToAssets(1_000_000, { blockTag: D.blocks.wrapper }), blkTs = (await provider.getBlock(D.blocks.wrapper)).timestamp;
        check("B0.v1", !!ev && BN(ev[0]).eq(stored) && stored.eq(legAtDeploy) && stored.eq(await sharePps()) && BN(ev[1]).eq(storedAt) && storedAt === blkTs && stored.gt(0),
          `the constructor stored the LIVE vault leg: lastGoodAssetsPerShare ${stored} = convertToAssets(1e6) at the deployment block ${D.blocks.wrapper} (${legAtDeploy}) = now (${await sharePps()}); lastGoodTime ${storedAt} = that block's timestamp; exactly one FallbackPriceStored(${ev ? ev[0] : "?"}, ${ev ? ev[1] : "?"})`);
        const ss = await w.shareState(), px = await w.getUnderlyingPrice(D.PBP);
        check("B0.v2", ss[0].eq(stored) && ss[1].eq(stored) && ss[2].eq(storedAt) && ss[3] === false && ss[4].eq(86400 - (headNow - storedAt)) && (await w.getShareUsdPrice()).eq(px.div(BN(10).pow(12))) && px.eq(shareExpect(stored, await guarded.getPrice(LIVE.USDC))),
          `shareState() is consistent: live ${ss[0]} = stored ${ss[1]} (at ${ss[2]}), usingFallback ${ss[3]}, ${ss[4]} s of window left = 86,400 - age ${headNow - storedAt}; getShareUsdPrice = price / 1e12; price = stored x the base oracle's USDC price (recomputed)`);
        const cst = { h: await w.FALLBACK_HAIRCUT_BPS(), w: await w.FALLBACK_WINDOW(), u: await w.POKE_MAX_UP_BPS(), i: await w.POKE_UP_INTERVAL() };
        check("B0.v3", cst.h.eq(300) && cst.w.eq(86400) && cst.u.eq(200) && cst.i.eq(3600) && (await w.shareDecimals()) === 6 && (await w.assetDecimals()) === 6,
          `constants: FALLBACK_HAIRCUT_BPS ${cst.h} (3 %), FALLBACK_WINDOW ${cst.w} s (24 h), POKE_MAX_UP_BPS ${cst.u} (2 %), POKE_UP_INTERVAL ${cst.i} s (1 h); share and asset decimals 6`);
      }
      const size = async (a) => ((await provider.getCode(a)).length - 2) / 2, onchain = { wrapper: await size(D.WRAPPER), delegator: await size(D.PBP), delegate: await size(D.DELEGATE) };
      let pinSizes = null; try { if (TOOL_ON) pinSizes = JSON.parse(fs.readFileSync(pinFile, "utf8")).sizes; } catch { /* no pin */ }
      const wantRuntime = Number(process.env.BP_WRAPPER_RUNTIME || 3628), LIMIT = 24576;
      const all = { ...onchain, accountingModule: pinSizes?.accountingModule };
      check("B0.v4", Object.values(onchain).every((n) => n > 0 && n < LIMIT) && (all.accountingModule === undefined || all.accountingModule < LIMIT) && (!TOOL_ON || (onchain.wrapper === wantRuntime && pinSizes && onchain.wrapper === pinSizes.oracle && onchain.delegator === pinSizes.delegator && onchain.delegate === pinSizes.delegate)),
        `runtime sizes (EIP-170 limit ${LIMIT}): wrapper ${onchain.wrapper} bytes (v2 = ${wantRuntime}), market (delegator) ${onchain.delegator}, delegate ${onchain.delegate}, accounting module ${all.accountingModule ?? "n/a (no pin: built-in mode)"}; on chain == the pin ${pinSizes ? "yes" : "n/a"}`);
    }
    // the data B1 compares against (taken now, before any ceremony transaction)
    S0 = await snapshot({ extraMarkets: [] });
    fs.writeFileSync(path.join(OUTDIR, "snapshot-before.json"), JSON.stringify(S0));
    results.data.vaultBefore = { totalAssets: sh(tA), totalSupply: sh(tS), pps: sh(await sharePps()) };
  });
  if (!D.PBP) { console.log("no market deployed: the rest cannot run"); finish(); }
  const wrapper = wr(), pBP = pb();

  // ============================================================================================================ B1 PRICE IDENTITY with the REAL feeds, BEFORE any mock
  const readPrices = async (oracleAddr) => {
    const o = C(oracleAddr, ORACLE), r = {};
    for (const [n, p] of [["pWAVAX", LIVE.PWAVAX], ["pUSDC", LIVE.PUSDC]]) {
      r[`${n}.getUnderlyingPrice`] = (await o.getUnderlyingPrice(p)).toString();
      r[`${n}.marketAsset`] = await o.marketAsset(p).catch((e) => `n/a:${decodeErr(e)}`);
    }
    for (const [n, a] of [["WAVAX", LIVE.WAVAX], ["USDC", LIVE.USDC]]) r[`${n}.getPrice`] = await o.getPrice(a).then((x) => x.toString()).catch((e) => `n/a:${decodeErr(e)}`);
    return r;
  };
  const accounts = []; // the live margin accounts
  const liveView = async () => {
    const v = {};
    for (const id of [1, 2]) {
      const pos = await exec.positions(id); if (!pos.account || pos.account === ZERO) continue; accounts.push(pos.account);
      v[`pos${id}.liquidity`] = await ctl.getAccountLiquidity(pos.account).then((l) => l.map(String).join("/")).catch((e) => `n/a:${decodeErr(e)}`);
      v[`pos${id}.metrics`] = await risk.getMetrics(pos.account).then((m) => m.map(String).join("/")).catch((e) => `n/a:${decodeErr(e)}`);
    }
    v.quoteOpen = await quoter.quoteOpen(LIVE.PUSDC, LIVE.PWAVAX, LIVE.PUSDC, 50_000_000, 200).then((q) => q.map(String).join("/")).catch((e) => `n/a:${decodeErr(e)}`);
    const sc = await ctl.liquidateCalculateSeizeTokens(LIVE.PUSDC, LIVE.PWAVAX, 1_000_000); v.seizeCalc_pUSDC_pWAVAX = sc.map(String).join("/");
    const sc2 = await ctl.liquidateCalculateSeizeTokens(LIVE.PWAVAX, LIVE.PUSDC, E18); v.seizeCalc_pWAVAX_pUSDC = sc2.map(String).join("/");
    return v;
  };
  await group("B1 price identity with the real feeds", async () => {
    // 1. before the swap: the guarded oracle directly (what the controller, the margin risk engine and the quoter read today)
    const oldP0 = await readPrices(LIVE.GUARDED_ORACLE), view0 = await liveView(); accounts.length = 0;
    check("B1.1", oldP0["pWAVAX.getUnderlyingPrice"] !== "0" && oldP0["pUSDC.getUnderlyingPrice"] !== "0" && oldP0["WAVAX.getPrice"] !== "0" && oldP0["USDC.getPrice"] !== "0" && true,
      `BEFORE the swap the real prices are non-zero (so equality below is not 0 == 0): pWAVAX ${oldP0["pWAVAX.getUnderlyingPrice"]}, pUSDC ${oldP0["pUSDC.getUnderlyingPrice"]}, getPrice(WAVAX) ${oldP0["WAVAX.getPrice"]}, getPrice(USDC) ${oldP0["USDC.getPrice"]}`);
    const ageB = { AVAX: await ageOf(LIVE.AVAX_FEED), USDC: await ageOf(LIVE.USDC_FEED) }; log(`feed ages before the swap: AVAX ${ageB.AVAX}s USDC ${ageB.USDC}s`);
    // 2. the Ledger transactions of the ceremony up to and including the oracle swap
    await runStep(step("oracleSwap"));
    check("B1.2", (await ctl.oracle()) === D.WRAPPER, `controller.oracle() is now the wrapper ${D.WRAPPER} (the oracle-swap transaction only)`);
    await toolCheck("B1.t1", "tool: `verify-listing rehearsal 1` (wrapper == guarded oracle for every market, share price sane) passes", ["verify-listing", "rehearsal", "1"], /verifyListing stage OK: 1/);
    const ageA = { AVAX: await ageOf(LIVE.AVAX_FEED), USDC: await ageOf(LIVE.USDC_FEED) }; log(`feed ages after the swap: AVAX ${ageA.AVAX}s USDC ${ageA.USDC}s`);
    // 3. after: the SAME functions through the wrapper and through the old oracle at the SAME block
    const newP = await readPrices(D.WRAPPER), oldP1 = await readPrices(LIVE.GUARDED_ORACLE), view1 = await liveView();
    const diffs = Object.keys(oldP1).filter((k) => oldP1[k] !== newP[k]).map((k) => `${k}: old ${oldP1[k]} wrapper ${newP[k]}`);
    check("B1.3", diffs.length === 0 && Object.keys(oldP1).length >= 6, `wrapper == old oracle BIT-IDENTICAL for getUnderlyingPrice(pWAVAX, pUSDC), getPrice(WAVAX, USDC) and marketAsset(pWAVAX, pUSDC) at the same block (${Object.keys(oldP1).length} values)`, diffs.join("; "));
    const drift = Object.keys(oldP0).filter((k) => oldP0[k] !== newP[k]).map((k) => `${k}: before ${oldP0[k]} after ${newP[k]}`);
    check("B1.4", drift.length === 0, "the prices read before the swap equal the prices read through the wrapper after it (the real feeds did not move between the two reads)", drift.join("; "));
    check("B1.5", newP["pWAVAX.getUnderlyingPrice"] !== "0" && newP["pUSDC.getUnderlyingPrice"] !== "0" && newP["USDC.getPrice"] !== "0", "after the swap the prices are still non-zero (not a stale-feed 0 == 0)");
    const adapterOracle = await C(LIVE.M_CLOSE_ADAPTER_V1, ["function oracle() view returns (address)"]).oracle().catch(() => "n/a");
    check("B1.6", (await risk.oracle()) === LIVE.GUARDED_ORACLE && (await quoter.oracle()) === LIVE.GUARDED_ORACLE && (adapterOracle === "n/a" || adapterOracle === LIVE.GUARDED_ORACLE), `THE WRAPPER IS NOT IN THE MARGIN PATH: the risk engine and the quoter still point at the guarded oracle and so does the close adapter (${adapterOracle}); the liquidator reads the risk engine's pointer - the swap changed only the controller pointer`);
    const vd = Object.keys(view0).filter((k) => view0[k] !== view1[k]).map((k) => `${k}: ${view0[k]} -> ${view1[k]}`);
    check("B1.7", vd.length === 0 && Object.keys(view0).length >= 5, `controller.getAccountLiquidity of the live margin accounts, risk-engine getMetrics, quoter.quoteOpen and the controller's liquidateCalculateSeizeTokens (both directions) are IDENTICAL before and after the swap (${Object.keys(view0).length} values)`, vd.join("; "));
    const S1 = await snapshot({ extraMarkets: [] });
    const d = diff(S0, S1);
    check("B1.8", d.positions.length === 0 && d.orders.length === 0 && d.proxies.length === 0 && d.slots.length === 0, "executor positions 1 and 2, registry orders and the raw storage of the margin proxies are field-for-field unchanged by the swap (debt interest excluded)", [...d.positions, ...d.orders, ...d.proxies, ...d.slots.map((s) => `${s.proxy}#${s.slot}`)].join("; "));
    const ld = d.lending.filter((x) => !/^markets\.(pWAVAX|pUSDC)\.(totalBorrows|totalReserves|exchangeRate|cash)/.test(x));
    check("B1.9", d.codehash.length === 0 && ld.length === 0, "lending state of the existing markets (CF, caps, pauses, floor, admin, rate model, flags) and every code hash in the account's path unchanged by the swap", [...d.codehash, ...ld].join("; "));
    check("B1.10", d.pointers.length === 1 && d.pointers[0].startsWith("controllerOracle"), `the ONLY pointer that moved is controllerOracle (${d.pointers.join(" | ")})`);
    const tc = touchedByStep[step("oracleSwap").id];
    const inPath = Object.entries(PATH_CONTRACTS()).filter(([, a]) => (tc?.addresses || []).map((x) => x.toLowerCase()).includes(a.toLowerCase())).map(([n]) => n);
    if (tc?.mode === "state-diff") check("B1.11", inPath.length === 1 && inPath[0] === "controller", `the oracle swap writes state in exactly one contract of the account's path: ${inPath.join(",")} (state-diff trace; all touched: ${tc.addresses.length})`);
    else note("B1.11", `state-diff tracer unavailable (${tc?.mode}): contracts CALLED by the swap tx in the account's path: ${inPath.join(",")}`);
    results.data.b1 = { oldP0, newP, view0, view1, ageB, ageA };
    check("B1.12", (await wrapper.marketAsset(D.PBP)) === (await guarded.marketAsset(D.PBP)), `wrapper.marketAsset(pBP) forwards the base oracle verbatim (${await wrapper.marketAsset(D.PBP)}): the share market is NOT a margin market`);
    // ROLLBACK CASE 1: right after the swap, BEFORE _supportMarket: clean
    await scenario("rollback before listing", async () => {
      const Sb = await snapshot();
      await runStep(step("rollback"));
      const Sa = await snapshot(), dr = diff(Sb, Sa), oldP = await readPrices(LIVE.GUARDED_ORACLE);
      check("B1.r1", (await ctl.oracle()) === LIVE.GUARDED_ORACLE && Object.keys(oldP).every((k) => oldP[k] === newP[k]), "ROLLBACK BEFORE LISTING (case 1): one Ledger transaction restores controller.oracle() = the guarded oracle and every existing price/consumer value equals the one read through the wrapper");
      check("B1.r2", dr.positions.length === 0 && dr.orders.length === 0 && dr.codehash.length === 0 && dr.pointers.length === 1 && dr.pointers[0].startsWith("controllerOracle") && dr.lending.filter((x) => !/(totalBorrows|totalReserves|exchangeRate|cash)/.test(x)).length === 0, `nothing but the controller's oracle pointer moves (${dr.pointers.join(" | ")}); no market is listed yet, so nothing can be frozen`, dr.lending.join("; "));
      const v2 = await liveView(); const vd2 = Object.keys(view1).filter((k) => view1[k] !== v2[k]).map((k) => `${k}`);
      check("B1.r3", vd2.length === 0, "the controller-side and margin-side views (liquidity of the live margin accounts, getMetrics, quoteOpen, seize calculation) are identical after the rollback", vd2.join(","));
    });
    note("B1.n1", `the wrapper prices the share market at ${(await wrapper.getUnderlyingPrice(D.PBP))} (= ${Number(await wrapper.getUnderlyingPrice(D.PBP)) / 1e30} USD per whole share) while the controller has not listed it yet`);
  });

  // ---- from here on mocks are allowed: the real feeds cannot be moved on a fork. The mock replaces runtime code at the real feed addresses; answers are the REAL answers at the pin.
  await etchFeed(LIVE.AVAX_FEED); await etchFeed(LIVE.USDC_FEED); await etchFeed(LIVE.USDT_FEED);
  note("B1.n2", "from here the AVAX, USDC and USDT feeds are MOCKS at their real answers (a fork cannot move real feeds; real feed lag, heartbeat and round behaviour are NOT rehearsed after this point)");

  // ============================================================================================================ margin stack AFTER the swap: OPEN, TP order executed, CLOSE (all through the live registry / adapter)
  const POOLC = C(LIVE.PHARAOH_POOL, POOL), tickNow = async () => { const s = await POOLC.slot0(); return { sqrtP: s[0], tick: s[1] }; };
  const sqrtAtTick = (t) => BigInt(Math.floor(Math.sqrt(Math.pow(1.0001, t)) * 2 ** 96));
  const whale = A("DEAD0001");
  async function moveTo(target) {
    const { tick } = await tickNow(); if (tick === target) return;
    const up = target > tick, tokenIn = up ? LIVE.USDC : LIVE.WAVAX, tokenOut = up ? LIVE.WAVAX : LIVE.USDC;
    const amountIn = up ? BN(20_000_000).mul(1e6) : BN(2_000_000).mul(E18);
    await impersonate(whale); await setErc20Balance(tokenIn, whale, amountIn);
    await tx("whale approve router", (o) => C(tokenIn, ERC20, whale).approve(LIVE.PHARAOH_ROUTER, amountIn, o));
    const limit = BN(sqrtAtTick(up ? target + 1 : target - 1).toString());
    const deadline = (await headTs()) + 3600;
    await tx("pool swap", (o) => C(LIVE.PHARAOH_ROUTER, CLROUTER, whale).exactInputSingle([tokenIn, tokenOut, 10, whale, deadline, amountIn, 0, limit], o));
    const after = (await tickNow()).tick; if (up ? after < target : after > target) throw new Error(`moveTo ${target}: the pool stopped at ${after} (depth)`);
  }
  async function syncOracleToPool() { const { sqrtP } = await tickNow(); const u = mocks[LIVE.USDC_FEED.toLowerCase()].answer; const x = sqrtP.mul(sqrtP).shr(64); await setFeed(LIVE.AVAX_FEED, x.mul(BN(10).pow(12)).mul(u).shr(128)); }
  const market = async (target) => { await moveTo(target); await syncOracleToPool(); };
  async function openLong(user, marginUsdc) {
    await impersonate(user); await setErc20Balance(LIVE.USDC, user, BN(marginUsdc));
    await tx("approve pUSDC", (o) => C(LIVE.USDC, ERC20, user).approve(LIVE.PUSDC, marginUsdc, o));
    const before = await pU.balanceOf(user);
    await tx("mint pUSDC", (o) => C(LIVE.PUSDC, PT, user).mint(marginUsdc, o));
    const shares = (await pU.balanceOf(user)).sub(before);
    await tx("approve margin vault", (o) => C(LIVE.PUSDC, PT, user).approve(LIVE.M_VAULT, shares, o));
    await tx("margin vault deposit", (o) => C(LIVE.M_VAULT, MVAULT, user).deposit(LIVE.PUSDC, shares, o));
    const rate = await pU.exchangeRateStored();
    const [, minPos] = await quoter.quoteOpen(LIVE.PUSDC, LIVE.PWAVAX, LIVE.PUSDC, shares.mul(rate).div(E18), 200);
    const id = (await exec.nextPositionId()).toNumber(); await repin();
    await tx("openPosition", (o) => C(LIVE.M_EXECUTOR, EXEC, user).openPosition([LIVE.PUSDC, LIVE.PWAVAX, LIVE.PUSDC, shares, 200, 0, minPos, 0, "0x"], o));
    return id;
  }
  const position = async (id) => { const p = await exec.positions(id); return { id, owner: p.owner, account: p.account, status: p.status }; };
  const priceE18 = () => mocks[LIVE.AVAX_FEED.toLowerCase()].answer.mul(BN(10).pow(10));
  await group("B1m margin after the oracle swap", async () => {
    await scenario("margin after the swap", async () => {
      // FORK-ONLY environment: the live pUSDC borrow cap (200 USDC) and cash cannot carry two new 2x positions; raised here, REVERTED with the scenario
      const supplier = A("5AFE01"); await impersonate(supplier); await setErc20Balance(LIVE.USDC, supplier, BN(100_000).mul(1e6));
      await tx("supplier approve", (o) => C(LIVE.USDC, ERC20, supplier).approve(LIVE.PUSDC, BN(100_000).mul(1e6), o));
      await tx("supplier mint pUSDC", (o) => C(LIVE.PUSDC, PT, supplier).mint(BN(100_000).mul(1e6), o));
      await tx("fork-only cap raise", (o) => C(LIVE.CONTROLLER, CTL, LIVE.LEDGER)._setMarketBorrowCaps([LIVE.PUSDC], [BN(1_000_000).mul(1e6)], o));
      note("B1m.n1", "fork only (reverted with the scenario): 100,000 USDC supplied to pUSDC and its borrow cap raised, so two new test positions can borrow; not part of the ceremony");
      const startTick = (await tickNow()).tick; await syncOracleToPool();
      const alice = A("A11CE"), bob = A("B0B01");
      const idA = await openLong(alice, 60_000_000);
      const pa = await position(idA);
      check("B1m.1", pa.status === 2 && pa.owner.toLowerCase() === alice.toLowerCase(), `margin OPEN after the oracle swap: a 2x long (position ${idA}) was opened through the live executor; its borrow went through the controller priced by the WRAPPER (controller.oracle() = ${await ctl.oracle()})`);
      const exp = (await headTs()) + 86400, price = priceE18();
      const slA = (await reg.nextOrderId()).toNumber();
      await tx("create SL", (o) => C(LIVE.M_REGISTRY, REG, alice).createOrder(idA, 1, false, price.mul(90).div(100), 10000, 100, exp, o));  // the stop-loss FIRST (a reachable TP executes within seconds on mainnet)
      const tpA = slA + 1;
      await tx("create TP", (o) => C(LIVE.M_REGISTRY, REG, alice).createOrder(idA, 0, true, price.mul(103).div(100), 10000, 100, exp, o));
      check("B1m.2", (await reg.getOrder(slA)).status === 1 && (await reg.getOrder(tpA)).status === 1, `a stop-loss (order ${slA}) and a take-profit (order ${tpA}) are registered in the LIVE order registry; the live adapter is ${await reg.adapter()} (pinned in live-addresses.env as ${LIVE.M_CLOSE_ADAPTER_V1})`);
      const early = await expectRevert(() => C(LIVE.M_REGISTRY, REG, A("AAAA1")).callStatic.executeOrder(tpA, "0x"));
      check("B1m.3", early !== null, `the take-profit does not execute before its trigger (${early})`);
      await market(startTick + 400); // +4 %: past the 103 % trigger; the mock AVAX feed follows the pool
      const stranger = A("AAAA1"); await impersonate(stranger); await repin();
      await tx("execute TP", (o) => C(LIVE.M_REGISTRY, REG, stranger).executeOrder(tpA, "0x", o));
      const pa2 = await position(idA);
      check("B1m.4", pa2.status === 5 && (await reg.getOrder(tpA)).status === 2, `TAKE-PROFIT executed through the live registry/adapter AFTER the swap (permissionless call): position ${idA} CLOSED, order ${tpA} EXECUTED`);
      check("B1m.5", (await reg.getOrder(slA)).status !== 1, `the sibling stop-loss was cancelled by the TP execution (order ${slA} status ${(await reg.getOrder(slA)).status})`);
      // CLOSE: a second position closed by a reachable stop-loss
      await market(startTick); await repin();
      const idB = await openLong(bob, 60_000_000); const price2 = priceE18();
      const slB = (await reg.nextOrderId()).toNumber();
      await tx("create SL bob", (o) => C(LIVE.M_REGISTRY, REG, bob).createOrder(idB, 1, false, price2.mul(97).div(100), 10000, 100, exp, o));
      await market(startTick - 400); await repin();
      await tx("execute SL", (o) => C(LIVE.M_REGISTRY, REG, stranger).executeOrder(slB, "0x", o));
      check("B1m.6", (await position(idB)).status === 5 && (await reg.getOrder(slB)).status === 2, `margin CLOSE after the swap: position ${idB} closed by its stop-loss through the live registry/adapter (order ${slB} EXECUTED)`);
      const snapM = await snapshot();
      const dm = diff(S0, snapM); // positions 1 and 2 untouched by all of the above
      check("B1m.7", dm.positions.filter((x) => /^position [12]\./.test(x)).length === 0 && dm.orders.filter((x) => /^order [1-4]\./.test(x)).length === 0, "live positions 1 and 2 and live orders 1..4 are field-for-field unchanged by the margin activity of other users", dm.positions.concat(dm.orders).join("; "));
    });
  });
  await repin();

  // ============================================================================================================ B2 seed and listing
  await group("B2 seed and listing", async () => {
    const mallory = A("0A110C");
    for (const key of orderOf(2)) {
      await runStep(step(key));
      if (key === "list") { // the SEED WINDOW: listed, not yet seeded
        await impersonate(mallory); await setErc20Balance(LIVE.USDC, mallory, 50_000_000);
        await tx("mallory approve USDC", (o) => C(LIVE.USDC, ERC20, mallory).approve(LIVE.VAULT, 50_000_000, o));
        let got = BN(0); try { await tx("mallory vault deposit", (o) => C(LIVE.VAULT, VAULT, mallory).deposit(5_000_000, mallory, o)); got = await vault.balanceOf(mallory); } catch (e) { got = BN(0); note("B2.n0", `mallory could not obtain shares through the vault (${String(e.message).slice(0, 80)}): the seed-window probe uses the Ledger's shares instead`); }
        if (BN(got).eq(0)) { await tx("Ledger gives mallory shares", (o) => C(LIVE.VAULT, VAULT, LIVE.LEDGER).transfer(mallory, 1_000_000, o)); }
        await tx("mallory approve shares", (o) => C(LIVE.VAULT, VAULT, mallory).approve(D.PBP, ethers.constants.MaxUint256, o));
        const r = await codeOrRevert(() => C(D.PBP, PT, mallory).callStatic.mint(100_000));
        const seedPending = r.revert && /SeedPending/.test(r.revert);
        check("B2.1", !!seedPending, `SEED WINDOW: between listing and the seed an outsider's mint is refused (${r.revert ?? "ACCEPTED code " + r.code}); the delegate allows only the admin to make the first mint`);
      }
    }
    await toolCheck("B2.t1", "tool: `verify-listing rehearsal 2` (listed, CF 0, borrow paused, cap 1, flash loans paused) passes", ["verify-listing", "rehearsal", "2"], /verifyListing stage OK: 2/);
    for (const key of orderOf(3)) await runStep(step(key));
    await toolCheck("B2.t2", "tool: `verify-listing rehearsal 3` (seed: supply 5,000,000,000 pTokens all at 0xdEaD, cash 1,000,000, exchange rate 2e14, mint paused) passes", ["verify-listing", "rehearsal", "3"], /verifyListing stage OK: 3/);
    // read-back of the listing
    const m = await ctl.markets(D.PBP), all = (await ctl.getAllMarkets()).map((a) => a.toLowerCase());
    check("B2.2", m[0] && m[1].eq(0) && all.length === 3 && all[2] === D.PBP.toLowerCase(), "LISTED with collateral factor 0 as the third market");
    const cap = await ctl.borrowCaps(D.PBP);
    check("B2.3", (await ctl.borrowGuardianPaused(D.PBP)) === true && cap.gt(0) && cap.lte(1000), `borrow paused and cap ${cap} (non-zero: 0 would mean UNLIMITED; effectively zero: <= 1000 raw shares)`);
    check("B2.4", (await pBP.flashLoansPaused()) === true && (await pBP.maxFlashLoan(LIVE.VAULT)).eq(0) && /flash loans are paused/.test((await expectRevert(() => C(D.PBP, PT, A("F1A5")).callStatic.flashLoan(A("F1A5"), LIVE.VAULT, 1, "0x"))) || ""), "flash loans paused: flag true, maxFlashLoan 0, flashLoan() reverts 'flash loans are paused'");
    const dead = await pBP.balanceOf(LIVE.DEAD), ts = await pBP.totalSupply(), cash = await pBP.getCash();
    check("B2.5", dead.eq(SEED_PTOKENS()) && dead.eq(ts) && cash.eq(KNOB.seedShares) && (await pBP.balanceOf(LIVE.LEDGER)).eq(0) && (await vault.balanceOf(D.PBP)).eq(cash) && (await pBP.exchangeRateStored()).eq(KNOB.initialExchangeRate),
      `PERMANENT SEED: ${dead} pTokens at 0xdEaD = the entire pToken supply (${ts}); the market holds ${sh(cash)} raw shares of cash; the Ledger holds no pTokens`);
    check("B2.6", (await ctl.mintGuardianPaused(D.PBP)) === true && /mint is paused/.test((await expectRevert(() => C(D.PBP, PT, mallory).callStatic.mint(100_000))) || ""), "mint is paused after the seed (T8): an outsider's mint reverts 'mint is paused'");
    // the share market is not borrowable
    await scenario("share market is not borrowable", async () => {
      const holder = A("B0A1"); await impersonate(holder); await setErc20Balance(LIVE.WAVAX, holder, BN(10).mul(E18));
      await tx("holder approve WAVAX", (o) => C(LIVE.WAVAX, ERC20, holder).approve(LIVE.PWAVAX, BN(10).mul(E18), o));
      const mintR = await codeOrRevert(() => C(LIVE.PWAVAX, PT, holder).callStatic.mint(BN(5).mul(E18)));
      if (mintR.code === 0) {
        await tx("holder mint pWAVAX", (o) => C(LIVE.PWAVAX, PT, holder).mint(BN(5).mul(E18), o));
        await tx("holder enter pWAVAX", (o) => C(LIVE.CONTROLLER, CTL, holder).enterMarkets([LIVE.PWAVAX], o));
        const liq = await ctl.getAccountLiquidity(holder);
        const b1 = await codeOrRevert(() => C(D.PBP, PT, holder).callStatic.borrow(1));
        check("B2.7", liq[1].gt(0) && !!b1.revert && /borrow is paused/.test(b1.revert), `a pWAVAX holder with liquidity ${liq[1]} cannot borrow shares: ${b1.revert ?? "code " + b1.code}`);
        await tx("Ledger UNPAUSES borrow (test)", (o) => C(LIVE.CONTROLLER, CTL, LIVE.LEDGER)._setBorrowPaused(D.PBP, false, o));
        const b2 = await codeOrRevert(() => C(D.PBP, PT, holder).callStatic.borrow(1));
        check("B2.8", !!b2.revert && /borrow cap reached/.test(b2.revert), `DEFENCE IN DEPTH: even with the borrow pause lifted, the cap (${cap}) refuses any borrow of shares: ${b2.revert ?? "code " + b2.code}`);
      } else check("B2.7", false, "could not set up a pWAVAX holder (pWAVAX mint is not possible)", JSON.stringify(mintR));
    });
    // price of the new market and the identity of the existing ones AFTER the whole ceremony
    const expectedPrice = (await vault.convertToAssets(1_000_000)).mul(mocks[LIVE.USDC_FEED.toLowerCase()].answer).mul(BN(10).pow(10)).mul(BN(10).pow(12)).div(1_000_000);
    check("B2.9", (await wrapper.getUnderlyingPrice(D.PBP)).eq(expectedPrice) && expectedPrice.gt(0), `wrapper price of the share market = convertToAssets(1 share) x USDC feed, recomputed independently: ${expectedPrice} (${Number(expectedPrice) / 1e30} USD per share)`);
    const pN = await readPrices(D.WRAPPER), pO = await readPrices(LIVE.GUARDED_ORACLE);
    check("B2.10", Object.keys(pO).every((k) => pO[k] === pN[k]), "after the whole listing the existing markets still price identically through the wrapper and the old oracle");
    check("B2.11", (await ctl.admin()) === LIVE.LEDGER && (await pBP.admin()) === LIVE.LEDGER && (await pBP.symbol()) === KNOB.symbol, `the controller and the new market are administered by the Ledger; symbol ${await pBP.symbol()}, decimals ${await pBP.decimals()}, exchange rate ${await pBP.exchangeRateStored()}`);
    const ceremonyTouched = [...new Set(Object.values(touchedByStep).flatMap((t) => (t.mode === "state-diff" ? t.addresses : [])))];
    results.data.ceremonyTouched = ceremonyTouched;
    results.data.gasCeremony = Object.fromEntries(Object.entries(results.gas).filter(([k]) => /^(T|R)\d+ /.test(k)));
  });

  // ============================================================================================================ helpers for the market users
  const pps = async () => BN(await sharePps());
  async function acquireShares(who, rawShares) {
    await impersonate(who);
    const need = BN(rawShares); const assets = (await vault.convertToAssets(need)).add(3);
    try {
      await setErc20Balance(LIVE.USDC, who, assets);
      await tx(`${who.slice(0, 8)} approve vault`, (o) => C(LIVE.USDC, ERC20, who).approve(LIVE.VAULT, assets, o));
      await tx(`${who.slice(0, 8)} vault deposit`, (o) => C(LIVE.VAULT, VAULT, who).deposit(assets, who, o));
      return { shares: await vault.balanceOf(who), via: "vault.deposit" };
    } catch (e) {
      note("B3.n0", `vault.deposit refused for a test wallet (${String(e.message).slice(0, 90)}): shares are taken from the Ledger instead`);
      await tx("Ledger -> test wallet shares", (o) => C(LIVE.VAULT, VAULT, LIVE.LEDGER).transfer(who, need, o));
      return { shares: await vault.balanceOf(who), via: "Ledger transfer" };
    }
  }
  const markets3 = () => [D.PBP];
  const pricePBP = () => wrapper.getUnderlyingPrice(D.PBP);
  const priceUSDC = () => wrapper.getUnderlyingPrice(LIVE.PUSDC);
  /** raw USDC that an account can still borrow according to the controller (liquidity in USD 1e18 / pUSDC price) */
  async function borrowPowerUsdc(acct) { const l = await ctl.getAccountLiquidity(acct); return { err: l[0], liq: l[1], short: l[2], raw: l[1].mul(E18).div(await priceUSDC()) }; }
  async function room() { const cash = await pU.getCash(), floor = await ctl.borrowCashFloor(LIVE.PUSDC), cap = await ctl.borrowCaps(LIVE.PUSDC), tb = await pU.totalBorrows(); const a = cash.sub(floor).sub(10), b = cap.sub(tb).sub(10); return { cash, floor, cap, tb, room: a.lt(b) ? a : b }; }
  async function supplyAndEnter(who, rawShares) {
    const got = await acquireShares(who, rawShares);
    await tx("approve shares to pBP", (o) => C(LIVE.VAULT, VAULT, who).approve(D.PBP, ethers.constants.MaxUint256, o));
    const bal0 = await vault.balanceOf(who), rate = await pBP.exchangeRateStored();
    const r = await codeOrRevert(() => C(D.PBP, PT, who).callStatic.mint(bal0));
    if (r.code !== 0) throw new Error(`pBP.mint refused: ${JSON.stringify(r)}`);
    await tx("pBP.mint", (o) => C(D.PBP, PT, who).mint(bal0, o));
    const pt = await pBP.balanceOf(who);
    await tx("enterMarkets", (o) => C(LIVE.CONTROLLER, CTL, who).enterMarkets([D.PBP], o));
    return { shares: bal0, pTokens: pt, rateAtMint: rate, via: got.via };
  }

  // ============================================================================================================ B6a rollback BEFORE use (pristine, seeded market)
  await group("B6a rollback before use", async () => {
    await scenario("rollback before use", async () => {
      const S = await snapshot();
      await runStep(step("rollback"));
      check("B6.a1", (await ctl.oracle()) === LIVE.GUARDED_ORACLE, "ONE Ledger transaction sets the controller's oracle back to the guarded oracle");
      const old = C(LIVE.GUARDED_ORACLE, ORACLE);
      check("B6.a2", (await old.getUnderlyingPrice(LIVE.PWAVAX)).gt(0) && (await old.getUnderlyingPrice(LIVE.PUSDC)).gt(0) && (await old.getUnderlyingPrice(D.PBP)).eq(0), "after the rollback the existing markets are priced exactly as before and the share market has NO price (the guarded oracle does not know it: 0)");
      const S2 = await snapshot(); const d = diff(S, S2);
      check("B6.a3", d.positions.length === 0 && d.orders.length === 0 && d.codehash.length === 0 && d.pointers.length === 1 && d.pointers[0].startsWith("controllerOracle") && d.lending.filter((x) => !/(totalBorrows|totalReserves|exchangeRate|cash)/.test(x)).length === 0, `the rollback changes only the controller's oracle pointer; no position, order, code or market parameter moves (${d.pointers.join(" | ")})`, d.lending.join("; "));
      // what freezes: raising the CF of the share market (price 0) and any account that entered it; nobody has entered yet
      const cf = await codeOrRevert(() => C(LIVE.CONTROLLER, CTL, LIVE.LEDGER).callStatic._setCollateralFactor(D.PBP, KNOB.cf));
      check("B6.a4", cf.code === 13, `FROZEN: _setCollateralFactor(pBP, 50 %) now returns PRICE_ERROR (13): no borrowing against shares can be enabled (${JSON.stringify(cf)})`);
      // margin keeps working through the rollback
      await scenario("margin after rollback", async () => {
        const supplier = A("5AFE02"); await impersonate(supplier); await setErc20Balance(LIVE.USDC, supplier, BN(100_000).mul(1e6));
        await tx("supplier approve", (o) => C(LIVE.USDC, ERC20, supplier).approve(LIVE.PUSDC, BN(100_000).mul(1e6), o)); await tx("supplier mint", (o) => C(LIVE.PUSDC, PT, supplier).mint(BN(100_000).mul(1e6), o));
        await tx("fork-only cap raise", (o) => C(LIVE.CONTROLLER, CTL, LIVE.LEDGER)._setMarketBorrowCaps([LIVE.PUSDC], [BN(1_000_000).mul(1e6)], o));
        await syncOracleToPool(); const id = await openLong(A("A11CF"), 60_000_000);
        check("B6.a5", (await position(id)).status === 2, "a margin position can still be opened after the rollback (the margin stack never depended on the wrapper)");
      });
      // and the wrapper can be put back by one more transaction
      await runStep(step("oracleSwap"));
      check("B6.a6", (await ctl.oracle()) === D.WRAPPER && (await wrapper.getUnderlyingPrice(D.PBP)).gt(0), "re-applying the wrapper is one more Ledger transaction and restores the share price");
    });
  });

  // ============================================================================================================ B8 pToken inflation (seed-only market)
  await group("B8 pToken inflation", async () => {
    await scenario("pToken inflation", async () => {
      if (await ctl.mintGuardianPaused(D.PBP)) await runStep(step("mintOpen"));
      const attacker = A("A77AC"), victim = A("71C71"); await impersonate(attacker); await impersonate(victim);
      const ledgerBal = await vault.balanceOf(LIVE.LEDGER); const X = ledgerBal.div(2);
      await tx("Ledger funds attacker", (o) => C(LIVE.VAULT, VAULT, LIVE.LEDGER).transfer(attacker, X, o));
      const rate0 = await pBP.exchangeRateStored(), supply0 = await pBP.totalSupply(), cash0 = await pBP.getCash();
      // the attack: donate the shares DIRECTLY to the pToken to inflate the exchange rate before a victim deposits
      await tx("attacker donates shares to the pToken", (o) => C(LIVE.VAULT, VAULT, attacker).transfer(D.PBP, X, o));
      const rate1 = await pBP.exchangeRateStored();
      check("B8.1", rate1.gt(rate0) && (await pBP.totalSupply()).eq(supply0) && (await pBP.balanceOf(attacker)).eq(0), `a direct donation of ${sh(X)} raw shares raises the exchange rate ${rate0} -> ${rate1}; the attacker holds no pTokens, so the whole donation accrues to the pToken holders (the dead seed)`);
      const victimShares = BN(3_000_000); await tx("Ledger funds victim", (o) => C(LIVE.VAULT, VAULT, LIVE.LEDGER).transfer(victim, victimShares, o));
      await tx("victim approve", (o) => C(LIVE.VAULT, VAULT, victim).approve(D.PBP, victimShares, o));
      const mintR = await codeOrRevert(() => C(D.PBP, PT, victim).callStatic.mint(victimShares));
      await tx("victim mint", (o) => C(D.PBP, PT, victim).mint(victimShares, o));
      const vPT = await pBP.balanceOf(victim);
      check("B8.2", mintR.code === 0 && vPT.gt(0), `the second depositor still receives pTokens after the donation (${vPT} pTokens for ${sh(victimShares)} raw shares; no zero-mint)`);
      await tx("victim redeem all", (o) => C(D.PBP, PT, victim).redeem(vPT, o));
      const back = await vault.balanceOf(victim), loss = victimShares.sub(back);
      const maxLoss = rate1.div(E18).add(2);
      check("B8.3", loss.gte(0) && loss.lte(maxLoss), `the second depositor redeems ${sh(back)} of ${sh(victimShares)} raw shares: rounding loss ${sh(loss)} <= ${sh(maxLoss)} (one pToken's worth of rate)`);
      const deadShare = (await pBP.balanceOf(LIVE.DEAD)).mul(rate1).div(E18);
      check("B8.4", deadShare.gt(cash0.sub(2)) && X.gt(0), `the donation is not recoverable by the attacker: the dead seed's claim went from ${sh(cash0)} to ${sh(deadShare)} raw shares (the attacker paid ${sh(X)} and holds nothing)`);
    });
  });

  // ============================================================================================================ B3 supply, enter, CF 50 %, borrow, repay, redeem
  let dave = null; // the standing borrower used by B4 and B6b
  await group("B3 supply, CF 50 %, borrow, repay", async () => {
    const stepOpen = await ctl.mintGuardianPaused(D.PBP);
    if (stepOpen) { await runStep(step("mintOpen")); note("B3.n1", "ACTIVATION step 1 (T9): supply opened with one Ledger transaction (_setMintPaused(market,false)); the listing leaves mint paused"); }
    const R = await room(); log(`pUSDC cash ${usd6(R.cash)} floor ${usd6(R.floor)} cap ${usd6(R.cap)} borrows ${usd6(R.tb)} -> room ${usd6(R.room)}`);
    const T = R.room.lt(2_000_000) ? R.room : BN(2_000_000);
    check("B3.1", T.gt(500_000), `there is room to borrow ${usd6(T)} USDC inside the live 200 USDC cap and the 50 USDC cash floor (cash ${usd6(R.cash)}, borrows ${usd6(R.tb)})`);
    const carol = A("CA201"); await impersonate(carol);
    const need = T.mul(4).mul(1_000_000).div(await pps()); // collateral worth 4 x the borrow so that a 50 % CF and a 50 % utilisation fit
    const c = await supplyAndEnter(carol, need);
    check("B3.2", c.pTokens.eq(c.shares.mul(E18).div(c.rateAtMint)) && (await ctl.checkMembership(carol, D.PBP)), `SUPPLY: ${sh(c.shares)} raw shares (${c.via}) -> ${sh(c.pTokens)} pTokens at exchange rate ${c.rateAtMint}; entered the market`);
    const l0 = await ctl.getAccountLiquidity(carol);
    const b0 = await codeOrRevert(() => C(LIVE.PUSDC, PT, carol).callStatic.borrow(T));
    check("B3.3", l0[0].eq(0) && l0[1].eq(0) && b0.code === 4, `CF 0: the supplied shares give NO borrow power (liquidity ${l0[1]}) and a borrow returns INSUFFICIENT_LIQUIDITY (4): ${JSON.stringify(b0)}`);
    // CF to 50 %: needs a non-zero share price, i.e. the oracle swap must already be in place
    const cfR = await provider.call({ from: LIVE.LEDGER, to: LIVE.CONTROLLER, data: new utils.Interface(CTL).encodeFunctionData("_setCollateralFactor", [D.PBP, KNOB.cf]) });
    check("B3.4", BN(cfR).eq(0), `_setCollateralFactor(pBP, 50 %) returns 0 (success) - it needs the wrapper's non-zero share price`);
    await runStep(step("setCF"));
    await toolCheck("B3.t1", "tool: `verify-listing rehearsal 4` (activation: CF 50 %, mint open) passes", ["verify-listing", "rehearsal", "4"], /verifyListing stage OK: 4/);
    check("B3.5", (await ctl.markets(D.PBP))[1].eq(KNOB.cf), `read-back: collateralFactorMantissa = ${(await ctl.markets(D.PBP))[1]}`);
    const l1 = await ctl.getAccountLiquidity(carol), rate = await pBP.exchangeRateStored(), price = await pricePBP();
    const collUsd = c.pTokens.mul(rate).div(E18).mul(price).div(E18);               // USD 1e18
    const expLiq = KNOB.cf.mul(rate).div(E18).mul(price).div(E18).mul(c.pTokens).div(E18); // the controller's own order of operations
    check("B3.6", l1[1].gt(0) && l1[1].sub(expLiq).abs().lte(BN(10).pow(6)), `liquidity = CF x value: ${l1[1]} vs independent ${expLiq} (collateral value ${Number(collUsd) / 1e18} USD, ${(Number(l1[1]) / Number(collUsd)).toFixed(4)} of it)`);
    const pw = await borrowPowerUsdc(carol); const over = pw.raw.add(20_000);
    const bo = await codeOrRevert(() => C(LIVE.PUSDC, PT, carol).callStatic.borrow(over));
    check("B3.7", bo.code === 4, `borrowing 0.02 USDC more than the power (${usd6(over)} vs ${usd6(pw.raw)}) is refused: INSUFFICIENT_LIQUIDITY (4) ${JSON.stringify(bo)}`);
    const capR = await codeOrRevert(() => C(LIVE.PUSDC, PT, carol).callStatic.borrow(R.cap));
    check("B3.8", !!capR.revert && /borrow cap reached/.test(capR.revert), `the 200 USDC pUSDC borrow cap still binds: ${capR.revert ?? "code " + capR.code}`);
    const usdc0 = await usdc.balanceOf(carol);
    const brR = await codeOrRevert(() => C(LIVE.PUSDC, PT, carol).callStatic.borrow(T));
    check("B3.9", brR.code === 0, `BORROW ${usd6(T)} USDC against shares: callStatic returns 0`, JSON.stringify(brR));
    await tx("carol borrow USDC", (o) => C(LIVE.PUSDC, PT, carol).borrow(T, o));
    const debt = await pU.borrowBalanceStored(carol);
    check("B3.10", (await usdc.balanceOf(carol)).sub(usdc0).eq(T) && debt.sub(T).abs().lte(2) && (await pU.getCash()).gte(R.floor), `carol received exactly ${usd6(T)} USDC, debt ${usd6(debt)}, pUSDC cash ${usd6(await pU.getCash())} >= the 50 USDC floor`);
    const l2 = await ctl.getAccountLiquidity(carol);
    check("B3.11", l2[1].lt(l1[1]) && l2[2].eq(0), `liquidity fell ${l1[1]} -> ${l2[1]}, no shortfall`);
    await tx("carol approve pUSDC", (o) => C(LIVE.USDC, ERC20, carol).approve(LIVE.PUSDC, ethers.constants.MaxUint256, o));
    await setErc20Balance(LIVE.USDC, carol, (await usdc.balanceOf(carol)).add(1000)); // a few wei for the seconds of interest
    const spent0 = await usdc.balanceOf(carol);
    await tx("carol repay all", (o) => C(LIVE.PUSDC, PT, carol).repayBorrow(ethers.constants.MaxUint256, o));
    check("B3.12", (await pU.borrowBalanceStored(carol)).eq(0) && spent0.sub(await usdc.balanceOf(carol)).lte(T.add(1000)), `REPAY: debt 0, paid ${usd6(spent0.sub(await usdc.balanceOf(carol)))} USDC`);
    const sBefore = await vault.balanceOf(carol), ptBal = await pBP.balanceOf(carol);
    await tx("carol redeem all pTokens", (o) => C(D.PBP, PT, carol).redeem(ptBal, o));
    const back = await vault.balanceOf(carol);
    check("B3.13", (await pBP.balanceOf(carol)).eq(0) && back.sub(sBefore).gte(c.shares.sub(2)) && back.sub(sBefore).lte(c.shares), `REDEEM: ${sh(ptBal)} pTokens -> ${sh(back.sub(sBefore))} raw shares back (supplied ${sh(c.shares)}; rounding loss ${sh(c.shares.sub(back.sub(sBefore)))})`);
    // dave: the standing borrower (stays supplied and in debt for B4 / B5 / B6b)
    const d = A("DA7E1"); await impersonate(d);
    const R2 = await room(); const Td = R2.room.lt(2_000_000) ? R2.room : BN(2_000_000);
    const needD = Td.mul(4).mul(1_000_000).div(await pps());
    const ds = await supplyAndEnter(d, needD);
    await tx("dave borrow", (o) => C(LIVE.PUSDC, PT, d).borrow(Td, o));
    dave = { addr: d, pTokens: ds.pTokens, debt: await pU.borrowBalanceStored(d), T: Td };
    check("B3.14", (await pU.borrowBalanceStored(d)).gt(0) && (await ctl.getAccountLiquidity(d))[2].eq(0), `a standing borrower exists (dave: ${sh(ds.pTokens)} pTokens, debt ${usd6(dave.debt)} USDC, healthy)`);
  });

  // ============================================================================================================ B4 stale feeds
  await group("B4 stale feeds", async () => {
    if (!dave) throw new Error("no standing borrower");
    const gp = await vault.guardParams(); const maxFeedAge = gp.maxFeedAge;
    const real = { usdt: (await readFeed(LIVE.USDT_FEED)), usdc: await readFeed(LIVE.USDC_FEED) };
    const liq = A("11C01"); await impersonate(liq);
    // 4.1 the USDT feed alone stale: the vault's totalAssets reverts, the v2 wrapper serves the FALLBACK (stored leg x 0.97 x live USDC price, up to 24 h after its last store; here: the constructor's store, a few
    //     hundred chain-seconds old), pUSDC / pWAVAX stay priced. (v1 said 0 here and froze every account that had entered the share market: the reason for v2.) The full outage timeline is B10.
    await scenario("stale USDT feed only", async () => {
      const liqLive = await ctl.getAccountLiquidity(dave.addr), priceLive = await pricePBP();
      await setFeed(LIVE.USDT_FEED, real.usdt.answer, (await headTs()) - (maxFeedAge + 1000));
      const ta = await expectRevert(() => vault.totalAssets()), c2a = await expectRevert(() => vault.convertToAssets(1_000_000));
      check("B4.1", /FeedInvalid\(2\)/.test(ta || "") && /FeedInvalid\(2\)/.test(c2a || ""), `USDT feed older than the vault's maxFeedAge (${maxFeedAge} s): vault.totalAssets() and convertToAssets() REVERT (${ta})`);
      const ss = await wrapper.shareState(), stored = ss[1], px = await C(LIVE.GUARDED_ORACLE, ORACLE).getPrice(LIVE.USDC), want = shareExpect(fallbackLeg(stored), px), fbAge = (await headTs()) - ss[2].toNumber();
      check("B4.2", fbAge >= 0 && fbAge < 86400 && ss[3] === true && ss[0].eq(0) && (await pricePBP()).eq(want) && want.gt(0) && (await pricePBP()).lt(priceLive) && (await wrapper.getShareUsdPrice()).gt(0) && (await priceUSDC()).gt(0) && (await wrapper.getUnderlyingPrice(LIVE.PWAVAX)).gt(0),
        `v2 FALLBACK: with the vault leg dead the wrapper does NOT return 0 and does not revert: usingFallback ${ss[3]} (stored ${stored} written ${fbAge} s ago), price ${await pricePBP()} = stored x 0.97 x the live USDC price (${want} recomputed) < the live-leg price ${priceLive}; pUSDC and pWAVAX stay priced`);
      const liqD = await ctl.getAccountLiquidity(dave.addr);
      check("B4.3", liqD[0].eq(0) && liqD[2].eq(0) && liqD[1].lt(liqLive[1]) && liqD[1].gt(0), `an account that entered the share market is PRICED (v1: error 13): getAccountLiquidity error ${liqD[0]}, liquidity ${liqD[1]} < ${liqLive[1]} at the live price (the 3 % haircut), shortfall ${liqD[2]}`);
      const bor = await codeOrRevert(() => C(LIVE.PUSDC, PT, dave.addr).callStatic.borrow(1_000)), red = await codeOrRevert(() => C(D.PBP, PT, dave.addr).callStatic.redeem(1_000));
      check("B4.4", bor.code === 0 && red.code === 0, `BOUNDED, NOT FROZEN: dave can still borrow (${JSON.stringify(bor)}) and redeem pTokens (${JSON.stringify(red)}) while the share price is the fallback (the haircut leaves the healthy account healthy)`);
      await impersonate(liq); await setErc20Balance(LIVE.USDC, liq, 10_000_000); await tx("liq approve", (o) => C(LIVE.USDC, ERC20, liq).approve(LIVE.PUSDC, 10_000_000, o));
      const lr = await codeOrRevert(() => C(LIVE.PUSDC, PT, liq).callStatic.liquidateBorrow(dave.addr, 100_000, D.PBP));
      check("B4.5", lr.code === 3, `a HEALTHY account is not liquidatable at the fallback price: rejected with INSUFFICIENT_SHORTFALL (3), not PRICE_ERROR (13) (${JSON.stringify(lr)}); B10 liquidates an insolvent account the same way`);
      const alice = await position(1); const lm = await ctl.getAccountLiquidity(alice.account);
      check("B4.6", lm[0].eq(0), `the live margin accounts (they never entered the share market) are unaffected (getAccountLiquidity error ${lm[0]})`);
      // a supplier who never entered the market can still redeem; the share holder can leave through the vault's ungated redeemInKind only if he holds shares, not pTokens
      const dump = await codeOrRevert(async () => { const r = await C(LIVE.VAULT, VAULT, LIVE.LEDGER).callStatic.redeemInKind(1_000_000, LIVE.LEDGER, LIVE.LEDGER); return BN(r[0]).add(r[1]).gt(0) ? 0 : 1; });
      check("B4.7", dump.code === 0, `the vault's exit path redeemInKind still works with the feed stale (no oracle read): ${JSON.stringify(dump)}`);
    });
    // 4.2 the USDC feed older than the guarded oracle's maxAge (90,000 s) but inside the vault's maxFeedAge: wrapper 0 AND pUSDC 0
    await scenario("stale USDC feed (91,000 s)", async () => {
      await setFeed(LIVE.USDC_FEED, real.usdc.answer, (await headTs()) - 91_000);
      const ok = await codeOrRevert(async () => (await vault.totalAssets()).gt(0) ? 0 : 1);
      check("B4.8", ok.code === 0 && (await pricePBP()).eq(0) && (await priceUSDC()).eq(0) && (await wrapper.getUnderlyingPrice(LIVE.PWAVAX)).gt(0) && (await wrapper.shareState())[3] === false, "USDC feed 91,000 s old (guarded maxAge 90,000, vault maxFeedAge 93,600): the vault still prices, but the wrapper's share price AND pUSDC are 0 (the share price uses the BASE oracle's USDC price; NEVER a fallback when the USDC price is missing: usingFallback false); pWAVAX stays priced");
      const bor = await codeOrRevert(() => C(LIVE.PUSDC, PT, dave.addr).callStatic.borrow(1_000));
      check("B4.9", bor.code === 13, `borrow refused with PRICE_ERROR (${JSON.stringify(bor)})`);
    });
    // 4.3 real passage of time: nothing re-pinned, every feed ages past every threshold, then the feeds come back
    await scenario("time warp past every maxAge, then recovery", async () => {
      await warpRaw(100_000);
      const ageU = await ageOf(LIVE.USDC_FEED);
      check("B4.10", ageU >= 100_000 && (await wrapper.shareState())[3] === false && (await pricePBP()).eq(0) && (await priceUSDC()).eq(0) && (await wrapper.getUnderlyingPrice(LIVE.PWAVAX)).eq(0), `after 100,000 s with no feed update every price is 0 (USDC feed age ${ageU} s): share (the stored value is older than 24 h AND the USDC price is missing: no fallback), pUSDC and pWAVAX`);
      const bor = await codeOrRevert(() => C(LIVE.PUSDC, PT, dave.addr).callStatic.borrow(1_000)); check("B4.11", bor.code === 13, `all borrowing is fail-closed (${JSON.stringify(bor)})`);
      await repin(); // the feeds update again
      check("B4.12", (await pricePBP()).gt(0) && (await priceUSDC()).gt(0), "RESTORE: when the feeds publish again the share price and pUSDC price return without any transaction on our side");
      const l = await ctl.getAccountLiquidity(dave.addr); check("B4.13", l[0].eq(0) && l[2].eq(0), `dave's account answers again (liquidity ${l[1]}, shortfall ${l[2]})`);
      const brw = await codeOrRevert(() => C(LIVE.PUSDC, PT, dave.addr).callStatic.borrow(1_000)); check("B4.14", brw.code === 0, `borrowing works again (${JSON.stringify(brw)})`);
    });
    await repin();
  });

  // ============================================================================================================ B5 liquidation with seize-and-keep
  await group("B5 liquidation", async () => {
    await scenario("liquidation", async () => {
      const erin = A("E41A1"), liq = A("11C0A"); await impersonate(erin); await impersonate(liq);
      const R = await room(); const T = R.room.lt(3_000_000) ? R.room : BN(3_000_000);
      const cf = KNOB.cf;
      // collateral sized so that CF x value = T / 0.98; erin then borrows 98.5 % of her power (capped by the room): underwater after a ~1.5 % fall of the share value
      const rawNeeded = T.mul(100).div(98).mul(E18).div(cf).mul(1_000_000).div(await pps());
      const e = await supplyAndEnter(erin, rawNeeded);
      const pw = await borrowPowerUsdc(erin); let near = pw.raw.mul(985).div(1000); if (near.gt(T)) near = T;
      await tx("erin borrows ~ the maximum", (o) => C(LIVE.PUSDC, PT, erin).borrow(near, o));
      const l1 = await ctl.getAccountLiquidity(erin);
      check("B5.1", l1[2].eq(0) && l1[1].gt(0), `setup: erin supplied ${sh(e.shares)} raw shares (${e.via}) and borrowed ${usd6(near)} USDC (${(Number(near) / Number(pw.raw)).toFixed(4)} of her power); healthy: liquidity ${l1[1]}, shortfall ${l1[2]}`);
      // METHOD: a USDT depeg on the vault's USDT/USD feed (a MOCK, the real feed cannot move). The vault's NAV values its USDT leg with that feed (totalAssets -> _pairToAsset(pp)), and an out-of-band answer does NOT revert totalAssets,
      // so convertToAssets falls by (USDT share of the NAV) x (depeg). Debt is priced by the USDC feed, which is untouched. This is the one real mechanism by which a share price can fall below its debt; no vault storage is edited.
      const usdtReal = (await readFeed(LIVE.USDT_FEED)).answer; const levels = [99, 97, 95, 90, 80, 60, 40];
      let depeg = null, method = "USDT/USD feed depeg (mock)";
      const pps0 = await vault.convertToAssets(1_000_000), ppsPrice0 = await pricePBP();
      for (const lv of levels) {
        await setFeed(LIVE.USDT_FEED, usdtReal.mul(lv).div(100));
        const l = await ctl.getAccountLiquidity(erin);
        if (l[2].gt(0)) { depeg = { lv, short: l[2] }; break; }
      }
      if (!depeg) { // the USDT leg is too small a part of the NAV: the fallback is a synthetic loss of vault assets
        method = "synthetic: the vault's LB bins are burned to a third party (anvil impersonates the vault) - NOT a real exploit path, only a loss of marked assets";
        await setFeed(LIVE.USDT_FEED, usdtReal);
        const pair = C(LIVE.VAULT_PAIR, PAIR); const bs = await vault.bandState(); const lo = bs[0], up = bs[1]; const vaultSigner = await impersonate(LIVE.VAULT);
        const ids = [], amts = []; for (let id = lo; id <= up; id++) { const b = await pair.balanceOf(LIVE.VAULT, id); if (b.gt(0)) { ids.push(id); amts.push(b.mul(30).div(100)); } }
        if (ids.length) await tx("synthetic loss: vault burns 30 % of its bins to a third party", (o) => C(LIVE.VAULT_PAIR, PAIR, LIVE.VAULT).burn(LIVE.VAULT, A("5171"), ids, amts, o));
        const l = await ctl.getAccountLiquidity(erin); if (l[2].gt(0)) depeg = { lv: "n/a (bins)", short: l[2] };
      }
      check("B5.2", !!depeg, `METHOD: ${method}. Underwater found at ${depeg?.lv === undefined ? "none" : depeg.lv + (typeof depeg.lv === "number" ? " % of $1" : "")}: shortfall ${depeg?.short}; vault convertToAssets(1 share) ${pps0} -> ${await vault.convertToAssets(1_000_000)}`);
      if (!depeg) { note("B5.n1", "NO faithful way found to make the account underwater: the liquidation test is not run (the offline unit tests cover the logic)"); return; }
      const gsx = await vault.guardState();
      note("B5.n2", `at that point the vault's own guard reads unsafe=${gsx[0]} reasons=${gsx[2]} (8 = PAIR_LEG_OUT_OF_BAND): deposits are closed, but convertToAssets (the wrapper's input) keeps answering - the wrapper does not look at the guard`);
      // liquidate
      const pShare = await pricePBP(), puN = await priceUSDC();
      const debtBefore = await pU.callStatic.borrowBalanceCurrent(erin), collBefore = await pBP.balanceOf(erin), rate = await pBP.exchangeRateStored();
      const lAfter = await ctl.getAccountLiquidity(erin);
      const debtStored = await pU.borrowBalanceStored(erin);
      const debtVal = debtStored.mul(puN).div(E18), collVal = collBefore.mul(rate).div(E18).mul(pShare).div(E18), cfVal = collVal.mul(cf).div(E18);
      check("B5.3", lAfter[2].gt(0) && lAfter[2].sub(debtVal.sub(cfVal)).abs().lte(debtVal.div(10 ** 9).add(1_000_000)), `SHORTFALL MATH: controller shortfall ${lAfter[2]} == debt value ${debtVal} - CF x collateral value ${cfVal} = ${debtVal.sub(cfVal)}`);
      await setErc20Balance(LIVE.USDC, liq, BN(50_000_000)); await tx("liquidator approve", (o) => C(LIVE.USDC, ERC20, liq).approve(LIVE.PUSDC, ethers.constants.MaxUint256, o));
      const closeFactor = await ctl.closeFactorMantissa(), maxRepay = debtBefore.mul(closeFactor).div(E18);
      const tooMuch = await codeOrRevert(() => C(LIVE.PUSDC, PT, liq).callStatic.liquidateBorrow(erin, maxRepay.add(maxRepay.div(10)).add(10), D.PBP));
      check("B5.4", tooMuch.code === 17 || !!tooMuch.revert, `CLOSE FACTOR 50 %: repaying more than ${usd6(maxRepay)} USDC is refused (${JSON.stringify(tooMuch)})`);
      const repay = maxRepay; const [, seizeExp] = await ctl.liquidateCalculateSeizeTokens(LIVE.PUSDC, D.PBP, repay);
      const incentive = await ctl.liquidationIncentiveMantissa();
      const seizeIndep = repay.mul(incentive).div(E18).mul(puN).div(pShare).mul(E18).div(rate); // repay x 1.08 x priceUSDC / priceShare / exchangeRate
      check("B5.5", seizeExp.sub(seizeIndep).abs().lte(seizeIndep.div(10 ** 9).add(2)), `INCENTIVE: seize ${seizeExp} pTokens == repay x 108 % x p(USDC) / p(share) / exchange rate = ${seizeIndep}`);
      const protoShare = await pBP.protocolSeizeShareMantissa(), toLiq = seizeExp.sub(seizeExp.mul(protoShare).div(E18));
      const usdcBefore = await usdc.balanceOf(liq), reservesBefore = await pBP.totalReserves(), supplyBefore = await pBP.totalSupply();
      const lr = await C(LIVE.PUSDC, PT, liq).callStatic.liquidateBorrow(erin, repay, D.PBP);
      check("B5.6", lr.eq(0), `liquidateBorrow(erin, ${usd6(repay)} USDC, pBP) static call returns 0`);
      const rcpt = await tx("LIQUIDATE", (o) => C(LIVE.PUSDC, PT, liq).liquidateBorrow(erin, repay, D.PBP, o));
      const evI = new utils.Interface(["event LiquidateBorrow(address liquidator, address borrower, uint256 repayAmount, address pTokenCollateral, uint256 seizeTokens)"]);
      const evs = rcpt.logs.filter((l) => l.address.toLowerCase() === LIVE.PUSDC.toLowerCase()).map((l) => { try { return evI.parseLog(l); } catch { return null; } }).filter(Boolean);
      const evSeize = evs[0]?.args.seizeTokens;
      const liqPT = await pBP.balanceOf(liq), erinPT = await pBP.balanceOf(erin), debtAfter = await pU.borrowBalanceStored(erin);
      check("B5.7", usdcBefore.sub(await usdc.balanceOf(liq)).eq(repay) && debtBefore.sub(debtAfter).sub(repay).abs().lte(1_000), `the liquidator paid ${usd6(repay)} USDC and the borrower's debt fell ${usd6(debtBefore)} -> ${usd6(debtAfter)}`);
      check("B5.8", liqPT.eq(toLiq) && collBefore.sub(erinPT).eq(seizeExp), `SEIZE-AND-KEEP: the liquidator holds ${liqPT} pBP (seized ${seizeExp} less the protocol's ${(Number(protoShare) / 1e16).toFixed(1)} % = ${toLiq}) and keeps them as pTokens (not redeemed); the borrower lost ${collBefore.sub(erinPT)}`);
      check("B5.8b", !!evSeize && evSeize.eq(seizeExp) && liqPT.eq(evSeize.sub(evSeize.mul(protoShare).div(E18))), `the liquidator's pToken delta (${liqPT}) equals the LiquidateBorrow event's seizeTokens (${evSeize}) minus the ${(Number(protoShare) / 1e16).toFixed(1)} % protocol seize share (${evSeize ? evSeize.mul(protoShare).div(E18) : "n/a"})`);
      check("B5.9", (await pBP.totalReserves()).gt(reservesBefore) && (await pBP.totalSupply()).eq(supplyBefore.sub(seizeExp.mul(protoShare).div(E18))), "the protocol's seize share went to reserves (pToken supply fell by exactly that share)");
      const liqValue = liqPT.mul(rate).div(E18).mul(pShare).div(E18), paidValue = repay.mul(puN).div(E18);
      check("B5.10", liqValue.gt(paidValue) && liqValue.lt(paidValue.mul(110).div(100)), `the liquidator's seized value ${Number(liqValue) / 1e18} USD exceeds the repaid ${Number(paidValue) / 1e18} USD by ${(Number(liqValue) / Number(paidValue) * 100 - 100).toFixed(2)} % (108 % incentive less the protocol's seize share)`);
      // a second liquidation of the rest is bounded by the close factor again; the borrower's position after
      const lNow = await ctl.getAccountLiquidity(erin);
      note("B5.n3", `after one liquidation the borrower's state: liquidity ${lNow[1]}, shortfall ${lNow[2]} (${lNow[2].gt(0) ? "still underwater: a depeg of this depth leaves a position that needs a second liquidation" : "healthy again"})`);
      // the borrower is NOT liquidatable at the real price: restore the feed
      await setFeed(LIVE.USDT_FEED, usdtReal);
    });
  });

  // ============================================================================================================ B10 stale-feed OUTAGE on the real vault (v2 fallback): after the listing, CF 50 %, the seed and the normal liquidation of B5; one snapshot, nothing survives it
  const ctx = { ctl, vault, wrapper, guarded, pBP, pU, pW, usdc, D, runStep, step, room, borrowPowerUsdc, readPrices, exec, PT, CTL, ERC20, VAULT };
  await runOutage(ctx);

  // ============================================================================================================ B6b rollback AFTER an account entered and borrowed
  await group("B6b rollback after use", async () => {
    await scenario("rollback after use", async () => {
      const d = dave.addr, other = A("07117"); await impersonate(other); await setErc20Balance(LIVE.USDC, other, 5_000_000);
      // a bystander who never touched the share market but borrowed (pWAVAX collateral is borrow-paused; use a pUSDC supplier who redeems)
      await tx("other approves", (o) => C(LIVE.USDC, ERC20, other).approve(LIVE.PUSDC, 5_000_000, o));
      await tx("other mints pUSDC", (o) => C(LIVE.PUSDC, PT, other).mint(5_000_000, o));
      const before = await snapshot();
      await runStep(step("rollback"));
      check("B6.b1", (await ctl.oracle()) === LIVE.GUARDED_ORACLE, "ONE Ledger transaction rolls the oracle back while dave has entered the share market and borrowed");
      const liqD = await ctl.getAccountLiquidity(d);
      check("B6.b2", liqD[0].eq(13), `FROZEN: dave's liquidity query now returns PRICE_ERROR (${liqD[0]}) because the guarded oracle prices the share market at 0`);
      const bor = await codeOrRevert(() => C(LIVE.PUSDC, PT, d).callStatic.borrow(1_000)), red = await codeOrRevert(() => C(D.PBP, PT, d).callStatic.redeem(1_000)), ex = await codeOrRevert(() => C(LIVE.CONTROLLER, CTL, d).callStatic.exitMarket(D.PBP));
      check("B6.b3", bor.code === 13 && red.code === 13, `FROZEN: dave cannot borrow more (${JSON.stringify(bor)}) nor redeem pTokens (${JSON.stringify(red)})`);
      note("B6.b4", `exitMarket(pBP) by dave while debt is open: ${JSON.stringify(ex)} (12 = NONZERO_BORROW_BALANCE)`);
      const liq = A("11C0B"); await impersonate(liq); await setErc20Balance(LIVE.USDC, liq, 10_000_000); await tx("liq approve", (o) => C(LIVE.USDC, ERC20, liq).approve(LIVE.PUSDC, 10_000_000, o));
      const lr = await codeOrRevert(() => C(LIVE.PUSDC, PT, liq).callStatic.liquidateBorrow(d, 100_000, D.PBP));
      check("B6.b5", lr.code === 13 || !!lr.revert, `FROZEN: dave cannot be liquidated either (${JSON.stringify(lr)}) - an account that entered the share market is a blind spot until the wrapper is back`);
      // repay still works
      await setErc20Balance(LIVE.USDC, d, 10_000_000); await tx("dave approve", (o) => C(LIVE.USDC, ERC20, d).approve(LIVE.PUSDC, ethers.constants.MaxUint256, o));
      await tx("dave repays during the rollback", (o) => C(LIVE.PUSDC, PT, d).repayBorrow(ethers.constants.MaxUint256, o));
      check("B6.b6", (await pU.borrowBalanceStored(d)).eq(0), "REPAY still works during the rollback (repayBorrow reads no price): dave's debt is 0");
      const red2 = await codeOrRevert(() => C(D.PBP, PT, d).callStatic.redeem(1_000)), ex2 = await codeOrRevert(() => C(LIVE.CONTROLLER, CTL, d).callStatic.exitMarket(D.PBP));
      note("B6.b7", `with the debt repaid, dave's pBP redeem is ${JSON.stringify(red2)} and exitMarket is ${JSON.stringify(ex2)} (redeem 13 = PRICE_ERROR and exitMarket 14 = REJECTION with opaque code 13 mean his pTokens stay stuck until the wrapper is re-applied)`);
      // others are unaffected
      const rOther = await codeOrRevert(() => C(LIVE.PUSDC, PT, other).callStatic.redeem(1_000_000)), live1 = await ctl.getAccountLiquidity((await exec.positions(1)).account);
      check("B6.b8", rOther.code === 0 && live1[0].eq(0), `accounts that never entered the share market are unaffected: a pUSDC supplier redeems (${JSON.stringify(rOther)}), live margin position 1 liquidity error ${live1[0]}`);
      const mid = await snapshot(); const dd = diff(before, mid);
      check("B6.b9", dd.positions.length === 0 && dd.orders.length === 0 && dd.codehash.length === 0, "no live margin position, order or code hash moved during the rollback", dd.positions.concat(dd.orders, dd.codehash).join("; "));
      await runStep(step("oracleSwap"));
      const l3 = await ctl.getAccountLiquidity(d);
      check("B6.b10", l3[0].eq(0) && (await C(D.PBP, PT, d).callStatic.redeem(1_000)).eq(0), "re-applying the wrapper unfreezes everything: dave's liquidity answers and his pTokens redeem again");
      note("B6.n1", "CONCLUSION: the one-transaction rollback is a clean undo only while NO account has entered the share market. After that it freezes those accounts' borrow, redeem and liquidation until the wrapper is re-applied; the safer reaction to a bad share price is the CF -> 0 / mint pause path (and, for a stale feed, the v2 wrapper's 24 h fallback: B4, B10), not the rollback.");
    });
  });

  // ============================================================================================================ B7 manipulation
  await group("B7 manipulation", async () => {
    const CF = KNOB.cf;
    const U = await vault.totalSupply();
    const holders = [["Ledger (its shares at this point)", (await vault.balanceOf(LIVE.LEDGER))], ["50 % of the supply", U.div(2)], ["10 % of the supply", U.div(10)]];
    const measure = async () => { const a = await vault.convertToAssets(1_000_000); const g = await vault.guardState(); const d = await vault.maxDeposit(LIVE.LEDGER).catch(() => BN(-1)); return { pps: a, price: await pricePBP(), nav: await vault.totalAssets(), supply: await vault.totalSupply(), guard: g[2], maxDeposit: d, active: (await C(LIVE.VAULT_PAIR, PAIR).getActiveId()) }; };
    const powerOf = (m, shares) => shares.mul(m.pps).div(1_000_000).mul(CF).div(E18); // borrow power in raw USDC for a holder of `shares` raw shares
    const base = await measure();
    note("B7.n0", `BASELINE: NAV ${usd6(base.nav)} USDC vs depositCap ${usd6(await vault.depositCap())}, supply ${sh(base.supply)}, 1 share = ${usd6(base.pps)} USDC, wrapper price ${base.price}, guard reasons ${base.guard}, maxDeposit ${usd6(base.maxDeposit)}; borrow power at CF 50 % of ALL ${sh(base.supply)} shares = ${usd6(powerOf(base, base.supply))} USDC`);
    const table = [];
    async function report(id, label, cost, m) {
      const rows = holders.map(([n, s]) => ({ holder: n, extra: powerOf(m, s).sub(powerOf(base, s)) }));
      const worst = rows.reduce((a, b) => (b.extra.gt(a.extra) ? b : a), rows[0]);
      table.push({ id, label, cost: sh(cost), pps: sh(m.pps), nav: sh(m.nav), guard: sh(m.guard), extra: Object.fromEntries(rows.map((r) => [r.holder, sh(r.extra)])) });
      note(`B7.n${table.length}`, `${label}: cost ${usd6(cost)} USDC | 1 share ${usd6(base.pps)} -> ${usd6(m.pps)} USDC (${((Number(m.pps) / Number(base.pps) - 1) * 1e4).toFixed(2)} bp) | NAV ${usd6(m.nav)} | guard reasons ${m.guard} | extra borrow power at CF 50 %: ${rows.map((r) => `${r.holder}: ${usd6(r.extra)}`).join("; ")}`);
      return { rows, worst };
    }
    // M1 donate USDC to the vault (idle balances count in the NAV; a donation bypasses the 200 USDC depositCap, which only bounds deposits)
    await scenario("donate USDC to the vault", async () => {
      const donor = A("D0A01"); await impersonate(donor);
      let k1 = 0; for (const D1 of [1_000_000, 20_000_000]) {
        await setErc20Balance(LIVE.USDC, donor, BN(D1)); await tx("donate USDC", (o) => C(LIVE.USDC, ERC20, donor).transfer(LIVE.VAULT, D1, o));
        const m = await measure(); const { rows, worst } = await report("B7.1", `donate ${usd6(D1)} USDC to the vault`, BN(D1), m);
        check(k1++ === 0 ? "B7.1a" : "B7.1b", m.pps.gte(base.pps) && worst.extra.lt(BN(D1)) && worst.extra.lte(BN(D1).mul(CF).div(E18).add(2)), `a ${usd6(D1)} USDC donation raises the share price ${usd6(base.pps)} -> ${usd6(m.pps)} but the extra borrow power of the BEST-placed holder (${worst.holder}: ${usd6(worst.extra)} USDC) is below the cost and below CF x donation (${usd6(BN(D1).mul(CF).div(E18))}); the NAV is now ${usd6(m.nav)} vs the ${usd6(await vault.depositCap())} cap`);
      }
    });
    await scenario("donate USDT to the vault", async () => {
      const donor = A("D0A02"); await impersonate(donor); const D2 = 5_000_000;
      await setErc20Balance(LIVE.USDT, donor, BN(D2)); await tx("donate USDT", (o) => C(LIVE.USDT, ERC20, donor).transfer(LIVE.VAULT, D2, o));
      const m = await measure(); const { worst } = await report("B7.2", `donate ${usd6(D2)} USDT to the vault`, BN(D2), m);
      check("B7.2", worst.extra.lt(BN(D2)), `donated USDT is valued with the USDT feed: extra power ${usd6(worst.extra)} < cost ${usd6(D2)}`);
    });
    // M3 donate to the pair itself and then swap: a transfer to the pair is not the vault's balance until someone swaps against it
    await scenario("pool: donate to the pair, then swap through it", async () => {
      const pairAddr = LIVE.VAULT_PAIR, trader = A("7ADE01"); await impersonate(trader);
      const BIG = BN(300_000).mul(1e6);
      await setErc20Balance(LIVE.USDC, trader, BIG.mul(2)); await setErc20Balance(LIVE.USDT, trader, BIG.mul(2));
      await tx("trader approves router USDC", (o) => C(LIVE.USDC, ERC20, trader).approve(LIVE.VAULT_ROUTER, ethers.constants.MaxUint256, o)); await tx("trader approves router USDT", (o) => C(LIVE.USDT, ERC20, trader).approve(LIVE.VAULT_ROUTER, ethers.constants.MaxUint256, o));
      await tx("donate 5 USDC to the pair", (o) => C(LIVE.USDC, ERC20, trader).transfer(pairAddr, 5_000_000, o));
      const mD = await measure();
      note("B7.3", `donating USDC to the PAIR: the vault's share price ${mD.pps.eq(base.pps) ? "did NOT change" : "CHANGED"} (${usd6(base.pps)} -> ${usd6(mD.pps)}); expected (bin reserves are accounted by the pair, not by its token balance) - a measurement of the live vault, not a guarantee`);
      const router = C(LIVE.VAULT_ROUTER, DLMM_ROUTER, trader); const startBal = { usdc: await usdc.balanceOf(trader), usdt: await usdt.balanceOf(trader) };
      let amounts = [BN(1_000).mul(1e6), BN(10_000).mul(1e6), BN(100_000).mul(1e6)], last = base;
      const uoracle = mocks[LIVE.USDT_FEED.toLowerCase()].answer.mul(BN(10).pow(10)).div(1); // USDT feed answer scaled to 1e18
      let k4 = 0; for (const amt of amounts) {
        const u0 = await usdc.balanceOf(trader), t0 = await usdt.balanceOf(trader);
        try { await tx(`swap ${usd6(amt)} USDC -> USDT in the vault's pool`, (o) => router.swapExactTokensForTokens(amt, 0, { pairBinSteps: [1], versions: [2], tokenPath: [LIVE.USDC, LIVE.USDT] }, trader, 4_000_000_000, o)); }
        catch (e) { note(["B7.4a", "B7.4b", "B7.4c"][k4++], `swap of ${usd6(amt)} USDC reverted (${String(e.message).slice(0, 120)}): the pool is not deep enough for this size; escalation stops`); break; }
        const spent = u0.sub(await usdc.balanceOf(trader)), got = (await usdt.balanceOf(trader)).sub(t0);
        const gotValue = got.mul(uoracle).div(mocks[LIVE.USDC_FEED.toLowerCase()].answer.mul(BN(10).pow(10)));  // USDT received, valued in USDC at the oracle
        const cost = spent.sub(gotValue); const m = await measure(); last = m;
        const { worst } = await report("B7.4", `swap ${usd6(amt)} USDC -> USDT through the pool (active bin ${base.active} -> ${m.active})`, cost.lt(0) ? BN(0) : cost, m);
        check(["B7.4a", "B7.4b", "B7.4c"][k4++], worst.extra.lte((cost.lt(0) ? BN(0) : cost).add(2)), `a ${usd6(amt)} USDC swap moved the active bin ${base.active} -> ${m.active}; swap cost at the oracle ${usd6(cost)} USDC vs extra borrow power of the best-placed holder ${usd6(worst.extra)} (${worst.holder}); guard reasons ${m.guard}`);
      }
      // the guard: pool/oracle deviation closes deposits but is invisible to convertToAssets / the wrapper
      const dep = await codeOrRevert(async () => { await C(LIVE.VAULT, VAULT, LIVE.LEDGER).callStatic.deposit(1_000_000, LIVE.LEDGER); return 0; });
      note("B7.5", `after the swaps: vault guard reasons ${last.guard} (16 = POOL_ORACLE_DEVIATION), maxDeposit ${usd6(last.maxDeposit)}, a deposit ${dep.revert ? "reverts " + dep.revert : "is accepted"}; the wrapper price is ${last.price} (nonzero) - the wrapper does not read the guard (a design decision: report to the integrator)`);
      // and back the other way
      const t1 = await usdt.balanceOf(trader);
      await tx("swap back USDT -> USDC", (o) => router.swapExactTokensForTokens(t1.sub(startBal.usdt).gt(0) ? t1.sub(startBal.usdt) : 1_000_000, 0, { pairBinSteps: [1], versions: [2], tokenPath: [LIVE.USDT, LIVE.USDC] }, trader, 4_000_000_000, o));
      const back = await measure();
      check("B7.6", back.pps.gte(base.pps.sub(1)), `a round trip through the pool leaves the share price at or above where it started (${usd6(base.pps)} -> ${usd6(back.pps)}): the trader paid fees and slippage to the LPs`);
    });
    results.data.b7 = table;
  });

  // ============================================================================================================ B9 final read-back
  await group("B9 final read-back", async () => {
    await repin();
    const S9 = await snapshot({ extraMarkets: [] }), d = diff(S0, S9);
    check("B9.1", d.positions.length === 0 && d.orders.length === 0, "the live margin positions (1 and 2) and orders (1..4) are field-for-field unchanged at the end (debt interest excluded)", d.positions.concat(d.orders).join("; "));
    check("B9.2", d.proxies.length === 0 && d.slots.length === 0 && d.codehash.length === 0, "the margin proxies (implementation, admin, 70 raw storage slots each) and every code hash in the account's path are unchanged", d.proxies.concat(d.slots.map((s) => `${s.proxy}#${s.slot}`), d.codehash).join("; "));
    const cfg = d.lending.filter((x) => !/^markets\.(pWAVAX|pUSDC)\.(totalSupply|totalBorrows|totalReserves|exchangeRate|cash)/.test(x));
    check("B9.3", cfg.length === 1 && /^allMarkets/.test(cfg[0]), `lending configuration of the existing markets (CF, caps, pauses, floor, admin, rate model, reserve factor, flash flag) and of the controller (close factor, incentive, guardian) is unchanged; only allMarkets gained the new market`, cfg.join("; "));
    check("B9.4", d.pointers.length === 1 && d.pointers[0].startsWith("controllerOracle") && S9.pointers.controllerOracle === D.WRAPPER, `the only pointer that moved is controller.oracle() -> the wrapper (risk engine and quoter still ${S9.pointers.riskEngineOracle})`);
    const bal = d.lending.filter((x) => /^markets\.(pWAVAX|pUSDC)\.(totalSupply|totalBorrows|totalReserves|exchangeRate|cash)/.test(x));
    note("B9.n1", `balance-type fields of the existing markets that moved because the TEST users supplied/borrowed (expected): ${bal.join(" | ") || "none"}`);
    const mk = await ctl.markets(D.PBP);
    check("B9.5", mk[0] && mk[1].eq(KNOB.cf) && (await ctl.borrowGuardianPaused(D.PBP)) && (await pBP.flashLoansPaused()) && (await ctl.borrowCaps(D.PBP)).gt(0), `the new market ends as designed: listed, CF ${mk[1]}, borrow paused, flash loans paused, cap ${await ctl.borrowCaps(D.PBP)}`);
    const touchedAll = results.data.ceremonyTouched || [];
    const path = PATH_CONTRACTS(); const inPath = Object.entries(path).filter(([, a]) => touchedAll.map((x) => x.toLowerCase()).includes(a.toLowerCase())).map(([n]) => n);
    if (touchedAll.length) check("B9.6", inPath.every((n) => ["controller", "dlmmVault"].includes(n)), `CONTRACTS TOUCHED (state written) by the whole ceremony: ${touchedAll.length} addresses; of those in the account's path: ${inPath.join(", ")} (expected: the controller [oracle pointer, new market, flags] and the DLMM vault [the seed transfer]); the new market ${D.PBP} and the wrapper's market ${D.WRAPPER} are new`, inPath.join(","));
    else note("B9.6", "state-diff tracer unavailable: the list of touched contracts could not be produced");
    note("B9.n3", WRAPPER_ON ? "the PHAR step (the rewards work's rehearsal folded in, checks B11.*) runs AFTER this read-back, as the last group: it moves shares, harvests and deploys a distributor, so it is not part of the state comparison above." : "the PHAR step (B11) was SKIPPED (REH_WRAPPER=0): the wrapper-split distribution of the rewards work was not rehearsed in this run.");
    note("B9.n2", `GAS of the ceremony txs: ${JSON.stringify(results.data.gasCeremony || {})}`);
    fs.writeFileSync(path2("snapshot-end.json"), JSON.stringify(S9)); fs.writeFileSync(path2("diff-end.json"), JSON.stringify(d));
  });
  // ============================================================================================================ B11 the PHAR distribution with the DEPLOYED market as the wrapper holder (LAST group; REH_WRAPPER=0 skips it)
  if (WRAPPER_ON) await runPhar(ctx);
  else note("B11.n0", "the PHAR step was SKIPPED (REH_WRAPPER=0)");
  finish();
}
function path2(n) { return path.join(OUTDIR, n); }

// READ-BACK of the live pilot: a JSON snapshot (margin positions and orders, margin proxies' raw storage + implementation slots, the lending state of every EXISTING market, the oracle pointers
// of controller / risk engine / quoter, code hashes of the contracts in the account's path, the DLMM vault totals) and a field-by-field diff. READ ONLY: nothing is sent.
// Used by the fork rehearsal (B1 before/after the oracle swap, B9 end) and by the operator before / after the live ceremony.
import { ethers, utils, BN, C, LIVE, provider, blockNumber } from "./lib.mjs";

const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";
const EXEC_ABI = ["function nextPositionId() view returns (uint256)", "function positions(uint256) view returns (uint256 id, address owner, address account, address marginPToken, address positionPToken, address debtPToken, uint256 lockedMarginPTokens, uint256 initialNotionalUsd, uint256 borrowedPrincipal, uint16 requestedLeverageX100, uint8 side, uint8 status)", "function orderExecutor() view returns (address)"];
const REG_ABI = ["function nextOrderId() view returns (uint256)", "function getOrder(uint256) view returns (tuple(uint256 positionId, address owner, uint8 kind, bool triggerAbove, uint256 triggerPriceE18, uint16 closeBps, uint16 maxSlippageBps, uint64 expiry, uint64 createdAt, uint64 updatedAt, uint8 status))", "function adapter() view returns (address)", "function paused() view returns (bool)", "function admin() view returns (address)"];
const PT_ABI = ["function balanceOf(address) view returns (uint256)", "function borrowBalanceStored(address) view returns (uint256)", "function exchangeRateStored() view returns (uint256)", "function totalSupply() view returns (uint256)", "function totalBorrows() view returns (uint256)", "function totalReserves() view returns (uint256)", "function getCash() view returns (uint256)", "function flashLoansPaused() view returns (bool)", "function admin() view returns (address)", "function implementation() view returns (address)", "function interestRateModel() view returns (address)", "function reserveFactorMantissa() view returns (uint256)", "function underlying() view returns (address)"];
const CTL_ABI = ["function oracle() view returns (address)", "function admin() view returns (address)", "function closeFactorMantissa() view returns (uint256)", "function liquidationIncentiveMantissa() view returns (uint256)", "function getAllMarkets() view returns (address[])", "function markets(address) view returns (bool,uint256,bool)", "function borrowCaps(address) view returns (uint256)", "function mintGuardianPaused(address) view returns (bool)", "function borrowGuardianPaused(address) view returns (bool)", "function borrowCashFloor(address) view returns (uint256)", "function pauseGuardian() view returns (address)", "function transferGuardianPaused() view returns (bool)", "function seizeGuardianPaused() view returns (bool)", "function isolatedMarginRiskHook() view returns (address)", "function comptrollerImplementation() view returns (address)", "function peridottrollerImplementation() view returns (address)"];
const RISK_ABI = ["function getMetrics(address) view returns (tuple(uint256 grossAssetValueUsd,uint256 debtValueUsd,int256 equityUsd,uint256 initialRequirementUsd,uint256 maintenanceRequirementUsd,uint256 healthFactorBps,uint256 leverageX100))", "function oracle() view returns (address)"];
const QUOTER_ABI = ["function oracle() view returns (address)"];
const ERC20_ABI = ["function balanceOf(address) view returns (uint256)", "function totalSupply() view returns (uint256)"];
const VAULT_ABI = ["function totalAssets() view returns (uint256)", "function totalSupply() view returns (uint256)", "function convertToAssets(uint256) view returns (uint256)", "function freeBalance(address,address) view returns (uint256)", "function lockedBalance(address,address) view returns (uint256)"];
const PROXIES = { executor: LIVE.M_EXECUTOR, riskEngine: LIVE.M_RISK_ENGINE, liquidator: LIVE.M_LIQUIDATOR, registry: LIVE.M_REGISTRY, config: LIVE.M_CONFIG };
const SLOTS = 70;

const t = async (fn) => { try { const r = await fn(); return r === undefined ? "n/a" : r; } catch { return "n/a"; } };
const s = (x) => (x === "n/a" ? x : x && x._isBigNumber ? x.toString() : x);

/** every contract whose code is in the account's path (lending + margin); code hash read from the chain */
export const PATH_CONTRACTS = () => ({
  controller: LIVE.CONTROLLER, pWAVAX: LIVE.PWAVAX, pUSDC: LIVE.PUSDC, guardedOracle: LIVE.GUARDED_ORACLE, sourceOracle: LIVE.SOURCE_ORACLE, rateModel: LIVE.RATE_MODEL, pTokenDelegate: LIVE.PTOKEN_DELEGATE,
  marginExecutor: LIVE.M_EXECUTOR, marginRiskEngine: LIVE.M_RISK_ENGINE, marginLiquidator: LIVE.M_LIQUIDATOR, marginRegistry: LIVE.M_REGISTRY, marginConfig: LIVE.M_CONFIG, marginVault: LIVE.M_VAULT, marginQuoter: LIVE.M_QUOTER,
  closeAdapterV1: LIVE.M_CLOSE_ADAPTER_V1, dlmmVault: LIVE.VAULT, dlmmVaultImpl: LIVE.VAULT_IMPL,
});

export async function snapshot(opts = {}) {
  const exec = C(LIVE.M_EXECUTOR, EXEC_ABI), reg = C(LIVE.M_REGISTRY, REG_ABI), risk = C(LIVE.M_RISK_ENGINE, RISK_ABI), ctl = C(LIVE.CONTROLLER, CTL_ABI);
  const pu = C(LIVE.PUSDC, PT_ABI), pw = C(LIVE.PWAVAX, PT_ABI), usdc = C(LIVE.USDC, ERC20_ABI), wavax = C(LIVE.WAVAX, ERC20_ABI), mvault = C(LIVE.M_VAULT, VAULT_ABI), vault = C(LIVE.VAULT, VAULT_ABI);
  const S = { block: await blockNumber(), positions: {}, orders: {}, proxies: {}, misc: {}, lending: {}, pointers: {}, codehash: {}, metrics: {}, dlmm: {} };
  const next = (await exec.nextPositionId()).toNumber();
  for (let id = 1; id < next; id++) {
    const p = await exec.positions(id), acct = p.account;
    S.positions[id] = {
      owner: p.owner, account: acct, marginPToken: p.marginPToken, positionPToken: p.positionPToken, debtPToken: p.debtPToken, lockedMarginPTokens: p.lockedMarginPTokens.toString(),
      initialNotionalUsd: p.initialNotionalUsd.toString(), borrowedPrincipal: p.borrowedPrincipal.toString(), leverageX100: p.requestedLeverageX100, side: p.side, status: p.status,
      pWavax: (await pw.balanceOf(acct)).toString(), pUsdc: (await pu.balanceOf(acct)).toString(), debtStored: (await pu.borrowBalanceStored(acct)).toString(),
      usdc: (await usdc.balanceOf(acct)).toString(), wavax: (await wavax.balanceOf(acct)).toString(),
      vaultFree: (await mvault.freeBalance(p.owner, LIVE.PUSDC)).toString(), vaultLocked: (await mvault.lockedBalance(p.owner, LIVE.PUSDC)).toString(),
    };
    const m = await t(() => risk.getMetrics(acct));
    S.metrics[id] = m === "n/a" ? m : { gross: m[0].toString(), debt: m[1].toString(), equity: m[2].toString(), initial: m[3].toString(), maintenance: m[4].toString(), health: m[5].toString(), leverage: m[6].toString() };
  }
  const nextOrder = (await reg.nextOrderId()).toNumber();
  S.misc.nextPositionId = next; S.misc.nextOrderId = nextOrder;
  for (let id = 1; id < nextOrder; id++) {
    const o = await reg.getOrder(id);
    S.orders[id] = { positionId: o.positionId.toString(), owner: o.owner, kind: o.kind, triggerAbove: o.triggerAbove, triggerPriceE18: o.triggerPriceE18.toString(), closeBps: o.closeBps, maxSlippageBps: o.maxSlippageBps, expiry: o.expiry.toString(), createdAt: o.createdAt.toString(), updatedAt: o.updatedAt.toString(), status: o.status };
  }
  S.misc.registryPaused = await t(() => reg.paused()); S.misc.registryAdmin = await t(() => reg.admin());
  S.misc.orderExecutor = await t(() => exec.orderExecutor()); S.misc.registryAdapter = await t(() => reg.adapter());
  for (const [name, addr] of Object.entries(PROXIES)) {
    const slots = {};
    for (let i = 0; i < SLOTS; i++) { const v = await provider.getStorageAt(addr, i); if (!/^0x0*$/.test(v)) slots[i] = v; }
    S.proxies[name] = { impl: utils.hexDataSlice(await provider.getStorageAt(addr, IMPL_SLOT), 12), admin: utils.hexDataSlice(await provider.getStorageAt(addr, ADMIN_SLOT), 12), slots };
  }
  // lending state of the EXISTING markets
  S.pointers = { controllerOracle: await t(() => ctl.oracle()), riskEngineOracle: await t(() => risk.oracle()), quoterOracle: await t(() => C(LIVE.M_QUOTER, QUOTER_ABI).oracle()) };
  const L = S.lending;
  L.controller = { admin: s(await t(() => ctl.admin())), closeFactor: s(await t(() => ctl.closeFactorMantissa())), incentive: s(await t(() => ctl.liquidationIncentiveMantissa())), pauseGuardian: s(await t(() => ctl.pauseGuardian())),
    transferPaused: s(await t(() => ctl.transferGuardianPaused())), seizePaused: s(await t(() => ctl.seizeGuardianPaused())), marginHook: s(await t(() => ctl.isolatedMarginRiskHook())) };
  const all = await t(() => ctl.getAllMarkets()); L.allMarkets = all === "n/a" ? all : all.map((a) => a.toLowerCase());
  L.markets = {};
  for (const [name, addr] of [["pWAVAX", LIVE.PWAVAX], ["pUSDC", LIVE.PUSDC]].concat((opts.extraMarkets || []).map((a, i) => [`extra${i}`, a]))) {
    const m = C(addr, PT_ABI), mk = await t(() => ctl.markets(addr));
    L.markets[name] = {
      isListed: mk === "n/a" ? mk : mk[0], collateralFactor: mk === "n/a" ? mk : mk[1].toString(), borrowCap: s(await t(() => ctl.borrowCaps(addr))), mintPaused: await t(() => ctl.mintGuardianPaused(addr)), borrowPaused: await t(() => ctl.borrowGuardianPaused(addr)),
      cashFloor: s(await t(() => ctl.borrowCashFloor(addr))), totalSupply: s(await t(() => m.totalSupply())), totalBorrows: s(await t(() => m.totalBorrows())), totalReserves: s(await t(() => m.totalReserves())), cash: s(await t(() => m.getCash())),
      exchangeRate: s(await t(() => m.exchangeRateStored())), flashLoansPaused: await t(() => m.flashLoansPaused()), admin: await t(() => m.admin()), implementation: await t(() => m.implementation()),
      rateModel: await t(() => m.interestRateModel()), reserveFactor: s(await t(() => m.reserveFactorMantissa())),
    };
  }
  for (const [name, addr] of Object.entries(PATH_CONTRACTS())) S.codehash[name] = utils.keccak256(await provider.getCode(addr));
  S.codehash.controllerImpl = await t(async () => { const a = await t(() => ctl.peridottrollerImplementation()); const b = a === "n/a" ? await ctl.comptrollerImplementation() : a; return utils.keccak256(await provider.getCode(b)); });
  S.dlmm = { totalSupply: s(await t(() => vault.totalSupply())), totalAssets: s(await t(() => vault.totalAssets())), convertToAssets1: s(await t(() => vault.convertToAssets(1_000_000))) };
  return S;
}

/** Differences between two snapshots. `ignore` lists position fields that legitimately move with time (debt interest). */
export function diff(a, b, opts = {}) {
  const out = { positions: [], orders: [], slots: [], proxies: [], misc: [], lending: [], pointers: [], codehash: [], metrics: [], dlmm: [] };
  const ignore = new Set(opts.ignorePositionFields || ["debtStored"]);
  for (const id of Object.keys(a.positions)) for (const k of Object.keys(a.positions[id])) {
    if (ignore.has(k)) continue;
    if (a.positions[id][k] !== b.positions[id]?.[k]) out.positions.push(`position ${id}.${k}: ${a.positions[id][k]} -> ${b.positions[id]?.[k]}`);
  }
  for (const id of Object.keys(a.orders)) for (const k of Object.keys(a.orders[id])) if (JSON.stringify(a.orders[id][k]) !== JSON.stringify(b.orders[id]?.[k])) out.orders.push(`order ${id}.${k}: ${a.orders[id][k]} -> ${b.orders[id]?.[k]}`);
  for (const [name, p] of Object.entries(a.proxies)) {
    const q = b.proxies[name];
    for (const k of ["impl", "admin"]) if (p[k] !== q[k]) out.proxies.push(`${name}.${k}: ${p[k]} -> ${q[k]}`);
    for (let i = 0; i < SLOTS; i++) if (p.slots[i] !== q.slots[i]) out.slots.push({ proxy: name, slot: i, before: p.slots[i] ?? "0x0", after: q.slots[i] ?? "0x0" });
  }
  for (const k of Object.keys(a.misc)) if (a.misc[k] !== b.misc[k]) out.misc.push(`${k}: ${a.misc[k]} -> ${b.misc[k]}`);
  for (const k of Object.keys(a.pointers)) if (a.pointers[k] !== b.pointers[k]) out.pointers.push(`${k}: ${a.pointers[k]} -> ${b.pointers[k]}`);
  for (const k of Object.keys(a.codehash)) if (a.codehash[k] !== b.codehash[k]) out.codehash.push(`${k}: ${a.codehash[k]} -> ${b.codehash[k]}`);
  const flat = (o, pre = "") => Object.entries(o).flatMap(([k, v]) => (v && typeof v === "object" && !Array.isArray(v) ? flat(v, `${pre}${k}.`) : [[`${pre}${k}`, JSON.stringify(v)]]));
  const fa = Object.fromEntries(flat(a.lending)), fb = Object.fromEntries(flat(b.lending));
  for (const k of new Set([...Object.keys(fa), ...Object.keys(fb)])) if (fa[k] !== fb[k]) out.lending.push(`${k}: ${fa[k]} -> ${fb[k]}`);
  const ma = Object.fromEntries(flat(a.metrics)), mb = Object.fromEntries(flat(b.metrics));
  for (const k of new Set([...Object.keys(ma), ...Object.keys(mb)])) if (ma[k] !== mb[k]) out.metrics.push(`${k}: ${ma[k]} -> ${mb[k]}`);
  for (const k of Object.keys(a.dlmm)) if (a.dlmm[k] !== b.dlmm[k]) out.dlmm.push(`${k}: ${a.dlmm[k]} -> ${b.dlmm[k]}`);
  return out;
}

// B10: the STALE-FEED OUTAGE on the REAL DLMM vault, against the v2 wrapper (PharaohDlmmShareOracle with the 24 h / -3 % fallback and the bounded permissionless poke()).
// Imported by rehearsal.mjs; runs AFTER the listing, the CF-50 % activation, the seed and the normal share liquidation (B5), inside ONE evm snapshot (nothing survives into B6b / B7 / B9).
// THE ASSISTANT HAS NOT RUN THIS ON A FORK (it has no endpoint): every check below has only ever been through DRY / syntax checks; the user runs it.
//
// WHY THE TIMELINE LOOKS LIKE THIS (read before changing it):
//   * the vault leg dies when the USDT/USD feed is older than the vault's maxFeedAge (93,600 s), but the fallback lives only 24 h (86,400 s) after the last stored value. With nothing but the
//     constructor's store, a feed that stopped at t0 gives NO fallback at t0 + 93,601 s (stored age > 24 h): the fallback exists only because a keeper pokes (any account may). So the harness
//     plays the keeper: it pokes while the vault still answers (USDT age 80,000 s), exactly as a poke cadence of a few hours would, and only then lets the feed age past 93,600 s.
//   * the USDT mock gets an EXPLICIT updatedAt (lib.repin() skips feeds with an explicit timestamp); AVAX and USDC are re-pinned fresh after every time movement (the base oracle's USDC maxAge is
//     90,000 s, AVAX 1,200 s). The vault's USDC feed and the base oracle's USDC feed are the SAME address (B0.f2), so one re-pinned mock serves both.
//   * eth_call / callStatic see block.timestamp == the head block's timestamp (probed on anvil 1.7.1), so the 24 h boundary is tested with static calls only (a mined transaction moves the head by 1 s).
import {
  ethers, BN, A, C, LIVE, signer, check, note, group, provider, rpc, tx, expectRevert, codeOrRevert, impersonate, setErc20Balance, setFeed, readFeed, warp, warpTo, headTs, scenario, mocks,
} from "./lib.mjs";

const E18 = BN(10).pow(18);
const usd6 = (x) => (Number(BN(x)) / 1e6).toFixed(6);
const WINDOW = 86400, HAIR = 300, UP_BPS = 200, UP_INT = 3600;

/** The wrapper's share price from first principles, in the contract's integer order: (leg x USD price of the asset (1e18) x 10^(18-shareDecimals)) / 10^assetDecimals (shares and USDC both have 6 decimals). */
export const shareExpect = (leg, usdcUsd18) => BN(leg).mul(usdcUsd18).mul(BN(10).pow(12)).div(BN(10).pow(6));
/** the fallback leg: stored x (10000 - 300) / 10000 */
export const fallbackLeg = (stored) => BN(stored).mul(10000 - HAIR).div(10000);
/** what poke() must do, written from the specification (BRIEF-v2), not from the contract code: { stored, value } */
export function expectPoke(prev, prevAt, live, now) {
  prev = BN(prev); live = BN(live);
  if (now - prevAt <= WINDOW && live.gt(prev)) {
    if (now - prevAt < UP_INT) return { stored: false };
    const cap = prev.mul(10000 + UP_BPS).div(10000);
    return { stored: true, value: live.gt(cap) ? cap : live };
  }
  return { stored: true, value: live };
}

const FEED_INVALID_SEL = ethers.utils.id("FeedInvalid(uint8)").slice(0, 10);
/** the RAW revert data of an eth_call (no ABI decoding): null when the call did not revert */
async function rawRevert(to, data) {
  try { await provider.send("eth_call", [{ to, data }, "latest"]); return null; }
  catch (e) {
    const cands = [e?.error?.data, e?.data, e?.error?.error?.data, e?.body, e?.error?.body, e?.message];
    for (const x of cands) { const t = typeof x === "string" ? x : x && typeof x.data === "string" ? x.data : ""; const m = /0x[0-9a-fA-F]*/.exec(t); if (m && m[0].length >= 2) return m[0]; }
    return "0x";   // reverted with data we could not read: treated as an empty revert
  }
}
export async function runOutage(c) {
  const { ctl, vault, wrapper, guarded, pBP, pU, pW, usdc, D, runStep, step, room, borrowPowerUsdc, readPrices, exec, PT, CTL, ERC20, VAULT } = c;
  const usdcUsd = () => guarded.getPrice(LIVE.USDC);                 // the BASE oracle's live USDC price (1e18): the same read the wrapper makes
  const priceBP = () => wrapper.getUnderlyingPrice(D.PBP);
  const st = async () => { const s = await wrapper.shareState(); return { live: s[0], stored: s[1], at: s[2].toNumber(), usingFallback: s[3], left: s[4] }; }; // by index (struct names collide with Array methods in ethers v5)
  const poked = async (label) => { const r = await tx(label, (o) => wrapper.connect(signer(A("90CE1"))).poke(o)); return r; };
  const pokeEvents = (r) => r.logs.filter((l) => l.address.toLowerCase() === D.WRAPPER.toLowerCase()).map((l) => { try { return wrapper.interface.parseLog(l); } catch { return null; } }).filter((e) => e && e.name === "FallbackPriceStored");

  await group("B10 stale-feed outage on the real vault (v2 fallback)", async () => {
    await scenario("outage on the real vault", async () => {
      await impersonate(A("90CE1"));
      const usdtReal = (await readFeed(LIVE.USDT_FEED)).answer;
      const gp = await vault.guardParams(); const maxFeedAge = gp.maxFeedAge;

      // ------------------------------------------------------------------------------------------------ setup: WAVAX collateral, a pUSDC borrow, ENTERED the share market with zero balance
      // FORK-ONLY environment (reverted with the scenario, not part of the ceremony): B3 leaves dave inside the live 200 USDC cap / 50 USDC cash floor, so 100,000 USDC are supplied to pUSDC and its cap raised, as in B1m
      const supplier = A("5AFE03"); await impersonate(supplier); await setErc20Balance(LIVE.USDC, supplier, BN(100_000).mul(1e6));
      await tx("supplier approves pUSDC", (o) => C(LIVE.USDC, ERC20, supplier).approve(LIVE.PUSDC, BN(100_000).mul(1e6), o));
      await tx("supplier mints pUSDC", (o) => C(LIVE.PUSDC, PT, supplier).mint(BN(100_000).mul(1e6), o));
      await tx("fork-only cap raise", (o) => C(LIVE.CONTROLLER, CTL, LIVE.LEDGER)._setMarketBorrowCaps([LIVE.PUSDC], [BN(1_000_000).mul(1e6)], o));
      note("B10.n0", "fork only (reverted with the scenario): 100,000 USDC supplied to pUSDC and its borrow cap raised so the test account can borrow; not part of the ceremony");
      const frank = A("F4A2C"); await impersonate(frank);
      const liqS = A("11C0D"); await impersonate(liqS); await setErc20Balance(LIVE.USDC, liqS, BN(50_000_000));   // the liquidator (funded and approved once: static probes and the real liquidations use it)
      await tx("liquidator approves pUSDC", (o) => C(LIVE.USDC, ERC20, liqS).approve(LIVE.PUSDC, ethers.constants.MaxUint256, o));
      const R = await room(); const T = R.room.lt(4_000_000) ? R.room : BN(4_000_000);
      if (T.lt(1_000_000)) throw new Error(`not enough pUSDC room to set the account up (${usd6(T)} USDC)`);
      const pxW = await guarded.getUnderlyingPrice(LIVE.PWAVAX), pxU = await guarded.getUnderlyingPrice(LIVE.PUSDC);
      const collUsd = T.mul(pxU).div(E18).mul(37).div(10);              // collateral worth 3.7 x the borrow: at CF 30 % x 90 % of the power the borrow is ~ T
      const wavaxAmt = collUsd.mul(E18).div(pxW);
      await setErc20Balance(LIVE.WAVAX, frank, wavaxAmt);
      await tx("frank approves pWAVAX", (o) => C(LIVE.WAVAX, ERC20, frank).approve(LIVE.PWAVAX, wavaxAmt, o));
      await tx("frank supplies WAVAX", (o) => C(LIVE.PWAVAX, PT, frank).mint(wavaxAmt, o));
      await tx("frank enters pWAVAX and the SHARE market (zero balance there)", (o) => C(LIVE.CONTROLLER, CTL, frank).enterMarkets([LIVE.PWAVAX, D.PBP], o));
      const pw = await borrowPowerUsdc(frank); let amt = pw.raw.mul(90).div(100); if (amt.gt(R.room)) amt = R.room;
      await tx("frank borrows pUSDC", (o) => C(LIVE.PUSDC, PT, frank).borrow(amt, o));
      const l0 = await ctl.getAccountLiquidity(frank);
      check("B10.1", (await ctl.checkMembership(frank, D.PBP)) && (await ctl.checkMembership(frank, LIVE.PWAVAX)) && (await pBP.balanceOf(frank)).eq(0) && (await pU.borrowBalanceStored(frank)).gt(0) && l0[0].eq(0) && l0[2].eq(0),
        `setup: frank supplied ${wavaxAmt} raw WAVAX (pWAVAX CF 30 %), borrowed ${usd6(amt)} USDC (${(Number(amt) / Number(pw.raw)).toFixed(3)} of his power), ENTERED the share market holding 0 pBP; healthy: liquidity ${l0[1]}, shortfall ${l0[2]}`);

      // ------------------------------------------------------------------------------------------------ baseline: no outage
      const live0 = await vault.convertToAssets(1_000_000), s0 = await st(), px0 = await usdcUsd();
      check("B10.2", (await priceBP()).eq(shareExpect(live0, px0)) && s0.live.eq(live0) && !s0.usingFallback && (await priceBP()).gt(0) && s0.left.eq(WINDOW - ((await headTs()) - s0.at)),
        `no outage: the wrapper's share price ${await priceBP()} = convertToAssets(1 share) ${live0} x the base oracle's USDC price ${px0} (recomputed independently); shareState: live ${s0.live}, stored ${s0.stored} (at ${s0.at}), usingFallback ${s0.usingFallback}, ${s0.left} s of window left`);

      // ------------------------------------------------------------------------------------------------ v3: a vault failure that is NOT FeedInvalid prices 0 at once, no fallback (fault injection on the pair, feeds fresh)
      await scenario("broken vault: pair without code", async () => {
        const origPairCode = await provider.getCode(LIVE.VAULT_PAIR);
        await rpc("anvil_setCode", [LIVE.VAULT_PAIR, "0x"]);              // every pair read of the vault now fails; the feeds are fresh, so this is NOT the FeedInvalid outage
        const data = new ethers.utils.Interface(VAULT).encodeFunctionData("convertToAssets", [1_000_000]);
        const raw = await rawRevert(LIVE.VAULT, data), sb = await st(), pb = await priceBP(), pk = await wrapper.callStatic.poke();
        if (raw === null) note("B10.2c", `FAULT INJECTION INEFFECTIVE: with the pair's code removed convertToAssets still answers (${await vault.convertToAssets(1_000_000)}): the broken-vault case could not be provoked on the fork; the offline self-test P3.7 covers it with stand-ins`);
        else check("B10.2b", !(raw.startsWith(FEED_INVALID_SEL)) && pb.eq(0) && sb.usingFallback === false && sb.live.eq(0) && sb.left.gt(0) && pk === false,
          `BROKEN VAULT (not an outage): with the pair's code removed (feeds fresh) convertToAssets reverts with ${raw.slice(0, 10)}${raw.length > 10 ? "..." : " (empty)"} (not FeedInvalid ${FEED_INVALID_SEL}); the wrapper prices the share 0 AT ONCE although the stored value is fresh (${sb.left} s of window left): usingFallback ${sb.usingFallback}, price ${pb}, live ${sb.live}; poke() returns ${pk}`);
        await rpc("anvil_setCode", [LIVE.VAULT_PAIR, origPairCode]);
        check("B10.2d", (await provider.getCode(LIVE.VAULT_PAIR)) === origPairCode && (await priceBP()).eq(shareExpect(await vault.convertToAssets(1_000_000), await usdcUsd())) && (await priceBP()).gt(0), "the pair's code is restored and the share price is the live price again");
      });

      // ------------------------------------------------------------------------------------------------ the poke upward cap on the REAL vault (own snapshot)
      await scenario("poke upward cap", async () => {
        const prev0 = (await st()).stored;
        await warp(UP_INT + 1);                                           // clear the 1 h gate of the constructor's store, feeds fresh
        let r0 = await poked("poke 1 (live == stored: a plain refresh)");
        const a = await st();
        check("B10.3", (await wrapper.lastGoodAssetsPerShare()).eq(a.stored) && a.at === (await provider.getBlock(r0.blockNumber)).timestamp && pokeEvents(r0).length === 1,
          `a first poke after more than an hour stores the live leg (${a.stored}; the constructor stored ${prev0}) and emits FallbackPriceStored`);
        const donor = A("D0A10"); await impersonate(donor); const DON = 20_000_000;
        await setErc20Balance(LIVE.USDC, donor, BN(DON)); await tx("donor sends 20 USDC to the vault (raises the NAV: idle USDC counts)", (o) => C(LIVE.USDC, ERC20, donor).transfer(LIVE.VAULT, DON, o));
        const liveHi = await vault.convertToAssets(1_000_000), capHi = a.stored.mul(10000 + UP_BPS).div(10000);
        const staticBlocked = await wrapper.callStatic.poke();
        const r1 = await poked("poke 2 (live is higher, last store seconds ago)");
        const b = await st();
        check("B10.4", liveHi.gt(capHi) && staticBlocked === false && b.stored.eq(a.stored) && b.at === a.at && pokeEvents(r1).length === 0,
          `UPWARD move inside ${UP_INT} s of the last store is REFUSED: live leg ${liveHi} (> stored ${a.stored} x 1.02 = ${capHi}), poke() returns false and stores nothing`);
        await warp(UP_INT + 1);
        const staticOk = await wrapper.callStatic.poke();
        const r2 = await poked("poke 3 (an hour later)");
        const c1 = await st(), blkTs2 = (await provider.getBlock(r2.blockNumber)).timestamp;
        check("B10.5", staticOk === true && c1.stored.eq(capHi) && c1.stored.lt(liveHi) && c1.at === blkTs2 && pokeEvents(r2).length === 1 && pokeEvents(r2)[0].args[0].eq(capHi),
          `the next upward poke is stored CAPPED at +2 %: stored ${c1.stored} = floor(${a.stored} x 10200 / 10000), below the live leg ${liveHi}`);
        const staticBlocked2 = await wrapper.callStatic.poke();
        await warp(UP_INT + 1);
        const cap2 = c1.stored.mul(10000 + UP_BPS).div(10000);
        const r3 = await poked("poke 4 (another hour later)");
        const d = await st();
        check("B10.6", staticBlocked2 === false && d.stored.eq(cap2.lt(liveHi) ? cap2 : liveHi) && d.stored.gt(c1.stored),
          `directly after a store a further upward poke is refused (${staticBlocked2}); an hour later it moves by at most another 2 %: ${c1.stored} -> ${d.stored} (cap ${cap2}, live ${liveHi}) - the stored value follows a glitch by at most 2 % per hour`);
      });

      // ------------------------------------------------------------------------------------------------ the outage timeline
      const U0 = await headTs();
      await setFeed(LIVE.USDT_FEED, usdtReal, U0);                       // an EXPLICIT updatedAt: lib.repin() leaves it alone from here on; every other mock is re-pinned after each time movement
      note("B10.n1", `TIMELINE: the USDT/USD feed stops updating at t0 = ${U0}; the vault's maxFeedAge is ${maxFeedAge} s, the wrapper's fallback window ${WINDOW} s. A keeper pokes at t0 + 80,000 s (vault still answering); the vault leg dies at t0 + ${maxFeedAge + 1}; the stored value expires 24 h after the poke.`);
      await warpTo(U0 + 80_000);
      const liveAtPoke = await vault.convertToAssets(1_000_000);          // still answering: USDT age 80,000 s
      const pre = await st();
      const staticPoke = await wrapper.callStatic.poke();
      const rp = await poked("keeper poke at t0 + 80,000 s");
      const afterPoke = await st(), tsPoke = (await provider.getBlock(rp.blockNumber)).timestamp, ex = expectPoke(pre.stored, pre.at, liveAtPoke, tsPoke);
      check("B10.7", staticPoke === ex.stored && ex.stored && afterPoke.stored.eq(ex.value) && afterPoke.at === tsPoke && pokeEvents(rp).length === 1,
        `the keeper's poke while the vault still answers stores ${afterPoke.stored} at ${afterPoke.at} (expected from the specification: ${ex.value}; live ${liveAtPoke}, previous ${pre.stored} stored ${tsPoke - pre.at} s earlier)`);

      // ---- the vault leg dies: USDT age > maxFeedAge, USDC and AVAX fresh
      await warpTo(U0 + maxFeedAge + 100);
      const feedErr = await expectRevert(() => vault.convertToAssets(1_000_000)), taErr = await expectRevert(() => vault.totalAssets());
      const rawData = new ethers.utils.Interface(VAULT).encodeFunctionData("convertToAssets", [1_000_000]), rawTA = new ethers.utils.Interface(VAULT).encodeFunctionData("totalAssets", []);
      const rev1 = await rawRevert(LIVE.VAULT, rawData), rev2 = await rawRevert(LIVE.VAULT, rawTA);
      const isFI = (r) => !!r && r.startsWith(FEED_INVALID_SEL) && r.length === 74 && ethers.BigNumber.from("0x" + r.slice(10)).eq(2);   // load-bearing: the wrapper treats ONLY this selector as an outage
      check("B10.8", isFI(rev1) && isFI(rev2) && /FeedInvalid\(2\)/.test(feedErr || "") && /FeedInvalid\(2\)/.test(taErr || "") && (await readFeed(LIVE.USDT_FEED)).age > maxFeedAge && (await readFeed(LIVE.USDC_FEED)).age < 100 && (await readFeed(LIVE.AVAX_FEED)).age < 100,
        `the vault leg is DEAD (USDT feed ${(await readFeed(LIVE.USDT_FEED)).age} s old > maxFeedAge ${maxFeedAge}): through the PROXY the RAW revert data of convertToAssets is ${rev1} and of totalAssets ${rev2}: selector ${FEED_INVALID_SEL} = FeedInvalid(uint8) with argument 2 (the selector the v3 wrapper keys on); the USDC and AVAX mocks are fresh (USDC ${(await readFeed(LIVE.USDC_FEED)).age} s, AVAX ${(await readFeed(LIVE.AVAX_FEED)).age} s)`);
      const sOut = await st(), pxOut = await usdcUsd(), wantPrice = shareExpect(fallbackLeg(sOut.stored), pxOut);
      check("B10.9", sOut.live.eq(0) && sOut.usingFallback && sOut.left.eq(WINDOW - ((await headTs()) - sOut.at)) && sOut.left.gt(0) && (await priceBP()).eq(wantPrice) && wantPrice.gt(0) && (await wrapper.getShareUsdPrice()).eq(wantPrice.div(BN(10).pow(12))),
        `FALLBACK: usingFallback true, live 0, stored ${sOut.stored}, ${sOut.left} s left; price ${await priceBP()} = stored x 0.97 x the LIVE USDC price ${pxOut} (${wantPrice} recomputed independently); getShareUsdPrice() agrees`);
      check("B10.10", (await wrapper.callStatic.poke()) === false && (await wrapper.getUnderlyingPrice(LIVE.PWAVAX)).gt(0) && (await wrapper.getUnderlyingPrice(LIVE.PUSDC)).gt(0),
        "poke() returns false while the vault cannot answer (nothing is stored from a dead vault); pWAVAX and pUSDC keep their live prices");
      // frank becomes insolvent: AVAX falls 60 %
      await setFeed(LIVE.AVAX_FEED, mocks[LIVE.AVAX_FEED.toLowerCase()].answer.mul(40).div(100));
      const lOut = await ctl.getAccountLiquidity(frank);
      check("B10.11", lOut[0].eq(0) && lOut[2].gt(0),
        `the account that entered the share market is PRICED, not frozen: getAccountLiquidity error ${lOut[0]} (v1 gave 13 = PRICE_ERROR here), shortfall ${lOut[2]} after AVAX -60 %`);

      // ---- LIQUIDATION during the outage (own snapshot: the position is restored afterwards)
      const liquidate = async (label) => {
        const liq = liqS;
        const debt = await pU.callStatic.borrowBalanceCurrent(frank), repay = debt.mul(await ctl.closeFactorMantissa()).div(E18);
        const seizeExp = (await ctl.liquidateCalculateSeizeTokens(LIVE.PUSDC, LIVE.PWAVAX, repay))[1], proto = await pW.protocolSeizeShareMantissa();
        const r = await codeOrRevert(() => C(LIVE.PUSDC, PT, liq).callStatic.liquidateBorrow(frank, repay, LIVE.PWAVAX));
        const u0 = await usdc.balanceOf(liq), l0w = await pW.balanceOf(liq), f0w = await pW.balanceOf(frank);
        await tx(`LIQUIDATE frank (${label})`, (o) => C(LIVE.PUSDC, PT, liq).liquidateBorrow(frank, repay, LIVE.PWAVAX, o));
        const u1 = await usdc.balanceOf(liq), l1w = await pW.balanceOf(liq), f1w = await pW.balanceOf(frank), d1 = await pU.borrowBalanceStored(frank);
        return { r, repay, seizeExp, toLiq: seizeExp.sub(seizeExp.mul(proto).div(E18)), paid: u0.sub(u1), got: l1w.sub(l0w), lost: f0w.sub(f1w), debtFall: debt.sub(d1) }; // debt = borrowBalanceCurrent just before (interest included)
      };
      await scenario("liquidation during the outage", async () => {
        const L = await liquidate("fallback active");
        check("B10.12", L.r.code === 0 && L.paid.eq(L.repay) && L.got.eq(L.toLiq) && L.lost.eq(L.seizeExp) && L.debtFall.sub(L.repay).abs().lte(1_000) && L.repay.gt(0),
          `LIQUIDATION WORKS during the outage (share price = the fallback): liquidateBorrow static call returns ${L.r.code}; the liquidator paid ${usd6(L.paid)} USDC (= repay), received ${L.got} pWAVAX (seized ${L.seizeExp} less the protocol share), frank lost ${L.lost} pWAVAX and ${usd6(L.debtFall)} USDC of debt`);
      });

      // ---- R1 rollback WHILE the fallback is active
      await scenario("R1 rollback during the outage", async () => {
        const wPrices = await readPrices(D.WRAPPER), bPriceShare = await wrapper.getUnderlyingPrice(D.PBP);
        await runStep(step("rollback"));
        const gPrices = await readPrices(LIVE.GUARDED_ORACLE);
        const diffs = Object.keys(gPrices).filter((k) => gPrices[k] !== wPrices[k]).map((k) => `${k}: wrapper ${wPrices[k]} guarded ${gPrices[k]}`);
        check("B10.13", (await ctl.oracle()) === LIVE.GUARDED_ORACLE && diffs.length === 0 && Object.keys(gPrices).length >= 6 && bPriceShare.gt(0) && (await guarded.getUnderlyingPrice(D.PBP)).eq(0),
          `R1 (one Ledger transaction) while the fallback is active: every existing market is priced IDENTICALLY by the guarded oracle and by the wrapper at the same block (${Object.keys(gPrices).length} values), the share market (fallback price ${bPriceShare} under the wrapper) is priced 0 by the guarded oracle`, diffs.join("; "));
        const lf = await ctl.getAccountLiquidity(frank), lr = await codeOrRevert(() => C(LIVE.PUSDC, PT, liqS).callStatic.liquidateBorrow(frank, 1_000, LIVE.PWAVAX));
        const live1 = await ctl.getAccountLiquidity((await exec.positions(1)).account);
        check("B10.14", lf[0].eq(13) && (lr.code === 13) && live1[0].eq(0), `the account that entered the share market is FROZEN under the guarded oracle (liquidity error ${lf[0]}, liquidation code ${lr.code ?? lr.revert}), the live margin account that never entered it is not (error ${live1[0]}): the rollback is a clean undo only while nobody has entered`);
        await runStep(step("oracleSwap"));
        const lb = await ctl.getAccountLiquidity(frank);
        check("B10.15", (await ctl.oracle()) === D.WRAPPER && lb[0].eq(0) && lb[2].gt(0) && (await priceBP()).eq(wantPrice), "re-applying the wrapper restores frank's liquidity answer and the fallback price");
      });

      // ---- the stored value ages out: valid at EXACTLY 24 h, 0 one second later
      await warpTo(sOut.at + WINDOW);                                   // head == stored + 86,400: no transaction until the next warp (a transaction would move the head)
      const sEdge = await st(), pxEdge = await usdcUsd();
      const lEdge = await codeOrRevert(() => C(LIVE.PUSDC, PT, liqS).callStatic.liquidateBorrow(frank, 1_000, LIVE.PWAVAX));
      check("B10.16", (await headTs()) === sOut.at + WINDOW && sEdge.usingFallback && sEdge.left.eq(0) && (await priceBP()).eq(shareExpect(fallbackLeg(sOut.stored), pxEdge)) && (await priceBP()).gt(0) && lEdge.code === 0,
        `the fallback is valid at age EXACTLY 24 h (head ${await headTs()} = stored ${sOut.at} + ${WINDOW}): usingFallback ${sEdge.usingFallback}, 0 s left, price ${await priceBP()} still the fallback price, liquidation static call code ${lEdge.code ?? lEdge.revert}`);
      await warpTo(sOut.at + WINDOW + 1);
      const sGone = await st(), lGone = await codeOrRevert(() => C(LIVE.PUSDC, PT, liqS).callStatic.liquidateBorrow(frank, 1_000, LIVE.PWAVAX)), lqGone = await ctl.getAccountLiquidity(frank);
      check("B10.17", (await priceBP()).eq(0) && (await wrapper.getShareUsdPrice()).eq(0) && !sGone.usingFallback && sGone.left.eq(0) && sGone.live.eq(0) && lGone.code === 13 && lqGone[0].eq(13),
        `ONE SECOND LATER (age ${WINDOW + 1} s, nobody poked): share price 0, usingFallback false, liquidation of frank returns PRICE_ERROR ${lGone.code ?? lGone.revert} (13), his liquidity query error ${lqGone[0]}`);
      const live1 = await ctl.getAccountLiquidity((await exec.positions(1)).account);
      check("B10.18", (await wrapper.getUnderlyingPrice(LIVE.PWAVAX)).gt(0) && (await wrapper.getUnderlyingPrice(LIVE.PUSDC)).gt(0) && live1[0].eq(0) && (await wrapper.callStatic.poke()) === false,
        `the expiry is confined to the share market: pWAVAX and pUSDC stay priced, the live margin account that never entered it answers (error ${live1[0]}), poke() still returns false (the vault is dead)`);

      // ---- the feed comes back
      await setFeed(LIVE.USDT_FEED, usdtReal);                          // updatedAt = head again: from here repin() keeps it fresh
      const liveBack = await vault.convertToAssets(1_000_000), pxBack = await usdcUsd(), sBack = await st();
      check("B10.19", (await priceBP()).eq(shareExpect(liveBack, pxBack)) && !sBack.usingFallback && sBack.live.eq(liveBack) && liveBack.gt(0) && sBack.left.eq(0) && sBack.stored.eq(sOut.stored),
        `USDT restored: the share price is the LIVE price again (${await priceBP()} = ${liveBack} x ${pxBack}) with no transaction; the stored value is untouched and still expired (${sBack.stored}, ${((await headTs()) - sBack.at)} s old)`);
      const donor2 = A("D0A11"); await impersonate(donor2);
      await setErc20Balance(LIVE.USDC, donor2, BN(20_000_000)); await tx("donor sends 20 USDC to the vault", (o) => C(LIVE.USDC, ERC20, donor2).transfer(LIVE.VAULT, 20_000_000, o));
      const liveHi = await vault.convertToAssets(1_000_000), staticBack = await wrapper.callStatic.poke();
      const rb = await poked("poke after the outage (stored value older than 24 h)");
      const sAfter = await st(), tsB = (await provider.getBlock(rb.blockNumber)).timestamp;
      check("B10.20", staticBack === true && liveHi.gt(sBack.stored.mul(10200).div(10000)) && sAfter.stored.eq(liveHi) && sAfter.at === tsB && pokeEvents(rb).length === 1 && (await priceBP()).eq(shareExpect(liveHi, pxBack)),
        `poke() after the outage stores the LIVE value UNCAPPED because the old one is older than 24 h: ${sBack.stored} -> ${sAfter.stored} (live ${liveHi}; a capped poke would have given at most ${sBack.stored.mul(10200).div(10000)}); price = live price ${await priceBP()}`);
      const L2 = await liquidate("after the outage");
      check("B10.21", L2.r.code === 0 && L2.paid.eq(L2.repay) && L2.got.eq(L2.toLiq) && L2.lost.eq(L2.seizeExp) && L2.repay.gt(0),
        `LIQUIDATION WORKS AGAIN after the feed is back, the poke done and the price the live price: static call ${L2.r.code}, paid ${usd6(L2.paid)} USDC, received ${L2.got} pWAVAX, frank lost ${L2.lost} pWAVAX`);
      note("B10.n2", "FINDING: a wrapper that is never poked has NO usable fallback when the USDT feed stops: the vault leg dies at 93,600 s of feed age, the fallback window is 86,400 s after the last store, so without a keeper poking at least once in the last ~24 h the outage window opens at price 0 (the v1 behaviour). The harness pokes at t0 + 80,000 s to model the keeper; a poke cadence of a few hours (any account may call poke()) is what makes the fallback real.");
    });
  });
}

"""Illustrative economics of the window variants. Inputs marked ASSUMPTION are NOT measured; measured inputs come from probe2
(Q1: gas increaseLiquidity 279,436; mint 1,014,864; getReward over 12 periods 1,053,520; getPeriodReward one period 178,344
 (cold) ; Q9: positionPeriodSecondsInRange 47,910 cold / 18,806 warm) and from the RPC gas price read once (2.5 gwei).
Run: python3 variant_econ.py"""
from fractions import Fraction as F
YEAR = 365 * 86400
W = 111                      # measured threshold
MARGIN = 10                  # design parameter
GAS_PRICE_GWEI = F(5, 2)     # read from the RPC at the time of writing (cast gas-price = 2.5 gwei)
GAS_DUST_DEPOSIT = 279_436 + 150_000   # increaseLiquidity measured + ASSUMED 150k vault overhead (no Solidity exists)
APR = F(20, 100)             # ASSUMPTION: fees + PHAR emissions as a fraction of deployed capital per year (not measured)


def w1(ops_per_day):
    lam = F(ops_per_day, 86400)
    # a liquidity-changing request is refused if another liquidity change happened in the last W s (Poisson, organic only)
    import math
    p = 1 - math.exp(-float(lam) * W)
    return p


def attacker_cost(window_s, days=1):
    n = 86400 * days // (window_s)
    gas = n * GAS_DUST_DEPOSIT
    avax = float(gas * GAS_PRICE_GWEI) / 1e9
    return n, gas, avax


def idle_cost_bps_of_deposit(wait_s):
    return float(APR * wait_s / YEAR) * 1e4


def buffer_drag_bps_of_nav(buf_bps):
    return float(APR) * buf_bps      # bps of NAV per year


if __name__ == '__main__':
    print('W1 organic refusal probability per liquidity-changing request (Poisson):')
    for ops in (5, 20, 100, 500):
        print('  %4d liquidity-changing ops/day -> %.2f%% refused (retry after <=111 s)' % (ops, 100 * w1(ops)))
    n, gas, avax = attacker_cost(W + 1)
    print('W1 dust attacker (one deposit per %d s keeps every exit refused): %d tx/day, %.3g gas/day, %.3g AVAX/day at 2.5 gwei' % (W + 1, n, gas, avax))
    print('EPOCH: deposit wait (avg = E/2) cost, bps of the deposit, APR assumed 20%%:')
    for E in (W + MARGIN + 1, 3600, 6 * 3600, 86400):
        print('  E=%6d s -> mean wait %7.0f s -> %.4f bps of the deposit; worst-case exit wait (no buffer) %d s' % (E, E / 2, idle_cost_bps_of_deposit(E / 2), E))
    print('EPOCH idle buffer drag (bps of NAV per year at APR 20%):')
    for b in (100, 500, 1000):
        print('  buffer %2d%% of NAV -> %.0f bps/yr' % (b // 100, buffer_drag_bps_of_nav(b)))

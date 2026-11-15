"""Mutation check for the PHAR reference model with NEW mutations (not the six in test_refmodel2.TestMutations).
Run: python3 -I phar_mutations.py [--n 1500]
For each mutation a copy of the tools is made in a scratch directory, refmodel2.py is patched by an exact text replacement
(the script asserts the text occurs once), and three checks run against the mutant:
  D  phar_difftest.py (vault ledger vs independent oracle, aligned generator)  -> caught if a failing history appears that the
     unmutated model does not already fail (the unmutated model has the known findings F1/F2, see the verdict)
  G  phar_difftest.py --gauge (gauge mirror vs source-based oracle, aligned)  -> caught if any mismatch
  T  the original 47 tests (test_refmodel2.py)                                 -> caught if any test fails
"""
import os, re, shutil, subprocess, sys, argparse, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = ['refmodel2.py', 'phar_oracle.py', 'phar_difftest.py', 'test_refmodel2.py', 'refmodel.py']

MUTS = [
    ('M1 same-period settlement ignores the account\'s J checkpoint (double counts earlier exposure)',
     "s.W[(h, cur)] = s.W.get((h, cur), F(0)) + b * (s.J.get(cur, F(0)) - jp)",
     "s.W[(h, cur)] = s.W.get((h, cur), F(0)) + b * (s.J.get(cur, F(0)))"),
    ('M2 window guard boundary: blocks only while elapsed < threshold+margin (off by one)',
     "if g.now - g.lm.get(id_, 0) <= s.threshold_live() + margin:",
     "if g.now - g.lm.get(id_, 0) < s.threshold_live() + margin:"),
    ('M3 gauge debt cascade dropped: earlier periods forfeit only up to the debt amount',
     "return unpaid if p < dp else min(unpaid, da)",
     "return min(unpaid, da)"),
    ('M4 harvest books forfeited tokens as funded (loss hidden as income)',
     "if paid:\n                        s.funded[(p, tok)] = s.funded.get((p, tok), F(0)) + paid\n                    if forf:",
     "if paid or forf:\n                        s.funded[(p, tok)] = s.funded.get((p, tok), F(0)) + paid + forf\n                    if forf:"),
    ('M5 finality ignores the outstanding amount (period final as soon as recorded)',
     "return all(s._outstanding(p, t) == 0 for t in TOKS)",
     "return True"),
    ('M6 continuing multi-period segment keeps the first period\'s J checkpoint',
     "dq[0] = (b, p + 1, F(0), end)",
     "dq[0] = (b, p + 1, jp, end)"),
    ('M7 entitlement divides by non-zero-supply exposure only (zero-supply share redistributed)',
     "return F(0) if Tt == 0 else s.funded.get((p, tok), F(0)) * s.W.get((h, p), F(0)) / Tt",
     "return F(0) if Tt == 0 else s.funded.get((p, tok), F(0)) * s.W.get((h, p), F(0)) / ((Tt - s.Z.get(p, F(0))) or Tt)"),
    ('M8 gauge sets lastModified BEFORE the auto-claim (claim always inside its own window)',
     "        if s.autoclaim:\n            try:",
     "        s.lm[id_] = s.now\n        if s.autoclaim:\n            try:"),
    ('M9 gauge window comparison < instead of <= (boundary)',
     "return s.now - lm <= s.threshold",
     "return s.now - lm < s.threshold"),
    ('M10 gauge does not decrement the forfeit debt as it is realised',
     "        if p == dp:\n            s.debt[(id_, tok)] = (dp, da - min(da, forf))\n",
     "        pass\n"),
]


def run(cmd, cwd, timeout=900):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout + r.stderr


def seeds(out, tag):
    m = re.search(tag + r' \[(.*?)\]', out)
    return set(int(x) for x in m.group(1).split(',') if x.strip()) if m else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=1500)
    a = ap.parse_args()
    root = tempfile.mkdtemp(prefix='phar_mut_', dir=os.environ.get('PHAR_SCRATCH'))
    src = open(os.path.join(HERE, 'refmodel2.py')).read()
    results = []
    for name, old, new in [('M0 unmutated', None, None)] + MUTS:
        d = os.path.join(root, name.split()[0])
        os.makedirs(d)
        for f in FILES:
            shutil.copy(os.path.join(HERE, f), d)
        if old is not None:
            assert src.count(old) == 1, (name, src.count(old))
            open(os.path.join(d, 'refmodel2.py'), 'w').write(src.replace(old, new))
        c1, o1 = run([sys.executable, '-I', 'phar_difftest.py', '--n', str(a.n), '--mode', 'aligned', '--show', '0'], d)
        c2, o2 = run([sys.executable, '-I', 'phar_difftest.py', '--n', '0', '--gauge', str(a.n), '--gauge-aligned', '--show', '0'], d)
        c3, o3 = run([sys.executable, '-I', 'test_refmodel2.py'], d)
        c4, o4 = run([sys.executable, '-I', 'phar_difftest.py', '--n', str(a.n), '--mode', 'strict', '--show', '0'], d)
        results.append((name, seeds(o1, 'FAILSEEDS'), seeds(o2, 'GAUGEFAILSEEDS'), c3, seeds(o4, 'FAILSEEDS'), o3))
        print('done', name, flush=True)
    base = results[0][1]
    print()
    print('baseline (unmutated) failing vault histories: %s of %d; gauge-only failures: %s; original tests exit code: %d' % (sorted(base), a.n, len(results[0][2] or []), results[0][3]))
    print('%-100s %-8s %-8s %-8s %-8s' % ('mutation', 'vault D', 'strict', 'gauge G', 'tests T'))
    sbase = results[0][4]
    for name, vs, gs, tc, ss, o3 in results[1:]:
        S = 'CAUGHT' if (ss is None or ss != sbase) else 'missed'
        D = 'CAUGHT' if (vs is None or vs != base) else 'missed'
        G = 'CAUGHT' if (gs is None or len(gs) > 0) else 'missed'
        T = 'CAUGHT' if tc != 0 else 'missed'
        extra = '' if vs is None or vs == base else ' (+%d histories)' % len(vs - base)
        print('%-100s %-8s %-8s %-8s %-8s%s' % (name[:100], D, S, G, T, extra))
    shutil.rmtree(root, ignore_errors=True)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Keeps a PRIVATE RPC endpoint out of logs. The secret is read from ENVIRONMENT VARIABLES whose NAMES are given on the command line; the
value never appears in an argument list, a file or an output line.

  stream mode (default):  <command> 2>&1 | avalanche-redact-rpc.py NAME [NAME...]
      copies stdin to stdout line by line, replacing the full URL, its host, its userinfo and every path/query token of it with markers.
      Needed because forge's own error text contains the URL ("error sending request for url (https://...)").
  scan mode:  avalanche-redact-rpc.py --scan DIR NAME [NAME...]
      exit 1 (and print only the NAMES of the offending files, never their content) if any file under DIR still contains one of the secrets.

Run with `python3 -I`. Standard library only."""
import os
import sys
from urllib.parse import urlsplit, unquote


def secrets_from_env(names):
    out = set()
    for n in names:
        v = os.environ.get(n, "")
        if len(v) < 6:  # unset or a placeholder such as "simulated"; nothing worth masking
            continue
        out.add(v)
        out.add(v.rstrip("/"))
        try:
            u = urlsplit(v)
        except ValueError:
            continue
        if u.netloc:
            out.add(u.netloc)
            if u.hostname:
                out.add(u.hostname)
        for part in (u.username, u.password):
            if part and len(part) >= 4:
                out.add(part)
        for seg in u.path.split("/") + u.query.replace("=", "/").replace("&", "/").split("/"):
            seg = unquote(seg)
            if len(seg) >= 8:  # key-like tokens; short path words ("ext", "bc", "C", "rpc") stay readable
                out.add(seg)
    return sorted((s for s in out if s), key=len, reverse=True)


def mask(line, secrets):
    for i, s in enumerate(secrets):
        if s in line:
            line = line.replace(s, "[RPC-MASKED]")
    return line


def main(argv):
    if argv and argv[0] == "--scan":
        if len(argv) < 3:
            print("usage: avalanche-redact-rpc.py --scan DIR NAME [NAME...]", file=sys.stderr)
            return 2
        root, names = argv[1], argv[2:]
        secrets = secrets_from_env(names)
        bad = []
        for dp, _, fs in os.walk(root):
            for f in fs:
                p = os.path.join(dp, f)
                try:
                    data = open(p, "rb").read().decode("utf-8", "replace")
                except OSError:
                    continue
                if any(s in data for s in secrets):
                    bad.append(p)
        for p in bad:
            print("RPC SECRET PRESENT IN: " + p)
        return 1 if bad else 0
    names = argv
    if not names:
        print("usage: <command> 2>&1 | avalanche-redact-rpc.py NAME [NAME...]", file=sys.stderr)
        return 2
    secrets = secrets_from_env(names)
    for line in sys.stdin:
        sys.stdout.write(mask(line, secrets))
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

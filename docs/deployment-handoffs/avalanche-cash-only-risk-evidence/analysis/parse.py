#!/usr/bin/env python3
"""Parse RISK| lines from forge logs into python structures and print summary tables."""
import sys, re, json, collections

def parse(paths):
    rows = []
    for p in paths:
        for line in open(p, errors="replace"):
            line = line.strip()
            i = line.find("RISK|")
            if i < 0:
                continue
            parts = line[i:].split("|")
            if parts[-1] != "END":
                continue
            kind = parts[1]
            d = {"_kind": kind}
            for kv in parts[2:-1]:
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    try:
                        d[k] = int(v)
                    except ValueError:
                        d[k] = v
            rows.append(d)
    return rows

if __name__ == "__main__":
    rows = parse(sys.argv[1:])
    c = collections.Counter(r["_kind"] for r in rows)
    print(c)

#!/usr/bin/env python3
"""Paired comparison for bench2.sh output: for every round, TPS of each config
divided by the baseline's TPS in the same round and client count; reports the
median ratio over rounds (as % change) and how many rounds the config won.
Robust against the device changing speed between rounds.

usage: paired2.py RAW.csv BASELINE_LABEL [--csv OUT.csv]
"""
import csv, statistics, sys
from collections import defaultdict
a = sys.argv[1:]; out = None
if "--csv" in a:
    k = a.index("--csv"); out = a[k + 1]; del a[k:k + 2]
raw, base = a[0], a[1]
t = defaultdict(dict); order = []; clients = set()
for r in csv.DictReader(open(raw)):
    if not r["tps"]: continue
    t[(r["workload"], r["config"], int(r["clients"]))][int(r["round"])] = float(r["tps"])
    if r["config"] not in order: order.append(r["config"])
    clients.add(int(r["clients"]))
clients = sorted(clients); rows = []
for wl in sorted({k[0] for k in t}):
    print(f"\n== {wl}: median over rounds of (TPS / '{base}' TPS in the same round) - 1   [rounds won]")
    print(f"{'config':38s}" + "".join(f"{c:>16d}" for c in clients))
    for cfg in order:
        if cfg == base: continue
        line = f"{cfg:38s}"
        for c in clients:
            b = t.get((wl, base, c), {}); v = t.get((wl, cfg, c), {})
            rs = [v[r] / b[r] for r in v if r in b]
            if not rs: line += f"{'-':>16s}"; continue
            med = (statistics.median(rs) - 1) * 100; won = sum(x > 1 for x in rs)
            line += f"{med:+9.1f}% [{won}/{len(rs)}]"
            rows.append(dict(workload=wl, config=cfg, clients=c, rounds=len(rs),
                             median_change_pct=round(med, 1),
                             min_change_pct=round((min(rs) - 1) * 100, 1),
                             max_change_pct=round((max(rs) - 1) * 100, 1),
                             rounds_won=won))
        print(line)
if out:
    w = csv.DictWriter(open(out, "w", newline=""), fieldnames=list(rows[0]))
    w.writeheader(); w.writerows(rows); print(f"\nwrote {out}")

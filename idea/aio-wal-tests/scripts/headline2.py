#!/usr/bin/env python3
"""Summaries of the headline bench3 run, which mixes two durability modes,
each compared with its own stock baseline.

usage: headline2.py headline_raw.csv OUTDIR

Disturbed blocks: the SSD sometimes collapses in the middle of a block (one
round at one client count, where every config runs once, seconds apart), so
the configs that ran during the collapse lose 3-10x while the others don't.
A block is dropped, for all configs alike, if any config's TPS in it is below
half of that config's median at that client count.  The number of blocks
dropped is printed and stored (rounds column).
writes OUTDIR/headline_paired.csv  (mode, config, clients, rounds,
                                    median/min/max change vs stock in %, rounds_won)
       OUTDIR/headline_tps.csv     (mode, config, clients, rounds, tps median/min/max,
                                    latency median ms)
"""
import csv, os, statistics, sys
from collections import defaultdict

raw, outdir = sys.argv[1], sys.argv[2]
BASE = {"fdatasync": "stock fdatasync", "open_datasync": "stock open_datasync"}

def mode_of(cfg):
    return "open_datasync" if ("odsync" in cfg or "open_datasync" in cfg) else "fdatasync"

tps = defaultdict(dict); lat = defaultdict(dict); order = []
for r in csv.DictReader(open(raw)):
    if not r["tps"]:
        continue
    k = (r["config"], int(r["clients"]))
    tps[k][int(r["round"])] = float(r["tps"])
    lat[k][int(r["round"])] = float(r["latency_avg_ms"])
    if r["config"] not in order:
        order.append(r["config"])
clients = sorted({k[1] for k in tps})

# drop disturbed blocks
dropped = []
med = {k: statistics.median(v.values()) for k, v in tps.items()}   # before dropping
for c in clients:
    rounds = sorted({r for (cfg, cc), v in tps.items() if cc == c for r in v})
    for r in rounds:
        bad = any(r in v and v[r] < 0.5 * med[(cfg, cc)]
                  for (cfg, cc), v in tps.items() if cc == c)
        if bad:
            dropped.append((r, c))
            for (cfg, cc), v in tps.items():
                if cc == c:
                    v.pop(r, None); lat[(cfg, cc)].pop(r, None)
print(f"dropped {len(dropped)} disturbed blocks (round, clients): {sorted(dropped)}")

paired, absolute = [], []
for cfg in order:
    m = mode_of(cfg)
    for c in clients:
        v = tps.get((cfg, c))
        if not v:
            continue
        absolute.append(dict(mode=m, config=cfg, clients=c, rounds=len(v),
                             tps_median=round(statistics.median(v.values())),
                             tps_min=round(min(v.values())), tps_max=round(max(v.values())),
                             latency_median_ms=round(statistics.median(lat[(cfg, c)].values()), 3)))
        if cfg == BASE[m]:
            continue
        b = tps.get((BASE[m], c), {})
        rs = [v[r] / b[r] for r in v if r in b]
        if not rs:
            continue
        paired.append(dict(mode=m, config=cfg, clients=c, rounds=len(rs),
                           median_change_pct=round((statistics.median(rs) - 1) * 100, 1),
                           min_change_pct=round((min(rs) - 1) * 100, 1),
                           max_change_pct=round((max(rs) - 1) * 100, 1),
                           rounds_won=sum(x > 1 for x in rs)))

for name, rows in (("headline_paired.csv", paired), ("headline_tps.csv", absolute)):
    with open(os.path.join(outdir, name), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)

print(f"{'config':28s}" + "".join(f"{c:>15d}" for c in clients))
for cfg in order:
    if cfg in BASE.values():
        continue
    line = f"{cfg:28s}"
    for c in clients:
        p = next((p for p in paired if p["config"] == cfg and p["clients"] == c), None)
        line += f"{p['median_change_pct']:+8.1f}% [{p['rounds_won']}/{p['rounds']}]" if p else f"{'-':>15s}"
    print(line)

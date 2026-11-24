#!/usr/bin/env python3
"""Summarize bench2.sh raw output: median TPS per (config, clients), the
spread across rounds, and the change vs a baseline config.

usage: summarize2.py RAW.csv [BASELINE_LABEL] [--csv OUT.csv]
"""
import csv, statistics, sys
from collections import defaultdict

args = [a for a in sys.argv[1:]]
out_csv = None
if "--csv" in args:
    k = args.index("--csv"); out_csv = args[k + 1]; del args[k:k + 2]
raw = args[0]
base = args[1] if len(args) > 1 else None

data = defaultdict(list); lat = defaultdict(list)
order, clients = [], []
with open(raw) as f:
    for row in csv.DictReader(f):
        key = (row["workload"], row["config"], int(row["clients"]))
        if not row["tps"]:
            continue
        data[key].append(float(row["tps"]))
        if row["latency_avg_ms"]:
            lat[key].append(float(row["latency_avg_ms"]))
        if row["config"] not in order: order.append(row["config"])
        if int(row["clients"]) not in clients: clients.append(int(row["clients"]))
clients.sort()
workloads = sorted({k[0] for k in data})
if base is None: base = order[0]

rows = []
for wl in workloads:
    print(f"\n== workload: {wl}   (median TPS over rounds; [min-max]; vs '{base}')")
    print(f"{'config':36s}" + "".join(f"{c:>22d}" for c in clients))
    for cfg in order:
        line = f"{cfg:36s}"
        for c in clients:
            v = data.get((wl, cfg, c))
            if not v:
                line += f"{'-':>22s}"; continue
            med = statistics.median(v)
            b = data.get((wl, base, c))
            pct = (med / statistics.median(b) - 1) * 100 if b else 0.0
            cell = f"{med:7.0f} {pct:+5.1f}%" if cfg != base else f"{med:7.0f}       "
            line += f"{cell:>22s}"
            rows.append(dict(workload=wl, config=cfg, clients=c, n=len(v),
                             tps_median=round(med), tps_min=round(min(v)),
                             tps_max=round(max(v)),
                             tps_stdev=round(statistics.stdev(v)) if len(v) > 1 else 0,
                             latency_median_ms=round(statistics.median(lat[(wl, cfg, c)]), 3) if lat.get((wl, cfg, c)) else "",
                             vs_baseline_pct=round(pct, 1) if cfg != base else 0.0))
        print(line)
    print(f"{'(spread: max-min as % of median)':36s}")
    for cfg in order:
        line = f"{'  ' + cfg:36s}"
        for c in clients:
            v = data.get((wl, cfg, c))
            line += f"{((max(v)-min(v))/statistics.median(v)*100 if v else 0):21.0f}%"
        print(line)

if out_csv:
    with open(out_csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader(); w.writerows(rows)
    print(f"\nwrote {out_csv}")

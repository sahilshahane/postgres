#!/usr/bin/env python3
"""Analysis of bench.sh output.

Each config is compared with the stock config of the same durability mode
(same wal_sync_method and debug_io_direct; stock = install dir ending in
/stock).  For every round: config TPS / baseline TPS in the same round and
client count; reported as the median over rounds (% change), min, max and
rounds won.  Paired ratios are robust against the device changing speed
between rounds; absolute medians are not, and are only given for reference.

Disturbed blocks: if any config in a (round, clients) block fell below half
its own median (the device collapsed mid-block), the block is dropped for
all configs alike; the number dropped is printed.

usage: analyze.py CONFIGS RAW.csv [OUTDIR]
writes OUTDIR/paired.csv and OUTDIR/tps.csv (default: next to RAW.csv)
"""
import csv, os, statistics, sys
from collections import defaultdict

cfgfile, raw = sys.argv[1], sys.argv[2]
outdir = sys.argv[3] if len(sys.argv) > 3 else os.path.dirname(os.path.abspath(raw))


def mode(gucs):
    g = {k.strip(): v.strip() for k, _, v in (x.partition("=") for x in gucs)}
    return (g.get("wal_sync_method", "fdatasync"), g.get("debug_io_direct", "") or "-")


cfg_mode, stock_of = {}, {}
for line in open(cfgfile):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    label, inst, *gucs = [x.strip() for x in line.split("|")]
    cfg_mode[label] = mode(gucs)
    if inst.rstrip("/").endswith("stock"):
        stock_of[cfg_mode[label]] = label

tps = defaultdict(dict); lat = defaultdict(dict); order = []
for r in csv.DictReader(open(raw)):
    if not r["tps"] or r["config"] not in cfg_mode:
        continue
    k = (r["workload"], r["config"], int(r["clients"]))
    tps[k][int(r["round"])] = float(r["tps"])
    lat[k][int(r["round"])] = float(r["latency_avg_ms"] or "nan")
    if r["config"] not in order:
        order.append(r["config"])

med = {k: statistics.median(v.values()) for k, v in tps.items()}
blocks = {(wl, c, rd) for (wl, _, c), v in tps.items() for rd in v}
dropped = []
for wl, c, rd in sorted(blocks):
    keys = [k for k in tps if k[0] == wl and k[2] == c]
    if any(rd in tps[k] and tps[k][rd] < 0.5 * med[k] for k in keys):
        dropped.append((wl, c, rd))
        for k in keys:
            tps[k].pop(rd, None); lat[k].pop(rd, None)
print(f"dropped {len(dropped)} of {len(blocks)} blocks as disturbed: "
      f"{[(c, rd) for _, c, rd in dropped]}")

paired, absolute = [], []
for (wl, cfg, c), v in sorted(tps.items(), key=lambda kv: (kv[0][0], order.index(kv[0][1]), kv[0][2])):
    if not v:
        continue
    absolute.append(dict(workload=wl, config=cfg, clients=c, rounds=len(v),
                         tps_median=round(statistics.median(v.values())),
                         tps_min=round(min(v.values())), tps_max=round(max(v.values())),
                         latency_median_ms=round(statistics.median(lat[(wl, cfg, c)].values()), 3)))
    base = stock_of.get(cfg_mode[cfg])
    if base is None or base == cfg:
        continue
    b = tps.get((wl, base, c), {})
    rs = [v[rd] / b[rd] for rd in v if rd in b]
    if rs:
        paired.append(dict(workload=wl, config=cfg, baseline=base, clients=c, rounds=len(rs),
                           median_change_pct=round((statistics.median(rs) - 1) * 100, 1),
                           min_change_pct=round((min(rs) - 1) * 100, 1),
                           max_change_pct=round((max(rs) - 1) * 100, 1),
                           rounds_won=sum(x > 1 for x in rs)))

for name, rows in (("paired.csv", paired), ("tps.csv", absolute)):
    if rows:
        with open(os.path.join(outdir, name), "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)

clients = sorted({p["clients"] for p in paired})
for wl in sorted({p["workload"] for p in paired}):
    print(f"\n== {wl}: median change vs stock of the same mode [rounds won/rounds]")
    print(f"{'config':34s}" + "".join(f"{c:>15d}" for c in clients))
    for cfg in order:
        cells = {p["clients"]: p for p in paired if p["workload"] == wl and p["config"] == cfg}
        if cells:
            print(f"{cfg:34s}" + "".join(
                f"{cells[c]['median_change_pct']:+8.1f}% [{cells[c]['rounds_won']}/{cells[c]['rounds']}]"
                if c in cells else f"{'-':>15s}" for c in clients))
print(f"\nwrote {outdir}/paired.csv, {outdir}/tps.csv")

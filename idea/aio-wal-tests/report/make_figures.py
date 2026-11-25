#!/usr/bin/env python3
"""Figures for REPORT.md, from the result directories in ../results-aws.

  python3 make_figures.py            (writes fig/*.png)

Figures whose data is missing are skipped with a message. Colors: the first
four slots of the validated categorical palette (blue, orange, aqua, violet);
each configuration keeps its color and marker in every figure.
"""
import csv, os, re, statistics, sys
from collections import defaultdict
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.environ.get("RESULTS", os.path.join(HERE, "..", "results-aws"))
OUT = os.path.join(HERE, "fig")
os.makedirs(OUT, exist_ok=True)

SURFACE, INK, INK2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
NEUTRAL, NEUTRAL2 = "#52514e", "#a9a79f"   # figures that are not about the four configurations
SERIES = {  # config label in the results -> (name in the report, color, marker)
    "stock4 default":           ("Stock PostgreSQL", "#2a78d6", "o"),
    "aio4 T4k S16k I8":         ("AIO, 4 kB threshold", "#eb6834", "s"),
    "stock4 max_sectors_kb=32": ("Stock + kernel split (max_sectors_kb=32)", "#1baf7a", "^"),
    "aio4 T512k S16k I8":       ("AIO, 512 kB threshold", "#6250d6", "D"),
}
ORDER = list(SERIES)
BASE = "stock4 default"

plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "axes.edgecolor": INK2, "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK2,
    "text.color": INK, "font.size": 10, "axes.titlesize": 11, "axes.titleweight": "bold",
    "axes.spines.top": False, "axes.spines.right": False, "axes.grid": True,
    "grid.color": GRID, "grid.linewidth": 0.8, "axes.axisbelow": True,
    "legend.frameon": False, "lines.linewidth": 2, "lines.markersize": 7,
})


def read(path):
    return list(csv.DictReader(open(path))) if os.path.exists(path) else None


def find(*names):
    for n in names:
        p = os.path.join(RES, n)
        if os.path.exists(p):
            return p
    return None


def save(fig, name):
    fig.savefig(os.path.join(OUT, name), dpi=150, bbox_inches="tight")
    plt.close(fig)
    print("wrote fig/" + name)


def clients_axis(ax, clients):
    ax.set_xscale("log", base=2)
    ax.set_xticks(clients)
    ax.set_xticklabels([str(c) for c in clients])
    ax.minorticks_off()
    ax.set_xlabel("clients")


def line_end_label(ax, x, y, text, color):
    ax.annotate(text, (x, y), xytext=(6, 0), textcoords="offset points",
                va="center", fontsize=8.5, color=INK2)


def tps_and_change(d, workload, title, fname, unit="transactions/s", note=None):
    """Two panels: throughput vs clients, and change vs stock (median of per-round ratios)."""
    tps = read(os.path.join(d, "tps.csv")) if d else None
    paired = read(os.path.join(d, "paired.csv")) if d else None
    if not tps or not paired:
        print(f"skip {fname}: no data in {d}"); return
    fig, (a, b) = plt.subplots(1, 2, figsize=(11, 4.2))
    clients = sorted({int(r["clients"]) for r in tps})
    for cfg in ORDER:
        rows = sorted((int(r["clients"]), float(r["tps_median"])) for r in tps if r["config"] == cfg)
        if not rows:
            continue
        name, col, mk = SERIES[cfg]
        a.plot([x for x, _ in rows], [y for _, y in rows], color=col, marker=mk, label=name,
               markeredgecolor=SURFACE, markeredgewidth=1)
    clients_axis(a, clients)
    a.set_ylabel(unit)
    a.set_ylim(bottom=0)
    a.set_title("Throughput (median of rounds)")
    b.axhline(0, color=INK2, linewidth=1)
    for cfg in ORDER:
        if cfg == BASE:
            continue
        rows = sorted((int(r["clients"]), float(r["median_change_pct"]), int(r["rounds_won"]), int(r["rounds"]))
                      for r in paired if r["config"] == cfg)
        if not rows:
            continue
        name, col, mk = SERIES[cfg]
        xs, ys = [x for x, *_ in rows], [y for _, y, *_ in rows]
        b.plot(xs, ys, color=col, marker=mk, label=name, markeredgecolor=SURFACE, markeredgewidth=1)
        line_end_label(b, xs[-1], ys[-1], f"{ys[-1]:+.0f}%", col)
    clients_axis(b, clients)
    b.set_ylabel("change vs stock (%)")
    b.set_title("Change vs stock PostgreSQL (median of paired rounds)")
    handles, labels = a.get_legend_handles_labels()
    fig.legend(handles, labels, loc="lower center", ncol=4, bbox_to_anchor=(0.5, -0.06))
    fig.suptitle(title, x=0.01, ha="left", fontsize=12, fontweight="bold")
    if note:
        fig.text(0.01, -0.12, note, fontsize=8.5, color=INK2, ha="left")
    fig.tight_layout(rect=(0, 0.04, 1, 0.95))
    save(fig, fname)


def device_mechanism(cases, fname):
    """Bars of device counters per configuration, one row per (workload dir, clients) case."""
    have = [(d, c, t) for d, c, t in cases if d and read(os.path.join(d, "raw.csv"))
            and "dev_wps" in read(os.path.join(d, "raw.csv"))[0]]
    if not have:
        print(f"skip {fname}: no device counters yet"); return
    metrics = [("dev_wkb", "average write size (kB)"), ("dev_wps", "device writes per second"),
               ("dev_qd", "average queue depth"), ("tps", "transactions per second")]
    fig, axes = plt.subplots(len(have), len(metrics), figsize=(13, 2.9 * len(have)), squeeze=False)
    for row, (d, c, title) in enumerate(have):
        raw = [r for r in read(os.path.join(d, "raw.csv")) if int(r["clients"]) == c]
        for col, (m, label) in enumerate(metrics):
            ax = axes[row][col]
            vals = []
            for cfg in ORDER:
                v = [float(r[m]) for r in raw if r["config"] == cfg and r[m] not in ("", None)]
                vals.append(statistics.median(v) if v else 0)
            xs = range(len(ORDER))
            bars = ax.bar(xs, vals, color=[SERIES[c][1] for c in ORDER], width=0.7,
                          edgecolor=SURFACE, linewidth=2)
            for x, v in zip(xs, vals):
                ax.annotate(f"{v:,.0f}" if v >= 10 else f"{v:.1f}", (x, v), xytext=(0, 3),
                            textcoords="offset points", ha="center", fontsize=8, color=INK2)
            ax.set_xticks(list(xs))
            ax.set_xticklabels(["stock", "AIO 4k", "stock+split", "AIO 512k"], fontsize=8)
            ax.grid(axis="x", visible=False)
            ax.set_ylim(0, max(vals) * 1.18 if max(vals) else 1)
            if row == 0:
                ax.set_title(label, fontsize=10)
        axes[row][0].set_ylabel(title, fontsize=9.5)
    fig.suptitle("What the device sees: median per run (data-file writes during the run included)",
                 x=0.01, ha="left", fontsize=12, fontweight="bold")
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    save(fig, fname)


def standard_small_multiples(base, fname):
    wls = [("ycsb", "YCSB-A (BenchBase)"), ("tpcc", "TPC-C (BenchBase)"),
           ("sysbench-wo", "sysbench oltp_write_only"), ("sysbench-ins", "sysbench oltp_insert"),
           ("copy", "Bulk COPY (13 MB per txn)")]
    wls = [(w, t) for w, t in wls if base and read(os.path.join(base, w, "paired.csv"))]
    if not wls:
        print(f"skip {fname}: no standard-benchmark data"); return
    ncol = 3; nrow = (len(wls) + 1 + ncol - 1) // ncol
    fig, axes = plt.subplots(nrow, ncol, figsize=(11, 3.3 * nrow), sharey=True, squeeze=False)
    flat = [a for row in axes for a in row]
    for ax, (w, t) in zip(flat, wls):
        paired = read(os.path.join(base, w, "paired.csv"))
        clients = sorted({int(r["clients"]) for r in paired})
        ax.axhline(0, color=INK2, linewidth=1)
        for cfg in ORDER:
            if cfg == BASE:
                continue
            rows = sorted((int(r["clients"]), float(r["median_change_pct"])) for r in paired if r["config"] == cfg)
            if rows:
                name, col, mk = SERIES[cfg]
                ax.plot([x for x, _ in rows], [y for _, y in rows], color=col, marker=mk, label=name,
                        markeredgecolor=SURFACE, markeredgewidth=1)
        clients_axis(ax, clients)
        ax.set_title(t, fontsize=10)
    for row in axes:
        row[0].set_ylabel("change vs stock (%)")
    handles, labels = flat[0].get_legend_handles_labels()
    for ax in flat[len(wls):]:
        ax.axis("off")
    flat[len(wls)].legend(handles, labels, loc="center", fontsize=10)
    fig.suptitle("Standard benchmarks: change vs stock PostgreSQL (median of 3 paired rounds)",
                 x=0.01, ha="left", fontsize=12, fontweight="bold")
    fig.tight_layout(rect=(0, 0, 1, 0.95))
    save(fig, fname)


def storage():
    # Phase 0 and 8a (fio on the gp3 volume), see FINDINGS.md
    fig, (a, b) = plt.subplots(1, 2, figsize=(11, 3.6))
    col = NEUTRAL
    x, v = ["1 in flight", "16 in flight"], [534, 6080]
    a.bar(x, v, color=col, width=0.55)
    for i, y in enumerate(v):
        a.annotate(f"{y:,} /s", (i, y), xytext=(0, 3), textcoords="offset points", ha="center", fontsize=9, color=INK2)
    a.set_title("8 kB durable writes per second: 11x with 16 in flight")
    a.set_ylabel("writes per second"); a.grid(axis="x", visible=False); a.set_ylim(0, 7000)
    x, v = ["1 x 160 kB", "4 x 40 kB", "8 x 20 kB", "20 x 8 kB"], [3.22, 1.80, 1.35, 2.98]
    b.bar(x, v, color=col, width=0.55)
    for i, y in enumerate(v):
        b.annotate(f"{y:.2f} ms", (i, y), xytext=(0, 3), textcoords="offset points", ha="center", fontsize=9, color=INK2)
    b.set_title("Time to make 160 kB durable: 2.4x faster as 8 parallel writes")
    b.set_ylabel("ms"); b.grid(axis="x", visible=False); b.set_ylim(0, 3.8)
    b.annotate("IOPS cap", (3, 2.98), xytext=(0, 16), textcoords="offset points", ha="center", fontsize=8.5, color=INK2)
    fig.suptitle("AWS EBS gp3 (fio, O_DIRECT + O_DSYNC)", x=0.01, ha="left", fontsize=12, fontweight="bold")
    fig.tight_layout(rect=(0, 0, 1, 0.93))
    save(fig, "f1_storage.png")


def progression():
    # Key cells as the changes were added (FINDINGS.md phases 2b/change 1, 4/5/8d, 8b/9)
    cases = [
        ("Small commits, 32 clients\n(fsync scheme, change 1)", ["before", "+ change 1"], [-13.8, -3.1]),
        ("Small commits, 64 clients\n(4 kB pages, O_DSYNC)", ["before", "+ change 2", "+ change 3\nsettings"], [-2.7, 5.5, 11.8]),
        ("Large commits, 1 client\n(bigpc, O_DSYNC)", ["before", "+ change 3", "final\n(T 512k)"], [0.3, 56.2, 59.0]),
    ]
    fig, axes = plt.subplots(1, 3, figsize=(11, 3.4))
    col = NEUTRAL
    for ax, (t, xs, ys) in zip(axes, cases):
        ax.axhline(0, color=INK2, linewidth=1)
        ax.bar(xs, ys, color=col, width=0.55)
        for i, y in enumerate(ys):
            ax.annotate(f"{y:+.1f}%", (i, y), xytext=(0, 3 if y >= 0 else -12), textcoords="offset points",
                        ha="center", fontsize=9, color=INK2)
        ax.set_title(t, fontsize=10); ax.grid(axis="x", visible=False)
        lo, hi = min(ys + [0]), max(ys + [0])
        ax.set_ylim(lo - 0.15 * (hi - lo) - 1, hi + 0.15 * (hi - lo) + 1)
    axes[0].set_ylabel("AIO change vs stock (%)")
    fig.suptitle("Effect of each optimization on the case it targets", x=0.01, ha="left", fontsize=12, fontweight="bold")
    fig.tight_layout(rect=(0, 0, 1, 0.92))
    save(fig, "f6_progression.png")


def harness():
    seqs = []
    for d, name in (("08e-screening", "without quiesce (phase 8e)"), ("08f-screening-quiesce", "with quiesce (phase 8f)")):
        p = os.path.join(RES, d, "log.txt")
        if not os.path.exists(p):
            continue
        seqs.append((name, [int(m.group(1)) for m in re.finditer(r"c=32\s+(\d+) tps", open(p).read())]))
    if len(seqs) < 2:
        print("skip f7_harness.png"); return
    fig, ax = plt.subplots(figsize=(11, 3.4))
    for (name, ys), (col, mk, ls) in zip(seqs, [(NEUTRAL2, "o", "--"), (NEUTRAL, "s", "-")]):
        ax.plot(range(1, len(ys) + 1), ys, color=col, marker=mk, linestyle=ls, label=name,
                markeredgecolor=SURFACE, markeredgewidth=1)
    ax.set_xlabel("run, in execution order (8 configurations x 3 rounds, 32 clients)")
    ax.set_ylabel("transactions/s"); ax.set_ylim(0, 1600)
    ax.legend(loc="lower right")
    ax.set_title("Leftover dirty data from one run slowed the next: every other run lost ~30%", loc="left")
    fig.tight_layout()
    save(fig, "f7_harness.png")


if __name__ == "__main__":
    storage()
    final = find("11-final")
    tps_and_change(os.path.join(final, "pgbench") if final else None, "pgbench",
                   "Small commits (pgbench -N, ~0.5 kB of WAL per commit)", "f2_small.png")
    large = os.path.join(final, "bigpc") if final and os.path.exists(os.path.join(final, "bigpc", "tps.csv")) \
        else find("09-tuned-stock")
    tps_and_change(large, "bigpc", "Large commits (500-row insert, ~150 kB of WAL per commit)", "f3_large.png")
    device_mechanism([(os.path.join(final, "bigpc") if final else None, 1, "large commits,\n1 client"),
                      (os.path.join(final, "bigpc") if final else None, 32, "large commits,\n32 clients"),
                      (os.path.join(final, "pgbench") if final else None, 64, "small commits,\n64 clients")],
                     "f4_device.png")
    standard_small_multiples(os.environ.get("STD", find("10-standard")), "f5_standard.png")
    progression()
    harness()

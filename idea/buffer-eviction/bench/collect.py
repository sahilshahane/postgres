#!/usr/bin/env python3
"""Collect every finished run under RESULTS/<campaign> into one CSV.

usage: collect.py RESULTS_DIR/CAMPAIGN > runs.csv
"""
import csv
import glob
import json
import os
import sys


def read_csv_rows(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [line.rstrip("\n").split(",") for line in f if line.strip()]


def summary(rundir):
    files = glob.glob(os.path.join(rundir, "benchbase", "*.summary.json"))
    if not files:
        return {}
    with open(files[0]) as f:
        s = json.load(f)
    lat = s.get("Latency Distribution", {})
    return {
        "throughput": s.get("Throughput (requests/second)"),
        "goodput": s.get("Goodput (requests/second)"),
        "measured_requests": s.get("Measured Requests"),
        "lat_avg_us": lat.get("Average Latency (microseconds)"),
        "lat_p50_us": lat.get("Median Latency (microseconds)"),
        "lat_p95_us": lat.get("95th Percentile Latency (microseconds)"),
        "lat_p99_us": lat.get("99th Percentile Latency (microseconds)"),
    }


def waits(rundir):
    """Share of sampled active backends waiting on the policy lock / on I/O."""
    total = lock = io = 0
    for row in read_csv_rows(os.path.join(rundir, "waits.csv"))[1:]:
        if len(row) != 4:
            continue
        n = int(row[3])
        total += n
        if row[2] == "BufferEvictionPolicy":
            lock += n
        if row[1] == "IO":
            io += n
    return {
        "samples": total,
        "policy_lock_wait_frac": lock / total if total else None,
        "io_wait_frac": io / total if total else None,
    }


def main():
    root = sys.argv[1]
    out = None
    for done in sorted(glob.glob(os.path.join(root, "**", "done"), recursive=True)):
        rd = os.path.dirname(done)
        with open(os.path.join(rd, "run.json")) as f:
            row = json.load(f)
        row.update(summary(rd))

        db = read_csv_rows(os.path.join(rd, "pg_stat_database.csv"))
        if db:
            hit, read = int(db[0][0]), int(db[0][1])
            row.update(blks_hit=hit, blks_read=read,
                       hit_ratio=hit / (hit + read) if hit + read else None,
                       xact_commit=int(db[0][2]), blk_read_time_ms=float(db[0][4]))

        reads = evictions = 0
        for r in read_csv_rows(os.path.join(rd, "pg_stat_io.csv")):
            if r[0] == "client backend":
                reads += int(float(r[3]))
                evictions += int(float(r[5]))
        row.update(io_reads=reads, io_evictions=evictions)

        ev = read_csv_rows(os.path.join(rd, "eviction_stats.csv"))
        if ev:
            allocs, checks = int(ev[0][1]), int(ev[0][2])
            row.update(policy_allocs=allocs,
                       checks_per_alloc=checks / allocs if allocs else None,
                       s3_small_to_main=int(ev[0][3]), s3_ghost_hits=int(ev[0][5]),
                       drrip_psel=int(ev[0][6]))
        row.update(waits(rd))
        row["sb_mb"] = int(row["shared_buffers"].rstrip("MB")) if row["shared_buffers"].endswith("MB") \
            else int(row["shared_buffers"].rstrip("GB")) * 1024

        if out is None:
            out = csv.DictWriter(sys.stdout, fieldnames=list(row.keys()), extrasaction="ignore")
            out.writeheader()
        out.writerow(row)


if __name__ == "__main__":
    main()

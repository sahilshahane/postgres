#!/usr/bin/env python3
"""
Builds the CSV files in this directory from the raw measurements taken
during the AIO WAL work (2026-11-01).  The raw tables are embedded below
exactly as they were printed by the benchmark scripts, so the CSVs can be
regenerated (python3 build_csv.py).

Code versions (see README.md):
  v1  whole-page writes, a write starting mid-page waits for the previous one
  v2  exact byte-range writes, no same-page waits (unsafe, superseded)
  v3  v2 + "zeroing write" rule, in-flight cap / zeroing waits done before
      taking WALWriteLock
  v4  v3 + single "reaper" waiter, no waiting under WALWriteLock (nowait
      issue), max write size 1 MB -> 32 MB.   == the final code
"""
import csv, os, re

HERE = os.path.dirname(os.path.abspath(__file__))

# --------------------------------------------------------------------------
# Throughput runs.  Each block: metadata + table text.
# Table formats:  "wide"  -> "config  tps@c1 tps@c2 ..." with header clients
#                 "long"  -> "config clients tps lat_ms"
# --------------------------------------------------------------------------
NVME = dict(storage="local NVMe (WDC SN530, ext4)", latency_ms=0,
            write_cache="write back (device)")

def dev(lat, wc):
    return dict(storage=f"dm-delay {lat}ms over loop (ext4)", latency_ms=lat,
                write_cache=wc)

RUNS = [
    dict(run="nvme_v1", code_version="v1", workload="pgbench -N scale 20",
         stat="single 15s", **NVME, fmt="long", default_inflight=16, text="""
stock fdatasync               1       2342        0.427
stock fdatasync               8      12940        0.618
stock fdatasync              32      30812        1.039
stock fdatasync             128      23168        5.525
stock open_datasync           1       2345        0.426
stock open_datasync           8      14085        0.568
stock open_datasync          32      29712        1.077
stock open_datasync         128      23029        5.558
aio io_uring                  1       2317        0.432
aio io_uring                  8       7743        1.033
aio io_uring                 32      18335        1.745
aio io_uring                128      22809        5.612
aio worker                    1       2335        0.428
aio worker                    8       6644        1.204
aio worker                   32      19277        1.660
aio worker                  128      23467        5.454
"""),
    dict(run="nvme_v2", code_version="v2", workload="pgbench -N scale 20",
         stat="single 15s", **NVME, fmt="long", default_inflight=16, text="""
aio io_uring                  1       2369        0.422
aio io_uring                  8       6499        1.231
aio io_uring                 32      11417        2.803
aio io_uring                128      21773        5.879
aio worker                    1       2355        0.425
aio worker                    8       7107        1.126
aio worker                   32      14082        2.272
aio worker                  128      25086        5.103
"""),
    dict(run="nvme_v2_inflight_sweep", code_version="v2",
         workload="pgbench -N scale 20", stat="single 10s", **NVME,
         fmt="wide", clients=[8, 32, 128], text="""
aio uring inflight=1       8558    25273    26808
aio uring inflight=2       9085    26754    27710
aio uring inflight=4       8030    24598    28632
aio worker inflight=1      9183    26664    26693
aio worker inflight=2      9711    27395    22751
aio worker inflight=4      8375    22224    19729
"""),
    dict(run="nvme_v3_inflight_sweep", code_version="v3",
         workload="pgbench -N scale 20", stat="single 10s", **NVME,
         fmt="wide", clients=[1, 8, 32, 128], text="""
aio uring inflight=1       2324    13371    27139    27149
aio uring inflight=2       2319    11494    28334    24335
aio uring inflight=4       2351    10173    27149    24302
aio uring inflight=16      2339     9093    17867    22055
aio worker inflight=1      2250    13758    27354    22713
aio worker inflight=2      2312    11894    26898    21262
aio worker inflight=4      2136     9605    24556    23001
aio worker inflight=16     2306     8854    19324    22713
"""),
    dict(run="nvme_v3_final", code_version="v3", workload="pgbench -N scale 20",
         stat="median of 3 x 10s", **NVME, fmt="wide",
         clients=[1, 8, 32, 128], text="""
stock fdatasync                 2315    14168    28189    22833
stock open_datasync             2370    13114    27264    20459
stock open_datasync+DIO         2523    15219    27035    21072
aio uring inflight=1            2211    12124    28103    26796
aio uring inflight=2            2330    10687    29798    27087
aio worker inflight=1           2301    12640    28533    27049
aio uring inflight=1+DIO        2624    14746    30424    29877
aio uring inflight=4+DIO        2701    13478    28602    26861
"""),
    dict(run="dev1ms_writeback_v3", code_version="v3",
         workload="pgbench -N scale 20", stat="single 12s",
         **dev(1, "write back (emulated)"), fmt="wide",
         clients=[1, 8, 32, 128], text="""
stock fdatasync                  417     1868     7813    18647
stock open_datasync              442     1977     7872    23044
aio uring inflight=1             475     1950     7612    25983
aio uring inflight=4             488     1857     6472    20324
aio uring inflight=16            482     1950     6212    19839
aio worker inflight=16           471     1904     6615    20107
aio uring inflight=16+DIO        472     1930     5317    19077
"""),
    dict(run="dev1ms_writethrough_v3", code_version="v3",
         workload="pgbench -N scale 20", stat="single 12s",
         **dev(1, "write through"), fmt="wide", clients=[1, 8, 32, 128], text="""
stock fdatasync                  994     3983    15822    29912
stock open_datasync              998     3996    15970    30276
aio uring inflight=1             999     3987    15876    30828
aio uring inflight=4             999     3217    10863    29238
aio uring inflight=16            999     3184     9310    27889
aio worker inflight=16          1000     3180     9904    27357
aio uring inflight=16+DIO        998     3991    10715    28981
"""),
    dict(run="dev4ms_writethrough_v3", code_version="v3",
         workload="pgbench -N scale 20", stat="single 12s",
         **dev(4, "write through"), fmt="wide", clients=[1, 8, 32, 128], text="""
stock fdatasync                  226      997     3946    15446
stock open_datasync              222      998     3983    15827
aio uring inflight=1             240      992     3866    13253
aio uring inflight=4             236      936     3025    10726
aio uring inflight=16            237      948     2963     9991
aio worker inflight=16           233      957     3655    11668
aio uring inflight=16+DIO        237      992     2816    11545
"""),
    dict(run="dev1ms_writethrough_v4", code_version="v4",
         workload="pgbench -N scale 20", stat="single 12s",
         **dev(1, "write through"), fmt="wide", clients=[1, 8, 32, 128], text="""
stock fdatasync                  999     3984    15852    30117
stock open_datasync              999     3996    15956    29041
aio uring inflight=1             999     3987    15925    29235
aio uring inflight=4             999     3240    11163    28611
aio uring inflight=16            999     3181    10121    27523
aio worker inflight=16           999     3199    10131    25906
aio uring inflight=16+DIO        996     3989    15807    27624
"""),
    dict(run="dev4ms_writethrough_v4", code_version="v4",
         workload="pgbench -N scale 20", stat="single 12s",
         **dev(4, "write through"), fmt="wide", clients=[1, 8, 32, 128], text="""
stock fdatasync                  225      997     3939    15402
stock open_datasync              244      998     3980    15876
aio uring inflight=1             241      992     3924    14647
aio uring inflight=4             238      952     3575    12606
aio uring inflight=16            243      950     3577    12581
aio worker inflight=16           242      944     3625    12543
aio uring inflight=16+DIO        244      997     3959    14725
"""),
    # large transactions: 500 rows x ~300 B per transaction (~150 kB WAL)
    dict(run="dev4ms_big_v3", code_version="v3", workload="large txn (big.sql)",
         stat="single 12s", **dev(4, "write through"), fmt="wide",
         clients=[1, 8, 32], text="""
stock fdatasync                148        719       1357
stock open_datasync            146        711       1360
aio inflight=1                 136        441        613
aio inflight=4                 137        415        563
aio inflight=16                134        377        503
"""),
    dict(run="dev4ms_big_v4_reaper", code_version="v4-step1 (reaper only)",
         workload="large txn (big.sql)", stat="single 12s",
         **dev(4, "write through"), fmt="wide", clients=[1, 8, 32], text="""
stock fdatasync                172        725       1282
aio inflight=1                 169        556        719
aio inflight=4                 167        439        648
aio inflight=16                150        446        613
aio worker inflight=4          156        449        663
"""),
    dict(run="dev4ms_big_v4_cap32", code_version="v4-step2 (reaper + 32MB writes)",
         workload="large txn (big.sql)", stat="single 12s",
         **dev(4, "write through"), fmt="wide", clients=[1, 8, 32], text="""
stock fdatasync                149        719       1282
aio inflight=1                 149        491        800
aio inflight=4                 142        395        697
aio inflight=16                143        402        861
aio worker inflight=4          148        448        730
"""),
    dict(run="dev4ms_big_v4_a", code_version="v4", workload="large txn (big.sql)",
         stat="single 12s", **dev(4, "write through"), fmt="wide",
         clients=[1, 8, 32], text="""
stock fdatasync                173        715       1214
aio inflight=1                 138        587        977
aio inflight=4                 148        590        924
aio inflight=16                143        446        760
aio worker inflight=4          153        446        680
"""),
    dict(run="dev4ms_big_v4_b", code_version="v4", workload="large txn (big.sql)",
         stat="single 12s", **dev(4, "write through"), fmt="wide",
         clients=[1, 8, 32], text="""
stock fdatasync                169        715       1270
aio inflight=1                 165        544        875
aio inflight=4                 170        428        691
aio inflight=16                146        425        703
aio worker inflight=4          164        419        671
"""),
    dict(run="dev1ms_big_v4", code_version="v4", workload="large txn (big.sql)",
         stat="single 12s", **dev(1, "write through"), fmt="wide",
         clients=[1, 8, 32], text="""
stock fdatasync                483       1052       1143
aio inflight=1                 385        508        672
aio inflight=4                 324        445        549
aio inflight=16                231        346        601
aio worker inflight=4          354        509        564
"""),
]


def parse_config(name, default_inflight=None):
    """Split a config label into its settings."""
    d = dict(wal_io_method="sync", io_method="", wal_io_max_inflight="",
             direct_io="no", wal_sync_method="")
    if name.startswith("stock"):
        d["wal_sync_method"] = "open_datasync" if "open_datasync" in name else "fdatasync"
    else:
        d["wal_io_method"] = "aio"
        d["io_method"] = "worker" if "worker" in name else "io_uring"
        m = re.search(r"inflight=(\d+)", name)
        d["wal_io_max_inflight"] = int(m.group(1)) if m else default_inflight
    if "DIO" in name:
        d["direct_io"] = "yes"
    return d


def throughput_rows():
    for r in RUNS:
        for line in r["text"].strip().splitlines():
            if r["fmt"] == "long":
                m = re.match(r"(.+?)\s+(\d+)\s+(\d+)\s+([\d.]+)$", line.strip())
                name, pairs = m.group(1), [(int(m.group(2)), int(m.group(3)), m.group(4))]
            else:
                m = re.match(r"(.+?)\s+([\d\s]+)$", line.strip())
                name = m.group(1)
                vals = [int(v) for v in m.group(2).split()]
                pairs = [(c, v, "") for c, v in zip(r["clients"], vals)]
            cfg = parse_config(name.strip(), r.get("default_inflight"))
            for clients, tps, lat in pairs:
                yield dict(run=r["run"], code_version=r["code_version"],
                           storage=r["storage"], latency_ms=r["latency_ms"],
                           write_cache=r["write_cache"], workload=r["workload"],
                           stat=r["stat"], config=name.strip(), **cfg,
                           clients=clients, tps=tps, latency_avg_ms=lat)


FIELDS = ["run", "code_version", "storage", "latency_ms", "write_cache",
          "workload", "stat", "config", "wal_io_method", "io_method",
          "wal_io_max_inflight", "direct_io", "wal_sync_method", "clients",
          "tps", "latency_avg_ms"]

# --------------------------------------------------------------------------
# Crash / power-cut correctness runs (summaries)
# --------------------------------------------------------------------------
CRASH = [
    # code_version, test, io_method, extra, crashes, acked_commits, lost, result
    ("v1", "process kill (all / postmaster alternating)", "worker", "", 8, 69832, 0, "pass"),
    ("v1", "process kill (all / postmaster alternating)", "io_uring", "", 8, 26140, 0, "pass"),
    ("v1", "process kill (all / postmaster alternating)", "sync", "", 6, 12536, 0, "pass"),
    ("v1", "process kill (all / postmaster alternating)", "io_uring", "debug_io_direct=wal", 6, 28308, 0, "pass"),
    ("v3", "process kill (all / postmaster alternating)", "sync", "", 4, 8526, 0, "pass"),
    ("v3", "process kill (all / postmaster alternating)", "io_uring", "", 6, 13936, 0, "pass"),
    ("v3", "process kill (all / postmaster alternating)", "io_uring", "debug_io_direct=wal", 6, 32164, 0, "pass"),
    ("v3", "process kill (all / postmaster alternating)", "worker", "", 6, 22099, 0, "pass"),
    ("v3", "power cut (dm-flakey)", "stock wal_io_method=sync", "", 8, 60850, 0, "pass"),
    ("v3", "power cut (dm-flakey)", "worker", "", 8, 45101, 0, "pass"),
    ("v3", "power cut (dm-flakey)", "io_uring", "", 8, 45998, 0, "pass"),
    ("v3", "power cut (dm-flakey)", "io_uring", "debug_io_direct=wal", 8, 43438, 0, "pass"),
    ("v3", "power cut (dm-flakey) - negative control", "worker", "fsync=off", 1, "", "", "unrecoverable cluster (expected)"),
    ("v4", "process kill (all / postmaster alternating)", "io_uring", "", 6, 15043, 0, "pass"),
    ("v4", "process kill (all / postmaster alternating)", "worker", "", 6, 22046, 0, "pass"),
    ("v4", "process kill (all / postmaster alternating)", "io_uring", "debug_io_direct=wal", 6, 28401, 0, "pass"),
    ("v4", "power cut (dm-flakey)", "worker", "", 6, 117485, 0, "pass"),
    ("v4", "power cut (dm-flakey)", "io_uring", "", 6, 124239, 0, "pass"),
    ("v4", "power cut (dm-flakey)", "io_uring", "debug_io_direct=wal", 6, 114086, 0, "pass"),
]

REGRESS = [
    # code_version, suite, wal_io_method, io_method, passed, total
    ("v1", "regress", "aio", "worker", 239, 239),
    ("v1", "regress", "aio", "io_uring", 239, 239),
    ("v1", "regress", "aio", "sync", 239, 239),
    ("v1", "regress", "sync", "worker", 239, 239),
    ("v1", "isolation", "aio", "worker", 134, 134),
    ("v3", "regress", "aio", "worker", 239, 239),
    ("v3", "regress", "aio", "io_uring", 239, 239),
    ("v4", "regress", "aio", "worker", 239, 239),
    ("v4", "regress", "aio", "io_uring", 239, 239),
]

# steady-state archive + pg_waldump test (pgbench -c 32, 8s, 1MB segments)
STEADY = [
    # code_version, io_method, direct_io, tps, max_inflight_sampled, out_of_order_completions, segments_archived, missing, waldump
    ("v1", "worker", "no", 9795, "", 485, 578, 0, "ok"),
    ("v1", "io_uring", "no", 9347, "", 42, 554, 0, "ok"),
    ("v1", "sync", "no", 5374, 1, 0, 364, 0, "ok"),
    ("v1", "worker", "no", 9018, 3, 409, 543, 0, "ok"),
    ("v1", "io_uring", "no", 7102, 3, 42, 446, 0, "ok"),
    ("v3", "worker", "no", "", 3, 678, 435, 0, "ok"),
    ("v3", "io_uring", "no", "", 3, 100, 412, 0, "ok"),
    ("v3", "io_uring", "yes", "", 3, 129, 365, 0, "ok"),
]

# micro measurements
MICRO = [
    # name, value, unit, notes
    ("pg_test_fsync open_datasync 8kB", 4533.785, "ops/s", "local NVMe, 221 us/op"),
    ("pg_test_fsync fdatasync 8kB", 3917.634, "ops/s", "local NVMe, 255 us/op"),
    ("pg_test_fsync fsync 8kB", 2690.759, "ops/s", "local NVMe, 372 us/op"),
    ("pg_test_fsync open_sync 8kB", 2742.316, "ops/s", "local NVMe, 365 us/op"),
    ("O_DSYNC 2MB write, aligned", 5.2, "ms/write", "4ms write-through dm-delay device"),
    ("O_DSYNC 2MB write, unaligned (+1234)", 5.0, "ms/write", "4ms write-through dm-delay device"),
    ("O_DSYNC 2MB write, overlapping previous tail page", 5.1, "ms/write", "4ms write-through dm-delay device"),
    ("big txn c=32 stock: WAL writes per 10s", 1024, "writes", "v4-step2; 2097 kB/write, pwrite 0.31 ms, fdatasync 5.07 ms"),
    ("big txn c=32 aio io_uring inflight=1: WAL writes per 10s", 649, "writes", "v4-step2; 2014 kB/write"),
    ("big txn c=32 aio worker inflight=1: WAL writes per 10s", 584, "writes", "v4-step2; 1937 kB/write"),
]

# wait-event samples (pg_stat_activity, 50 ms sampling) during big txn runs
WAITS = [
    # code_version, config, clients, wait_event, samples
    ("v3", "aio io_uring inflight=1", 8, "LWLock:AioUringCompletion", 481),
    ("v3", "aio io_uring inflight=1", 8, "LWLock:WALWrite", 163),
    ("v3", "aio io_uring inflight=1", 8, "Activity:WalWriterMain", 89),
    ("v3", "aio io_uring inflight=1", 8, "IO:AioIoUringExecution", 78),
    ("v3", "aio io_uring inflight=1", 8, "CPU", 52),
    ("v4-step1 (reaper only)", "stock fdatasync", 32, "LWLock:WALWrite", 1689),
    ("v4-step1 (reaper only)", "stock fdatasync", 32, "CPU", 94),
    ("v4-step1 (reaper only)", "stock fdatasync", 32, "IO:WalSync", 34),
    ("v4-step1 (reaper only)", "aio io_uring inflight=1", 32, "LWLock:WALWrite", 1315),
    ("v4-step1 (reaper only)", "aio io_uring inflight=1", 32, "IO:WalWrite", 505),
    ("v4-step1 (reaper only)", "aio io_uring inflight=1", 32, "IO:AioIoUringExecution", 36),
    ("v4", "aio io_uring inflight=1", 32, "IO:WalWrite", 803),
    ("v4", "aio io_uring inflight=1", 32, "LWLock:WALWrite", 792),
    ("v4", "aio io_uring inflight=1", 32, "CPU", 138),
]


def write(name, header, rows):
    with open(os.path.join(HERE, name), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)
    print(f"wrote {name}: {len(rows)} rows")


rows = list(throughput_rows())
with open(os.path.join(HERE, "throughput.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, FIELDS)
    w.writeheader()
    w.writerows(rows)
print(f"wrote throughput.csv: {len(rows)} rows")
write("crash_tests.csv", ["code_version", "test", "io_method", "extra_settings",
                          "crashes", "acknowledged_commits", "lost_commits", "result"], CRASH)
write("regression.csv", ["code_version", "suite", "wal_io_method", "io_method",
                         "passed", "total"], REGRESS)
write("steady_archive.csv", ["code_version", "io_method", "direct_io", "tps",
                             "max_wal_writes_inflight_sampled",
                             "out_of_order_completions", "segments_archived",
                             "segments_missing", "pg_waldump"], STEADY)
write("micro.csv", ["measurement", "value", "unit", "notes"], MICRO)
write("wait_events.csv", ["code_version", "config", "clients", "wait_event",
                          "samples"], WAITS)

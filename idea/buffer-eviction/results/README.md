# Buffer eviction policy study: results

Results of the `main` campaign (run 2026-11-23) comparing six buffer replacement
policies inside PostgreSQL 20devel (`buffer_eviction_policy` GUC, branch `idea2`):
`clock` (the PostgreSQL default and our baseline), `srrip`, `brrip`, `drrip` (RRIP, ISCA'10),
`sieve` (NSDI'24), `s3fifo` (SOSP'23).

## Files

| Path | Contents |
|---|---|
| `main-runs.csv` | one row per finished run (139 runs), output of `bench/collect.py` |
| `main-summary.csv` | one row per workload × shared_buffers × policy: means over reps, rep spread, deltas vs clock |
| `main-tables.md` | report-ready Markdown tables (miss ratio, vs clock, throughput, p99, eviction cost, win count) |
| `summarize.py` | regenerates the two files above: `python3 summarize.py main-runs.csv main` |
| `raw/main/<workload>/<policy>/sb<size>/rep<n>/` | per-run data copied from the bench server (see below) |
| `raw/main-trace/tpcc/run/` | the TPC-C trace-recording run (the trace itself stays on the server) |
| `raw/pilot/` | earlier pilot campaign (method shakedown, not for the report) |
| `setup/` | server README, `postgresql.bench.conf`, BenchBase XMLs + patch + commit, dataset sizes, scale factors, upstream `SOURCE_COMMIT`, full `eviction.patch`, `hardware.txt`, campaign log |

Each run directory contains:
- `benchbase/*.summary.json`: throughput and latency percentiles.
- `pg_stat_database.csv` and `pg_stat_io.csv`.
- `eviction_stats.csv`, from `pg_buffer_eviction_stats()`.
- `waits.csv`: wait-event samples taken once per second.
- `postgres.log`: its first line confirms which policy was active.
- `run.json`: the run's parameters.

The BenchBase `*.raw.csv` files hold per-request latencies, up to 200 MB each,
7 GB in total. They were **not** copied. They remain on the server under
`neel@10.129.148.248:/home/neel/postgres_sahil/bench/results/`.

## Setup

**Hardware** (`setup/hardware.txt`): AMD Ryzen 7 5700G, 8 cores / 16 threads, 15 GB RAM.
The machine is shared with other users. Storage is an Intel 660p QLC NVMe SSD (512 GB, ext4), on Linux 6.17.

**Software:**
- PostgreSQL 20devel, release build without asserts.
- BenchBase at commit `33c0047`.
- OpenJDK 21.

**Method** (`setup/configs/postgresql.bench.conf`):
- `debug_io_direct=data` bypasses the OS page cache, so every
  shared_buffers miss is a real SSD read.
- Each run cold-starts from a pristine copy of the loaded database.
- bgwriter and autovacuum are off, `synchronous_commit=off`, no parallel query, no JIT.
- Statistics are reset after a 30 s warm-up; then 120 s are measured with 16 terminals.

**Sweep:** shared_buffers ∈ {128 MB, 256 MB, 512 MB, 1 GB} × 6 policies.

| Workload | BenchBase scale | DB size | Reps |
|---|---|---|---|
| TPC-C | 20 warehouses | 2.16 GB | 2 |
| YCSB-B (95% read, Zipfian) | 2000 | 2.43 GB | 2 |
| YCSB-E (short scans, Zipfian) | 2000 | 2.43 GB | 1 (planned 2) |
| TPC-H | SF 1 | 2.14 GB | 1 |

**Main metric:** buffer miss ratio, computed as `1 - blks_hit/(blks_hit+blks_read)`. It repeats
within ≤0.3 points between reps. Throughput is reported, but it varies 20–40% between reps in
several configurations, and in the worst case (TPC-C brrip at 128 MB) by 143%. So throughput
supports the miss-ratio results; it cannot rank the policies on its own.

## Status (as of 2026-11-24)

Done:
- TPC-C, YCSB-B, TPC-H: complete.
- YCSB-E: complete at 128, 256 and 512 MB.

Missing:
- **YCSB-E at 1 GB:** only srrip has run. clock, brrip, drrip, sieve and s3fifo are missing.
- **Offline trace analysis:** this is the comparison against Belady OPT, LRU, ARC, LIRS and others via evictsim and libCacheSim.
  - TPC-C: the run was recorded at 256 MB. Its 118 per-backend files, 225 MB in total, are in
    `main-trace/tpcc/trace/` on the server, but they were never merged or replayed.
  - YCSB-B, YCSB-E, TPC-H: no trace has been recorded yet.

To finish, rerun `bench/scripts/campaign.sh main` on the server. Finished runs are skipped.
Then copy the new results here and rerun `summarize.py`.

## Findings so far

Full numbers are in `main-tables.md`.

Each row counts as a "case": one workload at one shared_buffers size.

| Policy | Lowest miss ratio (of 15 complete cases) | Worst case vs clock |
|---|---|---|
| **SIEVE** | **9**: most of TPC-C, YCSB-B, YCSB-E | +19% misses (TPC-H, 1 GB) |
| **S3-FIFO** | 4 (incl. TPC-H 128/512 MB) | +8% (TPC-C, 1 GB) |
| BRRIP | 2 (TPC-H 256 MB, 1 GB) | +0.6% |
| clock, SRRIP, DRRIP | 0 | — |

1. **SIEVE and S3-FIFO are best on skewed point-access workloads.**
   - YCSB-B: miss ratio −27% vs clock at 128 MB, shrinking to −3% at 1 GB.
   - YCSB-E: −8 to −11%.
   - At 128 MB on YCSB-B, throughput rises about 25–28% and p99 falls from 15.8 ms to 2.3 ms (SIEVE).
2. **SIEVE has a weakness on scans.** On TPC-H it is the worst policy, and the gap grows with the
   buffer size (+2% to +19% misses). S3-FIFO, whose small probationary FIFO filters scans, and BRRIP,
   whose insertion rule resists scans, do best there. This matches the known trade-off: SIEVE has no
   scan resistance.
3. **SRRIP and DRRIP behave almost like clock.** They come within a few percent of it, except on TPC-H
   at 1 GB (≈ −9%). DRRIP's set dueling adds little over SRRIP.
4. **Contention and eviction cost:**
   - The shared policy lock is not a bottleneck: it accounts for ≤0.13% of wait-event samples.
   - SIEVE does the least work per eviction, 1.1–4.5 buffers inspected per eviction, against 2.8–13 for clock.
5. **Overall:** SIEVE wins the most cases. S3-FIFO is the most robust single choice, near the top
   everywhere with a mild worst case. BRRIP is the safest, never meaningfully worse than clock, but
   its gains are smaller.

Caveats:
- YCSB-E and TPC-H have a single rep each.
- The 1 GB YCSB-E row is incomplete.
- The offline OPT, ARC and LIRS bounds are still pending.

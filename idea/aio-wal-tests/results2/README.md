# AIO WAL v6: group-commit-preserving optimizations, benchmark results

Measured 2026-11-24 on the shared benchmark machine: AMD Ryzen 7 5700G
(8 cores / 16 threads), 15 GB RAM, Intel 660p 512 GB QLC NVMe (volatile write
cache, FUA supported), WAL and data on a dedicated XFS partition
(`/mnt/xfs`, reflink=1), Linux, PostgreSQL 20devel, release builds
(`-O3`, no cassert, liburing).

## What changed since v5 (the version in the report)

v5 lost to stock PostgreSQL at moderate concurrency with
`wal_io_max_inflight > 1` (up to -51% at 16 clients), and at 1-4 clients with
`wal_io_max_inflight = 1`. Root causes, and the fix for each:

| # | cause | fix (GUC, default) |
|---|---|---|
| 1 | **Greedy pipelining destroys group commit.** Every committer that finds a free in-flight slot starts its own write/fsync. A single SSD executes cache flushes one at a time, so it alternates between one large batch and one tiny batch, and every flush is paid for by fewer commits. | **Adaptive batching** (`wal_io_pipeline_threshold`, 256kB): while an IO is in flight, start another only if it would carry at least that much WAL; otherwise publish the request and wait for the in-flight IO, so the next IO carries everyone's WAL. Large transactions still pipeline. |
| 2 | **Idle device between group commits.** When an IO completes, the process that sees it is usually already satisfied and returns; a *sleeping* waiter must wake up, take `WALWriteLock` and issue the next IO. | **Eager issue** (`wal_io_eager_issue`, now **off** by default, see below): the completing backend issues the published requests itself (`XLogAioIssuePending()`, conditional lock, never blocks). Measured: it costs more than it saves, because the IO it issues can't be inline. |
| 3 | **io_uring fsync / O_DSYNC write is a thread hand-off.** `IORING_OP_FSYNC` and a buffered `O_DSYNC` write cannot complete without blocking, so the kernel passes them to an io-wq worker thread and back: two context switches on every group commit's critical path. | **Inline IO** (`wal_io_inline_fsync`, on): a backend issuing an fsync (or, with `open_datasync`, the last O_DSYNC write) it will wait for anyway enters it in the in-flight tracker, releases `WALWriteLock`, and performs it itself. Other waiters sleep on the tracker's condition variable. WAL-writer and eager-issue IO still use AIO. The O_DSYNC part was added after the `final_odsync` run and is measured in `final_odsync2`. |

All three are runtime switchable (`PGC_SIGHUP`), so one binary gives the
ablation. Correctness: `scripts/crash_test.py` passes for every mode
(io_uring fdatasync, threshold 0, open_datasync, open_datasync + direct IO,
worker, inline off): 6 crashes each, 0 acknowledged commits lost.

## Method (`scripts/bench2.sh`, `scripts/summarize2.py`)

The previous campaigns (10 s x 3 reps, configs back to back) were dominated by
the SSD, not by the code: the 660p is QLC and ~90% full, so its SLC write
cache is small. After a few GB of sustained writes, fsync latency rises from
~0.45 ms to 4-10 ms for minutes, and even stock PostgreSQL drops below 200 TPS.
The new harness keeps the device in the same state for every measurement:

- **Interleaved rounds.** Each round runs every config once per client count,
  in an order rotated each round, so drift hits all configs equally. Results
  are the **median over rounds**; the spread (max-min) is reported too.
- **Device canary gate.** Before each config run: 200 x 8 kB `O_DSYNC` writes;
  if the mean is above 700 us the harness waits (15 s steps) until the drive
  has recovered. The canary value is stored with every row.
- **No setup writes.** Data directories are XFS reflink copies of one golden
  pgbench scale-20 cluster (VACUUM ANALYZE + CHECKPOINT); `sync` before
  measuring; 10 s idle after each server stop.
- **`full_page_writes = off`.** After every checkpoint, full-page images are
  most of the WAL volume (identical for all configs) and they fill the SSD
  cache. This isolates the commit/flush path being optimized.
- Server: `shared_buffers = 1GB`, `wal_buffers = 64MB`,
  `max_wal_size = 8GB`, `checkpoint_timeout = 30min`, autovacuum off;
  a CHECKPOINT and a 2 s warm-up (not recorded) at each server start.
- Workloads: `pgbench -N` (small commits, ~0.5 kB WAL each, 6 s per point)
  and `big.sql` (500-row insert, ~150 kB WAL per commit, 5 s per point).

Binaries: `stock` = upstream base commit; `v5` = commit eccb8fb (the report);
`opt` = v5 + this change.

## Results

Numbers are **paired** changes vs stock: per round, config TPS / stock TPS
in the same round, median over rounds (`paired2.py`). Absolute TPS moved by
up to 2x between rounds with the SSD's state, the ratios much less.

### Headline: final code with default settings, `headline_paired.csv`

bench3 with seven servers up at once (stock, v5 and opt in both durability
modes), 5 s runs, each mode vs its own stock. Round 6 of 6 is excluded:
`/mnt/xfs` filled up during it and every server, stock included, stopped with
ENOSPC (data directories of earlier campaigns had not been removed; fixed).
`scripts/headline2.py` drops a (round, clients) block for **all** configs if
any config in it fell below half its median (the SSD collapsing mid-block):
5 of the remaining 30 blocks dropped.
Brackets: rounds in which the config beat stock.

| clients | 1 | 4 | 8 | 16 | 32 | 64 |
|---|---:|---:|---:|---:|---:|---:|
| fdatasync: v5 inflight=1 | -1.3% | -5.2% | -4.4% | -5.9% | -11.3% | -11.1% |
| fdatasync: v5 inflight=16 (report) | -2.1% | -13.4% | -35.6% | -34.9% | -36.5% | -14.5% |
| **fdatasync: opt inflight=16** | **-1.1%** | **-0.4%** | **-1.4%** | **-4.2%** | **-8.2%** | **-5.3%** |
| O_DSYNC: v5 inflight=16 | -1.3% | -6.8% | -15.9% | -31.7% | -22.9% | -14.9% |
| **O_DSYNC: opt inflight=16** | **-0.2%** | **-0.6%** | **-2.0%** | **-2.7%** | **-5.8%** | **-4.9%** |

Defaults of the final code: `wal_io_pipeline_threshold = 256kB`,
`wal_io_inline_fsync = on`, `wal_io_eager_issue = off`. Crash tests with
these defaults (fdatasync and open_datasync, 6 crashes each): no lost commit.

### fdatasync (Linux default), pgbench -N, `paired_hi.csv` (bench3: all servers up, 5 s alternation, 6 rounds; eager on)

| clients | v5 inflight=1 | v5 inflight=16 (report) | **opt inflight=16** |
|---:|---:|---:|---:|
| 8 | -4.7% | -38.4% | **-2.6%** |
| 16 | -5.0% | -36.4% | **-3.1%** |
| 32 | -9.4% | -24.8% | **-3.5%** |
| 64 | -10.6% | -13.9% | **-3.8%** |

### fdatasync ablation, `paired_fdatasync.csv` (bench2: 4 rounds)

| clients | 1 | 4 | 8 | 16 | 32* | 64* |
|---|---:|---:|---:|---:|---:|---:|
| v5 inflight=1 | -2.1% | -5.1% | -7.0% | -5.8% | +4.6% | -9.5% |
| v5 inflight=16 | -2.1% | -12.4% | -38.9% | -34.5% | -9.9% | -26.1% |
| batch only | -0.8% | -2.8% | -5.4% | -7.4% | +2.3% | -3.9% |
| batch + eager | -1.2% | -2.4% | -3.2% | -3.9% | -1.9% | -3.7% |
| batch + inline | -0.2% | -0.6% | -2.3% | -6.1% | +8.8% | -5.3% |
| all three | -1.2% | -3.7% | -3.4% | -3.8% | -5.7% | -7.7% |

\* the SSD switched speed between rounds at 32/64 clients; see the bench3
table above for those.

**Reading.** Adaptive batching removes the v5 regression (-35..-39% at 8-16
clients becomes about -3%). With it, `wal_io_max_inflight = 16` is no longer
a trap, and AIO is better than v5's best setting (inflight 1) at every client
count. Eager issue and inline IO are each worth at most a few percent, within
the spread of this device. The remaining ~3% vs stock is the AIO bookkeeping
(in-flight tracker, condition-variable wake-ups) on a device that executes
flushes one at a time. On such a device, stock group commit is already close
to optimal for small commits, so parity is the ceiling. Gains need a device
that overlaps flushes (cloud block storage, RAID, enterprise NVMe with power
loss protection); see the dm-delay results in `../results/`.

### O_DSYNC (`open_datasync`), `paired_odsync_hi.csv` (bench3, 6 rounds; opt has inline writes, eager on)

| clients | v5 inflight=16 | **opt inflight=16** | stock + direct IO | opt + direct IO |
|---:|---:|---:|---:|---:|
| 4 | -4.8% | **-13.1%** | +3.1% | -0.7% |
| 8 | -14.7% | **-5.6%** | -4.4% | -6.5% |
| 16 | -26.0% | **-2.9%** | -9.0% | -10.3% |
| 32 | -20.5% | **-2.2%** | -16.7% | -17.3% |
| 64 | -13.9% | **-2.6%** | -2.3% | +1.0% |

All relative to stock `open_datasync` (buffered). With direct IO, opt tracks
stock with direct IO.

### Eager issue hurts at low concurrency: default changed to off (`paired_eager_raw.csv`)

| clients | 2 | 4 | 8 | 16 |
|---|---:|---:|---:|---:|
| O_DSYNC, eager on | -13.2% | -13.3% | -5.4% | -2.2% |
| O_DSYNC, eager off | **+1.1%** | **+0.2%** | -0.9% | -2.3% |
| fdatasync, eager on | -1.8% | -2.4% | -3.2% | -4.7% |
| fdatasync, eager off | -1.0% | -1.2% | -1.7% | -5.0% |

The backend that issues for others returns right after, so that IO always
goes through io_uring (thread hand-off) and never inline. That explains the
4-client dip above. `wal_io_eager_issue` now defaults to off; the headline
run below uses the defaults.

### Large transactions (`final_big.csv`): inconclusive on this SSD

Each 5 s run writes ~1 GB of WAL, which exhausts the 660p's SLC cache inside
the run: every config, stock included, randomly fell below 100 TPS. Only 1
client was stable: opt -0.7%, v5 -4.1% vs stock.

## Files

- `final_fdatasync.csv`, `final_odsync.csv`, `final_big.csv`: raw rows, one
  per (round, config, clients): tps, average latency, canary.
- `summary_*.csv`: median / min / max / stdev per (config, clients) and the
  change vs the stock baseline, from `summarize2.py --csv`.
- `cfg_*.txt`: exact configurations.

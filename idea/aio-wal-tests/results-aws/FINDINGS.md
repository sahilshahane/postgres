# AIO WAL on network storage (AWS EBS gp3): progress log

One entry per phase or code change, newest last: what was run or changed,
why, and what it showed. Raw data for each phase is in its own directory.

## Setup

| | |
|---|---|
| VM | AWS `c6i.2xlarge` (8 vCPU Xeon 8375C, 16 GB), Sydney `ap-southeast-2a`, Ubuntu 24.04, kernel 7.0.0-1018-aws |
| WAL + data | EBS **gp3**, 100 GB, 6,400 IOPS provisioned, 125 MB/s, XFS (reflink) |
| Builds | release (`-O3`, no cassert, liburing); `stock` = upstream base `126976a8ff`, `aio` = `5a78e355b7` (incl. the `wal_sync_method` reload fix) |
| Harness | `bench/bench.sh` (all configs' servers up at once, paired rounds, canary gate), `bench/analyze.py` (per-round ratio vs the stock config of the same durability mode) |
| Scripts | `bench/aws/aws_up.sh`, `aws_eice.sh` (SSH over HTTPS, campus network blocks port 22), `aws_down.sh` |

## Phase 0: does the storage overlap durable writes? (`00-setup/`)

fio, 8 kB `O_DSYNC` writes to one file:

| in flight | IOPS | mean latency |
|---|---:|---:|
| 1 (QD1) | 534 | 1.87 ms |
| 16 (QD16) | **6,080** (the 6,400 IOPS cap) | 2.63 ms |

**11x more durable writes per second with 16 in flight**, at nearly the same
latency. The local Intel 660p on the benchmark server could not do this
(it executes flushes one at a time), which is why AIO could at best match
stock there. gp3 is the kind of storage AIO WAL is designed for: if it
doesn't win here, the design has a problem.

Note: 6,400 IOPS is a hard cap. A scheme that issues more, smaller writes
per commit than stock will hit it sooner.

## Phase 1: pgbench -N, 1-64 clients (`01-main-gp3/`)

10 configs, 8 paired rounds x 10 s per (config, clients); 0 of 48 blocks
dropped (gp3 is stable, unlike the 660p). Change vs the stock config of the
same durability mode, median over rounds [rounds won of 8]:

| config | 1 | 4 | 8 | 16 | 32 | 64 |
|---|---:|---:|---:|---:|---:|---:|
| aio fdatasync, default (inflight 1) | +0.2% [5] | -0.9% [0] | -2.5% [0] | -5.1% [0] | **-13.5%** [0] | -5.2% [0] |
| aio fdatasync, inflight 16, batching 256 kB | +0.3% [6] | -0.9% [0] | -2.7% [0] | -5.1% [0] | **-13.3%** [0] | -5.4% [0] |
| aio fdatasync, inflight 16, **no batching** | -0.3% [4] | -46.8% [0] | -37.1% [0] | -34.3% [0] | -39.5% [0] | -33.9% [0] |
| aio O_DSYNC buffered, **no batching** | +3.0% [6] | -42.1% [0] | -63.4% [0] | -74.0% [0] | -69.8% [0] | -25.1% [0] |
| aio O_DSYNC + direct IO, batching 256 kB | -0.1% [3] | -0.7% [0] | -2.2% [0] | -3.9% [0] | **-12.6%** [0] | +1.0% [5] |
| aio O_DSYNC + direct IO, no batching | -0.1% [1] | -0.6% [0] | -2.1% [0] | -4.1% [0] | -17.9% [0] | -3.3% [0] |
| same + eager issue | -0.1% [2] | -0.7% [0] | -2.0% [0] | -4.0% [0] | -17.6% [0] | -3.2% [0] |

Absolute: stock fdatasync 870 / 2,105 / 4,161 / 8,207 / 15,963 / 21,100 TPS.

### Findings

1. **AIO is correct but does not beat stock on gp3 either.** The best AIO
   configs are at parity at 1-8 clients and 4-13% behind at 16-32 clients.
   They never won a round between 4 and 32 clients. Only at 64 clients does
   direct IO + batching reach parity (+1.0%, 5 of 8 rounds).
2. **Pipelining small commits is strongly harmful** (-34% to -74%). Without
   batching each commit becomes its own write and flush. Buffered writes to
   one WAL file are serialized by the filesystem, so overlapping them only
   multiplies device flushes (buffered O_DSYNC: commit latency 7.9 ms vs
   1.95 ms for stock at 16 clients). With direct IO the same-page rule
   serializes the writes instead, so no batching behaves like batching.
3. **Stock group commit is already close to the best possible here.** Stock
   commit latency stays at 1.90-2.00 ms from 4 to 32 clients, while TPS
   scales linearly (2,105 -> 15,963). fio shows a single durable write takes
   1.87 ms at QD1 and **2.63 ms at QD16**: parallel writes get slower each.
   So "one IO per commit, all in parallel" would *not* give commits lower
   latency than stock's ~1.9 ms. **This corrects my earlier estimate of
   +40-70% headroom** (based on the 1.15 ms single-client commit), which
   ignored that per-IO latency rises with queue depth. The page-per-commit
   idea (fresh 4 kB WAL page per pipelined flush, direct IO) would remove the
   same-page serialization, but on gp3 its ceiling is roughly parity with
   stock, at up to 8x more WAL volume. Not worth building for gp3.
4. **The consistent loss at 32 clients (-13%) is AIO overhead, not storage.**
   All batching configs show it, with or without direct IO, with or
   without eager issue, while the WAL per flush (~32 x 0.5 kB = 16 kB) is
   below the 256 kB threshold, so no pipelining happens. These configs then
   do what stock does, plus the AIO bookkeeping: in-flight tracker, condition
   variable wake-ups, hand-off of the next IO to a woken waiter. This is the
   concrete optimization target. Next step: a wait-event / perf profile at
   32 clients, stock vs AIO. (Attempted; the VM had been stopped.)

## Phase 1b: where backends wait at 32 clients (`01b-profile-32c/`)

The VM had been stopped at 21:10 IST by the program's Budgets spend-limit
action (`AWSServiceRoleForBudgetsSpendLimitMember`), which then also denied
starting or launching instances. The user removed the limit and the VM was
restarted. No data was lost (phase 1 was already copied).

pg_stat_activity sampled every 20 ms during 15 s of pgbench -N, 32 clients,
fresh servers (absolute TPS is lower than in phase 1 because of the sampler):

| wait | stock fdatasync (9,697 TPS) | aio fdatasync if=16 thr=256kB (9,081 TPS, -6%) |
|---|---:|---:|
| waiting for the group-commit flush | 77.1% `LWLock:WALWrite` | 81.8% `IO:WalSync` |
| performing the flush | 3.0% `IO:WalSync` | (included above) |
| on CPU | 7.8% | 8.3% |
| waiting for the client | 10.5% | 8.4% |

Both spend ~80% of the time waiting for the flush; AIO waits on the IO
itself rather than on the lock, as designed. CPU time is the same, so the
AIO overhead is **added latency per flush cycle**, not CPU work. Suspect:
the hand-off after an fsync completes (wake the waiters, one of them takes
WALWriteLock, writes the new WAL, starts the next fsync).

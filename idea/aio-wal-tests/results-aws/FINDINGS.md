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

## Phase 2: large transactions (`02-big-gp3-300MiBs/`)

Volume throughput raised from 125 to **300 MiB/s** (the instance's sustained
EBS limit is 312 MB/s; above it only bursts would help, which would vary
mid-run). The modification had completed before the run. `big.sql` (500-row
insert) writes **160 kB of WAL per commit**. 6 configs, 6 paired rounds x
10 s, 0 of 18 blocks dropped.

| change vs stock | 1 client | 4 | 16 |
|---|---:|---:|---:|
| aio fdatasync, batching 256 kB | +0.8% [3/6] | -9.5% [0/6] | +2.0% [4/6] |
| aio fdatasync, no batching | -1.2% [2/6] | -1.4% [2/6] | **+6.2% [5/6]** |
| aio O_DSYNC + direct IO, batching 256 kB | -0.2% [3/6] | -0.5% [3/6] | +2.5% [3/6] |
| aio O_DSYNC + direct IO, no batching | -0.1% [3/6] | -2.3% [2/6] | -6.1% [2/6] |

Stock: 304 / 557 / 684 TPS = 49 / 89 / 110 MB/s of WAL.

- **First majority win for AIO: pipelined large commits at 16 clients,
  +6.2% (5 of 6 rounds).** As predicted, large commits pipeline without the
  same-page serialization that hurts small ones.
- **The workload is not WAL-throughput bound**: 110 MB/s of 300 MiB/s. Wait
  events at 16 clients (stock): 54% `LWLock:WALWrite`, **22% `Lock:extend`**
  (16 clients extending the same table), 9% `IO:DataFileWrite`. TPS barely
  grows from 4 to 16 clients for that reason, which caps any WAL-side gain.
- The -9.5% at 4 clients for fdatasync + batching is unexplained (one
  config, 0 of 6 rounds); the no-batching variant is at -1.4% there.

## Phase 2b: why AIO loses 7-13% at 32 clients (`02b-diagnosis-32c/`)

pgbench -N, 32 clients, 10 s windows, stock fdatasync vs aio fdatasync
(inflight 16, batching 256 kB):

| | stock | aio |
|---|---:|---:|
| TPS | 9,979 | 9,491 (-4.9%) |
| voluntary context switches per commit | 6.05 | 6.14 |
| commits per WAL fsync (group size) | 15.29 | 15.64 |
| average fsync (`track_wal_io_timing`) | 1.477 ms | 1.488 ms |
| flush cycle (10 s / fsyncs) | 1.518 ms | 1.631 ms |
| **gap: one fsync ends -> next starts** | **0.041 ms** | **0.143 ms** |

- Ruled out: extra wake-ups (switches per commit equal), smaller groups
  (equal), slower fsyncs (equal). My first hypothesis, extra wake-ups, was
  wrong.
- **Cause: the hand-off between consecutive fsyncs is 3.5x longer**, about
  0.1 ms extra per flush cycle, which is the whole loss. After an inline
  fsync, the issuer broadcasts `aioWaitCV`. All ~31 waiters wake and each
  runs the issue path (flush / issued checks, spinlocks, `WaitXLogInsertionsToFinish`)
  before racing for `WALWriteLock`. The next fsync starts only when the
  winner gets through. Stock's next leader is already queued on the lock.
- The existing `wal_io_eager_issue` lets the first backend whose WAL became
  durable issue the next IO, but not inline: it goes through io_uring (a
  kernel worker thread hand-off), which is why eager was measured as harmful
  and is off by default.

**Change 1 (next):** let eager issue run the next fsync / O_DSYNC write
inline.

## Change 1: eager issue executes the fsync inline (`03-change1-eager-inline/`)

**Change** (`XLogAioIssuePending()`): with `wal_io_eager_issue = on` and
`wal_io_inline_fsync = on`, the backend that finds its own WAL durable and
issues the published requests now runs that fsync (or last O_DSYNC write)
itself, after releasing WALWriteLock, instead of handing it to io_uring.
The default stays `wal_io_eager_issue = off`.

**Correctness** (server, `../results3/change1_*.csv`): 5 affected modes
(eager with io_uring / worker / direct IO / pipelining, plus default) x
regress, crash, chaos, reload, repl on release and debug+cassert builds,
plus power cut x crash, chaos, reload: **67 of 67 passed**, 330 crashes or
power cuts, 169,458 acknowledged commits checked, 0 lost.

**Performance** (gp3, 8 paired rounds x 10 s, 0 of 32 blocks dropped):

| vs stock | 8 | 16 | 32 | 64 |
|---|---:|---:|---:|---:|
| aio fdatasync if=16 (before) | -2.4% [1] | -5.5% [0] | **-13.8%** [0] | -6.6% [0] |
| aio fdatasync if=16 + change 1 | **-13.1%** [0] | -6.7% [0] | **-3.1%** [0] | -6.9% [1] |
| aio O_DSYNC direct IO if=16 (before) | -2.0% [1] | -4.3% [0] | -12.5% [0] | -0.4% [2] |
| aio O_DSYNC direct IO + change 1 | -1.9% [1] | -4.1% [0] | -12.2% [0] | -0.2% [2] |

Hand-off gap at 32 clients (`gap.txt`): stock 0.053 ms, aio 0.144 ms,
**aio + change 1 0.054 ms**: the diagnosed cause is fixed.

- **32 clients: -13.8% -> -3.1%.** The gap between fsyncs is back at stock's.
- **8 clients: -2.4% -> -13.1%.** The eager backend's own client now waits
  one extra fsync (~1.5 ms) per cycle. With 8 clients that is a large share
  of the work; with 32 it is small. A trade, not a win: stays off by default.
- **No effect with direct IO**: that path is bound by the same-page rule
  (a write starting mid-page waits for the previous one), not the hand-off.
- **Next:** make it adaptive (eager-inline only when the pending batch is
  large), and test the user's design: 4 kB WAL pages, batch within a page,
  pipeline full pages (`wal_blocksize=4`, direct IO,
  `wal_io_pipeline_threshold = 4kB`).

## Phase 4: 4 kB WAL pages (`04-4k-pages/`)

The user's design: batch commits within a page, pipeline complete pages.
Both builds with `-Dwal_blocksize=4` (`stock4`, `aio4`, code as of change 1),
golden cluster made with them, pgbench -N, 6 paired rounds x 10 s, 0 of 36
blocks dropped. AIO configs: io_uring, `wal_io_max_inflight = 16`.

| vs stock4, same mode | 1 | 4 | 8 | 16 | 32 | 64 |
|---|---:|---:|---:|---:|---:|---:|
| aio4 O_DSYNC direct IO, threshold 4kB | +0.0% [4] | -0.8% [1] | -1.9% [0] | -4.3% [0] | -7.8% [0] | -2.6% [3] |
| aio4 O_DSYNC direct IO, threshold 256kB | -0.2% [1] | -0.9% [1] | -1.8% [0] | -4.3% [0] | -7.9% [0] | -2.1% [1] |
| aio4 fdatasync, threshold 4kB | -0.5% [2] | -1.1% [0] | -2.6% [0] | -5.2% [0] | -8.8% [3] | -15.0% [0] |

Stock4 TPS (fdatasync): 848 / 2,022 / 3,802 / 6,945 / 12,207 / 18,216.

- **Threshold 4kB and 256kB give the same result, to 0.5%.** So the
  4kB setting never produces a second write in flight: as predicted, almost
  every write ends mid-page, and the next write starts in that page and has
  to wait for it. The pipeline is serialized by the partial last page, not
  by the threshold. This is what change 2 addresses.
- AIO is at parity at 1-4 clients and loses 2-8% at 8-32, the same shape
  as with 8 kB pages (phase 1).
- Absolute TPS is not comparable with phase 1: this run's spread between
  rounds is much wider (32 clients: 8,017-16,349), i.e. the volume was
  noisier today. Only the paired ratios are used.

**Change 2 (next):** `wal_io_page_align`. While a write is in flight, a
new O_DSYNC write ends at the last complete page; the partial page waits
for the next write, so writes in flight never share a page.

## Change 2: page-aligned pipelining (`05-page-align/`)

**Change** (`wal_io_page_align`, default off, O_DSYNC scheme only): while a
write is in flight, a new write ends at the last complete WAL page; the
partially filled page waits for a later write, so writes in flight never
share a page. A backend whose record is in that page waits for the oldest
write and retries; with nothing in flight, everything is written.

**Correctness** (`../results3/change2_align_*.csv`): 80 of 80 passed
(release, debug+cassert, power cut), 396 crashes or power cuts, 208,165
acknowledged commits checked, 0 lost. The replication test saw up to 4
writes in flight (1-2 before): full pages really go out in parallel.

**Performance** (4 kB builds as phase 4, aio4 rebuilt with change 2;
6 paired rounds x 10 s, 0 of 36 blocks dropped). All: io_uring, O_DSYNC,
direct IO, `wal_io_max_inflight = 16`; vs stock4 O_DSYNC + direct IO:

| config | 1 | 4 | 8 | 16 | 32 | 64 |
|---|---:|---:|---:|---:|---:|---:|
| threshold 4kB (phase 4 best) | -0.2% [2] | -0.8% [0] | -2.1% [0] | -4.1% [0] | -7.2% [0] | -2.7% [2] |
| threshold 4kB + **page align** | -0.0% [3] | -0.7% [0] | -1.9% [0] | -4.3% [0] | -7.6% [0] | **+5.5% [6/6]** |
| threshold 0 + page align | -0.1% [1] | -0.6% [0] | -1.9% [0] | -4.3% [0] | -11.4% [0] | +2.3% [3] |
| threshold 0 + page align + eager | -0.1% [3] | -0.8% [1] | -2.0% [0] | -7.2% [0] | -17.8% [0] | +0.6% [3] |

At 64 clients: 18,738 TPS vs stock4 17,793, and median latency 3.43 ms vs
3.65 ms. The phase-4 config in the same run: 16,597 TPS.

- **64 clients: -2.7% -> +5.5%, won all 6 rounds.** The first configuration
  to beat stock on small commits on this storage. With 64 clients a group
  commit carries more than a page, so complete pages go out while the
  previous write is in flight instead of waiting for it.
- **1-32 clients: no change.** The WAL waiting in each group is less than
  one page past the in-flight write, so there is no complete page to
  pipeline and the behaviour is the same as before (batching).
- **Threshold 0 is worse** (32 clients -11.4%): every single full page
  becomes its own trip to storage, which costs the batch. Keep 4kB.
- **Eager issue hurts** here, as in change 1 at low concurrency.
- Recommended setting for many clients: 4 kB pages, direct IO,
  `wal_io_pipeline_threshold = 4kB`, `wal_io_page_align = on`.

## Phase 6: large transactions with 4 kB pages and change 2 (`06-big-4k-align/`)

`big.sql` (500-row insert into one shared table, ~150 kB of WAL per commit),
4 kB builds, 6 paired rounds x 10 s, 0 of 24 blocks dropped.

| vs stock4, same mode | 1 | 4 | 16 | 32 |
|---|---:|---:|---:|---:|
| aio4 fdatasync, no batching | -2.8% [2] | -3.8% [1] | **+11.6% [5/6]** | -3.6% [1] |
| aio4 O_DSYNC direct IO, threshold 4kB | -1.4% [1] | +3.7% [4] | +2.8% [4] | -2.7% [0] |
| aio4 O_DSYNC direct IO, threshold 4kB + page align | -1.5% [2] | +4.5% [4] | +1.8% [3] | -5.0% [1] |

Stock4 TPS (fdatasync): 320 / 562 / 800 / 1,033 (O_DSYNC + direct IO:
333 / 628 / 802 / 1,079), i.e. at most ~160 MB/s of WAL.

- **fdatasync without batching, 16 clients: +11.6%, 5 of 6 rounds**; it
  confirms phase 2 (+6.2% at 16 with 8 kB pages).
- O_DSYNC + direct IO wins small majorities at 4-16 clients (+2-5%) and
  loses at 32.
- **Page align makes no difference for large commits**, as expected: a
  150 kB write spans ~37 pages, and holding back one partial page per write
  changes little. Its benefit is for many small commits (phase 5).
- TPS grows only from 800 to 1,033 between 16 and 32 clients: the shared
  table's extension lock (`Lock:extend`, phase 2) still limits the
  workload, not WAL. Phase 7 removes it.

## Phase 7: large transactions, one table per client (`07-bigpc-4k-align/`)

`bigpc.sql`: the same 500-row insert, but each client into its own table
(`big_<client_id>`), so there is no shared extension lock. 4 kB builds,
6 paired rounds x 10 s, 1 of 30 blocks dropped (64 clients, round 2).

| vs stock4, same mode | 1 | 4 | 16 | 32 | 64 |
|---|---:|---:|---:|---:|---:|
| aio4 fdatasync, no batching | +1.0% [4] | +5.2% [4] | -8.8% [2] | +4.6% [4] | +11.3% [4/5] |
| aio4 O_DSYNC direct IO, threshold 4kB | -0.4% [3] | +0.6% [3] | +4.6% [3] | -3.9% [1] | -7.8% [2/5] |
| aio4 O_DSYNC direct IO, threshold 4kB + page align | +1.5% [3] | +0.2% [3] | -11.1% [2] | -1.8% [3] | +5.7% [3/5] |

- **Inconclusive.** The spread between rounds is very wide (stock4
  O_DSYNC at 16 clients: 562-1,148 TPS), the canary had to wait for the
  device 4 times (up to 8.7 ms per write instead of ~1 ms), and most cells
  are won in only 2-4 of 6 rounds. The signs flip between neighbouring
  client counts, which is noise, not behaviour.
- Removing the shared table did **not** make the workload scale: about
  1,100-1,200 TPS at most = ~180 MB/s of WAL, still below the volume's
  300 MiB/s. With 150 kB per commit the volume also has to absorb the
  heap writes, so the run seems to hit the volume's IOPS/throughput budget
  (and its throttling) rather than the WAL path.
- The one consistent signal across phases 2, 6 and 7: **AIO fdatasync
  without batching does well with large commits at higher concurrency**
  (+6.2%, +11.6%, +11.3% at its best client count, winning 4-5 rounds).
- A conclusive large-commit test needs storage with more headroom than
  this gp3 volume (io2, or a larger gp3 provisioning), plus longer runs.

## Summary (2026-11-25)

On EBS gp3 (network storage, ~1.9 ms per durable write, 11x more IOPS at
queue depth 16 than at 1):

- **Small commits, 8 kB pages:** AIO is at parity at 1-8 clients and loses
  4-13% at 16-32. Cause diagnosed (phase 2b): the hand-off gap between
  fsyncs; change 1 fixes it at 32 clients (-13.8% -> -3.1%) but costs 8
  clients, so it stays off by default.
- **Small commits, 4 kB pages + change 2 (`wal_io_page_align`):** **+5.5%
  at 64 clients, 6 of 6 rounds**, the first small-commit win on this
  storage; neutral at 1-32. Phase 4 showed why it was needed: without it,
  every write ended mid-page and the next one had to wait for it, so a
  4kB threshold behaved exactly like 256kB.
- **Large commits:** AIO fdatasync without batching wins at higher
  concurrency (+6% to +12%, phases 2, 6, 7); change 2 doesn't matter there.
  The workload is limited by the table extension lock (shared table) or
  the volume's budget (per-client tables), so the ceiling of the WAL-side
  gain is not measured.
- **Correctness:** every change passed the full suite including power
  cuts (210 + 67 + 80 runs, 0 acknowledged commits lost); one durability
  bug was found and fixed on the way (`5a78e355b7`).
- **Recommended settings:** small commits, many clients: 4 kB WAL pages,
  O_DSYNC + direct IO, `wal_io_max_inflight = 16`,
  `wal_io_pipeline_threshold = 4kB`, `wal_io_page_align = on`. Large
  commits: fdatasync, `wal_io_max_inflight = 16`,
  `wal_io_pipeline_threshold = 0`.

The VM was stopped (not terminated) after phase 7; its volume is kept.

## Phase 8a: where a large commit's time goes (`08a-large-commit-profile/`)

Goal: optimize large commits (WAL of one commit spans many pages). Two
measurements, stock4 only, no code change.

**1. fio, 160 kB of durable writes** (O_DIRECT + O_DSYNC, io_uring, 20 s
each), split into n parallel writes:

| 160 kB written as | IOPS | latency per IO | **time per 160 kB** |
|---|---:|---:|---:|
| 1 x 160 kB (what a large commit does now) | 311 | 3.20 ms | **3.22 ms** |
| 4 x 40 kB in parallel | 2,224 | 1.79 ms | 1.80 ms |
| **8 x 20 kB in parallel** | 5,909 | 1.35 ms | **1.35 ms** |
| 20 x 8 kB in parallel | 6,703 | 3.93 ms | 2.98 ms (IOPS cap) |

- A single large write is slow on gp3 (3.2 ms vs ~1.9 ms for a small one):
  its bytes are transferred serially. The same bytes as **8 parallel
  writes finish 2.4x faster**. Splitting further hits the volume's IOPS
  cap (6,400) and gets slow again.
- Today one flush is always **one** IO, however many pages it covers (up
  to 32 MB, `XLOG_AIO_MAX_PAGES`); `wal_io_max_inflight` only lets
  *different* flushes overlap.

**2. Synchronous vs asynchronous commit** (`bigpc`, 3 paired rounds x 10 s):

| TPS | 1 client | 4 | 16 |
|---|---:|---:|---:|
| O_DSYNC + direct IO, `synchronous_commit = on` | 313 | 489 | 525 |
| same, `synchronous_commit = off` | 779 | 738 | 780 |
| fdatasync, on | 293 | 347 | 524 |
| fdatasync, off | 742 | 876 | 793 |

- At 1 client a large transaction takes 3.2 ms, of which **~1.9 ms (60%)
  is waiting for the commit flush**; without that wait it would take 1.3 ms.
- So the upper bound of what faster WAL writing can give is about 2.5x at
  1 client and about +50% at 16 clients (async reaches ~780-880 TPS, the
  workload's ceiling on this VM).

**Next: change 3, split large writes.** Issue a large flush as several
parallel writes of whole pages (e.g. up to 8, at least some minimum size)
instead of one IO. They share no page, so they don't wait for each other,
and Flush still only advances over the contiguous completed prefix.

## Change 3: split large writes (`08b-split-writes/`)

**Change** (`wal_io_split_size`, default 0 = off, O_DSYNC scheme only): a
flush of at least twice that size is issued as several writes of whole
pages, at most as many as `wal_io_max_inflight` has free slots, instead of
one IO. Only the first chunk can start mid-page and only the last can end
mid-page, so the chunks share no page and run in parallel; Flush still
advances only over the contiguous completed prefix.

**Correctness** (`../results3/change3_split_*.csv`): 93 of 93 passed
(release, debug+cassert, power cut), 462 crashes or power cuts, 238,889
acknowledged commits checked, 0 lost; 6-9 writes in flight with splitting.

**Performance** (`bigpc`: 500-row insert, one table per client, ~150 kB of
WAL per commit; 4 kB builds; 6 paired rounds x 10 s, 1 of 24 blocks
dropped). All AIO O_DSYNC configs: io_uring, direct IO, inflight 16,
threshold 4kB, page align:

| vs stock4, same mode | 1 | 4 | 16 | 32 |
|---|---:|---:|---:|---:|
| AIO O_DSYNC, no split | +0.3% [3] | +2.5% [5] | +0.3% [3/5] | +0.7% [3] |
| **+ split 16 kB** | **+56.2% [6/6]** | **+44.6% [5/6]** | -4.4% [0/5] | -9.6% [1] |
| **+ split 32 kB** | **+42.3% [6/6]** | **+49.4% [5/6]** | +0.4% [3/5] | -2.2% [3] |
| AIO fdatasync, no batching (vs stock4 fdatasync) | -0.6% [2] | -3.8% [3] | -2.1% [2/5] | +0.5% [3] |

TPS at 1 client: stock 317 -> **500** (split 16 kB); commit latency
3.16 ms -> **2.00 ms**. At 4 clients: 602 -> 851 (split 32 kB).

- **The largest AIO gain so far: +56% at 1 client, +45-49% at 4, winning
  all or 5 of 6 rounds.** It matches fio (one 160 kB write 3.2 ms, 8
  parallel ones 1.35 ms) and phase 8a (60% of a large commit is the commit
  write).
- **At 16-32 clients splitting doesn't help and 16 kB hurts (-10% at 32).**
  There, writes of different commits already overlap, and splitting
  multiplies the number of IOs. Likely cause (not measured): the volume's
  IOPS cap; at ~900 commits/s, 16 kB chunks mean ~9 IOs per commit, over
  6,400 IOPS. 32 kB chunks (~5 per commit) stay about neutral.
- The fdatasync result (+11% in phase 7) did not repeat: noise in phase 7.

**Next (change 3b):** split only while nothing else is in flight, i.e.
when the device would otherwise serve this one write alone. That should
keep the 1-4 client gain and leave 16-32 clients as without splitting.

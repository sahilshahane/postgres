# Asynchronous WAL Writes in PostgreSQL on Cloud Block Storage

CS631 project report, part 2: optimization and evaluation on AWS EBS gp3
(November 2026). Part 1 (`../report.pdf`) covers the design, the first
implementation and the NVMe measurements. This report covers what came
after: the move to network storage, three optimizations, the correctness
testing of each, and benchmarks with PostgreSQL's own workloads and with
standard OLTP benchmarks (TPC-C, YCSB, sysbench, bulk load).

Detailed per-phase log with every table: `results-aws/FINDINGS.md`.
Correctness results: `results3/README.md`.

---

## 1. Summary

- **What was built.** `wal_io_method = aio` lets PostgreSQL issue WAL writes
  through its AIO subsystem (io_uring or IO workers) instead of the blocking
  `pwrite()` + `fdatasync()` under `WALWriteLock`. Several WAL writes can be
  in flight at once; a range tracker advances the durable `Flush` pointer only
  over the contiguous prefix of completed writes.
- **Storage.** On local NVMe (part 1) AIO could at best match stock: that
  device executes durable writes one at a time. AWS EBS gp3 is network
  storage that does overlap them: 534 durable 8 kB writes/s at queue depth
  1, 6,080/s at queue depth 16 (11x). It is the kind of storage AIO WAL is
  meant for.
- **Three optimizations**, each a new setting, default off:
  1. *Inline eager issue* (`wal_io_eager_issue` + `wal_io_inline_fsync`):
     removes a 0.1 ms hand-off gap between flushes (32 clients: -13.8% ->
     -3.1%), but costs 8 clients; off by default.
  2. *Page-aligned pipelining* (`wal_io_page_align`): writes in flight never
     share a WAL page, so full pages can go out while a write is in flight.
     First small-commit win: **+5.5% at 64 clients** (later +11.8% with change 3
     settings).
  3. *Split writes* (`wal_io_split_size`): a large flush is issued as several
     parallel whole-page writes. **Large commits: +56% at 1 client, +84-87% at 4,
     +8-20% at 16-32**, winning every round.
- **Correctness.** Every change passed the full suite (regression, crash,
  chaos reloads, replication, power cuts) on release and assert builds:
  **450 test runs, 2,280 crashes or power cuts, 1.16 million acknowledged
  commits verified, 0 lost.** One durability bug (after a `wal_sync_method` reload)
  was found by the tests and fixed.
- **The honest comparison.** Tuning stock with one kernel setting
  (`max_sectors_kb = 32` on the WAL device) gives stock the same large-commit
  gain (+56% / +90% / +38% / +27%). Change 3's gain comes from splitting large
  writes into parallel requests, which the block layer can also do. What
  stock cannot do is overlap *small* commits: there AIO keeps a real gain
  (+11.8% pgbench at 64 clients, +7% YCSB-A at 64 clients).
- **Open problem.** No single `wal_io_pipeline_threshold` is best for both:
  large commits want 512 kB (batch several commits per flush), small commits
  want 4 kB (pipeline single pages). With 512 kB, YCSB-A loses 18% at 64
  clients. An adaptive threshold is the next step.
- **Method lessons.** Three harness flaws were found and fixed along the way:
  cross-run interference from leftover dirty data (made all earlier 16-32
  client results unreliable), cold page caches for read-heavy benchmarks
  (made TPC-C bimodal), and canary-only device gating. Section 6.

---

## 2. Background: why WAL writing is a bottleneck

Every PostgreSQL commit waits until its commit record is durable
(`XLogFlush`). Stock PostgreSQL does this synchronously: one backend at a
time takes `WALWriteLock`, writes all WAL inserted so far (`pwrite`), makes
it durable (`fdatasync`, or `O_DSYNC` writes), and releases the lock.
Everyone whose record was included returns without I/O: that is **group
commit**.

Two consequences:

1. **One flush in flight.** Storage that can run many durable writes in
   parallel sees one at a time.
2. **Late arrivals pay double.** A commit that arrives while a flush is in
   progress waits for it and then for a full flush of its own.

On local NVMe the flush is fast (tens of microseconds) and the device
serializes flushes anyway. On cloud block storage a durable write takes
about 1.9 ms (gp3, measured) and the device can overlap many: there, the
synchronous design leaves most of the device's parallelism unused.

---

## 3. Design and implementation

All changes are in `src/backend/access/transam/xlog.c` (plus GUC
definitions, docs and an fsync operation in the AIO subsystem).

### 3.1 Issue and completion

`XLogFlushAio()` replaces the synchronous path when `wal_io_method = aio`:

- **Issue.** A backend that needs WAL durable takes `WALWriteLock` only to
  *start* writes (`XLogAioIssue`): it collects contiguous WAL pages into one
  IO, up to its target, the end of the WAL buffer ring, a segment end or
  32 MB, and submits it through `pgaio_*`. Then it releases the lock.
- **Completion.** Each write's completion marks its range done in a small
  shared ring (the in-flight tracker). `Flush` advances to the end of the
  longest run of completed writes starting at the current `Flush`, never
  further. Waiters sleep on a condition variable until `Flush` passes their
  LSN.
- **Bound.** `wal_io_max_inflight` (1-64) caps the writes in flight, so WAL
  cannot exhaust the AIO handles that data I/O needs.

### 3.2 Two durability schemes

| `wal_sync_method` | scheme | what is asynchronous |
|---|---|---|
| `open_datasync` / `open_sync` | **O_DSYNC**: each write is durable when it completes (with direct IO, one FUA write) | the writes |
| `fdatasync` / `fsync` (Linux default) | **fsync**: writes go to the page cache synchronously, then one AIO fsync covers them | the fsync |

### 3.3 Dependencies between writes

Out-of-order completion is safe because of the contiguous-prefix rule
above. The other dependency is between writes that touch the same bytes:

- **A write never overlaps the bytes of a write in flight.** Two writes of
  the same page in flight could complete in either order, and the older
  content could win on disk.
- **Direct IO writes whole pages**, so a write that starts in the middle of
  the last page (the usual case: the previous flush ended mid-page) must
  wait for the write that covers that page.
- **Zeroing.** The first write to reach a page also writes zeros for the
  rest of the page, so stale bytes from a recycled segment are never read
  as WAL after a crash. Later writes of that page wait for the zeroing write
  (`aioZeroedUpTo`, `XLogAioWaitForZeroingWrite`), and that waiting happens
  before `WALWriteLock` is taken (or with release and retry).
- **Pipeline threshold** (`wal_io_pipeline_threshold`, default 256 kB):
  while a write is in flight, a new one is started only if at least this
  much unwritten WAL is waiting; otherwise the flush waits and joins the
  next write. This keeps group commit: without it, every small commit
  becomes its own trip to storage (measured: -34% to -74%).

### 3.4 Settings

| setting | default | meaning |
|---|---|---|
| `wal_io_method` | `sync` | `aio` enables the new path (restart) |
| `wal_io_max_inflight` | 1 | max WAL writes in flight |
| `wal_io_pipeline_threshold` | 256 kB | min unwritten WAL to start a write while one is in flight |
| `wal_io_inline_fsync` | on | the backend that needs an fsync / last O_DSYNC write runs it itself after releasing the lock |
| `wal_io_eager_issue` | off | change 1 (section 4.1) |
| `wal_io_page_align` | off | change 2 (section 4.2) |
| `wal_io_split_size` | 0 (off) | change 3 (section 4.3) |

---

## 4. Optimizations

Each change was motivated by a measurement, tested for correctness, then
benchmarked against stock in the same run.

### 4.1 Change 1: inline eager issue

**Problem** (phase 2b). At 32 clients AIO lost 13% to stock. Profiling ruled
out extra wake-ups, smaller groups and slower fsyncs. The cause was the
**gap between one fsync ending and the next starting: 0.143 ms vs 0.041 ms
for stock**. After an fsync, all ~31 waiters woke and raced through the
issue path before one of them started the next write; in stock the next
leader is already queued on the lock.

**Change.** With `wal_io_eager_issue = on`, the backend that sees its WAL
durable starts the next write itself, inline, without the io_uring
hand-off.

**Result.** Gap back to 0.054 ms; 32 clients **-13.8% -> -3.1%**. But 8
clients went -2.4% -> -13.1% (that backend's own client now waits one extra
flush). A trade, not a win: off by default.

### 4.2 Change 2: page-aligned pipelining

**Problem** (phase 4). With 4 kB WAL pages and a 4 kB threshold (the idea:
batch within a page, pipeline complete pages), results were identical to a
256 kB threshold. Almost every write ends mid-page, so the next write
starts in that page and must wait (section 3.3): no second write was ever
in flight.

**Change** (`wal_io_page_align`, O_DSYNC scheme). While a write is in
flight, a new write ends at the last complete page; the partial page waits
for a later write. Writes in flight then never share a page. With nothing
in flight, everything is written as before.

**Result** (pgbench -N, 4 kB pages, direct IO). 64 clients: **-2.7% ->
+5.5%, 6 of 6 rounds** (18,738 vs 17,793 TPS). Neutral at 1-32 clients: a
group there carries less than one page past the write in flight, so there
is no full page to pipeline. The replication test saw up to 4 writes in
flight (1-2 before).

### 4.3 Change 3: split large writes

**Problem** (phase 8a). One flush is always one IO, however many pages it
covers. On gp3, fio shows a single 160 kB durable write takes **3.22 ms**,
but 8 parallel 20 kB writes finish in **1.35 ms (2.4x faster)**. And a
large commit (bigpc: 500-row insert, ~150 kB WAL) spends ~60% of its time
waiting for that one write (synchronous vs asynchronous commit: 313 vs 779
TPS at 1 client).

**Change** (`wal_io_split_size`, O_DSYNC scheme). A flush of at least twice
the split size is issued as several whole-page writes, at most as many as
`wal_io_max_inflight` has free slots. Only the first chunk can start
mid-page and only the last can end mid-page, so the chunks share no page
and run in parallel. `Flush` still advances only over the contiguous
completed prefix, so durability is unchanged.

**Result** (bigpc, best settings from a 7-config screening: threshold
512 kB, split 16 kB, 8 in flight; phase 9 run):

| vs stock | 1 client | 4 | 16 | 32 |
|---|---:|---:|---:|---:|
| AIO + change 3 | **+59.0%** [6/6] | **+83.8%** [6/6] | **+19.8%** [6/6] | **+11.7%** [6/6] |

TPS 329 -> 521 at 1 client (commit latency ~3.1 ms -> ~2.0 ms), 714 ->
1,311 at 4. The threshold matters at high concurrency: a 512 kB threshold
batches several commits into one flush (fewer IOs), the split keeps that
flush parallel.

---

## 5. Correctness

**Suite** (`tests/`, `run_all.py`), run for every change on release and
debug + cassert builds, for every affected configuration (`tests/modes.txt`):

| test | what it does |
|---|---|
| `regress` | PostgreSQL regression + isolation suites (373 tests) |
| `crash` | SIGKILL of every process / of the postmaster, alternating, during load; after recovery every acknowledged commit must be present |
| `chaos` | crashes while `wal_io_*` settings and `wal_sync_method` are reloaded at random |
| `reload` | `wal_sync_method` switched between the two durability schemes at runtime |
| `repl` | streaming standby + WAL archive + promotion |
| power cut | dm-flakey drops every write from the cut on and the page cache is lost; negative control: `fsync = off` fails at the first cut |

After every recovery, `amcheck` (B-tree and heap) must be clean and no log
may contain a PANIC or an assertion failure.

| code | runs passed | crashes / power cuts | acknowledged commits verified | lost |
|---|---:|---:|---:|---:|
| base (before changes) | 210 / 210 | 1,092 | 546,026 | 0 |
| change 1 | 67 / 67 | 330 | 169,458 | 0 |
| change 2 | 80 / 80 | 396 | 208,165 | 0 |
| change 3 | 93 / 93 | 462 | 238,889 | 0 |

**Bug found and fixed** (`5a78e355b7`): in the fsync scheme, after
`wal_sync_method` was reloaded to an O_DSYNC method, WAL files opened before
the reload lacked O_DSYNC, so acknowledged commits were not durable. Found
by `chaos` under power cut, then reproduced deterministically by `reload`.

---

## 6. Experimental method

### 6.1 Platform

| | |
|---|---|
| VM | AWS `c6i.2xlarge` (8 vCPU Xeon 8375C, 16 GB), Sydney, Ubuntu 24.04 |
| storage | EBS gp3, 100 GB, 6,400 IOPS, 300 MiB/s, XFS (reflink), WAL and data on the same volume |
| builds | release (`-O3`, liburing); 4 kB WAL pages (`-Dwal_blocksize=4`) from phase 4 on; `stock4` = upstream base, `aio4` = this work |
| common settings | `shared_buffers = 512MB`, `wal_buffers = 64MB`, `max_wal_size = 8GB`, `full_page_writes = off`, `autovacuum = off`; durability: `wal_sync_method = open_datasync`, `debug_io_direct = wal` for stock and AIO |

### 6.2 Harness (`bench/bench.sh`, `bench/analyze.py`)

- **Paired, interleaved runs.** All configurations' servers run at the same
  time on their own data directories (reflink copies of one golden
  directory). For each round and client count, each configuration gets one
  run, seconds apart, in an order rotated every round. So drift in the
  network storage's speed affects all configurations alike.
- **Statistic.** For each round, each configuration's throughput is divided
  by the stock baseline's from the same round; the table value is the
  **median of these ratios**, with `[rounds won / rounds]`. A consistent
  [6/6] or [0/6] is a real effect; 2-4 of 6 is noise.
- **Device gate.** Before each block of runs, a canary (200 x 8 kB O_DSYNC
  writes) must be below a latency limit, or the harness waits.
- **Quiesce (`QUIESCE=1`).** After each run: `CHECKPOINT` that server and
  `sync` (section 6.3).
- **Prewarm** (standard workloads). Before measuring: drop the page cache,
  then read each configuration's copy of the workload's tables and indexes
  into it (section 6.3).
- **Kernel settings per configuration.** `sys.max_sectors_kb = N` in a
  configuration line sets the device's maximum request size before each of
  its runs, restored afterwards.

### 6.3 Harness flaws found and fixed

1. **Cross-run interference** (phase 8e). At 32 clients, throughput
   alternated ~520 / ~720 TPS by *position in the run order*, whatever the
   configuration. A heavy run left 300-500 MB of dirty data that the kernel
   wrote out during the next server's run. Fix: quiesce after each run.
   Afterwards, 32-client throughput was 1,170-1,430 TPS in every run, and AIO
   won 63 of 63 screening cells. **All 16-32 client results before phase 8f
   are unreliable** (section 7 uses only quiesced runs for those).
2. **Cold page caches** (phase 10). Each configuration's TPC-C copy (1.6 GB)
   was read from the device during the runs; reads competed with WAL writes
   for IOPS and TPC-C results were bimodal (~1,020 or ~1,350 requests/s,
   even for configurations that cannot differ). Fix: prewarm; afterwards the
   device does 0 reads/s during runs.
3. **Small-sample screening.** 3-round screenings were used only to choose
   configurations; final numbers come from 6-round runs.

---

## 7. Results

### 7.1 Storage

fio, 8 kB O_DSYNC writes: 534 IOPS at queue depth 1 (1.87 ms), **6,080 at
queue depth 16** (2.63 ms, the IOPS cap). 160 kB durable: 1 write 3.22 ms;
4 x 40 kB 1.80 ms; 8 x 20 kB **1.35 ms**; 20 x 8 kB 2.98 ms (IOPS cap).

Two facts drive everything below: **parallel durable writes are almost
free on gp3, up to the IOPS cap**, and **a single large write is slow**.

### 7.2 Small commits (pgbench -N, ~0.5 kB WAL per commit)

| vs stock4 | 1 | 4 | 8 | 16 | 32 | 64 |
|---|---:|---:|---:|---:|---:|---:|
| AIO, threshold 4kB, page align (phase 5) | 0.0% | -0.7% | -1.9% | -4.3% | -7.6% | **+5.5% [6/6]** |
| AIO, threshold 4kB, page align, split 16kB, inflight 8 (phase 8d) | | | | -3.8% [0/6] | | **+11.8% [6/6]** |
| AIO, threshold 256kB, split 16kB, inflight 8 (phase 8d) | | | | -3.7% | | -3.7% [1/6] |

(16-32 client cells were measured before the quiesce fix; they are being
re-measured.)

- Small commits gain only when a group commit carries **more than a page**
  past the write in flight (64 clients). Below that, stock's group commit is
  already near the device's limit: stock commit latency stays at 1.9-2.0 ms
  from 4 to 32 clients while TPS scales linearly.
- Pipelining smaller units (threshold 0) is worse: each extra write costs a
  full device round trip.

### 7.3 Large commits (bigpc, ~150 kB WAL per commit) and tuned stock

Phase 9, 6 rounds x 10 s, quiesced, 0 blocks dropped:

| vs stock4 default | 1 | 4 | 16 | 32 |
|---|---:|---:|---:|---:|
| stock + `wal_writer_delay = 1ms` | +1.0% | -0.4% | 0.0% | -0.9% |
| stock + `commit_delay = 100` | +1.1% | +0.2% | +0.5% | +0.5% |
| **stock + `max_sectors_kb = 32`** | **+56.3% [6/6]** | **+90.2% [6/6]** | **+38.0% [6/6]** | **+27.3% [6/6]** |
| stock + `max_sectors_kb = 16` | +65.2% [6/6] | -3.7% | -41.5% [0/6] | -46.7% [0/6] |
| **AIO: T 512k, S 16k, I 8** | **+59.0% [6/6]** | **+83.8% [6/6]** | **+19.8% [6/6]** | **+11.7% [6/6]** |

- `max_sectors_kb` caps the request size the kernel sends the device;
  larger IOs are split into parallel requests. At 32 kB it does to stock's
  WAL write what change 3 does in PostgreSQL: equal at 1-4 clients, and
  better at 16-32.
- At 16 kB it splits *every* IO on the volume (data files too) and hits the
  IOPS cap from 4 clients on. Change 3 avoids that by splitting only WAL,
  and only flushes of at least twice the split size.
- `wal_writer_delay` and `commit_delay`, the usual WAL tuning knobs, do
  nothing here.

### 7.4 Standard benchmarks (phase 10)

Configurations: stock4 default (baseline), stock + `max_sectors_kb = 32`,
AIO large-commit best (T 512k, S 16k, I 8), AIO small-commit best (T 4k,
S 16k, I 8), AIO large-commit best + `max_sectors_kb = 32`. 3 rounds,
quiesced, prewarmed. 1 / 4 / 16 / 64 clients (bulk COPY: 1 / 4 / 16).

| benchmark | tool | workload |
|---|---|---|
| YCSB workload A | BenchBase | 1M records, 50% read / 50% update, one row per transaction |
| TPC-C | BenchBase | 16 warehouses, standard mix, serializable |
| sysbench `oltp_write_only` | sysbench 1.0.20 | 8 tables x 100k rows; 2 updates + delete + insert per transaction |
| sysbench `oltp_insert` | sysbench 1.0.20 | single-row inserts |
| bulk COPY | pgbench script | `COPY` of 50,000 rows (~13 MB) per transaction |

**YCSB-A** (requests/s vs stock default; stock: 1,420 / 2,570 / 7,730 /
22,360):

| config | 1 | 4 | 16 | 64 |
|---|---:|---:|---:|---:|
| AIO T 4k (small-commit best) | +0.6% | -2.9% | **+5.6% [3/3]** | **+7.0% [3/3]** |
| AIO T 512k (large-commit best) | +1.2% | -1.3% | -2.4% | **-17.7% [0/3]** |
| AIO T 512k + `max_sectors_kb = 32` | +1.4% | -0.7% | -2.4% | -17.1% [0/3] |
| stock + `max_sectors_kb = 32` | +1.4% | +0.7% | -0.1% | +3.3% |

*TPC-C, sysbench and bulk COPY: running, filled in when phase 10 finishes.*

---

## 8. Discussion

**When does AIO WAL help?** Only when there is WAL that could be written
in parallel and the device can absorb it:

- *Large commits:* a single flush of many pages, split into parallel writes
  (change 3). Large gain, but the kernel can do the same split for stock.
- *Many small commits:* WAL that arrives while a write is in flight, more
  than a page of it (change 2). Smaller gain (+6% to +12% at 64 clients),
  and **stock cannot get it by tuning**: no stock setting lets a second
  WAL write start while one is in progress.
- *Few small commits:* nothing to overlap. AIO is at parity at 1 client and
  slightly behind at 4-16 (bookkeeping on the commit path).

**Why parallel writes are not always a gain.** Each extra write in flight
costs one IO against a fixed IOPS budget (6,400) and a full device round
trip of its own (~1.9 ms). Group commit already amortizes one round trip
over many commits. A second write helps only if it carries enough new WAL
to be worth its round trip; otherwise it delays the next group. This is
what the pipeline threshold controls, and why its best value depends on
commit size.

**The threshold conflict.** Large commits at high concurrency want a big
threshold (512 kB: batch several commits, then split); small commits want
4 kB (pipeline each full page). With the 512 kB setting, YCSB-A loses 18% at
64 clients; with 4 kB, large commits at 32 clients lose ~20% (phase 8d). A
rule that adapts (for example, a threshold derived from the recent flush
size, or from how many writes are in flight) should get both.

**AIO vs tuned stock at 16-32 clients** (large commits): AIO is capped at 8
writes in flight; the kernel split is not. Raising the cap is untested.

---

## 9. Limitations and threats to validity

- **One storage type.** gp3 only (plus NVMe in part 1). io2 or local NVMe
  with deep queues would change the IOPS-cap trade-offs.
- **WAL and data share one volume**, so data-file writes compete with WAL
  for IOPS, and `max_sectors_kb` affects both. A dedicated WAL volume is the
  common production setup and would favour both stock tuning and AIO.
- **Short runs** (10-15 s, 3-6 rounds). Long-run effects (checkpoints under
  load, WAL recycling) are suppressed by `max_wal_size = 8GB` and the
  quiesce step.
- `full_page_writes = off` in all benchmarks (it affects all configurations
  alike, but it changes the WAL volume per commit).
- Results before phase 8f at 16-32 clients were affected by cross-run
  interference (section 6.3).

---

## 10. Future work

1. **Adaptive pipeline threshold** to resolve the small/large conflict.
2. **Raise `wal_io_max_inflight`** (16, 32) for large commits and compare
   with tuned stock at 16-32 clients.
3. **Dedicated WAL volume**, and io2 / local NVMe for comparison.
4. Re-measure the small-commit 16-32 client cells with the quiesced harness.
5. Change 1 made adaptive: inline eager issue only when the pending batch is
   large.

---

## 11. Reproducing

| what | where |
|---|---|
| code | `src/backend/access/transam/xlog.c` (search `XLogFlushAio`, `XLogAioIssue`) |
| correctness suite | `tests/run_all.py`, modes in `tests/modes.txt` |
| benchmark harness | `bench/bench.sh` (usage in its header), `bench/analyze.py` |
| golden data | `bench/make_golden.sh` (pgbench + bigpc tables), `bench/make_golden_std.sh` (BenchBase TPC-C / YCSB, sysbench, bulk) |
| AWS VM | `bench/aws/aws_up.sh`, `aws_down.sh`, `aws_eice.sh` |
| per-phase scripts and configs | `bench/aws/phases/` |
| raw results | `results-aws/<phase>/` (`raw.csv`, `log.txt`, `analysis.txt`, `cfg.txt`) |

## Appendix: phase index

| phase | directory | question |
|---|---|---|
| 0 | `00-setup` | does gp3 overlap durable writes? |
| 1, 1b | `01-main-gp3`, `01b-profile-32c` | pgbench -N, 1-64 clients; where backends wait |
| 2, 2b | `02-big-gp3-300MiBs`, `02b-diagnosis-32c` | large commits; why AIO loses at 32 clients |
| change 1 | `03-change1-eager-inline` | inline eager issue |
| 4 | `04-4k-pages` | 4 kB WAL pages |
| change 2 | `05-page-align` | page-aligned pipelining |
| 6, 7 | `06-big-4k-align`, `07-bigpc-4k-align` | large commits with 4 kB pages |
| 8a | `08a-large-commit-profile` | where a large commit's time goes |
| change 3 | `08b-split-writes`, `08c-split-inflight-cap` | split large writes |
| 8d-8f | `08d-threshold-256k`, `08e-screening`, `08f-screening-quiesce` | threshold / split / in-flight; harness fix |
| 9 | `09-tuned-stock` | can tuned stock match AIO? |
| 10 | `10-standard` | standard benchmarks |

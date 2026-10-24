# AIO-based WAL Writes in PostgreSQL: Today vs. Proposed

Oct 13, 2026 · @Placement team

## Summary

Today every PostgreSQL commit waits for a synchronous `pwrite()` followed by `fdatasync()`, issued one batch at a time under a single lock. This project would make WAL writes asynchronous through the PG 18 AIO subsystem, while keeping the same durability guarantee.

- **What changes:** WAL is written early and several writes can be in flight at once. On suitable hardware, one `O_DIRECT + O_DSYNC` (FUA) write replaces the write-then-flush pair.
- **What does not change:** a commit is still acknowledged only after its WAL is durable, and a data page is still never written before its WAL.
- **The core rule:** the "durable up to" pointer only advances to the end of the *contiguous* run of finished writes.
- **Status in PostgreSQL:** not in committed `master` as of 2026-10-12. Andres Freund (author of AIO) built a prototype, removed it from the upstream AIO patchset in 2024, and calls it "a pretty large project" still ahead.
- **Status in research:** pipelined or async log flushing is well studied (Aether, Silo, LeanStore). What is new here is the PostgreSQL-specific engineering and the measurements.

Code references in this doc point to the `REL_18_STABLE` tree.

## Background: WAL in one page

WAL is one sequential log. Every change is recorded there before the data page it describes reaches disk. A position in the log is an **LSN** (a byte offset). Records first go into an in-memory ring of WAL buffers (`wal_buffers`), then to 16 MB segment files in `pg_wal/`.

Shared memory tracks three positions (`XLogwrtResult`, `xlog.c:328-329`). They always satisfy `Flush ≤ Write ≤ Insert`:

| Pointer | Meaning | Who advances it |
| --- | --- | --- |
| Insert | WAL reserved and copied into WAL buffers | Any backend, in `XLogInsertRecord()` (`xlog.c:748`) |
| Write | WAL handed to the kernel with `pwrite()` | Whoever holds `WALWriteLock`, in `XLogWrite()` (`xlog.c:2304`) |
| Flush | WAL known to be on stable storage | Same, after `issue_xlog_fsync()` (`xlog.c:8746`) |

Two rules keep the database correct. AIO must preserve both:

1. **Commit durability.** `COMMIT` returns to the client only once `Flush ≥` the commit record's end LSN. This happens in `RecordTransactionCommit()` → `XLogFlush(XactLastRecEnd)` (`xact.c:1502`).
2. **Write-ahead.** A dirty data page with LSN *L* may be written to disk only once `Flush ≥ L`. The buffer manager calls `XLogFlush(page_lsn)` before every page write.

Crash recovery replays WAL from the last checkpoint and stops at the first record whose CRC fails. Anything after a gap or a torn page is therefore lost, even if it reached disk.

## How a commit writes WAL today

One backend at a time holds `WALWriteLock` and does both the write and the flush itself, synchronously. Everyone else waits on that lock.

&#91;embedded content: current commit path · xlog.c XLogFlush → XLogWrite\]

The lock logic is in `XLogFlush()` (`xlog.c:2780`, lock at `:2854`). The writes are the `pg_pwrite()` loop in `XLogWrite()` (`:2434`), and the flush is `issue_xlog_fsync()` at the end of `XLogWrite()`. The WAL writer process does the same work in the background every `wal_writer_delay` (200 ms) via `XLogBackgroundFlush()` (`:2968`). It uses the same lock and the same blocking calls; it only helps when commits are not waiting.

**Worked example (three clients commit at once):**

1. T1, T2 and T3 insert their commit records at LSNs 1000, 1100 and 1200. The bytes are now in WAL buffers only.
2. T1 reaches `XLogFlush(1000)` first and gets `WALWriteLock`. T2 and T3 arrive a moment later and sleep on the lock.
3. T1 calls `WaitXLogInsertionsToFinish()`, which reports everything up to 1300 is copied. T1 therefore writes up to 1300, not just 1000. That is group commit.
4. T1 blocks in `pwrite()` and then in `fdatasync()`. It sets `Flush = 1300` and releases the lock.
5. T2 and T3 wake, see `Flush (1300) ≥` their LSN, and return without doing any I/O.
6. Meanwhile T4 inserted at 1350 during T1's fsync. It cannot join T1's flush; it must wait for the lock and start a **second** full write+fsync round.

## Where time is lost today

The synchronous path loses time in three places: the device idles while the leader runs `pwrite()`, a commit that arrives mid-fsync waits a full extra round, and only one flush is ever in flight.

&#91;embedded content: schematic timeline · today vs. AIO\]

- **Serialized flushes.** `WALWriteLock` allows one write+fsync at a time. Storage that could run many requests in parallel (NVMe has deep queues) sees only one.
- **Late arrivals pay double.** T4 waits for T1's fsync to finish, then for its own whole round.
- **Two round trips per flush.** Buffered I/O needs the `pwrite()` (copy to the page cache) and then `fdatasync()` (push to device + cache flush). `O_DIRECT + O_DSYNC` can make it one FUA write.
- **Writes start late.** WAL is usually written only when someone needs it flushed. The WAL writer's 200 ms cadence and `commit_delay` (`xlog.c:2881`) trade latency for batching rather than overlapping work.

These costs grow with device latency. On cloud block storage, where a flush can take milliseconds, the commit path is dominated by waiting.

## Proposed flow with AIO

The project splits today's single blocking call into an **issue side** and a **completion side**. Two new pieces sit between them: a write issuer and a range tracker.

&#91;embedded content: proposed AIO WAL path · write side and completion side\]

**What each new piece does:**

- **Write issuer.** As soon as a WAL range is fully inserted (`WaitXLogInsertionsToFinish()` says so), it starts an AIO write for it through `pgaio_*`. It does not wait. It runs in the WAL writer and also in any backend whose `XLogFlush(L)` finds L not yet issued.
- **Durability per write.** With `O_DIRECT + O_DSYNC`, each completed write is already durable (a FUA write on capable devices). Without it, the issuer must also send an AIO `fdatasync` after the writes it covers have completed.
- **Range tracker.** A small shared structure in `XLogCtl` lists the in-flight ranges, ordered by LSN. A completion marks its range done. `Flush` moves to the end of the longest run of done ranges starting at the current `Flush`, never further.
- **Waiting.** `XLogFlush(L)` no longer takes `WALWriteLock` to do I/O itself. It makes sure L is issued, then sleeps on a condition variable until `Flush ≥ L`.
- **Bounded in-flight.** A cap (for example a new `wal_io_max_inflight` setting) limits concurrent WAL writes, so WAL cannot exhaust the AIO handles that data I/O also needs.

What stays the same: WAL record format, CRCs, recovery, segment files, and every caller of `XLogFlush()`. Only *how* the Flush pointer gets advanced changes.

## Worked examples of the new flow

### Example 1: writes finish out of order

The range tracker is what makes out-of-order completion safe. `Flush` only passes a range once every range below it is durable too.

&#91;embedded content: out-of-order completion · three snapshots of the range tracker\]

Why this is enough: recovery reads WAL sequentially and stops at the first record with a bad CRC. If C is torn or missing, recovery ends at 1600. No client was ever told that anything past 1600 committed, so nothing that was promised is lost.

If the tracker had set `Flush = 1600` already at snapshot 1 (because B was done), a crash before A finished would lose T5's commit after the client saw success. That is the bug the tracker exists to prevent.

### Example 2: the partially filled last page

The last WAL page is usually only partly filled when someone needs a flush.

1. Page P (8 kB) holds WAL 4000–4600. T7 commits at 4600, so the issuer writes P as it stands: **write W1**.
2. While W1 is in flight, T8 adds records 4600–5000 to the same page P. T8 commits, which needs P written again: **write W2**.
3. **The hazard:** if W1 and W2 are both in flight, the device may apply W2 first and W1 last. Disk then holds the *older* page, and T8's records vanish although W2 "completed".
4. **The fix:** never have two writes of the same block in flight. W2 waits for W1 to complete before it is submitted, or W2 includes only the full pages and the tail goes in a later write.
5. **Second hazard:** with `O_DIRECT`, the device reads page P from memory *while* T8 is still copying into it. Thomas Munro's patch "Writing out WAL buffers that are still in flux" copies the partial page to a private buffer before submitting.

### Example 3: the same three clients as today

Take T1–T3 committing at 1000, 1100, 1200 and T4 at 1350, as in the earlier example.

1. The WAL writer saw the inserts finish and had already submitted write A covering 0–1300. It submitted write B (1300–1400) when T4's record landed.
2. T1–T3 call `XLogFlush()`, see A is issued, and sleep. A completes, `Flush = 1300`, all three wake.
3. T4 also finds B already issued. It waits only for B's remaining time instead of a full extra write+fsync round.

## Correctness: what can go wrong and how each case is handled

Async I/O changes *when* waiting happens, not *what* is waited for. Every hazard below is about keeping the two rules true despite I/O that is in flight, out of order, or failing.

| Hazard | What goes wrong without care | How the design handles it |
| --- | --- | --- |
| Out-of-order completion | `Flush` passes a range whose lower neighbour is still in flight; a crash loses an acknowledged commit | Range tracker: `Flush` only advances over a contiguous run of done ranges (Example 1) |
| Completed but not durable | A buffered write completes into the page cache only; a power loss drops it | `O_DIRECT + O_DSYNC` so completion means durable; otherwise an AIO `fdatasync` issued only after the writes it covers completed |
| Same block written twice | Two in-flight writes of the last page land in the wrong order; the older version wins | At most one in-flight write per block; later writes of it wait (Example 2) |
| Buffer changed during DMA | With `O_DIRECT` the device reads a page that backends are still filling | Copy partial pages to a private bounce buffer before submitting (Munro patch) |
| WAL buffer reused too early | The ring wraps and `AdvanceXLInsertBuffer()` (`xlog.c:1988`) overwrites a buffer the device is still reading | Buffer stays pinned as "I/O in progress" until completion; insertion waits on it |
| Short write | Kernel reports fewer bytes than asked | Completion callback resubmits the remainder before marking the range done |
| Write or flush error | Retrying a failed fsync can hide lost data (the 2018 "fsyncgate" bug) | `PANIC` and recover from WAL, as today's `issue_xlog_fsync()` already does |
| Critical sections | WAL is written inside critical sections, where any error is a `PANIC` | AIO must issue and complete I/O there without allocating memory; AIO README says the subsystem was designed for this |
| Running out of AIO handles | WAL write cannot get a handle, but WAL writes "may not fail" (Freund) | Reserve a fixed pool of handles for WAL, or fall back to a synchronous write |
| Segment switch | A write spans the end of one 16 MB segment and the start of the next | Split writes at segment boundaries; a new segment's file must exist before its first write is issued |
| Replication and archiving | Walsenders send WAL that is not yet durable locally | Walsenders keep reading only up to `Flush`, and are woken when it advances |
| Torn page at the tail | Crash mid-write leaves half a page | Unchanged: per-record CRC lets recovery find the end of valid WAL |

**Proof obligation, in one sentence:** at every moment, all bytes below `Flush` are on stable storage, and no client has been told about a commit above `Flush`. The project's crash tests should check exactly that invariant.

## Code map

Almost all the change is in `src/backend/access/transam/xlog.c`. Everything else is a small hook-up.

| File (REL\_18\_STABLE) | Function or object | Change |
| --- | --- | --- |
| `access/transam/xlog.c:2304` | `XLogWrite()` | Split into "issue writes for a range" and "handle completion"; no blocking `pg_pwrite()` / `issue_xlog_fsync()` on the AIO path |
| `access/transam/xlog.c:2780` | `XLogFlush()` | Stop doing I/O under `WALWriteLock`; ensure issued, then wait on a condition variable for `Flush ≥ L` |
| `access/transam/xlog.c:2968` | `XLogBackgroundFlush()` | Becomes the main eager issuer: submit every newly completed range, not just on a timer |
| `access/transam/xlog.c:1988` | `AdvanceXLInsertBuffer()` | Before reusing a WAL buffer, wait for any in-flight write of it |
| `access/transam/xlog.c:328` | `XLogwrtResult`, `XLogCtl` | Add the in-flight range tracker and a condition variable to shared memory |
| `access/transam/xlog.c:8746` | `issue_xlog_fsync()` | Keep as the synchronous fallback; add an AIO fdatasync variant for buffered mode |
| `storage/aio/aio.c`, `aio_io.c` | `pgaio_io_start_writev()`, handle API | Use the existing writev support for WAL; possibly a reserved handle pool |
| `storage/aio/aio_target.c`, `aio_callback.c` | targets and completion callbacks | New WAL target and callback that report the LSN range done |
| `postmaster/walwriter.c` | main loop | Wake on "new range ready" as well as on the 200 ms timer |
| `utils/misc/guc_tables.c` | GUCs | `wal_io_method` (sync / aio) and an in-flight cap, so the old path stays default |
| `utils/activity/` (pg\_stat\_io) | WAL I/O stats | Count in-flight depth and wait time for evaluation |
| `src/test/recovery/t/` | TAP tests | Crash-injection tests that kill the server mid-I/O and check every acknowledged commit survives |

Worth reading first: `src/backend/storage/aio/README.md` (sections on writes and critical sections), and `read_stream.c` as an example of a real AIO user.

## Project plan, evaluation and risks

Keep the scope to the WAL writer and `XLogFlush()` on Linux with `io_method=io_uring`, and leave the old path as the default. That makes a 12-week project realistic.

&#91;embedded content: 12-week plan · 5 phases, 4 gates\]

**Evaluation matrix:**

| Dimension | Values to test |
| --- | --- |
| Write path | today (`fdatasync`), today with `open_datasync`, AIO + `O_DIRECT + O_DSYNC` |
| Storage | local NVMe; cloud block storage (higher flush latency) |
| Workload | `pgbench -N` (write-heavy), single-client latency, many small commits |
| Clients | 1, 8, 32, 128, 256 |
| Metrics | commit latency p50 / p99, TPS, WAL MB/s, CPU per commit, in-flight depth |

**Correctness testing:** TAP tests in `src/test/recovery` that run load, `kill -9` the server at random points, restart, and verify that every commit the client saw acknowledged is present. Also run the full regression and recovery suites with the AIO path forced on.

**Risks:**

- **Upstream overlap.** Andres Freund plans this himself. Mitigation: frame the work as a prototype + measurement study and discuss it on pgsql-hackers early.
- **Hardware variance.** FUA support and `O_DSYNC` speed differ widely between devices. Report results per device, not one headline number.
- **Scope creep.** Async fsync for buffered mode, segment pre-allocation and replication tuning can each fill a month. Treat them as stretch goals.

## Prior work and sources

**In PostgreSQL:**

- Committed `master` (checked 2026-10-12, commit `8e82d6610e`) has no AIO in `xlog.c`. The only AIO calls near WAL are `pgaio_error_cleanup()` in `xact.c` and `walwriter.c`.
- [Talking Postgres: What went wrong, what went right with AIO, with Andres Freund](https://talkingpostgres.com/episodes/what-went-wrong-what-went-right-with-aio-with-andres-freund/transcript): spent "at least a year and a half" on async WAL; calls it "a pretty large project" still ahead.
- [Re: AIO v2.0, pgsql-hackers](https://www.mail-archive.com/pgsql-hackers@lists.postgresql.org/msg178892.html): WAL AIO dropped from the upstream patchset in 2024.
- [Writing out WAL buffers that are still in flux](https://www.mail-archive.com/pgsql-hackers@lists.postgresql.org/msg182885.html) (Thomas Munro, 2024): partial-page copy for direct-I/O WAL.
- [Re: aio/README.md comments](https://www.mail-archive.com/pgsql-hackers@lists.postgresql.org/msg205588.html) and [Asynchronous and "direct" IO support for PostgreSQL](https://www.postgresql.org/message-id/20210223100344.llw5an2aklengrmn@alap3.anarazel.de) (2021 design thread).
- [Andres Freund, IO in PostgreSQL: Past, Present, Future (2022 talk)](https://anarazel.de/talks/2022-05-02-vaccination-db-aio/2022-05-02-vaccination-db-aio.pdf).

**In research:**

- [Jasny et al., High-Performance DBMSs with io\_uring: When and How to Use It](https://arxiv.org/pdf/2512.04859): notes that `fsync` through io\_uring still blocks in kernel worker threads.
- From memory, not checked for this doc: Aether (Johnson et al., VLDB 2010) on flush pipelining; Silo / SiloR (SOSP 2013, OSDI 2014) on epoch group commit; Haubenschild et al. (SIGMOD 2020) on decentralized logging for NVMe. Verify before citing.

Only the Talking Postgres transcript was opened in full; the other links come from search results and should be read before quoting.

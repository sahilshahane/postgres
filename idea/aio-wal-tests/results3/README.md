# Correctness of the current AIO WAL code (2026-11-24)

Code: commit `b6001c9004` plus the **`wal_sync_method` reload fix** below
(uncommitted when measured). Machine: the shared benchmark server (Ryzen 7
5700G, 16 threads, Intel 660p NVMe), data on XFS (`/mnt/xfs`). Suite:
`../tests/`, run with `tests/run_all.py` (`--epochs 8`; power cut `--epochs 6`).

**Result: 210 of 210 test runs passed, 0 failures, 0 acknowledged commits lost.**

| file | build | runs | crashes | acknowledged commits verified | random GUC reloads |
|---|---|---:|---:|---:|---:|
| `correctness_server_release.csv` | release | 66 / 66 | 312 | 166,258 | 977 |
| `correctness_server_debug.csv` | debug + cassert | 66 / 66 | 312 | 162,013 | 1,039 |
| `powercut_server_release.csv` | release | 39 / 39 | 234 power cuts | 109,582 | 743 |
| `powercut_server_debug.csv` | debug + cassert | 39 / 39 | 234 power cuts | 108,173 | 681 |

Per build: 13 configurations (`tests/modes.txt`) plus the stock baseline.

- `regress`: PostgreSQL regression + isolation suites, 373 tests, 14 of 14 runs passed.
- `crash`: SIGKILL of every process and of the postmaster only, alternating.
- `chaos`: crashes while `wal_io_*` and `wal_sync_method` are reloaded at random.
- `reload`: `wal_sync_method` switched at runtime to the other durability
  scheme, `fdatasync` <-> `open_datasync`.
- `repl`: streaming standby + archive + promotion.

After every recovery `amcheck` (B-tree and heap) was clean. No server log had
a PANIC or an assertion failure.

Power cut: dm-flakey under ext4 drops every write from the cut on and the page
cache is lost (`tests/dev.sh`). Negative control: with `fsync = off` the same
test fails at the first cut (an acknowledged commit is missing), so the test
does detect lost writes.

## Bug found and fixed: acknowledged commits not fsynced after a `wal_sync_method` reload

Found by `chaos` under power cut, reproduced deterministically by `reload`.

- **The bug.** In the fsync scheme (server started with `fdatasync` / `fsync`,
  `aioUseFsync`), WAL files are opened without O_DSYNC. After
  `wal_sync_method` was reloaded to `open_sync` / `open_datasync`, the inline
  fsync (`XLogAioRunInlineFsync()`, default on) and the synchronous fallback
  called `issue_xlog_fsync()`. That function returned without syncing for the
  open_* methods, because in stock PostgreSQL those files have O_DSYNC.
  Commits were acknowledged with no fsync.
- **Why the other tests missed it.** It is invisible to process-kill crashes,
  because the page cache survives them. Under power cut it lost commits at
  the first cut.
- **The fix** (`src/backend/access/transam/xlog.c`):
  - `issue_xlog_fsync()` skips the sync only if `get_sync_bit()` says the
    file has O_SYNC/O_DSYNC.
  - In the AIO fsync scheme the open_* methods do `fsync` / `fdatasync`.
  - The io_uring fsync uses datasync for `open_datasync`.
  - Stock behaviour and the walreceiver are unchanged.

| server started with `fdatasync`, power cuts | before fix | after fix |
|---|---|---|
| no reload | pass | pass |
| reload to `open_datasync` | **lost commits at the 1st cut** | pass |
| reload to `open_sync` | (not run) | pass |

## PostgreSQL TAP recovery suite with AIO WAL (before the fix)

`TEMP_CONFIG` (appended to every test cluster's postgresql.conf, verified in
a kept data directory) with `wal_io_method = aio`, `io_method = io_uring`,
`wal_sync_method = open_datasync`, `wal_io_max_inflight = 16`; debug +
cassert build, `meson test --suite recovery`:

**55 passed, 0 failed, 0 timeouts, 7 skipped.** The 7 skipped need injection
points, which this build doesn't have (`-Dinjection_points=false`):
035_standby_logical_decoding, 041_checkpoint_at_promote,
044_invalidate_inactive_slots, 046_checkpoint_logical_slot,
047_checkpoint_physical_slot, 050_redo_segment_missing,
057_snapshot_commit_race.

Not covered: a drive losing data it had already acknowledged from its own
volatile cache (dm-flakey drops writes only from the cut on); the TAP suite
for the other configurations.

## Change 2: wal_io_page_align (2026-11-24)

Modes `uring-ods-align`, `uring-ods-dio-align`, `uring-ods-dio-align-eager`,
`worker-ods-dio-align` (new) plus `uring-ods-dio-eager`, `uring-fds-default`;
chaos now also toggles `wal_io_page_align`. Release and debug+cassert x
regress, crash, chaos, reload, repl; power cut (debug) x crash, chaos,
reload: **80 of 80 passed**, 396 crashes or power cuts, 208,165
acknowledged commits checked, **0 lost**. Files: `change2_align_*.csv`.

## Change 3: wal_io_split_size (2026-11-25)

Modes `uring-ods-dio-split`, `uring-ods-split` (buffered, pipeline
threshold 0), `uring-ods-dio-split-align`, `uring-osync-split-noinline`,
`worker-ods-dio-split` (new, all `wal_io_split_size = 4kB`) plus
`uring-ods-dio-align`, `uring-fds-default`; chaos now also changes
`wal_io_split_size` (0 / 4kB / 64kB) while running. Release and
debug+cassert x regress, crash, chaos, reload, repl; power cut (debug) x
crash, chaos, reload: **93 of 93 passed**, 462 crashes or power cuts,
238,889 acknowledged commits checked, **0 lost**. The replication test saw
6-9 writes in flight with splitting (1-4 without). Files:
`change3_split_*.csv`.

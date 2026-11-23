# postgres_sahil — buffer eviction policy study

Benchmarks for the `buffer_eviction_policy` patch (clock, srrip, brrip, drrip,
sieve, s3fifo) on PostgreSQL 20devel. Source of truth for code and scripts is
the `idea2` branch of the dbms-project repo; this directory holds builds,
datasets and results.

| Path | Contents |
|---|---|
| `src/postgres/` | source tree used for the build (rsync of the repo, no .git) |
| `src/SOURCE_COMMIT`, `src/eviction.patch` | upstream base commit + full diff of the patch |
| `build/release/` | meson build dir (release, no cassert) |
| `install/release/` | installed binaries used by all benchmarks |
| `tools/benchbase/` | CMU BenchBase (TPC-C, YCSB, TPC-H), built for Java 21 |
| `tools/libCacheSim/` | libCacheSim simulator (ARC, LIRS, CLOCK-Pro, 2Q, Belady, ...) |
| `tools/evictsim/` | our trace replayer (mirrors the in-server policies + OPT/LRU) |
| `data/<bench>-pristine/` | loaded, vacuumed, checkpointed clusters (never modified) |
| `data/<bench>-run/` | scratch copy restored before every run |
| `bench/scripts/` | `load.sh`, `run_one.sh`, `sweep.sh`, `trace.sh`, `collect.py` |
| `bench/configs/` | postgresql.bench.conf, BenchBase XML templates, dataset sizes, BenchBase patch |
| `bench/results/<campaign>/<workload>/<policy>/sb<size>/rep<n>/` | one directory per run |
| `traces/`, `reports/` | trace analyses and generated reports |
| `logs/` | build and load logs |

Each run directory: `benchbase/` (BenchBase output), `postgres.log` (server log,
first line confirms the active policy), `pg_stat_database.csv`, `pg_stat_io.csv`,
`eviction_stats.csv` (pg_buffer_eviction_stats()), `waits.csv` (1 Hz wait-event
samples), `run.json` (parameters), `done` (marker; runs with it are skipped).

Method: `debug_io_direct=data` (no OS page cache, misses hit the SSD),
cold start from a pristine copy each run, bgwriter and autovacuum off,
synchronous_commit off, statistics reset after the warm-up.

# Correctness of the current AIO WAL code (2026-11-24)

Code: commit `b6001c9004` (the code under test; `2c3a6c4e6b` only changed the
test scripts). Machine: the shared benchmark server (Ryzen 7 5700G, 16
threads, Intel 660p NVMe), data on XFS (`/mnt/xfs`). Suite: `../tests/`,
run with `tests/run_all.py --epochs 8`.

| file | build |
|---|---|
| `correctness_server_release.csv` | `--buildtype=release`, no assertions (fast, so timing races show up more easily) |
| `correctness_server_debug.csv` | `--buildtype=debug -Dcassert=true` (assertions on) |

**Result: 106 of 106 test runs passed (53 per build), 0 failures.**

| | release | debug + cassert |
|---|---:|---:|
| configurations (`tests/modes.txt`) | 13 + stock baseline | 13 + stock baseline |
| regression + isolation (373 tests each) | 14 / 14 passed | 14 / 14 passed |
| crashes (half SIGKILL all, half postmaster only) | 208 | 208 |
| acknowledged commits verified after recovery | 117,631 | 113,938 |
| acknowledged commits lost | **0** | **0** |
| random reloads of the AIO GUCs + `wal_sync_method` under load | 1,024 | 973 |
| replication runs (primary crash, standby check, promote + crash) | 13 / 13 passed | 13 / 13 passed |
| PANIC / assertion failures in any server log | 0 | 0 |

After every recovery `amcheck` (B-tree and heap) was clean. In every
replication run the standby never had WAL beyond what the primary recovered,
caught up to identical contents, the archive had no gaps and `pg_waldump`
parsed all of it, and single-user mode with `wal_io_method = aio` worked.

Not covered here: power loss (`POWERCUT=1`, needs root; see `../README.md`)
and PostgreSQL's TAP suites (need perl `IPC::Run`, not installed on the
server).

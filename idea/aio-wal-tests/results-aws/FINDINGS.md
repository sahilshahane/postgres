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

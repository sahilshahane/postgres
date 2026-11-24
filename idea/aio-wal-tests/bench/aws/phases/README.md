# Per-phase scripts (AWS gp3 VM unless noted)

Each `run_*.sh` runs on the VM from `~/pgaio/bench/`, writes `~/pgaio/results-aws-*/`
and ends with a `*_DONE` marker; `INST` in the configs is replaced by `~/pgaio/inst`.
The `driver*.sh` scripts run on the lab server: they upload the files, start the
phase on the VM, wait for the marker and copy the results into `results-aws/`.

| Phase | Config | Script | Results |
|---|---|---|---|
| 4: 4 kB WAL pages | `cfg_4k.txt` | `build4.sh`, `run_4k.sh` | `results-aws/04-4k-pages/` |
| 5: change 2 (page align) | `cfg_align.txt` | `run_align.sh` (rebuilds aio4) | `results-aws/05-page-align/` |
| 6: large commits, shared table | `cfg_big4.txt` | `run_big4.sh` | `results-aws/06-big-4k-align/` |
| 7: large commits, table per client | `cfg_bigpc.txt` | `run_bigpc.sh` | `results-aws/07-bigpc-4k-align/` |
| 8a: fio split writes, sync vs async commit | `cfg_m8.txt` | `m8.sh` | `results-aws/08a-large-commit-profile/` |
| 8b: change 3 (split writes) | `cfg_split.txt` | `run_split.sh` (rebuilds aio4) | `results-aws/08b-split-writes/` |
| 8c: split writes, in-flight cap | `cfg_split2.txt` | `run_split2.sh` | `results-aws/08c-split-inflight-cap/` |
| 8d: threshold 256 kB + split | `cfg_thr_big.txt`, `cfg_thr_small.txt` | `run_thr.sh` | `results-aws/08d-threshold-256k/` |
| 8e: screening (short runs) | `cfg_screen.txt` | `run_screen.sh` | `results-aws/08e-screening/` |
| 8f: screening with QUIESCE=1 | `cfg_screen.txt` | `run_screen_q.sh` | `results-aws/08f-screening-quiesce/` |

`run_align_tests.sh`: change 2 correctness suite on the lab server
(`~/pgaio/latest`), results in `results3/change2_align_*.csv`.

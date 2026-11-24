#!/bin/bash
cd ~/pgaio/latest
M=uring-ods-align,uring-ods-dio-align,uring-ods-dio-align-eager,worker-ods-dio-align,uring-ods-dio-eager,uring-fds-default
python3 -u tests/run_all.py --inst ~/pgaio/latest/inst --build ~/pgaio/latest/build --work /mnt/xfs/align-rel --modes $M --out ~/pgaio/latest/align_release.csv --label "page align, release" --port 59400 > align_rel.log 2>&1 &
python3 -u tests/run_all.py --inst ~/pgaio/latest/inst-dbg --build ~/pgaio/latest/build-dbg --work /mnt/xfs/align-dbg --modes $M --out ~/pgaio/latest/align_debug.csv --label "page align, debug+cassert" --port 59600 > align_dbg.log 2>&1 &
wait
export TESTDISK_DIR=/mnt/xfs/pgtestdisk POWERCUT=1 PGDATA_DIR=/mnt/xfs/pgtestdisk/mnt/data
sudo -n -E tests/dev.sh setup 0 0 > /dev/null && sudo -n -E tests/dev.sh check &&
python3 -u tests/run_all.py --inst ~/pgaio/latest/inst-dbg --work /mnt/xfs/align-pc --modes $M --tests crash,chaos,reload --epochs 6 --out ~/pgaio/latest/align_powercut.csv --label "page align, power cut, debug" --port 59700 > align_pc.log 2>&1
sudo -n -E tests/dev.sh teardown > /dev/null 2>&1
echo ALIGN_DONE >> align_pc.log

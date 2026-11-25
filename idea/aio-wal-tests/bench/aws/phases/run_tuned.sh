#!/bin/bash
# phase 9: tuned stock vs AIO, large commits, 6 rounds x 10 s, QUIESCE=1
P=$HOME/pgaio; R=$P/results-aws-tuned; mkdir -p $R
sed "s|INST|$P/inst|" $P/bench/cfg_tuned.txt > $R/cfg.txt
CLIENTS="1 4 16 32" ROUNDS=6 SECONDS_=10 CANARY_MAX=6000 QUIESCE=1 WORKLOAD=bigpc WORKDIR=/mnt/xfs/b3 GOLDEN=/mnt/xfs/golden4 \
  bash $P/bench/bench.sh $R/cfg.txt $R/raw.csv > $R/log.txt 2>&1
python3 $P/bench/analyze.py $R/cfg.txt $R/raw.csv $R > $R/analysis.txt 2>&1
cat /sys/block/nvme1n1/queue/max_sectors_kb > $R/msk_after.txt
echo P9_DONE >> $R/log.txt

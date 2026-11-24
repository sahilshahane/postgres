#!/bin/bash
R=~/pgaio/results-aws-eager; mkdir -p $R
sed "s|INST|$HOME/pgaio/inst|" ~/pgaio/bench/cfg_eager.txt > $R/cfg.txt
CLIENTS="8 16 32 64" ROUNDS=8 SECONDS_=10 CANARY_MAX=6000 WORKLOAD=pgbench WORKDIR=/mnt/xfs/b3 GOLDEN=/mnt/xfs/golden-s20 \
  bash ~/pgaio/bench/bench.sh $R/cfg.txt $R/raw.csv > $R/log.txt 2>&1
python3 ~/pgaio/bench/analyze.py $R/cfg.txt $R/raw.csv $R > $R/analysis.txt 2>&1
C=32 bash ~/pgaio/fsynctime_eager.sh > $R/gap.txt 2>&1
echo EAGER_DONE >> $R/log.txt

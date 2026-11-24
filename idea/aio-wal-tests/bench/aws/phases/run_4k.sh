#!/bin/bash
R=~/pgaio/results-aws-4k; mkdir -p $R
sed "s|INST|$HOME/pgaio/inst|" ~/pgaio/bench/cfg_4k.txt > $R/cfg.txt
CLIENTS="1 4 8 16 32 64" ROUNDS=6 SECONDS_=10 CANARY_MAX=6000 WORKLOAD=pgbench WORKDIR=/mnt/xfs/b3 GOLDEN=/mnt/xfs/golden4 \
  bash ~/pgaio/bench/bench.sh $R/cfg.txt $R/raw.csv > $R/log.txt 2>&1
python3 ~/pgaio/bench/analyze.py $R/cfg.txt $R/raw.csv $R > $R/analysis.txt 2>&1
echo P4_DONE >> $R/log.txt

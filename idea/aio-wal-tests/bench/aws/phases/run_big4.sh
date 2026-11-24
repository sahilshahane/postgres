#!/bin/bash
P=$HOME/pgaio; R=$P/results-aws-big4; mkdir -p $R
sed "s|INST|$P/inst|" $P/bench/cfg_big4.txt > $R/cfg.txt
CLIENTS="1 4 16 32" ROUNDS=6 SECONDS_=10 CANARY_MAX=6000 WORKLOAD=big WORKDIR=/mnt/xfs/b3 GOLDEN=/mnt/xfs/golden4 \
  bash $P/bench/bench.sh $R/cfg.txt $R/raw.csv > $R/log.txt 2>&1
python3 $P/bench/analyze.py $R/cfg.txt $R/raw.csv $R > $R/analysis.txt 2>&1
echo P6_DONE >> $R/log.txt

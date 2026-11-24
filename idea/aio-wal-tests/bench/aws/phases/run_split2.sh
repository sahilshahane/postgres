#!/bin/bash
# phase 8c: benchmark (aio4 already has change 3) large commits (one table per client)
P=$HOME/pgaio; R=$P/results-aws-split2; mkdir -p $R
sed "s|INST|$P/inst|" $P/bench/cfg_split2.txt > $R/cfg.txt
CLIENTS="1 4 16 32" ROUNDS=6 SECONDS_=10 CANARY_MAX=6000 WORKLOAD=bigpc WORKDIR=/mnt/xfs/b3 GOLDEN=/mnt/xfs/golden4 \
  bash $P/bench/bench.sh $R/cfg.txt $R/raw.csv >> $R/log.txt 2>&1
python3 $P/bench/analyze.py $R/cfg.txt $R/raw.csv $R > $R/analysis.txt 2>&1
echo P8C_DONE >> $R/log.txt

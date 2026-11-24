#!/bin/bash
# phase 8f: screening rerun with QUIESCE=1 (3 rounds x 8 s, large commits, 1/4/32 clients)
P=$HOME/pgaio; R=$P/results-aws-screen-q; mkdir -p $R
sed "s|INST|$P/inst|" $P/bench/cfg_screen.txt > $R/cfg.txt
CLIENTS="1 4 32" ROUNDS=3 SECONDS_=8 CANARY_MAX=6000 QUIESCE=1 WORKLOAD=bigpc WORKDIR=/mnt/xfs/b3 GOLDEN=/mnt/xfs/golden4 \
  bash $P/bench/bench.sh $R/cfg.txt $R/raw.csv > $R/log.txt 2>&1
python3 $P/bench/analyze.py $R/cfg.txt $R/raw.csv $R > $R/analysis.txt 2>&1
echo P8F_DONE >> $R/log.txt

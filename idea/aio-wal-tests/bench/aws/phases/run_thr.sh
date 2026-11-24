#!/bin/bash
# phase 8d: pipeline threshold 256 kB vs 4 kB with split writes; large then small commits
P=$HOME/pgaio
for w in big small; do
  R=$P/results-aws-thr-$w; mkdir -p $R
  sed "s|INST|$P/inst|" $P/bench/cfg_thr_$w.txt > $R/cfg.txt
  if [ $w = big ]; then WL=bigpc; CL="1 4 16 32"; else WL=pgbench; CL="16 64"; fi
  CLIENTS="$CL" ROUNDS=6 SECONDS_=10 CANARY_MAX=6000 WORKLOAD=$WL WORKDIR=/mnt/xfs/b3 GOLDEN=/mnt/xfs/golden4 \
    bash $P/bench/bench.sh $R/cfg.txt $R/raw.csv > $R/log.txt 2>&1
  python3 $P/bench/analyze.py $R/cfg.txt $R/raw.csv $R > $R/analysis.txt 2>&1
done
echo P8D_DONE >> $P/results-aws-thr-small/log.txt

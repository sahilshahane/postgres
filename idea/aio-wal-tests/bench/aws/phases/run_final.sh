#!/bin/bash
# phase 11: final stock vs AIO, small (pgbench -N) and large (bigpc) commits, 3 rounds x 10 s, QUIESCE=1
P=$HOME/pgaio; B=$P/results-aws-final; mkdir -p $B
for w in "pgbench:1 4 8 16 32 64" "bigpc:1 4 16 32 64"; do
  W=${w%%:*}; R=$B/$W; mkdir -p $R
  sed "s|INST|$P/inst|" $P/bench/cfg_final.txt > $R/cfg.txt
  CLIENTS="${w#*:}" ROUNDS=3 SECONDS_=10 CANARY_MAX=6000 QUIESCE=1 WORKLOAD=$W WORKDIR=/mnt/xfs/b3 GOLDEN=/mnt/xfs/golden4 \
    bash $P/bench/bench.sh $R/cfg.txt $R/raw.csv > $R/log.txt 2>&1 || echo "bench failed" >> $R/log.txt
  python3 $P/bench/analyze.py $R/cfg.txt $R/raw.csv $R > $R/analysis.txt 2>&1
  echo "$W done $(date -u)" >> $B/progress.txt
done
echo P11_DONE >> $B/progress.txt

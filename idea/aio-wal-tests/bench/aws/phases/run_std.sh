#!/bin/bash
# phase 10: standard benchmarks, 3 rounds, QUIESCE=1; one results dir per workload
P=$HOME/pgaio; B=$P/results-aws-std; mkdir -p $B
for w in ${WORKLOADS:-ycsb:15 sysbench-wo:10 sysbench-ins:10 copy:10 tpcc:15}; do
  W=${w%:*}; R=$B/$W; mkdir -p $R
  C="1 4 16 64"; [ $W = copy ] && C="1 4 16"
  sed "s|INST|$P/inst|" $P/bench/cfg_std.txt > $R/cfg.txt
  CLIENTS="$C" ROUNDS=3 SECONDS_=${w#*:} CANARY_MAX=6000 QUIESCE=1 WORKLOAD=$W WORKDIR=/mnt/xfs/b3 GOLDEN=/mnt/xfs/golden-std \
    bash $P/bench/bench.sh $R/cfg.txt $R/raw.csv > $R/log.txt 2>&1 || echo "bench failed" >> $R/log.txt
  python3 $P/bench/analyze.py $R/cfg.txt $R/raw.csv $R > $R/analysis.txt 2>&1
  echo "$W done $(date -u)" >> $B/progress.txt
done
echo P10_DONE >> $B/progress.txt

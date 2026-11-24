#!/bin/bash
# phase 8b: rebuild aio4 with change 3, then benchmark large commits (one table per client)
P=$HOME/pgaio; R=$P/results-aws-split; mkdir -p $R
tar xzf $P/split_src.tgz -C $P/src/aio
( cd $P/src/aio && ninja -C build4 -j8 install > $R/build.log 2>&1 ) || { echo BUILD_FAILED >> $R/log.txt; exit 1; }
$P/inst/aio4/bin/postgres --describe-config 2>/dev/null | grep -q wal_io_split_size || { echo GUC_MISSING >> $R/log.txt; exit 1; }
sed "s|INST|$P/inst|" $P/bench/cfg_split.txt > $R/cfg.txt
CLIENTS="1 4 16 32" ROUNDS=6 SECONDS_=10 CANARY_MAX=6000 WORKLOAD=bigpc WORKDIR=/mnt/xfs/b3 GOLDEN=/mnt/xfs/golden4 \
  bash $P/bench/bench.sh $R/cfg.txt $R/raw.csv >> $R/log.txt 2>&1
python3 $P/bench/analyze.py $R/cfg.txt $R/raw.csv $R > $R/analysis.txt 2>&1
echo P8_DONE >> $R/log.txt

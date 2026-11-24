#!/bin/bash
# phase 5: rebuild aio4 with change 2, then benchmark (same settings as phase 4)
P=$HOME/pgaio; R=$P/results-aws-align; mkdir -p $R
tar xzf $P/align_src.tgz -C $P/src/aio
( cd $P/src/aio && ninja -C build4 -j8 install > $R/build.log 2>&1 ) || { echo BUILD_FAILED >> $R/log.txt; exit 1; }
$P/inst/aio4/bin/postgres --describe-config 2>/dev/null | grep -q wal_io_page_align || { echo "GUC_MISSING" >> $R/log.txt; exit 1; }
sed "s|INST|$P/inst|" $P/bench/cfg_align.txt > $R/cfg.txt
CLIENTS="1 4 8 16 32 64" ROUNDS=6 SECONDS_=10 CANARY_MAX=6000 WORKLOAD=pgbench WORKDIR=/mnt/xfs/b3 GOLDEN=/mnt/xfs/golden4 \
  bash $P/bench/bench.sh $R/cfg.txt $R/raw.csv >> $R/log.txt 2>&1
python3 $P/bench/analyze.py $R/cfg.txt $R/raw.csv $R > $R/analysis.txt 2>&1
echo P5_DONE >> $R/log.txt

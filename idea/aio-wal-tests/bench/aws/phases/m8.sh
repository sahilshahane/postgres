#!/bin/bash
P=$HOME/pgaio; R=$P/results-aws-m8; mkdir -p $R
# 1. fio: 160 kB of durable direct writes as 1 x 160k, 4 x 40k, 8 x 20k, 20 x 8k in parallel
F=/mnt/xfs/fiotest; for spec in "160k 1" "40k 4" "20k 8" "8k 20"; do set -- $spec
  fio --name=w --filename=$F --size=2g --rw=write --bs=$1 --iodepth=$2 --ioengine=io_uring --direct=1 --sync=dsync \
      --time_based --runtime=20 --output-format=json > $R/fio_$1_qd$2.json 2>&1
  python3 -c "import json,sys;j=json.load(open('$R/fio_$1_qd$2.json'))['jobs'][0]['write'];n=$2;print(f'bs=$1 qd=$2: {j[\"iops\"]:.0f} IOPS, clat mean {j[\"clat_ns\"][\"mean\"]/1e6:.2f} ms, p99 {j[\"clat_ns\"][\"percentile\"][\"99.000000\"]/1e6:.2f} ms, time per 160 kB {n/j[\"iops\"]*1000:.2f} ms, {j[\"bw\"]/1024:.0f} MiB/s')" >> $R/fio.txt
done; rm -f $F
# 2. sync vs async commit, large commits with one table per client
sed "s|INST|$P/inst|" $P/bench/cfg_m8.txt > $R/cfg.txt
CLIENTS="1 4 16" ROUNDS=3 SECONDS_=10 CANARY_MAX=6000 WORKLOAD=bigpc WORKDIR=/mnt/xfs/b3 GOLDEN=/mnt/xfs/golden4 \
  bash $P/bench/bench.sh $R/cfg.txt $R/raw.csv > $R/log.txt 2>&1
python3 $P/bench/analyze.py $R/cfg.txt $R/raw.csv $R > $R/analysis.txt 2>&1
echo M8_DONE >> $R/log.txt

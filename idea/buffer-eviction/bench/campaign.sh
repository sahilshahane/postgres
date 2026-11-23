#!/bin/bash
# campaign.sh CAMPAIGN -- the full study, in priority order.  Restartable:
# finished runs (and finished trace analyses) are skipped.
set -uo pipefail
S=$(dirname "$0")
C=${1:-main}
SBS="128MB 256MB 512MB 1GB"
POL="clock srrip brrip drrip sieve s3fifo"
$S/sweep.sh $C tpcc   tpcc   "$SBS" "$POL" 2
$S/sweep.sh $C ycsb   ycsb-b "$SBS" "$POL" 2
$S/sweep.sh $C tpch   tpch   "$SBS" "$POL" 1
$S/sweep.sh $C ycsb   ycsb-e "$SBS" "$POL" 2
# offline: traces at 256MB, replayed at 64MB..1GB (8192..131072 pages)
for wl in tpcc:tpcc ycsb:ycsb-b ycsb:ycsb-e tpch:tpch; do
  $S/trace.sh $C-trace ${wl%%:*} ${wl##*:} 256MB 8192,16384,32768,65536,131072 || echo "TRACE FAILED $wl"
done
python3 $S/collect.py /home/neel/postgres_sahil/bench/results/$C > /home/neel/postgres_sahil/reports/$C-runs.csv
echo "campaign $C finished $(date)"
